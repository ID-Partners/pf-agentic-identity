#!/usr/bin/env bash
# reference/single: one PingFederate (production profile) on PostgreSQL 17 over TLS, on a slot.
#
#   REF_SLOT=N ./up.sh          REF_NAME (default ref-single-s<N>), REF_OWNER, SKIP_BUILD=1, PF_RELEASE, REF_REAUTHOR=1
#
#   1. lib/build-image.sh     the modules staged for production and the image built (target capability)
#   2. lib/gen-tls.sh         the stack's CA, PostgreSQL's and PingFederate's certificates      (.local/<name>/tls)
#   3. lib/gen-secrets.sh     the roles' passwords, the smoke client's secret, the age identity  (.local/<name>/secrets)
#   5. lib/author.sh          the config archive, authored on a localhost PingFederate and age-encrypted - once per
#                             name (the issuer's port is in it); REF_REAUTHOR=1 authors it again
#   6. docker compose up      postgres, then db-roles and db-migrate, then PingFederate
#
# Then it waits for PingFederate to answer ready on https://localhost:<the slot's runtime port>, checking the
# certificate against the stack's CA. Licence details as the rig: $PING_DEVOPS_CONFIG (~/.pingidentity/config).
set -euo pipefail
export REF_STACK=single
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
for tool in docker terraform curl openssl unzip base64; do
  command -v "$tool" >/dev/null || ref_die "$tool is required"
done
[[ "$PFAI_MODE" == release ]] || command -v mvn >/dev/null || ref_die "mvn is required (or set PF_RELEASE)"
ref_slot_ports_reserved || ref_log "WARNING: carrying on; a container this host restarts can fail to start"
mkdir -p "$REF_LOCAL"
chmod 700 "$HERE/.local" "$REF_LOCAL"

"$REF_LIB/build-image.sh"
"$REF_LIB/gen-tls.sh" "$REF_LOCAL/tls" "postgres=postgres,localhost,127.0.0.1" \
  "pf=$REF_ISSUER_HOST,localhost,$REF_NAME-pf,127.0.0.1" >&2
"$REF_LIB/gen-secrets.sh" "$REF_LOCAL/secrets" >&2
if [[ "${REF_REAUTHOR:-0}" == 1 || ! -s "$REF_LOCAL/data.zip.age" ]]; then
  "$REF_LIB/author.sh"
else
  ref_log "reusing $REF_LOCAL/data.zip.age (REF_REAUTHOR=1 authors it again)"
fi
# Ciphertext, read through a bind mount by PingFederate's uid 9031: 0644 in this 0700 directory (an archive an earlier
# up.sh authored is 0600, which only Docker Desktop could read). reference/README.md, "File ownership on Linux".
chmod 644 "$REF_LOCAL/data.zip.age"

export REF_DB_MIGRATE_JAR="$REF_LOCAL/oidf-db-migrate.jar"
ref_compose up -d
"$REF_LIB/wait-ready.sh" "https://localhost:$PFAI_PORT_RUNTIME" "$REF_NAME-pf"
ref_log "up: issuer $REF_ISSUER (https://localhost:$PFAI_PORT_RUNTIME from this host), admin https://localhost:$PFAI_PORT_ADMIN, PostgreSQL 127.0.0.1:$PFAI_PORT_POSTGRES (TLS only). ./smoke.sh takes a token; ./down.sh removes it all."
