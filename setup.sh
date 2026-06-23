#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.15 (Docs — make the host spin-up path explicit + the unattended join reachable; no host behavior change: the Day-0 block now shows the UNATTENDED Tailscale join (set TS_AUTHKEY=tskey-… on the setup.sh line — honored even with `< /dev/null`; blank = browser web-login) and adds a "who runs this / there is no spin-up.sh|run.sh here — setup.sh IS the host genesis path" signpost so a spin-up agent doesn't hunt for a missing wizard. Corrects the v1.2.14 framing: the INTERACTIVE TS_AUTHKEY prompt fires only on a later interactive setup.sh re-run, NOT the `< /dev/null` Day-0 paste (which is load-bearing for the passwd step). policy/CLAUDE.md DO gains a fleet spin-up-paths bullet (host=setup.sh; workload=spin-up.sh→run.sh; never hand-roll podman run). Prior: v1.2.14 day-0 TS_AUTHKEY prompt; v1.2.13 docs cleanup (scrub deleted-repo refs); v1.2.12 FLEET governance (3-box model, host PR-only, fedora-dev sole merge box); v1.2.11 BUILT promotion gate; v1.2.10 HEADLESS binding prerequisite fleet-wide; v1.2.9 Principle 3 MINIMAL refined fleet-wide; v1.2.8 Principle 2(c) bounded official-upstream-binary class; v1.2.7 PR-first maintainership; v1.2.5 verify.sh fail2ban euid-gate fix; v1.2.4 genesis/mother-platform role + fedora-dev maintainership.)
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
