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

# fh_case <desc> <expect_state> <expect_rc>   (scenario env already exported; fresh state each call)
fh_case(){
  local desc="$1" exp_state="$2" exp_rc="$3" out rc home
  home="$ROOT/h$RANDOM$RANDOM"; mkdir -p "$home"
  out="$(HOME="$home" FLEET_HALT_STATE="$home/st" FLEET_HALT_TAG=t PATH="$BIN:$PATH" bash "$FH" 2>/dev/null)"; rc=$?
  if [ "$out" = "$exp_state" ] && [ "$rc" = "$exp_rc" ]; then ck 1 "$desc"; else
    ck 0 "$desc" "got state='$out' rc=$rc — want state='$exp_state' rc=$exp_rc"; fi
}

echo "== fleet-halt.sh: timeline-driven halt state (maintainer-bound both directions; App inert) =="
( export FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled arthur' FAKE_MAINTAINERS='arthur'
  fh_case "maintainer applied halt ⇒ HALTED" HALTED 10 )
( export FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled botapp' FAKE_MAINTAINERS='arthur'
  fh_case "App applied halt (404) ⇒ inert ⇒ CLEAR" CLEAR 0 )
( export FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled arthur\nunlabeled botapp' FAKE_MAINTAINERS='arthur'
  fh_case "App tries to UN-halt a maintainer halt ⇒ still HALTED" HALTED 10 )
( export FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled arthur\nunlabeled arthur' FAKE_MAINTAINERS='arthur'
  fh_case "maintainer applied then removed ⇒ CLEAR" CLEAR 0 )
( export FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled writer' FAKE_WRITERS='writer'
  fh_case "write-role collaborator halt (not maintain) ⇒ inert ⇒ CLEAR" CLEAR 0 )
( export FAKE_ISSUE_NUM=128 FAKE_TIMELINE=''
  fh_case "no halt-label events at all ⇒ CLEAR" CLEAR 0 )
( export FAKE_ISSUE_NUM=''
  fh_case "control issue ABSENT (empty search) ⇒ CLEAR" CLEAR 0 )

echo "== fleet-halt.sh: FAIL-CLOSED — unreadable pauses, K consecutive declares a persistent halt =="
( export FAKE_ISSUE_FAIL=1
  fh_case "discovery API error ⇒ PAUSED (transient)" PAUSED 11 )
( export FAKE_ISSUE_NUM=128 FAKE_TIMELINE_FAIL=1
  fh_case "timeline API error ⇒ PAUSED (transient)" PAUSED 11 )
( export FAKE_ISSUE_NUM=128 FAKE_TIMELINE=$'labeled flaky' FAKE_UNREADABLE='flaky'
  fh_case "role check UNREADABLE on the halt actor ⇒ PAUSED (fail-closed, not inert)" PAUSED 11 )

echo "-- K-debounce escalation: 3 consecutive unreadable reads on ONE counter ⇒ HALTED-UNREADABLE --"
( home="$ROOT/kh"; mkdir -p "$home"
  s1=$(HOME="$home" FLEET_HALT_STATE="$home/st" FLEET_HALT_TAG=k FAKE_ISSUE_FAIL=1 PATH="$BIN:$PATH" bash "$FH" 2>/dev/null); r1=$?
  s2=$(HOME="$home" FLEET_HALT_STATE="$home/st" FLEET_HALT_TAG=k FAKE_ISSUE_FAIL=1 PATH="$BIN:$PATH" bash "$FH" 2>/dev/null); r2=$?
  s3=$(HOME="$home" FLEET_HALT_STATE="$home/st" FLEET_HALT_TAG=k FAKE_ISSUE_FAIL=1 PATH="$BIN:$PATH" bash "$FH" 2>/dev/null); r3=$?
  # a CLEAR read must RESET the counter so a later blip starts over (not escalate immediately)
  s4=$(HOME="$home" FLEET_HALT_STATE="$home/st" FLEET_HALT_TAG=k FAKE_ISSUE_NUM='' PATH="$BIN:$PATH" bash "$FH" 2>/dev/null); r4=$?
  s5=$(HOME="$home" FLEET_HALT_STATE="$home/st" FLEET_HALT_TAG=k FAKE_ISSUE_FAIL=1 PATH="$BIN:$PATH" bash "$FH" 2>/dev/null); r5=$?
  if [ "$s1|$r1" = "PAUSED|11" ] && [ "$s2|$r2" = "PAUSED|11" ] && [ "$s3|$r3" = "HALTED-UNREADABLE|12" ] \
     && [ "$s4|$r4" = "CLEAR|0" ] && [ "$s5|$r5" = "PAUSED|11" ]; then
    ck 1 "PAUSED,PAUSED,HALTED-UNREADABLE then CLEAR resets → PAUSED"
  else
    ck 0 "K-debounce escalation+reset" "got $s1/$r1,$s2/$r2,$s3/$r3,$s4/$r4,$s5/$r5"
  fi )

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
