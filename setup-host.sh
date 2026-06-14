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

PHASE "host 1/7 hostname"
# Name the box. `hostnamectl set-hostname` writes the STATIC name to /etc/hostname AND sets the live
# (transient) one in the same call — idempotent, no reboot. On a cloud VPS that alone is NOT durable:
# cloud-init's update_hostname module runs every boot and would REVERT it to the cloud-provided name, so we
# also install `preserve_hostname: true` — the one documented key that disables both its set- and
# update-hostname modules. It goes in a /etc/cloud/cloud.cfg.d/ DROP-IN (upgrade-safe; editing the vendor
# cloud.cfg risks .rpmnew churn). No /etc/hosts edit is needed on Fedora — nss-myhostname already resolves
# the local name (the 127.0.1.1 line is a Debian-ism). The OS name is independent of Hostinger's external
# srvNNN.hstgr.cloud forward/reverse DNS (which only Hostinger controls — you cannot get erebus.hstgr.cloud).
H="${BOOTSTRAP_HOSTNAME:-erebus}"
case "$H" in (''|-*|*-|*[!a-z0-9-]*) echo "FATAL: invalid BOOTSTRAP_HOSTNAME '$H' (RFC-1123: lowercase a-z 0-9 and hyphen, no leading/trailing hyphen)" >&2; exit 1 ;; esac
[ "${#H}" -le 63 ] || { echo "FATAL: BOOTSTRAP_HOSTNAME '$H' exceeds 63 characters" >&2; exit 1; }
hostnamectl set-hostname "$H"
install -d -m0755 /etc/cloud/cloud.cfg.d
printf '#cloud-config\npreserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
chmod 0644 /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
restorecon /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg 2>/dev/null || true
echo ">> hostname set to '$H' (cloud-init preserve_hostname drop-in installed; persists across reboots)."

PHASE "host 2/7 packages (Fedora repos + Tailscale's official repo)"
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
# Pre-warm Tailscale's repo metadata so the VISIBLE install below does NOT print the harmless, transient
# "repomd.xml GPG signature verification error: Signing key not found" first-contact notice. dnf5 verifies
# repomd against a PER-REPO keyring that is SEPARATE from rpm's package keyring (per dnf5.conf repo_gpgcheck:
# "OpenPGP keys for this check are stored separately ... and ... separately for each repository") — so
# `rpm --import` does NOT help; only dnf can populate it. Triggering that first-contact import here via a
# scoped `makecache`, with -y to auto-accept and all output suppressed, caches the key in dnf5's per-repo
# store; the install then finds it already trusted and runs clean. Best-effort (|| true): on failure the
# install just shows the notice as before — repomd is still verified and gpgcheck=1 still verifies packages.
dnf -y -q --repo=tailscale-stable makecache >/dev/null 2>&1 || true
# install_weak_deps=False pins the host footprint to EXACTLY this list (Build Principle 4, host-minimal):
# Cockpit's recommended add-in plugins are weak deps, so they are never pulled. The Packages table is the
# allowlist of what IS installed; an add-in that isn't listed simply isn't there (do NOT drop this flag).
dnf -y --setopt=install_weak_deps=False install \
    distrobox flatpak-session-helper podman tmux mosh openssh-server tailscale \
    dnf5-plugin-automatic \
    cockpit cockpit-podman cockpit-files \
    cockpit-networkmanager cockpit-selinux

PHASE "host 3/7 operating user '$U' + scoped passwordless-sudo allowlist"
# Create the unprivileged user that OWNS the rootless layer (podman, distrobox, Claude
# Code). useradd also allocates its /etc/subuid + /etc/subgid ranges — the rootless
# prerequisite. It joins 'wheel' so a human admin escalates WITH a password (set via
# `passwd`). It gets NO blanket NOPASSWD; instead a SCOPED passwordless allowlist
# (policy/sudoers.claudebox) lets the in-box Claude Code run ONLY a few specific host
# commands without a password — everything else still needs the password, so the agent is
# OS-blocked from it. Grow the allowlist ONLY by committing to the repo (policy/CLAUDE.md:
# "propose; the user commits"). (For a stricter posture, drop '-G wheel' and the allowlist.)
id "$U" >/dev/null 2>&1 || useradd -m -G wheel "$U"
# ENFORCE the no-blanket-NOPASSWD model for the OPERATING USER rather than assume it. cloud-init grants its
# default user `<user> ALL=(ALL) NOPASSWD:ALL` in /etc/sudoers.d/90-cloud-init-users; if such a user is reused
# as $U, that blanket rule sits ALONGSIDE our scoped allowlist (sudoers is a permissive union — the broad rule
# still wins) and would hand the unattended in-box agent full passwordless root. Strip ONLY $U's blanket
# NOPASSWD line(s) — leaving any other cloud-init admins' stanzas untouched (no over-reach) — so $U falls back
# to password-gated `wheel` + the scoped allowlist. On Hostinger's root-only image this file doesn't exist, so
# it is a no-op; a panel rebuild re-provisions from scratch and re-runs setup.sh, which re-applies this.
ci=/etc/sudoers.d/90-cloud-init-users
if [ -f "$ci" ] && grep -qE "^[[:space:]]*${U}[[:space:]].*NOPASSWD" "$ci"; then
    grep -vE "^[[:space:]]*${U}[[:space:]].*NOPASSWD" "$ci" > "${ci}.new" || true
    chmod 0440 "${ci}.new"
    if ! visudo -cf "${ci}.new" >/dev/null 2>&1; then
        rm -f "${ci}.new"; echo "WARN: could not safely rewrite $ci to drop '$U' NOPASSWD; left as-is" >&2
    elif [ -s "${ci}.new" ]; then
        mv -f "${ci}.new" "$ci"; restorecon "$ci" 2>/dev/null || true       # other admins' rules remain → keep filtered file
        echo ">> stripped cloud-init's blanket NOPASSWD for '$U' (other cloud-init users untouched); scoped-sudo model enforced."
    else
        rm -f "${ci}.new" "$ci"                                              # file held only $U's blanket grant → remove it
        echo ">> removed cloud-init's blanket NOPASSWD ($ci held only '$U'); scoped-sudo model enforced."
    fi
fi
# Install the scoped allowlist, validated with visudo BEFORE it goes live (a malformed
# sudoers file can lock out sudo — never install one unchecked). The temp name contains a
# dot so sudo's includedir ignores it until it is valid and renamed into place.
sed "s/__USER__/${U}/g" "$HERE/policy/sudoers.claudebox" > /etc/sudoers.d/.claudebox.new
chmod 0440 /etc/sudoers.d/.claudebox.new
if visudo -cf /etc/sudoers.d/.claudebox.new >/dev/null; then
    mv -f /etc/sudoers.d/.claudebox.new /etc/sudoers.d/claudebox
    restorecon /etc/sudoers.d/claudebox 2>/dev/null || true
else
    rm -f /etc/sudoers.d/.claudebox.new
    echo "ERROR: policy/sudoers.claudebox failed visudo validation — scoped sudo not installed" >&2
    exit 1
fi

PHASE "host 4/7 system services"
# Bind cockpit.socket to LOOPBACK *before* it ever starts. Its vendor default is `ListenStream=9090`
# on ALL interfaces — and with no firewall on Fedora Cloud that exposes Cockpit on the PUBLIC IP. The
# empty `ListenStream=` first RESETS that default (systemd drop-ins append to list directives, so the
# reset line is load-bearing — the documented Cockpit "TCP Port and Address" idiom), then we re-bind to
# 127.0.0.1 only. The SOLE ingress then becomes the tailnet `tailscale serve` proxy (host 6/7), making
# Cockpit genuinely tailnet-only. (Cockpit guide; systemd.socket(5). No FreeBind/semanage needed:
# loopback is always up and the port stays 9090.)
install -d /etc/systemd/system/cockpit.socket.d
tee /etc/systemd/system/cockpit.socket.d/listen.conf >/dev/null <<'EOS'
[Socket]
ListenStream=
ListenStream=127.0.0.1:9090
EOS
systemctl daemon-reload
systemctl enable --now sshd cockpit.socket tailscaled
# A running socket keeps its old listener until restarted, so re-assert the loopback bind on re-runs too.
systemctl restart cockpit.socket

# Unattended host updates — dnf5-plugin-automatic (Fedora 44 is dnf5; the dnf4 'dnf-automatic' is
# obsoleted). Apply ALL updates (upgrade_type=security is UNRELIABLE on Fedora — Bodhi security
# metadata is incomplete, RH BZ#1770125), NEVER auto-reboot (doctrine: a human decides reboots). The
# host override is /etc/dnf/automatic.conf (the dnf5 host-override path; vendor defaults live in
# /usr/share/dnf5/dnf5-plugins/automatic.conf). This is the HOST cadence; the claudebox container
# (which carries Claude Code) refreshes separately and daily via the rebuild harness (setup-user.sh).
tee /etc/dnf/automatic.conf >/dev/null <<'EOS'
[commands]
upgrade_type = default
download_updates = yes
apply_updates = yes
reboot = never
random_sleep = 0

[emitters]
emit_via = stdio
EOS
# Run MONTHLY on the 15th (the vendor unit ships daily 06:00). An empty OnCalendar= first CLEARS the
# shipped value (systemd list-directive reset), then the 15th is set; the vendor Persistent=true +
# RandomizedDelaySec stay, so a run missed because the host was off catches up on next boot.
install -d /etc/systemd/system/dnf5-automatic.timer.d
tee /etc/systemd/system/dnf5-automatic.timer.d/schedule.conf >/dev/null <<'EOS'
[Timer]
OnCalendar=
OnCalendar=*-*-15 06:00
EOS

# Reboot NOTIFIER (never reboots). Applied package updates do not take effect for running services or
# the kernel until a restart; this surfaces that as a login motd so a human can decide. `dnf
# needs-restarting` exits 0 = nothing needed (clear the notice), nonzero = reboot recommended (write
# it). Re-checked ~2min after boot (clears the notice once you HAVE rebooted) and daily.
install -d /etc/motd.d
tee /etc/systemd/system/reboot-needed-notify.service >/dev/null <<'EOS'
[Unit]
Description=Surface "reboot recommended" after package updates (NEVER reboots)
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'dnf -q needs-restarting >/dev/null 2>&1 && rm -f /etc/motd.d/15-reboot-needed || echo "** A reboot is recommended to finish applying updates (kernel/libraries); reboot at your convenience. **" > /etc/motd.d/15-reboot-needed'
EOS
tee /etc/systemd/system/reboot-needed-notify.timer >/dev/null <<'EOS'
[Unit]
Description=Check whether a reboot is recommended (after boot + daily)
[Timer]
OnBootSec=2min
OnCalendar=*-*-* 07:00
Persistent=true
[Install]
WantedBy=timers.target
EOS
systemctl daemon-reload
systemctl enable --now dnf5-automatic.timer reboot-needed-notify.timer

PHASE "host 5/7 ssh: permit only LOGIN_KEY from authorized_keys"
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

PHASE "host 6/7 tailscale (host node + Tailscale SSH; Cockpit over tailnet)"
# Routing posture — ON BY DEFAULT for this deployment: this box is meant to BE an exit node and to reach the
# home LAN. Override per run with TS_EXIT_NODE=0 and/or TS_ACCEPT_ROUTES=0 to turn either off.
#   accept-routes        : the VPS (and the host-netns containers — claudebox shares the host netns via
#                          `--network host`) accept the subnet routes your LAN router advertises, so they reach
#                          LAN devices. (Consequence: the in-box agent can reach your LAN too.)
#   advertise-exit-node  : the VPS offers itself as an exit node so your devices can egress via its public IP
#                          (needs the IP forwarding below — Tailscale kb/1103).
ts_bool(){ case "${1:-}" in 0|false|FALSE|no|off) echo false;; *) echo true;; esac; }   # default TRUE; only 0/false/off => off
ACCEPT_ROUTES="$(ts_bool "${TS_ACCEPT_ROUTES:-}")"; ADVERTISE_EXIT="$(ts_bool "${TS_EXIT_NODE:-}")"
# Carry --accept-routes on the FIRST join so `up` never prints the transient "peers are advertising routes but
# --accept-routes is false" snapshot (it would, if accept-routes flipped on only afterward). --advertise-exit-node
# is deliberately NOT on `up` — it would warn IP forwarding is off (we enable that just below), so it rides the
# `set`. `up` does not persist these flags across runs, so the `set` re-asserts them idempotently on every run.
ts_up=(--ssh); [ "$ACCEPT_ROUTES" = true ] && ts_up+=(--accept-routes)
if ! tailscale status >/dev/null 2>&1; then
    if [ -n "${TS_AUTHKEY:-}" ]; then
        tailscale up "${ts_up[@]}" --auth-key="$TS_AUTHKEY"   # unattended join
    else
        echo ">> Tailscale needs browser auth. A https://login.tailscale.com/... link will"
        echo ">> print on the NEXT line. Open it now and approve this node."
        echo ">> (Or re-run with TS_AUTHKEY=tskey-... for an unattended join.)"
        # --timeout bounds the wait for tailscaled to reach RUNNING; the node stays in
        # NeedsLogin until you click the link, so this caps the auth hang. If you miss the
        # window, `up` exits non-zero, `|| true` absorbs it, and a re-run no-ops (gated).
        tailscale up "${ts_up[@]}" --timeout=5m || true
    fi
fi
# Re-assert the posture every run with `tailscale set` (not `up`): changes only these prefs + persists, never
# disturbing the --ssh from join. Advertising/accepting is NOT enough by itself — one-time admin-console
# approvals still apply (below).
tailscale set --accept-routes="$ACCEPT_ROUTES" --advertise-exit-node="$ADVERTISE_EXIT" \
    || echo ">> 'tailscale set' deferred (node not logged in yet) — re-run setup.sh after completing the browser-auth link so the routing prefs land." >&2
if [ "$ADVERTISE_EXIT" = true ]; then
    # An exit node FORWARDS packets; the kernel only does that with IP forwarding on (Tailscale kb/1103;
    # `tailscale up --advertise-exit-node` itself warns when it is off). Write it in place to the
    # system-owned dir (correct SELinux context) and apply now. Idempotent.
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' > /etc/sysctl.d/99-tailscale.conf
    sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null
    # Fedora Cloud Base ships NO firewalld, so this is normally a no-op. Only if firewalld is actually
    # running do the exit-node docs (kb/1103, known issue tailscale/tailscale#3416) require masquerade
    # so forwarded internet egress is NAT'd.
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-masquerade && firewall-cmd --reload
    fi
    echo ">> Tailscale: advertising as an exit node (default ON). One-time admin-console step remains —"
    echo ">> Machines > this VPS > Edit route settings > check 'Use as exit node'. Then on each client:"
    echo ">>   tailscale set --exit-node=<this-VPS> --exit-node-allow-lan-access"
fi
# Publish Cockpit on the tailnet AND make Cockpit work behind that proxy. cockpit.socket is now
# loopback-only (host 4/7), so the ONLY way to reach Cockpit is this `tailscale serve` proxy (TLS at 443
# on the tailnet -> http://127.0.0.1:9090). `serve --https` only works once the tailnet has MagicDNS +
# HTTPS Certificates enabled, so the helper retries in the background and applies it the instant they're
# on — no setup.sh re-run, nothing to forget. It also writes /etc/cockpit/cockpit.conf with the node's
# MagicDNS Origin (required, or the login WebSocket is rejected cross-origin), which is only knowable
# once the node is named — hence done from the helper, post-serve. Type=simple => never blocks boot.
install -m0755 "$HERE/cockpit-tailnet-serve.sh" /usr/local/sbin/cockpit-tailnet-serve
tee /etc/systemd/system/cockpit-tailnet-serve.service >/dev/null <<'EOS'
[Unit]
Description=Publish Cockpit on the tailnet (tailscale serve :443 -> 127.0.0.1:9090) + matching cockpit.conf
Documentation=https://tailscale.com/kb/1242/tailscale-serve
After=tailscaled.service cockpit.socket network-online.target
Wants=tailscaled.service
# The MANAGER owns the retry (idiomatic systemd), not a bash sleep-loop: the helper makes ONE attempt and
# exits non-zero until MagicDNS + HTTPS Certificates are enabled; systemd reschedules it (Restart=on-failure
# + RestartSec below). A clean exit 0 (serve applied) is not a failure, so it stops on first success.
# StartLimitIntervalSec=0 lifts the start rate-limit so an open-ended wait (seconds to days) is never capped
# — systemd.unit(5): a Restart= unit that hits the start limit "is not attempted to be restarted anymore".
StartLimitIntervalSec=0

[Service]
# Type=oneshot, no RemainAfterExit: a fire-once provisioning task that retries until it can complete, then
# settles at inactive(dead) — the honest "work done" state (serve config persists in tailscaled regardless).
Type=oneshot
ExecStart=/usr/local/sbin/cockpit-tailnet-serve
Restart=on-failure
RestartSec=60s

[Install]
WantedBy=multi-user.target
EOS
systemctl daemon-reload
# enable for boot, and start NOW without blocking: a oneshot's start would otherwise wait for the (first,
# expected-to-fail) attempt and return non-zero under `set -e`. --no-block kicks it off in the background.
systemctl enable cockpit-tailnet-serve.service
systemctl start --no-block cockpit-tailnet-serve.service

PHASE "host 7/7 tmux drop-in + bring up '$U' rootless user manager"
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
