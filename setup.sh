#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.12 (FLEET governance — host claudebox is now PR-ONLY; policy re-stamp, no host-layer delta: a 3-box fleet model with ONE merge authority is stamped identically into all three repos (THE FLEET header). The genesis host claudebox operates the host INCLUDING create/remove containers, is the ONLY box that sees the live containers, and LIVE-DIAGNOSES + develops fixes to the fleet image repos it operates — but STOPS at the open PR: it no longer merges, pushes, or tags main. fedora-dev becomes the fleet's SOLE merge box (merges any open PR incl. control-plane, only on Arthur's discrete clickable APPROVE; a free-text "yes" is not approval). Supersedes the closed v1.2.12 equalise-merge attempt. Re-run setup.sh to re-stamp the agent law. Prior: v1.2.11 BUILT promotion gate (managed PreToolUse hook + hardened managed-settings + CI diff-guard); v1.2.10 HEADLESS binding prerequisite fleet-wide; v1.2.9 Principle 3 MINIMAL refined fleet-wide; v1.2.8 Principle 2(c) bounded official-upstream-binary class; v1.2.7 PR-first maintainership; v1.2.5 verify.sh fail2ban euid-gate fix; v1.2.4 genesis/mother-platform role + fedora-dev maintainership.)
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
