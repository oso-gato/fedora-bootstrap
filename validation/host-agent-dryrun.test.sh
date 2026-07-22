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
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'SYSTEMCTL %s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
  *"show -p ExecMainStatus"*) echo "${FAKE_EXECMAIN:-0}" ;;  # emulate a clean refresh (mainstatus 0)
  *"is-active"*)              echo "${FAKE_ISACTIVE:-inactive}" ;;  # apply-bootstrap poll (host-apply.service)
esac
exit 0
EOF
chmod +x "$BIN/gh" "$BIN/systemctl"

pass=0; fail=0
run_case(){ # <desc> <fake-body> <expect-systemctl-start: yes|no> <expect-comment-substr>
  local desc="$1" body="$2" expect_start="$3" want="$4"
  local home="$ROOT/home-$RANDOM$RANDOM"; mkdir -p "$home"
  export HOME="$home"
  export GH_LOG="$home/gh.log";              : > "$GH_LOG"
  export SYSTEMCTL_LOG="$home/systemctl.log"; : > "$SYSTEMCTL_LOG"
  export FAKE_BODY="$body" FAKE_ISSUE=1 FAKE_EXECMAIN=0
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
  export FAKE_BODY=$'host-op: apply-bootstrap\napply merged main' FAKE_ISSUE=1 FAKE_ISACTIVE="$1" FAKE_EXECMAIN="$2"
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

echo
echo "host-agent-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
