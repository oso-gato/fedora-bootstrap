#!/usr/bin/env bash
# host-apply.sh — the HOST SELF-APPLY EXECUTOR (apparatus F16b; issue #133).
#
# THE GAP IT CLOSES ("merged system-layer ≠ live"): the F16 absorber (host-code-refresh.sh) makes
# merged USER-layer code live automatically (~/.local/bin scripts + ~/.config/systemd/user units, on
# a --user timer, no host root). But the SYSTEM layer — setup-host.sh's packages / /etc / host
# services / the scoped sudoers / policy stamped into the box — becomes live ONLY when `main` is
# pulled and `setup.sh` is RE-RUN AS ROOT. On erebus that was the last routine manual act: the
# maintainer's `git -C /opt/fedora-bootstrap pull && setup.sh`. THIS executor is that act, done
# without a human: fast-forward the control clone to merged `main` and re-run the FULL, idempotent
# `setup.sh` — HEALTH-GATED with the same recovery-before-power discipline as a redeploy (a failed
# apply rolls back / surfaces, never a half-applied host) and with a FAIL-CLOSED live read-back
# (R17/#179 generalised to the host-apply seam: 'applied' means 'proven live', not 'the script ran').
#
# HOW IT IS REACHED (the ONLY sanctioned path — see the SECURITY posture): the box-resident host
# agent (host-agent-watch.sh, uid 1000, NO host root) cannot run setup.sh itself. It triggers the
# host --user oneshot `host-apply.service`, whose ExecStart is `sudo /usr/local/sbin/host-apply` —
# escalating to root through ONE pinned, argument-free NOPASSWD entry in policy/sudoers.claudebox.
# `sudo` env_reset then DROPS the caller's environment, so the APPLY_* test seams below are
# UNREACHABLE in production (the agent cannot inject a command into this root process); the executor
# runs with its hardcoded, merge-gated defaults. This is the same env-seam posture host-code-refresh
# uses, hardened by the sudo boundary.
#
# WHY THE AGENT CANNOT ABUSE IT (the trust chain — a root executor adjacent to an agent-writable clone
# is only safe if the agent can inject NOTHING it runs):
#   * ORIGIN URL-VERIFIED, FETCH AS THE OPERATING USER. All git runs as `core` via runuser (mirroring
#     F16's proven context: the clone is core-owned since v1.2.67, so core holds the credentials + the
#     safe.directory entry, and root operating a core-owned clone would trip git's dubious-ownership
#     guard). Before fetching, the clone's `remote.origin.url` is CHECKED against the canonical repo
#     (APPLY_REPO_MATCH) — a repointed origin (the clone is core-writable) is REFUSED, so only the real
#     control repo is ever a source. The fetched sha is read from FETCH_HEAD (set by THIS fetch), which
#     the agent cannot forge (no push to the merge-gated `main`).
#   * PRISTINE MATERIALISATION. It runs setup.sh from a ROOT-OWNED `git archive` of the exact FETCHED
#     sha (content-addressed), NOT from the core-writable working tree — so whatever the agent may have
#     written into /opt/fedora-bootstrap never executes. What runs is byte-for-byte merged `main`.
#   * MERGE-GATED CONTENT. `main` only moves through the poller's two independent gates (host live-gate
#     + fitness). This verb chooses WHEN to apply already-approved code; it injects no content.
#   * FAIL-CLOSED. Dirty / diverged (non-fast-forward) clone ⇒ REFUSED untouched (a diverged host clone
#     is a question, not a force-pull). Forward-apply failure / unhealthy ⇒ rolled back to the prior
#     commit + re-converged. Readback mismatch ⇒ success NOT recorded. Idempotent: same-sha ⇒ no-op.
#
# EXIT CONTRACT (host-apply.service's ExecMainStatus; host-agent-watch.sh maps it to the ticket verdict):
#   0  APPLIED + health-gated + readback-verified   (or an idempotent no-op — already current)
#   1  forward apply FAILED or host UNHEALTHY after → ROLLED BACK + re-converged to the prior commit
#   2  readback MISMATCH — live artifacts != merged main (applied != proven-live); success NOT recorded
#   3  REFUSED — dirty / diverged (non-fast-forward) clone, un-provisioned, or `main` unfetchable
#
# HONEST LIMIT (surfaced, not hidden): rollback re-runs the PRIOR commit's setup.sh to re-converge the
# managed config — it does NOT uninstall a package a failed forward-apply may have added (config
# convergence, not an image-digest swap). The merged tree is always intact + git-revertable.
#
# `--selftest` unit-tests the PURE decision core (no git / setup / network). The full mock end-to-end
# — clean apply, refuse-diverged, verify-fail→rollback, and the readback MUTATION — lives in
# validation/host-apply.test.sh.  **Control-plane (host self-apply).**
set -uo pipefail

log()  { printf '[host-apply] %s\n' "$*"; }
warn() { printf '[host-apply] %s\n' "$*" >&2; }

# ROOT-OWNED throwaway trees are tracked and reaped by ONE EXIT trap (a per-function RETURN trap would
# be clobbered by the nested rollback's own trap and leak the outer tree). ha_mktemp registers each.
_HA_TMPS=()
ha_mktemp() { local d; d="$(mktemp -d /tmp/host-apply.XXXXXX)" || return 1; _HA_TMPS+=("$d"); printf '%s' "$d"; }
_ha_cleanup() { local d; for d in "${_HA_TMPS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }

# gitc: run git in the control clone AS THE OPERATING USER (creds + ownership + safe.directory correct,
# exactly like the F16 absorber's own context — the clone is core-owned since v1.2.67). Root drops to the
# user via runuser; the test seam APPLY_GIT_RUNNER='' runs git directly (the test IS the target user).
# `sudo` env_reset strips APPLY_GIT_RUNNER in production ⇒ always runuser there. Globals set by ha_main.
# The timeout is baked IN (a bare `timeout <fn>` can't wrap a shell function), so every git call is bounded
# and never prompts; `env` also carries GIT_TERMINAL_PROMPT through runuser (which preserves the env).
_HA_GITRUN=""; _HA_CLONE=""; _HA_GT=120
# shellcheck disable=SC2086
gitc() { timeout "$_HA_GT" env GIT_TERMINAL_PROMPT=0 $_HA_GITRUN git -C "$_HA_CLONE" "$@"; }

# ---- PURE decision core (unit-tested by --selftest; NO git/setup/network) --------------------------
# Given HEAD vs the FETCHED sha, whether HEAD is an ANCESTOR of fetched (rc 0 = yes, FF possible),
# whether the tree is DIRTY (1 = dirty), and whether applied.sha already records the fetched sha
# (1 = yes), name the action. Order mirrors host-code-refresh's hcr_decide: at-target wins first
# (UPTODATE if verified, else REAPPLY to self-heal), then a dirty tree is refused, then a strict
# fast-forward, else diverged.
ha_decide() {
  local head="$1" fetched="$2" ancestor_rc="$3" dirty="$4" applied_matches="$5"
  if [ "$head" = "$fetched" ]; then
    [ "$applied_matches" = 1 ] && { echo UPTODATE; return 0; }
    echo REAPPLY; return 0
  fi
  if [ "$dirty" = 1 ];        then echo REFUSE-DIRTY;    return 0; fi
  if [ "$ancestor_rc" = 0 ];  then echo FF;              return 0; fi
  echo REFUSE-DIVERGED
}

# ---- the apply, run as ROOT ------------------------------------------------------------------------
# Test seams (APPLY_*) are read ONLY here; in production `sudo` env_reset strips them (see header), so
# the agent cannot influence any of these — the executor takes the hardcoded, merge-gated defaults.
ha_main() {
  local clone="${APPLY_CLONE:-/opt/fedora-bootstrap}"
  local branch="${APPLY_BRANCH:-main}"
  local U="${APPLY_USER:-core}"
  local repo_match="${APPLY_REPO_MATCH-oso-gato/fedora-bootstrap}"                    # the canonical control repo the origin URL must name
  local state="${APPLY_STATE_DIR:-/var/lib/fedora-bootstrap/host-apply}"             # root-owned: the applied.sha record is unforgeable by the agent
  local applied="$state/applied.sha"
  local gt="${APPLY_GIT_TIMEOUT:-120}"
  mkdir -p "$state" 2>/dev/null || true

  _HA_GITRUN="${APPLY_GIT_RUNNER-runuser -u $U --}"; _HA_CLONE="$clone"; _HA_GT="$gt"   # arm gitc (used here + in ha_rollback)

  command -v git >/dev/null 2>&1 || { warn "git not found — cannot apply; refusing"; return 3; }
  [ -d "$clone/.git" ] || { warn "control clone $clone is not a git repo — not provisioned; refusing"; return 3; }

  # ---- REFUSE a repointed origin (the clone is core-writable): its remote URL must name the canonical
  #      control repo, else the agent could fetch attacker content = arbitrary root. ----
  local origin_url; origin_url="$(gitc config --get remote.origin.url 2>/dev/null || echo '')"
  case "$origin_url" in
    *"$repo_match"*) : ;;
    *) warn "clone origin '$origin_url' does not name $repo_match — REFUSING (possible repoint); untouched"; return 3 ;;
  esac

  # ---- fetch merged `main` from origin AS $U (bounded; core's proven credentials). FETCH_HEAD carries
  #      the exact remote sha — set by THIS fetch, so it is not a pre-existing ref the agent could move. ----
  if ! gitc fetch --quiet origin "$branch" 2>/dev/null; then
    warn "git fetch origin $branch failed (network/auth?) — refusing (re-file to retry)"; return 3
  fi
  local head fetched dirty anc appl_match decision
  head="$(gitc rev-parse HEAD 2>/dev/null || echo '')"
  fetched="$(gitc rev-parse FETCH_HEAD 2>/dev/null || echo '')"
  [ -n "$head" ] && [ -n "$fetched" ] || { warn "could not resolve HEAD / FETCH_HEAD — refusing"; return 3; }
  if [ -n "$(gitc status --porcelain 2>/dev/null)" ]; then dirty=1; else dirty=0; fi
  if gitc merge-base --is-ancestor "$head" "$fetched" 2>/dev/null; then anc=0; else anc=1; fi
  if [ -f "$applied" ] && [ "$(cat "$applied" 2>/dev/null)" = "$fetched" ]; then appl_match=1; else appl_match=0; fi

  decision="$(ha_decide "$head" "$fetched" "$anc" "$dirty" "$appl_match")"
  local short; short="$(printf '%s' "$fetched" | cut -c1-12)"
  case "$decision" in
    UPTODATE)       log "already at merged main $short and readback-verified — no-op"; return 0 ;;
    REFUSE-DIRTY)   warn "control clone has UNCOMMITTED changes — REFUSING (a dirty host clone is a question, not a force-pull); untouched"; return 3 ;;
    REFUSE-DIVERGED)warn "origin main $short does NOT fast-forward HEAD (diverged/force-push?) — REFUSING (untouched)"; return 3 ;;
    FF)             log "fast-forward available: $(printf '%s' "$head" | cut -c1-12) -> $short — applying merged main" ;;
    REAPPLY)        log "clone at $short but applied.sha absent/stale — re-applying + readback to confirm live" ;;
  esac

  # ---- materialise the EXACT fetched sha into a ROOT-OWNED tree; setup.sh runs from THERE (never the
  #      core-writable working tree). This is what makes the run inject-proof. ----
  local tmp; tmp="$(ha_mktemp)" || { warn "mktemp failed"; return 1; }
  if ! gitc archive "$fetched" | tar -x -C "$tmp" 2>/dev/null; then
    warn "could not materialise merged tree $short — aborting apply (untouched)"; return 3
  fi

  local prior="$head"   # rollback target: the clone's pre-apply HEAD (the clone is NOT merged until success)

  # ---- FORWARD APPLY: run the merged setup.sh as root; unhealthy/failed => rollback ----
  if ! ha_run_setup "$tmp"; then
    warn "setup.sh apply FAILED — rolling back to prior $(printf '%s' "$prior" | cut -c1-12)"
    ha_rollback "$clone" "$prior"; return 1
  fi
  if ! ha_run_verify "$tmp"; then
    warn "host UNHEALTHY after apply (verify.sh FAILED) — rolling back to prior $(printf '%s' "$prior" | cut -c1-12)"
    ha_rollback "$clone" "$prior"; return 1
  fi

  # ---- FAIL-CLOSED READBACK: the live artifacts must byte-equal merged main, else applied != live ----
  if ! ha_readback "$tmp" "$U"; then
    warn "READBACK MISMATCH — live host artifacts do NOT all equal merged $short; NOT recording success." \
         "Host left recoverable (merged tree intact, git-revertable); re-file to retry."
    return 2
  fi

  # ---- success: record the applied sha + fast-forward the live clone (operator + F16 visibility) ----
  gitc merge --ff-only "$fetched" >/dev/null 2>&1 \
    || warn "post-apply ff-merge of $clone failed (cosmetic — the applied content was the pristine archive); continuing"
  printf '%s\n' "$fetched" > "$applied" 2>/dev/null || warn "could not record applied.sha"
  log "APPLIED + health-gated + readback-verified merged main $short — recorded to $applied"
  return 0
}

# Run the merged setup.sh as root. The APPLY_SETUP_CMD seam (tests only — sudo-stripped in production,
# see header) receives the materialised tree in $APPLY_TREE. Non-interactive (< /dev/null): an
# unattended re-apply takes env/defaults, exactly like the F16 absorber's install.
ha_run_setup() { # <tree>
  local tree="$1"
  if [ -n "${APPLY_SETUP_CMD:-}" ]; then APPLY_TREE="$tree" bash -c "$APPLY_SETUP_CMD"; return $?; fi
  bash "$tree/setup.sh" < /dev/null
}

# The HEALTH GATE: the host's own acceptance suite (verify.sh, Build Principle 8) is the host analogue
# of a redeploy's container healthcheck. It runs as the OPERATING USER (its checks are user-scope), so
# root drops to $U via runuser. Non-zero => unhealthy => rollback.
ha_run_verify() { # <tree>
  local tree="$1"
  if [ -n "${APPLY_VERIFY_CMD:-}" ]; then APPLY_TREE="$tree" bash -c "$APPLY_VERIFY_CMD"; return $?; fi
  runuser -u "${APPLY_USER:-core}" -- bash "$tree/verify.sh"
}

# ROLLBACK = re-converge to the PRIOR commit by re-running its setup.sh (best-effort). The clone HEAD is
# still `prior` (we only ff-merge on success), so we re-materialise `prior` and re-apply. HONEST LIMIT
# (header): this restores the managed config, not a package a failed forward-apply may have installed.
ha_rollback() { # <clone> <prior-sha>   (uses gitc — armed by ha_main)
  local clone="$1" prior="$2" rtmp
  rtmp="$(ha_mktemp)" || { warn "rollback: mktemp failed — host left as-is; SURFACING"; return 1; }
  if gitc archive "$prior" | tar -x -C "$rtmp" 2>/dev/null; then
    ha_run_setup "$rtmp" && { log "rolled back + re-converged to prior $(printf '%s' "$prior" | cut -c1-12)"; return 0; }
  fi
  warn "rollback re-converge did NOT complete cleanly — host may be inconsistent; SURFACING for the maintainer"
  return 1
}

# FAIL-CLOSED live READ-BACK. Re-read each installed artifact and byte-compare it to the merged source.
# DRY: it sources the merged tree's OWN host-code-refresh.sh (that file is pristine merged main — the
# SAME content just applied, so the readback logic can never skew from the code) and reuses the proven,
# tested hcr_verify_from (full USER-layer manifest) + hcr_same (byte-exact, coreutils-only). It then
# adds the SYSTEM-layer /usr/local/sbin artifacts setup-host.sh installs — proving the ROOT layer (the
# distinctive part of a full setup.sh apply, which F16 never touches) actually reached disk. Any
# mismatch/missing => 1 (fail-closed). $1 = materialised merged tree, $2 = operating user.
ha_readback() { # <tree> <user>
  local tree="$1" U="$2" rc=0 pair sbin src
  export HCR_BIN_DIR="${APPLY_BIN_DIR:-/home/$U/.local/bin}"
  export HCR_UNIT_DIR="${APPLY_UNIT_DIR:-/home/$U/.config/systemd/user}"
  # shellcheck source=/dev/null
  . "$tree/host-code-refresh.sh" 2>/dev/null || { warn "readback: cannot source $tree/host-code-refresh.sh"; return 1; }
  hcr_verify_from "$tree" || rc=1                              # user-layer (scripts + --user units)
  for pair in host-apply:host-apply.sh \
              cockpit-tailnet-serve:cockpit-tailnet-serve.sh \
              selinux-enforce-once:selinux-enforce-once.sh; do
    sbin="${APPLY_SBIN_DIR:-/usr/local/sbin}/${pair%%:*}"; src="$tree/${pair#*:}"
    [ -f "$src" ] || continue                                 # tolerate a tree without an optional system script
    if ! hcr_same "$sbin" "$src"; then warn "READBACK MISMATCH: system artifact $sbin != merged $src"; rc=1; fi
  done
  [ "$rc" = 0 ] && log "readback: all live artifacts (user + system layer) match merged main"
  return "$rc"
}

# ---- selftest: exercise ONLY the pure decision core (no git/setup/network) --------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--selftest" ]; then
  f=0
  d(){ local g; g="$(ha_decide "$2" "$3" "$4" "$5" "$6")"; [ "$g" = "$7" ] && echo "ok: $1" \
       || { echo "FAIL: $1 — got '$g' want '$7'"; f=1; }; }
  #   desc                                   head   fetched anc dirty applied  want
  d "at target + verified ⇒ uptodate"        A      A       0   0     1        UPTODATE
  d "at target + unverified ⇒ reapply"       A      A       0   0     0        REAPPLY
  d "at target dirty but verified ⇒ uptodate" A     A       0   1     1        UPTODATE
  d "behind + clean + FF ⇒ apply"            A      B       0   0     0        FF
  d "behind + DIRTY ⇒ refuse-dirty"          A      B       0   1     0        REFUSE-DIRTY
  d "not-ancestor + clean ⇒ diverged"        A      B       1   0     0        REFUSE-DIVERGED
  d "not-ancestor + dirty ⇒ dirty-wins"      A      B       1   1     0        REFUSE-DIRTY
  [ "$f" = 0 ] && echo "ALL HOST-APPLY SELFTESTS PASS" || echo "HOST-APPLY SELFTESTS FAILED"
  exit "$f"
fi

# Run only when EXECUTED (systemd/CLI). When SOURCED (the mock test reuses ha_decide/ha_readback) only
# the definitions are pulled in.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  trap _ha_cleanup EXIT
  ha_main "$@"
  exit $?
fi
