#!/usr/bin/env bash
# validate-candidate.sh — (B) the PRE-MERGE LIVE GATE.
# Run a candidate image DISPOSABLY on the host, fenced as a non-prod tenant, probe its access
# paths, return a structured PASS/FAIL the dev loop reads BEFORE a PR is merged.
#
# It MUST run on the host box — a faithful live run needs the host engine's own namespaces, which
# fedora-dev's nested engine cannot give (own-netns => ping_group_range RO; own-pidns => mount proc
# denied). See validation/LIVE-GATE-HANDOFF.md for the schema this gate consumes.
#
# Model C: this gate runs ONE target (one built image + one fence). The per-repo, per-target
# contract (CFILE/FENCE/PROBE/HEALTH/secrets/resources) is declared in the candidate's in-tree
# `.live-gate` and threaded here as env by the orchestrator (live-gate-run.sh). A multi-target /
# multi-lineage repo (e.g. fedora-desktop xrdp + grd) is handled by the orchestrator BUILDING each
# target with its own Containerfile + fence and invoking this gate once per target — so there is no
# runtime lineage-guessing here: the fence that arrives already matches the image that was built.
#
# CONTAINMENT — the load-bearing safety for running un-merged code on the host (NOT signing).
# Reduce a broken/hostile candidate's blast radius to a throwaway:
#   --rm                    disposable; torn down on exit
#   --name vcand-$$         unique throwaway name, NEVER a real workload name
#   scratch secrets only    disposable test values bind-mounted ro; never real, never baked/logged
#   --network=none / fenced no public publish, no tailnet identity, no lateral reach (default)
#   rootless + dropped caps drop everything the probe doesn't strictly need
#   --memory / --pids-limit hard caps so a runaway candidate can't starve the host
set -uo pipefail

# FENCE_CHECK_ONLY=1 runs ONLY the fence validator (below) against $CAND_FENCE and exits — no image
# needed, no podman touched. This is what validation/fence-guard.test.sh drives to prove the
# allowlist without a live engine, so IMG is optional in that mode.
IMG="${1:-}"; [ -n "${FENCE_CHECK_ONLY:-}" ] || IMG="${1:?usage: validate-candidate.sh <candidate-image-ref> [health-cmd]}"
HEALTH="${2:-${HEALTH:-}}"      # arg overrides; else $HEALTH from env; else the image's own HEALTHCHECK
NAME="vcand-$$"
OUT="$(mktemp -d)"; pass=1
g(){ printf '  %-26s %s\n' "$1" "$2"; [ "$2" = PASS ] || pass=0; }
trap 'podman rm -f -t 0 "$NAME" >/dev/null 2>&1; rm -rf "$OUT"' EXIT
# Also tear down on INT/TERM/HUP (systemd stopping the timer sends SIGTERM): bash runs the EXIT trap
# on `exit`, so a plain `exit N` here fires the cleanup above instead of leaking the vcand container
# + $OUT until the age-gated sweeper. Matches build-throwaway.sh's INT/TERM/HUP handling.
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP

echo "== launch candidate DISPOSABLY + FENCED =="
# CAND_FENCE = this target's run-contract fence, MINUS the public publish (-p) and MINUS real
# secrets. DEFAULT = the HARDEST fence: --network=none --cap-drop=ALL. The probe runs on the
# candidate's OWN loopback via `podman exec`, so a loopback-only workload needs NO egress — keep it
# networkless by default. A target that genuinely needs devices/systemd OPTS IN explicitly
# via its `.live-gate` fence (FENCE_<target>), never silently.
CAND_FENCE="${CAND_FENCE:---network=none --cap-drop=ALL}"

# ==== FENCE VALIDATION — DEFAULT-DENY ALLOWLIST (the containment boundary for un-merged PR code) ====
# The resolved fence is derived (indirectly) from an UNTRUSTED, un-merged PR's `.live-gate`. A
# NON-EMPTY fence REPLACES the hard default entirely, so containment must be re-proven on EVERY
# resolved fence — not just the empty-default path.
#
# DESIGN = DEFAULT-DENY, not deny-listing. Every token MUST match an explicit ALLOW arm below (the
# small set of run-contract flags the real first-party fences use); ANY unrecognized token is RED.
# This is the only posture that is safe against an attacker's creativity — a deny-list of "bad flags"
# always loses to the flag/spelling you forgot (an earlier bounded-allowlist attempt was bypassed
# FOUR ways: `-v/:/host` shorthand concat, `/sys/fs/cgroup/../../` traversal, the `--net` alias, and
# a newline-split parser divergence — all now closed here). The allowed set is exactly:
#   --network/--net = none|lo · --cap-drop=* · --cap-add <named, never ALL> · --security-opt label=disable
#   --device <in /dev/{net/tun,fuse,kvm,dri}, no `..`> · -v/--volume/--mount <source under /sys/fs/cgroup,
#   no `..`> · --cgroupns host|private · --systemd[=always|true|false] · --shm-size <size>
# covering fedora-dev + both fedora-desktop lineages (incl. grd's systemd-PID-1 cgroup mount). Anything
# a future first-party fence needs is a DELIBERATE allowlist addition here (a control-plane change),
# never a silent pass. Two floors are always imposed at launch: --cap-drop=ALL (a --cap-add only adds
# back NAMED caps) and --network=none when the fence named no network (closes egress; `none` keeps `lo`
# up so loopback probes pass). CRUCIAL: the SAME validated token array is handed to podman at launch
# (`"${_ftok[@]}"`), never a re-split of the raw string — so the validator and podman can never disagree
# on tokenization. See validation/fence-guard.test.sh for the full ALLOW/REJECT matrix.
fence_reject(){ echo "  fence REJECTED: $1"; echo "VERDICT: RED (fence: $2)"; exit 1; }
# device sources a validation fence may pass — known-needed virtual devices only, and NO `..` (podman
# canonicalizes `..`, so `/dev/dri/../../dev/sda` must be rejected as a string BEFORE it reaches podman).
_dev_ok(){ case "$1" in *..*|'') return 1;; /dev/net/tun|/dev/fuse|/dev/kvm|/dev/dri|/dev/dri/*) return 0;; *) return 1;; esac; }
# bind-mount SOURCES a fence may expose: ONLY the cgroup pseudo-fs (systemd-PID-1 lineages need it),
# NEVER a real-data path and NEVER with `..` (blocks `-v /:/host`, `-v /etc:…`, `/sys/fs/cgroup/../../`).
_vol_src_ok(){ case "$1" in *..*|'') return 1;; /sys/fs/cgroup|/sys/fs/cgroup/*) return 0;; *) return 1;; esac; }
# _capall: true if a --cap-add value grants the FULL set. podman matches the ALL sentinel case-
# insensitively AND (historically) comma-splits the value, so uppercase then test bare-ALL or any
# comma element == ALL. Returns 0 (true => reject) if ALL is present in any spelling/position.
_capall(){ local u; u="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; case ",$u," in *,ALL,*) return 0;; esac; return 1; }

# A newline in the fence would let a validator that reads line-by-line disagree with podman's launch
# split — reject outright (a fence is one line of flags). Closes the newline-divergence bypass.
case "$CAND_FENCE" in *$'\n'*|*$'\r'*) fence_reject "fence contains a newline/CR (one line of flags only)" "newline";; esac

read -r -a _ftok <<< "$CAND_FENCE"
_seen_net=0; _i=0; _n=${#_ftok[@]}
while [ "$_i" -lt "$_n" ]; do
  _t="${_ftok[$_i]}"; _next="${_ftok[$((_i+1))]:-}"; _adv=1
  case "$_t" in
    # ---- network: only none|lo (both =form and space form; --net is podman's alias for --network) ----
    --network=*|--net=*)
      _seen_net=1; case "${_t#*=}" in none|lo) ;; *) fence_reject "'$_t' opens network (only none/lo)" "opens network";; esac;;
    --network|--net)
      _seen_net=1; case "$_next" in none|lo) _adv=2;; *) fence_reject "'$_t $_next' opens network (only none/lo)" "opens network";; esac;;
    # ---- cap-drop: dropping capabilities is always safe ----
    --cap-drop=*) : ;;
    --cap-drop) case "$_next" in -*|'') fence_reject "malformed --cap-drop" "cap-drop";; *) _adv=2;; esac;;
    # ---- cap-add: a NAMED capability only, NEVER ALL. podman compares the ALL sentinel CASE-
    # INSENSITIVELY (containers/common EqualFold) and may comma-split the value, so we must too:
    # uppercase, then reject bare ALL or any comma-list element that is ALL. _capall() does both. ----
    --cap-add=*) _capall "${_t#*=}" && fence_reject "'$_t' adds ALL capabilities (case/comma-normalized)" "cap-add"; [ -n "${_t#--cap-add=}" ] || fence_reject "empty --cap-add" "cap-add";;
    --cap-add) case "$_next" in -*|'') fence_reject "malformed --cap-add" "cap-add";; *) _capall "$_next" && fence_reject "--cap-add ALL (≈ privileged; case/comma-normalized)" "cap-add"; _adv=2;; esac;;
    # ---- security-opt: exactly label=disable (blocks seccomp=unconfined, apparmor=unconfined, …) ----
    --security-opt=*) case "${_t#*=}" in label=disable) ;; *) fence_reject "security-opt '${_t#*=}' (only label=disable)" "security-opt";; esac;;
    --security-opt) case "$_next" in label=disable) _adv=2;; *) fence_reject "security-opt '$_next' (only label=disable)" "security-opt";; esac;;
    # ---- device: allowlisted virtual device source, no `..` ----
    --device=*) _d="${_t#*=}"; _dev_ok "${_d%%:*}" || fence_reject "device '${_d%%:*}' not permitted (/dev/net/tun,/dev/fuse,/dev/kvm,/dev/dri)" "device";;
    --device) case "$_next" in -*|'') fence_reject "malformed --device" "device";; *) _dev_ok "${_next%%:*}" || fence_reject "device '${_next%%:*}' not permitted" "device"; _adv=2;; esac;;
    # ---- bind mounts: source under /sys/fs/cgroup only. THREE spellings incl. -vSRC shorthand concat ----
    -v=*|--volume=*) _m="${_t#*=}"; _vol_src_ok "${_m%%:*}" || fence_reject "bind source '${_m%%:*}' not permitted (only /sys/fs/cgroup)" "bind mount";;
    -v|--volume) case "$_next" in -*|'') fence_reject "malformed volume" "bind mount";; *) _vol_src_ok "${_next%%:*}" || fence_reject "bind source '${_next%%:*}' not permitted (only /sys/fs/cgroup)" "bind mount"; _adv=2;; esac;;
    -v?*) _m="${_t#-v}"; _vol_src_ok "${_m%%:*}" || fence_reject "bind source '${_m%%:*}' not permitted (only /sys/fs/cgroup) [shorthand]" "bind mount";;
    --mount=*|--mount)
      _m="${_t#*=}"; [ "$_m" = "$_t" ] && { case "$_next" in -*|'') fence_reject "malformed --mount" "bind mount";; esac; _m="$_next"; _adv=2; }
      _src=""; _oldifs="$IFS"; IFS=','; for _kv in $_m; do case "$_kv" in source=*|src=*) _src="${_kv#*=}";; esac; done; IFS="$_oldifs"
      _vol_src_ok "$_src" || fence_reject "--mount source '$_src' not permitted (only /sys/fs/cgroup)" "bind mount";;
    # ---- cgroup namespace: grd's systemd-PID-1 lineage needs host; private is fine ----
    --cgroupns=*) case "${_t#*=}" in host|private) ;; *) fence_reject "cgroupns '${_t#*=}' not permitted (host|private)" "cgroupns";; esac;;
    --cgroupns) case "$_next" in host|private) _adv=2;; *) fence_reject "cgroupns '$_next' not permitted (host|private)" "cgroupns";; esac;;
    # ---- systemd + shm-size: harmless run-contract knobs the desktop lineages carry ----
    --systemd=*) : ;;
    --systemd) case "$_next" in always|true|false) _adv=2;; esac;;
    --shm-size=*) : ;;
    --shm-size) case "$_next" in -*|'') fence_reject "malformed --shm-size" "shm-size";; *) _adv=2;; esac;;
    # ---- DEFAULT DENY: anything not explicitly allowed above is rejected (privileged, publish, -p,
    #      host namespaces, --dns, --add-host, -e/--env-file, --uidmap, --hooks-dir, --rootfs, …) ----
    *) fence_reject "unrecognized/disallowed fence token '$_t' — the fence is DEFAULT-DENY (only the explicit run-contract allowlist is permitted; a new first-party need is a deliberate allowlist addition)" "default-deny";;
  esac
  _i=$((_i+_adv))
done

# The imposed floors (always applied at launch, prepended before the validated tokens so a fence can
# only NARROW, never widen): drop-all caps, and networkless unless the fence explicitly opted into lo/none.
FENCE_FLOOR=( --cap-drop=ALL )
[ "$_seen_net" = 1 ] || FENCE_FLOOR+=( --network=none )

# FENCE_CHECK_ONLY: the validator above is the whole point of this mode — reaching here means the
# fence PASSED. Report + exit before touching podman (used by validation/fence-guard.test.sh).
[ -n "${FENCE_CHECK_ONLY:-}" ] && { echo "VERDICT: GREEN (fence check only) — floor: ${FENCE_FLOOR[*]}"; exit 0; }

# Scratch secrets: the fenced run gets DISPOSABLE test values, NEVER the real ones and NEVER baked
# into a layer or logged. A workload whose entrypoint reads a secrets file supplies CAND_SECRET_ENV
# (KEY=VALUE lines) + the in-container CAND_SECRET_MOUNT path; the gate materializes a 0600 file +
# bind-mounts it ro (cleaned with $OUT on exit).
SECRET_MOUNT=()
if [ -n "${CAND_SECRET_ENV:-}" ] && [ -n "${CAND_SECRET_MOUNT:-}" ]; then
  printf '%s\n' "$CAND_SECRET_ENV" > "$OUT/secrets.env"; chmod 600 "$OUT/secrets.env"
  SECRET_MOUNT=( -v "$OUT/secrets.env:${CAND_SECRET_MOUNT}:ro" )
  echo "  scratch secrets -> $CAND_SECRET_MOUNT (disposable test values, never real, never baked)"
fi

# Resource caps are GATE-imposed (not run.sh contract) — overridable so a heavy target (a full
# desktop + JVM/Tomcat + MariaDB) gets the headroom a bare sshd box doesn't need.
# SECURITY-CRITICAL: pass the SAME validated token array ("${_ftok[@]}") the validator checked —
# NOT `$CAND_FENCE` re-split — so podman receives exactly the tokens that were vetted (no second
# word-split, no glob expansion, no newline divergence). FENCE_FLOOR is prepended so the imposed floor
# (--cap-drop=ALL [+ --network=none if the fence named no network]) always precedes; a fence-declared
# --cap-add X only adds X back on top of the drop-all floor.
launch=( podman run -d --rm --name "$NAME" "${FENCE_FLOOR[@]}" "${_ftok[@]}"
         "${SECRET_MOUNT[@]}"
         --memory="${CAND_MEMORY:-2g}" --pids-limit="${CAND_PIDS:-512}"
         -e DUMMY_SECRETS=1 )
[ -n "$HEALTH" ] && launch+=( --health-cmd "$HEALTH" --health-start-period="${CAND_HEALTH_START:-90s}" --health-interval=10s --health-retries=12 )
if "${launch[@]}" "$IMG" >/dev/null 2>"$OUT/launch.err"; then
  g launch PASS
else
  g launch FAIL; cat "$OUT/launch.err"; echo "VERDICT: RED (launch)"; exit 1
fi

echo "== wait for healthy =="
# Overridable budget (CAND_HEALTH_TRIES × CAND_HEALTH_SLEEP s) — a systemd-PID-1 desktop
# (GNOME/GRD + Tomcat + MariaDB first-boot) needs a longer window than a bare sshd box.
st=none
for _ in $(seq 1 "${CAND_HEALTH_TRIES:-18}"); do
  st=$(podman inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo none)
  case "$st" in healthy|unhealthy) break;; esac
  sleep "${CAND_HEALTH_SLEEP:-6}"
done
[ "$st" = healthy ] && g healthy PASS || g healthy "FAIL($st)"

echo "== access-path probe =="
# CAND_PROBE = the workload's "does it actually serve" assertion, run INSIDE the candidate via
# `podman exec` (hits the candidate's OWN loopback — nothing is published to the host). Exit 0 =
# serves. Stronger than the healthcheck's pgrep (a healthy-but-not-serving image fails here).
CAND_PROBE="${CAND_PROBE:-}"
if [ -n "$CAND_PROBE" ]; then
  if podman exec "$NAME" sh -c "$CAND_PROBE" >"$OUT/probe.out" 2>&1; then
    g probes PASS
  else
    g probes FAIL; sed 's/^/    probe: /' "$OUT/probe.out"
  fi
else
  printf '  %-26s %s\n' probes "(none supplied — health-only gate)"
fi

podman logs "$NAME" 2>&1 | tail -20
echo; echo "VERDICT: $([ $pass = 1 ] && echo GREEN || echo RED)"
exit $((1 - pass))
