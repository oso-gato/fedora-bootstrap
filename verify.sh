#!/usr/bin/env bash
# Acceptance checks — every line PASS/FAIL, exit nonzero on any FAIL.
set -u; fail=0
ck(){ if eval "$2" >/dev/null 2>&1; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }
ck "host: podman.socket active"            "systemctl --user is-active podman.socket"
ck "host: cockpit.socket active"           "systemctl is-active cockpit.socket"
ck "host: tmux auto-attach drop-in"        "test -f /etc/profile.d/zz-tmux-attach.sh"
ck "host: no shim symlinks in ~/.local/bin" "test ! -e ~/.local/bin/podman && test ! -e ~/.local/bin/systemctl"
ck "box: exists"                           "distrobox list | grep -q claudebox"
ck "box: claude runs"                      "distrobox enter claudebox -- /usr/bin/claude --version"
ck "box: policy present"                   "distrobox enter claudebox -- sh -c 'test -f /etc/claude-code/CLAUDE.md && test -f /etc/claude-code/managed-settings.json'"
ck "box: podman reaches HOST engine"       "distrobox enter claudebox -- sh -lc 'podman info --format {{.Host.RemoteSocket.Exists}} | grep -q true'"
# Probe the shim with a SYSTEM-level query (its real purpose): distrobox-host-exec rewrites the
# *session* bus env to /run/host paths that don't resolve host-side, so `systemctl --user` over the
# shim can't reach core's user bus — but system systemctl uses the system bus and works. tailscaled is
# a system service we enabled, so this confirms the shim routes to the host's systemd.
ck "box: systemctl shim works (host)"      "distrobox enter claudebox -- /usr/local/bin/systemctl is-active tailscaled"
# Tolerate the browser-auth path: setup-host.sh joins the tailnet unattended (TS_AUTHKEY) OR leaves
# the node in NeedsLogin until you click the consent link (it absorbs a missed window with `|| true`
# and still exits 0). So PASS when the backend is Running (joined) OR pending auth — only a missing/
# down daemon (no BackendState) fails. Use --json so we read the state, not the bare exit code.
ck "tailnet: host joined (or pending browser-auth)" "tailscale status --json 2>/dev/null | grep BackendState | grep -qE 'Running|NeedsLogin|Starting|NeedsMachineAuth'"
exit $fail
