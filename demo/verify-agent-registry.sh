#!/usr/bin/env bash
# The attester's agent registry on the rig (plan item X-A22, package A22): the bootstrap listener's order and banner
# line, agent_id in the CAS metadata, the operator API's status change and its version check, and the runtime role's
# append-only audit log.
#
# What it does:
#   1. starts a throwaway PostgreSQL 16 (PG_PORT, default 57631, label owner=prod-phase5), creates a runtime role,
#      runs `oidf-db-migrate.jar migrate --family agent` and `grants --runtime-role <role> --family agent --apply`,
#      and checks the role holds SELECT and INSERT only on agent_status_audit_log
#   2. boots the rig (up.sh) on its own slot (PF_RIG_NAME=pf-p5-agents, ports 47031/47080/47999, authoring
#      47199/47131), unless SKIP_UP=1, then recreates the container with OIDF_AGENT_REGISTRY_MODE=database and
#      OIDF_AGENT_REGISTRY_JDBC_URL at that database (development), and a development static operator bearer
#   3. checks server.log: the listener's line after LifecycleListener's markWebapp line and before the issuance
#      servlet's part, and the banner's "ATTESTATION_ISSUER agent registry: database" line
#   4. checks /.well-known/client-attestation-service lists agent_id in attestation_claims_issued
#   5. seeds an agent row, lists it (200), suspends it with expected_version 0 (200), revokes it with
#      expected_version 0 (409 version_conflict), and checks one audit row as the operator; no token is 401
#   6. takes the database and the rig down (KEEP_RIG=1 keeps both)
#
# The production profile's refusal of an in-memory registry is not driven here: the rig's image boots from a plaintext
# archive, which pf-entrypoint.sh refuses under production before PingFederate starts (seen 2026-10-08), and the
# profile is read from the environment only. AgentRegistryListenerTest holds that refusal (the part REFUSED, nothing
# thrown); REL5's rig profile with data.zip.age is where it can run on a PingFederate.
#
# The DPoP-bound operator token the production path takes is not driven here: the rig has no operator client, and the
# development static bearer (OIDF_AUTHORITY_ADMIN_TOKEN) stands in for it. The full issue, suspend and refuse loop
# needs live issuance behind real resolvers (B11) and is the release package's (REL5's agent-registry profile).
#
# Env:
#   SKIP_UP=1        the rig is already up on the slot (an earlier run with KEEP_RIG=1)
#   SKIP_AUTHOR=1 / SKIP_BUILD=1   passed through to up.sh
#   KEEP_RIG=1       leave the rig and the database running
#   MIGRATE_JAR      the migrator (default tools/db-migrate/target/oidf-db-migrate.jar: mvn -pl tools/db-migrate -am
#                    package first)
#   OUT_DIR          where server.log is copied (default conformance/.agent-registry, git-ignored)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=layout.sh
. "$HERE/layout.sh"
export PF_RIG_NAME="${PF_RIG_NAME:-pf-p5-agents}"
export PF_PORT_HTTPS="${PF_PORT_HTTPS:-47031}" PF_PORT_HTTP="${PF_PORT_HTTP:-47080}" PF_PORT_ADMIN="${PF_PORT_ADMIN:-47999}"
export PF_AUTHOR_ADMIN_PORT="${PF_AUTHOR_ADMIN_PORT:-47199}" PF_AUTHOR_RUNTIME_PORT="${PF_AUTHOR_RUNTIME_PORT:-47131}"
if [[ "$PF_RIG_NAME" == pf-agentic-identity ]]; then
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-conformance}"
else
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$PF_RIG_NAME}"
fi
PG_PORT="${PG_PORT:-57631}"
PG_NAME="$PF_RIG_NAME-pg"
MIGRATE_JAR="${MIGRATE_JAR:-$REPO/tools/db-migrate/target/oidf-db-migrate.jar}"
OUT="${OUT_DIR:-$HERE/.agent-registry}"
PF="https://localhost:$PF_PORT_HTTPS"
RUNTIME_ROLE="oidf_agent_rt"
LOG=/opt/out/instance/log/server.log

for tool in docker curl jq java openssl; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required" >&2; exit 1; }
done
[[ -f "$MIGRATE_JAR" ]] || { echo "ERROR: no migrator at $MIGRATE_JAR - mvn -pl tools/db-migrate -am package first" >&2; exit 1; }

WORK="$(mktemp -d)"
mkdir -p "$OUT"
PG_ADMIN_PASSWORD="$(openssl rand -hex 16)"
RUNTIME_PASSWORD="$(openssl rand -hex 16)"
ADMIN_TOKEN="$(openssl rand -hex 24)"
FAILS=0

cleanup() {
  rm -rf "$WORK"
  if [[ "${KEEP_RIG:-}" != 1 ]]; then
    docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
    ( cd "$HERE" && COMPOSE_FILE=docker-compose.yml docker compose down >/dev/null 2>&1 ) || true
  fi
}
trap cleanup EXIT

# check NAME EXPECTED GOT: one line, and a FAIL counted when GOT does not start with EXPECTED.
check() {
  local ok=ok
  [[ "$3" == "$2"* ]] || { ok=FAIL; FAILS=$((FAILS + 1)); }
  printf '%-58s %-30s %-40s %s\n' "$1" "$2" "${3:0:40}" "$ok"
}

psql_q() {
  docker exec -i "$PG_NAME" psql -U postgres -v ON_ERROR_STOP=1 -tA -c "$1"
}

# boot KEY=VALUE...: the container recreated with these settings over vars.env, then waited for.
boot() {
  { echo "services:"; echo "  pingfederate:"; echo "    labels:"; echo "      owner: prod-phase5"; echo "    environment:"
    for kv in "$@"; do printf '      %s: %s\n' "${kv%%=*}" "$(printf '%s' "${kv#*=}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"; done
  } > "$WORK/override.yml"
  ( cd "$HERE" && COMPOSE_FILE="docker-compose.yml:$WORK/override.yml" docker compose up -d --force-recreate >/dev/null 2>&1 )
  for _ in $(seq 1 60); do
    if [[ "$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "$PF/.well-known/openid-configuration")" == 200 ]]; then
      sleep 10   # the load-on-startup servlets and the deferred audit banner
      return 0
    fi
    sleep 5
  done
  echo "ERROR: PingFederate did not come back within five minutes; the end of server.log:" >&2
  docker exec "$PF_RIG_NAME" tail -40 "$LOG" >&2 || docker logs --tail 40 "$PF_RIG_NAME" >&2 || true
  exit 1
}

# line N PATTERN: the number of the first server.log line matching PATTERN, or 0.
line() {
  docker exec "$PF_RIG_NAME" grep -n -m1 -F "$1" "$LOG" 2>/dev/null | cut -d: -f1 || echo 0
}

# call METHOD PATH [BODY]: the status, a space, and the body's error member or "ok".
call() {
  local body="${3:-}" args=(-sk -o "$WORK/body" -w '%{http_code}' -X "$1" -H "Authorization: Bearer $ADMIN_TOKEN")
  [[ -z "$body" ]] || args+=(-H 'Content-Type: application/json' --data "$body")
  local status; status="$(curl "${args[@]}" "$PF/federation/attestation/agents$2")"
  printf '%s %s' "$status" "$(jq -r '.error // "ok"' "$WORK/body" 2>/dev/null || echo '-')"
}

echo "== 1. PostgreSQL, the agent family and the runtime role's grants"
docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
docker run -d --name "$PG_NAME" --label owner=prod-phase5 -e POSTGRES_PASSWORD="$PG_ADMIN_PASSWORD" \
  -p "127.0.0.1:$PG_PORT:5432" postgres:16 >/dev/null
for _ in $(seq 1 30); do docker exec "$PG_NAME" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 2
psql_q "CREATE ROLE $RUNTIME_ROLE LOGIN PASSWORD '$RUNTIME_PASSWORD'" >/dev/null
printf '%s' "$PG_ADMIN_PASSWORD" > "$WORK/pg.pw"
MIGRATE=(java -jar "$MIGRATE_JAR")
DB=(--jdbc-url "jdbc:postgresql://localhost:$PG_PORT/postgres" --user postgres --password-file "$WORK/pg.pw" --allow-plaintext)
"${MIGRATE[@]}" migrate --family agent "${DB[@]}" | tail -1
"${MIGRATE[@]}" grants --runtime-role "$RUNTIME_ROLE" --family agent --apply "${DB[@]}" | tail -1
check "migrated: V201 recorded" "201" "$(psql_q "SELECT max(version::int) FROM oidf_schema_history WHERE family = 'agent'")"
check "the runtime role on agent_status_audit_log" "INSERT,SELECT" "$(psql_q "SELECT string_agg(privilege_type, ',' ORDER BY privilege_type) FROM information_schema.role_table_grants WHERE grantee = '$RUNTIME_ROLE' AND table_name = 'agent_status_audit_log'")"
check "the runtime role on agent_identity" "DELETE,INSERT,SELECT,UPDATE" "$(psql_q "SELECT string_agg(privilege_type, ',' ORDER BY privilege_type) FROM information_schema.role_table_grants WHERE grantee = '$RUNTIME_ROLE' AND table_name = 'agent_identity'")"

echo "== 2. The rig, with the registry in that database"
[[ "${SKIP_UP:-}" == 1 ]] || "$HERE/up.sh"
boot OIDF_AGENT_REGISTRY_MODE=database \
  "OIDF_AGENT_REGISTRY_JDBC_URL=jdbc:postgresql://host.docker.internal:$PG_PORT/postgres" \
  "OIDF_AGENT_REGISTRY_JDBC_USERNAME=$RUNTIME_ROLE" "OIDF_AGENT_REGISTRY_JDBC_PASSWORD=$RUNTIME_PASSWORD" \
  "OIDF_AUTHORITY_ADMIN_TOKEN=$ADMIN_TOKEN"
docker cp "$PF_RIG_NAME:$LOG" "$OUT/server-database.log" >/dev/null 2>&1 || true

echo "== 3. server.log: the listener's order and the banner"
MARK="$(line "Lifecycle: this copy of platform is the webapp's")"
REGISTRY="$(line "Agent registry: database")"
ISSUER_PART="$(line "AttestationIssuanceServlet")"
check "markWebapp logged" "ok" "$([[ "$MARK" -gt 0 ]] && echo ok || echo missing)"
check "the registry's line after markWebapp" "ok" "$([[ "$REGISTRY" -gt "$MARK" && "$MARK" -gt 0 ]] && echo ok || echo "mark $MARK registry $REGISTRY")"
check "and before the issuance servlet's part" "ok" "$([[ "$REGISTRY" -gt 0 && ( "$ISSUER_PART" -eq 0 || "$REGISTRY" -lt "$ISSUER_PART" ) ]] && echo ok || echo "registry $REGISTRY issuer $ISSUER_PART")"
check "the banner names the registry" "ATTESTATION_ISSUER agent registry: database (a direct JDBC URL, development)" "$(docker exec "$PF_RIG_NAME" grep -o -m1 -F 'ATTESTATION_ISSUER agent registry: database (a direct JDBC URL, development)' "$LOG" || echo missing)"
LEAKS="$(docker exec "$PF_RIG_NAME" grep -c -F "$RUNTIME_PASSWORD" "$LOG" || true)"
check "the registry's password is in no server.log line" "0" "${LEAKS:-0}"

echo "== 4. The CAS metadata"
check "attestation_claims_issued lists agent_id" "true" "$(curl -sk "$PF/.well-known/client-attestation-service" | jq -c '.attestation_claims_issued | index("agent_id") != null')"

echo "== 5. The operator API"
psql_q "INSERT INTO agent_identity (agent_id, iss, client_id, instance_format, instance_subject, minted_at) VALUES ('rig-agent-1', '$PF', 'rig-client', 'spiffe_id', 'spiffe://rig.example/agent-1', now())" >/dev/null
check "GET / with no token" "401" "$(curl -sk -o /dev/null -w '%{http_code}' "$PF/federation/attestation/agents/?client_id=rig-client")"
check "GET / lists the seeded agent" "200 ok" "$(call GET "/?client_id=rig-client")"
check "  and it is there" "rig-agent-1" "$(jq -r '.agents[0].agent_id' "$WORK/body")"
check "GET /nope/x is 404 before the token" "404 not_found" "$(call GET "/nope/x")"
check "POST :suspend, expected_version 0" "200 ok" "$(call POST "/rig-agent-1:suspend" '{"reason":"rig A22","expected_version":0}')"
check "  status" "suspended" "$(jq -r '.status' "$WORK/body")"
check "POST :revoke, expected_version 0 (stale)" "409 version_conflict" "$(call POST "/rig-agent-1:revoke" '{"reason":"rig A22","expected_version":0}')"
check "  current_version" "1" "$(jq -r '.current_version' "$WORK/body")"
check "one audit row, as the operator" "1|suspended|admin:" "$(psql_q "SELECT count(*) || '|' || max(to_status) || '|' || max(actor) FROM agent_status_audit_log WHERE agent_id = 'rig-agent-1'")"

echo
if [[ "$FAILS" -gt 0 ]]; then
  echo "$FAILS check(s) failed; server.log is in $OUT"
  exit 1
fi
echo "every check passed; server.log is in $OUT"
