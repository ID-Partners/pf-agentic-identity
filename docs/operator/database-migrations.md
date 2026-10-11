# Database migrations

From 0.7.0 PingFederate creates and alters no table. Every table this repository's stores use is created by a
versioned migration, and `oidf-db-migrate.jar`, a release asset, applies them. Run it as a job before PingFederate
starts, on every upgrade, as a role that may change the schema; PingFederate then connects as a role that may only
read and write rows.

Up to 0.6.x it was different: the SSF tables store created its tables at start-up (`JdbcSsfStore.ensureSchema()`,
with an `ALTER TABLE ... ADD COLUMN` that two nodes starting together raced on), and the federation and agent tables
were applied by hand from the `.sql` files ([0.1.5 to 0.3.0](upgrading/0.1.5-to-0.3.0.md), "Apply the migrations").
Nothing recorded which migrations a database had. A database built that way is taken on with `adopt`
([Upgrading from 0.6.x](#upgrading-from-06x)).

## Families

A migration is a file `V<version>__<description>.sql`. Its major version puts it in a family, and each family has its
own history: one family can be migrated, adopted or validated without the others.

| Family | Versions | Tables | Used by |
|---|---|---|---|
| `platform` | V10-V99 | V10 `oidf_lease` | the `jdbc` lease backend ([clustering.md](clustering.md#leases)): apply it to the database `OIDF_LEASE_DATA_STORE_ID` names |
| `federation` | V100-V199 | V100 `hosted_entity`, `hosted_entity_audit_log`; V101 adds `hosted_entity_audit_log.actor`; V102 `trust_mark_grant`, `trust_mark_audit_log`; V103 `federation_key_current`, `federation_key_history`; V104 `federation_key_observed`; V105 `federation_subordinate`, `federation_subordinate_key_change`, `federation_subordinate_audit_log`; V106 `federation_subordinate_observation`, `federation_subordinate_key_change.decision_reason`, a PENDING `federation_subordinate.status` | the authority's hosted entities, Trust Marks, key history, key observations and pinned subordinates (`OIDF_FEDERATION_SUBORDINATE_STORE=database`) |
| `agent` | V200-V299 | V200 `agent_identity` | the agent identity registry |
| `ssf` | V300-V399 | V300 `ssf_streams`, `ssf_stream_subjects`, `ssf_pending_sets`, `ssf_scim_users`; V301 adds `ssf_streams.owner_client_id`, `description`, `min_verification_interval` and `inactivity_timeout`; V302 makes `ssf_streams.push_auth_header` `TEXT`; V303 `ssf_stream_lease` (a push stream's lease, backfilled for the push streams already there); V304 adds `ssf_pending_sets.seq`, numbered in the order a backlog had, its sequence `ssf_pending_sets_seq` and an index on `(stream_id, seq)`; V305 adds `ssf_streams.last_verification_at`; V306 `ssf_dead_sets` (the SETs a receiver refused for good, F-0361); V307 `ssf_receiver_inbox` (the receiver's inbound SETs by `(iss, jti)`, with partial indexes on pending `next_attempt_at` and on `ack_due`) and `ssf_receiver_set_errs` (refused polled SETs until reported); V308 adds `ssf_streams.row_version` (0 for the streams there), `last_activity_at` (backfilled with `now()`) and `paused_by`, and `ssf_stream_lease.failing_since`; V309 `ssf_emission_outbox` (an event raised and not yet fanned out, its id sequence `ssf_emission_outbox_id_seq` and an index on `(subject_key, id)`), `ssf_pending_sets.emission_id` with a unique partial index on `(emission_id, stream_id)`, and `ssf_logout_replay` (a logout hint's replay key until its bound); V310 adds `ssf_scim_users.user_name_key` (unique index; the userName compared case and width aside, backfilled at start, left unset for a duplicate) and `email_key`, `ssf_stream_subjects.email_key` and an index on `ssf_stream_subjects (subject_key)`, and `ssf_logout_pending` (a sign-off waiting for its confirmation, by the SHA-256 of its request state, with an index on `expires_at`) | the SSF transmitter's tables store (`storeDialect=tables`); V303-V310 are what SSF on a cluster needs ([clustering.md](clustering.md#ssf-push-streams), [SSF receiver](clustering.md#ssf-receiver), [SSF emission](clustering.md#ssf-emission)) |
| `enrolment` | V400-V499 | none yet | - |
| `mdm-adapter` | V500-V599 | none yet | - |

The SSF `ldm` dialect keeps its state in the Identity Object Model's `idm.entry`, which `idp-scim-service` migrates;
a deployment on `ldm` has no `ssf` family to apply. `info` lists the versions the jar carries.

V304's sequence belongs to the role that runs the migration and is owned by its column (`OWNED BY
ssf_pending_sets.seq`), so it is dropped with the column. The runtime role inserts a pending SET by taking the
sequence's next value, which needs `USAGE` on it: run `grants` again after V304 - it prints `GRANT USAGE, SELECT ON
SEQUENCE` for every sequence in the family's tables. Without it every SET the transmitter queues fails with
`permission denied for sequence ssf_pending_sets_seq`.

V307's tables are new, so `grants` must run again after it as well: without `SELECT, INSERT, UPDATE, DELETE` on
`ssf_receiver_inbox` and `ssf_receiver_set_errs` every pushed SET is answered 503 and no polled SET is acknowledged.
Apply V307 before the jar that reads it starts; the receiver starts with an empty inbox, so a SET delivered before the
upgrade and again after it is acted on again - a rerun of the grants handler revokes any grant issued to the user
since the first run ([clustering.md](clustering.md)). V306 is S10B's (`ssf_dead_sets`).

V308 (plan item S10c) adds columns only, so `grants` need not run again for it: the runtime role's `UPDATE` on
`ssf_streams` and `ssf_stream_lease` covers them. Apply it before the jar that reads it starts - every stream read
selects the new columns. Its backfill starts each stream's `inactivity_timeout` counter at the upgrade, so the first
sweep pauses none for idleness before it; a stream paused before it has no `paused_by` (who paused it is not known).

V309's tables and sequence are new, so `grants` must run again after it: without them every raised SSF event stays in
the node's hand-off (`ssf.outbox.write_failed`) and `POST /ssf/events:emit` and SCIM's account events answer 500.
Apply V309 before the jar that reads it starts. SETs queued before it keep no `emission_id`; they stay queued and go
first.

V310's `ssf_logout_pending` is new, so `grants` must run again after it: without it a logout's sign-off is not recorded
and no session-revoked follows the confirmation. Before applying it, find the SCIM users whose userNames differ only in
case or width (the query in the 0.7.0 release note): the unique index admits them, the start-up backfill keys the first
of each and reports the rest (`ssf.scim.username_conflict`) until one is renamed.

## Running it

```sh
java -jar oidf-db-migrate.jar <info|validate|migrate|adopt|grants> [options]
```

It needs Java 17 or later and reaches PostgreSQL with the JDBC driver it carries; it has no other dependency.

| Option | Environment variable | What it is |
|---|---|---|
| `--jdbc-url URL` | `OIDF_DB_MIGRATE_JDBC_URL` | `jdbc:postgresql://host:5432/db?sslmode=verify-full`. A URL that does not require TLS is refused unless `--allow-plaintext` is given (a development database only); so is a URL carrying a password |
| `--user NAME` | `OIDF_DB_MIGRATE_USER` | the migrator role |
| `--password-file PATH` | `OIDF_DB_MIGRATE_PASSWORD_FILE` | a file holding the password; its line ending is dropped. There is no password option |
| `--schema NAME` | `OIDF_DB_MIGRATE_SCHEMA` | where the tables and the history live; default `public` |
| `--family F` | - | one family; without it, every family the jar carries (for `info`, `validate`, `migrate` and `grants`) |

An option on the command line wins over its variable. TLS counts when `sslmode` is `require`, `verify-ca` or
`verify-full` exactly as PgJDBC spells them, or `ssl` is given with no value or `true`: PgJDBC's own default,
`prefer`, falls back to plaintext. Use `verify-full` against a production database. The jar prints no password and
never repeats the URL in a message. [The configuration reference](../configuration/db-migrate.md) lists the four
variables.

`java -jar oidf-db-migrate.jar --help` prints the commands, options and exit statuses.

### info

Per family: each version the jar carries, and whether the history has it as `applied` (by `migrate`), `adopted` (by
`adopt`), or neither (`pending`); and any problem (below). It changes nothing.

### validate

`info`, then exit 1 if any family has a problem:

- **drift** - a version was applied with one checksum and the jar's script has another. A shipped migration was
  edited after it ran; nothing in this repository edits one, so this is a database migrated from a modified jar.
- **gap** - a version has not run but a later one of its family has; it would run out of order.
- **unknown** - the history has a version the jar does not carry: the database was migrated by a newer jar, or a
  row was written by hand.
- **failed** - the history records a version as failed.

The checksum is SHA-256 over the script with line endings, trailing spaces and trailing blank lines normalised, so a
checkout that rewrote line endings is not drift.

### migrate

Applies each family's pending versions in version order, each script and its history row in one transaction: a
script that fails is rolled back with nothing of it left, the versions before it stay applied, and the run exits 1.
`--target V` stops at version V. migrate refuses to run anything while `validate` would fail.

It holds a PostgreSQL advisory lock for the schema while it works. A second runner against the same schema - a
second job, a second node's init container - waits for the first and then finds nothing pending, so starting
several at once is safe. The history is the table `oidf_schema_history` in the schema (`family`, `version`,
`description`, `script`, `checksum`, `kind`, `installed_by`, `installed_at`, `execution_ms`, `success`), which
migrate creates on its first run.

### adopt

```sh
java -jar oidf-db-migrate.jar adopt --family ssf --baseline 301
```

For a database built before 0.7.0, by `ensureSchema` or by hand. adopt builds the family's tables up to the baseline
in a scratch schema inside a transaction it rolls back, reads their shape - tables, columns with their types, NOT
NULL and defaults, constraints and indexes - and compares it with the live schema. Column order is not compared: a
column `ALTER TABLE ... ADD COLUMN` added sits last, and 0.3.0-0.6.x databases had columns added that way. Only if
the shapes match exactly does it record every version up to the baseline as adopted; otherwise it records nothing,
prints each difference, and exits 1. A table a later version of the family creates that is already there is a
difference too (the database is ahead of the baseline). Tables of other families, and any other table in the
schema, are not compared. adopt refuses a family that already has a history.

The migrator role needs `CREATE` on the database for the scratch schema; it is dropped with the rollback.

### grants

```sh
java -jar oidf-db-migrate.jar grants --runtime-role pf_runtime            # print them
java -jar oidf-db-migrate.jar grants --runtime-role pf_runtime --apply    # and run them
```

The least privilege PingFederate's role needs: `USAGE` on the schema, `SELECT, INSERT, UPDATE, DELETE` on each of
the families' tables (an `*_audit_log` table gets `SELECT, INSERT` only, as nothing updates or deletes an audit
row), `USAGE, SELECT` on their sequences, and `SELECT` on `oidf_schema_history`, which the start-up check reads. No DDL. Run it after every `migrate` that adds a table. Without
`--family` it names every family's tables, so a database that has only some families (an SSF data store on the `ldm`
dialect has no `ssf` tables) takes one `--family` run per family it has. The runtime
role must own nothing in the schema and hold no `CREATE` on it: an owner can alter its tables whatever is granted.

## Roles

Two roles, so that the role PingFederate's pool holds cannot change the schema:

```sql
CREATE ROLE oidf_migrator LOGIN PASSWORD '...';     -- runs oidf-db-migrate.jar: owns the tables
CREATE ROLE pf_runtime    LOGIN PASSWORD '...';     -- PingFederate's JDBC data store: rows only
GRANT CREATE ON DATABASE oidf TO oidf_migrator;     -- the schema, if not public, and adopt's scratch schema
GRANT CREATE, USAGE ON SCHEMA public TO oidf_migrator;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;         -- PostgreSQL 15 and later already do not grant it
```

Then `migrate` as `oidf_migrator` and `grants --runtime-role pf_runtime --apply`, and point PingFederate's data
store at `pf_runtime`. If the tables live in a schema other than `public`, the runtime role's `search_path` must
reach it (`ALTER ROLE pf_runtime SET search_path = oidf`): the stores name their tables without a schema.

## A new deployment

```sh
java -jar oidf-db-migrate.jar migrate
java -jar oidf-db-migrate.jar grants --runtime-role pf_runtime --apply
java -jar oidf-db-migrate.jar validate
```

then start PingFederate. A cluster whose nodes take `OIDF_LEASE_BACKEND=jdbc` needs the `platform` family (V10) in the
lease data store's database; `migrate` applies it with the rest. On each later upgrade, run `migrate` (and `grants` again) with the new release's jar before
the new PingFederate starts; a PingFederate that started first is `FAILED_CONFIG` until it restarts after the migrate
([The start-up check](#the-start-up-check)). A release whose migrations the previous release cannot run against says so in its
"Before you deploy".

The reference stacks run exactly this as two jobs before any PingFederate starts (`service_completed_successfully`):
`db-roles` creates the roles above, and `db-migrate` runs `migrate`, `grants --runtime-role pf_runtime --apply` and
`validate` as `oidf_migrator` over `verify-full` TLS with a password file ([reference/single](../../demo/reference/single/README.md)).
Build's `reference-data-tier` job checks what they leave: `pf_runtime` owns nothing and holds no `CREATE`, and
`validate` is clean.

## Upgrading from 0.6.x

0.7.0 PingFederate does not create the SSF tables, and does not add the columns 0.6.x added at start-up: run the jar
before you upgrade.

First hand the tables to the migrator role. The 0.6.x SSF tables were created by whichever role PingFederate's data
store used, and the federation and agent tables by whoever applied the 0.3.0 guide's SQL, so that role owns them.
`migrate` alters `ssf_streams` (V302), and PostgreSQL lets only a table's owner alter it: run as `oidf_migrator`
against tables it does not own, migrate stops at V302 with `must be owner of table ssf_streams`, rolls it back and
exits 1. Run this as a superuser (or as the owning role, once it is a member of `oidf_migrator`), for the tables the
database has:

```sql
ALTER TABLE ssf_streams OWNER TO oidf_migrator;
ALTER TABLE ssf_stream_subjects OWNER TO oidf_migrator;
ALTER TABLE ssf_pending_sets OWNER TO oidf_migrator;
ALTER TABLE ssf_scim_users OWNER TO oidf_migrator;
ALTER TABLE hosted_entity OWNER TO oidf_migrator;
ALTER TABLE hosted_entity_audit_log OWNER TO oidf_migrator;
ALTER TABLE trust_mark_grant OWNER TO oidf_migrator;
ALTER TABLE trust_mark_audit_log OWNER TO oidf_migrator;
ALTER TABLE federation_key_current OWNER TO oidf_migrator;
ALTER TABLE federation_key_history OWNER TO oidf_migrator;
ALTER TABLE agent_identity OWNER TO oidf_migrator;
```

A table's indexes and the sequences its serial columns own move with it (checked on PostgreSQL 16, 2026-10-05).
This also takes DDL away from PingFederate's role, so move every node to 0.7.0 first, or straight after: a 0.6.x node
still runs its start-up DDL on every start and fails on tables it no longer owns.

Then, as `oidf_migrator`, adopt each family the database has at the version the 0.6.x database is at, and migrate
the rest:

| Family | Adopt at | When |
|---|---|---|
| `federation` | `--baseline 103` | the authority's database holds hosted entities, Trust Marks or the key history, and the 0.3.0 guide's V101-V103 were applied |
| `agent` | `--baseline 200` | the agent identity registry has its table |
| `ssf` | `--baseline 301` | the SSF transmitter ran with `storeDialect=tables` on 0.6.x (its start-up created V300 and V301's shape) |

```sh
export OIDF_DB_MIGRATE_JDBC_URL='jdbc:postgresql://db.example.com:5432/oidf?sslmode=verify-full'
export OIDF_DB_MIGRATE_USER=oidf_migrator OIDF_DB_MIGRATE_PASSWORD_FILE=/run/secrets/oidf_migrator
java -jar oidf-db-migrate.jar adopt --family federation --baseline 103
java -jar oidf-db-migrate.jar adopt --family agent --baseline 200
java -jar oidf-db-migrate.jar adopt --family ssf --baseline 301
java -jar oidf-db-migrate.jar migrate        # V302-V310 for ssf; any family the database did not have is created
java -jar oidf-db-migrate.jar grants --runtime-role pf_runtime --apply
java -jar oidf-db-migrate.jar validate
```

Skip the adopt of a family the database does not have; `migrate` creates it. If the families live in different
databases (the authority's and the SSF data store's), run the jar against each with `--family`. An `ssf` database
last started by a release before 0.6.0 has neither `ssf_scim_users` nor the three stream-member columns, and adopt
refuses it with those differences: start 0.6.1 against it once, which brings it to 0.6.x's shape, then adopt at 301.
If adopt refuses any other shape, the difference it prints is the change to make by hand, or to raise; nothing is
recorded until the shape matches.

## Exit statuses

| Status | Meaning |
|---|---|
| 0 | done; `info` and `validate` found nothing wrong |
| 1 | refused: drift, a gap, an unknown or failed version; a script failed and was rolled back; a shape adopt does not match; a family already adopted |
| 2 | usage: the command line or environment cannot be acted on, or the password file cannot be read; nothing was run against the database |
| 3 | the database could not be reached, or answered an error outside a script (the message carries its SQLState) |

## The start-up check

From 0.7.0 each store checks its family before PingFederate publishes it (plan item DB-4, `platform.jdbc.SchemaVerifier`):
the SSF store's `tables` dialect (`ssf`), the authority's hosted entities, Trust Marks and key history (`federation`,
asked by HOSTING, FEDERATION and OPERATOR_API) and the agent registry (`agent`, ATTESTATION_ISSUER). The versions it
expects are the scripts the release's own jars carry - the same `db/migration` files `oidf-db-migrate.jar` runs - read
once per class-loader copy; no version is written down anywhere else. It reads the family's rows of
`oidf_schema_history` as PingFederate's role, through `search_path` as the stores find their tables, and compares them
as `validate` does:

| What the database is | Development | Production |
|---|---|---|
| current: every script applied (or adopted) with its checksum | starts | starts |
| behind: a script pending, a gap, or no history at all | `FAILED_CONFIG` | `FAILED_CONFIG` |
| ahead: rows this release has no script for, and nothing else | one WARN per family, starts | one WARN per family, starts |
| drift: a checksum that differs, or a row recorded as failed | WARN, starts | `FAILED_CONFIG` |
| the role may not read `oidf_schema_history` (SQLState 42501) | `FAILED_CONFIG` | `FAILED_CONFIG` |
| the database cannot be reached | `FAILED_DEPENDENCY`, retried | `FAILED_DEPENDENCY`, retried |

The component's reason names the family, the newest version the release ships and the newest the database records,
and the command to run: `migrate --family <family>` (with `adopt` for a database that has tables but no history).
`FAILED_CONFIG` is not retried: after migrating, **restart PingFederate**. Each check emits the catalogued
`platform.schema.checked` event (family, verdict, both heads). A pass is remembered per database and family, so the
three federation components ask once. There is no switch to turn it off.

Ahead starts on purpose: in a rolling upgrade the database is migrated first and the old nodes keep running against it.
That holds only while every migration is compatible with the release before it - a new table or a new nullable column,
never a dropped or renamed one in the same release that stops writing it. A release that breaks that says so in its
"Before you deploy".

The check reads `oidf_schema_history` as the runtime role, so that role needs `SELECT` on it: `grants` prints and
applies it from 0.7.0. **Upgrading: rerun `grants --runtime-role <role> --apply` before the new PingFederate starts**,
or every JDBC component is `FAILED_CONFIG` naming the grant.

The `ldm` SSF dialect lives in the Identity Object Model's schema, which the model repository (idp-scim-service) owns
and records in its own ledger, `idm.schema_migration`. The SSF store checks that ledger instead, by name
(`platform.jdbc.IomLedger`): `0000-base-schema` and `0001-add-shared-signals-ssf`, and with `receiverInstanceRegistry`
on, `002-backfill-may-attrs` and `006-add-agent-instance-registry` too. A name missing is `FAILED_CONFIG` naming it;
the role needs `SELECT` on `idm.schema_migration`. Checksums are not compared there: the model repository re-applies a
migration with `ON CONFLICT (name) DO UPDATE SET checksum`. The Identity Object Model's other readers outside the
component lifecycle - the instance-registry datasource plugin and the device-enrolment service - are not checked
(finding F-0510).

### The Identity Object Model's ledger

An Identity Object Model database that was not built through the model repository's `migrations/` has a ledger that
is empty or missing, even where the schema is there. Two are known: the live directory, built from
`spec/identity-object-model.sql` directly (idp-scim-service, `migrations/006-add-agent-instance-registry.test-report.md`:
"0000 and 002 genuinely were never recorded there"), and a database built from `docker-entrypoint-initdb.d` scripts,
as idp-pingfed-ssf-servelet's `ldm-store` is. **From 0.7.0 an `ldm` SSF store on such a database is `FAILED_CONFIG`
until its ledger names what the store needs** (finding F-0511). For each name the start-up check reports:

**The model repository's reconcile script does this for you.** idp-scim-service's `scripts/reconcile-ledger.sql`
(merged to its main as commit `e9652bd`, PR #2, 2026-10-09) is a plain psql script. By default it
only reports, and a SELECT-only role can run it: for each migration it says recorded, present (record it), absent
(apply it) or partial (investigate), and prints the psql commands to apply the absent ones in order. Run with
`PGOPTIONS='-c ldm.reconcile_mode=record'`, it inserts the ledger rows (name and the file's checksum) for the present
migrations only. It never applies a migration and never records an absent or partial one. In a
`docker-entrypoint-initdb.d` directory, put `SET ldm.reconcile_mode = 'record';` first and the script after it, as the
last init script. Note from the model repository: `0000-base-schema` and `0001-add-shared-signals-ssf` cannot be
re-applied (unguarded DDL, plain INSERTs), so a database that already has them must record them, never re-run them;
everything from 002 on can be re-applied safely. The steps below are what the script automates.

The start-up check reports, for each name:

- **Its effect is not there:** apply that migration from the model repository. Each records itself.
- **Its effect is already there** (the database was built from the spec SQL that migration came from): record it, with
  the checksum from the `INSERT INTO idm.schema_migration` line at the end of that migration's file, as the model
  repository's DBA role:

  ```sql
  INSERT INTO idm.schema_migration (name, checksum)
  VALUES ('0000-base-schema', 'sha256:<from 0000-base-schema.sql>')
  ON CONFLICT (name) DO NOTHING;
  ```

  The ledger table itself is `CREATE TABLE IF NOT EXISTS` at the top of every model migration; create it that way
  first if it is missing. Ask the model repository's owner which migrations a spec-built database already carries;
  that report records that the live directory has never had `002-backfill-may-attrs` applied (every class's
  `may_attrs` is empty), so 002 there is applied, not recorded.
- **Never re-apply `002-backfill-may-attrs` after `006-add-agent-instance-registry`.** 002 sets `may_attrs`
  absolutely and drops 006's `pingoneUserId` from `involvedParty` (`libs/device-instance/src/test/resources/idm/README.md`,
  "Ordering matters"). Where 002 is missing and 006 is
  applied - the live directory with `receiverInstanceRegistry` on - apply 002, then re-run 006, which is idempotent.

Then restart PingFederate.
