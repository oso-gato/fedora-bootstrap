# Live-validation gate + rollback backstop — the `.live-gate` reference

**Status: the dev->host handoff is COMPLETE.** Both halves are proven on the host box
(`fedora-bootstrap`, on `erebus`): the pre-merge live gate (`validate-candidate.sh`) and the
post-merge rollback backstop (`validation/rollback-spike.sh`).

Settled architecture (from a 4-agent ultra-verify): **(B) `validate-candidate.sh` is the pre-merge
quality gate** — Tier-2 only, engaged via the `live-validate` label — and **(A) `container-refresh.sh`'s
digest rollback is the post-merge backstop** (proven by `rollback-spike.sh`). Cosign image-signing was
built then **reverted as over-engineering** (provenance, not containment, on a single-owner locked-down
host) — do **not** re-add it.

This file is now the **`.live-gate` schema + script-chain reference** (section 8 below). For the loop's
role and trust boundary see `policy/CLAUDE.md` (LIVE-GATE TRUST MODEL) and `FLEET.md` (the dev<->host
live-gate loop); for the throwaway/churn discipline see `CLAUDE.md` (Principle 10).

---

## 8. Model C — DYNAMIC discovery + the in-repo `.live-gate` contract (as built)

The transport in §6 is now built as **Model C: dynamic, repo-set-agnostic**. The watcher does
**not** carry a workload list, and a candidate repo does **not** need a pre-placed clone. As repos
are created / removed / renamed / merged, Arthur maintains **nothing** — labelling a PR
`live-validate` is the entire opt-in.

### 8.1 The pieces

| Script | Role |
|---|---|
| `live-gate-watch.sh` | **Discovery.** ONE org-wide query — `gh search prs --owner oso-gato --state open --label live-validate --json repository,number` (fallback `gh api search/issues -f q='org:oso-gato is:pr is:open label:live-validate'`) — finds every labelled open PR across **all** repos. Resolves each head SHA with `gh pr view <n> --json headRefOid` (note: `headRefOid` is **not** a `gh search prs` JSON field, so the SHA is a cheap second call). Per-`(repo,SHA)` `.done` dedup + `flock` self-serialize, unchanged. `LIVE_GATE_WORKLOADS` is now an **optional allowlist FILTER** (restrict discovery to those repos for safety/testing); unset = org-wide. |
| `live-gate-run.sh <repo> <pr>` | **Clone-on-demand + orchestration.** Fetches ONLY the PR head into an ephemeral temp tree (`git init` + `git fetch --depth 1 origin pull/<n>/head` + checkout — no default-branch clone). **Structural guard:** gateable only if the tree has a top-level `.live-gate` and/or a `Containerfile*`; else posts a neutral `SKIPPED` comment and exits 3 (never errors). **Parses** the contract **safely** (`lg_load` — never `source`s it; a contract that smuggles command substitution / chaining is rejected RED), builds + gates **every** declared target, posts the combined verdict, tears the tree down. |
| `build-candidate.sh <name> <src> [ref] [Containerfile]` | Builds ONE target's disposable image from the materialized tree (model-C path) or a clone+ref (legacy manual path), hands it to the gate, `rmi`s it. |
| `validate-candidate.sh <img> [health]` | Runs ONE built image fenced + disposable, waits healthy, runs the probe, returns PASS/FAIL. No runtime lineage-guessing — the fence it receives already matches the image that was built. |

**Multi-target = the grd fix.** A repo declaring `LIVE_GATE_TARGETS="xrdp grd"` is built **twice**:
the `grd` target builds `Containerfile.grd` under the systemd fence, the `xrdp` target builds
`Containerfile` under its fence. **ALL** targets must be GREEN. This is the explicit-target
replacement for the old approach (build the one `Containerfile`, guess the lineage at runtime),
which could mis-build a grd PR against the xrdp Containerfile.

**Networkless by default (containment).** A target's fence defaults to `--network=none
--cap-drop=ALL`; probes run on the candidate's own loopback via `podman exec`, so a loopback-only
workload never gets egress. A target needing egress/devices/systemd opts in explicitly via its
`FENCE_<target>`.

### 8.2 The `.live-gate` schema

A workload repo ships `.live-gate` at its **top level**; it travels in the PR head so the contract
always matches the code under test. It is consumed **SAFELY — PARSED, NOT SOURCED**: the host reads
it line by line and assigns each `KEY=VALUE` with `printf -v` (never `.`/`source`), so nothing in the
file is ever executed on the host. Grammar: one `KEY=VALUE` per line; single-quoted values are taken
verbatim (single-quote any HEALTH/PROBE command — its `$( )`/`&&`/`;` run only inside the fenced
container); double-quoted values reject command substitution; unquoted values must be a bare token;
no `;`-chaining, no cross-variable references. A contract that smuggles command substitution /
chaining (e.g. `FENCE_x="$(cmd)"` or `KEY=1; cmd`) is **rejected with a RED verdict, not executed**.
Resolution order: in-tree `.live-gate` → host `~/.config/live-gate/<repo>.env` → generic default
(single `Containerfile`, image HEALTHCHECK, no probe).

```
LIVE_GATE_TARGETS="xrdp grd"        # space-separated; omit => one implicit target `default`

# per-target, suffixed _<target> (a bare CAND_*/HEALTH global is the fallback for any unset target):
CFILE_<t>          # Containerfile to build (default: Containerfile) — the multi-lineage selector
FENCE_<t>          # podman run flags = run.sh MINUS -p MINUS real secrets; default --network=none --cap-drop=ALL
HEALTH_<t>         # explicit health-cmd (OCI drops the Containerfile HEALTHCHECK)
PROBE_<t>          # "does it serve" assertion, podman exec on the candidate's loopback; exit 0 = serves
SECRET_MOUNT_<t>   # in-container path to bind-mount the scratch secrets file (ro, 0600)
SECRET_ENV_<t>     # KEY=VALUE lines — DISPOSABLE test values, never real, never baked/logged
MEMORY_<t> PIDS_<t># gate-imposed caps (default 2g / 512)
HEALTH_START_<t>   # --health-start-period (default 90s)
HEALTH_TRIES_<t> HEALTH_SLEEP_<t>   # healthy-wait budget = TRIES × SLEEP s (default 18 × 6)
```

A fully commented copy-me reference is `validation/live-gate.sample`. The
single-set `live-gate-presets/fedora-dev.env` is consumed via the implicit `default` target.
