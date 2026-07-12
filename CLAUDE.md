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
`fedora-dev` merges, on Arthur's clickable APPROVE (see THE FLEET — mastered in
`fedora-dev/policy/fleet-core.md`, spliced into the in-box law at the `<!--FLEET-CORE-->` marker;
absent in this tree by design). CI builds the image; the new image reaches the host via the
workload-refresh pull. A repo it neither operates nor can diagnose stays
surface-only. Developing source ≠ building (CI) ≠ merging (`fedora-dev`) ≠
deploying (the pull).

The dev↔host loop runs autonomously EXCEPT the final merge — full mechanics in **THE FLEET**
(mastered in `fedora-dev/policy/fleet-core.md`, spliced into the in-box law at the `<!--FLEET-CORE-->`
marker; absent in this tree by design) and mirrored in [FLEET.md](FLEET.md) ("The dev↔host live-gate
loop"). On THIS host it is wired `live-gate-watch.sh` → `live-gate-run.sh` → `build-candidate.sh` +
`validate-candidate.sh`: discovery is one org-wide `live-validate`-label query (no repo list), a
STRUCTURAL GUARD builds only a candidate carrying a `Containerfile`/`.live-gate`, the in-repo
`.live-gate` is PARSED, never executed, and the host posts a GREEN/RED verdict comment — it never
merges; iterate until green → Arthur's discrete clickable APPROVE → `fedora-dev` merges.

**Post-merge deploy — the other half I own.** Once `fedora-dev` merges and CI republishes `:latest`,
I redeploy — the only box that touches the live host — via `workload-refresh@<name>` (monthly
`*-*-15 04:00` +jitter, or on demand). Full mechanics + the load-bearing invariants live in
`policy/CLAUDE.md` → **WORKLOAD REFRESH MECHANISM** + **REFRESH IS NOT A SECURITY BOUNDARY** (the
stamped in-box law): busy-probe deferral via `.pending`; digest-compare; **unhealthy → automatic
digest rollback, which works ONLY because the Quadlet is `Pull=missing`**; a `.rolled-back` marker
that does NOT re-arm the retry; a manual rollback beyond that is **STOP-AND-SURFACE**. The host
itself has no image/Quadlet — its deploy analogue is the operator re-running `setup.sh` as root.

## RELEASING A NEW VERSION

Every change that ships ANY visible delta (code or doc) gets a version bump.
Sequence:

1. Apply the change (scripts, units, policy, distrobox.ini, README, etc.).
2. Bump the version: `VERSION` (the single source of truth) + mirror it in the
   `setup.sh` header (`# Version: X.Y.Z (one-line summary)` — ONE line, no
   embedded changelog; the changelog lives in the release docs below).
3. Add the release doc per the RELEASE-DOC CONVENTION below.
4. Commit (single commit per release; do not batch multiple releases).
5. Open a PR; `fedora-dev` merges to `main` on Arthur's clickable APPROVE (THE
   FLEET) — the box never direct-pushes `main`. The host applies the merged
   release by re-running `setup.sh`.

Semver: patch for any user-visible change including pure docs; minor for
additive features that don't break existing usage; major for breaking
changes. Doc-only fixes still patch-bump.

**No per-release git tag.** The version-of-record is the in-tree `VERSION` +
`setup.sh` header + the release docs (the changelog). The host deploys `main`
(not tags), rollback is `git checkout <commit>` + re-run `setup.sh`, and
nothing external pins to a release — so a per-release tag was redundant
friction (the `v1.0.0`–`v1.2.19` tags remain as history). Tagging stays
OPTIONAL — for a genuine milestone you deliberately choose to name, never a
per-release obligation.

## RELEASE-DOC CONVENTION (binding)

The standard upgrade flow is ALWAYS the same (`cd /opt/fedora-bootstrap && git
pull --ff-only origin main && ./setup.sh < /dev/null`) and `setup.sh` is
idempotent across the entire version history — a v1.0.0 host jumps straight to
latest in one run. So the release doc is sized to what the release actually
demands of the operator:

- **Default (most releases): ONE changelog-table row** in `UPGRADING.md` —
  `| version | what changed | beyond the standard flow |` (last column `—`
  when the standard flow suffices, which is the norm).
- **A FULL subsection** (prose intro; one self-contained paste block =
  standard flow + the version-specific steps; verification with expected
  output; rollback recipe) ONLY when the release ships genuine
  version-specific operator steps — a migration, a repair `setup.sh` cannot
  perform, a reboot-bearing transition, or a safety correction. It lives in
  README's "Upgrading an existing host" section while current; relocate it
  verbatim to `UPGRADING.md`'s "Retained full procedures" once superseded.
- **v1.0.0 baseline:** every code-bearing release supports upgrading straight
  from v1.0.0 (that is what setup.sh idempotence means). If a release
  genuinely cannot, SAY SO in its row/subsection with the minimum starting
  point — and surface the constraint to the user before shipping it.
- **History is append-only:** never rewrite a shipped row or retained
  procedure; corrections are a dated `> **⚠️ Corrected/Superseded in
  vX.Y.Z:**` note beside the original.
- Release-doc rules live HERE, not in README (its intro is a two-line
  human-facing pointer).

## HEADLESS (binding prerequisite)

The host — and everything it runs — is **fully headless**: a remote VPS with no physical monitor,
GPU, or local login seat. The host services, the claudebox, and every workload image (fedora-dev
and the fedora-desktop **xrdp**/**grd** desktop lineages) must work with NO physical display — any
desktop is a *virtual* display rendered in software (llvmpipe), reached only over the network
(ssh / RDP / VNC / web, over the tailnet or the hardened public doors). A change that requires a
physical display, GPU, or seat is a **defect**, not an option.

## PRINCIPLE 0 — THE SELF-SUSTAINING APPARATUS

Autonomy mandate, two-tier validation, and Definition of Done live in **THE SELF-SUSTAINING
APPARATUS** section — mastered in `fedora-dev/policy/fleet-core.md` and spliced into the in-box law
(`/etc/claude-code/CLAUDE.md`) from `policy/CLAUDE.md`'s `<!--FLEET-CORE-->` marker on every box
rebuild; present in the stamped law, **absent in this repo tree by design** (single-source parity
guard), always in context for the in-box agent. This box's role (PR-only, never-merge) is in
**PIPELINE CONTEXT** above.


## DOC ARCHITECTURE — DRY rule (binding)

One authoritative home per concept; every other mention is a one-line pointer or deleted. Evidence and benchmarks live only in the principle they prove. Fleet-wide identical blocks are enforced by CI (`bin/fleet-guard-parity.sh`).

**Layer roles.** `policy/CLAUDE.md` = binding law (stamped at every box rebuild; always in context) — owns autonomy mandate, two-tier validation, DoD, merge gate, and control-plane class. `CLAUDE.md` (this file) = per-repo build rules (BUILD PRINCIPLES table) + per-file purpose map. `FLEET.md` = cross-box map (human + agent-accessible); shared sections fleet-wide. `README.md` = human-only; not an authoritative source for any agent rule.

## BUILD PRINCIPLES (binding for every code change)

| # | Principle | Rule |
|---|---|---|
| 1 | TARGET | Fedora Cloud Base, pinned latest stable (image tag in distrobox.ini, host assumptions documented in README). Bump deliberately, per rule 3. |
| 2 | SOURCES | Host and box install only from an official source, exactly one of: (a) Fedora repos via dnf (RPM); (b) the vendor's/developer's own RPM or dnf repo (`.repo` with `gpgcheck=1`); (c) an **official-upstream binary release artifact with NO class-(a)/(b) source** — bounded by the **Class-(c) rules** below (last-resort/zero-base; take the vendor's directly-published raw binary — never apt/`.deb`; provenance-GRADED c1 GPG-sig / c2 checksum / c3 resolve-log, strongest-available, fail-closed, pinned; shape is a within-grade tiebreaker — a persistent runtime binary IS permitted; disclosed per-artifact). Never: COPR or other third-party repos, pip/npm/cargo/gem/brew installs, curl-pipe-sh, mirror/aggregator binaries, flatpak, snap. Anything outside (a)/(b)/(c)-as-scoped needs an explicit user waiver row. **Class-(c) artifacts in use: none.** |
| 3 | VERIFY FIRST | Fact-check any source/version against the live source before changing it. |
| 4 | HOST MINIMAL & IMMUTABLE | The PACKAGES table below is the complete sanctioned host footprint. Anything else runs in a container or in claudebox. Host installs beyond it require an explicit user waiver, recorded as a new row. **Always install the most specific (leaf) package, never a convenience metapackage, unless an explicit architectural reason is recorded in the Why column. `install_weak_deps=False` blocks optional Recommends but NOT a metapackage's hard Requires, so a metapackage can silently drag in components you never use (e.g. `fail2ban` hard-pulls `fail2ban-firewalld`→`firewalld` + `fail2ban-sendmail`→`esmtp`; install `fail2ban-server` instead). Minimalism is a package-choice discipline, not just a flag. If unsure whether a name is a metapackage or what it hard-requires, VERIFY (`dnf repoquery --requires <pkg>` / `rpm -q --requires`) and flag it for review before adding.** **"MINIMUM" IS RELATIVE TO THE CHOSEN CAPABILITY, not the absolute package count.** Once a capability is decided (e.g. a working desktop; an RDP-grade web gate), install the minimal LEAF footprint that makes THAT capability work, and accept + DISCLOSE the irreducible hard-dependency closure it entails (e.g. a `gnome-shell` desktop→webkit + `gnome-control-center`; a KDE desktop→samba/codec). Between options that deliver the SAME capability, prefer the smaller-footprint / built-in / class-(a) one. A lighter option that REDUCES the capability is NOT "more minimal" — it is a lesser function, and choosing it is a recorded capability trade-off, NOT a minimalism win. (Worked decision in fedora-desktop: Guacamole [RDP-grade web gate — H.264/audio/clipboard/file-transfer in the browser] was chosen over noVNC [VNC-grade], so its Tomcat + JVM + `.war` footprint IS the minimum for full RDP-in-the-browser.) |
| 5 | NO SECRETS | No passwords, keys, or tokens in this repo, ever. Tailscale auth is interactive or via TS_AUTHKEY env at run time. |
| 6 | GUARDRAILS ARE CODE | Claude Code's law lives in policy/ (enterprise tier: /etc/claude-code/ inside the box) and is re-stamped on every setup.sh run. Changing the rules = changing this repo. |
| 7 | EXPOSURE | Public IP carries key-only ssh and mosh ONLY. Cockpit and every sensitive port are tailnet-only. etserver is never installed (replaced fleet-wide by mosh). |
| 8 | VALIDATE | setup.sh ends with verify.sh; a bootstrap is done when every check PASSes. **Prove runtime/terminal behaviour empirically, not by reasoning:** for tmux multi-client geometry, TUI redraw, and the like, drive multiple sized PTY clients with a real harness and assert the actual bytes each client renders (a naive byte VT model mis-reads UTF-8 fills like `·` as garbage) — not just a reported window size. |
| 9 | LEAST PRIVILEGE / LAYERS | Provisioning splits by identity: the SYSTEM layer (packages, /etc, system services) runs as root once via setup-host.sh; the ROOTLESS layer (podman, distrobox, Claude Code) runs as the operating user via setup-user.sh. The user is a password-gated `wheel` admin with NO blanket NOPASSWD; the in-box agent gets only a scoped passwordless allowlist (policy/sudoers.claudebox), grown solely by committing to the repo, and is OS-blocked from everything else (host installs stay hard-denied). Privileged files are written in place by root, never staged via a user-owned /tmp file. |
| 10 | THROWAWAY TREE & CHURN | Validate every build as a DISPOSABLE throwaway, never against the live tree: (a) the throwaway tree + all build caches live on the **WRITABLE home volume** — the immutable live tree is **never mutated**; (b) provenance still obeys Principle 2 in full — **no loosening because it's a throwaway**; (c) everything is **thrown away** after the build (`localhost/disposable/<name>:val-<sha>`, never pushed, `--rm` + `rmi`'d, temp tree removed). **ONE thing persists** — the dnf PACKAGE CACHE (a plain bind dir `-v <home>/.cache/fd-dnf:/var/cache/libdnf5:rw`, NOT an image layer, so it survives `rmi` and every disposal; churn RPMs are served from cache, not re-downloaded — buildah `--mount=type=cache` does NOT work under `--isolation=chroot`, verified); everything else (candidate image, layers, temp tree, run container) is **ephemeral by design** — layers self-bound via `rmi` and each throwaway rebuilds fresh from the cache (current package versions, no stale-frozen-layer risk). Structure Containerfiles **heavy/stable-early, churn-late**, and **never `--no-cache`/prune during churn** (reserved for the monthly clean rebuild). **Isolation:** per-build tree + unique `val-<sha>` tag + unique `vcand-$$` container; the cache is content-addressed so it cannot serve a wrong version. **Storage safety:** EXIT-trap self-destruct + the orphan sweeper (`throwaway-sweep.sh`) reaping crash leaks and bounding the caches — mechanics + knobs live in the scripts' own headers (`build-candidate.sh`, `throwaway-sweep.sh`). |

### Class-(c) sources — the bounded last-resort exception (fleet-wide; identical in fedora-desktop + fedora-dev + fedora-bootstrap)

**(c)** ONLY when **no class-(a) Fedora package and no class-(b) vendor `.repo`** exists for the
needed artifact — a **last-resort, zero-base check, re-confirmed at every version bump**; the
moment it appears in Fedora or a vendor `.repo` it MUST move to (a)/(b): an **official-upstream
binary release artifact**, fetched over TLS from the project's **own canonical release channel**
— whose exact host + org/repo (or release-API URL) is **pinned in the disclosure row and
changeable only as a control-plane change** — never a mirror, aggregator, COPR, PPA, OBS home
project, language-package-manager registry (Maven Central/npm/PyPI/crates.io/RubyGems), or
third-party rebuild. Each artifact MUST be **(1) version-pinned** via a Containerfile `ARG` (or
`distrobox.ini`/setup pin), the SOLE exception being an artifact Principle 6 designates
latest-at-build; and **(2) integrity-verified FAIL-CLOSED before any use, GRADED by what is
verifiable on the RAW BINARY via the direct-download path** (not by a signed repo we do not
consume):
- **c1** — a detached **GPG signature on the binary** (`<artifact>.asc`/`.sig`), verified against
  the vendor's key fingerprint pinned in-repo (`gpg --verify`). Strongest.
- **c2** — a vendor-published **checksum** (`sha256/sha512`) with **no binary signature
  available**; `sha*sum -c`, acceptable ONLY because no signature is offered.
- **c3** — a **latest-at-build** artifact with no pre-pinnable hash: TLS-authenticated fetch from
  the vendor's own release API + **resolve-and-log** (auditable record, NOT a fail-closed gate);
  reserved to artifacts that GENUINELY cannot be pinned, each **individually named AND
  control-plane-approved** — never a general unpinned escape hatch.

Take the **strongest grade the direct channel offers** — you may NOT use c2 when a c1 signature
exists, nor c3 when a hash can be pinned. The build **fails closed** on any mismatch / missing /
unfetchable check.

**Consume the BINARY, never a foreign-distro package manager.** Where a vendor ships a signed
**apt** (or other non-dnf) repo but no dnf repo, do NOT add or invoke that package manager on
Fedora, and do NOT unpack its `.deb`/`.pkg` to reach the binary — take the vendor's
**directly-published raw binary** from the same canonical channel and verify it per the grades
above. A signed foreign-distro repo raises confidence the vendor's key is genuine but does NOT set
the grade; the grade is what we can verify on the binary we install.

**Shape is a within-grade TIEBREAKER, not a gate.** A **persistent runtime-layer binary IS
permitted** (the former absolute "$PATH binary NEVER permitted" ban is removed — the rule gates
PROVENANCE, not shape). When two artifacts share a grade, prefer strongest→weakest: (i) a
**build-time-only tool** (runs once, installs nothing on `$PATH`, deleted) → (ii) a webapp/archive
**deployed into a class-(a) runtime** (an Apache `.war` into Fedora's Tomcat) → (iii) a
self-contained **AppImage from `/opt`** → (iv) a **persistent runtime-layer binary** (e.g. an OCI
runtime such as `runsc`) registered with the engine. Each (c) artifact gets a **disclosure row**
in the PACKAGES table (pinned canonical URL + version + **grade c1/c2/c3** + shape); the table's
**enumeration line lists every (c) artifact in use**. **Backstop:** there is NO CI guard — the in-session clickable merge gate
(Arthur's click) is the sole backstop; the discipline that every binary on `$PATH` resolves to an
rpm (`rpm -qf`) is asserted at PR-review time against the disclosure rows, not by a CI job.

**ANTI-THEATER (doctrine — do not rebuild the sieve).** A static SCRIPT-SCAN for "bad" fetch/install
patterns is **NOT** a valid 2(c) backstop — it is the exact pattern the fleet already de-theatered
(v1.2.48 dropped the inert `--cap-add` denylist; `managed-settings.json`'s deny-list "is best-effort
only… not the boundary"). Detecting bad patterns in arbitrary shell is a sieve — a seventh evasion
always exists — and a guard that implies coverage it can't deliver is **worse than none**. The host
ships no image, so for a fetched binary the boundary is the **installer's OWN fail-closed
verification** (sha/GPG; exit non-zero + install nothing on any mismatch/missing) **+ the disclosure
row + the click** — never a scan. (A host static fetch-guard was built and closed for exactly this
reason — do not resurrect it.)

**Class-(c) artifacts in use: none.** This host/box ships no upstream binary artifact today; the
rule is carried for fleet parity so any future need inherits the identical bounded definition.
(The only repo with class-(c) artifacts is fedora-desktop: `guacamole.war` + Obsidian.)

## REPO FILE PURPOSES

| File | Purpose |
|---|---|
| CLAUDE.md | this file — agent rules for editing this repo |
| README.md | human-facing project doc (purpose, install, upgrade, use, reference) |
| UPGRADING.md | the changelog (one table row per release) + the canonical standard upgrade flow + retained full procedures for releases with genuine operator steps; README keeps the latest releases + a pointer |
| VERSION | repo's release version (single line, semver) |
| day0.sh | interactive Day-0 wizard (run as root, the LAST line of the Day-0 paste): ASKS for the Tailscale auth key (reads `/dev/tty`; blank = browser web-login), runs `setup.sh < /dev/null` with it in the env, then prompts for core's password + reboots into the SELinux convergence (`SELINUX_TARGET=permissive` ⇒ no reboot). Mirrors the workload `spin-up.sh`; `setup.sh` stays the non-interactive contract it wraps |
| setup.sh | orchestrator (run as root): runs the system layer then the rootless layer in their correct identities |
| setup-host.sh | **system layer**, as root — packages, /etc, system services, tailnet, host dnf-automatic, creates `core` + its rootless prerequisites |
| setup-user.sh | **rootless layer**, as `core` — user podman socket, ssh keys, claudebox, Claude policy, the `claude` + `claudebox-rebuild` wrappers + the box-rebuild units, workload-refresh harness, verify (no host privilege) |
| sync-authorized-keys.sh | authorizes `core`'s SSH keys from `github.com/<user>.keys` — ALL keys on the account (the account is the single trust root; no in-image allowlist, no LOGIN_KEY tagging — symmetric with the dev box); defensive (never wipes keys on a failed/empty fetch) |
| distrobox.ini | claudebox, declaratively (image pin, pre-init Anthropic repo on the `latest` channel, packages) |
| box-rebuild.sh | the full claudebox rebuild (`distrobox rm -f` → re-run setup-user.sh); detached so it outlives the box it recreates |
| claudebox-daily.sh | daily-refresh decision: rebuild now if idle, else defer to session exit |
| claudebox-init.sh | claudebox host bridge (CONTAINER_HOST → host rootless podman socket) + in-box `claudebox-rebuild` command, applied post-assemble over the quote-safe `distrobox enter -- sudo` channel |
| cockpit-tailnet-serve.sh | publishes Cockpit on the tailnet (`tailscale serve` :443 → loopback:9090) + writes `/etc/cockpit/cockpit.conf` for the proxied origin |
| selinux-enforce-once.sh | fire-once helper for the **no-wait** SELinux disabled→enforcing convergence. Installed to `/usr/local/sbin/selinux-enforce-once`, run by the `selinux-enforce-once.service` unit `setup-host.sh` stamps; on the first permissive+labeled boot it flips to enforcing **live** (`setenforce 1` + config) and self-disarms (arm marker `/var/lib/fedora-bootstrap/selinux-enforce-armed`). Replaced the pre-v1.2.49 four-unit soak/AVC-gate/health-check/auto-revert state machine. |
| container-refresh.sh | per-workload refresh: busy-probe + pull + digest compare + `systemctl --user restart <name>.service` + rollback on health failure |
| claudebox-busy-probe.sh | generic busy probe — `podman exec` + AND-check session.lock + box-rebuild.lock; exit 0/1/2 = idle/busy/broken |
| live-gate-watch.sh | live-gate DISCOVERY (Gate B). One org-wide `gh` query for every `live-validate`-labelled open PR (no repo list), resolves each head SHA, per-`(repo,SHA)` `.done` dedup + `flock` self-serialize, invokes `live-gate-run.sh`. Runs inside claudebox (needs `gh`/`git`; drives the host engine via `CONTAINER_HOST`); a `systemd --user` timer. `LIVE_GATE_WORKLOADS` is an optional allowlist FILTER (unset = org-wide) |
| live-gate-run.sh | clone-on-demand + orchestration for one PR: fetches ONLY the PR head into an ephemeral tree, applies the STRUCTURAL GUARD (gateable only with a top-level `.live-gate`/`Containerfile*`, else neutral `SKIPPED`), PARSES the in-repo `.live-gate` (never `source`s it), builds + gates every declared target, posts the combined GREEN/RED verdict comment, tears the tree down. The host comments, never merges |
| build-candidate.sh | pre-merge BUILD step: exports a PR ref to a throwaway tree (under `$FD_THROWAWAY_TMPDIR`, sweeper-reapable), `podman build`s a DISPOSABLE candidate (`localhost/disposable/<name>:val-<sha>`, never pushed, `--rm`/`rmi`'d; base layers stay cached) with a PERSISTENT dnf RPM bind cache (`$FD_DNF_CACHE` → `/var/cache/libdnf5`, churn served from cache; the host engine is not chroot-isolated so a bind cache works), hands it to `validate-candidate.sh`. Sanctioned by the v1.2.25 carve-out |
| throwaway-sweep.sh | throwaway-churn reaper + cache GC: removes AGED orphan `localhost/disposable/*` images, `vcand-*` containers, and throwaway source trees a `kill -9`/crash left (the per-run EXIT traps miss); BOUNDS the persistent dnf RPM cache by SIZE — over `FD_DNF_CACHE_CAP_GB` (default 15 GB) it is dropped **wholesale** (`rm -rf`; a data-less cache re-warms for free, so no per-RPM age/LRU bookkeeping); prunes DANGLING layers (`image prune -f`); and CAPS the image STORE by reaping UNUSED images older than `FD_STORE_MAX_AGE_H` (default 60 d) via `image prune -a --filter until=` — a running Quadlet workload's image is always spared, so this only reaps retired GHCR digests + superseded base images. Age-gated + non-forced + flock-guarded + self-throttled so it never touches a running gate's artifacts; invoked at `live-gate-watch.sh` start, also wirable to a periodic timer/cron. (NB the surgical AGE-then-LRU dnf GC — `FD_DNF_CACHE_MAX_AGE_DAYS` — lives on the DEV side in `fedora-dev`'s `build-throwaway.sh`; the host is deliberately blunt.) |
| validate-candidate.sh | Gate B itself: runs the disposable candidate fenced (`CAND_FENCE`, loopback-only, no real secrets) and probes its OWN loopback (`CAND_PROBE` — does it actually serve, not just health) → PASS/FAIL |
| Containerfile.livegate | fedora-bootstrap's SHELL live-gate build (P0 uniform loop) — NOT a deployable image. The host live-gate builds it DISPOSABLY; its RUN steps ARE the gate — shellcheck + `bash -n` on every shipped `*.sh`, every `--selftest`, the mock host-agent dry-run. Build GREEN = verdict GREEN; a failed check = a failed RUN = RED. Untrusted PR shell runs INSIDE the throwaway build, never on the host. Reuses the image-repo harness verbatim (zero new host machinery) — this is how a NON-image repo gets a live-gate verdict the poller can read |
| .live-gate | fedora-bootstrap's live-gate CONTRACT (PARSED, never sourced) — one target `shellgate` building `Containerfile.livegate` with a trivial health + no probe (this repo is the orchestrator, not a workload; the build already decided the verdict). Makes the host gate this non-image repo like any workload, closing the STRUCTURAL-GUARD SKIP |
| host-agent-watch.sh | **the HOST AUTONOMOUS AGENT** (apparatus fedora-dev#131 R5) — the symmetric half of the dev-side poller. Consumes dev→host **`host-task` GitHub-issue tickets** from the **control repo** (`$ORG/$REPO`, default `oso-gato/fedora-bootstrap` — host commands are scoped to the host's own repo, NOT org-wide, so authorization is the host repo's collaborators; `gh issue list` per tick — immediate, no search-lag, dep-free; flock singleton), parses the LINE-1 instruction `host-op: <verb> [args]`, dispatches to a fixed **verb ALLOWLIST** (v1: `redeploy <workload>` → `workload-refresh@<workload>`; **no arbitrary-command verb by design**; workload arg must be in the known set), reports the true outcome (DONE/DEFERRED/FAILED-rolled-back via `ExecMainStatus`) as a `host-agent:` comment + best-effort label + closes the ticket. **Decoupled idempotency**: `.acted` (written the instant the mutating op runs) guards the action so a delivery retry never re-redeploys; `.done` (written on delivery) guards re-delivery. Runs INSIDE claudebox (gh + CONTAINER_HOST bridge); `--selftest` exercises the pure parser + allowlist. Driven by `host-agent-watch.timer` (10s), stood down during a box rebuild. Before any destructive verb lands, an issue-author allowlist must gate dispatch |
| systemd-units/ | instance templates for workload-refresh + retry, the two watcher units, + `claudebox-up.service` |
| systemd-units/claudebox-up.service | **the claudebox OWNER** (incident 2026-07-11). Starts the box with `env -u INVOCATION_ID podman start claudebox` so podman creates the container's OWN `libpod-conmon` scope (it skips scope creation when `INVOCATION_ID` is set — the exact bug: conmon then lands in the *starting* unit's cgroup and dies with it, exit 143). **`RemainAfterExit=yes` and NO `ExecStop`** — v1.2.60 shipped neither and the unit STARTED then immediately STOPPED the box every ~10s tick (a oneshot without RemainAfterExit goes inactive the instant ExecStart returns, and systemd runs ExecStop on deactivation; a `claude` session died in 5s). Do not re-add ExecStop; do not drop RemainAfterExit. **Recovery** of a dead box is the watchers' job, not this unit's: their `env -u INVOCATION_ID … distrobox enter` starts a stopped box into an independent scope every 10s. Rebuild-guarded via ExecCondition; `podman start` is a no-op on a running box. Enabled + started by setup-user.sh BEFORE the watcher timers; stood down + re-armed by box-rebuild.sh |
| policy/CLAUDE.md | host-claudebox runtime law (stamped at /etc/claude-code/CLAUDE.md inside the box) |
| policy/managed-settings.json | deny-rule guardrails (defense-in-depth) + bypass-permissions disabled (managed tier) |
| policy/sudoers.claudebox | scoped passwordless-sudo allowlist for the operating user; visudo-validated, stamped to /etc/sudoers.d/claudebox |
| verify.sh | PASS/FAIL acceptance: sockets, box, claude, policy, host-engine reach, tailnet, box-rebuild units, workload-refresh timers, dnf-automatic timer, fail2ban absent (key-only door), firewalld absent (leaf footprint), sudo doctrine boundary, SELinux config not disabled (permissive or enforcing) |
| .github/workflows/refresh-release.yml | weekly CI (Fri): re-checks Fedora's latest stable + Hostinger's provisioned version, refreshes README status line + pinned releasever |

## PACKAGES

> **Base-tooling assumption:** the SELinux disabled→enforcing convergence relies on Fedora Cloud `@core` tooling assumed present and intentionally **not** installed by this repo (so it is not a host-footprint addition): **policycoreutils** (`restorecon`/`fixfiles`/the stock `selinux-autorelabel` units) and **libselinux-utils** (`getenforce`/`setenforce`). If a future minimal base drops them, the convergence no-ops (host stays permissive). This keeps the "complete sanctioned host footprint" invariant honest about the dependency.

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
| Host | fastfetch | Fedora repos | system-info banner shown at every interactive login (operator waiver to Build Principle 4) via the `/etc/profile.d/zz-fastfetch.sh` drop-in; a single small binary. Also a Box tool (below). |
| Box | claude-code | Anthropic's official dnf repo (`latest` channel) | the manager — claudebox's purpose; refreshed daily by box rebuild |
| Box | host-spawn | Fedora repos | container side of distrobox-host-exec (no GitHub download — deterministic) |
| Box | bubblewrap, socat | Fedora repos | Claude Code's Linux sandbox dependencies |
| Box | podman (client) | Fedora repos | drives the HOST engine via CONTAINER_HOST socket |
| Box | git, gh, tmux, fastfetch | Fedora repos | orchestration toolset (repos, GHCR auth, sessions) |

Class-(c) artifacts in use: none (see the Class-(c) rules under BUILD PRINCIPLES). Adding a
package = add a row + edit setup-host.sh / distrobox.ini accordingly + PR.
