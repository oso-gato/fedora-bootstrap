#!/usr/bin/env bash
# build-candidate.sh — the pre-merge BUILD step the host live-gate needs.
#
# Build a workload's candidate as a DISPOSABLE image on the host's TOP-LEVEL engine,
# live-gate it via validate-candidate.sh, then discard it (base layers stay cached for the
# next churn). This is the host's half of the pre-merge loop: CI publishes nothing pullable
# on an OPEN PR (build.yml push:false on pull_request) and the dev box's NESTED engine cannot
# live-run a PID-1 image (own-netns ping_group_range RO; own-pidns mount-proc denied), so the
# host is the ONLY surface that can build the candidate AND faithfully run it for a verdict.
#
# Sanctioned by policy/CLAUDE.md (v1.2.25) DISPOSABLE-VALIDATION-BUILD carve-out — this build:
#   - is tagged localhost/disposable/<name>:val-<sha>   (NEVER a ghcr.io/oso-gato deploy ref)
#   - is NEVER `podman push`ed                          (the host holds no write:packages cred)
#   - is run --rm by the gate and `rmi`'d on teardown
#   - is NEVER a WORKLOAD_CONTAINERS member / never enters the workload-refresh deploy path
#
# Usage:
#   build-candidate.sh <name> <repo-dir> [git-ref] [Containerfile]
#     <name>       workload name (disposable tag + log only; a bare name, never a ref)
#     <repo-dir>   a local git clone of the workload repo
#     [git-ref]    optional ref to build (e.g. 'pull/31/head', a branch, a sha). A 'pull/N/head'
#                  ref is fetched first. Omit = build the clone's current HEAD.
#     [Containerfile]  default: Containerfile
#   env passed THROUGH to validate-candidate.sh:  CAND_FENCE  CAND_PROBE  HEALTH (as $2)
#   env:  BUILD_ARGS (extra `--build-arg ...`)   BUILD_ISOLATION (e.g. chroot; default = engine default)
set -uo pipefail

NAME="${1:?usage: build-candidate.sh <name> <repo-dir> [git-ref] [Containerfile]}"
REPO="${2:?repo-dir required}"
REF_IN="${3:-}"
CFILE="${4:-Containerfile}"

# Carve-out guard: <name> must be a bare workload name, so the tag can only be localhost/disposable/<name>.
case "$NAME" in */*|*:*|ghcr.io*|registry.*) echo "FATAL: <name> must be a bare workload name, not a ref ($NAME)"; exit 2;; esac
[ -d "$REPO/.git" ] || { echo "FATAL: $REPO is not a git clone"; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/validate-candidate.sh"
[ -x "$GATE" ] || GATE="$HOME/.local/bin/validate-candidate.sh"
[ -x "$GATE" ] || { echo "FATAL: validate-candidate.sh not found (looked in $HERE and ~/.local/bin)"; exit 2; }

# Resolve the ref (fetch a PR head first if asked).
if [ -n "$REF_IN" ]; then
  echo "== fetch $REF_IN =="
  git -C "$REPO" fetch -q origin "$REF_IN" || { echo "FATAL: git fetch $REF_IN failed"; exit 2; }
  REF=FETCH_HEAD
else
  REF=HEAD
fi
SHA="$(git -C "$REPO" rev-parse --short "$REF")" || { echo "FATAL: cannot resolve ref"; exit 2; }
TAG="localhost/disposable/${NAME}:val-${SHA}"   # carve-out namespace — never pushed, never a deploy ref

# THROWAWAY SOURCE TREE: export the ref to a temp dir (no working-tree mutation). Discarded on exit;
# the clone's git objects + the engine's layer cache persist, so N churns reuse the warm base.
SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"; podman rmi -f "$TAG" >/dev/null 2>&1 || true' EXIT
git -C "$REPO" archive --format=tar "$REF" | tar -x -C "$SRC" || { echo "FATAL: archive/extract failed"; exit 2; }

echo "== build DISPOSABLE candidate $TAG (host top-level engine; cache retained, no --no-cache) =="
iso=(); [ -n "${BUILD_ISOLATION:-}" ] && iso=(--isolation="$BUILD_ISOLATION")
# shellcheck disable=SC2086
if ! podman build "${iso[@]}" ${BUILD_ARGS:-} -t "$TAG" -f "$SRC/$CFILE" "$SRC"; then
  echo "VERDICT: RED (build failed)"; exit 1
fi

echo "== live-gate the candidate via Gate B (validate-candidate.sh) =="
"$GATE" "$TAG" "${HEALTH:-}"
rc=$?

echo "candidate ${NAME}@${SHA}: gate exit=$rc  (disposable image rmi'd on exit; base layers cached)"
exit "$rc"
