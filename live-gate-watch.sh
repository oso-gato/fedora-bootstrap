#!/usr/bin/env bash
# live-gate-watch.sh — poll workload repos for PRs labelled `live-validate` and live-gate each
# new candidate commit exactly once. Driven by live-gate-watch.timer (systemd --user).
#
# The pre-merge loop's transport (with live-gate-run.sh): fedora-dev opens/labels a PR -> this
# picks it up -> builds + gates the candidate DISPOSABLY on the host -> posts GREEN/RED back to the
# PR -> fedora-dev iterates (RED) or Arthur merges (GREEN). The host comments, NEVER merges.
#
# NOT gated on any workload's session: the gate runs a throwaway container that never touches the
# running workload, so an active fedora-dev dev session never blocks validation (by design — the
# loop's whole point is to validate WHILE fedora-dev is being worked in). Self-serializing so two
# timer firings never overlap; per-commit `.done` marker so each SHA is gated exactly once.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HOME/.local/bin/live-gate-run.sh"; [ -x "$RUNNER" ] || RUNNER="$HERE/live-gate-run.sh"
STATE="$HOME/.local/state/live-gate"; mkdir -p "$STATE"
# Workloads to watch (the host operates these). Override via LIVE_GATE_WORKLOADS (space-separated).
read -r -a WORKLOADS <<< "${LIVE_GATE_WORKLOADS:-fedora-dev}"

exec 9>"$STATE/watch.lock"
flock -n 9 || { echo "[live-gate-watch] another run holds the lock; skipping"; exit 0; }
[ -x "$RUNNER" ] || { echo "FATAL: live-gate-run.sh not found"; exit 2; }

for WL in "${WORKLOADS[@]}"; do
  REPO="$HOME/$WL"
  [ -d "$REPO/.git" ] || { echo "[live-gate-watch] $WL: no clone at $REPO; skipping"; continue; }
  prs="$(gh pr list --repo "oso-gato/$WL" --label live-validate --state open --json number,headRefOid 2>/dev/null)" \
    || { echo "[live-gate-watch] $WL: gh pr list failed; skipping"; continue; }
  mapfile -t rows < <(printf '%s' "$prs" | python3 -c 'import sys,json
for p in json.load(sys.stdin): print(p["number"], p["headRefOid"])' 2>/dev/null)
  [ "${#rows[@]}" -eq 0 ] && { echo "[live-gate-watch] $WL: no live-validate PRs"; continue; }
  for row in "${rows[@]}"; do
    num="${row%% *}"; sha="${row##* }"
    marker="$STATE/${WL}-${sha}.done"
    if [ -e "$marker" ]; then
      echo "[live-gate-watch] $WL#$num @ ${sha:0:7} already gated ($(cat "$marker")); skip"
      continue
    fi
    echo "[live-gate-watch] gating $WL#$num @ ${sha:0:7}"
    if "$RUNNER" "$WL" "$num"; then v=GREEN; else v=RED; fi
    printf '%s %s\n' "$v" "$(date -Iseconds 2>/dev/null || echo now)" > "$marker"
    echo "[live-gate-watch] $WL#$num @ ${sha:0:7} -> $v"
  done
done
