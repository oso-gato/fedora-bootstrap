#!/usr/bin/env bash
# live-gate-run.sh — gate ONE candidate PR on the host and post the verdict back.
#
# The actionable unit of the pre-merge live-gate loop: build the PR's candidate DISPOSABLY
# (build-candidate.sh -> localhost/disposable/*, never pushed, --rm/rmi'd), live-run + access-probe
# it (validate-candidate.sh), then `gh pr comment` the GREEN/RED verdict onto the PR. The host MAY
# comment; it NEVER merges (gate-push.sh blocks merges) — fedora-dev iterates (RED) or Arthur
# merges (GREEN). This runs in a SEPARATE disposable container and never touches the running
# workload, so it is NOT gated on the dev box's session (validation is never blocked by an active
# fedora-dev session — that is by design).
#
# Usage: live-gate-run.sh <workload> <pr-number> [repo-dir]
#   <workload>   the ghcr.io/oso-gato/<workload> name (e.g. fedora-dev)
#   <pr-number>  the open PR to gate
#   [repo-dir]   local clone of the workload repo (default: ~/<workload>)
#
# Preset (CAND_FENCE / CAND_PROBE / HEALTH) resolution order:
#   1. the PR's own `.live-gate` file (workload-shipped — preferred; auto-tracks the run-contract)
#   2. ~/.config/live-gate/<workload>.env  (host fallback, shipped by setup-user.sh)
set -uo pipefail

WL="${1:?usage: live-gate-run.sh <workload> <pr-number> [repo-dir]}"
PR="${2:?pr-number required}"
REPO="${3:-$HOME/$WL}"

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILDER="$HOME/.local/bin/build-candidate.sh"; [ -x "$BUILDER" ] || BUILDER="$HERE/build-candidate.sh"

case "$WL" in */*|*:*) echo "FATAL: <workload> must be a bare name ($WL)"; exit 2;; esac
[ -d "$REPO/.git" ] || { echo "FATAL: $REPO is not a git clone of $WL"; exit 2; }
[ -x "$BUILDER" ] || { echo "FATAL: build-candidate.sh not found (looked in ~/.local/bin and $HERE)"; exit 2; }

# Fetch the PR head once; resolve the preset (prefer the PR-shipped .live-gate).
git -C "$REPO" fetch -q origin "pull/$PR/head" || { echo "FATAL: git fetch pull/$PR/head failed"; exit 2; }
SHA="$(git -C "$REPO" rev-parse --short FETCH_HEAD)" || { echo "FATAL: cannot resolve PR head"; exit 2; }

PRESET="$(mktemp)"; LOG="$(mktemp)"
trap 'rm -f "$PRESET" "$LOG"' EXIT
if git -C "$REPO" show "FETCH_HEAD:.live-gate" >"$PRESET" 2>/dev/null && [ -s "$PRESET" ]; then
  echo "[live-gate] preset: PR-shipped .live-gate"
elif [ -f "$HOME/.config/live-gate/$WL.env" ]; then
  cp "$HOME/.config/live-gate/$WL.env" "$PRESET"; echo "[live-gate] preset: host ~/.config/live-gate/$WL.env"
else
  echo "FATAL: no live-gate preset for $WL (no PR .live-gate, no host ~/.config/live-gate/$WL.env)"; exit 2
fi
# shellcheck disable=SC1090
set -a; . "$PRESET"; set +a    # export CAND_FENCE / CAND_PROBE / HEALTH for build-candidate.sh

echo "[live-gate] gating $WL PR #$PR @ $SHA"
if "$BUILDER" "$WL" "$REPO" "pull/$PR/head" 2>&1 | tee "$LOG"; then VERDICT=GREEN; else VERDICT=RED; fi

# Post the verdict to the PR (host MAY comment; NEVER merges).
TAIL="$(tail -12 "$LOG" | sed 's/`/ /g')"
BODY="$(printf '**Host live-gate (Gate B): VERDICT %s** — %s @ %s\n\nbuilt disposably on the host (localhost/disposable/*, never pushed) + access-probed.\n\n```\n%s\n```\n' "$VERDICT" "$WL" "$SHA" "$TAIL")"
if gh pr comment "$PR" --repo "oso-gato/$WL" --body "$BODY"; then
  echo "[live-gate] verdict $VERDICT posted to oso-gato/$WL#$PR"
else
  echo "[live-gate] WARN: failed to post verdict comment (verdict was $VERDICT)"
fi
# Dedup (the per-commit .done marker) is owned by live-gate-watch.sh, the caller. Standalone runs
# are explicit + re-runnable, so the runner writes no marker. Exit code carries the verdict.
[ "$VERDICT" = GREEN ]
