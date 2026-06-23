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

# --- the one Day-0 question (read from the terminal, not stdin) ---------------
# Blank = the browser web-login fallback (a login.tailscale.com URL prints during setup).
if [ -z "$TS_AUTHKEY" ] && [ -r /dev/tty ]; then
    printf '>> Tailscale auth key for an UNATTENDED join (tskey-…; blank = browser web-login): ' >/dev/tty
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
# On success it reboots into the SELinux convergence (relabel -> soak -> enforcing).
# Staying permissive (SELINUX_TARGET=permissive) needs no reboot. A cancelled or
# mismatched passwd does NOT reboot — just re-run this script.
echo ">> Set core's admin/sudo + Cockpit/console password (never stored in the repo):"
if [ "${SELINUX_TARGET:-}" = permissive ]; then
    passwd core
    echo ">> permissive target — password set; no reboot needed."
else
    passwd core && reboot
fi
