#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.51 (fastfetch-login: install fastfetch on the HOST (it was box-only) + an /etc/profile.d/zz-fastfetch.sh drop-in that shows a fastfetch system-info banner at every interactive login for every user — root, core, any user day0 creates. Named to sort before zz-tmux-attach.sh so it prints once per ssh/mosh login before the shell exec's into tmux, and is suppressed inside tmux panes via a $TMUX guard. PACKAGES gains a Host fastfetch waiver row (Build Principle 4). Prior: v1.2.50 cache/UI knobs; v1.2.49 SELinux no-wait; v1.2.48 fence de-theater. Prior releases: see the README "Upgrading an existing host" section + UPGRADING.md.)
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
