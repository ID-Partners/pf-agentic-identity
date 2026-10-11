#!/usr/bin/env bash
# Wait for a reference PingFederate to answer /pf/heartbeat.ping and /agentic-identity/health/ready with 200 over TLS,
# checking its certificate against the stack's CA (so this also proves the certificate names the host dialled).
#
#   wait-ready.sh BASE_URL CONTAINER [SECONDS]
#
# On a timeout it prints the container's last log lines and the ready answer, and exits 1.
set -euo pipefail
# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
base="${1:?usage: wait-ready.sh BASE_URL CONTAINER [SECONDS]}"
container="${2:?usage: wait-ready.sh BASE_URL CONTAINER [SECONDS]}"
limit="${3:-420}"
ca="$REF_LOCAL/tls/ca.crt"
deadline=$((SECONDS + limit))
while (( SECONDS < deadline )); do
  hb="$(curl -s --cacert "$ca" --max-time 5 -o /dev/null -w '%{http_code}' "$base/pf/heartbeat.ping" || true)"
  rd="$(curl -s --cacert "$ca" --max-time 5 -o /dev/null -w '%{http_code}' "$base/agentic-identity/health/ready" || true)"
  if [[ "$hb" == 200 && "$rd" == 200 ]]; then
    ref_log "$container ready at $base"
    exit 0
  fi
  if [[ "$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo missing)" =~ ^(exited|dead|missing)$ ]]; then
    break
  fi
  sleep 5
done
docker logs --tail 60 "$container" >&2 2>&1 || true
curl -s --cacert "$ca" --max-time 5 "$base/agentic-identity/health/ready" >&2 || true
ref_die "$container was not ready at $base (heartbeat ${hb:-none}, ready ${rd:-none})"
