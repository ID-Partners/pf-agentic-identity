#!/usr/bin/env bash
# reference/cluster's licensed boot check, on a stack up.sh brought up. Every node's start-up audit says its mode,
# the production profile, OAuth clients in the database, the jdbc lease backend and no refusal; the console's
# cluster/status lists it and two engines; and reference-smoke takes a token through HAProxy and through each engine
# on its own port, every call over TLS checked against the stack's CA.
#
#   REF_SLOT=N ./smoke.sh
set -euo pipefail
export REF_STACK=cluster
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
want=("OAuth clients in database" "lease backend jdbc")
"$REF_LIB/smoke-node.sh" - "$REF_NAME-console" CLUSTERED_CONSOLE "${want[@]}"
"$REF_LIB/smoke-node.sh" "https://localhost:$PFAI_PORT_ENGINE_1" "$REF_NAME-engine-1" CLUSTERED_ENGINE "${want[@]}"
"$REF_LIB/smoke-node.sh" "https://localhost:$PFAI_PORT_ENGINE_2" "$REF_NAME-engine-2" CLUSTERED_ENGINE "${want[@]}"
for _ in 1 2 3 4; do
  # Round robin: four tokens through HAProxy reach both engines.
  curl -sf --cacert "$REF_LOCAL/tls/ca.crt" --max-time 10 -K "$(ref_curl_user reference-smoke "$REF_LOCAL/secrets/smoke-client")" \
    -d grant_type=client_credentials -d scope=reference.smoke "https://localhost:$PFAI_PORT_RUNTIME/as/token.oauth2" \
    | grep -q '"access_token"' || ref_die "no token through HAProxy"
done
status="$(curl -sf --cacert "$REF_LOCAL/tls/ca.crt" -K "$(ref_curl_user administrator "$REF_LOCAL/secrets/pf-admin")" \
  -H 'X-XSRF-Header: PingFederate' "https://localhost:$PFAI_PORT_ADMIN/pf-admin-api/v1/cluster/status")"
python3 - "$status" <<'PY' || ref_die "cluster/status does not list one console and two engines: $status"
import json, sys
modes = sorted(n.get("mode") for n in json.loads(sys.argv[1]).get("nodes", []))
sys.exit(0 if modes == ["CLUSTERED_CONSOLE", "CLUSTERED_ENGINE", "CLUSTERED_ENGINE"] else 1)
PY
ref_log "smoke: passed - a console and two engines, tokens through HAProxy and each engine ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
