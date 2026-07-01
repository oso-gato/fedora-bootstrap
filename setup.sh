#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.48 (live-gate-fence-detheater: drop the inert/bypassable `--cap-add=` denylist arm from validate-candidate.sh's fence loop — it matched only the `=` form so the space form `--cap-add X` word-split past it, and the sole real candidate (fedora-dev) uses exactly those caps, so it blocked nothing while implying it did. Granular first-party cap/device/security-opt opt-ins a candidate declares in its `.live-gate` are now ALLOWED; blanket `--privileged`, publish flags, and non-loopback `--network` stay REJECTED; the real containment is the hard defaults `--network=none --cap-drop=ALL --rm --memory --pids-limit` + rootless podman. No change to any real candidate run. Prior: v1.2.47 less-is-more doc/comment reduction; v1.2.46 setup.sh exec-bit restore. Prior releases: see the README "Upgrading an existing host" section + UPGRADING.md.)
#
# Runs the two privilege layers in their correct identities (see README "Privilege layers"):
#   setup-host.sh  — the SYSTEM layer, as ROOT: host packages, /etc, system services, the
#                    tailnet node, and CREATES the operating user + its rootless prerequisites.
#   setup-user.sh  — the ROOTLESS layer, as the operating user: user podman socket, ssh keys,
#                    claudebox, Claude policy, verify. Needs NO host privilege.
# Idempotent — re-run safely.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
U="${BOOTSTRAP_USER:-core}"

if [ "$(id -u)" = 0 ]; then
    BOOTSTRAP_USER="$U" "$HERE/setup-host.sh"
    # Hand off to the operating user for the rootless layer. The root phase already
    # brought up its user bus, so `su -` finds it. `< /dev/null` keeps a queued paste line
    # (e.g. a following `passwd`) from being swallowed by a child that reads stdin.
    su - "$U" -c "GH_KEYS_USER='${GH_KEYS_USER:-oso-gato}' '$HERE/setup-user.sh'" < /dev/null
else
    # Invoked as the unprivileged user: run ONLY the rootless layer. The system layer must
    # already have been provisioned as root (run setup.sh as root on a fresh host).
    echo ">> Running the rootless (user) layer only. The SYSTEM layer must already be in place;"
    echo ">> on a fresh host run setup.sh as root instead."
    exec "$HERE/setup-user.sh"
fi
