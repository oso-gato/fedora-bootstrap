#!/usr/bin/env bash
# live-gate-watch.sh — DYNAMIC org-wide discovery of PRs labelled `live-validate`, live-gating each
# new candidate commit exactly once. Driven by live-gate-watch.timer (systemd --user).
#
# Model C (repo-set-agnostic): instead of iterating a hard-coded workload list, this polls the WHOLE
# org in ONE query for any open PR carrying the `live-validate` label, across EVERY repo. So as repos
# are created / removed / renamed / merged, Arthur maintains NO list — labelling a PR is the entire
# opt-in. The per-PR build/gate is clone-on-demand (live-gate-run.sh fetches the PR head into an
# ephemeral tree), so a repo needs no pre-placed clone here either.
#
# The pre-merge loop's transport (with live-gate-run.sh): fedora-dev opens/labels a PR -> this picks
# it up -> builds + gates the candidate DISPOSABLY on the host -> posts GREEN/RED/SKIPPED back to the
# PR -> fedora-dev iterates (RED) or Arthur merges (GREEN). The host comments, NEVER merges.
#
# NOT gated on any workload's session: the gate runs a throwaway container that never touches the
# running workload, so an active dev session never blocks validation (by design). Self-serializing
# (flock) so two timer firings never overlap; per-(repo,SHA) `.done` marker so each commit is gated
# exactly once.
#
# Optional safety/testing filter: set LIVE_GATE_WORKLOADS (space-separated bare repo names) to
# RESTRICT discovery to those repos. Unset (the DEFAULT) = org-wide, no list.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HOME/.local/bin/live-gate-run.sh"; [ -x "$RUNNER" ] || RUNNER="$HERE/live-gate-run.sh"
STATE="$HOME/.local/state/live-gate"; mkdir -p "$STATE"
ORG="${LIVE_GATE_ORG:-oso-gato}"
LABEL="${LIVE_GATE_LABEL:-live-validate}"

# Optional allowlist FILTER (default: empty = org-wide). When set, discovery is restricted to it.
declare -A ALLOW=(); ALLOW_ON=0
if [ -n "${LIVE_GATE_WORKLOADS:-}" ]; then
  ALLOW_ON=1; for w in $LIVE_GATE_WORKLOADS; do ALLOW["$w"]=1; done
fi

exec 9>"$STATE/watch.lock"
flock -n 9 || { echo "[live-gate-watch] another run holds the lock; skipping"; exit 0; }
[ -x "$RUNNER" ] || { echo "FATAL: live-gate-run.sh not found"; exit 2; }

# ---- ORPHAN SWEEP + CACHE GC (opportunistic, self-throttled, flock-guarded) ----
# Reap throwaway images/containers/trees a `kill -9`/crash left behind (the per-run EXIT traps only
# fire on a clean exit) and bound the persistent build caches so churn can't exhaust the VPS quota.
# Self-throttled (FD_SWEEP_INTERVAL_MIN, default 30m) so calling it every poll is ~free.
SWEEP="$HOME/.local/bin/throwaway-sweep.sh"; [ -x "$SWEEP" ] || SWEEP="$HERE/throwaway-sweep.sh"
[ -x "$SWEEP" ] && "$SWEEP" || true

# ---- DISCOVERY: one org-wide query for ALL open `live-validate` PRs. `gh search prs` exposes
# repository + number (NOT the head SHA — headRefOid is not a search JSON field), so resolve the
# head SHA per PR with a cheap `gh pr view`. Fallback: the search/issues REST endpoint. ----
rows=""
if rows="$(gh search prs --owner "$ORG" --state open --label "$LABEL" \
             --limit 200 --json repository,number 2>/dev/null)" && [ -n "$rows" ]; then
  mapfile -t PRS < <(printf '%s' "$rows" | python3 -c 'import sys,json
for p in json.load(sys.stdin): print(p["repository"]["name"], p["number"])' 2>/dev/null)
else
  echo "[live-gate-watch] gh search prs failed/empty; trying search/issues REST fallback"
  rows="$(gh api -X GET search/issues -f q="org:$ORG is:pr is:open label:$LABEL" --paginate 2>/dev/null)" || {
    echo "[live-gate-watch] discovery failed (both gh search prs and search/issues); skipping this poll"; exit 0; }
  # repository_url tail = repo name; number = PR number.
  mapfile -t PRS < <(printf '%s' "$rows" | python3 -c 'import sys,json
d=json.load(sys.stdin)
for it in d.get("items", []):
    print(it["repository_url"].rsplit("/",1)[-1], it["number"])' 2>/dev/null)
fi

[ "${#PRS[@]}" -eq 0 ] && { echo "[live-gate-watch] no open $LABEL PRs in org:$ORG"; exit 0; }

for row in "${PRS[@]}"; do
  repo="${row%% *}"; num="${row##* }"
  [ -n "$repo" ] && [ -n "$num" ] || continue
  if [ "$ALLOW_ON" = 1 ] && [ -z "${ALLOW[$repo]:-}" ]; then
    echo "[live-gate-watch] $repo#$num: not in LIVE_GATE_WORKLOADS allowlist; skip"; continue
  fi
  sha="$(gh pr view "$num" --repo "$ORG/$repo" --json headRefOid -q .headRefOid 2>/dev/null)" || sha=""
  [ -n "$sha" ] || { echo "[live-gate-watch] $repo#$num: cannot resolve head SHA; skip this poll"; continue; }
  marker="$STATE/${repo}-${sha}.done"
  if [ -e "$marker" ]; then
    echo "[live-gate-watch] $repo#$num @ ${sha:0:7} already gated ($(cat "$marker")); skip"
    continue
  fi
  echo "[live-gate-watch] gating $repo#$num @ ${sha:0:7}"
  "$RUNNER" "$repo" "$num"; rc=$?
  # DEDUP DISCIPLINE: write the per-SHA .done marker ONLY for a DELIVERED outcome (a verdict/skip that
  # actually reached the PR as a comment). rc 2 (FATAL infra) and rc 4 (verdict computed but the
  # comment post FAILED) are NON-verdicts — dedup'ing them buries the commit forever with nothing on
  # the PR, so leave NO marker and let the next poll re-gate + re-attempt delivery.
  case "$rc" in
    0) v=GREEN;       dedup=1;;
    1) v=RED;         dedup=1;;
    3) v=SKIP;        dedup=1;;
    4) v=UNDELIVERED; dedup=0;;
    2) v=FATAL;       dedup=0;;
    *) v="ERR($rc)";  dedup=0;;
  esac
  if [ "$dedup" = 1 ]; then
    printf '%s %s\n' "$v" "$(date -Iseconds 2>/dev/null || echo now)" > "$marker"
    echo "[live-gate-watch] $repo#$num @ ${sha:0:7} -> $v (deduped)"
  else
    echo "[live-gate-watch] $repo#$num @ ${sha:0:7} -> $v (NOT deduped — will re-gate next poll)"
  fi
done
