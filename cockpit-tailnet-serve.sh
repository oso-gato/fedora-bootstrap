#!/usr/bin/env bash
# fedora-bootstrap — publish Cockpit on the tailnet, and make Cockpit work behind that proxy.
# Run by cockpit-tailnet-serve.service (installed to /usr/local/sbin by setup-host.sh).
#
# ONE attempt per run — the systemd MANAGER owns the retry, not a bash sleep-loop. The unit declares
# Restart=on-failure + RestartSec=60s + StartLimitIntervalSec=0, so this script just tries once and exits
# non-zero when the tailnet isn't ready; systemd reschedules it. A clean exit 0 (serve applied) is not a
# failure, so it stops retrying on the first success. This keeps each attempt observable in the journal /
# `systemctl status` instead of one opaque process that reports "active" while it is merely sleeping.
#
# Two halves, BOTH required for genuinely-tailnet-only Cockpit (cockpit.socket is loopback-bound by
# setup-host.sh, so this proxy is the only ingress):
#   1. `tailscale serve` publishes https://<node>.<tailnet>.ts.net/ -> http://127.0.0.1:9090, terminating
#      TLS at the tailnet edge. It blocks until the tailnet has MagicDNS + HTTPS Certificates enabled
#      (admin console: DNS > MagicDNS, then HTTPS Certificates), so `timeout` caps the attempt.
#   2. cockpit-ws sits behind that TLS-terminating proxy and would otherwise reject the login WebSocket as
#      cross-origin, so we allow-list the node's MagicDNS origin in /etc/cockpit/cockpit.conf. That FQDN
#      is only knowable once the node is up and named — which is exactly here, right after serve applies.
set -euo pipefail

# 1. One serve attempt. `timeout`'s non-zero exit (or tailscale's own error) => "not ready" => exit 1, and
#    systemd retries after RestartSec. Once it succeeds, serve config persists in tailscaled.
if ! timeout 20 tailscale serve --bg --https=443 http://127.0.0.1:9090; then
    echo "cockpit-serve: tailnet not ready — enable MagicDNS + HTTPS Certificates in the admin console; exiting non-zero so systemd retries" >&2
    exit 1
fi

# 2. Allow-list this node's MagicDNS origin so the proxied login WebSocket is accepted. python3 ships in
#    Fedora Cloud Base; .Self.DNSName is the node's FQDN (trailing dot stripped).
fqdn="$(tailscale status --json 2>/dev/null \
        | python3 -c 'import sys,json; print((json.load(sys.stdin).get("Self") or {}).get("DNSName","").rstrip("."))' 2>/dev/null || true)"
if [ -n "$fqdn" ]; then
    # AllowUnencrypted=true is SAFE here and prevents any HTTP->HTTPS redirect through the plain-HTTP
    # loopback hop: the bind is loopback-only, traffic is encrypted edge-to-edge by Tailscale (WireGuard)
    # and TLS-terminated at the node, so no plaintext byte leaves the host. Origins (https + wss) is the
    # load-bearing line — without it login's WebSocket is rejected cross-origin ("unexpected internal error").
    install -D -m0644 /dev/stdin /etc/cockpit/cockpit.conf <<EOF
[WebService]
Origins = https://${fqdn} wss://${fqdn}
ProtocolHeader = X-Forwarded-Proto
AllowUnencrypted = true
EOF
    systemctl try-restart cockpit || true   # best-effort: cockpit.conf is also re-read on the next connection
    echo "cockpit-serve: published at https://${fqdn}/ (Origins set; cockpit restarted)"
else
    echo "cockpit-serve: serve applied, but could not resolve the node's MagicDNS name — is MagicDNS enabled on the tailnet?" >&2
fi
