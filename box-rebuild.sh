#!/usr/bin/env bash
# fedora-bootstrap — full claudebox rebuild (destroy + recreate from the pinned manifest).
#
# Run by the user service claudebox-rebuild-run.service (as the operating user, DETACHED under
# the user manager so it OUTLIVES the box it tears down — see setup-user.sh "user 3/4"). There is
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

echo ">> claudebox rebuild: removing the existing box (force) …"
distrobox rm -f claudebox >/dev/null 2>&1 || true

echo ">> claudebox rebuild: re-running the rootless layer — fresh image + latest Claude Code …"
# setup-user.sh is idempotent: it re-syncs keys, re-assembles a fresh box (the manifest's bare
# `assemble create` now creates from scratch since we just removed it), re-applies bridges + policy,
# re-installs these rebuild units, and verifies. exec so the run service tracks it to completion.
exec "$HERE/setup-user.sh"
