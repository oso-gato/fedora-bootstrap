# fedora-bootstrap

Version: **1.1.3** — workload-container refresh harness (v1.1.1); "Upgrading an existing host" convention (v1.1.2); convention section restructured to pure prose so the per-version code block is the unambiguous copy-paste target (v1.1.3).

## Purpose

`fedora-bootstrap` provisions a Fedora Cloud host and installs the **host's
claudebox** — the Claude Code agent that operates the container fleet on
that host. It is one half of a strict two-agent pipeline:

- **the host's claudebox** (this repo's product) — where Claude Code DEPLOYS
  and OPERATES container images on the Fedora VPS. Pulls images from
  `ghcr.io/oso-gato/<name>:latest`, recreates running containers from each
  image's `run.sh` via the workload-refresh harness, manages the systemd
  user units that keep them healthy. It NEVER builds images.
- **`fedora-dev`** (and future `debian-dev`, downstream image repos) — where
  Claude Code DEVELOPS and VALIDATION-BUILDS those images. Their output is
  pushed git commits; CI publishes to GHCR.

The handoff is one-way and explicit:

```
image source developed in fedora-dev → pushed to GitHub → CI builds →
ghcr.io/oso-gato/<name>:latest → the host's claudebox pulls + recreates
via the workload-refresh harness on a monthly cadence
```

A container running on the host with no published image, no repo, and no CI
behind it is drift. Don't create them. If a task appears to require building
or modifying the source of an image, that work belongs to the image's own
claudebox (inside `fedora-dev` for Fedora-based images, inside `debian-dev`
for Debian-based) — not here.

## Fedora Cloud Update

<!-- HOSTINGER_STATUS_START : auto-generated every Friday by .github/workflows/refresh-release.yml — do not edit by hand -->
**Hostinger's Fedora Cloud is 44 — yes, it's the latest release.** You can ignore the version-upgrade steps in this section and skip straight to **Day 0** below.
<!-- HOSTINGER_STATUS_END -->

Cloud images can ship behind current Fedora; when a provider lags, the status line
above says how far behind, and you bring the host current **before** running `setup.sh`
(the Packages table and vendor repos are validated against the latest stable). That
status is refreshed every Friday by [`refresh-release.yml`](.github/workflows/refresh-release.yml);
either way, the `dnf upgrade --refresh` folded into **Day 0** still freshens packages.

Both blocks below run Fedora's official **DNF system-upgrade** flow, which is
**built into dnf5** (Fedora ≥ 41 — there is no plugin to install). Fedora supports
jumping at most **two releases** at once (N → N+2), exactly the cloud-image gap.
Only `curl` is needed, and it ships by default on Fedora Cloud (as `curl-minimal`).
Pick whichever you prefer — they reach the same place.

**Option 1 — self-updating (never edit this one).** Reads the latest GA straight
from Fedora's official, Beta-safe
[`releases.json`](https://fedoraproject.org/releases.json) (GA shows as a bare
integer like `"44"`; the regex matches only purely-integer `version` values, so any non-GA/pre-release entry (not a bare integer) is ignored and an integer-only `max` never lands
on a pre-release) and caps the jump at +2:

```sh
( set -e
  cur=$(rpm -E %fedora)
  # latest stable GA, straight from Fedora's official release data (Beta-safe)
  latest=$(curl -fsSL https://fedoraproject.org/releases.json \
            | grep -oE '"version": *"[0-9]+"' | grep -oE '[0-9]+' | sort -rn | head -1)
  : "${latest:?could not reach fedoraproject.org to detect the latest release}"
  # Fedora supports at most a two-release jump (N -> N+2); cap there
  target=$(( latest - cur > 2 ? cur + 2 : latest ))
  echo "Current: Fedora $cur | latest stable: Fedora $latest | this pass -> Fedora $target"
  [ "$target" -gt "$cur" ] || { echo "Already on the latest stable release - nothing to do."; exit 0; }
  sudo dnf upgrade --refresh
  sudo dnf system-upgrade download --releasever="$target"
  sudo dnf system-upgrade reboot
)
```

**Option 2 — pinned (kept current for you).** The release number is spelled out so
you see exactly where you're going. You never edit it either: the `--releasever`
below is **auto-bumped to the latest stable every week** by
[`.github/workflows/refresh-release.yml`](.github/workflows/refresh-release.yml),
which re-reads `releases.json` and commits the new number only when it changes —
so this block is never stale:

```sh
sudo dnf upgrade --refresh
sudo dnf system-upgrade download --releasever=44   # fedora-stable — auto-bumped weekly
sudo dnf system-upgrade reboot
```

Both reboot the host **twice** — once to apply the offline transaction, once into
the new release — unreachable for a few minutes in between. Append `-y` to the
`dnf` lines for an unattended run. If a cloud image is ever more than two releases
behind, run the block again for the next +2 step. Then carry on to **Day 0** below.

## Objective

**Turn a fresh Fedora Cloud host into my standard container host — in one
script.** The host itself stays as close to immutable as possible: it runs
Podman containers, and everything else (including the Claude Code that
manages it) lives in containers or in the disposable `claudebox` Distrobox.
Built and pinned for **Fedora Cloud Base 44** <!-- OBJECTIVE_PIN: kept in lockstep with distrobox.ini's fedora-toolbox tag by refresh-release.yml; the weekly run flags when a newer stable ships so the pin is bumped deliberately (Build Principles 1 & 3) -->; Workstation
and Atomic hosts work as documented secondary paths.

## The ecosystem this host anchors

1. **What the Fedora host does**
   - **It spins up from this repo**: four root commands (Day 0 below), one
     script, two clicks — then it is fully equipped.
   - **It runs containers**: every major function is a Podman container
     pulled from `ghcr.io/oso-gato/*` — nothing is installed onto the host
     itself beyond this bootstrap's short, fixed package list.
   - **It has claudebox to manage itself**: a Distrobox containing Claude
     Code whose sole mission is host orchestration — pulling images,
     spinning containers up and down, writing quadlets and runtime
     configuration. It never builds, never develops, and treats the host as
     immutable (policy/CLAUDE.md is the binding law, stamped into the box).
   - **Every major function is a Podman container**, each from its own
     GitHub repo with binding Build Principles, built by CI, published to
     GHCR, pulled here. An image that exists only on this host is drift.
   - **It has two development environments** — `debian-dev` (.deb/apt
     world) and `fedora-dev` (RPM/dnf world) — containers where images and
     projects are developed and validation-built with nested podman, then
     pushed to GitHub for CI to build. Development never happens on the
     host or in claudebox; deployment never happens from the dev boxes.
   - **It carries my personal universe and second brain**: the desktop
     containers (fedora-xrdp, fedora-tigervnc, fedora-kasm,
     debian-kasm-tigervnc) run Claude Code with two primary interfaces —
     **VS Code is the primary interface for the personal universe** (code,
     projects, terminals), and **Obsidian is the primary interface for the
     second brain** (the knowledge vault Claude Code reads and writes).
     Sessions survive disconnects (RDP KillDisconnected / tmux).

2. **Remote access**

   | Door | From the public internet | From the tailnet |
   |---|---|---|
   | Host shell (ssh, mosh) | yes — key-only | yes (+ keyless Tailscale SSH) |
   | Desktops (web: KasmVNC / noVNC / Guacamole) | yes — TLS + password | yes |
   | Desktops (native RDP / VNC) | no | yes |
   | Dev containers (ssh, mosh, Tailscale SSH) | no | yes |
   | Cockpit | no | yes (tailscale serve) |

   The public IP exposes exactly two surfaces: the host's hardened shell
   and the desktops' TLS web doors — and Guacamole already delivers a full
   RDP session in the browser, so nothing native needs exposing. Every
   shell login, on any door, lands in a persistent per-device tmux session (named by the authenticating key).

## Day 0 — fresh VPS, root terminal

The only manual steps. As root on a fresh Fedora Cloud instance:

```sh
dnf -y upgrade --refresh        # freshen ALL packages first (already-latest hosts no-op the release-upgrade above)
dnf -y install git
git clone https://github.com/oso-gato/fedora-bootstrap /opt/fedora-bootstrap
if /opt/fedora-bootstrap/setup.sh < /dev/null; then
  echo 'setup: all layers PASS.'
else
  echo '*** setup did NOT finish all-PASS. If it printed a login.tailscale.com link,'
  echo '*** open it once, then re-run as root:  /opt/fedora-bootstrap/setup.sh < /dev/null'
  echo '*** Otherwise fix the cause shown above and re-run the same command.'
fi
passwd core      # REQUIRED — sets core's admin (password-gated sudo) + Cockpit/console password; SSH stays key-only
```

`setup.sh` runs **as root** and orchestrates the two privilege layers (see **Privilege
layers** below): it runs the SYSTEM phase (`setup-host.sh`) as root — host packages, `/etc`,
system services, the tailnet, and **creating the `core` user** — then drops to `core` for the
ROOTLESS phase (`setup-user.sh`). The repo is cloned by root into `/opt/fedora-bootstrap`
because it is the host's provisioning definition (root-owned), and because `core` does not
exist yet when the clone runs. To name the operating user something other than `core`, set
`BOOTSTRAP_USER=<name>` before `setup.sh` — it's created fresh (or reused if it already exists) as a
password-gated `wheel` admin. Either way the bootstrap **strips cloud-init's default-user blanket
`NOPASSWD:ALL`** (`/etc/sudoers.d/90-cloud-init-users`), so reusing or colliding with a cloud image's
default user (e.g. `fedora`) can never smuggle passwordless root past the scoped-sudo model. The VPS comes
up as an **exit node** and **accepting LAN routes by default** — set `TS_EXIT_NODE=0` / `TS_ACCEPT_ROUTES=0`
to turn either off — see **Tailscale routing** below (each still needs a one-time admin-console approval).

The host **names itself `erebus`** (override with `BOOTSTRAP_HOSTNAME=<name>`). This sets the static
hostname via `hostnamectl` and — the part that actually makes it stick on a cloud image — installs a
`/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg` drop-in with `preserve_hostname: true`, so cloud-init
doesn't revert the name to `srvNNN` on the next boot. It's purely the OS's local identity: Hostinger's
external `srvNNN.hstgr.cloud` forward/reverse DNS is separate and unaffected (you still reach the box at
that name or its tailnet name; you can't make `erebus.hstgr.cloud` resolve — that subdomain is
Hostinger's to assign). No `/etc/hosts` edit is needed — Fedora's `nss-myhostname` resolves it. The name
survives reboots; only a Hostinger panel **rebuild/reinstall** (which wipes the disk) resets it to `srvNNN`
until you re-run `setup.sh`. (Because the hostname is set before `tailscale up`, a fresh tailnet join also
takes the name — so the box appears as `erebus.<tailnet>.ts.net`.)

The first `dnf upgrade` freshens every package (an already-latest host no-ops the
release-upgrade section above, so this is where it still gets current). If it pulls a new
kernel or systemd and you want them live first, `reboot`, then run the rest.

**`core` is a full `sudo` admin** — it is in `wheel`, so `sudo` works once you set its
password with `passwd core` (required: that is `core`'s admin/sudo password, not just
Cockpit's). There is **no blanket `NOPASSWD:ALL`**; instead a **scoped** passwordless
allowlist (`policy/sudoers.claudebox` → `/etc/sudoers.d/claudebox`) lets `core` run a few
specific host commands without a password — currently an **exact-pinned** `tailscale serve`
loopback proxy (`…http://127.0.0.1:9090`) plus read-only `tailscale status` (no wildcards, no
`funnel`), so the in-box Claude Code can re-assert / read the tailnet exposure of Cockpit (the one pinned loopback port; exposing any other port it deploys needs a new exact-pinned line you commit). Every *other* `sudo` needs the
password: a human admin types it (the Fedora default), while the unattended in-box agent —
which has no password — is OS-blocked. So after Day 0, `root` is retired and `core` runs
everything; you `sudo` (with the password) for host changes, the agent only for its narrow
allowlist (and even then it asks you first). To let the agent do more, grow the allowlist by
committing to `policy/sudoers.claudebox` — see **Privilege layers** and `policy/CLAUDE.md`.

`setup.sh` runs **as root** and is idempotent. It splits into two layers: the **system**
phase (`setup-host.sh`, as root — the hostname, packages, the `core` user, system services, the
ssh drop-in, tailscale, the tmux drop-in, and `core`'s user manager) and the **rootless** phase
(`setup-user.sh`, as `core` — podman socket, ssh keys, claudebox assemble, Claude policy,
verify). It pauses at most once during the run: the tailscale auth link (once
per host; open it, then re-run setup.sh). Claude Code is installed but NOT logged
in by setup.sh — the first time you run `claude` (the wrapper in ~/.local/bin) you
complete OAuth once. On this headless VPS that first run prints a login URL: open
it in your Mac browser, approve, and paste the returned code back into the SSH
session; for unattended use mint a token with `distrobox enter claudebox -- claude
setup-token` and export CLAUDE_CODE_OAUTH_TOKEN (a secret — never commit it). Re-run
after any failure; it resumes safely. Rebuild the box anytime by re-running setup.sh
(assemble is declarative; ad-hoc tools inside the box are disposable by design).

**SSH keys & provenance.** The rootless phase pulls your public keys from
`github.com/oso-gato.keys` (GitHub is the registry — no keys in this repo) and writes
`core`'s own `authorized_keys`, tagging each with `environment="LOGIN_KEY=…"` so every
login is attributable to the key that authenticated (`oSo`, `Alchemist`, `Fatima`). Add
or revoke a key on GitHub, then re-run `setup.sh` to resync. The host's tmux drop-in names
each login's session after that tag, so every device lands in its own persistent session
(`tmux attach -t <other>` hops between them). `core` has **no blanket passwordless `sudo`**
(only the scoped `/etc/sudoers.d/claudebox` allowlist); the **required** `passwd core` sets
its admin/`sudo` + Cockpit/console password — a password-gated `wheel` escalation for a human
admin. SSH stays key-only regardless.

## Upgrading an existing host to a new release

### Convention (binding for every future release)

This part is the rules for how upgrade docs get written, not commands to run.
For an actual upgrade, jump to the per-version subsection below.

Every release MUST add a subsection here titled **"Upgrading to vX.Y.Z (from
any prior version)"** — or **"Upgrading to vX.Y.Z (from vA.B.C and later)"**
for breaking releases that require a minimum prior version.

Each subsection contains **one self-contained `sh` block** the operator pastes
into the VPS's root terminal in a single go. The block always has these parts
in order:

- **Standard upgrade flow** (always first, always present): a `cd
  /opt/fedora-bootstrap` → `git pull --ff-only origin main` → `./setup.sh <
  /dev/null` sequence. `setup.sh` is fully idempotent — re-running on an
  existing host picks up new phases, files, units, and policies without
  disturbing existing state. Volumes persist by name; existing systemd units
  are re-stamped, overwriting any drift.

- **Version-specific operator steps** (only when needed): anything `setup.sh`
  can't or shouldn't do on its own — editing secret env files, migrating from
  pre-Quadlet containers, retiring deprecated units, etc. A purely-internal
  release with no operator-visible changes can skip this entirely.

- **Verification**: the exact commands to confirm the upgrade succeeded and
  what their expected output looks like.

- **Rollback recipe**: how to revert to the prior running state if the upgrade
  fails midway.

The standard upgrade flow is **never** broken out as its own code snippet in
this Convention section — it is inlined as the first commands of every
per-version block. That way the operator copies one block, pastes once, runs
to completion. No assembly required at paste time.

### Upgrading to v1.1.1 (from any prior version)

Adds the workload-container refresh harness, Quadlet-based deployment for
`fedora-dev`, image-signature scaffolding, the restructured agent policy.
The pre-v1.1.1 fedora-dev was started via raw `podman run` from `run.sh`;
v1.1.1 replaces that with a Quadlet-generated `fedora-dev.service`. Named
volumes (`fedora-dev-home`, `fedora-dev-state`) persist by name, so all
in-volume state — Claude credentials, gh auth, in-flight projects, nested
podman storage — carries over automatically.

**As root on the VPS:**

```sh
# 1. Standard upgrade flow — picks up v1.1.1 code + new user 4/5 phase
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null

# 2. Populate the new env-file scaffold for fedora-dev's runtime secrets.
#    The Quadlet's EnvironmentFile= requires this file to exist with
#    CORE_PASSWORD set before fedora-dev.service can start. Use the same
#    CORE_PASSWORD you've been using; TS_AUTHKEY optional.
nano /home/core/.config/container-refresh/fedora-dev.env

# 3. Stop the pre-Quadlet fedora-dev container and start the Quadlet'd one.
#    Container name collides; the old must come down before the new can come
#    up. Named volumes persist by name — no data movement needed.
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

**Expected after step 4:**

- `fedora-dev.service` shows `active (running)`; healthcheck transitions to
  healthy within ~30 seconds (`pgrep -x sshd && pgrep -x tailscaled` returns
  zero inside the container).
- Two `workload-refresh@fedora-dev` timers — `.timer` next-fires on the
  upcoming 15th @ 04:00 ± 2h, `-retry@.timer` within the next hour.
- `podman ps` shows fedora-dev as `Up` and `(healthy)`.

**If something fails**, the old container can be brought back manually for
inspection while you fix the issue:

```sh
su - core -c '
    systemctl --user stop fedora-dev.service 2>/dev/null || true
    cd ~/fedora-dev && CORE_PASSWORD=... ./run.sh
'
```

(Replace `CORE_PASSWORD=...` with your actual password. This restores the
pre-Quadlet flow.) Investigate via `journalctl --user -u fedora-dev.service`,
then retry steps 2–4 once the issue is resolved.

## Using the host — get in and work

**Prerequisite — be on the tailnet.** Everything below (SSH, Cockpit, Mosh) is reached over your
**tailnet**, not the public IP. Run Tailscale on your client and join the same tailnet; the VPS appears
as `<vps>.<tailnet>.ts.net`.

**1. Get in — SSH (or Mosh)**

```sh
ssh core@<vps>.<tailnet>.ts.net      # or the 100.x tailnet IP
```

- **Key-only.** Your public keys come from `github.com/oso-gato.keys` into `core`'s `authorized_keys`
  (the 1Password agent answers — see **macOS** below). Tailscale SSH is also on, so from a tailnet
  device the connection is authed by Tailscale per your ACL.
- You land **straight into a tmux session** named after the key that authenticated (`oSo`/`Alchemist`/
  `Fatima`).
- `passwd core` (Day 0) set the password used for **sudo** and **Cockpit**. SSH stays key-only.

**2. tmux — persistent, one session per device.** Every interactive login auto-attaches a tmux session
named after your device key (unkeyed → `main`). Sessions **persist across disconnects** and outlive box
rebuilds / tailscaled restarts. Detach (leave it running): `Ctrl-b` then `d`; reattach by logging in
again, or `tmux attach -t <name>`. All device sessions share one server, so `tmux attach -t oSo` hops
into that device's session.

**3. Mosh — resilient connections.** `mosh` survives roaming, sleep, and flaky links. Install it on your
client (`brew install mosh`), then `mosh core@<vps>.<tailnet>.ts.net`. Mosh runs your login shell, so it
also drops you into your tmux session — **mosh + tmux = double resilience** (mosh rides out network
changes; tmux rides out everything else).

**4. Claude Code — just `claude`.**

```sh
claude          # enters claudebox, runs Claude Code inside it, in your current directory
```

First run prints a one-time OAuth URL (open in your browser, paste the code back). Everything runs
**inside `claudebox`** — see **Inside claudebox** below. (`distrobox enter claudebox` for a box shell.)

**5. Cockpit — the web console (tailnet-only).** A browser dashboard for the host: Podman containers,
files, networking, SELinux, logs, terminal.

- **Reachable only over the tailnet** — `cockpit.socket` is bound to loopback, so the public `:9090` is
  closed; the only ingress is the tailnet `tailscale serve` proxy. You must be connected to Tailscale.
- **One-time tailnet setup:** in the admin console enable **DNS → MagicDNS** and **HTTPS Certificates**.
  Within ~60s the host auto-publishes Cockpit (no re-run, nothing to forget).
- **Open** `https://<vps>.<tailnet>.ts.net/` from a tailnet device; **log in** as `core` with your
  `passwd core` password.

## Inside claudebox — what the agent has

`claudebox` is the **Distrobox container** where Claude Code and its tools live. **Nothing below is
installed on the host** — the host carries only the `claude` + `claudebox-rebuild` wrappers and the
rebuild units. The box is defined declaratively in `distrobox.ini` and built on the first `setup.sh`
run; rebuild it anytime with `claudebox-rebuild` (or it auto-refreshes daily) — see **Staying current**.

| Layer | What | Why |
|---|---|---|
| Base image | `quay.io/fedora/fedora-toolbox:44` (pinned) | Fedora 44 userspace |
| Agent | **`claude-code`** → `/usr/bin/claude`, from Anthropic's official dnf repo (**`latest`** channel) | Claude Code CLI — kept current by the daily box rebuild (day-one model access) |
| Host bridge | `CONTAINER_HOST` → host rootless **podman** socket | drive the host's podman engine from inside the box (socket-based, works headless). Host *command* shims are deliberately omitted — they need `host-spawn` → `flatpak-session-helper`, which isn't running on a headless server; by policy the host is immutable and the agent doesn't run host systemd |
| Dev tools | `git`, `gh`, `tmux`, `podman`, `socat`, `bubblewrap`, `fastfetch` | the agent's toolbox |
| Policy (managed tier) | `/etc/claude-code/CLAUDE.md` + `managed-settings.json` | best-effort deny globs for host installs (defense-in-depth — the real gate is the sudo wall), `disableBypassPermissionsMode`, behavioural rules |

**The nesting:** host → `claudebox` (the container) → Claude Code (the program in it). The box shares
your `/home/core`, so the agent edits the same files you do; `podman` inside the box drives the **host**
engine via `CONTAINER_HOST`, so containers it builds are real host containers, not nested. The agent's
*only* host privilege is the scoped `tailscale serve`/`status` sudo allowlist — every other host change
is OS-blocked by the kernel.

You do **not** enter the box to use Claude. `setup.sh` installs a wrapper at `~/.local/bin/claude` that
runs `distrobox enter claudebox -- bash -lc 'exec /usr/bin/claude "$@"'` — so a bare `claude` enters the
box, sources its login profile (so `CONTAINER_HOST` is set), and execs the real CLI
connected to your terminal, in your current directory. First run is a one-time OAuth (or `distrobox
enter claudebox -- claude setup-token` for a headless token, then export `CLAUDE_CODE_OAUTH_TOKEN` — a
secret, never commit it).

## Staying current — updates

Two independent cadences keep the system fresh without babysitting:

**The box (Claude Code + tools) — rebuilt, three ways.** Claude Code installs from Anthropic's
`latest` channel, and a package-manager install does not self-update, so the box is kept current by
*rebuilding* it: a fresh `distrobox assemble` reinstalls the latest CLI + tools, re-applies the host
bridges + policy, and verifies. **Your Claude login survives** — credentials live in your `$HOME`, not
the disposable box. The rebuild runs detached as a `core` `systemd` user service (so it outlives the
box it replaces), and the triggering terminal streams live progress + a completion message:

1. **Daily** — `claudebox-rebuild-daily.timer` (~04:00) refreshes the box. If a `claude` session is
   active it does **not** interrupt: it defers and rebuilds the moment you next exit. The box never
   drifts; live work is never yanked (concurrent sessions are handled — it only fires once all exit).
2. **Ask Claude** — tell Claude to rebuild; it runs `claudebox-rebuild` inside the box, signalling the
   host via a flag file its `.path` unit watches. This session ends; reconnect with `claude`.
3. **Manual** — run `claudebox-rebuild` on the host; it starts + follows the rebuild inline.

Force one anytime with `claudebox-rebuild`; watch any rebuild with
`journalctl --user -u claudebox-rebuild-run -f`.

**The host (OS packages) — dnf-automatic, monthly.** `dnf5-plugin-automatic` applies host package
updates on the **15th of each month** and **never reboots** (doctrine: a human decides reboots). When
an update needs a restart to take effect, a login notice says so (driven by `dnf needs-restarting`);
reboot at your convenience. A major Fedora jump (44 → 45) stays a deliberate, separate
`dnf system-upgrade` you run by hand.

**Workload containers (`fedora-dev`, `debian-dev`, downstream image containers)
— monthly fleet refresh via Quadlets + claudebox-lock deferral.** Each
workload container is deployed via a podman **Quadlet** (`<name>.container`
shipped at the top of the container's own repo, copied by `setup-user.sh`
to `~/.config/containers/systemd/`). systemd-generator emits `<name>.service`
per container with `Notify=healthy`, `AutoUpdate=registry`, `HealthCmd=`,
`Restart=always` — the standard upstream pattern.

The refresh harness wraps each Quadlet with monthly trigger + busy probe +
digest-compare + Quadlet-driven restart + image-rollback on health failure.
Template-driven across the fleet: one systemd instance template, one probe,
one refresh script. Adding a new workload container is a one-line edit to
`WORKLOAD_CONTAINERS` in `setup-user.sh`; no new files.

The pieces:

| Piece | Generic across the fleet? |
|---|---|
| `~/.local/bin/container-refresh.sh` | yes — busy-probe + pull + digest-compare + `systemctl --user restart <name>.service` (Quadlet drives the restart) + rollback to prior digest on health failure |
| `~/.local/bin/claudebox-busy-probe.sh <name>` | yes — `podman exec --user 1000:1000` into the container, AND-checks the two standard claudebox flocks; exit codes distinguish idle (0) / busy (1) / probe-broken (2) |
| `~/.config/containers/systemd/<name>.container` | per-container Quadlet, shipped from the container's own repo |
| `workload-refresh@<name>.service` + `.timer` | yes — instance template, `%i` substitutes container name |
| `workload-refresh-retry@<name>.service` + `.timer` | yes — `ConditionPathExists`-gated hourly retry with ±15m jitter |

Adding a workload container:

```sh
# 1. Uncomment the line in setup-user.sh's WORKLOAD_CONTAINERS array
# 2. setup.sh re-run (root); the user phase:
#    - clones github.com/oso-gato/<name> into ~/<name>/
#    - copies ~/<name>/<name>.container into ~/.config/containers/systemd/
#    - writes ~/.config/container-refresh/<name>.env scaffold (operator populates)
#    - systemctl --user enable --now workload-refresh@<name>.timer \
#                                    workload-refresh-retry@<name>.timer
# 3. Populate the env file with CORE_PASSWORD (and optional TS_AUTHKEY)
# 4. systemctl --user start <name>.service for first boot
# 5. From the next 15th onward, refresh is automatic with busy-probe deferral
```

The uniform contract every workload container in this fleet must honor:

- Published to **`ghcr.io/oso-gato/<name>:latest`** by its own CI.
- Repo at **`github.com/oso-gato/<name>`** with an executable **`run.sh`** at the top.
- Repo ships a **`<name>.container` Quadlet** at the top — declarative spec the host installs to `~/.config/containers/systemd/`.
- Hosts an in-container claudebox using the **standard claudebox scripts** so
  the lock paths are **`/home/core/.local/state/claudebox/{session,box-rebuild}.lock`**
  inside the container.
- Container's operator user is the generic **`core`** (Build Principle 5).

These are the same conventions fedora-dev follows. Future workload containers
inherit them through their own Build Principles tables.

**Image signature verification.** Scaffolded but defaults to permissive
(`insecureAcceptAnything` for `ghcr.io/oso-gato/*`). fedora-dev signs as of
its `9180a24` commit (cosign keyless via GitHub Actions OIDC, attached to
the immutable manifest digest). Once every workload CI signs, upgrade
`~/.config/containers/policy.json` to `sigstoreSigned` per the comment block
inside it. The scaffolding files — `~/.config/containers/policy.json` and
`~/.config/containers/registries.d/ghcr-io.yaml` — are installed automatically
by `setup-user.sh`.

**Runtime secrets** for each workload container live in
`~/.config/container-refresh/<name>.env` (mode 0600), read by the Quadlet
via `EnvironmentFile=`. `setup-user.sh` creates an empty scaffold; the
operator populates it once with `CORE_PASSWORD` (and optional `TS_AUTHKEY`)
before the first `systemctl --user start <name>.service`.

**Cadence:** 15th of each month @ 04:00 local ± 2h jitter. Hourly retry timer
has ±15m jitter to spread fleet-wide retries across the hour. Trigger
out-of-cadence with `systemctl --user start workload-refresh@<name>.service`
(still respects probe).

**Non-claudebox workloads** (a future database container, etc.) don't fit
this template — they have no claudebox locks to probe. For those, write a
separate `<name>-refresh.service` calling `container-refresh.sh` directly
with a different (or empty) 4th argument. The generic `container-refresh.sh`
is busy-probe-agnostic.

## Privilege layers — what runs as root, what runs as the user

Provisioning is split into two layers by **identity**, matching Fedora/Red Hat's
documented model — root provisions the *system* layer; the unprivileged user owns the
*rootless* layer. `setup.sh` (run as root) orchestrates both.

**Root layer — `setup-host.sh` (runs as root).** The bounded, one-time set of operations
that *genuinely require* root. Nothing here is a persistent root workload — it is host
provisioning, done once:

| Root action | Why it must be root |
|---|---|
| install the host package set (`dnf`) | system packages |
| write `/etc/yum.repos.d/tailscale.repo` (in place, `restorecon`) | system repo file |
| `useradd -m -G wheel core` (+ `/etc/subuid` / `/etc/subgid`) | create the user + its rootless prerequisites |
| `systemctl enable --now sshd cockpit.socket tailscaled` | **system** services |
| write `/etc/ssh/sshd_config.d/…` + reload sshd | system SSH config |
| `tailscale up` / `tailscale serve` | configure the system `tailscaled` daemon |
| write `/etc/profile.d/…` | system-wide login config |
| `loginctl enable-linger core` + start `user@<uid>.service` | bring up `core`'s user manager (the one root→user bridge) |

**User layer — `setup-user.sh` (runs as `core`, no host privilege).** The rootless layer.
The only escalation is *inside* the box (the container's own root, not the host's):

| User action | scope |
|---|---|
| `systemctl --user enable --now podman.socket` | `core`'s own user manager |
| sync `core`'s `~/.ssh/authorized_keys` | `core`'s own file |
| `distrobox assemble` + build claudebox | rootless Podman, `core`'s containers |
| stamp the Claude policy into the box | the box's root, not the host's |
| write `~/.local/bin/claude`; run `verify.sh` | `core`'s own |

**The principles this enforces:**

- **Least privilege.** Each action runs in its native identity. The system phase needs root
  once; the user phase needs no broad host privilege — so `core` carries **no `NOPASSWD:ALL`**.
  A human admin keeps a *password-gated* `wheel` escalation; the in-box Claude Code gets only a
  **scoped passwordless allowlist** (`/etc/sudoers.d/claudebox`, from `policy/sudoers.claudebox`
  — currently an exact-pinned `tailscale serve` loopback proxy + read-only `status`, no wildcards,
  no `funnel`) and is OS-blocked from everything else.
- **Immutable host, enforced by the OS.** Outside its small allowlist `core` has no passwordless
  root, so the Claude Code running as `core` cannot modify the host — the `policy/CLAUDE.md` rule
  "never modify the host" is backed by the kernel, not only the policy file. The agent grows its
  allowlist only by *proposing* a command you commit to `policy/sudoers.claudebox` (the same
  "propose; you commit" model as box packages).
- **No cross-privilege file handoffs.** Privileged files are written *in place* in their
  system directory by root (correct SELinux context); nothing is staged in a `core`-owned
  `/tmp` file and handed to root (the SELinux `tmp_t` mislabel / `curl 23` failure class is
  designed out, not patched).
- **Clean failure domains.** A system failure surfaces in the root phase; a rootless failure
  in the user phase — no SELinux denial masquerading as a user-script bug.

## Tailscale routing — LAN access & exit node

**On by default.** The host comes up advertising itself as an **exit node** and **accepting** the subnet
routes your LAN router advertises — so a bare `setup.sh` run already does the node side. Turn either off per
run with `TS_EXIT_NODE=0` / `TS_ACCEPT_ROUTES=0`. Applied with `tailscale set` (not `up`), so it never
disturbs the `--ssh` join and re-runs are idempotent.

```sh
# default = exit node + accept-routes ON. To opt OUT of either:
TS_EXIT_NODE=0 TS_ACCEPT_ROUTES=0 /opt/fedora-bootstrap/setup.sh < /dev/null
```

| Default | What it does | Disable with | Official basis |
|---|---|---|---|
| accept-routes **ON** | `tailscale set --accept-routes=true` — the host **and the host-netns containers** (claudebox runs with `--network host`, so the in-box agent too) accept subnet routes a remote router advertises, reaching those LAN devices. | `TS_ACCEPT_ROUTES=0` | [kb/1019](https://tailscale.com/kb/1019/subnets) |
| advertise-exit-node **ON** | `tailscale set --advertise-exit-node=true` **plus** IP forwarding (`net.ipv4.ip_forward` + `net.ipv6.conf.all.forwarding` → `/etc/sysctl.d/99-tailscale.conf`) **plus** a firewalld masquerade *only if firewalld is running* (Fedora Cloud Base ships none, so normally a no-op). | `TS_EXIT_NODE=0` | [kb/1103](https://tailscale.com/kb/1103/exit-nodes) |

**The script does only the host-node side.** Each capability also needs one-time actions the host
cannot perform for you:

| Goal | One-time action | Where |
|---|---|---|
| Reach the LAN | Approve the advertised route | admin console → Machines → *the router* → approve its CIDR |
| Reach the LAN | Ensure IP forwarding is on **the advertising router** (not this VPS) | the router host |
| Exit node | Approve the exit node | admin console → Machines → *this VPS* → Edit route settings → ✓ Use as exit node |
| Exit node | Opt in per device | each device: `tailscale set --exit-node=<vps> --exit-node-allow-lan-access` |

**Containers as their own tailnet devices.** A service container that should be reachable by its own
name runs the official `tailscale/tailscale` image in **userspace mode** (rootless-friendly, the
image default) with `TS_AUTHKEY` + `TS_HOSTNAME` + a persistent `TS_STATE_DIR` volume; it
self-registers as its own node with its own MagicDNS name. Nothing is required on the host for this,
and you do **not** advertise the container subnet from the VPS.

> **Security — scope the agent's reach.** Because accept-routes is now **ON by default**, the in-box
> Claude Code **can send packets to your LAN out of the box**; `--accept-routes` itself imposes no limit.
> Contain it in the **tailnet policy file** ([grants/ACLs](https://tailscale.com/kb/1393/access-control)):
> tag the VPS (`tag:vps`) and grant it only specific LAN hosts/ports — never the bare `/24` — and scope
> which devices may use the exit node. With routing on by default this is the **recommended hardening**,
> not optional. (Or set `TS_ACCEPT_ROUTES=0` if the agent shouldn't reach the LAN at all.)

## macOS — log in via the 1Password SSH agent

Keep your private keys in 1Password and let its SSH agent answer the auth
challenge — the private half never touches disk, and `ssh core@<host>` just
works (1Password prompts for Touch ID, then you land in the tmux session named
after the key that authenticated).

1. **Turn on the agent.** 1Password → **Settings → Developer → Use the SSH Agent**.
   Also enable **Keep 1Password in the menu bar** + **Start at login** (General)
   so the agent is up whenever you open Terminal. Reference:
   [1password.dev/ssh/get-started](https://www.1password.dev/ssh/get-started/).

2. **Point ssh at the 1Password agent for every host** in `~/.ssh/config` — one
   block, no per-server entries:

   ```
   Host *
     IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
   ```

   On any `ssh core@<host>` the agent offers your keys and the server accepts
   whichever it allowlists — nothing to set up per host. (Don't put `User core`
   under `Host *`; it would force `core` onto github.com and everything else —
   just type `core@`.)

3. **Pick which identity this Mac uses** (optional). The host allowlists all
   three keys, so the **first** key the agent offers that the server accepts is
   the one that authenticates — it decides which `LOGIN_KEY` session you land in.
   Order them in 1Password's agent config,
   [`~/.config/1Password/ssh/agent.toml`](https://www.1password.dev/ssh/agent/config/),
   which is **local to each machine** (the keys sync; this ordering doesn't), so
   every device can prefer its own identity while keeping the others as fallback:

   ```toml
   # ~/.config/1Password/ssh/agent.toml — local to THIS Mac
   [[ssh-keys]]
   item = "oSo"          # offered first → the identity this machine authenticates as

   [[ssh-keys]]
   item = "Alchemist"

   [[ssh-keys]]
   item = "Fatima"
   ```

   Use the item titles as they appear in 1Password (add `vault`/`account` lines
   if a title repeats across vaults). Once this file exists, the agent offers
   **only** the listed keys, **in this order**. Each Mac gets its own file, so
   reorder per device to make its identity win. Fastest way to create it: in
   1Password pick a key → **Configure for SSH Agent**, then edit the order.

4. **Log in:**

   ```sh
   ssh core@<host>        # Touch ID for the matching key, then you're in
   ```

Verify the agent is live and offering your keys in the chosen order:

```sh
ssh-add -l
```

## Build Principles (binding — follow verbatim for any change to this repo)

| # | Principle | Rule |
|---|---|---|
| 1 | TARGET | Fedora Cloud Base, pinned latest stable (image tag in distrobox.ini, host assumptions documented here). Bump deliberately, per rule 3. |
| 2 | SOURCES | Host and box install only from: (a) Fedora repos via dnf (RPM); (b) the vendor's/developer's official RPM/dnf repo; (c) at worst a developer/vendor AppImage. Never curl-pipe-sh, language package managers onto PATH, tarballs onto PATH, third-party repos. Exceptions only by explicit user waiver recorded in the Packages table. Current waivers: none. |
| 3 | VERIFY FIRST | Fact-check any source/version against the live source before changing it. |
| 4 | HOST MINIMAL & IMMUTABLE | The host package list below is the complete sanctioned host footprint. Anything else runs in a container or in claudebox. Host installs beyond this list require an explicit user waiver, recorded here. |
| 5 | NO SECRETS | No passwords, keys, or tokens in this repo, ever. Tailscale auth is interactive or via TS_AUTHKEY env at run time. |
| 6 | GUARDRAILS ARE CODE | Claude Code's law lives in policy/ (enterprise tier: /etc/claude-code/ inside the box) and is re-stamped on every setup.sh run. Changing the rules = changing this repo. |
| 7 | EXPOSURE | Public IP carries key-only ssh and mosh ONLY. Cockpit and every sensitive port are tailnet-only. etserver is never installed (replaced fleet-wide by mosh). |
| 8 | VALIDATE | setup.sh ends with verify.sh; a bootstrap is done when every check PASSes. |
| 9 | LEAST PRIVILEGE / LAYERS | Provisioning splits by identity: the SYSTEM layer (packages, /etc, system services) runs as root once via setup-host.sh; the ROOTLESS layer (podman, distrobox, Claude Code) runs as the operating user via setup-user.sh. The user is a password-gated `wheel` admin with NO blanket NOPASSWD; the in-box agent gets only a scoped passwordless allowlist (policy/sudoers.claudebox), grown solely by committing to the repo, and is OS-blocked from everything else (host installs stay hard-denied). Privileged files are written in place by root, never staged via a user-owned /tmp file. |

## Packages

| Tier | Package | Source | Why |
|---|---|---|---|
| Host | podman | Fedora repos (preinstalled on Cloud) | the container engine — the host's purpose |
| Host | distrobox | Fedora repos | runs claudebox (declarative via distrobox.ini) |
| Host | flatpak-session-helper | Fedora repos | host side of distrobox-host-exec (D-Bus activated; not preinstalled on Cloud) |
| Host | tmux | Fedora repos | the persistence layer: every remote login attaches session "main"; outlives box rebuilds and tailscaled restarts |
| Host | mosh | Fedora repos | roaming-resilient public remote shell (UDP, AEAD; bootstraps over sshd) |
| Host | openssh-server | Fedora repos | key-only public door + mosh bootstrap (Cloud default config is already key-only) |
| Host | tailscale | Tailscale's official dnf repo | tailnet node + Tailscale SSH + serves Cockpit |
| Host | cockpit, -podman, -files, -networkmanager, -selinux | Fedora repos | browser host management (containers, files, network, SELinux), tailnet-only |
| Host | dnf5-plugin-automatic | Fedora repos | unattended host package updates (monthly on the 15th; applies, never auto-reboots) |
| Box | claude-code | Anthropic's official dnf repo (**`latest`** channel) | the manager — claudebox's purpose; refreshed by the daily box rebuild |
| Box | host-spawn | Fedora repos | container side of distrobox-host-exec (no GitHub download — deterministic) |
| Box | bubblewrap, socat | Fedora repos | Claude Code's Linux sandbox dependencies |
| Box | podman (client) | Fedora repos | drives the HOST engine via CONTAINER_HOST socket |
| Box | git, gh, tmux, fastfetch | Fedora repos | orchestration toolset (repos, GHCR auth, sessions) |

## Files

| File | Purpose |
|---|---|
| CLAUDE.md | repo-editing guide for Claude Code (read README first; Build Principles + Packages tables are binding; host-immutability doctrine; policy/* are the law stamped into the box) |
| setup.sh | orchestrator (run as root): runs the system layer then the rootless layer in their correct identities |
| setup-host.sh | **system layer**, as root — packages, /etc, system services, tailnet, host dnf-automatic, creates `core` + its rootless prerequisites |
| setup-user.sh | **rootless layer**, as `core` — user podman socket, ssh keys, claudebox, Claude policy, the `claude` + `claudebox-rebuild` wrappers + the box-rebuild units, verify (no host privilege) |
| sync-authorized-keys.sh | authorizes `core`'s **allowlisted** SSH keys from `github.com/<user>.keys` (fingerprint allowlist = the access policy; other keys ignored), tags each `environment="LOGIN_KEY=<device>"`; defensive (never wipes keys on a failed fetch) |
| distrobox.ini | claudebox, declaratively (image pin, pre-init Anthropic repo on the `latest` channel, packages) |
| box-rebuild.sh | the full box rebuild (`distrobox rm -f` → re-run setup-user.sh); run detached by `claudebox-rebuild-run.service` so it outlives the box it recreates — the target of all 3 update triggers |
| claudebox-daily.sh | the daily-refresh **decision** (update method 1): rebuild now if idle, else defer so the `claude` wrapper rebuilds on session exit — never interrupts live work |
| claudebox-init.sh | claudebox host bridge (CONTAINER_HOST → host rootless podman socket) + the in-box `claudebox-rebuild` command (method 2), applied as the box's own root post-assemble over the quote-safe `distrobox enter -- sudo` channel — avoids distrobox's init_hook quote traps |
| cockpit-tailnet-serve.sh | installed to /usr/local/sbin; publishes Cockpit on the tailnet (`tailscale serve` :443 → loopback:9090, retrying until MagicDNS+HTTPS-certs are on) and writes `/etc/cockpit/cockpit.conf` with the node's MagicDNS Origin so the proxied login works |
| policy/CLAUDE.md | Claude Code's binding law inside claudebox (mission: orchestrate, host immutable, source rules) |
| policy/managed-settings.json | deny-rule guardrails (best-effort, defense-in-depth) + bypass-permissions disabled — non-overridable (managed tier) |
| policy/sudoers.claudebox | scoped passwordless-sudo allowlist for the operating user (exact-pinned `tailscale serve` loopback proxy + read-only `status`; no wildcards, no `funnel`); grown by propose+commit; visudo-validated, stamped to /etc/sudoers.d/claudebox |
| verify.sh | PASS/FAIL acceptance: sockets, box, claude, policy, host-engine reach, tailnet, the box-rebuild units + host dnf-automatic timer, and the doctrine boundary (agent has NO passwordless dnf) |
| .github/workflows/refresh-release.yml | weekly CI (Fri): re-checks Fedora's latest stable + Hostinger's provisioned version, refreshes the README status line and the pinned releasever, committing only on change |

## Notes

- Tested design, not yet host-tested: this repo's first run on a real
  Fedora Cloud instance is its acceptance test (verify.sh). Built from
  live-verified facts (2026-06-12): distrobox 1.8.x assemble syntax,
  host-spawn rpm in Fedora repos, /run/user shared into the box,
  fedora-toolbox:44 image, Anthropic rpm repo.
- Distrobox 2.0 (Go rewrite) is in RC: same manifest/CLI interface
  promised; re-verify on Fedora's first 2.0 ship.
- The future `cage` profile (truly contained box for autonomous runs: no
  shared $HOME, egress allowlist) is documented intent, not yet built.
