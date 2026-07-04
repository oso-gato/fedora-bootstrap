#!/usr/bin/env bash
# build-candidate.sh — build ONE disposable candidate TARGET on the host engine + live-gate it.
#
# The host's half of the pre-merge loop: CI publishes nothing pullable on an OPEN PR
# (build.yml push:false on pull_request) and the dev box's NESTED engine cannot live-run a PID-1
# image (own-netns ping_group_range RO; own-pidns mount-proc denied), so the host is the ONLY
# surface that can build the candidate AND faithfully run it for a verdict.
#
# Sanctioned by policy/CLAUDE.md (v1.2.25) DISPOSABLE-VALIDATION-BUILD carve-out — this build:
#   - is tagged localhost/disposable/<name>:<suffix>    (NEVER a ghcr.io/oso-gato deploy ref)
#   - is NEVER `podman push`ed                          (the host holds no write:packages cred)
#   - is run --rm by the gate and `rmi`'d on teardown
#   - is NEVER a WORKLOAD_CONTAINERS member / never enters the workload-refresh deploy path
#
# Model C (dynamic): the orchestrator (live-gate-run.sh) fetches the PR head into an EPHEMERAL
# tree once and calls this builder ONCE PER declared build target (CFILE varies per target — e.g.
# fedora-desktop's xrdp=Containerfile vs grd=Containerfile.grd). So the primary path is
# "build context already materialized"; the legacy "git clone + ref" path is kept for standalone
# manual runs.
#
# Usage:
#   build-candidate.sh <name> <src> [git-ref] [Containerfile]
#     <name>       workload name (disposable tag + log only; a bare name, never a ref)
#     <src>        EITHER a materialized source tree (the build context — model C / default)
#                  OR a local git clone (combined with [git-ref] for the legacy/manual path)
#     [git-ref]    optional; ONLY with a git-clone <src>: ref to fetch+archive (e.g. pull/31/head).
#                  Omit (the model-C path) => <src> IS the build context as-is.
#     [Containerfile]  default: $CAND_CFILE, else Containerfile
#   env passed THROUGH to validate-candidate.sh: CAND_FENCE CAND_PROBE HEALTH (as $2)
#                                                CAND_SECRET_ENV CAND_SECRET_MOUNT
#                                                CAND_MEMORY CAND_PIDS CAND_HEALTH_*
#   env:  CAND_TAG (disposable tag suffix; default val-<sha>)   BUILD_ARGS   BUILD_ISOLATION
set -uo pipefail

NAME="${1:?usage: build-candidate.sh <name> <src> [git-ref] [Containerfile]}"
SRC_IN="${2:?src (a materialized tree OR a git clone) required}"
REF_IN="${3:-}"
CFILE="${4:-${CAND_CFILE:-Containerfile}}"

# Carve-out guard: <name> must be a bare workload name, so the tag can only be localhost/disposable/<name>.
case "$NAME" in */*|*:*|ghcr.io*|registry.*) echo "FATAL: <name> must be a bare workload name, not a ref ($NAME)"; exit 2;; esac
[ -d "$SRC_IN" ] || { echo "FATAL: $SRC_IN is not a directory"; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/validate-candidate.sh"
[ -x "$GATE" ] || GATE="$HOME/.local/bin/validate-candidate.sh"
[ -x "$GATE" ] || { echo "FATAL: validate-candidate.sh not found (looked in $HERE and ~/.local/bin)"; exit 2; }

# ---- PERSISTENT DNF/RPM PACKAGE CACHE (the churn served from cache) ----
# The host TOP-LEVEL engine is NOT chroot-isolated (unlike the dev box, which REQUIRES
# --isolation=chroot under which buildah's --mount=type=cache does not persist), so a plain writable
# BIND cache works here. Bind a home-volume dir onto the build's libdnf5 cache so the RPMs a candidate
# downloads PERSIST across every later candidate build: a forced re-run then re-uses them instead of
# re-downloading (measured 94s -> 33s on a forced in-box re-run). dnf5 (Fedora's default front-end)
# caches under /var/cache/libdnf5. This is decoupled from the podman LAYER cache (which already
# survives the candidate `rmi`): the layer cache reuses unchanged layers, the dnf bind cache means
# even a layer that DOES re-run dnf serves its RPMs from disk instead of the network. Bounded by
# throwaway-sweep.sh's cache GC (FD_DNF_CACHE_CAP_GB) so it can never exhaust the VPS quota.
FD_DNF_CACHE="${FD_DNF_CACHE:-$HOME/.cache/fd-dnf}"
mkdir -p "$FD_DNF_CACHE" 2>/dev/null || true

# Throwaway source trees live under ONE identifiable home-volume dir so the crash-orphan sweeper
# (throwaway-sweep.sh) can find + reap a tree a SIGKILL'd build left behind — the EXIT trap below only
# fires on a clean exit, never on `kill -9`/OOM.
FD_THROWAWAY_TMPDIR="${FD_THROWAWAY_TMPDIR:-$HOME/.cache/fd-throwaway}"
mkdir -p "$FD_THROWAWAY_TMPDIR" 2>/dev/null || true

# Resolve the build context + a SHA for the tag.
#   (1) legacy/standalone: <src> is a git clone + [git-ref] given -> fetch the ref, archive it to a
#       throwaway tree (no working-tree mutation). The throwaway tree is cleaned on exit.
#   (2) model C (default): <src> IS the build context (an ephemeral PR-head tree the caller owns +
#       cleans). No archive, no extra temp dir -> nothing for THIS script to leak.
CLEAN_SRC=""
if [ -n "$REF_IN" ] && [ -d "$SRC_IN/.git" ]; then
  echo "== fetch $REF_IN =="
  git -C "$SRC_IN" fetch -q origin "$REF_IN" || { echo "FATAL: git fetch $REF_IN failed"; exit 2; }
  SHA="$(git -C "$SRC_IN" rev-parse --short FETCH_HEAD)" || { echo "FATAL: cannot resolve ref"; exit 2; }
  SRC="$(mktemp -d "$FD_THROWAWAY_TMPDIR/bc.XXXXXX")"; CLEAN_SRC="$SRC"
  git -C "$SRC_IN" archive --format=tar FETCH_HEAD | tar -x -C "$SRC" || { echo "FATAL: archive/extract failed"; exit 2; }
else
  SRC="$SRC_IN"
  if [ -d "$SRC/.git" ]; then SHA="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo nogit)"; else SHA=nogit; fi
fi

TAG="localhost/disposable/${NAME}:${CAND_TAG:-val-${SHA}}"   # carve-out namespace — never pushed, never a deploy ref
# shellcheck disable=SC2064
trap "[ -n \"$CLEAN_SRC\" ] && rm -rf \"$CLEAN_SRC\"; podman rmi -f \"$TAG\" >/dev/null 2>&1 || true" EXIT
# Tear down on INT/TERM/HUP too (systemd stopping the live-gate timer sends SIGTERM): a plain `exit N`
# fires the EXIT trap above, so the disposable image + temp tree are reaped now instead of leaking
# until the age-gated throwaway-sweep. Matches build-throwaway.sh / validate-candidate.sh.
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP

[ -f "$SRC/$CFILE" ] || { echo "FATAL: $CFILE not found in candidate tree"; echo "VERDICT: RED (missing $CFILE)"; exit 1; }

echo "== build DISPOSABLE candidate $TAG (Containerfile=$CFILE; host top-level engine; layer cache retained + dnf bind cache $FD_DNF_CACHE; no --no-cache) =="
iso=(); [ -n "${BUILD_ISOLATION:-}" ] && iso=(--isolation="$BUILD_ISOLATION")
# shellcheck disable=SC2086
if ! podman build "${iso[@]}" ${BUILD_ARGS:-} -v "$FD_DNF_CACHE:/var/cache/libdnf5:rw" -t "$TAG" -f "$SRC/$CFILE" "$SRC"; then
  echo "VERDICT: RED (build failed)"; exit 1
fi

echo "== live-gate the candidate via Gate B (validate-candidate.sh) =="
"$GATE" "$TAG" "${HEALTH:-}"
rc=$?

echo "candidate ${NAME}@${SHA} [${CFILE}]: gate exit=$rc  (disposable image rmi'd on exit; base layers cached)"
exit "$rc"
