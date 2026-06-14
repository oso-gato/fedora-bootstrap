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
# Tolerate the browser-auth path: setup-host.sh joins the tailnet unattended (TS_AUTHKEY) OR leaves
# the node in NeedsLogin until you click the consent link (it absorbs a missed window with `|| true`
# and still exits 0). So PASS when the backend is Running (joined) OR pending auth — only a missing/
# down daemon (no BackendState) fails. Use --json so we read the state, not the bare exit code.
ck "tailnet: host joined (or pending browser-auth)" "tailscale status --json 2>/dev/null | grep BackendState | grep -qE 'Running|NeedsLogin|Starting|NeedsMachineAuth'"
# box-update harness — all 3 trigger methods funnel into claudebox-rebuild-run.service
ck "box-update: ask-Claude watcher enabled"        "systemctl --user is-enabled claudebox-rebuild.path"
ck "box-update: daily refresh timer enabled"       "systemctl --user is-enabled claudebox-rebuild-daily.timer"
ck "box-update: claudebox-rebuild command present"  "test -x ~/.local/bin/claudebox-rebuild"
# host self-update — dnf-automatic on the monthly cadence
ck "host: dnf-automatic timer enabled"             "systemctl is-enabled dnf5-automatic.timer"
# DOCTRINE BOUNDARY: the in-box agent's scoped sudo must NOT grant host-mutating dnf (that would be
# host root). -k clears any cached timestamp so a recent password-sudo can't mask a missing grant.
ck "host: agent has NO passwordless dnf (immutable host)" "! sudo -kn /usr/bin/dnf --version"
exit $fail
