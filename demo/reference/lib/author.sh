#!/usr/bin/env bash
# Author a reference stack's config archive, as conformance/author.sh, apply.sh and export.sh do for the rig: the
# stack's own PingFederate image with no archive (it carries the PostgreSQL driver the data stores name, which the
# stock image does not, and PingFederate refuses a data store whose driver it cannot load) on the slot's authoring
# ports (localhost only), reference/terraform/<stack> applied to it, its realised
# configuration exported, then encrypted with age to the stack's recipient. Only the ciphertext is kept.
#
#   REF_STACK=single|cluster REF_SLOT=N reference/lib/author.sh
#
# Writes $REF_LOCAL/data.zip.age, 0644 in the 0700 $REF_LOCAL: ciphertext, which PingFederate's uid 9031 must read
# through a bind mount (reference/README.md, "File ownership on Linux"); the identity that opens it stays 0600. Needs $REF_LOCAL/tls (gen-tls.sh, with the pf leaf) and $REF_LOCAL/secrets
# (gen-secrets.sh, with age), which up.sh makes first, and the licence details the rig reads
# ($PING_DEVOPS_CONFIG, default ~/.pingidentity/config), handed to docker as an env file and never read here.
set -euo pipefail
# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
PING_CONFIG="${PING_DEVOPS_CONFIG:-$HOME/.pingidentity/config}"
[[ -f "$PING_CONFIG" ]] || ref_die "no licence details at $PING_CONFIG (conformance/README.md says how to make one)"
S="$REF_LOCAL/secrets"
T="$REF_LOCAL/tls"
for f in "$T/ca.crt" "$S/pf-admin" "$S/pf-runtime" "$S/pf-clients" "$S/smoke-client" "$S/age.pub" "$T/pf.p12" "$T/pf.p12.pass"; do
  [[ -s "$f" ]] || ref_die "missing $f - run up.sh, which generates it"
done

NAME="$REF_NAME-author"
ADMIN="https://127.0.0.1:$PFAI_PORT_AUTHOR_ADMIN"
umask 077
ENV_FILE="$REF_LOCAL/author.env"
printf 'PING_IDENTITY_PASSWORD=%s\n' "$(cat "$S/pf-admin")" > "$ENV_FILE"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -f "$ENV_FILE" "$REF_LOCAL/data.zip" "$REF_LOCAL/data.zip.tmp"; }
trap cleanup EXIT

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --label "owner=$REF_OWNER" --env-file "$PING_CONFIG" --env-file "$ENV_FILE" \
  -e PING_IDENTITY_ACCEPT_EULA=YES -e CREATE_INITIAL_ADMIN_USER=true \
  -p "127.0.0.1:$PFAI_PORT_AUTHOR_RUNTIME:9031" -p "127.0.0.1:$PFAI_PORT_AUTHOR_ADMIN:9999" \
  "$REF_IMAGE" >/dev/null
ref_log "authoring PingFederate $NAME starting (admin $ADMIN)"
code=""
for _ in $(seq 1 72); do
  code="$(curl -sk --max-time 8 -K "$(ref_curl_user administrator "$S/pf-admin")" -H 'X-XSRF-Header: PingFederate' -o /dev/null \
    -w '%{http_code}' "$ADMIN/pf-admin-api/v1/version" || true)"
  [[ "$code" == 200 ]] && break
  sleep 5
done
[[ "$code" == 200 ]] || { docker logs --tail 40 "$NAME" >&2 || true; ref_die "the authoring admin API never answered 200 (last: ${code:-nothing})"; }

TF_DIR="$REF_ROOT/terraform/$REF_STACK"
export TF_VAR_pf_admin_host="$ADMIN"
TF_VAR_pf_admin_password="$(cat "$S/pf-admin")"
TF_VAR_runtime_tls_p12_base64="$(base64 < "$T/pf.p12" | tr -d '\n')"
TF_VAR_runtime_tls_password="$(cat "$T/pf.p12.pass")"
TF_VAR_runtime_role_password="$(cat "$S/pf-runtime")"
TF_VAR_clients_role_password="$(cat "$S/pf-clients")"
TF_VAR_smoke_client_secret="$(cat "$S/smoke-client")"
export TF_VAR_pf_admin_password TF_VAR_runtime_tls_p12_base64 TF_VAR_runtime_tls_password TF_VAR_runtime_role_password
export TF_VAR_clients_role_password TF_VAR_smoke_client_secret
TF_VAR_stack_ca_pem="$(cat "$T/ca.crt")"
export TF_VAR_stack_ca_pem
export TF_VAR_pf_base_url="$REF_ISSUER" TF_VAR_pf_product_version="${PF_TERRAFORM_PRODUCT_VERSION:?}"
# A fresh authoring server each time, so a fresh state: the state is kept beside the archive, never in the tree.
STATE="$REF_LOCAL/terraform.tfstate"
rm -f "$STATE" "$STATE.backup"
[[ -d "$TF_DIR/.terraform" ]] || terraform -chdir="$TF_DIR" init -input=false -lockfile=readonly >/dev/null
# One resource at a time, as the rig's apply: in parallel PingFederate has read back settings as their defaults.
terraform -chdir="$TF_DIR" apply -input=false -auto-approve -parallelism=1 -state="$STATE" >"$REF_LOCAL/terraform.log" 2>&1 \
  || { tail -30 "$REF_LOCAL/terraform.log" >&2; ref_die "terraform apply failed ($REF_LOCAL/terraform.log)"; }
ref_log "applied reference/terraform/$REF_STACK"

code="$(curl -sk --max-time 180 -K "$(ref_curl_user administrator "$S/pf-admin")" -H 'X-XSRF-Header: PingFederate' \
  -o "$REF_LOCAL/data.zip.tmp" -w '%{http_code}' "$ADMIN/pf-admin-api/v1/configArchive/export")"
[[ "$code" == 200 ]] || ref_die "the archive export answered $code"
listing="$(unzip -l "$REF_LOCAL/data.zip.tmp")"
for member in pf.jwk pingfederate-system-keys.xml; do
  grep -q " $member\$" <<<"$listing" || ref_die "the exported archive has no $member"
done
mv "$REF_LOCAL/data.zip.tmp" "$REF_LOCAL/data.zip"
# age runs in the stack's PingFederate image, which carries it; the host needs none.
docker run --rm -i --entrypoint /usr/local/bin/age "$REF_IMAGE" -r "$(cat "$S/age.pub")" \
  < "$REF_LOCAL/data.zip" > "$REF_LOCAL/data.zip.age.tmp"
head -c 21 "$REF_LOCAL/data.zip.age.tmp" | grep -q '^age-encryption.org/v1' || ref_die "age produced no ciphertext"
# 0644, not this script's umask's 0600: PingFederate reads it as uid 9031, which on Linux is not the owner (Docker
# Desktop's file sharing hid that until C-7 ran on a Linux runner). It is age ciphertext; the identity is not here.
chmod 644 "$REF_LOCAL/data.zip.age.tmp"
mv "$REF_LOCAL/data.zip.age.tmp" "$REF_LOCAL/data.zip.age"
ref_log "exported and encrypted $REF_LOCAL/data.zip.age ($(wc -c < "$REF_LOCAL/data.zip.age" | tr -d ' ') bytes); the plaintext is gone"
