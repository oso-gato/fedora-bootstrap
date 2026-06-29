# Upgrade history (archived from README.md)

Per-version upgrade subsections for **v1.1.1 through v1.2.42**, relocated from `README.md` to keep the README scannable (v1.1.1–v1.1.14 in v1.1.16; v1.1.15–v1.2.42 in v1.2.45). The current release's upgrade steps stay in [README.md](README.md) under "Upgrading an existing host to a new release". These blocks are an immutable historical record (see [CLAUDE.md](CLAUDE.md) RELEASE-DOC CONVENTION). Per the v1.0.0 baseline guarantee, a fresh host can jump straight to the latest release via the newest subsection in README; the blocks below are for stepwise / forensic reference.

#### Upgrading to v1.1.1 (from v1.0.0)

Adds the workload-container refresh harness, Quadlet-based deployment for `fedora-dev`, image-signature scaffolding, the restructured agent policy. The pre-v1.1.1 fedora-dev was started via raw `podman run` from `run.sh`; v1.1.1 replaces that with a Quadlet-generated `fedora-dev.service`. Named volumes (`fedora-dev-home`, `fedora-dev-state`) persist by name, so all in-volume state — Claude credentials, gh auth, in-flight projects, nested podman storage — carries over automatically.

**Both v1.0.0 and v1.1.0 starting points are supported by the same upgrade block.** `setup.sh` is fully idempotent:

- **From v1.0.0** → installs the v1.1.0 deltas (claudebox 3-way rebuild mechanism + host dnf-automatic + Anthropic `latest`-channel switch) AND the v1.1.1 deltas (workload-refresh harness + signature scaffolding + restructured policy) in a single setup.sh re-run.
- **From v1.1.0** → re-stamps existing claudebox-rebuild state (idempotent no-op) and installs only the v1.1.1 delta.

The version-specific operator steps below (env file population, container switch) are identical for both starting points.

**As root on the VPS:**

```sh
# 1. Standard upgrade flow — picks up v1.1.1 code + new user 4/5 phase
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null

# 2. Populate the new env-file scaffold for fedora-dev's runtime secrets.
nano /home/core/.config/container-refresh/fedora-dev.env

# 3. Stop the pre-Quadlet fedora-dev container and start the Quadlet'd one.
su - core -c '
    podman stop fedora-dev 2>/dev/null || true
    podman rm   fedora-dev 2>/dev/null || true
    systemctl --user daemon-reload
    systemctl --user enable --now fedora-dev.service
'

# 4. Verify
su - core -c '
    systemctl --user status fedora-dev.service --no-pager | head -20
    systemctl --user list-timers "workload-refresh@*" --no-pager
    podman ps --filter name=fedora-dev
'
```

Expected after step 4: `fedora-dev.service` shows `active (running)`, healthcheck transitions to healthy within ~30s, two `workload-refresh@fedora-dev` timers visible. `podman ps` shows fedora-dev as `Up` and `(healthy)`.

If anything fails, the old container can be brought back manually:

```sh
su - core -c '
    systemctl --user stop fedora-dev.service 2>/dev/null || true
    cd ~/fedora-dev && CORE_PASSWORD=... ./run.sh
'
```

#### Upgrading to v1.1.2 through v1.1.8 (from v1.1.1)

Documentation + agent-policy patches: README restructured into the operator-focused four-section shape, release-doc convention written down, binding agent tables (Build Principles, Packages, REPO FILE PURPOSES) consolidated in [CLAUDE.md](CLAUDE.md), v1.0.0-baseline guarantee added to release-doc convention (v1.1.7), HOW DO I operational recipes added to the host-claudebox policy file (v1.1.8). No code changes; no version-specific operator steps. The standard upgrade flow alone is sufficient (and the next claudebox-rebuild on the host picks up the new in-box policy):

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
```

(If you're jumping from a pre-v1.1.1 version, follow the v1.1.1 block above — it folds these doc-only patches in along the way; this subsection is just a record-of-no-action for hosts already at v1.1.1.)

#### Upgrading to v1.1.9 (from v1.0.0)

> **⚠️ Corrected in v1.1.16:** the manual rollback recipe (b) below references `~/.local/state/container-refresh/<name>.prev-digest`, a file the refresh harness **never writes** (the prior image digest is held only in-memory during a refresh). Use the working procedure in README's "Upgrading to v1.1.16" instead — rely on the automatic health-failure rollback, or pin a known-good digest by hand.

Two code changes, applied in lockstep with [`fedora-dev` v1.1.9](https://github.com/oso-gato/fedora-dev) for fleet-wide consistency:

- **Host gains `fail2ban`** with an `sshd` jail (`backend = auto` so it reads from `journald`; tailnet CGNAT `100.64.0.0/10` is `ignoreip`'d). The host's public sshd on :22 now has the same brute-force posture as fedora-dev's new public sshd on host :4444.
- **Bootstrap drops the env-file scaffold** for `fedora-dev`. Upstream `fedora-dev` v1.1.9 eliminates `CORE_PASSWORD` entirely (sshd is key-only; authorized_keys synced from `github.com/<user>.keys` at every container start) and adds public-IP paths: ssh on host `:4444` → container `:22`, mosh on UDP `61001-62000` (non-default range, chosen to NOT collide with the host's own public mosh-server which uses 60000-61000 on the same kernel UDP namespace). The Quadlet drops `EnvironmentFile=`; `~/.config/container-refresh/fedora-dev.env` becomes unused.

**Assumptions about the starting state:**
- Hosts at **v1.0.0 / v1.1.0** are running `fedora-dev` from raw `podman run` (pre-Quadlet). The block below stops it and starts the v1.1.9 Quadlet, exactly as v1.1.1 did. No CORE_PASSWORD is needed at any step.
- Hosts at **v1.1.1 through v1.1.8** already have `fedora-dev.service` running with the old env-file Quadlet. The block detects that path and does `daemon-reload` + `restart` instead — `Pull=newer` fetches the v1.1.9 image and the new Quadlet (no `EnvironmentFile=`) takes effect on restart.

`fedora-dev:latest` on GHCR must already point to the v1.1.9 manifest before you run this block (CI on `oso-gato/fedora-dev` builds + cosigns on push to main; check with `podman manifest inspect ghcr.io/oso-gato/fedora-dev:latest | jq .config.digest` against the v1.1.9 tag commit's CI run).

**As root on the VPS:**

```sh
# 1. Standard upgrade flow — installs all deltas (workload-refresh harness if
#    coming from pre-v1.1.1, fail2ban+jail in v1.1.9, env-scaffold drop in v1.1.9).
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null

# 2. Re-apply the fedora-dev workload — pulls v1.1.9 image, applies new Quadlet.
#    Branches by starting state: if the .service exists, daemon-reload + restart;
#    otherwise stop-and-recreate the pre-Quadlet container (v1.0.0/v1.1.0 path).
su - core -c '
    if systemctl --user is-enabled fedora-dev.service >/dev/null 2>&1; then
        # v1.1.1+ path: in-place Quadlet refresh.
        systemctl --user daemon-reload
        systemctl --user restart fedora-dev.service
    else
        # v1.0.0/v1.1.0 path: retire pre-Quadlet container, enable Quadlet'\''d one.
        podman stop fedora-dev 2>/dev/null || true
        podman rm   fedora-dev 2>/dev/null || true
        systemctl --user daemon-reload
        systemctl --user enable --now fedora-dev.service
    fi
'

# 3. (Optional cleanup) Remove the now-unused env-file scaffold from prior versions.
#    Harmless to leave in place — the v1.1.9 Quadlet has no EnvironmentFile= so the
#    file is no longer read by anything.
rm -f /home/core/.config/container-refresh/fedora-dev.env

# 4. Verify host fail2ban + fedora-dev health.
fail2ban-client status sshd | head -10
su - core -c '
    systemctl --user status fedora-dev.service --no-pager | head -20
    podman ps --filter name=fedora-dev
'
```

Expected after step 4: `fail2ban-client status sshd` shows `Currently banned: 0` (or some number) and `File list: /var/log/secure` (or the systemd-journal source) — the jail is active. `fedora-dev.service` shows `active (running)`, healthcheck `(healthy)` within ~30s on the new image.

Functional probe each access path:

```sh
# From a client on the public internet (NOT the tailnet) — confirms public surface
# survived the upgrade and uses the NEW ports:
ssh -p 4444 core@<public-ip>                                  # key-only; one of github.com/<user>.keys
mosh -p 61001:62000 --ssh='ssh -p 4444' core@<public-ip>     # public mosh range

# From a tailnet device — confirms keyless Tailscale SSH still works:
ssh core@<vps>.<tailnet>.ts.net
```

**Rollback** if v1.1.9 misbehaves (e.g., fedora-dev fails to come up healthy on the new image):

```sh
# (a) Revert /opt/fedora-bootstrap to v1.1.8 — drops fail2ban config + restores
#     the env-file scaffold path.
cd /opt/fedora-bootstrap
git checkout v1.1.8
./setup.sh < /dev/null

# (b) Roll fedora-dev back to the prior image digest. workload-refresh.service
#     records the prior digest in /home/core/.local/state/container-refresh/
#     <name>.prev-digest; the auto-rollback path on health-failure already uses
#     it, but you can also pin manually:
su - core -c '
    prev=$(cat ~/.local/state/container-refresh/fedora-dev.prev-digest 2>/dev/null)
    [ -n "$prev" ] && podman tag "$prev" ghcr.io/oso-gato/fedora-dev:latest
    systemctl --user daemon-reload
    systemctl --user restart fedora-dev.service
'
# (If no prev-digest is recorded — first deploy at v1.1.9 — you can pull a
# specific older tag with `podman pull ghcr.io/oso-gato/fedora-dev:<sha>`
# and `podman tag` it as :latest.)
```

#### Upgrading to v1.1.10 (from v1.0.0)

One code change, in `setup-host.sh`'s Tailscale phase (host 6/7) — no `fedora-dev` / workload action and no operator env steps. The standard upgrade flow carries it:

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
```

**What changed.** `--advertise-exit-node` (and `--accept-routes`) now ride the authenticated `tailscale up` join, with IP forwarding enabled *before* the join, instead of a separate `tailscale set` afterward. The old order let a slow browser login outrun `--timeout=5m`: `up` timed out (swallowed by `|| true`), the racing `set` then ran against a not-yet-`Running` node (swallowed by `|| echo`), and the exit node was never advertised to the control plane — greyed-out in the admin console — yet the bootstrap still printed "all layers PASS". The fix carries the advertise on the join, stops swallowing failure (a stuck login now aborts loudly under `set -e`), and verifies the node reached `Running` with the route advertised before declaring success.

**How the re-run behaves**, depending on the host's current Tailscale state:

- **Logged out** (`tailscale status` → `NeedsLogin` — the symptom of the old bug): the re-run prints a fresh `https://login.tailscale.com/...` link. Open it and approve the node; the advertise lands as part of that login.
- **Already up** (`Running`): the idempotent `tailscale set` re-asserts the advertise against the live node and it propagates immediately — no re-login.

Then approve the exit node once (admin console → Machines → *this VPS* → Edit route settings → ✓ Use as exit node), or skip that click fleet-wide with `autoApprovers` — see [Tailscale routing](#tailscale-routing-lan-access--exit-node).

**Verify:**

```sh
tailscale status --json | grep -E 'BackendState|"Online"'   # want: "Running" / true
tailscale debug prefs   | grep -A2 AdvertiseRoutes          # want: 0.0.0.0/0 and ::/0
```

Then, on each client that should egress through the VPS: `tailscale set --exit-node=<vps> --exit-node-allow-lan-access`.

#### Upgrading to v1.1.11 (from v1.0.0)

Fixes a fleet-wide image-pull breakage, plus two host-claudebox policy corrections:

- **`setup-user.sh` no longer writes an invalid `policy.json`.** The signature-policy template carried JSON "comment" keys (`"//"`, `"//upgrade"`). podman's `containers/image` policy parser is strict and rejects unknown keys, so **every** image pull failed with `invalid policy in ".../policy.json": Unknown key "//"` (exit 125) — breaking `fedora-dev` startup and every monthly `workload-refresh` pull. The template now emits clean JSON; the sigstore-upgrade guidance moved to shell comments. Semantics unchanged (default reject; `ghcr.io/oso-gato` permissive).
- **`policy/CLAUDE.md`** (the host-claudebox law, re-stamped into the box on every `setup.sh` run): the stale `EnvironmentFile=`/env-scaffold fact (removed in v1.1.9) is corrected, and the agent's PR-authority is sharpened to by-repo — the agent opens PRs only against `fedora-bootstrap`; for image repos (code *and* docs) it surfaces a diff for the operator.

**This needs a one-time operator step on existing hosts.** `setup-user.sh` writes `policy.json` only `if [ ! -e ]`, so the standard `setup.sh` re-run does **not** repair an already-broken file — existing hosts must rewrite it once (step 2 below; idempotent and harmless if yours was already clean, e.g. a fresh v1.0.0→v1.1.11 install where step 1 wrote the corrected template). Until it's fixed, all GHCR pulls on the host fail.

**As root on the VPS:**

```sh
# 1. Standard upgrade flow — installs the corrected setup-user.sh template and
#    re-stamps policy/CLAUDE.md into the box. Does NOT touch an existing policy.json.
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null

# 2. Repair the existing policy.json — drop the "//" comment keys podman rejects.
#    Backs up first; validates the rewritten file parses. Run as core (owns the file).
su - core -c '
    f=~/.config/containers/policy.json
    [ -f "$f" ] && cp "$f" "$f.bak"
    cat > "$f" <<JSON
{
    "default": [{ "type": "reject" }],
    "transports": {
        "docker": {
            "ghcr.io/oso-gato": [{ "type": "insecureAcceptAnything" }],
            "": [{ "type": "reject" }]
        }
    }
}
JSON
    python3 -m json.tool "$f" >/dev/null && echo "policy.json OK"
'

# 3. Bring fedora-dev up — the pull now succeeds. (reset-failed clears any
#    crash-loop left from the broken state before starting.)
su - core -c '
    systemctl --user reset-failed fedora-dev.service 2>/dev/null || true
    systemctl --user start fedora-dev.service
    podman ps --filter name=fedora-dev --format "table {{.Names}}\t{{.Status}}"
'
```

Expected after step 3: `podman pull` of `ghcr.io/oso-gato/fedora-dev:latest` succeeds (no `Unknown key` error) and `fedora-dev` shows `Up … (healthy)` within ~30s.

**Rollback** (the `policy.json` fix is data, not code — this reverts only it):

```sh
su - core -c 'f=~/.config/containers/policy.json; [ -f "$f.bak" ] && mv "$f.bak" "$f"'
```

#### Upgrading to v1.1.12 (from v1.0.0)

Documentation + comment-only on the host side — no functional code change to the bootstrap, no version-specific operator steps. Clarifies the update-cadence docs (which mechanism quitting a session does and doesn't accelerate — see "What auto-updates, and when") and corrects the `container-refresh.sh` rollback comment to match the workload Quadlet's `Pull=missing`. The standard upgrade flow re-stamps `policy/CLAUDE.md` into the box:

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
```

The companion `oso-gato/fedora-dev` fixes (`Pull=missing` so auto-rollback reverts, a readiness healthcheck, and the honest SELinux docs) ride in via the monthly image refresh, or apply one now with `su - core -c 'systemctl --user start workload-refresh@fedora-dev.service'` once they're on `:latest`.

#### Upgrading to v1.1.13 (from v1.0.0)

A small `container-refresh.sh` fix: after a successful auto-rollback the harness now clears `.pending` and writes a separate `<name>.rolled-back` marker instead of keeping `.pending`. The hourly retry timer is gated on `.pending`, and after a rollback the registry `:latest` is still the bad image — the old behavior re-pulled it every hour and re-flapped the rollback. No operator steps; the standard upgrade flow re-installs `container-refresh.sh` and re-stamps `policy/CLAUDE.md`:

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
```

After a rollback you'll now see `~/.local/state/container-refresh/<name>.rolled-back` and no `<name>.pending` — the bad `:latest` is not retried until the next monthly cycle or a manual `systemctl --user start workload-refresh@<name>.service`.

#### Upgrading to v1.1.14 (from v1.0.0)

> **⚠️ Superseded in v1.2.0:** the manual flip in step 4 below (hand-edit `SELINUX=enforcing` + reboot after a soak) is replaced by an **automated, self-disarming convergence** — `setup.sh` now arms a chain that goes permissive → relabel → soak → enforcing → post-enforce health check with **auto-revert to permissive** on failure. Use the **"Upgrading to v1.2.0"** subsection in [README.md](README.md) instead. The v1.1.14 steps below remain valid as the permissive-first first leg (and `SELINUX_TARGET=permissive` reproduces exactly this manual-flip posture), but do not hand-flip enforcing if you are on v1.2.0 — let the chain do it.

Turns SELinux back on (Fedora's default; this VPS's provider image shipped it disabled). `setup-host.sh` moves a disabled host to **permissive** and schedules a one-time relabel — it never auto-reboots, never downgrades an already-enabled host, and never sets `enforcing` (you do that after soaking). The `fedora-dev` container stays SELinux-exempt (`label=disable`). **This release requires a reboot** — the relabel runs on next boot.

**Before you start:** take a Hostinger **snapshot** (hPanel → VPS → Snapshots) — hypervisor-level rollback if anything misbehaves. SELinux is enablable here because the VPS is KVM (own kernel) with no in-guest provider agent to conflict with.

**As root on the VPS:**

```sh
# 1. Standard upgrade flow — installs the setup-host.sh SELinux step + re-stamps policy.
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
# setup.sh sets SELINUX=permissive + touches /.autorelabel, then prints
# "ACTION REQUIRED: REBOOT". It does NOT reboot for you.

# 2. Reboot to apply — a full filesystem relabel runs on next boot (can take minutes).
reboot

# 3. After it returns, confirm permissive and soak:
getenforce                         # expect: Permissive
sudo ausearch -m avc -ts recent    # review denials (empty = clean); soak a few days

# 4. Once clean, flip to enforcing (no relabel needed this time):
sudo sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
sudo reboot                        # after this: getenforce -> Enforcing
```

Expected after step 3: `getenforce` = `Permissive`, all services healthy, `verify.sh` PASSes (fedora-dev is unaffected — it's `label=disable`d). If `ausearch` shows denials tied to a service, fix labels (`restorecon -Rv <path>`) before enforcing.

**Rollback** if SELinux causes trouble: restore the Hostinger snapshot, or revert to disabled —
```sh
sudo sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config && sudo reboot
```


---

<!-- v1.1.15–v1.2.42 relocated from README.md in v1.2.45 -->

#### Upgrading to v1.1.15 (from v1.0.0)

Dependency-hygiene fix (Build Principle 4 — leaf over metapackage). Hosts provisioned since v1.1.9 installed the `fail2ban` **metapackage**, whose hard dependencies silently pulled in `firewalld` (via `fail2ban-firewalld`) plus an MTA (`esmtp` via `fail2ban-sendmail`) — none of which the host uses. That latent `firewalld`, enabled-on-install, started on the first reboot after it landed (the v1.1.14 relabel reboot) with a stock zone that blocks mosh's UDP — the classic "connected to mosh-server … waiting for UDP traffic". This release installs the leaf `fail2ban-server`, switches the ban backend to the host-native `nftables[type=multiport]` (the box has no `iptables`), and has `setup.sh` **converge the footprint** — marking the daemon user-owned and removing the metapackage + its `firewalld`/`esmtp` baggage. On a fresh v1.0.0 host (which never had the metapackage) that convergence is a clean no-op. No reboot required. (Rides on top of v1.1.14; if you're not yet on v1.1.14, its SELinux reboot step applies too.)

**As root on the VPS:**

```sh
# 1. Standard upgrade flow. setup.sh installs fail2ban-server (leaf) + the nftables[type=multiport]
#    banaction AND idempotently removes the legacy fail2ban-metapackage baggage (firewalld/esmtp) if
#    present — no manual cleanup. It marks fail2ban-server + fail2ban-selinux user-owned BEFORE the
#    removal so the cleanup can't cascade the daemon out. A fresh host no-ops the removal.
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null

# 2. Verify.
systemctl is-active fail2ban.service         # expect: active
sudo fail2ban-client status sshd             # expect: sshd jail up (banning via nftables)
rpm -q firewalld >/dev/null 2>&1 && echo "WARN: firewalld still present" || echo "firewalld removed ✓"
```

Expected after step 2: `fail2ban` is `active`, its `sshd` jail is listed, `firewalld` is gone, and mosh reconnects (UDP 60000–61000 no longer filtered). `verify.sh` PASSes — including its new `firewalld absent (leaf footprint)` check and the backend-agnostic fail2ban check (`fail2ban.service` + `fail2ban-client status sshd`, both shipped by `fail2ban-server`).

**Rollback** (no data migration — fully reconstructable, works after a partial run): `sudo dnf install -y fail2ban` reinstates the prior package set (the metapackage pulls `fail2ban-server` + `firewalld` + `esmtp` back); for just the jail daemon, `sudo dnf install -y fail2ban-server && sudo systemctl enable --now fail2ban`. Note a later `setup.sh` re-run re-converges to the leaf footprint by design, so a durable revert means pinning an older checkout.

#### Upgrading to v1.1.16 (from v1.0.0)

Documentation-only — **no host action required** (no code, package, or service change). It (1) relocates the v1.1.1–v1.1.14 upgrade history to [UPGRADING.md](UPGRADING.md) (the upgrade log had grown to ~55% of this README), and (2) corrects the v1.1.9 manual-rollback recipe, which cited a `<name>.prev-digest` file the refresh harness never writes.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main      # docs only — nothing to apply; no service is touched
```

**Correction to v1.1.9's manual rollback (b):** the refresh harness does **not** persist `~/.local/state/container-refresh/<name>.prev-digest` (the prior image digest is held only in-memory during a refresh; the only markers written are `<name>.pending` and `<name>.rolled-back`). To roll a workload back to a prior image, rely on the automatic health-failure rollback (`systemctl --user start workload-refresh@<name>.service`), or pin a known-good digest by hand:
```sh
su - core -c '
    podman pull ghcr.io/oso-gato/<name>@sha256:<known-good-digest>
    podman tag  ghcr.io/oso-gato/<name>@sha256:<known-good-digest> ghcr.io/oso-gato/<name>:latest
    systemctl --user restart <name>.service
'
```

**Rollback** (docs-only — nothing to revert on the host): `git checkout` the prior commit to restore the old README layout; no host state is affected.

#### Upgrading to v1.1.17 (from v1.0.0)

Documentation-only — **no host action required**. Refreshes an agent-facing `CLAUDE.md` cross-repo note (the fail2ban-server PACKAGES row) now that `fedora-dev` shipped its nft-only banaction fix to main — both repos are now nft-native. `git pull` to get the updated docs; nothing to apply. Rollback: none needed (no host state touched).

#### Upgrading to v1.2.0 (from v1.0.0)

SELinux now reaches **enforcing automatically**, hands-off, in one operator action. This **supersedes the v1.1.14 manual flip** (see the dated note beside v1.1.14 in [UPGRADING.md](UPGRADING.md)). `setup.sh` ensures `permissive` + a relabel and **arms a one-time convergence chain** of self-disarming system units; you reboot **once**, and the host then drives itself: relabel in permissive → auto-reboot → a ~15-minute, fail-closed soak (system healthy + critical services up + zero AVC denials) → flip to `enforcing` → auto-reboot → a post-enforce health check that **auto-reverts to permissive** (instant `setenforce 0` + config + reboot, no loop) if the enforcing boot is unhealthy. It is safe by construction — permissive-first means enforcing never runs against an unlabeled filesystem — and self-disarms once a healthy enforcing boot is confirmed. A hands-off soak cannot exercise interactive paths (Cockpit WebSocket, a box-rebuild) or denials hidden by `dontaudit`; the post-enforce auto-revert is the net for those. Opt out per-host with `SELINUX_TARGET=permissive`. The `fedora-dev` container stays SELinux-exempt (`label=disable`); host enforcing does not touch it.

**Before you start:** take a Hostinger **snapshot** (hPanel → VPS → Snapshots) — the one-button, SSH-independent recovery if anything misbehaves.

**As root on the VPS:**

```sh
# 1. Standard upgrade flow — installs the SELinux auto-enforce driver + four self-disarming units,
#    ensures SELINUX=permissive, schedules the relabel, and ARMS the convergence chain. setup.sh
#    prints "ACTION REQUIRED: REBOOT". It does NOT reboot for you (the first reboot is yours).
#    Opt out of enforcing entirely with:  SELINUX_TARGET=permissive ./setup.sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null

# 2. Reboot ONCE to launch the chain. Everything after is automatic: on the happy path two more
#    reboots, ~20-25 min total on this host (relabel(permissive) -> soak+auto-confirm -> enforcing
#    -> post-enforce health check). An UNHEALTHY enforcing boot auto-reverts to permissive with one
#    additional reboot (a .rolled-back marker is written; no loop).
reboot

# 3. After it settles (give it ~25 min), confirm convergence:
getenforce                                    # expect: Enforcing
ls -1 /var/lib/fedora-bootstrap/              # expect: selinux-chain.enforced ; NO .state/.rolled-back/.aborted
systemctl is-enabled selinux-enforce.timer    # expect: disabled (chain self-disarmed)
sudo ausearch -m avc -ts boot                 # expect: <no matches> (no denials this boot)
```

Expected after step 3: `getenforce` = `Enforcing`, `selinux-chain.enforced` present (the chain disarmed itself), no `.rolled-back`/`.aborted` marker, and `verify.sh` PASSes (including its new `SELinux config enabled` check; `fedora-dev` is unaffected — `label=disable`). If you instead find **`selinux-chain.rolled-back`**, the enforcing boot was unhealthy and the host **auto-reverted to permissive** — review `sudo ausearch -m avc -ts boot` (and `sudo semodule -DB` to reveal `dontaudit`-hidden denials), fix labels (`restorecon -Rv <path>`) or policy, then remove the marker and re-run `setup.sh` to retry. A `selinux-chain.aborted` marker means the permissive soak gate never passed (host stayed permissive) — same investigate-and-retry.

**Rollback** (works after a partial run): the chain self-heals an unhealthy enforcing boot back to permissive automatically. To revert manually: `sudo sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config && sudo reboot`, or restore the Hostinger snapshot. In the rare case a boot wedges before multi-user (a relabeled fs makes this unlikely), recover out-of-band via the Hostinger hPanel **GRUB console**: at the menu press `e`, append `enforcing=0` to the kernel line, boot (comes up permissive), then fix and reboot — or restore-to-base.

#### Upgrading to v1.2.1 (from v1.0.0)

Policy/doc only — **no host behavior change**. The in-box agent is now the `fedora-bootstrap` maintainer: it commits, pushes to `main`, and tags releases directly. The host-apply gate is unchanged — the live host still changes only when you re-run `setup.sh` as root (the agent has no host root). This release just re-stamps the updated agent law (`policy/CLAUDE.md` → `/etc/claude-code/CLAUDE.md` inside claudebox).

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps the updated agent law into the box; no host change
```

**Rollback** (docs/policy only — no host state to revert): `git checkout` the prior commit and re-run `setup.sh` to re-stamp the previous agent law.

#### Upgrading to v1.2.2 (from v1.0.0)

Docs/policy only — **no host behavior change**. Brings the agent recipes in `policy/CLAUDE.md` into line with the v1.2.0/v1.2.1 reality: the "Add a new workload container" recipe and FLEET-CONTRACT gate now use the **maintainership push-to-`main` flow** (not `gh pr create → human merges`), drop the dead **`*.env` scaffold** step (runtime secrets use `podman secret` + a Quadlet `Secret=` since v1.1.9), and add a **SELinux-posture check** — any *new* workload added to the fleet must be enforcing-host-compatible (label-exempt like `fedora-dev`, or ship a `udica` policy), since the host is now enforcing. `fedora-dev` itself needs no change. `setup.sh` re-stamps the updated agent law.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps the updated agent law into the box; no host change
```

**Rollback** (docs/policy only — no host state to revert): `git checkout` the prior commit and re-run `setup.sh`.

#### Upgrading to v1.2.3 (from v1.0.0)

Documentation only — **no host behavior change**. Adds a Day-0 boot-stage table to the README's "fresh VPS" section, mapping the SELinux convergence reboots (setup → relabel → permissive soak → enforcing) to each boot's SELinux stage and to **when `fedora-dev` is first pulled and started** (the permissive soak boot — the first `default.target` boot after the Quadlet lands) and re-created, volumes persisting with no re-pull, on every later boot. No code, units, or policy changed.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # docs-only release — re-stamp is a no-op; no host change
```

**Rollback** (docs only — no host state to revert): `git checkout` the prior commit.

#### Upgrading to v1.2.4 (from v1.0.0)

Policy/doc only — **no host behavior change**. Articulates the host claudebox's purpose as the **genesis agent / mother platform** (operate + maintain the host) and extends its maintainership: in addition to `fedora-bootstrap`, the agent now maintains the **`fedora-dev`** repo directly (commit, push to `main`, tag) — `fedora-dev` being the first workload image and the template later workloads follow. All *other* image repos stay surface-only (the agent proposes a diff; the operator or that image's own box opens the PR). Unchanged: image builds still run in CI on push (never `podman build` on the host); the host-apply gate (the live host changes only when you re-run `setup.sh` as root); and the `fedora-dev` deploy path (a pushed image reaches the host only via the workload-refresh pull, and a running box only adopts it once its live spec is refreshed). This release re-stamps the updated agent law (`policy/CLAUDE.md` → `/etc/claude-code/CLAUDE.md` inside claudebox) and refreshes the README Purpose.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps the updated agent law into the box; no host change
```

**Rollback** (docs/policy only — no host state to revert): `git checkout` the prior commit and re-run `setup.sh` to re-stamp the previous agent law.

#### Upgrading to v1.2.5 (from v1.0.0)

Fix only — **no host behavior change**. `verify.sh`'s `host: fail2ban active (sshd jail)` check ran `fail2ban-client status sshd`, which needs root to reach fail2ban's `0700` control socket — but `verify.sh` runs as the unprivileged `core` user (`setup.sh` hands the rootless layer to `su - core`), so the check short-circuited to a **false FAIL on every bring-up even though fail2ban was healthy**. The check now gates the root-only jail query on euid: it asserts the daemon is active (works as `core`) and additionally checks the sshd jail only when run as root.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-runs verify with the corrected check; no host change
```

**Rollback** (no host state to revert): `git checkout` the prior commit.

#### Upgrading to v1.2.7 (from v1.0.0)

Docs + agent-policy — **no host behavior change**. Adds a plain-words "TL;DR" at the top of the README, and updates the host-claudebox law (`policy/CLAUDE.md`) so it maintains `fedora-bootstrap` and `fedora-dev` via **PR-first + maintainer-approved merge** (no direct push to `main`). Host-apply is unchanged — the operator still re-runs `setup.sh`.

> **⚠️ Note — `v1.2.6` was a mis-applied tag** (it points at v1.2.5's commit); **v1.2.7 is its real successor** — there is no v1.2.6 release content.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # docs + policy re-stamp; re-runs verify, no host change
```

**Rollback** (no host state to revert): `git checkout` the prior commit.

---

#### Upgrading to v1.2.8 (from v1.0.0)

Agent-policy only — **no host behavior change**. Broadens BUILD PRINCIPLE 2(c) fleet-wide to a
bounded official-upstream-binary class (last-resort/zero-base, publisher-signature-or-checksum
verified fail-closed, three self-contained consumption shapes, never loose on `$PATH`, disclosed
per-artifact). `fedora-bootstrap` ships no class-(c) artifact (enumeration stays "none"); the
rule is carried for fleet parity so the whole fleet obeys one source-class definition. Host-apply
is unchanged — the operator still re-runs `setup.sh` (it re-stamps the policy docs; no host delta).

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # policy re-stamp + verify; no host change
```

**Rollback** (no host state to revert): `git checkout` the prior commit.

---

#### Upgrading to v1.2.9 (from v1.0.0)

Agent-policy only — **no host behavior change**. Refines BUILD PRINCIPLE 3 (MINIMAL) fleet-wide:
*"minimum" is relative to the chosen capability*, not absolute package count — install the
smallest leaf footprint that makes the chosen capability work, accept + disclose its irreducible
hard-dep closure, and treat a lighter option that *reduces* function as a recorded capability
trade-off (not a minimalism win). Carried for fleet parity (identical wording in fedora-desktop +
fedora-dev). Host-apply is unchanged — re-run `setup.sh` (re-stamps policy docs; no host delta).

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # policy re-stamp + verify; no host change
```

**Rollback** (no host state to revert): `git checkout` the prior commit.

---

#### Upgrading to v1.2.10 (from v1.0.0)

Agent-policy + docs only — **no host behavior change**. Declares **HEADLESS a binding
prerequisite** fleet-wide: the host, the claudebox, and every workload image (`fedora-dev` + the
`fedora-desktop` **xrdp**/**grd** lineages) run with no physical monitor/GPU/seat — any desktop is
a *virtual* software-GL (llvmpipe) display reached only over the network. The statement is carried
in BOTH the machine file (`CLAUDE.md`, a new "HEADLESS (binding prerequisite)" section ahead of
the build principles) and the human file (this README). `fedora-bootstrap` already ran headless;
this only makes the requirement explicit and fleet-consistent. Host-apply is unchanged — the
operator re-runs `setup.sh` (re-stamps the policy docs; no host delta).

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # policy re-stamp + verify; no host change
```

**Rollback** (no host state to revert): `git checkout` the prior commit.

#### Upgrading to v1.2.12 (from v1.0.0)

Agent-policy + docs only — **no host behavior change**. Stamps the **3-box FLEET governance model** (one merge authority) identically into all three repos' agent law. The host claudebox's role is restated: it **operates the host (incl. creating/removing containers)** and **live-diagnoses + develops fixes** to the fleet image repos it operates, but is now **PR-only** — it **stops at the open PR** and no longer merges, pushes, or tags `main`. **`fedora-dev`** becomes the fleet's sole merge box (merges any open PR, control-plane included, only on Arthur's discrete clickable APPROVE). Host-apply is unchanged: re-running `setup.sh` re-stamps the updated agent law; no host delta.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps the updated agent law into the box; no host change
```

**Rollback** (no host state to revert): `git checkout` the prior commit and re-run `setup.sh`.

#### Upgrading to v1.2.13 (from v1.0.0)

Docs/policy only — **no host behavior change**. Scrubs references to the **now-deleted** standalone repos (`fedora-xrdp`, `fedora-tigervnc`, `fedora-kasm`, `debian-kasm-tigervnc`, `debian-dev`) — `fedora-desktop` (xrdp + grd lineages) superseded the desktop variants. README's desktop-containers line now names `fedora-desktop`; the `WORKLOAD_CONTAINERS` dead commented placeholders are removed (a `fedora-desktop` placeholder added for when it's onboarded); `policy/CLAUDE.md`'s dev-box example de-references `debian-dev`. Re-running `setup.sh` re-stamps the updated agent law; no host delta.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps the updated agent law; no host change
```

**Rollback** (no host state to revert): `git checkout` the prior commit and re-run `setup.sh`.

#### Upgrading to v1.2.14 (from v1.0.0)

`setup-host.sh` change — **day-0 now ASKS for a Tailscale auth key.** When `TS_AUTHKEY` isn't already in the environment and you're at an interactive terminal, the host setup prompts for a `tskey-…` (an **unattended** tailnet join); a **blank** answer — or a non-interactive `setup.sh < /dev/null` — falls through to the existing **browser web-login** join, exactly as before. No new package, no security-posture change. This matches the ask-or-web-login pattern the workload spin-up wizards use (`fedora-desktop` + `fedora-dev` `spin-up.sh`). Existing hosts: nothing required — the prompt simply appears on the next interactive `setup.sh` run.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh                    # INTERACTIVE — it will ASK for a TS_AUTHKEY (blank = browser web-login)
# Non-interactive `./setup.sh < /dev/null` still works: it skips the prompt and uses the browser
# web-login join if the node isn't already up and no TS_AUTHKEY env var is set.
```

**Rollback** (no host state to revert): `git checkout` the prior commit and re-run `setup.sh`.

#### Upgrading to v1.2.15 (from v1.0.0)

Docs/policy only — **no host behavior change**. Makes the host spin-up path explicit so an agent (or operator) doesn't miss it: the Day-0 block now shows the **unattended** Tailscale join (`TS_AUTHKEY=tskey-…` on the `setup.sh` line, honored with `< /dev/null`; blank = browser web-login) and a **"who runs this / no `spin-up.sh`/`run.sh` here — `setup.sh` IS the host genesis path"** signpost. Corrects the v1.2.14 framing (the interactive prompt fires only on a later *interactive* `setup.sh` run, not the `< /dev/null` Day-0 paste). `policy/CLAUDE.md` DO gains a fleet spin-up-paths bullet.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps the updated agent law; no host change
```

**Rollback** (no host state to revert): `git checkout` the prior commit and re-run `setup.sh`.

#### Upgrading to v1.2.16 (from v1.0.0)

Adds the interactive **Day-0 wizard `day0.sh`** — it ASKS for the Tailscale auth key (**Enter** = browser web-login), runs `setup.sh`, then prompts for core's password and reboots into the SELinux convergence. `setup.sh` is **unchanged**, so the scripted `TS_AUTHKEY=… setup.sh < /dev/null` + `passwd core && reboot` path is identical. **`day0.sh` is the *fresh-host* bring-up entry point only** — an existing-host re-stamp/upgrade still uses `setup.sh` directly (no re-prompt, no reboot):

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamp/upgrade an existing host (day0.sh is for a FRESH Day-0 only)
```

**Rollback** (no host state to revert): `git checkout` the prior commit and re-run `setup.sh`.

#### Upgrading to v1.2.17 (from v1.0.0)

Docs only — **no host behavior change**. Adds **`FLEET.md`** (the human-readable swarm map) and a **"Where this sits — the fleet"** table to the README (the at-a-glance 3-box overview + a `FLEET.md` link); the binding law (`policy/CLAUDE.md` `THE FLEET` block) is unchanged.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # docs/policy re-stamp; no host change
```

**Rollback** (no host state to revert): `git checkout` the prior commit and re-run `setup.sh`.

#### Upgrading to v1.2.18 (from v1.0.0)

Fixes garbled ssh/mosh/tmux output (input **and** output) seen on every client except a freshly-relaunched native macOS terminal. The cause was the single-shared-session login attach: with no `tmux.conf`, `window-size=latest` resized the shared window to whichever client was active last and painted the others onto a foreign grid. This release re-stamps the login drop-in so each connection gets its **own session inside one shared `main` group** (shared windows, independent per-client geometry) and writes a new `/etc/tmux.conf`. A single `main` group — not per-`LOGIN_KEY` — because the primary path is keyless Tailscale SSH (never sets `LOGIN_KEY`), so per-key would collapse to `main` on the tailnet anyway and would fragment your workspace across access methods; one group keeps tailnet ssh, public ssh, and mosh in one continuous workspace. `setup.sh` re-stamp does it all; no operator data migration. `LOGIN_KEY` is retained for per-device audit only.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps zz-tmux-attach.sh + writes /etc/tmux.conf
# Apply to your OWN shell: detach (Ctrl-b d) and reconnect — the new login lands
# you in a "c<pid>" session sharing the shared "main" windows. (Already-attached
# sessions keep the old behavior until you re-login; no need to kill the server.)
```

**Verify** — `test -f /etc/tmux.conf && echo OK` prints `OK`; after a fresh login, `tmux display -p '#{session_name}'` shows `c<pid>` and `tmux display -p '#{session_group}'` is non-empty (`main`). `./verify.sh` includes a `host: tmux server config` check. Functional proof: connect from two clients of different sizes simultaneously — both render clean.

**Rollback** — `git checkout` the prior commit (or `git checkout v1.2.17`) and re-run `./setup.sh < /dev/null`; it re-stamps the prior single-session drop-in. Optionally `rm /etc/tmux.conf`. Existing windows are untouched.

#### Upgrading to v1.2.19 (from v1.0.0)

> **⚠️ Corrected in v1.2.21:** the `policy.json` writer this release introduced emitted an invalid `containers-storage` entry (a bare array, not a scope→requirements object), which made podman reject the entire image-trust policy and broke every `ghcr.io/oso-gato` pull. Use the **v1.2.21** subsection below — `setup.sh` there repairs the file in place.

Control-plane policy refinement — **the production run-set does not change**. The host image-trust `policy.json` (default `reject`, previously allowing only `ghcr.io/oso-gato/*`) gains two scoped entries: the class-(a) Fedora base `registry.fedoraproject.org/fedora` (so the `validation/` host-validation spikes+gates can pull stock Fedora test fixtures) and the `containers-storage` transport (so `podman save`/`load` works for the throwaway tar cache those fixtures live in). Workloads still **run** only `ghcr.io/oso-gato/*` images — the Quadlets are unchanged; this only widens what may be *pulled* for disposable host-validation. `setup.sh` writes the new policy on a fresh host and **idempotently, additively** merges the two entries into an existing `policy.json` without clobbering operator edits. (The Fedora base is permitted at the same `insecureAcceptAnything` posture as the production `oso-gato` stanza; both can be tightened to `sigstoreSigned` in lockstep later — see the comment block in `setup-user.sh`.)

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # merges the two policy.json entries; no workload/run change
```

**Verify** the entries landed and the production guarantees are intact (key-only check, no store write):

```sh
python3 -c 'import json;d=json.load(open("/home/core/.config/containers/policy.json"));t=d["transports"];print("fedora-base:", "registry.fedoraproject.org/fedora" in t["docker"]);print("containers-storage:", "containers-storage" in t);print("default-reject:", d["default"]==[{"type":"reject"}]);print("non-oso-gato-docker-rejected:", t["docker"][""]==[{"type":"reject"}])'
# expect all four True
```

Expected output: four `True` lines. (Optional functional check — note it transiently writes the live store: `podman pull --quiet registry.fedoraproject.org/fedora:44 && podman rmi registry.fedoraproject.org/fedora:44`.)

**Rollback** — no host *state* changes; the only artifact is the policy file, and the merge is **additive-only** (re-running an older `setup.sh` will NOT remove the two entries). To revert, delete them explicitly:

```sh
python3 - <<'PY'
import json
p="/home/core/.config/containers/policy.json"
d=json.load(open(p)); t=d.get("transports",{})
t.get("docker",{}).pop("registry.fedoraproject.org/fedora", None)
t.pop("containers-storage", None)
json.dump(d, open(p,"w"), indent=4); open(p,"a").write("\n")
print("[policy] validation-fixture entries removed")
PY
```

#### Upgrading to v1.2.20 (from v1.0.0)

Policy only — **no host package or service change**. The host claudebox now defaults to the **`auto` permission mode**: `policy/managed-settings.json` drops `"disableAutoMode": "disable"` and adds `"defaultMode": "auto"`, so in-box Claude sessions start without routine permission prompts (a background classifier vets each action before it runs). The **merge gate is unchanged** — the managed `gate-push.sh` `ask` hook, the `git push` / `gh pr merge` deny rules, and `disableBypassPermissionsMode` all remain in force, so nothing reaches `main` without your explicit approval. The change is re-stamped into `/etc/claude-code/managed-settings.json` on every `setup.sh` run.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps managed-settings.json; no host package/service change
```

**Verify** the box default flipped (key-only check):

```sh
distrobox enter claudebox -- python3 -c 'import json;p=json.load(open("/etc/claude-code/managed-settings.json"))["permissions"];print("defaultMode:", p.get("defaultMode"));print("disableAutoMode:", p.get("disableAutoMode"))'
# expect: defaultMode: auto   /   disableAutoMode: None
```

Then reconnect the claudebox session (`claude`); routine actions run without prompting (the first entry may show a one-time auto-mode opt-in). The merge gate still prompts for any push/merge.

**Rollback** — policy only, no host state to revert: `git checkout` the prior commit and re-run `./setup.sh < /dev/null` to re-stamp the previous `managed-settings.json` (or, in-session, cycle to a stricter mode with Shift+Tab).

#### Upgrading to v1.2.21 (from v1.0.0)

Bug fix — **restores the ability to pull and run workloads** on any host whose `policy.json` carries the malformed `containers-storage` entry shipped in v1.2.19. That entry was written as a bare requirements array; containers-image requires a scope→requirements object, so podman rejected the whole image-trust policy (`JSON object expected, got 91`) and every `ghcr.io/oso-gato` pull failed. The fixed `setup-user.sh` corrects both writers and its idempotent merge now **repairs an existing broken file in place** — no manual edit — with a fail-closed structural check.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # repairs policy.json in place; no workload/run change
```

**Verify** the policy now parses and a pull succeeds:

```sh
python3 -c 'import json;t=json.load(open("/home/core/.config/containers/policy.json"))["transports"];print("containers-storage is object:", isinstance(t.get("containers-storage"), dict));print("all transports objects:", all(isinstance(v,dict) for v in t.values()))'
# expect: both True
podman pull --quiet ghcr.io/oso-gato/fedora-dev:latest >/dev/null && echo "pull OK"
```

Expected: two `True` lines and `pull OK`. Any deferred workload then starts: `systemctl --user restart fedora-dev.service`.

**Rollback** — policy only; `setup.sh` only *repairs* the file (never widens trust). To remove the validation-fixture entries entirely, use the removal snippet in the v1.2.19 subsection above.

#### Upgrading to v1.2.22 (from v1.0.0)

Validation tooling + a `container-refresh.sh` capability — **no production behavior change**. `container-refresh.sh` gains a `BUSY_PROBE` env seam: **unset in production** (the steady-state `workload-refresh@` timers keep using the claudebox busy-probe unchanged), but a non-claudebox workload — or the `validation/rollback-spike.sh` host-validation spike — can set `BUSY_PROBE=/bin/true` for the "empty busy probe" the agent docs already prescribe. The spike's throwaway Quadlet also now sets an explicit `HealthCmd=` (a `podman build` image's `HEALTHCHECK` is dropped under OCI). Together these let the spike exercise — and prove **GREEN** — `container-refresh.sh`'s rollback branch, which had never fired before.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps container-refresh.sh with the BUSY_PROBE seam; no run change
```

**Verify** (optional — exercises the rollback branch on a throwaway workload; touches no real fleet container, pushes nothing):

```sh
/opt/fedora-bootstrap/validation/rollback-spike.sh
# expect: VERDICT: GREEN
```

**Rollback** — tooling only; `git checkout` the prior commit and re-run `setup.sh` to re-stamp the prior `container-refresh.sh` (the `BUSY_PROBE` default is identical, so production is unaffected either way).

#### Upgrading to v1.2.23 (from v1.0.0)

Validation tooling — **no production behavior change**. The pre-merge live gate `validate-candidate.sh` is now parameterized so it can validate a real workload faithfully: `CAND_FENCE` supplies the candidate's run-contract (caps/devices, minus public ports + real secrets; default = the hardest untrusted fence), and `CAND_PROBE` is the workload's "does it actually serve" assertion, run on the candidate's own loopback via `podman exec`. The gate faithfully PASSES a correctly-serving candidate and FAILS one that is up/healthy but serves wrong — the access-path probe is load-bearing, not just the healthcheck. See `validation/LIVE-GATE-HANDOFF.md` for the full gate contract.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps validate-candidate.sh; no workload/run change
```

**Verify** (optional — gate A's rollback branch on a throwaway workload; touches no real fleet container, pushes nothing):

```sh
/opt/fedora-bootstrap/validation/rollback-spike.sh    # expect: VERDICT: GREEN
```

**Rollback** — tooling only; `git checkout` the prior commit and re-run `setup.sh` to re-stamp the prior `validate-candidate.sh`.

#### Upgrading to v1.2.24 (from v1.0.0)

Config defaults only — **no host package or service change**. The host claudebox now **starts every session at ultracode**. Two coordinated changes: the `claude` wrapper (`setup-user.sh`) injects `--settings '{"ultracode":true}'` on every launch — ultracode (`xhigh` effort + workflow-by-default) is **session-scoped and ignored in settings files**, so the wrapper is the only place it can be defaulted — and `policy/managed-settings.json` gains a top-level `"effortLevel": "xhigh"` as the persistent floor for any path that does not go through the wrapper (subagents, a direct `/usr/bin/claude`). Together with v1.2.20's `defaultMode: auto`, this completes the autonomous-defaults set: the box comes up in **auto mode at ultracode with no per-session action**. The **merge gate is unchanged** — the `gate-push.sh` `ask` hook, the `git push` / `gh pr merge` deny rules, and `disableBypassPermissionsMode` all remain in force.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps managed-settings.json + the claude wrapper; no host package/service change
```

**Verify** the effort floor stamped and the wrapper injects ultracode:

```sh
distrobox enter claudebox -- python3 -c 'import json;print("effortLevel:", json.load(open("/etc/claude-code/managed-settings.json")).get("effortLevel"))'
# expect: effortLevel: xhigh
grep -q ultracode ~/.local/bin/claude && echo "wrapper injects ultracode"
# expect: wrapper injects ultracode
```

Then reconnect the claudebox session (`claude`); it starts at ultracode/`xhigh` effort. Per-session you can still drop effort (`/effort`) or cycle permission modes (Shift+Tab); the defaults reset on the next launch.

**Rollback** — config only, no host state to revert: `git checkout` the prior commit and re-run `./setup.sh < /dev/null` to re-stamp the previous `managed-settings.json` + `claude` wrapper.

#### Upgrading to v1.2.25 (from v1.0.0)

Policy/doc only — **no host package, service, or deploy-path change**. The host law is amended to permit **disposable validation builds**: the host MAY `podman build` a throwaway image *solely* to live-test an open PR before merge (`localhost/disposable/*`, never pushed, `--rm`, never a workload), while building any **shipping** image stays **always CI's job**. This unblocks the pre-merge live-gate loop (the host candidate-builder is the next step). The stamped `/etc/claude-code/CLAUDE.md` + the project `CLAUDE.md` are re-stamped/pulled on `setup.sh`.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps policy/CLAUDE.md into /etc/claude-code/; no package/service/deploy change
```

**Verify** the carve-out is stamped into the box law:

```sh
distrobox enter claudebox -- grep -c 'CARVE-OUT — disposable validation builds' /etc/claude-code/CLAUDE.md
# expect: 1
```

**Rollback** — doc only, no host state to revert: `git checkout` the prior commit and re-run `./setup.sh < /dev/null` to re-stamp the previous `policy/CLAUDE.md`.

#### Upgrading to v1.2.26 (from v1.0.0)

New tooling — **no host package, service, or deploy-path change**. Adds `build-candidate.sh`, the host's pre-merge BUILD step: it exports a workload PR ref to a throwaway tree, `podman build`s a disposable candidate (`localhost/disposable/*`, never pushed, `--rm`/`rmi`'d), live-gates it via `validate-candidate.sh`, and discards it (base layers stay cached). `setup-user.sh` installs both into `~/.local/bin` (`validate-candidate.sh` was previously uninstalled). Sanctioned by the v1.2.25 carve-out.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # installs build-candidate.sh + validate-candidate.sh to ~/.local/bin; no package/service/deploy change
```

**Verify** (optional — proves the build→gate path; needs a local `fedora-dev` clone, e.g. `~/fedora-dev`):

```sh
ls -1 ~/.local/bin/build-candidate.sh ~/.local/bin/validate-candidate.sh   # both present
# Full run (with the fedora-dev CAND_FENCE/CAND_PROBE/HEALTH preset documented in build-candidate.sh):
~/.local/bin/build-candidate.sh fedora-dev ~/fedora-dev
# expect: ... VERDICT: GREEN ... gate exit=0   (disposable image rmi'd; nothing pushed)
```

**Rollback** — tooling only; `git checkout` the prior commit and re-run `setup.sh`; optionally `rm ~/.local/bin/build-candidate.sh`.

#### Upgrading to v1.2.27 (from v1.0.0)

New tooling — **no host package, service, or deploy-path change**. Adds the live-gate loop transport: `live-gate-run.sh` (gate one PR: build disposably → gate → `gh pr comment` the verdict) + `live-gate-watch.sh` (a `systemd --user` timer polling `live-validate`-labelled PRs, dedup per-commit, never gated on a dev session) + per-workload presets (`live-gate-presets/<wl>.env` → `~/.config/live-gate/`). `setup-user.sh` installs both scripts, the presets, and the units, and enables `live-gate-watch.timer`. The host **comments, never merges**.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # installs live-gate-run/watch + presets + enables live-gate-watch.timer; no package/service/deploy change
```

**Verify** the watcher is armed:

```sh
systemctl --user list-timers live-gate-watch.timer
ls ~/.local/bin/live-gate-run.sh ~/.local/bin/live-gate-watch.sh ~/.config/live-gate/fedora-dev.env
# To use: label an open workload PR `live-validate`; the watcher builds + gates it and comments the verdict.
```

**Rollback** — tooling only; `git checkout` the prior commit and re-run `setup.sh`; `systemctl --user disable --now live-gate-watch.timer` to stop watching.

#### Upgrading to v1.2.28 (from v1.0.0)

Bug/robustness fixes to the v1.2.27 transport — **no host package, service, or deploy-path change**. (1) The live-gate watcher runs **inside the claudebox** (it needs `gh`/`git`, which are box tools; it drives the host engine via `CONTAINER_HOST`) — the host-only service had failed `gh pr list`. (2) `setup.sh`'s workload-clone update no longer aborts on a dirty `~/<name>` working tree (it discards stray edits, then fast-forwards — keeping force-push detection).

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps live-gate-watch.service + setup-user.sh; no package/service/deploy change
```

**Verify** the watcher runs in-box cleanly:

```sh
systemctl --user start live-gate-watch.service && systemctl --user show live-gate-watch.service -p Result --value   # expect: success
journalctl --user -u live-gate-watch.service --since '1 min ago' | tail -3   # expect: "[live-gate-watch] <wl>: no live-validate PRs" (or it gates one)
```

**Rollback** — tooling only; `git checkout` the prior commit and re-run `setup.sh`.

#### Upgrading to v1.2.29 (from v1.0.0)

Timer tweak only — **no host package, service, or deploy-path change**. The live-gate watcher polls every **15 s** instead of 5 min (`live-gate-watch.timer`: `OnBootSec`/`OnUnitActiveSec=15s` + `AccuracySec=1s`; jitter removed). Safe — the watcher self-serializes (`flock`), so a running build makes intervening firings skip; idle firings are a cheap box-enter + one `gh pr list`.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps live-gate-watch.timer; no package/service/deploy change
```

**Verify** the cadence:

```sh
systemctl --user list-timers live-gate-watch.timer
systemctl --user cat live-gate-watch.timer | grep -E 'OnUnitActiveSec|AccuracySec'   # expect 15s / 1s
```

**Rollback** — tooling only; `git checkout` the prior commit and re-run `setup.sh`.

#### Upgrading to v1.2.30 (from v1.0.0)

Unit tweak only — **no host package, deploy-path, or security-flag change**. Lowers the box-rebuild crash/hang backstop on `claudebox-rebuild-run.service` from `TimeoutStartSec=900` (15 min) to **`480`** (8 min). A practical exam on this VPS measured the box `dnf install` at 101 s, a full rebuild ≈ 150 s, and the worst-case *legit* rebuild (cold 2.17 GB image pull + first-enter retries) ≈ 400–450 s — so 900 s was ~2× the worst case and let a genuinely-stuck rebuild lock out new sessions for 15 min. 480 s clears the worst-case legit rebuild with margin while halving crash recovery; it only ever fires on a *stuck* rebuild (a healthy one is detected complete within ~2 s), so normal rebuilds are never clipped. Host-only — the host serializes the rebuild via systemd, so the fd-9 `box-rebuild.lock` leak that hangs the workload boxes does not apply here (the matching workload fix ships in `fedora-dev`/`fedora-desktop`).

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps claudebox-rebuild-run.service with TimeoutStartSec=480
```

**Verify**:

```sh
systemctl --user cat claudebox-rebuild-run.service | grep TimeoutStartSec   # expect 480
```

**Rollback** — unit only; `git checkout` the prior commit and re-run `setup.sh`.

#### Upgrading to v1.2.31 (from v1.0.0)

Multi-device tmux geometry — **config re-stamp only, no host package/service/security-flag change**. Supersedes the v1.2.18 fix. Symptom it removes: connecting a *small* client (iPad/Prompt 3) over mosh/ssh made a *large* client (Ghostty) on the same shared session "completely garbled" (it recovered when the small client disconnected). Root cause, proven against tmux 3.6 source + a live multi-client harness: **a tmux window has exactly one size, shared by every client viewing it** — so two differently-sized devices on the *same tab* can't each be full-size (unfixable in tmux). The mismatched client isn't "garbage": tmux fills its surplus area every frame with `fill-character` (compiled default `·` middle-dot) — that dot-fill on a big idle screen *is* the garble. The old `window-size smallest` sized the shared window to the *smallest* client, dotting every larger screen. New `/etc/tmux.conf`:

- **`window-size latest`** (default) — the session follows whichever device most recently sent **input**: type on the Mac and it's Mac-sized; pick up the iPad and type and it rescales to the iPad. Both stay connected (mosh-friendly); the idle device blank-letterboxes/crops cleanly and reclaims full size on its next keystroke; when the active device disconnects the session falls back to whoever remains. Seamless macOS↔iPad handoff.
- **`fill-character ' '`** — idle larger device's surplus is blank, not `·`.
- **`prefix + g`** cycles `latest → smallest` (every device sees the WHOLE session sized to the smallest, big screens blank-letterbox) `→ largest` (biggest wins, smaller devices crop) `→ latest`.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-stamps /etc/tmux.conf; no host package/service change
```

**Verify**:

```sh
grep -E 'window-size|fill-character' /etc/tmux.conf   # expect: window-size latest + fill-character ' '
```

Then, from two clients of different sizes, type on each in turn — the whole session rescales to whichever you last typed on; `prefix+g` cycles the policy and shows the active mode. (Existing windows untouched; reconnect to pick up the new server config, or `tmux kill-server` after detaching all clients.)

**Rollback** — config only; `git checkout v1.2.30` (or the prior commit) and re-run `./setup.sh < /dev/null` to re-stamp the previous `/etc/tmux.conf`.

#### Upgrading to v1.2.33 (from v1.0.0)

Live-gate validation tooling only — **no host package, system service, or production deploy-path change** (the live-gate runs disposable, never-pushed throwaway containers; the workload-refresh path is untouched). This release makes the pre-merge live-gate **dynamic** and **safe**:

- **Dynamic discovery (Model C).** The watcher no longer carries a per-repo workload list: it runs one **org-wide** query for every `live-validate`-labelled open PR, **clones each PR head on demand** into an ephemeral tree, reads that repo's **in-tree `.live-gate` contract**, builds + gates **every** declared target, and **structurally skips** (neutral, never errors) any repo with no top-level `Containerfile*`/`.live-gate`. Labelling a PR `live-validate` is the entire opt-in — Arthur maintains no allow/deny list.
- **`.live-gate` is consumed *safely* (parsed, not executed).** Previously the host **sourced** the PR-shipped `.live-gate` as host shell, so a `FENCE_x="$(cmd)"` or `KEY=1; cmd` line was a **host RCE** from any labelled PR. It is now **parsed** (`KEY=VALUE` read line by line, key checked against the schema allowlist, one quote layer stripped, assigned via `printf -v` — never `eval`/`source`); single-quoted command values are inert on the host and run only **inside the fenced container**, command substitution outside single quotes is **refused**, and a hostile/malformed contract is **rejected RED and never executed**.
- **Fences are loopback-only-enforced.** The gate now **fails closed (RED)** if a resolved fence carries a publish flag (`-p`/`--publish`/`-P`/`--publish-all`) — it probes the candidate on its own loopback via `podman exec`, so no port may be published.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # re-installs live-gate-run.sh + validate-candidate.sh + the normalized presets; no package/service/deploy change
```

**Verify** the safe consumer + loopback-only enforcement (a fresh check, run as `core`):

```sh
# 1. the consumer parses (never sources): a poisoned contract is rejected and runs nothing.
printf '%s\n' 'FENCE_x="$(touch /tmp/PWNED)"' > /tmp/bad.live-gate
bash -c 'lg_reason=; '"$(sed -n "/^lg_load(){/,/^}/p" ~/fedora-bootstrap/live-gate-run.sh)"'; lg_load /tmp/bad.live-gate && echo ACCEPTED || echo "REJECTED: $lg_reason"'
test -e /tmp/PWNED && echo "FAIL: /tmp/PWNED created" || echo "OK: /tmp/PWNED not created"; rm -f /tmp/bad.live-gate
# expect: REJECTED: ... + OK: /tmp/PWNED not created
# 2. a fence that publishes a port is rejected before launch.
CAND_FENCE='--cap-add NET_ADMIN -p 8443:8443' bash ~/fedora-bootstrap/validate-candidate.sh localhost/nonexistent:none 2>&1 | grep -m1 'RED (fence'
# expect: VERDICT: RED (fence publishes a port)
```

**Rollback** — tooling only; `git checkout` the prior commit and re-run `setup.sh`.

#### Upgrading to v1.2.34 (from v1.0.0)

Live-gate **throwaway-churn** hardening — **no host package, system service, or production deploy-path change** (the live-gate still runs disposable, never-pushed throwaway containers; the workload-refresh path is untouched). It makes the host's pre-merge throwaway-build mechanism cheap to churn and self-cleaning:

- **Persistent dnf package cache.** `build-candidate.sh` binds `$HOME/.cache/fd-dnf` onto each candidate build's `/var/cache/libdnf5:rw`. The RPMs a candidate downloads now **persist across every later candidate build**, so a forced re-run serves them from disk instead of re-downloading (**94 s → 33 s** measured on a forced in-box re-run). The host top-level engine is **not** chroot-isolated, so a writable bind cache works here (unlike the dev box, which requires `--isolation=chroot`). The disposable `localhost/disposable/*` tag, the EXIT-trap `rmi`, and the absence of `--no-cache` are all unchanged — the layer cache still survives the candidate `rmi`; the dnf bind cache is additive.
- **Crash-safe orphan sweeper.** A new `throwaway-sweep.sh` runs at `live-gate-watch.sh` start (self-throttled to once per `FD_SWEEP_INTERVAL_MIN`, default 30 m) and reaps what a `kill -9`/OOM/crash leaves behind that the per-run EXIT traps miss: **aged** (older than `FD_SWEEP_AGE_MIN`, default 120 m) orphan `localhost/disposable/*` images, `vcand-*` containers, and throwaway source trees (now under `$FD_THROWAWAY_TMPDIR`). It is age-gated, uses a **non-forced** `rmi` (an image a running gate still references is skipped), targets only the `vcand-*` throwaway namespace, and is `flock`-guarded — so a running gate's current artifacts are never touched.
- **Bounded cache GC.** The same reaper caps the persistent dnf cache so churn can't exhaust the VPS quota — **age-prune first, then size-prune**: it removes RPMs older than `FD_DNF_CACHE_MAX_AGE_DAYS` (default **45 days**), then, if the cache is still over `FD_DNF_CACHE_CAP_GB` (default **15 GB**), LRU-evicts the oldest remaining RPMs until under the cap (keeping the freshest churn RPMs hot). The dangling podman build cache is bounded separately via `podman image prune --filter until=$FD_BUILDCACHE_AGE` (default 168 h; **dangling-only**, so tagged `ghcr.io/oso-gato/*` images are never touched). All knobs are overridable env vars.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # installs throwaway-sweep.sh + the cache-wired build-candidate.sh; no package/service/deploy change
```

**Optional — wire a periodic sweep** (recommended only if this host gates PRs infrequently; the watcher already calls the self-throttled sweeper at every poll). As `core`:

```sh
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/throwaway-sweep.service <<'EOF'
[Unit]
Description=Reap leaked live-gate throwaways + bound the build caches
[Service]
Type=oneshot
Environment=FD_SWEEP_FORCE=1
ExecStart=%h/.local/bin/throwaway-sweep.sh
EOF
cat > ~/.config/systemd/user/throwaway-sweep.timer <<'EOF'
[Unit]
Description=Hourly live-gate throwaway sweep
[Timer]
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now throwaway-sweep.timer
```

**Verify** (as `core`):

```sh
# 1. the dnf bind cache is wired into the candidate build command.
grep -q 'var/cache/libdnf5' ~/.local/bin/build-candidate.sh && echo "OK: dnf bind cache wired" || echo "FAIL"
# 2. the sweeper removes a deliberately-aged orphan image + container while leaving non-orphans.
FD_SWEEP_FORCE=1 FD_SWEEP_AGE_MIN=0 FD_SWEEP_DRYRUN=1 ~/.local/bin/throwaway-sweep.sh   # report-only dry run
```

**Rollback** — tooling only; `git checkout` the prior commit and re-run `setup.sh` (then `systemctl --user disable --now throwaway-sweep.timer` if you wired the optional timer).

#### Upgrading to v1.2.35 (from v1.0.0)

Fix — **`claudebox-rebuild` failed on the host with `Source image docker://quay.io/fedora/fedora-toolbox:44 is rejected by policy` (exit 125) after the first build.** No host package, system service, or deploy-path change. The image-trust `policy.json` (default `reject`) trusted `ghcr.io/oso-gato` + `registry.fedoraproject.org/fedora` + `containers-storage`, but **not** `quay.io/fedora/fedora-toolbox` — the claudebox base pinned in `distrobox.ini`, which distrobox **re-pulls on every rebuild**. The *first* day-zero build worked because the claudebox assemble in `setup-user.sh` **phase 3** runs **before** the policy is written in **phase 4** (so it pulls under the permissive default and caches the toolbox); every later rebuild re-pulls under the now-restrictive policy and is rejected — which is exactly why "the first build always works, subsequent updates fail." `setup-user.sh` now trusts the toolbox base in **both** writers (the create-heredoc for fresh hosts **and** the idempotent merge), so re-running `setup.sh` **repairs an already-deployed host in place**.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # adds quay.io/fedora/fedora-toolbox to policy.json (repairs in place)
claudebox-rebuild             # now succeeds
```

**Immediate unblock without re-running `setup.sh`** (adds just the one scope to the live policy, then rebuilds):

```sh
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.config/containers/policy.json")
d = json.load(open(p)); t = d.setdefault("transports", {}).setdefault("docker", {})
t.setdefault("quay.io/fedora/fedora-toolbox", [{"type": "insecureAcceptAnything"}])
json.dump(d, open(p, "w"), indent=4)
print("trusted quay.io/fedora/fedora-toolbox")
PY
claudebox-rebuild
```

**Verify**: `claudebox-rebuild` completes, and `podman pull quay.io/fedora/fedora-toolbox:44` succeeds. `fedora-dev` and `fedora-desktop` are **unaffected** — their claudeboxes run no restrictive `policy.json` (permissive default), so their rebuilds were never rejected.

**Rollback** — config only; `git checkout` the prior commit and re-run `setup.sh`. (Removing the scope re-breaks subsequent rebuilds, so only roll back with that understanding.)

#### Upgrading to v1.2.36 (from v1.0.0)

Process/docs only — **no host action required** (`git pull` for the updated convention; nothing to apply, no service touched). Drops the per-release **git tag** requirement from the release convention: the host deploys `main` (not tags), rollback is `git checkout <commit>` + re-run `setup.sh`, nothing external pins a release, and the version-of-record is already in-tree (`VERSION` + `setup.sh` header + README front-matter + the "Upgrading" changelog) — so the tag was redundant friction, and it was already unused after `v1.2.19` while the version reached 1.2.35. `CLAUDE.md` (RELEASING + RELEASE-DOC) and the agent-law `policy/CLAUDE.md` drop the tag step and the immutable-tags rule; the stale `git push origin main` release step is corrected to the PR-merge model. Tagging stays **optional** for a deliberate milestone, and the existing `v1.0.0`–`v1.2.19` tags remain as history.

**Rollback** — none needed (process/doc only; no host state touched).

#### Upgrading to v1.2.37 (from v1.0.0)

Fix for an ordering bug in the v1.2.35 claudebox-trust fix. `setup-user.sh` wrote/repaired the image-trust `policy.json` in **`user 4/5`** but assembled the claudebox in **`user 3/5`** — so on an already-deployed host whose restrictive policy still lacks the toolbox scope, the `user 3/5` assemble's `quay.io/fedora/fedora-toolbox` pull is **rejected before** `user 4/5` can add it, and a plain `setup.sh` re-run fails every time at `user 3/5`. A small **idempotent guard** now trusts the toolbox base in the live `policy.json` **before** the assemble (a no-op on a fresh host with no policy yet, and when the scope is already present). v1.2.35 fixed *fresh* day-zero hosts; this fixes the *re-run-on-an-already-deployed-host* path.

If your host is currently stuck at `user 3/5 … rejected by policy`, do the one-time repair + upgrade (as **root**, in `/opt/fedora-bootstrap`):

```sh
sudo -u core tee /home/core/.config/containers/policy.json >/dev/null <<'EOF'
{
    "default": [{ "type": "reject" }],
    "transports": {
        "docker": {
            "ghcr.io/oso-gato": [{ "type": "insecureAcceptAnything" }],
            "registry.fedoraproject.org/fedora": [{ "type": "insecureAcceptAnything" }],
            "quay.io/fedora/fedora-toolbox": [{ "type": "insecureAcceptAnything" }],
            "": [{ "type": "reject" }]
        },
        "containers-storage": { "": [{ "type": "insecureAcceptAnything" }] }
    }
}
EOF
git pull --ff-only origin main && ./setup.sh < /dev/null
```

Once v1.2.37 is applied, a plain `git pull --ff-only origin main && ./setup.sh < /dev/null` self-heals — no manual policy step needed ever again.

**Validation honesty:** this fix is `bash -n`-clean and its guard logic is simulation-checked, but it has **not** been run end-to-end on a live host — a real `setup.sh` re-run on a deployed host is the only true proof.

**Rollback** — `git checkout` the prior commit + re-run `setup.sh` (the guard is additive; removing it restores the ordering bug).

#### Upgrading to v1.2.38 (from v1.0.0)

Fix for the **update mechanism**: every auto-update / `claudebox-rebuild` "built a box then failed", while day-zero succeeded. It is a **concurrency race**, not a build defect — the v1.2.29 **15 s live-gate watcher** fires `distrobox enter claudebox` throughout a rebuild and races `setup-user.sh`'s own first-enter (which runs `distrobox-init` = the `dnf install`); two `distrobox enter` then drive `distrobox-init` concurrently in the same fresh box and either **collide on the pre-init hooks** (init errors) or **deadlock on distrobox's name-keyed fifo** (init hangs), with the v1.2.30 **480 s timeout** turning the hang into a hard kill. Day-zero is immune because the watcher's timer is enabled only *after* the box build. The fix (1) stands the watcher down for the rebuild window in `box-rebuild.sh` (trap-protected re-arm), (2) adds an `ExecCondition` to `live-gate-watch.service` that skips while a rebuild is active, (3) makes `setup-user.sh`'s first-enter an authoritative readiness check, and (4) raises the rebuild-service `TimeoutStartSec` 480 → 1800 s. **Applying is safe on the broken host** — a plain `setup.sh` re-run does **not** remove the box (so it doesn't trigger the race); it only re-stamps the fixed `box-rebuild.sh`, units, and timeout. Apply as **root** in `/opt/fedora-bootstrap`:

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null    # re-stamps box-rebuild.sh + the live-gate ExecCondition + the 1800s rebuild timeout
```

**Verify** the units carry the fix (the `ExecCondition` line and a 30-min timeout), then prove a rebuild now succeeds — run the rebuild **as `core`** (it tears down + recreates the box, then reconnect with `claude`):

```sh
systemctl --user --machine=core@.host cat live-gate-watch.service | grep -i ExecCondition
systemctl --user --machine=core@.host show claudebox-rebuild-run.service -p TimeoutStartUSec   # → 30min
sudo -iu core claudebox-rebuild    # completes "claudebox rebuild COMPLETE"; then `claude` to reconnect
```

Expected: the `ExecCondition=… ! systemctl --user is-active … claudebox-rebuild-run.service` line is present, `TimeoutStartUSec=30min`, and `claudebox-rebuild` finishes green where it previously "built then failed".

**Rollback** — `git checkout` the prior commit + re-run `setup.sh` (this restores the racing behaviour, so only roll back with that understanding).

#### Upgrading to v1.2.39 (from v1.0.0)

Documentation-only patch — no host behavior change. `validation/live-gate.sample` now documents the **deeper-probe pattern**: a target's `PROBE` may invoke a *shipped script* (COPY'd into the image, no Containerfile change) for richer, lineage-aware assertions — the desktop session actually rendering, the RDP-server config, the Guacamole auth chain, multi-user per-user ports — all inside the loopback candidate, self-diagnosing. A real RDP-pixel frame stays operator-run (it needs a published port + host-side tools). Proven by fedora-desktop's deeper Gate-B probe (the gate is workload-agnostic; zero host/apparatus change). The standard upgrade flow applies.

**As root on the VPS:**

```sh
# Standard upgrade flow — idempotent; picks up the doc + version markers, no host change.
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
```

Expected: `cat /opt/fedora-bootstrap/VERSION` → `1.2.39`; `setup.sh` ends green (`verify.sh` all PASS). **Rollback** — `git checkout` the prior commit + re-run `setup.sh`.

#### Upgrading to v1.2.40 (from v1.0.0)

Documentation-only patch — no host behavior change. Corrects two understated public-exposure claims in the **Access** section: the table marked the dev container's ssh/mosh as `From public internet: no`, and the prose said the public IP "exposes exactly two surfaces." In fact this host deploys the `fedora-dev` Quadlet, whose `PublishPort`s expose **public key-only ssh on :4444 + mosh on 61001-62000/udp** — a third hardened public surface (key-only, and since fedora-dev's key-sync, fingerprint-allowlisted). The table cell and the sentence now state this; native RDP/VNC and Cockpit remain tailnet-only. Found during the SSH/Mosh connectivity audit; no host package/service/deploy-path change.

**As root on the VPS:**

```sh
# Standard upgrade flow — docs only; nothing to apply, no service touched.
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
```

Expected: `cat /opt/fedora-bootstrap/VERSION` → `1.2.40`; `setup.sh` ends green (`verify.sh` all PASS). **Rollback** — none needed (docs only; no host state touched).

#### Upgrading to v1.2.41 (from v1.0.0)

Security-posture change — **fail2ban is removed from the host**. Both public ssh doors are key-only (no password to brute-force), so fail2ban's jail bought nothing — on the host it ran (journald backend) but guarded nothing. `setup.sh` drops `fail2ban-server` from the install and **converges an already-deployed host in place** — it stops + disables `fail2ban.service`, removes the package (leaf + SELinux module) and any legacy `fail2ban`-metapackage baggage, and removes the jail file. `verify.sh` now asserts fail2ban is **absent**. Idempotent: a clean no-op on a host that never had it. (Pairs with the merged `fedora-dev` drop of `fail2ban` + `rsyslog`.)

**As root on the VPS:**

```sh
# Standard upgrade flow — drops fail2ban + converges the footprint; re-stamps everything else.
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
```

Expected: `cat /opt/fedora-bootstrap/VERSION` → `1.2.41`; `systemctl is-active fail2ban.service` → `inactive`/`unknown`; `rpm -q fail2ban-server` → not installed; `setup.sh` ends green (`verify.sh` all PASS, including its new `host: fail2ban absent (key-only door)` check). Trade-off: scanners hitting the public ssh doors are no longer rate-limited — acceptable on a key-only door (they cannot authenticate regardless). **Rollback** — `sudo dnf install -y fail2ban-server`, restore the jail file, `systemctl enable --now fail2ban.service`; note a later `setup.sh` re-run re-converges to the no-fail2ban footprint by design, so a durable revert means pinning an older checkout.

#### Upgrading to v1.2.42 (from v1.0.0)

Security-posture change — the host SSH door goes **all-keys**, symmetric with the dev box. The public-door fingerprint **allowlist is dropped**: `sync-authorized-keys.sh` now authorizes **every** key on `github.com/oso-gato.keys` (the GitHub account becomes the single access-control point — add/remove a key there to grant/revoke). `setup.sh` re-syncs the keys and **converges an already-deployed host in place** — it removes the per-device `LOGIN_KEY` sshd drop-in (`/etc/ssh/sshd_config.d/20-login-key.conf`) and reloads sshd, so `PermitUserEnvironment` is no longer set; the `LOGIN_KEY` per-device audit tagging is gone. Idempotent: a clean no-op on a host already in this state.

**As root on the VPS:**

```sh
# Standard upgrade flow — re-syncs all account keys + drops the LOGIN_KEY drop-in; re-stamps the rest.
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
```

Expected: `cat /opt/fedora-bootstrap/VERSION` → `1.2.42`; `~core/.ssh/authorized_keys` now lists every key from `github.com/oso-gato.keys` (untagged, no `environment="LOGIN_KEY=…"`); `test -e /etc/ssh/sshd_config.d/20-login-key.conf` → absent; `setup.sh` ends green (`verify.sh` all PASS). Trade-off: any key on the account can use the public door (acceptable — the operator manages the account's keys); per-device login attribution via `LOGIN_KEY` is no longer recorded. **Rollback** — restore the fingerprint-allowlist `sync-authorized-keys.sh` + the `20-login-key.conf` drop-in from a prior checkout and re-run `setup.sh`; note a later `setup.sh` re-run re-converges to all-keys by design, so a durable revert means pinning an older checkout.

