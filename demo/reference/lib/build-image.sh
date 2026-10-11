#!/usr/bin/env bash
# The stack's PingFederate image and oidf-db-migrate.jar, from this checkout's reactor or from a release, staged for
# the production profile into $REF_LOCAL/context - never into build/pingfederate/modules, which the rig stages for
# the conformance profile - then `docker build --target capability`: the image without a baked archive, which the
# stack mounts encrypted.
#
#   SKIP_BUILD=1   reuse $REF_LOCAL/context and the image if both are there
#   PF_RELEASE     <version>|<dir>: stage from that release's verified assets (conformance/layout.sh decides the mode)
set -euo pipefail
# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
CTX="$REF_LOCAL/context"
if [[ "${SKIP_BUILD:-0}" == 1 && -f "$CTX/modules/MANIFEST" && -s "$REF_LOCAL/oidf-db-migrate.jar" ]] \
   && docker image inspect "$REF_IMAGE" >/dev/null 2>&1; then
  ref_log "reusing $REF_IMAGE and $CTX (SKIP_BUILD=1)"
  exit 0
fi
mkdir -p "$CTX"
if [[ "$PFAI_MODE" == release ]]; then
  STAGE_DEST="$CTX/modules" "$PFAI_IMAGE_DIR/stage-from-release.sh" --profile production ${PF_RELEASE:+"$PF_RELEASE"} >&2
  jar="${REF_DB_MIGRATE_JAR:-$PFAI_RELEASE_DIR/oidf-db-migrate.jar}"
else
  ( cd "$PFAI_ROOT" && mvn -q -DskipTests package && STAGE_DEST="$CTX/modules" build/pingfederate/stage-modules.sh --profile production ) >&2
  jar="${REF_DB_MIGRATE_JAR:-$PFAI_ROOT/tools/db-migrate/target/oidf-db-migrate.jar}"
fi
[[ -s "$jar" ]] || ref_die "no oidf-db-migrate.jar at $jar (set REF_DB_MIGRATE_JAR)"
install -m 0644 "$jar" "$REF_LOCAL/oidf-db-migrate.jar"
cp "$PFAI_IMAGE_DIR"/{Dockerfile,assemble-pf-runtime-war.sh,filters.xml,pf-entrypoint.sh,pf-healthcheck.sh} "$CTX/"
docker build --quiet --target capability --build-arg STAGING_PROFILE=production \
  --label "owner=$REF_OWNER" -t "$REF_IMAGE" "$CTX" >/dev/null
ref_log "built $REF_IMAGE (capability, production profile) from $CTX"
