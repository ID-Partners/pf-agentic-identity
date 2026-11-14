#!/usr/bin/env bash
# Author a reference stack's config archive: profiles/minimal.yaml through tools/profile.py author, which does for any
# profile what the rig does - the stack's own PingFederate image with no archive (it carries the PostgreSQL driver the
# data stores name, which the stock image does not, and PingFederate refuses a data store whose driver it cannot load)
# on the slot's authoring ports (localhost only), deploy/terraform/agentic-idp applied to it with fresh state, its
# realised configuration exported, then encrypted with age to the stack's recipient. Only the ciphertext is kept. The
# cluster keeps PingFederate's OAuth clients in PostgreSQL too (pf.client_storage=jdbc); that is the one difference.
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
python3 -c 'import yaml' 2>/dev/null \
  || ref_die "tools/profile.py reads the profiles with PyYAML: python3 -m pip install --require-hashes -r $PFAI_ROOT/tools/profile/requirements.txt"
S="$REF_LOCAL/secrets"
T="$REF_LOCAL/tls"
for f in "$T/ca.crt" "$S/pf-admin" "$S/pf-runtime" "$S/pf-clients" "$S/smoke-client" "$S/age.pub" "$T/pf.p12" "$T/pf.p12.pass"; do
  [[ -s "$f" ]] || ref_die "missing $f - run up.sh, which generates it"
done

NAME="$REF_NAME-author"
OUT="$REF_LOCAL/profile"
umask 077
# The admin password (the archive's) and var.secrets' members, as the files tools/profile.py reads; gone on exit.
ENV_FILE="$REF_LOCAL/author.env"
SECRETS_FILE="$REF_LOCAL/author-secrets.env"
printf 'PING_IDENTITY_PASSWORD=%s\n' "$(cat "$S/pf-admin")" > "$ENV_FILE"
{
  printf 'runtime_tls_password=%s\n' "$(cat "$T/pf.p12.pass")"
  printf 'postgres_runtime_password=%s\n' "$(cat "$S/pf-runtime")"
  printf 'postgres_clients_password=%s\n' "$(cat "$S/pf-clients")"
  printf 'smoke_client_secret=%s\n' "$(cat "$S/smoke-client")"
} > "$SECRETS_FILE"
cleanup() { rm -f "$ENV_FILE" "$SECRETS_FILE" "$OUT/data.zip" "$OUT/data.zip.tmp" "$OUT/terraform.tfstate"*; }
trap cleanup EXIT

# The authoring container's name is this stack's: one an earlier author.sh left carries no tools/profile.py label,
# which author refuses to replace, so it goes here.
docker rm -f "$NAME" >/dev/null 2>&1 || true
STORAGE=xml
[[ "$REF_STACK" == cluster ]] && STORAGE=jdbc
ref_log "authoring PingFederate $NAME: profiles/minimal.yaml, pf.client_storage=$STORAGE (admin https://127.0.0.1:$PFAI_PORT_AUTHOR_ADMIN)"
# age runs in the stack's PingFederate image, which carries it; the host needs none. The ciphertext is 0644, not this
# script's umask's 0600: PingFederate reads it as uid 9031, which on Linux is not the owner (Docker Desktop's file
# sharing hid that until C-7 ran on a Linux runner). It is age ciphertext; the identity is not here.
PING_DEVOPS_CONFIG="$PING_CONFIG" python3 "$PFAI_ROOT/tools/profile.py" author minimal \
  --base-url "$REF_ISSUER" --set "pf.client_storage=$STORAGE" --out "$OUT" \
  --material-dir "$T" --secrets "$SECRETS_FILE" --author-env "$ENV_FILE" \
  --name "$NAME" --label "owner=$REF_OWNER" --image "$REF_IMAGE" \
  --admin-port "$PFAI_PORT_AUTHOR_ADMIN" --runtime-port "$PFAI_PORT_AUTHOR_RUNTIME" \
  --age-recipient "$(cat "$S/age.pub")" --age-image "$REF_IMAGE" \
  || ref_die "authoring failed (the apply's log is $OUT/terraform.log)"
mv "$OUT/data.zip.age" "$REF_LOCAL/data.zip.age"
ref_log "exported and encrypted $REF_LOCAL/data.zip.age ($(wc -c < "$REF_LOCAL/data.zip.age" | tr -d ' ') bytes); the plaintext is gone"
