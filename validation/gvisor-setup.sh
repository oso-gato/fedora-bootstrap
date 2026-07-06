#!/usr/bin/env bash
# gvisor-setup.sh — install gVisor (runsc) as a ROOTLESS podman runtime for the live-gate.
#
# WHY: the host live-gate runs UN-MERGED, untrusted PR code. The shared-kernel podman fence
# (validate-candidate.sh) is the current boundary; gVisor adds a stronger one — a USER-SPACE kernel
# (runsc) that answers the candidate's syscalls itself, so a host-kernel exploit hits gVisor's kernel,
# not the host's. This is the feasible isolation upgrade on this VPS: a real VM / Kata / Firecracker
# needs /dev/kvm + nested virt, which Hostinger disables provider-side; gVisor needs neither.
#
# PROVENANCE — Build Principle 2 WAIVER (disclosed, requires operator sign-off). runsc is a persistent
# container-runtime BINARY. It is not in Fedora repos, gVisor ships no dnf repo, and it fits NONE of the
# three sanctioned class-(c) shapes (AppImage / webapp-into-runtime / deleted build-time tool) — it is a
# long-lived executable podman invokes. So it CANNOT be installed provenance-compliantly; it needs an
# explicit waiver, recorded here and in the PR. Mitigations kept as tight as the rule allows:
#   * fetched over TLS from gVisor's OWN canonical release bucket (storage.googleapis.com/gvisor), the
#     host/path pinned here and changeable only as a control-plane change — never a mirror/aggregator;
#   * VERSION-PINNED (GVISOR_RELEASE) per Principle 6 — bump deliberately, re-verify each bump;
#   * INTEGRITY-VERIFIED fail-closed: the publisher's runsc.sha512 is checked, and the GPG signature
#     verified when the signing key is present. Any mismatch/missing/unfetchable → hard fail, nothing
#     installed;
#   * INSTALLED USER-SPACE (~/.local/bin), never onto the immutable host root, and registered only in
#     the rootless user's containers.conf — no host-root, no system PATH.
#
# Idempotent. Run as the claudebox/live-gate user (rootless). Re-run after a GVISOR_RELEASE bump.
set -uo pipefail

# Pin — bump deliberately (Principle 6); 'latest' is accepted but discouraged (not reproducible).
GVISOR_RELEASE="${GVISOR_RELEASE:-20260401.0}"
GVISOR_BASE="https://storage.googleapis.com/gvisor/releases/release/${GVISOR_RELEASE}"
GVISOR_KEY_URL="https://gvisor.dev/archive.key"     # publisher's signing key (canonical)
ARCH="$(uname -m)"                                  # x86_64 / aarch64
BIN_DIR="$HOME/.local/bin"
CONF="$HOME/.config/containers/containers.conf"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM HUP
die(){ echo "gvisor-setup: FATAL: $*" >&2; exit 1; }

command -v curl >/dev/null || die "curl required"
command -v sha512sum >/dev/null || die "sha512sum required"
mkdir -p "$BIN_DIR" "$(dirname "$CONF")"

echo "== fetch runsc ${GVISOR_RELEASE} (${ARCH}) from the canonical gVisor bucket =="
url="${GVISOR_BASE}/${ARCH}/runsc"
curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/runsc"        "$url"        || die "download runsc failed ($url)"
curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/runsc.sha512" "$url.sha512" || die "download runsc.sha512 failed"

echo "== verify sha512 (fail-closed) =="
# The published .sha512 lists the bucket path, not our temp name — compare the digest field only.
want="$(awk '{print $1}' "$TMP/runsc.sha512" | head -1)"
got="$(sha512sum "$TMP/runsc" | awk '{print $1}')"
[ -n "$want" ] || die "no digest in runsc.sha512"
[ "$want" = "$got" ] || die "sha512 MISMATCH — want=$want got=$got (refusing to install)"
echo "  sha512 OK ($got)"

echo "== verify GPG signature IF the vendor ever publishes one (future-proof; currently NONE) =="
# VERIFIED 2026-07: the gVisor release bucket serves runsc + runsc.sha512 but NO runsc.asc (404) — the
# apt REPO metadata is GPG-signed, but the raw binary we install is not. Since we consume the binary
# (never apt), sha512 above is the integrity gate → this artifact is provenance grade c2 (checksum-only)
# per CLASS-C-RESHAPE. This block stays as a no-op-today future-proof: the day gVisor ships a detached
# binary signature, it fires and the artifact auto-upgrades to c1.
if curl -fsSL --proto '=https' -o "$TMP/runsc.asc" "$url.asc" 2>/dev/null && command -v gpg >/dev/null; then
  if curl -fsSL --proto '=https' -o "$TMP/gvisor.key" "$GVISOR_KEY_URL" 2>/dev/null; then
    export GNUPGHOME="$TMP/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    gpg --batch --import "$TMP/gvisor.key" >/dev/null 2>&1 || die "gpg import of publisher key failed"
    gpg --batch --verify "$TMP/runsc.asc" "$TMP/runsc" >/dev/null 2>&1 || die "GPG signature verify FAILED"
    echo "  GPG signature OK"
  else die "publisher .asc present but signing key unfetchable — fail closed"; fi
else
  echo "  (no detached .asc published for the raw binary — sha512 is the publisher's integrity gate here)"
fi

echo "== install user-space + register rootless runtime =="
install -m 0755 "$TMP/runsc" "$BIN_DIR/runsc" || die "install to $BIN_DIR failed"
echo "  installed $BIN_DIR/runsc"

# Register runsc as a podman runtime for THIS rootless user only (containers.conf). Merge, don't clobber.
if [ -f "$CONF" ] && grep -q '^\[engine.runtimes\]' "$CONF"; then
  if grep -qE '^\s*runsc\s*=' "$CONF"; then
    echo "  containers.conf already registers runsc — leaving as-is"
  else
    # insert a runsc line under the existing [engine.runtimes] table
    awk -v bin="$BIN_DIR/runsc" '1; /^\[engine.runtimes\]/ && !done {print "runsc = [\"" bin "\"]"; done=1}' \
      "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
    echo "  added runsc to [engine.runtimes] in $CONF"
  fi
else
  { printf '\n[engine.runtimes]\nrunsc = ["%s"]\n' "$BIN_DIR/runsc"; } >> "$CONF"
  echo "  wrote [engine.runtimes] runsc to $CONF"
fi

echo "== smoke: podman can see the runsc runtime =="
if podman --runtime runsc info >/dev/null 2>&1; then
  echo "  OK — podman recognizes runtime 'runsc'"
else
  echo "  NOTE: podman does not yet accept '--runtime runsc' — rootless gVisor may need cgroup/ptrace"
  echo "  tuning surfaced by validation/gvisor-feasibility.sh. Install is done; feasibility is the next step."
fi
echo "gvisor-setup: done (release ${GVISOR_RELEASE})."
