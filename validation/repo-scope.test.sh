#!/usr/bin/env bash
# repo-scope.test.sh — R16 OPERATING SCOPE, host end (issue #132). Two layers, both bite:
#
#   (1) the READER (repo-scope.sh) decides scope correctly — in-scope ⇒ rc 0, out-of-scope ⇒ rc 3,
#       and it fails CLOSED to the two apparatus repos when scope.conf is unreadable (rc 0 for an
#       apparatus repo, rc 4 for a foreign one);
#   (2) the WATCHER (live-gate-watch.sh) actually GATES on it: driven with a stub `gh` returning one
#       in-scope + one out-of-scope labelled PR, it invokes the runner for the in-scope repo ONLY and
#       skips the out-of-scope one with the loud R16 line — before any per-PR SHA resolve or build.
#
# MUTATION (proves the watcher test bites): neuter the R16-SCOPE-GATE guard so the check never fires,
# and assert the out-of-scope repo THEN reaches the runner (the org-wide #165 leak restored). The
# mutant sits BESIDE the real script (temp copy of the tree) so it resolves the same stubbed helpers.
#
# No real GitHub / network / podman. `bash validation/repo-scope.test.sh` → exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/.."
READER="$SRC/repo-scope.sh"; WATCH="$SRC/live-gate-watch.sh"
[ -f "$READER" ] || { echo "FATAL: repo-scope.sh not found at $READER"; exit 2; }
[ -f "$WATCH" ]  || { echo "FATAL: live-gate-watch.sh not found at $WATCH"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# ---------------------------------------------------------------------------------------------------
echo "== (1) reader decisions =="
CONF="$ROOT/scope.conf"
printf '# comment\nfedora-dev\nfedora-bootstrap\nfedora-desktop\nknowledge-desktop\n' > "$CONF"
rck(){ SCOPE_FILE="$CONF" bash "$READER" check "$1" >/dev/null 2>&1; echo $?; }

[ "$(rck knowledge-desktop)" = 0 ]      && ok "in-scope repo → rc 0"            || no "in-scope repo should be rc 0"
[ "$(rck oso-gato/fedora-desktop)" = 0 ] && ok "owner-prefixed in-scope → rc 0" || no "owner-prefixed in-scope should be rc 0"
[ "$(rck some-foreign-repo)" = 3 ]      && ok "out-of-scope repo → rc 3"        || no "out-of-scope repo should be rc 3"
# unreadable config → fail closed to the two apparatus repos
[ "$(SCOPE_FILE=$ROOT/nope.conf bash "$READER" check fedora-dev >/dev/null 2>&1; echo $?)" = 0 ] \
  && ok "unreadable config: apparatus repo still allowed (rc 0)" || no "unreadable config should allow apparatus repo"
[ "$(SCOPE_FILE=$ROOT/nope.conf bash "$READER" check fedora-desktop >/dev/null 2>&1; echo $?)" = 4 ] \
  && ok "unreadable config: foreign repo denied (rc 4)" || no "unreadable config should deny foreign repo"
# readable-but-empty denies everything (a maintainer who empties it means it)
: > "$ROOT/empty.conf"
[ "$(SCOPE_FILE=$ROOT/empty.conf bash "$READER" check fedora-dev >/dev/null 2>&1; echo $?)" = 3 ] \
  && ok "empty config denies even an apparatus repo (rc 3)" || no "empty config should deny everything"

# ---------------------------------------------------------------------------------------------------
# Parts (2)+(3) drive the REAL live-gate-watch.sh, whose discovery parses the `gh` JSON with python3
# (the watcher's own runtime dependency). Where python3 is absent the watcher cannot run at all, so
# skip loudly rather than fail spuriously — the reader-core gate (part 1) still bit above, and the gate
# image (Containerfile.livegate) installs python3 so the disposable live-gate DOES exercise 2+3.
if ! command -v python3 >/dev/null 2>&1; then
  echo "== (2)+(3) SKIPPED: no python3 (live-gate-watch.sh discovery needs it) — reader-core still gated =="
  echo; echo "repo-scope: $pass passed, $fail failed (watcher integration skipped — no python3)"
  [ "$fail" -eq 0 ]; exit
fi

echo "== (2) watcher gates discovery on scope (in-scope gated, out-of-scope skipped) =="
# A fake $HOME the watcher resolves its helpers under: it prefers $HOME/.local/bin/<script>.
FHOME="$ROOT/home"; BIN="$FHOME/.local/bin"; DATA="$FHOME/.config/live-gate"
mkdir -p "$BIN" "$DATA"
cp "$READER" "$BIN/repo-scope.sh"; chmod +x "$BIN/repo-scope.sh"
# the scope set the watcher will honour: fedora-desktop IN, forbidden-repo OUT.
printf 'fedora-dev\nfedora-bootstrap\nfedora-desktop\n' > "$DATA/scope.conf"
# stub fleet-halt → CLEAR (never halt); stub runner → record which repos it is invoked for.
cat > "$BIN/fleet-halt.sh" <<'EOF'
#!/usr/bin/env bash
echo CLEAR; exit 0
EOF
cat > "$BIN/live-gate-run.sh" <<'EOF'
#!/usr/bin/env bash
echo "RAN $1 $2" >> "$RUN_LOG"; exit 3
EOF
chmod +x "$BIN/fleet-halt.sh" "$BIN/live-gate-run.sh"

# stub PATH: gh returns one in-scope + one out-of-scope labelled PR; python3 stays real.
STUBS="$ROOT/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  search)  # gh search prs ... --json repository,number
    printf '[{"repository":{"name":"fedora-desktop"},"number":11},{"repository":{"name":"forbidden-repo"},"number":22}]';;
  pr)      # gh pr view <num> --repo ... --json headRefOid -q .headRefOid
    printf 'sha%s\n' "$3";;
  *) exit 0;;
esac
EOF
chmod +x "$STUBS/gh"

run_watcher(){  # $1 = watcher script path
  rm -f "$ROOT/run.log"; : > "$ROOT/run.log"
  env HOME="$FHOME" PATH="$STUBS:$PATH" RUN_LOG="$ROOT/run.log" \
    bash "$1" > "$ROOT/watch.out" 2>&1 || true
}

run_watcher "$WATCH"
{ grep -q 'RAN fedora-desktop 11' "$ROOT/run.log"; } \
  && ok "in-scope PR (fedora-desktop#11) reached the runner" \
  || no "in-scope PR should have reached the runner"
{ ! grep -q 'forbidden-repo' "$ROOT/run.log"; } \
  && ok "out-of-scope PR (forbidden-repo#22) never reached the runner" \
  || no "out-of-scope PR should NOT have reached the runner"
{ grep -q 'R16 OUT-OF-SCOPE: forbidden-repo#22' "$ROOT/watch.out"; } \
  && ok "out-of-scope PR skipped with the loud R16 line" \
  || no "expected the loud R16 OUT-OF-SCOPE skip line for forbidden-repo#22"

# ---------------------------------------------------------------------------------------------------
echo "== (3) MUTATION: neuter the R16-SCOPE-GATE guard → out-of-scope repo IS gated (the leak) =="
# The mutant must live BESIDE the real tree so it resolves $HERE/repo-scope.sh etc. identically; but
# the watcher prefers $HOME/.local/bin first, so the stub helpers above still win regardless.
MUT="$SRC/.repo-scope-watch-mut-$$.sh"; trap 'rm -f "$MUT"; rm -rf "$ROOT"' EXIT
# flip the guard `if ! scope_ok "$repo"; then` to a never-true one. `if ! scope_ok` matches ONLY the
# call site (the definition is `scope_ok(){`), so this is unambiguous.
sed 's/if ! scope_ok/if false \&\& ! scope_ok/' "$WATCH" > "$MUT"
if grep -q 'if false && ! scope_ok' "$MUT"; then
  run_watcher "$MUT"
  { grep -q 'RAN forbidden-repo 22' "$ROOT/run.log"; } \
    && ok "mutation: gate neutered → out-of-scope repo reaches the runner (org-wide leak); real code skips it" \
    || no "mutant did not restore the org-wide leak (test would not bite)"
else
  no "mutation VACUOUS (sed did not neuter the R16-SCOPE-GATE guard)"
fi

echo; echo "repo-scope: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
