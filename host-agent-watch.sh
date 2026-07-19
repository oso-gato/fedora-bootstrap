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
#     ghost) → RESTORE + RESUME every manifest session (tmux at its cwd + the validated resume cmd:
#     the host-fixed default, or the manifest's strict-UUID sid resumed by id — never eval'd) →
#     VERIFY the entrypoint-supervised poller is OBSERVABLY sweeping → REPORT killed/restored/resumed/
#     could-not. Fail-safe: any unverified kill, unhealthy rebuild, idle-not-resuming session, or
#     silent poller SURFACES as FAILED (silence never means restored). Because it kills active sessions,
#     it is AUTHOR-GATED (below), unlike the reversible `redeploy`.
#
# DESTRUCTIVE-VERB AUTHORIZATION (host-agent header's own standing requirement; R16 scope law): the
#   `host-task` label is NOT sufficient authorization for a verb that destroys running work. `redeploy`
#   is reversible/bounded (label-authorized). `rebuild-devbox` requires a MAINTAINER'S EXPLICIT ACT, in
#   EITHER of two equivalent forms (the R17 APPROVAL GATE, maintainer-confirmed 2026-07-19):
#     (a) the ISSUE AUTHOR holds admin|maintain (is_authorized_author — authorship IS approval; the
#         original path, unchanged), OR
#     (b) a MAINTAINER has APPLIED the `approved` LABEL to the ticket (approved_by_maintainer) — the
#         ONE-TAP path: the APPARATUS files the ticket (manifest + all), the human authorizes with a
#         single label tap on mobile. TIMELINE-BOUND, never presence-bound (the fleet-halt applier
#         discipline): the label's own labeled/unlabeled events are walked NEWEST-FIRST and the first
#         event whose actor is role-checked admin|maintain decides — an App identity or mere label
#         presence authorizes NOTHING, and an unresolvable actor is fail-closed NOT-approved.
#   A bot-authored ticket with NEITHER is PENDING, not refused: left OPEN + UNCONSUMED (no .done), one
#   marker-gated "awaiting approval" comment posted, re-checked every tick — the tap can come anytime.
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
# PARSED as bounded DATA (parse_manifest), never executed. Each line: `session <name> <cwd> [<sid>]`
# — the optional 4th field is a claude-code session-id (fedora-dev D4/#191): PRESENT ⇒ resume THAT
# session by id (`claude --resume <sid>`); ABSENT ⇒ the cwd-scoped `claude --continue` (v1, still
# accepted, so an old producer keeps working). By-id resume is what makes MULTI-TENANT restore correct:
# N sessions can share one cwd, which `--continue` (most-recent-in-cwd) cannot disambiguate. The sid is
# validated as DATA (UUID grammar) and only ever passed as LITERAL argv/keystrokes to tmux, never eval'd.
MANIFEST_BEGIN='%%DEVBOX-MANIFEST-BEGIN%%'
MANIFEST_END='%%DEVBOX-MANIFEST-END%%'
DEVBOX_MAX_SESSIONS="${DEVBOX_MAX_SESSIONS:-32}"
# Container-facing incantations = the R17 CONTRACT that fedora-dev#174 fulfils (host-fixed — the
# manifest NEVER supplies executable content). Overridable so the host operator / dev side can tune
# them (poller unit name, resume verb) without touching this control logic.
DEVBOX_RESUME_CMD="${DEVBOX_RESUME_CMD:-claude --continue}"     # typed into each restored session (in its cwd)
DEVBOX_POLLER_UNIT="${DEVBOX_POLLER_UNIT:-poller.service}"      # entrypoint-supervised service to verify sweeping
DEVBOX_POLLER_WINDOW="${DEVBOX_POLLER_WINDOW:-120}"            # s: "sweeping" = the poller LOGGED within this recent lookback (a PID is not enough)
DEVBOX_POLLER_READY_WINDOW="${DEVBOX_POLLER_READY_WINDOW:-600}" # s: ACROSS-TICKS deadline for the poller to become observably sweeping after the sessions are restored. A COLD poller-service must wait .assembled + the credential + a self-refresh reload before its FIRST sweep — which outlasts a single tick — so we DEFER (the box_ready discipline), not false-FAIL (2026-07-19 live rebuild verdicted a false PARTIAL 'poller=down' while the poller came up seconds later)
DEVBOX_RESUME_SETTLE="${DEVBOX_RESUME_SETTLE:-20}"            # s: a restored session's TUI settles this long before the first nudge
# --- RESUME-TO-ACTIVE (R17 option-b, 2026-07-17) — a resumed session must come up ACTIVELY CONTINUING its
#     prior task, not merely present. Empirically established (fedora-dev, tmux + the real claude TUI):
#       * `claude --resume <sid>` restores context but comes up IDLE-at-the-input — a positional prompt only
#         PRE-FILLS, it never submits. So "restored" genuinely != "working".
#       * SUBMITTING a nudge DOES make it continue — typed as literal text then a DISCRETE `send-keys Enter`
#         (a separate key event; an inline `\r` in one write is swallowed by the TUI's bracketed-paste).
#       * A live session's transcript does NOT flush to disk within minutes, so transcript growth is NOT a
#         usable liveness signal; the reliable in-tick proof is a FILESYSTEM HANDSHAKE (below).
#     So the executor (1) waits for the freshly-rebuilt box to actually be able to run claude before launching
#     — else the launch falls back to a bare shell (the 0/N-idle race that resumed 0/2 on the first real
#     rebuild), and (2) submits a nudge that asks the session to TOUCH a per-sid marker as its first act, then
#     polls that marker (same home volume, base-visible) to CONFIRM the session received+submitted+executed —
#     genuine progress, not just a process being up. %MARKER% is substituted per session; the manifest never
#     supplies executable content (the nudge is host-fixed).
DEVBOX_RESUME_MARKER_DIR="${DEVBOX_RESUME_MARKER_DIR:-/home/core/.local/state/rebuild-resumed}"   # per-sid liveness markers the resumed session touches
DEVBOX_RESUME_NUDGE="${DEVBOX_RESUME_NUDGE:-[auto-resume] Your dev box was rebuilt and this session was restored. FIRST, acknowledge you are active by running exactly:  touch %MARKER%  — then review your recent messages and CONTINUE the task you were working on, exactly where you left off.}"
DEVBOX_BOX_READY_WINDOW="${DEVBOX_BOX_READY_WINDOW:-900}"   # s: DEADLINE for the fresh box's claudebox to become assembled+enterable (checked ACROSS ticks, not blocked in one) before we give up
DEVBOX_WORK_WINDOW="${DEVBOX_WORK_WINDOW:-120}"            # s: after nudging, a session must touch its marker within this to count ACTIVELY WORKING
DEVBOX_NUDGE_TRIES="${DEVBOX_NUDGE_TRIES:-5}"             # (re)submit the nudge up to this many times across the work window (TUI-readiness timing)
DEVBOX_WORK_POLL="${DEVBOX_WORK_POLL:-5}"                 # s: marker-poll interval within the work window (lowered by the dry-run test)
DEVBOX_ASSEMBLED_MARKER="${DEVBOX_ASSEMBLED_MARKER:-/home/core/.local/state/claudebox/.assembled}"          # box-ready signal the `claude` wrapper itself gates on
DEVBOX_ASSEMBLE_FAILED_MARKER="${DEVBOX_ASSEMBLE_FAILED_MARKER:-/home/core/.local/state/claudebox/.assemble-failed}"  # a half-assembled box (overrides a stale .assembled)
DEVBOX_BOX_NAME="${DEVBOX_BOX_NAME:-claudebox}"           # the in-container distrobox `claude` runs inside (for the enterable probe)
DEVBOX_APPROVER_MENTION="${DEVBOX_APPROVER_MENTION:-@oso-gato}"   # @mentioned on the awaiting-approval comment (mobile push); the AUTHORIZATION is role-checked, never this string
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
      if ($1 != "session" || (NF != 3 && NF != 4))           { rc=2; exit }   # session <name> <cwd> [<sid>]
      if ($2 !~ /^[A-Za-z0-9._-]+$/ || length($2) > 64)      { rc=2; exit }   # session name allowlist
      if ($3 !~ /^\/[A-Za-z0-9._\/@%+-]*$/ || length($3) > 256) { rc=2; exit }   # absolute path, no spaces/metacharacters
      if (NF == 4 && $4 !~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) { rc=2; exit }   # optional session-id: a real UUID (fixed-width 8-4-4-4-12 hex; exactly what --session-id requires). Strict-UUID also RE-CLOSES the space-in-cwd hole: a fumbled `cwd with-a-space` splits to a 4th field that is not a UUID ⇒ rejected.
      if (++n > MAX)                                         { rc=2; exit }
      if (NF == 4) printf "%s\t%s\t%s\n", $2, $3, $4         # v2: name<TAB>cwd<TAB>sid (resume by id)
      else         printf "%s\t%s\n",     $2, $3             # v1: name<TAB>cwd (cwd-scoped --continue)
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

# approval_fold: PURE core of the R17 approval gate — rows "event<TAB>maint" NEWEST-FIRST (event ∈
# labeled|unlabeled for the `approved` label; maint ∈ 1 = actor role-checked admin|maintain, 0 =
# confirmed non-maintainer/App, U = role could not be resolved) → APPROVED|NO on stdout. The FIRST
# maintainer event decides (labeled ⇒ APPROVED, unlabeled ⇒ NO — a maintainer REMOVING the label is an
# un-approval); a non-maintainer/App event is INERT both directions (label presence proves nothing —
# every fleet App holds the triage needed to add a label); an UNRESOLVABLE actor is fail-closed NO
# outright (it might be a maintainer's un-approval; a DESTRUCTIVE verb never guesses past it — the
# pending state re-checks next tick, so a transient API blip costs seconds, never correctness).
# Defined ABOVE the selftest gate (pure, no deps) so --selftest can exercise it.
approval_fold(){
  local event maint
  while IFS=$'\t' read -r event maint; do
    [ -n "$event" ] || continue
    case "$maint" in
      1) [ "$event" = labeled ] && echo APPROVED || echo NO; return 0;;
      U) echo NO; return 0;;
      *) : ;;                       # inert: keep walking to the next-older event
    esac
  done
  echo NO; return 0                 # no maintainer event at all (incl. zero rows) ⇒ not approved
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
  # v2 optional session-id (D4/#191): a valid UUID ⇒ 3rd out-field; absent ⇒ 2 fields (v1); non-UUID/extra ⇒ reject
  cm "with sid"     $'%%DEVBOX-MANIFEST-BEGIN%%\nsession main /home/core 0deceee8-34ab-4e41-be19-ba4210469eb6\n%%DEVBOX-MANIFEST-END%%' $'main\t/home/core\t0deceee8-34ab-4e41-be19-ba4210469eb6' 0
  cm "sid + no-sid" $'%%DEVBOX-MANIFEST-BEGIN%%\nsession a /r/a 11111111-2222-3333-4444-555555555555\nsession b /r/b\n%%DEVBOX-MANIFEST-END%%' $'a\t/r/a\t11111111-2222-3333-4444-555555555555\nb\t/r/b' 0
  cm "sid not uuid" $'%%DEVBOX-MANIFEST-BEGIN%%\nsession a /r/a not-a-uuid\n%%DEVBOX-MANIFEST-END%%'                      ''                         2
  cm "bad sid meta" $'%%DEVBOX-MANIFEST-BEGIN%%\nsession a /r/a bad;rm\n%%DEVBOX-MANIFEST-END%%'                          ''                         2
  cm "five fields"  $'%%DEVBOX-MANIFEST-BEGIN%%\nsession a /r/a 0deceee8-34ab-4e41-be19-ba4210469eb6 extra\n%%DEVBOX-MANIFEST-END%%' ''             2
  cm "loose uuid"   $'%%DEVBOX-MANIFEST-BEGIN%%\nsession a /r/a 123456789-abc-4444-5555-123456789012\n%%DEVBOX-MANIFEST-END%%'        ''             2   # length-36, 5 hex groups, but NOT 8-4-4-4-12 ⇒ the fixed-width regex REJECTS (the old loose `+`-group regex wrongly accepted it)
  # kill_verified: <desc> <oldid> <newid> <gone|alive> <expected verdict>
  ckv(){ local g; g="$(kill_verified "$2" "$3" "$4")"; [ "$g" = "$5" ] && echo "ok: kv $1" || { echo "FAIL: kv $1 — got '$g' want '$5'"; f=1; }; }
  ckv "clean kill"  AAAA BBBB gone  ok
  ckv "ghost"       AAAA BBBB alive GHOST
  ckv "no new"      AAAA ''   gone  NONEW
  ckv "same id"     AAAA AAAA gone  SAMEID
  is_rebuildable_workload fedora-dev     && echo "ok: fedora-dev rebuildable"          || { echo "FAIL: fedora-dev not rebuildable"; f=1; }
  is_rebuildable_workload fedora-desktop && { echo "FAIL: desktop rebuildable"; f=1; } || echo "ok: desktop NOT rebuildable (narrow allowlist)"
  # ---- approval_fold (R17 approval gate, pure) — rows NEWEST-FIRST "event<TAB>maint" → APPROVED|NO ----
  caf(){ local g; g="$(printf '%b' "$2" | approval_fold)"; [ "$g" = "$3" ] && echo "ok: af $1" || { echo "FAIL: af $1 — got '$g' want '$3'"; f=1; }; }
  caf "maintainer labeled"            'labeled\t1\n'                             APPROVED
  caf "maintainer UN-labeled newest"  'unlabeled\t1\nlabeled\t1\n'               NO         # un-approval wins over an older approval
  caf "app labeled only"              'labeled\t0\n'                             NO         # label presence proves nothing
  caf "app noise over maint approval" 'labeled\t0\nunlabeled\t0\nlabeled\t1\n'   APPROVED   # App events inert; the maintainer's decides
  caf "unresolvable newest"           'labeled\tU\nlabeled\t1\n'                 NO         # fail-closed: never guess past a U
  caf "no events"                     ''                                          NO
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

# approved_by_maintainer: has a MAINTAINER applied the `approved` label to <issue>? Resolves the label's
# own timeline events (oldest-first from the API → reversed to newest-first), role-checks each actor
# (`.role_name` — `.permission` collapses maintain→"write"; a 200 answer maps role → 1/0; ANY failed
# lookup ⇒ U — `gh api` exits rc≠0 on a 404 and on a rate-limit/5xx alike, and this function does NOT
# tell them apart), and folds via approval_fold. FAIL-CLOSED: an unreadable timeline ⇒ NOT approved.
approved_by_maintainer(){ # <issue>
  local issue="$1" rows out='' event actor role m
  rows="$(gh api "repos/$ORG/$REPO/issues/$issue/timeline" --paginate \
          -q '.[] | select((.event=="labeled" or .event=="unlabeled") and .label.name=="approved") | "\(.event)\t\(.actor.login)"' 2>/dev/null)" \
    || return 1
  [ -n "$rows" ] || return 1
  local line
  while IFS=$'\t' read -r event actor; do
    [ -n "$event" ] && [ -n "$actor" ] || continue
    if role="$(gh api "repos/$ORG/$REPO/collaborators/$actor/permission" -q '.role_name // .permission' 2>/dev/null)"; then
      # App/bot actors answer 200 + role_name:"" (empirically pinned by fleet-halt.sh), so they resolve
      # DEFINITIVELY to m=0 (inert). NB: a non-collaborator login (e.g. a departed one) 404s, and
      # `gh api` exits rc≠0 on that just like on a rate-limit/5xx — so a 404 lands in the U branch
      # below, NOT here (unlike fleet-halt.sh's 3-way check, which parses stderr for HTTP 404).
      case "$role" in admin|maintain) m=1;; *) m=0;; esac
    else
      # unresolvable actor ⇒ U: fail-closed (approval_fold answers NO outright, the strictest read —
      # it MIGHT be a maintainer's un-approval). A transient blip costs one tick (the pending state
      # re-checks); a PERSISTENT failure — e.g. a departed collaborator's old event 404ing — answers
      # NO even over an older maintainer approval, and recovery is a maintainer RE-TAP: their fresh
      # label event becomes newest and decides.
      m=U
    fi
    printf -v line '%s\t%s' "$event" "$m"
    out+="$line"$'\n'
  done <<< "$rows"
  [ "$(printf '%s' "$out" | tac | approval_fold)" = APPROVED ]
}

# REACH BACK IN: podman exec into the FRESH container as the fleet uid (mirrors claudebox-busy-probe).
pexec(){ podman exec --user 1000:1000 "$@"; }

# restore_session: recreate ONE tmux session at its recorded cwd inside the fresh box, then RESUME it by
# typing the validated resume command — the host-fixed DEVBOX_RESUME_CMD default, or, when the manifest
# carried a session-id, the strict-UUID `claude --resume <sid>` (parse_manifest-validated, literal-only,
# never eval'd — see below). Idempotent (drops a stale same-name
# session first). rc 0 = created + resume dispatched; 1 = could-not (surfaces, never a silent success).
# $1 is the VERIFIED CONTAINER ID (never the name — the reused name is what hid the ghost; R17 req 6).
restore_session(){ # <cid> <name> <cwd> [<sid>]
  local cid="$1" name="$2" cwd="$3" sid="${4:-}"
  # RESUME COMMAND: by-id when the manifest carried a sid (multi-tenant; resumes THAT session even when
  # sessions share a cwd), else the host-fixed cwd-scoped default. The sid is parse_manifest-validated
  # to a strict UUID (hex-only, 8-4-4-4-12) so it is safe as a literal send-keys keystroke — never eval'd.
  local resume_cmd; if [ -n "$sid" ]; then resume_cmd="claude --resume $sid"; else resume_cmd="$DEVBOX_RESUME_CMD"; fi
  pexec "$cid" test -d "$cwd" 2>/dev/null || { log "restore: cwd '$cwd' absent in $cid — cannot restore '$name'"; return 1; }
  pexec "$cid" tmux kill-session -t "$name" >/dev/null 2>&1 || true
  pexec "$cid" tmux new-session -d -s "$name" -c "$cwd" >/dev/null 2>&1 \
    || { log "restore: tmux new-session '$name' failed in $cid"; return 1; }
  pexec "$cid" tmux send-keys -t "$name" "$resume_cmd" Enter >/dev/null 2>&1 \
    || { log "restore: resume send-keys '$name' failed in $cid"; return 1; }
  return 0
}

# box_ready: is the fresh container's in-container claudebox ASSEMBLED + ENTERABLE right now? A just-recreated
# dev box first-boot ASSEMBLES its claudebox (distrobox assemble — MINUTES); type `claude` before that
# finishes and the wrapper diverts to `claudebox-rebuild --watch-only` / tails-or-runs the assemble — never a
# running claude, so the pane falls back to a BARE SHELL and every session reads IDLE (the 0/N-idle race that
# made the first real rebuild resume 0/2). SINGLE-SHOT by design: the decoupled state machine re-checks it
# ACROSS ticks (the do_rebuild_devbox FINISH phase returns-until-ready), so a minutes-long assemble never
# blocks one 300s-capped tick. Ready = `.assembled` present, `.assemble-failed` absent (a half-assembled box
# overrides a stale marker), and the box actually enterable (a bounded `distrobox enter -- true`, the
# entrypoint's own box_ready idiom). $1 = VERIFIED CONTAINER ID. rc 0 = ready.
box_ready(){ # <cid>
  local cid="$1"
  pexec "$cid" test -e "$DEVBOX_ASSEMBLED_MARKER" 2>/dev/null \
    && ! pexec "$cid" test -e "$DEVBOX_ASSEMBLE_FAILED_MARKER" 2>/dev/null \
    && pexec "$cid" timeout 15 distrobox enter "$DEVBOX_BOX_NAME" -- true >/dev/null 2>&1
}

# nudge_session: SUBMIT the auto-continue nudge into a resumed session's claude TUI so it picks its task back
# up. `-l` types the literal nudge (with %MARKER% resolved to this session's per-sid liveness marker), then a
# DISCRETE `send-keys Enter` submits it (a separate key event — an inline return is swallowed by the TUI's
# bracketed paste). Best-effort each call; the caller (re)submits across the work window for TUI-readiness
# timing. $1=cid $2=name $3=marker-path.
nudge_session(){ # <cid> <name> <marker>
  local cid="$1" name="$2" marker="$3" text="${DEVBOX_RESUME_NUDGE//%MARKER%/$3}"
  pexec "$cid" tmux send-keys -t "$name" -l "$text" >/dev/null 2>&1 || return 1
  pexec "$cid" tmux send-keys -t "$name" Enter >/dev/null 2>&1 || return 1
  return 0
}

# session_working: has the resumed session CONFIRMED it is actively continuing? The reliable in-tick proof is
# the FILESYSTEM HANDSHAKE — the nudge asked it to `touch` its per-sid marker as its first act; the marker
# lands on the shared home volume, visible to this base-level probe. Present ⇒ the session received, submitted
# AND executed the nudge (genuine progress). $1=cid $2=marker. rc 0 = confirmed working.
session_working(){ # <cid> <marker>
  pexec "$1" test -e "$2" 2>/dev/null
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

# poller_sweeping_now: is the entrypoint-supervised poller OBSERVABLY sweeping RIGHT NOW — the unit active
# AND it LOGGED a sweep within DEVBOX_POLLER_WINDOW (a PID is not enough; silence never means restored). A
# SINGLE-PASS check (no in-tick block) — patience lives ACROSS TICKS in poller_finish, bounded by
# DEVBOX_POLLER_READY_WINDOW, so the host-agent tick still returns in seconds (300s cap). $1 = VERIFIED
# CONTAINER ID (never the name — R17 req 6). rc 0 = observably sweeping.
poller_sweeping_now(){ # <cid>
  local cid="$1" n
  pexec "$cid" systemctl --user is-active --quiet "$DEVBOX_POLLER_UNIT" 2>/dev/null || return 1
  n="$(pexec "$cid" journalctl --user -u "$DEVBOX_POLLER_UNIT" --since "-${DEVBOX_POLLER_WINDOW}s" -q 2>/dev/null | wc -l)"
  [ "${n:-0}" -gt 0 ]
}

# poller_finish: the SHARED FINISH verdict. Verify the poller (single-pass), then EITHER deliver the outcome
# (writes .acted) OR — when every session is actively-continuing but the COLD poller has not been seen
# sweeping yet — DEFER across ticks up to DEVBOX_POLLER_READY_WINDOW (writes NO .acted, so the next tick
# re-checks via the .restored re-entry; no re-restore). The caller RETURNS after this in EVERY case: on a
# commit the next tick short-circuits at the .acted phase; on a defer it re-enters the poller-only path.
# args: repo issue wl acted rstd oldid newid ok total up failed_names
poller_finish(){
  local repo="$1" issue="$2" wl="$3" acted="$4" rstd="$5" oldid="$6" newid="$7" ok="$8" total="$9" up="${10}" failed_names="${11}"
  local st detail poller=down
  poller_sweeping_now "$newid" && poller=sweeping
  if [ "$ok" = "$total" ] && [ "$poller" = down ]; then
    local page; page=$(( $(date +%s 2>/dev/null || echo 0) - $(stat -c %Y "$rstd" 2>/dev/null || echo 0) ))
    if [ "$page" -le "$DEVBOX_POLLER_READY_WINDOW" ]; then
      log "$ORG/$repo#$issue: RESTORED $ok/$total actively-continuing; poller not observed sweeping yet (${page}s/${DEVBOX_POLLER_READY_WINDOW}s) — DEFER, re-checking next tick (no re-restore)"
      return
    fi
  fi
  if [ "$ok" = "$total" ] && [ "$poller" = sweeping ]; then
    st=done
    detail="rebuild-devbox '$wl' COMPLETE — KILLED old ${oldid:0:12} (zero survivors), rebuilt to ${newid:0:12} (health-gated), RESTORED + RESUMED + ACTIVELY CONTINUING $ok/$total sessions (handshake-confirmed), poller SWEEPING in the new container."
  else
    local upnote=''; [ "${up:-0}" -gt 0 ] && upnote=", claude-up-but-unconfirmed $up"
    local pnote=''; [ "$ok" = "$total" ] && [ "$poller" = down ] && pnote=" (poller never observed sweeping within ${DEVBOX_POLLER_READY_WINDOW}s)"
    st=failed
    detail="rebuild-devbox '$wl' PARTIAL — killed ${oldid:0:12}→${newid:0:12}; actively-continuing $ok/$total${upnote}${failed_names:+ (${failed_names# })}, poller=$poller${pnote}. Surfacing rather than claiming restored (R17); box is up on the new image."
  fi
  printf '%s|%s\n' "$st" "$detail" > "$acted"; respond "$repo" "$issue" "$st" "$detail"
}

# do_rebuild_devbox: a DECOUPLED two-phase state machine (a host-agent tick is meant to take SECONDS —
# host-agent-watch.service caps ExecStart at 300s — while a health-gated rebuild can take minutes, so we
# FIRE the rebuild --no-block and POLL it across ticks; a `.rebuild` marker guards re-firing so FORCE
# never loops). Phase FIRE: authorize + validate manifest + capture old container ID + start
# workload-rebuild@. Phase FINISH (marker present, unit done): KILL-verify by ID → RESTORE+RESUME every
# session → VERIFY the poller → record + deliver the outcome.
do_rebuild_devbox(){ # <repo> <issue> <workload>
  local repo="$1" issue="$2" wl="$3"
  local acted="$STATE/${1}-${2}.acted" rb="$STATE/${1}-${2}.rebuild" rstd="$STATE/${1}-${2}.restored" st detail
  is_rebuildable_workload "$wl" || { respond "$repo" "$issue" failed "rebuild-devbox refused: '$wl' is not a rebuildable dev box (allowed: $REBUILD_WORKLOADS)"; return; }

  # (0) outcome already recorded by a prior tick → re-DELIVER only, never re-act (the .acted contract).
  if [ -e "$acted" ] && IFS='|' read -r st detail < "$acted" && [ -n "$st" ]; then
    log "$ORG/$repo#$issue: rebuild-devbox outcome already recorded; re-delivering ($st)"
    respond "$repo" "$issue" "$st" "$detail"; return
  fi

  # (0b) sessions already RESTORED + tallied by a prior tick (the .restored marker) but no .acted yet ⇒ we
  # deferred waiting on the COLD poller. SKIP restore entirely (re-restoring would KILL the just-resumed
  # sessions) — only finish the poller verification, deferred across ticks up to DEVBOX_POLLER_READY_WINDOW.
  if [ -e "$rstd" ]; then
    local r_newid r_oldid r_ok r_total r_up r_failed
    IFS='|' read -r r_newid r_oldid r_ok r_total r_up r_failed < "$rstd"
    poller_finish "$repo" "$issue" "$wl" "$acted" "$rstd" "$r_oldid" "$r_newid" "$r_ok" "$r_total" "$r_up" "$r_failed"; return
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

    # BOX-READY GATE (resume-to-active): the recreated box first-boot ASSEMBLES its claudebox (minutes);
    # restoring before it can run claude is the 0/N-idle race (the launch falls back to a bare shell). Checked
    # SINGLE-SHOT and re-tried ACROSS ticks — RETURN (ticket + .rebuild marker stay) until ready, so no one
    # 300s tick blocks. Bounded by DEVBOX_BOX_READY_WINDOW measured from the marker's OWN mtime: a box that
    # NEVER assembles surfaces FAILED, it does not loop forever.
    if ! box_ready "$newid"; then
      local rbage; rbage=$(( $(date +%s 2>/dev/null || echo 0) - $(stat -c %Y "$rb" 2>/dev/null || echo 0) ))
      if [ "$rbage" -gt "$DEVBOX_BOX_READY_WINDOW" ]; then
        st=failed
        detail="rebuild-devbox '$wl': box recreated (${oldid:0:12}→${newid:0:12}) but its claudebox never became ready within ${DEVBOX_BOX_READY_WINDOW}s — NO sessions restored (they would fall back to idle shells). Re-file to retry."
        printf '%s|%s\n' "$st" "$detail" > "$acted"; respond "$repo" "$issue" "$st" "$detail"; return
      fi
      log "$ORG/$repo#$issue: box recreated (${newid:0:12}) but its claudebox not ready yet (${rbage}s elapsed) — will restore next tick"; return
    fi

    # RESTORE every manifest session (create tmux at its cwd + dispatch `claude --resume <sid>`), BY VERIFIED
    # CONTAINER ID ($newid — never the name; R17 req 6). Track name+sid packed as 'name:sid' (name is
    # [A-Za-z0-9._-] and the sid a UUID — neither holds ':', so the split is clean; empty sid ⇒ 'name:').
    # `set -f` is on, so word-splitting $created on spaces is safe.
    local total=0 ok=0 up=0 name cwd sid marker failed_names='' created=''
    pexec "$newid" mkdir -p "$DEVBOX_RESUME_MARKER_DIR" >/dev/null 2>&1 || true
    while IFS=$'\t' read -r name cwd sid; do
      [ -n "$name" ] || continue
      total=$((total+1))
      pexec "$newid" rm -f "$DEVBOX_RESUME_MARKER_DIR/${sid:-$name}" >/dev/null 2>&1 || true   # clear a stale handshake marker so it cannot false-confirm
      if restore_session "$newid" "$name" "$cwd" "$sid"; then created="$created $name:${sid:-}"; else failed_names="$failed_names $name(norestore)"; fi
    done <<< "$manifest"
    [ -n "$created" ] && sleep "$DEVBOX_RESUME_SETTLE"      # one bounded settle for ALL TUIs to come up before the first nudge

    # RESUME-TO-ACTIVE: SUBMIT the continue-nudge to each restored session and CONFIRM it actually resumed
    # working via the filesystem handshake (the per-sid marker it was asked to touch). Bounded + SHARED across
    # all sessions (ONE work window, not N×) so the FINISH tick stays under the 300s cap; (re)nudge up to
    # DEVBOX_NUDGE_TRIES times to cover TUI-readiness timing (a nudge to a not-yet-ready TUI is lost).
    local -A worked=()
    local poll="$DEVBOX_WORK_POLL"; [ "$poll" -ge 1 ] || poll=1
    local slice=$(( DEVBOX_WORK_WINDOW / DEVBOX_NUDGE_TRIES )); [ "$slice" -ge "$poll" ] || slice=$poll
    local t j entry
    for ((t=1; t<=DEVBOX_NUDGE_TRIES; t++)); do
      local remaining=0
      for entry in $created; do
        name="${entry%%:*}"; sid="${entry#*:}"; marker="$DEVBOX_RESUME_MARKER_DIR/${sid:-$name}"
        [ -n "${worked[$name]:-}" ] && continue
        remaining=1; nudge_session "$newid" "$name" "$marker"
      done
      [ "$remaining" = 0 ] && break
      for ((j=0; j<slice; j+=poll)); do
        sleep "$poll"
        local allworked=1
        for entry in $created; do
          name="${entry%%:*}"; sid="${entry#*:}"; marker="$DEVBOX_RESUME_MARKER_DIR/${sid:-$name}"
          [ -n "${worked[$name]:-}" ] && continue
          if session_working "$newid" "$marker"; then worked[$name]=1; else allworked=0; fi
        done
        [ "$allworked" = 1 ] && break 2
      done
    done

    # TALLY (honest, three-way): handshake-confirmed = ACTIVELY CONTINUING; of the rest, distinguish a
    # claude that is UP but did not confirm (resumed + nudged, activity unproven — NOT claimed working) from a
    # bare-shell IDLE failure (claude never launched). NFR: no silent degradation — each is named.
    for entry in $created; do
      name="${entry%%:*}"
      if [ -n "${worked[$name]:-}" ]; then ok=$((ok+1))
      elif session_active "$newid" "$name"; then up=$((up+1)); failed_names="$failed_names $name(up-unconfirmed)"
      else failed_names="$failed_names $name(idle)"; fi
    done

    # RECORD the tally so a deferred re-entry (0b) never re-RESTORES (which would kill the just-resumed
    # sessions), then FINISH: verify the poller and either deliver the verdict or DEFER across ticks while a
    # cold poller-service is still starting (poller_finish owns the DONE/PARTIAL/defer decision + delivery).
    printf '%s|%s|%s|%s|%s|%s\n' "$newid" "$oldid" "$ok" "$total" "$up" "$failed_names" > "$rstd"
    poller_finish "$repo" "$issue" "$wl" "$acted" "$rstd" "$oldid" "$newid" "$ok" "$total" "$up" "$failed_names"; return
  fi

  # (2) FRESH → AUTHORIZE (destructive) + validate the manifest + capture the old ID + FIRE the rebuild.
  # AUTHORIZE (R17 approval gate — see the DESTRUCTIVE-VERB AUTHORIZATION header): a maintainer's
  # explicit act, in either form. Neither ⇒ PENDING (open + unconsumed, re-checked every tick), so the
  # one-tap `approved` label can arrive any time later — never a refusal that consumes the ticket.
  local author; author="$(gh issue view "$issue" --repo "$ORG/$REPO" --json author -q '.author.login' 2>/dev/null || echo '')"
  if is_authorized_author "$author"; then
    :   # a maintainer AUTHORED the ticket — authorship IS approval (the original path, unchanged)
  elif approved_by_maintainer "$issue"; then
    log "$ORG/$repo#$issue: rebuild-devbox APPROVED via the \`approved\` label (applier role-checked admin|maintain) — proceeding"
  else
    # PENDING APPROVAL: no .done/.acted is written, so discovery re-dispatches here every tick until a
    # maintainer taps the label (or authors/closes). ONE marker-gated comment tells the human the tap.
    local pend="$STATE/${repo}-${issue}.approval-asked"
    if [ ! -e "$pend" ]; then
      gh issue comment "$issue" --repo "$ORG/$repo" --body "**host-agent: ⏳ AWAITING APPROVAL** — ${DEVBOX_APPROVER_MENTION} this \`rebuild-devbox $wl\` ticket was filed by the apparatus and needs a maintainer's ONE-TAP authorization: **apply the \`approved\` label to this issue**. It kills + rebuilds the dev box, then restores + resumes every manifest session. The applier is role-checked admin|maintain from the label's own timeline (an App-applied label is inert). The host re-checks every ~10s and fires the moment the label lands. To reject: close this issue." >/dev/null 2>&1 \
        && : > "$pend" \
        || log "$ORG/$repo#$issue: awaiting-approval comment failed to post (will retry next tick)"
    fi
    log "$ORG/$repo#$issue: rebuild-devbox PENDING maintainer approval (\`approved\` label or maintainer authorship) — ticket left open, re-checking each tick"
    return
  fi
  local manifest rc
  manifest="$(printf '%s' "$TICKET_BODY" | parse_manifest)"; rc=$?
  if [ "$rc" != 0 ]; then
    respond "$repo" "$issue" failed "rebuild-devbox REFUSED — $( [ "$rc" = 3 ] && echo "no session manifest found" || echo "malformed session manifest" ): expected \`session <name> <cwd> [<sid>]\` lines between $MANIFEST_BEGIN and $MANIFEST_END (names [A-Za-z0-9._-], cwd an absolute path with no spaces/metacharacters, optional session-id a UUID 8-4-4-4-12 hex, ≤$DEVBOX_MAX_SESSIONS sessions)."
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
