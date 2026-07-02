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
#
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
# metadata is incomplete, RH BZ#1770125), NEVER auto-reboot (steady-state doctrine: a human decides
# reboots — the ONE sanctioned exception is the one-time SELinux setup convergence below, which
# self-disarms once enforcing is reached; from then on, never auto-reboot). The
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

# ---- SELinux: one-time convergence to ENFORCING — NO-WAIT (v1.2.49). A fresh Fedora Cloud host boots
# SELinux-DISABLED; enforcing on an UNLABELED fs can fail to boot (the RHEL-documented wedge), so the
# ONE brick-safe step kept is: relabel in PERMISSIVE first, then flip to enforcing once labeled.
# Everything the pre-v1.2.49 chain wrapped around that — a 15-min soak, an AVC acceptance gate, a
# post-enforce health check, an auto-revert, four units + the selinux-autoenforce.sh state machine — is
# DROPPED by design: a data-less throwaway VPS just re-provisions if enforcing ever wedges, so that
# insurance is not worth its complexity. Flow from disabled: SELINUX=permissive + /.autorelabel; the
# operator's `passwd core && reboot` boots into the relabel (permissive, safe) which auto-reboots; on
# that next (permissive, now-labeled) boot a FIRE-ONCE unit flips to enforcing LIVE (setenforce 1 +
# config) and self-disarms — 2 reboots, no waiting, enforcing without a 3rd reboot. Doctrine unchanged:
# sanctioned one-time SETUP machinery (not a steady-state agent reboot); never downgrade an
# already-enforcing host; fedora-dev stays SELinux-exempt (label=disable). Opt out: SELINUX_TARGET=permissive.
selc=/etc/selinux/config
seldir=/var/lib/fedora-bootstrap
selarmed="$seldir/selinux-enforce-armed"          # ConditionPathExists gate for the fire-once flip unit
seltarget="${SELINUX_TARGET:-enforcing}"
install -d -m0755 "$seldir"

# Converge a pre-v1.2.49 host: tear down the OLD multi-reboot chain (units, driver, chain markers) so
# nothing lingers. A clean no-op on a fresh host.
systemctl disable --now selinux-enforce.timer selinux-enforce-flip.service \
                        selinux-postenforce.timer selinux-postenforce.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/selinux-enforce.timer /etc/systemd/system/selinux-enforce-flip.service \
      /etc/systemd/system/selinux-postenforce.timer /etc/systemd/system/selinux-postenforce.service \
      /usr/local/sbin/selinux-autoenforce \
      "$seldir/selinux-chain.state" "$seldir/selinux-chain.rolled-back" \
      "$seldir/selinux-chain.aborted" "$seldir/selinux-chain.enforced"

# The fire-once flip helper: on the first permissive+labeled boot, go enforcing LIVE (no reboot) and
# self-disarm. Installed to a system root path (bin_t) so it may edit /etc/selinux/config + setenforce.
install -m0755 "$HERE/selinux-enforce-once.sh" /usr/local/sbin/selinux-enforce-once
restorecon /usr/local/sbin/selinux-enforce-once 2>/dev/null || true
tee /etc/systemd/system/selinux-enforce-once.service >/dev/null <<EOS
[Unit]
Description=fedora-bootstrap: one-time SELinux permissive->enforcing flip (no-wait, self-disarming)
ConditionSecurity=selinux
ConditionPathExists=$selarmed
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/selinux-enforce-once
[Install]
WantedBy=multi-user.target
EOS
systemctl daemon-reload

# set SELINUX= by substitution, or APPEND if the line is missing (never silently no-op).
_sel_set(){ if grep -qE '^SELINUX=' "$selc"; then sed -i "s/^SELINUX=.*/SELINUX=$1/" "$selc"; else printf 'SELINUX=%s\n' "$1" >> "$selc"; fi; restorecon "$selc" 2>/dev/null || true; }
_sel_unarm(){ rm -f "$selarmed"; systemctl disable selinux-enforce-once.service >/dev/null 2>&1 || true; }

# Branch on the LIVE kernel state (getenforce), not the config file — the config we may have just
# rewritten does not reflect the running mode until a reboot, so getenforce is what keeps re-runs and
# the pre-/post-relabel boots on the correct branch.
selcur=$(getenforce 2>/dev/null || true)
if [ ! -f "$selc" ] || [ -z "$selcur" ]; then
    echo ">> no getenforce/$selc (SELinux userspace absent?) — skipping SELinux config." >&2
elif grep -qE '(^| )selinux=0( |$)' /proc/cmdline 2>/dev/null; then
    # selinux=0 force-disables SELinux regardless of config — relabel/flip can never run. Don't arm.
    _sel_unarm
    echo ">> WARNING: 'selinux=0' on the kernel cmdline overrides $selc — SELinux cannot enable; enforcing NOT armed." >&2
    echo ">>   Remove selinux=0 from the bootloader, then re-run setup.sh." >&2
elif [ "$seltarget" != enforcing ]; then
    # Opt-out: permissive only. Relabel if coming from disabled so a later manual enforce stays safe.
    [ "$selcur" = Disabled ] && { [ -e /.autorelabel ] || touch /.autorelabel; }
    _sel_set permissive; _sel_unarm
    echo ">> SELINUX_TARGET=$seltarget -> permissive only; enforcing NOT armed (was $selcur). REBOOT if newly set."
elif [ "$selcur" = Enforcing ]; then
    _sel_set enforcing; _sel_unarm                # already converged — never downgrade
    echo ">> SELinux already enforcing — nothing to converge."
elif [ "$selcur" = Permissive ]; then
    # Already labeled (permissive) -> flip to enforcing LIVE now; no relabel, no reboot needed.
    _sel_set enforcing; setenforce 1 2>/dev/null || true; _sel_unarm
    echo ">> SELinux was permissive (labeled) -> flipped to ENFORCING live (no reboot needed)."
else
    # Disabled/unset -> permissive + full relabel now; arm the fire-once flip for the post-relabel boot.
    _sel_set permissive
    [ -e /.autorelabel ] || touch /.autorelabel
    : > "$selarmed"
    systemctl enable selinux-enforce-once.service >/dev/null 2>&1 || true
    echo ">> SELinux ARMED — no-wait convergence to ENFORCING (was $selcur):"
    echo ">>   REBOOT -> relabel in permissive (auto-reboots) -> next boot flips to ENFORCING live."
    echo ">>   = 2 reboots, NO waiting. Day-0 'passwd core && reboot' launches it; snapshot first."
    echo ">>   Opt out: SELINUX_TARGET=permissive ./setup.sh"
fi

PHASE "host 5/7 ssh: key-only door (keys = all of github.com/<user>.keys)"
# The login door is key-only (Fedora Cloud default). Authorized keys are ALL keys
# published on the GitHub account — synced into the user's own ~/.ssh by
# setup-user.sh (user layer); the account is the single trust root. No in-image
# allowlist and no LOGIN_KEY tagging (symmetric with the dev box). Converge an
# already-deployed host: drop the old per-device LOGIN_KEY sshd drop-in if present
# and reload sshd so PermitUserEnvironment is no longer set. Idempotent no-op on a
# fresh host. (PermitUserEnvironment was only ever scoped to LOGIN_KEY and is now
# unused; removing it keeps the door minimal.)
if [ -f /etc/ssh/sshd_config.d/20-login-key.conf ]; then
    rm -f /etc/ssh/sshd_config.d/20-login-key.conf
    systemctl reload sshd 2>/dev/null || systemctl restart sshd
fi

# NO fail2ban (removed v1.2.39). The public ssh door is KEY-ONLY (PasswordAuthentication off in the
# Fedora Cloud Base default) — there is no password to brute-force, so a fail2ban jail bought nothing
# here; the keys are the access control. (The matching fedora-dev change drops it on the dev box too,
# where it never even ran for lack of journald.) Converge an already-deployed host to the no-fail2ban
# footprint: stop+disable the service, drop the jail file, and remove the package (leaf + SELinux
# module) PLUS any legacy `fail2ban` METAPACKAGE baggage (firewalld/esmtp) a pre-v1.1.15 host may still
# carry. Idempotent: a clean no-op on a fresh host (nothing installed to stop or remove).
systemctl disable --now fail2ban.service 2>/dev/null || true
rm -f /etc/fail2ban/jail.d/sshd-fedora-bootstrap.local
dnf remove -y fail2ban fail2ban-server fail2ban-selinux fail2ban-firewalld fail2ban-sendmail firewalld esmtp libesmtp 2>/dev/null || true

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
# Enable IP forwarding BEFORE the join. The kernel only forwards packets for an exit node when this is on
# (Tailscale kb/1103), and `tailscale up --advertise-exit-node` warns when it is off — turning it on here is
# what lets --advertise-exit-node ride the authenticated `up` itself (below) with no warning. Written to the
# system-owned dir (correct SELinux context); idempotent.
if [ "$ADVERTISE_EXIT" = true ]; then
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' > /etc/sysctl.d/99-tailscale.conf
    sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null
    # Fedora Cloud Base ships no firewalld, and we install nothing that pulls it in, so this is a
    # DEFENSIVE no-op kept only in case a future package re-introduces firewalld. Only if firewalld is
    # actually running do
    # the exit-node docs (kb/1103, known issue tailscale/tailscale#3416) require masquerade so forwarded
    # internet egress is NAT'd.
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-masquerade && firewall-cmd --reload
    fi
fi
# Carry EVERY routing pref on the join so they apply atomically as part of authentication. --accept-routes
# on the join also avoids the transient "peers are advertising routes but --accept-routes is false" snapshot.
# CRITICAL: --advertise-exit-node MUST ride `up`, not a follow-up `tailscale set`. A post-`up` `set` can run
# before the node reaches Running (slow browser auth, pending device approval) and silently no-op — leaving the
# exit node UN-ADVERTISED and greyed-out in the admin console while the script still reports PASS. Sending it on
# `up` registers the advertised route with the control plane during login, so it always shows up for approval.
ts_up=(--ssh)
[ "$ACCEPT_ROUTES" = true ] && ts_up+=(--accept-routes)
[ "$ADVERTISE_EXIT" = true ] && ts_up+=(--advertise-exit-node)
# Day-0: if the environment didn't supply TS_AUTHKEY, ASK for one (an UNATTENDED join). A blank
# answer — or a non-interactive run (`setup.sh < /dev/null`) — falls through to the browser
# web-login join below. Same ask-or-web-login pattern the workload spin-up wizards follow.
if [ -z "${TS_AUTHKEY:-}" ] && [ -t 0 ]; then
    read -rp '>> Tailscale auth key for an UNATTENDED host join (tskey-…; blank = browser web-login): ' TS_AUTHKEY || TS_AUTHKEY=""
fi
if ! tailscale status >/dev/null 2>&1; then
    if [ -n "${TS_AUTHKEY:-}" ]; then
        tailscale up "${ts_up[@]}" --auth-key="$TS_AUTHKEY"   # unattended join
    else
        echo ">> Tailscale needs browser auth. A https://login.tailscale.com/... link will"
        echo ">> print on the NEXT line. Open it now and approve this node."
        echo ">> (Or re-run with TS_AUTHKEY=tskey-... for an unattended join.)"
        # Bounded wait for RUNNING, but failure is NOT swallowed: under set -e a timeout aborts the script so
        # the orchestrator's "investigate the failure" branch fires instead of a false PASS. (The old
        # `--timeout=5m || true` ate the timeout, then a racing `set` ate its own failure — that double-swallow
        # is what shipped half-configured nodes with the exit node never advertised.)
        tailscale up "${ts_up[@]}" --timeout=10m
    fi
fi
# Re-assert idempotently on every run (covers the already-up re-run path + pref drift). With forwarding already
# on and the node Running by now, this neither warns nor races.
tailscale set --accept-routes="$ACCEPT_ROUTES" --advertise-exit-node="$ADVERTISE_EXIT" \
    || echo ">> 'tailscale set' deferred (node not logged in?) — re-run setup.sh after completing browser-auth." >&2
if [ "$ADVERTISE_EXIT" = true ]; then
    # Verify the node is actually LOGGED IN and the advertise reached the control plane. Checking local prefs
    # alone is a false positive: `tailscale set` writes AdvertiseRoutes even on a logged-out (NeedsLogin) node,
    # so the route shows locally yet never propagates and the admin console keeps the exit node greyed. Gate on
    # BackendState=Running AND the advertised default route.
    # `tailscale debug prefs` is an unstable debug surface, but it is the only route-level signal for an
    # advertised-but-unapproved route; match EITHER default route since --advertise-exit-node advertises both
    # 0.0.0.0/0 and ::/0 (an IPv4-only match would false-fail an IPv6-present output).
    if tailscale status --json 2>/dev/null | grep -q '"BackendState":[[:space:]]*"Running"' \
       && tailscale debug prefs 2>/dev/null | grep -Eq '0\.0\.0\.0/0|::/0'; then
        echo ">> Tailscale: advertising as an exit node (default ON). One-time admin-console step remains —"
        echo ">> Machines > this VPS > Edit route settings > check 'Use as exit node'. Then on each client:"
        echo ">>   tailscale set --exit-node=<this-VPS> --exit-node-allow-lan-access"
    else
        echo "ERROR: node is not logged in (BackendState != Running) or the exit-node route is not advertised." >&2
        echo "       Complete the browser-auth link so the node reaches Running, then re-run setup.sh." >&2
        exit 1
    fi
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

PHASE "host 7/7 tmux drop-in + config + bring up '$U' rootless user manager"
# System-wide login drop-in: every ssh/mosh login gets its OWN session inside
# ONE shared "main" tmux group. The windows (the work) are shared across every
# client, but each connection's geometry + redraw state stay INDEPENDENT — so a
# small client never forces a resize on a large one. That is the multi-client
# geometry race: under one shared SESSION (window-size=latest) a newly-attaching
# client of a different size resizes the shared window to its own geometry and
# paints every OTHER client onto a foreign row/column grid -> garbled
# input+output (Prompt 3 / WebSSH, and the initial garble even on native
# terminals). Session groups give shared windows + per-session size (tmux(1):
# "Sessions in the same group share the same set of windows ... the current and
# previous window ... remain independent"). A single "main" group is deliberate:
# the primary access path is keyless Tailscale SSH, so a per-key/per-device model
# would collapse to "main" on the tailnet anyway AND would fragment the workspace
# across access methods. One "main" group = one continuous workspace over tailnet
# ssh, public ssh, and mosh. The per-connection "c<pid>" session self-destroys on
# disconnect; work persists in the detached "main" base.
tee /etc/profile.d/zz-tmux-attach.sh >/dev/null <<'EOS'
# ssh/mosh logins each get their own session in the shared "main" group.
case $- in *i*) ;; *) return ;; esac
if [ -z "${TMUX:-}" ] && command -v tmux >/dev/null && { [ -n "${SSH_TTY:-}" ] || [ -t 0 ]; }; then
    tmux has-session -t main 2>/dev/null || tmux new-session -d -s main 2>/dev/null || true
    exec tmux new-session -t main -s "c$$" \; set-option destroy-unattached on
fi
EOS
# tmux server config: multi-device geometry policy + clean co-view. A tmux window
# has exactly ONE size shared by every client viewing it (verified against tmux
# 3.6 source + a live multi-client harness), so differently-sized devices on the
# SAME tab cannot each be full-size — unfixable in tmux. What we control is which
# single size wins and how the mismatched client degrades (a smaller client gets
# a clean cursor-following crop; a larger one shows the content top-left and fills
# the surplus with fill-character — actively redrawn each frame, NOT garbage; the
# compiled default is the `·` middle-dot, the "screen full of dots" garble look).
#   window-size=latest (DEFAULT): the session follows the client that most
#     recently sent INPUT — type on the Mac and it's Mac-sized; pick up the iPad
#     and type and it rescales to the iPad. Both stay connected (mosh-friendly);
#     the idle device blank-letterboxes/crops and reclaims full size on its next
#     keystroke; when the active device disconnects the session falls to whoever
#     remains. This is the seamless macOS<->iPad handoff.
#   fill-character ' ': idle larger device's surplus is BLANK, not `·`.
#   aggressive-resize on: devices parked on DIFFERENT tabs each get their own size.
#   client-attached/-resized -> refresh-client: full server-driven repaint on
#     every attach/resize so a client that won't self-redraw (xterm.js / WebSSH /
#     mosh) gets a clean frame after each rescale.
tee /etc/tmux.conf >/dev/null <<'EOS'
set -g default-terminal "tmux-256color"
set -g window-size latest
setw -g aggressive-resize on
setw -g fill-character ' '
set-hook -g client-attached 'refresh-client'
set-hook -g client-resized  'refresh-client'
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
