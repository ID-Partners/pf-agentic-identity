#!/usr/bin/env bash
# The reference stacks' lint, for Build's lint job: `docker compose config -q` for each stack, and the cluster with
# each profile, against a dummy .local/ (empty files where up.sh would generate them), so a compose file that does
# not parse or interpolate fails here and not at someone's first up. The scripts' shellcheck is
# tools/ci/lint-shell.sh's, over every tracked script. Needs docker compose; starts nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tls" "$TMP/secrets" "$TMP/redis" "$TMP/bao/console" "$TMP/bao/engine-1" "$TMP/bao/engine-2"
for f in tls/ca.crt tls/postgres.crt tls/postgres.key tls/redis.crt tls/redis.key tls/openbao.crt \
         tls/openbao.key secrets/postgres-superuser secrets/age.key secrets/ssf-secret-key secrets/oidf-migrator \
         secrets/pf-clients redis/users.acl data.zip.age oidf-db-migrate.jar service-points.conf \
         oauth-client-management-postgresql.sql spire/bundle.pem; do
  mkdir -p "$(dirname "$TMP/$f")"
  : > "$TMP/$f"
done
# A licence file need not exist: the compose files mark it required: false.
export PING_DEVOPS_CONFIG="$TMP/no-licence" REF_LOCAL="$TMP" REF_DB_MIGRATE_JAR="$TMP/oidf-db-migrate.jar"
export REF_OWNER=lint REF_UID=1000 REF_GID=1000
set -a
# shellcheck disable=SC1091 # images.env: KEY=VALUE, found at run time through $ROOT
. "$ROOT/lib/images.env"
set +a
n=0
for spec in "single:" "cluster:" "cluster:spire" "cluster:mdm"; do
  stack="${spec%%:*}"; profile="${spec#*:}"
  args=(--project-name "lint-$stack" --project-directory "$ROOT/$stack" -f "$ROOT/$stack/compose.yml")
  [[ -z "$profile" ]] || args+=(--profile "$profile")
  REF_NAME="lint-$stack" docker compose "${args[@]}" config -q
  services="$(REF_NAME="lint-$stack" docker compose "${args[@]}" config --services | sort | paste -sd' ' -)"
  echo "ok: reference/$stack${profile:+ (profile $profile)}: $services"
  n=$((n + 1))
done
echo "ok: $n compose configurations parse and interpolate"
