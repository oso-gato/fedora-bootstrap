#!/usr/bin/env bash
# fedora-bootstrap — claudebox host bridges, run as the BOX's own root.
#
# Invoked by setup-user.sh, post-assemble, as:
#     distrobox enter claudebox -- sudo bash /run/host<repo>/claudebox-init.sh <host-uid>
#
# WHY this is a script and not a distrobox.ini init_hook: distrobox-create embeds init_hooks as
# `-- '<hook>'` (single-quoted) and re-`eval`s the whole create command ON THE HOST, so any quote
# in the hook breaks out of that wrapper and the body runs as the unprivileged HOST user
# (Permission denied writing /etc, /usr/local/bin). distrobox-assemble has the mirror-image trap
# for double quotes. Driving the bridges from here — over the same proven `distrobox enter -- sudo`
# channel that stamps the Claude policy — sends only a path + a numeric uid across the boundary, so
# there is nothing left to detonate. Idempotent: re-running just rewrites the file and the symlinks.
set -euo pipefail
host_uid="${1:?usage: claudebox-init.sh <host-uid>}"
# Defend the one value that reaches a path: it must be the host operator's numeric uid, nothing else.
case "$host_uid" in (''|*[!0-9]*) echo "claudebox-init.sh: host-uid must be numeric, got '$host_uid'" >&2; exit 1 ;; esac

# podman inside the box drives the HOST's rootless engine through its API socket, which distrobox
# bind-mounts at /run/user/<host_uid>/podman/podman.sock. Export it for every login shell.
printf 'export CONTAINER_HOST=unix:///run/user/%s/podman/podman.sock\n' "$host_uid" \
    > /etc/profile.d/10-host-podman.sh
chmod 0644 /etc/profile.d/10-host-podman.sh

# In-box `claudebox-rebuild`: how Claude (or anyone in the box) asks the HOST to destroy+recreate
# this box. The in-box agent has no host systemd access — its ONLY channel is a flag file in the
# shared HOME, which the host's claudebox-rebuild.path watches across the bind mount. Writing the
# flag ends THIS session shortly (the host tears the box down) and rebuilds with latest Claude Code.
cat > /usr/local/bin/claudebox-rebuild <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.local/state/claudebox"
: > "$HOME/.local/state/claudebox/rebuild.request"
echo "⟳ claudebox rebuild requested. This session will end shortly and the box will rebuild in the"
echo "  background (~2-5 min: fresh image + latest Claude Code). Reconnect with: claude"
EOF
chmod 0755 /usr/local/bin/claudebox-rebuild

# NOTE: deliberately NO systemctl/journalctl/loginctl/flatpak host-exec shims. They route through
# host-spawn, which calls org.freedesktop.Flatpak.Development.HostCommand on the session bus — a method
# only flatpak-session-helper provides, and its unit is PartOf=graphical-session.target, which never
# starts on a headless, linger-only server. So those shims never functioned here. And by policy the host
# is immutable: the agent drives host containers via CONTAINER_HOST (above), not host systemd, and real
# host changes go through propose-and-commit (a human re-runs setup.sh as root). CONTAINER_HOST is the
# one host bridge, and it is socket-based (not host-spawn), so it works headless.

echo "claudebox bridge: CONTAINER_HOST -> host rootless podman socket (uid ${host_uid})."
