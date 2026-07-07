#!/usr/bin/env bash
# host-gh-refresh.sh — mint + rewire the HOST's standing GitHub identity (<=1h App
# installation token), driven hourly by host-gh-refresh.timer.
#
# The HOST is a first-class gh consumer: live-gate-watch.sh discovers `live-validate` PRs
# and POSTS the GREEN/RED verdict comments — the identity the deterministic auto-merge
# trusts as LG_HOST_LOGIN. This keeps that identity standing (no human expiry) the same
# way the dev box does, via the VERBATIM-mirrored gh-app-auth.sh: fresh JWT -> <=1h
# installation token -> ~/.git-credentials (store helper) + ~/.config/gh/hosts.yml.
#
# The App private key's ONLY at-rest home is the rootless podman secret `gh_app_host_key`
# (created by setup-user's paste prompt); it is handed to gh-app-auth.sh via the process
# env, never written to disk here. The PUBLIC ids live in ~/.config/gh-app-host.env.
#
# NO-OP (rc 0) when the host App is not provisioned — the timer can always be enabled;
# the operator may be running on a manual `gh auth login` instead (setup WARNs about it).
set -euo pipefail
umask 077

ENVF="$HOME/.config/gh-app-host.env"
if [ ! -r "$ENVF" ] || ! podman secret exists gh_app_host_key 2>/dev/null; then
    echo "host-gh-refresh: no HOST App provisioned (missing $ENVF or secret gh_app_host_key) — nothing to do"
    exit 0
fi
# shellcheck source=/dev/null
. "$ENVF"    # GH_APP_ID + GH_APP_INSTALLATION_ID (public integers)
[ -n "${GH_APP_ID:-}" ] || { echo "host-gh-refresh: FATAL — $ENVF lacks GH_APP_ID" >&2; exit 1; }

# PEM out of the secret store into the process env only (podman >=4.7 --showsecret).
GH_APP_PRIVATE_KEY="$(podman secret inspect --showsecret --format '{{.SecretData}}' gh_app_host_key)" \
    || { echo "host-gh-refresh: FATAL — could not read secret gh_app_host_key" >&2; exit 1; }
[ -n "$GH_APP_PRIVATE_KEY" ] || { echo "host-gh-refresh: FATAL — secret gh_app_host_key is empty" >&2; exit 1; }

export GH_APP_ID GH_APP_INSTALLATION_ID GH_APP_PRIVATE_KEY
AUTH="$HOME/.local/bin/gh-app-auth.sh"; [ -x "$AUTH" ] || AUTH="$(dirname "$(readlink -f "$0")")/gh-app-auth.sh"
exec "$AUTH" install
