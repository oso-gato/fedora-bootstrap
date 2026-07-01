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

IMG="${1:?usage: validate-candidate.sh <candidate-image-ref> [health-cmd]}"
HEALTH="${2:-${HEALTH:-}}"      # arg overrides; else $HEALTH from env; else the image's own HEALTHCHECK
NAME="vcand-$$"
OUT="$(mktemp -d)"; pass=1
g(){ printf '  %-26s %s\n' "$1" "$2"; [ "$2" = PASS ] || pass=0; }
trap 'podman rm -f -t 0 "$NAME" >/dev/null 2>&1; rm -rf "$OUT"' EXIT

echo "== launch candidate DISPOSABLY + FENCED =="
# CAND_FENCE = this target's run-contract fence, MINUS the public publish (-p) and MINUS real
# secrets. DEFAULT = the HARDEST fence: --network=none --cap-drop=ALL. The probe runs on the
# candidate's OWN loopback via `podman exec`, so a loopback-only workload needs NO egress — keep it
# networkless by default. A target that genuinely needs egress/devices/systemd OPTS IN explicitly
# via its `.live-gate` fence (FENCE_<target>), never silently.
CAND_FENCE="${CAND_FENCE:---network=none --cap-drop=ALL}"

# LOOPBACK-ONLY ENFORCEMENT (hardening): the gate probes the candidate on its OWN loopback via
# `podman exec`; NOTHING is ever published to a host port. A fence that publishes a port would punch
# a hole in that and expose UN-MERGED candidate code on a real host port. Fail CLOSED if the resolved
# per-target fence carries any publish flag (-p / --publish / -P / --publish-all, incl. =forms and
# the no-space -p8443:8443 form). The gate adds its own --rm/--name/--memory/--pids-limit; a fence
# must never carry a public publish. (Word-splitting $CAND_FENCE here matches the launch below.)
for _tok in $CAND_FENCE; do
  case "$_tok" in
    -p*|--publish|--publish=*|--publish-all|--publish-all=*|-P)
      echo "  fence REJECTED: publish flag '$_tok' present (the gate is loopback-only by construction; no port may be published)"
      echo "VERDICT: RED (fence publishes a port)"; exit 1;;
    --privileged|--privileged=true)
      echo "  fence REJECTED: '$_tok' grants blanket privilege — not permitted in a validation fence"
      echo "VERDICT: RED (fence requests privileged)"; exit 1;;
    # NO --cap-add denylist arm (v1.2.48): granular capability/device/security-opt opt-ins a candidate
    # declares in its FIRST-PARTY .live-gate (e.g. fedora-dev's `--cap-add NET_ADMIN --cap-add SYS_ADMIN
    # --device /dev/net/tun --device /dev/fuse --security-opt label=disable`, required for its nested
    # rootless podman) are ALLOWED. The former `--cap-add=…` reject was theater — it matched only the
    # `=` form, so the space form `--cap-add X` word-split past it, and the sole real candidate uses
    # exactly those caps — so it blocked nothing while implying it did. Blanket --privileged stays
    # rejected above; the real containment is the hard defaults (--network=none --cap-drop=ALL --rm
    # --memory --pids-limit) + rootless podman + the publish / non-loopback-network rejects here.
    --network=host|--network=slirp4netns|--network=pasta)
      # Only --network=none or --network=lo are permitted. host/slirp/pasta give the candidate
      # real or near-real network access (including the tailnet on the host), defeating containment.
      echo "  fence REJECTED: '$_tok' grants network access beyond loopback — not permitted in a validation fence"
      echo "VERDICT: RED (fence opens network)"; exit 1;;
    --network=*)
      # Reject any --network= value that is not none or the loopback interface name.
      _net="${_tok#--network=}"
      case "$_net" in
        none|lo) ;;  # permitted
        *) echo "  fence REJECTED: '--network=$_net' is not a permitted fence value (only none or lo)"
           echo "VERDICT: RED (fence opens network)"; exit 1;;
      esac;;
  esac
done

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
# word-splitting CAND_FENCE into podman args is intentional
launch=( podman run -d --rm --name "$NAME" $CAND_FENCE
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
