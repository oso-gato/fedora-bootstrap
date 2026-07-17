#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.67 (host self-refresh ARMED: the F16 absorber (host-code-refresh) that makes merged host code go live now actually WORKS + is VISIBLE. setup-host.sh chowns the control clone core-writable — the one root bootstrap step the absorber needed (a --user process can't git-merge a root-owned clone), so it was a permanent silent no-op and a human hand-copied every merged host change (incident 2026-07-17). setup-user.sh PRIMES it once so the host is current the moment setup finishes. host-code-refresh writes a per-tick HEARTBEAT (OK/BLOCKED/SKIPPED/FAILED + reason) and verify.sh asserts the absorber is armed + the clone is writable + the last tick was not BLOCKED/FAILED — so a non-self-refreshing host is a LOUD verify FAIL, not silence. The absorber becomes the sole pull mechanism (as core); after upgrading, a manual pull is `sudo -u core git -C /opt/fedora-bootstrap pull`. Covered by validation/host-code-refresh.test.sh (7 cases incl. not-writable→BLOCKED + a mutation). R23 host half.)
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
    # Capture the REAL device name (/dev/pts/N) via tty(1)/ttyname — NEVER the /proc fd-link
    # trick: an fd opened on /dev/tty readlinks back to the literal "/dev/tty" (the magic 5,0
    # alias's own dentry, not the pts it points at). Verified live round 5: the banner said
    # "/dev/tty -> core", and for core — whose su session has no controlling terminal — that
    # alias dereferences to NOTHING (ENXIO), which is precisely the problem being ferried
    # around. Only a concrete /dev/pts/N (or console) name survives the su boundary.
    SPINUP_TTY=""
    _t="$(tty </dev/tty 2>/dev/null || true)"
    case "$_t" in /dev/tty|'') _t="";; esac      # the alias itself is NOT a ferryable answer
    [ -n "$_t" ] && [ -e "$_t" ] && SPINUP_TTY="$_t"
    # Fallback: the controlling terminal per ps ("?" = none).
    if [ -z "$SPINUP_TTY" ]; then
        _pstty="$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')"
        [ -n "$_pstty" ] && [ "$_pstty" != "?" ] && [ -e "/dev/$_pstty" ] && SPINUP_TTY="/dev/$_pstty"
    fi
    # Defensive: a quote in the device path would break the su -c string below (readlink of a
    # pts never contains one, but fail SAFE to "no ferry" rather than a mangled command).
    case "$SPINUP_TTY" in *"'"*) SPINUP_TTY="";; esac
    # REPORT the ferry outcome either way — a silent no-terminal run cost a live Day-0
    # (2026-07-07: Tailscale question skipped wordlessly, App pastes impossible, FATAL at
    # user 4/5 with no hint why). day0.sh now refuses to start without a terminal; this
    # banner covers direct setup.sh runs and makes every log self-diagnosing.
    if [ -n "$SPINUP_TTY" ]; then
        echo ">> tty ferry: $SPINUP_TTY -> $U (user-layer questions will prompt on this terminal)"
    else
        echo ">> tty ferry: NO TERMINAL — user-layer questions take their defaults; App-credential" >&2
        echo ">>            pastes are impossible (fedora-dev's will FATAL unless GH_APP_* env is set)." >&2
        echo ">>            Interactive setup: run day0.sh from a plain 'ssh root@<host>' login." >&2
    fi
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
