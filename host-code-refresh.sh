#!/usr/bin/env bash
# host-code-refresh.sh — the HOST-SIDE SELF-ARMING ABSORBER (apparatus "F16").
#
# THE PROBLEM IT SOLVES ("merged ≠ live"): the host has no product image and no CI-published
# artifact — its own control code (the watcher/refresh/gate/halt scripts + their systemd --user
# units) becomes LIVE only when `main` is pulled into the control clone and the user-layer install
# is re-run (the maintainer's `git -C /opt/fedora-bootstrap pull && setup-user.sh`). So a PR the
# poller merges to `main` is NOT yet running on the host. THIS absorber closes that gap
# autonomously: on a timer it fast-forwards the control clone to merged `main` and re-runs the
# idempotent install subset factored out of setup-user.sh — with a FAIL-CLOSED live read-back that
# refuses to record success unless every installed artifact byte-matches the merged source.
#
# SAFETY POSTURE (this is safety-critical control-plane code):
#   * IDEMPOTENT + safe to run every tick — a no-op once the clone is at the applied sha.
#   * FAIL-CLOSED — it NEVER clobbers: a DIRTY or DIVERGED clone is REFUSED and left untouched
#     (it does NOT `reset --hard`/`clean`, unlike the workload-clone loop in setup-user.sh which
#     deliberately discards stray edits). It applies ONLY a clean strict FAST-FORWARD.
#     Mirrors setup-user.sh's `git merge --ff-only origin/main` discipline (v-history comment:
#     "KEEP `--ff-only` so a non-fast-forward … still SURFACES rather than being silently accepted
#     (a blind `reset --hard origin/main` would hide that attack)").
#   * NEVER BRICKS RECOVERABILITY — every failure path logs loudly and degrades to the status quo;
#     it never stops future ticks (the timer fires regardless of this oneshot's exit). The merged
#     git tree is always left intact and git-revertable; a bad readback records NO success, so the
#     absorber keeps re-attempting until it verifies clean or the operator intervenes.
#   * LIVE READ-BACK (R23/R10, the load-bearing part) — after applying, it re-reads each INSTALLED
#     artifact on disk and byte-compares it against the just-merged source. ANY mismatch ⇒ FAILURE:
#     no `applied.sha` is written, the mismatch is logged loudly, the process exits non-zero (unit
#     shows failed = operator-visible) while leaving the system recoverable. Only a fully verified
#     match writes `applied.sha` (the merged sha) as the success record.
#   * BOUNDED — git + systemctl calls are wrapped in `timeout`; no unbounded hang can wedge a tick.
#
# OWNERSHIP / UNIT SCOPE (disclosed, not assumed — see the report/README):
#   This runs as a systemd **--user** unit, as the operating user `core`, directly on the host
#   (NOT via `distrobox enter` — it needs only git + coreutils + `systemctl --user`, all host-side;
#   it needs no gh/CONTAINER_HOST, so it mirrors host-gh-refresh.service, not the box-entering
#   watchers). The "make merged → live" install half is IRREDUCIBLY user-scope: it writes the
#   user's own ~/.local/bin + ~/.config/systemd/user and drives the user's own systemd manager — a
#   root/system unit could not own those correctly. The default control clone /opt/fedora-bootstrap
#   is ROOT-owned (Day-0 `git clone` as root; the maintainer upgrade `git pull` runs as root), so a
#   --user process CANNOT `git merge` there. This absorber therefore REQUIRES the control clone to
#   be WRITABLE BY `core`; it does NOT silently assume write access — a non-writable / non-repo
#   clone is a fail-closed no-op with a loud one-line reason. Provisioning that writability is a
#   one-time root step (`chown -R core:core /opt/fedora-bootstrap`, or point HCR_CLONE at a
#   core-owned clone); until then the timer is harmless (each tick fail-closes), exactly like
#   host-gh-refresh.timer is safe-to-enable-before-provisioned.
#
# ENV KNOBS (production defaults; the HCR_* overrides are the TEST seams, UNSET in production):
#   HCR_CLONE      control clone to absorb         (default /opt/fedora-bootstrap)
#   HCR_BRANCH     the branch that is "live"        (default main)
#   HCR_BIN_DIR    script install dir              (default $HOME/.local/bin)
#   HCR_UNIT_DIR   systemd --user unit dir         (default $HOME/.config/systemd/user)
#   HCR_STATE_DIR  success-record dir              (default ${XDG_STATE_HOME:-$HOME/.local/state}/host-code-refresh)
#   HCR_GIT_TIMEOUT / HCR_SC_TIMEOUT  bounded call budgets (seconds; default 120 / 30)
#
# `--selftest` unit-tests the PURE decision core + the manifest shape with no git/systemctl/network
# (podman-free; run by the host live-gate's Containerfile.livegate). The full mock end-to-end lives
# in validation/host-code-refresh.test.sh.
set -uo pipefail

log()  { printf '[host-code-refresh] %s\n' "$*"; }
warn() { printf '[host-code-refresh] %s\n' "$*" >&2; }

# ---- THE MANAGED MANIFEST (single source of truth; the absorber INSTALLS and VERIFIES exactly this
#      set, and setup-user.sh re-uses hcr_install_from for the same set — see setup-user.sh) --------
# Emits one `MODE<TAB>SRC_RELPATH<TAB>DEST_ABSPATH` line per user-scope artifact this absorber keeps
# live: the autonomous-machinery SCRIPTS (0755 → $HCR_BIN_DIR) and their systemd --user UNITS (0644
# → $HCR_UNIT_DIR). It DELIBERATELY excludes the heredoc-GENERATED wrappers setup-user.sh writes
# inline (the `claude`/`claudebox-rebuild` launchers + the claudebox-rebuild*.{service,path,timer}):
# those have no standalone source file to copy or byte-verify, so a change to THEM still needs a full
# setup-user.sh run (box rebuild / maintainer) — a disclosed, bounded gap, not a silent one.
hcr_manifest() {
    local bin="${HCR_BIN_DIR:-$HOME/.local/bin}"
    local unit="${HCR_UNIT_DIR:-$HOME/.config/systemd/user}"
    local s
    # autonomous-machinery scripts (mode 0755 → bin)
    for s in \
        container-refresh.sh \
        claudebox-busy-probe.sh \
        validate-candidate.sh \
        build-candidate.sh \
        throwaway-sweep.sh \
        live-gate-run.sh \
        live-gate-watch.sh \
        fleet-halt.sh \
        host-agent-watch.sh \
        gh-app-auth.sh \
        host-gh-refresh.sh \
        host-code-refresh.sh
    do
        printf '0755\t%s\t%s\n' "$s" "$bin/$s"
    done
    # systemd --user units (mode 0644 → unit dir); DEST basename strips the systemd-units/ prefix
    for s in \
        workload-refresh@.service \
        workload-refresh@.timer \
        workload-refresh-retry@.service \
        workload-refresh-retry@.timer \
        workload-rebuild@.service \
        claudebox-up.service \
        live-gate-watch.service \
        live-gate-watch.timer \
        host-agent-watch.service \
        host-agent-watch.timer \
        host-gh-refresh.service \
        host-gh-refresh.timer \
        host-code-refresh.service \
        host-code-refresh.timer
    do
        printf '0644\tsystemd-units/%s\t%s\n' "$s" "$unit/$s"
    done
}

# Install every manifest artifact from CLONE into place (idempotent). `install -D` creates parent
# dirs + copies + sets mode atomically. A missing source is a hard error (the tree is incomplete).
hcr_install_from() {
    local clone="$1" mode src dst rc=0
    while IFS=$'\t' read -r mode src dst; do
        [ -n "$mode" ] || continue
        if [ ! -f "$clone/$src" ]; then
            warn "install: MISSING source $clone/$src — refusing to install a partial set"
            rc=1; continue
        fi
        install -D -m "$mode" "$clone/$src" "$dst" || { warn "install FAILED: $clone/$src -> $dst"; rc=1; }
    done < <(hcr_manifest)
    return "$rc"
}

# LIVE READ-BACK (fail-closed). Re-read each INSTALLED artifact on disk and byte-compare it to the
# just-merged source in CLONE. Returns 0 only if EVERY installed artifact matches; logs each drift
# loudly and returns 1 on ANY mismatch/missing. This is the load-bearing verification: it proves the
# merged code is what is actually on disk, not merely that an install command was issued.
hcr_verify_from() {
    local clone="$1" mode src dst rc=0 n=0
    while IFS=$'\t' read -r mode src dst; do
        [ -n "$mode" ] || continue
        n=$((n + 1))
        if [ ! -f "$dst" ]; then
            warn "READBACK MISMATCH: installed artifact MISSING: $dst"
            rc=1; continue
        fi
        if ! cmp -s "$dst" "$clone/$src"; then
            warn "READBACK MISMATCH: on-disk $dst != merged source $clone/$src"
            rc=1
        fi
    done < <(hcr_manifest)
    [ "$rc" = 0 ] && log "readback: all $n installed artifacts match the merged source"
    return "$rc"
}

# Re-materialise the merged unit definitions + ensure the managed timers/owner are enabled + running.
# Mirrors setup-user.sh's final `daemon-reload` + `enable --now` block. Script changes go live on the
# NEXT tick automatically (the watchers re-exec their script every fire), so no service restart is
# forced here; a changed long-running unit definition (e.g. claudebox-up.service) takes full effect on
# the next box rebuild. Bounded + best-effort (|| true) so a transient systemd hiccup never bricks a
# tick or blocks the readback that follows.
hcr_reload_restart() {
    local sc_t="${HCR_SC_TIMEOUT:-30}" u
    timeout "$sc_t" systemctl --user daemon-reload || warn "daemon-reload failed (non-fatal; continuing)"
    for u in \
        host-code-refresh.timer \
        host-gh-refresh.timer \
        live-gate-watch.timer \
        host-agent-watch.timer \
        claudebox-up.service
    do
        timeout "$sc_t" systemctl --user enable --now "$u" || warn "enable --now $u failed (non-fatal)"
    done
}

# ---- PURE decision core (unit-tested by --selftest; NO git/systemctl/network) --------------------
# Given the two shas, whether HEAD is an ANCESTOR of the remote (rc 0 = yes, FF possible), and
# whether the tree is DIRTY (1 = dirty), name the action. Order matters: up-to-date wins first, then
# a dirty tree is refused, then a strict fast-forward, else diverged.
hcr_decide() {
    local local_sha="$1" remote_sha="$2" ancestor_rc="$3" dirty="$4"
    if [ "$local_sha" = "$remote_sha" ]; then echo UPTODATE; return 0; fi
    if [ "$dirty" = 1 ];                  then echo DIRTY;    return 0; fi
    if [ "$ancestor_rc" = 0 ];            then echo FF;       return 0; fi
    echo DIVERGED
}

# ---- the absorber -------------------------------------------------------------------------------
hcr_main() {
    local clone="${HCR_CLONE:-/opt/fedora-bootstrap}"
    local branch="${HCR_BRANCH:-main}"
    local state="${HCR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/host-code-refresh}"
    local applied="$state/applied.sha"
    local gt="${HCR_GIT_TIMEOUT:-120}"
    mkdir -p "$state" 2>/dev/null || true

    # ---- preconditions (fail-closed → loud no-op, exit 0; NOT provisioned/transient is expected) ----
    command -v git >/dev/null 2>&1 || { warn "git not found on host — cannot absorb; no-op"; return 0; }
    if [ ! -d "$clone/.git" ]; then
        warn "control clone $clone is not a git repo — not provisioned; no-op"
        return 0
    fi
    # Do NOT assume write access to a possibly root-owned clone. A merge needs to write .git; refuse
    # loudly (with the fix) rather than error obscurely each tick.
    if [ ! -w "$clone" ] || [ ! -w "$clone/.git" ]; then
        warn "control clone $clone is not writable by $(id -un) — REFUSING (one-time fix: as root," \
             "'chown -R $(id -un):$(id -un) $clone', or set HCR_CLONE to a core-owned clone); no-op"
        return 0
    fi

    # ---- fetch (bounded; a network blip is a skipped tick, never a hang) ----
    if ! GIT_TERMINAL_PROMPT=0 timeout "$gt" git -C "$clone" fetch --quiet origin "$branch" 2>/dev/null; then
        warn "git fetch origin $branch failed (network/auth?) — skipping this tick"
        return 0
    fi

    # ---- read state ----
    local cur local_sha remote_sha anc dirty short
    cur="$(git -C "$clone" symbolic-ref --quiet --short HEAD 2>/dev/null || echo '')"
    if [ "$cur" != "$branch" ]; then
        warn "control clone is on '${cur:-<detached>}', not '$branch' — REFUSING (won't apply onto a" \
             "non-$branch checkout); no-op"
        return 0
    fi
    local_sha="$(git -C "$clone" rev-parse HEAD 2>/dev/null || echo '')"
    remote_sha="$(git -C "$clone" rev-parse "origin/$branch" 2>/dev/null || echo '')"
    if [ -z "$local_sha" ] || [ -z "$remote_sha" ]; then
        warn "could not resolve HEAD or origin/$branch — skipping this tick"
        return 0
    fi
    if [ -n "$(git -C "$clone" status --porcelain 2>/dev/null)" ]; then dirty=1; else dirty=0; fi
    if git -C "$clone" merge-base --is-ancestor "$local_sha" "$remote_sha" 2>/dev/null; then anc=0; else anc=1; fi
    short="$(printf '%s' "$remote_sha" | cut -c1-12)"

    local decision; decision="$(hcr_decide "$local_sha" "$remote_sha" "$anc" "$dirty")"

    case "$decision" in
        UPTODATE)
            # A true no-op ONLY when the success record confirms this sha is already applied.
            # If applied.sha is absent/stale (a prior readback failed, or a merge landed without a
            # confirmed install), REAPPLY-and-verify to self-heal — do NOT silently trust the tree.
            if [ -f "$applied" ] && [ "$(cat "$applied" 2>/dev/null)" = "$local_sha" ]; then
                return 0   # silent no-op — already live and verified
            fi
            log "clone at $short but applied.sha absent/stale — running install + readback to confirm"
            decision=REAPPLY
            ;;
    esac

    case "$decision" in
        DIRTY)
            warn "clone has UNCOMMITTED changes — REFUSING (left untouched, not clobbered); no-op"
            return 0
            ;;
        DIVERGED)
            warn "origin/$branch does NOT fast-forward HEAD (diverged/force-push?) — REFUSING" \
                 "(left untouched); no-op"
            return 0
            ;;
        FF)
            log "fast-forward available: $(printf '%s' "$local_sha" | cut -c1-12) -> $short — applying"
            if ! timeout "$gt" git -C "$clone" merge --ff-only "origin/$branch" >/dev/null 2>&1; then
                warn "git merge --ff-only unexpectedly failed after FF check — leaving clone as-is"
                return 1
            fi
            ;;
        REAPPLY)
            : # tree already at target; install + verify only, no merge
            ;;
    esac

    local merged_sha; merged_sha="$(git -C "$clone" rev-parse HEAD 2>/dev/null || echo '')"
    [ -n "$merged_sha" ] || { warn "post-merge HEAD unreadable — aborting apply"; return 1; }

    # ---- apply: (re)install the merged artifacts, reload/enable the units ----
    if ! hcr_install_from "$clone"; then
        warn "install of the managed set FAILED — NOT recording success; will retry next tick"
        return 1
    fi
    hcr_reload_restart

    # ---- LIVE READ-BACK (fail-closed) — the merged sha is recorded ONLY on a verified match ----
    if hcr_verify_from "$clone"; then
        printf '%s\n' "$merged_sha" > "$applied"
        log "APPLIED + VERIFIED merged sha $short — recorded to $applied"
        return 0
    fi
    warn "READBACK FAILED — installed artifacts do NOT all match merged $short; NOT recording success." \
         "System left recoverable (merged tree intact, git-revertable); absorber will re-attempt."
    return 1
}

# ---- selftest: exercise the PURE decision core + manifest shape (no git/systemctl/network) --------
# Guarded on DIRECT execution too, so a sourced context (setup-user.sh reusing the functions) whose
# own $1 is "--selftest" can never trip the branch and exit the sourcing shell.
if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--selftest" ]; then
    f=0
    d(){ local g; g="$(hcr_decide "$2" "$3" "$4" "$5")"; [ "$g" = "$6" ] && echo "ok: $1" \
         || { echo "FAIL: $1 — got '$g' want '$6'"; f=1; }; }
    #   desc                              local  remote ancestorRC dirty  want
    d "equal shas ⇒ up-to-date"           A      A      0          0      UPTODATE
    d "equal shas even if dirty"          A      A      0          1      UPTODATE
    d "behind + clean + FF ⇒ apply"       A      B      0          0      FF
    d "behind + DIRTY ⇒ refuse"           A      B      0          1      DIRTY
    d "not-ancestor + clean ⇒ diverged"   A      B      1          0      DIVERGED
    d "not-ancestor + dirty ⇒ dirty-wins" A      B      1          1      DIRTY
    # manifest shape: every line is MODE(0755|0644)<TAB>SRC<TAB>DEST, non-empty, self-included
    manifest_out="$(HOME=/nonexistent hcr_manifest)"
    lines=0; bad=0; self=0
    while IFS=$'\t' read -r m s dpath; do
        [ -n "$m" ] || continue
        lines=$((lines + 1))
        case "$m" in 0755|0644) ;; *) bad=1;; esac
        [ -n "$s" ] && [ -n "$dpath" ] || bad=1
        [ "$s" = "host-code-refresh.sh" ] && self=1
    done <<EOF
$manifest_out
EOF
    { [ "$lines" -ge 20 ] && [ "$bad" = 0 ] && [ "$self" = 1 ]; } \
        && echo "ok: manifest shape ($lines entries, well-formed, self-included)" \
        || { echo "FAIL: manifest shape — lines=$lines bad=$bad self=$self"; f=1; }
    [ "$f" = 0 ] && echo "ALL HOST-CODE-REFRESH SELFTESTS PASS" || echo "HOST-CODE-REFRESH SELFTESTS FAILED"
    exit "$f"
fi

# Run the absorber only when EXECUTED (systemd ExecStart / CLI); when SOURCED (setup-user.sh reuses
# the manifest/install functions) only the definitions above are pulled in.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    hcr_main "$@"
    exit $?
fi
