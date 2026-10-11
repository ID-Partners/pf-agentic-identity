#!/usr/bin/env bash
# Ask a reference cluster's console to replicate its configuration to the engines (PingFederate's admin API,
# POST /pf-admin-api/v1/cluster/replicate), and wait until the console says every node is in sync.
set -euo pipefail
# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
ADMIN="https://localhost:$PFAI_PORT_ADMIN"
CA="$REF_LOCAL/tls/ca.crt"
auth=(-K "$(ref_curl_user administrator "$REF_LOCAL/secrets/pf-admin")" -H 'X-XSRF-Header: PingFederate')
status=""
for _ in $(seq 1 60); do
  status="$(curl -s --cacert "$CA" --max-time 10 "${auth[@]}" "$ADMIN/pf-admin-api/v1/cluster/status" || true)"
  n="$(python3 -c 'import json,sys
try: d=json.loads(sys.argv[1])
except Exception: print(0); raise SystemExit
print(sum(1 for x in d.get("nodes",[]) if x.get("mode")=="CLUSTERED_ENGINE"))' "$status")"
  [[ "$n" -ge 2 ]] && break
  sleep 5
done
[[ "${n:-0}" -ge 2 ]] || { echo "$status" >&2; ref_die "the console never saw two engines in the cluster"; }
code="$(curl -s --cacert "$CA" --max-time 120 "${auth[@]}" -X POST -o "$REF_LOCAL/replicate.json" -w '%{http_code}' \
  "$ADMIN/pf-admin-api/v1/cluster/replicate")"
[[ "$code" == 200 ]] || { cat "$REF_LOCAL/replicate.json" >&2; ref_die "cluster/replicate answered $code"; }
for _ in $(seq 1 30); do
  status="$(curl -s --cacert "$CA" --max-time 10 "${auth[@]}" "$ADMIN/pf-admin-api/v1/cluster/status" || true)"
  if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); raise SystemExit(0 if d.get("replicationRequired") is False else 1)' "$status" 2>/dev/null; then
    ref_log "the console replicated its configuration; cluster/status says no replication is required"
    exit 0
  fi
  sleep 3
done
echo "$status" >&2
ref_die "cluster/status still says replication is required"
