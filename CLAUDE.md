# fedora-bootstrap — agent rules for editing this repo

## BEFORE ANY CHANGE

Read README.md. The "Build Principles" and "Packages" tables are BINDING.
policy/CLAUDE.md + policy/managed-settings.json + policy/sudoers.claudebox are
the law stamped into the host claudebox — editing them in THIS repo is the
ONLY way they change.

Host immutability is the core doctrine: README.md's host package list is the
complete sanctioned host footprint. Never grow it without an explicit user
waiver recorded in the Packages table.

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
- `"Upgrading to vX.Y.Z (from any prior version)"` — default
- `"Upgrading to vX.Y.Z (from vA.B.C and later)"` — only for BREAKING
  releases that require a minimum prior version (name the minimum)

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

## README "UPGRADING" INTRO SHAPE

The intro under the top-level "Upgrading an existing host to a new release"
heading is two-or-three lines max, human-facing, structurally:

- Tells the reader each release has a subsection below
- Tells the reader to find their target version and paste its single code
  block
- Cross-references THIS FILE for the rules

Nothing else goes between the top-level heading and the first per-version
subsection.
