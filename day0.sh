#!/usr/bin/env bash
# day0.sh — interactive Day-0 wizard for the fedora-bootstrap HOST (run as root).
# ============================================================================
# Mirrors the workload spin-up wizards (fedora-desktop / fedora-dev `spin-up.sh`):
# it ASKS the one Day-0 question — the Tailscale auth key — on the terminal, then
# runs `setup.sh`, then the one unavoidable manual step (core's password), which on
# success reboots into the SELinux convergence.
#
# WHY a wizard (and why run it as the LAST line of the Day-0 paste): a prompt placed
# *inside* a multi-line paste would read the NEXT pasted line as its answer. This
# wizard reads from the controlling terminal (`/dev/tty`) and is the final command,
# so there is nothing buffered behind it — the prompt is safe. `setup.sh` itself is
# unchanged: it still runs with stdin from /dev/null (it never reads the terminal);
# the key reaches it via the env. An env-supplied TS_AUTHKEY / SELINUX_TARGET is
# honored as-is (no prompt) — so a fully scripted Day-0 can skip this wizard and call
# `setup.sh` directly, exactly as before.
# ============================================================================
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "day0.sh: run as root on the fresh host (Day-0 setup)." >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TS_AUTHKEY="${TS_AUTHKEY:-}"

# --- TERMINAL PREFLIGHT (fail at the front door, not at user 4/5) --------------
# Day-0 is INTERACTIVE: the Tailscale key, the HOST GitHub App paste, and each workload's
# questions (fedora-dev's App paste) all read the terminal. Verified live 2026-07-07: with no
# terminal, the old silent [ -r /dev/tty ] guard skipped the Tailscale question WITHOUT A WORD,
# the host App declined itself, and setup died only at fedora-dev's App paste — three symptoms,
# one cause. A terminal is ABSENT when day0 is launched via `ssh root@host '<cmd>'` (command
# mode allocates NO tty), any piped/heredoc invocation, or console tools that don't allocate a
# pty. So refuse loudly up front, with the fix:
if ! { : </dev/tty; } 2>/dev/null; then
    echo "FATAL: no terminal (/dev/tty is not readable) — Day-0 asks interactive questions" >&2
    echo "  (Tailscale key + two GitHub App key pastes) and cannot proceed without one." >&2
    echo "  RUN IT INTERACTIVELY:  ssh root@<host>   (a plain login, NOT 'ssh host <cmd>')" >&2
    echo "                         /opt/fedora-bootstrap/day0.sh" >&2
    echo "  Or force a tty:        ssh -t root@<host> /opt/fedora-bootstrap/day0.sh" >&2
    echo "  Browser console (Hostinger etc. — no pty): wrap in script(1) to manufacture one:" >&2
    echo "                         script -qec /opt/fedora-bootstrap/day0.sh /dev/null" >&2
    echo "  (Fully-scripted runs: export TS_AUTHKEY + GH_APP_ID/GH_APP_INSTALLATION_ID/" >&2
    echo "   GH_APP_SECRET and call setup.sh directly — day0 is the interactive wizard.)" >&2
    exit 1
fi

# --- the one Day-0 question (read from the terminal, not stdin) ---------------
# Blank = the browser web-login fallback (a login.tailscale.com URL prints during setup).
if [ -z "$TS_AUTHKEY" ]; then
    {
        printf '── Tailscale key for THE HOST '\''%s'\'' (fedora-bootstrap) ────────────────────────\n' "${BOOTSTRAP_HOSTNAME:-erebus}"
        printf '   Joins the tailnet as node '\''%s'\'' (the VPS itself). The DEV BOX ('\''nox'\'') joins\n' "${BOOTSTRAP_HOSTNAME:-erebus}"
        printf '   separately, asked later in its own spin-up section.\n'
        printf '>> Tailscale auth key for HOST '\''%s'\'' (tskey-…; blank = browser web-login): ' "${BOOTSTRAP_HOSTNAME:-erebus}"
    } >/dev/tty
    IFS= read -r TS_AUTHKEY </dev/tty || TS_AUTHKEY=""
fi
export TS_AUTHKEY

# --- host setup (stdin = /dev/null so setup.sh never reads the terminal) ------
# With a key set, the tailnet join is unattended; blank => the login.tailscale.com
# URL prints here — open it and approve before setup continues.
if ! "$HERE/setup.sh" < /dev/null; then
    echo "*** setup failed — investigate (login.tailscale.com link? scoped sudoers? the verify.sh output above), then re-run $HERE/day0.sh" >&2
    exit 1
fi
echo "setup: all layers PASS."

# --- the one unavoidable manual step: core's password ------------------------
# On success it reboots into the no-wait SELinux convergence (relabel in permissive -> auto-reboot
# -> flips to enforcing live; 2 reboots, no wait).
# Staying permissive (SELINUX_TARGET=permissive) needs no reboot. A cancelled or
# mismatched passwd does NOT reboot — just re-run this script.
echo ">> Set core's admin/sudo + Cockpit/console password (never stored in the repo):"
if [ "${SELINUX_TARGET:-}" = permissive ]; then
    passwd core
    echo ">> permissive target — password set; no reboot needed."
else
    passwd core && reboot
fi
