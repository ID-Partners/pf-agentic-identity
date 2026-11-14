#!/usr/bin/env bash
# Brings up the rig's SPIRE overlay (conformance/docker-compose.spire.yml) from nothing and proves it end to end:
#
#   1. SPIRE Server starts with the reference policy; its trust bundle and a join token go to the agent.
#   2. Two registration entries are created for one SPIFFE id with SPIRE's own CLI, inside the server's container.
#   3. The reader, from its image, answers GET /v1/entries for that id over mutual TLS inside the compose network:
#      200 with both entries, as the contract (ReaderContract) shapes them. /health is 200. A client certificate from
#      the same authority whose key is not pinned gets 403 forbidden_client; no client certificate, no handshake.
#   4. The workload fetches a JWT-SVID from the agent for the attester's issuer: sub is the SPIFFE id, aud the
#      audience, iss the server's jwt_issuer.
#   5. The policy: a SPIRE CLI binary at another path, run from the reader's image in the server's PID namespace
#      with the reader's user and group, may count entries and may not create one (PermissionDenied).
#      SPIRE_RIG_POLICY=off runs the server without the policy (spire/server-open.conf) and skips this step.
#
#   conformance/spire/smoke.sh            all of that, then down
#   conformance/spire/smoke.sh --keep     all of that, and leave it running
#   conformance/spire/smoke.sh --down     stop and remove the overlay's services and volumes, nothing else
#
# The reader's image is built from services/spire-entry-reader (run `mvn -pl services/spire-entry-reader -am
# -DskipTests package` first) unless SPIRE_READER_IMAGE names one already built, as CI does. PF_RIG_NAME and
# COMPOSE_PROJECT_NAME follow up.sh; SPIRE_RIG_STATE moves the state directory (default conformance/.spire);
# SPIRE_RIG_OWNER is the owner label on every container. It publishes no port on the host and touches no other
# project's containers.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conf="$(cd "$here/.." && pwd)"
export PF_RIG_NAME="${PF_RIG_NAME:-pf-agentic-identity}"
if [[ "$PF_RIG_NAME" == pf-agentic-identity ]]; then
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-conformance}"
else
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$PF_RIG_NAME}"
fi
mkdir -p "${SPIRE_RIG_STATE:-$conf/.spire}"
SPIRE_RIG_STATE="$(cd "${SPIRE_RIG_STATE:-$conf/.spire}" && pwd)"
export SPIRE_RIG_STATE
export SPIRE_RIG_OWNER="${SPIRE_RIG_OWNER:-pf-agentic-identity-rig}"
export SPIRE_RIG_AUDIENCE="${SPIRE_RIG_AUDIENCE:-https://localhost:9031}"
export SPIRE_READER_IMAGE="${SPIRE_READER_IMAGE:-}"
case "${SPIRE_RIG_POLICY:-on}" in
  on) export SPIRE_RIG_SERVER_CONF=server.conf ;;
  off) export SPIRE_RIG_SERVER_CONF=server-open.conf ;;
  *) printf 'smoke.sh: FAILED: SPIRE_RIG_POLICY is %s (expected on or off)\n' "$SPIRE_RIG_POLICY" >&2; exit 1 ;;
esac
build_reader=0
if [[ -z "$SPIRE_READER_IMAGE" ]]; then
  SPIRE_READER_IMAGE="$PF_RIG_NAME/spire-entry-reader:local"
  build_reader=1
fi

# 8.16.0, the multi-arch index digest, read 2026-10-09: the client inside the compose network.
CURL=curlimages/curl:8.16.0@sha256:463eaf6072688fe96ac64fa623fe73e1dbe25d8ad6c34404a669ad3ce1f104b6
TD=rig.example
AGENT_ID="spiffe://$TD/agent/rig"
WORKLOAD_ID="spiffe://$TD/workload/attester-client"
CLI=/opt/spire/bin/spire-server
SERVICES=(workload spire-reader spire-agent spire-server)
VOLUMES=(spire-server-socket spire-server-data spire-agent-socket spire-agent-data)

compose() { docker compose --project-directory "$conf" -f "$conf/docker-compose.spire.yml" "$@"; }
server_cli() { compose exec -T spire-server "$CLI" "$@"; }
say() { printf 'smoke.sh: %s\n' "$*"; }
fail() { printf 'smoke.sh: FAILED: %s\n' "$*" >&2; exit 1; }

down() {
  compose rm --force --stop --volumes "${SERVICES[@]}" > /dev/null 2>&1 || true
  for v in "${VOLUMES[@]}"; do docker volume rm -f "${COMPOSE_PROJECT_NAME}_$v" > /dev/null 2>&1 || true; done
  # The network goes only when no container, stopped or running, still names it: the rig's PingFederate, say, stopped
  # and later started again, needs it. docker network rm refuses only while a running container is attached.
  local net="${COMPOSE_PROJECT_NAME}_default"
  if [[ -z "$(docker ps -aq --filter "network=$net" 2> /dev/null)" ]]; then
    docker network rm "$net" > /dev/null 2>&1 || true
  fi
}

case "${1:-}" in
  --down) down; say "the SPIRE overlay of $COMPOSE_PROJECT_NAME is down"; exit 0 ;;
  --keep) keep=1 ;;
  "") keep=0 ;;
  *) fail "unknown argument $1 (expected --keep or --down)" ;;
esac

on_exit() {
  local status=$?
  if (( status != 0 )); then
    compose logs --no-color --tail 60 spire-server spire-agent spire-reader >&2 || true
  fi
  if (( status != 0 || keep == 0 )); then down; fi
}
trap on_exit EXIT

# curl_reader CLIENT PATH: the reader's answer to GET PATH with the client certificate client/CLIENT (none if CLIENT is
# empty), as the body and then the status on a line of its own; curl's own exit status when there is no answer.
curl_reader() {
  local cert=()
  if [[ -n "$1" ]]; then cert=(--cert "/c/$1.crt" --key "/c/$1.key"); fi
  docker run --rm --label "owner=$SPIRE_RIG_OWNER" --network "${COMPOSE_PROJECT_NAME}_default" \
    -v "$SPIRE_RIG_STATE/client:/c:ro" "$CURL" -sS --max-time 10 --cacert /c/server-ca.crt "${cert[@]}" \
    -w '\n%{http_code}' "https://spire-reader:8443$2"
}

down
"$here/gen-certs.sh" "$SPIRE_RIG_STATE"

if (( build_reader )); then
  ls "$conf"/../services/spire-entry-reader/target/spire-entry-reader-*.jar > /dev/null 2>&1 \
    || fail "no reader jar: run mvn -pl services/spire-entry-reader -am -DskipTests package first"
  compose build spire-reader
fi

say "SPIRE Server"
compose up -d --wait spire-server
mkdir -p "$SPIRE_RIG_STATE/agent"
chmod 0755 "$SPIRE_RIG_STATE/agent"
server_cli bundle show > "$SPIRE_RIG_STATE/agent/bundle.pem"
token="$(server_cli token generate -spiffeID "$AGENT_ID" -ttl 600 | sed -n 's/^Token: //p')"
[[ -n "$token" ]] || fail "SPIRE Server gave no join token"
cat > "$SPIRE_RIG_STATE/agent/agent.conf" <<EOF
agent {
  data_dir = "/var/lib/spire/agent"
  log_level = "INFO"
  server_address = "spire-server"
  server_port = "8081"
  socket_path = "/tmp/spire-agent/public/api.sock"
  trust_bundle_path = "/opt/spire/conf/agent/bundle.pem"
  trust_domain = "$TD"
  join_token = "$token"
}
plugins {
  NodeAttestor "join_token" {
    plugin_data {}
  }
  KeyManager "memory" {
    plugin_data {}
  }
  WorkloadAttestor "unix" {
    plugin_data {}
  }
}
EOF
chmod 0644 "$SPIRE_RIG_STATE/agent/"*

say "two entries for $WORKLOAD_ID, with SPIRE's CLI"
server_cli entry create -spiffeID "$WORKLOAD_ID" -parentID "$AGENT_ID" -selector unix:uid:1001 > /dev/null
server_cli entry create -spiffeID "$WORKLOAD_ID" -parentID "$AGENT_ID" -selector unix:uid:1001 -selector unix:gid:1001 > /dev/null

say "the agent and the reader"
compose up -d --wait spire-agent spire-reader

health=""
for _ in $(seq 1 60); do
  health="$(curl_reader smoke /health 2>&1 || true)"
  [[ "$(tail -n1 <<< "$health")" == 200 ]] && break
  sleep 1
done
[[ "$(tail -n1 <<< "$health")" == 200 ]] || fail "the reader's /health did not answer 200: $health"
say "/health: 200"

query="/v1/entries?spiffe_id=$WORKLOAD_ID"
answer="$(curl_reader smoke "$query")"
ANSWER="$answer" WORKLOAD_ID="$WORKLOAD_ID" AGENT_ID="$AGENT_ID" TD="$TD" python3 - <<'PY'
import json, os, sys
body, _, status = os.environ["ANSWER"].rpartition("\n")
if status != "200":
    sys.exit(f"smoke.sh: FAILED: /v1/entries answered {status}: {body}")
doc = json.loads(body)
want_keys = ["count", "entries", "read_at", "spiffe_id", "trust_domain"]
problems = []
if sorted(doc) != want_keys:
    problems.append(f"members {sorted(doc)}, not {want_keys}")
if doc.get("spiffe_id") != os.environ["WORKLOAD_ID"] or doc.get("trust_domain") != os.environ["TD"]:
    problems.append(f"spiffe_id {doc.get('spiffe_id')!r}, trust_domain {doc.get('trust_domain')!r}")
entries = doc.get("entries") or []
if doc.get("count") != 2 or len(entries) != 2:
    problems.append(f"count {doc.get('count')} with {len(entries)} entries, not 2")
entry_keys = ["downstream", "expires_at", "id", "parent_id", "revision_number", "selectors"]
for e in entries:
    if sorted(e) != entry_keys:
        problems.append(f"entry members {sorted(e)}, not {entry_keys}")
    if e.get("parent_id") != os.environ["AGENT_ID"]:
        problems.append(f"entry parent_id {e.get('parent_id')!r}")
got = sorted(sorted((s["type"], s["value"]) for s in e.get("selectors", [])) for e in entries)
want = [[("unix", "gid:1001"), ("unix", "uid:1001")], [("unix", "uid:1001")]]
if got != want:
    problems.append(f"selectors {got}, not {want}")
if problems:
    sys.exit("smoke.sh: FAILED: " + "; ".join(problems) + f"\n{body}")
print(f"smoke.sh: /v1/entries: 200, two entries for {doc['spiffe_id']}: " + json.dumps(got))
PY

stranger="$(curl_reader stranger "$query" || true)"
[[ "$(tail -n1 <<< "$stranger")" == 403 && "$stranger" == *forbidden_client* ]] \
  || fail "a client whose key is not pinned was not refused 403 forbidden_client: $stranger"
say "a client certificate whose key is not pinned: 403 forbidden_client"
if anonymous="$(curl_reader "" "$query" 2>&1)" && [[ "$(tail -n1 <<< "$anonymous")" != 000 ]]; then
  fail "a client with no certificate got an answer: $anonymous"
fi
say "no client certificate: no answer"

say "the workload's JWT-SVID, audience $SPIRE_RIG_AUDIENCE"
svid=""
for _ in $(seq 1 30); do
  if svid="$(compose run --rm --no-deps workload 2>/dev/null)" && [[ "$svid" == *'"svids"'* || "$svid" == *'"svid"'* ]]; then
    break
  fi
  svid=""
  sleep 2
done
[[ -n "$svid" ]] || fail "the workload got no JWT-SVID from the agent"
SVID="$svid" WORKLOAD_ID="$WORKLOAD_ID" AUD="$SPIRE_RIG_AUDIENCE" python3 - <<'PY'
import base64, json, os, re, sys
tokens = re.findall(r'"svid"\s*:\s*"([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)"', os.environ["SVID"])
if not tokens:
    sys.exit("smoke.sh: FAILED: no JWT in the workload's answer: " + os.environ["SVID"][:500])
payload = tokens[0].split(".")[1]
claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
aud = claims.get("aud")
aud = aud if isinstance(aud, list) else [aud]
problems = []
if claims.get("sub") != os.environ["WORKLOAD_ID"]:
    problems.append(f"sub {claims.get('sub')!r}")
if aud != [os.environ["AUD"]]:
    problems.append(f"aud {aud!r}")
if claims.get("iss") != "https://spire.rig.example":
    problems.append(f"iss {claims.get('iss')!r}")
if problems:
    sys.exit("smoke.sh: FAILED: the JWT-SVID's " + "; ".join(problems))
print(f"smoke.sh: JWT-SVID: sub {claims['sub']}, aud {aud}, iss {claims['iss']}, lifetime {claims['exp'] - claims['iat']} s")
PY

if [[ "$SPIRE_RIG_SERVER_CONF" == server-open.conf ]]; then
  say "the policy: off (SPIRE_RIG_POLICY=off), not checked"
else
  say "the policy: a SPIRE CLI at another path, from the reader's image, in the server's PID namespace"
  server="$(compose ps -q spire-server)"
  mkdir -p "$SPIRE_RIG_STATE/bin"
  docker cp "$server:$CLI" "$SPIRE_RIG_STATE/bin/not-the-cli" > /dev/null
  chmod 0755 "$SPIRE_RIG_STATE/bin" "$SPIRE_RIG_STATE/bin/not-the-cli"
  elsewhere=(docker run --rm --label "owner=$SPIRE_RIG_OWNER" --network none --pid "container:$server" --user 65532:1000
    --read-only -v "${COMPOSE_PROJECT_NAME}_spire-server-socket:/s:ro" -v "$SPIRE_RIG_STATE/bin:/elsewhere:ro"
    --entrypoint /elsewhere/not-the-cli "$SPIRE_READER_IMAGE")
  count="$("${elsewhere[@]}" entry count -socketPath /s/api.sock 2>&1)" || fail "a read from the reader's image was refused: $count"
  if write="$("${elsewhere[@]}" entry create -socketPath /s/api.sock -spiffeID "spiffe://$TD/smuggled" \
        -parentID "$AGENT_ID" -selector unix:uid:4242 2>&1)"; then
    fail "a write from the reader's image was allowed: $write"
  fi
  [[ "$write" == *PermissionDenied* ]] || fail "a write from the reader's image failed, but not with PermissionDenied: $write"
  say "entry count: allowed ($count); entry create: PermissionDenied"
fi

if (( keep )); then
  say "passed; left running as project $COMPOSE_PROJECT_NAME (conformance/spire/smoke.sh --down stops it)"
else
  say "passed"
fi
