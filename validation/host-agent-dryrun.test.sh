#!/usr/bin/env bash
# host-agent-dryrun.test.sh — MOCK end-to-end dry-run of the host autonomous agent
# (host-agent-watch.sh) with ZERO host contact.
#
# This is the non-image repo's analogue of a live-gate's "does it actually run" probe. The host agent's
# load-bearing safety is its PARSE (line-1-only `host-op:`) + verb ALLOWLIST + DISPATCH routing. We
# exercise all three end-to-end by STUBBING `gh` and `systemctl` on PATH: a fake `host-task` issue is
# discovered, its body parsed, the verb allowlist enforced, and dispatch routed — while `systemctl` is
# a recorder that NEVER executes a unit, so NO real workload / systemd / GitHub is ever touched. It runs
# on a plain CI runner (no podman, no host engine).
#
# Run:  bash validation/host-agent-dryrun.test.sh   → exit 0 = all cases pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../host-agent-watch.sh"
[ -f "$WATCH" ] || { echo "FATAL: host-agent-watch.sh not found at $WATCH"; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# ---- stub gh: fabricate ONE open host-task issue, serve a per-case body, log every mutating call. ----
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# minimal gh stub — only the subcommands host-agent-watch.sh calls; never touches GitHub.
sub="${1:-} ${2:-}"
case "$sub" in
  "issue list") echo "${FAKE_ISSUE:-1}" ;;            # discovery → one fake issue number
  "issue view") printf '%s' "$FAKE_BODY" ;;           # body fetch → this case's body
  "issue comment"|"issue close"|"issue edit"|"label create")
                printf 'GH %s\n' "$*" >> "$GH_LOG" ;; # record delivery, do nothing
  *)            printf 'GH %s\n' "$*" >> "$GH_LOG" ;;
esac
exit 0
EOF

# ---- stub systemctl: RECORD the call, NEVER execute a unit. THIS is the "no real workload" guard. ----
# FAKE_START_RC lets a case make a `start` FAIL (with stderr, as the real one does) — the failure paths
# are exactly where the "say why" reporting lives, and they were previously never executed by any test.
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'SYSTEMCTL %s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
  *"show -p ExecMainStatus"*) echo "${FAKE_EXECMAIN:-0}" ;;  # emulate a clean refresh (mainstatus 0)
  *"is-active"*)              echo "${FAKE_ISACTIVE:-inactive}" ;;  # apply-bootstrap poll (host-apply.service)
  *start*) [ "${FAKE_START_RC:-0}" = 0 ] || {
             echo "Failed to start: Unit not found." >&2; exit "${FAKE_START_RC}"; } ;;
esac
exit 0
EOF

# ---- stub journalctl: serve a case-chosen unit log; RECORD which unit was asked for. ----
# The recording is load-bearing for one assertion: a failure report must carry the log of the unit that
# ACTUALLY failed, never a global captured on some other verb's path earlier in the same sweep.
cat > "$BIN/journalctl" <<'EOF'
#!/usr/bin/env bash
printf 'JOURNALCTL %s\n' "$*" >> "${JOURNAL_LOG:-/dev/null}"
[ "${FAKE_JOURNAL_RC:-0}" = 0 ] || exit "${FAKE_JOURNAL_RC}"
printf '%s\n' "${FAKE_JOURNAL:-}"
EOF
chmod +x "$BIN/gh" "$BIN/systemctl" "$BIN/journalctl"

pass=0; fail=0
run_case(){ # <desc> <fake-body> <expect-systemctl-start: yes|no> <expect-comment-substr>
  local desc="$1" body="$2" expect_start="$3" want="$4"
  local home="$ROOT/home-$RANDOM$RANDOM"; mkdir -p "$home"
  export HOME="$home"
  export GH_LOG="$home/gh.log";              : > "$GH_LOG"
  export SYSTEMCTL_LOG="$home/systemctl.log"; : > "$SYSTEMCTL_LOG"
  export FAKE_BODY="$body" FAKE_ISSUE=1 FAKE_EXECMAIN=0 FAKE_START_RC=0
  PATH="$BIN:$PATH" bash "$WATCH" >/dev/null 2>&1 || true
  local got_start=no
  grep -q 'SYSTEMCTL --user start workload-refresh@' "$SYSTEMCTL_LOG" && got_start=yes
  local ok=1
  [ "$got_start" = "$expect_start" ] || { ok=0; printf '  FAIL %s\n       systemctl-start expected=%s got=%s\n' "$desc" "$expect_start" "$got_start"; }
  grep -qF "$want" "$GH_LOG" || { ok=0; printf '  FAIL %s\n       comment missing: %s\n       gh.log: %s\n' "$desc" "$want" "$(tr '\n' ' ' < "$GH_LOG")"; }
  if [ "$ok" = 1 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$desc"; else fail=$((fail+1)); fi
}

echo "== dispatch routing: a KNOWN verb + KNOWN workload REACHES redeploy (stubbed — no real unit) =="
run_case "redeploy fedora-dev  → routes to workload-refresh@ (stub), reports DONE" \
  $'host-op: redeploy fedora-dev\nplease deploy the new image' yes 'host-agent: DONE'
run_case "redeploy fedora-desktop → routes, reports DONE" \
  $'host-op: redeploy fedora-desktop' yes 'host-agent: DONE'

echo "== allowlist: an UNKNOWN workload is REFUSED BEFORE any host mutation (systemctl NEVER called) =="
run_case "redeploy evil-repo → refused, no systemctl" \
  $'host-op: redeploy evil-repo' no 'unknown workload'
run_case "redeploy '*' (glob) → refused, no systemctl" \
  $'host-op: redeploy *' no 'unknown workload'

echo "== allowlist: an UNKNOWN or INCOMPLETE verb is REFUSED (systemctl NEVER called) =="
run_case "unknown verb 'nuke' → refused" \
  $'host-op: nuke everything now' no 'unsupported or empty host-op'
run_case "redeploy with no workload → refused" \
  $'host-op: redeploy' no 'redeploy needs a workload name'
run_case "host-op NOT on line 1 → refused (line-1-only parse)" \
  $'hello there\nhost-op: redeploy fedora-dev' no 'no valid'

echo "== apply-bootstrap (#133): DECOUPLED fire → poll → deliver (host-apply.service; stubbed) =="
# apply-bootstrap is long-running, so it FIRES --no-block then polls the unit across ticks. Drive two ticks
# over ONE persistent HOME (the .applyfired marker carries between them) and assert the box-side contract:
# tick 1 fires host-apply.service and delivers NOTHING (ticket stays open); tick 2 reads ExecMainStatus and
# delivers the mapped verdict. This exercises dispatch routing + the decoupled state machine end-to-end.
ahome="$ROOT/apply-home"; mkdir -p "$ahome"
ab_tick(){ # <isactive> <execmain>
  export HOME="$ahome" GH_LOG="$ahome/gh.log" SYSTEMCTL_LOG="$ahome/sc.log"
  export FAKE_BODY=$'host-op: apply-bootstrap\napply merged main' FAKE_ISSUE=1 FAKE_ISACTIVE="$1" FAKE_EXECMAIN="$2" FAKE_START_RC=0
  : > "$GH_LOG"; : > "$SYSTEMCTL_LOG"
  PATH="$BIN:$PATH" bash "$WATCH" >/dev/null 2>&1 || true
}
ab_check(){ # <desc> <cond:0/1> <detail>
  if [ "$2" = 0 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "$3"; fi
}
# tick 1: FRESH → fires the unit --no-block, NO delivery.
ab_tick activating 0
c=0
grep -q 'SYSTEMCTL --user start --no-block host-apply.service' "$ahome/sc.log" || { c=1; d1="no --no-block start of host-apply.service"; }
grep -q 'host-agent:' "$ahome/gh.log" && { c=1; d1="delivered a comment on the FIRE tick (should stay open)"; }
[ -e "$ahome/.local/state/host-agent/fedora-bootstrap-1.applyfired" ] || { c=1; d1="no .applyfired marker after firing"; }
ab_check "tick 1 fires host-apply.service --no-block, delivers nothing, marks .applyfired" "$c" "${d1:-}"
# tick 2: unit still activating → in-progress, still no delivery, no re-fire.
ab_tick activating 0
c=0
grep -q 'start --no-block host-apply.service' "$ahome/sc.log" && { c=1; d2="re-fired the unit while in progress (should only poll)"; }
grep -q 'host-agent:' "$ahome/gh.log" && { c=1; d2="delivered while still activating"; }
ab_check "tick 2 (still activating) polls only — no re-fire, no delivery" "$c" "${d2:-}"
# tick 3: unit terminal (inactive) + ExecMainStatus 0 → deliver DONE.
ab_tick inactive 0
grep -q 'host-agent: DONE' "$ahome/gh.log" && c=0 || { c=1; d3="no DONE on terminal+ExecMainStatus=0: $(tr '\n' ' ' <"$ahome/gh.log")"; }
ab_check "tick 3 (inactive, ExecMainStatus=0) delivers DONE" "$c" "${d3:-}"

echo "== apply-bootstrap verdict mapping: ExecMainStatus 3 (diverged) → FAILED 'REFUSED' =="
rhome="$ROOT/apply-refuse"; mkdir -p "$rhome/.local/state/host-agent"
: > "$rhome/.local/state/host-agent/fedora-bootstrap-1.applyfired"   # pretend already fired
export HOME="$rhome" GH_LOG="$rhome/gh.log" SYSTEMCTL_LOG="$rhome/sc.log"
export FAKE_BODY=$'host-op: apply-bootstrap' FAKE_ISSUE=1 FAKE_ISACTIVE=failed FAKE_EXECMAIN=3
: > "$GH_LOG"; : > "$SYSTEMCTL_LOG"
PATH="$BIN:$PATH" bash "$WATCH" >/dev/null 2>&1 || true
{ grep -q 'host-agent: FAILED' "$rhome/gh.log" && grep -qi 'REFUSED' "$rhome/gh.log"; } \
  && { pass=$((pass+1)); printf '  ok   ExecMainStatus=3 → FAILED REFUSED (diverged/dirty, a question)\n'; } \
  || { fail=$((fail+1)); printf '  FAIL ExecMainStatus=3 mapping\n       gh.log: %s\n' "$(tr '\n' ' ' <"$rhome/gh.log")"; }

echo "== SAY WHY: the FAILURE paths must DELIVER a verdict, carrying THEIR OWN unit's cause =="
# REGRESSION (2026-07-29). These paths compose the failure report, and no case had ever executed one —
# every case above takes a SUCCEEDING start. The first cut of "say why" read an unset global here:
# under `set -u` that ABORTS the tick before `.acted` is written and before the comment is posted, so
# the ticket gets NO verdict, no marker, and the next tick re-enters and dies identically — a
# permanently wedged bus, from the diagnostic meant to explain it. Assert what must survive a failure:
# the verdict is DELIVERED, it names the cause, the cause is THIS unit's, and the op is RECORDED.
whome="$ROOT/redeploy-fail"; mkdir -p "$whome"
export HOME="$whome" GH_LOG="$whome/gh.log" SYSTEMCTL_LOG="$whome/sc.log" JOURNAL_LOG="$whome/j.log"
export FAKE_BODY=$'host-op: redeploy fedora-dev' FAKE_ISSUE=1 FAKE_EXECMAIN=1 FAKE_START_RC=1
export FAKE_JOURNAL='verify.sh FAILED — cockpit.socket dead'
: > "$GH_LOG"; : > "$SYSTEMCTL_LOG"; : > "$JOURNAL_LOG"
PATH="$BIN:$PATH" bash "$WATCH" >/dev/null 2>&1 || true
c=0; d=''
grep -q 'host-agent: FAILED' "$GH_LOG" \
  || { c=1; d="NO verdict delivered at all (the pre-fix crash — tick aborted, ticket left silent)"; }
grep -qF 'verify.sh FAILED — cockpit.socket dead' "$GH_LOG" \
  || { c=1; d="${d:+$d; }verdict delivered WITHOUT the unit journal — the cause was discarded again"; }
grep -qF -- '-u workload-refresh@fedora-dev.service' "$JOURNAL_LOG" \
  || { c=1; d="${d:+$d; }read the wrong unit's journal: $(tr '\n' ' ' <"$JOURNAL_LOG")"; }
[ -e "$whome/.local/state/host-agent/fedora-bootstrap-1.acted" ] \
  || { c=1; d="${d:+$d; }no .acted marker — the op ran but was never recorded (a retry would re-act)"; }
ab_check "redeploy start FAILS → FAILED verdict DELIVERED + .acted, carrying workload-refresh@'s OWN log" "$c" "$d"

# apply-bootstrap's fire path is --no-block: a failure there means the unit never RAN, so its journal
# would be some PREVIOUS apply. The cause is systemctl's stderr — assert THAT is what is reported, and
# that no journal was consulted (a stale log presented as "the actual cause" is a false report).
nhome="$ROOT/apply-nostart"; mkdir -p "$nhome"
export HOME="$nhome" GH_LOG="$nhome/gh.log" SYSTEMCTL_LOG="$nhome/sc.log" JOURNAL_LOG="$nhome/j.log"
export FAKE_BODY=$'host-op: apply-bootstrap' FAKE_ISSUE=1 FAKE_ISACTIVE=inactive FAKE_EXECMAIN=0 FAKE_START_RC=1
: > "$GH_LOG"; : > "$SYSTEMCTL_LOG"; : > "$JOURNAL_LOG"
PATH="$BIN:$PATH" bash "$WATCH" >/dev/null 2>&1 || true
c=0; d=''
grep -qF 'could not start host-apply.service' "$GH_LOG" \
  || { c=1; d="no could-not-start verdict delivered: $(tr '\n' ' ' <"$GH_LOG")"; }
grep -qF 'Failed to start: Unit not found.' "$GH_LOG" \
  || { c=1; d="${d:+$d; }verdict delivered without systemctl's stderr — the actual cause"; }
[ -s "$JOURNAL_LOG" ] \
  && { c=1; d="${d:+$d; }consulted a journal for a unit that never ran (a PREVIOUS apply = a false cause)"; }
[ -e "$nhome/.local/state/host-agent/fedora-bootstrap-1.applyfired" ] \
  && { c=1; d="${d:+$d; }marked .applyfired despite the start failing (would poll forever)"; }
ab_check "apply-bootstrap start FAILS → verdict names systemctl's stderr, consults NO stale journal" "$c" "$d"

echo "== why_tail NAMES THE READ THAT FOUND THE CAUSE (not the tool) =="
# The point of trying four reads is knowing WHICH one saw the executor's output. The first cut used
# `$2` inside the helper — the first word of the COMMAND (literally `journalctl`), not the label — so
# all four candidates rendered identically and the feature was defeated exactly where it is
# load-bearing. 13/13 passed carrying that defect, because nothing asserted the label.
_wt_probe(){ # <marker-present:0|1> → the rendered report text
  ( unset -f grep
    eval "$(sed -n '/^why_tail()/,/^}/p' "$HERE/../host-agent-watch.sh")"
    why_block(){ printf '%s' "$1"; }
    systemctl(){ echo "INV123"; }
    journalctl(){
      case "$*" in
        *_SYSTEMD_INVOCATION_ID=INV123*)
          if [ "${MARK:-0}" = 1 ]; then echo "[host-apply] setup.sh apply FAILED"
          else echo "systemd[901]: Starting host-apply.service"; fi ;;
        *) echo "systemd[901]: bookend" ;;
      esac
    }
    MARK="$1" why_tail host-apply.service "host-apply log" "[host-apply]" )
}
_hit="$(_wt_probe 1)"; _miss="$(_wt_probe 0)"
c=0; d=''
case "$_hit" in *"user journal, this invocation"*) : ;; *) c=1; d="did not name its LABEL: [$_hit]";; esac
case "$_hit" in *journalctl*) c=1; d="${d:+$d; }named the TOOL (journalctl) instead of the read";; esac
ab_check "a marker-bearing read reports its LABEL, never the tool name" "$c" "$d"
c=0; d=''
case "$_miss" in *"no [host-apply] lines"*) : ;; *) c=1; d="markerless read did not say the marker was missing: [$_miss]";; esac
# …and says only what it CHECKED. The first cut asserted "systemd bookends only" — a claim about the
# BODY'S CONTENTS that nothing in the function ever reads. Absence of the marker is not presence of
# bookends: the redeploy body below is neither.
case "$_miss" in *"bookends only"*) c=1; d="${d:+$d; }asserts the body is bookends — a content claim the code never checks";; esac
ab_check "a markerless read reports the marker was absent, and claims NOTHING about the body" "$c" "$d"

echo "== why_tail's MARKER IS THE CALLER'S — the redeploy path is not stamped with host-apply's =="
# The marker was hardcoded `[host-apply]`, which host-apply.sh ALONE emits. why_tail's other caller
# reports a FAILED redeploy from workload-refresh@<wl>, whose journal carries container-refresh.sh's
# `[<wl>]` lines and can never contain `[host-apply]`. So the search always missed, the fallback fired
# unconditionally, and every redeploy failure was labelled "no [host-apply] lines — systemd bookends
# only" directly above a body holding the actual cause. The label this PR exists to ADD was a LIE on
# half its call sites — the same mistake, re-committed by the fix for it.
_wt_probe2(){ # <unit> <summary-prefix> <marker> <invocation-body> → the rendered report text
  ( unset -f grep
    eval "$(sed -n '/^why_tail()/,/^}/p' "$HERE/../host-agent-watch.sh")"
    why_block(){ printf '%s' "$1"; }
    systemctl(){ echo "INV777"; }
    journalctl(){
      case "$*" in
        *_SYSTEMD_INVOCATION_ID=INV777*) printf '%s\n' "$BODY" ;;
        *) echo "systemd[901]: bookend" ;;
      esac
    }
    BODY="$4" why_tail "$1" "$2" "$3" )
}
_rd="$(_wt_probe2 "workload-refresh@fedora-dev.service" "workload-refresh@fedora-dev log" "[fedora-dev]" \
        "[fedora-dev] FAILED — candidate never became (healthy) after 120s")"
c=0; d=''
case "$_rd" in *"has [fedora-dev] output"*) : ;; *) c=1; d="did not recognise container-refresh's OWN marker: [$_rd]";; esac
case "$_rd" in *host-apply*) c=1; d="${d:+$d; }stamped the redeploy report with host-apply's marker";; esac
case "$_rd" in *"no [fedora-dev] lines"*) c=1; d="${d:+$d; }called a cause-bearing body markerless";; esac
ab_check "a redeploy read carrying container-refresh's cause is NAMED as such, not mislabelled" "$c" "$d"
# WIRING — the parameter is inert unless BOTH callers pass their own executor's marker (and under
# `set -u` an unpassed one kills the subshell, restoring the silence this PR exists to end).
c=0; d=''
grep -qF 'why_tail "workload-refresh@${wl}.service" "workload-refresh@${wl} log" "[$wl]"' "$HERE/../host-agent-watch.sh" \
  || { c=1; d="the redeploy caller does not pass container-refresh's [<workload>] marker"; }
grep -qF 'why_tail "$unit" "host-apply log" "[host-apply]"' "$HERE/../host-agent-watch.sh" \
  || { c=1; d="${d:+$d; }the apply caller does not pass [host-apply]"; }
ab_check "BOTH callers pass their OWN executor's marker" "$c" "$d"

echo
echo "host-agent-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
