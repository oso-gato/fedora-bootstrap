#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.12 (EQUALISE host-claudebox dev authority to the fedora-dev build box — policy re-stamp, no host-layer delta: the genesis claudebox may now DEVELOP + PR + clickable-approved-merge ANY fleet image source repo it operates and can diagnose live (fedora-desktop + every WORKLOAD_CONTAINERS image), not just the foundation fedora-bootstrap/fedora-dev — because the host is the ONLY vantage that can probe/log the live containers and turn that first-hand diagnosis into patches (diagnose-live -> patch -> PR -> approved-merge -> CI -> workload-refresh pull -> redeploy). Two boundaries PRESERVED: builds are always CI's job (never podman build here), and a repo the host neither operates nor can diagnose stays surface-only. Also unifies the merge-rule wording fleet-wide: ONE canonical statement (propose -> clickable approval -> the AGENT merges, never a human), and the gate-push.sh deny message now states that procedure at the moment of action. Prior: v1.2.11 BUILT promotion gate (managed PreToolUse hook + hardened managed-settings + CI diff-guard); v1.2.10 HEADLESS binding prerequisite fleet-wide; v1.2.9 Principle 3 MINIMAL refined fleet-wide; v1.2.8 Principle 2(c) bounded official-upstream-binary class; v1.2.7 PR-first maintainership; v1.2.5 verify.sh fail2ban euid-gate fix; v1.2.4 genesis/mother-platform role + fedora-dev maintainership.)
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
