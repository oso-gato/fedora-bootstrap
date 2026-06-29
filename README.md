# fedora-bootstrap

## TL;DR — in plain words

One script that turns a fresh cloud server into your **"mother platform"** — a locked-down host that runs your whole fleet of container apps. Its on-board Claude (the "host claudebox") has **two standing jobs**: it **operates the host** (including starting and removing containers), and — being the only thing that watches the apps run *live* — it **diagnoses them and proposes fixes**. It's one of **three boxes**: this host box **operates + diagnoses**, `fedora-dev` **builds + merges**, the desktop box **builds its own tools**. All three **open PRs; only `fedora-dev` merges** — on your one click.

- 🔑 **How you get in:** key-only SSH/Mosh from anywhere; the admin console (Cockpit) and everything sensitive are reachable only over your private Tailscale network.
- 🏭 **Maintaining the host:** keeps it minimal and treated-as-immutable; every app runs as a container pulled from your registry, auto-refreshed monthly with **automatic roll-back** if a new version comes up unhealthy. The host claudebox operates the fleet.
- 🔧 **What it can change:** because it's the only box watching the apps run live, it can **diagnose any container it runs and propose a fix** (a PR) to that app's code — including the foundation it stands on. But it **stops at the proposal**: it never merges its own change. `fedora-dev` merges it, on your click.
- 🚧 **The split:** it **never builds** images (CI does), **never merges** (`fedora-dev` does), and **never edits the live host** by hand — you re-run the setup script as root to apply. "Proposing a change" is never "applying it."
- 🔒 **No secrets in the repo.**

Version: **1.2.45** — docs patch: README restructured for readability (upgrade log v1.1.15–v1.2.42 relocated to [UPGRADING.md](UPGRADING.md)). Prior: v1.2.44 — fix SELinux enforce-gate no longer requires the removed `fail2ban.service` (was silently pinning the host permissive). v1.2.43 — `claude` wrapper now auto-retries the transient post-rebuild PTY race. Full history in [UPGRADING.md](UPGRADING.md).

## Where this sits — the fleet

**This repo is the `fedora-bootstrap` box** of a three-box swarm — **the genesis / mother-platform box** that operates the VPS host and live-diagnoses the containers on it; PR-only. Full map: **[FLEET.md](FLEET.md)**.

| Box | Role | Builds? | Merges? | Operates host? | Spin up |
|-----|------|:--:|:--:|:--:|---------|
| **fedora-dev** | develop · build · **merge** | ✅ nested | ✅ **(sole merger)** | ❌ | `./spin-up.sh` |
| **fedora-bootstrap** *(this one)* | operate host · live-diagnose → PR | ❌ (CI) | ❌ PR-only | ✅ incl. create/remove | `./day0.sh` (Day-0) |
| **fedora-desktop** | knowledge-work + own toolset → PR | ❌ (CI) | ❌ PR-only | ❌ | `./spin-up.sh` |

This box **operates the host and proposes fixes (PRs) — it never merges**; `fedora-dev` merges on Arthur's **clickable APPROVE**. The host genesis path is `day0.sh` → `setup.sh` (no `spin-up.sh`/`run.sh` here). See [FLEET.md](FLEET.md) for the handoff + boundaries.

> **Headless (binding prerequisite).** There is never a screen plugged into this server, and there is no "log in at the console" — the host is a remote cloud VPS you only ever reach over the network. Every desktop the fleet serves (Obsidian, VS Code, the browser) is drawn by software on a *virtual* screen inside a container and streamed to you over RDP/VNC/the web gate; nothing in the design may ever assume a real monitor, graphics card, or sit-down seat. If something needs one, that's a bug to fix, not a setting to toggle.

## How the box works with you

The two boxes — this host box and `fedora-dev` — are **one self-running development machine**, and its whole point is to **keep you out of the loop until you're genuinely needed**. The box does **most of the work and the thinking**: when there's more than one way to do something, it **builds two or three, tries them, throws away the ones that don't fit, and lands on the right one itself** — it doesn't hand you a menu to pick from. It makes its own recommendation **and tests it**, and it's willing to **tear down its own first draft and start over** to get it right.

How it tests is **two-tier**, and most of it never touches this host. **By default it tests in its own dev box** — `fedora-dev` builds a throwaway copy of the change and runs it right there in its own sandbox, fixing and rebuilding over and over with no involvement from this host at all. **It only brings a change to this host's live-gate for two reasons:** when the change is something the dev box simply can't run on its own (for example a full-desktop image that needs to boot like a real machine), or as the **final dress rehearsal** before shipping — this host builds it one last time, proves it works **live on a real server**, then throws it away, and only then is the change offered to you to approve. Every test copy is a **throwaway** that's deleted afterwards, but the box keeps the heavy download/build work cached between attempts, so iterating fifty times doesn't mean downloading the same thing fifty times.

Here's how that caching actually holds up across many attempts (it's been measured, not just hoped for). The durable thing the box keeps is a **kept-aside pile of the actual software packages** — it lives in plain storage on the box's own disk, not inside any image, so it **survives every test copy being thrown away**. Even when an attempt changes which packages get installed, they're **pulled from that local pile instead of re-downloaded** — measured: a forced re-run fetched **nothing at all (0 bytes, versus 9.4 MiB the cold first time) and ran about 3.7× faster**, with only a genuinely new package fetched the one time, after which it too joins the pile. The box does **not** try to hang onto the half-finished build steps between attempts, and that's deliberate, not a shortcoming: each thrown-away copy takes its own build steps with it, so (a) the disk **never silently fills up** with old build leftovers, and (b) every fresh attempt is **rebuilt from the package pile against the current versions** — so nothing quietly goes stale — for the price of just a few seconds of local work (about 3.6 s when warm), never another download. (When a test copy is still around — back-to-back tweaks, or one deliberately kept — its finished steps are reused too, skipping even that work; it's just never relied on once the copy is gone.) Each attempt also builds in its own private workspace under its own one-off name, so two attempts can't trip over each other, and the pile is keyed by content, so it can never hand back the wrong version. And because this runs on a small server with limited disk, three guards keep it tidy: each throwaway deletes itself when it finishes (pass, fail, or crash), a sweeper cleans up anything a hard crash leaves behind, and a cap keeps the package pile in check — dropping anything older than **45 days** first, then trimming oldest-first to stay under **15 GB** (both adjustable).

It comes to you for **exactly two reasons**:

1. **It's done** — the change is finished and proven, and it needs your one click to APPROVE the merge.
2. **It's stuck** — it's hit a genuine roadblock and needs a real decision from you (not a merge).

That's it — no "which should I do?", no status check-ins. **The PR is its proof of work**, and "done" means the change has been **validated** (in the dev box, and on this host's live-gate when that tier applies) and the box has written a short **TLDR that it has critically checked against the whole objective** before bringing it to you.

## Purpose

`fedora-bootstrap` turns a fresh Fedora Cloud VPS into a **container-as-app fleet** operated by an in-box Claude Code agent. The host stays minimal and treated-as-immutable; every application function runs in a container pulled from `ghcr.io/oso-gato/*`.

The host's claudebox is the **genesis agent** of this platform — the first claudebox brought up, running *on* the host. Its standing purpose is two-fold:

1. **Operate + maintain the mother platform** — the host itself, which runs every current and future containerised workload. It deploys and operates workload images and keeps the host sound. It **never builds** images (CI does) and **never applies** host changes itself (the operator re-runs `setup.sh` as root).
2. **Live-diagnose + develop fixes → open PRs** — being the only box that sees the containers running live, it diagnoses them and develops fixes to the fleet image repos it operates (`fedora-bootstrap`, `fedora-dev`, and the workloads deployed here) — and **opens PRs only**. It never merges, pushes, or tags `main`: **`fedora-dev` merges**, on Arthur's clickable APPROVE (THE FLEET). Builds stay CI's job.

A repo it neither operates nor can diagnose stays **surface-only** (it proposes a diff; that repo's own dev box or the operator opens the PR). For **all** images, the build/deploy handoff is one-way and unchanged:

image source → pushed to GitHub → CI builds + publishes to GHCR → host claudebox pulls and recreates via the workload-refresh harness (monthly).

Maintaining a repo's source is never the same as building its image (CI's job) or deploying it (the pull): the host claudebox writes source and pulls images; it never `podman build`s and never hand-deploys.

## What the host provides after bootstrap

After `setup.sh` (see "Using the bootstrap" below), the VPS:

- **Runs containers from `ghcr.io/oso-gato/*` via podman.** Each major function is its own container; nothing else is installed onto the host beyond a short fixed package list.
- **Hosts claudebox** — the in-host management agent (Claude Code in a Distrobox). Pulls images, runs containers, writes Quadlets, refreshes them on schedule.
- **Carries the personal universe and second brain** via the **fedora-desktop** container (XFCE over xrdp + an experimental GNOME/grd lineage). VS Code for projects, Obsidian for the knowledge vault. RDP `KillDisconnected` + tmux give session survival across disconnects.

**Access:**

| Door | From public internet | From tailnet |
|---|---|---|
| Host shell (ssh, mosh) | yes — key-only | yes (+ keyless Tailscale SSH) |
| Desktops (web: KasmVNC / noVNC / Guacamole) | yes — TLS + password | yes |
| Desktops (native RDP / VNC) | no | yes |
| Dev containers (ssh, mosh) | yes — key-only (ssh :4444 + mosh 61001-62000/udp) | yes (+ keyless Tailscale SSH) |
| Cockpit | no | yes (tailscale serve) |

The public IP exposes three hardened surfaces — the host's key-only shell (ssh/mosh), the desktops' TLS+password web doors, and the **dev container's key-only ssh (:4444) + mosh (61001-62000/udp)** (deployed by this host via the fedora-dev Quadlet's `PublishPort`s). Native RDP/VNC and Cockpit stay tailnet-only. Host shell logins land in a persistent shared `main` tmux session (each connection gets its own view) that survives disconnects.

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

As root on a fresh Fedora Cloud instance (take a Hostinger snapshot first — `day0.sh` reboots the host into the automated SELinux convergence).

> **Who runs this & how the host "spins up":** a human operator with host root pastes this block. The in-host claudebox agent has **NO host root** — if *you* are the agent, **surface** this block to the operator, don't run it (policy/CLAUDE.md ROLE). There is **no `spin-up.sh` / `run.sh` / Quadlet** in this repo: unlike the workload repos (`fedora-dev` / `fedora-desktop`, which spin up via `spin-up.sh` → `run.sh`), the HOST genesis path is **`day0.sh` → `setup.sh`**; workloads then come up automatically (below).

```sh
dnf -y upgrade --refresh
dnf -y install git
git clone https://github.com/oso-gato/fedora-bootstrap /opt/fedora-bootstrap
/opt/fedora-bootstrap/day0.sh        # interactive Day-0 wizard — keep this the LAST line
```

`day0.sh` is the interactive Day-0 wizard (mirrors the workload `spin-up.sh`): it **ASKS for a Tailscale auth key** (`tskey-…`; press **Enter** to leave it blank → **browser web-login**, a `login.tailscale.com` link prints — open it and approve), then runs `setup.sh`, then **prompts for core's password** (admin/sudo + Cockpit — never stored in the repo) and, on success, **reboots** into the SELinux convergence (relabel → soak → enforcing → post-enforce check; two further automatic reboots on the happy path, ~20–25 min; an unhealthy enforcing boot auto-reverts to permissive with one more). Run it as the **last** line so its prompt has nothing buffered behind it.

- **Stay permissive (no enforcing):** `SELINUX_TARGET=permissive /opt/fedora-bootstrap/day0.sh` — sets the password, no reboot.
- **Fully scripted / unattended (no prompts):** skip the wizard and call `setup.sh` directly, as before — `TS_AUTHKEY=tskey-… /opt/fedora-bootstrap/setup.sh < /dev/null` then `passwd core && reboot`. The `< /dev/null` keeps `setup.sh` from swallowing the pasted `passwd` line; `setup.sh` honors `TS_AUTHKEY` (blank ⇒ browser web-login) and never reboots itself (the reboot is gated on your `passwd`).

`setup.sh` is fully idempotent. It runs as root and orchestrates two layers in their correct identities:

1. **System layer** (`setup-host.sh`, as root): host packages, `/etc`, system services, tailnet, dnf-automatic, creates `core` user + rootless prerequisites.
2. **Rootless layer** (`setup-user.sh`, as `core`): user podman socket, ssh keys synced from `github.com/oso-gato.keys`, claudebox assembled from `distrobox.ini`, Claude policy stamped, workload-refresh harness enabled, verify.

Tailscale join (one-time per host): with `TS_AUTHKEY=tskey-…` set it's unattended (no pause); otherwise it's browser web-login — open the `login.tailscale.com` URL printed in the output, approve, then re-run `setup.sh`. (On a later *interactive* `setup.sh` run — without `< /dev/null` — `setup-host.sh` instead PROMPTS for the key; the Day-0 `< /dev/null` paste above skips that prompt by design.)

**Host naming:** the VPS names itself `erebus` (override with `BOOTSTRAP_HOSTNAME=<name>`). `hostnamectl` sets it; a cloud-init drop-in pins it across reboots.

**Default networking:** the host comes up advertising itself as a Tailscale **exit node** AND **accepting LAN routes** the tailnet advertises. Turn either off with `TS_EXIT_NODE=0` / `TS_ACCEPT_ROUTES=0` before setup. Each capability also needs one-time admin-console approval (Tailscale → Machines).

> **Security note:** with accept-routes ON, the in-box Claude Code can reach your LAN. Scope its access via tailnet ACLs (tag the VPS, grant only specific hosts/ports — never the bare `/24`).

#### Credentials Day-0 asks for — the Tailscale key + an optional GitHub App

- **Host Tailscale auth key** — `day0.sh` prompts for it first (`tskey-…`; **Enter** = browser web-login). Generate it in the Tailscale admin console → **Settings → Keys → Generate auth key**.
- **Per-workload questions (delegated)** — as `setup.sh` brings up each bundled workload (currently `fedora-dev`), it runs **that workload's own `spin-up.sh`** to ask **its** setup questions, so each container is the single source of truth for what it asks. For `fedora-dev` that's its **Tailscale auth key** + an optional **standing GitHub App credential** (paste the App ID, Installation ID, and the private-key PEM — it streams into a podman secret, **never a file**). The App is **optional + fail-safe**: decline it and that box uses its own `gh auth login` instead.

**Create the GitHub App once** — github.com → **Settings → Developer settings → GitHub Apps → New GitHub App** (owned by `oso-gato`): uncheck **Webhook → Active**; **Repository permissions** = Contents **R/W** + Pull requests **R/W** + Workflows **R/W**; **Create** → note the **App ID**; **Generate a private key** (`.pem`); **Install** on your repos → note the **Installation ID**.

> The host's **own** GitHub App (for the host-claudebox's standing auth) and wiring the bundled box's collected Tailscale key into its Quadlet are tracked **follow-ups** (same feature family as the deferred fedora-desktop per-user work).

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

Each release has one self-contained code block to paste into the VPS root terminal — find your target version and paste its block. Paths from `v1.1.1` through `v1.2.42` are archived in [UPGRADING.md](UPGRADING.md); the three most recent releases follow.

> Release-doc rules live in [CLAUDE.md](CLAUDE.md) (agent-facing).

#### Upgrading to v1.2.43 (from v1.0.0)

Fix for a **transient post-rebuild entry race**: right after a box rebuild, running `claude` can fail **once** with `Error: OCI runtime error: crun: ptsname: Inappropriate ioctl for device` and then work seconds later on a manual re-run. It is not a broken box — the freshly (re)started claudebox's `/dev/pts` needs a moment before an interactive `podman exec` can allocate a pseudo-terminal, so the wrapper's **first** `distrobox enter` loses the race. The `claude` wrapper now **retries automatically**: `distrobox-enter` ends in `exec "$@"`, so `podman`'s exit code reaches the wrapper verbatim, and `podman`/OCI exec-setup failures (exit **125/126** — codes a session that actually started never returns) are retried (bounded to **6**, escalating backoff capped at 4 s, ~18 s total — comfortably past the observed ~15 s warmup window) while any other outcome — success, `Ctrl-C` (130), a genuine non-zero (including the start-phase exit-1 path when the box is not already running) — is surfaced unchanged. This is **distinct from and complementary to** the v1.2.38 fix (concurrent enters *during* a rebuild); it addresses your **own** `claude` entry *after* the rebuild completes. **Applying is safe** — a plain `setup.sh` re-run does **not** remove the box; it only re-stamps the `claude` wrapper. **As root on the VPS:**

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null    # re-stamps the `claude` wrapper with the post-rebuild entry-retry loop
```

**Verify** the installed wrapper carries the retry loop (`~/.local/bin/claude` is owned by `core`):

```sh
grep -q 'still warming up after the rebuild' /home/core/.local/bin/claude && echo "retry present" || echo "MISSING"
```

Expected: `cat /opt/fedora-bootstrap/VERSION` → `1.2.43`; the grep prints `retry present`. The real end-to-end proof is behavioural — after a `claudebox-rebuild`, `claude` reconnects on the first try (it prints `>> claudebox is still warming up after the rebuild — retrying entry (N/6)…` and proceeds, instead of erroring out and requiring a manual re-run). **Rollback** — `git checkout` the prior commit + re-run `setup.sh`; the wrapper reverts to entering once (so a post-rebuild `claude` may again need a manual re-run, as before).

#### Upgrading to v1.2.44 (from v1.0.0)

Host-only **security fix** — the SELinux enforce-gate no longer requires the removed `fail2ban.service`. In v1.2.41 fail2ban was dropped (key-only door), but `selinux-autoenforce.sh`'s critical-services health gate still listed `fail2ban.service`, so the gate could never PASS: a fresh host stayed **permissive** and an already-enforcing host **auto-reverted** to permissive. This drops `fail2ban.service` from that list so the convergence to **enforcing** can complete. A host pinned permissive by this bug carries a `selinux-chain.rolled-back` or `selinux-chain.aborted` marker — the standard flow re-stamps the fixed script; clear the marker to re-arm the now-fixed convergence.

**As root on the VPS:**

```sh
# Standard upgrade flow — re-stamps the corrected selinux-autoenforce.sh + units.
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null

# ONLY if this bug pinned the host permissive (a marker exists): clear it + re-arm.
ls /var/lib/fedora-bootstrap/selinux-chain.rolled-back \
   /var/lib/fedora-bootstrap/selinux-chain.aborted 2>/dev/null \
  && rm -f /var/lib/fedora-bootstrap/selinux-chain.rolled-back \
           /var/lib/fedora-bootstrap/selinux-chain.aborted \
  && ./setup.sh < /dev/null   # re-arms the convergence (reboots into the soak → enforce)
```

Expected: `cat /opt/fedora-bootstrap/VERSION` → `1.2.44`; once a healthy enforcing boot is confirmed, `getenforce` → `Enforcing` and `/var/lib/fedora-bootstrap/selinux-chain.enforced` exists. A host already healthily enforcing is unaffected (no-op). **Rollback** — `git checkout <prior-commit> && ./setup.sh < /dev/null`; to stay permissive deliberately, `SELINUX_TARGET=permissive ./setup.sh`.


#### Upgrading to v1.2.45 (from v1.0.0)

Documentation-only patch — the README is restructured for human readability. The per-version upgrade log (`v1.1.15`–`v1.2.42`, 811 lines) is relocated verbatim to [UPGRADING.md](UPGRADING.md); the front-matter `Version:` line is replaced with a short summary. The `v1.2.43` and `v1.2.44` upgrade subsections remain in this file. No host code or behaviour changes.

**As root on the VPS:**

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
```

Expected: `cat /opt/fedora-bootstrap/VERSION` → `1.2.45`; no host behaviour change. **Rollback** — `git checkout <prior-commit>` (docs only, no functional effect either way).

---

## Operating the host (as the maintainer)

**Prerequisite — be on the tailnet.** Everything below is reached over your tailnet, not the public IP. Run Tailscale on your client and join the same tailnet; the VPS appears as `<vps>.<tailnet>.ts.net`.

### Connecting (ssh / mosh / tmux / claude)

```sh
ssh core@<vps>.<tailnet>.ts.net      # or the 100.x tailnet IP
mosh core@<vps>.<tailnet>.ts.net     # roaming-resilient; install via brew
```

- **Key-only**: your keys come from `github.com/oso-gato.keys` (Day-0 sync). On macOS, store them in 1Password and use its SSH agent — see [macOS section](#macos--log-in-via-the-1password-ssh-agent) below.
- **tmux**: every login auto-attaches to **one shared `main` session group** — each connection gets its own view (`c<pid>`) of the same windows, so you can reach the same work from several devices at once. Sessions persist across disconnects and outlive box rebuilds and tailscaled restarts. Detach with `Ctrl-b d`; reattach by logging in again. See **Multi-device sessions** below for how the geometry follows whichever device you're actively typing on.
- **`passwd core`** (Day 0) set the password for sudo and Cockpit. SSH stays key-only.

### Multi-device sessions (tmux geometry)

Because every login joins one shared `main` tmux group, you can reach the same work from several devices at once (a macOS terminal, an iPad, …). A tmux **window has exactly one size** shared by every client viewing it, so the session is configured **`window-size latest`**: the **device you most recently typed on wins**, and the whole session rescales to that device's geometry.

- **Switching devices is automatic.** Type on the Mac → the session is Mac-sized; pick up the iPad and type → it rescales to the iPad. A **fresh** login wins **on connect** (no keystroke needed); an **already-connected** device (e.g. a backgrounded mosh session) wins on its **next keystroke** — any key (even an arrow or `Esc`), no command required.
- **The idle device never garbles.** A larger idle device shows the active (smaller) view top-left with a **blank** letterbox around it (`fill-character ' '`); a smaller idle device shows a clean **crop** that pans to the cursor. When the active device disconnects, the session falls back to whichever device remains.
- **Inherent limit:** two **different-sized** devices viewing the **same** tab can't both be full-size at once — impossible in tmux (one window = one size). The active one is always full; the other degrades cleanly (never garbled). Devices on **different tabs** are each full-size.
- **Switch the policy live:** `prefix + g` cycles `latest → smallest → largest`. `smallest` = every device sees the whole session sized to the smallest connected device (good for watching on a phone while working on a desktop); `largest` = the biggest screen always wins.

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

3. **Pick which identity this Mac offers** (optional, in `~/.config/1Password/ssh/agent.toml`). The host authorizes **all** keys on the GitHub account; the first one the agent offers that the server accepts authenticates. List whichever account keys this Mac should offer (the examples below are the current account devices).

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
