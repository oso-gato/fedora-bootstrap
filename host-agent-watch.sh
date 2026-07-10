#!/usr/bin/env bash
# host-agent-watch.sh — the HOST AUTONOMOUS AGENT (apparatus spec fedora-dev#131, R5).
#
# The symmetric other half of the dev-side poller. The dev box (fedora-dev / nox) develops and
# merges, but is WALLED OFF from host operations — it cannot recreate the fedora-dev container,
# redeploy a new image, or touch the erebus runtime. THIS service is how the dev box gets those
# done: it consumes dev→host TICKETS (GitHub issues labelled `host-task`) and performs the
# host-only operation each requests, then posts the OUTCOME back as a comment + closes the ticket.
#
# TICKET PROTOCOL (the dev↔host instruction bus — GitHub issues, per Arthur 2026-07-10):
#   * A ticket is an OPEN issue in ANY oso-gato repo carrying the `host-task` label.
#   * Its FIRST body line is the machine-read instruction:  `host-op: <verb> [args...]`
#     (leading whitespace/`> ` blockquote tolerated; everything after line 1 is human prose).
#   * The verb MUST be in the fixed ALLOWLIST below — there is NO arbitrary-command verb, by design
#     (a ticket can request a bounded, reversible host operation, never `run <anything>`). An
#     unknown/malformed verb is refused (host-failed), never executed.
#   * OUTCOME: the agent comments `host-agent: DONE|FAILED — <detail>`, adds the `host-done`/
#     `host-failed` label, and CLOSES the issue. The dev side reads the closed state + the comment.
#
# DISCOVERY / SERIALISATION / DEDUP: modelled on live-gate-watch.sh — one org-wide `gh search issues`
# per tick (no repo list to maintain), a flock singleton so two timer firings never overlap, and a
# per-(repo,issue) `.done` marker written ONLY after a delivered outcome (a transient failure leaves
# no marker → the next tick retries; the still-OPEN issue is itself the backstop).
#
# WHY PLAIN SHELL (no model in the loop): like the poller, deterministic dispatch of an allowlisted
# verb is unforgeable and prompt-injection-proof. A future judgement verb (e.g. live-validate with a
# semantic check) may spawn `claude -p` for THAT step, but the dispatch + safety stay in shell.
#
# RUNS INSIDE claudebox (needs gh/git + the CONTAINER_HOST bridge to drive the host engine), driven
# by host-agent-watch.timer (systemd --user). Stands down during a box rebuild (ExecCondition).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$HOME/.local/state/host-agent"; mkdir -p "$STATE"
LOG="$STATE/host-agent.log"
ORG="${HOST_AGENT_ORG:-oso-gato}"
LABEL="${HOST_AGENT_LABEL:-host-task}"
# Known workloads the agent may (re)deploy — an arg allowlist so a ticket can't inject an arbitrary
# systemd instance name. A workload here must have a real workload-refresh@<name> unit on the host.
KNOWN_WORKLOADS="${HOST_AGENT_WORKLOADS:-fedora-dev fedora-desktop}"

log(){ echo "[$(date -u +%FT%TZ 2>/dev/null || date)] host-agent: $*" | tee -a "$LOG" >&2; }

exec 9>"$STATE/watch.lock"
flock -n 9 || { echo "[host-agent] another run holds the lock; skipping" >&2; exit 0; }

# ---- pure helpers (no I/O) -------------------------------------------------------------------------
# parse_op: read an issue body on stdin -> echo the FIRST-LINE instruction "verb args" (or nothing).
# STRICT: only the machine-owned first line is trusted; a `host-op:` mention anywhere below line 1
# (human prose, a quoted example) is ignored — the same line-1-only discipline auto-merge.sh uses.
parse_op(){ tr -d '\r' | sed -n '1{s/^[[:space:]]*>\{0,1\}[[:space:]]*//;s/^host-op:[[:space:]]*//p;q}'; }
# a workload name must be in the known set (exact match) — reject anything else.
is_known_workload(){ local w; for w in $KNOWN_WORKLOADS; do [ "$w" = "$1" ] && return 0; done; return 1; }

if [ "${1:-}" = "--selftest" ]; then
  f=0; ck(){ local g; g="$(printf '%s' "$2" | parse_op)"; [ "$g" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — got '$g' want '$3'"; f=1; }; }
  ck "plain"        $'host-op: redeploy fedora-dev\nplease deploy'   'redeploy fedora-dev'
  ck "blockquote"   $'> host-op: restamp\nprose'                     'restamp'
  ck "leading ws"   $'   host-op:   redeploy fedora-desktop  '       'redeploy fedora-desktop  '
  ck "not-line1"    $'hello\nhost-op: redeploy fedora-dev'           ''
  ck "no op"        $'just a normal issue body'                      ''
  ck "backtick ex"  '`host-op: redeploy fedora-dev`'                 ''
  is_known_workload fedora-dev   && echo "ok: known fedora-dev"    || { echo "FAIL known"; f=1; }
  is_known_workload evil-repo    && { echo "FAIL: evil-repo accepted"; f=1; } || echo "ok: unknown workload rejected"
  [ "$f" = 0 ] && echo "ALL HOST-AGENT SELFTESTS PASS" || echo "HOST-AGENT SELFTESTS FAILED"; exit "$f"
fi

# respond: post the outcome comment + label + CLOSE the ticket. <repo> <issue> <state:done|failed> <detail>
respond(){ # writes the marker on success so a delivered outcome is not repeated
  local repo="$1" issue="$2" st="$3" detail="$4" slug="$ORG/$1" verb; verb=DONE; [ "$st" = failed ] && verb=FAILED
  local body="**host-agent: $verb** — $detail"$'\n\n<sub>autonomous host agent (apparatus R5); ticket consumed + closed.</sub>'
  if gh issue comment "$issue" --repo "$slug" --body "$body" >/dev/null 2>&1 \
     && gh issue edit "$issue" --repo "$slug" --add-label "host-$st" >/dev/null 2>&1 \
     && gh issue close "$issue" --repo "$slug" >/dev/null 2>&1; then
    : > "$STATE/${repo}-${issue}.done"
    log "$slug#$issue -> $verb ($detail) — responded + closed"
  else
    log "$slug#$issue -> $verb computed but response/close FAILED — no marker, will retry next tick"
  fi
}

# ---- the ONE-VERB dispatcher (allowlist). Add verbs here; nothing else executes. ----
# redeploy <workload>: pull + digest-compare + restart the workload via its workload-refresh@ unit
#   (the sanctioned host deploy path; busy-probe + auto-rollback live inside container-refresh.sh).
do_redeploy(){ # <repo> <issue> <workload>
  local repo="$1" issue="$2" wl="$3"
  is_known_workload "$wl" || { respond "$repo" "$issue" failed "unknown workload '$wl' (allowed: $KNOWN_WORKLOADS)"; return; }
  if systemctl --user start "workload-refresh@${wl}.service" >/dev/null 2>&1; then
    respond "$repo" "$issue" done "redeploy triggered for '$wl' (workload-refresh@${wl}: pull + digest-compare + restart, health-gated with auto-rollback)"
  else
    respond "$repo" "$issue" failed "could not start workload-refresh@${wl}.service (unit missing or start failed)"
  fi
}

dispatch(){ # <repo> <issue> <verb> <args...>
  local repo="$1" issue="$2" verb="$3"; shift 3
  case "$verb" in
    redeploy) [ -n "${1:-}" ] && do_redeploy "$repo" "$issue" "$1" \
                 || respond "$repo" "$issue" failed "redeploy needs a workload name (host-op: redeploy <workload>)";;
    ""|*)     respond "$repo" "$issue" failed "unsupported or empty host-op '$verb' — allowed verbs: redeploy <workload>";;
  esac
}

# ---- DISCOVERY: one org-wide query for OPEN `host-task` issues (no repo list). ----
rows=""
if ! rows="$(gh search issues --owner "$ORG" --state open --label "$LABEL" --limit 100 \
              --json repository,number 2>/dev/null)"; then
  log "discovery failed (gh search issues) — skipping this tick"; exit 0
fi
mapfile -t TICKETS < <(printf '%s' "$rows" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: d=[]
for it in d: print(it["repository"]["name"], it["number"])' 2>/dev/null)

[ "${#TICKETS[@]}" -eq 0 ] && { log "no open $LABEL tickets in org:$ORG"; exit 0; }

for row in "${TICKETS[@]}"; do
  repo="${row%% *}"; issue="${row##* }"
  [ -n "$repo" ] && [ -n "$issue" ] || continue
  [ -e "$STATE/${repo}-${issue}.done" ] && { log "$ORG/$repo#$issue already handled; skip"; continue; }
  body="$(gh issue view "$issue" --repo "$ORG/$repo" --json body -q .body 2>/dev/null)" \
    || { log "$ORG/$repo#$issue: body fetch failed; skip this tick"; continue; }
  op="$(printf '%s' "$body" | parse_op)"
  if [ -z "$op" ]; then
    respond "$repo" "$issue" failed "no valid \`host-op:\` on line 1 of the ticket body (expected: host-op: <verb> [args])"
    continue
  fi
  log "$ORG/$repo#$issue: host-op='$op'"
  # shellcheck disable=SC2086
  dispatch "$repo" "$issue" $op
done
