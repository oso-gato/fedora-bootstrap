#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.49 (selinux-nowait: replace the multi-reboot SELinux convergence STATE MACHINE (a 15-min soak, an AVC acceptance gate, a post-enforce health check, an auto-revert, four system units + the 176-line selinux-autoenforce.sh driver + selinux-chain.* markers) with a NO-WAIT convergence. From a disabled host, setup-host.sh sets SELINUX=permissive + /.autorelabel; the Day-0 `passwd core && reboot` boots into the relabel (permissive, brick-safe) which auto-reboots; a fire-once selinux-enforce-once.service then flips to enforcing LIVE on the now-labeled boot and self-disarms — 2 reboots, NO waiting, enforcing without a 3rd reboot. The insurance (soak/gate/health-check/auto-revert) is dropped by design for a data-less throwaway VPS that just re-provisions if enforcing ever wedges; enforcing stays the target + the SELINUX_TARGET=permissive opt-out stays. Prior: v1.2.48 live-gate fence de-theater; v1.2.47 doc reduction; v1.2.46 setup.sh exec-bit restore. Prior releases: see the README "Upgrading an existing host" section + UPGRADING.md.)
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
