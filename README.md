# fedora-bootstrap

Version: **1.1.15** — Dependency hygiene (leaf over metapackage). The host was installing the `fail2ban` **metapackage**, whose hard deps silently pulled in `firewalld` (via `fail2ban-firewalld`) + an MTA (`esmtp` via `fail2ban-sendmail`) — none used. That latent `firewalld` started on a reboot with a stock zone that blocked mosh's UDP. This installs the leaf `fail2ban-server` (ban backend `nftables[type=multiport]`) and removes the firewall as the unintended dependency it was — see "Upgrading to v1.1.15". Prior: v1.1.14 — SELinux permissive-first.

## Purpose

`fedora-bootstrap` turns a fresh Fedora Cloud VPS into a **container-as-app fleet** operated by an in-box Claude Code agent. The host stays minimal and treated-as-immutable; every application function runs in a container pulled from `ghcr.io/oso-gato/*`.

This is one half of a two-agent pipeline:

- **the host's claudebox** (this repo's product) — DEPLOYS and OPERATES container images. **Never builds.**
- **`fedora-dev` / `debian-dev`** (separate repos) — DEVELOP and BUILD container images. **Never deploy.**

The handoff is one-way: image source built in the dev container → pushed to GitHub → CI publishes to GHCR → host claudebox pulls and recreates via the workload-refresh harness on a monthly cadence.

## What the host provides after bootstrap

After `setup.sh` (see "Using the bootstrap" below), the VPS:

- **Runs containers from `ghcr.io/oso-gato/*` via podman.** Each major function is its own container; nothing else is installed onto the host beyond a short fixed package list.
- **Hosts claudebox** — the in-host management agent (Claude Code in a Distrobox). Pulls images, runs containers, writes Quadlets, refreshes them on schedule.
- **Carries the personal universe and second brain** via desktop containers (fedora-xrdp, fedora-tigervnc, fedora-kasm, debian-kasm-tigervnc). VS Code for projects, Obsidian for the knowledge vault. RDP `KillDisconnected` + tmux give session survival across disconnects.

**Access:**

| Door | From public internet | From tailnet |
|---|---|---|
| Host shell (ssh, mosh) | yes — key-only | yes (+ keyless Tailscale SSH) |
| Desktops (web: KasmVNC / noVNC / Guacamole) | yes — TLS + password | yes |
| Desktops (native RDP / VNC) | no | yes |
| Dev containers (ssh, mosh, Tailscale SSH) | no | yes |
| Cockpit | no | yes (tailscale serve) |

The public IP exposes exactly two surfaces: the host's hardened shell and the desktops' TLS web doors. Every shell login on any door lands in a persistent per-device tmux session named by the authenticating key (`oSo`, `Alchemist`, `Fatima`).

---

## Using the bootstrap

### Fedora Cloud Update (prerequisite check)

<!-- HOSTINGER_STATUS_START : auto-generated every Friday by .github/workflows/refresh-release.yml — do not edit by hand -->
**Hostinger's Fedora Cloud is 44 — yes, it's the latest release.** You can ignore the version-upgrade steps in this section and skip straight to **Day 0** below.
<!-- HOSTINGER_STATUS_END -->

If the status line above says the cloud image is behind, bring the host current via Fedora's official DNF system-upgrade flow (built into dnf5 — no plugin needed). Fedora supports a +2 jump at most per pass.

**Option 1 — self-updating** (reads latest GA from Fedora's releases.json, Beta-safe):

```sh
( set -e
  cur=$(rpm -E %fedora)
  latest=$(curl -fsSL https://fedoraproject.org/releases.json \
            | grep -oE '"version": *"[0-9]+"' | grep -oE '[0-9]+' | sort -rn | head -1)
  : "${latest:?could not reach fedoraproject.org}"
  target=$(( latest - cur > 2 ? cur + 2 : latest ))
  echo "Current: $cur | latest: $latest | this pass -> $target"
  [ "$target" -gt "$cur" ] || { echo "Already on latest stable."; exit 0; }
  sudo dnf upgrade --refresh
  sudo dnf system-upgrade download --releasever="$target"
  sudo dnf system-upgrade reboot
)
```

**Option 2 — pinned** (`--releasever` auto-bumped weekly by CI from `releases.json` — never goes stale):

```sh
sudo dnf upgrade --refresh
sudo dnf system-upgrade download --releasever=44   # fedora-stable — auto-bumped weekly
sudo dnf system-upgrade reboot
```

Both reboot the host twice (offline transaction, then into the new release). Append `-y` for unattended. If more than +2 releases behind, repeat the block for the next step.

### Day 0 — fresh VPS

As root on a fresh Fedora Cloud instance:

```sh
dnf -y upgrade --refresh
dnf -y install git
git clone https://github.com/oso-gato/fedora-bootstrap /opt/fedora-bootstrap
if /opt/fedora-bootstrap/setup.sh < /dev/null; then
  echo 'setup: all layers PASS.'
else
  echo '*** investigate the failure (login.tailscale.com link? scoped sudoers? see verify.sh output above) and re-run /opt/fedora-bootstrap/setup.sh < /dev/null'
fi
passwd core      # REQUIRED — sets core's admin/sudo + Cockpit/console password
```

`setup.sh` is fully idempotent. It runs as root and orchestrates two layers in their correct identities:

1. **System layer** (`setup-host.sh`, as root): host packages, `/etc`, system services, tailnet, dnf-automatic, creates `core` user + rootless prerequisites.
2. **Rootless layer** (`setup-user.sh`, as `core`): user podman socket, ssh keys synced from `github.com/oso-gato.keys`, claudebox assembled from `distrobox.ini`, Claude policy stamped, workload-refresh harness enabled, verify.

The only interactive pause: the tailscale auth link (one-time per host). Open the URL printed in the output, approve, then re-run setup.sh.

**Host naming:** the VPS names itself `erebus` (override with `BOOTSTRAP_HOSTNAME=<name>`). `hostnamectl` sets it; a cloud-init drop-in pins it across reboots.

**Default networking:** the host comes up advertising itself as a Tailscale **exit node** AND **accepting LAN routes** the tailnet advertises. Turn either off with `TS_EXIT_NODE=0` / `TS_ACCEPT_ROUTES=0` before setup. Each capability also needs one-time admin-console approval (Tailscale → Machines).

> **Security note:** with accept-routes ON, the in-box Claude Code can reach your LAN. Scope its access via tailnet ACLs (tag the VPS, grant only specific hosts/ports — never the bare `/24`).

### Upgrading an existing host to a new release

Each release below has one self-contained code block to paste into the VPS root terminal. Find your target version and follow its subsection — that's the entire upgrade.

> The rules governing what goes in each per-version subsection live in [CLAUDE.md](CLAUDE.md) (agent-facing).

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

---

## Operating the host (as the maintainer)

**Prerequisite — be on the tailnet.** Everything below is reached over your tailnet, not the public IP. Run Tailscale on your client and join the same tailnet; the VPS appears as `<vps>.<tailnet>.ts.net`.

### Connecting (ssh / mosh / tmux / claude)

```sh
ssh core@<vps>.<tailnet>.ts.net      # or the 100.x tailnet IP
mosh core@<vps>.<tailnet>.ts.net     # roaming-resilient; install via brew
```

- **Key-only**: your keys come from `github.com/oso-gato.keys` (Day-0 sync). On macOS, store them in 1Password and use its SSH agent — see [macOS section](#macos--log-in-via-the-1password-ssh-agent) below.
- **tmux**: every login auto-attaches a tmux session named after the authenticating key (`oSo`/`Alchemist`/`Fatima`). Sessions persist across disconnects and outlive box rebuilds and tailscaled restarts. Detach with `Ctrl-b d`; reattach by logging in again or `tmux attach -t <name>`. All keys share one tmux server, so `tmux attach -t oSo` hops between devices' sessions.
- **`passwd core`** (Day 0) set the password for sudo and Cockpit. SSH stays key-only.

### Claude Code — just `claude`

```sh
claude          # enters claudebox; runs Claude Code in your current directory
```

First run prints a one-time OAuth URL (open in your browser, paste the code back). Everything runs inside `claudebox`; the wrapper handles the entry. For a shell inside the box: `distrobox enter claudebox`.

### Cockpit — web console (tailnet-only)

A browser dashboard for the host: podman containers, files, networking, SELinux, logs, terminal.

**Why it's here (design rationale).** Cockpit is the **deliberately-chosen management interface** for this headless VPS, not an incidental install. Fedora Server is headless by design — no GUI, only a text console — and [Cockpit](https://cockpit-project.org/) is the project's official answer for remote administration: an *"easy-to-use, integrated, glanceable, open web-based interface for your servers"* that **uses the system's own APIs and CLI tooling** (no parallel agent, no drifting state), is reachable from any browser on any OS, makes the host discoverable without memorising commands, and — decisive for a minimal host — has **zero idle footprint**: it doesn't run in the background; `cockpit.socket` activates it on demand via systemd socket activation. The `cockpit` aggregator metapackage is therefore a *recorded* Build Principle 4 exception (its hard deps are exactly the console core; add-in Recommends are blocked by `install_weak_deps=False`).

- Reachable **only over the tailnet** — by design (Build Principle 7): `cockpit.socket` is bound to loopback and the sole ingress is the tailscale-serve proxy. It is **never** published on the public IP.
- **One-time tailnet setup**: in the Tailscale admin console enable **DNS → MagicDNS** and **HTTPS Certificates**. Within ~60s the host auto-publishes Cockpit.
- **Open** `https://<vps>.<tailnet>.ts.net/`, log in as `core` with your `passwd core` password.

### What auto-updates, and when

| Layer | Cadence | Trigger | Behavior |
|---|---|---|---|
| Host OS packages | Monthly, 15th | `dnf-automatic.timer` | applies updates, **never reboots** (you decide; a login notice fires when needed) |
| claudebox (CLI + tools) | Daily, ~04:00 | in-host `claudebox-rebuild-daily.timer` | defers if a `claude` session is active; rebuilds on next session exit |
| Workload containers (fedora-dev, etc.) | Monthly, 15th @ 04:00 ± 2h | `workload-refresh@<name>.timer` | pulls latest from GHCR, recreates only if changed; defers via the in-container busy probe while a `claude` session (or box rebuild) is live; **resumes on the hourly retry timer once idle — NOT on session exit**; rolls back to the prior digest if the new image fails its healthcheck |
| Major Fedora release jump (44→45) | Manual | `dnf system-upgrade` you run by hand | deliberate, separate; see "Fedora Cloud Update" above |

**Force a refresh now**:
- claudebox: run `claudebox-rebuild` (host or in-box; in-box triggers via flag file).
- Workload container: `systemctl --user start workload-refresh@<name>.service` (still respects busy probe).

Watch any rebuild: `journalctl --user -u claudebox-rebuild-run -f` or `journalctl --user -u workload-refresh@<name>.service -f`.

> **Does quitting a session trigger a deferred update?** For the **daily claudebox rebuild** — yes: the deferred rebuild fires the moment you exit (the `claude` wrapper does it). For the **monthly whole-container refresh** — no: quitting does not advance it; it re-attempts on the next **hourly retry** (`workload-refresh-retry@<name>.timer`, ±15m) once the in-container busy probe sees the box idle. So quitting accelerates the box rebuild, not the monthly container refresh.

### Tailscale routing (LAN access + exit node)

Defaults: the VPS advertises itself as an exit node AND accepts subnet routes from the tailnet. Each capability needs a one-time admin-console approval beyond what the host does:

| Goal | One-time action | Where |
|---|---|---|
| Reach the LAN through the VPS | Approve the router's advertised CIDR | admin console → Machines → *the LAN router* → approve route |
| Reach the LAN through the VPS | Ensure IP forwarding is on the LAN router (not this VPS) | the router host |
| Use this VPS as an exit node | Approve the exit node | admin console → Machines → *this VPS* → Edit route settings → ✓ Use as exit node |
| Use this VPS as an exit node | Opt in per client device | `tailscale set --exit-node=<vps> --exit-node-allow-lan-access` on each |

**Zero-touch approval (skip the console click).** "Approve the exit node" above is manual because an interactively-joined node isn't trusted to self-approve. To eliminate it fleet-wide, join hosts with a **tagged** auth key (`TS_AUTHKEY=tskey-…` carrying e.g. `tag:server`) and add an `autoApprovers` rule to the tailnet policy file (admin console → Access controls):

```json
"autoApprovers": {
    "exitNode": ["tag:server"]
}
```

A `tag:server` host that advertises an exit node is then approved automatically at join — no per-host click. Caveat (Tailscale): auto-approval only fires when the tailnet *first* receives the advertisement, so the tag must be present at join — use the `TS_AUTHKEY` path, not interactive login, for those hosts.

To run a containerized service as its own tailnet device (its own MagicDNS name): use the official `tailscale/tailscale` image in userspace mode with `TS_AUTHKEY` + `TS_HOSTNAME` + persistent `TS_STATE_DIR` volume. Don't advertise container subnets from the VPS.

### macOS — log in via the 1Password SSH agent

Keep private keys in 1Password; let its SSH agent answer the auth challenge. The private half never touches disk; `ssh core@<host>` just works (1Password prompts for Touch ID).

1. **Turn on the agent.** 1Password → **Settings → Developer → Use the SSH Agent**. Also enable **Keep 1Password in the menu bar** + **Start at login**.

2. **Point ssh at the 1Password agent for every host** in `~/.ssh/config`:

   ```
   Host *
     IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
   ```

   (Don't put `User core` under `Host *` — type `core@` explicitly so github.com and other hosts aren't affected.)

3. **Pick which identity this Mac uses** (optional, in `~/.config/1Password/ssh/agent.toml`). The host allowlists three keys (`oSo`, `Alchemist`, `Fatima`); the first one the agent offers that the server accepts authenticates and decides which tmux session you land in.

   ```toml
   # ~/.config/1Password/ssh/agent.toml — local to THIS Mac
   [[ssh-keys]]
   item = "oSo"          # offered first → this machine authenticates as oSo
   [[ssh-keys]]
   item = "Alchemist"
   [[ssh-keys]]
   item = "Fatima"
   ```

   Each Mac gets its own file (the keys sync; this ordering doesn't). Reorder per device to make its identity win.

4. **Log in**: `ssh core@<host>` — Touch ID for the matching key, then you're in.

Verify the agent is offering your keys in order: `ssh-add -l`.

---

## Notes

- Tested design, not yet host-tested: this repo's first run on a real Fedora Cloud instance is its acceptance test (`verify.sh`). Built from live-verified facts (2026-06-12): distrobox 1.8.x assemble syntax, host-spawn rpm in Fedora repos, /run/user shared into the box, fedora-toolbox:44 image, Anthropic rpm repo.
- Distrobox 2.0 (Go rewrite) is in RC: same manifest/CLI interface promised; re-verify on Fedora's first 2.0 ship.
- The future `cage` profile (truly contained box for autonomous runs: no shared `$HOME`, egress allowlist) is documented intent, not yet built.

---

## Appendix — Design overview

A PRD-style summary of what this repo is trying to be. Implementation rules and binding tables (Build Principles, Files inventory, full Packages table) live in [CLAUDE.md](CLAUDE.md).

### Requirement

Turn a fresh Fedora Cloud VPS into a container-as-app fleet that an LLM agent operates with minimal human babysitting, where:

- The host is treated-as-immutable: only containers carry state
- Every container is built elsewhere (its own repo + CI → GHCR), pulled here
- The agent has the smallest privilege set it can operate with
- Updates are autonomous but never destructive of in-flight work

### Design principles

1. **Host immutability & minimal packages.** A short fixed package list is the complete sanctioned host footprint. Anything else runs in a container. Growing the list requires an explicit waiver recorded in CLAUDE.md's Build Principles. Within the list, always install the most specific (leaf) package rather than a convenience metapackage — `install_weak_deps=False` blocks optional Recommends but not a metapackage's hard Requires, so a metapackage can silently pull components you never use. Use a metapackage only for a recorded architectural reason; when in doubt, verify its hard deps and flag for review.
2. **Container-as-app.** Each major function is its own image with its own repo, CI, and Quadlet. An image that exists only on this host (no repo, no CI behind it) is drift.
3. **Two-agent pipeline.** Dev containers BUILD images; host claudebox DEPLOYS them. Strict separation; the boundary is enforced by per-agent `policy/CLAUDE.md` rules.
4. **Least privilege, kernel-enforced.** `core` user is password-gated `wheel` admin; in-box agent has scoped passwordless sudo for exactly the pinned commands in `policy/sudoers.claudebox` (currently `tailscale serve` loopback + read-only `tailscale status`). Everything else is OS-blocked.
5. **Self-updating with safety.** Refreshes respect a busy-probe (don't kill mid-flight Claude work or in-flight box rebuilds) and roll back automatically on healthcheck failure.
6. **Propose-and-commit.** Any change to setup, policy, or workload list flows through this repo's git history (PR + `setup.sh` re-run). Ad-hoc changes vanish on next setup.

### Outcomes achieved

- Fresh VPS → fully operational in one orchestrated script + one `passwd core`.
- Monthly host OS updates without intervention; no surprise reboots.
- Daily Claude Code refresh without yanking active sessions.
- Monthly workload-container updates with rollback on failure, busy-deferred when needed.
- Image-source compromise window bounded by next refresh; cosign signature path scaffolded for opt-in once every workload CI signs.
- Agent and human operator have OS-enforced privilege boundaries; the agent literally cannot modify the host outside its scoped allowlist.

### Where to look next

| Looking for | Where |
|---|---|
| Detailed binding rules for editing this repo (Build Principles + Files inventory + Release procedure) | [CLAUDE.md](CLAUDE.md) |
| The host agent's runtime law (its role, do/don't, fleet contract, refresh mechanism) | [policy/CLAUDE.md](policy/CLAUDE.md) |
| Per-package justification (host + box) | [CLAUDE.md](CLAUDE.md) Packages table |
| Scoped sudo allowlist | [policy/sudoers.claudebox](policy/sudoers.claudebox) |
| Refresh script + busy probe internals | [container-refresh.sh](container-refresh.sh), [claudebox-busy-probe.sh](claudebox-busy-probe.sh) |
| Workload Quadlet template (in each workload container's repo) | e.g. [oso-gato/fedora-dev's `fedora-dev.container`](https://github.com/oso-gato/fedora-dev/blob/main/fedora-dev.container) |
