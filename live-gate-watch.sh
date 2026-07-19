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
# R16 OPERATING SCOPE (issue #132): discovery is org-wide, so each candidate repo is checked against
# the maintainer-confirmed scope set (repo-scope.sh + policy/scope.conf) BEFORE any per-PR work — an
# out-of-scope labelled PR is skipped with one loud line, no build, no verdict (see scope_ok below).
#
# Optional safety/testing filter: set LIVE_GATE_WORKLOADS (space-separated bare repo names) to
# RESTRICT discovery to those repos. Unset (the DEFAULT) = org-wide (still scope-gated).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HOME/.local/bin/live-gate-run.sh"; [ -x "$RUNNER" ] || RUNNER="$HERE/live-gate-run.sh"
SCOPE="$HOME/.local/bin/repo-scope.sh"; [ -x "$SCOPE" ] || SCOPE="$HERE/repo-scope.sh"
STATE="$HOME/.local/state/live-gate"; mkdir -p "$STATE"
ORG="${LIVE_GATE_ORG:-oso-gato}"
LABEL="${LIVE_GATE_LABEL:-live-validate}"
# The unreadable-config / missing-reader fallback set — the apparatus's OWN two repos (R16 rule 4).
SCOPE_OWN="${SCOPE_OWN:-fedora-dev fedora-bootstrap}"

# scope_ok <repo> — the R16 gate. rc 0 = act; nonzero = out of scope (skip). Delegates to the reader
# (which itself falls back to $SCOPE_OWN when policy/scope.conf is unreadable). If the READER is
# missing/not-executable it cannot answer, so fail CLOSED here to $SCOPE_OWN — the host can still gate
# its own two repos but never wanders (issue #132).
scope_ok(){
  local r="$1" w
  if [ -x "$SCOPE" ]; then "$SCOPE" check "$r" >/dev/null 2>&1; return; fi
  for w in $SCOPE_OWN; do [ "$w" = "$r" ] && return 0; done
  return 1
}

# Optional allowlist FILTER (default: empty = org-wide). When set, discovery is restricted to it.
declare -A ALLOW=(); ALLOW_ON=0
if [ -n "${LIVE_GATE_WORKLOADS:-}" ]; then
  ALLOW_ON=1; for w in $LIVE_GATE_WORKLOADS; do ALLOW["$w"]=1; done
fi

exec 9>"$STATE/watch.lock"
flock -n 9 || { echo "[live-gate-watch] another run holds the lock; skipping"; exit 0; }
[ -x "$RUNNER" ] || { echo "FATAL: live-gate-run.sh not found"; exit 2; }

# ---- R9 FLEET HALT (apparatus fedora-dev#135): read the maintainer-bound `halt` signal at the TOP of
# the tick — BEFORE the sweep/discovery/build/post below — so a fleet SOFT STOP takes effect within one
# tick. HALTED / persistently-unreadable ⇒ OBSERVE-ONLY: log and exit cleanly (sweep nothing, build
# nothing, post nothing); un-halt resumes next tick (the timer keeps firing). An in-flight build from a
# prior tick already completed before this tick could acquire the flock above, so it is never touched.
# The reader (fleet-halt.sh) mirrors the dev-side bin/fleet-halt.sh contract and fails CLOSED toward
# stopping, so a missing/unreadable reader parks this tick rather than acting blind. ----
FLEET_HALT="$HOME/.local/bin/fleet-halt.sh"; [ -x "$FLEET_HALT" ] || FLEET_HALT="$HERE/fleet-halt.sh"
if [ ! -x "$FLEET_HALT" ]; then
  echo "[live-gate-watch] fail-closed: R9 halt reader (fleet-halt.sh) missing/not executable — cannot read the halt signal; observe-only this tick"
  exit 0
fi
halt_state="$(FLEET_HALT_TAG=live-gate "$FLEET_HALT")"; hrc=$?
if [ "$hrc" != 0 ]; then
  echo "[live-gate-watch] FLEET HALT ($halt_state) — OBSERVE-ONLY: sweeping/building/posting NOTHING this tick (un-halt resumes next tick)"
  exit 0
fi
echo "[live-gate-watch] fleet-halt: CLEAR — proceeding"

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
  # R16-SCOPE-GATE (issue #132): honour the confirmed OPERATING SCOPE before ANY per-PR API call,
  # build or verdict. An out-of-scope repo (the #165 leak from the host end) is skipped here — the
  # host never touches a repo the maintainer did not confirm.
  if ! scope_ok "$repo"; then
    echo "[live-gate-watch] R16 OUT-OF-SCOPE: $repo#$num not in the confirmed scope set (policy/scope.conf) — no build, no verdict; skip"
    continue
  fi
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
