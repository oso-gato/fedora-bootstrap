#!/usr/bin/env bash
# Acceptance checks — every line PASS/FAIL, exit nonzero on any FAIL.
set -u; fail=0
ck(){ if eval "$2" >/dev/null 2>&1; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }
ck "host: podman.socket active"            "systemctl --user is-active podman.socket"
ck "host: cockpit.socket active"           "systemctl is-active cockpit.socket"
ck "host: tmux auto-attach drop-in"        "test -f /etc/profile.d/zz-tmux-attach.sh"
ck "host: tmux server config"              "test -f /etc/tmux.conf"
ck "host: no shim symlinks in ~/.local/bin" "test ! -e ~/.local/bin/podman && test ! -e ~/.local/bin/systemctl"
ck "box: exists"                           "distrobox list | grep -q claudebox"
ck "box: claude runs"                      "distrobox enter claudebox -- /usr/bin/claude --version"
ck "box: policy present"                   "distrobox enter claudebox -- sh -c 'test -f /etc/claude-code/CLAUDE.md && test -f /etc/claude-code/managed-settings.json'"
ck "box: promotion-gate hook present"      "distrobox enter claudebox -- sh -c 'test -x /etc/claude-code/hooks/gate-push.sh'"
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
# v1.1.9: brute-force jail on public sshd:22 — symmetric posture with fedora-dev's public ssh:4444.
# v1.2.5: gate the jail query on euid. verify.sh runs as the unprivileged `core` user (setup.sh hands
# the rootless layer to `su - core`), but `fail2ban-client status sshd` needs root to reach fail2ban's
# 0700 control socket — so as `core` it always short-circuited to a false FAIL even with the daemon up.
# Now: assert the daemon is active (works as core) AND, only when actually root, the sshd jail too.
ck "host: fail2ban active (sshd jail)"             "systemctl is-active fail2ban.service && { [ \$(id -u) -ne 0 ] || fail2ban-client status sshd; }"
# v1.1.15: leaf footprint — firewalld must NOT be installed (the fail2ban metapackage used to pull it in;
# its stock zone blocked mosh UDP). setup-host.sh converges this; assert it stays converged.
ck "host: firewalld absent (leaf footprint)"       "! rpm -q firewalld"
# DOCTRINE BOUNDARY: the in-box agent's scoped sudo must NOT grant host-mutating dnf (that would be
# host root). -k clears any cached timestamp so a recent password-sudo can't mask a missing grant.
ck "host: agent has NO passwordless dnf (immutable host)" "! sudo -kn /usr/bin/dnf --version"
# v1.2.0: SELinux must not be deliberately DISABLED. Key on the config (durable intent), NOT on
# getenforce — the live kernel legitimately reads Disabled during the pre-relabel reboot window, and
# the claudebox container's own /etc/selinux/config is empty, so read the HOST file via /run/host
# (fall back to /etc when verify.sh is run directly on the host). PASS for permissive OR enforcing.
ck "host: SELinux config enabled (permissive or enforcing)" "grep -qE '^SELINUX=(permissive|enforcing)' /run/host/etc/selinux/config 2>/dev/null || grep -qE '^SELINUX=(permissive|enforcing)' /etc/selinux/config"
exit $fail
