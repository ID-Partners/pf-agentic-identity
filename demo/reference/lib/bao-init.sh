#!/bin/sh
# The reference cluster's bao-init job, in the OpenBao image as the host's user: initialise OpenBao with one unseal
# share (first run), unseal it (every run), and give each PingFederate node its secrets and an AppRole that reads
# only them. Example-only: the unseal key and the root token are kept in .local/<name>/bao/init (0600), which a
# deployment would never do.
#
#   /bao      .local/<name>/bao, read-write: init, and <node>/role-id and <node>/secret-id for each node's agent
#   /secrets  .local/<name>/secrets, read-only: the values written to secret/pf/<node>
set -eu
umask 077
export BAO_ADDR=https://openbao:8200 BAO_CACERT=/tls/ca.crt
NODES="console engine-1 engine-2"

# bao status: 0 unsealed, 2 sealed, 1 not answering.
i=0
while :; do
  rc=0; bao status >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || break
  i=$((i + 1)); [ "$i" -lt 60 ] || { echo "bao-init: OpenBao never answered at $BAO_ADDR" >&2; exit 1; }
  sleep 1
done
if ! bao status 2>/dev/null | grep -Eq '^Initialized[[:space:]]+true'; then
  bao operator init -key-shares=1 -key-threshold=1 > /bao/init
  echo "bao-init: initialised OpenBao (one share; the key and root token in .local, example-only)"
fi
key="$(sed -n 's/^Unseal Key 1: //p' /bao/init)"
BAO_TOKEN="$(sed -n 's/^Initial Root Token: //p' /bao/init)"
export BAO_TOKEN
[ -n "$key" ] && [ -n "$BAO_TOKEN" ] || { echo "bao-init: /bao/init holds no unseal key or root token" >&2; exit 1; }
if bao status 2>/dev/null | grep -Eq '^Sealed[[:space:]]+true'; then
  bao operator unseal "$key" >/dev/null
  echo "bao-init: unsealed"
fi

bao secrets list | grep -q '^secret/' || bao secrets enable -path=secret -version=2 kv >/dev/null
bao auth list | grep -q '^approle/' || bao auth enable approle >/dev/null

for node in $NODES; do
  age_key=""
  [ "$node" != console ] || age_key="$(cat /secrets/age.key)"
  bao kv put "secret/pf/$node" \
    redis_password="$(cat /secrets/redis-oidf)" \
    cluster_password="$(cat /secrets/pf-cluster)" \
    ssf_secret_key="$(cat /secrets/ssf-secret-key)" \
    age_key="$age_key" >/dev/null
  printf 'path "secret/data/pf/%s" {\n  capabilities = ["read"]\n}\n' "$node" | bao policy write "pf-$node" - >/dev/null
  bao write "auth/approle/role/pf-$node" token_policies="pf-$node" token_ttl=1h token_max_ttl=24h \
    secret_id_ttl=0 secret_id_num_uses=0 >/dev/null
  mkdir -p "/bao/$node"
  bao read -field=role_id "auth/approle/role/pf-$node/role-id" > "/bao/$node/role-id"
  bao write -f -field=secret_id "auth/approle/role/pf-$node/secret-id" > "/bao/$node/secret-id"
  echo "bao-init: secret/pf/$node and AppRole pf-$node ready"
done
