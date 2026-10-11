#!/usr/bin/env bash
# Register reference-smoke through a reference cluster's console admin API, once: with JDBC client storage the client
# lives in PostgreSQL, where every engine reads it without replication. Idempotent - a client already there is kept,
# its secret set to the generated one.
set -euo pipefail
# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ADMIN="https://localhost:$PFAI_PORT_ADMIN/pf-admin-api/v1"
CA="$REF_LOCAL/tls/ca.crt"
auth=(-K "$(ref_curl_user administrator "$REF_LOCAL/secrets/pf-admin")" -H 'X-XSRF-Header: PingFederate' -H 'Content-Type: application/json')
body="$(SECRET="$(cat "$REF_LOCAL/secrets/smoke-client")" python3 -c '
import json, os
print(json.dumps({
    "clientId": "reference-smoke", "name": "Reference stack smoke check", "grantTypes": ["CLIENT_CREDENTIALS"],
    "clientAuth": {"type": "SECRET", "secret": os.environ["SECRET"]},
    "restrictScopes": True, "restrictedScopes": ["reference.smoke"],
    "defaultAccessTokenManagerRef": {"id": "referenceJwt"},
}))')"
code="$(curl -s --cacert "$CA" --max-time 20 "${auth[@]}" -o /dev/null -w '%{http_code}' "$ADMIN/oauth/clients/reference-smoke")"
if [[ "$code" == 200 ]]; then
  method=PUT url="$ADMIN/oauth/clients/reference-smoke"
else
  method=POST url="$ADMIN/oauth/clients"
fi
code="$(curl -s --cacert "$CA" --max-time 30 "${auth[@]}" -X "$method" --data-binary @- -o "$REF_LOCAL/smoke-client.json" \
  -w '%{http_code}' "$url" <<<"$body")"
[[ "$code" =~ ^20[01]$ ]] || { cat "$REF_LOCAL/smoke-client.json" >&2; ref_die "registering reference-smoke answered $code"; }
rm -f "$REF_LOCAL/smoke-client.json"
ref_log "reference-smoke registered through the console ($method), in the cluster's client storage"
