#!/usr/bin/env bash
# The attestation events over SSF on this rig (feature 206, story #339): a SOC receiver's stream, flagged for refusals,
# hears each attestation event once per thing that happened - instance-registered, attestation-issued (first, then a
# renewal), attestation-refused and attester-key-rotated - from a booted PingFederate, through its real endpoints.
#
# What it does:
#   1. builds services/harness (AttestationEventsHarness) and tools/db-migrate, unless SKIP_BUILD=1, and makes a P-256
#      JWT-SVID signer and an instance key; the signer's public JWKS is the attestation client's SPIFFE bundle
#   2. starts a throwaway PostgreSQL 16 (PG_PORT, label owner=pf-attestation-events) and migrates its platform, agent
#      and ssf families with oidf-db-migrate.jar
#   3. boots the rig (up.sh) on its own slot (PF_RIG_SLOT, default 38) with docker-compose.attester-keys.yml - OpenBao's
#      transit key attestation-es256 and the conformance-attester-transit client, whose bundle is step 1's - unless
#      SKIP_UP=1; then recreates PingFederate with the agent registry and the SSF store on that database (the tables
#      store), OIDF_SSF_REFUSAL_RECEIVERS=conformance-ssf-receiver and a 60 s key refresh (the overlay's)
#   4. as conformance-ssf-receiver (private_key_jwt, ssf.manage) creates a poll stream requesting the four event types,
#      and checks events_delivered names all four
#   5. drives them: an attestation (200), a request whose proof is signed by another key (400 invalid_instance_proof,
#      refused after the evidence matched the client), the transit key rotated in OpenBao, and, past the refresh
#      interval, a second attestation for the same agent (200, signed under the new kid)
#   6. polls the stream (every SET's signature checked against the transmitter's jwks_uri) and checks each type arrived
#      exactly once per trigger: one instance-registered and one attestation-refused, one attestation-issued per 200
#      (the first with renewal false, the rest true), one attester-key-rotated naming the old and new kid, and nothing
#      else; the SETs go to OUT_DIR/sets.jsonl
#   7. takes the rig and the database down (KEEP_RIG=1 keeps both)
#
# Two-node: the reference cluster (reference/cluster) runs with the attestation issuer off (reference/lib/pf-common.env)
# until F-0601 is closed, so "no duplicates on two nodes" is not driven here. The tables store's replay keys that make
# it hold are tested on PostgreSQL with two nodes in-process: JdbcAgentRegistryTest (one mint reported once),
# DeviceInstanceRegistrationsOnPostgresTest and AttesterKeyRotatedSetOnPostgresTest.
#
# The development profile, as the rig's: PingFederate reaches the database as its superuser, and the SPIRE reader is
# not configured (the client's bundle is a static JWKS), so no spire: selectors are read.
#
# Env:
#   JAVA (java: 17 or later), PF_RIG_SLOT (38), SKIP_UP=1, SKIP_AUTHOR=1 / SKIP_BUILD=1 (passed to up.sh too), KEEP_RIG=1
#   PG_PORT (57931), REFRESH (65: seconds waited after the rotation; the overlay's refresh is 60)
#   OUT_DIR (conformance/.attestation-events, git-ignored: the private JWKs, the SETs, server.log)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=layout.sh
. "$HERE/layout.sh"
export PF_RIG_SLOT="${PF_RIG_SLOT:-38}"
pfai_slot_ports "$PF_RIG_SLOT"
export PF_RIG_NAME="${PF_RIG_NAME:-pf-rig-s$PF_RIG_SLOT}"
export PF_PORT_HTTPS="${PF_PORT_HTTPS:-$PFAI_PORT_RIG_HTTPS}"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$PF_RIG_NAME}"
COMPOSE_FILES="docker-compose.yml:docker-compose.attester-keys.yml"
PG_PORT="${PG_PORT:-57931}"
PG_NAME="$PF_RIG_NAME-pg"
REFRESH="${REFRESH:-65}"
OUT="${OUT_DIR:-$HERE/.attestation-events}"
PF="https://localhost:$PF_PORT_HTTPS"
LOG=/opt/out/instance/log/server.log
RECEIVER=conformance-ssf-receiver
RECEIVER_JWKS="$HERE/keys/ssf-receiver.private.jwks.json"
URN="urn:idpartners:params:secevent:attestation:1.0:"
EVENTS=("${URN}instance-registered" "${URN}attestation-issued" "${URN}attestation-refused" "${URN}attester-key-rotated")
MIGRATE_JAR="$REPO/tools/db-migrate/target/oidf-db-migrate.jar"

JAVA="${JAVA:-java}"
for tool in docker curl jq "$JAVA" mvn openssl python3; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required" >&2; exit 1; }
done
mkdir -p "$OUT"
WORK="$(mktemp -d)"
PG_PASSWORD="$(openssl rand -hex 16)"
FAILS=0

cleanup() {
  rm -rf "$WORK"
  if [[ "${KEEP_RIG:-}" != 1 ]]; then
    docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
    ( cd "$HERE" && COMPOSE_FILE="$COMPOSE_FILES" docker compose down -v >/dev/null 2>&1 ) || true
  fi
}
trap cleanup EXIT

# check NAME EXPECTED GOT: one line, and a FAIL counted when GOT is not EXPECTED.
check() {
  local ok=ok
  [[ "$3" == "$2" ]] || { ok=FAIL; FAILS=$((FAILS + 1)); }
  printf '%-62s %-26s %-26s %s\n' "$1" "${2:0:26}" "${3:0:26}" "$ok"
}

echo "== 1. The harness, the migrator and the keys"
if [[ "${SKIP_BUILD:-}" != 1 ]]; then
  ( cd "$REPO" && mvn -B -q -pl services/harness,tools/db-migrate -am install -DskipTests )
fi
( cd "$REPO" && mvn -B -q -pl services/harness dependency:build-classpath -Dmdep.outputFile="$WORK/cp.txt" )
HARNESS_CP="$(cat "$WORK/cp.txt"):$REPO/services/harness/target/classes"
harness() {
  OIDF_HARNESS_INSECURE_TLS=true "$JAVA" -cp "$HARNESS_CP" com.pingidentity.ps.oidf.harness.AttestationEventsHarness "$@"
}
harness keys "$OUT" >/dev/null
chmod 600 "$OUT"/*.private.jwk.json

echo "== 2. PostgreSQL: the platform, agent and ssf families"
docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
docker run -d --name "$PG_NAME" --label owner=pf-attestation-events -e POSTGRES_PASSWORD="$PG_PASSWORD" \
  -p "127.0.0.1:$PG_PORT:5432" postgres:16-alpine >/dev/null
for _ in $(seq 1 30); do docker exec "$PG_NAME" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 2
printf '%s' "$PG_PASSWORD" > "$WORK/pg.pw"
for family in platform agent ssf; do
  "$JAVA" -jar "$MIGRATE_JAR" migrate --family "$family" --jdbc-url "jdbc:postgresql://localhost:$PG_PORT/postgres" \
    --user postgres --password-file "$WORK/pg.pw" --allow-plaintext | tail -1
done

echo "== 3. The rig, with the attester's transit key and the client whose bundle is ours"
if [[ "${SKIP_UP:-}" != 1 ]]; then
  ( cd "$HERE" && COMPOSE_FILE="$COMPOSE_FILES" TF_VAR_attester_signing_key_ref=attestation-es256 \
      TF_VAR_attester_spiffe_bundle="$(cat "$OUT/svid-bundle.public.jwks.json")" \
      TF_VAR_attester_client_secret="$(openssl rand -hex 16)" ./up.sh )
fi
JDBC="jdbc:postgresql://host.docker.internal:$PG_PORT/postgres"
{ echo "services:"; echo "  pingfederate:"; echo "    environment:"
  for kv in OIDF_AGENT_REGISTRY_MODE=database "OIDF_AGENT_REGISTRY_JDBC_URL=$JDBC" OIDF_AGENT_REGISTRY_JDBC_USERNAME=postgres \
      "OIDF_AGENT_REGISTRY_JDBC_PASSWORD=$PG_PASSWORD" "OIDF_SSF_JDBC_URL=$JDBC" OIDF_SSF_JDBC_USERNAME=postgres \
      "OIDF_SSF_JDBC_PASSWORD=$PG_PASSWORD" OIDF_SSF_STORE_DIALECT=tables "OIDF_SSF_REFUSAL_RECEIVERS=$RECEIVER"; do
    printf '      %s: %s\n' "${kv%%=*}" "$(printf '%s' "${kv#*=}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  done
} > "$WORK/override.yml"
( cd "$HERE" && COMPOSE_FILE="$COMPOSE_FILES:$WORK/override.yml" docker compose up -d --force-recreate --no-deps pingfederate \
    >/dev/null 2>&1 )
ready=0
for _ in $(seq 1 60); do
  if [[ "$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "$PF/.well-known/ssf-configuration")" == 200 ]]; then
    sleep 10; ready=1; break
  fi
  sleep 5
done
if [[ "$ready" != 1 ]]; then
  echo "ERROR: PingFederate did not come back within five minutes; the end of server.log:" >&2
  docker exec "$PF_RIG_NAME" tail -40 "$LOG" >&2 || true
  exit 1
fi
check "the banner names the registry" "database" \
  "$(docker exec "$PF_RIG_NAME" grep -o -m1 -E 'agent registry: database' "$LOG" | sed 's/agent registry: //' || echo missing)"
check "ssf-configuration: all_events_supported lists the four" "4" \
  "$(curl -sk "$PF/.well-known/ssf-configuration" | jq --argjson e "$(printf '%s\n' "${EVENTS[@]}" | jq -R . | jq -s .)" \
     '[.all_events_supported // [] | .[] | select(. as $x | $e | index($x))] | length')"

echo "== 4. The SOC receiver's stream"
STREAM_JSON="$(harness stream "$PF" "$RECEIVER_JWKS" "$RECEIVER" "${EVENTS[@]}")"
STREAM_ID="$(jq -r .stream_id <<<"$STREAM_JSON")"
check "events_delivered names all four (flagged for refusals)" "4" "$(jq '.events_delivered | length' <<<"$STREAM_JSON")"

echo "== 5. Attest, refuse, rotate, attest again"
FIRST="$(harness issue "$PF" "$OUT")"
check "first attestation" "200" "$(jq -r .status <<<"$FIRST")"
AGENT="$(jq -r .agent_id <<<"$FIRST")"; KID1="$(jq -r .kid <<<"$FIRST")"
REFUSED="$(harness issue "$PF" "$OUT" wrong-proof)"
check "a proof signed by another key" "400 invalid_instance_proof" "$(jq -r '"\(.status) \(.error)"' <<<"$REFUSED")"
docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN=rig-root-token "$PF_RIG_NAME-openbao" \
  bao write -f transit/keys/attestation-es256/rotate >/dev/null
echo "   rotated attestation-es256 in OpenBao; waiting ${REFRESH}s for the attester's refresh"
sleep "$REFRESH"
ISSUED=1; KID2="$KID1"; SECOND=""
for _ in 1 2 3; do
  SECOND="$(harness issue "$PF" "$OUT")"
  [[ "$(jq -r .status <<<"$SECOND")" == 200 ]] && ISSUED=$((ISSUED + 1))
  KID2="$(jq -r .kid <<<"$SECOND")"
  [[ "$KID2" != "$KID1" ]] && break
  sleep 5
done
check "a later attestation" "200" "$(jq -r .status <<<"$SECOND")"
check "  the same agent" "$AGENT" "$(jq -r .agent_id <<<"$SECOND")"
check "  signed under a new kid" "yes" "$([[ -n "$KID2" && "$KID2" != "$KID1" ]] && echo yes || echo "no ($KID2)")"

echo "== 6. What the stream received"
sleep 2
harness poll "$PF" "$RECEIVER_JWKS" "$RECEIVER" "$STREAM_ID" > "$OUT/sets.jsonl"
count() { jq -s --arg t "$URN$1" '[.[] | select(.event == $t)] | length' "$OUT/sets.jsonl"; }
check "every SET's signature verified" "true" "$(jq -s 'all(.[]; .verified)' "$OUT/sets.jsonl")"
check "nothing but the four types" "0" "$(jq -s --arg u "$URN" '[.[] | select(.event | startswith($u) | not)] | length' "$OUT/sets.jsonl")"
check "instance-registered: once" "1" "$(count instance-registered)"
check "  about the agent_id" "$AGENT" "$(jq -rs --arg t "${URN}instance-registered" '.[] | select(.event == $t) | .sub_id.id' "$OUT/sets.jsonl")"
check "attestation-issued: once per attestation" "$ISSUED" "$(count attestation-issued)"
check "  first, then renewals" "$(printf 'false'; for _ in $(seq 2 "$ISSUED"); do printf ' true'; done)" \
  "$(jq -rs --arg t "${URN}attestation-issued" '[.[] | select(.event == $t) | .payload.renewal | tostring] | join(" ")' "$OUT/sets.jsonl")"
check "attestation-refused: once" "1" "$(count attestation-refused)"
check "  reason" "proof_rejected" "$(jq -rs --arg t "${URN}attestation-refused" '.[] | select(.event == $t) | .payload.reason' "$OUT/sets.jsonl")"
check "  about the client" "conformance-attester-transit" "$(jq -rs --arg t "${URN}attestation-refused" '.[] | select(.event == $t) | .sub_id.sub' "$OUT/sets.jsonl")"
check "attester-key-rotated: once" "1" "$(count attester-key-rotated)"
check "  previous_kid -> kid" "$KID1 -> $KID2" "$(jq -rs --arg t "${URN}attester-key-rotated" '.[] | select(.event == $t) | "\(.payload.previous_kid) -> \(.payload.kid)"' "$OUT/sets.jsonl")"
docker cp "$PF_RIG_NAME:$LOG" "$OUT/server.log" >/dev/null 2>&1 || true

echo
if [[ "$FAILS" -gt 0 ]]; then
  echo "FAILED: $FAILS check(s); the SETs are in $OUT/sets.jsonl, server.log beside them"
  exit 1
fi
echo "PASSED: each attestation event arrived once per trigger ($(wc -l < "$OUT/sets.jsonl" | tr -d ' ') SETs)"
