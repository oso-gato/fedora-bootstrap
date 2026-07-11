#!/usr/bin/env bash
# fedora-bootstrap — USER phase: the rootless layer.
#
# Run AS the unprivileged operating user (NOT root). Brings up the user's podman socket,
# authorizes SSH keys into the user's own ~/.ssh, builds the claudebox Distrobox, stamps
# the Claude policy, and verifies. It needs NO host privilege — the system layer was
# already provisioned as root by setup-host.sh. The only escalation here is INSIDE the
# box (the container's own root). See README "Privilege layers". Idempotent.
set -euo pipefail
[ "$(id -u)" != 0 ] || { echo "setup-user.sh is the ROOTLESS layer and must run as the unprivileged user, not root. Run setup.sh as root, or 'su - <user> -c .../setup-user.sh'." >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
PHASE() { printf '\n==== %s ====\n' "$*"; }

PHASE "user 1/5 rootless podman socket"
# The user manager + bus were brought up by the root phase (setup-host.sh); this just
# enables the per-user podman API socket the box drives via CONTAINER_HOST.
[ -S "$XDG_RUNTIME_DIR/bus" ] || { echo "FATAL: user D-Bus ($XDG_RUNTIME_DIR/bus) is not up — run the SYSTEM phase (setup.sh as root / setup-host.sh) first." >&2; exit 1; }
systemctl --user enable --now podman.socket

PHASE "user 2/5 ssh keys (from github.com/${GH_KEYS_USER:-oso-gato}.keys — all account keys)"
# Writes THIS user's own ~/.ssh/authorized_keys (user layer; no host privilege). GitHub
# is the key registry — no keys in this repo. Re-running resyncs.
bash "$HERE/sync-authorized-keys.sh"

PHASE "user 3/5 claudebox (declarative assemble from distrobox.ini) + Claude policy"
# ORDER-CRITICAL: the assemble below pulls the claudebox base (quay.io/fedora/
# fedora-toolbox, distrobox.ini) — but the image-trust policy.json is written/
# merged later, in user 4/5. On an ALREADY-DEPLOYED host whose policy.json
# already default-rejects everything but ghcr.io/oso-gato + Fedora base, that pull
# is REJECTED before user 4/5 ever runs to fix it ("Source image ... is rejected
# by policy") — so a re-run of setup.sh fails here every time. Pre-trust the
# toolbox base NOW, before the assemble, so the script self-heals. Idempotent; a
# FRESH host has no policy.json yet and assembles under the permissive default
# (then user 4/5 writes the full policy WITH the toolbox scope), so this is a
# no-op there. The full create/merge in user 4/5 is unchanged.
if [ -e "$HOME/.config/containers/policy.json" ]; then
    python3 - "$HOME/.config/containers/policy.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
docker = d.setdefault("transports", {}).setdefault("docker", {})
if "quay.io/fedora/fedora-toolbox" not in docker:
    docker["quay.io/fedora/fedora-toolbox"] = [{"type": "insecureAcceptAnything"}]
    with open(p, "w") as f:
        json.dump(d, f, indent=4); f.write("\n")
    print("[policy] pre-assemble: trusted quay.io/fedora/fedora-toolbox (claudebox base)")
PY
fi
cd "$HERE" && distrobox assemble create --file distrobox.ini
echo ">> first enter builds the box (dnf install claude-code from Anthropic + init hooks) — this can take a minute"
distrobox enter claudebox -- true   # triggers distrobox-init (dnf install claude-code + tools)
# AUTHORITATIVE build barrier — do NOT trust the `-- true` exit alone. distrobox-enter only WAITS for
# init completion in the enter that actually `podman start`ed the box; a *concurrent* enter that finds
# it already running skips the wait and returns 0 while dnf is still in flight (this is exactly the
# rebuild race the live-gate watcher caused — now prevented in box-rebuild.sh + the watcher's
# ExecCondition). Belt-and-suspenders: assert the init's real signature (claude-code installed) before
# touching the box further, so a half-built box can never be mislabeled "built" at the policy/verify
# steps below. Loud, bounded wait (<< the run service's TimeoutStartSec); a genuine dnf failure already
# made the `-- true` above exit nonzero (set -e), so reaching here means init merely needs to finish.
for _i in $(seq 1 120); do
    if distrobox enter claudebox -- command -v claude >/dev/null 2>&1; then break; fi
    sleep 5
done
distrobox enter claudebox -- command -v claude >/dev/null 2>&1 || {
    echo "FATAL: claudebox init did not complete — claude-code is not installed after the box build." \
         "The distrobox-init dnf install failed or was interrupted (e.g. a concurrent 'distrobox enter'" \
         "raced it). Aborting the rebuild rather than leaving a half-built box." >&2
    exit 1
}
# Guard: the box's root maps to THIS user via keep-id (NOT real root), so the bridge + policy steps
# below can only read the repo at /run/host$HERE if the clone dir is traversable+readable by this
# user. Day-0 clones to /opt/fedora-bootstrap (root umask 022 -> world-traversable), which is fine; a
# 0700 clone dir would otherwise fail those steps with a cryptic Permission denied. Fail loudly here.
distrobox enter claudebox -- test -r "/run/host$HERE/claudebox-init.sh" || {
    echo "FATAL: claudebox cannot read this repo at /run/host$HERE — the clone dir is not readable by" \
         "$(id -un) (uid $(id -u)). Clone to /opt/fedora-bootstrap per Day-0, or make the path" \
         "traversable+readable by this user, then re-run setup.sh." >&2
    exit 1
}
# Wire the box's host bridges (CONTAINER_HOST -> host podman socket; systemctl/journalctl/loginctl/
# flatpak shims). Done here, NOT via distrobox.ini init_hooks: distrobox-create single-quote-wraps
# init_hooks and re-evals them on the host, so any quote in the hook escapes and runs as this
# unprivileged user (Permission denied on /etc, /usr/local/bin). The `sudo` is the CONTAINER's own
# root; we pass only a path + our numeric uid, so nothing crosses the boundary that could detonate.
distrobox enter claudebox -- sudo bash "/run/host$HERE/claudebox-init.sh" "$(id -u)"
# Stamp the enterprise policy into the box. The `sudo` here is the CONTAINER's root
# (distrobox grants it passwordless inside the box), NOT the host's root.
# Assemble the law: per-box header + <!--FLEET-CORE--> marker replaced by fleet-core.md
# (fleet-core.md mastered in fedora-dev). Use the local live clone if present;
# fall back to GitHub raw (public repo; on Day-0 the live clone may not exist yet).
distrobox enter claudebox -- sudo mkdir -p /etc/claude-code
_fc="${HOME}/.local/share/fedora-dev/policy/fleet-core.md"
if [ ! -f "$_fc" ]; then
    _fc=$(mktemp /tmp/fleet-core-XXXXXX)
    curl -fsSL "https://raw.githubusercontent.com/oso-gato/fedora-dev/main/policy/fleet-core.md" \
        > "$_fc" || { echo "FATAL: cannot fetch fleet-core.md from fedora-dev" >&2; rm -f "$_fc"; exit 1; }
fi
_law=$(mktemp /tmp/assembled-law-XXXXXX)
sed -e "/<!--FLEET-CORE-->/r ${_fc}" \
    -e "/<!--FLEET-CORE-->/d" \
    "${HERE}/policy/CLAUDE.md" > "$_law"
distrobox enter claudebox -- sudo cp "/run/host${_law}" /etc/claude-code/CLAUDE.md
rm -f "$_law" "$_fc"
distrobox enter claudebox -- sudo cp "/run/host$HERE/policy/managed-settings.json" /etc/claude-code/managed-settings.json
# UNSHACKLED (P0, 2026-07-11): the gate-push PreToolUse hook is RETIRED fleet-wide — policy/hooks/
# no longer exists and managed-settings.json registers no PreToolUse hook. Interactive-merge safety
# is the require-PR server ruleset + the `Bash(gh pr merge:*)` deny in managed-settings.json; the
# autonomous merge path is the dev-side poller's two independent gates. Remove any hooks dir a
# PREVIOUS stamp left so an already-deployed box converges to the hook-free state on rebuild.
distrobox enter claudebox -- sudo rm -rf /etc/claude-code/hooks
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user" "$HOME/.local/state/claudebox"

# `claude` entry wrapper. XDG_RUNTIME_DIR is pinned so `su core` works (su keeps the prior user's
# value, which would send rootless podman to /run/user/0 -> "mkdir /run/user/0/libpod: permission
# denied"); a normal SSH login already has the right value, so it is a no-op there. It holds a SHARED
# session lock (so the DAILY refresh can tell a session is live and defer), and on exit it (a) follows
# a Claude-triggered rebuild, or (b) runs a daily refresh that was deferred while you worked — your
# "quit -> it rebuilds". BOX STARTUP DEFAULTS (Arthur, 2026-07-11 — a fleet build requirement, identical
# to fedora-dev's bin/claude): the wrapper launches claude with three flags so every session STARTS ready
# at full capability with NO per-session toggling, all session-scoped (survive rebuilds without depending
# on accumulated home state) and all overridable mid-session:
#   --model default        the RECOMMENDED model, NOT a version pin — the `default` alias resolves to the
#                          provider's recommended model and auto-follows new releases (Opus 4.8 today,
#                          Sonnet 5 on lower tiers; every recommended tier is xhigh/ultracode-capable). This
#                          un-pins the model (was `--model opus`, which Arthur does not want) AND avoids the
#                          2.1.195 regression where dropping --model let the client fall to a non-ultracode
#                          Sonnet default.
#   --permission-mode auto AUTO mode (not manual) — a launch flag so a FRESH box reliably starts autonomous
#                          (a bare box came up "manual"). RECONCILIATION with the v1.2.59 unshackle: that
#                          release set managed-settings `defaultMode: default` as the NO-FLAG floor; this
#                          launch flag is the DELIBERATE per-box override back to auto for the operator's
#                          session — an explicit choice, not a silent regression — and it does NOT re-add
#                          the removed gate-push hook/prompts.
#   --effort ultracode     the canonical ultracode flag (xhigh effort + dynamic workflows); replaces the old
#                          `--settings '{"ultracode":true}'` injection. Ultracode is session-only by design.
# effortLevel:xhigh stays in policy/managed-settings.json as the persistent floor for any non-wrapper path.
# Emitted via a QUOTED heredoc so $(id -u)/"$@"/$HOME/$state stay LITERAL.
cat > "$HOME/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
state="$HOME/.local/state/claudebox"; mkdir -p "$state"
# If a rebuild is already running, follow it instead of entering a half-built box.
if systemctl --user is-active --quiet claudebox-rebuild-run.service 2>/dev/null; then
    exec "$HOME/.local/bin/claudebox-rebuild" --watch-only
fi
# Hold a SHARED session lock for the session's lifetime so the daily refresh defers while you work.
# Retry the transient post-rebuild OCI/PTY race: right after a box rebuild the freshly (re)started
# container's /dev/pts can need a moment before an interactive `podman exec` can allocate a
# pseudo-terminal, so the FIRST `distrobox enter` can fail with
#     Error: OCI runtime error: crun: ptsname: Inappropriate ioctl for device
# distrobox-enter ends in `exec "$@"` (it execs into `podman exec`), so podman's exit code reaches us
# verbatim through flock. 125/126 are podman/OCI exec-SETUP failures: a session that actually started
# returns its OWN code (claude is a Node app that exits 0/1/130, not these), so they uniquely mark
# "couldn't enter yet" and are the only codes safe to retry. Bounded to 6 retries, short escalating
# backoff capped at 4s (~18s total — comfortably past the observed ~15s warmup window). Every other
# outcome breaks out at once and is surfaced unchanged: success, Ctrl-C=130, a genuine nonzero — and
# the start-phase path (a box that is NOT already running enters via distrobox's start block, which
# returns 1, not 125/126; that path boots PID 1 with no interactive pty, so /dev/pts has settled
# before the exec and the ptsname race does not arise there — it is intentionally not retried).
attempt=0
while :; do
    flock -s "$state/session.lock" distrobox enter claudebox -- bash -lc 'exec /usr/bin/claude --model default --permission-mode auto --effort ultracode "$@"' bash "$@"
    rc=$?
    { [ "$rc" -eq 125 ] || [ "$rc" -eq 126 ]; } && [ "$attempt" -lt 6 ] || break
    attempt=$((attempt + 1))
    printf >&2 '>> claudebox is still warming up after the rebuild — retrying entry (%d/6)…\n' "$attempt"
    sleep "$(( attempt < 4 ? attempt : 4 ))"
done
# Post-session: (a) Claude triggered a rebuild -> follow it to completion; else (b) a daily refresh
# was deferred while you worked AND no other session is active now -> rebuild now and follow it.
if systemctl --user is-active --quiet claudebox-rebuild-run.service 2>/dev/null; then
    exec "$HOME/.local/bin/claudebox-rebuild" --watch-only
elif [ -e "$state/rebuild.pending" ] && flock -n -x "$state/session.lock" -c true 2>/dev/null; then
    rm -f "$state/rebuild.pending"
    echo ">> a daily claudebox refresh came due while you were working — rebuilding now…"
    exec "$HOME/.local/bin/claudebox-rebuild"
fi
exit "$rc"
EOF
chmod +x "$HOME/.local/bin/claude"

# `claudebox-rebuild` HOST command: deliberately rebuild the box from the host shell and follow it.
# The rebuild runs as a DETACHED user service (claudebox-rebuild-run.service) so it outlives the box
# it recreates; this command only triggers + tails it, so Ctrl-C is safe (the rebuild keeps going).
cat > "$HOME/.local/bin/claudebox-rebuild" <<'EOF'
#!/usr/bin/env bash
# claudebox-rebuild              start a full box rebuild and follow it to completion
# claudebox-rebuild --watch-only follow an already-running rebuild (used by the claude wrapper)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
run=claudebox-rebuild-run.service
follower=
trap '[ -n "$follower" ] && kill "$follower" 2>/dev/null' EXIT INT TERM
if [ "${1:-}" != "--watch-only" ]; then
    systemctl --user reset-failed "$run" 2>/dev/null || true
    echo ">> claudebox: starting rebuild — fresh image + latest Claude Code (~2-5 min)…"
    systemctl --user start --no-block "$run"
fi
journalctl --user -u "$run" -f -n 0 --no-hostname 2>/dev/null & follower=$!
for _ in $(seq 1 20); do systemctl --user is-active --quiet "$run" && break; sleep 0.5; done
while systemctl --user is-active --quiet "$run"; do sleep 2; done
sleep 1
if systemctl --user is-failed --quiet "$run"; then
    echo ">> claudebox rebuild FAILED — inspect: journalctl --user -u $run -e"
    exit 1
fi
echo ">> claudebox rebuild COMPLETE — run 'claude' to reconnect (you're still logged in)."
EOF
chmod +x "$HOME/.local/bin/claudebox-rebuild"

# Box-rebuild harness (NO schedule — rebuild is always deliberate). Three user units in core's
# lingering systemd manager (linger is enabled by the root phase, so they run with no login and
# OUTLIVE the box). Verified design (systemd.path/.service + flag file across the HOME bind mount):
#   claudebox-rebuild.path     watches the in-box flag (PathExists), fires the handler
#   claudebox-rebuild.service  consumes the flag, then fire-and-forgets the run service --no-block
#   claudebox-rebuild-run.*    the actual destroy+recreate; started as its OWN unit so systemd's
#                              cgroup teardown of the handler (and `distrobox rm -f` killing the box)
#                              cannot kill the rebuild mid-flight. A fixed unit name serializes the
#                              host-trigger and the agent-trigger for free.
# A lingering user service inherits NO login shell, so the run unit hard-sets DBUS/PATH (XDG_RUNTIME_DIR
# is provided by the manager but set defensively). %U=uid, %h=home are systemd specifiers (left literal).
cat > "$HOME/.config/systemd/user/claudebox-rebuild-run.service" <<EOF
[Unit]
Description=Rebuild the claudebox Distrobox (destroy + recreate from the pinned manifest)
After=podman.socket

[Service]
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:%h/.local/bin
ExecStart=$HERE/box-rebuild.sh
# 1800s (fleet standard — matches live-gate-watch.service). Supersedes the v1.2.30 480s cap, whose
# analysis assumed a RACE-FREE rebuild (~150s, worst-case cold pull ~450s) — but v1.2.29's 15s
# live-gate watcher races the rebuild and adds contention/hangs, so 480s clipped legit rebuilds and
# turned the race into a hard SIGTERM kill. With the watcher now stood down for the rebuild window
# (box-rebuild.sh), a rebuild runs clean well under this; the larger cap only widens the backstop for
# a genuinely stuck rebuild and gives the in-script readiness wait room to fail loudly first.
TimeoutStartSec=1800
EOF

cat > "$HOME/.config/systemd/user/claudebox-rebuild.service" <<'EOF'
[Unit]
Description=Handle an in-box claudebox rebuild request (consume flag, launch detached rebuild)

[Service]
Type=oneshot
# Consume the flag FIRST so the .path re-arms and cannot loop, THEN fire the detached rebuild.
ExecStartPre=/usr/bin/rm -f %h/.local/state/claudebox/rebuild.request
ExecStart=/usr/bin/systemctl --user start --no-block claudebox-rebuild-run.service
EOF

cat > "$HOME/.config/systemd/user/claudebox-rebuild.path" <<'EOF'
[Unit]
Description=Watch for an in-box claudebox rebuild request

[Path]
PathExists=%h/.local/state/claudebox/rebuild.request

[Install]
WantedBy=paths.target
EOF

# Method 1 — DAILY refresh (so the box never drifts even if you never ask). The timer's service does
# NOT rebuild directly: claudebox-daily.sh rebuilds now if idle, else drops rebuild.pending and the
# `claude` wrapper does it the moment you next exit. Either way a live session is never interrupted.
# (Methods 2/3 are the on-demand triggers: #2 ask-Claude via the .path flag, #3 host claudebox-rebuild.)
cat > "$HOME/.config/systemd/user/claudebox-rebuild-daily.service" <<EOF
[Unit]
Description=Daily claudebox refresh (rebuild if idle, else defer to session exit)

[Service]
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:%h/.local/bin
ExecStart=$HERE/claudebox-daily.sh
EOF

cat > "$HOME/.config/systemd/user/claudebox-rebuild-daily.timer" <<'EOF'
[Unit]
Description=Daily claudebox refresh

[Timer]
OnCalendar=*-*-* 04:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now claudebox-rebuild.path claudebox-rebuild-daily.timer

PHASE "user 4/5 workload-container refresh (Quadlets + claudebox-lock deferral)"

# THE FLEET. Each entry is a claudebox-pattern workload container honoring:
#   - GHCR-published at ghcr.io/oso-gato/<name>:latest
#   - Repo at github.com/oso-gato/<name> with executable run.sh AND a
#     <name>.container Quadlet at the repo top
#   - In-container claudebox at the standard lock paths
#     (/home/core/.local/state/claudebox/{session,box-rebuild}.lock)
#   - Operator user `core` (uid 1000)
WORKLOAD_CONTAINERS=(
    fedora-dev
    # fedora-desktop  # uncomment when onboarded (the desktop workload — xrdp + grd lineages)
)

# ---- generic helpers (one source of truth for the fleet) ----
install -m 0755 "$HERE/container-refresh.sh"    "$HOME/.local/bin/container-refresh.sh"
install -m 0755 "$HERE/claudebox-busy-probe.sh" "$HOME/.local/bin/claudebox-busy-probe.sh"
# Pre-merge live-gate pair (Gate B + its build step): build-candidate.sh builds a PR candidate
# DISPOSABLY on the host (v1.2.25 carve-out: localhost/disposable/*, never pushed, --rm/rmi'd) and
# hands it to validate-candidate.sh, which live-runs + access-probes it. validate-candidate.sh was
# previously uninstalled (an orphan with no caller); install both so the live-gate harness can call them.
install -m 0755 "$HERE/validate-candidate.sh"   "$HOME/.local/bin/validate-candidate.sh"
install -m 0755 "$HERE/build-candidate.sh"      "$HOME/.local/bin/build-candidate.sh"
# Throwaway-churn reaper: build-candidate.sh persists a dnf RPM bind cache + the podman layer cache
# across candidate builds; throwaway-sweep.sh reaps the orphans a `kill -9`/crash leaves (the EXIT
# traps miss) and caps both persistent caches so churn can't exhaust the VPS quota. Invoked at
# live-gate-watch.sh start (self-throttled); may also be wired to a periodic timer/cron.
install -m 0755 "$HERE/throwaway-sweep.sh"      "$HOME/.local/bin/throwaway-sweep.sh"
# Pre-merge live-gate loop transport (Model C, dynamic): live-gate-watch.sh discovers ALL open
# `live-validate`-labelled PRs ORG-WIDE in one query (no workload list), dedups per-(repo,commit);
# live-gate-run.sh gates ONE PR — fetches the PR head into an ephemeral tree ON DEMAND (no
# pre-placed clone), builds + gates EVERY declared target, comments the verdict back. The host
# comments, NEVER merges. Not gated on any dev session.
install -m 0755 "$HERE/live-gate-run.sh"        "$HOME/.local/bin/live-gate-run.sh"
install -m 0755 "$HERE/live-gate-watch.sh"      "$HOME/.local/bin/live-gate-watch.sh"
# Per-repo live-gate contracts (new multi-target schema) — HOST FALLBACK; a candidate may ship its
# own top-level `.live-gate` to override (preferred — it travels in the PR). Read by live-gate-run.sh.
mkdir -p "$HOME/.config/live-gate"
install -m 0644 "$HERE/live-gate-presets/"*.env "$HOME/.config/live-gate/" 2>/dev/null || true

# ---- systemd template units (refresh trigger + retry) ----
install -m 0644 "$HERE/systemd-units/workload-refresh@.service"        "$HOME/.config/systemd/user/"
install -m 0644 "$HERE/systemd-units/workload-refresh@.timer"          "$HOME/.config/systemd/user/"
install -m 0644 "$HERE/systemd-units/workload-refresh-retry@.service"  "$HOME/.config/systemd/user/"
install -m 0644 "$HERE/systemd-units/workload-refresh-retry@.timer"    "$HOME/.config/systemd/user/"
# claudebox OWNER (incident 2026-07-11): starts the box so its conmon lands in an INDEPENDENT scope,
# not in a watcher-tick's oneshot cgroup (which the tick's teardown/timeout would SIGTERM, killing the
# box — 41 deaths in one afternoon). Both watchers Wants= it, so every tick first ensures the box is up
# and revives it if it died. Enabled + started below, BEFORE the watcher timers.
install -m 0644 "$HERE/systemd-units/claudebox-up.service"             "$HOME/.config/systemd/user/"
# Live-gate watcher (poll `live-validate` PRs + build/gate/verdict them on the host)
install -m 0644 "$HERE/systemd-units/live-gate-watch.service"          "$HOME/.config/systemd/user/"
install -m 0644 "$HERE/systemd-units/live-gate-watch.timer"            "$HOME/.config/systemd/user/"
# Host agent (consume `host-task` GitHub-issue tickets → perform host ops → post outcomes) — the host
# half of the autonomous apparatus (fedora-dev#131 R5); the dev box instructs the host through this.
install -m 0755 "$HERE/host-agent-watch.sh"                            "$HOME/.local/bin/host-agent-watch.sh"
install -m 0644 "$HERE/systemd-units/host-agent-watch.service"         "$HOME/.config/systemd/user/"
install -m 0644 "$HERE/systemd-units/host-agent-watch.timer"           "$HOME/.config/systemd/user/"

# ---- HOST standing GitHub App credential (the live-gate's OWN identity) ----
# The HOST runs `gh` itself — live-gate-watch discovers PRs and POSTS the GREEN/RED verdicts —
# so it needs a standing identity exactly like the dev box, and a DISTINCT one: the deterministic
# auto-merge (fedora-dev bin/auto-merge.sh) only trusts a verdict whose author DIFFERS from the PR
# author, so host and dev box MUST NOT share an App. Same paste->podman-secret model as the
# workloads (helpers mirrored VERBATIM from fedora-dev, the canonical copy); the PEM's only at-rest
# home is the rootless podman secret store; a <=1h installation token is minted + rewired hourly
# by host-gh-refresh.timer. Declining (or a scripted run) => the host falls back to whatever
# `gh auth login` the operator did — the WARN says so and how to provision later.
install -m 0755 "$HERE/gh-app-auth.sh"       "$HOME/.local/bin/gh-app-auth.sh"
install -m 0755 "$HERE/host-gh-refresh.sh"   "$HOME/.local/bin/host-gh-refresh.sh"
install -m 0644 "$HERE/systemd-units/host-gh-refresh.service" "$HOME/.config/systemd/user/"
install -m 0644 "$HERE/systemd-units/host-gh-refresh.timer"   "$HOME/.config/systemd/user/"
if podman secret exists gh_app_host_key 2>/dev/null && [ -r "$HOME/.config/gh-app-host.env" ]; then
    echo "[host-gh] standing HOST App credential already provisioned (secret gh_app_host_key) — keeping it."
else
    . "$HERE/gh-app-provision.sh"
    GHA_TTY="${SPINUP_TTY:-/dev/tty}"; GHA_IN="$GHA_TTY"
    _hg_ans=y
    if { : <"$GHA_IN"; } 2>/dev/null; then
        {
            printf '── GitHub App credential for THE HOST '\''%s'\'' (fedora-bootstrap) ─────────────────\n' "$(hostname -s)"
            printf '   This is the HOST'\''s live-gate identity (the '\''host-gate'\'' App — posts the GREEN/RED\n'
            printf '   verdicts; Contents read-only). NOT the dev box'\''s App: that one is asked separately,\n'
            printf '   in the fedora-dev spin-up section — the two MUST be DIFFERENT Apps.\n'
            printf '>> Provision the HOST (%s) App credential now (paste the key)? — DEFAULT y (y/n) [y]: ' "$(hostname -s)"
        } >"$GHA_TTY"
        IFS= read -r _hg_ans <"$GHA_IN" || _hg_ans=""; _hg_ans="${_hg_ans:-y}"
    else
        echo "[host-gh] no terminal — cannot paste the HOST App key in this run." >&2
        _hg_ans=n
    fi
    if [ "$_hg_ans" = y ]; then
        GH_APP_HOST_ID=""; GH_APP_HOST_INST=""
        prompt_github_app gh_app_host_key GH_APP_HOST_ID GH_APP_HOST_INST \
            || { echo "FATAL: HOST GitHub App provisioning failed" >&2; exit 1; }
        _um="$(umask)"; umask 077
        printf 'GH_APP_ID=%s\nGH_APP_INSTALLATION_ID=%s\n' "$GH_APP_HOST_ID" "$GH_APP_HOST_INST" \
            > "$HOME/.config/gh-app-host.env"   # PUBLIC integers only; the PEM stays in the secret
        umask "$_um"
        "$HOME/.local/bin/host-gh-refresh.sh" \
            || { echo "FATAL: initial HOST token mint failed (bad App id/key?)" >&2; exit 1; }
        echo "[host-gh] HOST App credential provisioned + first token minted (App $GH_APP_HOST_ID)."
        echo "[host-gh] NOTE: this user's github.com identity (gh hosts.yml + git store helper) is"
        echo "          now the App token and is REWRITTEN hourly — a manual 'gh auth login' on the"
        echo "          host will be overwritten; the host acts as the App by design."
    else
        echo "[host-gh] NO standing HOST App credential — the live-gate's gh calls rely on a manual" >&2
        echo "          'gh auth login' until you provision one: re-run setup, or as $USER run:" >&2
        echo "          . $HERE/gh-app-provision.sh && prompt_github_app gh_app_host_key GH_APP_HOST_ID GH_APP_HOST_INST" >&2
        echo "          then write ~/.config/gh-app-host.env and run host-gh-refresh.sh" >&2
    fi
fi
systemctl --user enable --now host-gh-refresh.timer

# ---- image signature verification scaffolding ----
# Default policy: reject everything; then trust THREE repos unconditionally
# (insecureAcceptAnything): ghcr.io/oso-gato/* (the production workloads that
# actually RUN); registry.fedoraproject.org/fedora (the class-(a) Fedora BASE
# the validation/ host-validation spikes+gates pull as disposable test fixtures —
# never a run-set image); and quay.io/fedora/fedora-toolbox (the claudebox base
# pinned in distrobox.ini — distrobox RE-PULLS it on every `claudebox-rebuild`, so
# without this scope the rebuild fails `Source image ... is rejected by policy` the
# moment the cached toolbox layer is gone. The first day-zero assemble happens to
# run BEFORE this file exists, which is exactly why only SUBSEQUENT rebuilds broke).
# Plus containers-storage (local save/load, for the throwaway tar cache the
# fixtures are cached in). See the merge block below.
#
# DO NOT add JSON "comment" keys (e.g. "//") inside policy.json: podman's
# containers/image policy parser is strict and REJECTS unknown keys, which makes
# EVERY image pull fail with `invalid policy ... Unknown key "//"` (exit 125).
# Upgrade guidance lives here, in shell comments, NOT in the emitted JSON.
#
# ENFORCEMENT IS DELIBERATELY DEFERRED (a researched decision, NOT a TODO):
# our CI cosign-signs KEYLESS (GitHub Actions OIDC), so the signer identity is a
# URI SAN (the workflow ref), NOT an email. podman's native containers-policy.json
# `sigstoreSigned`/`fulcio` matches ONLY `subjectEmail` — there is NO URI /
# workflow-identity / regexp field, and caData + rekorPublicKeyData are mandatory
# with no system trust root (verified vs containers-policy.json(5)). So a keyless
# stanza CANNOT match these signatures — a `subjectEmail` keyless config would
# silently fail to gate. Enforcing keyless would need EITHER a cosign-verify
# pre-pull gate (cosign on the host — a footprint addition that fights Principle 2:
# cosign is neither class-(a) Fedora nor a permitted loose binary) OR switching CI
# to STATIC-key signing (the keyPath form below — a managed private key, which
# keyless was chosen to avoid). For a SINGLE-OPERATOR, own-CI, own-GHCR, TLS-pulled
# fleet the threat (a stolen GHCR push token) does not justify either cost: the
# signature stays a useful AUDIT TRAIL and the run-trust gate is
# insecureAcceptAnything BY DESIGN. Re-open ONLY on (a) multiple operators / an
# untrusted publisher, or (b) podman gaining keyless URI-identity matching.
#   keyPath form (the ONLY natively-enforceable option — adopt only if a future
#   decision switches CI to static-key signing):
#     { "type": "sigstoreSigned", "keyPath": "/etc/containers/cosign-pub-keys/oso-gato.pub" }
install -d -m 0755 "$HOME/.config/containers"
install -d -m 0755 "$HOME/.config/containers/registries.d"
if [ ! -e "$HOME/.config/containers/policy.json" ]; then
    cat > "$HOME/.config/containers/policy.json" <<'EOF'
{
    "default": [{ "type": "reject" }],
    "transports": {
        "docker": {
            "ghcr.io/oso-gato": [{ "type": "insecureAcceptAnything" }],
            "registry.fedoraproject.org/fedora": [{ "type": "insecureAcceptAnything" }],
            "quay.io/fedora/fedora-toolbox": [{ "type": "insecureAcceptAnything" }],
            "": [{ "type": "reject" }]
        },
        "containers-storage": { "": [{ "type": "insecureAcceptAnything" }] }
    }
}
EOF
fi
# Idempotently ensure the validation-fixture entries on an EXISTING host too (the create-if-
# absent above won't touch a file that already exists, to preserve operator edits). Adds ONLY:
# pulling the class-(a) Fedora BASE the validation/ spikes+gates use, and copying LOCAL images
# (podman save -> the throwaway tar cache). Production still only RUNS oso-gato workloads (the
# Quadlets reference only oso-gato images) — this widens what may be PULLED for disposable
# host-validation, not what runs. Structural JSON merge (no comment keys; the parser rejects them).
python3 - "$HOME/.config/containers/policy.json" <<'PY'
import json, sys
p = sys.argv[1]
pol = json.load(open(p))
t = pol.setdefault("transports", {})
d = t.setdefault("docker", {})
changed = False
if "registry.fedoraproject.org/fedora" not in d:
    d["registry.fedoraproject.org/fedora"] = [{"type": "insecureAcceptAnything"}]; changed = True
if "quay.io/fedora/fedora-toolbox" not in d:
    # the claudebox base pinned in distrobox.ini; distrobox re-pulls it on every
    # `claudebox-rebuild`, so a default-reject policy that lacks this scope breaks
    # EVERY rebuild after the first (the first day-zero assemble runs before this
    # file exists). REPAIRS an already-deployed host in place on the next setup.sh.
    d["quay.io/fedora/fedora-toolbox"] = [{"type": "insecureAcceptAnything"}]; changed = True
cs = t.get("containers-storage")
if cs is None:
    t["containers-storage"] = {"": [{"type": "insecureAcceptAnything"}]}; changed = True
elif isinstance(cs, list):
    # REPAIR a pre-v1.2.21 host: containers-image requires each transport to map
    # scope -> requirements (an OBJECT), not a bare requirements ARRAY. The array form
    # made podman reject the WHOLE policy ("JSON object expected, got 91"), so every
    # ghcr.io/oso-gato pull failed and no workload could start.
    t["containers-storage"] = {"": cs}; changed = True
# Fail-closed structural check: every transport value MUST be a scope->requirements object.
for _n, _v in t.items():
    if not isinstance(_v, dict):
        sys.exit(f"[policy] FATAL: transport {_n!r} must be a scope->requirements object, got {type(_v).__name__}")
if changed:
    with open(p, "w") as f:
        json.dump(pol, f, indent=4); f.write("\n")
    print("[policy] validation-fixture entries ensured (containers-storage normalized to object)")
else:
    print("[policy] validation-fixture entries already present and well-formed")
PY
if [ ! -e "$HOME/.config/containers/registries.d/ghcr-io.yaml" ]; then
    cat > "$HOME/.config/containers/registries.d/ghcr-io.yaml" <<'EOF'
docker:
    ghcr.io:
        use-sigstore-attachments: true
EOF
fi

systemctl --user daemon-reload

# ---- per-container provisioning ----
for _c in "${WORKLOAD_CONTAINERS[@]}"; do
    # (a) Clone the container's repo (idempotent). NO `|| true` on the pull
    # so any genuine pull failure surfaces (security: silent fast-forward
    # refusal could hide a force-push attack).
    if [ ! -d "$HOME/$_c/.git" ]; then
        git clone "https://github.com/oso-gato/$_c" "$HOME/$_c"
    else
        # ~/<name> is a SETUP-MANAGED clone for the workload-refresh/Quadlet DEPLOY path (the
        # live-gate no longer uses it — Model C clones each PR head on demand into a temp tree).
        # Discard any stray working-tree changes
        # so the update never aborts on a dirty file (maintainer edits belong in a SEPARATE clone),
        # but KEEP `--ff-only` so a non-fast-forward — a force-push to `main` — still SURFACES rather
        # than being silently accepted (a blind `reset --hard origin/main` would hide that attack).
        (cd "$HOME/$_c" \
            && git fetch origin main \
            && git reset --hard HEAD \
            && git clean -fd \
            && git merge --ff-only origin/main)
    fi

    # (a2) DELEGATE to the workload's OWN spin-up.sh to ASK that container's setup questions
    # and create its podman secrets (as THIS rootless user), WITHOUT launching — so day0 never
    # duplicates a container's questions; each spin-up.sh is the single source of truth for what
    # its container asks (a new workload type ships its own spin-up.sh and is asked automatically).
    # The wizard reads /dev/tty (preserved through the `su` into this user) and emits its resolved
    # env as one `export …` line, captured here WITHOUT clobbering the host's own TS_AUTHKEY.
    # FAIL-LOUD (was a silent `if -x` skip): a workload whose spin-up.sh is missing or
    # non-executable would previously be provisioned with NO questions and NO error — the
    # operator only discovers the missing App credential when the loop stalls on auth. The
    # wizard is part of the fleet contract exactly like the Quadlet below, so enforce it the
    # same way. Announce the delegation so the questions are attributable in the day0 scroll.
    GH_APP_ID=""; GH_APP_INSTALLATION_ID=""; GH_APP_SECRET=""; BOX_HOSTNAME=""
    if [ ! -x "$HOME/$_c/spin-up.sh" ]; then
        echo "FATAL: $HOME/$_c/spin-up.sh missing or not executable — workload contract violation" >&2
        echo "  (every workload repo must ship an executable spin-up.sh; its questions were NOT asked," >&2
        echo "   so its secrets/credentials were NOT provisioned — refusing to continue silently)" >&2
        exit 1
    fi
    echo ">> ${_c}: asking its setup questions (delegated to its own spin-up.sh) ..."
    _collected="$(cd "$HOME/$_c" && COLLECT_ONLY=1 ./spin-up.sh)" \
        || { echo "FATAL: $_c spin-up.sh collect failed" >&2; exit 1; }
    # The eval sets the WORKLOAD's answers (incl. ITS TS_AUTHKEY); the host's own TS_AUTHKEY
    # is saved/restored around it — but the workload's key must be CAPTURED first, or it is
    # silently DROPPED (verified live: the operator pasted nox's key and the box still fell
    # back to web-login — the Quadlet path had no channel for it at all). (b4) ferries it.
    _save_ts="${TS_AUTHKEY:-}"; eval "$_collected"
    _wl_ts="${TS_AUTHKEY:-}"; TS_AUTHKEY="$_save_ts"
    if [ -z "${GH_APP_SECRET:-}" ]; then
        echo "  -> ${_c}: NO standing GitHub App credential provisioned (declined or skipped)." >&2
        echo "     The autonomous loop will stall on auth until one exists: run" >&2
        echo "     'cd ~/${_c} && ./spin-up.sh' later, or re-run setup." >&2
    fi

    # (b) Install the container's Quadlet into systemd's user search path.
    # Enforces the fleet contract: every workload repo MUST ship <name>.container.
    if [ ! -f "$HOME/$_c/$_c.container" ]; then
        echo "FATAL: $HOME/$_c/$_c.container missing — workload contract violation" >&2
        echo "  (every workload container repo must ship a podman Quadlet at the top)" >&2
        exit 1
    fi
    install -d -m 0755 "$HOME/.config/containers/systemd"
    install -m 0644 "$HOME/$_c/$_c.container" "$HOME/.config/containers/systemd/"

    # (b2) Activate the standing GitHub App credential in the INSTALLED Quadlet from the answers
    # collected above: uncomment the `# Secret=`/`# Environment=` lines + fill the PUBLIC ids.
    # Idempotent; a no-op when no App was provisioned. The PEM lives ONLY in the podman secret the
    # wizard created — never in this file, never in the repo. (The daemon-reload after the loop
    # picks up the change.)
    if [ -n "${GH_APP_ID:-}" ] && [ -n "${GH_APP_SECRET:-}" ]; then
        _q="$HOME/.config/containers/systemd/$_c.container"
        sed -i \
          -e "s|^# *Secret=gh_app_key,type=mount,target=gh_app_key.*|Secret=${GH_APP_SECRET},type=mount,target=gh_app_key|" \
          -e "s|^# *Environment=GH_APP_ID=.*|Environment=GH_APP_ID=${GH_APP_ID} GH_APP_INSTALLATION_ID=${GH_APP_INSTALLATION_ID}|" \
          "$_q"
        echo "  -> ${_c}: standing GitHub App credential wired (podman secret '${GH_APP_SECRET}', App ${GH_APP_ID})."
    fi

    # (b3) Stamp the wizard-collected pairing hostname into the INSTALLED Quadlet, so the
    # day0/Quadlet deploy path honors it exactly like a by-hand run.sh does. The workload's
    # spin-up.sh derives it from THIS host's hostname (host phase 1/7 set it before any of
    # this user layer ran): erebus -> nox, strix -> nyx. The hostname becomes both the
    # container hostname AND the tailnet node name; the podman container NAME stays <repo>
    # (the refresh units key on it). No-op when the wizard emitted none.
    if [ -n "${BOX_HOSTNAME:-}" ]; then
        sed -i "s|^HostName=.*|HostName=${BOX_HOSTNAME}|" "$HOME/.config/containers/systemd/$_c.container"
        echo "  -> ${_c}: container/tailnet hostname stamped: ${BOX_HOSTNAME}"
    fi

    # (b4) Ferry the WORKLOAD's TS_AUTHKEY into its Quadlet deploy: the key goes into a
    # podman secret (never a file/env-file) and the shipped commented `Secret=` line is
    # activated — the entrypoint sees $TS_AUTHKEY (type=env) and joins unattended. No key
    # collected => no-op (the box's web-login fallback prints its URL in `podman logs`).
    if [ -n "${_wl_ts:-}" ]; then
        printf '%s' "$_wl_ts" | podman secret create --replace "${_c}-ts-authkey" - >/dev/null
        sed -i "s|^# *Secret=${_c}-ts-authkey,type=env,target=TS_AUTHKEY.*|Secret=${_c}-ts-authkey,type=env,target=TS_AUTHKEY|" \
            "$HOME/.config/containers/systemd/$_c.container"
        if grep -q "^Secret=${_c}-ts-authkey,type=env,target=TS_AUTHKEY" "$HOME/.config/containers/systemd/$_c.container"; then
            echo "  -> ${_c}: unattended tailnet join wired (podman secret '${_c}-ts-authkey')."
        else
            echo "  -> ${_c}: WARN — its Quadlet ships no '# Secret=${_c}-ts-authkey' line to activate;" >&2
            echo "     secret created but NOT wired; the box will use the web-login fallback" >&2
            echo "     (URL in 'podman logs ${_c}') until the workload repo adds the line." >&2
        fi
    fi
    unset _wl_ts

    # (c) Enable the refresh + retry timers. The Quadlet-generated <name>.service
    # is enabled separately by the operator (or by the per-version upgrade
    # subsection). v1.1.9: NO env-file scaffold — workload Quadlets no longer
    # carry runtime secrets (fedora-dev's CORE_PASSWORD was eliminated; sshd is
    # key-only with keys synced from github.com/<user>.keys). If a future
    # workload re-introduces a runtime secret, prefer `podman secret` + Quadlet
    # `Secret=` over env files. Stale ~/.config/container-refresh/*.env files
    # from pre-v1.1.9 hosts are harmless (unread); operators may delete.
    systemctl --user enable --now \
        "workload-refresh@${_c}.timer" \
        "workload-refresh-retry@${_c}.timer"
done

systemctl --user daemon-reload
# Enable + START the claudebox OWNER first: it holds the box's conmon in an independent scope so the
# watcher ticks below can never kill it (incident 2026-07-11). Idempotent (`podman start` no-ops a
# running box); `|| true` so a first run where the box is briefly still assembling never fails setup —
# the watchers' Wants= will bring it up on the next tick regardless.
systemctl --user enable --now claudebox-up.service || true
# Enable the live-gate watcher (polls `live-validate`-labelled PRs and builds/gates them on the host).
systemctl --user enable --now live-gate-watch.timer
# Enable the host agent (polls `host-task` tickets and performs host ops — apparatus R5).
systemctl --user enable --now host-agent-watch.timer

PHASE "user 5/5 verify"
bash "$HERE/verify.sh"
