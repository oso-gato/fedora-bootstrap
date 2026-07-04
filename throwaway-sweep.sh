#!/usr/bin/env bash
# throwaway-sweep.sh — reap leaked live-gate throwaway artifacts + bound the persistent build caches.
#
# WHY: build-candidate.sh + validate-candidate.sh each carry an EXIT trap that `rmi`s the disposable
# image, `rm -f`s the vcand container, and `rm -rf`s the throwaway source tree on a CLEAN exit. A
# `kill -9` / OOM-kill / host crash NEVER runs that trap, so a killed gate leaks:
#   - its disposable image   localhost/disposable/<name>:val-<sha>...
#   - its fenced container    vcand-<pid>
#   - its source tree         $FD_THROWAWAY_TMPDIR/{bc,lg}.XXXXXX
# Left uncollected across a churny dev loop these accumulate and can exhaust the VPS disk quota. This
# reaper removes them once AGED past a threshold, and bounds the two PERSISTENT caches (the podman
# LAYER cache + the dnf RPM bind cache) so churn itself can never fill the disk.
#
# SAFETY — never break a RUNNING gate's current artifacts:
#   - AGE-GATED: only artifacts older than FD_SWEEP_AGE_MIN (default 120 min) are eligible. A live
#     build+gate finishes in ~1-3 min, so its current image/container/tree is far younger than the
#     window and is never in range.
#   - IMAGE removal is NON-forced (`podman rmi` WITHOUT -f): an image still referenced by ANY
#     container (a running gate's) refuses deletion and is skipped — a belt over the age braces.
#   - CONTAINER removal only targets `vcand-*` names (the gate's throwaway namespace, NEVER a real
#     workload) older than the threshold.
#   - FLOCK-aware: takes its OWN non-blocking lock so two sweeps never race; it only reaps AGED
#     orphans, so it is safe to run CONCURRENTLY with an active live-gate-watch / build.
#   - THROTTLED: a marker file rate-limits real work to once per FD_SWEEP_INTERVAL_MIN (default 30),
#     so live-gate-watch.sh can call it every poll (15 s) for ~free; FD_SWEEP_FORCE=1 overrides.
#
# INVOCATION:
#   - opportunistic: called at live-gate-watch.sh start (the default wiring) — self-throttled.
#   - manual: `FD_SWEEP_FORCE=1 throwaway-sweep.sh` runs immediately; `FD_SWEEP_DRYRUN=1` reports only.
#
# OVERRIDABLE KNOBS (env) — sane defaults:
#   FD_SWEEP_AGE_MIN       orphan age threshold, minutes               (default 120)
#   FD_SWEEP_INTERVAL_MIN  min minutes between real sweeps (throttle)  (default 30)
#   FD_SWEEP_FORCE         1 = ignore the throttle, sweep now          (default unset)
#   FD_SWEEP_DRYRUN        1 = report only, remove nothing             (default unset)
#   FD_DNF_CACHE              persistent dnf RPM bind-cache dir         (default ~/.cache/fd-dnf)
#   FD_DNF_CACHE_CAP_GB       dnf cache SIZE cap; cleared wholesale over (default 15)
#   FD_STORE_MAX_AGE_H        image-store: reap UNUSED images older than (default 1440 = 60d)
#   FD_THROWAWAY_TMPDIR       throwaway source-tree parent dir          (default ~/.cache/fd-throwaway)
set -uo pipefail

AGE_MIN="${FD_SWEEP_AGE_MIN:-120}"
INTERVAL_MIN="${FD_SWEEP_INTERVAL_MIN:-30}"
DNF_CACHE="${FD_DNF_CACHE:-$HOME/.cache/fd-dnf}"
DNF_CAP_GB="${FD_DNF_CACHE_CAP_GB:-15}"
TT="${FD_THROWAWAY_TMPDIR:-$HOME/.cache/fd-throwaway}"
DRY="${FD_SWEEP_DRYRUN:-}"
FORCE="${FD_SWEEP_FORCE:-}"

STATE="$HOME/.local/state/live-gate"; mkdir -p "$STATE" 2>/dev/null || true
LAST="$STATE/sweep.last"

run(){ if [ -n "$DRY" ]; then echo "[sweep] DRYRUN would: $*"; else "$@"; fi; }

# ---- self-serialize (flock) so two sweeps never race; the watch may call us every poll ----
exec 8>"$STATE/sweep.lock"
flock -n 8 || { echo "[sweep] another sweep holds the lock; skipping"; exit 0; }

# ---- throttle: skip if a real sweep ran within FD_SWEEP_INTERVAL_MIN (unless forced) ----
if [ -z "$FORCE" ] && [ -e "$LAST" ] && find "$LAST" -mmin -"$INTERVAL_MIN" -print -quit 2>/dev/null | grep -q .; then
  exit 0
fi

now="$(date +%s)"
cutoff=$(( now - AGE_MIN * 60 ))
echo "[sweep] start: age>${AGE_MIN}m orphans + cache GC (dnf size cap ${DNF_CAP_GB}G, dangling build layers)${DRY:+ [DRYRUN]}"

# ---- (1) stale vcand-* containers (the EXIT trap missed) ----
# `.Created.Unix` yields epoch seconds directly — the bare `{{.Created}}` renders Go's time.Time
# String() form ("2026-06-27 08:15:09.6 +0000 UTC") which GNU `date -d` cannot parse.
while IFS= read -r c; do
  [ -n "$c" ] || continue
  cepoch="$(podman inspect -f '{{.Created.Unix}}' "$c" 2>/dev/null)" || continue
  case "$cepoch" in ''|*[!0-9]*) continue;; esac
  if [ "$cepoch" -lt "$cutoff" ]; then
    run podman rm -f -t 0 "$c" >/dev/null 2>&1 && echo "[sweep] removed stale gate container $c"
  fi
done < <(podman ps -a --filter 'name=^vcand-' --format '{{.Names}}' 2>/dev/null)

# ---- (2) stale localhost/disposable/* images (non-forced rmi: skips any still in use) ----
while IFS= read -r id; do
  [ -n "$id" ] || continue
  cepoch="$(podman image inspect -f '{{.Created.Unix}}' "$id" 2>/dev/null)" || continue
  case "$cepoch" in ''|*[!0-9]*) continue;; esac
  if [ "$cepoch" -lt "$cutoff" ]; then
    if [ -n "$DRY" ]; then echo "[sweep] DRYRUN would: podman rmi $id"
    elif podman rmi "$id" >/dev/null 2>&1; then echo "[sweep] removed stale disposable image $id"
    fi
  fi
done < <(podman images --filter 'reference=localhost/disposable/*' --format '{{.ID}}' 2>/dev/null | sort -u)

# ---- (3) orphan throwaway source trees (kill -9 left them; a live build's tree is far younger) ----
if [ -d "$TT" ]; then
  while IFS= read -r -d '' d; do
    run rm -rf "$d" && echo "[sweep] removed orphan throwaway tree $d"
  done < <(find "$TT" -mindepth 1 -maxdepth 1 -type d -mmin +"$AGE_MIN" -print0 2>/dev/null)
fi

# ---- (4) BOUND the dnf RPM bind-cache by SIZE: if it exceeds the cap, drop it wholesale (it re-warms
# from the vendor repos on the next build — a data-less throwaway loses nothing). Blunt on purpose: no
# per-RPM age/LRU bookkeeping for a cache whose ENTIRE value is "skip a re-download", recovered for free.
if [ -d "$DNF_CACHE" ]; then
  cur_kb="$(du -sk "$DNF_CACHE" 2>/dev/null | cut -f1)"; cur_kb="${cur_kb:-0}"
  if [ "$cur_kb" -gt $(( DNF_CAP_GB * 1024 * 1024 )) ]; then
    run rm -rf "$DNF_CACHE" && echo "[sweep] dnf cache $(( cur_kb / 1024 ))M > cap ${DNF_CAP_GB}G — cleared (re-warms on next build)"
  fi
fi

# ---- (5) prune DANGLING build-layer images (abandoned candidate-build cruft). Dangling-only is
# podman's default (no -a), so tagged workload images (ghcr.io/oso-gato/*) are never touched.
if [ -n "$DRY" ]; then echo "[sweep] DRYRUN would: podman image prune -f (dangling layers)"
else podman image prune -f >/dev/null 2>&1 || true; fi

# ---- (6) BOUND the image/layer STORE (the one residual with no ceiling before v1.2.53). Per-candidate
# rmi + the dangling prune above handle churn, but SUPERSEDED, non-dangling images have no cap: a
# retired GHCR `:latest` digest no longer backing any container, and OLD base images left after a
# Fedora bump (fedora:44 → 45) or a vendor pin change. Reap images that are BOTH unused (podman
# `prune -a` never removes an image backing a running container, so a live Quadlet workload is always
# spared) AND OLDER than FD_STORE_MAX_AGE_H (default 60 days) — long enough that a still-current base
# costs at most one re-pull per that window, never per churn iteration. Overridable + DRY-aware.
STORE_MAX_AGE_H="${FD_STORE_MAX_AGE_H:-1440}"   # 1440h = 60d
if [ -n "$DRY" ]; then echo "[sweep] DRYRUN would: podman image prune -a -f --filter until=${STORE_MAX_AGE_H}h (cold/superseded images, in-use spared)"
else podman image prune -a -f --filter "until=${STORE_MAX_AGE_H}h" >/dev/null 2>&1 || true; fi

[ -z "$DRY" ] && : > "$LAST"
echo "[sweep] done"
