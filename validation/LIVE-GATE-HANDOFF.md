# Live-validation gate + rollback backstop — HANDOFF to the host box

**Read this first. It is the standing brief for finishing the autonomous dev loop.**
It was written by the **fedora-dev** box, which develops + merges but has **no socket to
the host's podman engine and no systemd** — so it physically cannot *run* the two scripts
below. You (the **fedora-bootstrap / host claudebox**) are the only box that can. Your job:
**run + iterate the two drafted scripts on the host until they're green, then report back.**

Also read `~/.claude/CLAUDE.md` (the behavioural law) and this repo's `CLAUDE.md` +
`policy/CLAUDE.md` before touching anything.

---

## 1. The objective

A **self-looping, self-sustaining autonomous dev loop**: the agent develops a workload,
**validates it actually works**, iterates until green **on its own**, and presents only a
**known-working PR** for Arthur's terminal merge. **The human is in the loop at exactly one
point — the final merge.** Nowhere else.

## 2. The actors / moving pieces

| Actor | Role | Can run containers on the host? |
|---|---|---|
| **fedora-dev** (dev box) | develops, builds, runs the **in-box** validate harness (`bin/validate.sh`), and **merges** on Arthur's clickable APPROVE | **No** — nested rootless engine only; can't run a container in its own namespaces; no systemd |
| **fedora-bootstrap** (this box, on erebus) | **operates the host**, the only box that sees live containers, live-diagnoses, develops fixes → PRs | **Yes** — this is the only faithful live-run surface in the fleet |
| **erebus** (the host) | runs workloads as Quadlets; `container-refresh.sh` pulls `:latest` + health-gates + rolls back | — |

No nested KVM on erebus, so there is no separate VM/sandbox; the host kernel is the only
faithful execution surface. Everything below runs **disposably + torn down** — host stays
immutable.

## 3. The complete loop (where each gate sits)

```
fedora-dev: develop → IN-BOX validate (build+assembly+lint, bin/validate.sh) → iterate
              │  [DONE + MERGED: fedora-dev #28 / #29]
              ▼
   ┌──► (B) PRE-MERGE LIVE GATE  ── validate-candidate.sh ──┐   ← THIS WORK (the gate)
   │     run the candidate DISPOSABLY on the host, fenced,  │
   │     probe every access path, return PASS/FAIL          │
   └────────────────────────────────────────────────────────┘
              │  green
              ▼
   Arthur: terminal merge of the known-working PR   ← the ONE human touch
              │
              ▼
   (A) POST-MERGE BACKSTOP ── container-refresh.sh ──        ← THIS WORK (test the backstop)
        pull :latest → health-gate → ROLLBACK on failure
        (the rollback branch has NEVER fired — prove it)
```

**Architecture decision (settled by a 4-agent ultra-verify):** **B is the gate, A is the
backstop.** B is a real pre-merge quality gate that keeps the trunk known-good-live; A is a
deployment-resilience net, demoted to defence-in-depth — *and its rollback path has never been
exercised,* so it is not a safety net you can trust yet. **Both must be proven by a run on
this box.**

## 4. What is already done (do not redo)

- **In-box validate harness** — `fedora-dev/bin/validate.sh`, merged (#28 + #29). Gates
  build (`--isolation=chroot`) + assembly + lint, repo-agnostically, host-immutably; tested
  green on fedora-dev + both fedora-desktop lineages. This is the loop's pre-merge *static*
  gate. It does **not** prove the workload runs/serves — that's what (B) adds.
- **Cosign signature floor** — built then **reverted** as over-engineering (provenance, not
  containment; doesn't stop the real threat; host is single-owner + locked down). Don't
  re-add it. (fedora-dev #27 / fedora-bootstrap #30 closed; fedora-desktop #63 reverted #59;
  signing-key secrets deleted.)
- **A-vs-B architecture** — decided: **B gate + A backstop** (above).

## 5. What is left — YOUR work (drafted here, unproven; run + iterate to green)

### (A) Prove the rollback backstop — `validation/rollback-spike.sh`
Fires `container-refresh.sh`'s rollback branch once, against a **throwaway** workload
(`rbspike`), with tiny local images — no real fleet container touched, **nothing pushed to
GHCR**. Asserts: a never-healthy `:latest` is **rolled back** to the prior healthy digest,
the container is healthy again, and a `<name>.rolled-back` marker lands.

**The registry snag (already solved here):** `container-refresh.sh` *pulls* `:latest` from
GHCR (`:68`), so a local-only test can't push a broken image there. The spike drives the real
rollback logic via a **test-only `SKIP_PULL` seam** added to `container-refresh.sh` (unset in
production → zero prod behaviour change): the spike pre-stages the bad image as the workload's
local `:latest`, then runs `SKIP_PULL=1 container-refresh.sh rbspike`. The pull is orthogonal
to the rollback branch under test. (If you'd rather not carry the seam, the alternative is a
local registry — but the host `policy.json` rejects non-`oso-gato` images like `registry:2`,
so the seam is the clean path.)

Run it: `validation/rollback-spike.sh` → expect `VERDICT: GREEN`. If red, the rollback branch
has a real bug — diagnose + fix `container-refresh.sh`, that's the *point* of the spike.

### (B) Build the pre-merge live gate — `validate-candidate.sh`
The contained, disposable run of a candidate that fedora-dev cannot do. Runs the candidate
image `--rm` as a **fenced non-prod tenant** (own name/ports, **no secrets mounted**,
network-fenced, dropped caps, hard resource caps), waits for healthy, runs the workload's
access-path probes, captures a **structured PASS/FAIL + logs**, tears down. Returns the verdict
that lets the dev loop decide *before* a PR is opened.

It's drafted as a skeleton (the contract + the fence + the result shape). **Iterate it on a
real candidate** (e.g. a `fedora-desktop:xrdp` build) until its probes faithfully assert
"the web door serves + the desktop paints," then it's the gate.

## 6. How the loop closes (the channel, once B works)

fedora-dev builds a candidate + opens a PR → (B) runs here disposably + writes the structured
result back to the PR → fedora-dev reads it + iterates → when green, Arthur merges → (A)
backstops the deploy. The *transport* (how the PR triggers a run here + how the result returns)
is the last piece; for now, **run B by hand on a candidate to prove the gate itself works** —
the automated trigger is a follow-up once the gate is real.

## 7. Definition of done for this handoff

1. `rollback-spike.sh` → GREEN (A's rollback branch is finally proven, or fixed until it is).
2. `validate-candidate.sh` → runs a real candidate, returns a faithful PASS on a good image and
   FAIL on a broken one.
3. Report results back (PR comment / commit on this branch) so fedora-dev knows the live gate
   is real and can wire the trigger.

Everything here is **host-box work by construction** — fedora-dev drafted it but cannot run it.
Prove it, fix it, and the loop is complete end-to-end.
