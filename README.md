# fedora-bootstrap

## TL;DR — in plain words

One script that turns a fresh cloud server into your **"mother platform"** — a locked-down host that runs your whole fleet of container apps. Its on-board Claude (the "host claudebox") has **two standing jobs**: it **operates the host** (including starting and removing containers), and — being the only thing that watches the apps run *live* — it **diagnoses them and proposes fixes**. It's one of **two boxes**: this host box **operates + diagnoses** and `fedora-dev` **builds + merges**. Both **open PRs; only `fedora-dev` merges** — on your one click.

- 🔑 **How you get in:** key-only SSH/Mosh from anywhere; the admin console (Cockpit) and everything sensitive are reachable only over your private Tailscale network.
- 🏭 **Maintaining the host:** keeps it minimal and treated-as-immutable; every app runs as a container pulled from your registry, auto-refreshed monthly with **automatic roll-back** if a new version comes up unhealthy. The host claudebox operates the fleet.
- 🔧 **What it can change:** because it's the only box watching the apps run live, it can **diagnose any container it runs and propose a fix** (a PR) to that app's code — including the foundation it stands on. But it **stops at the proposal**: it never merges its own change. `fedora-dev` merges it, on your click.
- 🚧 **The split:** it **never builds** images (CI does), **never merges** (`fedora-dev` does), and **never edits the live host** by hand — you re-run the setup script as root to apply. "Proposing a change" is never "applying it."
- 🔒 **No secrets in the repo.**

See [UPGRADING.md](UPGRADING.md) for the version history.

## Where this sits — the fleet

**This repo is the `fedora-bootstrap` box** of a two-box swarm — **the genesis / mother-platform box** that operates the VPS host and live-diagnoses the containers on it; PR-only. Full map: **[FLEET.md](FLEET.md)**.

| Box | Role | Builds? | Merges? | Operates host? | Spin up |
|-----|------|:--:|:--:|:--:|---------|
| **fedora-dev** | develop · build · **merge** | ✅ nested | ✅ **(sole merger)** | ❌ | `./spin-up.sh` |
| **fedora-bootstrap** *(this one)* | operate host · live-diagnose → PR | ❌ (CI) | ❌ PR-only | ✅ incl. create/remove | `./day0.sh` (Day-0) |

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

### GitHub Apps — the fleet's standing identities (create BEFORE Day 0)

Day 0 asks you to paste **two GitHub App credentials** (both prompts default **y**): one for the **HOST**
(this box — `live-gate-watch` discovers `live-validate` PRs and posts the GREEN/RED verdicts as this
identity) and one for the **dev box** (`fedora-dev` authors PRs as it). They MUST be **two distinct
Apps**: the deterministic auto-merge refuses any verdict authored by the PR author, so one shared App
would fail-closed every gate forever. Create both before running `day0.sh`.

**1. Create (×2)** — github.com → avatar → **Settings → Developer settings → GitHub Apps → New GitHub
App**. Name them readably (they become the `[bot]` names on PRs, e.g. `oso-gato-host-gate` /
`oso-gato-devbox`); Homepage URL = anything; **uncheck Webhook → Active** (the fleet polls); "Where can
this App be installed?" → **Only on this account** → **Create GitHub App**.

**2. Permissions** — set only these; leave everything else at *No access*:

| Repository permissions | Host App (`host-gate`) | Dev App (`devbox`) | Why |
|---|---|---|---|
| Actions | Read-only | Read-only | watch CI run results |
| Contents | **Read-only** | **Read and write** | host only clones PR heads to gate them; dev pushes feature branches |
| Issues | Read and write | Read and write | the `live-validate` label + PR comments ride the issues API |
| Metadata | Read-only *(mandatory, auto-set)* | Read-only *(mandatory, auto-set)* | forced by GitHub |
| Pull requests | Read and write | Read and write | host posts verdict comments; dev opens PRs |
| Workflows | **No access** | **Read and write** | only the dev box edits `.github/workflows/**` |
| Packages | **No access** | **No access** | ratified constraint — CI publishes images, never the boxes |

| Organization permissions | both Apps |
|---|---|
| *all* | No access |

| Account permissions | both Apps |
|---|---|
| *all* | No access |

The Contents/Workflows asymmetry is least-privilege doing real work: a compromised host box can only
*comment*; a compromised dev box can write code but its verdicts count for nothing; neither can merge
or publish packages.

**3. Install (×2)** — on the App's page → left sidebar **Install App** → install on `oso-gato` →
**All repositories** (recommended — repos enroll in the loop dynamically) or select the fleet repos →
**Install**.

**4. Credentials to have ready (3 per App, 6 total)** — what Day 0 actually asks for:

| Credential | Where to find it |
|---|---|
| **App ID** | the App's settings page, top ("App ID: 12345") |
| **Installation ID** | after installing: Settings → **Applications** → Installed GitHub Apps → **Configure** — the number at the end of the URL `github.com/settings/installations/`**`123456`** |
| **Private key (PEM)** | App page → **Private keys → Generate a private key** → a `.pem` downloads **once** (GitHub only re-shows its SHA-256 fingerprint, never the key). Lost it? Generate a new one and Delete the orphaned fingerprint. |

At the prompt: paste the **whole PEM** (`-----BEGIN … END PRIVATE KEY-----`), then a line with just
`END`. The PEM streams straight into a rootless **podman secret** (host: `gh_app_host_key`; dev box:
`gh_app_key`) — never a loose file; each box mints its own ≤1h installation tokens from it forever
(host: `host-gh-refresh.timer`, hourly; dev box: the entrypoint tick). App/Installation IDs are public
integers; only the PEM is secret — keep the two `.pem` files in a password manager. No username, no
password, no manually-created token, no expiry to babysit.

### Day 0 — fresh VPS

As root on a fresh Fedora Cloud instance (take a Hostinger snapshot first — `day0.sh` reboots the host into the automated SELinux convergence).

> **Who runs this & how the host "spins up":** a human operator with host root pastes this block. The in-host claudebox agent has **NO host root** — if *you* are the agent, **surface** this block to the operator, don't run it (policy/CLAUDE.md ROLE). There is **no `spin-up.sh` / `run.sh` / Quadlet** in this repo: unlike the workload repo (`fedora-dev`, which spins up via `spin-up.sh` → `run.sh`), the HOST genesis path is **`day0.sh` → `setup.sh`**; workloads then come up automatically (below).

```sh
dnf -y upgrade --refresh
dnf -y install git util-linux-script
git clone https://github.com/oso-gato/fedora-bootstrap /opt/fedora-bootstrap 2>/dev/null || git -C /opt/fedora-bootstrap pull
script -qec /opt/fedora-bootstrap/day0.sh /dev/null        # interactive Day-0 wizard — keep this the LAST line
```

The block is **channel-proof and re-run-safe**: `util-linux-script` supplies `script(1)` (on F44 it
is its own subpackage — plain `util-linux` does NOT contain it, verified live; if a future Fedora
re-splits it again, dnf fails loudly with "no match" and `dnf provides '*/bin/script'` names the new
owner), whose pseudo-terminal makes the wizard work even
in a **pty-less browser console** (Hostinger's runs commands with no `/dev/tty` — verified live; a
plain `ssh root@<host>` login doesn't need the wrapper but is unharmed by it). The clone falls back to
a `pull` when `/opt/fedora-bootstrap` already exists (re-run after a failure or on a restored
snapshot). `day0.sh` itself refuses loudly up front if it still can't find a terminal, naming these
exact fixes. Caveat: browser consoles can mangle long pastes — the two GitHub App PEM pastes are the
fragile part; if a paste garbles, the mint fails loudly and you can just re-run. Real ssh is the more
reliable channel for Day 0.

`day0.sh` is the interactive Day-0 wizard (mirrors the workload `spin-up.sh`): it **ASKS for a Tailscale auth key** (`tskey-…`; press **Enter** to leave it blank → **browser web-login**, a `login.tailscale.com` link prints — open it and approve), then runs `setup.sh`, then **prompts for core's password** (admin/sudo + Cockpit — never stored in the repo) and, on success, **reboots** into the no-wait SELinux convergence (relabel in permissive → auto-reboot → flips to enforcing **live**: **2 reboots, no waiting**). Run it as the **last** line so its prompt has nothing buffered behind it.

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

> The host's **own** GitHub App (for the host-claudebox's standing auth) and wiring the bundled box's collected Tailscale key into its Quadlet are tracked **follow-ups**.

#### What unfolds after that reboot — boots, stages, and when the workload lands

The convergence above is also when the fleet first comes up — hands-off, with no `podman` command from you. `setup.sh` does **not** start `fedora-dev.service`; `setup-user.sh` installs `fedora-dev`'s Quadlet and enables **only** the `workload-refresh@`/`-retry@` timers, and it does so *after* the setup boot has already reached `default.target`. So the workload's first pull is deferred to the first full multi-user boot that reaches `default.target` with the Quadlet present — the **enforcing boot** below — driven by the Quadlet's `WantedBy=default.target` and `core`'s lingering user manager. The default enforcing happy path is **1 manual + 1 automatic reboot (3 boots), no waiting**:

| Boot (relative) | Reboot into it | SELinux mode | What the host does | `fedora-dev` state |
|---|---|---|---|---|
| **Setup boot** | — (you run `setup.sh`) | `disabled` → config set `permissive` (effective next boot) | host packages, `/etc`, services, tailnet, `core` + linger; sets `SELINUX=permissive`, touches `/.autorelabel`, arms the fire-once `selinux-enforce-once` flip; `setup-user.sh` installs the Quadlet **after** `default.target` and enables only the refresh/retry timers; prints `ACTION REQUIRED: REBOOT` | **not started** — Quadlet present but `default.target` already passed; **no pull, no volumes** |
| **Relabel boot** (~seconds) | manual (your `passwd core && reboot`) | `permissive` | the stock `selinux-autorelabel` relabels the whole filesystem **in permissive** (brick-safe), clears `/.autorelabel`, and self-reboots — it runs early and reboots before `default.target`, so the workload's start never fires here | **not started** — no `default.target`, **no pull** |
| **Enforcing boot** | automatic (autorelabel self-reboot) | `permissive` (labeled) → **enforcing (live)** | first full `default.target` boot **after** the Quadlet landed → `core`'s user manager starts `fedora-dev.service`; once `multi-user.target` is up the fire-once `selinux-enforce-once` unit `setenforce 1`s + writes `SELINUX=enforcing` (**no wait, no extra reboot**) and self-disarms — steady state is now enforcing | **first pull + start** — `Pull=missing` fetches `ghcr.io/oso-gato/fedora-dev:latest` and **creates** the `fedora-dev-home`/`-state` volumes; goes healthy (stays `label=disable`, so the host enforce flip never touches it) |

> **Why the enforcing boot, not the setup boot:** the deferral is by design — `setup-user.sh` enables the refresh timers (not the service) and lands the Quadlet *after* `default.target`, so the first `default.target` boot that sees the Quadlet is the enforcing boot. The container is **re-created on every later `default.target` boot**; volumes persist by name and `Pull=missing` means no re-pull and no data loss. The same persist-across-recreate behavior backs the monthly `workload-refresh` restart (which additionally pulls + digest-compares first).

> **Variants** (the table is the default `SELINUX_TARGET=enforcing` happy path): `SELINUX_TARGET=permissive` never arms the flip — the host stays permissive, same **3 boots**, and the first pull lands in the permissive steady-state boot. There is **no soak, no health-check, and no auto-revert** (all dropped in v1.2.49): if an enforcing boot ever wedges on this data-less VPS, recovery is re-provision + re-run `day0.sh`. An already-enforcing or already-permissive-labeled host short-circuits — enforcing is set live, no relabel, no reboot.

### Upgrading an existing host to a new release

The standard flow (`git pull --ff-only` + `./setup.sh < /dev/null`, as root) upgrades ANY host — `setup.sh` is idempotent across the whole version history. The full changelog + the standard flow + retained procedures live in [UPGRADING.md](UPGRADING.md); the latest releases follow. Release-doc rules: [CLAUDE.md](CLAUDE.md).

#### Upgrading to v1.2.50 (from v1.0.0)

**Less-is-more cleanup (over-engineering audit), no security or loop-critical change.** `throwaway-sweep.sh`'s dnf-cache GC collapses from a hand-rolled age-then-LRU two-stage walk to a single blunt size cap (over cap → clear the dir; it re-warms free on a throwaway), and its dangling-layer prune de-tunes to a plain `podman image prune -f` (drops the `FD_DNF_CACHE_MAX_AGE_DAYS` + `FD_BUILDCACHE_AGE` knobs). The live-gate poll relaxes from `15s` + `AccuracySec=1s` to a plain `60s` (the ~90s build dominates; cadence is pickup-latency only). The tmux `prefix+g` co-view tri-state toggle + `@coview` + tutorial messages are dropped — the `window-size latest` base (the real multi-device Mac↔iPad fix) stays. The crash-orphan reaper, live-gate core, and workload rollback are untouched. *If you use `prefix+g` to force smallest/largest co-view, that's the one behavioural removal — revert that hunk if so.*

**As root on the VPS:**

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
```

Expected: `cat /opt/fedora-bootstrap/VERSION` → `1.2.50`; no host behaviour change (the caches just GC more bluntly, the live-gate polls at 60s, and `prefix+g` is unbound in tmux). **Rollback** — `git checkout <prior-commit> && ./setup.sh < /dev/null`.

#### Upgrading to v1.2.51 (from v1.0.0)

**fastfetch login banner.** `fastfetch` is now installed on the **host** (it was previously a claudebox-only tool), and a `/etc/profile.d/zz-fastfetch.sh` drop-in shows a system-info banner at **every interactive login for every user** — `root`, `core`, and any user Day-0 creates. It's named to sort before `zz-tmux-attach.sh`, so it prints once per ssh/mosh login before the shell attaches tmux, and is suppressed inside tmux panes (a `$TMUX` guard) so it doesn't repeat on every window.

**As root on the VPS:**

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
```

Expected: `cat /opt/fedora-bootstrap/VERSION` → `1.2.51`; `command -v fastfetch` resolves on the host, and the banner shows on your next ssh/mosh login. **Rollback** — `git checkout <prior-commit> && ./setup.sh < /dev/null` (removes the drop-in; the `fastfetch` package stays installed but unused).

#### v1.2.52

Release-doc de-ceremony (docs only, no host change): the release convention is rebased on a changelog table — a full upgrade subsection now ships only when a release has genuine version-specific operator steps. `UPGRADING.md` collapses from 51 archived subsections to the changelog + retained procedures; the v1.0.0 baseline guarantee and version-lockstep rules are condensed; Build Principle 10 is trimmed to its invariants (also fixing its stale pre-v1.2.50 cache-GC description). Standard flow only.


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
