#!/usr/bin/env bash
# host-apply.test.sh — MOCK end-to-end of the HOST SELF-APPLY EXECUTOR (host-apply.sh, issue #133)
# against a REAL git mock control clone, with ZERO host/root/systemd/network contact.
#
# WHAT IS REAL vs STUBBED:
#   * REAL git — a bare `origin` + a working clone built with real git init/clone/commit/fetch/archive.
#     The executor's PINNED-URL fetch, ff-ancestry decision, dirty/diverged refusal, and the pristine
#     `git archive` materialisation run against genuine git history.
#   * REAL readback — the executor's OWN ha_readback (which reuses the merged tree's hcr_verify_from +
#     hcr_same) byte-compares the installed artifacts to the merged source, UNMODIFIED. This is the
#     load-bearing #133 BLOCKING check ('applied' = 'proven live').
#   * STUBBED setup.sh + verify.sh — via the APPLY_SETUP_CMD / APPLY_VERIFY_CMD seams (which `sudo`
#     env_reset makes UNREACHABLE in production — see the host-apply.sh header). The setup stub faithfully
#     INSTALLS the merged artifacts (so a clean run's readback passes); parameterised MUTATE injects a
#     STALE artifact so the readback must FAIL; VERIFY_FAIL makes the health-gate fail so rollback fires.
#     No real setup.sh / verify.sh / package / systemd is ever touched.
#
# Runs on a plain runner: no podman, no host engine, no network (local git only). FENCE_CHECK_ONLY is
# irrelevant here (it never fences a container), so the host live-gate's Containerfile.livegate runs it
# in the disposable build (git-core is installed there).
#
# Run:  bash validation/host-apply.test.sh   → exit 0 = all cases pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_SRC="$(cd "$HERE/.." && pwd)"
EXEC="$REPO_SRC/host-apply.sh"
[ -f "$EXEC" ] || { echo "FATAL: host-apply.sh not found at $EXEC"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available — host-apply.test.sh needs real git"; exit 0; }

# Reuse the absorber's OWN manifest to seed the mock repo's user-layer set (so it can never drift).
# shellcheck source=/dev/null
. "$REPO_SRC/host-code-refresh.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=ha GIT_AUTHOR_EMAIL=ha@test GIT_COMMITTER_NAME=ha GIT_COMMITTER_EMAIL=ha@test

# ---- stubs: a setup.sh that INSTALLS the merged set (+ optional MUTATE), and a pass/fail verify.sh ----
STUB_SETUP="$ROOT/stub-setup.sh"
cat > "$STUB_SETUP" <<'EOF'
#!/usr/bin/env bash
# Stand-in for `setup.sh`: install the merged artifacts the readback will byte-check. $APPLY_TREE is the
# root-owned pristine materialisation the executor built; the APPLY_*_DIR seams are the "live" dests.
set -uo pipefail
tree="${APPLY_TREE:?}"
export HCR_BIN_DIR="$APPLY_BIN_DIR" HCR_UNIT_DIR="$APPLY_UNIT_DIR"
# shellcheck source=/dev/null
. "$tree/host-code-refresh.sh"
hcr_install_from "$tree" || exit 1                                  # user-layer (scripts + --user units)
mkdir -p "$APPLY_SBIN_DIR"
for s in host-apply cockpit-tailnet-serve selinux-enforce-once; do  # system-layer /usr/local/sbin artifacts
  install -m0755 "$tree/$s.sh" "$APPLY_SBIN_DIR/$s" || exit 1
done
case "${MUTATE:-}" in
  sbin) printf 'STALE-INJECTED' >> "$APPLY_SBIN_DIR/host-apply";;        # a stale SYSTEM-layer artifact (the host-apply seam)
  user) printf 'STALE-INJECTED' >> "$APPLY_BIN_DIR/host-agent-watch.sh";; # a stale USER-layer artifact
esac
# increment 2: simulate setup.sh (re)writing a deployed workload Quadlet (the fitness-lines-uncommented case).
if [ -n "${QUADLET_WRITE:-}" ]; then
  mkdir -p "${APPLY_QUADLET_DIR:?}"
  printf '%s\n' "$QUADLET_WRITE" > "$APPLY_QUADLET_DIR/fedora-dev.container"
fi
exit 0
EOF
STUB_VERIFY="$ROOT/stub-verify.sh"
printf '#!/usr/bin/env bash\nexit "${VERIFY_FAIL:-0}"\n' > "$STUB_VERIFY"
chmod +x "$STUB_SETUP" "$STUB_VERIFY"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }

# Seed an author repo (user-layer manifest + the system-layer sources the readback checks), commit base.
seed_author() {
  local dir="$1" mode src _d s
  while IFS=$'\t' read -r mode src _d; do
    [ -n "$mode" ] || continue
    install -D -m "$mode" "$REPO_SRC/$src" "$dir/$src"
  done < <(HCR_BIN_DIR=/_ HCR_UNIT_DIR=/_ hcr_manifest)
  for s in host-apply cockpit-tailnet-serve selinux-enforce-once setup.sh verify.sh; do
    install -D -m0755 "$REPO_SRC/$s" "$dir/$s" 2>/dev/null || install -D -m0755 "$REPO_SRC/${s}.sh" "$dir/${s}.sh"
  done
  git init -q -b main "$dir"; git -C "$dir" add -A; git -C "$dir" commit -q -m base
}
# author → bare origin → working clone. Globals: C_ORIGIN / C_WORK.
build_repo() {
  local tag="$1"; local author="$ROOT/$tag-author"
  C_ORIGIN="$ROOT/$tag-origin.git"; C_WORK="$ROOT/$tag-work"
  seed_author "$author"
  git clone -q --bare "$author" "$C_ORIGIN"
  git clone -q "$C_ORIGIN" "$C_WORK"
}
# Advance origin one commit AHEAD of the working clone (so the executor sees a fast-forward).
advance_origin() {
  local w="$ROOT/adv-$1"; git clone -q "$C_ORIGIN" "$w"
  printf '\n# ADVANCED %s\n' "$1" >> "$w/throwaway-sweep.sh"
  git -C "$w" commit -q -am "advance $1"; git -C "$w" push -q origin main; rm -rf "$w"
}
# Run the executor against C_WORK with per-case throwaway dest/state dirs. Sets RC + A_* globals.
run_apply() { # <tag> [extra env assignments...]
  local tag="$1"; shift
  A_BIN="$ROOT/$tag/bin"; A_UNIT="$ROOT/$tag/units"; A_SBIN="$ROOT/$tag/sbin"
  A_STATE="$ROOT/$tag/state"; A_OUT="$ROOT/$tag.out"
  # APPLY_GIT_RUNNER='' → git runs directly (the test IS 'core'; runuser needs root). APPLY_ORIGIN_ALLOW
  # is the exact-URL allowlist seam (space-separated; `sudo` env_reset strips it in production) — set to
  # the local mock origin path (C_ORIGIN = "$ROOT/<tag>-origin.git") so the ANCHORED guard admits the mock
  # WITHOUT loosening the production canonical-forms match (which host-apply.sh --selftest exercises).
  env APPLY_CLONE="$C_WORK" APPLY_GIT_RUNNER= APPLY_ORIGIN_ALLOW="$C_ORIGIN" APPLY_BRANCH=main \
      APPLY_STATE_DIR="$A_STATE" APPLY_BIN_DIR="$A_BIN" APPLY_UNIT_DIR="$A_UNIT" APPLY_SBIN_DIR="$A_SBIN" \
      APPLY_SETUP_CMD="bash $STUB_SETUP" APPLY_VERIFY_CMD="bash $STUB_VERIFY" "$@" \
      bash "$EXEC" > "$A_OUT" 2>&1
  RC=$?
}

echo "== CASE 1: behind + clean → FF apply, health-gate + readback pass, applied.sha = merged sha =="
build_repo c1; advance_origin one
want="$(git -C "$C_ORIGIN" rev-parse main)"
run_apply c1
{ [ "$RC" = 0 ] \
  && [ -f "$A_STATE/applied.sha" ] && [ "$(cat "$A_STATE/applied.sha")" = "$want" ] \
  && hcr_same "$A_BIN/host-agent-watch.sh" "$C_WORK/host-agent-watch.sh" \
  && grep -q 'ADVANCED one' "$A_BIN/throwaway-sweep.sh" \
  && grep -qi 'readback: all live artifacts' "$A_OUT"; } \
  && ok "FF-applied, readback-verified, applied.sha == merged sha" \
  || bad "clean-apply" "rc=$RC applied=$(cat "$A_STATE/applied.sha" 2>/dev/null) want=$want; out: $(tr '\n' '|' <"$A_OUT")"

echo "== CASE 2: up-to-date (applied.sha present) → no-op, setup NOT run =="
build_repo c2   # no advance → work == origin
head="$(git -C "$C_WORK" rev-parse HEAD)"
mkdir -p "$ROOT/c2/state"; printf '%s\n' "$head" > "$ROOT/c2/state/applied.sha"
run_apply c2
{ [ "$RC" = 0 ] && [ ! -d "$A_BIN" ] && grep -qi 'no-op' "$A_OUT"; } \
  && ok "up-to-date is a no-op (setup stub never ran → no install dir)" \
  || bad "uptodate" "rc=$RC bin-exists?=$( [ -d "$A_BIN" ] && echo yes||echo no); out: $(tr '\n' '|' <"$A_OUT")"

echo "== CASE 3: dirty clone → REFUSED (exit 3), setup NOT run, no applied.sha =="
build_repo c3; advance_origin three
printf '\n# LOCAL-DIRTY\n' >> "$C_WORK/throwaway-sweep.sh"
run_apply c3
{ [ "$RC" = 3 ] && [ ! -d "$A_BIN" ] && [ ! -f "$A_STATE/applied.sha" ] && grep -qi 'UNCOMMITTED\|dirty' "$A_OUT"; } \
  && ok "dirty refused fail-closed (exit 3), untouched" \
  || bad "dirty" "rc=$RC; out: $(tr '\n' '|' <"$A_OUT")"

echo "== CASE 4: diverged clone → REFUSED (exit 3), no apply =="
build_repo c4; advance_origin four
printf '\n# LOCAL-DIVERGE\n' >> "$C_WORK/live-gate-watch.sh"; git -C "$C_WORK" commit -q -am "local diverge"
run_apply c4
{ [ "$RC" = 3 ] && [ ! -f "$A_STATE/applied.sha" ] && grep -qi 'diverg\|does NOT fast-forward' "$A_OUT"; } \
  && ok "diverged refused (exit 3) — a question, not a force-pull" \
  || bad "diverged" "rc=$RC; out: $(tr '\n' '|' <"$A_OUT")"

echo "== CASE 4b: REPOINTED origin — a substring-crafted URL that merely CONTAINS the canonical slug → REFUSED before any fetch (exit 3) =="
# The clone is core-writable, so the agent could repoint origin. The OLD *substring* guard would have
# ACCEPTED file:///…/oso-gato/fedora-bootstrap (zero creds needed) or https://evil.tld/oso-gato/fedora-bootstrap
# and fetched attacker content = arbitrary root (the #133 blocker). The ANCHORED allowlist admits ONLY the
# exact canonical origin, so a slug-containing repoint is refused BEFORE any fetch. A green = only the real
# control repo is ever a source. (The production canonical-forms anchoring is unit-proven by --selftest.)
build_repo c4b
git -C "$C_WORK" remote set-url origin "file://$ROOT/evil/oso-gato/fedora-bootstrap"
run_apply c4b
{ [ "$RC" = 3 ] && [ ! -d "$A_BIN" ] && [ ! -f "$A_STATE/applied.sha" ] && grep -qi 'repoint\|not the canonical' "$A_OUT"; } \
  && ok "substring-crafted repoint refused (exit 3) before any fetch — inject-proof source" \
  || bad "repoint" "rc=$RC; out: $(tr '\n' '|' <"$A_OUT")"

echo "== CASE 5: health-gate FAILS → ROLLBACK to prior + re-converge (exit 1), no applied.sha =="
build_repo c5; advance_origin five
run_apply c5 VERIFY_FAIL=1
{ [ "$RC" = 1 ] && [ ! -f "$A_STATE/applied.sha" ] && grep -qi 'UNHEALTHY\|rolling back\|rolled back' "$A_OUT"; } \
  && ok "unhealthy after apply → rolled back, success NOT recorded (exit 1)" \
  || bad "verify-fail-rollback" "rc=$RC applied?=$( [ -f "$A_STATE/applied.sha" ] && echo yes||echo no); out: $(tr '\n' '|' <"$A_OUT")"

echo "== CASE 6 (MUTATION): setup injects a STALE system-layer artifact → readback FAILS closed (exit 2) =="
# The #133 BLOCKING clause: 'applied' must mean 'proven live'. The setup stub installs everything then
# CORRUPTS /usr/local/sbin/host-apply on disk (a stale artifact) — the REAL ha_readback must catch that
# the live artifact != merged main and REFUSE to record success. A green here needs the readback to bite.
build_repo c6; advance_origin six
run_apply c6 MUTATE=sbin
{ [ "$RC" = 2 ] && [ ! -f "$A_STATE/applied.sha" ] && grep -qi 'READBACK MISMATCH' "$A_OUT"; } \
  && ok "stale artifact → readback fails closed (exit 2), NO applied.sha, loud READBACK log" \
  || bad "readback-mutation" "rc=$RC applied?=$( [ -f "$A_STATE/applied.sha" ] && echo yes||echo no); out: $(tr '\n' '|' <"$A_OUT")"

echo "== MUTATION GUARD: neutralize ha_readback (return 0) → CASE 6 would WRONGLY pass — proves it is load-bearing =="
# Replace ha_readback's verdict with an unconditional success. If the readback were NOT load-bearing, the
# stale-artifact case would already pass without it; instead the neutralised executor now WRONGLY records
# success (rc 0, applied.sha written) — so CASE 6's green above is genuinely due to the real readback.
MUT="$ROOT/host-apply-mut.sh"
sed 's/  return "\$rc"/  return 0/' "$EXEC" > "$MUT"
if ! grep -q '  return 0' "$MUT" || grep -q '  return "\$rc"' "$MUT"; then
  bad "mutation vacuous" "sed did not neutralize ha_readback's verdict"
else
  A_BIN="$ROOT/cm/bin"; A_UNIT="$ROOT/cm/units"; A_SBIN="$ROOT/cm/sbin"; A_STATE="$ROOT/cm/state"; A_OUT="$ROOT/cm.out"
  env APPLY_CLONE="$C_WORK" APPLY_GIT_RUNNER= APPLY_ORIGIN_ALLOW="$C_ORIGIN" APPLY_BRANCH=main \
      APPLY_STATE_DIR="$A_STATE" APPLY_BIN_DIR="$A_BIN" APPLY_UNIT_DIR="$A_UNIT" APPLY_SBIN_DIR="$A_SBIN" \
      APPLY_SETUP_CMD="bash $STUB_SETUP" APPLY_VERIFY_CMD="bash $STUB_VERIFY" MUTATE=sbin \
      bash "$MUT" > "$A_OUT" 2>&1; mrc=$?
  { [ "$mrc" = 0 ] && [ -f "$A_STATE/applied.sha" ]; } \
    && ok "neutralised readback WRONGLY records success on a stale artifact — the real readback IS the guard" \
    || bad "mutation" "neutralised executor did not wrongly-pass (rc=$mrc applied?=$( [ -f "$A_STATE/applied.sha" ] && echo yes||echo no)) — CASE 6 may be passing for the wrong reason"
fi

echo "== CASE 7 (increment 2): apply CHANGES a deployed workload Quadlet → the changed-quadlet signal lists it =="
# The recreate TRIGGER: setup.sh rewrites ~core/.config/containers/systemd/fedora-dev.container (the fitness
# lines uncommented). host-apply.sh sha's it BEFORE vs AFTER and records the changed workload to the signal
# the host agent reads to file an approved-gated recreate. Pre-seed the OLD Quadlet; the stub writes the NEW.
build_repo c7; advance_origin seven
mkdir -p "$ROOT/c7/state" "$ROOT/c7/quadlets"; printf 'OLD-ENV\n' > "$ROOT/c7/quadlets/fedora-dev.container"
run_apply c7 APPLY_QUADLET_DIR="$ROOT/c7/quadlets" QUADLET_WRITE=NEW-ENV
{ [ "$RC" = 0 ] && [ "$(cat "$ROOT/c7/state/quadlet-changed" 2>/dev/null)" = "fedora-dev" ]; } \
  && ok "changed Quadlet → signal lists 'fedora-dev' (the approved-gated recreate trigger)" \
  || bad "quadlet-change-signal" "rc=$RC signal='$(cat "$ROOT/c7/state/quadlet-changed" 2>/dev/null)'; out: $(tr '\n' '|' <"$ROOT/c7.out")"

echo "== CASE 8 (increment 2): an apply that does NOT change the Quadlet → EMPTY signal (no spurious recreate) =="
# A merged change that re-runs setup.sh but leaves the Quadlet byte-identical must NOT trigger a recreate
# (a session-dropping act). Pre-seed SAME-ENV; the stub rewrites the identical content → sha unchanged.
build_repo c8; advance_origin eight
mkdir -p "$ROOT/c8/state" "$ROOT/c8/quadlets"; printf 'SAME-ENV\n' > "$ROOT/c8/quadlets/fedora-dev.container"
run_apply c8 APPLY_QUADLET_DIR="$ROOT/c8/quadlets" QUADLET_WRITE=SAME-ENV
{ [ "$RC" = 0 ] && [ -f "$ROOT/c8/state/quadlet-changed" ] && [ ! -s "$ROOT/c8/state/quadlet-changed" ]; } \
  && ok "unchanged Quadlet → empty signal written (no spurious recreate)" \
  || bad "quadlet-nochange-signal" "rc=$RC signal-exists?=$( [ -f "$ROOT/c8/state/quadlet-changed" ] && echo yes||echo no) signal='$(cat "$ROOT/c8/state/quadlet-changed" 2>/dev/null)'"

echo
echo "host-apply: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
