#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.47 (less-is-more: documentation/comment reduction, no host code or behaviour change. DRY the duplicated dev<->host-loop / post-merge-deploy / merge-gate prose across CLAUDE.md + FLEET.md down to single-source pointers (canonical homes: the parity-guarded fleet-core "THE FLEET" / "THE SELF-SUSTAINING APPARATUS" blocks spliced into the in-box law, plus this repo policy/CLAUDE.md for the deploy mechanics); close the dangling "SELF-SUSTAINING APPARATUS" pointers with a fleet-core breadcrumb; delete a self-contradicting post-merge-tag clause from the stamped law; fix stale "user 3/4" and "tagged per device" comments; and trim this header recursive changelog chain + the completed LIVE-GATE-HANDOFF narrative. v1.2.46 restored setup.sh executable bit (Day-0 Permission-denied regression on fresh clones). Prior releases: see the README "Upgrading an existing host" section + UPGRADING.md.)
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
