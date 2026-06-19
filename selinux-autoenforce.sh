#!/usr/bin/env bash
# fedora-bootstrap — SELinux one-time disabled->enforcing convergence driver.
#
# Installed by setup-host.sh to /usr/local/sbin/selinux-autoenforce (a system root path =>
# bin_t; under enforcing this runs as unconfined_service_t with DAC fallback, so it MAY edit
# /etc/selinux/config (selinux_config_t), setenforce, and reboot — which is what the auto-revert
# needs). NEVER install this under ~/.local/bin (home_bin_t, wrong layer + wrong transition).
#
# The whole point: take a fresh, SELinux-DISABLED host to ENFORCING in one hands-off day-0 run,
# the Red Hat-sanctioned safe way (permissive-first + full relabel BEFORE enforcing, so enforcing
# never runs against an unlabeled filesystem). The machinery is one-time and SELF-DISARMS once a
# healthy enforcing boot is confirmed; steady-state doctrine is then plain "enforcing".
#
# Driven by setup-stamped system units (two .timer + their oneshot .service), each a no-op outside
# its phase (gated by the chain marker + a token, and ConditionSecurity=selinux so they never fire on
# the kernel-disabled boot). BOTH checks run via TIMERS (not the boot transaction) so their
# is-system-running gate can read 'running' — a WantedBy+After=multi-user.target oneshot would
# deadlock its own gate (cannot read 'running' until its own ExecStart returns):
#   soak-confirm  (selinux-enforce-flip.service, fired ~15min after the permissive Boot2 by
#                  selinux-enforce.timer): exercise + acceptance gate; on PASS flip to enforcing.
#   post-enforce  (selinux-postenforce.service, fired ~2min into each armed boot by
#                  selinux-postenforce.timer; acts only when token=ENFORCING-PENDING):
#                  confirm the enforcing boot is healthy -> self-disarm; else AUTO-REVERT to permissive.
#
# Boot sequence (from a disabled host; first reboot is operator-initiated, the rest are automatic):
#   Boot1 permissive + /.autorelabel -> stock selinux-autorelabel.service relabels -> auto-reboots
#   Boot2 permissive, labeled        -> ~SOAK settle -> soak-confirm: gate PASS -> SELINUX=enforcing -> reboot
#   Boot3 enforcing,  labeled        -> post-enforce: healthy -> disarm (DONE); broken -> setenforce 0 +
#                                       SELINUX=permissive + .rolled-back + reboot (no loop)
#
# State token in $STATE:  ARMED -> ENFORCING-PENDING -> (marker removed = DONE)
# Terminal markers (setup-host.sh will NOT auto-re-arm while either is present):
#   selinux-chain.rolled-back  enforcing boot was unhealthy; auto-reverted to permissive
#   selinux-chain.aborted      permissive soak gate never passed; stayed permissive
set -uo pipefail

STATEDIR=/var/lib/fedora-bootstrap
STATE="$STATEDIR/selinux-chain.state"
ROLLED_BACK="$STATEDIR/selinux-chain.rolled-back"
ABORTED="$STATEDIR/selinux-chain.aborted"
ENFORCED="$STATEDIR/selinux-chain.enforced"
SELC=/etc/selinux/config
UNITS="selinux-enforce.timer selinux-enforce-flip.service selinux-postenforce.timer selinux-postenforce.service"

# Acceptance-gate tuning. Soak is an EVENT gate with a settle floor, not a fixed clock: the timer
# already waited OnBootSec before we run, then we poll the gate to absorb slow-starting services.
GATE_TRIES=10                                     # poll attempts...
GATE_SLEEP=30                                     # ...GATE_SLEEP apart (~5 min absorption window)

log(){ printf '[selinux-autoenforce] %s\n' "$*"; logger -t selinux-autoenforce -- "$*" 2>/dev/null || true; }
token(){ [ -f "$STATE" ] && tr -d '[:space:]' < "$STATE" 2>/dev/null || true; }

# Substitute or APPEND SELINUX= — never silently no-op on a config that lacks the line.
set_selinux(){
    if grep -qE '^SELINUX=' "$SELC" 2>/dev/null; then
        sed -i "s/^SELINUX=.*/SELINUX=$1/" "$SELC"
    else
        printf 'SELINUX=%s\n' "$1" >> "$SELC"
    fi
    restorecon "$SELC" 2>/dev/null || true
    log "set $SELC -> SELINUX=$1"
}

# Remove the marker and disable every chain unit so nothing re-fires on a later boot.
disarm(){ rm -f "$STATE"; systemctl disable $UNITS >/dev/null 2>&1 || true; log "chain disarmed (marker removed, units disabled)"; }

# Best-effort, NON-disruptive exercise of the denial-prone paths a purely idle soak would miss,
# so any AVC they trigger is logged BEFORE the gate reads ausearch. The Cockpit *WebSocket* and a
# full box-rebuild cannot be faithfully synthesized headless — that residual is exactly what the
# Boot3 post-enforce health check + auto-revert exists to catch.
exercise(){
    curl -ksS --max-time 5 https://127.0.0.1:9090/ping >/dev/null 2>&1 || true   # cockpit-ws loopback
    runuser -u core -- env XDG_RUNTIME_DIR=/run/user/1000 podman info >/dev/null 2>&1 || true  # rootless podman
    runuser -u core -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active fedora-dev.service >/dev/null 2>&1 || true
}

# Fail-CLOSED acceptance gate. Returns 0 only if the host is demonstrably healthy AND clean of
# SELinux denials since this boot. Used for both the permissive soak and the post-enforce check.
# Assumes base @core tooling: audit (ausearch) + libselinux-utils (get/setenforce) + policycoreutils
# (restorecon/fixfiles/selinux-autorelabel) — all ship in the Fedora Cloud image; if auditd is
# somehow inactive the gate fails closed below.
gate_once(){
    local why="" s sysstate avc
    systemctl is-active --quiet auditd || why="auditd inactive (ausearch would be falsely empty)"
    if [ -z "$why" ]; then
        sysstate=$(systemctl is-system-running 2>/dev/null || true)
        # 'degraded' (one unrelated failed unit) is a common healthy steady state — accept it. The
        # SELinux signal is the AVC count + the named critical services below, not global unit health;
        # rejecting all 'degraded' would spuriously abort the soak / auto-revert on normal hosts.
        case "$sysstate" in running|degraded) ;; *) why="systemctl is-system-running='$sysstate' (want: running/degraded)" ;; esac
    fi
    if [ -z "$why" ]; then
        for s in sshd.service tailscaled.service cockpit.socket fail2ban.service; do
            systemctl is-active --quiet "$s" || { why="$s not active"; break; }
        done
    fi
    if [ -z "$why" ]; then
        avc=$(ausearch -m avc -ts boot 2>/dev/null | grep -c 'type=AVC' || true)
        [ "${avc:-0}" -eq 0 ] || why="${avc} SELinux AVC denial(s) since boot"
    fi
    if [ -n "$why" ]; then log "gate FAIL: $why"; return 1; fi
    log "gate PASS: system running; sshd/tailscaled/cockpit/fail2ban active; 0 AVC denials since boot"
    return 0
}

# Poll the gate to absorb slow-starting services. Returns 0 on first PASS, 1 if never.
gate_wait(){
    local i
    for i in $(seq 1 "$GATE_TRIES"); do
        exercise
        if gate_once; then return 0; fi
        [ "$i" -lt "$GATE_TRIES" ] && { log "gate not clean (attempt $i/$GATE_TRIES); waiting ${GATE_SLEEP}s"; sleep "$GATE_SLEEP"; }
    done
    return 1
}

cmd_soak_confirm(){
    [ "$(token)" = "ARMED" ] || { log "soak-confirm: token!=ARMED (token='$(token)') — no-op"; exit 0; }
    [ "$(getenforce 2>/dev/null)" = "Permissive" ] || { log "soak-confirm: getenforce!=Permissive — no-op"; exit 0; }
    log "soak-confirm: permissive soak gate starting (exercise + ausearch, fail-closed)"
    if gate_wait; then
        # Token BEFORE config (and before reboot) fails toward permissive: a crash in this window
        # leaves config=permissive, which post-enforce detects next boot and self-heals to permissive
        # (never a silent stall). sync makes the config write durable before the reboot.
        echo "ENFORCING-PENDING" > "$STATE"
        set_selinux enforcing
        sync
        log "soak clean -> flipped config to enforcing; rebooting into the enforcing boot"
        systemctl reboot
    else
        set_selinux permissive                        # belt-and-suspenders: stay permissive
        printf 'soak gate never passed at %s\n' "$(date -u +%FT%TZ 2>/dev/null || echo unknown)" > "$ABORTED"
        disarm
        # exit 0, not 1: the .aborted marker + disarm record the terminal state. A nonzero ExecStart
        # would mark this oneshot 'failed' -> is-system-running='degraded' -> poisons a later re-run's gate.
        log "ABORTED: soak gate never passed — host stays PERMISSIVE. Investigate (ausearch -m avc -ts boot), then clear $ABORTED and re-run setup.sh to retry."
        exit 0
    fi
}

cmd_post_enforce(){
    [ "$(token)" = "ENFORCING-PENDING" ] || { log "post-enforce: token!=ENFORCING-PENDING (token='$(token)') — no-op"; exit 0; }
    if [ "$(getenforce 2>/dev/null)" != "Enforcing" ]; then
        # Expected Enforcing on this boot. Not enforcing => the flip didn't take (a crash in the
        # token->config window, or selinux=0 on the cmdline). Fail SAFE and SELF-HEAL toward
        # permissive: abort the chain rather than loop or sit silently stalled.
        set_selinux permissive
        printf 'flip did not result in enforcing (getenforce=%s) at %s\n' "$(getenforce 2>/dev/null)" "$(date -u +%FT%TZ 2>/dev/null || echo unknown)" > "$ABORTED"
        disarm
        log "ABORTED: token=ENFORCING-PENDING but not enforcing this boot — staying PERMISSIVE, chain disarmed. Investigate, clear $ABORTED, re-run setup.sh."
        exit 0
    fi
    log "post-enforce: enforcing boot reached; running health gate (auto-revert on failure)"
    if gate_wait; then
        printf 'enforcing confirmed healthy at %s\n' "$(date -u +%FT%TZ 2>/dev/null || echo unknown)" > "$ENFORCED"
        disarm
        log "DONE: enforcing boot healthy. Chain self-disarmed; steady state is now enforcing."
    else
        setenforce 0 2>/dev/null || true              # instant live relief on THIS boot
        set_selinux permissive                        # durable revert for the next boot
        printf 'enforcing boot UNHEALTHY; auto-reverted to permissive at %s\n' "$(date -u +%FT%TZ 2>/dev/null || echo unknown)" > "$ROLLED_BACK"
        disarm                                         # terminal: do NOT loop / re-arm
        sync                                           # make the permissive revert durable before reboot
        log "AUTO-REVERT: enforcing boot unhealthy -> setenforce 0 + SELINUX=permissive + $ROLLED_BACK written. Rebooting into permissive. setup.sh will NOT re-arm until you investigate and remove $ROLLED_BACK."
        systemctl reboot
    fi
}

case "${1:-}" in
    soak-confirm) cmd_soak_confirm ;;
    post-enforce) cmd_post_enforce ;;
    *) echo "usage: ${0##*/} {soak-confirm|post-enforce}" >&2; exit 2 ;;
esac
