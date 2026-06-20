# fedora-bootstrap

Version: **1.2.5** — Fix: `verify.sh`'s `host: fail2ban active (sshd jail)` check no longer false-FAILs on the normal (unprivileged `core`) bring-up path — the root-only `fail2ban-client status sshd` query is gated on euid (full daemon+jail check when root, daemon-active check when `core`). No host behavior change. Prior: v1.2.4 — genesis/mother-platform role + `fedora-dev` maintainership; v1.2.3 — docs Day-0 boot-stage table; v1.2.2 — agent-recipe alignment; v1.2.1 — agent maintainership (push to `main` + tag; host-apply stays operator-gated).

## Purpose

`fedora-bootstrap` turns a fresh Fedora Cloud VPS into a **container-as-app fleet** operated by an in-box Claude Code agent. The host stays minimal and treated-as-immutable; every application function runs in a container pulled from `ghcr.io/oso-gato/*`.

The host's claudebox is the **genesis agent** of this platform — the first claudebox brought up, running *on* the host. Its standing purpose is two-fold:

1. **Operate + maintain the mother platform** — the host itself, which runs every current and future containerised workload. It deploys and operates workload images and keeps the host sound. It **never builds** images (CI does) and **never applies** host changes itself (the operator re-runs `setup.sh` as root).
2. **Develop + maintain the foundation's source** — it directly maintains (commit, push to `main`, tag) **`fedora-bootstrap`** (the host's own machinery) and **`fedora-dev`** (the first workload image, and the template every later workload follows), so the ongoing container workflow keeps evolving from a maintained base.

Every *other* workload image's source is developed and built in that image's own dev container (`debian-dev`, …) and is **surface-only** to the host claudebox. For **all** images — including the two the host claudebox maintains — the build/deploy handoff is one-way and unchanged:

image source → pushed to GitHub → CI builds + publishes to GHCR → host claudebox pulls and recreates via the workload-refresh harness (monthly).

Maintaining a repo's source is never the same as building its image (CI's job) or deploying it (the pull): the host claudebox writes source and pulls images; it never `podman build`s and never hand-deploys.

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

As root on a fresh Fedora Cloud instance (take a Hostinger snapshot first — the last line reboots the host into the automated SELinux convergence):

```sh
dnf -y upgrade --refresh
dnf -y install git
git clone https://github.com/oso-gato/fedora-bootstrap /opt/fedora-bootstrap
if /opt/fedora-bootstrap/setup.sh < /dev/null; then
  echo 'setup: all layers PASS.'
else
  echo '*** investigate the failure (login.tailscale.com link? scoped sudoers? see verify.sh output above) and re-run /opt/fedora-bootstrap/setup.sh < /dev/null'
fi
passwd core && reboot   # REQUIRED — set core's admin/sudo + Cockpit/console password; on SUCCESS the host reboots to launch the v1.2.0 SELinux convergence (runs hands-off from there). A mismatched/cancelled passwd does NOT reboot — just re-run this line.
```

The `< /dev/null` on `setup.sh` is load-bearing: it keeps setup from reading the terminal so your pasted `passwd core` line isn't swallowed. `passwd core && reboot` makes the one unavoidable manual step (the password — never stored in the repo) also the trigger: on a successful set, the host reboots and the SELinux chain takes over (relabel → soak → enforcing → post-enforce check, two further automatic reboots on the happy path, ~20–25 min; an unhealthy enforcing boot auto-reverts to permissive with one more). `setup.sh` itself never reboots; the reboot lives in your command, gated on the password. To stay permissive instead, run `SELINUX_TARGET=permissive /opt/fedora-bootstrap/setup.sh < /dev/null` and drop the `&& reboot`.

`setup.sh` is fully idempotent. It runs as root and orchestrates two layers in their correct identities:

1. **System layer** (`setup-host.sh`, as root): host packages, `/etc`, system services, tailnet, dnf-automatic, creates `core` user + rootless prerequisites.
2. **Rootless layer** (`setup-user.sh`, as `core`): user podman socket, ssh keys synced from `github.com/oso-gato.keys`, claudebox assembled from `distrobox.ini`, Claude policy stamped, workload-refresh harness enabled, verify.

The only interactive pause: the tailscale auth link (one-time per host). Open the URL printed in the output, approve, then re-run setup.sh.

**Host naming:** the VPS names itself `erebus` (override with `BOOTSTRAP_HOSTNAME=<name>`). `hostnamectl` sets it; a cloud-init drop-in pins it across reboots.

**Default networking:** the host comes up advertising itself as a Tailscale **exit node** AND **accepting LAN routes** the tailnet advertises. Turn either off with `TS_EXIT_NODE=0` / `TS_ACCEPT_ROUTES=0` before setup. Each capability also needs one-time admin-console approval (Tailscale → Machines).

> **Security note:** with accept-routes ON, the in-box Claude Code can reach your LAN. Scope its access via tailnet ACLs (tag the VPS, grant only specific hosts/ports — never the bare `/24`).

#### What unfolds after that reboot — boots, stages, and when the workload lands

The convergence above is also when the fleet first comes up — hands-off, with no `podman` command from you. `setup.sh` does **not** start `fedora-dev.service`; `setup-user.sh` installs `fedora-dev`'s Quadlet and enables **only** the `workload-refresh@`/`-retry@` timers, and it does so *after* the setup boot has already reached `default.target`. So the workload's first pull is deferred to the first full multi-user boot that reaches `default.target` with the Quadlet already present — the **permissive soak boot** — driven by the Quadlet's `WantedBy=default.target` and `core`'s lingering user manager. The default enforcing happy path is 1 manual + 2 automatic reboots (4 boots):

| Boot (relative) | Reboot into it | SELinux mode | What the host does | `fedora-dev` state |
|---|---|---|---|---|
| **Setup boot** | — (you run `setup.sh`) | `disabled`/`permissive` (config set to `permissive`; effective next boot) | host packages, `/etc`, services, tailnet, `core` + linger; arms the convergence chain + `/.autorelabel`; `setup-user.sh` installs the Quadlet **after** `default.target` and enables only the refresh/retry timers; prints `ACTION REQUIRED: REBOOT` | **not started** — Quadlet present but `default.target` already passed; **no pull, no volumes** |
| **Relabel boot** (~seconds) | manual (your `passwd core && reboot`) | `permissive` | the stock `selinux-autorelabel` relabels the whole filesystem, clears `/.autorelabel`, and self-reboots — it runs early and reboots before `default.target`, so the workload's start never fires here | **not started** — no `default.target`, **no pull** |
| **Permissive soak boot** (~15 min floor) | automatic (autorelabel self-reboot) | `permissive` (labeled) | first full `default.target` boot **after** the Quadlet landed → `core`'s user manager starts `fedora-dev.service`; a ~15-min fail-closed soak gate (critical services up, zero AVC denials) then flips `SELINUX=enforcing` and reboots | **first pull + start** — `Pull=missing` fetches `ghcr.io/oso-gato/fedora-dev:latest` and **creates** the `fedora-dev-home`/`-state` volumes; the container goes healthy |
| **Enforcing boot** | automatic (soak gate passed) | `enforcing` (labeled) — steady state | boots enforcing against the now-labeled filesystem; the post-enforce health gate passes → writes `selinux-chain.enforced` and **self-disarms** the chain; no further reboots | **re-created** — fresh instance, **named volumes persist**, `Pull=missing` reuses the local image (**no re-pull**) |

> **Why the soak boot, not the setup boot:** the deferral is by design, not host-incidental — `setup-user.sh` enables the refresh timers (not the service) and lands the Quadlet *after* `default.target`, so the first `default.target` boot that sees the Quadlet is the soak boot. The container is **re-created on every later `default.target` boot** (including the enforcing one); volumes persist by name and `Pull=missing` means no re-pull and no data loss. The same persist-across-recreate behavior backs the monthly `workload-refresh` restart (which additionally pulls + digest-compares first).

> **Variants** (the table is the default `SELINUX_TARGET=enforcing` happy path): `SELINUX_TARGET=permissive` drops the enforcing flip — **one fewer reboot** (1 manual + 1 automatic, 3 boots), and the first pull lands in the permissive *steady-state* boot rather than a soak boot. An **unhealthy enforcing boot auto-reverts** to permissive with **one extra reboot** (writes `selinux-chain.rolled-back`, no loop); the workload was already first-pulled in the soak boot and is simply re-created across the revert with volumes intact.

### Upgrading an existing host to a new release

Each release below has one self-contained code block to paste into the VPS root terminal. Find your target version and follow its subsection — that's the entire upgrade.

> The rules governing what goes in each per-version subsection live in [CLAUDE.md](CLAUDE.md) (agent-facing).

> **Older upgrade paths (v1.1.1 – v1.1.14)** are archived in **[UPGRADING.md](UPGRADING.md)** to keep this file scannable. The latest release(s) follow; the v1.0.0-baseline guarantee means the most recent subsection takes a fresh host straight to current.

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
3. **Build/deploy separation (genesis agent).** Images are always BUILT in CI (never `podman build` on the host) and DEPLOYED by the host claudebox via the pull. The host claudebox is the genesis agent: it operates the host AND maintains the *source* of `fedora-bootstrap` + `fedora-dev` (commit/push/tag); every *other* image's source is developed in that image's own dev box and is surface-only to it. The invariant the `policy/CLAUDE.md` rules enforce is **build-in-CI + maintainership scope** (which repos the agent may push), not a strict develop-vs-deploy agent split.
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
