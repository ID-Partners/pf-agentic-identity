#!/bin/sh
# The db-migrate job of the reference stacks, in a Temurin 17 JRE: oidf-db-migrate.jar as the migrator role, with
# the URL, user and password file from the environment (OIDF_DB_MIGRATE_*; the URL is verify-full). Every family's
# migrations, then the runtime role's grants, then validate - docs/operator/database-migrations.md "A new
# deployment". A failure stops the job, and PingFederate, which waits on it, never starts.
set -eu
jar=/opt/oidf/oidf-db-migrate.jar
[ -s "$jar" ] || { echo "db-migrate: no oidf-db-migrate.jar mounted at $jar (REF_DB_MIGRATE_JAR)" >&2; exit 2; }
java -jar "$jar" migrate
java -jar "$jar" grants --runtime-role pf_runtime --apply
java -jar "$jar" validate
echo "db-migrate: migrated, pf_runtime granted, validate clean"
