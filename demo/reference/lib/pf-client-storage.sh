#!/bin/sh
# The reference cluster's pf-client-storage job, in the PostgreSQL image: PingFederate's own client storage script,
# taken from the pinned PingFederate image (server/default/conf/oauth-client-management/sql-scripts/
# oauth-client-management-postgresql.sql, which up.sh extracts), run as pf_clients in schema pf over verify-full TLS.
# Idempotent and all or nothing: both tables there, it does nothing; neither, it runs the script in one transaction;
# one without the other is a partial set, which it refuses rather than guess how it came about.
set -eu
export PGPASSWORD
PGPASSWORD="$(cat /secrets/pf-clients)"
conn="host=postgres dbname=oidf user=pf_clients sslmode=verify-full sslrootcert=/tls/ca.crt options=-csearch_path=pf"
n="$(psql -XAtq "$conn" -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'pf'
  AND table_name IN ('pingfederate_oauth_clients', 'pingfederate_oauth_clients_ext')")"
case "$n" in
  2) echo "pf-client-storage: schema pf already has PingFederate's client tables"; exit 0 ;;
  0) ;;
  *) echo "pf-client-storage: schema pf has $n of PingFederate's two client tables - a partial set; drop it or finish it by hand" >&2; exit 1 ;;
esac
[ -s /sql/oauth-client-management-postgresql.sql ] || { echo "pf-client-storage: no SQL script mounted" >&2; exit 2; }
psql -Xq -v ON_ERROR_STOP=1 --single-transaction "$conn" -f /sql/oauth-client-management-postgresql.sql
echo "pf-client-storage: created PingFederate's client tables in schema pf as pf_clients"
