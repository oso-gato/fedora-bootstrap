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
#   * A ticket is an OPEN issue in the CONTROL REPO ($ORG/$REPO, default oso-gato/fedora-bootstrap)
#     carrying the `host-task` label. Scoping host commands to the host's OWN repo — not org-wide —
#     is deliberate: a `host-op` is a host mutation, so its authorization surface must be the host
#     repo's collaborators, NOT "anyone with triage on any oso-gato repo" (adversarial review R5,
#     finding 2). Before any DESTRUCTIVE verb (recreate/re-stamp) is added, this must be tightened
#     further with an issue-AUTHOR allowlist — the label alone is not sufficient authorization then.
#   * Its FIRST body line is the machine-read instruction:  `host-op: <verb> [args...]`
#     (leading whitespace/`> ` blockquote tolerated; everything after line 1 is human prose).
#   * The verb MUST be in the fixed ALLOWLIST below — there is NO arbitrary-command verb, by design
#     (a ticket can request a bounded, reversible host operation, never `run <anything>`). An
#     unknown/malformed verb is refused (host-failed), never executed.
#   * OUTCOME = the `host-agent: DONE|FAILED — <detail>` COMMENT (the authoritative signal the dev
#     side waits on) + the `host-done`/`host-failed` label (best-effort, created-on-use) + the issue
#     CLOSED.
#
# IDEMPOTENCY — TWO markers, deliberately DECOUPLED (adversarial review R5, finding 1):
#   * `<repo>-<issue>.acted`  — written the instant a MUTATING op is performed, BEFORE outcome
#     delivery, recording the computed outcome. Guards the op so a DELIVERY failure NEVER re-runs the
#     host action. (A redeploy gated only on delivery would, against a bad `:latest`, re-`podman pull`
#     + health-flap the workload every 10s until the outcome happened to deliver — container-refresh's
#     anti-flap `.rolled-back` marker only guards its hourly retry timer, not a fresh `systemctl start`.)
#   * `<repo>-<issue>.done`   — written only after the outcome is DELIVERED (comment posted + issue
#     closed). A transient delivery failure leaves `.acted` (op done once) but no `.done`, so the next
#     tick RE-DELIVERS the recorded outcome only — it never re-acts. The still-open issue is the backstop.
#
# DISCOVERY: `gh issue list` on the control repo (NOT `gh search`, NOT python3) — no search-index lag
# (a 10s bus needs immediate consistency), REST rate-limit headroom, and no undeclared interpreter dep.
# `--label` on a not-yet-created label returns empty rc=0 (does not wedge).
#
# WHY PLAIN SHELL (no model in the loop): like the poller, deterministic dispatch of an allowlisted
# verb is unforgeable and prompt-injection-proof. A future judgement verb may spawn `claude -p` for
# THAT step, but the dispatch + safety stay in shell.
#
# RUNS INSIDE claudebox (needs gh/git + the CONTAINER_HOST bridge to drive the host engine), driven
# by host-agent-watch.timer (systemd --user); logs to journald (via stderr — no unbounded file).
# Stands down during a box rebuild (ExecCondition + box-rebuild.sh).
set -uo pipefail
# noglob: the ticket's line-1 instruction ($op) is attacker-influenced and is word-split UNQUOTED in
# dispatch() (intended — to separate verb from args). Without this, a `host-op: redeploy *` would ALSO
# pathname-expand against the CWD (leaking ~/.local/bin filenames into a public issue comment, and
# smearing the arg). The script does no intentional globbing anywhere, so disable it wholesale.
set -f

STATE="$HOME/.local/state/host-agent"; mkdir -p "$STATE"
ORG="${HOST_AGENT_ORG:-oso-gato}"
REPO="${HOST_AGENT_REPO:-fedora-bootstrap}"      # the control repo host-task tickets are read from
LABEL="${HOST_AGENT_LABEL:-host-task}"
# Known workloads the agent may (re)deploy — an arg allowlist so a ticket can't inject an arbitrary
# systemd instance name. A workload here must have a real workload-refresh@<name> unit on the host.
KNOWN_WORKLOADS="${HOST_AGENT_WORKLOADS:-fedora-dev fedora-desktop}"

log(){ echo "[$(date -u +%FT%TZ 2>/dev/null || date)] host-agent: $*" >&2; }   # → journald (no file)

exec 9>"$STATE/watch.lock"
flock -n 9 || { echo "[host-agent] another run holds the lock; skipping" >&2; exit 0; }

# ---- pure helpers (no I/O) -------------------------------------------------------------------------
# parse_op: read an issue body on stdin -> echo the FIRST-LINE instruction "verb args" (or nothing).
# STRICT: only the machine-owned first line is trusted; a `host-op:` mention anywhere below line 1
# (human prose, a quoted example) is ignored — the same line-1-only discipline auto-merge.sh uses.
# `tr -d '\r'` strips CRs first so CRLF cannot forge/hide line boundaries.
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
  ck "crlf"         $'host-op: redeploy fedora-dev\r\nprose'         'redeploy fedora-dev'
  is_known_workload fedora-dev   && echo "ok: known fedora-dev"    || { echo "FAIL known"; f=1; }
  is_known_workload evil-repo    && { echo "FAIL: evil-repo accepted"; f=1; } || echo "ok: unknown workload rejected"
  is_known_workload '*'          && { echo "FAIL: glob '*' accepted as workload"; f=1; } || echo "ok: glob workload rejected"
  is_known_workload ''           && { echo "FAIL: empty accepted as workload"; f=1; } || echo "ok: empty workload rejected"
  # noglob proof: with set -f, an attacker '*' in the arg position word-splits but does NOT expand to filenames.
  set -- $(printf 'redeploy *'); [ "${2:-}" = '*' ] && echo "ok: noglob keeps '*' literal" || { echo "FAIL: '*' expanded to '${2:-}'"; f=1; }
  [ "$f" = 0 ] && echo "ALL HOST-AGENT SELFTESTS PASS" || echo "HOST-AGENT SELFTESTS FAILED"; exit "$f"
fi

# respond: DELIVER the outcome. Close-FIRST (idempotent — re-closing a closed issue is a no-op), then
# post the comment and gate the `.done` marker on the COMMENT landing — so a delivery retry can never
# post a DUPLICATE comment (a failed comment posted nothing; only the tick it succeeds writes .done).
# The label is best-effort and created-on-use; it NEVER gates delivery. <repo> <issue> <done|failed> <detail>
respond(){
  local repo="$1" issue="$2" st="$3" detail="$4" slug="$ORG/$1" verb; verb=DONE; [ "$st" = failed ] && verb=FAILED
  local body="**host-agent: $verb** — $detail"$'\n\n<sub>autonomous host agent (apparatus R5); ticket consumed + closed.</sub>'
  gh label create "host-$st" --repo "$slug" --color ededed --force >/dev/null 2>&1 || true   # create-on-use; ok if exists/denied
  gh issue close "$issue" --repo "$slug" >/dev/null 2>&1 || true                              # idempotent
  gh issue edit  "$issue" --repo "$slug" --add-label "host-$st" >/dev/null 2>&1 \
     || log "$slug#$issue: add-label host-$st failed (non-fatal; label is decorative)"
  if gh issue comment "$issue" --repo "$slug" --body "$body" >/dev/null; then                 # stderr → journald on failure
    : > "$STATE/${repo}-${issue}.done"; rm -f "$STATE/${repo}-${issue}.acted"
    log "$slug#$issue -> $verb ($detail) — delivered + closed"
  else
    log "$slug#$issue -> $verb: issue closed but outcome COMMENT failed — no marker, will re-deliver next tick"
  fi
}

# ---- the ONE-VERB dispatcher (allowlist). Add verbs here; nothing else executes. ----
# redeploy <workload>: trigger the sanctioned host deploy path — workload-refresh@ → container-refresh.sh
#   (busy-probe deferral + digest-compare + health-gated restart + AUTO-ROLLBACK). Idempotent by digest.
do_redeploy(){ # <repo> <issue> <workload>
  local repo="$1" issue="$2" wl="$3" acted="$STATE/${1}-${2}.acted" st detail
  is_known_workload "$wl" || { respond "$repo" "$issue" failed "unknown workload '$wl' (allowed: $KNOWN_WORKLOADS)"; return; }
  if [ -e "$acted" ]; then
    # the host op already ran ONCE for this ticket (a prior tick) — re-DELIVER the recorded outcome
    # only; NEVER re-run the mutating action (that is the health-flap / re-pull defect this guards).
    IFS='|' read -r st detail < "$acted"
    log "$ORG/$repo#$issue: redeploy already performed; re-delivering recorded outcome ($st)"
  else
    local err sc scmain
    err="$(systemctl --user start "workload-refresh@${wl}.service" 2>&1)"; sc=$?
    # workload-refresh@ is a oneshot with SuccessExitStatus=10, so `systemctl start` returns 0 for both
    # a real refresh AND a busy-DEFERRAL (container-refresh exit 10). Read ExecMainStatus to tell them
    # apart and to report the true outcome (R5 = "reports outcomes" — a deferral is NOT a completed deploy).
    scmain="$(systemctl --user show -p ExecMainStatus --value "workload-refresh@${wl}.service" 2>/dev/null)"
    err="${err//$'\n'/ }"
    if [ "$sc" = 0 ] && [ "${scmain:-0}" = 10 ]; then
      st=done;   detail="redeploy '$wl' DEFERRED — workload busy; workload-refresh-retry@${wl} will complete the pull+restart"
    elif [ "$sc" = 0 ]; then
      st=done;   detail="redeploy '$wl' done — workload-refresh@ pulled + digest-compared + health-gated restart (no-op if already current)"
    else
      st=failed; detail="redeploy '$wl' FAILED — workload-refresh@${wl} exit sc=$sc mainstatus=${scmain:-?} (start error, or candidate unhealthy → auto-rolled-back; host left on prior image)${err:+ — $err}"
    fi
    printf '%s|%s\n' "$st" "$detail" > "$acted"   # record BEFORE delivery: a retry re-delivers, never re-acts
  fi
  respond "$repo" "$issue" "$st" "$detail"
}

dispatch(){ # <repo> <issue> <verb> <args...>
  local repo="$1" issue="$2" verb="$3"; shift 3
  case "$verb" in
    redeploy) [ -n "${1:-}" ] && do_redeploy "$repo" "$issue" "$1" \
                 || respond "$repo" "$issue" failed "redeploy needs a workload name (host-op: redeploy <workload>)";;
    ""|*)     respond "$repo" "$issue" failed "unsupported or empty host-op '$verb' — allowed verbs: redeploy <workload>";;
  esac
}

# ---- DISCOVERY: OPEN `host-task` issues in the CONTROL REPO (gh issue list — immediate, dep-free). ----
if ! rows="$(gh issue list --repo "$ORG/$REPO" --state open --label "$LABEL" --limit 100 --json number -q '.[].number')"; then
  log "discovery failed (gh issue list $ORG/$REPO) — skipping this tick"; exit 0    # gh error → journald
fi
NUMS=(); [ -n "$rows" ] && mapfile -t NUMS <<< "$rows"
[ "${#NUMS[@]}" -eq 0 ] && exit 0    # no open tickets — quiet (10s cadence; don't spam journald)

for issue in "${NUMS[@]}"; do
  [ -n "$issue" ] || continue
  [ -e "$STATE/${REPO}-${issue}.done" ] && continue
  body="$(gh issue view "$issue" --repo "$ORG/$REPO" --json body -q .body 2>/dev/null)" \
    || { log "$ORG/$REPO#$issue: body fetch failed; skip this tick"; continue; }
  op="$(printf '%s' "$body" | parse_op)"
  if [ -z "$op" ]; then
    respond "$REPO" "$issue" failed "no valid \`host-op:\` on line 1 of the ticket body (expected: host-op: <verb> [args])"
    continue
  fi
  log "$ORG/$REPO#$issue: host-op='$op'"
  # shellcheck disable=SC2086
  dispatch "$REPO" "$issue" $op
done
