#!/usr/bin/env bash
# live-gate-shacoherence.test.sh — the DEDUP KEY and the GATED ARTIFACT must name the SAME sha.
#
# THE BUG (observed on fedora-bootstrap#267, 2026-07-28): live-gate-watch.sh resolves the PR head with
# `gh pr view --json headRefOid` and dedups under THAT sha; live-gate-run.sh independently fetches
# `refs/pull/<n>/head`, a DERIVED ref GitHub updates asynchronously that can still carry the PREVIOUS
# head for a minute after a push. b19b03c was pushed at 20:22:07Z; the tick that followed posted a
# DUPLICATE GREEN naming the previous head 2ff1964 and returned a VERDICT code — so the watcher wrote
# the `.done` marker under b19b03c. b19b03c was then buried forever: "already gated", no verdict ever on
# the PR, and the dev-side consumers (which bind a verdict to the full 40-hex head) read host=NONE →
# poller NOOP. Same bury CLASS as CAT-04 (validation/live-gate-fetchfail.test.sh), a different cause.
#
# THE CONTRACT UNDER TEST: given the caller's expected head sha as arg 3, live-gate-run.sh gates ONLY
# that sha — a mismatch exits 2 (infra NON-verdict: nothing built, NO comment, NOT deduped → re-gate
# next poll when the ref catches up). Drives the REAL live-gate-run.sh with a stub git whose fetch
# "lands on" a caller-chosen sha. MUTATION neutralizes the guard and proves the wrong-sha head then
# DELIVERS a comment (rc 3) that the watcher would dedup under the expected sha = the bury.
# Also asserts the WIRING: the guard is inert unless live-gate-watch.sh actually passes the sha.
# No real GitHub/network. `bash validation/live-gate-shacoherence.test.sh` → exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RUN="$HERE/../live-gate-run.sh"; WATCH="$HERE/../live-gate-watch.sh"
[ -f "$RUN" ] || { echo "FATAL: live-gate-run.sh not found at $RUN"; exit 2; }
[ -f "$WATCH" ] || { echo "FATAL: live-gate-watch.sh not found at $WATCH"; exit 2; }
ROOT="$(mktemp -d)"; MUT="$HERE/../.lg-run-coh-mut-$$.sh"
trap 'rm -f "$MUT"; rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# The two heads in play: OLD = what the lagging `refs/pull/<n>/head` still resolves to; NEW = what the
# caller resolved via headRefOid and will dedup under.
OLD_SHA="2ff19647fefab00d6cf0091a2671811fe93e8572"
NEW_SHA="b19b03c40b7286fb614c579c1455880df1467ddf"

# stub git: init/remote/fetch/checkout all "succeed"; rev-parse reports the sha the fetch LANDED on
# ($STUB_FETCHED_SHA) — i.e. whatever the pull ref carried at fetch time.
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" rev-parse --short HEAD "*) printf '%s\n' "${STUB_FETCHED_SHA:0:7}"; exit 0;;
  *" rev-parse HEAD "*)         printf '%s\n' "$STUB_FETCHED_SHA"; exit 0;;
esac
exit 0
EOF
# stub gh: record any comment attempt — the mismatch path must deliver ZERO.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "pr comment" ] && printf 'COMMENT %s\n' "$*" >> "$GH_LOG"
exit 0
EOF
chmod +x "$BIN/git" "$BIN/gh"

# run <script> <sha-the-fetch-lands-on> [expected-head-sha] -> echoes the exit code
run(){ : > "$ROOT/gh.log"
  env PATH="$BIN:$PATH" FD_THROWAWAY_TMPDIR="$ROOT" GH_LOG="$ROOT/gh.log" STUB_FETCHED_SHA="$2" \
    bash "$1" fedora-dev 999 "${3:-}" > "$ROOT/out.log" 2>&1; echo $?; }
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s (rc=%s gh=%s)\n       out: %s\n' "$1" "${2:-?}" "$(tr '\n' '|' <"$ROOT/gh.log" 2>/dev/null)" "$(tail -1 "$ROOT/out.log" 2>/dev/null)"; }

echo "== a LAGGING pull ref (fetched OLD head, caller dedups NEW) exits 2, builds nothing, posts NO comment =="
rc="$(run "$RUN" "$OLD_SHA" "$NEW_SHA")"
{ [ "$rc" = 2 ] && [ ! -s "$ROOT/gh.log" ] && grep -q 'head sha MISMATCH' "$ROOT/out.log"; } \
  && ok "mismatch → exit 2 (non-verdict, caller re-gates), no verdict posted for the wrong sha" \
  || no "mismatch did not exit 2 cleanly" "$rc"

echo "== a COHERENT head (fetched == expected) is gated normally — the guard does not false-positive =="
rc="$(run "$RUN" "$NEW_SHA" "$NEW_SHA")"
{ [ "$rc" = 3 ] && [ -s "$ROOT/gh.log" ] && ! grep -q 'head sha MISMATCH' "$ROOT/out.log"; } \
  && ok "coherent head passes the guard and reaches a DELIVERED outcome (structural skip on the stub tree)" \
  || no "coherent head was not gated" "$rc"

echo "== a standalone run (no expected sha) is unchanged — backwards compatible =="
rc="$(run "$RUN" "$OLD_SHA")"
{ [ "$rc" = 3 ] && [ -s "$ROOT/gh.log" ] && ! grep -q 'head sha MISMATCH' "$ROOT/out.log"; } \
  && ok "no expected-sha arg → nothing to enforce, gates the fetched head as before" \
  || no "standalone run regressed" "$rc"

echo "== a malformed expected sha is a bad ARG (exit 2), never a silent unguarded gate =="
rc="$(run "$RUN" "$OLD_SHA" "b19b03c")"
{ [ "$rc" = 2 ] && [ ! -s "$ROOT/gh.log" ] && grep -q '40-hex' "$ROOT/out.log"; } \
  && ok "short/malformed expected sha → exit 2, gates nothing" \
  || no "malformed expected sha was not refused" "$rc"

echo "== WIRING: live-gate-watch.sh passes the sha it dedups under (an unpassed sha = an inert guard) =="
if grep -q '"\$RUNNER" "\$repo" "\$num" "\$sha"' "$WATCH"; then
  ok "watcher hands the runner the exact sha its .done marker will name"
else
  no "watcher does NOT pass \$sha to the runner — the coherence guard is inert" "-"
fi

echo "== MUTATION: neutralize the coherence guard → the wrong-sha head is DELIVERED + deduped (the bug) =="
# The mutant must sit BESIDE the real live-gate-run.sh so its build-candidate.sh preflight (which runs
# BEFORE the fetch) passes and it actually reaches the guard under test.
sed '/head sha MISMATCH/{n;s/^\( *\)exit 2$/\1:/;}' "$RUN" > "$MUT"
if grep -A1 'head sha MISMATCH' "$MUT" | grep -Eq '^ *:$'; then
  rc="$(run "$MUT" "$OLD_SHA" "$NEW_SHA")"
  { [ "$rc" = 3 ] && [ -s "$ROOT/gh.log" ]; } \
    && ok "mutation: without the guard the OLD head is gated + commented while the caller dedups the NEW one = the #267 bury" \
    || no "mutant did not deliver an outcome for the wrong sha" "$rc"
else
  no "mutation VACUOUS (sed did not neutralize the mismatch exit)" "-"
fi

echo; echo "live-gate-shacoherence: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
