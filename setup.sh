#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.52 (release-doc de-ceremony: changelog-table convention; UPGRADING.md collapsed; docs only)
#
# Runs the two privilege layers in their correct identities (see README "Privilege layers"):
#   setup-host.sh  — the SYSTEM layer, as ROOT: host packages, /etc, system services, the
#                    tailnet node, and CREATES the operating user + its rootless prerequisites.
#   setup-user.sh  — the ROOTLESS layer, as the operating user: user podman socket, ssh keys,
#                    claudebox, Claude policy, verify. Needs NO host privilege.
# Idempotent — re-run safely.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
U="${BOOTSTRAP_USER:-core}"

if [ "$(id -u)" = 0 ]; then
    BOOTSTRAP_USER="$U" "$HERE/setup-host.sh"
    # ---- TTY FERRY across the su boundary ------------------------------------------------
    # The user layer asks interactive questions (its own + each workload's spin-up.sh), but
    # `su … < /dev/null` DETACHES the controlling terminal (util-linux TIOCSTI hardening when
    # stdin is not a tty) — so /dev/tty is ENXIO in that layer and every question silently ate
    # its default (verified live 2026-07-07: the App credential was never asked). Root still
    # holds the terminal here: capture the tty DEVICE, grant the operating user rw on it for
    # the setup duration only, and pass the path down as SPINUP_TTY (wizards read the device
    # directly — no controlling terminal needed). Fully-scripted runs (no tty) pass no
    # SPINUP_TTY and the wizards take env/defaults loudly.
    SPINUP_TTY=""
    if { exec 9</dev/tty; } 2>/dev/null; then
        SPINUP_TTY="$(readlink -f /proc/self/fd/9 2>/dev/null || true)"; exec 9<&-
    fi
    # Defensive: a quote in the device path would break the su -c string below (readlink of a
    # pts never contains one, but fail SAFE to "no ferry" rather than a mangled command).
    case "$SPINUP_TTY" in *"'"*) SPINUP_TTY="";; esac
    if [ -n "$SPINUP_TTY" ] && [ -e "$SPINUP_TTY" ]; then
        # Branch on setfacl SUCCESS, not existence: devpts does NOT support POSIX ACLs
        # (`setfacl` on /dev/pts/N fails "Operation not supported"), so on a real interactive
        # host the mode-grant fallback is the NORMAL path, not the exotic one.
        if command -v setfacl >/dev/null 2>&1 && setfacl -m "u:$U:rw" "$SPINUP_TTY" 2>/dev/null; then
            trap 'setfacl -x "u:$U" "$SPINUP_TTY" 2>/dev/null || true' EXIT
        else
            _tty_mode="$(stat -c %a "$SPINUP_TTY")"
            chmod o+rw "$SPINUP_TTY"
            trap 'chmod "$_tty_mode" "$SPINUP_TTY" 2>/dev/null || true' EXIT
        fi
    fi
    # Hand off to the operating user for the rootless layer. The root phase already
    # brought up its user bus, so `su -` finds it. `< /dev/null` keeps a queued paste line
    # (e.g. a following `passwd`) from being swallowed by a child that reads stdin.
    # Ferry the scripted-path App env through the environment-resetting `su` too — without
    # this, a headless run can never satisfy spin-up's "supply GH_APP_ID… via env" remedy
    # (the ids are PUBLIC integers / a secret NAME; the PEM itself never rides an env var here).
    su - "$U" -c "GH_KEYS_USER='${GH_KEYS_USER:-oso-gato}' SPINUP_TTY='$SPINUP_TTY' GH_APP_ID='${GH_APP_ID:-}' GH_APP_INSTALLATION_ID='${GH_APP_INSTALLATION_ID:-}' GH_APP_SECRET='${GH_APP_SECRET:-}' '$HERE/setup-user.sh'" < /dev/null
else
    # Invoked as the unprivileged user: run ONLY the rootless layer. The system layer must
    # already have been provisioned as root (run setup.sh as root on a fresh host).
    echo ">> Running the rootless (user) layer only. The SYSTEM layer must already be in place;"
    echo ">> on a fresh host run setup.sh as root instead."
    exec "$HERE/setup-user.sh"
fi
