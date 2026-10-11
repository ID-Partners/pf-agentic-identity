#!/usr/bin/env bash
# Stop and remove reference/single on a slot: containers, network and volumes (the database with them). .local/<name>/
# stays - certificates, secrets and the archive - so the next up.sh reuses them; delete it to start again.
set -euo pipefail
export REF_STACK=single
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
ref_compose down --volumes --remove-orphans --timeout 30
docker rm -f "$REF_NAME-author" >/dev/null 2>&1 || true
ref_log "down"
