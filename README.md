# fedora-bootstrap

Version: **1.1.8** — host-claudebox policy gains HOW DO I... operational-recipes section (refresh workload, add to fleet, check fleet status, investigate deferring, rollback-via-SURFACE, propose change, signature-flip-via-SURFACE). Self-audited recipes against role boundaries — two recipes reframed from imperative-action to SURFACE-to-operator to honor busy-probe + propose-and-commit doctrine.

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

- Reachable **only over the tailnet** — `cockpit.socket` is bound to loopback; the only ingress is the tailscale-serve proxy.
- **One-time tailnet setup**: in the Tailscale admin console enable **DNS → MagicDNS** and **HTTPS Certificates**. Within ~60s the host auto-publishes Cockpit.
- **Open** `https://<vps>.<tailnet>.ts.net/`, log in as `core` with your `passwd core` password.

### What auto-updates, and when

| Layer | Cadence | Trigger | Behavior |
|---|---|---|---|
| Host OS packages | Monthly, 15th | `dnf-automatic.timer` | applies updates, **never reboots** (you decide; a login notice fires when needed) |
| claudebox (CLI + tools) | Daily, ~04:00 | in-host `claudebox-rebuild-daily.timer` | defers if a `claude` session is active; rebuilds on next session exit |
| Workload containers (fedora-dev, etc.) | Monthly, 15th @ 04:00 ± 2h | `workload-refresh@<name>.timer` | pulls latest from GHCR, recreates only if changed, defers via in-container busy probe; hourly retry if deferred; rollback to prior digest if new image fails healthcheck |
| Major Fedora release jump (44→45) | Manual | `dnf system-upgrade` you run by hand | deliberate, separate; see "Fedora Cloud Update" above |

**Force a refresh now**:
- claudebox: run `claudebox-rebuild` (host or in-box; in-box triggers via flag file).
- Workload container: `systemctl --user start workload-refresh@<name>.service` (still respects busy probe).

Watch any rebuild: `journalctl --user -u claudebox-rebuild-run -f` or `journalctl --user -u workload-refresh@<name>.service -f`.

### Tailscale routing (LAN access + exit node)

Defaults: the VPS advertises itself as an exit node AND accepts subnet routes from the tailnet. Each capability needs a one-time admin-console approval beyond what the host does:

| Goal | One-time action | Where |
|---|---|---|
| Reach the LAN through the VPS | Approve the router's advertised CIDR | admin console → Machines → *the LAN router* → approve route |
| Reach the LAN through the VPS | Ensure IP forwarding is on the LAN router (not this VPS) | the router host |
| Use this VPS as an exit node | Approve the exit node | admin console → Machines → *this VPS* → Edit route settings → ✓ Use as exit node |
| Use this VPS as an exit node | Opt in per client device | `tailscale set --exit-node=<vps> --exit-node-allow-lan-access` on each |

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

1. **Host immutability.** A short fixed package list is the complete sanctioned host footprint. Anything else runs in a container. Growing the list requires an explicit waiver recorded in CLAUDE.md's Build Principles.
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
