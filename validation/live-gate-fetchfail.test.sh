#!/usr/bin/env bash
# live-gate-fetchfail.test.sh — CAT-04 (audit 2026-07-18; the likely kd#23 root cause). A transient
# PR-head fetch failure must exit a NON-DEDUP code (2 = infra non-verdict) so live-gate-watch.sh re-gates
# next poll — NOT exit 3 (SKIPPED), which the watcher DEDUPS, burying the sha forever with no verdict
# comment ever on the PR. Drives the REAL live-gate-run.sh with a stub git whose `fetch` always fails,
# asserts it exits 2, reached the fetch-fail path, and posted NO comment. MUTATION restores the old
# `exit 3` and asserts the fetch-fail then exits 3 (the bug). No real GitHub/network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RUN="$HERE/../live-gate-run.sh"
[ -f "$RUN" ] || { echo "FATAL: live-gate-run.sh not found at $RUN"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"; REALGIT="$(command -v git)"

# stub git: REAL except `fetch` always fails (the transient blip). init/remote/checkout run for real.
cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = fetch ] && exit 1; done
exec "$REALGIT" "\$@"
EOF
# stub gh: record any comment attempt — the fetch-failure path must post ZERO.
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "pr comment" ] && printf 'COMMENT %s\n' "$*" >> "$GH_LOG"
exit 0
EOF
chmod +x "$BIN/git" "$BIN/gh"

run(){ env PATH="$BIN:$PATH" FD_THROWAWAY_TMPDIR="$ROOT" GH_LOG="$ROOT/gh.log" \
  bash "$1" fedora-dev 999 > "$ROOT/out.log" 2>&1; echo $?; }
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s (rc=%s gh=%s)\n       out: %s\n' "$1" "${2:-?}" "$(tr '\n' '|' <"$ROOT/gh.log" 2>/dev/null)" "$(tail -1 "$ROOT/out.log" 2>/dev/null)"; }

echo "== a PR-head fetch failure exits 2 (infra non-dedup), reaches the fetch-fail path, posts NO comment =="
: > "$ROOT/gh.log"; rc="$(run "$RUN")"
{ [ "$rc" = 2 ] && [ ! -s "$ROOT/gh.log" ] && grep -q 'could not fetch' "$ROOT/out.log"; } \
  && ok "fetch-fail → exit 2 (watcher re-gates), no phantom SKIP comment" \
  || no "fetch-fail did not exit 2 cleanly" "$rc"

echo "== MUTATION: restore the old 'exit 3' on the fetch-fail branch → it would be deduped (buried) =="
# The mutant must sit BESIDE the real live-gate-run.sh so its build-candidate.sh preflight (which runs
# BEFORE the fetch) passes and it actually reaches the fetch-fail branch under test.
MUT="$HERE/../.lg-run-mut-$$.sh"; trap 'rm -f "$MUT"; rm -rf "$ROOT"' EXIT
sed '/INFRA failure/{n;s/exit 2/exit 3/;}' "$RUN" > "$MUT"
if grep -A1 'INFRA failure' "$MUT" | grep -q 'exit 3'; then
  : > "$ROOT/gh.log"; rc="$(run "$MUT")"
  { [ "$rc" = 3 ] && grep -q 'could not fetch' "$ROOT/out.log"; } \
    && ok "mutation: fetch-fail exits 3 → watcher DEDUPS = buries the sha (the bug); real code exits 2" \
    || no "mutant did not exit 3" "$rc"
else
  no "mutation VACUOUS (sed did not flip the fetch-fail exit to 3)" "-"
fi

echo; echo "live-gate-fetchfail: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
