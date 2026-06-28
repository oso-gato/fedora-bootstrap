#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.42 (host-all-keys: drop the public-door SSH key allowlist - authorize ALL keys on github.com/<user>.keys, symmetric with the dev box. The operator manages the GitHub account directly, so the account is the single trust root; the in-image fingerprint allowlist added marginal defense-in-depth at the cost of enroll friction + a host/dev-box lockstep. sync-authorized-keys.sh now authorizes every published key (no label_for, no LOGIN_KEY tagging); setup-host.sh phase 5 drops the LOGIN_KEY sshd drop-in (20-login-key.conf) - converging an already-deployed host by removing the file + reloading sshd so PermitUserEnvironment is no longer set - and the tmux comment is reworded (LOGIN_KEY audit gone). Control-plane (key-sync + sshd). Security-posture change, flagged. Prior: v1.2.41 (drop-fail2ban: remove fail2ban from the host. Both public ssh doors are KEY-ONLY, so its core job - throttling password brute-force - does not apply; it ran (journald backend) but guarded nothing. setup-host.sh drops fail2ban-server from the install + the sshd jail, and converges an already-deployed host by stop+disable of the service and removal of the package plus any legacy fail2ban-metapackage baggage; verify.sh now asserts fail2ban ABSENT; the PACKAGES row is removed. Paired with the merged fedora-dev drop of fail2ban + rsyslog. Trade-off: slightly more scanner log-noise, in exchange for not running a control with no purpose on a key-only door. Security-posture change, flagged. Prior: v1.2.40 (docs-access-honesty: correct two false public-exposure claims in README. The Access table marked dev-container ssh/mosh as public=no and the prose claimed the public IP exposes exactly two surfaces, but this host deploys the fedora-dev Quadlet which publishes public key-only ssh:4444 + mosh 61001-62000/udp; the table cell + sentence now list the dev container's key-only public door as a third hardened surface, native RDP/VNC + Cockpit remaining tailnet-only. Found during the SSH/Mosh connectivity audit. Docs only; no host package/service/deploy-path change. Prior: v1.2.39 (live-gate.sample: document the deeper-probe pattern - PROBE may invoke a shipped script for richer lineage-aware assertions; doc-only, no host change.)
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
