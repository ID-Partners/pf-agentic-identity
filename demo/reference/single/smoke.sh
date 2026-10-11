#!/usr/bin/env bash
# reference/single's licensed smoke check, on a stack up.sh brought up: PingFederate is ready, reports itself
# STANDALONE on the production profile with no component refused, and hands reference-smoke a token by
# client_credentials - every call over TLS checked against the stack's CA.
#
#   REF_SLOT=N ./smoke.sh
set -euo pipefail
export REF_STACK=single
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
"$REF_LIB/smoke-node.sh" "https://localhost:$PFAI_PORT_RUNTIME" "$REF_NAME-pf" STANDALONE
ref_log "smoke: passed ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
