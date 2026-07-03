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

# ==== FENCE VALIDATION — BOUNDED ALLOWLIST (the containment boundary for un-merged PR code) ========
# The resolved fence is derived (indirectly) from an UNTRUSTED, un-merged PR's `.live-gate`. A
# NON-EMPTY fence REPLACES the hard default entirely, so containment must be re-proven on EVERY
# resolved fence — not just the empty-default path (the pre-v1.2.53 bug: a hostile
# `FENCE_default='-v /:/host:rw --cap-add ALL ...'` dropped the `--network=none --cap-drop=ALL`
# default AND passed the old loop, bind-mounting the host root rw into un-merged code => host RCE).
#
# We do NOT blanket-reject the primitives first-party candidates legitimately need — fedora-dev and
# both fedora-desktop lineages use `--cap-add NET_ADMIN/SYS_ADMIN`, `--device /dev/net/tun|/dev/fuse`,
# `--security-opt label=disable`, and grd additionally `--cgroupns=host -v /sys/fs/cgroup:...:rw`
# `--systemd=always` `--shm-size=1g`. Instead each DANGEROUS flag is validated against a bounded
# allowlist; anything outside it is RED. Two floors are ALWAYS imposed at launch regardless of fence:
# `--cap-drop=ALL` (so a `--cap-add X` can only add back NAMED caps, never start from a full set) and
# `--network=none` when the fence declares no network (closes egress for un-merged code; `none` keeps
# `lo` up so the loopback probes still work). See validation/fence-guard.test.sh for the full matrix.
fence_reject(){ echo "  fence REJECTED: $1"; echo "VERDICT: RED (fence: $2)"; exit 1; }
# device sources a validation fence may pass (rootless podman already restricts to the caller's own
# device perms; this bounds it further to the known-needed virtual devices — never a host block dev).
_dev_ok(){ case "$1" in /dev/net/tun|/dev/fuse|/dev/kvm|/dev/dri|/dev/dri/*) return 0;; *) return 1;; esac; }
# bind-mount SOURCES a validation fence may expose: ONLY the cgroup pseudo-fs (systemd-PID-1 lineages
# need it), NEVER a real-data path. This arm is what blocks `-v /:/host:rw`, `-v /etc:...`, etc.
_vol_src_ok(){ case "$1" in /sys/fs/cgroup|/sys/fs/cgroup/*) return 0;; *) return 1;; esac; }

read -r -a _ftok <<< "$CAND_FENCE"
_seen_net=0; _i=0; _n=${#_ftok[@]}
while [ "$_i" -lt "$_n" ]; do
  _t="${_ftok[$_i]}"; _next="${_ftok[$((_i+1))]:-}"
  _inlineval="${_t#*=}"; [ "$_inlineval" = "$_t" ] && _inlineval=""   # =-suffix value, if the token carried one
  case "$_t" in
    -p*|--publish|--publish=*|--publish-all|--publish-all=*|-P)
      fence_reject "publish flag '$_t' (gate is loopback-only by construction; no port may be published)" "publishes a port";;
    --privileged|--privileged=true)
      fence_reject "'$_t' grants blanket privilege" "privileged";;
    --pid=host|--ipc=host|--uts=host|--userns=host)
      fence_reject "'$_t' shares a host namespace" "host namespace";;
    --pid|--ipc|--uts|--userns)
      [ "$_next" = host ] && fence_reject "'$_t $_next' shares a host namespace" "host namespace"
      _i=$((_i+2)); continue;;
    --cap-add=ALL|--cap-add=all)
      fence_reject "'$_t' adds ALL capabilities (≈ privileged)" "cap-add ALL";;
    --cap-add)
      case "$_next" in ALL|all) fence_reject "'--cap-add $_next' adds ALL capabilities" "cap-add ALL";; esac
      _i=$((_i+2)); continue;;
    --security-opt=*|--security-opt)
      _so="$_inlineval"; [ -z "$_so" ] && { _so="$_next"; _i=$((_i+1)); }
      case "$_so" in label=disable) : ;; *) fence_reject "security-opt '$_so' (only label=disable permitted)" "security-opt";; esac;;
    --device=*|--device)
      _d="$_inlineval"; [ -z "$_d" ] && { _d="$_next"; _i=$((_i+1)); }
      _dev_ok "${_d%%:*}" || fence_reject "device '${_d%%:*}' not in the permitted set (/dev/net/tun,/dev/fuse,/dev/kvm,/dev/dri)" "device";;
    -v=*|--volume=*|-v|--volume)
      _m="$_inlineval"; [ -z "$_m" ] && { _m="$_next"; _i=$((_i+1)); }
      _vol_src_ok "${_m%%:*}" || fence_reject "bind mount source '${_m%%:*}' not permitted (only /sys/fs/cgroup)" "bind mount";;
    --mount=*|--mount)
      _m="$_inlineval"; [ -z "$_m" ] && { _m="$_next"; _i=$((_i+1)); }
      _src=""; _oldifs="$IFS"; IFS=','; for _kv in $_m; do case "$_kv" in source=*|src=*) _src="${_kv#*=}";; esac; done; IFS="$_oldifs"
      _vol_src_ok "$_src" || fence_reject "--mount source '$_src' not permitted (only /sys/fs/cgroup)" "bind mount";;
    --network=host|--network=slirp4netns|--network=pasta)
      fence_reject "'$_t' grants network access beyond loopback" "opens network";;
    --network=*)
      _seen_net=1; case "${_t#--network=}" in none|lo) ;; *) fence_reject "'--network=${_t#--network=}' is not permitted (only none or lo)" "opens network";; esac;;
    --network)
      _seen_net=1; case "$_next" in none|lo) ;; *) fence_reject "'--network $_next' is not permitted (only none or lo)" "opens network";; esac
      _i=$((_i+2)); continue;;
  esac
  _i=$((_i+1))
done

# The imposed floors (always applied at launch, prepended before $CAND_FENCE so a fence can only
# NARROW, never widen): drop-all caps, and networkless unless the fence explicitly opted into lo/none.
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
# word-splitting CAND_FENCE into podman args is intentional; FENCE_FLOOR is prepended so the imposed
# floor (--cap-drop=ALL [+ --network=none if the fence named no network]) always precedes — and a
# fence-declared --cap-add X only adds X back on top of the drop-all floor.
launch=( podman run -d --rm --name "$NAME" "${FENCE_FLOOR[@]}" $CAND_FENCE
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
