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

Images are CI-built on GitHub and GHCR-published; the host claudebox **pulls
and operates** them — it never `podman build`s a **shipping** image (CI does); it MAY build a disposable, never-pushed validation throwaway to live-gate an open PR pre-merge (see `policy/CLAUDE.md` DO NOT carve-out). The host claudebox is the
**genesis agent / mother platform**: besides operating the host (incl. creating
and removing containers), it is the **only** box that sees the live containers,
so it **live-diagnoses** them and develops fixes to the fleet image repos it
operates (`fedora-bootstrap`, `fedora-dev`, and the workload images deployed
here). But it **opens PRs only — it never merges, pushes, or tags `main`**:
`fedora-dev` merges, on Arthur's clickable APPROVE (see THE FLEET in
`policy/CLAUDE.md`). CI builds the image; the new image reaches the host via the
workload-refresh pull. A repo it neither operates nor can diagnose stays
surface-only. Developing source ≠ building (CI) ≠ merging (`fedora-dev`) ≠
deploying (the pull).

The dev↔host loop runs autonomously EXCEPT the final merge: develop → open PR
(feature pushes are autonomous) → label it `live-validate` → the host live-gate
(Gate B) DISCOVERS it ORG-WIDE by that label (no repo list to maintain), fetches
the PR head on-demand, applies a STRUCTURAL GUARD (only builds a candidate
carrying a `Containerfile`/`.live-gate`, else skips cleanly), builds it DISPOSABLY
per the repo's own in-repo `.live-gate` contract (PARSED, never executed) under
loopback-only fences, and posts a GREEN/RED verdict comment → iterate (RED: push
a fix, or SUPERSEDE the branch if the approach was wrong; GREEN: BUILD UPON it)
until green → Arthur's discrete clickable APPROVE → fedora-dev merges. The human
is OUT of the per-iteration loop — only the merge is a click. Repos are discovered
DYNAMICALLY: create/rename/merge/delete freely; enroll one just by labelling its
PR `live-validate` and shipping a `.live-gate`. On the host this is wired by
`live-gate-watch.sh` → `live-gate-run.sh` → `build-candidate.sh` +
`validate-candidate.sh` (the host comments the verdict, never merges; no per-repo
clone or workload list is maintained — discovery is the org-wide label query).

**Post-merge deploy — the other half I own.** Once `fedora-dev` merges and CI
republishes `:latest`, I redeploy — the only box that touches the live host. A
workload refreshes via `workload-refresh@<name>.timer` (monthly `*-*-15 04:00`
+2 h jitter) or on demand `systemctl --user start workload-refresh@<name>.service`.
`container-refresh.sh` flocks `<name>.lock`, busy-probes (`claudebox-busy-probe.sh`
AND-checks the in-container `session.lock` + `box-rebuild.lock`; busy → append
`<name>.pending`, exit 10), captures the prior image id, `podman pull`s,
digest-compares, and on change `systemctl --user restart <name>.service` (Quadlet,
`Notify=healthy` blocks until healthy). **Unhealthy → automatic digest rollback:**
retag `:latest` back to the prior id and restart (works only because the Quadlet is
`Pull=missing`); on success clear `.pending` + write `<name>.rolled-back` (and does
NOT re-arm the hourly `workload-refresh-retry@<name>.timer`, since registry `:latest`
is still bad). A manual rollback beyond this is **STOP-AND-SURFACE**. The host
itself has no image/Quadlet — its deploy analogue is the operator re-running
`setup.sh` as root.

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
historical record — never modify them after their tag is pushed. TWO additive (never-rewriting) exceptions: (1) **RELOCATION** — older subsections may be moved verbatim to `UPGRADING.md` to keep README scannable; leave the latest 1–2 subsections + a pointer in README, content unchanged. (2) **dated SAFETY-CORRECTION / SUPERSESSION note** — a `> **⚠️ Corrected in vX.Y.Z:**` callout (beside a subsection documenting something factually wrong or unsafe) OR a `> **⚠️ Superseded in vX.Y.Z:**` callout (beside a still-valid procedure that a later release replaced with a better one) may be appended, pointing to the procedure in the current release's subsection. Never silently rewrite the original steps.

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

## HEADLESS (binding prerequisite)

The host — and everything it runs — is **fully headless**: a remote VPS with no physical monitor,
GPU, or local login seat. The host services, the claudebox, and every workload image (fedora-dev
and the fedora-desktop **xrdp**/**grd** desktop lineages) must work with NO physical display — any
desktop is a *virtual* display rendered in software (llvmpipe), reached only over the network
(ssh / RDP / VNC / web, over the tailnet or the hardened public doors). A change that requires a
physical display, GPU, or seat is a **defect**, not an option.

## BUILD PRINCIPLES (binding for every code change)

| # | Principle | Rule |
|---|---|---|
| 1 | TARGET | Fedora Cloud Base, pinned latest stable (image tag in distrobox.ini, host assumptions documented in README). Bump deliberately, per rule 3. |
| 2 | SOURCES | Host and box install only from an official source, exactly one of: (a) Fedora repos via dnf (RPM); (b) the vendor's/developer's own RPM or dnf repo (`.repo` with `gpgcheck=1`); (c) an **official-upstream binary release artifact with NO class-(a)/(b) source** — bounded by the **Class-(c) rules** below (last-resort/zero-base; publisher GPG-signature-or-checksum-verified, fail-closed; one of three self-contained consumption shapes; never loose on `$PATH`; disclosed per-artifact). Never: COPR or other third-party repos, pip/npm/cargo/gem/brew installs, curl-pipe-sh, tarball-on-PATH, flatpak, snap. Anything outside (a)/(b)/(c)-as-scoped needs an explicit user waiver row. **Class-(c) artifacts in use: none.** |
| 3 | VERIFY FIRST | Fact-check any source/version against the live source before changing it. |
| 4 | HOST MINIMAL & IMMUTABLE | The PACKAGES table below is the complete sanctioned host footprint. Anything else runs in a container or in claudebox. Host installs beyond it require an explicit user waiver, recorded as a new row. **Always install the most specific (leaf) package, never a convenience metapackage, unless an explicit architectural reason is recorded in the Why column. `install_weak_deps=False` blocks optional Recommends but NOT a metapackage's hard Requires, so a metapackage can silently drag in components you never use (e.g. `fail2ban` hard-pulls `fail2ban-firewalld`→`firewalld` + `fail2ban-sendmail`→`esmtp`; install `fail2ban-server` instead). Minimalism is a package-choice discipline, not just a flag. If unsure whether a name is a metapackage or what it hard-requires, VERIFY (`dnf repoquery --requires <pkg>` / `rpm -q --requires`) and flag it for review before adding.** **"MINIMUM" IS RELATIVE TO THE CHOSEN CAPABILITY, not the absolute package count.** Once a capability is decided (e.g. a working desktop; an RDP-grade web gate), install the minimal LEAF footprint that makes THAT capability work, and accept + DISCLOSE the irreducible hard-dependency closure it entails (e.g. a `gnome-shell` desktop→webkit + `gnome-control-center`; a KDE desktop→samba/codec). Between options that deliver the SAME capability, prefer the smaller-footprint / built-in / class-(a) one. A lighter option that REDUCES the capability is NOT "more minimal" — it is a lesser function, and choosing it is a recorded capability trade-off, NOT a minimalism win. (Worked decision in fedora-desktop: Guacamole [RDP-grade web gate — H.264/audio/clipboard/file-transfer in the browser] was chosen over noVNC [VNC-grade], so its Tomcat + JVM + `.war` footprint IS the minimum for full RDP-in-the-browser.) |
| 5 | NO SECRETS | No passwords, keys, or tokens in this repo, ever. Tailscale auth is interactive or via TS_AUTHKEY env at run time. |
| 6 | GUARDRAILS ARE CODE | Claude Code's law lives in policy/ (enterprise tier: /etc/claude-code/ inside the box) and is re-stamped on every setup.sh run. Changing the rules = changing this repo. |
| 7 | EXPOSURE | Public IP carries key-only ssh and mosh ONLY. Cockpit and every sensitive port are tailnet-only. etserver is never installed (replaced fleet-wide by mosh). |
| 8 | VALIDATE | setup.sh ends with verify.sh; a bootstrap is done when every check PASSes. |
| 9 | LEAST PRIVILEGE / LAYERS | Provisioning splits by identity: the SYSTEM layer (packages, /etc, system services) runs as root once via setup-host.sh; the ROOTLESS layer (podman, distrobox, Claude Code) runs as the operating user via setup-user.sh. The user is a password-gated `wheel` admin with NO blanket NOPASSWD; the in-box agent gets only a scoped passwordless allowlist (policy/sudoers.claudebox), grown solely by committing to the repo, and is OS-blocked from everything else (host installs stay hard-denied). Privileged files are written in place by root, never staged via a user-owned /tmp file. |

### Class-(c) sources — the bounded last-resort exception (fleet-wide; identical in fedora-desktop + fedora-dev + fedora-bootstrap)

**(c)** ONLY when **no class-(a) Fedora package and no class-(b) vendor `.repo`** exists for the
needed artifact — a **last-resort, zero-base check, re-confirmed at every version bump**; the
moment it appears in Fedora or a vendor `.repo` it MUST move to (a)/(b): an **official-upstream
binary release artifact**, fetched over TLS from the project's **own canonical release channel**
— whose exact host + org/repo (or release-API URL) is **pinned in the disclosure row and
changeable only as a control-plane change** — never a mirror, aggregator, COPR, PPA, OBS home
project, language-package-manager registry (Maven Central/npm/PyPI/crates.io/RubyGems), or
third-party rebuild. Each artifact MUST be **(1) version-pinned** via a Containerfile `ARG` (or
`distrobox.ini` pin), the SOLE exception being an artifact Principle 6 designates
latest-at-build; and **(2) integrity-verified before any use** — against the publisher's **GPG
signature** (`gpg --verify`, key fingerprint pinned in-repo) **whenever one is published**; a
bare `sha*sum -c` is acceptable **only** when the project publishes no signature; the build
**fails closed** on any mismatch / missing / unfetchable check. *(For a latest-at-build artifact
where no hash can be pre-pinned: TLS-authenticated fetch from the publisher's own release API +
**resolve-and-log** — an auditable record, NOT a fail-closed gate; reserved to explicitly-named
latest-at-build artifacts only.)* The artifact may be consumed in **exactly one of three
self-contained shapes**: (i) a developer/vendor **AppImage** run from `/opt` (never a bare
ELF/script/tarball); (ii) a webapp/archive **deployed into a class-(a) runtime** (an Apache
`.war` into Fedora's Tomcat); or (iii) a **build-time-only tool** that is itself (c)-verified,
transforms a named (c) artifact, fetches no further network, installs nothing onto `$PATH`, runs
deterministically, and is deleted. **A loose executable / script / tarball on `$PATH` is NEVER
permitted under (c).** Each (c) artifact gets a **disclosure row** in the PACKAGES table (pinned
canonical URL + version + signature/checksum kind); the table's **enumeration line lists every
(c) artifact in use**. **Mechanical backstop (CI):** the control-plane diff-guard asserts every
binary on `$PATH` resolves to an rpm (`rpm -qf`).

**Class-(c) artifacts in use: none.** This host/box ships no upstream binary artifact today; the
rule is carried for fleet parity so any future need inherits the identical bounded definition.
(The only repo with class-(c) artifacts is fedora-desktop: `guacamole.war` + Obsidian.)

## REPO FILE PURPOSES

| File | Purpose |
|---|---|
| CLAUDE.md | this file — agent rules for editing this repo |
| README.md | human-facing project doc (purpose, install, upgrade, use, reference) |
| UPGRADING.md | archived per-version upgrade subsections — older releases relocated from README per the RELEASE-DOC CONVENTION; README keeps the latest 1–2 + a pointer |
| VERSION | repo's release version (single line, semver) |
| day0.sh | interactive Day-0 wizard (run as root, the LAST line of the Day-0 paste): ASKS for the Tailscale auth key (reads `/dev/tty`; blank = browser web-login), runs `setup.sh < /dev/null` with it in the env, then prompts for core's password + reboots into the SELinux convergence (`SELINUX_TARGET=permissive` ⇒ no reboot). Mirrors the workload `spin-up.sh`; `setup.sh` stays the non-interactive contract it wraps |
| setup.sh | orchestrator (run as root): runs the system layer then the rootless layer in their correct identities |
| setup-host.sh | **system layer**, as root — packages, /etc, system services, tailnet, host dnf-automatic, creates `core` + its rootless prerequisites |
| setup-user.sh | **rootless layer**, as `core` — user podman socket, ssh keys, claudebox, Claude policy, the `claude` + `claudebox-rebuild` wrappers + the box-rebuild units, workload-refresh harness, verify (no host privilege) |
| sync-authorized-keys.sh | authorizes `core`'s allowlisted SSH keys from `github.com/<user>.keys` (fingerprint allowlist = the access policy; other keys ignored), tags each `environment="LOGIN_KEY=<device>"`; defensive (never wipes keys on a failed fetch) |
| distrobox.ini | claudebox, declaratively (image pin, pre-init Anthropic repo on the `latest` channel, packages) |
| box-rebuild.sh | the full claudebox rebuild (`distrobox rm -f` → re-run setup-user.sh); detached so it outlives the box it recreates |
| claudebox-daily.sh | daily-refresh decision: rebuild now if idle, else defer to session exit |
| claudebox-init.sh | claudebox host bridge (CONTAINER_HOST → host rootless podman socket) + in-box `claudebox-rebuild` command, applied post-assemble over the quote-safe `distrobox enter -- sudo` channel |
| cockpit-tailnet-serve.sh | publishes Cockpit on the tailnet (`tailscale serve` :443 → loopback:9090) + writes `/etc/cockpit/cockpit.conf` for the proxied origin |
| selinux-autoenforce.sh | drives the one-time SELinux disabled→enforcing convergence (soak-confirm + flip; post-enforce health check + auto-revert). Installed to `/usr/local/sbin/selinux-autoenforce`; invoked by the **four** `selinux-*` system units `setup-host.sh` stamps (`selinux-enforce.timer` + `-flip.service`; `selinux-postenforce.timer` + `.service`) + a `/var/lib/fedora-bootstrap/selinux-chain.state` marker. The repo's first **system-scoped** stamped units (workload-refresh units are user-scoped). |
| container-refresh.sh | per-workload refresh: busy-probe + pull + digest compare + `systemctl --user restart <name>.service` + rollback on health failure |
| claudebox-busy-probe.sh | generic busy probe — `podman exec` + AND-check session.lock + box-rebuild.lock; exit 0/1/2 = idle/busy/broken |
| live-gate-watch.sh | live-gate DISCOVERY (Gate B). One org-wide `gh` query for every `live-validate`-labelled open PR (no repo list), resolves each head SHA, per-`(repo,SHA)` `.done` dedup + `flock` self-serialize, invokes `live-gate-run.sh`. Runs inside claudebox (needs `gh`/`git`; drives the host engine via `CONTAINER_HOST`); a `systemd --user` timer. `LIVE_GATE_WORKLOADS` is an optional allowlist FILTER (unset = org-wide) |
| live-gate-run.sh | clone-on-demand + orchestration for one PR: fetches ONLY the PR head into an ephemeral tree, applies the STRUCTURAL GUARD (gateable only with a top-level `.live-gate`/`Containerfile*`, else neutral `SKIPPED`), PARSES the in-repo `.live-gate` (never `source`s it), builds + gates every declared target, posts the combined GREEN/RED verdict comment, tears the tree down. The host comments, never merges |
| build-candidate.sh | pre-merge BUILD step: exports a PR ref to a throwaway tree, `podman build`s a DISPOSABLE candidate (`localhost/disposable/<name>:val-<sha>`, never pushed, `--rm`/`rmi`'d; base layers stay cached), hands it to `validate-candidate.sh`. Sanctioned by the v1.2.25 carve-out |
| validate-candidate.sh | Gate B itself: runs the disposable candidate fenced (`CAND_FENCE`, loopback-only, no real secrets) and probes its OWN loopback (`CAND_PROBE` — does it actually serve, not just health) → PASS/FAIL |
| systemd-units/ | instance templates for workload-refresh + retry |
| policy/CLAUDE.md | host-claudebox runtime law (stamped at /etc/claude-code/CLAUDE.md inside the box) |
| policy/managed-settings.json | deny-rule guardrails (defense-in-depth) + bypass-permissions disabled (managed tier) |
| policy/sudoers.claudebox | scoped passwordless-sudo allowlist for the operating user; visudo-validated, stamped to /etc/sudoers.d/claudebox |
| verify.sh | PASS/FAIL acceptance: sockets, box, claude, policy, host-engine reach, tailnet, box-rebuild units, workload-refresh timers, dnf-automatic timer, fail2ban sshd jail, firewalld absent (leaf footprint), sudo doctrine boundary, SELinux config not disabled (permissive or enforcing) |
| .github/workflows/refresh-release.yml | weekly CI (Fri): re-checks Fedora's latest stable + Hostinger's provisioned version, refreshes README status line + pinned releasever |

## PACKAGES

> **Base-tooling assumption (v1.2.0):** the SELinux disabled→enforcing convergence relies on Fedora Cloud `@core` tooling assumed present and intentionally **not** installed by this repo (so it is not a host-footprint addition): **audit** (`ausearch`), **policycoreutils** (`restorecon`/`fixfiles`/the stock `selinux-autorelabel` units), **libselinux-utils** (`getenforce`/`setenforce`). If a future minimal base drops them, the convergence gate fails closed (host stays permissive). This keeps the "complete sanctioned host footprint" invariant honest about the dependency.

| Tier | Package | Source | Why required |
|---|---|---|---|
| Host | podman | Fedora repos (preinstalled on Cloud) | the container engine — the host's purpose |
| Host | distrobox | Fedora repos | runs claudebox (declarative via distrobox.ini); installs workload Quadlets |
| Host | flatpak-session-helper | Fedora repos | host side of distrobox-host-exec (D-Bus activated; not preinstalled on Cloud) |
| Host | tmux | Fedora repos | persistence layer — every remote login attaches a tmux session; outlives box rebuilds + tailscaled restarts |
| Host | mosh | Fedora repos | roaming-resilient public remote shell (UDP, AEAD; bootstraps over sshd) |
| Host | openssh-server | Fedora repos | key-only public door + mosh bootstrap (Cloud default config is already key-only) |
| Host | tailscale | Tailscale's official dnf repo | tailnet node + Tailscale SSH + serves Cockpit |
| Host | cockpit, -podman, -files, -networkmanager, -selinux | Fedora repos | **Deliberate management interface (maintainer-specified) for this headless VPS.** Fedora Server is headless by design and Cockpit is the official web console for remote admin: it uses the system's own APIs/CLI (no parallel agent or drifting state), is browser-reachable from any OS, and has **zero idle footprint** — socket-activated via `cockpit.socket`, never running in the background (see cockpit-project.org). Exposure is **tailnet-ONLY by design** (loopback-bound + tailscale-serve proxy; never public — Build Principle 7). The `cockpit` aggregator is a **deliberately-retained metapackage** (Build Principle 4 recorded exception): its hard deps (`cockpit-bridge`/`-system`/`-ws`) are exactly the console core and all used; add-in Recommends are blocked by `install_weak_deps=False`, so no unused baggage lands. |
| Host | dnf5-plugin-automatic | Fedora repos | unattended host package updates (15th monthly; applies, never auto-reboots) |
| Host | fail2ban-server | Fedora repos | brute-force mitigation on the public sshd port (22). Reads sshd's AUTHPRIV events via journald (`backend = auto`); tailnet CGNAT 100.64.0.0/10 is `ignoreip`'d; bans via `nftables[type=multiport]`. The **leaf** package, NOT the `fail2ban` metapackage (whose hard deps pull `fail2ban-firewalld`→`firewalld` + `fail2ban-sendmail`→`esmtp`, all unused — see Build Principle 4). Jail posture (bantime 1h, CGNAT `ignoreip`) matches the v1.1.9 fedora-dev jail. (fedora-dev shipped the same fixes on its main: leaf `fail2ban-server` at 9312b19 and the nft-only banaction at 615f9c5 — so both repos are nft-native.) |
| Box | claude-code | Anthropic's official dnf repo (`latest` channel) | the manager — claudebox's purpose; refreshed daily by box rebuild |
| Box | host-spawn | Fedora repos | container side of distrobox-host-exec (no GitHub download — deterministic) |
| Box | bubblewrap, socat | Fedora repos | Claude Code's Linux sandbox dependencies |
| Box | podman (client) | Fedora repos | drives the HOST engine via CONTAINER_HOST socket |
| Box | git, gh, tmux, fastfetch | Fedora repos | orchestration toolset (repos, GHCR auth, sessions) |

Class-(c) artifacts in use: none (see the Class-(c) rules under BUILD PRINCIPLES). Adding a
package = add a row + edit setup-host.sh / distrobox.ini accordingly + PR.
