#!/usr/bin/env bash
# live-gate-run.sh — gate ONE candidate PR on the host and post the verdict back.
#
# Model C (DYNAMIC, repo-set-agnostic): the PR's repo is NOT pre-cloned. Fetch the PR head into an
# EPHEMERAL temp tree ON DEMAND, read the repo's IN-TREE `.live-gate` contract, build + gate EVERY
# declared build target DISPOSABLY (build-candidate.sh -> localhost/disposable/*, never pushed,
# --rm/rmi'd; validate-candidate.sh live-runs + access-probes each), then `gh pr comment` the
# combined GREEN/RED verdict. ALL targets must be GREEN for an overall GREEN. The host MAY comment;
# it NEVER merges (gate-push.sh blocks merges) — fedora-dev iterates (RED) or Arthur merges (GREEN).
#
# Each gate runs in a SEPARATE disposable container that never touches the running workload, so it
# is NOT gated on the dev box's session (validation is never blocked by an active dev session).
#
# Usage: live-gate-run.sh <repo> <pr-number>
#   <repo>       the bare repo name under github.com/oso-gato (e.g. fedora-desktop)
#   <pr-number>  the open PR to gate
# Exit: 0 GREEN | 1 RED | 2 FATAL (bad args / missing builder — infra, NOT a verdict) |
#       3 SKIPPED (not gateable / PR-head fetch failed-soft) |
#       4 UNDELIVERED (verdict computed but the PR comment could not be posted — caller must re-gate)
# Codes 2 and 4 are NON-VERDICTS: the watcher must NOT write the per-SHA dedup marker for them, or
# the commit is buried with no comment ever reaching the PR.
#
# Contract (CFILE / FENCE / PROBE / HEALTH / secret + resource knobs) resolution order:
#   1. the candidate's OWN top-level `.live-gate` file (in-tree — preferred; auto-tracks the repo)
#   2. ~/.config/live-gate/<repo>.env  (host fallback preset, shipped by setup-user.sh)
#   3. a generic default (single target: Containerfile, image's own HEALTHCHECK, no probe)
# See validation/LIVE-GATE-HANDOFF.md for the `.live-gate` schema.
set -uo pipefail

REPO_NAME="${1:?usage: live-gate-run.sh <repo> <pr-number>}"
PR="${2:?pr-number required}"
case "$REPO_NAME" in */*|*:*) echo "FATAL: <repo> must be a bare name ($REPO_NAME)"; exit 2;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILDER="$HOME/.local/bin/build-candidate.sh"; [ -x "$BUILDER" ] || BUILDER="$HERE/build-candidate.sh"
[ -x "$BUILDER" ] || { echo "FATAL: build-candidate.sh not found (looked in ~/.local/bin and $HERE)"; exit 2; }

SLUG="oso-gato/$REPO_NAME"
# The ephemeral PR-head tree lives under ONE identifiable home-volume dir so the crash-orphan sweeper
# (throwaway-sweep.sh) can reap a tree this run leaks on `kill -9`/OOM (the EXIT trap only fires on a
# clean exit). The tiny LOG/PRESET temp FILES stay in $TMPDIR — they are bytes, not a quota concern.
FD_THROWAWAY_TMPDIR="${FD_THROWAWAY_TMPDIR:-$HOME/.cache/fd-throwaway}"; mkdir -p "$FD_THROWAWAY_TMPDIR" 2>/dev/null || true
SRC="$(mktemp -d "$FD_THROWAWAY_TMPDIR/lg.XXXXXX")"; LOG="$(mktemp)"; PRESET="$(mktemp)"
trap 'rm -rf "$SRC" "$LOG" "$PRESET"' EXIT

# ---- CLONE-ON-DEMAND: fetch ONLY the PR head into the ephemeral tree (no pre-placed clone) ----
# git init + a single shallow fetch of pull/<n>/head avoids cloning the default branch at all.
echo "[live-gate] fetching $SLUG#$PR head into $SRC"
if ! { git -C "$SRC" init -q \
    && git -C "$SRC" remote add origin "https://github.com/$SLUG" \
    && git -C "$SRC" fetch --depth 1 -q origin "pull/$PR/head" \
    && git -C "$SRC" checkout -q FETCH_HEAD; }; then
  echo "[live-gate] WARN: could not fetch $SLUG PR #$PR head; skipping (treat as not-gateable)"
  exit 3
fi
SHA="$(git -C "$SRC" rev-parse --short HEAD)"

# ---- STRUCTURAL GUARD: gateable ONLY if the candidate carries a top-level .live-gate and/or a
# Containerfile*. Otherwise SKIP GRACEFULLY (neutral comment, exit 3) — never error. This is what
# makes discovery repo-set-agnostic: a non-image repo that happens to get the label is skipped, not
# failed, so Arthur maintains no allow/deny list of "which repos are buildable".
if [ ! -f "$SRC/.live-gate" ] && ! ls "$SRC"/Containerfile* >/dev/null 2>&1; then
  echo "[live-gate] $SLUG#$PR @ $SHA: no Containerfile*/.live-gate at the repo top — not gateable"
  if gh pr comment "$PR" --repo "$SLUG" --body \
"**Host live-gate (Gate B): SKIPPED** — \`$REPO_NAME\` @ \`$SHA\` carries no top-level \`Containerfile*\` or \`.live-gate\`, so there is nothing to build/gate. Neutral skip, **not** a failure." \
    >/dev/null 2>&1; then
    exit 3
  else
    echo "[live-gate] WARN: skip-comment failed — exit 4 (UNDELIVERED; caller must re-gate, not dedup)"
    exit 4
  fi
fi

# ---- SAFE CONTRACT CONSUMER (hardening: NEVER execute a labelled PR's `.live-gate` as host shell) -
# The `.live-gate` travels in the UNTRUSTED PR head. The old consumer did `set -a; . "$PRESET"`,
# which EXECUTES the file as host shell at source-time: a line like FENCE_x="$(touch /tmp/x)" or
# `KEY=1; touch /tmp/x` would run arbitrary code ON THE HOST (RCE from a labelled PR). lg_load PARSES
# the file instead of sourcing it — it reads KEY=VALUE line by line, validates the key against the
# schema allowlist, strips ONE layer of surrounding quotes, and assigns with `printf -v` (NEVER eval,
# NEVER `.`). No shell expansion is ever performed on the file's contents, so command substitution /
# chaining in the file CANNOT run on the host.
#
# SAFETY PROPERTY — why each form is inert:
#   * single-quoted values are taken VERBATIM: `$(...)`, backticks, `&&`, `;`, `<`, `>` inside them
#     are literal characters, stored as a string and only ever run LATER, INSIDE the fenced
#     disposable container (HEALTH via --health-cmd, PROBE via `podman exec`) — never on the host.
#     This is the safe subset HEALTH_*/PROBE_* use (single-quote your command).
#   * double-quoted values: only the inert bash escapes (\" \$ \\ \`) are unescaped; $VAR is NOT
#     expanded; and command substitution ($( ) or a backtick) is REFUSED — outside single quotes it
#     has no inert reading, so its presence means the contract is hostile/malformed.
#   * unquoted values must be a single bare token (no whitespace / shell metacharacters), so
#     `KEY=1; touch /tmp/x` fails closed.
#   * keys are restricted to the live-gate schema (LIVE_GATE_TARGETS / CAND_* / the suffixed knobs),
#     so a contract can never clobber an arbitrary shell variable (PATH, IFS, ...).
# On ANY violation lg_load returns non-zero WITHOUT having executed anything; the caller posts a RED
# verdict and refuses to build/gate (a poisoned contract must NOT be allowed to silently skip Gate B).
lg_reason=""
lg_load(){
  local file="$1" line trimmed key rest body after more val
  local s i nn c nx closed remainder
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"          # strip leading whitespace for the tests below
    [ -z "$trimmed" ] && continue
    case "$trimmed" in '#'*) continue;; esac            # comment line
    case "$trimmed" in
      [A-Za-z_]*=*) : ;;
      *) lg_reason="line is not a KEY=VALUE assignment: ${trimmed:0:48}"; return 1;;
    esac
    key="${trimmed%%=*}"; rest="${trimmed#*=}"
    case "$key" in *[!A-Za-z0-9_]*) lg_reason="invalid key name: $key"; return 1;; esac
    case "$key" in                                       # schema-key allowlist (no arbitrary clobber)
      LIVE_GATE_TARGETS|HEALTH|CAND_*|CFILE_*|FENCE_*|HEALTH_*|PROBE_*|SECRET_MOUNT_*|SECRET_ENV_*|MEMORY_*|PIDS_*) : ;;
      *) echo "[live-gate] WARN: ignoring non-schema key in contract: $key"; continue;;
    esac
    case "$rest" in
      \'*)  # single-quoted: VERBATIM (single quotes neutralise $() ` && ; < > etc.)
        body="${rest#\'}"
        if [[ "$body" == *\'* ]]; then                  # closes on this line
          val="${body%%\'*}"
          after="${body#*\'}"; after="${after#"${after%%[![:space:]]*}"}"
          case "$after" in ''|'#'*) :;; *) lg_reason="trailing content after value for $key"; return 1;; esac
        else                                            # multi-line single-quoted (e.g. SECRET_ENV)
          val="$body"
          while IFS= read -r more || [ -n "$more" ]; do
            if [[ "$more" == *\'* ]]; then
              val+=$'\n'"${more%%\'*}"
              after="${more#*\'}"; after="${after#"${after%%[![:space:]]*}"}"
              case "$after" in ''|'#'*) :;; *) lg_reason="trailing content after multi-line value for $key"; return 1;; esac
              break
            fi
            val+=$'\n'"$more"
          done
        fi
        ;;
      \"*)  # double-quoted: scan to the first UNESCAPED " ; unescape only \" \$ \\ \` ; refuse $()/`
        s="${rest#\"}"; nn=${#s}; i=0; val=""; closed=0; remainder=""
        while (( i < nn )); do
          c="${s:i:1}"
          if [ "$c" = '\' ] && (( i+1 < nn )); then
            nx="${s:i+1:1}"
            case "$nx" in '"'|'$'|'\'|'`') val+="$nx"; i=$((i+2)); continue;; esac
            val+="$c"; i=$((i+1)); continue
          fi
          if [ "$c" = '"' ]; then closed=1; remainder="${s:i+1}"; break; fi
          val+="$c"; i=$((i+1))
        done
        (( closed )) || { lg_reason="unterminated double-quote for $key"; return 1; }
        remainder="${remainder#"${remainder%%[![:space:]]*}"}"
        case "$remainder" in ''|'#'*) :;; *) lg_reason="trailing content after value for $key"; return 1;; esac
        case "$val" in *'$('*|*'`'*) lg_reason="command substitution/backtick in value for $key (refused outside single quotes)"; return 1;; esac
        ;;
      *)  # unquoted: must be a single bare token (no whitespace / shell metacharacters)
        val="$rest"
        case "$val" in
          *[[:space:]]*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'`'*|*'$'*|*'('*|*')'*)
            lg_reason="unsafe unquoted value for $key (quote it if it is meant literally)"; return 1;;
        esac
        ;;
    esac
    printf -v "$key" '%s' "$val"                         # assign literally — never eval
  done < "$file"
  return 0
}

# ---- CONTRACT resolution: in-tree .live-gate (preferred) -> host fallback -> generic default ----
if [ -f "$SRC/.live-gate" ]; then
  cp "$SRC/.live-gate" "$PRESET"; echo "[live-gate] contract: in-tree .live-gate"
elif [ -f "$HOME/.config/live-gate/$REPO_NAME.env" ]; then
  cp "$HOME/.config/live-gate/$REPO_NAME.env" "$PRESET"; echo "[live-gate] contract: host ~/.config/live-gate/$REPO_NAME.env"
else
  : > "$PRESET"; echo "[live-gate] contract: none -> generic default (Containerfile, image HEALTHCHECK, no probe)"
fi
# SAFE CONSUMPTION: parse the contract (lg_load), never source it. A rejected contract is hostile or
# malformed — fail it RED + loud (it must NOT be allowed to silently SKIP the gate) and never run it.
if ! lg_load "$PRESET"; then
  echo "[live-gate] contract REJECTED (unsafe/malformed; NOT executed on host): $lg_reason"
  if gh pr comment "$PR" --repo "$SLUG" --body \
"**Host live-gate (Gate B): RED** — \`$REPO_NAME\` @ \`$SHA\` ships a \`.live-gate\` that was **REJECTED as unsafe/malformed and NOT executed** on the host: $lg_reason. The contract is *parsed*, never sourced — declare inert \`KEY=VALUE\` pairs only (single-quote any HEALTH/PROBE command; no command substitution or chaining outside single quotes; one assignment per line). See validation/live-gate.sample." \
    >/dev/null 2>&1; then
    exit 1
  else
    echo "[live-gate] WARN: reject-comment failed — exit 4 (UNDELIVERED; caller must re-gate, not dedup)"
    exit 4
  fi
fi

# ---- TARGET list: new multi-target schema (LIVE_GATE_TARGETS) OR a single implicit target that
# collapses both the legacy single-set CAND_* contract AND the generic default into one build. ----
targets=()
if [ -n "${LIVE_GATE_TARGETS:-}" ]; then
  read -r -a targets <<< "$LIVE_GATE_TARGETS"
else
  targets=( default )
fi

# Per-target lookup: VAR_<target> with a global/legacy fallback (indirect expansion).
pt(){ local v="${1}_${2}"; printf '%s' "${!v:-$3}"; }

# HOST-CONTROLLED runtime selection [PROVISIONAL / OPT-IN]. Chosen HERE by the host, NEVER by the
# untrusted `.live-gate` (a contract choosing its own runtime would just pick the weaker fence to dodge
# gVisor). DEFAULT = 'default' (the plain shared-kernel fence = current behaviour). A (repo) or
# (repo:target) listed in the host runsc allowlist — a lineage the feasibility test has PROVEN runs
# under gVisor — is opted into 'runsc'. Empty/missing allowlist = everything on the plain fence = the
# loop behaves exactly as today. This makes gVisor a PROVEN, per-lineage opt-in, never a fleet-wide flip
# to an unproven runtime. The allowlist is a HOST file, not a schema key — a PR cannot influence it.
# (When ALL lineages are proven, flip the default to runsc + invert this to a plain-fence exception list.)
RUNSC_ALLOW="${LG_RUNSC_ALLOW:-$HOME/.config/live-gate/runsc.allow}"
runtime_for(){ # $1=repo $2=target -> echoes 'runsc' (proven, opted-in) or 'default' (plain fence)
  local repo="$1" tgt="$2" line
  [ -f "$RUNSC_ALLOW" ] || { printf 'default'; return; }
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"; [ -z "$line" ] && continue
    if [ "$line" = "$repo" ] || [ "$line" = "$repo:$tgt" ]; then printf 'runsc'; return; fi
  done < "$RUNSC_ALLOW"
  printf 'default'
}

say(){ printf '%s\n' "$*" | tee -a "$LOG"; }
run_target(){ # uses the loop-local vars in scope; tees build+gate output to the verdict LOG
  CAND_FENCE="$fence" CAND_PROBE="$probe" HEALTH="$health" \
  CAND_SECRET_MOUNT="$smount" CAND_SECRET_ENV="$senv" \
  CAND_MEMORY="$mem" CAND_PIDS="$pids" \
  CAND_HEALTH_START="$hstart" CAND_HEALTH_TRIES="$htries" CAND_HEALTH_SLEEP="$hsleep" \
  CAND_RUNTIME="$runtime" \
  CAND_TAG="val-${SHA}-${t}" \
    "$BUILDER" "$REPO_NAME" "$SRC" "" "$cfile" 2>&1 | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}

say "[live-gate] gating $SLUG PR #$PR @ $SHA — targets: ${targets[*]}"
overall=GREEN
for t in "${targets[@]}"; do
  case "$t" in *[!A-Za-z0-9_]*) say "[target $t] FATAL: target name must match [A-Za-z0-9_]"; overall=RED; continue;; esac
  cfile="$(pt CFILE "$t" "${CAND_CFILE:-Containerfile}")"
  fence="$(pt FENCE "$t" "${CAND_FENCE:-}")"            # empty => validate-candidate uses the hardest default
  health="$(pt HEALTH "$t" "${HEALTH:-}")"
  probe="$(pt PROBE "$t" "${CAND_PROBE:-}")"
  smount="$(pt SECRET_MOUNT "$t" "${CAND_SECRET_MOUNT:-}")"
  senv="$(pt SECRET_ENV "$t" "${CAND_SECRET_ENV:-}")"
  mem="$(pt MEMORY "$t" "${CAND_MEMORY:-}")"
  pids="$(pt PIDS "$t" "${CAND_PIDS:-}")"
  hstart="$(pt HEALTH_START "$t" "${CAND_HEALTH_START:-}")"
  htries="$(pt HEALTH_TRIES "$t" "${CAND_HEALTH_TRIES:-}")"
  hsleep="$(pt HEALTH_SLEEP "$t" "${CAND_HEALTH_SLEEP:-}")"

  say "== target [$t]  CFILE=$cfile =="
  if run_target; then say "== target [$t]: GREEN =="; else say "== target [$t]: RED =="; overall=RED; fi
done
say "== OVERALL VERDICT: $overall  ($SLUG#$PR @ $SHA) =="

# Post the combined verdict to the PR (host MAY comment; NEVER merges).
TAIL="$(tail -28 "$LOG" | sed 's/`/ /g')"
BODY="$(printf '**Host live-gate (Gate B): VERDICT %s** — %s @ %s (targets: %s)\n\nEach target built DISPOSABLY on the host (localhost/disposable/*, never pushed) from an ephemeral PR-head tree (torn down) + access-probed on its own loopback. ALL targets must be GREEN.\n\n```\n%s\n```\n' \
  "$overall" "$REPO_NAME" "$SHA" "${targets[*]}" "$TAIL")"
if gh pr comment "$PR" --repo "$SLUG" --body "$BODY"; then
  echo "[live-gate] verdict $overall posted to $SLUG#$PR"
else
  # The verdict was COMPUTED but NOT DELIVERED. If we returned the plain verdict code the caller
  # would write the per-SHA .done marker and this commit would NEVER be re-gated — the verdict is
  # lost forever with no comment on the PR. Exit 4 instead: the caller must NOT dedup, so the next
  # poll re-gates and re-attempts delivery.
  echo "[live-gate] WARN: failed to post verdict comment (verdict was $overall) — exit 4 (UNDELIVERED; caller must re-gate, not dedup)"
  exit 4
fi

# Dedup (the per-commit .done marker) is owned by live-gate-watch.sh, the caller. Standalone runs
# are explicit + re-runnable. Exit code carries the DELIVERED verdict (3 = skipped, 4 = undelivered,
# both handled above; 0 = GREEN, 1 = RED).
[ "$overall" = GREEN ]
