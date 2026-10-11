#!/usr/bin/env bash
# One reference node's smoke check: ready, its start-up audit, and (on a node that serves the runtime) a
# client_credentials token for reference-smoke.
#
#   smoke-node.sh BASE_URL|- CONTAINER MODE [EXPECT...]
#
# The audit is pf-runtime.war's banner in the node's server.log (docs/operator/startup-audit.md), read with docker
# exec: /agentic-identity/info carries the same topology, but in production it needs an operator token DPoP-bound to
# the caller, which this example does not configure. The audit must say the expected mode and the production
# profile, have no code refusal and no violation it REFUSED, and list no component REFUSED or FAILED; each EXPECT is a further
# substring it must contain (the cluster's "OAuth clients in database" and "lease backend jdbc"). BASE_URL - skips
# the readiness and token checks (a console serves no runtime traffic).
set -euo pipefail
# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
base="${1:?}"; container="${2:?}"; mode="${3:?}"; shift 3
ca="$REF_LOCAL/tls/ca.crt"
[[ "$base" == - ]] || "$REF_LIB/wait-ready.sh" "$base" "$container" 60
audit="$(docker exec "$container" sh -c 'awk "/Start-up audit for \/ \(ROOT\)/{found=1; text=\"\"} found{text=text \$0 \"\n\"} END{printf \"%s\", text}" /opt/out/instance/log/server.log' \
  | awk 'NR==1 || /^  [a-zA-Z]/ || /^                  /' | sed -n '1,/^  platform:/p')"
[[ -n "$audit" ]] || ref_die "$container: no start-up audit for / (ROOT) in server.log"
for want in "topology:       $mode" "profile:        production" "code refusals:  none" "$@"; do
  grep -qF -- "$want" <<<"$audit" || { echo "$audit" >&2; ref_die "$container: the start-up audit does not say '$want'"; }
done
# A violation the sweep lists as "not refused (not switched on)" names a component this example switches off. An
# engine's audit may show SSF FAILED_DEPENDENCY: it starts before the console replicates the data stores to it, and the
# component supervisor starts SSF once they arrive - ready (200 above) is the state now.
if grep -qE ' (REFUSED|FAILED_CONFIG)\b|REFUSED:' <<<"$audit"; then
  echo "$audit" >&2
  ref_die "$container: a component is refused or failed"
fi
# A client registered a moment ago may not be seen yet: an engine reads JDBC client storage through PingFederate's own
# cache (U-0027; C-7 measures the window). So the token is asked for until it comes or REF_TOKEN_WAIT seconds pass.
if [[ "$base" != - ]]; then
  started=$SECONDS token=""
  while :; do
    token="$(curl -s --cacert "$ca" --max-time 10 -K "$(ref_curl_user reference-smoke "$REF_LOCAL/secrets/smoke-client")" \
      -d grant_type=client_credentials -d scope=reference.smoke "$base/as/token.oauth2" \
      | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("access_token",""))
except Exception: print("")')"
    [[ "$token" == ey*.*.* ]] && break
    (( SECONDS - started < ${REF_TOKEN_WAIT:-180} )) || ref_die "$container: no JWT access token for reference-smoke at $base in ${REF_TOKEN_WAIT:-180} s"
    sleep 2
  done
  (( SECONDS - started < 2 )) || ref_log "$container: the first token came after $((SECONDS - started)) s"
fi
if [[ "$base" == - ]]; then ref_log "$container: $mode, production, no refusal"; else ref_log "$container: $mode, production, no refusal, a token at $base"; fi
