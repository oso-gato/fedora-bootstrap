#!/usr/bin/env bash
# fleet-halt.sh — the HOST-side R9 FLEET HALT reader (apparatus fedora-dev#135; mirrors the dev-side
# `bin/fleet-halt.sh` contract, fedora-dev#168). One job: at the TOP of a sweep, tell the caller whether
# the fleet-wide maintainer SOFT STOP is asserted, so every host sweeper (live-gate-watch.sh, and any
# future host watcher) can go OBSERVE-ONLY before it builds or posts anything.
#
# THE SIGNAL: a repo MAINTAINER (admin|maintain on the CONTROL repo) applies the `halt` label to the
# FLEET HALT CONTROL issue in the control repo ($FLEET_HALT_ORG/$FLEET_HALT_REPO, default
# oso-gato/fedora-bootstrap — discovered BY TITLE so Arthur maintains no number; live: #128). While it
# stands, every sweeper logs what it WOULD do and acts on nothing; removing the label resumes the loop
# next tick (no restart). In-flight work is not touched — this reader only gates NEW action.
#
# MAINTAINER-BOUND BOTH DIRECTIONS, from the label's OWN TIMELINE EVENTS — an App/bot identity can
# neither halt nor UN-halt the loop:
#   * We read the issue's `labeled`/`unlabeled` events for the `halt` label, newest-first, and the
#     MOST-RECENT event whose actor holds admin|maintain decides: labeled ⇒ HALTED, unlabeled ⇒ CLEAR.
#   * Non-maintainer/App events are INERT (skipped) — so an App applying `halt` does NOT halt the fleet,
#     and an App REMOVING a maintainer's `halt` does NOT un-halt it (the maintainer's label still stands).
#   * No maintainer label event at all ⇒ CLEAR.
#
# AN UNREADABLE SIGNAL IS NOT A HALT (fail direction INVERTED 2026-07-30 — ported from the dev side's
# fedora-dev#274 STEP 3, which made exactly this change on 2026-07-28 and left this half behind).
#   * The control issue ABSENT (a clean empty search) is a DEFINITE "no halt asserted" ⇒ CLEAR.
#   * An UNREADABLE signal (discovery/timeline API error, or a role check that GitHub could not answer
#     definitively) ⇒ CLEAR, logged, and logged LOUDLY past K CONSECUTIVE unreadable reads. It NEVER
#     escalates to a halt, and a clean read resets the streak — which now governs only how loudly the
#     read logs, never whether work proceeds. A 404 on the role check IS definitive ("not a
#     collaborator") ⇒ the event is inert, NOT unreadable — that keeps an App-applied label inert.
#   * What still HALTS is unchanged: a label READ, PRESENT, and applied by a MAINTAINER.
#
# WHY, MEASURED — and the numbers are the whole argument. On the DEV side this reader fired 935 halts
# of which ZERO were maintainer-thrown: 100% "the API returned garbage". They suppressed 338 concrete
# actions, and one of them BLOCKED THE TICKET THAT WOULD HAVE REPAIRED A SIX-DAY OUTAGE. Independently,
# the `halt` label on the control issue has NEVER been applied by anyone, all-time (0 timeline events,
# verified 2026-07-30) — so the protection fail-closed buys has not once been needed, while its cost is
# routine. Freezing the HOST is the worse half of that trade: the host is what REPAIRS an outage, so a
# GitHub blip was taking the repair engine offline at precisely the moment it was needed.
#
# THE REASONING THIS RETIRES: "a gate that cannot be read cannot be trusted to say go." That mistook
# this label for a safety gate. Merge safety is the two INDEPENDENT App-identity gates, and R9's hard
# stop is App-key REVOCATION — which needs no GitHub read to work. Failing this label open weakens
# neither. DISCLOSED RESIDUAL, stated at its full width: for the DURATION of any unreadable window, a
# standing halt is UNHONORED — not just a switch thrown for the first time, but one already standing
# that this read cannot see; the host keeps acting until a read succeeds. Accepted — key revocation is
# the stop that does not depend on a readable signal.
#
# NOT MEASURED HERE (stated rather than implied): the 935 figure is the DEV box's. The host's own
# false-halt count lives in host journald and was not read for this change. The two read the SAME
# GitHub API from the same network, so a comparable rate is a fair INFERENCE — not a measurement.
#
# OUTPUT — a single state word on stdout + exit code (the caller branches on the code):
#   CLEAR              exit 0   → proceed (act normally)
#   HALTED             exit 10  → observe-only (maintainer halt asserted)
# RETIRED: PAUSED (11) and HALTED-UNREADABLE (12) can no longer be produced. The tokens stay documented
# because the rc contract is what a caller binds to and these codes were part of it: a consumer still
# branching on them is INERT (this reader never emits them again), not wrong. The ONE deployed consumer
# is live-gate-watch.sh, and it branches on the EXIT CODE, never the token — treating EVERY non-zero rc
# (a missing reader's 127 included) as "no new action". So a MISSING or CRASHED reader remains
# fail-closed BY CONSTRUCTION: the reader itself decides, and one that cannot run at all still stops the
# sweep. That is the boundary this change deliberately does NOT move.
# A human-readable line goes to stderr (→ journald). `--selftest` unit-tests the pure decision core with
# no gh/network. Runs INSIDE claudebox (needs gh + its auth); invoked by a sweeper, not a unit of its own.
set -uo pipefail

ORG="${FLEET_HALT_ORG:-oso-gato}"
REPO="${FLEET_HALT_REPO:-fedora-bootstrap}"       # CONTROL repo the FLEET HALT CONTROL issue lives in
LABEL="${FLEET_HALT_LABEL:-halt}"
TITLE="${FLEET_HALT_TITLE:-FLEET HALT CONTROL}"    # discovery-by-title term (live: #128)
ISSUE="${FLEET_HALT_ISSUE:-}"                      # optional pin; empty = discover by title (preferred)
K="${FLEET_HALT_UNREADABLE_K:-3}"                  # consecutive unreadable reads before a DECLARED persistent halt
TAG="${FLEET_HALT_TAG:-default}"                   # per-caller counter namespace (a sweeper passes its own)
STATE="${FLEET_HALT_STATE:-$HOME/.local/state/fleet-halt}"
CFILE="$STATE/${TAG}.unreadable"                   # consecutive-unreadable counter (K-debounce)

log(){ echo "[fleet-halt] $*" >&2; }               # → journald when called from a sweeper unit

# ---- PURE decision core (unit-tested by --selftest; NO gh/network) --------------------------------
# decide_from_events: stdin is the halt-label events NEWEST-FIRST, one per line "event<TAB>maint" where
# maint ∈ {1 = actor is admin|maintain, 0 = confirmed non-maintainer/App, U = could not determine}.
# The most-recent MAINTAINER event decides; 0 is inert (skip to older); U (on a still-undecided event)
# is fail-closed UNREADABLE; exhausting all events with no maintainer ⇒ CLEAR.
decide_from_events(){
  local event maint
  # `|| [ -n "$event" ]` so a final line with no trailing newline is still processed.
  while IFS=$'\t' read -r event maint || [ -n "$event" ]; do
    case "$maint" in
      1) case "$event" in labeled) echo HALTED;; *) echo CLEAR;; esac; return 0;;
      0) continue;;                       # non-maintainer/App event — inert, look further back
      U) echo UNREADABLE; return 0;;      # cannot confirm this (more recent) actor — fail closed
    esac
  done
  echo CLEAR                              # no maintainer ever acted on the label ⇒ not halted
}

# ---- gh-backed helpers ----------------------------------------------------------------------------
# is_maintainer: does <login> hold admin|maintain on the CONTROL repo? Echoes YES|NO|UNREADABLE.
# Mirrors host-agent-watch.sh's is_authorized_author, but 3-WAY: a DEFINITIVE GitHub 404 (login is not a
# collaborator — e.g. an App/bot) is a real "NO" (keeps App-applied labels inert), while a transient /
# auth / rate-limit / 5xx error is UNREADABLE (fail-closed). `.role_name` is the fine-grained role
# (`.permission` collapses maintain→"write", so it can never match "maintain" — read role_name first).
is_maintainer(){ # <login>
  local login="$1" role err
  [ -n "$login" ] || { echo NO; return 0; }
  if role="$(gh api "repos/$ORG/$REPO/collaborators/$login/permission" -q '.role_name // .permission' 2>/dev/null)"; then
    case "$role" in admin|maintain) echo YES;; *) echo NO;; esac   # any 200 answer is definitive
    return 0
  fi
  # rc≠0 — distinguish a definitive 404 (NOT a collaborator ⇒ inert) from an unreadable error.
  err="$(gh api "repos/$ORG/$REPO/collaborators/$login/permission" 2>&1 >/dev/null)"
  case "$err" in
    *"HTTP 404"*) echo NO;;
    *)            echo UNREADABLE;;
  esac
}

declare -A MAINT_CACHE=()
maint_cached(){ # <login> — memoized is_maintainer (one API call per distinct actor)
  local login="$1"
  # A ghost/deleted actor whose timeline event carries a null `.actor.login` arrives here as an EMPTY
  # login. An empty associative-array subscript is a bash "bad array subscript" fatal — guard it BEFORE
  # the cache lookup and return the same definitive NO is_maintainer already gives an empty login, so the
  # event is treated as inert (a non-maintainer), never misclassified UNREADABLE by the crash.
  [ -n "$login" ] || { echo NO; return 0; }
  [ -n "${MAINT_CACHE[$login]+x}" ] || MAINT_CACHE["$login"]="$(is_maintainer "$login")"
  printf '%s' "${MAINT_CACHE[$login]}"
}

# read_halt_state: resolve the control issue, read its halt-label timeline, decide. Echoes the RAW read
# (CLEAR|HALTED|UNREADABLE) — the K-debounce is applied by main().
read_halt_state(){
  local num events ev login mv stream=''
  if [ -n "$ISSUE" ]; then
    num="$ISSUE"
  else
    num="$(gh issue list --repo "$ORG/$REPO" --state open --search "in:title \"$TITLE\"" \
             --json number -q '.[].number' 2>/dev/null | sort -n | head -n1)" \
      || { echo UNREADABLE; return 0; }
    [ -n "$num" ] || { echo CLEAR; return 0; }   # control issue ABSENT = definite "no halt asserted"
  fi
  events="$(gh api "repos/$ORG/$REPO/issues/$num/timeline" --paginate \
              -q '.[] | select((.event=="labeled" or .event=="unlabeled") and .label.name=="'"$LABEL"'") | [.event, .actor.login] | @tsv' 2>/dev/null)" \
    || { echo UNREADABLE; return 0; }
  [ -n "$events" ] || { echo CLEAR; return 0; }  # label never applied/removed by anyone ⇒ CLEAR
  # Build the NEWEST-FIRST "event<TAB>maint" stream (tac reverses the oldest→newest timeline), resolving
  # each distinct actor's maintainer status, then hand it to the pure decision core.
  while IFS=$'\t' read -r ev login; do
    [ -n "$ev" ] || continue
    case "$(maint_cached "$login")" in YES) mv=1;; NO) mv=0;; *) mv=U;; esac
    stream+="$ev"$'\t'"$mv"$'\n'
  done < <(printf '%s\n' "$events" | tac)
  printf '%s' "$stream" | decide_from_events
}

reset_counter(){ rm -f "$CFILE" 2>/dev/null || true; }
bump_counter(){ # increment + echo the new consecutive-unreadable count
  local n=0
  [ -f "$CFILE" ] && n="$(cat "$CFILE" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0;; esac
  n=$((n + 1)); printf '%s\n' "$n" > "$CFILE" 2>/dev/null || true
  printf '%s' "$n"
}

main(){
  mkdir -p "$STATE" 2>/dev/null || true
  local raw n; raw="$(read_halt_state)"
  case "$raw" in
    CLEAR)
      reset_counter; echo CLEAR; exit 0;;
    HALTED)
      reset_counter; echo HALTED
      log "FLEET HALT asserted by a maintainer on $ORG/$REPO ('$LABEL' label) — sweepers observe-only until removed"
      exit 10;;
    UNREADABLE)
      # AN UNREADABLE SIGNAL IS NOT A HALT. The counter survives, but it now governs only how LOUDLY
      # this reads — never whether work proceeds. Emitting the host's own proceed token (CLEAR) rather
      # than the dev side's (RUN) keeps this change to the fail DIRECTION alone. HONEST about what that
      # defers: the CLEAR→RUN rename is NEARLY FREE, not caller-risky — exactly ONE deployed consumer
      # reads this reader (live-gate-watch.sh), it branches on the EXIT CODE (`hrc != 0`), and the token
      # reaches only a log line. So the vocabulary alignment is deferred as SCOPE DISCIPLINE, not
      # because anything would break; it is a separate change, declared rather than smuggled in here.
      n="$(bump_counter)"
      echo CLEAR
      if [ "$n" -ge "$K" ]; then
        log "FLEET HALT signal UNREADABLE ${n}× (≥ K=$K consecutive) — this is NOT a halt; proceeding. Nobody has asserted a halt; the signal cannot be READ. If this persists, GitHub reachability is the fault to chase — not the loop."
      else
        log "FLEET HALT signal UNREADABLE ${n}× (< K=$K) — not a halt; proceeding"
      fi
      exit 0;;
    *)
      # An UNEXPECTED state is NOT the unreadable case: the reader returned something no branch above
      # recognises, which is a defect in this reader rather than a fact about GitHub. That stays
      # fail-closed — we do not know what it means, so we do not act on a guess.
      echo "$raw"
      log "FLEET HALT reader returned an unexpected state '$raw' — treating as observe-only (fail-closed; an unrecognised verdict is a reader defect, not an unreadable signal)"
      exit 10;;
  esac
}

# ---- selftest: exercise the pure decision core across every ordering/actor mix (no gh) -------------
if [ "${1:-}" = "--selftest" ]; then
  f=0
  d(){ local g; g="$(printf '%s' "$2" | decide_from_events)"; [ "$g" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 — got '$g' want '$3'"; f=1; }; }
  #  desc                                  newest-first "event<TAB>maint" stream                 want
  d "maintainer halt"                       $'labeled\t1'                                         HALTED
  d "maintainer unhalt"                     $'unlabeled\t1'                                       CLEAR
  d "App label alone is inert"              $'labeled\t0'                                         CLEAR
  d "App unlabel over maintainer halt"      $'unlabeled\t0\nlabeled\t1'                           HALTED
  d "maintainer unhalt is latest"           $'unlabeled\t1\nlabeled\t1'                           CLEAR
  d "maintainer relabel is latest"          $'labeled\t1\nunlabeled\t1'                           HALTED
  d "skip App events, older maint halt"     $'labeled\t0\nunlabeled\t0\nlabeled\t1'               HALTED
  d "newest actor unreadable ⇒ UNREADABLE"  $'labeled\tU\nlabeled\t1'                             UNREADABLE
  d "older unreadable never reached"        $'labeled\t1\nlabeled\tU'                             HALTED
  d "App newest, then unreadable ⇒ UNREAD"  $'unlabeled\t0\nlabeled\tU'                           UNREADABLE
  d "no events at all"                      ''                                                    CLEAR
  d "all App/non-maint events"              $'labeled\t0\nunlabeled\t0'                           CLEAR
  # bump/reset counter behaviour (pure file logic, no gh)
  STATE="$(mktemp -d)"; CFILE="$STATE/t.unreadable"
  n1="$(bump_counter)"; n2="$(bump_counter)"; reset_counter; n3="$(bump_counter)"
  { [ "$n1" = 1 ] && [ "$n2" = 2 ] && [ "$n3" = 1 ]; } && echo "ok: counter bump/reset (1,2,reset,1)" \
    || { echo "FAIL: counter — got $n1,$n2,reset,$n3 want 1,2,reset,1"; f=1; }
  rm -rf "$STATE"
  [ "$f" = 0 ] && echo "ALL FLEET-HALT SELFTESTS PASS" || echo "FLEET-HALT SELFTESTS FAILED"
  exit "$f"
fi

main "$@"
