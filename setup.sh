#!/usr/bin/env bash
# fedora-bootstrap: point a fresh Fedora Cloud host here and run me.
# Idempotent — re-run safely after any failure. Run as your non-root user
# (wheel/sudo), NEVER as root. See README "Day 0" for the root-shell steps.
set -euo pipefail
[ "$(id -u)" != 0 ] || { echo "Run as your user, not root (see README Day 0)"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
PHASE() { printf '\n==== %s ====\n' "$*"; }

PHASE "1/8 host packages (Fedora repos + Tailscale's official repo)"
tmp=$(mktemp)
if sudo curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo -o "$tmp" \
   && grep -q '^\[tailscale-stable\]' "$tmp"; then
    sudo install -m 0644 "$tmp" /etc/yum.repos.d/tailscale.repo
elif [ ! -s /etc/yum.repos.d/tailscale.repo ]; then
    rm -f "$tmp"; echo "ERROR: could not fetch tailscale.repo and no existing copy present" >&2; exit 1
else
    echo ">> tailscale.repo fetch failed; keeping existing repo file" >&2
fi
rm -f "$tmp"
sudo dnf -y --setopt=install_weak_deps=False install \
    distrobox flatpak-session-helper podman tmux mosh openssh-server tailscale \
    cockpit cockpit-podman cockpit-files cockpit-storaged \
    cockpit-networkmanager cockpit-selinux

PHASE "2/8 host services"
sudo systemctl enable --now sshd cockpit.socket tailscaled
# Bring up THIS user's systemd manager + D-Bus user bus BEFORE any `systemctl --user`
# call. On Day 0, setup.sh runs via `su - core -c`, which has NO logind session, so the
# user bus (/run/user/<uid>/bus) doesn't exist yet. enable-linger starts
# user@<uid>.service, but ASYNCHRONOUSLY — so start it explicitly (this blocks until the
# unit is active) and then wait for the bus socket to appear before using it. Without
# this, `systemctl --user` dies with "Failed to connect to user scope bus" and -e aborts
# the whole bootstrap at Phase 2 (the original maiden-run failure on Fedora Cloud 44).
sudo loginctl enable-linger "$USER"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
sudo systemctl start "user@$(id -u).service"
for _ in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/bus" ] && break; sleep 0.1; done
[ -S "$XDG_RUNTIME_DIR/bus" ] || { echo "FATAL: user D-Bus ($XDG_RUNTIME_DIR/bus) never came up; cannot run 'systemctl --user'. Re-run setup.sh, or log in as core interactively once." >&2; exit 1; }
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
    if [ -n "${TS_AUTHKEY:-}" ]; then
        sudo tailscale up --ssh --auth-key="$TS_AUTHKEY"            # unattended join
    else
        echo ">> Tailscale needs browser auth. A https://login.tailscale.com/... link will"
        echo ">> print on the NEXT line. Open it now and approve this node."
        echo ">> (Or re-run with TS_AUTHKEY=tskey-... for an unattended join.)"
        # --timeout bounds the wait for tailscaled to reach RUNNING; on a fresh host the
        # node stays in NeedsLogin until you click the link, so this caps the auth hang.
        # If you don't finish in time, `up` exits non-zero, `|| true` absorbs it, and the
        # script proceeds; a re-run then no-ops (status-gated).
        sudo tailscale up --ssh --timeout=5m || true
    fi
fi
# Cockpit: tailnet-only (Fedora Cloud has no firewall — never expose 9090 publicly).
# `serve --https` needs HTTPS Certificates + MagicDNS enabled ONCE per tailnet (admin
# console: DNS > MagicDNS, then HTTPS Certificates). Until then serve prints a consent
# URL to stdout and would BLOCK, so bound it with `timeout` and keep the run moving.
if ! sudo tailscale serve status --json 2>/dev/null | grep -q '"tcp:443"'; then
    sudo timeout 15 tailscale serve --bg --https=443 http://127.0.0.1:9090 || \
        echo ">> Cockpit not yet served over the tailnet. Enable MagicDNS + HTTPS Certificates" \
             "in the Tailscale admin console (or complete the consent URL printed above), then re-run setup.sh."
fi

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
echo ">> first enter builds the box (dnf install claude-code from Anthropic + init hooks) — this can take a minute"
distrobox enter claudebox -- true   # triggers distrobox-init: installs additional_packages, runs init hooks; fails loudly HERE, not mislabeled in Phase 7

PHASE "7/8 Claude Code policy (enterprise tier, inside the box)"
distrobox enter claudebox -- sudo mkdir -p /etc/claude-code
distrobox enter claudebox -- sudo cp "/run/host$HERE/policy/CLAUDE.md" /etc/claude-code/CLAUDE.md
distrobox enter claudebox -- sudo cp "/run/host$HERE/policy/managed-settings.json" /etc/claude-code/managed-settings.json
mkdir -p "$HOME/.local/bin"
printf '#!/usr/bin/env bash\nexec distrobox enter claudebox -- bash -lc '\''exec /usr/bin/claude "$@"'\'' bash "$@"\n' > "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"

PHASE "8/8 verify"
bash "$HERE/verify.sh"
