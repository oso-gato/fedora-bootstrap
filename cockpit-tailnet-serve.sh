#!/usr/bin/env bash
# fedora-bootstrap — publish Cockpit on the tailnet, and make Cockpit work behind that proxy.
# Run by cockpit-tailnet-serve.service (installed to /usr/local/sbin by setup-host.sh). Idempotent and
# self-healing: re-asserting serve is instant once applied, and it re-derives the conf on every boot.
#
# Two halves, BOTH required for genuinely-tailnet-only Cockpit (cockpit.socket is already bound to
# loopback by setup-host.sh, so this proxy is the only ingress):
#   1. `tailscale serve` publishes https://<node>.<tailnet>.ts.net/ -> http://127.0.0.1:9090, terminating
#      TLS at the tailnet edge. It blocks until the tailnet has MagicDNS + HTTPS Certificates enabled
#      (admin console: DNS > MagicDNS, then HTTPS Certificates), so each attempt is bounded and retried.
#   2. cockpit-ws sits behind that TLS-terminating proxy and would otherwise reject the login WebSocket as
#      cross-origin, so we allow-list the node's MagicDNS origin in /etc/cockpit/cockpit.conf. That FQDN
#      is only knowable once the node is up and named — which is exactly here, right after serve applies.
set -euo pipefail

# 1. Apply serve (idempotent). Retry until the tailnet toggles are on; then it persists in tailscaled.
until timeout 20 tailscale serve --bg --https=443 http://127.0.0.1:9090; do
    echo "cockpit-serve: tailnet not ready — enable MagicDNS + HTTPS Certificates in the admin console; retrying in 60s" >&2
    sleep 60
done

# 2. Allow-list this node's MagicDNS origin so the proxied login WebSocket is accepted. python3 ships in
#    Fedora Cloud Base; .Self.DNSName is the node's FQDN (with a trailing dot we strip).
fqdn="$(tailscale status --json 2>/dev/null \
        | python3 -c 'import sys,json; print((json.load(sys.stdin).get("Self") or {}).get("DNSName","").rstrip("."))')"
if [ -n "$fqdn" ]; then
    # AllowUnencrypted=true is SAFE here and prevents any HTTP->HTTPS redirect through the plain-HTTP
    # loopback hop: the bind is loopback-only, traffic is encrypted edge-to-edge by Tailscale (WireGuard)
    # and TLS-terminated at the node, so no plaintext byte ever leaves the host. ProtocolHeader is kept
    # for defensiveness. Origins (https + wss) is the load-bearing line — without it login's WebSocket is
    # rejected cross-origin (the page loads, then "unexpected internal error").
    install -D -m0644 /dev/stdin /etc/cockpit/cockpit.conf <<EOF
[WebService]
Origins = https://${fqdn} wss://${fqdn}
ProtocolHeader = X-Forwarded-Proto
AllowUnencrypted = true
EOF
    systemctl try-restart cockpit
    echo "cockpit-serve: published at https://${fqdn}/ (Origins set; cockpit restarted)"
else
    echo "cockpit-serve: serve applied, but could not resolve the node's MagicDNS name — is MagicDNS enabled on the tailnet?" >&2
fi
