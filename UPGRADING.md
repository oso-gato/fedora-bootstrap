# Upgrade history (archived from README.md)

Per-version upgrade subsections for **v1.1.1 through v1.1.14**, relocated from `README.md` (in v1.1.16) to keep the README scannable. The current release's upgrade steps stay in [README.md](README.md) under "Upgrading an existing host to a new release". These blocks are an immutable historical record (see [CLAUDE.md](CLAUDE.md) RELEASE-DOC CONVENTION). Per the v1.0.0 baseline guarantee, a fresh host can jump straight to the latest release via the newest subsection in README; the blocks below are for stepwise / forensic reference.

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

