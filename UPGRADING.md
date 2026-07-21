# Upgrade history

One line per release below (**v1.1.1 – current**; the latest releases also keep their full text in [README.md](README.md) while current). `setup.sh` is **idempotent across the entire version history** — a v1.0.0 host jumps straight to latest with the standard flow; the table exists for forensic reference, and a release keeps its **full procedure** (below the table) only where it shipped genuine version-specific operator steps or a safety correction. Release-doc rules: [CLAUDE.md](CLAUDE.md).

**The standard upgrade flow** (as root on the VPS — the same for every release):

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
```

> **From v1.2.67 on, this is rarely needed by hand.** v1.2.67 arms the **self-refresh absorber**
> (`host-code-refresh`), which fast-forwards the control clone to merged `main` and re-applies the host
> code every ~15 min — so merged host changes go live on their own. The upgrade above still works to force
> a version immediately, with one change: v1.2.67 makes `/opt/fedora-bootstrap` **`core`-owned** (the
> absorber runs as `core` and must write the clone), so after upgrading, a manual pull is
> **`sudo -u core git -C /opt/fedora-bootstrap pull --ff-only origin main`** (then `sudo ./setup.sh < /dev/null`)
> — a root `git pull` on the now-core-owned clone would trip git's dubious-ownership guard. The
> **first** upgrade to v1.2.67 still uses the plain root flow above (the clone is still root-owned when you
> pull; that setup.sh run does the chown). Check it's working: `cat ~core/.local/state/host-code-refresh/status`
> (a fresh `… OK …` line) or `systemctl --user -M core@ status host-code-refresh.timer`.

## Changelog

| Release | What changed | Beyond the standard flow |
|---|---|---|
| v1.1.1 | Workload-refresh harness, Quadlet deploy for `fedora-dev`, signature scaffolding, restructured agent policy | **full procedure below** (env file + container migration) |
| v1.1.2–v1.1.8 | Docs + agent-policy patches (README shape, release-doc convention, binding agent tables) | — |
| v1.1.9 | Runtime secrets eliminated (key-only sshd, keys synced from GitHub); env-file scaffolds retired | **full procedure below** |
| v1.1.10 | Tailscale phase fix (host 6/7) | — |
| v1.1.11 | Fleet-wide image-pull fix + two host-claudebox policy corrections | — |
| v1.1.12–v1.1.13 | Docs/comments; `container-refresh.sh` `.rolled-back` marker split | — |
| v1.1.14 | SELinux re-enabled (permissive) | — *(superseded by v1.2.0, then v1.2.49)* |
| v1.1.15 | `fail2ban-server` leaf install replaces metapackage; firewalld dropped | — *(superseded by v1.2.41 — fail2ban removed)* |
| v1.1.16–v1.1.17 | Docs only | — |
| v1.2.0 | Automated SELinux convergence to enforcing (multi-reboot chain) | — *(superseded by v1.2.49 — no-wait flip)* |
| v1.2.1–v1.2.5 | Policy/docs patches; small fix (v1.2.5) | — |
| v1.2.7–v1.2.13 | Agent-policy + docs (build principles, PR-first pathway, fleet governance) | — |
| v1.2.14–v1.2.15 | Day-0 asks for the Tailscale auth key; docs | — |
| v1.2.16 | Interactive Day-0 wizard `day0.sh` added | — (wizard is for a fresh Day-0 only) |
| v1.2.17–v1.2.18 | Docs; tmux multi-client geometry-garble fix | — |
| v1.2.19 | Control-plane policy.json refinement | **full procedure below** (⚠️ corrected in v1.2.21) |
| v1.2.20–v1.2.26 | auto-mode default, policy.json array fix (v1.2.21), validation tooling (rollback spike, live-gate params), ultracode default, disposable-build carve-out, host candidate-builder | — |
| v1.2.27–v1.2.31 | Live-gate transport (watcher, verdict comments, 15s poll), rebuild-timeout tweaks, tmux co-view | — |
| v1.2.33–v1.2.34 | Live-gate dynamic discovery + `.live-gate` contract; throwaway-sweep + bounded caches | — |
| v1.2.35 | claudebox-rebuild trust fix (quay.io base in policy.json) | **full procedure below** |
| v1.2.36 | Per-release git-tag mandate dropped (version-of-record is in-tree) | — |
| v1.2.37 | Ordering fix for v1.2.35; canonical policy.json rewrite | **full procedure below** |
| v1.2.38 | Rebuild-vs-watcher race fix ("built a box then failed") | **full procedure below** |
| v1.2.39–v1.2.40 | Docs | — |
| v1.2.41 | fail2ban removed (key-only doors) | — |
| v1.2.42 | Host SSH door goes all-keys (GitHub account = trust root) | — |
| v1.2.43 | `claude` wrapper retries the transient post-rebuild PTY race | — |
| v1.2.44 | SELinux enforce-gate no longer requires removed fail2ban (could pin hosts permissive) | **full procedure below** (marker clearing) |
| v1.2.45 | README restructured; per-version log relocated here | — |
| v1.2.46 | `setup.sh` executable bit restored (Day-0 `Permission denied` on fresh clones) | — |
| v1.2.47 | Less-is-more doc reduction: gospel DRY'd to single-source pointers; dangling pointers fixed | — |
| v1.2.48 | Live-gate fence de-theater: inert `--cap-add=` denylist arm dropped | — |
| v1.2.49 | SELinux convergence goes no-wait: fire-once flip, 2 reboots, no soak | **full procedure below** |
| v1.2.50 | Cache/UI knobs simplified (blunt dnf-cache cap, 60s live-gate poll, tmux toggle dropped) | — *(60s poll superseded by v1.2.55 — 10s)* |
| v1.2.51 | fastfetch installed on the host + login banner for every user | — |
| v1.2.52 | Release-doc de-ceremony: changelog-table convention; this file collapsed from 51 subsections | — |
| v1.2.53 | live-gate fix: dnf bind cache mounted `:z` — the v1.2.49 SELinux-enforcing convergence was RED-failing **every** gate build org-wide (EACCES in `/var/cache/libdnf5`; false negatives on fedora-dev#82/#107, fedora-desktop#101). `:z` also relabels the existing cache on first mount, so no manual heal. Re-gate affected PRs by pushing a new head SHA (per-SHA dedup) | — |
| v1.2.54 | live-gate: preset fences now NAME the podman default-cap closure (CHOWN/DAC_OVERRIDE/FOWNER/FSETID/KILL/NET_BIND_SERVICE/SETFCAP/SETGID/SETPCAP/SETUID/SYS_CHROOT) — the launch floor is `--cap-drop=ALL`, so the old 2-cap fences under-capped candidates vs their own run-contract and PID-1 died at first boot (`healthy FAIL(none)`, proven A/B in-box: <1s death → alive). Gate also drops the evidence-destroying `--rm` (EXIT trap already reaps) and posts candidate state + boot-log tail into the verdict on health-FAIL | — |
| v1.2.55 | live-gate pickup cadence 60s → 10s (`OnBootSec`/`OnUnitActiveSec=10s` **+ `AccuracySec=1s`** — without the accuracy override systemd's default 1-min window coalesces a sub-minute timer back to ~60s). Operator-requested loop latency cut, paired with the dev-side poller's matching 10s sweep (fedora-dev). Work is still bounded by flock + per-SHA `.done` dedup; ~360 label queries/h stays well inside API budgets | — |
| v1.2.56 | live-gate verdict header now carries the **FULL 40-hex head sha** (`… — <repo> @ <full-sha> (targets: …)`); short sha stays for tags/logs. Lockstep with fedora-dev's #96 merger hardening: dev-side consumers (auto-merge.sh, pr-poller.sh) bind verdicts to the full sha on the comment's first line — a 7-hex prefix is 28 bits and a ground commit-sha collision could inherit a stale GREEN. Until this release is applied on the host, the hardened consumers read host verdicts as NONE (fail-closed: NOOP/REFUSE, never a wrong merge) | — |
| v1.2.57 | **HOST AGENT** (`host-agent-watch.sh` + `.service`/`.timer`, 10s) — the host half of the autonomous apparatus (fedora-dev#131 R5). Consumes `host-task` GitHub-issue tickets from the **control repo** (`oso-gato/fedora-bootstrap`; `host-op: <verb>` on line 1), performs the requested **allowlisted** host op (v1 verb: `redeploy <workload>` → `workload-refresh@<workload>`, reporting DONE/DEFERRED/FAILED-rolled-back accurately), posts a `host-agent:` comment + closes the ticket. This is how the walled-off dev box gets host operations done. **No arbitrary-command verb by design**; workload arg must be in the known-workloads allowlist; host commands are scoped to the host's own repo (not org-wide). Decoupled `.acted`/`.done` markers ensure a delivery retry re-delivers but never re-redeploys. Standing-down mirrors the live-gate watcher during a box rebuild. The standard flow enables it on this host. **Prereq**: the host GitHub App needs **Issues: Read & Write** on `fedora-bootstrap` (it was the PR/verdict identity, Contents-read-only) | grant the host App Issues:write; standard upgrade (one-time host-agent activation via setup.sh) |
| v1.2.58 | **Host live-gate now gates NON-image repos.** fedora-bootstrap ships `Containerfile.livegate` + `.live-gate` (target `shellgate`): the host builds a DISPOSABLE candidate whose RUN steps ARE the gate — shellcheck + `bash -n` on every shipped `*.sh`, every `--selftest`, and the mock host-agent dry-run — and posts the same `Host live-gate (Gate B): VERDICT GREEN/RED` comment instead of the old neutral SKIPPED. Closes the SKIPPED-verdict hole that forced manual click-merges of bootstrap PRs; ZERO new host machinery (reuses `live-gate-run.sh`→`build-candidate.sh`→`validate-candidate.sh` verbatim). Part of P0 — apparatus PRs auto-merge zero-click via the org-wide poller. | — |
| v1.2.59 | **UNSHACKLE the host claudebox** (fleet parity with fedora-dev #137). `policy/managed-settings.json` is the BYTE-IDENTICAL fleet copy: no PreToolUse gate-push hook, `defaultMode` `auto`→`default` (the interactive agent runs its own commands without prompts), and a new hard `Bash(gh pr merge:*)` **deny** — the box stays PR-only structurally (require-PR ruleset + merge-verb deny) instead of via the retired text-scanning hook (which false-positived on words like "merged" in command text). `policy/hooks/` deleted; `setup-user.sh` now REMOVES any previously-stamped `/etc/claude-code/hooks` instead of stamping + FATAL-guarding it. Autonomous merges continue solely via the dev-side poller's two independent gates. | standard flow; then `claudebox-rebuild` (or the daily rebuild) re-stamps the box policy |
| v1.2.60 | **BOX-STABILITY: stop the watcher ticks from killing the claudebox.** Root cause (incident 2026-07-11, **41 box deaths / exit 143 in one afternoon**, each paired ±1s with a watcher-unit cgroup teardown): a container started by podman *from within a systemd unit* skips its own `libpod-conmon` scope (podman bails when `INVOCATION_ID` is set), so the box's `conmon` lands in the *starting* unit's cgroup — and the `live-gate-watch`/`host-agent-watch` oneshots (which auto-started the box via `distrobox enter`) then SIGTERM'd it on their own completion/timeout. Fix: a new **`claudebox-up.service`** owns the box (`env -u INVOCATION_ID podman start` → conmon gets an INDEPENDENT scope), both watchers `Wants=`/`After=` it (every tick first ensures the box is up + revives it if it died) and carry an `env -u INVOCATION_ID` belt on their own enter; `host-agent-watch` `TimeoutStartSec` cut 1800→300 (its ticks take seconds; 1800 turned any hang into a 30-min wedge). `box-rebuild.sh` stands the owner down for the rebuild window + re-arms it on exit. | standard flow (re-installs + enables the units + owner) |
| v1.2.61 | **BOX STARTUP DEFAULTS.** The `claude` wrapper now launches `/usr/bin/claude --model default --permission-mode auto --effort ultracode` (was `--model opus --settings '{"ultracode":true}'`). Three fleet-required defaults so every box starts ready at full capability with no per-session toggling, all session-scoped (survive rebuilds, no home-state dependency) and all overridable mid-session: **`--model default`** — the RECOMMENDED model, NOT a version pin; the `default` alias auto-follows new releases (Opus 4.8 today; every recommended tier stays ultracode-capable, so this also avoids the 2.1.195 regression where dropping `--model` fell to a non-ultracode Sonnet default). **`--permission-mode auto`** — auto mode, not manual (a fresh box was coming up "manual"; a launch flag makes it a build guarantee). **`--effort ultracode`** — the canonical ultracode flag, replacing the old settings-injection. Identical to fedora-dev's `bin/claude`. Compatible with the unshackle (auto mode does not re-add the removed gate-push prompts). | standard flow only — `setup.sh` rewrites the **host-side** wrapper `~/.local/bin/claude` (setup-user.sh), so the next `claude` invocation already carries the flags. **No box rebuild needed on the host.** (fedora-dev's copy is baked into the nox image and does need a workload redeploy.) |
| v1.2.62 | **conmon regression fix**: `claudebox-up.service` gains `RemainAfterExit=yes` and **drops `ExecStop`**. v1.2.60 shipped neither — a `Type=oneshot` unit without `RemainAfterExit` goes inactive the instant `ExecStart` returns, and systemd runs `ExecStop` on deactivation, so the unit **started then immediately stopped** the box on every ~10s watcher tick; a `claude` session died within 5s. Recovery of a dead box is the watchers' `env -u INVOCATION_ID … distrobox enter` (v1.2.60 belt), not this unit. Verified live on the host | — |
| v1.2.63 | **R17 `rebuild-devbox` host verb** (fedora-dev#174 host half): the host-agent's second verb — a *purposeful* dev-box lifecycle rebuild the dev box cannot do to itself (its orchestrator dies at KILL). Given a validated **session manifest** in the ticket body, it (1) **KILLs** the dev container from OUTSIDE — a host podman-level Quadlet restart reaps every process in its PID namespace, the ghost a shared-PID-ns in-container `distrobox rm -f` left behind on 2026-07-13; (2) **REBUILDs** via the new on-demand `workload-rebuild@` unit = `container-refresh.sh` under `FORCE_REBUILD` (**R10 health-gate + digest auto-rollback preserved**, not duplicated — it only overrides the busy-defer + digest short-circuit); (3) **verifies the kill BY CONTAINER ID** (never by name — the reused name is what hid the ghost); (4) **RESTOREs + RESUMEs** each manifest session (tmux at its cwd + the host-fixed resume cmd) and (5) **VERIFYs** the entrypoint-supervised poller is observably sweeping — reporting killed/restored/resumed/could-not (any unverified kill, unhealthy rebuild, idle session, or silent poller SURFACES as FAILED). Destructive → **author-gated** (issue author must hold admin\|maintain). Decoupled state machine (fire `--no-block`, poll across ticks) so a minutes-long rebuild never wedges the 300s host-agent tick. | standard flow (installs `workload-rebuild@.service`, updates `container-refresh.sh` + `host-agent-watch.sh`) |
| v1.2.64 | **R9 FLEET HALT reaches the host live-gate watcher** (fedora-dev#131/#135): `live-gate-watch.sh` — a timer-driven sweeper that BUILDS candidates and POSTS verdicts — now reads the fleet-wide maintainer SOFT STOP at the TOP of every tick (after the flock, before any sweep/discovery/build/post) and goes OBSERVE-ONLY while it stands, mirroring the dev-side `bin/fleet-halt.sh` contract via a new **`fleet-halt.sh`** reader. The signal is the `halt` label on the FLEET HALT CONTROL issue (`oso-gato/fedora-bootstrap` #128, discovered by title) — read from the label's OWN TIMELINE EVENTS so it is **MAINTAINER-BOUND BOTH DIRECTIONS** (an App/bot label add *or* removal is inert; a role check confirms admin\|maintain). **Fails closed toward stopping**: issue absent ⇒ CLEAR, but an unreadable read pauses the sweep and K consecutive unreadable reads declare a persistent halt; a missing reader parks the tick. Un-halt (a maintainer removing the label) resumes the loop next tick with no restart; an in-flight build completes untouched. `fleet-halt.sh --selftest` + `validation/fleet-halt-dryrun.test.sh` cover it. | standard flow (installs `fleet-halt.sh`, updates `live-gate-watch.sh`) |
| v1.2.65 | **rebuild-devbox RESUME-BY-ID** (fedora-dev D4/#191): the R17 session manifest gains an optional 4th field — a claude-code session-id (a UUID). When present, `host-agent-watch.sh` resumes THAT session with `claude --resume <sid>` instead of the cwd-scoped `claude --continue`, so a multi-tenant rebuild no longer collapses N sessions sharing one cwd (`/home/core`) to the most-recent one — every tenant returns by id. Backward-compatible: a 3-field v1 manifest still resumes with `--continue`. `parse_manifest` now accepts `session <name> <cwd> [<sid>]`; strict fixed-width UUID (8-4-4-4-12 hex) validation on the 4th field also re-closes the space-in-cwd hole (a fumbled cwd-with-a-space splits to a non-UUID 4th field ⇒ rejected). Covered by `--selftest` (parse rows) + `validation/rebuild-devbox-dryrun.test.sh` (behavioral: v1→`--continue`, v2→`--resume <sid>`). | — |
| v1.2.66 | **rebuild-devbox RESUME-TO-ACTIVE** (fedora-dev R17 option-b): a rebuilt box's restored sessions now come up **actively continuing**, not merely present. Two additions to `host-agent-watch.sh`: (1) a **BOX-READY gate** (`box_ready` — `.assembled` present, `.assemble-failed` absent, box enterable) re-checked ACROSS ticks (DEFER-until-ready, deadline-bounded → FAILED if it never assembles) so the launch never lands in a still-assembling box and falls back to a bare shell — **the 0/N-idle race that resumed 0/2 on the first real rebuild**; and (2) after restoring `claude --resume <sid>`, a host-fixed continue-**NUDGE** is submitted (literal text + a DISCRETE `send-keys Enter` — an inline return is swallowed by the TUI's bracketed paste) asking the session to `touch` a per-sid marker, which the executor polls as a **filesystem HANDSHAKE** confirming it received+submitted+executed. Honest three-way tally: handshake-confirmed = ACTIVELY CONTINUING; a claude that is UP but unconfirmed and a bare-shell IDLE are named distinctly, never claimed working. Empirically grounded (tmux + the real claude TUI): a positional `claude --resume <sid> "<prompt>"` only PRE-FILLS (never submits) and a live session's transcript does not flush in-tick, so neither is a usable liveness signal. Covered by `validation/rebuild-devbox-dryrun.test.sh` (box-ready defer/deadline, handshake-confirmed vs up-but-unconfirmed vs idle, + 3 in-suite mutations). | — |
| v1.2.67 | **host self-refresh ARMED** (R23 host half): the F16 absorber (`host-code-refresh`) that makes merged host code go live now actually **works** and is **visible**. It existed since v1.2.64 but was a permanent *silent* no-op on the running host — a `--user` process can't `git merge` a root-owned clone, so a human hand-copied every merged host change (incident 2026-07-17). Fixes: (1) **`setup-host.sh` chowns the control clone `core`-writable** — the one root bootstrap step it needed; the absorber becomes the sole pull mechanism; (2) **`setup-user.sh` primes it once** so the host is current the moment setup finishes; (3) **a per-tick HEARTBEAT** (`~core/.local/state/host-code-refresh/status`: `OK`/`BLOCKED`/`SKIPPED`/`FAILED` + reason) makes "is it self-refreshing, and if not why?" observable off-box; (4) **`verify.sh` asserts** the absorber timer is enabled, the clone is core-writable, and the last tick was not `BLOCKED`/`FAILED` — so a non-self-refreshing host is a **loud verify FAIL**, not silence. Covered by `validation/host-code-refresh.test.sh` (7 cases incl. not-writable→`BLOCKED` + a mutation proving the heartbeat carries the reason). | **clone becomes `core`-owned** — after upgrading, a manual `git pull` is `sudo -u core git -C /opt/fedora-bootstrap pull` (see the note under the standard flow). The **first** upgrade to v1.2.67 uses the plain root flow (that run does the chown). |
| v1.2.68 | **live-gate CAT-04 fix — a fetch blip no longer buries a live sha** (audit 2026-07-18; the likely kd#23 root cause): a transient PR-head **fetch failure** in `live-gate-run.sh` exited **3** (SKIPPED) having posted **no comment** — and `live-gate-watch.sh` **dedups rc 3** as a delivered skip, writing the per-`(repo,sha)` `.done` marker, so the sha was **buried forever** with nothing ever on the PR and the dev poller read `host=NONE` → NOOP indefinitely (the six-hour silent stall). The fetch-failure now exits **2** (infra non-verdict → the watcher **re-gates** next poll); rc 3 is reserved for a genuinely-**delivered** structural skip, honouring the watcher's dedup-only-delivered contract. Mutation-proven by `validation/live-gate-fetchfail.test.sh` (restore `exit 3` and the fetch-fail is deduped/buried). | — |
| v1.2.69 | **R17 APPROVAL GATE — one-tap mobile authorization for `rebuild-devbox`** (maintainer-confirmed 2026-07-19): the destructive verb now fires on EITHER a maintainer-AUTHORED ticket (the original path, unchanged) OR a maintainer-APPLIED **`approved` label** on a bot-filed ticket — so the APPARATUS can file the rebuild ticket (manifest and all) and the human authorizes with a single label tap in the GitHub mobile app. The approval is TIMELINE-BOUND, never presence-bound (the fleet-halt applier discipline): the label's own labeled/unlabeled events are walked newest-first and the first actor role-checked admin\|maintain decides — an App-applied label is INERT, a maintainer UN-label UN-approves, an unresolvable actor is fail-closed NOT-approved (`approval_fold`, pure + selftested). A bot-authored ticket with neither is **PENDING, not refused**: left open + unconsumed (no `.done`), ONE marker-gated `⏳ AWAITING APPROVAL` comment (@mention, `DEVBOX_APPROVER_MENTION`) posted, re-checked every ~10s tick — the tap can come any time. Covered by `--selftest` (`approval_fold` rows) + `validation/rebuild-devbox-dryrun.test.sh` (PENDING / one-ask / tap-fires / App-inert / un-label / mutation M4 neutralizing the gate). Also ships a `Containerfile.livegate` fix its own gate run surfaced: selftest detection now matches an actual handler (`= "--selftest"` comparison / `--selftest)` case-arm), not any substring mention — this release's setup.sh header line merely *mentioning* the flag had made the shellgate execute `setup.sh` for real inside the disposable build (RED at `hostnamectl`). | — |
| v1.2.73 | **fleet parity — the anti-stall `Stop` hook** is added to `policy/managed-settings.json` so it is byte-identical to the fedora-dev anchor. `anti-stall-stop.sh`'s `Stop` hook was added to fedora-dev's managed-settings but never propagated here, so `bin/fleet-guard-parity.sh` flagged the drift (`fedora-bootstrap managed-settings.json DIFFERS from fedora-dev`) on every fedora-dev PR. Pure guard-payload alignment — the hook fails open (`[ -x "$H" ] && exec … ; exit 0`), a no-op where the script is absent. (Sequences after v1.2.72 / #221.) | — |
| v1.2.71 | **rebuild-devbox RESUME made real, end-to-end** — a rebuild whose sessions the last four rounds thought were *lost* were actually **live but invisible + falsely reported FAILED**; six fixes to `host-agent-watch.sh` close that. **G1 (the reported incident):** the poller-sweeping VERIFY probed `systemctl --user is-active`/`journalctl --user`, but the dev box has **no systemd** (PID 1 is a bash init; the poller is an entrypoint-supervised background loop, never a unit) — the probe could **never** succeed, so **every** rebuild read `poller=down` regardless of reality; it now asserts the poller's base-visible **HEARTBEAT** (`~/.local/state/pr-poller/poller.log` mtime FRESH). **G2/G3:** restored sessions were standalone `tmux new-session -s <name>` sessions **outside the `main` group** every mosh/ssh login joins — alive + handshake-confirmed yet the user moshed into a bare shell and re-resumed → **duplicates**; each tenant is now a **named WINDOW in `main`** (visible to the login; N tenants stay distinct because a group shares one window set but N windows do not), selected current so the login lands **on** it. **G4:** the verdict fused poller-liveness with session-restore, so a perfect 2/2 restore read **FAILED** on `poller=down` and routed the maintainer to a **destructive re-rebuild** of a healthy box; now **multi-dimensional** — DONE on `ok==total`, poller-down ⇒ **DEGRADED** (restart the poller, do NOT re-rebuild), FAILED only when sessions did not restore. **G5:** `restore_session` is **idempotent** — a re-entered tick leaves a live session alone, never kill+recreate. **G6:** the box-ready **deadline** timed from `.rebuild` (stamped at FIRE) charged the whole health-gated rebuild against the assemble budget → premature FAILED; now from `.assembling` (stamped at rebuild-COMPLETE). **G8:** the re-nudge slice is floored at 40 s so a received nudge confirms before a second is sent. `validation/rebuild-devbox-dryrun.test.sh` = **26/26** incl. the new DONE+DEGRADED case + 4 mutations. | — |
| v1.2.70 | **rebuild-devbox self-captures the session manifest from the LIVE dev box** — the R17 arm now works end-to-end. The dev-side in-box producer CANNOT enumerate all sessions (a claudebox-nested shell reads only its OWN `/proc` lineage; a base-level filer has no `gh`), so `fedora-dev`'s poller refused to file a complete manifest and no rebuild ticket could carry one. `host-agent-watch.sh`'s `do_rebuild_devbox` now captures the manifest ITSELF, FRESH, moments before the kill: `pexec` (`podman exec --user 1000` = core at the fedora-dev BASE level) reads EVERY session's `/proc`, and the host already has `gh` — the two capabilities that cannot coexist inside the box DO coexist on the host (it orchestrates from outside). A rebuild ticket may now arrive BARE (`host-op: rebuild-devbox fedora-dev`, no manifest) and the host fills it; a ticket-carried manifest is a fallback only, and the live read is PREFERRED (freshest snapshot, moments before the kill). Fail-safe kept: zero sessions (live read + ticket both empty) ⇒ REFUSED, box never killed. Covered by `validation/rebuild-devbox-dryrun.test.sh` (host-self-capture fires with the live manifest, freshness prefers live over the ticket, zero-session refuse). | — |

## Retained full procedures

#### Upgrading to v1.1.1 (from v1.0.0)

Adds the workload-container refresh harness, Quadlet-based deployment for `fedora-dev`, image-signature scaffolding, the restructured agent policy. The pre-v1.1.1 fedora-dev was started via raw `podman run` from `run.sh`; v1.1.1 replaces that with a Quadlet-generated `fedora-dev.service`. Named volumes (`fedora-dev-home`, `fedora-dev-state`) persist by name, so all in-volume state — Claude credentials, gh auth, in-flight projects, nested podman storage — carries over automatically.

**Both v1.0.0 and v1.1.0 starting points are supported by the same upgrade block.** `setup.sh` is fully idempotent:

- **From v1.0.0** → installs the v1.1.0 deltas (claudebox 3-way rebuild mechanism + host dnf-automatic + Anthropic `latest`-channel switch) AND the v1.1.1 deltas (workload-refresh harness + signature scaffolding + restructured policy) in a single setup.sh re-run.
- **From v1.1.0** → re-stamps existing claudebox-rebuild state (idempotent no-op) and installs only the v1.1.1 delta.

The version-specific operator steps below (env file population, container switch) are identical for both starting points.

**As root on the VPS:**

```sh
# 1. Standard upgrade flow — picks up v1.1.1 code + new user 4/5 phase
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null

# 2. Populate the new env-file scaffold for fedora-dev's runtime secrets.
nano /home/core/.config/container-refresh/fedora-dev.env

# 3. Stop the pre-Quadlet fedora-dev container and start the Quadlet'd one.
su - core -c '
    podman stop fedora-dev 2>/dev/null || true
    podman rm   fedora-dev 2>/dev/null || true
    systemctl --user daemon-reload
    systemctl --user enable --now fedora-dev.service
'

# 4. Verify
su - core -c '
    systemctl --user status fedora-dev.service --no-pager | head -20
    systemctl --user list-timers "workload-refresh@*" --no-pager
    podman ps --filter name=fedora-dev
'
```

Expected after step 4: `fedora-dev.service` shows `active (running)`, healthcheck transitions to healthy within ~30s, two `workload-refresh@fedora-dev` timers visible. `podman ps` shows fedora-dev as `Up` and `(healthy)`.

If anything fails, the old container can be brought back manually:

```sh
su - core -c '
    systemctl --user stop fedora-dev.service 2>/dev/null || true
    cd ~/fedora-dev && CORE_PASSWORD=... ./run.sh
'
```

#### Upgrading to v1.1.9 (from v1.0.0)

> **⚠️ Corrected in v1.1.16:** the manual rollback recipe (b) below references `~/.local/state/container-refresh/<name>.prev-digest`, a file the refresh harness **never writes** (the prior image digest is held only in-memory during a refresh). Use the working procedure in README's "Upgrading to v1.1.16" instead — rely on the automatic health-failure rollback, or pin a known-good digest by hand.

Two code changes, applied in lockstep with [`fedora-dev` v1.1.9](https://github.com/oso-gato/fedora-dev) for fleet-wide consistency:

- **Host gains `fail2ban`** with an `sshd` jail (`backend = auto` so it reads from `journald`; tailnet CGNAT `100.64.0.0/10` is `ignoreip`'d). The host's public sshd on :22 now has the same brute-force posture as fedora-dev's new public sshd on host :4444.
- **Bootstrap drops the env-file scaffold** for `fedora-dev`. Upstream `fedora-dev` v1.1.9 eliminates `CORE_PASSWORD` entirely (sshd is key-only; authorized_keys synced from `github.com/<user>.keys` at every container start) and adds public-IP paths: ssh on host `:4444` → container `:22`, mosh on UDP `61001-62000` (non-default range, chosen to NOT collide with the host's own public mosh-server which uses 60000-61000 on the same kernel UDP namespace). The Quadlet drops `EnvironmentFile=`; `~/.config/container-refresh/fedora-dev.env` becomes unused.

**Assumptions about the starting state:**
- Hosts at **v1.0.0 / v1.1.0** are running `fedora-dev` from raw `podman run` (pre-Quadlet). The block below stops it and starts the v1.1.9 Quadlet, exactly as v1.1.1 did. No CORE_PASSWORD is needed at any step.
- Hosts at **v1.1.1 through v1.1.8** already have `fedora-dev.service` running with the old env-file Quadlet. The block detects that path and does `daemon-reload` + `restart` instead — `Pull=newer` fetches the v1.1.9 image and the new Quadlet (no `EnvironmentFile=`) takes effect on restart.

`fedora-dev:latest` on GHCR must already point to the v1.1.9 manifest before you run this block (CI on `oso-gato/fedora-dev` builds + cosigns on push to main; check with `podman manifest inspect ghcr.io/oso-gato/fedora-dev:latest | jq .config.digest` against the v1.1.9 tag commit's CI run).

**As root on the VPS:**

```sh
# 1. Standard upgrade flow — installs all deltas (workload-refresh harness if
#    coming from pre-v1.1.1, fail2ban+jail in v1.1.9, env-scaffold drop in v1.1.9).
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null

# 2. Re-apply the fedora-dev workload — pulls v1.1.9 image, applies new Quadlet.
#    Branches by starting state: if the .service exists, daemon-reload + restart;
#    otherwise stop-and-recreate the pre-Quadlet container (v1.0.0/v1.1.0 path).
su - core -c '
    if systemctl --user is-enabled fedora-dev.service >/dev/null 2>&1; then
        # v1.1.1+ path: in-place Quadlet refresh.
        systemctl --user daemon-reload
        systemctl --user restart fedora-dev.service
    else
        # v1.0.0/v1.1.0 path: retire pre-Quadlet container, enable Quadlet'\''d one.
        podman stop fedora-dev 2>/dev/null || true
        podman rm   fedora-dev 2>/dev/null || true
        systemctl --user daemon-reload
        systemctl --user enable --now fedora-dev.service
    fi
'

# 3. (Optional cleanup) Remove the now-unused env-file scaffold from prior versions.
#    Harmless to leave in place — the v1.1.9 Quadlet has no EnvironmentFile= so the
#    file is no longer read by anything.
rm -f /home/core/.config/container-refresh/fedora-dev.env

# 4. Verify host fail2ban + fedora-dev health.
fail2ban-client status sshd | head -10
su - core -c '
    systemctl --user status fedora-dev.service --no-pager | head -20
    podman ps --filter name=fedora-dev
'
```

Expected after step 4: `fail2ban-client status sshd` shows `Currently banned: 0` (or some number) and `File list: /var/log/secure` (or the systemd-journal source) — the jail is active. `fedora-dev.service` shows `active (running)`, healthcheck `(healthy)` within ~30s on the new image.

Functional probe each access path:

```sh
# From a client on the public internet (NOT the tailnet) — confirms public surface
# survived the upgrade and uses the NEW ports:
ssh -p 4444 core@<public-ip>                                  # key-only; one of github.com/<user>.keys
mosh -p 61001:62000 --ssh='ssh -p 4444' core@<public-ip>     # public mosh range

# From a tailnet device — confirms keyless Tailscale SSH still works:
ssh core@<vps>.<tailnet>.ts.net
```

**Rollback** if v1.1.9 misbehaves (e.g., fedora-dev fails to come up healthy on the new image):

```sh
# (a) Revert /opt/fedora-bootstrap to v1.1.8 — drops fail2ban config + restores
#     the env-file scaffold path.
cd /opt/fedora-bootstrap
git checkout v1.1.8
./setup.sh < /dev/null

# (b) Roll fedora-dev back to the prior image digest. workload-refresh.service
#     records the prior digest in /home/core/.local/state/container-refresh/
#     <name>.prev-digest; the auto-rollback path on health-failure already uses
#     it, but you can also pin manually:
su - core -c '
    prev=$(cat ~/.local/state/container-refresh/fedora-dev.prev-digest 2>/dev/null)
    [ -n "$prev" ] && podman tag "$prev" ghcr.io/oso-gato/fedora-dev:latest
    systemctl --user daemon-reload
    systemctl --user restart fedora-dev.service
'
# (If no prev-digest is recorded — first deploy at v1.1.9 — you can pull a
# specific older tag with `podman pull ghcr.io/oso-gato/fedora-dev:<sha>`
# and `podman tag` it as :latest.)
```

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

#### Upgrading to v1.2.35 (from v1.0.0)

Fix — **`claudebox-rebuild` failed on the host with `Source image docker://quay.io/fedora/fedora-toolbox:44 is rejected by policy` (exit 125) after the first build.** No host package, system service, or deploy-path change. The image-trust `policy.json` (default `reject`) trusted `ghcr.io/oso-gato` + `registry.fedoraproject.org/fedora` + `containers-storage`, but **not** `quay.io/fedora/fedora-toolbox` — the claudebox base pinned in `distrobox.ini`, which distrobox **re-pulls on every rebuild**. The *first* day-zero build worked because the claudebox assemble in `setup-user.sh` **phase 3** runs **before** the policy is written in **phase 4** (so it pulls under the permissive default and caches the toolbox); every later rebuild re-pulls under the now-restrictive policy and is rejected — which is exactly why "the first build always works, subsequent updates fail." `setup-user.sh` now trusts the toolbox base in **both** writers (the create-heredoc for fresh hosts **and** the idempotent merge), so re-running `setup.sh` **repairs an already-deployed host in place**.

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null        # adds quay.io/fedora/fedora-toolbox to policy.json (repairs in place)
claudebox-rebuild             # now succeeds
```

**Immediate unblock without re-running `setup.sh`** (adds just the one scope to the live policy, then rebuilds):

```sh
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.config/containers/policy.json")
d = json.load(open(p)); t = d.setdefault("transports", {}).setdefault("docker", {})
t.setdefault("quay.io/fedora/fedora-toolbox", [{"type": "insecureAcceptAnything"}])
json.dump(d, open(p, "w"), indent=4)
print("trusted quay.io/fedora/fedora-toolbox")
PY
claudebox-rebuild
```

**Verify**: `claudebox-rebuild` completes, and `podman pull quay.io/fedora/fedora-toolbox:44` succeeds. `fedora-dev` and `fedora-desktop` are **unaffected** — their claudeboxes run no restrictive `policy.json` (permissive default), so their rebuilds were never rejected.

**Rollback** — config only; `git checkout` the prior commit and re-run `setup.sh`. (Removing the scope re-breaks subsequent rebuilds, so only roll back with that understanding.)

#### Upgrading to v1.2.37 (from v1.0.0)

Fix for an ordering bug in the v1.2.35 claudebox-trust fix. `setup-user.sh` wrote/repaired the image-trust `policy.json` in **`user 4/5`** but assembled the claudebox in **`user 3/5`** — so on an already-deployed host whose restrictive policy still lacks the toolbox scope, the `user 3/5` assemble's `quay.io/fedora/fedora-toolbox` pull is **rejected before** `user 4/5` can add it, and a plain `setup.sh` re-run fails every time at `user 3/5`. A small **idempotent guard** now trusts the toolbox base in the live `policy.json` **before** the assemble (a no-op on a fresh host with no policy yet, and when the scope is already present). v1.2.35 fixed *fresh* day-zero hosts; this fixes the *re-run-on-an-already-deployed-host* path.

If your host is currently stuck at `user 3/5 … rejected by policy`, do the one-time repair + upgrade (as **root**, in `/opt/fedora-bootstrap`):

```sh
sudo -u core tee /home/core/.config/containers/policy.json >/dev/null <<'EOF'
{
    "default": [{ "type": "reject" }],
    "transports": {
        "docker": {
            "ghcr.io/oso-gato": [{ "type": "insecureAcceptAnything" }],
            "registry.fedoraproject.org/fedora": [{ "type": "insecureAcceptAnything" }],
            "quay.io/fedora/fedora-toolbox": [{ "type": "insecureAcceptAnything" }],
            "": [{ "type": "reject" }]
        },
        "containers-storage": { "": [{ "type": "insecureAcceptAnything" }] }
    }
}
EOF
git pull --ff-only origin main && ./setup.sh < /dev/null
```

Once v1.2.37 is applied, a plain `git pull --ff-only origin main && ./setup.sh < /dev/null` self-heals — no manual policy step needed ever again.

**Validation honesty:** this fix is `bash -n`-clean and its guard logic is simulation-checked, but it has **not** been run end-to-end on a live host — a real `setup.sh` re-run on a deployed host is the only true proof.

**Rollback** — `git checkout` the prior commit + re-run `setup.sh` (the guard is additive; removing it restores the ordering bug).

#### Upgrading to v1.2.38 (from v1.0.0)

Fix for the **update mechanism**: every auto-update / `claudebox-rebuild` "built a box then failed", while day-zero succeeded. It is a **concurrency race**, not a build defect — the v1.2.29 **15 s live-gate watcher** fires `distrobox enter claudebox` throughout a rebuild and races `setup-user.sh`'s own first-enter (which runs `distrobox-init` = the `dnf install`); two `distrobox enter` then drive `distrobox-init` concurrently in the same fresh box and either **collide on the pre-init hooks** (init errors) or **deadlock on distrobox's name-keyed fifo** (init hangs), with the v1.2.30 **480 s timeout** turning the hang into a hard kill. Day-zero is immune because the watcher's timer is enabled only *after* the box build. The fix (1) stands the watcher down for the rebuild window in `box-rebuild.sh` (trap-protected re-arm), (2) adds an `ExecCondition` to `live-gate-watch.service` that skips while a rebuild is active, (3) makes `setup-user.sh`'s first-enter an authoritative readiness check, and (4) raises the rebuild-service `TimeoutStartSec` 480 → 1800 s. **Applying is safe on the broken host** — a plain `setup.sh` re-run does **not** remove the box (so it doesn't trigger the race); it only re-stamps the fixed `box-rebuild.sh`, units, and timeout. Apply as **root** in `/opt/fedora-bootstrap`:

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null    # re-stamps box-rebuild.sh + the live-gate ExecCondition + the 1800s rebuild timeout
```

**Verify** the units carry the fix (the `ExecCondition` line and a 30-min timeout), then prove a rebuild now succeeds — run the rebuild **as `core`** (it tears down + recreates the box, then reconnect with `claude`):

```sh
systemctl --user --machine=core@.host cat live-gate-watch.service | grep -i ExecCondition
systemctl --user --machine=core@.host show claudebox-rebuild-run.service -p TimeoutStartUSec   # → 30min
sudo -iu core claudebox-rebuild    # completes "claudebox rebuild COMPLETE"; then `claude` to reconnect
```

Expected: the `ExecCondition=… ! systemctl --user is-active … claudebox-rebuild-run.service` line is present, `TimeoutStartUSec=30min`, and `claudebox-rebuild` finishes green where it previously "built then failed".

**Rollback** — `git checkout` the prior commit + re-run `setup.sh` (this restores the racing behaviour, so only roll back with that understanding).

#### Upgrading to v1.2.44 (from v1.0.0)

Host-only **security fix** — the SELinux enforce-gate no longer requires the removed `fail2ban.service`. In v1.2.41 fail2ban was dropped (key-only door), but `selinux-autoenforce.sh`'s critical-services health gate still listed `fail2ban.service`, so the gate could never PASS: a fresh host stayed **permissive** and an already-enforcing host **auto-reverted** to permissive. This drops `fail2ban.service` from that list so the convergence to **enforcing** can complete. A host pinned permissive by this bug carries a `selinux-chain.rolled-back` or `selinux-chain.aborted` marker — the standard flow re-stamps the fixed script; clear the marker to re-arm the now-fixed convergence.

**As root on the VPS:**

```sh
# Standard upgrade flow — re-stamps the corrected selinux-autoenforce.sh + units.
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null

# ONLY if this bug pinned the host permissive (a marker exists): clear it + re-arm.
ls /var/lib/fedora-bootstrap/selinux-chain.rolled-back \
   /var/lib/fedora-bootstrap/selinux-chain.aborted 2>/dev/null \
  && rm -f /var/lib/fedora-bootstrap/selinux-chain.rolled-back \
           /var/lib/fedora-bootstrap/selinux-chain.aborted \
  && ./setup.sh < /dev/null   # re-arms the convergence (reboots into the soak → enforce)
```

Expected: `cat /opt/fedora-bootstrap/VERSION` → `1.2.44`; once a healthy enforcing boot is confirmed, `getenforce` → `Enforcing` and `/var/lib/fedora-bootstrap/selinux-chain.enforced` exists. A host already healthily enforcing is unaffected (no-op). **Rollback** — `git checkout <prior-commit> && ./setup.sh < /dev/null`; to stay permissive deliberately, `SELINUX_TARGET=permissive ./setup.sh`.

#### Upgrading to v1.2.49 (from v1.0.0)

**SELinux convergence — no-wait.** The multi-reboot enforce chain (a 15-min soak, an AVC acceptance gate, a post-enforce health check, an auto-revert, four `selinux-*` units + the 176-line `selinux-autoenforce.sh` driver + `selinux-chain.*` markers) is replaced by a **fire-once** flip: from a disabled host, `setup-host.sh` sets `SELINUX=permissive` + `/.autorelabel`; the Day-0 `passwd core && reboot` relabels **in permissive** (brick-safe), auto-reboots, and `selinux-enforce-once.service` then flips to enforcing **live** on the now-labeled boot and self-disarms — **2 reboots, no waiting**, enforcing without a 3rd reboot. Enforcing stays the target; the soak/health-check/auto-revert insurance is dropped by design (a data-less VPS just re-provisions if enforcing ever wedges). `SELINUX_TARGET=permissive` opt-out unchanged. **Converges an existing host:** re-running `setup.sh` tears down the old chain (disables + removes the four units, the driver, and the `selinux-chain.*` markers) and re-arms the fire-once flip.

**As root on the VPS:**

```sh
cd /opt/fedora-bootstrap
git pull --ff-only origin main
./setup.sh < /dev/null
```

Expected: `cat /opt/fedora-bootstrap/VERSION` → `1.2.49`. On a fresh disabled host, the Day-0 reboot converges to enforcing in **2 reboots**; confirm with `getenforce` → `Enforcing` once the second boot settles. An already-enforcing host is a no-op; an already-permissive-labeled host flips to enforcing live with no reboot. **Rollback** — `git checkout <prior-commit> && ./setup.sh < /dev/null` (restores the multi-reboot chain); to stay permissive, `SELINUX_TARGET=permissive ./setup.sh`.
