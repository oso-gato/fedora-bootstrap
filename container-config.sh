#!/usr/bin/env bash
# container-config.sh — read a container's configuration from the PRIVATE control repo.
#
# WHY THIS EXISTS: provisioning a container asked its questions on a terminal. That is fine on
# Day-0 with a human present and impossible everywhere else — an autonomous `apply-bootstrap` has no
# tty, so any container whose wizard prompts could not be provisioned without someone sitting there.
# The answers now live in oso-gato/ak-private under `erebus/<container>.env`, one file per container,
# and the host reads them instead of asking.
#
# THE BOOTSTRAP ORDER THIS DEPENDS ON (maintainer's requirement, 2026-07-29): the repo is PRIVATE, so
# it is readable only with a GitHub App installation token. Day-0 therefore authorises the App BEFORE
# it provisions any container — App auth is the one credential a human supplies, and it unlocks every
# other answer. setup-user.sh already establishes the host App identity in phase 4 before its
# per-container loop, so this reads from a token that already exists.
#
# FAIL-SOFT BY DESIGN, and deliberately not fail-closed: a missing file, an unreadable repo, an
# unmintable token or no App at all ⇒ EMPTY OUTPUT and rc 0. The caller then provisions exactly as it
# does today (its own defaults, or a prompt when a human is present). Configuration that cannot be
# fetched must never be the reason a host cannot bring a container up — this is a convenience over the
# existing path, never a new dependency in front of it.
#
#   container-config.sh get <container>    print `KEY=value` lines for that container; empty if none
#   container-config.sh --selftest         exercise the pure parser (no network, no token)
#
# ENV: CC_REPO (oso-gato/ak-private) · CC_DIR (erebus) · CC_TOKEN_CMD (gh-app-auth.sh token)
# Covered by validation/container-config.test.sh.
set -uo pipefail
HERE="$(dirname "$(readlink -f "$0")")"

CC_REPO="${CC_REPO:-oso-gato/ak-private}"
CC_DIR="${CC_DIR:-erebus}"
CC_TOKEN_CMD="${CC_TOKEN_CMD:-$HERE/gh-app-auth.sh token}"

log(){ echo "[container-config] $*" >&2; }

# ---- PURE CORE (--selftest covers exactly this) ----------------------------------------------------
# cc_parse — read a .env body on stdin, emit only well-formed `KEY=value` lines.
# STRICT ON PURPOSE. This output is EVALUATED by the caller, so anything that is not plainly a
# variable assignment must not survive: no command substitution, no backticks, no `$(`, no semicolons
# or newlines smuggled through a quoted value. A config file in a repo is not a script, and treating
# it as one would hand anyone who can write that repo a root-adjacent shell on the host.
# Blank values are KEPT — "blank means take the container's default" is a real answer, not an omission.
cc_parse(){
  awk '
    /^[[:space:]]*#/ { next }                                  # comment
    /^[[:space:]]*$/ { next }                                  # blank
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      eq = index(line, "=")
      if (eq < 2) next                                          # no `=`, or nothing before it
      key = substr(line, 1, eq - 1)
      val = substr(line, eq + 1)
      if (key !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next               # not a shell-safe identifier
      # strip ONE layer of matching quotes, then refuse anything with shell metacharacters left
      if (val ~ /^".*"$/ || val ~ /^\x27.*\x27$/) val = substr(val, 2, length(val) - 2)
      if (val ~ /[$`;&|<>()\\]/) { print "SKIP " key > "/dev/stderr"; next }
      if (val ~ /["\x27]/)       { print "SKIP " key > "/dev/stderr"; next }
      printf "%s=%s\n", key, val
    }'
}

if [ "${1:-}" = "--selftest" ]; then
  p=0 f=0
  ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok   %s\n' "$1"
        else f=$((f+1)); printf '  FAIL %s\n       want=[%s] got=[%s]\n' "$1" "$3" "$2"; fi; }
  ck "plain assignment"     "$(printf 'BOX_HOSTNAME=nox\n' | cc_parse 2>/dev/null)" "BOX_HOSTNAME=nox"
  ck "blank value is kept"  "$(printf 'TS_AUTHKEY=\n' | cc_parse 2>/dev/null)" "TS_AUTHKEY="
  ck "comment ignored"      "$(printf '# a note\nA=1\n' | cc_parse 2>/dev/null)" "A=1"
  ck "blank line ignored"   "$(printf '\n\nA=1\n' | cc_parse 2>/dev/null)" "A=1"
  ck "leading space ok"     "$(printf '   A=1\n' | cc_parse 2>/dev/null)" "A=1"
  ck "double quotes strip"  "$(printf 'A="hello world"\n' | cc_parse 2>/dev/null)" "A=hello world"
  ck "single quotes strip"  "$(printf "A='hello world'\n" | cc_parse 2>/dev/null)" "A=hello world"
  ck "value keeps = signs"  "$(printf 'A=b=c\n' | cc_parse 2>/dev/null)" "A=b=c"
  echo "== the output is EVALUATED — these must never survive =="
  ck "command substitution" "$(printf 'A=$(whoami)\n' | cc_parse 2>/dev/null)" ""
  ck "backticks"            "$(printf 'A=`id`\n' | cc_parse 2>/dev/null)" ""
  ck "semicolon chain"      "$(printf 'A=1;rm -rf /\n' | cc_parse 2>/dev/null)" ""
  ck "pipe"                 "$(printf 'A=1|sh\n' | cc_parse 2>/dev/null)" ""
  ck "redirect"             "$(printf 'A=1>/etc/passwd\n' | cc_parse 2>/dev/null)" ""
  ck "ampersand"            "$(printf 'A=1&\n' | cc_parse 2>/dev/null)" ""
  ck "backslash escape"     "$(printf 'A=x\\ny\n' | cc_parse 2>/dev/null)" ""
  ck "embedded quote"       "$(printf 'A=he"llo\n' | cc_parse 2>/dev/null)" ""
  ck "no equals ignored"    "$(printf 'JUST A LINE\n' | cc_parse 2>/dev/null)" ""
  ck "empty key ignored"    "$(printf '=value\n' | cc_parse 2>/dev/null)" ""
  ck "bad identifier"       "$(printf '2FOO=1\n' | cc_parse 2>/dev/null)" ""
  ck "dash in key"          "$(printf 'A-B=1\n' | cc_parse 2>/dev/null)" ""
  ck "a good line survives a bad neighbour" "$(printf 'BAD=$(id)\nGOOD=1\n' | cc_parse 2>/dev/null)" "GOOD=1"
  echo; echo "container-config selftest: $p passed, $f failed"; [ "$f" -eq 0 ]; exit
fi

# ---- fetch ------------------------------------------------------------------------------------------
[ "${1:-}" = get ] || { echo "usage: container-config.sh get <container> | --selftest" >&2; exit 2; }
name="${2:-}"
case "$name" in
  ''|*[!A-Za-z0-9._-]*) log "refusing container name '$name' — not a plain repo-safe name"; exit 0;;
esac

tok="$($CC_TOKEN_CMD 2>/dev/null)" || tok=""
if [ -z "$tok" ]; then
  log "no App token available — $name will use its own defaults (this is not an error)"
  exit 0
fi

body="$(GH_TOKEN="$tok" gh api "repos/$CC_REPO/contents/$CC_DIR/$name.env" -q .content 2>/dev/null \
        | base64 -d 2>/dev/null)" || body=""
if [ -z "$body" ]; then
  log "no $CC_DIR/$name.env in $CC_REPO — $name will use its own defaults"
  exit 0
fi

out="$(printf '%s\n' "$body" | cc_parse)"
[ -n "$out" ] && log "$name: $(printf '%s\n' "$out" | grep -c .) value(s) from $CC_REPO/$CC_DIR/$name.env" \
             || log "$name: $CC_DIR/$name.env had no usable values"
printf '%s\n' "$out"
