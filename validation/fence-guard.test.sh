#!/usr/bin/env bash
# fence-guard.test.sh — ALLOW/REJECT matrix for validate-candidate.sh's fence validator.
#
# Drives the validator in FENCE_CHECK_ONLY mode (no podman, no image) so it runs anywhere. Asserts:
#   * every FIRST-PARTY fence the fleet actually ships is ALLOWED (fedora-dev + both desktop lineages);
#   * every host-escape a hostile PR's `.live-gate` could smuggle is REJECTED (the pre-v1.2.53 hole).
# Run: `bash validation/fence-guard.test.sh` → exit 0 = all rows pass.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VC="$HERE/../validate-candidate.sh"
[ -f "$VC" ] || { echo "FATAL: validate-candidate.sh not found at $VC"; exit 2; }

pass=0; fail=0
# check <expect allow|reject> <fence string> <description>
check(){
  local expect="$1" fence="$2" desc="$3" rc
  CAND_FENCE="$fence" FENCE_CHECK_ONLY=1 bash "$VC" _fence_check_ >/dev/null 2>&1; rc=$?
  # rc 0 = ALLOWED (reached the FENCE_CHECK_ONLY green exit); rc 1 = REJECTED by the validator.
  local got; [ "$rc" -eq 0 ] && got=allow || got=reject
  if [ "$got" = "$expect" ]; then pass=$((pass+1)); printf '  ok    [%-6s] %s\n' "$expect" "$desc"
  else fail=$((fail+1)); printf '  FAIL  expected=%-6s got=%-6s (rc=%s): %s\n    fence: %s\n' "$expect" "$got" "$rc" "$desc" "$fence"; fi
}

echo "== ALLOW: the fences the fleet legitimately ships =="
check allow '' 'empty fence -> hard default'
check allow '--network=none --cap-drop=ALL' 'explicit hard default'
check allow '--cap-add NET_ADMIN --cap-add SYS_ADMIN --device /dev/net/tun --device /dev/fuse --security-opt label=disable' 'fedora-dev / desktop-xrdp fence'
check allow '--systemd=always --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --shm-size=1g --cap-add NET_ADMIN --cap-add SYS_ADMIN --device /dev/net/tun --device /dev/fuse --security-opt label=disable' 'fedora-desktop grd (systemd-PID-1) fence'
check allow '--network=lo' 'loopback network explicitly'
check allow '--device=/dev/kvm' 'device =-form, permitted source'

echo "== REJECT: host-escape a hostile PR .live-gate could smuggle =="
check reject '-v /:/host:rw' 'THE headline vector — host root bind-mounted rw'
check reject '-v /etc:/etc:ro' 'sensitive host path bind mount'
check reject '--volume /home/core:/hc' 'home dir bind mount (--volume form)'
check reject '--mount type=bind,source=/,target=/host' '--mount host-root form'
check reject '--cap-add ALL' 'cap-add ALL (space form) ~= privileged'
check reject '--cap-add=ALL' 'cap-add ALL (=form)'
check reject '--privileged' 'blanket privilege'
check reject '--pid=host' 'host PID namespace'
check reject '--ipc host' 'host IPC namespace (space form)'
check reject '--userns=host' 'host user namespace'
check reject '--security-opt seccomp=unconfined' 'seccomp unconfined'
check reject '--security-opt=apparmor=unconfined' 'apparmor unconfined (=form)'
check reject '--device /dev/sda' 'host block device'
check reject '--device=/dev/sda1:/dev/sda1' 'host block device (=form, with dst)'
check reject '--network=host' 'host network'
check reject '--network pasta' 'pasta egress (space form)'
check reject '-p 8443:8443' 'publish a port'

echo
echo "fence-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
