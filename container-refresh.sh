#!/usr/bin/env bash
# fedora-bootstrap — refresh one workload container.
#
# Driven by workload-refresh@<name>.service. The workload container itself is
# a Quadlet (<name>.container in this repo's clone), so its systemd unit is
# <name>.service. This script's job:
#
#   1. Self-serialize (per-container flock; prevents main + retry colliding).
#   2. Busy probe (claudebox-busy-probe.sh): idle = exit 0, busy = exit 1,
#      probe-error = exit 2+. Don't conflate them.
#   3. Pull the latest image. If pull fails, mark pending and exit 1 — the
#      hourly retry timer (ConditionPathExists-gated on the pending marker)
#      will retry.
#   4. Compare digests. If unchanged, exit clean.
#   5. Restart via the Quadlet-generated unit. Quadlet handles stop/pull/start.
#      Notify=healthy means systemctl waits for the healthcheck to pass.
#   6. On restart failure (new image won't go healthy), roll back: retag
#      :latest to the captured prior digest, restart again. The prior runs
#      again until the next refresh.
#
# Exit codes:
#   0   refreshed (or already current)
#   1   pull failed (pending marker written; retry will try again)
#   2   busy-probe broken (pending marker written; investigate)
#   10  deferred (busy; pending marker written; retry will try again)
#
# FORCE_REBUILD (R17 rebuild-devbox, via the workload-rebuild@ unit): a PURPOSEFUL kill+recreate. It
# reuses THIS script's health-gate + digest auto-rollback UNCHANGED, but (a) SKIPS the busy-probe — a
# purposeful rebuild deliberately overrides an active session (the whole point of R17) — and (b) SKIPS
# the digest-unchanged short-circuit — a lifecycle rebuild must recreate even on the same image. The
# `systemctl restart` below, run from the host, tears down the whole container (reaping every process
# in its PID namespace) and Notify=healthy gates the fresh one; on health failure the SAME rollback
# fires. It is UNSET in every other path, so zero behaviour change there.
set -u

name="${1:?usage: container-refresh.sh <name>}"
state="$HOME/.local/state/container-refresh"
mkdir -p "$state"
pending="$state/$name.pending"
image="ghcr.io/oso-gato/${name}:latest"

# (1) Self-serialize per container.
exec 9<>"$state/$name.lock"
flock -n 9 || {
    echo "[$name] another refresh already in progress; exiting clean"
    exit 0
}

# (2) Busy probe — distinguishes idle vs busy vs broken. BUSY_PROBE overrides the default
#     claudebox probe (UNSET in production → claudebox-busy-probe.sh); a non-claudebox workload
#     supplies an empty/appropriate probe (e.g. BUSY_PROBE=/bin/true), per CLAUDE.md.
#     FORCE_REBUILD (R17) SKIPS the busy-probe: a purposeful kill+rebuild overrides an active session.
if [ -n "${FORCE_REBUILD:-}" ]; then
    echo "[$name] FORCE_REBUILD: skipping busy-probe — a purposeful R17 rebuild overrides an active session."
else
    "${BUSY_PROBE:-$HOME/.local/bin/claudebox-busy-probe.sh}" "$name"
    rc=$?
    case $rc in
        0)  : ;;  # idle, proceed
        1)
            echo "[$name] busy (claude session or box rebuild active); deferring"
            date -Iseconds >> "$pending"
            # Cap defer-count visibility: > 24 means stuck for > 1 day of hourly retries.
            c=$(wc -l <"$pending")
            if [ "$c" -gt 24 ]; then
                echo "[$name] WARNING: deferred $c times — investigate why busy never clears" >&2
            fi
            exit 10
            ;;
        *)
            echo "[$name] busy-probe FAILED with exit $rc (broken probe, container down, etc.)" >&2
            date -Iseconds >> "$pending"
            exit 2
            ;;
    esac
fi

# (3) Capture prior image digest BEFORE pulling, for rollback if needed.
prior_id=$(podman container inspect "$name" -f '{{.Image}}' 2>/dev/null || echo "")

# (4) Pull. Pull failure -> defer (the retry timer handles it).
# SKIP_PULL is a TEST-ONLY seam (validation/rollback-spike.sh): UNSET in production, so zero
# behaviour change there. When set, the registry pull is skipped so the rollback branch can be
# exercised against a locally-staged image with nothing pushed to GHCR. The pull is orthogonal
# to the rollback logic under test.
if [ -z "${SKIP_PULL:-}" ]; then
    echo "[$name] pulling $image…"
    if ! podman pull "$image" >/dev/null; then
        echo "[$name] pull FAILED — leaving running container alone" >&2
        date -Iseconds >> "$pending"
        exit 1
    fi
fi

# (5) Compare digests.
new_id=$(podman image inspect "$image" -f '{{.Id}}' 2>/dev/null || echo "")
if [ -z "$new_id" ]; then
    echo "[$name] could not inspect pulled image $image" >&2
    date -Iseconds >> "$pending"
    exit 1
fi
if [ "$prior_id" = "$new_id" ] && [ -z "${FORCE_REBUILD:-}" ]; then
    echo "[$name] already at $new_id — no change."
    rm -f "$pending"
    exit 0
fi
if [ -n "${FORCE_REBUILD:-}" ] && [ "$prior_id" = "$new_id" ]; then
    echo "[$name] FORCE_REBUILD: digest unchanged ($new_id) — forcing a clean recreate anyway (R17 lifecycle)."
fi

# (6) Restart via Quadlet-generated unit. Notify=healthy gates "active"
# on healthcheck pass; restart returns non-zero if it never reaches healthy.
echo "[$name] image changed ($prior_id → $new_id); restarting $name.service via Quadlet…"
if systemctl --user restart "$name.service"; then
    echo "[$name] refreshed and healthy."
    rm -f "$pending" "$state/$name.rolled-back"
    exit 0
fi

# Health-gate failed → rollback to the prior image.
echo "[$name] new image did NOT reach healthy → rolling back to $prior_id" >&2
if [ -n "$prior_id" ]; then
    # Retag :latest locally to the prior digest. The workload Quadlet sets
    # Pull=missing (NOT newer), so this restart uses our retagged LOCAL image and
    # does not re-pull — the rollback actually reverts. (With Pull=newer this
    # restart re-pulled the bad registry :latest and silently defeated the rollback.)
    if podman tag "$prior_id" "$image" && systemctl --user restart "$name.service"; then
        echo "[$name] rolled back; prior image is healthy again." >&2
        # Record the rollback WITHOUT re-arming the hourly retry: the retry timer
        # is ConditionPathExists-gated on $pending, and the registry :latest is
        # still the bad image — an hourly retry would re-pull it and re-flap the
        # rollback. Clear $pending; drop a separate <name>.rolled-back marker for
        # operator visibility. The next monthly cycle (or the operator) re-attempts,
        # by when upstream :latest may be fixed.
        rm -f "$pending"
        date -Iseconds >> "$state/$name.rolled-back"
        exit 1
    fi
    echo "[$name] ROLLBACK FAILED — container down; investigate manually" >&2
fi
date -Iseconds >> "$pending"
exit 1
