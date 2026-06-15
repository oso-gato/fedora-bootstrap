# fedora-bootstrap — agent rules for editing this repo

## BEFORE ANY CHANGE

Read README.md for human-facing context (what this bootstrap is, what it
provides, how operators use and maintain it). THIS file (CLAUDE.md) carries
the binding agent-facing tables (BUILD PRINCIPLES, REPO FILE PURPOSES,
PACKAGES) and the release/doc procedures.

`policy/CLAUDE.md` + `policy/managed-settings.json` + `policy/sudoers.claudebox`
are the law stamped into the host claudebox at runtime — editing them in
THIS repo is the ONLY way they change.

Host immutability is the core doctrine: the PACKAGES table below is the
complete sanctioned host footprint. Never grow it without an explicit user
waiver recorded as a new row.

The managed-settings.json deny list is best-effort defense-in-depth only —
argument-shaped Bash deny rules are prefix-fragile (dnf5, /usr/bin/dnf,
host-spawn, arg reordering all evade them). The AUTHORITATIVE
host-immutability gate is the password-gated sudo + the scoped allowlist in
policy/sudoers.claudebox. Never weaken sudoers on the assumption the deny
list is the boundary — it is not.

## PIPELINE CONTEXT

Images developed in fedora-dev / debian-dev containers, CI-built on GitHub,
GHCR-published. claudebox (this repo's product) pulls and operates them on
the host — never builds.

## RELEASING A NEW VERSION

Every change that ships ANY visible delta (code or doc) gets a version bump
and a tag. Sequence:

1. Apply the change (scripts, units, policy, distrobox.ini, README, etc.).
2. Bump version markers IN LOCKSTEP — they must agree:
   - `VERSION` file at repo top
   - `setup.sh` header comment (line near top: `# Version: X.Y.Z (one-line summary)`)
   - README front-matter `Version: **X.Y.Z** — ...` line
3. Add a README "Upgrading to vX.Y.Z" subsection per the RELEASE-DOC
   CONVENTION below.
4. Commit (single commit per release; do not batch multiple releases).
5. `git push origin main`.
6. `git tag -a vX.Y.Z -m "vX.Y.Z: <subject>"` then `git push origin vX.Y.Z`.

Semver: patch for any user-visible change including pure docs; minor for
additive features that don't break existing usage; major for breaking
changes. Doc-only fixes still patch-bump.

Tags are immutable once pushed. Never `git tag -f` to amend a released tag.
A mistake in a tagged release ships as a new patch release with a subsection
pointing back to the issue.

## RELEASE-DOC CONVENTION (binding)

README has a top-level section "Upgrading an existing host to a new release".
EVERY release adds a subsection inside it. Prior versions' subsections are
historical record — never modify them after their tag is pushed.

Subsection title:
- `"Upgrading to vX.Y.Z (from v1.0.0)"` — default. v1.0.0 is the binding
  baseline; every code-bearing release MUST support starting from there.
- `"Upgrading to vX.Y.Z (from vA.B.C and later)"` — ONLY when the release
  genuinely cannot support v1.0.0 as a starting point (destructive
  migration, removed-then-restored capability, etc.). REQUIRES surfacing
  the constraint to the user BEFORE writing the subsection.
- `"Upgrading to vX.Y.Z through vX.Y.W (from v<last code-bearing>)"` —
  consolidated doc-only patch runs; presumes the user already followed
  the prior code-bearing release's subsection.

## v1.0.0 BASELINE GUARANTEE (binding)

By default, every per-version subsection for a code-bearing release MUST
support v1.0.0 as a valid starting point. `setup.sh` is designed to be
idempotent across the entire version history — re-running on a v1.0.0
host installs all intermediate deltas (every `setup-host.sh` + every
`setup-user.sh` phase) in a single pass, and the per-release operator
steps (env file population, container migration, etc.) compose with the
same standard upgrade flow.

This is a HARD default, not a soft suggestion. When drafting a new
release's upgrade subsection:

1. Default the heading to `(from v1.0.0)`.
2. Verify mentally (or by walking the diff against v1.0.0) that the
   `setup.sh` re-run + the version-specific operator steps cleanly take
   a v1.0.0 host to the new version. If yes, ship it.
3. If you discover the upgrade GENUINELY cannot start from v1.0.0
   (because some intermediate release performed a destructive migration
   the new setup.sh can no longer redo, or because of an OS-level
   constraint that broke a prior assumption): **STOP. Do not write the
   subsection.** Surface the constraint to the user with:
   - what the specific blocking factor is
   - the minimum starting point that works
   - whether a multi-step upgrade path (v1.0.0 → vA.B.C → new) can be
     documented as a workaround
   Let the user decide whether to relax `from v1.0.0`, document a
   multi-step path, or refactor setup.sh to restore v1.0.0 starting
   compatibility.

If the heading reads `(from vA.B.C and later)` for any reason other than
"the user explicitly accepted that this release cannot support v1.0.0",
that is a violation of this rule.

Examples named explicitly:
- `"Upgrading to v1.1.1 (from v1.0.0)"` — code-bearing release; v1.0.0
  fully supported per the analysis in the prose intro.
- `"Upgrading to v1.1.2 through v1.1.7 (from v1.1.1)"` — consolidated
  doc-only patch run, presumes v1.1.1.
- `"Upgrading to v2.0.0 (from v1.5.0 and later)"` — hypothetical breaking
  release where v1.0.0 cannot be a starting point because v1.5.0
  permanently migrated something that v2.0.0 needs to be already migrated.
  This kind of heading REQUIRES the prior user-discussion step.

Subsection structure, in this order:

1. **Prose intro** — what this release adds at the operator-visible level
   and what assumptions the upgrade block makes (e.g., "this assumes
   fedora-dev was previously deployed via run.sh; if not, step 3 is a
   fresh-install path").
2. **One self-contained `sh` code block** the operator pastes ONCE into the
   VPS root terminal. The block always contains, in order:
   - **Standard upgrade flow**: `cd /opt/fedora-bootstrap`, `git pull
     --ff-only origin main`, `./setup.sh < /dev/null`. `setup.sh` is
     idempotent — re-running on an existing host picks up new phases,
     files, units, policies without disturbing existing state. Volumes
     persist by name; existing systemd units are re-stamped.
   - **Version-specific operator steps** — anything `setup.sh` can't or
     shouldn't do (env-file population, pre-Quadlet container migration,
     retiring deprecated units, etc.). OMIT this part if the release has
     none.
   - **Verification commands** with expected output. State the expected
     output (active/running, healthy, timer next-firing, etc.) in prose
     adjacent to or after the block.
   - **Rollback recipe** — how to revert to the prior running state if the
     upgrade fails midway. Must work even after a partial run.

NEVER:
- Break the standard upgrade flow into a separate code snippet in the
  README "Upgrading" section's intro or anywhere else. The per-version
  block is the SINGLE paste target on the page. Duplicating it as a
  standalone snippet creates an incomplete-paste foot-gun.
- Put release-doc-writing rules in README. They live HERE (this file).
  README's Upgrading-section intro is a short human-facing pointer with no
  rules, no convention text, no structural description.
- Modify a prior version's subsection after its tag is pushed. If a doc
  fix is genuinely needed, ship a new patch release that adds a NOTE under
  the prior subsection AND links to that note from the new release's
  subsection.

CONSOLIDATION ALLOWED for runs of doc-only patches:
- When a series of consecutive patch releases (e.g. v1.1.2 through v1.1.7)
  contains NO code changes — only README/CLAUDE.md/docs refinements — a
  SINGLE combined subsection titled "Upgrading to v1.1.X through v1.1.Y
  (from v1.1.<lower>)" is acceptable in place of one subsection per
  patch. The combined subsection still follows the standard shape (prose
  intro stating "documentation-only patches", one code block with the
  standard upgrade flow, no version-specific steps section since there
  are none). When the next code-bearing release ships (e.g. v1.2.0 or
  v1.1.8 with actual code), the consolidated subsection is CLOSED — the
  new release gets its own full subsection.

## README "UPGRADING" INTRO SHAPE

The intro under the top-level "Upgrading an existing host to a new release"
heading is two-or-three lines max, human-facing, structurally:

- Tells the reader each release has a subsection below
- Tells the reader to find their target version and paste its single code
  block
- Cross-references THIS FILE for the rules

Nothing else goes between the top-level heading and the first per-version
subsection.

## BUILD PRINCIPLES (binding for every code change)

| # | Principle | Rule |
|---|---|---|
| 1 | TARGET | Fedora Cloud Base, pinned latest stable (image tag in distrobox.ini, host assumptions documented in README). Bump deliberately, per rule 3. |
| 2 | SOURCES | Host and box install only from: (a) Fedora repos via dnf (RPM); (b) the vendor's/developer's official RPM/dnf repo; (c) at worst a developer/vendor AppImage. Never curl-pipe-sh, language package managers onto PATH, tarballs onto PATH, third-party repos. Exceptions only by explicit user waiver recorded as a new row in the PACKAGES table below. Current waivers: none. |
| 3 | VERIFY FIRST | Fact-check any source/version against the live source before changing it. |
| 4 | HOST MINIMAL & IMMUTABLE | The PACKAGES table below is the complete sanctioned host footprint. Anything else runs in a container or in claudebox. Host installs beyond it require an explicit user waiver, recorded as a new row. |
| 5 | NO SECRETS | No passwords, keys, or tokens in this repo, ever. Tailscale auth is interactive or via TS_AUTHKEY env at run time. |
| 6 | GUARDRAILS ARE CODE | Claude Code's law lives in policy/ (enterprise tier: /etc/claude-code/ inside the box) and is re-stamped on every setup.sh run. Changing the rules = changing this repo. |
| 7 | EXPOSURE | Public IP carries key-only ssh and mosh ONLY. Cockpit and every sensitive port are tailnet-only. etserver is never installed (replaced fleet-wide by mosh). |
| 8 | VALIDATE | setup.sh ends with verify.sh; a bootstrap is done when every check PASSes. |
| 9 | LEAST PRIVILEGE / LAYERS | Provisioning splits by identity: the SYSTEM layer (packages, /etc, system services) runs as root once via setup-host.sh; the ROOTLESS layer (podman, distrobox, Claude Code) runs as the operating user via setup-user.sh. The user is a password-gated `wheel` admin with NO blanket NOPASSWD; the in-box agent gets only a scoped passwordless allowlist (policy/sudoers.claudebox), grown solely by committing to the repo, and is OS-blocked from everything else (host installs stay hard-denied). Privileged files are written in place by root, never staged via a user-owned /tmp file. |

## REPO FILE PURPOSES

| File | Purpose |
|---|---|
| CLAUDE.md | this file — agent rules for editing this repo |
| README.md | human-facing project doc (purpose, install, upgrade, use, reference) |
| VERSION | repo's release version (single line, semver) |
| setup.sh | orchestrator (run as root): runs the system layer then the rootless layer in their correct identities |
| setup-host.sh | **system layer**, as root — packages, /etc, system services, tailnet, host dnf-automatic, creates `core` + its rootless prerequisites |
| setup-user.sh | **rootless layer**, as `core` — user podman socket, ssh keys, claudebox, Claude policy, the `claude` + `claudebox-rebuild` wrappers + the box-rebuild units, workload-refresh harness, verify (no host privilege) |
| sync-authorized-keys.sh | authorizes `core`'s allowlisted SSH keys from `github.com/<user>.keys` (fingerprint allowlist = the access policy; other keys ignored), tags each `environment="LOGIN_KEY=<device>"`; defensive (never wipes keys on a failed fetch) |
| distrobox.ini | claudebox, declaratively (image pin, pre-init Anthropic repo on the `latest` channel, packages) |
| box-rebuild.sh | the full claudebox rebuild (`distrobox rm -f` → re-run setup-user.sh); detached so it outlives the box it recreates |
| claudebox-daily.sh | daily-refresh decision: rebuild now if idle, else defer to session exit |
| claudebox-init.sh | claudebox host bridge (CONTAINER_HOST → host rootless podman socket) + in-box `claudebox-rebuild` command, applied post-assemble over the quote-safe `distrobox enter -- sudo` channel |
| cockpit-tailnet-serve.sh | publishes Cockpit on the tailnet (`tailscale serve` :443 → loopback:9090) + writes `/etc/cockpit/cockpit.conf` for the proxied origin |
| container-refresh.sh | per-workload refresh: busy-probe + pull + digest compare + `systemctl --user restart <name>.service` + rollback on health failure |
| claudebox-busy-probe.sh | generic busy probe — `podman exec` + AND-check session.lock + box-rebuild.lock; exit 0/1/2 = idle/busy/broken |
| systemd-units/ | instance templates for workload-refresh + retry |
| policy/CLAUDE.md | host-claudebox runtime law (stamped at /etc/claude-code/CLAUDE.md inside the box) |
| policy/managed-settings.json | deny-rule guardrails (defense-in-depth) + bypass-permissions disabled (managed tier) |
| policy/sudoers.claudebox | scoped passwordless-sudo allowlist for the operating user; visudo-validated, stamped to /etc/sudoers.d/claudebox |
| verify.sh | PASS/FAIL acceptance: sockets, box, claude, policy, host-engine reach, tailnet, box-rebuild units, workload-refresh timers, dnf-automatic timer, fail2ban sshd jail, sudo doctrine boundary |
| .github/workflows/refresh-release.yml | weekly CI (Fri): re-checks Fedora's latest stable + Hostinger's provisioned version, refreshes README status line + pinned releasever |

## PACKAGES

| Tier | Package | Source | Why required |
|---|---|---|---|
| Host | podman | Fedora repos (preinstalled on Cloud) | the container engine — the host's purpose |
| Host | distrobox | Fedora repos | runs claudebox (declarative via distrobox.ini); installs workload Quadlets |
| Host | flatpak-session-helper | Fedora repos | host side of distrobox-host-exec (D-Bus activated; not preinstalled on Cloud) |
| Host | tmux | Fedora repos | persistence layer — every remote login attaches a tmux session; outlives box rebuilds + tailscaled restarts |
| Host | mosh | Fedora repos | roaming-resilient public remote shell (UDP, AEAD; bootstraps over sshd) |
| Host | openssh-server | Fedora repos | key-only public door + mosh bootstrap (Cloud default config is already key-only) |
| Host | tailscale | Tailscale's official dnf repo | tailnet node + Tailscale SSH + serves Cockpit |
| Host | cockpit, -podman, -files, -networkmanager, -selinux | Fedora repos | browser host management (containers, files, network, SELinux), tailnet-only |
| Host | dnf5-plugin-automatic | Fedora repos | unattended host package updates (15th monthly; applies, never auto-reboots) |
| Host | fail2ban | Fedora repos | brute-force mitigation on the public sshd port (22). Reads sshd's AUTHPRIV events via journald (`backend = auto`); tailnet CGNAT 100.64.0.0/10 is `ignoreip`'d. Symmetric posture with the v1.1.9 fedora-dev image. |
| Box | claude-code | Anthropic's official dnf repo (`latest` channel) | the manager — claudebox's purpose; refreshed daily by box rebuild |
| Box | host-spawn | Fedora repos | container side of distrobox-host-exec (no GitHub download — deterministic) |
| Box | bubblewrap, socat | Fedora repos | Claude Code's Linux sandbox dependencies |
| Box | podman (client) | Fedora repos | drives the HOST engine via CONTAINER_HOST socket |
| Box | git, gh, tmux, fastfetch | Fedora repos | orchestration toolset (repos, GHCR auth, sessions) |

Current waivers: none. Adding a package = add a row + edit setup-host.sh /
distrobox.ini accordingly + PR.
