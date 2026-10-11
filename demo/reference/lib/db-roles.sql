-- The reference stacks' roles and database, as docs/operator/database-migrations.md "Roles" has them, plus
-- pf_clients for PingFederate's OAuth client storage. Run by the db-roles job as the postgres superuser over TLS,
-- with the passwords as psql variables (mig, rt, cl), on every start: each statement is idempotent, and the
-- passwords are set again so a regenerated secret takes effect. psql reads them from /secrets itself, so no
-- password is on a command line (`ps` on a Linux host lists every container's).
\set ON_ERROR_STOP on
\set mig `cat /secrets/oidf-migrator`
\set rt `cat /secrets/pf-runtime`
\set cl `cat /secrets/pf-clients`
SELECT format('CREATE ROLE %I LOGIN', r) FROM unnest(ARRAY['oidf_migrator', 'pf_runtime', 'pf_clients']) AS r
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec
ALTER ROLE oidf_migrator LOGIN PASSWORD :'mig';
ALTER ROLE pf_runtime LOGIN PASSWORD :'rt';
ALTER ROLE pf_clients LOGIN PASSWORD :'cl';
SELECT 'CREATE DATABASE oidf' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'oidf') \gexec
\connect oidf
-- oidf_migrator owns the families' tables in public; adopt's scratch schema needs CREATE on the database.
GRANT CREATE ON DATABASE oidf TO oidf_migrator;
GRANT CREATE, USAGE ON SCHEMA public TO oidf_migrator;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
-- pf_runtime gets rows only, from oidf-db-migrate.jar's grants --apply; it connects and nothing else here.
GRANT CONNECT ON DATABASE oidf TO pf_runtime, pf_clients;
REVOKE CREATE ON DATABASE oidf FROM pf_runtime, pf_clients;
-- PingFederate's client storage lives in its own schema, owned by its own role, out of the families' way.
CREATE SCHEMA IF NOT EXISTS pf AUTHORIZATION pf_clients;
REVOKE ALL ON SCHEMA pf FROM PUBLIC;
ALTER ROLE pf_clients IN DATABASE oidf SET search_path = pf;
