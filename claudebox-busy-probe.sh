#!/usr/bin/env bash
# fedora-bootstrap — busy probe for any claudebox-pattern workload container.
#
# Called by container-refresh.sh as: claudebox-busy-probe.sh <name>
#
# Exit codes (load-bearing — caller distinguishes them):
#   0   idle (BOTH session.lock AND box-rebuild.lock acquirable)
#   1   busy (at least one lock held)
#   2   probe broken: container not running, exec failed, lock dir missing
#
# Distinguishing 1 vs 2 matters: 1 = "defer, retry hourly"; 2 = "alert the
# operator; something is genuinely wrong."
#
# AND-checks two in-container flocks. Every workload container in the fleet
# hosts a claudebox using the standard scripts, so paths are uniform:
#   /home/core/.local/state/claudebox/session.lock     SHARED by `claude` for session lifetime
#   /home/core/.local/state/claudebox/box-rebuild.lock EXCLUSIVE by box-rebuild.sh for rebuild lifetime
# Idle iff BOTH acquirable via `flock -n -x ... -c true` (try-and-release).
#
# Uses `--user 1000:1000` (numeric) not `--user core` (name) — the in-container
# /etc/passwd may not always resolve `core` consistently; UID 1000 is the
# fleet contract (Build Principle 5 of every workload container's repo).
set -u

name="${1:?usage: claudebox-busy-probe.sh <name>}"

# Verify the container is running first. If it isn't, "busy probe" is
# meaningless and refresh is moot — but report exit 2 (probe broken) so the
# refresh script logs it loudly rather than silently treating it as busy.
if ! podman container inspect "$name" -f '{{.State.Running}}' 2>/dev/null | grep -q true; then
    echo "[$name] busy-probe: container not running" >&2
    exit 2
fi

# Verify the state directory exists. If it doesn't, the container isn't a
# claudebox-pattern container OR its first-boot bootstrap hasn't completed.
# Either way, NOT a "lock-is-held" case → exit 2, not 1.
if ! podman exec --user 1000:1000 "$name" test -d /home/core/.local/state/claudebox 2>/dev/null; then
    echo "[$name] busy-probe: /home/core/.local/state/claudebox missing inside container" >&2
    exit 2
fi

# The actual probe.
if podman exec --user 1000:1000 "$name" bash -c '
    flock -n -x /home/core/.local/state/claudebox/session.lock     -c true \
 && flock -n -x /home/core/.local/state/claudebox/box-rebuild.lock -c true
' >/dev/null 2>&1; then
    exit 0
fi
exit 1
