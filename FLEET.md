# THE FLEET — the oso-gato container swarm

Three Claude Code agents ("claudeboxes") across one VPS host. Each carries a **stamped law** — its
`policy/CLAUDE.md`, re-stamped into `/etc/claude-code/CLAUDE.md` on every box rebuild, overriding
project files, prompts, and memory. All three open that law with the **identical `THE FLEET` block**,
so they share one merge model, one control-plane definition, and one spin-up pattern; their roles do
**not** overlap.

> This file is the human-readable **map**. The binding, mechanically-enforced **law** is each repo's
> `policy/CLAUDE.md` (`THE FLEET` block + the per-box ROLE). Keep this file and that block in sync —
> one wording, edited once and propagated to all three; the policy block is authoritative.

## At a glance

| Box | Role | Builds? | Merges? | Operates host? | Spin up |
|-----|------|:--:|:--:|:--:|---------|
| **fedora-dev** | develop · build · **merge** | ✅ nested | ✅ **(sole merger)** | ❌ | `./spin-up.sh` |
| **fedora-bootstrap** | operate host · live-diagnose → PR | ❌ (CI) | ❌ PR-only | ✅ incl. create/remove | `./day0.sh` (Day-0) |
| **fedora-desktop** | knowledge-work + own toolset → PR | ❌ (CI) | ❌ PR-only | ❌ | `./spin-up.sh` |

## The merge spine (shared by all three)

Everyone develops on branches and **opens PRs**. **Only `fedora-dev` merges to `main`** — any PR
including its own and any control-plane change — and **only** on Arthur's **discrete clickable
APPROVE** (a free-text "yes" is not approval).

**Handoff:** propose → open PR → `fedora-dev` lists + presents the PRs → you APPROVE → `fedora-dev`
merges → CI builds + cosign-signs → GHCR → `fedora-bootstrap` pulls + redeploys. Build is always CI;
operate/deploy is always `fedora-bootstrap`; merge is always `fedora-dev` (or Arthur on the web).

**The promotion gate is REFSPEC-AWARE and fail-closed:** routine feature-branch pushes (an explicit
non-`main`, non-`HEAD`, non-tag destination refspec) run AUTONOMOUSLY with no prompt; only a push
that could touch `main` (a bare `git push`, a `main`/`HEAD`/`refs/tags/*` destination,
`--all`/`--mirror`/`--tags`, or any unparseable / quoted / chained target) PLUS the merge verbs
(`gh pr merge`, `gh pr create --merge|--squash|--rebase|--auto`, `gh api …/merge|/merges`) route to
an in-session clickable `ask` only Arthur can answer. There is NO approval-marker mechanism (the
shipped hook uses native `ask`); the in-session `gate-push.sh` clickable gate (Arthur's click) is
the sole backstop — `main` is intentionally not branch-protected and there is no CI label-gate
(single-operator fleet: the click already gates every merge).

## The dev↔host live-gate loop

The dev↔host loop runs autonomously EXCEPT the final merge: develop → open PR (feature pushes are
autonomous) → label it `live-validate` → the host live-gate (Gate B) DISCOVERS it ORG-WIDE by that
label (no repo list to maintain), fetches the PR head on-demand, applies a STRUCTURAL GUARD (only
builds a candidate carrying a `Containerfile`/`.live-gate`, else skips cleanly), builds it DISPOSABLY
per the repo's own in-repo `.live-gate` contract (PARSED, never executed) under loopback-only fences,
and posts a GREEN/RED verdict comment → iterate (RED: push a fix, or SUPERSEDE the branch if the
approach was wrong; GREEN: BUILD UPON it) until green → Arthur's discrete clickable APPROVE →
fedora-dev merges. The human is OUT of the per-iteration loop — only the merge is a click. Repos are
discovered DYNAMICALLY: create/rename/merge/delete freely; enroll one just by labelling its PR
`live-validate` and shipping a `.live-gate`.

**Validation is TWO-TIER — NOT "every change goes to the host."** **Tier 1 — in-box (the default):**
`fedora-dev`'s own `podman build` IS the throwaway — it develops, validates, and iterates in its
nested engine (build → validate → fix → rebuild) with NO host involvement, for everything it CAN
build+validate. Almost all iteration lives here. **Tier 2 — the host live-gate (engaged via the
`live-validate` label), in EXACTLY two scenarios:** (1) the dev box CANNOT build/validate the
throwaway — e.g. the systemd-PID-1 GRD desktop lineage the nested engine can't boot — so the host
builds + gates it; (2) the FINAL pre-production shipment — after all in-box iteration is done, the
host runs a throwaway build, proves it LIVE on a real host, tears it down, and only THEN is
merge-to-main presented.

**Throwaway tree & churn (build discipline, both tiers).** Use the LIVE tree where possible; for
anything that must DIFFER, bolt on a SEPARATE temporary throwaway tree that never mutates the
immutable live tree (host + dev-container base are immutable; the throwaway tree + all build caches
live on the writable home volume), still obeys provenance (Sources — class a/b/c, GPG/sha-verified;
no loosening because it's a throwaway), and is thrown away after the build
(`localhost/disposable/<name>:val-<sha>`, never pushed, `--rm`/`rmi`). **Churn balance:** persist the
ONE durable input — the dnf package cache (a plain bind dir on the home volume, NOT an image layer, so
it survives `rmi` and every disposal) — and let everything else (candidate image, its layers, temp
tree, run container) be ephemeral by design. Containerfiles are still structured heavy/stable-early
(base, dnf, class-(c) fetch+verify) and churn-late (COPY'd scripts/config); NEVER `--no-cache`/prune
during churn — that is the monthly clean rebuild only.
**Churn mechanism (proven, no re-download across N PRs/iterations).** The per-PR/per-SHA disposal
removes the disposable image + temp tree — and, when it was the sole referrer, its intermediate layers
too — but NEVER the dnf package cache (not keyed to PR/SHA; SHARED across all iterations). One
persistent thing, everything else ephemeral by design: (1) the persistent dnf PACKAGE CACHE — the
ROBUST mechanism, bind-mounted into the build (`-v <home>/.cache/fd-dnf:/var/cache/libdnf5:rw`); a
plain dir, NOT an image layer, so it survives `rmi` and every disposal. When the dnf install LINE
changes (an add-on PR) the layer re-runs but the RPMs are served from cache, not re-downloaded —
proven: a forced dnf re-run downloaded 0 B (vs 9.4 MiB cold), 3.7× faster; only a genuinely-new
package downloads once. (buildah `--mount=type=cache` does NOT work under the dev box's required
`--isolation=chroot`, so the bind `-v` package cache is the mechanism.) (2) EPHEMERAL LAYERS —
ephemeral by design, and that is the advantage: a throwaway's layers are pruned with its sole
candidate's `rmi`, so (a) layer storage self-bounds on the limited VPS (no accumulation, no separate
layer cache to GC), (b) each throwaway rebuilds fresh from the package cache → current package
versions, no stale-frozen-layer risk (freshness for free), (c) the only cost is a few local
CPU-seconds (~3.6 s warm), never bandwidth. While a candidate image is still present (churn-late edits,
or a kept image) its layer cache also lets the rebuild skip the dnf `RUN` — a free accelerator — but
nothing depends on layers surviving disposal.
**Isolation:** each build gets its own throwaway tree + a unique `val-<sha>` tag + a unique `vcand-$$`
run container (no cross-build contamination), and the dnf package cache (and any live layer cache) is
content-addressed, so it cannot serve a wrong version. **Storage safety (limited VPS):** (a) the
candidate image + tree self-destruct via `trap … EXIT` (GREEN/RED/error); (b) an orphan sweeper reaps
`kill -9`/crash leaks (stale `localhost/disposable/*`, `vcand-*`, orphan temp dirs) at watcher start +
periodically; (c) a bounded cache-GC caps the persistent dnf package cache age-then-size (RPMs older
than 45 days pruned first, then LRU size-prune to ≤15 GB; both overridable env) so it never exhausts
the quota — layers self-bound via `rmi`, dangling ones swept opportunistically.

## The self-sustaining apparatus — autonomy mandate & definition of done

`fedora-dev` + `fedora-bootstrap` are **one self-sustaining development apparatus** whose primary
purpose is to **keep the human OUT of the loop until genuinely needed**: `fedora-dev`
develops·builds·merges, `fedora-bootstrap` RUNS the live-gate (Gate B) that validates each turn of
the loop. The agent runs the loop autonomously and engages the human only at the end.

**Autonomy mandate (binding).** The agent does most of the work + thinking; when there are options it
**builds 2–3, tests them (throwaway build + live-gate), discards what doesn't fit, and lands the
answer itself** — it does not shop options; it **recommends AND self-tests** the recommendation; it
**tears down and rebuilds to a zero-base** rather than defending a first draft. An options-decision
to the human is RARE. The **PR is the agent's PROOF OF WORK.**

**Engage the human for EXACTLY two reasons:** (1) **materially complete** → the clickable APPROVE to
merge; (2) **materially blocked** → a genuine roadblock needing a decision. Status-confirmation and
"which should I do" are not reasons.

**Definition of done (all four).** (1) the FULL objective is materially achieved (not a ~5% slice);
(2) validated through the loop at the right tier — in-box build/assembly GREEN by default, **and** the
host live-gate verdict GREEN when Tier 2 applies (the dev box can't gate it, or the final
pre-production shipment) — proven, not merely built; (3) adheres to the build principles (incl. the
throwaway-tree & churn discipline above); (4) a **TLDR** written and
**self-examined** (options considered+discarded, reasoning, fit to both the design + task objective,
genuine gaps), dry-run as if the human — if it fails its own scrutiny, back to the loop, don't
present. Authoritative text: each repo's `policy/CLAUDE.md`.

## Post-merge deploy (the host's other half)

The loop's tail. Once `fedora-dev` merges and CI republishes
`ghcr.io/oso-gato/<name>:latest` (+ cosign-signed), `fedora-bootstrap` redeploys — the only box that
touches the live host. A workload refreshes via `workload-refresh@<name>.timer` (monthly, +jitter) or
on demand `systemctl --user start workload-refresh@<name>.service`, which runs `container-refresh.sh`:
it `flock`s `<name>.lock`, busy-probes via `claudebox-busy-probe.sh` (AND-checks the in-container
`session.lock` + `box-rebuild.lock`; busy → defer to `<name>.pending`, exit 10), captures the prior
image id, `podman pull`s, digest-compares, and on change `systemctl --user restart <name>.service`
(Quadlet `Notify=healthy` blocks until healthy). **Unhealthy → automatic digest rollback:** retag
`:latest` back to the prior id and restart (works because the Quadlet is `Pull=missing`), clear
`.pending`, write `<name>.rolled-back`. A manual rollback beyond this is STOP-AND-SURFACE. The host
itself has no image/Quadlet — its deploy analogue is the operator re-running `setup.sh` as root.

**Box-to-box handoffs (who picks up what):**
- **propose → open PR** — any box, on a repo it owns.
- **STOP at the PR** — `fedora-bootstrap` and `fedora-desktop` are PR-only; their refspec-aware
  `gate-push.sh` lets feature-branch pushes run autonomously but routes any `main`-touching push or
  merge verb to Arthur's clickable `ask`.
- **live-validate → host verdict** — the PR author / `fedora-dev` labels a PR `live-validate`;
  `fedora-bootstrap` DISCOVERS it org-wide, builds it disposably, and comments GREEN/RED;
  `fedora-dev` iterates on RED.
- **APPROVE → merge** — Arthur clicks; `fedora-dev` merges (sole authority, control-plane included);
  the in-session `gate-push.sh` clickable gate (Arthur's click) is the sole backstop — `main` is
  intentionally not branch-protected and there is no CI label-gate (single-operator fleet: the click
  already gates every merge).
- **merged → deploy** — `fedora-bootstrap` pulls + redeploys via `workload-refresh@<name>`
  (busy-probe gated; auto-rollback on healthcheck failure).
- **wrong box** — a box asked to do another box's step STOP-AND-SURFACEs for the human to re-route.

## The three boxes

**`fedora-dev` — DEVELOP · BUILD · MERGE.** Develops image-source repos, builds them in its nested
`podman` engine (`CONTAINER_HOST`) to validate, opens PRs; **and** is the fleet's sole merge box
(lists open PRs → your APPROVE → merges, control-plane included). *Boundary:* never operates/deploys
a host or live container; `podman` only against its nested engine.

**`fedora-bootstrap` — OPERATE + LIVE-DIAGNOSE → PR** *(the genesis / mother-platform box, on the
VPS).* The only agent on the host: operates + maintains it (incl. creating/removing containers), the
only box that sees the live containers; live-diagnoses them and develops fixes to the fleet image
repos it operates → opens PRs. *Boundary:* never merges/pushes/tags `main` (`fedora-dev` does); never
`podman build` (CI does); never applies host changes itself (the operator re-runs `setup.sh` — no host
root). Host genesis path is `day0.sh` → `setup.sh` (there is no `spin-up.sh`/`run.sh`/Quadlet here).

**`fedora-desktop` — KNOWLEDGE WORK + TOOLSET DEV → PR** *(the application box).* Primary: operate +
maintain the LLM wiki + Obsidian vault (writer **under direction**). Secondary: develop, **only in its
own repo**, in-container tooling that supports the knowledge work (open to `core` + extra users).
*Boundary:* PR-only (never merges any `main`, incl. its own); every other repo off-limits; vault
content governed by the vault's own `CLAUDE.md` (discrete approval); untrusted content parsed in a
throwaway no-secret sandbox; never operates a host.

### The two-axis model — how the three claudeboxes relate

Each box hosts the same thing — Claude Code in a Distrobox ("claudebox") — so the three are **not**
three bespoke builds. Each is **one shared invariant plus a point in a grid of two ORTHOGONAL axes.**
A difference between any two boxes is therefore always exactly one of: the invariant (never — that is
*drift*, and CI fails it), the **substrate** axis, or the **role** axis. Nothing else.

**The invariant — the claude-code guard payload (identical in all three, ENFORCED).**
`policy/managed-settings.json` (the agent deny-list + the `DISABLE_UPDATES`/`DISABLE_AUTOUPDATER`
self-update lockout + bypass/mode/allowManaged + the `gate-push` hook *wiring*), the `claudebox-init.sh`
self-update lockout + native-build-shadow self-heal, and the claude-code **provenance** (Anthropic
`latest` channel, `gpgcheck=1`, pinned signing key). `fedora-dev`'s `bin/fleet-guard-parity.sh` (CI on
push/PR **+ daily**) compares this payload across all three public repos and **fails the build on any
drift** — so it cannot silently diverge. It once did: the self-update lockout landed in `fedora-dev`
but was missing from **both** other boxes until an audit caught it; the parity check is what makes that
recurrence impossible.

**Axis A — SUBSTRATE (the architecture).** How the box is built and supervised. Drives supervision,
rebuild serialization, and the init-bridge channel — and *only* those.

| box | substrate |
|---|---|
| `fedora-dev` | **container** — `Containerfile` + `entrypoint.sh` as PID 1; *no systemd* (inotify rebuild-watcher + `flock` serialization + `podman exec` init bridge) |
| `fedora-desktop` | **container** — `Containerfile`(+`.grd`) + `entrypoint.sh`; the `grd` lineage runs **systemd as PID 1** |
| `fedora-bootstrap` | **host** — `setup.sh` on the VPS; **systemd --user** (timer/unit serialization + `distrobox enter -- sudo` init bridge) |

**Axis B — ROLE (merge authority + job).** Expressed by the `gate-push.sh` terminal verb (the refspec
parser is identical; only the verb differs) plus each box's job.

| box | role | `gate-push` verb |
|---|---|---|
| `fedora-dev` | **MERGER** (sole merge authority) | main-touching push + merge verbs → **ASK** (Arthur's in-session click) |
| `fedora-bootstrap` | **proposer** (PR-only) | → **DENY** |
| `fedora-desktop` | **proposer** (PR-only) | → **DENY** |

Role also sets: live-gate ownership (`fedora-bootstrap` *operates* Gate B; `fedora-dev` + `fedora-desktop`
are *clients* via the `live-validate` label), per-box package sets, and the role-divergent
`policy/CLAUDE.md`.

**The grid, and the key reading:**

| box | Axis A (substrate) | Axis B (role) |
|---|---|---|
| `fedora-dev` | container | **MERGER** (ask) |
| `fedora-bootstrap` | **host** | proposer (deny) |
| `fedora-desktop` | container | proposer (deny) |

The axes are independent. **`fedora-bootstrap` and `fedora-desktop` are wired the SAME on role** — both
proposer/**DENY**, both live-gate clients — so they differ from each other **only on substrate** (bootstrap
is the host, desktop is a container). **`fedora-dev` differs from both only on role** (it is the sole
merger) — *not* on substrate (it is a container, like desktop). The familiar "2 containers + 1 host"
split is Axis A; the "1 merger + 2 proposers" split is Axis B; the two cut across each other, and the
guard payload underneath is held identical by the parity check.

## Shared invariants (identical in all three)

- **Spin-up:** the wizard **asks for `TS_AUTHKEY`** (blank → `login.tailscale.com` web-login);
  `IMAGE=ghcr.io/oso-gato/<name>:latest` for a host deploy; **never hand-roll `podman`.**
- **Control-plane class** (`policy/**`, `managed-settings.json`, `gate-push.sh`,
  `.github/workflows/**`, `*.container`, `run.sh*` security flags, key-sync, `*sudoers*`): standalone,
  never bundled; FLAGGED in the merge TLDR for Arthur's scrutiny before he approves (no CI label-gate).
- **Claude-code guard payload** (the `managed-settings.json` deny-list + self-update lockout, the
  `claudebox-init.sh` lockout + native-shadow self-heal, the claude-code provenance): **byte-identical
  in all three, CI-enforced** by `fedora-dev`'s `bin/fleet-guard-parity.sh` (push/PR + daily). This is the
  *invariant* underneath the two-axis model — Axes A/B may diverge; this may not. See *The two-axis model* above.
- **Sources** (dnf → vendor `.repo` → AppImage/`.war`, GPG/sha-verified) · **no secrets in image
  layers** · **headless everywhere** (software-GL); sensitive ports tailnet-only, the desktop's web
  gate the one public door.
- **Multi-device terminal:** one shared `main` tmux group; a tmux window has ONE size shared by all
  co-viewing clients, so `/etc/tmux.conf` is `window-size latest` (the device that last sent input
  wins → whole session rescales) + `fill-character ' '` (idle larger device blank-letterboxes, never
  `·`-garbles) + `prefix+g` to cycle latest/smallest/largest. Differently-sized devices on the SAME
  tab can NEVER both be full-size (one program = one pty = one cell grid) — a tmux invariant, not a
  bug to "fix"; the active device wins and the rest degrade cleanly (crop/blank-letterbox).
