#!/usr/bin/env bash
# A reference stack's generated secrets, one file each, 0600 in a 0700 directory, kept once made and never printed.
#
#   gen-secrets.sh DIR [--no-age]
#
#   postgres-superuser   the postgres role's password (db-roles uses it, and nothing else)
#   oidf-migrator        oidf_migrator: oidf-db-migrate.jar's role, which owns the families' tables
#   pf-runtime           pf_runtime: PingFederate's data stores for the modules' tables (rows only)
#   pf-clients           pf_clients: PingFederate's OAuth client storage, which owns schema pf
#   redis-oidf           the Redis ACL user oidf's password
#   pf-admin             the authoring PingFederate's administrator password (it becomes the archive's)
#   pf-cluster           the cluster's pf.cluster.auth.pwd (cluster stack only reads it)
#   ssf-secret-key       OIDF_SSF_SECRET_KEY: 32 random bytes, base64, sealing push streams' authorization headers
#   smoke-client         reference-smoke's client secret, which the smoke checks take a token with
#   age.key, age.pub     the age identity the config archive is encrypted to, and its recipient
#
# --no-age makes no age identity (the data-tier job has no PingFederate image to run age-keygen in).
# Passwords are 32 characters of [A-Za-z0-9], so they sit in a URL, a psql variable and an ACL file unquoted.
set -euo pipefail
dir="${1:?usage: gen-secrets.sh DIR [--no-age]}"
umask 077
mkdir -p "$dir"
chmod 700 "$dir"
rand() { openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | cut -c1-32; }
for name in postgres-superuser oidf-migrator pf-runtime pf-clients redis-oidf pf-admin pf-cluster smoke-client; do
  if [[ -s "$dir/$name" ]]; then
    echo "kept      $name"
  else
    # The admin password must satisfy PingFederate's policy: a digit, an upper- and a lower-case letter.
    if [[ "$name" == pf-admin ]]; then printf '%sAa1' "$(rand)" > "$dir/$name"; else rand > "$dir/$name"; fi
    echo "generated $name"
  fi
done
if [[ -s "$dir/ssf-secret-key" ]]; then
  echo "kept      ssf-secret-key"
else
  openssl rand -base64 32 > "$dir/ssf-secret-key"
  echo "generated ssf-secret-key"
fi
if [[ "${2:-}" == --no-age ]]; then
  :
elif [[ -s "$dir/age.key" && -s "$dir/age.pub" ]]; then
  echo "kept      age.key"
else
  # age-keygen runs in the image that will decrypt with it, so the host needs no age.
  : "${REF_IMAGE:?gen-secrets.sh needs REF_IMAGE (the PingFederate image of the stack, which carries age-keygen)}"
  docker run --rm --entrypoint /usr/local/bin/age-keygen "$REF_IMAGE" 2>/dev/null | grep '^AGE-SECRET-KEY-1' > "$dir/age.key"
  docker run --rm -i --entrypoint /usr/local/bin/age-keygen "$REF_IMAGE" -y < "$dir/age.key" > "$dir/age.pub"
  [[ -s "$dir/age.key" && "$(cat "$dir/age.pub")" == age1* ]] || { echo "ERROR: age-keygen in $REF_IMAGE made no identity" >&2; exit 1; }
  echo "generated age.key"
fi
chmod 600 "$dir"/*
