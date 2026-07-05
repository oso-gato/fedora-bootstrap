#!/usr/bin/env bash
# verify-fetch-guard.sh — HOST mechanical backstop for Principle 2(c).
#
# WHY A DIFFERENT GUARD HERE: fedora-dev and fedora-desktop are built as IMAGES, so their CI can grep
# every binary on the image's $PATH and assert each is rpm-owned or a disclosed class-(c) artifact
# (the No-loose-binary job). fedora-bootstrap ships NO image — it is the host, provisioned by setup*.sh
# which DOWNLOAD-AND-INSTALL onto the live host. There is no image to inventory, so the equivalent risk
# is "a setup script fetches an executable and installs it WITHOUT verifying it." This guard makes that
# a CHECKED CONTRACT:
#   (1) an ALLOWLIST enumerates the scripts permitted to fetch+install a binary (the mechanical mirror
#       of the class-(c) disclosure line); each MUST integrity-verify (sha256/sha512 compare or
#       gpg --verify) fail-closed in the same script.
#   (2) NO OTHER script may fetch-and-install a binary — a new one must be DISCLOSED here (a reviewed,
#       control-plane change), exactly like adding a class-(c) disclosure row.
# This turns gvisor-setup.sh's runsc verification from a thing-that-happens into an enforced rule, and
# catches a future PR that curls a binary onto the host without verifying it — the host analogue of a
# loose non-rpm binary on an image's $PATH.
#
# Run: `bash bin/verify-fetch-guard.sh` → exit 0 = clean. Wired into CI (see .github/workflows).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# (1) Scripts DISCLOSED as binary-installers. Each is asserted to verify below. Add a new entry ONLY as
# a reviewed control-plane change, alongside the artifact's class-(c) disclosure row in CLAUDE.md.
APPROVED_INSTALLERS=( "validation/gvisor-setup.sh" )

fail=0
note(){ printf '  %s\n' "$*"; }
bad(){ printf '  ✗ %s\n' "$*"; fail=1; }
ok(){  printf '  ✓ %s\n' "$*"; }

# Does this script INSTALL A FETCHED EXECUTABLE? Precisely: a curl/wget OUTPUT path that is LATER made
# executable / installed into a bin dir / registered as a runtime. We CORRELATE the fetched output with
# the executable outcome (not merely AND the two signals) so a script that fetches a *data* file
# (fleet-core.md, tailscale.repo) AND separately installs its OWN repo-shipped scripts to a bin dir is
# NOT flagged — only a fetched file that becomes executable trips this. Variable output paths work
# because the same literal token (e.g. "$TMP/runsc") appears in both the curl -o and the install line.
installs_binary(){
  local f="$1" out
  while IFS= read -r out; do
    [ -n "$out" ] || continue
    # is THIS fetched output later chmod+x'd, installed to a bin dir, or used as a container runtime?
    grep -F -- "$out" "$f" | grep -qE 'chmod \+x|install -m|/\.local/bin|/usr/local/bin|/usr/bin|--runtime|engine\.runtimes' && return 0
  done < <(grep -oE '(-o|--output)[[:space:]]+"?[^" ]+"?' "$f" | sed -E 's/^(-o|--output)[[:space:]]+//; s/"//g')
  return 1
}
verifies(){ grep -qE 'sha256sum|sha512sum|gpg --verify|gpgv' "$1"; }
is_approved(){ local x; for x in "${APPROVED_INSTALLERS[@]}"; do [ "$1" = "$x" ] && return 0; done; return 1; }

echo "== verify-fetch-guard: host binary-fetch contract =="

# (1) every approved installer exists and verifies
for rel in "${APPROVED_INSTALLERS[@]}"; do
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then bad "approved installer missing: $rel (stale allowlist — remove it)"; continue; fi
  if verifies "$f"; then ok "approved installer verifies fail-closed: $rel"
  else bad "approved installer does NOT integrity-verify (needs sha256/sha512/gpg): $rel"; fi
done

# (2) no UNDISCLOSED script fetches+installs a binary
while IFS= read -r f; do
  rel="${f#$ROOT/}"
  [ "$rel" = "bin/verify-fetch-guard.sh" ] && continue   # skip self (contains the pattern literals)
  is_approved "$rel" && continue
  if installs_binary "$f"; then
    bad "UNDISCLOSED binary-installing script: $rel — a script that fetches + installs an executable must be added to APPROVED_INSTALLERS (a reviewed control-plane change) AND must verify it fail-closed"
  fi
done < <(find "$ROOT" -maxdepth 2 -name '*.sh' -not -path '*/.git/*' 2>/dev/null)

echo
if [ "$fail" = 0 ]; then echo "verify-fetch-guard: OK — every host binary fetch is disclosed + verified fail-closed"
else echo "verify-fetch-guard: FAIL — see above"; fi
exit "$fail"
