# fedora-bootstrap — instructions for Claude Code

BEFORE ANY CHANGE: read README.md. The "Build Principles" and "Packages"
tables are BINDING. policy/CLAUDE.md + policy/managed-settings.json are the
law stamped into claudebox — editing them here is the ONLY way they change.
Host immutability is the core doctrine: this repo's host package list is
the complete sanctioned host footprint; never grow it without an explicit
user waiver recorded in the Packages table.

The managed-settings.json deny list is best-effort defense-in-depth only:
per Claude Code docs, argument-shaped Bash deny rules are prefix-fragile
(dnf5, /usr/bin/dnf, host-spawn, arg reordering all evade them). The
AUTHORITATIVE host-immutability gate is the password-gated sudo + the
scoped allowlist in policy/sudoers.claudebox. Never weaken sudoers on the
assumption the deny list is the boundary — it is not.

Pipeline context: images are developed in debian-dev/fedora-dev containers,
CI-built on GitHub, GHCR-published; claudebox (this repo's product) only
pulls and operates them on the host.
