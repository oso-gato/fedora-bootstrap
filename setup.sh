#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.14 (Day-0 ASKS for TS_AUTHKEY — unattended Tailscale join, browser-login fallback: when TS_AUTHKEY is not in the environment AND stdin is a tty, setup-host.sh now PROMPTS for a Tailscale auth key (tskey-…) for an unattended host join; a blank answer — or a non-interactive run like `setup.sh < /dev/null` — falls through to the existing interactive browser web-login join. Brings the host day-0 to the same ask-or-web-login Tailscale pattern the workload spin-up wizards follow (fedora-desktop + fedora-dev spin-up.sh). setup-host.sh only; no security-posture change, no new package. Prior: v1.2.13 docs cleanup (scrub deleted-repo refs); v1.2.12 FLEET governance (3-box model, host PR-only, fedora-dev sole merge box); v1.2.11 BUILT promotion gate; v1.2.10 HEADLESS binding prerequisite fleet-wide; v1.2.9 Principle 3 MINIMAL refined fleet-wide; v1.2.8 Principle 2(c) bounded official-upstream-binary class; v1.2.7 PR-first maintainership; v1.2.5 verify.sh fail2ban euid-gate fix; v1.2.4 genesis/mother-platform role + fedora-dev maintainership.)
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
