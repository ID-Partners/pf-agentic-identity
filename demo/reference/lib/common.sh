# shellcheck shell=bash
# Sourced by every reference stack script after it sets REF_STACK (single or cluster). Sets no shell options.
#
#   REF_SLOT   required: 0 to 44, the slot whose ports the stack takes (conformance/layout.sh's pfai_slot_ports)
#   REF_NAME   the compose project and the prefix of every container (default ref-<stack>-s<slot>)
#   REF_OWNER  the owner label on every container, network and volume (default pf-agentic-identity)
#
# It exports what the compose files read: the slot's ports, the pinned images (lib/images.env), REF_LOCAL - the
# git-ignored directory this stack instance keeps its certificates, secrets and archive in, <stack>/.local/<name> -
# and REF_IMAGE, the PingFederate image up.sh builds. It returns non-zero after saying why.
REF_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF_ROOT="$(cd "$REF_LIB/.." && pwd)"
: "${REF_STACK:?REF_STACK is set by the script that sources common.sh}"
REF_STACK_DIR="$REF_ROOT/$REF_STACK"
# This repository keeps the rig's layout.sh in conformance/, beside reference/; the public tree exports reference/ as
# demo/reference/, beside demo/layout.sh.
if [[ -f "$REF_ROOT/../conformance/layout.sh" ]]; then
  # shellcheck source=../../conformance/layout.sh
  . "$REF_ROOT/../conformance/layout.sh" || return 1
elif [[ -f "$REF_ROOT/../layout.sh" ]]; then
  # shellcheck disable=SC1091
  . "$REF_ROOT/../layout.sh" || return 1
else
  echo "ERROR: no conformance/layout.sh beside $REF_ROOT, or layout.sh above it (the public tree's demo/)" >&2
  return 1
fi
if [[ -z "${REF_SLOT:-}" ]]; then
  echo "ERROR: set REF_SLOT to a slot from 0 to 44 (reference/README.md, 'Slots'); every port the stack publishes is the slot's" >&2
  return 1
fi
pfai_slot_ports "$REF_SLOT" || return 1
REF_NAME="${REF_NAME:-ref-$REF_STACK-s$REF_SLOT}"
if [[ ! "$REF_NAME" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]]; then
  echo "ERROR: REF_NAME '$REF_NAME' is not a compose project name (lower-case letters, digits and -, at most 41)" >&2
  return 1
fi
REF_OWNER="${REF_OWNER:-pf-agentic-identity}"
REF_LOCAL="$REF_STACK_DIR/.local/$REF_NAME"
# shellcheck disable=SC1091 # images.env: KEY=VALUE beside this file, found at run time through $REF_LIB
. "$REF_LIB/images.env"
# shellcheck disable=SC1090
. "$PFAI_VERSION_ENV"
REF_IMAGE="${REF_IMAGE:-$REF_NAME/pingfederate:local}"
# The issuer: a name only the stack's network resolves, on the port the host reaches it at, so a client in the
# network and one on the host use the same URL's port, and the certificate names both pf.reference.test and
# localhost.
REF_ISSUER_HOST=pf.reference.test
REF_ISSUER="https://$REF_ISSUER_HOST:$PFAI_PORT_RUNTIME"
COMPOSE_PROJECT_NAME="$REF_NAME"
export REF_LIB REF_ROOT REF_STACK REF_STACK_DIR REF_SLOT REF_NAME REF_OWNER REF_LOCAL REF_IMAGE REF_ISSUER_HOST REF_ISSUER
export COMPOSE_PROJECT_NAME REF_POSTGRES_IMAGE REF_REDIS_IMAGE REF_HAPROXY_IMAGE REF_OPENBAO_IMAGE REF_JRE_IMAGE
export REF_SPIRE_SERVER_IMAGE REF_SPIRE_AGENT_IMAGE PF_IMAGE PF_IMAGE_DIGEST

ref_log() { echo "reference/$REF_STACK ($REF_NAME): $*" >&2; }
# ref_curl_user USER SECRET_FILE: the path of a 0600 curl config (`curl -K`) carrying USER:<the secret>, written
# beside the secret, so no password is on a curl command line where ps would show it.
ref_curl_user() {
  local cfg="$2.curl"
  if [[ ! -s "$cfg" || "$cfg" -ot "$2" ]]; then
    (umask 077 && printf 'user = "%s:%s"\n' "$1" "$(cat "$2")" > "$cfg")
  fi
  printf '%s\n' "$cfg"
}
ref_die() { ref_log "ERROR: $*"; exit 1; }
# ref_slot_ports_reserved: 0 when no outgoing connection on this host can take one of the slot's ports - not Linux,
# the ports outside the kernel's local port range, or reserved (net.ipv4.ip_local_reserved_ports); otherwise 1, after
# saying how to reserve them. Linux's default range, 32768-60999, holds every slot (57100-57999), so a connection to
# a published port can be given another of them as its own; a container stopped and started again then cannot bind
# its port ("address already in use": C-7's Redis and console faults on the Linux runner, 2026-10-08). Docker Desktop
# binds published ports on the Mac, where nothing of the stack's own makes connections out of them.
ref_slot_ports_reserved() {
  [[ "$(uname -s)" == Linux && -r /proc/sys/net/ipv4/ip_local_port_range ]] || return 0
  local lo hi first last reserved r a b p ok
  read -r lo hi < /proc/sys/net/ipv4/ip_local_port_range
  first="$PFAI_SLOT_BASE"; last=$((PFAI_SLOT_BASE + 19))
  (( last < lo || first > hi )) && return 0
  reserved="$(cat /proc/sys/net/ipv4/ip_local_reserved_ports 2>/dev/null || true)"
  for ((p = first; p <= last; p++)); do
    ok=0
    IFS=, read -ra r <<<"$reserved"
    for a in "${r[@]}"; do
      [[ -n "$a" ]] || continue
      b="${a#*-}"; a="${a%-*}"
      if (( p >= a && p <= b )); then ok=1; break; fi
    done
    if (( ! ok )); then
      ref_log "port $p, one of slot $REF_SLOT's ($first-$last), is in this host's local port range ($lo-$hi) and not reserved: a container stopped and started again can find it taken by an outgoing connection. Reserve every slot's: echo 'net.ipv4.ip_local_reserved_ports = 57100-57999' | sudo tee /etc/sysctl.d/60-pfai-slots.conf && sudo sysctl -p /etc/sysctl.d/60-pfai-slots.conf"
      return 1
    fi
  done
  return 0
}

# docker compose for this stack instance, with its files and the env file of generated, non-secret values.
ref_compose() {
  docker compose --project-name "$REF_NAME" --project-directory "$REF_STACK_DIR" \
    -f "$REF_STACK_DIR/compose.yml" "$@"
}
