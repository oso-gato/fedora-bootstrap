#!/usr/bin/env bash
# host-code-refresh.test.sh — MOCK end-to-end of the HOST-SIDE SELF-ARMING ABSORBER (F16),
# host-code-refresh.sh, against a REAL git mock control clone with ZERO host/systemd/network contact.
#
# WHAT IS REAL vs STUBBED:
#   * REAL git — a bare `origin` + a working clone built with real `git init/clone/commit/fetch/merge`.
#     The absorber's fetch / ff-only / merge-base decisions run against genuine git history.
#   * REAL filesystem install — the absorber's own hcr_install_from copies the manifest artifacts into
#     per-case throwaway dirs (via the HCR_BIN_DIR/HCR_UNIT_DIR/HCR_STATE_DIR test seams), and the REAL
#     hcr_verify_from read-back byte-compares them — the load-bearing check is exercised UNMODIFIED.
#   * STUBBED systemctl — a PATH shim that RECORDS `--user` calls and touches no real systemd.
#   * For the readback-mismatch case ONLY, a PATH `install` shim faithfully copies every artifact then
#     CORRUPTS one on disk — simulating "installed artifact != merged source" the honest way (a botched
#     install), so the real readback catches it. See MUTATION NOTE at that case.
#
# Runs on a plain runner: no podman, no host engine, no network (local git only). FENCE_CHECK_ONLY is
# irrelevant here (this test never fences a container) — it runs identically with or without it, so the
# host live-gate's Containerfile.livegate can run it in the disposable build (git-core is installed there).
#
# Run:  bash validation/host-code-refresh.test.sh   → exit 0 = all cases pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_SRC="$(cd "$HERE/.." && pwd)"
ABSORBER="$REPO_SRC/host-code-refresh.sh"
[ -f "$ABSORBER" ] || { echo "FATAL: host-code-refresh.sh not found at $ABSORBER"; exit 2; }

# Some environments (e.g. a minimal live-gate image) may lack git — skip cleanly rather than red the
# whole suite; the absorber itself fail-closes without git, and the real host + dev box always have it.
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available — host-code-refresh.test.sh needs real git"; exit 0; }

# Reuse the absorber's OWN manifest to seed the mock repo, so the mock can never drift from the managed
# set. Sourcing defines the functions without running the absorber (its main is guarded on direct exec).
# shellcheck source=/dev/null
. "$ABSORBER"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# Isolate git from any host/global config; give commits a deterministic identity with no config files.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=f16 GIT_AUTHOR_EMAIL=f16@test GIT_COMMITTER_NAME=f16 GIT_COMMITTER_EMAIL=f16@test

# ---- stub systemctl: RECORD every call, execute NOTHING (the "no real systemd" guard) ----
BIN="$ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'SYSTEMCTL %s\n' "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$BIN/systemctl"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }

# Build a fresh {author → bare origin → working clone} trio for a case. Globals: C_AUTHOR/C_ORIGIN/C_WORK.
build_repo() {
    local tag="$1"
    C_AUTHOR="$ROOT/$tag-author"; C_ORIGIN="$ROOT/$tag-origin.git"; C_WORK="$ROOT/$tag-work"
    local mode src _d
    while IFS=$'\t' read -r mode src _d; do
        [ -n "$mode" ] || continue
        install -D -m "$mode" "$REPO_SRC/$src" "$C_AUTHOR/$src"
    done < <(HCR_BIN_DIR=/_ HCR_UNIT_DIR=/_ hcr_manifest)
    git init -q -b main "$C_AUTHOR"
    git -C "$C_AUTHOR" add -A
    git -C "$C_AUTHOR" commit -q -m base
    git clone -q --bare "$C_AUTHOR" "$C_ORIGIN"
    git -C "$C_AUTHOR" remote add origin "$C_ORIGIN"
    git clone -q "$C_ORIGIN" "$C_WORK"
}
# Advance origin one commit AHEAD of the working clone (append a marker to a manifest file, push).
advance_origin() {
    printf '\n# ADVANCED %s\n' "$1" >> "$C_AUTHOR/throwaway-sweep.sh"
    git -C "$C_AUTHOR" commit -q -am "advance $1"
    git -C "$C_AUTHOR" push -q origin main
}

# Run the absorber against C_WORK with per-case throwaway install/state dirs. Sets globals RC + paths.
run_absorber() {
    local tag="$1" extra_path="${2:-}"
    A_BIN="$ROOT/$tag-inst/bin"; A_UNIT="$ROOT/$tag-inst/units"; A_STATE="$ROOT/$tag-inst/state"
    A_OUT="$ROOT/$tag.out"; A_SCLOG="$ROOT/$tag.systemctl.log"
    : > "$A_SCLOG"
    HCR_CLONE="$C_WORK" HCR_BIN_DIR="$A_BIN" HCR_UNIT_DIR="$A_UNIT" HCR_STATE_DIR="$A_STATE" \
        SYSTEMCTL_LOG="$A_SCLOG" PATH="${extra_path}$BIN:$PATH" \
        bash "$ABSORBER" > "$A_OUT" 2>&1
    RC=$?
}

echo "== CASE 1: advanced + clean → ff-pull + reinstall + applied.sha = merged sha =="
build_repo c1; advance_origin one
want_sha="$(git -C "$C_AUTHOR" rev-parse HEAD)"
run_absorber c1
{ [ "$RC" = 0 ] \
  && [ -f "$A_STATE/applied.sha" ] && [ "$(cat "$A_STATE/applied.sha")" = "$want_sha" ] \
  && [ "$(git -C "$C_WORK" rev-parse HEAD)" = "$want_sha" ] \
  && grep -q 'ADVANCED one' "$A_BIN/throwaway-sweep.sh" \
  && hcr_same "$A_BIN/host-agent-watch.sh" "$C_WORK/host-agent-watch.sh" \
  && grep -q 'SYSTEMCTL --user daemon-reload' "$A_SCLOG"; } \
  && ok "ff-applied, merged content live, applied.sha == merged sha, daemon-reload issued" \
  || bad "advanced+clean" "rc=$RC applied=$(cat "$A_STATE/applied.sha" 2>/dev/null) want=$want_sha; out: $(tr '\n' '|' <"$A_OUT")"

echo "== CASE 2: dirty clone → REFUSED, untouched, NO applied.sha =="
build_repo c2; advance_origin two
base_sha="$(git -C "$C_WORK" rev-parse HEAD)"
printf '\n# LOCAL-DIRTY-EDIT\n' >> "$C_WORK/throwaway-sweep.sh"     # uncommitted tracked-file change
run_absorber c2
{ [ "$RC" = 0 ] \
  && [ ! -f "$A_STATE/applied.sha" ] \
  && [ "$(git -C "$C_WORK" rev-parse HEAD)" = "$base_sha" ] \
  && grep -q 'LOCAL-DIRTY-EDIT' "$C_WORK/throwaway-sweep.sh" \
  && grep -qi 'uncommitted\|refus' "$A_OUT"; } \
  && ok "dirty refused, clone HEAD untouched, no applied.sha, loud log" \
  || bad "dirty" "rc=$RC head=$(git -C "$C_WORK" rev-parse HEAD) base=$base_sha applied?=$( [ -f "$A_STATE/applied.sha" ] && echo yes||echo no); out: $(tr '\n' '|' <"$A_OUT")"

echo "== CASE 3: diverged clone → REFUSED, NO applied.sha =="
build_repo c3; advance_origin three
printf '\n# LOCAL-COMMIT-DIVERGE\n' >> "$C_WORK/live-gate-watch.sh"
git -C "$C_WORK" commit -q -am "local diverging commit"
div_sha="$(git -C "$C_WORK" rev-parse HEAD)"
run_absorber c3
{ [ "$RC" = 0 ] \
  && [ ! -f "$A_STATE/applied.sha" ] \
  && [ "$(git -C "$C_WORK" rev-parse HEAD)" = "$div_sha" ] \
  && grep -qi 'diverg\|does NOT fast-forward\|refus' "$A_OUT"; } \
  && ok "diverged refused, clone HEAD untouched, no applied.sha, loud log" \
  || bad "diverged" "rc=$RC out: $(tr '\n' '|' <"$A_OUT")"

echo "== CASE 4: up-to-date (applied.sha present) → silent no-op (no systemctl, no re-record) =="
build_repo c4    # no advance → work == origin
head_sha="$(git -C "$C_WORK" rev-parse HEAD)"
mkdir -p "$ROOT/c4-inst/state"; printf '%s\n' "$head_sha" > "$ROOT/c4-inst/state/applied.sha"
run_absorber c4
{ [ "$RC" = 0 ] \
  && [ "$(cat "$A_STATE/applied.sha")" = "$head_sha" ] \
  && [ ! -s "$A_SCLOG" ] \
  && [ ! -s "$A_OUT" ]; } \
  && ok "up-to-date is a silent no-op (systemctl untouched, applied.sha unchanged, no output)" \
  || bad "up-to-date" "rc=$RC sclog=$(wc -c <"$A_SCLOG") out=$(tr '\n' '|' <"$A_OUT")"

echo "== CASE 5: readback MISMATCH → FAIL-CLOSED (no applied.sha, loud log, non-zero exit) =="
# MUTATION NOTE: this case is the guard on the live read-back. The `install` shim below copies every
# artifact faithfully, then corrupts ONE on disk (container-refresh.sh) — exactly "installed artifact
# != merged source". The REAL hcr_verify_from must catch it and refuse to write applied.sha. If the
# read-back were neutralised (e.g. hcr_verify_from hard-coded to `return 0`), THIS case would wrongly
# PASS (applied.sha written, rc 0) — so a green here proves the read-back is actually load-bearing.
MBIN="$ROOT/mbin"; mkdir -p "$MBIN"
cat > "$MBIN/install" <<'EOF'
#!/usr/bin/env bash
/usr/bin/install "$@"; rc=$?
dest=; for a in "$@"; do dest="$a"; done      # last arg = destination
case "$dest" in */container-refresh.sh) printf 'CORRUPTION' >> "$dest";; esac
exit "$rc"
EOF
chmod +x "$MBIN/install"
build_repo c5; advance_origin five
run_absorber c5 "$MBIN:"
{ [ "$RC" != 0 ] \
  && [ ! -f "$A_STATE/applied.sha" ] \
  && grep -qi 'READBACK' "$A_OUT"; } \
  && ok "readback mismatch fails closed: non-zero exit, NO applied.sha, loud READBACK log" \
  || bad "readback-mismatch" "rc=$RC applied?=$( [ -f "$A_STATE/applied.sha" ] && echo yes||echo no); out: $(tr '\n' '|' <"$A_OUT")"

echo
echo "host-code-refresh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
