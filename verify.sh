#!/usr/bin/env bash
# Acceptance checks — every line PASS/FAIL, exit nonzero on any FAIL.
set -u; fail=0
ck(){ if eval "$2" >/dev/null 2>&1; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }
ck "host: podman.socket active"            "systemctl --user is-active podman.socket"
ck "host: cockpit.socket active"           "sudo systemctl is-active cockpit.socket"
ck "host: tmux auto-attach drop-in"        "test -f /etc/profile.d/zz-tmux-attach.sh"
ck "host: no shim symlinks in ~/.local/bin" "test ! -e ~/.local/bin/podman && test ! -e ~/.local/bin/systemctl"
ck "box: exists"                           "distrobox list | grep -q claudebox"
ck "box: claude runs"                      "distrobox enter claudebox -- /usr/bin/claude --version"
ck "box: policy present"                   "distrobox enter claudebox -- sh -c 'test -f /etc/claude-code/CLAUDE.md && test -f /etc/claude-code/managed-settings.json'"
ck "box: podman reaches HOST engine"       "distrobox enter claudebox -- sh -lc 'podman info --format {{.Host.RemoteSocket.Exists}} | grep -q true'"
ck "box: systemctl shim works (host)"      "distrobox enter claudebox -- systemctl --user is-active podman.socket"
ck "tailnet: host joined"                  "tailscale status"
exit $fail
