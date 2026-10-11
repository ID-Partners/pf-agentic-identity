#!/usr/bin/env bash
# Stop and remove reference/cluster on a slot, every profile's services included: containers, network and volumes (the
# database and OpenBao's storage with them). .local/<name>/ stays; OpenBao is initialised afresh next time, so its
# old init file goes.
set -euo pipefail
export REF_STACK=cluster
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
ref_compose --profile spire --profile mdm down --volumes --remove-orphans --timeout 30
docker rm -f "$REF_NAME-author" >/dev/null 2>&1 || true
rm -rf "$REF_LOCAL/bao"
ref_log "down"
