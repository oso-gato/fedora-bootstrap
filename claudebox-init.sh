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

# systemctl/journalctl/loginctl (systemd) and flatpak have no meaning inside the box; shim them out
# to the host via distrobox-host-exec so the agent manages the real host services.
for c in systemctl journalctl loginctl flatpak; do
    ln -sf /usr/bin/distrobox-host-exec "/usr/local/bin/$c"
done

echo "claudebox bridges: CONTAINER_HOST -> host uid ${host_uid}; shims systemctl/journalctl/loginctl/flatpak."
