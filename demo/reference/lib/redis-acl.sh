#!/usr/bin/env bash
# The reference cluster's Redis ACL file: the default user off, and oidf - the user every PingFederate node connects
# as - held to the modules' key prefixes (oidf: and oidf-registration:) and the commands libs/platform's Redis client
# sends to a master (AUTH GET SET DEL EVAL EVALSHA INCR PEXPIRE PING SELECT ROLE), everything else refused. A FLUSHALL,
# a KEYS, or a key outside the prefixes is NOPERM. SENTINEL, the client's eleventh command, goes to a sentinel only:
# Redis 7.4.11 refuses to start with +sentinel in a master's ACL ("Unknown command or category name in ACL", seen
# 2026-10-08).
#
#   redis-acl.sh SECRETS_DIR OUT
set -euo pipefail
secrets="${1:?usage: redis-acl.sh SECRETS_DIR OUT}"
out="${2:?usage: redis-acl.sh SECRETS_DIR OUT}"
umask 077
mkdir -p "$(dirname "$out")"
pw="$(cat "$secrets/redis-oidf")"
[[ "$pw" =~ ^[A-Za-z0-9]{32}$ ]] || { echo "ERROR: $secrets/redis-oidf is not a generated password" >&2; exit 1; }
{
  echo "user default off resetkeys resetchannels -@all"
  echo "user oidf on >$pw resetkeys ~oidf:* ~oidf-registration:* resetchannels -@all +auth +get +set +del +eval +evalsha +incr +pexpire +ping +select +role"
} > "$out.tmp"
mv "$out.tmp" "$out"
