#!/usr/bin/env bash
# fedora-bootstrap — one-time SELinux permissive->enforcing flip (NO-WAIT, self-disarming).
#
# Installed by setup-host.sh to /usr/local/sbin/selinux-enforce-once (a system root path => bin_t, so
# it may edit /etc/selinux/config + setenforce). Run by selinux-enforce-once.service on the first boot
# that reaches multi-user.target AFTER the permissive relabel — by then the filesystem is labeled, so
# flipping to enforcing is brick-safe. It flips LIVE (setenforce 1) so no third reboot is needed, makes
# the change durable in config, then self-disarms (removes the arm marker + disables the unit) so it
# fires exactly once. See setup-host.sh "host 4/7" for the whole flow. Replaces the pre-v1.2.49
# selinux-autoenforce.sh state machine (soak + AVC gate + post-enforce health check + auto-revert).
set -uo pipefail
seldir=/var/lib/fedora-bootstrap; selc=/etc/selinux/config; armed="$seldir/selinux-enforce-armed"
[ -f "$armed" ] || exit 0

# Flip only once we are actually PERMISSIVE — i.e. the relabel boot has run (fs now labeled). The
# ConditionSecurity=selinux on the unit already fences the kernel-disabled boot; this double-checks the
# running mode so we never setenforce against an unlabeled fs.
if [ "$(getenforce 2>/dev/null)" = Permissive ]; then
    if grep -qE '^SELINUX=' "$selc"; then sed -i 's/^SELINUX=.*/SELINUX=enforcing/' "$selc"
    else printf 'SELINUX=enforcing\n' >> "$selc"; fi
    restorecon "$selc" 2>/dev/null || true
    setenforce 1 2>/dev/null || true
    logger -t selinux-enforce-once "flipped to ENFORCING (live) on a labeled fs; disarming" 2>/dev/null || true
fi

rm -f "$armed"
systemctl disable selinux-enforce-once.service >/dev/null 2>&1 || true
