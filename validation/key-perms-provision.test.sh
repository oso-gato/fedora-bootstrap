#!/usr/bin/env bash
# key-perms-provision.test.sh — the deployed Quadlet-provisioning sed in setup-user.sh mounts the two
# GitHub App private keys owner-only 0400 (drift-guard for the audit 2026-07-22 finding #5).
#
# WHY: setup-user.sh writes the LIVE fedora-dev Quadlet. It previously uncommented the App `Secret=` lines
# with NO mode= parameter, so podman applied its default 0444 (world-readable) — letting any in-box uid-1000
# process read the FITNESS key and mint a fitness token (collapsing author≠judge). This guard fails if a
# future edit drops the owner/mode, or narrows the anchor so a setup.sh re-run can no longer self-heal an
# already-uncommented (0444) live Quadlet.
#   * DEV key  → uid=1000,gid=1000,mode=0400 (its reader is `core` inside fedora-dev).
#   * FITNESS  → mode=0400, owner left root (its reader is fedora-dev PID-1 root); NO uid=/gid=.
#   * anchor   → `^#* *` (zero-or-more `#`) so the sed matches a commented OR already-uncommented line.
#
# Runs on a plain runner (pure grep; FENCE_CHECK_ONLY irrelevant). bash validation/key-perms-provision.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_SRC="$(cd "$HERE/.." && pwd)"
SU="$REPO_SRC/setup-user.sh"
[ -f "$SU" ] || { echo "FATAL: setup-user.sh not found at $SU"; exit 2; }

fails=0
ck() { if [ "$2" -eq 0 ]; then printf 'ok   — %s\n' "$1"; else printf 'FAIL — %s\n' "$1"; fails=$((fails+1)); fi; }

# The dev-key provisioning sed: owner-only 0400 owned by core, matched with the self-heal anchor.
ck "dev-key sed replacement is ...target=gh_app_key,uid=1000,gid=1000,mode=0400" \
   "$(grep -Eq 'Secret=\$\{GH_APP_SECRET\},type=mount,target=gh_app_key,uid=1000,gid=1000,mode=0400' "$SU"; echo $?)"
ck "dev-key sed anchor is self-healing ^#* * (matches commented AND uncommented)" \
   "$(grep -Eq 's\|\^#\* \*Secret=gh_app_key,type=mount' "$SU"; echo $?)"

# The fitness-key provisioning sed: mode=0400, owner stays root (no uid=/gid=), self-heal anchor.
ck "fitness-key sed replacement is ...target=gh_app_key_fitness,mode=0400" \
   "$(grep -Eq 'Secret=\$\{GH_APP_FITNESS_SECRET\},type=mount,target=gh_app_key_fitness,mode=0400' "$SU"; echo $?)"
ck "fitness-key sed does NOT pin uid/gid (owner must stay root)" \
   "$(! grep -E 'target=gh_app_key_fitness' "$SU" | grep -Eq 'uid=|gid='; echo $?)"
ck "fitness-key sed anchor is self-healing ^#* *" \
   "$(grep -Eq 's\|\^#\* \*Secret=gh_app_key_fitness,type=mount' "$SU"; echo $?)"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails assertion(s) failed"; exit 1; fi
echo "ok — setup-user.sh provisions both App keys owner-only 0400 (dev=core, fitness=root), self-healing anchor"
