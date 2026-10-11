#!/usr/bin/env bash
# A signing-key rotation without a restart, on this rig (plan item S6b, F-0011): PingFederate is given a new static
# ES256 key, and the federation publishes it at once and signs with it only after the activation delay - OpenID
# Federation 1.0 section 11.2: "Add the new keys to the jwks representing the Trust Anchor's signing keys in its
# Entity Configuration." ... "Keep signing the Entity Configuration and the Entity Statements using the old keys for a
# long enough time period to allow all Subordinates to have obtained the new keys." ... "Switch to signing with the
# new keys." ... "After a reasonable time period, remove the old keys."
#
# What it does:
#   1. starts a throwaway PostgreSQL (PG_NAME, PG_PORT) and migrates its platform and federation families with
#      tools/db-migrate's oidf-db-migrate.jar (built beforehand), as the start-up schema check wants - the
#      authority's database and the leases' (jdbc lease backend, so the key observer's writes are fenced in that
#      database)
#   2. boots the rig (up.sh, PF_PROFILE=federation) on its own slot, unless SKIP_UP=1, then recreates the container
#      once with ES256, a 5 s key refresh, key history on, the delay (DELAY, default 60 s) and one Trust Mark type
#   3. grants that Trust Mark to the rig itself (a row in trust_mark_grant), generates two P-256 key pairs and an RSA
#      one, and makes the first P-256 key PingFederate's static active key; waits until the federation signs with it
#   4. the measured rotation: makes the second P-256 key active (the first becomes PingFederate's previous key) through
#      PUT /pf-admin-api/v1/keyPairs/oauthOpenIdConnect, then prints, timestamped: the new kid pending in the Entity
#      Configuration's jwks while the configuration and a Trust Mark still carry the old kid; then, after the delay and
#      a tick, both carrying the new kid, the old kid in jwks and at /federation/historical_keys, the old mark's
#      status still active; and the container's StartedAt unchanged (no restart)
#   5. takes the rig and the database down (KEEP_RIG=1 keeps both)
#
# The explicit registration response is signed by the same FederationKeys signer as the Entity Configuration
# (RegistrationService), and is not driven here: registering needs a relying party with a trust chain.
#
# Env: PF_RIG_NAME (default pf-p4-rotation), PF_PORT_HTTPS/HTTP/ADMIN (57631/57680/57699), PF_AUTHOR_ADMIN_PORT and
# PF_AUTHOR_RUNTIME_PORT (57599/57531), PG_NAME (<rig>-pg), PG_PORT (57362), DELAY (60), SKIP_UP=1, SKIP_AUTHOR=1,
# SKIP_BUILD=1, KEEP_RIG=1, OUT_DIR (conformance/.key-rotation, git-ignored).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=layout.sh
. "$HERE/layout.sh"
export PF_RIG_NAME="${PF_RIG_NAME:-pf-p4-rotation}"
export PF_PORT_HTTPS="${PF_PORT_HTTPS:-57631}" PF_PORT_HTTP="${PF_PORT_HTTP:-57680}" PF_PORT_ADMIN="${PF_PORT_ADMIN:-57699}"
export PF_AUTHOR_ADMIN_PORT="${PF_AUTHOR_ADMIN_PORT:-57599}" PF_AUTHOR_RUNTIME_PORT="${PF_AUTHOR_RUNTIME_PORT:-57531}"
export PF_AUTHOR_ENV="${PF_AUTHOR_ENV:-$HERE/.author.env}"
export PF_PROFILE=federation
if [[ "$PF_RIG_NAME" == pf-agentic-identity ]]; then
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-conformance}"
else
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$PF_RIG_NAME}"
fi
PG_NAME="${PG_NAME:-$PF_RIG_NAME-pg}"
PG_PORT="${PG_PORT:-57362}"
PG_PASSWORD="rotation-$(openssl rand -hex 8)"
DELAY="${DELAY:-60}"
TICK=30
OUT="${OUT_DIR:-$HERE/.key-rotation}"
LOCAL="https://localhost:$PF_PORT_HTTPS"
ADMIN="https://localhost:$PF_PORT_ADMIN/pf-admin-api/v1"
MIGRATE_JAR="$REPO/tools/db-migrate/target/oidf-db-migrate.jar"

for tool in docker curl jq node openssl java; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required" >&2; exit 1; }
done
[[ -f "$MIGRATE_JAR" ]] || { echo "ERROR: no $MIGRATE_JAR - run mvn -pl tools/db-migrate -am package first" >&2; exit 1; }
mkdir -p "$OUT"

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "[$(stamp)] $*" | tee -a "$OUT/summary.txt"; }
cleanup() {
  docker exec "$PF_RIG_NAME" cat /opt/out/instance/log/server.log > "$OUT/server.log" 2>/dev/null || true
  if [[ "${KEEP_RIG:-0}" != 1 ]]; then
    ( cd "$HERE" && docker compose down >/dev/null 2>&1 ) || true
    docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
  fi
}
on_exit() {
  local rc=$?
  cleanup
  exit "$rc"
}
trap on_exit EXIT
: > "$OUT/summary.txt"

# ── 1. the database ──────────────────────────────────────────────────────────────────────────────
if [[ "${SKIP_UP:-0}" != 1 ]]; then
  docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$PG_NAME" --label owner=prod-phase4 -e POSTGRES_PASSWORD="$PG_PASSWORD" -p "$PG_PORT:5432" \
    postgres:16-alpine >/dev/null
  for _ in $(seq 1 30); do docker exec "$PG_NAME" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
  PW_FILE="$(mktemp)"; printf '%s' "$PG_PASSWORD" > "$PW_FILE"
  for family in platform federation; do
    java -jar "$MIGRATE_JAR" migrate --family "$family" --allow-plaintext --user postgres --password-file "$PW_FILE" \
      --jdbc-url "jdbc:postgresql://localhost:$PG_PORT/postgres" >/dev/null
  done
  rm -f "$PW_FILE"
  say "migrated: $(docker exec "$PG_NAME" psql -qtA -U postgres -d postgres \
    -c "SELECT string_agg(family || ' V' || version, ', ' ORDER BY family, script) FROM oidf_schema_history")"
else
  PG_PASSWORD="$(docker exec "$PG_NAME" printenv POSTGRES_PASSWORD)"
fi
sql() { docker exec -i "$PG_NAME" psql -qtA -v ON_ERROR_STOP=1 -U postgres -d postgres -c "$1"; }

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────
# verify <jws> <jwks-json>: the kid, and whether the signature verifies under the JWK that kid names in the set
verify() {
  node -e '
    const crypto = require("node:crypto");
    const [jws, jwksText] = process.argv.slice(1);
    const [h, p, s] = jws.split(".");
    const header = JSON.parse(Buffer.from(h, "base64url"));
    const jwk = JSON.parse(jwksText).keys.find((k) => k.kid === header.kid);
    const ok = !!jwk && crypto.verify("sha256", Buffer.from(h + "." + p), { key: crypto.createPublicKey({ key: jwk, format: "jwk" }),
      dsaEncoding: "ieee-p1363" }, Buffer.from(s, "base64url"));
    console.log(header.kid + (ok ? " verified" : " NOT VERIFIED"));' "$1" "$2"
}
payload() { cut -d. -f2 <<<"$1" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(Buffer.from(d.trim(),"base64url").toString()))'; }
ec() { curl -sk "$LOCAL/.well-known/openid-federation"; }
ec_kid() { node -e 'console.log(JSON.parse(Buffer.from(process.argv[1].split(".")[0],"base64url")).kid)' "$1"; }
ec_jwks() { payload "$1" | jq -c .jwks; }
mark() { curl -sk -G --data-urlencode "trust_mark_type=$MARK_TYPE" --data-urlencode "sub=$ENTITY" "$LOCAL/federation/trust_mark"; }
mark_status() {  # the status the Trust Mark Status endpoint gives <mark>
  local response; response="$(curl -sk --data-urlencode "trust_mark=$1" "$LOCAL/federation/trust_mark_status")"
  payload "$response" | jq -r .status
}
snapshot() {  # snapshot <label>: what the federation signs with and publishes now
  local conf jwks m; conf="$(ec)"; jwks="$(ec_jwks "$conf")"; m="$(mark)"
  say "$1: Entity Configuration $(verify "$conf" "$jwks"); jwks $(jq -c '[.keys[].kid]' <<<"$jwks"); Trust Mark $(verify "$m" "$jwks");" \
    "active $(sql "SELECT kid FROM federation_key_current"); observed $(sql "SELECT string_agg(kid || '@' || to_char(first_seen_at, 'HH24:MI:SS'), ' ' ORDER BY first_seen_at) FROM federation_key_observed")"
}
generate() {  # generate <EC|RSA> <size> <name> -> the new signing key pair's id
  pf POST /keyPairs/signing/generate "{\"commonName\":\"$3\",\"organization\":\"pf-agentic-identity rig\",\"country\":\"AU\",\"validDays\":30,\"keyAlgorithm\":\"$1\",\"keySize\":$2}" >/dev/null
  need 201 "generating the $3 key pair"
  jq -r .id <<<"$PF_BODY"
}
use_static() {  # use_static <active p256 id> <active kid> [<previous p256 id> <previous kid>]
  local settings; pf GET /keyPairs/oauthOpenIdConnect >/dev/null; need 200 "reading the OAuth/OIDC keys"; settings="$PF_BODY"
  settings="$(jq -c --arg a "$1" --arg ak "$2" --arg p "${3:-}" --arg pk "${4:-}" --arg r "$RSA" '
    .staticJwksEnabled = true
    | .rsaActiveCertRef = {id: $r} | .rsaActiveKeyId = "rotation-rsa"
    | .p256ActiveCertRef = {id: $a} | .p256ActiveKeyId = $ak
    | if $p == "" then del(.p256PreviousCertRef, .p256PreviousKeyId) else .p256PreviousCertRef = {id: $p} | .p256PreviousKeyId = $pk end' <<<"$settings")"
  pf PUT /keyPairs/oauthOpenIdConnect "$settings" >/dev/null; need 200 "making $2 PingFederate's active P-256 key"
}
wait_until() {  # wait_until <seconds> <description> <command...>
  local limit="$1" what="$2"; shift 2
  local start; start="$(date +%s)"
  until "$@"; do
    (( $(date +%s) - start < limit )) || { say "ERROR: $what did not happen within ${limit}s"; return 1; }
    sleep 3
  done
}
signs_with() { [[ "$(ec_kid "$(ec)")" == "$1" ]]; }
active_is() { [[ "$(sql "SELECT kid FROM federation_key_current")" == "$1" ]]; }
settled_on() { active_is "$1" && signs_with "$1"; }  # the cluster's active key, not a node's fallback to PingFederate's
publishes() { ec_jwks "$(ec)" | jq -e --arg k "$1" '[.keys[].kid] | index($k)' >/dev/null; }

# ── 2. the rig ───────────────────────────────────────────────────────────────────────────────────
if [[ "${SKIP_UP:-0}" != 1 ]]; then
  ( cd "$HERE" && ./up.sh )
fi
ENTITY="$(payload "$(ec)" | jq -r .iss || true)"
[[ -n "$ENTITY" && "$ENTITY" != null ]] || ENTITY="$LOCAL"
MARK_TYPE="$ENTITY/marks/rotation-probe"
JDBC="jdbc:postgresql://host.docker.internal:$PG_PORT/postgres"
{
  echo "OIDF_FEDERATION_SIGNING_ALG=ES256"
  echo "OIDF_FEDERATION_KEY_REFRESH_SECONDS=5"
  echo "OIDF_FEDERATION_HISTORICAL_KEYS=true"
  echo "OIDF_FEDERATION_KEY_ACTIVATION_DELAY_SECONDS=$DELAY"
  echo "OIDF_AUTHORITY_JDBC_URL=$JDBC"
  echo "OIDF_AUTHORITY_JDBC_USERNAME=postgres"
  echo "OIDF_AUTHORITY_JDBC_PASSWORD=$PG_PASSWORD"
  echo "OIDF_LEASE_BACKEND=jdbc"
  echo "OIDF_LEASE_JDBC_URL=$JDBC"
  echo "OIDF_LEASE_JDBC_USERNAME=postgres"
  echo "OIDF_LEASE_JDBC_PASSWORD=$PG_PASSWORD"
  echo "OIDF_FEDERATION_TRUST_MARK_TYPES={\"$MARK_TYPE\":{\"lifetime_seconds\":3600,\"subjects\":\"any\"}}"
} >> "$HERE/.context/vars.env"
( cd "$HERE" && docker compose up -d --force-recreate --no-build >/dev/null 2>&1 )
for _ in $(seq 1 90); do
  curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "$LOCAL/.well-known/openid-federation" | grep -q 200 && break
  sleep 4
done
STARTED="$(docker inspect -f '{{.State.StartedAt}}' "$PF_RIG_NAME")"
say "rig up on $LOCAL as $ENTITY, delay ${DELAY}s, container started $STARTED"

PW="$(sed -n 's/^PING_IDENTITY_PASSWORD=//p' "$PF_AUTHOR_ENV")"
[[ -n "$PW" ]] || { echo "ERROR: no PING_IDENTITY_PASSWORD in $PF_AUTHOR_ENV" >&2; exit 1; }
pf() {  # pf <method> <path> [json-body] -> body; the status is in PF_STATUS
  local method="$1" path="$2" body="${3:-}" tmp; tmp="$(mktemp)"
  if [[ -n "$body" ]]; then
    PF_STATUS="$(curl -sk -o "$tmp" -w '%{http_code}' -X "$method" -u "administrator:$PW" -H 'X-XSRF-Header: PingFederate' \
      -H 'Content-Type: application/json' -d "$body" "$ADMIN$path")"
  else
    PF_STATUS="$(curl -sk -o "$tmp" -w '%{http_code}' -X "$method" -u "administrator:$PW" -H 'X-XSRF-Header: PingFederate' "$ADMIN$path")"
  fi
  PF_BODY="$(cat "$tmp")"; rm -f "$tmp"
  printf '%s' "$PF_BODY"
}
need() { [[ "$PF_STATUS" == "$1" ]] || { echo "ERROR: $2 answered HTTP $PF_STATUS (wanted $1): $(head -c 600 <<<"$PF_BODY")" >&2; exit 1; }; }

# ── 3. a first static key, and the Trust Mark grant ──────────────────────────────────────────────
sql "INSERT INTO trust_mark_grant (trust_mark_type, subject, status, granted_at, actor) VALUES ('$MARK_TYPE', '$ENTITY', 'ACTIVE', now(), 'rig')
     ON CONFLICT (trust_mark_type, subject) DO NOTHING" >/dev/null
RUN="$(date +%s)"
RSA="$(generate RSA 2048 "rotation-rsa-$RUN")"
KEY_A="$(generate EC 256 "rotation-a-$RUN")"; KID_A="rotation-a-$RUN"
KEY_B="$(generate EC 256 "rotation-b-$RUN")"; KID_B="rotation-b-$RUN"
use_static "$KEY_A" "$KID_A"
say "PingFederate signs with static key $KID_A"
# Leaving dynamic keys drops them from PingFederate (static keys replace every key), so the node signs with $KID_A at
# once (federation.key.activation_skipped); the observer makes it the cluster's active key after the delay.
wait_until $(( DELAY + 3 * TICK )) "$KID_A becoming the active key" settled_on "$KID_A"
snapshot "before the rotation"
MARK_BEFORE="$(mark)"

# ── 4. the measured rotation ─────────────────────────────────────────────────────────────────────
use_static "$KEY_B" "$KID_B" "$KEY_A" "$KID_A"
ROTATED="$(date +%s)"
say "PingFederate signs with $KID_B now, $KID_A its previous key (PUT /keyPairs/oauthOpenIdConnect, no restart)"
wait_until $(( 2 * TICK )) "$KID_B in the Entity Configuration's jwks" publishes "$KID_B"
say "$KID_B published after $(( $(date +%s) - ROTATED ))s"
snapshot "pending"
signs_with "$KID_A" || { say "ERROR: the federation signs with $KID_B before the delay"; exit 1; }
wait_until $(( DELAY + 3 * TICK )) "the federation signing with $KID_B" settled_on "$KID_B"
say "the federation signs with $KID_B after $(( $(date +%s) - ROTATED ))s (delay ${DELAY}s, tick ${TICK}s)"
snapshot "after the delay"
if publishes "$KID_A"; then say "$KID_A stays in the jwks for its grace"; else say "ERROR: $KID_A left the jwks"; exit 1; fi
curl -sk "$LOCAL/federation/historical_keys" > "$OUT/historical_keys.jwt"
say "historical_keys: $(payload "$(cat "$OUT/historical_keys.jwt")" | jq -c '[.keys[] | {kid, exp}]')"
say "the mark minted under $KID_A: $(mark_status "$MARK_BEFORE"); a mark now: $(ec_kid "$(mark)")"
NOW_STARTED="$(docker inspect -f '{{.State.StartedAt}}' "$PF_RIG_NAME")"
if [[ "$NOW_STARTED" == "$STARTED" ]]; then say "no restart: StartedAt $NOW_STARTED"; else say "ERROR: the container restarted ($STARTED -> $NOW_STARTED)"; exit 1; fi
docker exec "$PF_RIG_NAME" grep -E 'federation\.key\.(observed|activated|changed|retired)' /opt/out/instance/log/server.log \
  | sed 's/^.*event=/event=/' | tee -a "$OUT/summary.txt" || true
say "done on PingFederate $(pf GET /version | jq -r .version)"
