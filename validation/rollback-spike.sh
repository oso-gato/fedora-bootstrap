#!/usr/bin/env bash
# rollback-spike.sh — HOST-VALIDATION spike for container-refresh.sh's rollback branch.
#
# DRAFT written by fedora-dev; NOT yet run. MUST run on the host box (needs the user
# systemd + Quadlet + the host podman engine that container-refresh drives). fedora-dev
# has no systemd and no host engine, so it cannot run this — that's why it's a handoff.
#
# Proves the load-bearing, never-fired branch: when a workload's :latest never goes healthy,
# container-refresh.sh retags :latest back to the prior digest, restarts, and the prior
# (healthy) image runs again — with a <name>.rolled-back marker.
#
# Disposable + host-immutable: a throwaway workload 'rbspike', tiny LOCAL images, its own
# Quadlet + state, all torn down on exit. Touches NO real fleet workload, pushes NOTHING to
# GHCR. Uses container-refresh's test-only SKIP_PULL seam (see PR) so no registry is needed.
set -uo pipefail

NAME=rbspike
IMG="ghcr.io/oso-gato/${NAME}:latest"        # LOCAL-only tag; never pushed
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REFRESH="$HERE/../container-refresh.sh"
UDIR="$HOME/.config/containers/systemd"
STATE="$HOME/.local/state/container-refresh"
pass=1; t(){ printf '  %-30s %s\n' "$1" "$2"; [ "$2" = PASS ] || pass=0; }

cleanup() {
  systemctl --user stop "${NAME}.service" 2>/dev/null
  rm -f "$UDIR/${NAME}.container"; systemctl --user daemon-reload 2>/dev/null
  podman rm -f "$NAME" 2>/dev/null
  podman rmi -f "$IMG" "localhost/${NAME}-good" "localhost/${NAME}-bad" 2>/dev/null
  rm -f "$STATE/${NAME}".* 2>/dev/null
}
trap cleanup EXIT
cleanup   # clean slate

echo "== build GOOD (health passes) + BAD (health never passes) images =="
podman build -t "localhost/${NAME}-good" - >/dev/null 2>&1 <<'EOF'
FROM registry.fedoraproject.org/fedora:44
HEALTHCHECK --interval=2s --start-period=1s --retries=3 CMD test -f /tmp/ok
ENTRYPOINT ["bash","-c","touch /tmp/ok; exec sleep infinity"]
EOF
podman build -t "localhost/${NAME}-bad" - >/dev/null 2>&1 <<'EOF'
FROM registry.fedoraproject.org/fedora:44
HEALTHCHECK --interval=2s --start-period=1s --retries=3 CMD false
ENTRYPOINT ["bash","-c","exec sleep infinity"]
EOF
podman image exists "localhost/${NAME}-good" && podman image exists "localhost/${NAME}-bad" \
  && t build-test-images PASS || { t build-test-images FAIL; exit 1; }

echo "== deploy GOOD as the workload via a minimal Quadlet (Pull=missing, Notify=healthy) =="
mkdir -p "$UDIR" "$STATE"
cat > "$UDIR/${NAME}.container" <<EOF
[Unit]
Description=rollback-spike throwaway workload
[Container]
Image=${IMG}
ContainerName=${NAME}
Pull=missing
Notify=healthy
HealthCmd=test -f /tmp/ok
HealthInterval=2s
HealthStartPeriod=1s
HealthRetries=3
[Install]
WantedBy=default.target
EOF
podman tag "localhost/${NAME}-good" "$IMG"
good_id=$(podman image inspect "$IMG" -f '{{.Id}}')
systemctl --user daemon-reload
if systemctl --user start "${NAME}.service" && [ "$(systemctl --user is-active ${NAME}.service)" = active ]; then
  t deploy-good-healthy PASS
else
  t deploy-good-healthy FAIL; journalctl --user -u "${NAME}.service" -n 20 --no-pager; exit 1
fi

echo "== swap :latest -> BAD locally, run container-refresh (SKIP_PULL), expect ROLLBACK =="
podman tag "localhost/${NAME}-bad" "$IMG"           # the 'new' :latest that won't go healthy
bad_id=$(podman image inspect "$IMG" -f '{{.Id}}')
[ "$good_id" != "$bad_id" ] && t images-differ PASS || t images-differ FAIL
SKIP_PULL=1 BUSY_PROBE=/bin/true "$REFRESH" "$NAME"; rc=$?
echo "  (container-refresh exit: $rc — expect 1 = rolled back)"

echo "== assertions =="
running_id=$(podman container inspect "$NAME" -f '{{.Image}}' 2>/dev/null || echo "")
[ "$running_id" = "$good_id" ] && t rolled-back-to-prior PASS || t rolled-back-to-prior "FAIL(running=$running_id)"
[ "$(systemctl --user is-active ${NAME}.service)" = active ] && t healthy-after-rollback PASS || t healthy-after-rollback FAIL
[ -f "$STATE/${NAME}.rolled-back" ] && t rolled-back-marker PASS || t rolled-back-marker FAIL

echo; echo "VERDICT: $([ $pass = 1 ] && echo GREEN || echo RED)"
[ $pass = 1 ] || echo "RED => container-refresh.sh's rollback branch has a real bug; fix it (that is the point)."
exit $((1 - pass))
