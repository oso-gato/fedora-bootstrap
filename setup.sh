#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.1.15 (dependency hygiene — leaf over metapackage: install fail2ban-server, NOT the fail2ban metapackage that hard-pulls fail2ban-firewalld->firewalld + fail2ban-sendmail->esmtp; ban backend nftables[type=multiport] on this nft-native host. Removes the firewalld whose stock zone had silently blocked mosh's UDP after a reboot. See README "Upgrading to v1.1.15". Prior: v1.1.14 SELinux permissive-first.)
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
