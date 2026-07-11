#!/usr/bin/env bash
# host-agent-dryrun.test.sh — MOCK end-to-end dry-run of the host autonomous agent
# (host-agent-watch.sh) with ZERO host contact.
#
# This is the non-image repo's analogue of a live-gate's "does it actually run" probe. The host agent's
# load-bearing safety is its PARSE (line-1-only `host-op:`) + verb ALLOWLIST + DISPATCH routing. We
# exercise all three end-to-end by STUBBING `gh` and `systemctl` on PATH: a fake `host-task` issue is
# discovered, its body parsed, the verb allowlist enforced, and dispatch routed — while `systemctl` is
# a recorder that NEVER executes a unit, so NO real workload / systemd / GitHub is ever touched. It runs
# on a plain CI runner (no podman, no host engine).
#
# Run:  bash validation/host-agent-dryrun.test.sh   → exit 0 = all cases pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../host-agent-watch.sh"
[ -f "$WATCH" ] || { echo "FATAL: host-agent-watch.sh not found at $WATCH"; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"

# ---- stub gh: fabricate ONE open host-task issue, serve a per-case body, log every mutating call. ----
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# minimal gh stub — only the subcommands host-agent-watch.sh calls; never touches GitHub.
sub="${1:-} ${2:-}"
case "$sub" in
  "issue list") echo "${FAKE_ISSUE:-1}" ;;            # discovery → one fake issue number
  "issue view") printf '%s' "$FAKE_BODY" ;;           # body fetch → this case's body
  "issue comment"|"issue close"|"issue edit"|"label create")
                printf 'GH %s\n' "$*" >> "$GH_LOG" ;; # record delivery, do nothing
  *)            printf 'GH %s\n' "$*" >> "$GH_LOG" ;;
esac
exit 0
EOF

# ---- stub systemctl: RECORD the call, NEVER execute a unit. THIS is the "no real workload" guard. ----
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'SYSTEMCTL %s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
  *"show -p ExecMainStatus"*) echo "${FAKE_EXECMAIN:-0}" ;;  # emulate a clean refresh (mainstatus 0)
esac
exit 0
EOF
chmod +x "$BIN/gh" "$BIN/systemctl"

pass=0; fail=0
run_case(){ # <desc> <fake-body> <expect-systemctl-start: yes|no> <expect-comment-substr>
  local desc="$1" body="$2" expect_start="$3" want="$4"
  local home="$ROOT/home-$RANDOM$RANDOM"; mkdir -p "$home"
  export HOME="$home"
  export GH_LOG="$home/gh.log";              : > "$GH_LOG"
  export SYSTEMCTL_LOG="$home/systemctl.log"; : > "$SYSTEMCTL_LOG"
  export FAKE_BODY="$body" FAKE_ISSUE=1 FAKE_EXECMAIN=0
  PATH="$BIN:$PATH" bash "$WATCH" >/dev/null 2>&1 || true
  local got_start=no
  grep -q 'SYSTEMCTL --user start workload-refresh@' "$SYSTEMCTL_LOG" && got_start=yes
  local ok=1
  [ "$got_start" = "$expect_start" ] || { ok=0; printf '  FAIL %s\n       systemctl-start expected=%s got=%s\n' "$desc" "$expect_start" "$got_start"; }
  grep -qF "$want" "$GH_LOG" || { ok=0; printf '  FAIL %s\n       comment missing: %s\n       gh.log: %s\n' "$desc" "$want" "$(tr '\n' ' ' < "$GH_LOG")"; }
  if [ "$ok" = 1 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$desc"; else fail=$((fail+1)); fi
}

echo "== dispatch routing: a KNOWN verb + KNOWN workload REACHES redeploy (stubbed — no real unit) =="
run_case "redeploy fedora-dev  → routes to workload-refresh@ (stub), reports DONE" \
  $'host-op: redeploy fedora-dev\nplease deploy the new image' yes 'host-agent: DONE'
run_case "redeploy fedora-desktop → routes, reports DONE" \
  $'host-op: redeploy fedora-desktop' yes 'host-agent: DONE'

echo "== allowlist: an UNKNOWN workload is REFUSED BEFORE any host mutation (systemctl NEVER called) =="
run_case "redeploy evil-repo → refused, no systemctl" \
  $'host-op: redeploy evil-repo' no 'unknown workload'
run_case "redeploy '*' (glob) → refused, no systemctl" \
  $'host-op: redeploy *' no 'unknown workload'

echo "== allowlist: an UNKNOWN or INCOMPLETE verb is REFUSED (systemctl NEVER called) =="
run_case "unknown verb 'nuke' → refused" \
  $'host-op: nuke everything now' no 'unsupported or empty host-op'
run_case "redeploy with no workload → refused" \
  $'host-op: redeploy' no 'redeploy needs a workload name'
run_case "host-op NOT on line 1 → refused (line-1-only parse)" \
  $'hello there\nhost-op: redeploy fedora-dev' no 'no valid'

echo
echo "host-agent-dryrun: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
