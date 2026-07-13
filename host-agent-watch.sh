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
#     (leading whitespace/`> ` blockquote tolerated). Everything after line 1 is human prose — EXCEPT
#     the `rebuild-devbox` verb, which additionally reads a SESSION MANIFEST from the body between the
#     %%DEVBOX-MANIFEST-BEGIN%% / %%DEVBOX-MANIFEST-END%% sentinels (parse_manifest — bounded, strictly
#     validated DATA, never sourced or executed; the fields only ever become literal argv to podman/tmux).
#   * The verb MUST be in the fixed ALLOWLIST below — there is NO arbitrary-command verb, by design
#     (a ticket can request a bounded, reversible host operation, never `run <anything>`). An
#     unknown/malformed verb is refused (host-failed), never executed.
#
# VERBS (allowlist — nothing else executes):
#   redeploy <workload>       — sanctioned pull+digest+health-gated restart (workload-refresh@). Idempotent.
#   rebuild-devbox <devbox>   — R17 (fedora-dev#174 host half): the DESTRUCTIVE lifecycle verb. KILL the
#     dev box from OUTSIDE (total teardown; a host podman-level Quadlet restart reaps every process in
#     the container's PID namespace — the ghost an in-container `distrobox rm -f` cannot, incident
#     2026-07-13) → REBUILD via the SANCTIONED path (workload-rebuild@ = container-refresh.sh under
#     FORCE_REBUILD, so R10's health-gate + digest auto-rollback still apply — not bypassed, not
#     duplicated) → VERIFY the kill BY CONTAINER ID (never by name — the reused name is what hid the
#     ghost) → RESTORE + RESUME every manifest session (tmux at its cwd + the host-fixed resume cmd) →
#     VERIFY the entrypoint-supervised poller is OBSERVABLY sweeping → REPORT killed/restored/resumed/
#     could-not. Fail-safe: any unverified kill, unhealthy rebuild, idle-not-resuming session, or
#     silent poller SURFACES as FAILED (silence never means restored). Because it kills active sessions,
#     it is AUTHOR-GATED (below), unlike the reversible `redeploy`.
#
# DESTRUCTIVE-VERB AUTHORIZATION (host-agent header's own standing requirement; R16 scope law): the
#   `host-task` label is NOT sufficient authorization for a verb that destroys running work. `redeploy`
#   is reversible/bounded (label-authorized). `rebuild-devbox` additionally requires the ISSUE AUTHOR to
#   hold admin|maintain on the control repo (is_authorized_author, fail-closed) — an App identity or a
#   mere label authorizes NOTHING.
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
# rebuild-devbox (R17) is NARROWER than KNOWN_WORKLOADS: only a genuine dev box has the session/poller
# semantics restore assumes, and a rebuild KILLS active sessions — so it is not offered fleet-wide.
REBUILD_WORKLOADS="${HOST_AGENT_REBUILDABLE:-fedora-dev}"
# The session MANIFEST rides in the ticket BODY between these sentinels (line 1 stays `host-op:`),
# PARSED as bounded DATA (parse_manifest), never executed. Each line: `session <name> <cwd>`.
MANIFEST_BEGIN='%%DEVBOX-MANIFEST-BEGIN%%'
MANIFEST_END='%%DEVBOX-MANIFEST-END%%'
DEVBOX_MAX_SESSIONS="${DEVBOX_MAX_SESSIONS:-32}"
# Container-facing incantations = the R17 CONTRACT that fedora-dev#174 fulfils (host-fixed — the
# manifest NEVER supplies executable content). Overridable so the host operator / dev side can tune
# them (poller unit name, resume verb) without touching this control logic.
DEVBOX_RESUME_CMD="${DEVBOX_RESUME_CMD:-claude --continue}"     # typed into each restored session (in its cwd)
DEVBOX_POLLER_UNIT="${DEVBOX_POLLER_UNIT:-poller.service}"      # entrypoint-supervised service to verify sweeping
DEVBOX_POLLER_WINDOW="${DEVBOX_POLLER_WINDOW:-120}"            # s: poller must LOG within this bound (sweeping, not a PID)
DEVBOX_RESUME_SETTLE="${DEVBOX_RESUME_SETTLE:-20}"            # s: a restored session must go non-idle within this bound
TICKET_BODY=''   # set per-ticket in the discovery loop; rebuild-devbox parses its manifest from it

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
# rebuild-devbox is offered only for a genuine dev box (exact match) — narrower than KNOWN_WORKLOADS.
is_rebuildable_workload(){ local w; for w in $REBUILD_WORKLOADS; do [ "$w" = "$1" ] && return 0; done; return 1; }

# parse_manifest: read an issue body on stdin -> echo one validated `name<TAB>cwd` per session line.
# Exit: 0 = a well-formed block (possibly zero sessions), 2 = MALFORMED (bad/extra field, or a BEGIN
# with no END), 3 = NO manifest block at all. The name/cwd are validated as DATA against strict
# allowlists here and are only ever passed as LITERAL argv to podman/tmux downstream (never eval'd);
# together with `set -f` that closes the injection surface the issue calls out.
parse_manifest(){
  awk -v B="$MANIFEST_BEGIN" -v E="$MANIFEST_END" -v MAX="$DEVBOX_MAX_SESSIONS" '
    BEGIN{ inb=0; seenb=0; n=0; rc=0 }
    { sub(/\r$/,""); t=$0; sub(/^[[:space:]]+/,"",t); sub(/[[:space:]]+$/,"",t) }   # CR-strip + trimmed copy for sentinel match
    t==B { inb=1; seenb=1; next }
    t==E { if(inb) inb=2; next }
    inb==1 {
      if ($0 ~ /^[[:space:]]*$/) next                                    # blank lines inside the block are fine
      if ($1 != "session" || NF != 3)                        { rc=2; exit }   # exactly: session <name> <cwd> (no spaces in cwd)
      if ($2 !~ /^[A-Za-z0-9._-]+$/ || length($2) > 64)      { rc=2; exit }   # session name allowlist
      if ($3 !~ /^\/[A-Za-z0-9._\/@%+-]*$/ || length($3) > 256) { rc=2; exit }   # absolute path, no spaces/metacharacters
      if (++n > MAX)                                         { rc=2; exit }
      printf "%s\t%s\n", $2, $3
    }
    END{ if(rc) exit rc; if(!seenb) exit 3; if(inb==1) exit 2; exit 0 }
  '
}

# kill_verified: the KILL/rebuild verdict, BY CONTAINER ID (never by name — the reused name is exactly
# what hid the 2026-07-13 ghost). old=gone means the removed container (and thus every process in its
# PID namespace) is truly reaped. Echoes ok|GHOST|NONEW|SAMEID; returns 0 only on ok.
kill_verified(){ # <oldid> <newid> <gone|alive>
  [ "$3" = gone ]  || { echo GHOST;  return 1; }   # old container / its processes survive → the ghost
  [ -n "$2" ]      || { echo NONEW;  return 1; }   # nothing came back up
  [ "$2" != "$1" ] || { echo SAMEID; return 1; }   # same ID → not a real rebuild (name reuse illusion)
  echo ok; return 0
}

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
  # ---- rebuild-devbox pure helpers (R17) ----
  # parse_manifest: <desc> <body> <expected TAB-joined out> <expected rc>
  cm(){ local g rc; g="$(printf '%s' "$2" | parse_manifest)"; rc=$?; { [ "$g" = "$3" ] && [ "$rc" = "$4" ]; } && echo "ok: mf $1" || { echo "FAIL: mf $1 — got '$g' rc=$rc want '$3' rc=$4"; f=1; }; }
  cm "one session"  $'prose\n%%DEVBOX-MANIFEST-BEGIN%%\nsession dev134 /home/core/repos/a\n%%DEVBOX-MANIFEST-END%%\ntail' $'dev134\t/home/core/repos/a' 0
  cm "two + blank"  $'%%DEVBOX-MANIFEST-BEGIN%%\nsession a /r/a\n\nsession b /r/b\n%%DEVBOX-MANIFEST-END%%'                 $'a\t/r/a\nb\t/r/b'         0
  cm "empty block"  $'%%DEVBOX-MANIFEST-BEGIN%%\n%%DEVBOX-MANIFEST-END%%'                                                  ''                         0
  cm "no block"     $'just prose, no manifest at all'                                                                      ''                         3
  cm "unterminated" $'%%DEVBOX-MANIFEST-BEGIN%%\nsession a /r/a'                                                           $'a\t/r/a'                 2
  cm "bad verb"     $'%%DEVBOX-MANIFEST-BEGIN%%\nrun rm -rf /\n%%DEVBOX-MANIFEST-END%%'                                    ''                         2
  cm "cwd w/ space" $'%%DEVBOX-MANIFEST-BEGIN%%\nsession a /r/a b\n%%DEVBOX-MANIFEST-END%%'                                ''                         2
  cm "relative cwd" $'%%DEVBOX-MANIFEST-BEGIN%%\nsession a rel/path\n%%DEVBOX-MANIFEST-END%%'                              ''                         2
  cm "meta in name" $'%%DEVBOX-MANIFEST-BEGIN%%\nsession a;rm /r/a\n%%DEVBOX-MANIFEST-END%%'                               ''                         2
  # kill_verified: <desc> <oldid> <newid> <gone|alive> <expected verdict>
  ckv(){ local g; g="$(kill_verified "$2" "$3" "$4")"; [ "$g" = "$5" ] && echo "ok: kv $1" || { echo "FAIL: kv $1 — got '$g' want '$5'"; f=1; }; }
  ckv "clean kill"  AAAA BBBB gone  ok
  ckv "ghost"       AAAA BBBB alive GHOST
  ckv "no new"      AAAA ''   gone  NONEW
  ckv "same id"     AAAA AAAA gone  SAMEID
  is_rebuildable_workload fedora-dev     && echo "ok: fedora-dev rebuildable"          || { echo "FAIL: fedora-dev not rebuildable"; f=1; }
  is_rebuildable_workload fedora-desktop && { echo "FAIL: desktop rebuildable"; f=1; } || echo "ok: desktop NOT rebuildable (narrow allowlist)"
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
    : > "$STATE/${repo}-${issue}.done"    # .acted is left as a PERMANENT tombstone — .done alone gates the
                                          # discovery skip, so removing .acted would only add a non-atomic re-act hole.
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
  if [ -e "$acted" ] && IFS='|' read -r st detail < "$acted" && [ -n "$st" ]; then
    # the host op already ran ONCE for this ticket (a prior tick) — re-DELIVER the recorded outcome
    # only; NEVER re-run the mutating action (that is the health-flap / re-pull defect this guards).
    # A corrupt/empty marker fails the [ -n "$st" ] guard and falls to a safe (digest-idempotent) re-act.
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

# ---- rebuild-devbox (R17) — the DESTRUCTIVE lifecycle verb: KILL → REBUILD → RESTORE → RESUME → VERIFY ----

# is_authorized_author: a DESTRUCTIVE verb needs the ISSUE AUTHOR to hold admin|maintain on the control
# repo (the `host-task` label is NOT authorization — host-agent header; R16 scope law). FAIL-CLOSED:
# an unreadable / empty / non-collaborator permission is NOT authorized (a 404 is `gh api` rc≠0).
is_authorized_author(){ # <login>
  local login="$1" role
  [ -n "$login" ] || return 1
  # `.role_name` is the FINE-GRAINED role (admin|maintain|write|triage|read); `.permission` is the
  # coarse legacy field that collapses maintain→"write", so it can NEVER match "maintain" — read
  # role_name (falling back only if the API omits it). A 404 for a non-collaborator/App is `gh api` rc≠0.
  role="$(gh api "repos/$ORG/$REPO/collaborators/$login/permission" -q '.role_name // .permission' 2>/dev/null)" || return 1
  case "$role" in admin|maintain) return 0;; *) return 1;; esac
}

# REACH BACK IN: podman exec into the FRESH container as the fleet uid (mirrors claudebox-busy-probe).
pexec(){ podman exec --user 1000:1000 "$@"; }

# restore_session: recreate ONE tmux session at its recorded cwd inside the fresh box, then RESUME it by
# typing the host-fixed DEVBOX_RESUME_CMD (never manifest content). Idempotent (drops a stale same-name
# session first). rc 0 = created + resume dispatched; 1 = could-not (surfaces, never a silent success).
# $1 is the VERIFIED CONTAINER ID (never the name — the reused name is what hid the ghost; R17 req 6).
restore_session(){ # <cid> <name> <cwd>
  local cid="$1" name="$2" cwd="$3"
  pexec "$cid" test -d "$cwd" 2>/dev/null || { log "restore: cwd '$cwd' absent in $cid — cannot restore '$name'"; return 1; }
  pexec "$cid" tmux kill-session -t "$name" >/dev/null 2>&1 || true
  pexec "$cid" tmux new-session -d -s "$name" -c "$cwd" >/dev/null 2>&1 \
    || { log "restore: tmux new-session '$name' failed in $cid"; return 1; }
  pexec "$cid" tmux send-keys -t "$name" "$DEVBOX_RESUME_CMD" Enter >/dev/null 2>&1 \
    || { log "restore: resume send-keys '$name' failed in $cid"; return 1; }
  return 0
}

# session_active: a RESUMED session must be actively running its task — a pane still at a bare login
# shell is IDLE = a FAILURE (R17). ONE check; the caller settles ONCE for ALL sessions, so total FINISH
# time is bounded by a SINGLE DEVBOX_RESUME_SETTLE, not N×settle (an adversarial N-idle manifest can't
# blow the 300s host-agent tick). $1 = the VERIFIED CONTAINER ID (never the name — R17 req 6).
session_active(){ # <cid> <name>
  local cid="$1" name="$2" cmd
  cmd="$(pexec "$cid" tmux list-panes -t "$name" -F '#{pane_current_command}' 2>/dev/null | head -n1)"
  case "$cmd" in
    ''|bash|-bash|sh|-sh|zsh|-zsh|fish|-fish) log "resume: session '$name' still idle ('${cmd:-none}') — NOT resuming"; return 1;;
    *) return 0;;
  esac
}

# wait_poller_sweeping: the entrypoint-supervised poller must be OBSERVABLY sweeping — active AND logging
# within the window (a PID is not enough). Poll up to DEVBOX_POLLER_WINDOW (every 2s).
# $1 is the VERIFIED CONTAINER ID (never the name — R17 req 6).
wait_poller_sweeping(){ # <cid>
  local cid="$1" i n
  for ((i=0; i<DEVBOX_POLLER_WINDOW; i+=2)); do
    if pexec "$cid" systemctl --user is-active --quiet "$DEVBOX_POLLER_UNIT" 2>/dev/null; then
      n="$(pexec "$cid" journalctl --user -u "$DEVBOX_POLLER_UNIT" --since "-${DEVBOX_POLLER_WINDOW}s" -q 2>/dev/null | wc -l)"
      [ "${n:-0}" -gt 0 ] && return 0
    fi
    sleep 2
  done
  return 1
}

# do_rebuild_devbox: a DECOUPLED two-phase state machine (a host-agent tick is meant to take SECONDS —
# host-agent-watch.service caps ExecStart at 300s — while a health-gated rebuild can take minutes, so we
# FIRE the rebuild --no-block and POLL it across ticks; a `.rebuild` marker guards re-firing so FORCE
# never loops). Phase FIRE: authorize + validate manifest + capture old container ID + start
# workload-rebuild@. Phase FINISH (marker present, unit done): KILL-verify by ID → RESTORE+RESUME every
# session → VERIFY the poller → record + deliver the outcome.
do_rebuild_devbox(){ # <repo> <issue> <workload>
  local repo="$1" issue="$2" wl="$3"
  local acted="$STATE/${1}-${2}.acted" rb="$STATE/${1}-${2}.rebuild" st detail
  is_rebuildable_workload "$wl" || { respond "$repo" "$issue" failed "rebuild-devbox refused: '$wl' is not a rebuildable dev box (allowed: $REBUILD_WORKLOADS)"; return; }

  # (0) outcome already recorded by a prior tick → re-DELIVER only, never re-act (the .acted contract).
  if [ -e "$acted" ] && IFS='|' read -r st detail < "$acted" && [ -n "$st" ]; then
    log "$ORG/$repo#$issue: rebuild-devbox outcome already recorded; re-delivering ($st)"
    respond "$repo" "$issue" "$st" "$detail"; return
  fi

  # (1) rebuild already FIRED (marker present) → poll the unit; on completion do KILL-verify + RESTORE.
  if [ -e "$rb" ]; then
    local active; active="$(systemctl --user is-active "workload-rebuild@${wl}.service" 2>/dev/null)"
    case "$active" in
      ""|activating|active|reloading|deactivating)
        # "" = a transient systemctl read; treat as in-progress and retry next tick (fail-safe: never
        # mistake an unreadable state for "completed" and verify a half-done rebuild). Ticket stays open.
        log "$ORG/$repo#$issue: rebuild of $wl in progress (${active:-unknown}) — will restore on completion"; return ;;
      failed)
        st=failed
        detail="rebuild-devbox '$wl' FAILED its health-gate — container-refresh rolled back to the prior image (R10); box left on the last-known-good, NO sessions restored. Re-file to retry."
        printf '%s|%s\n' "$st" "$detail" > "$acted"; respond "$repo" "$issue" "$st" "$detail"; return ;;
      *) : ;;  # inactive/dead → the oneshot completed successfully; fall through to verification.
    esac

    # rebuild completed — VERIFY THE KILL BY CONTAINER ID (never by name).
    local oldid newid manifest verdict oldexists=gone
    oldid="$(head -n1 "$rb" 2>/dev/null)"
    manifest="$(tail -n +2 "$rb" 2>/dev/null)"
    newid="$(podman container inspect "$wl" -f '{{.Id}}' 2>/dev/null || echo '')"
    [ -n "$oldid" ] && podman container exists "$oldid" 2>/dev/null && oldexists=alive
    verdict="$(kill_verified "$oldid" "$newid" "$oldexists")" || {
      st=failed
      detail="rebuild-devbox '$wl': KILL/rebuild verification FAILED ($verdict) — oldID=${oldid:0:12} newID=${newid:0:12} oldContainer=$oldexists. Box in a KNOWN state; NOT claiming success."
      printf '%s|%s\n' "$st" "$detail" > "$acted"; respond "$repo" "$issue" "$st" "$detail"; return
    }

    # RESTORE every manifest session (create tmux at its cwd + dispatch the resume), BY VERIFIED
    # CONTAINER ID ($newid — never the name; R17 req 6); then settle ONCE and verify each is actively
    # resuming — a restored-but-idle session is a FAILURE (R17). Names are validated [A-Za-z0-9._-]
    # (no spaces) and `set -f` is on, so word-splitting $created is safe.
    local total=0 ok=0 name cwd failed_names='' created=''
    while IFS=$'\t' read -r name cwd; do
      [ -n "$name" ] || continue
      total=$((total+1))
      if restore_session "$newid" "$name" "$cwd"; then created="$created $name"; else failed_names="$failed_names $name(norestore)"; fi
    done <<< "$manifest"
    [ -n "$created" ] && sleep "$DEVBOX_RESUME_SETTLE"      # one bounded settle for ALL sessions, not per-session
    for name in $created; do
      if session_active "$newid" "$name"; then ok=$((ok+1)); else failed_names="$failed_names $name(idle)"; fi
    done

    # VERIFY the entrypoint-supervised poller is OBSERVABLY sweeping in the NEW container (by $newid).
    local poller=down; wait_poller_sweeping "$newid" && poller=sweeping

    if [ "$ok" = "$total" ] && [ "$poller" = sweeping ]; then
      st=done
      detail="rebuild-devbox '$wl' COMPLETE — KILLED old ${oldid:0:12} (zero survivors), rebuilt to ${newid:0:12} (health-gated), RESTORED+RESUMED $ok/$total sessions, poller SWEEPING in the new container."
    else
      st=failed
      detail="rebuild-devbox '$wl' PARTIAL — killed ${oldid:0:12}→${newid:0:12}, but resumed only $ok/$total sessions${failed_names:+ (idle/failed:$failed_names)}, poller=$poller. Surfacing rather than claiming restored (R17); box is up on the new image."
    fi
    printf '%s|%s\n' "$st" "$detail" > "$acted"; respond "$repo" "$issue" "$st" "$detail"; return
  fi

  # (2) FRESH → AUTHORIZE (destructive) + validate the manifest + capture the old ID + FIRE the rebuild.
  local author; author="$(gh issue view "$issue" --repo "$ORG/$REPO" --json author -q '.author.login' 2>/dev/null || echo '')"
  if ! is_authorized_author "$author"; then
    respond "$repo" "$issue" failed "rebuild-devbox REFUSED — issue author '${author:-?}' lacks admin|maintain on $ORG/$REPO; a verb that kills the dev box + its active sessions needs a maintainer, not the host-task label alone."
    return
  fi
  local manifest rc
  manifest="$(printf '%s' "$TICKET_BODY" | parse_manifest)"; rc=$?
  if [ "$rc" != 0 ]; then
    respond "$repo" "$issue" failed "rebuild-devbox REFUSED — $( [ "$rc" = 3 ] && echo "no session manifest found" || echo "malformed session manifest" ): expected \`session <name> <cwd>\` lines between $MANIFEST_BEGIN and $MANIFEST_END (names [A-Za-z0-9._-], cwd an absolute path with no spaces/metacharacters, ≤$DEVBOX_MAX_SESSIONS sessions)."
    return
  fi
  local oldid; oldid="$(podman container inspect "$wl" -f '{{.Id}}' 2>/dev/null || echo '')"
  { printf '%s\n' "$oldid"; printf '%s\n' "$manifest"; } > "$rb"     # marker: line1=oldID, rest=validated manifest
  systemctl --user reset-failed "workload-rebuild@${wl}.service" 2>/dev/null || true
  if systemctl --user start --no-block "workload-rebuild@${wl}.service" 2>/dev/null; then
    log "$ORG/$repo#$issue: rebuild-devbox FIRED for $wl (old ${oldid:0:12}); FORCE health-gated rebuild running — restore/resume/verify on completion."
  else
    st=failed; detail="rebuild-devbox '$wl': could not start workload-rebuild@${wl} — unit missing? Box left untouched."
    rm -f "$rb"; printf '%s|%s\n' "$st" "$detail" > "$acted"; respond "$repo" "$issue" "$st" "$detail"
  fi
}

dispatch(){ # <repo> <issue> <verb> <args...>
  local repo="$1" issue="$2" verb="$3"; shift 3
  case "$verb" in
    redeploy)       [ -n "${1:-}" ] && do_redeploy "$repo" "$issue" "$1" \
                       || respond "$repo" "$issue" failed "redeploy needs a workload name (host-op: redeploy <workload>)";;
    rebuild-devbox) [ -n "${1:-}" ] && do_rebuild_devbox "$repo" "$issue" "$1" \
                       || respond "$repo" "$issue" failed "rebuild-devbox needs a dev-box name (host-op: rebuild-devbox <devbox>)";;
    ""|*)           respond "$repo" "$issue" failed "unsupported or empty host-op '$verb' — allowed verbs: redeploy <workload>, rebuild-devbox <devbox>";;
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
  TICKET_BODY="$body"   # rebuild-devbox reads its session MANIFEST from the body (parse_manifest); other verbs ignore it
  # shellcheck disable=SC2086
  dispatch "$REPO" "$issue" $op
done
