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

PHASE "user 2/5 ssh keys (from github.com/${GH_KEYS_USER:-oso-gato}.keys, tagged per device)"
# Writes THIS user's own ~/.ssh/authorized_keys (user layer; no host privilege). GitHub
# is the key registry — no keys in this repo. Re-running resyncs.
bash "$HERE/sync-authorized-keys.sh"

PHASE "user 3/5 claudebox (declarative assemble from distrobox.ini) + Claude policy"
cd "$HERE" && distrobox assemble create --file distrobox.ini
echo ">> first enter builds the box (dnf install claude-code from Anthropic + init hooks) — this can take a minute"
distrobox enter claudebox -- true   # triggers distrobox-init; fails loudly HERE, not mislabeled later
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
distrobox enter claudebox -- sudo mkdir -p /etc/claude-code
distrobox enter claudebox -- sudo cp "/run/host$HERE/policy/CLAUDE.md" /etc/claude-code/CLAUDE.md
distrobox enter claudebox -- sudo cp "/run/host$HERE/policy/managed-settings.json" /etc/claude-code/managed-settings.json
# Stamp the managed PreToolUse hooks. managed-settings.json wires
# /etc/claude-code/hooks/gate-push.sh as a Bash PreToolUse hook with
# allowManagedHooksOnly:true — the hook MUST exist there or a missing PreToolUse
# hook fails OPEN, defeating the promotion gate. FAIL LOUDLY if it didn't land.
distrobox enter claudebox -- sudo mkdir -p /etc/claude-code/hooks
distrobox enter claudebox -- sudo cp -a "/run/host$HERE/policy/hooks/." /etc/claude-code/hooks/
distrobox enter claudebox -- sudo bash -c 'chmod 0755 /etc/claude-code/hooks/*.sh 2>/dev/null || true'
distrobox enter claudebox -- sudo test -x /etc/claude-code/hooks/gate-push.sh || {
    echo "FATAL: promotion-gate hook /etc/claude-code/hooks/gate-push.sh missing or not" \
         "executable after stamp — refusing to leave the genesis box without its gate." >&2
    exit 1
}
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user" "$HOME/.local/state/claudebox"

# `claude` entry wrapper. XDG_RUNTIME_DIR is pinned so `su core` works (su keeps the prior user's
# value, which would send rootless podman to /run/user/0 -> "mkdir /run/user/0/libpod: permission
# denied"); a normal SSH login already has the right value, so it is a no-op there. It holds a SHARED
# session lock (so the DAILY refresh can tell a session is live and defer), and on exit it (a) follows
# a Claude-triggered rebuild, or (b) runs a daily refresh that was deferred while you worked — your
# "quit -> it rebuilds". It also injects --settings {"ultracode":true} so every session STARTS in
# ultracode (xhigh effort + workflow-by-default); ultracode is SESSION-SCOPED and IGNORED in settings
# files, so the wrapper is the only place it can be made a default (effortLevel:xhigh lives in
# policy/managed-settings.json as the persistent floor for any non-wrapper path). Emitted via a
# QUOTED heredoc so $(id -u)/"$@"/$HOME/$state AND the literal {"ultracode":true} stay LITERAL.
cat > "$HOME/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
state="$HOME/.local/state/claudebox"; mkdir -p "$state"
# If a rebuild is already running, follow it instead of entering a half-built box.
if systemctl --user is-active --quiet claudebox-rebuild-run.service 2>/dev/null; then
    exec "$HOME/.local/bin/claudebox-rebuild" --watch-only
fi
# Hold a SHARED session lock for the session's lifetime so the daily refresh defers while you work.
flock -s "$state/session.lock" distrobox enter claudebox -- bash -lc 'exec /usr/bin/claude --settings "{\"ultracode\":true}" "$@"' bash "$@"
rc=$?
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
TimeoutStartSec=900
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

# ---- systemd template units (refresh trigger + retry) ----
install -m 0644 "$HERE/systemd-units/workload-refresh@.service"        "$HOME/.config/systemd/user/"
install -m 0644 "$HERE/systemd-units/workload-refresh@.timer"          "$HOME/.config/systemd/user/"
install -m 0644 "$HERE/systemd-units/workload-refresh-retry@.service"  "$HOME/.config/systemd/user/"
install -m 0644 "$HERE/systemd-units/workload-refresh-retry@.timer"    "$HOME/.config/systemd/user/"

# ---- image signature verification scaffolding ----
# Default policy: reject everything; then trust two repos unconditionally
# (insecureAcceptAnything): ghcr.io/oso-gato/* (the production workloads that
# actually RUN) and registry.fedoraproject.org/fedora (the class-(a) Fedora BASE
# the validation/ host-validation spikes+gates pull as disposable test fixtures —
# never a run-set image). Plus containers-storage (local save/load, for the
# throwaway tar cache the fixtures are cached in). See the merge block below.
#
# DO NOT add JSON "comment" keys (e.g. "//") inside policy.json: podman's
# containers/image policy parser is strict and REJECTS unknown keys, which makes
# EVERY image pull fail with `invalid policy ... Unknown key "//"` (exit 125).
# Upgrade guidance lives here, in shell comments, NOT in the emitted JSON.
#
# To enforce signatures once every workload CI signs via cosign + GitHub Actions
# OIDC, replace the ghcr.io/oso-gato stanza below with either:
#   keyPath: { "type": "sigstoreSigned", "keyPath": "/etc/containers/cosign-pub-keys/oso-gato.pub" }
#   keyless: { "type": "sigstoreSigned",
#              "signedIdentity": { "type": "matchRepoDigestOrExact" },
#              "fulcio": { "caData": "...",
#                          "oidcIssuer": "https://token.actions.githubusercontent.com",
#                          "subjectEmail": "..." } }
# The same sigstoreSigned tightening applies to the registry.fedoraproject.org/fedora
# base (Fedora publishes sigstore signatures) — upgrade both stanzas in lockstep so the
# fixture base is never held to a weaker bar than the production run-set.
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
        (cd "$HOME/$_c" && git pull --ff-only origin main)
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

PHASE "user 5/5 verify"
bash "$HERE/verify.sh"
