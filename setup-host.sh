#!/usr/bin/env bash
# fedora-bootstrap — ROOT phase: the host SYSTEM layer.
#
# Run as ROOT. This performs ONLY operations that genuinely require root: install the
# host package set, write /etc system config, enable the SYSTEM systemd services, join
# the tailnet, CREATE the operating user, and stand up that user's rootless
# prerequisites (subuid/subgid via useradd, linger + user manager). It grants the user
# NO passwordless sudo. Everything rootless is done afterwards by setup-user.sh, run AS
# that user. See README "Privilege layers". Idempotent — re-run safely.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "setup-host.sh is the SYSTEM phase and must run as root. Run setup.sh as root (see README Day 0)." >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
U="${BOOTSTRAP_USER:-core}"
# Validate the operating-user name before it goes into useradd/sudoers: a crafted
# BOOTSTRAP_USER could otherwise inject a sudoers line that still passes `visudo -cf`.
case "$U" in (''|*[!a-z0-9_-]*) echo "FATAL: invalid BOOTSTRAP_USER '$U' (allowed chars: a-z 0-9 _ -)" >&2; exit 1 ;; esac
PHASE() { printf '\n==== %s ====\n' "$*"; }

PHASE "host 1/6 packages (Fedora repos + Tailscale's official repo)"
# Tailscale's OFFICIAL vendor repo. Write it (as root) straight into /etc/yum.repos.d —
# the system-owned dir, correct SELinux context — to a temp ".new" name dnf ignores,
# validate it's the real repo file, then atomically move it into place, so a partial or
# failed fetch never poisons dnf. Never stage through /tmp: a tmp_t-labelled file moved
# into /etc/yum.repos.d is the classic SELinux mislabel (and root-curl to a user-owned
# /tmp file fails with curl 23).
new=/etc/yum.repos.d/.tailscale.repo.new
if curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo -o "$new" \
   && grep -q '^\[tailscale-stable\]' "$new"; then
    mv -f "$new" /etc/yum.repos.d/tailscale.repo
    restorecon /etc/yum.repos.d/tailscale.repo 2>/dev/null || true
elif [ -s /etc/yum.repos.d/tailscale.repo ]; then
    rm -f "$new"; echo ">> tailscale.repo fetch failed; keeping existing repo file" >&2
else
    rm -f "$new"; echo "ERROR: could not fetch tailscale.repo and no existing copy present" >&2; exit 1
fi
dnf -y --setopt=install_weak_deps=False install \
    distrobox flatpak-session-helper podman tmux mosh openssh-server tailscale \
    cockpit cockpit-podman cockpit-files \
    cockpit-networkmanager cockpit-selinux
# cockpit-storaged is intentionally NOT installed (host-minimal, Build Principle 4): little
# use on a single-disk VPS, and it is the heaviest Cockpit add-on (udisks2 + libblockdev-* +
# mdadm). Remove it + its now-orphaned deps if an earlier run installed it (dnf clears
# no-longer-needed dependencies on removal by default).
rpm -q cockpit-storaged >/dev/null 2>&1 && dnf -y remove cockpit-storaged || true

PHASE "host 2/6 operating user '$U' + scoped passwordless-sudo allowlist"
# Create the unprivileged user that OWNS the rootless layer (podman, distrobox, Claude
# Code). useradd also allocates its /etc/subuid + /etc/subgid ranges — the rootless
# prerequisite. It joins 'wheel' so a human admin escalates WITH a password (set via
# `passwd`). It gets NO blanket NOPASSWD; instead a SCOPED passwordless allowlist
# (policy/sudoers.claudebox) lets the in-box Claude Code run ONLY a few specific host
# commands without a password — everything else still needs the password, so the agent is
# OS-blocked from it. Grow the allowlist ONLY by committing to the repo (policy/CLAUDE.md:
# "propose; the user commits"). (For a stricter posture, drop '-G wheel' and the allowlist.)
id "$U" >/dev/null 2>&1 || useradd -m -G wheel "$U"
# Install the scoped allowlist, validated with visudo BEFORE it goes live (a malformed
# sudoers file can lock out sudo — never install one unchecked). The temp name contains a
# dot so sudo's includedir ignores it until it is valid and renamed into place.
sed "s/__USER__/${U}/g" "$HERE/policy/sudoers.claudebox" > /etc/sudoers.d/.claudebox.new
chmod 0440 /etc/sudoers.d/.claudebox.new
if visudo -cf /etc/sudoers.d/.claudebox.new >/dev/null; then
    mv -f /etc/sudoers.d/.claudebox.new /etc/sudoers.d/claudebox
else
    rm -f /etc/sudoers.d/.claudebox.new
    echo "ERROR: policy/sudoers.claudebox failed visudo validation — scoped sudo not installed" >&2
    exit 1
fi

PHASE "host 3/6 system services"
systemctl enable --now sshd cockpit.socket tailscaled

PHASE "host 4/6 ssh: permit only LOGIN_KEY from authorized_keys"
# Whitelist ONLY the LOGIN_KEY variable (never the unsafe blanket `yes`, which would also
# permit LD_PRELOAD et al.). The keys themselves are synced into the user's own ~/.ssh by
# setup-user.sh (user layer).
tee /etc/ssh/sshd_config.d/20-login-key.conf >/dev/null <<'EOS'
# fedora-bootstrap: let authorized_keys carry environment="LOGIN_KEY=<device>",
# whitelisted to that single variable, so each session is tagged by the key that
# authenticated (used to name the per-device tmux session).
PermitUserEnvironment LOGIN_KEY
EOS
systemctl reload sshd 2>/dev/null || systemctl restart sshd

PHASE "host 5/6 tailscale (host node + Tailscale SSH; Cockpit over tailnet)"
if ! tailscale status >/dev/null 2>&1; then
    if [ -n "${TS_AUTHKEY:-}" ]; then
        tailscale up --ssh --auth-key="$TS_AUTHKEY"            # unattended join
    else
        echo ">> Tailscale needs browser auth. A https://login.tailscale.com/... link will"
        echo ">> print on the NEXT line. Open it now and approve this node."
        echo ">> (Or re-run with TS_AUTHKEY=tskey-... for an unattended join.)"
        # --timeout bounds the wait for tailscaled to reach RUNNING; the node stays in
        # NeedsLogin until you click the link, so this caps the auth hang. If you miss the
        # window, `up` exits non-zero, `|| true` absorbs it, and a re-run no-ops (gated).
        tailscale up --ssh --timeout=5m || true
    fi
fi
# Cockpit: tailnet-only (Fedora Cloud has no firewall — never expose 9090 publicly).
# `serve --https` needs MagicDNS + HTTPS Certificates enabled ONCE per tailnet (admin
# console: DNS > MagicDNS, then HTTPS Certificates); until then it would block on a
# consent URL, so bound it with `timeout`. The JSON guard matches the real schema
# {"TCP":{"443":...}}.
if ! tailscale serve status --json 2>/dev/null | tr -d ' \n' | grep -q '"TCP":{[^}]*"443"'; then
    timeout 15 tailscale serve --bg --https=443 http://127.0.0.1:9090 || \
        echo ">> Cockpit not yet served over the tailnet. Enable MagicDNS + HTTPS Certificates" \
             "in the Tailscale admin console (or complete the consent URL above), then re-run." >&2
fi

PHASE "host 6/6 tmux drop-in + bring up '$U' rootless user manager"
# System-wide login drop-in: ssh/mosh logins attach a per-device tmux session.
tee /etc/profile.d/zz-tmux-attach.sh >/dev/null <<'EOS'
# ssh/mosh logins attach to a tmux session named after the key that authenticated
# (LOGIN_KEY, from authorized_keys). Each device gets its own persistent session;
# all sessions share one server, so `tmux attach -t <other>` hops between them.
# Local/unkeyed logins fall back to the shared "main".
case $- in *i*) ;; *) return ;; esac
if [ -z "${TMUX:-}" ] && command -v tmux >/dev/null && { [ -n "${SSH_TTY:-}" ] || [ -t 0 ]; }; then
    exec tmux new-session -A -s "${LOGIN_KEY:-main}"
fi
EOS
# Stand up the user's systemd manager + D-Bus user bus NOW, as root, so the rootless
# phase (setup-user.sh, run via `su - $U`) finds the bus already up — no session-less
# `systemctl --user` race. enable-linger persists it across reboots; the explicit start
# blocks until the unit is active.
loginctl enable-linger "$U"
uid="$(id -u "$U")"
systemctl start "user@${uid}.service"
for _ in $(seq 1 100); do [ -S "/run/user/${uid}/bus" ] && break; sleep 0.1; done
[ -S "/run/user/${uid}/bus" ] || { echo "FATAL: user D-Bus (/run/user/${uid}/bus) never came up for '$U'." >&2; exit 1; }

echo ">> SYSTEM layer complete. Hand off to '$U' for the rootless layer (setup-user.sh)."
