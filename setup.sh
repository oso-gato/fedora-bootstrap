#!/usr/bin/env bash
# fedora-bootstrap: point a fresh Fedora Cloud host here and run me.
# Idempotent — re-run safely after any failure. Run as your non-root user
# (wheel/sudo), NEVER as root. See README "Day 0" for the root-shell steps.
set -euo pipefail
[ "$(id -u)" != 0 ] || { echo "Run as your user, not root (see README Day 0)"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
PHASE() { printf '\n==== %s ====\n' "$*"; }

PHASE "1/8 host packages (Fedora repos + Tailscale's official repo)"
sudo dnf -y install dnf-plugins-core >/dev/null 2>&1 || true
sudo curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo \
    -o /etc/yum.repos.d/tailscale.repo
sudo dnf -y --setopt=install_weak_deps=False install \
    distrobox flatpak-session-helper podman tmux mosh openssh-server tailscale \
    cockpit cockpit-podman cockpit-files cockpit-storaged \
    cockpit-networkmanager cockpit-selinux

PHASE "2/8 host services"
sudo systemctl enable --now sshd cockpit.socket tailscaled
# enable-linger + XDG_RUNTIME_DIR BEFORE the --user call so `systemctl --user`
# works even when setup.sh runs via `su - core -c` on Day 0 (no logind session).
sudo loginctl enable-linger "$USER"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
systemctl --user enable --now podman.socket

PHASE "3/8 ssh access (keys from github.com/${GH_KEYS_USER:-oso-gato}.keys, tagged per device)"
# GitHub is the key registry — no keys live in this repo. Each key is tagged with
# environment="LOGIN_KEY=<device>" so every login is attributable. Re-running
# resyncs (add/revoke on GitHub, re-run setup.sh). See sync-authorized-keys.sh.
bash "$HERE/sync-authorized-keys.sh"
# Permit ONLY the LOGIN_KEY variable from authorized_keys (whitelist — never the
# unsafe blanket `yes`, which would also allow LD_PRELOAD et al.).
sudo tee /etc/ssh/sshd_config.d/20-login-key.conf >/dev/null <<'EOS'
# fedora-bootstrap: let authorized_keys carry environment="LOGIN_KEY=<device>",
# whitelisted to that single variable, so each session is tagged by the key that
# authenticated (used to name the per-device tmux session in phase 5).
PermitUserEnvironment LOGIN_KEY
EOS
sudo systemctl reload sshd 2>/dev/null || sudo systemctl restart sshd

PHASE "4/8 tailscale (host node + Tailscale SSH)"
if ! tailscale status >/dev/null 2>&1; then
    sudo tailscale up --ssh ${TS_AUTHKEY:+--auth-key="$TS_AUTHKEY"} || true
    echo ">> If a login.tailscale.com link printed above: open it once, then re-run setup.sh"
fi
# Cockpit: tailnet-only (Fedora Cloud has no firewall — never expose 9090 publicly)
sudo tailscale serve --bg --https=443 http://localhost:9090 2>/dev/null || true

PHASE "5/8 tmux on every remote login (per-device session named by LOGIN_KEY)"
sudo tee /etc/profile.d/zz-tmux-attach.sh >/dev/null <<'EOS'
# ssh/mosh logins attach to a tmux session named after the key that authenticated
# (LOGIN_KEY, from authorized_keys). Each device gets its own persistent session;
# all sessions share one server, so `tmux attach -t <other>` hops between them.
# Local/unkeyed logins fall back to the shared "main".
case $- in *i*) ;; *) return ;; esac
if [ -z "${TMUX:-}" ] && command -v tmux >/dev/null && { [ -n "${SSH_TTY:-}" ] || [ -t 0 ]; }; then
    exec tmux new-session -A -s "${LOGIN_KEY:-main}"
fi
EOS

PHASE "6/8 claudebox (declarative assemble from distrobox.ini)"
cd "$HERE" && distrobox assemble create --file distrobox.ini

PHASE "7/8 Claude Code policy (enterprise tier, inside the box)"
distrobox enter claudebox -- sudo mkdir -p /etc/claude-code
distrobox enter claudebox -- sudo cp "/run/host$HERE/policy/CLAUDE.md" /etc/claude-code/CLAUDE.md
distrobox enter claudebox -- sudo cp "/run/host$HERE/policy/managed-settings.json" /etc/claude-code/managed-settings.json
mkdir -p "$HOME/.local/bin"
printf '#!/usr/bin/env bash\nexec distrobox enter claudebox -- claude "$@"\n' > "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"

PHASE "8/8 verify"
bash "$HERE/verify.sh"
