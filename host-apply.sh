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
#     guard). Before fetching, the clone's `remote.origin.url` is matched against an ANCHORED ALLOWLIST
#     of the canonical control-repo forms (ha_origin_allowed — a whole-string `=` compare, NOT a
#     `*substring*`: a repointed origin that merely CONTAINS the slug, e.g.
#     file:///…/oso-gato/fedora-bootstrap or https://evil.tld/oso-gato/fedora-bootstrap, is REFUSED), so
#     only the real control repo is ever a fetch source. The fetched sha is read from FETCH_HEAD (set by
#     THIS fetch), which the agent cannot forge (no push to the merge-gated `main`).
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
#   3  REFUSED — repointed origin, dirty / diverged (non-fast-forward) clone, un-provisioned, or `main` unfetchable
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

# ORIGIN-URL guard — an ANCHORED ALLOWLIST, never a substring (the #133 blocker). The clone is
# core-writable, so the agent could repoint origin; a `*slug*` substring test WRONGLY accepts any URL
# that merely CONTAINS the slug — file:///…/oso-gato/fedora-bootstrap (no creds needed), or
# https://evil.tld/oso-gato/fedora-bootstrap — and would then fetch attacker content = arbitrary root.
# Here every candidate is compared WHOLE-STRING with `=`. The canonical forms are derived from the
# pinned slug (APPLY_REPO_MATCH, `:-` default so an EMPTY seam falls back to the real slug rather than
# matching everything). FAIL-CLOSED: an empty/unknown URL matches nothing. Test seam APPLY_ORIGIN_ALLOW
# (space-separated EXACT URLs; `sudo` env_reset strips every APPLY_* in production — header) lets the mock
# admit its local bare-repo path without loosening the production anchored match.
ha_origin_allowed() { # <origin_url>
  local url="$1" slug="${APPLY_REPO_MATCH:-oso-gato/fedora-bootstrap}" cand
  [ -n "$url" ] || return 1
  if [ -n "${APPLY_ORIGIN_ALLOW:-}" ]; then
    for cand in $APPLY_ORIGIN_ALLOW; do [ "$url" = "$cand" ] && return 0; done
    return 1
  fi
  for cand in "https://github.com/$slug"     "https://github.com/$slug.git" \
              "git@github.com:$slug"          "git@github.com:$slug.git" \
              "ssh://git@github.com/$slug"    "ssh://git@github.com/$slug.git"; do
    [ "$url" = "$cand" ] && return 0
  done
  return 1
}

# ---- QUADLET-CHANGE DETECTION (increment 2: config-converge is not enough for a running container) ----
# A re-run of setup.sh may REWRITE a deployed workload Quadlet (~<user>/.config/containers/systemd/
# <name>.container) — e.g. #229 uncommenting the fitness `Secret=`/`Environment=` lines. That changes the
# file ON DISK + daemon-reloads, but the RUNNING container keeps its old env until it is RECREATED. So the
# executor records WHICH workload Quadlets actually changed (sha256 before vs after the apply); the host
# agent reads that signal and files an APPROVAL-GATED rebuild-devbox recreate for the changed dev box (the
# session-dropping act stays maintainer-gated + reuses the proven R17 restore lineage). PURE where it can be.
#
# ha_quadlet_shas <dir> -> "<name>\t<sha>" per <name>.container (name = basename minus .container); the
# SORTED, whitespace-free lines make ha_changed_quadlets a pure string compare. Missing dir ⇒ no lines.
ha_quadlet_shas() { # <dir>
  local dir="$1" f n s
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.container; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .container)"
    s="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
    printf '%s\t%s\n' "$n" "$s"
  done | sort
}
# ha_changed_quadlets <before-shas> <after-shas> -> changed workload names, one per line (PURE, unit-tested).
# CHANGED = present AFTER with a sha that differs from (or was absent) BEFORE. A REMOVED quadlet is NOT
# changed (nothing to recreate). An unreadable sha ("" field) never spuriously matches a real one.
ha_changed_quadlets() { # <before> <after>  (after fed to awk via stdin so an empty after still yields none)
  local before="$1"
  printf '%s\n' "$2" | awk -v before="$before" '
    BEGIN{ n=split(before, B, "\n"); for(i=1;i<=n;i++){ if(B[i]=="") continue; t=index(B[i],"\t"); if(t){ nm=substr(B[i],1,t-1); pre[nm]=substr(B[i],t+1) } } }
    { if($0=="") next; t=index($0,"\t"); if(!t) next; nm=substr($0,1,t-1); sh=substr($0,t+1);
      if(!(nm in pre) || pre[nm]!=sh) print nm }
  '
}
# ha_write_changed <before-shas> <quadlet-dir> <signal-path> <state-dir> (I/O): capture the AFTER shas,
# compute the changed workloads, and write them (one per line; EMPTY on a no-op) to the signal file
# WORLD-READABLE (the host agent is uid 1000). Called on EVERY rc-0 terminal path so the signal always
# reflects THIS apply (the agent reads it only on rc 0). A write failure degrades to no-recreate (safe).
ha_write_changed() { # <before> <qdir> <signal> <state>
  local before="$1" qdir="$2" signal="$3" state="$4" after changed
  after="$(ha_quadlet_shas "$qdir")"
  changed="$(ha_changed_quadlets "$before" "$after")"
  printf '%s' "$changed" > "$signal" 2>/dev/null || { warn "could not write quadlet-changed signal $signal — no recreate will be filed"; return 0; }
  chmod 0644 "$signal" 2>/dev/null || true
  chmod 0755 "$state"  2>/dev/null || true      # uid 1000 must traverse the root-owned state dir to read the signal
  if [ -n "$changed" ]; then
    log "workload Quadlet(s) CHANGED on disk — the new env is NOT yet live on the running container: $(printf '%s' "$changed" | tr '\n' ' ')(the host agent files an approved-gated recreate)"
  else
    log "no deployed workload Quadlet changed by this apply — no recreate needed"
  fi
}

# ---- the apply, run as ROOT ------------------------------------------------------------------------
# Test seams (APPLY_*) are read ONLY here; in production `sudo` env_reset strips them (see header), so
# the agent cannot influence any of these — the executor takes the hardcoded, merge-gated defaults.
ha_main() {
  local clone="${APPLY_CLONE:-/opt/fedora-bootstrap}"
  local branch="${APPLY_BRANCH:-main}"
  local U="${APPLY_USER:-core}"
  local state="${APPLY_STATE_DIR:-/var/lib/fedora-bootstrap/host-apply}"             # root-owned: the applied.sha record is unforgeable by the agent
  local applied="$state/applied.sha"
  local gt="${APPLY_GIT_TIMEOUT:-120}"
  # increment 2 — the deployed workload Quadlets + the changed-quadlet signal the host agent reads to
  # decide whether an (approved-gated) recreate is needed. The agent runs as uid 1000, so the signal must
  # be world-readable (chmod'd on write); a stale signal is never read (the agent reads it ONLY on rc 0,
  # and every rc-0 terminal path rewrites it fresh, empty on a no-op).
  local qdir="${APPLY_QUADLET_DIR:-/home/$U/.config/containers/systemd}"
  local changed_signal="${APPLY_CHANGED_SIGNAL:-$state/quadlet-changed}"
  mkdir -p "$state" 2>/dev/null || true

  _HA_GITRUN="${APPLY_GIT_RUNNER-runuser -u $U --}"; _HA_CLONE="$clone"; _HA_GT="$gt"   # arm gitc (used here + in ha_rollback)

  command -v git >/dev/null 2>&1 || { warn "git not found — cannot apply; refusing"; return 3; }
  [ -d "$clone/.git" ] || { warn "control clone $clone is not a git repo — not provisioned; refusing"; return 3; }

  # ---- REFUSE a repointed origin (the clone is core-writable): its remote URL must be EXACTLY one of the
  #      canonical control-repo forms (ANCHORED, not a substring), else the agent could point origin at
  #      attacker content that merely contains the slug and fetch it = arbitrary root. ----
  local origin_url; origin_url="$(gitc config --get remote.origin.url 2>/dev/null || echo '')"
  if ! ha_origin_allowed "$origin_url"; then
    warn "clone origin '$origin_url' is not the canonical control repo — REFUSING (possible repoint); untouched"; return 3
  fi

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
    UPTODATE)       ha_write_changed '' "$qdir" "$changed_signal" "$state"; log "already at merged main $short and readback-verified — no-op"; return 0 ;;
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

  # increment 2 — snapshot the deployed workload Quadlets BEFORE the apply (re-run of setup.sh may rewrite one).
  local before_q; before_q="$(ha_quadlet_shas "$qdir")"

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

  # increment 2 — record WHICH deployed workload Quadlets changed (env-on-disk changed; the running
  # container is stale). The host agent reads this signal + files an approved-gated recreate.
  ha_write_changed "$before_q" "$qdir" "$changed_signal" "$state"

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

  # ORIGIN-URL anchored allowlist (the #133 blocker): the canonical forms pass; a substring-crafted URL
  # that merely CONTAINS the slug, a wrong host, or an empty URL is REFUSED. A `*slug*` substring match
  # would WRONGLY accept the three substring cases — these are the regression guard for exactly that.
  unset APPLY_REPO_MATCH APPLY_ORIGIN_ALLOW
  o(){ local r; if ha_origin_allowed "$2"; then r=allow; else r=refuse; fi; [ "$r" = "$3" ] && echo "ok: $1" \
       || { echo "FAIL: $1 — got '$r' want '$3'"; f=1; }; }
  o "canonical https"          "https://github.com/oso-gato/fedora-bootstrap"        allow
  o "canonical https .git"     "https://github.com/oso-gato/fedora-bootstrap.git"    allow
  o "canonical ssh scp-form"   "git@github.com:oso-gato/fedora-bootstrap.git"        allow
  o "canonical ssh url-form"   "ssh://git@github.com/oso-gato/fedora-bootstrap.git"  allow
  o "substring file:// path"   "file:///tmp/evil/oso-gato/fedora-bootstrap"          refuse
  o "substring wrong host"     "https://evilgithub.com/oso-gato/fedora-bootstrap"    refuse
  o "substring attacker host"  "https://attacker.tld/oso-gato/fedora-bootstrap"      refuse
  o "empty origin"             ""                                                     refuse

  # QUADLET-CHANGE detection (increment 2): CHANGED = present AFTER with a differing/new sha; a REMOVED
  # quadlet is NOT changed (nothing to recreate). PURE — the trigger for the approved-gated recreate.
  q(){ local g; g="$(ha_changed_quadlets "$2" "$3" | tr '\n' ',')"; [ "$g" = "$4" ] && echo "ok: $1" \
       || { echo "FAIL: $1 — got '$g' want '$4'"; f=1; }; }
  q "unchanged => none"         $'fedora-dev\tAAA'                       $'fedora-dev\tAAA'                       ''
  q "env changed => that one"   $'fedora-dev\tAAA'                       $'fedora-dev\tBBB'                       'fedora-dev,'
  q "new quadlet => changed"    ''                                      $'fedora-dev\tAAA'                       'fedora-dev,'
  q "removed => NOT changed"    $'fedora-dev\tAAA'                       ''                                      ''
  q "one of two changed"        $'fedora-dev\tAAA\nfedora-desktop\tXXX'  $'fedora-dev\tBBB\nfedora-desktop\tXXX'  'fedora-dev,'
  q "empty both => none"        ''                                      ''                                      ''

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
