#!/usr/bin/env bash
# rebuild-devbox-dryrun.test.sh — MOCK end-to-end dry-run of the R17 `rebuild-devbox` verb
# (host-agent-watch.sh) with ZERO host contact. Runs on a plain CI runner / inside Containerfile.livegate
# (no podman, no host engine): `gh`, `systemctl` and `podman` are STUBBED on PATH so a fake ticket drives
# the whole KILL→REBUILD→(BOX-READY)→RESTORE→RESUME→(NUDGE→HANDSHAKE)→VERIFY state machine while nothing
# real is ever touched.
#
# These are the "tests that BITE" (mutation-checked — each asserts the exact verdict a broken
# implementation would get wrong):
#   * a rebuild that leaves the old container alive (a GHOST) ⇒ FAILED, not success (kill-by-ID);
#   * the fresh box's claudebox NOT YET READY ⇒ DEFER (no verdict, ticket open) — restore next tick;
#     and NEVER-ready past the deadline ⇒ FAILED (never a restore into idle shells) — the 0/N-idle race;
#   * RESUME-TO-ACTIVE (option-b): a session that CONFIRMS via the filesystem handshake (touched its
#     per-sid marker) ⇒ ACTIVELY CONTINUING; a claude that is UP but did not confirm ⇒ honestly reported
#     up-but-unconfirmed (NOT claimed working); a bare-shell claude ⇒ idle FAILURE;
#   * the poller not observably sweeping in the NEW container ⇒ FAILED (log activity, not a PID);
#   * a failed/rolled-back rebuild ⇒ FAILED, surfaced (never a half-built box reported as done);
#   * a DESTRUCTIVE verb from a non-maintainer author ⇒ REFUSED, no rebuild fired;
#   * a malformed / missing session manifest ⇒ REFUSED, no rebuild fired;
#   * the happy path ⇒ FIRE writes the marker + starts workload-rebuild@ (ticket stays open), then
#     FINISH reports DONE with sessions ACTIVELY CONTINUING + poller sweeping.
#   * THREE in-suite MUTATIONS (each sed must change the file, else its row fails vacuous): neutralize the
#     box-ready gate → a not-ready box is (wrongly) restored; neutralize session_working → an idle session
#     is (wrongly) claimed working; neutralize the nudge → the handshake never confirms (DONE never reached).
#
# Run:  bash validation/rebuild-devbox-dryrun.test.sh   → exit 0 = all cases pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../host-agent-watch.sh"
[ -f "$WATCH" ] || { echo "FATAL: host-agent-watch.sh not found at $WATCH"; exit 2; }
SID=0deceee8-34ab-4e41-be19-ba4210469eb6

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# ---- stub gh: one open ticket; serve body/author/permission per-case; log every mutating call. ----
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  api)
    url="$2"                                                        # gh api <URL> … — the URL is always arg 2
    case "$url" in
      *"/timeline"*) printf '%s' "${FAKE_TIMELINE:-}" ;;            # `approved`-label events, API order (oldest-first), "event\tactor" lines
      *"/collaborators/"*)                                          # per-login role: FAKE_PERM_<login> overrides, else FAKE_PERM (default admin)
        login="${url#*collaborators/}"; login="${login%%/*}"        # NB ${*#…} would strip EACH positional arg — use the scalar url
        pvar="FAKE_PERM_${login}"
        printf '%s' "${!pvar:-${FAKE_PERM:-admin}}" ;;
      *) : ;;
    esac ;;
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
# The RESUME-TO-ACTIVE handshake is modeled honestly: the per-sid marker is "present" ONLY IF the case says
# the session worked (SCEN_WORKED) AND the nudge that asks it to `touch <marker>` was ACTUALLY sent (grep
# the captured send-keys) — so neutralizing the nudge makes the handshake never confirm (mutation M3).
cat > "$BIN/podman" <<'EOF'
#!/usr/bin/env bash
a="$*"
case "$a" in
  "container inspect"*"{{.Id}}"*)   echo "${SCEN_NEWID:-NEWID}" ;;                 # id of the (new) container
  "container exists"*)  [ "${SCEN_OLD_GONE:-yes}" = yes ] && exit 1 || exit 0 ;;   # gone→rc1, alive(ghost)→rc0
  *"mkdir -p"*)         exit 0 ;;                                                  # marker dir create
  *"rm -f "*rebuild-resumed*) exit 0 ;;                                            # stale-marker clear
  *"distrobox enter"*)  [ "${SCEN_BOX_ENTER:-yes}" = yes ] && exit 0 || exit 1 ;;  # box_ready enterable probe
  *"test -e "*.assemble-failed*) [ "${SCEN_ASSEMBLE_FAILED:-no}" = yes ] && exit 0 || exit 1 ;;
  *"test -e "*.assembled*)       [ "${SCEN_ASSEMBLED:-yes}" = yes ] && exit 0 || exit 1 ;;
  *"test -e "*rebuild-resumed*)                                                    # the HANDSHAKE marker
    mk="${a##*test -e }"; mk="${mk%%[[:space:]]*}"
    { [ "${SCEN_WORKED:-yes}" = yes ] && grep -qF -- "touch $mk" "${RESUME_LOG:-/dev/null}" 2>/dev/null; } && exit 0 || exit 1 ;;
  *" test -d "*)        [ "${SCEN_CWD_OK:-yes}" = yes ] && exit 0 || exit 1 ;;
  *"tmux has-session"*) printf 'has-session %s\n' "$a" >> "${TMUX_LOG:-/dev/null}"
                        [ "${SCEN_MAIN_EXISTS:-no}" = yes ] && exit 0 || exit 1 ;; # does the 'main' base session exist yet?
  *"tmux new-session"*) printf 'new-session %s\n' "$a" >> "${TMUX_LOG:-/dev/null}"
                        [ "${SCEN_TMUX_NEW_OK:-yes}" = yes ] && exit 0 || exit 1 ;;
  *"tmux new-window"*)  printf 'new-window %s\n' "$a" >> "${TMUX_LOG:-/dev/null}"
                        [ "${SCEN_TMUX_NEW_OK:-yes}" = yes ] && exit 0 || exit 1 ;;
  *"tmux list-panes"*)  echo "${SCEN_PANE:-claude}" ;;                            # bare shell name ⇒ session_active=idle
  *"tmux send-keys"*)   printf '%s\n' "$a" >> "${RESUME_LOG:-/dev/null}"; exit 0 ;; # capture resume + nudge keystrokes
  *"tmux "*)            printf '%s\n' "$a" >> "${TMUX_LOG:-/dev/null}"; exit 0 ;;  # kill-window / kill-session etc.
  *"is-active"*)        [ "${SCEN_POLLER_ACTIVE:-yes}" = yes ] && exit 0 || exit 1 ;;  # poller active?
  *"journalctl"*)       [ -n "${SCEN_POLLER_LOG-x}" ] && echo "${SCEN_POLLER_LOG:-sweep}" ; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/gh" "$BIN/systemctl" "$BIN/podman"

pass=0; fail=0
newhome(){ HOME="$ROOT/home-$RANDOM$RANDOM"; export HOME; mkdir -p "$HOME";
  export GH_LOG="$HOME/gh.log";              : > "$GH_LOG"
  export SYSTEMCTL_LOG="$HOME/systemctl.log"; : > "$SYSTEMCTL_LOG"
  export RESUME_LOG="$HOME/resume.log";       : > "$RESUME_LOG"
  export TMUX_LOG="$HOME/tmux.log";           : > "$TMUX_LOG"; }
tmux_has(){ grep -qF -- "$1" "$TMUX_LOG"; }
# fast windows so the nudge/marker poll + settles don't stall the suite
tick_on(){ PATH="$BIN:$PATH" DEVBOX_RESUME_SETTLE=1 DEVBOX_POLLER_WINDOW=1 DEVBOX_WORK_WINDOW=1 DEVBOX_NUDGE_TRIES=1 DEVBOX_WORK_POLL=1 bash "$1" >/dev/null 2>&1 || true; }
tick(){ tick_on "$WATCH"; }
seed_marker(){ mkdir -p "$HOME/.local/state/host-agent"; printf '%s\n%b\n' "$1" "$2" > "$HOME/.local/state/host-agent/fedora-bootstrap-1.rebuild"; }
age_rebuild(){ touch -d '2 hours ago' "$HOME/.local/state/host-agent/fedora-bootstrap-1.rebuild"; }
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       %s\n       gh:  %s\n' "$1" "$2" "$(tr '\n' '|' <"$GH_LOG")"; }
has(){ grep -qF "$1" "$GH_LOG"; }
resume_has(){ grep -qF -- "$1" "$RESUME_LOG"; }

MF=$'host-op: rebuild-devbox fedora-dev\ntear down + resurrect\n%%DEVBOX-MANIFEST-BEGIN%%\nsession dev134 /home/core/repos/a\n%%DEVBOX-MANIFEST-END%%'
seed_v2(){ seed_marker OLDID "dev134\t/home/core/repos/a\t$SID"; }   # a v2 (by-id) restore marker

echo "== FRESH phase: authorize + validate manifest, then FIRE workload-rebuild@ (ticket stays open) =="
newhome; export FAKE_BODY="$MF" FAKE_AUTHOR=arthur FAKE_PERM=admin FAKE_ISSUE=1; unset SCEN_UNIT_STATE
SCEN_NEWID=OLDID tick
if grep -qF 'start --no-block workload-rebuild@fedora-dev.service' "$HOME/systemctl.log" \
   && [ -f "$HOME/.local/state/host-agent/fedora-bootstrap-1.rebuild" ] \
   && ! has 'issue close'; then ok "authorized+valid → rebuild FIRED, marker written, ticket open"
else no "authorized+valid → rebuild FIRED" "expected workload-rebuild@ start + .rebuild marker + NO close"; fi

echo "== R17 APPROVAL GATE: a bot-authored ticket with NO approval ⇒ PENDING (open, unconsumed, ONE ask) =="
newhome; export FAKE_BODY="$MF" FAKE_AUTHOR=appbot FAKE_PERM=read; unset FAKE_TIMELINE FAKE_PERM_arthur 2>/dev/null
tick
if has 'AWAITING APPROVAL' && ! has 'issue close' && ! grep -qF 'workload-rebuild@' "$HOME/systemctl.log" \
   && [ ! -f "$HOME/.local/state/host-agent/fedora-bootstrap-1.rebuild" ] \
   && [ ! -f "$HOME/.local/state/host-agent/fedora-bootstrap-1.done" ]; then ok "unapproved bot ticket → PENDING: ask posted, nothing fired, ticket open + unconsumed"
else no "pending path" "expected AWAITING APPROVAL comment + no rebuild + no close + no .done"; fi
tick   # marker-gated: a SECOND tick re-checks the approval but does NOT re-ask
if [ "$(grep -cF 'AWAITING APPROVAL' "$GH_LOG")" = 1 ]; then ok "second tick re-checks without re-asking (marker-gated)"
else no "re-ask gate" "expected exactly ONE awaiting-approval comment across two ticks"; fi

echo "== R17 APPROVAL GATE: the ONE-TAP maintainer-applied 'approved' label FIRES the rebuild =="
newhome; export FAKE_BODY="$MF" FAKE_AUTHOR=appbot FAKE_PERM=read FAKE_PERM_arthur=admin FAKE_TIMELINE=$'labeled\tarthur'; unset SCEN_UNIT_STATE
SCEN_NEWID=OLDID tick
if grep -qF 'start --no-block workload-rebuild@fedora-dev.service' "$HOME/systemctl.log" \
   && [ -f "$HOME/.local/state/host-agent/fedora-bootstrap-1.rebuild" ] && ! has 'issue close'; then ok "maintainer tap → FIRED, marker written, ticket open (the one-tap path)"
else no "approve fires" "expected workload-rebuild@ start + .rebuild marker + no close"; fi

echo "== R17 APPROVAL GATE trust boundary: App label INERT; a maintainer UN-label UN-approves =="
newhome; export FAKE_BODY="$MF" FAKE_AUTHOR=appbot FAKE_PERM=read FAKE_TIMELINE=$'labeled\tsomebot'; unset FAKE_PERM_arthur 2>/dev/null   # somebot resolves read ⇒ inert
tick
A1=ok; { has 'AWAITING APPROVAL' && ! grep -qF 'workload-rebuild@' "$HOME/systemctl.log"; } || A1=no
newhome; export FAKE_BODY="$MF" FAKE_AUTHOR=appbot FAKE_PERM=read FAKE_PERM_arthur=admin FAKE_TIMELINE=$'labeled\tarthur\nunlabeled\tarthur'   # newest = un-label
tick
A2=ok; { ! grep -qF 'workload-rebuild@' "$HOME/systemctl.log"; } || A2=no
if [ "$A1$A2" = okok ]; then ok "App-applied label authorizes NOTHING + maintainer un-label un-approves (both PENDING)"
else no "label trust boundary" "A1=$A1 (App label must not fire) A2=$A2 (un-label must not fire)"; fi

echo "== M4: neutralize approved_by_maintainer ⇒ the one-tap approval no longer fires (the gate bites) =="
MUT4="$ROOT/watch-m4.sh"; sed 's/elif approved_by_maintainer "$issue"; then/elif false; then/' "$WATCH" > "$MUT4"
if cmp -s "$WATCH" "$MUT4"; then no "M4 vacuous" "sed did not change the copy"; else
  newhome; export FAKE_BODY="$MF" FAKE_AUTHOR=appbot FAKE_PERM=read FAKE_PERM_arthur=admin FAKE_TIMELINE=$'labeled\tarthur'
  tick_on "$MUT4"
  if ! grep -qF 'workload-rebuild@' "$HOME/systemctl.log" && has 'AWAITING APPROVAL'; then ok "M4: mutant ignores the tap ⇒ the approve-fires row discriminates"
  else no "M4" "mutant fired or did not ask — the approval row would not bite"; fi
fi
unset FAKE_TIMELINE FAKE_PERM_arthur 2>/dev/null

echo "== manifest: a malformed / missing manifest is REFUSED before any rebuild =="
newhome; export FAKE_BODY=$'host-op: rebuild-devbox fedora-dev\n%%DEVBOX-MANIFEST-BEGIN%%\nrun rm -rf /\n%%DEVBOX-MANIFEST-END%%' FAKE_AUTHOR=arthur FAKE_PERM=admin
tick
if has 'malformed session manifest' && ! grep -qF 'workload-rebuild@' "$HOME/systemctl.log"; then ok "malformed manifest → REFUSED, no rebuild"
else no "malformed manifest" "expected 'malformed session manifest' + no rebuild"; fi
newhome; export FAKE_BODY=$'host-op: rebuild-devbox fedora-dev\njust prose no block' FAKE_AUTHOR=arthur FAKE_PERM=admin
tick
if has 'no session manifest found' && ! grep -qF 'workload-rebuild@' "$HOME/systemctl.log"; then ok "no manifest block → REFUSED, no rebuild"
else no "no manifest block" "expected 'no session manifest found' + no rebuild"; fi

echo "== BOX-READY gate: a not-yet-assembled box DEFERS (no verdict, ticket open) — restore next tick =="
newhome; export FAKE_BODY="$MF" FAKE_AUTHOR=arthur FAKE_PERM=admin; seed_v2
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_ASSEMBLED=no tick
if ! has 'host-agent:' && ! has 'issue close'; then ok "box not ready (fresh) → DEFER, no premature verdict"
else no "box-ready defer" "expected NO verdict + NO close while the box is not ready"; fi

echo "== BOX-READY gate: a box that NEVER becomes ready (past the deadline) ⇒ FAILED, never a restore =="
newhome; export FAKE_BODY="$MF"; seed_v2; age_rebuild
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_ASSEMBLED=no tick
if has 'host-agent: FAILED' && has 'never became ready' && ! has 'host-agent: DONE'; then ok "box never ready past deadline → FAILED (no idle-shell restore)"
else no "box never ready" "expected FAILED + 'never became ready'"; fi

echo "== FINISH happy: box ready, restored, HANDSHAKE-confirmed actively continuing, poller sweeping → DONE =="
newhome; export FAKE_BODY="$MF" FAKE_AUTHOR=arthur FAKE_PERM=admin; seed_v2
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=claude SCEN_WORKED=yes SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweeping tick
if has 'host-agent: DONE' && has 'ACTIVELY CONTINUING 1/1' && has 'handshake-confirmed' && has 'poller SWEEPING' && has 'issue close'; then ok "all-green → DONE (killed + restored + actively continuing + sweeping)"
else no "all-green DONE" "expected DONE + ACTIVELY CONTINUING 1/1 + handshake-confirmed + poller SWEEPING + close"; fi

echo "== RESUME cmd (D4/#191): a v1 manifest (no sid) resumes cwd-scoped with 'claude --continue' =="
newhome; export FAKE_BODY="$MF"; seed_marker OLDID 'dev134\t/home/core/repos/a'
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=claude SCEN_WORKED=yes SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweep tick
if resume_has 'claude --continue' && ! resume_has 'claude --resume'; then ok "no sid → resumed with 'claude --continue' (v1 backward-compat)"
else no "v1 resume" "expected send-keys 'claude --continue', never '--resume' — got: $(tr '\n' '|' <"$RESUME_LOG")"; fi

echo "== RESUME cmd (D4/#191): a v2 manifest (with sid) resumes THAT session by id — 'claude --resume <sid>' =="
newhome; export FAKE_BODY="$MF"; seed_v2
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=claude SCEN_WORKED=yes SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweep tick
if resume_has "claude --resume $SID" && ! resume_has 'claude --continue'; then ok "sid present → resumed 'claude --resume <sid>' (multi-tenant by-id, not --continue)"
else no "v2 resume-by-id" "expected send-keys 'claude --resume <sid>', never '--continue' — got: $(tr '\n' '|' <"$RESUME_LOG")"; fi

echo "== NUDGE: the restored session is SUBMITTED a continue-nudge asking it to touch its per-sid marker =="
newhome; export FAKE_BODY="$MF"; seed_v2
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=claude SCEN_WORKED=yes SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweep tick
if resume_has "touch /home/core/.local/state/rebuild-resumed/$SID" && resume_has 'Enter'; then ok "nudge submitted (literal touch <marker> + a discrete Enter)"
else no "nudge submit" "expected send-keys of 'touch <marker>' and an Enter — got: $(tr '\n' '|' <"$RESUME_LOG")"; fi

echo "== #1 FIX: the session is restored into a WINDOW of the shared 'main' group, not a standalone session =="
# Incident 2026-07-19: the executor restored each session as a STANDALONE 'tmux new-session -s <name>'. But every
# interactive login joins the 'main' GROUP ('tmux new-session -t main -s c\$\$' with 'destroy-unattached on'), and a
# grouped client sees only 'main's WINDOW set — so a standalone session is INVISIBLE to the operator's reconnect
# (proven on a throwaway: PROOF-1 a window added to 'main' is seen; PROOF-2 a standalone session is not). The
# restore now ensures the 'main' base then adds the session as a WINDOW of it ('new-window -t main:'), and the
# resume + nudge + active-probe all target 'main:<name>' — so a reconnecting login lands on the resumed window.
newhome; export FAKE_BODY="$MF"; seed_v2   # SCEN_MAIN_EXISTS defaults 'no' ⇒ the base 'main' is created first
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=claude SCEN_WORKED=yes SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweep tick
r1=ok
tmux_has 'new-window -d -t main: -n dev134'          || r1='no(window-not-in-main)'
tmux_has 'new-session -d -s main'                    || r1='no(main-base-not-ensured)'
tmux_has 'new-session -d -s dev134'                  && r1='no(restored-STANDALONE-the-bug)'
resume_has '-t main:dev134'                          || r1='no(resume-not-targeting-main-window)'
if [ "$r1" = ok ]; then ok "restored as a WINDOW of 'main' (base ensured, no standalone session, resume targets main:dev134)"
else no "restore-into-main" "$r1 — tmux: $(tr '\n' '|' <"$TMUX_LOG") | resume: $(tr '\n' '|' <"$RESUME_LOG")"; fi

echo "== RESUME-TO-ACTIVE: claude UP but NOT handshake-confirmed ⇒ honestly up-but-unconfirmed (not working) =="
newhome; export FAKE_BODY="$MF"; seed_v2
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=claude SCEN_WORKED=no SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweep tick
if has 'host-agent: FAILED' && has 'actively-continuing 0/1' && has 'claude-up-but-unconfirmed 1' && has 'up-unconfirmed' && ! has 'host-agent: DONE'; then ok "up but no handshake → up-but-unconfirmed (never claimed working)"
else no "up-unconfirmed" "expected FAILED + 'actively-continuing 0/1' + 'claude-up-but-unconfirmed 1', never DONE"; fi

echo "== RESUME-TO-ACTIVE: a bare-shell claude (never launched) ⇒ idle FAILURE =="
newhome; export FAKE_BODY="$MF"; seed_v2
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=bash SCEN_WORKED=no SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweep tick
if has 'host-agent: FAILED' && has 'actively-continuing 0/1' && has '(idle)' && ! has 'host-agent: DONE'; then ok "bare shell → idle FAILURE (claude never launched)"
else no "idle failure" "expected FAILED + 'actively-continuing 0/1' + '(idle)', never DONE"; fi

echo "== BITE: a GHOST (old container survives the kill) ⇒ FAILED, not success =="
newhome; export FAKE_BODY="$MF"; seed_v2
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=no SCEN_PANE=claude SCEN_WORKED=yes SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweep tick
if has 'host-agent: FAILED' && has 'verification FAILED' && ! has 'host-agent: DONE'; then ok "old container alive → FAILED (kill-by-ID GHOST)"
else no "ghost" "expected FAILED + 'verification FAILED', never DONE"; fi

echo "== #2 FIX: poller NOT yet sweeping but EVERY session confirmed (ok==total) ⇒ DONE-WITH-A-NOTE, never FAILED =="
# Incident 2026-07-19: a proven 2/2 handshake-confirmed resume reported FAILED because a COLD poller-service
# had not swept at check time (a fresh box reassembles the claudebox before poller-service can launch, so the
# poller warms up AFTER the sessions). Sessions are the rebuild's success criterion; a not-yet-sweeping poller
# is DONE-with-a-note (surfaced honestly, independently watched by the #173 poller-liveness watchdog), not a
# false FAILED. ok==total is the gate; the poller is verified best-effort and reported, never a merge blocker.
newhome; export FAKE_BODY="$MF"; seed_v2
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=claude SCEN_WORKED=yes SCEN_POLLER_ACTIVE=no tick
if has 'host-agent: DONE' && has 'ACTIVELY CONTINUING 1/1' && has 'NOT yet observably sweeping' \
   && ! has 'poller SWEEPING' && ! has 'host-agent: FAILED' && has 'issue close'; then ok "poller cold but sessions 1/1 → DONE-with-a-poller-NOTE (no false FAILED)"
else no "poller cold DONE-with-note" "expected DONE + ACTIVELY CONTINUING 1/1 + 'NOT yet observably sweeping' NOTE + close, never FAILED/poller SWEEPING"; fi

echo "== #2 GUARD: a genuine SESSION failure (ok<total) still FAILS even when the poller is also down =="
# The #2 fix relaxes ONLY the poller check; a session that did not come up ACTIVELY CONTINUING must still FAIL
# loudly (poller-down does not mask, nor is it masked by, a real session loss). ok<total dominates.
newhome; export FAKE_BODY="$MF"; seed_v2
SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=claude SCEN_WORKED=no SCEN_POLLER_ACTIVE=no tick
if has 'host-agent: FAILED' && has 'actively-continuing 0/1' && ! has 'host-agent: DONE'; then ok "session lost + poller down → FAILED (session failure dominates, never a false DONE)"
else no "session-loss dominates" "expected FAILED + 'actively-continuing 0/1', never DONE"; fi

echo "== BITE: a health-gate FAILURE (rolled back) surfaces as FAILED, never a half-built success =="
newhome; export FAKE_BODY="$MF"; seed_v2
SCEN_UNIT_STATE=failed tick
if has 'host-agent: FAILED' && has 'rolled back' && ! has 'host-agent: DONE'; then ok "unit failed → FAILED-rolled-back (never DONE)"
else no "rollback surfaced" "expected FAILED + 'rolled back', never DONE"; fi

echo "== in-progress: rebuild still activating ⇒ WAIT (no verdict yet, ticket stays open) =="
newhome; export FAKE_BODY="$MF"; seed_v2
SCEN_UNIT_STATE=activating tick
if ! has 'host-agent:' && ! has 'issue close'; then ok "activating → no premature verdict, ticket open"
else no "in-progress wait" "expected NO verdict comment + NO close while activating"; fi

echo "== MUTATIONS (each sed MUST change the file; each proves a real guard bites) =="
# M1 — neutralize the BOX-READY gate: a not-ready box is (wrongly) RESTORED instead of deferring.
MUT1="$ROOT/mut-boxready.sh"; sed 's/^box_ready(){ # <cid>/box_ready(){ return 0 # <cid>/' "$WATCH" > "$MUT1"
if cmp -s "$WATCH" "$MUT1"; then no "M1 vacuous" "sed did not change box_ready"; else
  newhome; export FAKE_BODY="$MF" FAKE_AUTHOR=arthur FAKE_PERM=admin; seed_v2
  SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_ASSEMBLED=no SCEN_PANE=claude SCEN_WORKED=yes SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweep tick_on "$MUT1"
  if has 'host-agent:'; then ok "M1: neutralized box-ready gate RESTORES a not-ready box (real script DEFERS) — gate bites"
  else no "M1" "mutant with box_ready→true should reach a verdict on a not-ready box"; fi
fi
# M2 — neutralize session_working: an IDLE (bare-shell) session is (wrongly) claimed working.
MUT2="$ROOT/mut-working.sh"; sed 's/^session_working(){ # <cid> <marker>/session_working(){ return 0 # <cid> <marker>/' "$WATCH" > "$MUT2"
if cmp -s "$WATCH" "$MUT2"; then no "M2 vacuous" "sed did not change session_working"; else
  newhome; export FAKE_BODY="$MF"; seed_v2
  SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=bash SCEN_WORKED=no SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweep tick_on "$MUT2"
  if has 'ACTIVELY CONTINUING 1/1' || has 'host-agent: DONE'; then ok "M2: forced session_working claims an idle session works — handshake verify bites"
  else no "M2" "mutant with session_working→true should claim the idle session actively continuing"; fi
fi
# M3 — neutralize the NUDGE: with no nudge sent, the handshake marker never confirms → DONE unreachable.
MUT3="$ROOT/mut-nudge.sh"; sed 's/^nudge_session(){ # <cid> <name> <marker>/nudge_session(){ return 0 # <cid> <name> <marker>/' "$WATCH" > "$MUT3"
if cmp -s "$WATCH" "$MUT3"; then no "M3 vacuous" "sed did not change nudge_session"; else
  newhome; export FAKE_BODY="$MF"; seed_v2
  SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=claude SCEN_WORKED=yes SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweep tick_on "$MUT3"
  if has 'actively-continuing 0/1' && ! has 'host-agent: DONE'; then ok "M3: no nudge ⇒ handshake never confirms ⇒ DONE unreachable — the nudge is what drives it"
  else no "M3" "mutant with a no-op nudge should never reach DONE (handshake unconfirmed)"; fi
fi
# M5 (#1) — revert the RESTORE to a STANDALONE session (the pre-fix bug): the session lands OUTSIDE the shared
# 'main' group where a reconnecting login can't see it. The #1 window-in-main check must then observe the standalone.
MUT5="$ROOT/mut-standalone.sh"; sed 's/tmux new-window -d -t main: -n "$name"/tmux new-session -d -s "$name"/' "$WATCH" > "$MUT5"
if cmp -s "$WATCH" "$MUT5"; then no "M5 vacuous" "sed did not change the restore target"; else
  newhome; export FAKE_BODY="$MF"; seed_v2
  SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=claude SCEN_WORKED=yes SCEN_POLLER_ACTIVE=yes SCEN_POLLER_LOG=sweep tick_on "$MUT5"
  if tmux_has 'new-session -d -s dev134'; then ok "M5: reverted restore makes a STANDALONE session (invisible to the 'main' login) — the #1 window-in-main check bites"
  else no "M5" "mutant reverting to 'new-session -s <name>' should restore a standalone session"; fi
fi
# M6 (#2) — re-require the poller for a DONE (the pre-fix gate: ok==total AND poller==sweeping): the incident
# state (poller cold, sessions 1/1) then falls to FAILED. The #2 no-false-FAILED row must observe the regression.
MUT6="$ROOT/mut-pollerreq.sh"; sed 's/if \[ "$ok" = "$total" \]; then/if [ "$ok" = "$total" ] \&\& [ "$poller" = sweeping ]; then/' "$WATCH" > "$MUT6"
if cmp -s "$WATCH" "$MUT6"; then no "M6 vacuous" "sed did not change the verdict gate"; else
  newhome; export FAKE_BODY="$MF"; seed_v2
  SCEN_UNIT_STATE=inactive SCEN_NEWID=NEWID SCEN_OLD_GONE=yes SCEN_PANE=claude SCEN_WORKED=yes SCEN_POLLER_ACTIVE=no tick_on "$MUT6"
  if has 'host-agent: FAILED' && ! has 'host-agent: DONE'; then ok "M6: re-requiring the poller FAILS a proven 1/1 resume on a cold poller — the #2 no-false-FAILED row bites"
  else no "M6" "mutant re-requiring poller==sweeping should FAIL the cold-poller-but-sessions-OK case"; fi
fi

echo
echo "rebuild-devbox-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
