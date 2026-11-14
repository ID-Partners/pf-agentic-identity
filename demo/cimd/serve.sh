#!/usr/bin/env bash
# Serve the CIMD profile's document (cimd/payments.json) over https on 127.0.0.1:57443, from a throwaway nginx
# container, with the certificate gen-keys.sh writes for host.docker.internal (keys/suite-tls.*).
#
#   cimd/serve.sh          start it (replacing one already running)
#   cimd/serve.sh stop     stop and remove it
#
# PingFederate reaches it as https://host.docker.internal:57443/agents/payments, the client id
# profiles/conformance-attester-cimd.yaml lists (conformance.cimd_client_id). CIMD_PORT moves the host port.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RIG="$(cd "$HERE/.." && pwd)"
NAME="${PF_RIG_NAME:-pf-agentic-identity}-cimd"
docker rm -f "$NAME" >/dev/null 2>&1 || true
[[ "${1:-}" == stop ]] && exit 0
[[ -f "$RIG/keys/suite-tls.crt" ]] || "$RIG/gen-keys.sh"
docker run -d --name "$NAME" --label owner=pf-agentic-identity-rig \
  -p "127.0.0.1:${CIMD_PORT:-57443}:8443" \
  -v "$HERE/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$HERE/payments.json:/cimd/payments.json:ro" \
  -v "$RIG/keys/suite-tls.crt:/keys/suite-tls.crt:ro" -v "$RIG/keys/suite-tls.key:/keys/suite-tls.key:ro" \
  nginx:1.27-alpine >/dev/null
echo "CIMD document  https://localhost:${CIMD_PORT:-57443}/agents/payments  (container $NAME)"
