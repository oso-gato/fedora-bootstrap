# fedora-bootstrap

## Fedora Cloud Update

Cloud images ship behind current Fedora — Hostinger, for instance, still
provisions **Fedora Cloud 42**, typically two releases behind. Bring the host
fully current **before** running `setup.sh` (the Packages table and vendor repos
are validated against the latest stable).

Both blocks below run Fedora's official **DNF system-upgrade** flow, which is
**built into dnf5** (Fedora ≥ 41 — there is no plugin to install). Fedora supports
jumping at most **two releases** at once (N → N+2), exactly the cloud-image gap.
Only `curl` is needed, and it ships by default on Fedora Cloud (as `curl-minimal`).
Pick whichever you prefer — they reach the same place.

**Option 1 — self-updating (never edit this one).** Reads the latest GA straight
from Fedora's official, Beta-safe
[`releases.json`](https://fedoraproject.org/releases.json) (GA shows as a bare
integer `"44"`; the regex matches only purely-integer `version` values, so any non-GA/pre-release entry (not a bare integer) is ignored and an integer-only `max` never lands
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
Built and pinned for **Fedora Cloud Base, latest stable (44)**; Workstation
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
dnf -y install git
useradd -m -G wheel core
echo 'core ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/core
if su - core -c 'git clone https://github.com/oso-gato/fedora-bootstrap && cd fedora-bootstrap && ./setup.sh'; then
  echo 'setup.sh: all phases PASS.'
else
  echo '*** setup.sh did NOT finish all-PASS. If it printed a login.tailscale.com link,'
  echo '*** open it once, then re-run:  su - core -c "cd ~/fedora-bootstrap && ./setup.sh"'
  echo '*** Otherwise fix the cause shown above and re-run the same command.'
fi
passwd core      # optional, runs last — Cockpit/console password (SSH stays key-only)
```

Why a non-root user first: rootless podman, distrobox, and Claude Code all
assume one; `wheel` + the `NOPASSWD` drop-in let the unattended `su - core -c …`
run the script's privileged steps without a password prompt (delete
`/etc/sudoers.d/core` later if you'd rather require one). Fedora Cloud images may
already provide a cloud-init user (often `fedora`) — using it instead of creating
`core` is fine.

`setup.sh` is idempotent and ordered (8 numbered phases: packages → services
→ ssh keys → tailscale → tmux-attach → claudebox assemble → Claude policy →
verify). It pauses at most once during the run: the tailscale auth link (once
per host; open it, then re-run setup.sh). Claude Code is installed but NOT logged
in by setup.sh — the first time you run `claude` (the wrapper in ~/.local/bin) you
complete OAuth once. On this headless VPS that first run prints a login URL: open
it in your Mac browser, approve, and paste the returned code back into the SSH
session; for unattended use mint a token with `distrobox enter claudebox -- claude
setup-token` and export CLAUDE_CODE_OAUTH_TOKEN (a secret — never commit it). Re-run
after any failure; it resumes safely. Rebuild the box anytime by re-running setup.sh
(assemble is declarative; ad-hoc tools inside the box are disposable by design).

**SSH keys & provenance.** Phase 3 pulls your public keys from
`github.com/oso-gato.keys` (GitHub is the registry — no keys in this repo) and
writes `core`'s `authorized_keys`, tagging each with `environment="LOGIN_KEY=…"`
so every login is attributable to the key that authenticated (`oSo`,
`Alchemist`, `Fatima`). Add or revoke a key on GitHub, then re-run `setup.sh` to
resync. Phase 5 names each login's tmux session after that tag, so every device
lands in its own persistent session (`tmux attach -t <other>` hops between
them). Day 0 gives `core` passwordless `sudo` (so `setup.sh` runs unattended; key-only
SSH means no console password to protect by default); the optional final `passwd`
adds a Cockpit/console password. SSH stays key-only regardless.

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
| Host | cockpit, -podman, -files, -storaged, -networkmanager, -selinux | Fedora repos | browser host management (containers, files, disks, network, SELinux), tailnet-only |
| Box | claude-code | Anthropic's official dnf repo | the manager — claudebox's purpose |
| Box | host-spawn | Fedora repos | container side of distrobox-host-exec (no GitHub download — deterministic) |
| Box | bubblewrap, socat | Fedora repos | Claude Code's Linux sandbox dependencies |
| Box | podman (client) | Fedora repos | drives the HOST engine via CONTAINER_HOST socket |
| Box | git, gh, tmux, fastfetch | Fedora repos | orchestration toolset (repos, GHCR auth, sessions) |

## Files

| File | Purpose |
|---|---|
| setup.sh | the one command: 8 idempotent phases, ends in verify |
| sync-authorized-keys.sh | authorizes `core`'s **allowlisted** SSH keys from `github.com/<user>.keys` (fingerprint allowlist = the access policy; other keys ignored), tags each `environment="LOGIN_KEY=<device>"`; defensive (never wipes keys on a failed fetch) |
| distrobox.ini | claudebox, declaratively (image pin, packages, host bridges) |
| policy/CLAUDE.md | Claude Code's binding law inside claudebox (mission: orchestrate, host immutable, source rules) |
| policy/managed-settings.json | hard deny rules + bypass-permissions disabled — non-overridable |
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
