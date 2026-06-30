#!/usr/bin/env bash
# fedora-bootstrap — full claudebox rebuild (destroy + recreate from the pinned manifest).
#
# Run by the user service claudebox-rebuild-run.service (as the operating user, DETACHED under
# the user manager so it OUTLIVES the box it tears down — see setup-user.sh "user 3/5"). There is
# NO schedule; a rebuild is always deliberate, triggered one of two ways:
#   * In-box:  Claude runs `claudebox-rebuild` -> writes ~/.local/state/claudebox/rebuild.request
#              -> claudebox-rebuild.path fires -> claudebox-rebuild.service -> starts THIS via the
#              run service. (The in-box agent has no host systemd access; the flag file in the
#              shared HOME is its only signal — the host .path watcher sees it across the bind mount.)
#   * Host:    `claudebox-rebuild` -> starts the run service directly.
#
# The rebuild = drop the box, then re-run the rootless layer (setup-user.sh): a fresh `distrobox
# assemble` re-pulls the base image and reinstalls the LATEST-channel claude-code + tools from
# Anthropic's repo, then re-applies the host bridges (claudebox-init.sh) + Claude policy + verify.
# Your Claude login/credentials SURVIVE — they live in the shared HOME, not the disposable box.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Any rebuild satisfies a deferred daily refresh — clear the marker so the wrapper won't re-fire it.
rm -f "$HOME/.local/state/claudebox/rebuild.pending" 2>/dev/null || true

# STAND DOWN the live-gate watcher for the WHOLE rebuild. THIS is the fix for the rebuild-only
# "builds then fails": live-gate-watch.timer fires `distrobox enter claudebox` every 15s, and during
# a rebuild that races setup-user.sh's own first `distrobox enter claudebox -- true` — the enter that
# runs distrobox-init (the dnf install). Two `distrobox enter` then drive distrobox-init concurrently
# in the same fresh box: they collide on the pre-init hooks (init errors) OR deadlock on distrobox's
# name-keyed `~/.cache/distrobox/.claudebox.fifo` (init hangs → the run service's TimeoutStartSec
# kills it). Either way the box "builds" and the rebuild fails. Day-zero is immune ONLY because the
# timer is enabled AFTER the box is built (setup-user.sh user 4/5); on every subsequent rebuild it is
# already firing throughout. Stopping the timer AND any in-flight service instance removes the race
# window. setup-user.sh re-enables the timer at its end (user 4/5); the trap is the backstop so a
# FAILED rebuild still re-arms the watcher (never leave PR gating dead).
echo ">> claudebox rebuild: standing down the live-gate watcher for the rebuild window …"
systemctl --user stop live-gate-watch.timer live-gate-watch.service 2>/dev/null || true
trap 'systemctl --user start live-gate-watch.timer 2>/dev/null || true' EXIT

echo ">> claudebox rebuild: removing the existing box (force) …"
distrobox rm -f claudebox >/dev/null 2>&1 || true

echo ">> claudebox rebuild: re-running the rootless layer — fresh image + latest Claude Code …"
# setup-user.sh is idempotent: it re-syncs keys, re-assembles a fresh box (the manifest's bare
# `assemble create` now creates from scratch since we just removed it), re-applies bridges + policy,
# re-installs these rebuild units, and verifies. NOT `exec`: keep this shell alive so the EXIT trap
# above re-arms the watcher even when setup-user.sh fails. The run service still tracks us to
# completion (Type=oneshot tracks ExecStart=box-rebuild.sh, which waits for setup-user.sh) and its
# exit code still propagates (set -e + this being the last command).
"$HERE/setup-user.sh"
