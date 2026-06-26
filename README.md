# fedora-bootstrap

## TL;DR — in plain words

One script that turns a fresh cloud server into your **"mother platform"** — a locked-down host that runs your whole fleet of container apps. Its on-board Claude (the "host claudebox") has **two standing jobs**: it **operates the host** (including starting and removing containers), and — being the only thing that watches the apps run *live* — it **diagnoses them and proposes fixes**. It's one of **three boxes**: this host box **operates + diagnoses**, `fedora-dev` **builds + merges**, the desktop box **builds its own tools**. All three **open PRs; only `fedora-dev` merges** — on your one click.

- 🔑 **How you get in:** key-only SSH/Mosh from anywhere; the admin console (Cockpit) and everything sensitive are reachable only over your private Tailscale network.
- 🏭 **Maintaining the host:** keeps it minimal and treated-as-immutable; every app runs as a container pulled from your registry, auto-refreshed monthly with **automatic roll-back** if a new version comes up unhealthy. The host claudebox operates the fleet.
- 🔧 **What it can change:** because it's the only box watching the apps run live, it can **diagnose any container it runs and propose a fix** (a PR) to that app's code — including the foundation it stands on. But it **stops at the proposal**: it never merges its own change. `fedora-dev` merges it, on your click.
- 🚧 **The split:** it **never builds** images (CI does), **never merges** (`fedora-dev` does), and **never edits the live host** by hand — you re-run the setup script as root to apply. "Proposing a change" is never "applying it."
- 🔒 **No secrets in the repo.**

Version: **1.2.27** — **Live-gate loop closed — fedora-dev labels a PR, the host builds + gates it, and posts the verdict back.** `live-gate-run.sh` gates one PR (build the candidate disposably → `validate-candidate.sh` Gate B → `gh pr comment` the GREEN/RED verdict; the host **comments, never merges**). `live-gate-watch.sh` (a `systemd --user` timer) polls `live-validate`-labelled PRs, dedups per-commit, and invokes the runner — running a **disposable** container that never touches the live workload, so it is **not gated on the dev session** (validation runs *while* fedora-dev is in active use — the loop's point). **Proven end-to-end: a labelled fedora-dev test PR was built-from-source + gated GREEN and the verdict posted back to the PR; the watcher discovered + deduped it.** Closes the loop — fedora-dev opens/labels a PR → host builds + gates + verdicts → fedora-dev iterates (RED) or you merge (GREEN), human at exactly one point. Prior: v1.2.26 — **Live-gate builder — the host can now build a PR candidate disposably and gate it (the loop's linchpin).** `build-candidate.sh` exports a PR ref to a **throwaway source tree** (`git archive` → temp dir, no clone mutation), `podman build`s a **disposable** candidate (`localhost/disposable/<name>:val-<sha>`; default isolation works on the host's native-overlay top-level engine — no `--isolation=chroot`), hands it to `validate-candidate.sh` (Gate B), then `rmi`s it (base layers stay cached for the next churn). **Proven end-to-end: the host built fedora-dev from source and gated it GREEN** — the pre-merge build→gate path CI (no PR publish) and the dev box (can't live-run PID-1) cannot do. `setup-user.sh` now installs `build-candidate.sh` + `validate-candidate.sh` (the latter was an uninstalled orphan). Sanctioned by the v1.2.25 carve-out — never pushed, never deployed. Prior: v1.2.25 — **Policy carve-out — the host may now build _disposable validation_ images.** The host law (`policy/CLAUDE.md` + project `CLAUDE.md`) is split into two classes: building a **shipping** image (published/pushed/deployed) stays **always CI's job, never on the host**; building a **throwaway validation** image is now **permitted** — *solely* to live-test an open PR **before merge** (CI publishes nothing pullable on an open PR, and the dev box's nested engine can't live-run a PID-1 image, so the host is the only surface that gives a faithful pre-merge verdict). Permitted only when `localhost/disposable/*`-tagged (never a `ghcr.io/oso-gato` deploy ref), **never** `podman push`ed (the host holds no `write:packages` credential), run `--rm` + `rmi`'d, never a `WORKLOAD_CONTAINERS` member — exactly what `validation/rollback-spike.sh` already does. **The deploy path + shipping-image provenance are unchanged** (CI-built + cosign-signed). Prior: v1.2.24 — **Default effort — the host claudebox now starts every session at ultracode.** The `claude` wrapper injects `--settings '{"ultracode":true}'` so each session begins in **ultracode** (`xhigh` effort + workflow-by-default), and `policy/managed-settings.json` gains a top-level `"effortLevel": "xhigh"` as the persistent floor for any path that doesn't go through the wrapper (subagents, a direct `/usr/bin/claude`). Ultracode is **session-scoped and ignored in settings files**, so the wrapper is the only place it can be made a default. With v1.2.20's `defaultMode: auto`, a fresh `setup.sh` re-run now brings the box up **in auto mode at ultracode with no per-session action** — completing the autonomous-defaults set. The **merge gate is unchanged** — the `gate-push.sh` `ask` hook, the `git push` / `gh pr merge` deny rules, and `disableBypassPermissionsMode` all remain. Prior: v1.2.23 — **Loop gate B proven — the pre-merge live candidate gate is faithful.** `validate-candidate.sh` is parameterized: `CAND_FENCE` supplies the candidate's run-contract (caps/devices, minus public ports + real secrets; default = hardest untrusted fence) and `CAND_PROBE` is the "does it actually serve" assertion, run on the candidate's OWN loopback via `podman exec`. Demonstrated faithful — a correctly-serving candidate **PASSES**, while one that is *healthy but serves HTTP 500* is caught by the probe and **FAILS** (the access-path probe is load-bearing, not just health). Validation tooling; no production behavior change. Prior: v1.2.22 — **Loop gate A proven — the deploy-resilience rollback backstop fired for the first time.** `validation/rollback-spike.sh` now goes **GREEN**: a never-healthy `:latest` is retagged to the prior digest, restarted, and recovers with a `.rolled-back` marker. Two reusable fixes it surfaced — the spike's throwaway Quadlet now uses an explicit `HealthCmd=` (OCI drops a built image's `HEALTHCHECK`), and `container-refresh.sh` gains a **`BUSY_PROBE` seam**: default unchanged (the claudebox probe), overridable to an empty probe for non-claudebox workloads (the documented mechanism, previously missing). No production behavior change. Prior: v1.2.21 — **Fix — the image-trust `policy.json` writer produced an invalid `containers-storage` entry that broke every pull.** `setup-user.sh` wrote `"containers-storage": [ … ]` (a bare requirements array) where containers-image requires a scope→requirements **object** `{ "": [ … ] }`; podman rejected the entire policy (`JSON object expected, got 91`), so no `ghcr.io/oso-gato` image could be pulled and `fedora-dev` was stuck restart-looping. Both writers are fixed, the idempotent merge now **repairs an already-broken host in place**, and a fail-closed structural check rejects any non-object transport. Prior: v1.2.20 — **Auto mode — the host claudebox now defaults to the `auto` permission mode.** `policy/managed-settings.json` drops `"disableAutoMode": "disable"` and adds `"defaultMode": "auto"`, so in-box Claude sessions start in auto mode — no routine permission prompts, with a background classifier vetting each action before it runs. The **merge gate is unchanged**: the managed `gate-push.sh` `ask` hook, the `git push` / `gh pr merge` deny rules, and `disableBypassPermissionsMode` all remain, so nothing reaches `main` without your explicit approval. Re-stamped into `/etc/claude-code/managed-settings.json` on every `setup.sh` run. Prior: v1.2.19 — **Policy — permit the class-(a) Fedora base + local copy for host-validation fixtures.** The host image-trust `policy.json` (default `reject`, previously trusting only `ghcr.io/oso-gato/*`) gains two scoped entries — the class-(a) Fedora base `registry.fedoraproject.org/fedora` (so the `validation/` host-validation spikes+gates can pull stock Fedora test fixtures) and the `containers-storage` transport (local `save`/`load` for the throwaway tar cache those fixtures live in). The **production run-set is unchanged** — workload Quadlets reference only `ghcr.io/oso-gato/*`, `default` stays `reject`, and the `docker` `""` fallback stays `reject`; this widens only what may be *pulled* for disposable host-validation, not what *runs*. `setup-user.sh` writes it fresh on a new host and **idempotently/additively** merges the two entries into an existing `policy.json` without clobbering operator edits (same `insecureAcceptAnything` posture as the `oso-gato` stanza; both upgradeable to `sigstoreSigned` in lockstep later). Prior: v1.2.18 — **tmux single-group — fix the multi-client geometry-race garble.** ssh/mosh/tmux output garbled (input + output) on every client except a freshly-relaunched native macOS terminal. Root cause: every login funnelled into ONE shared session and, with no `tmux.conf`, `window-size=latest` resized that shared window to whichever client was active last, painting the others onto a foreign grid. Now each login gets its **own session inside one shared `main` tmux GROUP** — every client **shares the windows** but keeps **independent geometry/redraw** (no race) — plus a new `/etc/tmux.conf` (`default-terminal tmux-256color`, `window-size smallest`, `aggressive-resize on`, `client-attached`/`-resized` → `refresh-client`). A single `main` group (not per-`LOGIN_KEY`) is deliberate: the primary path is **keyless Tailscale SSH**, which never sets `LOGIN_KEY`, so a per-key model would collapse to `main` on the tailnet anyway *and* fragment the workspace across access methods — one group = one continuous workspace over tailnet ssh, public ssh, and mosh (`LOGIN_KEY` retained for audit only). Identical model to `fedora-dev`'s fix. Prior: v1.2.17 — Docs: add `FLEET.md` (the swarm map) + a "Where this sits — the fleet" table to the README (no host behavior change; identical `FLEET.md` across all three repos — the human-readable mirror of the `policy/CLAUDE.md` `THE FLEET` block). Prior: v1.2.16 — a Day-0 wizard (`day0.sh`) that ASKS for the Tailscale auth key**, mirroring the workload `spin-up.sh`. Run it as the last Day-0 line: it reads the key from the terminal (**Enter** = browser web-login), runs `setup.sh`, then prompts for core's password and reboots into the SELinux convergence (`SELINUX_TARGET=permissive` ⇒ no reboot). **`setup.sh` is unchanged** — it still honors env `TS_AUTHKEY` and never reboots, so the fully-scripted `TS_AUTHKEY=… setup.sh < /dev/null` + `passwd core && reboot` path still works. Prior: v1.2.15 — spin-up path made explicit; v1.2.14 — day-0 TS_AUTHKEY prompt; v1.2.13 — docs cleanup (scrub deleted-repo refs); v1.2.12 — FLEET governance (3-box model, host PR-only, `fedora-dev` sole merge box); v1.2.11 — BUILT promotion gate (managed `PreToolUse` hook + hardened `managed-settings.json` + CI diff-guard); v1.2.10 — HEADLESS binding prerequisite fleet-wide; v1.2.9 — Principle 3 (MINIMAL) refined fleet-wide (*"minimum" is relative to the chosen capability* + disclosed irreducible hard-dep closure; a lighter option that *reduces* function — e.g. noVNC vs Guacamole's RDP-grade web gate — is a recorded **capability trade-off, not a minimalism win**); v1.2.8 — Principle 2(c) bounded official-upstream-binary class; v1.2.7 — PR-first + maintainer-approved-merge maintainership; v1.2.5 — `verify.sh` fail2ban euid-gate fix; v1.2.4 — genesis/mother-platform role + `fedora-dev` maintainership.

## Where this sits — the fleet

**This repo is the `fedora-bootstrap` box** of a three-box swarm — **the genesis / mother-platform box** that operates the VPS host and live-diagnoses the containers on it; PR-only. Full map: **[FLEET.md](FLEET.md)**.

| Box | Role | Builds? | Merges? | Operates host? | Spin up |
|-----|------|:--:|:--:|:--:|---------|
| **fedora-dev** | develop · build · **merge** | ✅ nested | ✅ **(sole merger)** | ❌ | `./spin-up.sh` |
| **fedora-bootstrap** *(this one)* | operate host · live-diagnose → PR | ❌ (CI) | ❌ PR-only | ✅ incl. create/remove | `./day0.sh` (Day-0) |
| **fedora-desktop** | knowledge-work + own toolset → PR | ❌ (CI) | ❌ PR-only | ❌ | `./spin-up.sh` |

This box **operates the host and proposes fixes (PRs) — it never merges**; `fedora-dev` merges on Arthur's **clickable APPROVE**. The host genesis path is `day0.sh` → `setup.sh` (no `spin-up.sh`/`run.sh` here). See [FLEET.md](FLEET.md) for the handoff + boundaries.

> **Headless (binding prerequisite).** There is never a screen plugged into this server, and there is no "log in at the console" — the host is a remote cloud VPS you only ever reach over the network. Every desktop the fleet serves (Obsidian, VS Code, the browser) is drawn by software on a *virtual* screen inside a container and streamed to you over RDP/VNC/the web gate; nothing in the design may ever assume a real monitor, graphics card, or sit-down seat. If something needs one, that's a bug to fix, not a setting to toggle.

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
