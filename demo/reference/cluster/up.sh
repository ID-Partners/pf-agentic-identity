#!/usr/bin/env bash
# reference/cluster: a PingFederate console and two engines (production profile) behind HAProxy, on PostgreSQL,
# Redis and OpenBao, on a slot.
#
#   REF_SLOT=N ./up.sh [--profile spire|mdm ...]
#        REF_NAME (default ref-cluster-s<N>), REF_OWNER, SKIP_BUILD=1, PF_RELEASE, REF_REAUTHOR=1, REF_PF_MEM_LIMIT
#
#   1. lib/build-image.sh     the modules staged for production and the image built (target capability)
#   2. lib/gen-tls.sh         the stack's CA and the certificates of PostgreSQL, Redis, OpenBao and PingFederate
#   3. lib/gen-secrets.sh     the roles' and Redis user's passwords, the cluster password, the SSF key, the age identity
#   5. lib/redis-acl.sh       Redis's ACL file
#   6. from the image         PingFederate's PostgreSQL client storage script, and service-points.conf with
#                             client.manager set to ClientManagerJdbcImpl - one line changed, checked
#   7. lib/author.sh          the config archive (client storage on), once per name; REF_REAUTHOR=1 again
#   8. docker compose up      the data tier and its jobs, OpenBao and bao-init, an agent per node, the console, the
#                             engines and HAProxy
#   9. the console replicates its configuration to the engines (POST /pf-admin-api/v1/cluster/replicate) and registers
#      reference-smoke in the database's client storage (lib/smoke-client.sh); then each engine, restarted once so it
#      trusts the stack's CA the replication brought (F-0585), and HAProxy must answer ready over TLS checked against
#      the stack's CA
set -euo pipefail
export REF_STACK=cluster
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
SPIRE=0 MDM=0
while (( $# )); do
  case "$1:${2:-}" in
    --profile:spire) SPIRE=1; shift 2 ;;
    --profile:mdm) MDM=1; shift 2 ;;
    *) ref_die "unknown argument '$1 ${2:-}' (--profile spire, --profile mdm)" ;;
  esac
done
for tool in docker terraform curl openssl unzip base64 python3; do
  command -v "$tool" >/dev/null || ref_die "$tool is required"
done
[[ "$PFAI_MODE" == release ]] || command -v mvn >/dev/null || ref_die "mvn is required (or set PF_RELEASE)"
ref_slot_ports_reserved || ref_log "WARNING: carrying on; a container this host restarts (up.sh restarts each engine once) can fail to start"
mkdir -p "$REF_LOCAL/bao"
chmod 700 "$HERE/.local" "$REF_LOCAL"

"$REF_LIB/build-image.sh"
"$REF_LIB/gen-tls.sh" "$REF_LOCAL/tls" "postgres=postgres,localhost,127.0.0.1" "redis=redis,localhost,127.0.0.1" \
  "openbao=openbao,localhost,127.0.0.1" \
  "pf=$REF_ISSUER_HOST,localhost,console,engine-1,engine-2,$REF_NAME-console,$REF_NAME-engine-1,$REF_NAME-engine-2,127.0.0.1" >&2
"$REF_LIB/gen-secrets.sh" "$REF_LOCAL/secrets" >&2
"$REF_LIB/redis-acl.sh" "$REF_LOCAL/secrets" "$REF_LOCAL/redis/users.acl"

# PingFederate's own files, from the image the nodes run: the client storage script U-0027 asked for, and
# service-points.conf, which cluster replication cannot carry, with client.manager moved to the JDBC implementation.
SQL=/opt/server/server/default/conf/oauth-client-management/sql-scripts/oauth-client-management-postgresql.sql
docker run --rm --entrypoint cat "$REF_IMAGE" "$SQL" > "$REF_LOCAL/oauth-client-management-postgresql.sql"
grep -q 'CREATE TABLE pingfederate_oauth_clients(' "$REF_LOCAL/oauth-client-management-postgresql.sql" \
  || ref_die "the image's $SQL does not create pingfederate_oauth_clients"
docker run --rm --entrypoint cat "$REF_IMAGE" /opt/server/server/default/conf/service-points.conf > "$REF_LOCAL/service-points.stock"
# The stock file has CRLF line endings; the one line is changed in place, ending and all, and nothing else.
python3 - "$REF_LOCAL/service-points.stock" "$REF_LOCAL/service-points.conf" <<'PY' || ref_die "service-points.conf: the image's client.manager line was not the one expected"
import re, sys
stock = open(sys.argv[1], "rb").read()
pattern = re.compile(rb"^client\.manager=org\.sourceid\.oauth20\.domain\.ClientManagerXmlFileImpl(\r?)$", re.M)
new, n = pattern.subn(rb"client.manager=org.sourceid.oauth20.domain.ClientManagerJdbcImpl\1", stock)
changed = [a for a, b in zip(stock.splitlines(), new.splitlines()) if a != b]
if n != 1 or len(changed) != 1 or len(stock.splitlines()) != len(new.splitlines()):
    sys.exit(f"expected one client.manager line to change; {n} matched, {len(changed)} changed")
open(sys.argv[2], "wb").write(new)
PY
chmod 644 "$REF_LOCAL/service-points.conf" "$REF_LOCAL/oauth-client-management-postgresql.sql"

if [[ "${REF_REAUTHOR:-0}" == 1 || ! -s "$REF_LOCAL/data.zip.age" ]]; then
  "$REF_LIB/author.sh"
else
  ref_log "reusing $REF_LOCAL/data.zip.age (REF_REAUTHOR=1 authors it again)"
fi
# Ciphertext, read through a bind mount by PingFederate's uid 9031: 0644 in this 0700 directory (an archive an earlier
# up.sh authored is 0600, which only Docker Desktop could read). reference/README.md, "File ownership on Linux".
chmod 644 "$REF_LOCAL/data.zip.age"

export REF_DB_MIGRATE_JAR="$REF_LOCAL/oidf-db-migrate.jar" REF_UID REF_GID
REF_UID="$(id -u)"; REF_GID="$(id -g)"
ref_compose up -d

# The console imports the archive, then pushes it to the engines. The image's own hook replicates only after a bulk
# import, not after the drop-in archive this image boots from, so it is asked here.
ADMIN="https://localhost:$PFAI_PORT_ADMIN"
CA="$REF_LOCAL/tls/ca.crt"
auth=(-K "$(ref_curl_user administrator "$REF_LOCAL/secrets/pf-admin")" -H 'X-XSRF-Header: PingFederate')
code=""
for _ in $(seq 1 96); do
  code="$(curl -s --cacert "$CA" --max-time 8 "${auth[@]}" -o /dev/null -w '%{http_code}' "$ADMIN/pf-admin-api/v1/version" || true)"
  [[ "$code" == 200 ]] && break
  sleep 5
done
[[ "$code" == 200 ]] || { docker logs --tail 60 "$REF_NAME-console" >&2 || true; ref_die "the console's admin API never answered 200 (last: ${code:-nothing})"; }
"$REF_LIB/replicate.sh"
"$REF_LIB/smoke-client.sh"
# An engine's JVM trusts what PingFederate's trusted CAs held when it started (U-0321), and a new engine gets the
# stack's CA only with the console's replication, after it started: until it restarts once, its own TLS calls to the
# issuer (SSF's introspection) and to a receiver under the stack's CA fail PKIX (F-0585; C-7 hit it on 2026-10-08).
# Each engine is restarted once, in turn, after its first replication.
for engine in engine-1 engine-2; do
  port_var="PFAI_PORT_ENGINE_${engine#engine-}"
  "$REF_LIB/wait-ready.sh" "https://localhost:${!port_var}" "$REF_NAME-$engine"
  docker restart "$REF_NAME-$engine" >/dev/null
  "$REF_LIB/wait-ready.sh" "https://localhost:${!port_var}" "$REF_NAME-$engine"
done
"$REF_LIB/wait-ready.sh" "https://localhost:$PFAI_PORT_RUNTIME" "$REF_NAME-haproxy"
if (( SPIRE )); then
  # The agent joins with a one-time token from the server; the server's bundle is exported for the attestation client.
  mkdir -p "$REF_LOCAL/spire"
  ref_compose --profile spire up -d --wait spire-server
  spire() { docker exec "$REF_NAME-spire-server" /opt/spire/bin/spire-server "$@" -socketPath /tmp/spire-server/private/api.sock; }
  if ! docker inspect "$REF_NAME-spire-agent" >/dev/null 2>&1; then
    REF_SPIRE_JOIN_TOKEN="$(spire token generate -spiffeID "spiffe://reference.test/agent/$REF_NAME" -ttl 600 | sed -n 's/^Token: //p')"
    [[ -n "$REF_SPIRE_JOIN_TOKEN" ]] || ref_die "the SPIRE server generated no join token"
    export REF_SPIRE_JOIN_TOKEN
  fi
  ref_compose --profile spire up -d spire-agent
  spire bundle show -format pem > "$REF_LOCAL/spire/bundle.pem"
  grep -q 'BEGIN CERTIFICATE' "$REF_LOCAL/spire/bundle.pem" || ref_die "the SPIRE server exported no bundle"
  ref_log "spire: server and agent up; trust bundle for spiffe://reference.test in $REF_LOCAL/spire/bundle.pem"
fi
if (( MDM )); then
  # services/device-enrolment from this checkout's build; a release publishes no device-enrolment asset.
  [[ "$PFAI_MODE" == reactor ]] || ref_die "the mdm profile needs this repository's reactor build (a release has no device-enrolment)"
  DE="$PFAI_ROOT/services/device-enrolment/target"
  jar=""
  for candidate in "$DE"/device-enrolment-*.jar; do
    [[ "$candidate" == *-original* || ! -s "$candidate" ]] || { jar="$candidate"; break; }
  done
  [[ -s "$jar" && -d "$DE/dependency" ]] || ref_die "no device-enrolment jar and dependency/ under $DE (mvn package)"
  rm -rf "$REF_LOCAL/device-enrolment"; mkdir -p "$REF_LOCAL/device-enrolment"
  cp "$jar" "$REF_LOCAL/device-enrolment/device-enrolment.jar"
  cp -R "$DE/dependency" "$REF_LOCAL/device-enrolment/dependency"
  "$REF_LIB/gen-ec-jwk.sh" "$REF_LOCAL/secrets/enrolment-signing.jwk" >&2
  ref_compose --profile mdm up -d device-enrolment
  for _ in $(seq 1 30); do
    curl -sf --max-time 3 "http://localhost:$PFAI_PORT_MDM/health" >/dev/null && break
    sleep 2
  done
  curl -sf --max-time 3 "http://localhost:$PFAI_PORT_MDM/health" >/dev/null \
    || { docker logs --tail 30 "$REF_NAME-device-enrolment" >&2; ref_die "device-enrolment did not answer /health"; }
  ref_log "mdm: device-enrolment (development, REGISTRY=memory) at http://localhost:$PFAI_PORT_MDM"
fi
ref_log "up: issuer $REF_ISSUER (https://localhost:$PFAI_PORT_RUNTIME through HAProxy), engines https://localhost:$PFAI_PORT_ENGINE_1 and :$PFAI_PORT_ENGINE_2, console admin $ADMIN, HAProxy runtime API 127.0.0.1:$PFAI_PORT_HAPROXY_API. ./smoke.sh checks every node; ./down.sh removes it all."
