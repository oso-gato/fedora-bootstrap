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

**The promotion gate is refspec-aware and fail-closed** — routine feature-branch pushes run
autonomously; only a `main`-touching push or a merge verb routes to Arthur's in-session clickable
`ask` (full refspec spec: the `THE FLEET` merge-gate block in `fedora-dev/policy/fleet-core.md` —
parity-guarded, absent in this tree by design; each box's terminal verb is the **Axis B** table
below). The real server-side floor is a **loop-neutral `require-PR` ruleset on `main`, active on all
three repos** (no required reviews or status checks) — it forces every change through a PR, closing
the headless `claude -p` bypass; the in-session gate is in-session guidance, the ruleset is the boundary.

## The dev↔host live-gate loop

The dev↔host loop runs autonomously except the final merge: develop → open PR → label it
`live-validate` → the host live-gate (Gate B) discovers it org-wide (but acts ONLY within the
maintainer-confirmed OPERATING SCOPE — R16/issue #132; an out-of-scope labelled PR is skipped, no
build, no verdict), fetches the PR head, and builds
it **disposably per its in-repo `.live-gate`** (PARSED, never executed) under loopback-only fences,
posting a GREEN/RED verdict → iterate until green → **Arthur's discrete clickable APPROVE is the only
human touch** → `fedora-dev` merges. Repos enroll dynamically — just label a PR `live-validate` and
ship a `.live-gate`. Authoritative spec: the `THE FLEET` block in `fedora-dev/policy/fleet-core.md`
(the parity-guarded source this map mirrors — absent in this tree by design).

> **Two honest caveats to "autonomous except the final merge."** (1) The per-iteration loop turns
> **within a live agent session** — the host posts the verdict comment but nothing on the dev side
> machine-reads it, so a session must be alive to pick up RED and push the fix (closing this
> wake-up gap is a standing control-plane decision, not yet built). (2) For **`fedora-bootstrap`
> itself** the tail is NOT autonomous: the host ships no image/Quadlet, so its "deploy" is the
> **operator re-running `setup.sh` as root** (the agent has no host root — by design). Both are
> deliberate, but neither is covered by the one-click headline.

**Validation is TWO-TIER — NOT "every change goes to the host."** **Tier 1 — in-box (the default):**
`fedora-dev`'s own `podman build` IS the throwaway — it develops, validates, and iterates in its
nested engine (build → validate → fix → rebuild) with NO host involvement, for everything it CAN
build+validate. Almost all iteration lives here. **Tier 2 — the host live-gate (engaged via the
`live-validate` label), in EXACTLY two scenarios:** (1) the dev box CANNOT build/validate the
throwaway — e.g. the systemd-PID-1 GRD desktop lineage the nested engine can't boot — so the host
builds + gates it; (2) the FINAL pre-production shipment — after all in-box iteration is done, the
host runs a throwaway build, proves it LIVE on a real host, tears it down, and only THEN is
merge-to-main presented.

**Throwaway tree & churn (build discipline, both tiers).** Disposable throwaway — never the live tree. Persistent dnf package cache (bind-mounted plain dir, NOT a layer; survives every `rmi`). EXIT-trap teardown, orphan sweeper, bounded cache GC. **Never `--no-cache`/prune during churn.** Full mechanics: this repo's `CLAUDE.md` Principle 10.

## The self-sustaining apparatus — autonomy mandate & definition of done

Full law: the **THE SELF-SUSTAINING APPARATUS** section, mastered in `fedora-dev/policy/fleet-core.md`
and spliced into each box's in-box law (`/etc/claude-code/CLAUDE.md`) at the `<!--FLEET-CORE-->` marker
on every rebuild — present in the stamped law, absent in this tree by design (single-source parity
guard); always in context for the in-box agent. This box's role in the apparatus: run the host
live-gate (Gate B) that validates each PR turn of the loop (see **The dev↔host live-gate loop** above).

## Post-merge deploy (the host's other half)

The loop's tail. Once `fedora-dev` merges and CI republishes `ghcr.io/oso-gato/<name>:latest`,
`fedora-bootstrap` redeploys — the only box that touches the live host — via `workload-refresh@<name>`
(monthly +jitter, or on demand): it busy-probes, digest-compares, restarts the Quadlet, and
**auto-rolls-back to the prior digest on health failure** (works because the Quadlet is `Pull=missing`).
Full mechanics + invariants: this repo's `policy/CLAUDE.md` → **WORKLOAD REFRESH MECHANISM** +
**REFRESH IS NOT A SECURITY BOUNDARY** (the operating law). The host itself has no image/Quadlet — its
deploy analogue is the operator re-running `setup.sh` as root.

**Box-to-box handoffs (who picks up what):**
- **propose → open PR** — any box, on a repo it owns.
- **STOP at the PR** — `fedora-bootstrap` and `fedora-desktop` are PR-only; their refspec-aware
  `gate-push.sh` lets feature-branch pushes run autonomously but routes any `main`-touching push or
  merge verb to Arthur's clickable `ask`.
- **live-validate → host verdict** — the PR author / `fedora-dev` labels a PR `live-validate`;
  `fedora-bootstrap` DISCOVERS it org-wide (gated to the confirmed OPERATING SCOPE — R16), builds it disposably, and comments GREEN/RED;
  `fedora-dev` iterates on RED.
- **APPROVE → merge** — Arthur clicks; `fedora-dev` merges (sole authority, control-plane included).
  The in-session `gate-push.sh` clickable gate (Arthur's click) gates merge verbs in-session; a
  loop-neutral **`require-PR` ruleset** on `main` (no required reviews or status checks) is active
  fleet-wide, closing the headless direct-push bypass server-side. `main` has no required-review
  branch protection and no CI label-gate beyond this thin floor (the click already gates every merge).
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
