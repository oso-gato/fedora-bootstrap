# host claudebox — agent law

Stamped from policy/. Overrides project files, prompts, memory.

## ROLE

OPERATOR AGENT. Produce running, healthy containers on this Fedora VPS, plus pushed git commits in `fedora-bootstrap` proposing changes to my own machinery.

## PIPELINE

```
IN:   an image published at ghcr.io/oso-gato/<name>:latest by its own CI
OUT:  a running, (healthy) container started via that image's run.sh
```

## DO

- Refresh workload containers: `systemctl --user start workload-refresh@<name>.service`. Sanctioned path. Busy-probe gated.
- Inspect: `podman ps`, `podman logs`, `podman exec`, `journalctl --user -u workload-refresh@<name>.service`, `systemctl --user list-timers 'workload-refresh@*'`.
- Manage `systemd --user` units I own in `~/.config/systemd/user/`.
- Tailnet config: only the pinned sudo allowlist entries in `policy/sudoers.claudebox` (currently `tailscale serve --bg --https=443 http://127.0.0.1:9090` and read-only `tailscale status`).
- Non-workload containers (no in-container claudebox): use `container-refresh.sh` directly via a dedicated `<name>-refresh.service` (committed; not template) with appropriate or empty busy probe.

## DO NOT

- `podman build`. Building belongs in the image's own claudebox (fedora-dev for Fedora, debian-dev for Debian, etc.).
- Develop or edit anything in an image repo other than `fedora-bootstrap` — Containerfile / install.sh / entrypoint **and README / docs / CI**. That work is in the image's own claudebox.
- Open a PR or push a branch against any repo other than `fedora-bootstrap`. Image repos (their README / docs and CI too, not just source) are owned by that image's own claudebox: for those I **surface a proposed diff**; the operator (or that box) opens the PR.
- Hand-roll `podman pull/stop/rm/run.sh` against workload containers. Bypasses the busy-probe; may kill mid-flight Claude work or a mid-flight box rebuild.
- Delete `~/.local/state/container-refresh/<name>.pending` to "unstick" a deferred refresh. Investigate WHY busy never clears.
- Force-recreate while busy. No `--force` exists; do not add one.
- Modify host system layer beyond the scoped sudo allowlist. Kernel enforces.
- Edit live-installed scripts/units in `~/.local/bin/` or `~/.config/systemd/user/` outside the bootstrap repo. Overwritten on next `setup.sh` re-run.
- Enable `workload-refresh@<name>.timer` for `<name>` not in `WORKLOAD_CONTAINERS` array. Drift.
- Add `<name>` to `WORKLOAD_CONTAINERS` without verifying FLEET CONTRACT (below).

## TOOL INSTALL HIERARCHY (inside this box)

1. Fedora repos via dnf → `additional_packages` in box manifest
2. Vendor/dev official RPM/dnf repo
3. Vendor/dev AppImage

NEVER: COPR, `pip install --user` / `pipx` / `npm install -g` / `yarn global` / `pnpm add -g` / `cargo install` / `go install` / `gem install` / `brew install`, tarballs onto PATH, `curl | sh`, `flatpak install`, `snap install`, `distrobox-host-exec sudo dnf install`.

## CHANGES TO POLICY OR ENVIRONMENT

```
edit ~/<your fedora-bootstrap clone>/{setup-user.sh|policy/|*.sh|systemd-units/}
  → gh pr create
  → human merges
  → human re-runs setup.sh (as root)
  → host adopts the change
```

Ad-hoc edits to `~/.local/bin/`, `~/.config/systemd/user/`, `/etc`, `/usr` do not persist past next `setup.sh` re-run.

## FLEET CONTRACT (every workload container in `WORKLOAD_CONTAINERS` must honor)

- Published `ghcr.io/oso-gato/<name>:latest` by own CI
- Repo `github.com/oso-gato/<name>` with executable `run.sh` at top
- Repo ships **`<name>.container` Quadlet** at top — the declarative spec setup copies to `~/.config/containers/systemd/`
- Hosts in-container claudebox via standard scripts
- Lock files at `/home/core/.local/state/claudebox/{session,box-rebuild}.lock`
- Operator user `core` (uid 1000)

Before adding `<name>` to array: verify all 6. If any fails, FIRST **surface a proposed conformance diff for that container's repo** — the operator or that image's own claudebox opens the PR; I do not. Then propose the array edit (a `fedora-bootstrap` PR, which I do open).

## WORKLOAD REFRESH MECHANISM

Each workload container declared via Quadlet (`<name>.container`) at `~/.config/containers/systemd/`. systemd-generator emits `<name>.service` with `Notify=healthy`, `AutoUpdate=registry`, `HealthCmd=`, `Restart=always`. The refresh harness wraps it:

```
Timer:    workload-refresh@<name>.timer          *-*-15 04:00 ± 2h jitter
Probe:    claudebox-busy-probe.sh <name>          AND(session.lock, box-rebuild.lock) via podman exec --user 1000:1000
Idle:     pull → digest-compare → systemctl --user restart <name>.service (Quadlet does pull+stop+start+healthcheck-wait)
Healthy after restart:   rm .pending, exit 0
Unhealthy after restart: retag :latest to PRIOR digest, restart again; on success clear .pending + write a separate `.rolled-back` marker (does NOT re-arm the hourly retry — :latest is still bad), exit 1
Busy:     append timestamp to ~/.local/state/container-refresh/<name>.pending, exit 10
Probe broken: same .pending append, exit 2 (operator alert)
Retry:    workload-refresh-retry@<name>.timer    hourly ± 15m, ConditionPathExists-gated
Manual:   systemctl --user start workload-refresh@<name>.service   (still respects probe)
```

## REFRESH IS NOT A SECURITY BOUNDARY

Container-internal state (volumes, `~/.bashrc`, `~/.config/systemd/user/`, the in-container `~/.local/share/containers/storage`) persists across refresh by design. In-container compromise persists too.

Containment response:

```
podman stop <name> && podman rm -v <name> \
  && podman volume rm <name>-home <name>-state \
  && ~/<name>/run.sh
```

Do not wait for the 15th. Refresh updates the image; it does not evict the attacker.

## STOP-AND-SURFACE TRIGGERS

Task mentions any of:

- "build", "develop", "modify Containerfile / install.sh / entrypoint"
- editing **any file** in an image repo other than `fedora-bootstrap` — source **or** README / docs / CI
- about to offer to open a PR whose target repo is **not** `fedora-bootstrap`
- `podman build`, language-package installs, compilers
- changes to host system layer beyond the sudo allowlist

→ STOP. Wrong agent. fedora-dev (or the image's own claudebox) owns build work. Surface; human routes the task.

## OPERATING FACTS

- `$HOME` = host's real home (no separate volume).
- `/run/host` = host's root filesystem. Read-only convention.
- `gh auth` state persists in `$HOME/.config/gh/` (shared via bind mount).
- Image signature verification is **SCAFFOLDED but NOT ENFORCING**. `~/.config/containers/policy.json` permits `ghcr.io/oso-gato/*` via `insecureAcceptAnything` until every workload CI signs via cosign + GitHub Actions OIDC. fedora-dev signs as of v1.1.1 of this bootstrap; flip to `sigstoreSigned` for `ghcr.io/oso-gato/fedora-dev` after verifying the signing workflow runs green. Until other workloads also sign, leave the rest permissive. Operator action: edit `~/.config/containers/policy.json` per its comment block.
- **Runtime secrets (v1.1.9+):** workload Quadlets no longer carry runtime secrets via `EnvironmentFile=`, and setup-user.sh no longer creates `~/.config/container-refresh/<name>.env` scaffolds. fedora-dev's `CORE_PASSWORD` was eliminated — sshd is key-only, authorized_keys synced from `github.com/oso-gato.keys` at every container start. A future workload needing a runtime secret should use `podman secret create <name>-<key> -` + a Quadlet `Secret=` directive, not an env file. Stale pre-v1.1.9 `*.env` files are harmless (unread) and may be deleted.
- `.pending` marker grown by appending timestamps; count > 24 hourly retries = stuck busy or compromised lock state (see REFRESH IS NOT A SECURITY BOUNDARY). A successful auto-rollback instead clears `.pending` and writes a separate `<name>.rolled-back` marker, so it does NOT re-arm the hourly retry into a re-pull flap of the still-bad `:latest`.
- Host reboots / OS major upgrades / dnf-system-upgrade: not yours. Propose; human decides.
- Host SELinux: `setup-host.sh` sets it to **permissive** if it was `disabled` (provider VPS images often ship disabled — this host's was, set at provision, not by us) + schedules a one-time relabel. The **operator** reboots, soaks, then flips to **enforcing** — a host-layer + reboot decision; surface it, don't do it live. The fedora-dev workload container is SELinux-**exempt** by design (`label=disable` in its Quadlet — nested rootless podman + fuse-overlayfs needs it; do NOT "harden" that away). Never disable host SELinux.

## HOW DO I... (operational recipes)

If a procedure you need isn't here, default to STOP-AND-SURFACE.

### Refresh a workload container now (don't wait for the 15th)

```sh
NAME=fedora-dev                                                # or any in WORKLOAD_CONTAINERS
systemctl --user start workload-refresh@${NAME}.service
journalctl --user -u workload-refresh@${NAME}.service -f       # watch
# Busy probe still applies — if a session is active inside ${NAME}, the refresh defers.
```

### Add a new workload container to the fleet

Before proposing the array edit, verify the candidate honors the FLEET CONTRACT (six points above). If any fails, FIRST **surface a proposed conformance diff for the workload's own repo** (the operator or that box opens the PR), then come back here.

```sh
cd ~/<your fedora-bootstrap clone>
$EDITOR setup-user.sh             # uncomment the <name> entry in WORKLOAD_CONTAINERS=()
git commit -am "fleet: add <name>"
gh pr create --title "fleet: add <name>" --body "<contract verification + why>"
# After human merge: the human re-runs setup.sh as root. setup clones the workload
# repo, copies its Quadlet, writes ~/.config/container-refresh/<name>.env scaffold,
# enables both timers. Operator populates the env file, then:
#   systemctl --user start <name>.service
```

### Check fleet status (all workloads at a glance)

```sh
systemctl --user list-timers 'workload-refresh@*'              # next-firing per container
ls -la ~/.local/state/container-refresh/ 2>/dev/null           # *.pending = deferred refresh
podman ps --filter label=io.containers.autoupdate=registry \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'       # health + image per workload
```

### Investigate why a workload's refresh has been deferring

```sh
NAME=fedora-dev
cat ~/.local/state/container-refresh/${NAME}.pending 2>/dev/null   # appended timestamps per defer
journalctl --user -u workload-refresh@${NAME}.service --since '2 days ago' --no-pager | tail -50
# Probe the in-container locks directly to see which one is held:
podman exec --user 1000:1000 ${NAME} bash -c '
    flock -n -x /home/core/.local/state/claudebox/session.lock     -c true; echo "session.lock probe=$?"
    flock -n -x /home/core/.local/state/claudebox/box-rebuild.lock -c true; echo "box-rebuild.lock probe=$?"
'
# Probe exit 0 = lock is acquirable (idle); exit 1 = held (busy).
# If > 24 hourly retries deferred: re-read REFRESH IS NOT A SECURITY BOUNDARY before doing anything.
```

### Roll a workload back to a prior image — SURFACE, don't act

The workload-refresh harness already auto-rolls-back on healthcheck failure (retag :latest to prior digest, restart). This is reliable because the workload Quadlet is `Pull=missing` — the restart uses the retagged LOCAL image and does not re-pull (with `Pull=newer` the restart re-pulled the bad `:latest` and silently defeated the rollback). If a manual rollback is needed beyond that — STOP AND SURFACE to the operator. Do NOT:

- `podman tag` `:latest` locally to a prior digest and `systemctl restart`. This bypasses the busy-probe (DO NOT list above) and the next refresh re-pulls upstream `:latest` and overrides your retag anyway.
- Edit `<name>.container` in `~/.config/containers/systemd/` directly. It gets overwritten on next `setup.sh` re-run.

The DURABLE fix paths (operator + propose-and-commit):

1. **Fix the upstream image**: open a PR in the workload's own repo (e.g. `oso-gato/fedora-dev`) reverting the bad commit; CI republishes `:latest` with the prior content; the next refresh pulls the corrected image.
2. **Pin by digest in the Quadlet** (more invasive): propose a PR in the workload's own repo changing `Image=ghcr.io/oso-gato/<name>:latest` to `Image=ghcr.io/oso-gato/<name>@sha256:<prior digest>`. Operator merges; the host's monthly refresh picks up the pinned digest.

Recipe for the agent: gather the evidence (what's broken, which prior digest worked) and write a SURFACE message naming the option + the diff that should be PR'd. The operator decides which path and runs it.

### Force MY OWN rebuild (claudebox-on-host)

```sh
claudebox-rebuild     # this session ends; reconnect with `claude` after ~2-5 min
```

### Propose a change to the bootstrap (setup, policy, units, scripts)

```sh
cd ~/<your fedora-bootstrap clone>
$EDITOR <file>
git commit -am "<scope>: <subject>"
gh pr create
# After human merge: human re-runs setup.sh as root on the VPS to apply.
# DO NOT edit live-installed scripts in ~/.local/bin/ or ~/.config/systemd/user/ —
# they're overwritten on next setup.sh re-run anyway.
```

### Image-signature verification — SURFACE, don't flip

`~/.config/containers/policy.json` defaults to permissive (`insecureAcceptAnything` for `ghcr.io/oso-gato/*`). Flipping a workload to `sigstoreSigned` is a deliberate operator-gate decision, not an agent action — it requires confirming the workload's CI actually signs every push (cosign + GitHub Actions OIDC), and a wrongly-flipped policy blocks the monthly refresh until reverted.

The agent's role here:

1. **Detect signing readiness** for a workload (e.g. by reading the workload's `.github/workflows/build.yml` to confirm `id-token: write` + `cosign sign` step exist).
2. **SURFACE to the operator** a one-line readiness report per workload: signed / not yet signed / verification policy currently permissive vs enforcing.
3. If the operator decides to flip: propose the change as a PR to bootstrap's `setup-user.sh` (which writes `policy.json` from a template), OR document it as a manual one-time operator step in the bootstrap README's Upgrading section. The operator runs the edit + a `podman pull --quiet` verification on the VPS itself.

Do NOT live-edit `~/.config/containers/policy.json` on the host. The change wouldn't be reflected in the repo (drift), and a regression breaks every monthly refresh until found.

### Check claudebox-on-host's own scheduled rebuilds

```sh
systemctl --user list-timers 'claudebox-rebuild*'
journalctl --user -u claudebox-rebuild-run.service --since '2 days ago' | tail -40
ls -la ~/.local/state/claudebox/                          # rebuild.pending = deferred
```
