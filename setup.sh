#!/usr/bin/env bash
# fedora-bootstrap — orchestrator. Run as ROOT on a fresh host (Day 0).
# Version: 1.2.22 (loop-gate-A: proved container-refresh.sh's never-fired ROLLBACK branch GREEN via validation/rollback-spike.sh — a bad :latest that won't go healthy is retagged to the prior digest, restarted, and recovers with a .rolled-back marker. Two fixes it required: an explicit HealthCmd in the spike's throwaway Quadlet (OCI drops a built image's HEALTHCHECK) + a new BUSY_PROBE seam in container-refresh.sh (UNSET in production = the claudebox probe unchanged; a non-claudebox workload sets BUSY_PROBE=/bin/true, the documented empty-probe path). No production behavior change. Prior: v1.2.21 policy-fix: setup-user.sh wrote the image-trust policy.json "containers-storage" transport as a bare ARRAY instead of a scope->requirements OBJECT; containers-image rejected the WHOLE policy ("JSON object expected, got 91") so EVERY ghcr.io/oso-gato pull failed and no workload could start (fedora-dev stuck restart-looping). Fixed both writers (create-heredoc + merge), the idempotent merge now REPAIRS an already-broken host in place, and a fail-closed structural check rejects any non-object transport. Prior: v1.2.20 auto-mode: the host claudebox now DEFAULTS to the 'auto' permission mode — policy/managed-settings.json drops "disableAutoMode":"disable" and adds "defaultMode":"auto", so in-box sessions start without routine permission prompts (a background classifier still vets each action). The MERGE GATE IS UNCHANGED: the managed gate-push.sh 'ask' hook, the git push / gh pr merge deny rules, and disableBypassPermissionsMode all remain, so nothing reaches main without explicit approval. Prior: v1.2.19 policy: the host image-trust policy.json now also permits the class-(a) Fedora base registry.fedoraproject.org/fedora plus the containers-storage transport (local save/load), so the validation/ host-validation spikes+gates can pull stock Fedora fixtures into a throwaway tar cache. Production run-set UNCHANGED — workload Quadlets reference only ghcr.io/oso-gato/*, default stays reject, the docker "" fallback stays reject; this widens only what may be PULLED for disposable host-validation, not what RUNS. setup-user.sh writes it fresh (heredoc) and idempotently/additively merges the two entries into an existing policy.json without clobbering operator edits. Same insecureAcceptAnything posture as the oso-gato stanza; both upgradeable to sigstoreSigned in lockstep later. Prior: v1.2.18 tmux SINGLE-GROUP multi-client geometry-race fix; v1.2.17 FLEET.md swarm map; v1.2.16 Day-0 wizard (day0.sh asks for the TS auth key); v1.2.15 spin-up path explicit; v1.2.14 day-0 TS_AUTHKEY prompt; v1.2.13 docs cleanup; v1.2.12 FLEET governance (3-box model, host PR-only, fedora-dev sole merge box); v1.2.11 BUILT promotion gate; v1.2.10 HEADLESS prerequisite; v1.2.9 Principle 3 MINIMAL; v1.2.8 Principle 2(c); v1.2.7 PR-first maintainership; v1.2.5 verify.sh fail2ban euid-gate fix; v1.2.4 genesis/mother-platform role + fedora-dev maintainership.)
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
    # Hand off to the operating user for the rootless layer. The root phase already
    # brought up its user bus, so `su -` finds it. `< /dev/null` keeps a queued paste line
    # (e.g. a following `passwd`) from being swallowed by a child that reads stdin.
    su - "$U" -c "GH_KEYS_USER='${GH_KEYS_USER:-oso-gato}' '$HERE/setup-user.sh'" < /dev/null
else
    # Invoked as the unprivileged user: run ONLY the rootless layer. The system layer must
    # already have been provisioned as root (run setup.sh as root on a fresh host).
    echo ">> Running the rootless (user) layer only. The SYSTEM layer must already be in place;"
    echo ">> on a fresh host run setup.sh as root instead."
    exec "$HERE/setup-user.sh"
fi
