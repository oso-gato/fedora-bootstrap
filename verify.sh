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
ck "box: retired gate hook ABSENT"         "distrobox enter claudebox -- sh -c 'test ! -e /etc/claude-code/hooks/gate-push.sh'"
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
# host self-refresh (F16 absorber): the "merged host code -> live" mechanism. These make a NON-armed or
# BLOCKED absorber a LOUD verify FAIL instead of a silent no-op (incident 2026-07-17: the host sat on
# hand-applied code for days because the only signal was a journald warn). A correct setup.sh run arms
# it: setup-host.sh chowns the control clone core-writable, setup-user.sh enables the timer + primes it.
ck "host-refresh: absorber timer enabled"          "systemctl --user is-enabled host-code-refresh.timer"
ck "host-refresh: control clone core-writable"     "test -w \"\${HCR_CLONE:-/opt/fedora-bootstrap}\" && test -w \"\${HCR_CLONE:-/opt/fedora-bootstrap}/.git\""
ck "host-refresh: last tick not BLOCKED/FAILED"    "test -f \"\$HOME/.local/state/host-code-refresh/status\" && ! grep -qE '^[0-9]+ (BLOCKED|FAILED)' \"\$HOME/.local/state/host-code-refresh/status\""
# box owner (incident 2026-07-11): claudebox-up.service holds the box's conmon in an independent scope so
# a watcher-tick teardown can't kill it. Assert it is enabled (so it starts on boot + is Wants='d by both
# watchers). Its being "active (exited)"/inactive is normal for a oneshot — enablement is what matters.
ck "box owner: claudebox-up.service enabled"        "systemctl --user is-enabled claudebox-up.service"
# R16 OPERATING SCOPE (issue #132): the org-wide host live-gate must gate discovery on the
# maintainer-confirmed scope set, else it re-opens the #165 leak. Assert the reader + scope.conf are
# installed AND the gate genuinely discriminates: fedora-desktop is IN-scope but NOT an apparatus repo,
# so it passes ONLY when scope.conf is present (a missing conf would deny it via the fallback) — that
# makes a non-scoping or broken gate a LOUD FAIL, not a silent revert to org-wide.
ck "live-gate: R16 scope gate functional"           "test -r \"\$HOME/.config/live-gate/scope.conf\" && \"\$HOME/.local/bin/repo-scope.sh\" check fedora-desktop && ! \"\$HOME/.local/bin/repo-scope.sh\" check definitely-not-a-scoped-repo"
# host self-update — dnf-automatic on the monthly cadence
ck "host: dnf-automatic timer enabled"             "systemctl is-enabled dnf5-automatic.timer"
# v1.2.39: fail2ban removed fleet-wide — the public ssh door is key-only (no password to brute-force),
# so the jail bought nothing. Assert it stays GONE (no service, no package) rather than active.
ck "host: fail2ban absent (key-only door)"         "! systemctl is-active --quiet fail2ban.service && ! rpm -q fail2ban-server"
# firewalld must NOT be installed (Fedora Cloud ships none; we pull nothing that adds it). setup-host.sh
# converges this; assert it stays converged.
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
