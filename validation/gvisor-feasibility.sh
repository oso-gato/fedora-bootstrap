#!/usr/bin/env bash
# gvisor-feasibility.sh — does a candidate actually BOOT under gVisor (runsc)?
#
# The 30-minute empirical test, scripted. gVisor emulates the kernel and does NOT implement every
# syscall; heavy systemd-PID-1 workloads (the grd desktop lineage) are the ones most likely to fail to
# boot under it. This tool runs a boot smoke of a built candidate image under runsc AND under the plain
# runtime, side by side, and tells you which targets can move to gVisor and which must stay on the plain
# fence (a host-allowlisted exception). Run it on the HOST (rootless, where the live-gate runs), per
# fleet image/lineage, AFTER gvisor-setup.sh.
#
# Usage:
#   gvisor-feasibility.sh <image-ref> [health-cmd] [fence...]
#     <image-ref>  an already-built candidate image (build one with build-candidate.sh, or reuse a tag)
#     [health-cmd] optional --health-cmd string (else the image's own / none)
#     [fence...]   optional extra podman run flags to mirror the target's real fence (e.g. the grd fence)
#
# Output: a PASS/FAIL for runsc and for plain, and a verdict. Shipped model: default = plain fence,
# runsc is OPT-IN per PROVEN lineage. If runsc PASSES → the exact `~/.config/live-gate/runsc.allow`
# line to OPT this lineage into gVisor. If runsc FAILS but plain PASSES → leave it on the default plain
# fence (add nothing). So gVisor is adopted only where empirically proven, one lineage at a time.
set -uo pipefail
IMG="${1:?usage: gvisor-feasibility.sh <image-ref> [health-cmd] [fence...]}"; shift
HEALTH="${1:-}"; [ $# -gt 0 ] && shift
FENCE=( "$@" )
TRIES="${GV_TRIES:-15}"; SLEEP="${GV_SLEEP:-4}"

command -v podman >/dev/null || { echo "FATAL: podman required"; exit 2; }
podman image exists "$IMG" 2>/dev/null || { echo "FATAL: image '$IMG' not found — build it first"; exit 2; }

# boot_under <runtime-label> <podman-runtime-args...> -> prints PASS/FAIL, returns 0 on PASS
boot_under(){
  local label="$1"; shift; local rt=( "$@" )
  local name="gvfeas-$label-$$" out st=none rc
  podman rm -f -t 0 "$name" >/dev/null 2>&1
  local run=( podman run -d --rm --name "$name" "${rt[@]}" --network=none --cap-drop=ALL
              --memory=2g --pids-limit=512 "${FENCE[@]}" )
  [ -n "$HEALTH" ] && run+=( --health-cmd "$HEALTH" --health-start-period=90s --health-interval=5s --health-retries=18 )
  if ! out="$("${run[@]}" "$IMG" 2>&1)"; then
    printf '  %-8s FAIL (launch rejected)\n' "$label"; echo "     $out" | sed 's/^/     /' | head -4
    podman rm -f -t 0 "$name" >/dev/null 2>&1; return 1
  fi
  # give it a moment; if it's still running (and healthy, when a health-cmd is set) => booted
  local i
  for i in $(seq 1 "$TRIES"); do
    podman ps --filter "name=^${name}$" --filter status=running -q | grep -q . || break
    if [ -n "$HEALTH" ]; then
      st="$(podman inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo none)"
      [ "$st" = healthy ] && break
      [ "$st" = unhealthy ] && break
    fi
    sleep "$SLEEP"
  done
  local up; up="$(podman ps -a --filter "name=^${name}$" --format '{{.Status}}' 2>/dev/null || echo gone)"
  podman logs "$name" 2>&1 | tail -6 | sed 's/^/     log: /'
  podman rm -f -t 0 "$name" >/dev/null 2>&1
  if { [ -z "$HEALTH" ] && printf '%s' "$up" | grep -qi 'Up'; } || { [ -n "$HEALTH" ] && [ "$st" = healthy ]; }; then
    printf '  %-8s PASS (booted%s)\n' "$label" "${HEALTH:+ + healthy}"; return 0
  fi
  printf '  %-8s FAIL (did not stay up/healthy: %s)\n' "$label" "$up"; return 1
}

echo "== gVisor feasibility: $IMG =="
[ "${#FENCE[@]}" -gt 0 ] && echo "   fence: ${FENCE[*]}"
gv=1; pl=1
if podman --runtime runsc info >/dev/null 2>&1; then
  boot_under runsc --runtime runsc && gv=0 || gv=1
else
  echo "  runsc    N/A (runtime not registered — run validation/gvisor-setup.sh first)"; gv=2
fi
boot_under plain && pl=0 || pl=1

echo
# Verdicts speak the SHIPPED model: default = plain fence; runsc is OPT-IN per PROVEN lineage via the
# host runsc.allow file (live-gate-run.sh). A CAPABLE lineage is OPTED IN by adding it to runsc.allow;
# an INCAPABLE one simply stays on the default plain fence (add NOTHING).
if [ "$gv" = 0 ]; then
  echo "VERDICT: gVisor-CAPABLE — OPT this lineage into gVisor (stronger isolation) by adding it to the"
  echo "  host runsc allowlist (default is the plain fence; runsc is opt-in per proven lineage):"
  echo "     echo '<repo>[:<target>]' >> ~/.config/live-gate/runsc.allow"
elif [ "$gv" = 2 ]; then
  echo "VERDICT: INCONCLUSIVE — install gVisor first (validation/gvisor-setup.sh), then re-run."
elif [ "$pl" = 0 ]; then
  echo "VERDICT: gVisor-INCAPABLE but plain-fence OK — leave this lineage on the DEFAULT plain fence"
  echo "  (add NOTHING to runsc.allow; the plain fence is already the default). Record WHY it can't run"
  echo "  under gVisor so a future session doesn't retry blindly."
else
  echo "VERDICT: BROKEN under both — the candidate itself does not boot; fix the candidate, not the runtime."
fi
[ "$gv" = 0 ] || [ "$pl" = 0 ]
