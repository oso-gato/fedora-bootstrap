#!/usr/bin/env bash
# fedora-bootstrap — USER phase: the rootless layer.
#
# Run AS the unprivileged operating user (NOT root). Brings up the user's podman socket,
# authorizes SSH keys into the user's own ~/.ssh, builds the claudebox Distrobox, stamps
# the Claude policy, and verifies. It needs NO host privilege — the system layer was
# already provisioned as root by setup-host.sh. The only escalation here is INSIDE the
# box (the container's own root). See README "Privilege layers". Idempotent.
set -euo pipefail
[ "$(id -u)" != 0 ] || { echo "setup-user.sh is the ROOTLESS layer and must run as the unprivileged user, not root. Run setup.sh as root, or 'su - <user> -c .../setup-user.sh'." >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
PHASE() { printf '\n==== %s ====\n' "$*"; }

PHASE "user 1/4 rootless podman socket"
# The user manager + bus were brought up by the root phase (setup-host.sh); this just
# enables the per-user podman API socket the box drives via CONTAINER_HOST.
[ -S "$XDG_RUNTIME_DIR/bus" ] || { echo "FATAL: user D-Bus ($XDG_RUNTIME_DIR/bus) is not up — run the SYSTEM phase (setup.sh as root / setup-host.sh) first." >&2; exit 1; }
systemctl --user enable --now podman.socket

PHASE "user 2/4 ssh keys (from github.com/${GH_KEYS_USER:-oso-gato}.keys, tagged per device)"
# Writes THIS user's own ~/.ssh/authorized_keys (user layer; no host privilege). GitHub
# is the key registry — no keys in this repo. Re-running resyncs.
bash "$HERE/sync-authorized-keys.sh"

PHASE "user 3/4 claudebox (declarative assemble from distrobox.ini) + Claude policy"
cd "$HERE" && distrobox assemble create --file distrobox.ini
echo ">> first enter builds the box (dnf install claude-code from Anthropic + init hooks) — this can take a minute"
distrobox enter claudebox -- true   # triggers distrobox-init; fails loudly HERE, not mislabeled later
# Guard: the box's root maps to THIS user via keep-id (NOT real root), so the bridge + policy steps
# below can only read the repo at /run/host$HERE if the clone dir is traversable+readable by this
# user. Day-0 clones to /opt/fedora-bootstrap (root umask 022 -> world-traversable), which is fine; a
# 0700 clone dir would otherwise fail those steps with a cryptic Permission denied. Fail loudly here.
distrobox enter claudebox -- test -r "/run/host$HERE/claudebox-init.sh" || {
    echo "FATAL: claudebox cannot read this repo at /run/host$HERE — the clone dir is not readable by" \
         "$(id -un) (uid $(id -u)). Clone to /opt/fedora-bootstrap per Day-0, or make the path" \
         "traversable+readable by this user, then re-run setup.sh." >&2
    exit 1
}
# Wire the box's host bridges (CONTAINER_HOST -> host podman socket; systemctl/journalctl/loginctl/
# flatpak shims). Done here, NOT via distrobox.ini init_hooks: distrobox-create single-quote-wraps
# init_hooks and re-evals them on the host, so any quote in the hook escapes and runs as this
# unprivileged user (Permission denied on /etc, /usr/local/bin). The `sudo` is the CONTAINER's own
# root; we pass only a path + our numeric uid, so nothing crosses the boundary that could detonate.
distrobox enter claudebox -- sudo bash "/run/host$HERE/claudebox-init.sh" "$(id -u)"
# Stamp the enterprise policy into the box. The `sudo` here is the CONTAINER's root
# (distrobox grants it passwordless inside the box), NOT the host's root.
distrobox enter claudebox -- sudo mkdir -p /etc/claude-code
distrobox enter claudebox -- sudo cp "/run/host$HERE/policy/CLAUDE.md" /etc/claude-code/CLAUDE.md
distrobox enter claudebox -- sudo cp "/run/host$HERE/policy/managed-settings.json" /etc/claude-code/managed-settings.json
mkdir -p "$HOME/.local/bin"
printf '#!/usr/bin/env bash\nexec distrobox enter claudebox -- bash -lc '\''exec /usr/bin/claude "$@"'\'' bash "$@"\n' > "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"

PHASE "user 4/4 verify"
bash "$HERE/verify.sh"
