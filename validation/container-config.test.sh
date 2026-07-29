#!/usr/bin/env bash
# container-config.test.sh — drives the REAL container-config.sh with a stubbed token command and a
# stubbed `gh`. No network, no App, no token. bash validation/container-config.test.sh → exit 0.
#
# Proves the two properties that matter: the fetch path FAILS SOFT (no token / no file / no repo ⇒
# empty output and rc 0, so a host can always still bring a container up), and the parser cannot be
# used to execute anything (its output is eval'd by setup-user.sh).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../container-config.sh"
[ -f "$SUT" ] || { echo "FATAL: container-config.sh not found"; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

# stub gh: emits $FAKE_ENV (base64, as the contents API does) or nothing when $GH_FAIL=1
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
[ "${GH_FAIL:-0}" = 1 ] && exit 1
[ -n "${FAKE_ENV:-}" ] || exit 1
printf '%s' "$FAKE_ENV" | base64 -w0
EOF
chmod +x "$BIN/gh"
# stub token command: prints a token unless $NO_TOKEN=1
printf '#!/usr/bin/env bash\n[ "${NO_TOKEN:-0}" = 1 ] && exit 1\necho faketoken\n' > "$BIN/tok"; chmod +x "$BIN/tok"

run(){ OUT="$(env PATH="$BIN:$PATH" CC_TOKEN_CMD="$BIN/tok" "$@" bash "$SUT" get nox 2>/dev/null)"; RC=$?; }

echo "== the pure parser =="
bash "$SUT" --selftest >/dev/null 2>&1 && ok "container-config --selftest exits 0" || no "parser selftest failed"

echo "== FAIL SOFT: a host must always be able to bring a container up =="
run NO_TOKEN=1
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok "no App token → empty, rc 0 (wizard falls back to its defaults)" \
  || no "no-token path" "rc=$RC out='$OUT'"
run GH_FAIL=1
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok "repo unreadable → empty, rc 0" || no "repo-fail path" "rc=$RC out='$OUT'"
run FAKE_ENV=''
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok "no file for this container → empty, rc 0" || no "no-file path" "rc=$RC out='$OUT'"

echo "== a filled-in file provisions the container =="
run FAKE_ENV="$(printf '# nox\nBOX_HOSTNAME=nox\nIMAGE=ghcr.io/oso-gato/fedora-dev:latest\nTS_AUTHKEY=\n')"
{ printf '%s' "$OUT" | grep -qx 'BOX_HOSTNAME=nox' \
  && printf '%s' "$OUT" | grep -qx 'IMAGE=ghcr.io/oso-gato/fedora-dev:latest' \
  && printf '%s' "$OUT" | grep -qx 'TS_AUTHKEY='; } \
  && ok "values returned, blank kept (blank = take the container's own default)" \
  || no "happy path" "out='$OUT'"

echo "== the output is EVALUATED by setup-user.sh — injection must not survive the fetch path =="
run FAKE_ENV="$(printf 'BOX_HOSTNAME=nox\nEVIL=$(touch %s/pwned)\n' "$ROOT")"
{ [ ! -e "$ROOT/pwned" ] && ! printf '%s' "$OUT" | grep -q 'EVIL' \
  && printf '%s' "$OUT" | grep -qx 'BOX_HOSTNAME=nox'; } \
  && ok "command substitution dropped, the good value survives" \
  || no "injection" "out='$OUT' pwned=$([ -e "$ROOT/pwned" ] && echo yes || echo no)"
# The caller eval's what we print; prove the printed text is inert when actually eval'd.
EVALOUT="$(FAKE_ENV="$(printf 'A=1;touch %s/pwned2\n' "$ROOT")" env PATH="$BIN:$PATH" CC_TOKEN_CMD="$BIN/tok" bash "$SUT" get nox 2>/dev/null)"
( eval "$EVALOUT" ) >/dev/null 2>&1 || true
[ ! -e "$ROOT/pwned2" ] && ok "eval of the emitted text runs nothing" || no "eval-safety" "a semicolon chain executed"

echo "== THE DEFAULT PATH: ambient gh auth, no token command =="
# Every row above sets CC_TOKEN_CMD, so none of them exercised what production actually runs.
# The first cut defaulted CC_TOKEN_CMD to `gh-app-auth.sh token`, whose key path is
# /run/secrets/gh_app_key — the IN-CONTAINER mount, absent on the host. It would have returned
# nothing on every run and fallen back to defaults silently: green, dead, and untested.
# On the host, host-gh-refresh.sh keeps ~/.config/gh/hosts.yml as the App, so `gh` IS the App.
OUT="$(env PATH="$BIN:$PATH" FAKE_ENV="$(printf 'BOX_HOSTNAME=nox\n')" bash "$SUT" get nox 2>/dev/null)"; RC=$?
{ [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qx 'BOX_HOSTNAME=nox'; } \
  && ok "no CC_TOKEN_CMD → uses gh's ambient auth and returns values" \
  || no "ambient-auth default" "rc=$RC out='$OUT' (the default path fetches nothing — silently dead)"

echo "== a bad container name is refused before any network call =="
OUT="$(env PATH="$BIN:$PATH" CC_TOKEN_CMD="$BIN/tok" FAKE_ENV='A=1' bash "$SUT" get '../../etc/passwd' 2>/dev/null)"; RC=$?
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok "path traversal in the name → refused, empty" || no "name-check" "rc=$RC out='$OUT'"

echo
echo "container-config: $pass passed, $fail failed"
[ "$fail" = 0 ]
