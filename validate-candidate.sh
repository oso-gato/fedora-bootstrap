#!/usr/bin/env bash
# validate-candidate.sh — (B) the PRE-MERGE LIVE GATE.
# Run a candidate image DISPOSABLY on the host, fenced as a non-prod tenant, probe its access
# paths, return a structured PASS/FAIL the dev loop reads BEFORE a PR is merged.
#
# DRAFT SKELETON written by fedora-dev; NOT yet run. It MUST run on the host box — a faithful
# live run needs the host engine's own namespaces, which fedora-dev's nested engine cannot give
# (own-netns => ping_group_range RO; own-pidns => mount proc denied). Iterate the LAUNCH and
# PROBE sections on a REAL candidate (e.g. a fedora-desktop:xrdp build) until they faithfully
# assert "the workload serves", then this is the gate. See validation/LIVE-GATE-HANDOFF.md.
#
# CONTAINMENT — the load-bearing safety for running un-merged code on the host (NOT signing;
# see the cosign roll-back). Reduce a broken/hostile candidate's blast radius to a throwaway:
#   --rm                    disposable; torn down on exit
#   --name vcand-$$         unique throwaway name, NEVER a real workload name
#   no secrets mounted      dummy creds only — nothing real to exfiltrate
#   --network=none / fenced no public publish, no tailnet identity, no lateral reach
#   rootless + dropped caps drop everything the probe doesn't strictly need
#   --memory / --pids-limit hard caps so a runaway candidate can't starve the host
set -uo pipefail

IMG="${1:?usage: validate-candidate.sh <candidate-image-ref> [health-cmd]}"
HEALTH="${2:-}"                 # optional override; else the image's own HEALTHCHECK
NAME="vcand-$$"
OUT="$(mktemp -d)"; pass=1
g(){ printf '  %-26s %s\n' "$1" "$2"; [ "$2" = PASS ] || pass=0; }
trap 'podman rm -f -t 0 "$NAME" >/dev/null 2>&1' EXIT

echo "== launch candidate DISPOSABLY + FENCED =="
# TODO(host box): thread the workload's real run.sh contract here, MINUS the public publish and
# MINUS the real secrets (dummy RDP_PW/GUAC_PW etc). Keep --rm + fence + caps. Probe on loopback
# inside the container's own netns via `podman exec`, so nothing is published to the host.
launch=( podman run -d --rm --name "$NAME"
         --network=none
         --memory=2g --pids-limit=512
         --cap-drop=ALL
         -e DUMMY_SECRETS=1 )
[ -n "$HEALTH" ] && launch+=( --health-cmd "$HEALTH" --health-start-period=90s --health-interval=10s --health-retries=12 )
if "${launch[@]}" "$IMG" >/dev/null 2>"$OUT/launch.err"; then
  g launch PASS
else
  g launch FAIL; cat "$OUT/launch.err"; echo "VERDICT: RED (launch)"; exit 1
fi

echo "== wait for healthy =="
st=none
for _ in $(seq 1 18); do
  st=$(podman inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo none)
  case "$st" in healthy|unhealthy) break;; esac
  sleep 6
done
[ "$st" = healthy ] && g healthy PASS || g healthy "FAIL($st)"

echo "== access-path probes =="
# TODO(host box): replace with the workload's REAL probes, run via `podman exec "$NAME" …` so
# they hit the candidate's OWN loopback (nothing published to the host). For fedora-desktop:
#   web door  : podman exec "$NAME" curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/guacamole/   == 200
#   web login : POST /guacamole/api/tokens with the dummy creds -> authToken (or TOTP challenge)
#   RDP up    : podman exec "$NAME" bash -c 'exec 3<>/dev/tcp/127.0.0.1/3389'
#   paint     : freerdp + Xvfb + a frame-stddev>0 check (the desktop actually rendered)
g probes "TODO(host) — fill per workload"

podman logs "$NAME" 2>&1 | tail -20 > "$OUT/candidate.log"
echo; echo "VERDICT: $([ $pass = 1 ] && echo GREEN || echo RED)   (logs: $OUT)"
echo "(DRAFT — complete the launch contract + the access-path probes per workload; then it is the gate.)"
exit $((1 - pass))
