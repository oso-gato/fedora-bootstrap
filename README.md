# fedora-bootstrap

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
exist yet when the clone runs. To reuse a cloud-init user (often `fedora`) instead of
creating `core`, set `BOOTSTRAP_USER=fedora` before `setup.sh`. To also give the VPS access to a
home LAN or make it an exit node, set `TS_ACCEPT_ROUTES=1` / `TS_EXIT_NODE=1` — see **Tailscale
routing** below (both are opt-in; a bare run leaves the tailnet posture untouched).

The first `dnf upgrade` freshens every package (an already-latest host no-ops the
release-upgrade section above, so this is where it still gets current). If it pulls a new
kernel or systemd and you want them live first, `reboot`, then run the rest.

**`core` is a full `sudo` admin** — it is in `wheel`, so `sudo` works once you set its
password with `passwd core` (required: that is `core`'s admin/sudo password, not just
Cockpit's). There is **no blanket `NOPASSWD:ALL`**; instead a **scoped** passwordless
allowlist (`policy/sudoers.claudebox` → `/etc/sudoers.d/claudebox`) lets `core` run a few
specific host commands without a password — currently an **exact-pinned** `tailscale serve`
loopback proxy (`…http://127.0.0.1:9090`) plus read-only `tailscale status` (no wildcards, no
`funnel`), so the in-box Claude Code can re-assert / read the tailnet exposure of what it deploys. Every *other* `sudo` needs the
password: a human admin types it (the Fedora default), while the unattended in-box agent —
which has no password — is OS-blocked. So after Day 0, `root` is retired and `core` runs
everything; you `sudo` (with the password) for host changes, the agent only for its narrow
allowlist (and even then it asks you first). To let the agent do more, grow the allowlist by
committing to `policy/sudoers.claudebox` — see **Privilege layers** and `policy/CLAUDE.md`.

`setup.sh` runs **as root** and is idempotent. It splits into two layers: the **system**
phase (`setup-host.sh`, as root — packages, the `core` user, system services, the ssh
drop-in, tailscale, the tmux drop-in, and `core`'s user manager) and the **rootless** phase
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
installed on the host** — the host carries only the one-line `claude` wrapper. The box is defined
declaratively in `distrobox.ini` and built on the first `setup.sh` run; rebuild it anytime by re-running
`setup.sh`.

| Layer | What | Why |
|---|---|---|
| Base image | `quay.io/fedora/fedora-toolbox:44` (pinned) | Fedora 44 userspace |
| Agent | **`claude-code`** → `/usr/bin/claude`, from Anthropic's official dnf repo | Claude Code CLI |
| Host bridges | `CONTAINER_HOST` → host rootless **podman** socket; `host-spawn`; shims `systemctl`/`journalctl`/`loginctl`/`flatpak` → host | drive host podman + host commands from inside the box |
| Dev tools | `git`, `gh`, `tmux`, `podman`, `socat`, `bubblewrap`, `fastfetch` | the agent's toolbox |
| Policy (managed tier) | `/etc/claude-code/CLAUDE.md` + `managed-settings.json` | hard-deny host installs, `disableBypassPermissionsMode`, behavioural rules |

**The nesting:** host → `claudebox` (the container) → Claude Code (the program in it). The box shares
your `/home/core`, so the agent edits the same files you do; `podman` inside the box drives the **host**
engine via `CONTAINER_HOST`, so containers it builds are real host containers, not nested. The agent's
*only* host privilege is the scoped `tailscale serve`/`status` sudo allowlist — every other host change
is OS-blocked by the kernel.

You do **not** enter the box to use Claude. `setup.sh` installs a wrapper at `~/.local/bin/claude` that
runs `distrobox enter claudebox -- bash -lc 'exec /usr/bin/claude "$@"'` — so a bare `claude` enters the
box, sources its login profile (so `CONTAINER_HOST` + the shims are set), and execs the real CLI
connected to your terminal, in your current directory. First run is a one-time OAuth (or `distrobox
enter claudebox -- claude setup-token` for a headless token, then export `CLAUDE_CODE_OAUTH_TOKEN` — a
secret, never commit it).

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

## Tailscale routing — LAN access & exit node (optional)

By default the host joins the tailnet as a plain node (Tailscale SSH + Cockpit over `serve`); it
neither reaches remote subnets nor routes anyone's traffic. Two **env vars** passed to `setup.sh`
turn routing on. They are **opt-in and non-destructive**: leave a var unset and that preference is
left exactly as-is (a re-run never tears down a posture an earlier run set); pass `…=0` to withdraw
one explicitly. Applied with `tailscale set` (not `up`), so they never disturb the `--ssh` join.

```sh
# reach a home LAN advertised by a remote subnet router, AND be an exit node:
TS_ACCEPT_ROUTES=1 TS_EXIT_NODE=1 /opt/fedora-bootstrap/setup.sh < /dev/null
```

| Env var | Effect | Official basis |
|---|---|---|
| `TS_ACCEPT_ROUTES=1` | `tailscale set --accept-routes=true` — the host **and the host-netns containers** (claudebox runs with `--network host`) accept subnet routes a remote router advertises, so they reach those LAN devices. Off by default on Linux. | [kb/1019](https://tailscale.com/kb/1019/subnets) |
| `TS_EXIT_NODE=1` | `tailscale set --advertise-exit-node=true` **plus** IP forwarding (`net.ipv4.ip_forward` + `net.ipv6.conf.all.forwarding` → `/etc/sysctl.d/99-tailscale.conf`) **plus** a firewalld masquerade *only if firewalld is running* (Fedora Cloud Base ships none, so normally a no-op). | [kb/1103](https://tailscale.com/kb/1103/exit-nodes) |

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

> **Security — scope the agent's reach.** Once the VPS accepts routes, the in-box Claude Code can
> send packets to your LAN; `--accept-routes` itself imposes no limit. Contain it in the **tailnet
> policy file** ([grants/ACLs](https://tailscale.com/kb/1393/access-control)): tag the VPS
> (`tag:vps`) and grant it only specific LAN hosts/ports — never the bare `/24` — and scope which
> devices may use the exit node. Optional for *function*, recommended as posture.

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
| Box | claude-code | Anthropic's official dnf repo | the manager — claudebox's purpose |
| Box | host-spawn | Fedora repos | container side of distrobox-host-exec (no GitHub download — deterministic) |
| Box | bubblewrap, socat | Fedora repos | Claude Code's Linux sandbox dependencies |
| Box | podman (client) | Fedora repos | drives the HOST engine via CONTAINER_HOST socket |
| Box | git, gh, tmux, fastfetch | Fedora repos | orchestration toolset (repos, GHCR auth, sessions) |

## Files

| File | Purpose |
|---|---|
| setup.sh | orchestrator (run as root): runs the system layer then the rootless layer in their correct identities |
| setup-host.sh | **system layer**, as root — packages, /etc, system services, tailnet, creates `core` + its rootless prerequisites |
| setup-user.sh | **rootless layer**, as `core` — user podman socket, ssh keys, claudebox, Claude policy, verify (no host privilege) |
| sync-authorized-keys.sh | authorizes `core`'s **allowlisted** SSH keys from `github.com/<user>.keys` (fingerprint allowlist = the access policy; other keys ignored), tags each `environment="LOGIN_KEY=<device>"`; defensive (never wipes keys on a failed fetch) |
| distrobox.ini | claudebox, declaratively (image pin, pre-init Anthropic repo, packages) |
| claudebox-init.sh | claudebox host bridges (CONTAINER_HOST → host podman socket; systemctl/journalctl/loginctl/flatpak shims), applied as the box's own root post-assemble over the quote-safe `distrobox enter -- sudo` channel — avoids distrobox's init_hook quote traps |
| cockpit-tailnet-serve.sh | installed to /usr/local/sbin; publishes Cockpit on the tailnet (`tailscale serve` :443 → loopback:9090, retrying until MagicDNS+HTTPS-certs are on) and writes `/etc/cockpit/cockpit.conf` with the node's MagicDNS Origin so the proxied login works |
| policy/CLAUDE.md | Claude Code's binding law inside claudebox (mission: orchestrate, host immutable, source rules) |
| policy/managed-settings.json | hard deny rules + bypass-permissions disabled — non-overridable |
| policy/sudoers.claudebox | scoped passwordless-sudo allowlist for the operating user (exact-pinned `tailscale serve` loopback proxy + read-only `status`; no wildcards, no `funnel`); grown by propose+commit; visudo-validated, stamped to /etc/sudoers.d/claudebox |
| verify.sh | PASS/FAIL acceptance: sockets, box, claude, host-engine reach, shims, tailnet |

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
