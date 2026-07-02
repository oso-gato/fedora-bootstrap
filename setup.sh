#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.50 (cache-ui-knobs: less-is-more cleanup from the over-engineering audit — no security or loop-critical change. throwaway-sweep.sh dnf-cache GC collapsed from a hand-rolled age-then-LRU two-stage walk to a single blunt SIZE cap (over cap -> clear the dir; it re-warms free on a throwaway) and the dangling-layer prune de-tuned to a plain `podman image prune -f` (dropped the FD_DNF_CACHE_MAX_AGE_DAYS + FD_BUILDCACHE_AGE knobs); live-gate-watch.timer relaxed from 15s + AccuracySec=1s to a plain 60s (the ~90s build dominates; cadence is pickup-latency only); the tmux `prefix+g` co-view tri-state toggle + @coview + 3 tutorial messages dropped (the `window-size latest` base IS the real multi-device fix and stays); the uninstalled optional periodic-sweep timer recommendation dropped from the sweeper + watcher. The crash-orphan reaper, live-gate core, and workload rollback are untouched. Prior: v1.2.49 SELinux no-wait; v1.2.48 fence de-theater; v1.2.47 doc reduction. Prior releases: see the README "Upgrading an existing host" section + UPGRADING.md.)
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
