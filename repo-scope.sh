#!/usr/bin/env bash
# repo-scope.sh — the HOST-side R16 OPERATING-SCOPE reader (issue #132; apparatus fedora-dev#167).
#
# THE LEAK THIS CLOSES: the host live-gate (live-gate-watch.sh) discovers `live-validate` PRs ORG-WIDE
# — it would build a candidate for ANY labelled repo in the org (the #165 scope leak from the host
# end, R16 rule 5). This reader answers one question — "may the apparatus act on this repo?" — against
# the maintainer-confirmed set in policy/scope.conf, so the watcher skips an out-of-scope PR with one
# loud line, before any per-PR API call, build or verdict.
#
# LOCKSTEP MIRROR of the CANONICAL fedora-dev `bin/repo-scope.sh` (the fleet-halt.sh /
# gh-app-provision.sh precedent — the dev reader itself names this mirror as the intended design). This
# host copy is the CEILING-ONLY reader: it implements `check`/`list` against scope.conf. It DELIBERATELY
# omits the dev-side per-session (R27/R28) layer and the fitness-gate helpers (diff-adds / confirm-names)
# — the host neither merges nor reviews PRs, so those are dead weight here. The PURE decision helpers
# (scope_norm / scope_parse / scope_member / scope_decide) are mirrored VERBATIM from the canonical, so
# a scope answer is byte-identical on both ends.
#
# FAIL DIRECTION (R16 rule 4 / issue #132): an UNREADABLE config means NO action on anything but the
# apparatus's OWN two repos ($SCOPE_OWN — fedora-dev + fedora-bootstrap) so the host can still validate
# itself but can never wander. A READABLE but EMPTY scope denies EVERYTHING (a maintainer who empties
# the file means it). A MISSING READER is the caller's fail-closed problem, not this script's: the
# watcher treats a missing/erroring reader as "act only on the two apparatus repos" (the reader cannot
# run to answer when it is absent).
#
# CONTRACT (what live-gate-watch.sh relies on):
#   repo-scope.sh check <repo>   rc 0 = IN scope (the ONLY "act") · rc 3 = OUT of scope ·
#                                rc 4 = out of scope under the unreadable-config fallback ·
#                                rc 2 = usage. Detail rides stderr; the caller emits its OWN single
#                                loud skip line and acts on the rc alone.
#   repo-scope.sh list           the actionable set, one per line (unreadable config → $SCOPE_OWN,
#                                warned on stderr; rc 0 either way — the fallback IS the answer).
#   repo-scope.sh --selftest     exercise the pure helpers (no gh / network / clone).
#
# COST: a local file read — zero API calls, safe at the watcher's 10 s cadence.
#
# ENV: SCOPE_FILE (default: repo-clone $HERE/policy/scope.conf, else the installed
#      $HOME/.config/live-gate/scope.conf); SCOPE_OWN (default "fedora-dev fedora-bootstrap" — the
#      apparatus's own two repos, the unreadable-config fallback).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# SCOPE_FILE resolution: env override wins; then the repo-clone layout ($HERE/policy/scope.conf, where
# this script ships beside its data — the dev-run + test case); then the installed layout
# ($HOME/.config/live-gate/scope.conf, where setup-user.sh / the F16 absorber place it beside the
# live-gate presets). If neither exists, the installed path is the canonical target — absent ⇒ the
# reader treats it as unreadable and the caller falls back to $SCOPE_OWN.
if [ -z "${SCOPE_FILE:-}" ]; then
  if   [ -f "$HERE/policy/scope.conf" ];            then SCOPE_FILE="$HERE/policy/scope.conf"
  elif [ -f "$HOME/.config/live-gate/scope.conf" ]; then SCOPE_FILE="$HOME/.config/live-gate/scope.conf"
  else SCOPE_FILE="$HOME/.config/live-gate/scope.conf"
  fi
fi
SCOPE_OWN="${SCOPE_OWN:-fedora-dev fedora-bootstrap}"

log(){ printf 'repo-scope: %s\n' "$*" >&2; }

# ---- PURE HELPERS (--selftest covers exactly these; mirrored VERBATIM from the dev-side reader) -----

# scope_norm <name> → the bare repo name: any 'owner/' prefix stripped, so `check oso-gato/x` and
# `check x` answer identically (actuators hold both forms).
scope_norm(){ printf '%s' "${1##*/}"; }

# scope_parse — config on stdin → one clean repo name per line: CRs and comments (#…) stripped, edges
# trimmed; a line with characters outside [A-Za-z0-9._-] is INVALID and DROPPED — an invalid line can
# only ever NARROW the effective scope, never widen it (fail direction, header).
scope_parse(){
  sed -e 's/\r$//' -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -E '^[A-Za-z0-9._-]+$' || true
}

# scope_member <repo> <parsed-list> → 1|0 (exact whole-name match — no globs, no substrings).
scope_member(){
  printf '%s\n' "$2" | grep -qxF -- "$1" && printf 1 || printf 0
}

# scope_decide <member:0|1> <readable:0|1> <own:0|1> → ALLOW | DENY | FALLBACK_ALLOW | FALLBACK_DENY.
# A readable config decides on membership ALONE (own-repo status buys nothing — an EMPTIED config
# denies even fedora-dev: narrowing is always the maintainer's right); an unreadable one falls back to
# the own-repo set and nothing else.
scope_decide(){
  local member="$1" readable="$2" own="$3"
  if [ "$readable" = 1 ]; then
    [ "$member" = 1 ] && printf 'ALLOW' || printf 'DENY'
  else
    [ "$own" = 1 ] && printf 'FALLBACK_ALLOW' || printf 'FALLBACK_DENY'
  fi
}

# ---- reader plumbing (impure: touches the filesystem) ----------------------------------------------

# _scope_read → sets READABLE (1|0) and PARSED (the parsed name list).
_scope_read(){
  if [ -f "$SCOPE_FILE" ] && [ -r "$SCOPE_FILE" ]; then
    READABLE=1; PARSED="$(scope_parse < "$SCOPE_FILE")"
  else
    READABLE=0; PARSED=""
  fi
}

# _own_member <repo> → 1|0 if the repo is one of the apparatus's own two repos ($SCOPE_OWN).
_own_member(){
  # shellcheck disable=SC2086  # intentional word-split: SCOPE_OWN is a space-separated list
  printf '%s\n' $SCOPE_OWN | grep -qxF -- "$1" && printf 1 || printf 0
}

cmd_check(){
  [ $# -eq 1 ] || { log "usage: check <repo>"; return 2; }
  local repo member own decision
  repo="$(scope_norm "$1")"
  _scope_read
  member="$(scope_member "$repo" "$PARSED")"
  own="$(_own_member "$repo")"
  decision="$(scope_decide "$member" "$READABLE" "$own")"
  case "$decision" in
    ALLOW)          log "$repo IN scope"; return 0;;
    DENY)           log "$repo OUT of scope (not in $SCOPE_FILE)"; return 3;;
    FALLBACK_ALLOW) log "$repo allowed under unreadable-config fallback (apparatus repo; $SCOPE_FILE unreadable)"; return 0;;
    FALLBACK_DENY)  log "$repo denied: scope config unreadable ($SCOPE_FILE) and not an apparatus repo"; return 4;;
  esac
}

cmd_list(){
  _scope_read
  if [ "$READABLE" = 1 ]; then
    printf '%s\n' "$PARSED"
  else
    log "scope config unreadable ($SCOPE_FILE) — falling back to apparatus repos: $SCOPE_OWN"
    # shellcheck disable=SC2086  # intentional word-split
    printf '%s\n' $SCOPE_OWN
  fi
}

cmd_selftest(){
  local f=0
  _t(){ if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s (got=%s want=%s)\n' "$1" "$2" "$3"; f=1; fi; }

  _t "norm strips owner/"   "$(scope_norm oso-gato/fedora-dev)"                       "fedora-dev"
  _t "norm bare passthrough" "$(scope_norm fedora-dev)"                               "fedora-dev"
  _t "parse drops comment/blank/invalid" \
     "$(printf 'fedora-dev\n# a comment\n\n  fedora-bootstrap  \nbad name\nweird$\n' | scope_parse | tr '\n' ',')" \
     "fedora-dev,fedora-bootstrap,"
  _t "member hit"           "$(scope_member fedora-dev "$(printf 'fedora-dev\nfedora-bootstrap\n')")"   "1"
  _t "member miss"          "$(scope_member foreign "$(printf 'fedora-dev\nfedora-bootstrap\n')")"      "0"
  _t "member no-substring"  "$(scope_member dev "$(printf 'fedora-dev\n')")"                            "0"
  _t "decide readable+member=ALLOW"      "$(scope_decide 1 1 0)" "ALLOW"
  _t "decide readable+nonmember=DENY"    "$(scope_decide 0 1 1)" "DENY"
  _t "decide unreadable+own=FALLBACK_ALLOW" "$(scope_decide 0 0 1)" "FALLBACK_ALLOW"
  _t "decide unreadable+foreign=FALLBACK_DENY" "$(scope_decide 0 0 0)" "FALLBACK_DENY"

  echo; [ "$f" = 0 ] && echo "repo-scope --selftest: PASS" || echo "repo-scope --selftest: FAIL"
  return "$f"
}

case "${1:-}" in
  check)      shift; cmd_check "$@";;
  list)       shift; cmd_list "$@";;
  --selftest) cmd_selftest;;
  *) log "usage: repo-scope.sh {check <repo>|list|--selftest}"; exit 2;;
esac
