#!/usr/bin/env bash
# fedora-bootstrap — DAILY claudebox refresh DECISION (update method 1). NOT the rebuild itself.
#
# Run by claudebox-rebuild-daily.service (timer-activated, see setup-user.sh "user 3/5"). Keeps the
# box from drifting even if you never ask for a rebuild — WITHOUT ever interrupting live work:
#   * No claudebox session active  -> start the detached rebuild now.
#   * A session IS active          -> do NOT interrupt; drop a rebuild.pending marker. The `claude`
#                                     wrapper performs the rebuild the moment you next exit a session
#                                     (so a refresh that came due while you worked happens on quit).
# The two on-demand methods (#2 ask-Claude flag + #3 host `claudebox-rebuild`) are unaffected and
# always available. Detection is via the SHARED session lock the `claude` wrapper holds per session.
set -uo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
state="$HOME/.local/state/claudebox"; mkdir -p "$state"

# Probe the session lock: if we can take it EXCLUSIVE (non-blocking), no session holds the shared
# lock -> idle -> rebuild now. If not, a session is live -> defer to its exit.
if flock -n -x "$state/session.lock" -c true 2>/dev/null; then
    echo "claudebox daily refresh: idle -> rebuilding now."
    exec systemctl --user start --no-block claudebox-rebuild-run.service
fi
echo "claudebox daily refresh: session active -> deferring; rebuilds when you exit."
: > "$state/rebuild.pending"
