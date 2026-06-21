#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.11 (BUILT promotion gate — REAL host-behavior change, not docs-only: the genesis claudebox now stamps a managed PreToolUse hook (policy/hooks/gate-push.sh) that fail-closed DENIES git push / gh pr merge / gh api .../merge to a remote main unless a one-shot approval marker is present, wired by a hardened managed-settings.json (allowManagedHooksOnly + allowManagedPermissionRulesOnly + disableAutoMode + mcp merge denies); setup-user.sh stamps it + verify.sh checks it; a CI control-plane diff-guard blocks unlabelled guardrail PRs. Closes the ultra-verify finding that the PR-first rule was prose-only while the box held a main-pushing token. Server-side branch protection on main remains the PRIMARY backstop (operator one-time item). Prior: v1.2.10 HEADLESS binding prerequisite fleet-wide; v1.2.9 Principle 3 MINIMAL refined fleet-wide ("minimum" is RELATIVE to the chosen capability + disclosed irreducible hard-dep closure; a lighter option that REDUCES function is a recorded capability trade-off, not a minimalism win); v1.2.8 Principle 2(c) bounded official-upstream-binary class; v1.2.7 PR-first maintainership; v1.2.5 verify.sh fail2ban euid-gate fix; v1.2.4 genesis/mother-platform role + fedora-dev maintainership.)
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
