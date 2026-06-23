#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.13 (Docs cleanup — scrub references to the now-deleted standalone repos; no host behavior change: the desktop-variant repos (fedora-xrdp, fedora-tigervnc, fedora-kasm, debian-kasm-tigervnc) + debian-dev were deleted from oso-gato (fedora-desktop's xrdp+grd lineages superseded them). README's desktop-containers line now names fedora-desktop; the WORKLOAD_CONTAINERS dead commented placeholders are removed and a fedora-desktop placeholder added; policy/CLAUDE.md's dev-box example de-references debian-dev. Policy re-stamp only — re-run setup.sh. Prior: v1.2.12 FLEET governance (3-box model, host PR-only, fedora-dev sole merge box); v1.2.11 BUILT promotion gate; v1.2.10 HEADLESS binding prerequisite fleet-wide; v1.2.9 Principle 3 MINIMAL refined fleet-wide; v1.2.8 Principle 2(c) bounded official-upstream-binary class; v1.2.7 PR-first maintainership; v1.2.5 verify.sh fail2ban euid-gate fix; v1.2.4 genesis/mother-platform role + fedora-dev maintainership.)
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
