#!/usr/bin/env bash
# The reference cluster's data tier, unlicensed: PostgreSQL and Redis with the db-roles, db-migrate and
# pf-client-storage jobs, on a slot, then assertions on what they left; always taken down. Build's
# reference-data-tier job runs it; it runs the same on a Mac.
#
#   REF_SLOT=N reference/lib/data-tier-test.sh [DB_MIGRATE_JAR]
#
# DB_MIGRATE_JAR defaults to tools/db-migrate/target/oidf-db-migrate.jar (mvn -pl tools/db-migrate -am package).
# Asserts: both servers refuse plaintext; pf_runtime owns nothing and has no CREATE on the database or a schema;
# oidf-db-migrate.jar's validate is clean; PingFederate's client tables are in schema pf, owned by pf_clients, and a
# second pf-client-storage run changes nothing; Redis's oidf user is refused a key off its prefixes and FLUSHALL, and
# the default user is off. No PingFederate and no licence: the client storage script comes from the pinned public
# image, which needs none to read.
set -euo pipefail
export REF_STACK=cluster
export REF_NAME="${REF_NAME:-ref-data-s${REF_SLOT:-}}"
# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
JAR="${1:-$PFAI_ROOT/tools/db-migrate/target/oidf-db-migrate.jar}"
[[ -s "$JAR" ]] || ref_die "no oidf-db-migrate.jar at $JAR (mvn -q -pl tools/db-migrate -am -DskipTests package)"
NET="${REF_NAME}_default"
SERVICES=(postgres redis db-roles db-migrate pf-client-storage)
failures=0
check() { # check DESCRIPTION COMMAND...: run it, say PASS or FAIL
  local what="$1"; shift
  if "$@"; then echo "PASS  $what"; else echo "FAIL  $what"; failures=$((failures + 1)); fi
}
down() { ref_compose down --volumes --remove-orphans --timeout 10 >/dev/null 2>&1 || true; }
trap down EXIT

mkdir -p "$REF_LOCAL"
chmod 700 "$REF_STACK_DIR/.local" "$REF_LOCAL"
"$REF_LIB/gen-tls.sh" "$REF_LOCAL/tls" "postgres=postgres,localhost,127.0.0.1" "redis=redis,localhost,127.0.0.1" >/dev/null
"$REF_LIB/gen-secrets.sh" "$REF_LOCAL/secrets" --no-age >/dev/null
"$REF_LIB/redis-acl.sh" "$REF_LOCAL/secrets" "$REF_LOCAL/redis/users.acl"
install -m 0644 "$JAR" "$REF_LOCAL/oidf-db-migrate.jar"
SQL=/opt/server/server/default/conf/oauth-client-management/sql-scripts/oauth-client-management-postgresql.sql
docker run --rm --entrypoint cat "$PF_IMAGE@$PF_IMAGE_DIGEST" "$SQL" > "$REF_LOCAL/oauth-client-management-postgresql.sql"
chmod 644 "$REF_LOCAL/oauth-client-management-postgresql.sql"
export REF_DB_MIGRATE_JAR="$REF_LOCAL/oidf-db-migrate.jar"

down
ref_compose up -d "${SERVICES[@]}" >/dev/null 2>&1 || true
for job in db-roles db-migrate pf-client-storage; do
  state=""
  for _ in $(seq 1 120); do
    state="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$REF_NAME-$job" 2>/dev/null || true)"
    [[ "$state" == exited* ]] && break
    sleep 2
  done
  check "job $job completed ($state)" test "$state" = "exited 0"
done
ref_compose logs --no-color db-roles db-migrate pf-client-storage | sed 's/^/    /' | grep -E 'db-roles:|validate:|db-migrate:|pf-client-storage:|ERROR|error' || true

psql_as() { # psql_as ROLE SSLMODE SQL: one value, over the stack's network
  local role="$1" mode="$2" sql="$3" pwfile
  case "$role" in postgres) pwfile=postgres-superuser ;; pf_runtime) pwfile=pf-runtime ;; pf_clients) pwfile=pf-clients ;; esac
  docker run --rm --network "$NET" -v "$REF_LOCAL/tls/ca.crt:/tls/ca.crt:ro" -v "$REF_LOCAL/secrets/$pwfile:/pw:ro" \
    --entrypoint sh "$REF_POSTGRES_IMAGE" -c \
    "PGPASSWORD=\"\$(cat /pw)\" psql -XAtq \"host=postgres dbname=oidf user=$role sslmode=$mode sslrootcert=/tls/ca.crt\" -c \"$sql\"" 2>&1 || true
}
redis_as() { # redis_as USER|- TLS(yes|no) COMMAND...: the reply
  local user="$1" tls="$2"; shift 2
  local args=(-h redis -p 6379)
  [[ "$tls" == yes ]] && args+=(--tls --cacert /tls/ca.crt)
  [[ "$user" == - ]] || args+=(--user "$user" --pass "$(cat "$REF_LOCAL/secrets/redis-oidf")" --no-auth-warning)
  docker run --rm --network "$NET" -v "$REF_LOCAL/tls/ca.crt:/tls/ca.crt:ro" "$REF_REDIS_IMAGE" \
    redis-cli "${args[@]}" "$@" 2>&1 || true
}

out="$(psql_as pf_runtime disable 'SELECT 1')"
check "PostgreSQL refuses a plaintext connection ($(head -c 90 <<<"$out"))" grep -q 'no encryption' <<<"$out"
out="$(redis_as oidf no PING)"
no_pong() { ! grep -q PONG <<<"$1"; }
check "Redis refuses a plaintext connection ($(head -c 60 <<<"$out" | tr '\n' ' '))" no_pong "$out"
out="$(psql_as postgres verify-full "SELECT count(*) FROM pg_class c JOIN pg_roles r ON r.oid = c.relowner WHERE r.rolname = 'pf_runtime'")"
check "pf_runtime owns no table, sequence or index ($out)" test "$out" = 0
out="$(psql_as postgres verify-full "SELECT count(*) FROM pg_namespace n JOIN pg_roles r ON r.oid = n.nspowner WHERE r.rolname = 'pf_runtime'")"
check "pf_runtime owns no schema ($out)" test "$out" = 0
out="$(psql_as postgres verify-full "SELECT has_database_privilege('pf_runtime', 'oidf', 'CREATE')::text || ',' || has_schema_privilege('pf_runtime', 'public', 'CREATE')::text || ',' || has_schema_privilege('pf_runtime', 'pf', 'CREATE')::text")"
check "pf_runtime has no CREATE on the database, public or pf ($out)" test "$out" = "false,false,false"
out="$(psql_as pf_runtime verify-full "SELECT count(*) FROM ssf_streams")"
check "pf_runtime reads the families' tables over verify-full ($out)" test "$out" = 0
out="$(docker run --rm --network "$NET" -v "$REF_LOCAL/tls/ca.crt:/tls/ca.crt:ro" \
  -v "$REF_LOCAL/secrets/oidf-migrator:/pw:ro" -v "$REF_LOCAL/oidf-db-migrate.jar:/jar:ro" \
  -e OIDF_DB_MIGRATE_JDBC_URL='jdbc:postgresql://postgres:5432/oidf?sslmode=verify-full&sslrootcert=/tls/ca.crt' \
  -e OIDF_DB_MIGRATE_USER=oidf_migrator -e OIDF_DB_MIGRATE_PASSWORD_FILE=/pw "$REF_JRE_IMAGE" java -jar /jar validate 2>&1 || true)"
check "oidf-db-migrate.jar validate is clean ($(tail -n 1 <<<"$out"))" grep -q 'no drift, gaps, unknown or failed versions' <<<"$out"
out="$(psql_as postgres verify-full "SELECT string_agg(t.tablename || ':' || t.tableowner, ',' ORDER BY t.tablename) FROM pg_tables t WHERE t.schemaname = 'pf'")"
check "PingFederate's client tables are in schema pf, owned by pf_clients ($out)" \
  test "$out" = "pingfederate_oauth_clients:pf_clients,pingfederate_oauth_clients_ext:pf_clients"
out="$(ref_compose run --rm --no-deps pf-client-storage 2>&1 | tail -n 1)"
check "a second pf-client-storage run changes nothing ($out)" grep -q 'already has' <<<"$out"
out="$(redis_as oidf yes SET oidf:reference:probe 1)"
check "Redis: oidf may SET under oidf: ($out)" test "$out" = OK
out="$(redis_as oidf yes SET reference:probe 1)"
check "Redis: oidf is refused a key off its prefixes ($(head -c 70 <<<"$out"))" grep -q NOPERM <<<"$out"
out="$(redis_as oidf yes FLUSHALL)"
check "Redis: oidf is refused FLUSHALL ($(head -c 70 <<<"$out"))" grep -q NOPERM <<<"$out"
out="$(redis_as - yes GET oidf:reference:probe)"
check "Redis: the default user is off ($(head -c 70 <<<"$out"))" grep -q NOAUTH <<<"$out"

if (( failures )); then
  ref_die "$failures data-tier check(s) failed"
fi
ref_log "data tier: every check passed ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
