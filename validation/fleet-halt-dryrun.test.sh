#!/usr/bin/env bash
# fleet-halt-dryrun.test.sh — MOCK end-to-end of the R9 FLEET HALT reader (fleet-halt.sh) and its
# integration into the host live-gate watcher (live-gate-watch.sh), with ZERO GitHub / host contact.
#
# The load-bearing safety of the halt gate is: (1) it reads the maintainer-bound `halt` label from the
# label's own TIMELINE EVENTS (App/non-maintainer events inert, both directions), (2) it FAILS CLOSED
# toward stopping (unreadable ⇒ observe-only; K consecutive ⇒ declared persistent halt) while a clean
# empty (issue absent) is CLEAR, and (3) live-gate-watch.sh acts on NOTHING while halted. We exercise all
# three by STUBBING `gh` on PATH: a fake control issue + timeline + collaborator-permission answers drive
# every branch, and stub live-gate-run.sh / throwaway-sweep.sh recorders prove the watcher builds/sweeps
# nothing under halt. Runs on a plain CI runner (no podman, no host engine, no network).
#
# The assertions BITE: every case runs its ck() in THIS shell (no ( ) subshell would swallow the pass/fail
# increment before the summary sees it), and a MUTATION-CHECK block injects a fail-open / App-active
# regression and requires the guarding case to FAIL — so an inert assertion can never ship green.
#
# Run:  bash validation/fleet-halt-dryrun.test.sh   → exit 0 = all cases pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FH="$HERE/../fleet-halt.sh"
WATCH="$HERE/../live-gate-watch.sh"
[ -f "$FH" ]    || { echo "FATAL: fleet-halt.sh not found at $FH"; exit 2; }
[ -f "$WATCH" ] || { echo "FATAL: live-gate-watch.sh not found at $WATCH"; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# ---- stub gh: a scenario-driven fake of ONLY the calls fleet-halt.sh / live-gate-watch.sh make. ----
# Scenario via env (exported by each case):
#   FAKE_ISSUE_NUM        number `gh issue list` returns (empty ⇒ control issue ABSENT ⇒ CLEAR)
#   FAKE_ISSUE_FAIL=1     make `gh issue list` error (rc≠0 ⇒ UNREADABLE)
#   FAKE_TIMELINE         halt-label events, one "event login" per line, OLDEST→NEWEST ('' ⇒ no events)
#   FAKE_TIMELINE_FAIL=1  make the timeline `gh api` error (rc≠0 ⇒ UNREADABLE)
#   FAKE_MAINTAINERS      space-list of logins that are admin|maintain (role 200 "admin")
#   FAKE_WRITERS          space-list of logins that are collaborators but NOT maintainer (role 200 "write")
#   FAKE_UNREADABLE       space-list of logins whose permission check errors WITHOUT an HTTP 404 (UNREADABLE)
#   (any other login ⇒ a definitive HTTP 404 ⇒ confirmed non-collaborator ⇒ inert)
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
in_list(){ local x w; x="$1"; shift; for w in $*; do [ "$w" = "$x" ] && return 0; done; return 1; }
case "${1:-} ${2:-}" in
  "issue list")
    [ "${FAKE_ISSUE_FAIL:-0}" = 1 ] && { echo "gh: server error (HTTP 502)" >&2; exit 1; }
    [ -n "${FAKE_ISSUE_NUM:-}" ] && echo "$FAKE_ISSUE_NUM"    # empty ⇒ prints nothing ⇒ CLEAR
    exit 0 ;;
  "search prs") echo "[]"; exit 0 ;;                          # live-gate-watch discovery: no open PRs
  "api "*|"api")
    url=""; for a in "$@"; do case "$a" in repos/*|/repos/*|search/*) url="$a";; esac; done
    case "$url" in
      *"/timeline")
        [ "${FAKE_TIMELINE_FAIL:-0}" = 1 ] && { echo "gh: server error (HTTP 500)" >&2; exit 1; }
        # emit the halt events as event<TAB>login (what `-q '... | @tsv'` would produce), oldest→newest
        [ -n "${FAKE_TIMELINE:-}" ] && while read -r ev lg; do [ -n "$ev" ] && printf '%s\t%s\n' "$ev" "$lg"; done <<< "$FAKE_TIMELINE"
        exit 0 ;;
      *"/collaborators/"*"/permission")
        login="${url#*/collaborators/}"; login="${login%/permission}"
        if in_list "$login" "${FAKE_MAINTAINERS:-}"; then echo admin; exit 0; fi
        if in_list "$login" "${FAKE_WRITERS:-}";     then echo write; exit 0; fi
        if in_list "$login" "${FAKE_UNREADABLE:-}";  then echo "gh: error connecting to api.github.com" >&2; exit 1; fi
        echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;        # not a collaborator ⇒ inert
      *) echo "[]"; exit 0 ;;                                 # search/issues fallback etc.
    esac ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/gh"

pass=0; fail=0
ck(){ [ "$1" = 1 ] && { pass=$((pass+1)); printf '  ok   %s\n' "$2"; } || { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$2" "$3"; }; }

# fh_case <desc> <expect_state> <expect_rc> [VAR=val ...]   (scenario env passed INLINE, not exported in a
# subshell — a subshell would trap ck()'s pass/fail increments and the summary would never see them, so the
# suite must call this in the PARENT shell; fresh HOME/state each call keeps cases independent.)
fh_case(){
  local desc="$1" exp_state="$2" exp_rc="$3"; shift 3
  local out rc home
  home="$ROOT/h$RANDOM$RANDOM"; mkdir -p "$home"
  out="$(HOME="$home" FLEET_HALT_STATE="$home/st" FLEET_HALT_TAG=t PATH="$BIN:$PATH" env "$@" bash "$FH" 2>/dev/null)"; rc=$?
  if [ "$out" = "$exp_state" ] && [ "$rc" = "$exp_rc" ]; then ck 1 "$desc"; else
    ck 0 "$desc" "got state='$out' rc=$rc — want state='$exp_state' rc=$exp_rc"; fi
}

echo "== fleet-halt.sh: timeline-driven halt state (maintainer-bound both directions; App inert) =="
fh_case "maintainer applied halt ⇒ HALTED" HALTED 10 \
  FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled arthur' FAKE_MAINTAINERS=arthur
fh_case "App applied halt (404) ⇒ inert ⇒ CLEAR" CLEAR 0 \
  FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled botapp' FAKE_MAINTAINERS=arthur
fh_case "App tries to UN-halt a maintainer halt ⇒ still HALTED" HALTED 10 \
  FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled arthur\nunlabeled botapp' FAKE_MAINTAINERS=arthur
fh_case "maintainer applied then removed ⇒ CLEAR" CLEAR 0 \
  FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled arthur\nunlabeled arthur' FAKE_MAINTAINERS=arthur
fh_case "write-role collaborator halt (not maintain) ⇒ inert ⇒ CLEAR" CLEAR 0 \
  FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled writer' FAKE_WRITERS=writer
fh_case "ghost/deleted actor (empty login) halt is inert ⇒ CLEAR" CLEAR 0 \
  FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled '
fh_case "no halt-label events at all ⇒ CLEAR" CLEAR 0 \
  FAKE_ISSUE_NUM=128 FAKE_TIMELINE=
fh_case "control issue ABSENT (empty search) ⇒ CLEAR" CLEAR 0 \
  FAKE_ISSUE_NUM=

echo "== fleet-halt.sh: AN UNREADABLE SIGNAL IS NOT A HALT (fail direction inverted 2026-07-30) =="
# These three rows are the INVERSION of what this file asserted before: each previously demanded PAUSED/11
# (freeze the host on a GitHub blip). Measured on the dev side: 935 such halts, ZERO maintainer-thrown,
# 338 actions suppressed, one of them blocking the repair of a six-day outage. The `halt` label has never
# been applied by anyone, all-time. So the frozen-on-noise behaviour was pure cost.
fh_case "discovery API error ⇒ CLEAR (not a halt)" CLEAR 0 \
  FAKE_ISSUE_FAIL=1
fh_case "timeline API error ⇒ CLEAR (not a halt)" CLEAR 0 \
  FAKE_ISSUE_NUM=128 FAKE_TIMELINE_FAIL=1
fh_case "role check UNREADABLE on the halt actor ⇒ CLEAR (not a halt, still not inert-by-accident)" CLEAR 0 \
  FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled flaky' FAKE_UNREADABLE=flaky

echo "-- what still HALTS, and what an UNRECOGNISED verdict does (the boundaries NOT moved) --"
fh_case "a MAINTAINER-applied label still HALTS" HALTED 10 \
  FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled arthur' FAKE_MAINTAINERS=arthur

echo "-- K-debounce now governs LOUDNESS ONLY: every read proceeds, the Kth says so loudly --"
# NOT a subshell — ck must increment pass/fail in the PARENT. One shared HOME/state so the counter carries
# across the five reads; env passed inline per read. STDERR is captured per read, because the counter's
# whole remaining job is the WORDING: if the loud line never appears, a persistent outage would proceed
# in silence, which is the one thing this must not do.
kh="$ROOT/kh"; mkdir -p "$kh"
kread(){ # <env…> → sets KS (state), KR (rc), KE (stderr)
  KE="$(HOME="$kh" FLEET_HALT_STATE="$kh/st" FLEET_HALT_TAG=k PATH="$BIN:$PATH" env "$@" bash "$FH" 2>&1 >/dev/null)"
  KS="$(HOME="$kh" FLEET_HALT_STATE="$kh/st" FLEET_HALT_TAG=k PATH="$BIN:$PATH" env "$@" bash "$FH" 2>/dev/null)"; KR=$?
}
# NB each kread runs the reader TWICE (once for stderr, once for stdout+rc), so the counter advances by 2.
# That is fine for a LOUDNESS assertion — we need only to cross K, never to land on it exactly.
kread FAKE_ISSUE_FAIL=1;  s1="$KS|$KR"; e1="$KE"
kread FAKE_ISSUE_FAIL=1;  s2="$KS|$KR"; e2="$KE"
kread FAKE_ISSUE_NUM='';  s4="$KS|$KR"                      # a CLEAR read must RESET the streak
kread FAKE_ISSUE_FAIL=1;  s5="$KS|$KR"; e5="$KE"
if [ "$s1" = "CLEAR|0" ] && [ "$s2" = "CLEAR|0" ] && [ "$s4" = "CLEAR|0" ] && [ "$s5" = "CLEAR|0" ]; then
  ck 1 "every unreadable read proceeds (CLEAR/0), before and after a clean read"
else
  ck 0 "unreadable reads must all proceed" "got $s1,$s2,$s4,$s5"
fi
if printf '%s' "$e1" | grep -q 'not a halt' && printf '%s' "$e2" | grep -q 'GitHub reachability'; then
  ck 1 "the Kth consecutive unreadable read escalates the LOG (never the verdict)"
else
  ck 0 "K-debounce loudness" "first='$e1' later='$e2'"
fi
if printf '%s' "$e5" | grep -q 'not a halt' && ! printf '%s' "$e5" | grep -q 'GitHub reachability'; then
  ck 1 "a clean read RESETS the streak — the next blip is quiet again"
else
  ck 0 "streak reset" "after-reset stderr='$e5'"
fi

echo "== MUTATION-CHECK: the safety assertions BITE — inject a regression, require the guard case to FAIL =="
# A suite that reports GREEN while its assertions fail is worse than none — the exact defect this file had
# (fh_case/K-debounce once ran in ( ) subshells whose ck() pass/fail increments never reached the summary,
# so breaking fail-closed still printed "0 failed"). #131 requires tests that BITE, mutation-checked. So we
# PROVE each safety property's assertion distinguishes correct from broken: build a mutant reader with that
# property inverted and require the case guarding it to MISMATCH the good answer. A mutant that still
# satisfies the assertion means the assertion is inert — and THIS check then fails loudly.
# mut_case <mutant-file> <desc> <good_state> <good_rc> [VAR=val ...]
mut_case(){
  local mut="$1" desc="$2" good_state="$3" good_rc="$4"; shift 4
  local out rc home
  home="$ROOT/m$RANDOM$RANDOM"; mkdir -p "$home"
  out="$(HOME="$home" FLEET_HALT_STATE="$home/st" FLEET_HALT_TAG=m PATH="$BIN:$PATH" env "$@" bash "$mut" 2>/dev/null)"; rc=$?
  if [ "$out" = "$good_state" ] && [ "$rc" = "$good_rc" ]; then
    ck 0 "$desc" "MUTANT still satisfied the assertion (it is INERT / does not bite): got '$out'/$rc"
  else
    ck 1 "$desc — mutant caught (got '$out'/$rc ≠ good '$good_state'/$good_rc)"
  fi
}
# MUT_FC — the FAIL-CLOSED regression, i.e. the behaviour this change REMOVES. The old suite mutated in
# the opposite direction (UNREADABLE ⇒ CLEAR) because fail-closed was then the property under guard; that
# mutant is now the REAL code, so it would be inert and must not survive as a row. The mutation that bites
# today is restoring the freeze: `echo CLEAR` on its own line exists ONLY in the UNREADABLE arm (the CLEAR
# arm's is `reset_counter; echo CLEAR; exit 0;;`), so this anchors precisely and nowhere else.
MUT_FC="$ROOT/mut-failclosed.sh"
sed 's/^      echo CLEAR$/      echo PAUSED/' "$FH" > "$MUT_FC"
[ "$(grep -c '^      echo PAUSED$' "$MUT_FC")" = 1 ] || ck 0 "MUT_FC anchor" "the fail-closed mutation did not apply exactly once — the row below would be vacuous"
MUT_APP="$ROOT/mut-appactive.sh"   # APP-ACTIVE regression: a non-maintainer/App event is no longer inert
sed 's/0) continue;;/0) case "$event" in labeled) echo HALTED;; *) echo CLEAR;; esac; return 0;;/' "$FH" > "$MUT_APP"
mut_case "$MUT_FC"  "proceed-on-unreadable bites: discovery-error mutant no longer CLEAR" CLEAR 0 \
  FAKE_ISSUE_FAIL=1
mut_case "$MUT_FC"  "proceed-on-unreadable bites: role-check-U mutant no longer CLEAR"    CLEAR 0 \
  FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled flaky' FAKE_UNREADABLE=flaky
mut_case "$MUT_APP" "App-inert bites: App-label mutant no longer CLEAR"          CLEAR  0 \
  FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled botapp' FAKE_MAINTAINERS=arthur

echo "== live-gate-watch.sh INTEGRATION: HALTED ⇒ sweeps/builds NOTHING; CLEAR ⇒ proceeds =="
# stub live-gate-run.sh + throwaway-sweep.sh as recorders inside a temp HOME so the watcher picks THEM
# (its $HOME/.local/bin lookup wins); fleet-halt.sh is NOT stubbed there, so the watcher uses the REAL
# reader against the stubbed gh — a true end-to-end integration.
wt_case(){ # <desc> <halt|clear> <expect_runner: yes|no> <expect_sweep: yes|no> <expect_substr>
  local desc="$1" mode="$2" exp_run="$3" exp_sweep="$4" want="$5"
  local home="$ROOT/w$RANDOM$RANDOM"; mkdir -p "$home/.local/bin"
  printf '#!/usr/bin/env bash\necho RAN >> "%s/runner.log"\n' "$home" > "$home/.local/bin/live-gate-run.sh"
  printf '#!/usr/bin/env bash\necho SWEPT >> "%s/sweep.log"\n'  "$home" > "$home/.local/bin/throwaway-sweep.sh"
  chmod +x "$home/.local/bin/live-gate-run.sh" "$home/.local/bin/throwaway-sweep.sh"
  local env_extra=()
  if [ "$mode" = halt ]; then env_extra=(FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled arthur' FAKE_MAINTAINERS=arthur)
  else                         env_extra=(FAKE_ISSUE_NUM='');  fi
  local out
  out="$(HOME="$home" FLEET_HALT_STATE="$home/st" PATH="$BIN:$PATH" env "${env_extra[@]}" bash "$WATCH" 2>&1)" || true
  local got_run=no got_sweep=no
  [ -s "$home/runner.log" ] && got_run=yes
  [ -s "$home/sweep.log" ]  && got_sweep=yes
  local ok=1 why=''
  [ "$got_run" = "$exp_run" ]     || { ok=0; why="runner expected=$exp_run got=$got_run; "; }
  [ "$got_sweep" = "$exp_sweep" ] || { ok=0; why="$why""sweep expected=$exp_sweep got=$got_sweep; "; }
  printf '%s' "$out" | grep -qF "$want"     || { ok=0; why="$why""log missing '$want' (log: $(printf '%s' "$out" | tr '\n' ' '))"; }
  ck "$ok" "$desc" "$why"
}
wt_case "HALTED ⇒ runner NOT invoked, sweep NOT run, observe-only logged" halt  no  no  "OBSERVE-ONLY"
wt_case "CLEAR ⇒ proceeds (sweep runs), no PRs so runner NOT invoked"      clear no  yes "CLEAR — proceeding"

echo
echo "fleet-halt-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
