# fedora-bootstrap — instructions for Claude Code

BEFORE ANY CHANGE: read README.md. The "Build Principles" and "Packages"
tables are BINDING. policy/CLAUDE.md + policy/managed-settings.json are the
law stamped into claudebox — editing them here is the ONLY way they change.
Host immutability is the core doctrine: this repo's host package list is
the complete sanctioned host footprint; never grow it without an explicit
user waiver recorded in the Packages table.

Pipeline context: images are developed in debian-dev/fedora-dev containers,
CI-built on GitHub, GHCR-published; claudebox (this repo's product) only
pulls and operates them on the host.
