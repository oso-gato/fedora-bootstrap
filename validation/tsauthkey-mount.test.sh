#!/usr/bin/env bash
# tsauthkey-mount.test.sh — the day-0 TS_AUTHKEY never lands on a process command line: the HOST join
# passes it via a file, and the WORKLOAD (devcontainer) Quadlet ferry mounts it as a file, not an env
# var (drift-guard for the audit 2026-07-22 finding #6).
#
# WHY: `tailscale up --auth-key="$TS_AUTHKEY"` puts the key on the tailscale process argv
# (/proc/<pid>/cmdline). And a Quadlet `Secret=…,type=env,target=TS_AUTHKEY` injects the key as a
# container ENV VAR, which distrobox re-materialises on every `distrobox enter`/`podman exec` argv.
# Both are fixed: the host join uses `--auth-key=file:`, and the ferry wires `type=mount,target=ts-authkey`.
#
# Pure grep; FENCE_CHECK_ONLY-safe. bash validation/tsauthkey-mount.test.sh → exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_SRC="$(cd "$HERE/.." && pwd)"
SH="$REPO_SRC/setup-host.sh"; SU="$REPO_SRC/setup-user.sh"
for f in "$SH" "$SU"; do [ -f "$f" ] || { echo "FATAL: $(basename "$f") not found"; exit 2; }; done
fails=0
ck() { if [ "$2" -eq 0 ]; then printf 'ok   — %s\n' "$1"; else printf 'FAIL — %s\n' "$1"; fails=$((fails+1)); fi; }

# HOST day-0 join: the key goes via a file (--auth-key=file:), never a bare env value on argv.
ck "setup-host.sh joins the host via tailscale --auth-key=file: (key off argv)" \
   "$(grep -Fq -- '--auth-key="file:' "$SH"; echo $?)"
ck "setup-host.sh does NOT pass the raw key on tailscale's argv (--auth-key=\"\$TS_AUTHKEY\")" \
   "$(! grep -Eq -- '--auth-key="\$\{?TS_AUTHKEY' "$SH"; echo $?)"

# WORKLOAD (devcontainer) Quadlet ferry: mount the secret as a file, not inject it as an env var.
ck "setup-user.sh ferries the workload ts-authkey as type=mount,target=ts-authkey" \
   "$(grep -Eq 'type=mount,target=ts-authkey' "$SU"; echo $?)"
ck "setup-user.sh no longer wires the ts-authkey secret as type=env,target=TS_AUTHKEY" \
   "$(! grep -Eq 'ts-authkey,type=env,target=TS_AUTHKEY' "$SU"; echo $?)"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails assertion(s) failed"; exit 1; fi
echo "ok — TS_AUTHKEY reaches the host and the devcontainer via files, never a command line"
