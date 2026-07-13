#!/usr/bin/env bash
# rebuild-devbox-dryrun.test.sh — MOCK end-to-end dry-run of the R17 `rebuild-devbox` verb
# (host-agent-watch.sh) with ZERO host contact. Runs on a plain CI runner / inside Containerfile.livegate
# (no podman, no host engine): `gh`, `systemctl` and `podman` are STUBBED on PATH so a fake ticket drives
# the whole KILL→REBUILD→RESTORE→RESUME→VERIFY state machine while nothing real is ever touched.
#
# These are the "tests that BITE" the issue demands (mutation-checked — each asserts the exact verdict a
# broken implementation would get wrong):
#   * a rebuild that leaves the old container alive (a GHOST) ⇒ FAILED, not success (kill-by-ID);
#   * the poller not observably sweeping in the NEW container ⇒ FAILED (log activity, not a PID);
#   * a restored-but-IDLE session (pane still a bare shell) ⇒ FAILED;
#   * a failed/rolled-back rebuild ⇒ FAILED, surfaced (never a half-built box reported as done);
#   * a DESTRUCTIVE verb from a non-maintainer author ⇒ REFUSED, no rebuild fired;
#   * a malformed / missing session manifest ⇒ REFUSED, no rebuild fired;
#   * the happy path ⇒ FIRE writes the marker + starts workload-rebuild@ (ticket stays open), then
#     FINISH reports DONE with sessions restored + poller sweeping.
#
# Run:  bash validation/rebuild-devbox-dryrun.test.sh   → exit 0 = all cases pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../host-agent-watch.sh"
[ -f "$WATCH" ] || { echo "FATAL: host-agent-watch.sh not found at $WATCH"; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# ---- stub gh: one open ticket; serve body/author/permission per-case; log every mutating call. ----
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  api)   printf '%s' "${FAKE_PERM:-admin}" ;;                       # collaborators/<login>/permission
  issue)
    case "$2" in
      list) echo "${FAKE_ISSUE:-1}" ;;                              # discovery → one fake issue
      view) case "$*" in *author*) printf '%s' "${FAKE_AUTHOR:-arthur}" ;; *) printf '%s' "$FAKE_BODY" ;; esac ;;
      *)    printf 'GH %s\n' "$*" >> "$GH_LOG" ;;                   # comment / close / edit → record
    esac ;;
  *) printf 'GH %s\n' "$*" >> "$GH_LOG" ;;                          # label create etc → record
esac
exit 0
EOF

# ---- stub systemctl: record every call; echo the workload-rebuild@ unit state the case selected. ----
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'SYSTEMCTL %s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
  *"is-active workload-rebuild@"*) echo "${SCEN_UNIT_STATE:-inactive}" ;;
esac
exit 0
EOF

# ---- stub podman: the REACH-IN. Route each subcommand to the case's scenario knobs. NEVER real. ----
cat > "$BIN/podman" <<'EOF'
#!/usr/bin/env bash
a="$*"
case "$a" in
  "container inspect"*"{{.Id}}"*) echo "${SCEN_NEWID:-NEWID}" ;;                 # id of the (new) container
  "container exists"*)  [ "${SCEN_OLD_GONE:-yes}" = yes ] && exit 1 || exit 0 ;; # gone→rc1, alive(ghost)→rc0
  *" test -d "*)        [ "${SCEN_CWD_OK:-yes}" = yes ] && exit 0 || exit 1 ;;
  *"tmux new-session"*) [ "${SCEN_TMUX_NEW_OK:-yes}" = yes ] && exit 0 || exit 1 ;;
  *"tmux list-panes"*)  echo "${SCEN_PANE:-claude}" ;;                            # bare shell name ⇒ idle
  *"tmux "*)            exit 0 ;;                                                 # kill-session / send-keys
  *"is-active"*)        [ "${SCEN_POLLER_ACTIVE:-yes}" = yes ] && exit 0 || exit 1 ;;  # poller active?
  *"journalctl"*)       [ -n "${SCEN_POLLER_LOG-x}" ] && echo "${SCEN_POLLER_LOG:-sweep}" ; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/gh" "$BIN/systemctl" "$BIN/podman"

pass=0; fail=0
newhome(){ HOME="$ROOT/home-$RANDOM$RANDOM"; export HOME; mkdir -p "$HOME";
  export GH_LOG="$HOME/gh.log";              : > "$GH_LOG"
  export SYSTEMCTL_LOG="$HOME/systemctl.log"; : > "$SYSTEMCTL_LOG"; }
tick(){ PATH="$BIN:$PATH" DEVBOX_RESUME_SETTLE=2 DEVBOX_POLLER_WINDOW=2 bash "$WATCH" >/dev/null 2>&1 || true; }
seed_marker(){ mkdir -p "$HOME/.local/state/host-agent"; printf '%s\n%b\n' "$1" "$2" > "$HOME/.local/state/host-agent/fedora-bootstrap-1.rebuild"; }
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       %s\n       gh:  %s\n       sys: %s\n' "$1" "$2" "$(tr '\n' '|' <"$GH_LOG")" "$(tr '\n' '|' <"$SYSTEMCTL_LOG")"; }
has(){ grep -qF "$1" "$GH_LOG"; }
sys_has(){ grep -qF "$1" "$SYSTEMCTL_LOG"; }

MF=$'host-op: rebuild-devbox fedora-dev\ntear down + resurrect\n%%DEVBOX-MANIFEST-BEGIN%%\nsession dev134 /home/core/repos/a\n%%DEVBOX-MANIFEST-END%%'

echo "== FRESH phase: authorize + validate manifest, then FIRE workload-rebuild@ (ticket stays open) =="
newhome; export FAKE_BODY="$MF" FAKE_AUTHOR=arthur FAKE_PERM=admin FAKE_ISSUE=1; unset SCEN_UNIT_STATE
SCEN_NEWID=OLDID tick
if sys_has 'start --no-block workload-rebuild@fedora-dev.service' \
   && [ -f "$HOME/.local/state/host-agent/fedora-bootstrap-1.rebuild" ] \
   && ! has 'issue close'; then ok "authorized+valid → rebuild FIRED, marker written, ticket open"
else no "authorized+valid → rebuild FIRED" "expected workload-rebuild@ start + .rebuild marker + NO close"; fi

echo "== authorization: a NON-maintainer author is REFUSED before any rebuild (destructive-verb gate) =="
newhome; export FAKE_BODY="$MF" FAKE_AUTHOR=random FAKE_PERM=read
tick
if has 'REFUSED' && has 'lacks admin|maintain' && ! sys_has 'workload-rebuild@' \
   && [ ! -f "$HOME/.local/state/host-agent/fedora-bootstrap-1.rebuild" ]; then ok "author lacks maintain → REFUSED, no rebuild"
else no "author gate" "expected REFUSED + no workload-rebuild@ start + no marker"; fi

echo "== manifest: a malformed / missing manifest is REFUSED before any rebuild =="
newhome; export FAKE_BODY=$'host-op: rebuild-devbox fedora-dev\n%%DEVBOX-MANIFEST-BEGIN%%\nrun rm -rf /\n%%DEVBOX-MANIFEST-END%%' FAKE_AUTHOR=arthur FAKE_PERM=admin
tick
if has 'malformed session manifest' && ! sys_has 'workload-rebuild@'; then ok "malformed manifest → REFUSED, no rebuild"
else no "malformed manifest" "expected 'malformed session manifest' + no rebuild"; fi
newhome; export FAKE_BODY=$'host-op: rebuild-devbox fedora-dev\njust prose no block' FAKE_AUTHOR=arthur FAKE_PERM=admin
tick
if has 'no session manifest found' && ! sys_has 'workload-rebuild@'; then ok "no manifest block → REFUSED, no rebuild"
else no "no manifest block" "expected 'no session manifest found' + no rebuild"; fi

echo "== FINISH phase: rebuild done, KILL verified by ID, session restored+resumed, poller sweeping → DONE =="
newhome; export FAKE_BODY="$MF" FAKE_AUTHOR=arthur FAKE_PERM=admin
seed_marker OLDID 'dev134\t/home/core/repos/a'
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=claude SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweeping tick
if has 'host-agent: DONE' && has 'RESTORED+RESUMED 1/1' && has 'poller SWEEPING' && has 'issue close'; then ok "all-green → DONE (killed + restored + resumed + sweeping)"
else no "all-green DONE" "expected DONE + RESTORED+RESUMED 1/1 + poller SWEEPING + close"; fi

echo "== BITE: a GHOST (old container survives the kill) ⇒ FAILED, not success =="
newhome; export FAKE_BODY="$MF"
seed_marker OLDID 'dev134\t/home/core/repos/a'
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=no SCEN_PANE=claude SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweep tick
if has 'host-agent: FAILED' && has 'verification FAILED' && ! has 'host-agent: DONE'; then ok "old container alive → FAILED (kill-by-ID GHOST)"
else no "ghost" "expected FAILED + 'verification FAILED', never DONE"; fi

echo "== BITE: poller NOT observably sweeping in the new box ⇒ FAILED =="
newhome; export FAKE_BODY="$MF"
seed_marker OLDID 'dev134\t/home/core/repos/a'
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=claude SCEN_POLLER_ACTIVE=no tick
if has 'host-agent: FAILED' && has 'poller=down' && ! has 'host-agent: DONE'; then ok "poller silent → FAILED (not a PID — observable sweep required)"
else no "poller down" "expected FAILED + poller=down, never DONE"; fi

echo "== BITE: a restored-but-IDLE session (pane is a bare shell) ⇒ FAILED =="
newhome; export FAKE_BODY="$MF"
seed_marker OLDID 'dev134\t/home/core/repos/a'
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=bash SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweep tick
if has 'host-agent: FAILED' && has 'resumed only 0/1' && ! has 'host-agent: DONE'; then ok "idle session → FAILED (restored ≠ resuming)"
else no "idle session" "expected FAILED + 'resumed only 0/1', never DONE"; fi

echo "== BITE: a health-gate FAILURE (rolled back) surfaces as FAILED, never a half-built success =="
newhome; export FAKE_BODY="$MF"
seed_marker OLDID 'dev134\t/home/core/repos/a'
SCEN_UNIT_STATE=failed tick
if has 'host-agent: FAILED' && has 'rolled back' && ! has 'host-agent: DONE'; then ok "unit failed → FAILED-rolled-back (never DONE)"
else no "rollback surfaced" "expected FAILED + 'rolled back', never DONE"; fi

echo "== in-progress: rebuild still activating ⇒ WAIT (no verdict yet, ticket stays open) =="
newhome; export FAKE_BODY="$MF"
seed_marker OLDID 'dev134\t/home/core/repos/a'
SCEN_UNIT_STATE=activating tick
if ! has 'host-agent:' && ! has 'issue close'; then ok "activating → no premature verdict, ticket open"
else no "in-progress wait" "expected NO verdict comment + NO close while activating"; fi

echo
echo "rebuild-devbox-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
