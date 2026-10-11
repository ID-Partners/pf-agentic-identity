# reference/single

One PingFederate on the production profile, on PostgreSQL 17 over TLS. [../README.md](../README.md) has the slots, the
issuer and what `up.sh` generates.

```sh
REF_SLOT=3 ./up.sh && REF_SLOT=3 ./smoke.sh && REF_SLOT=3 ./down.sh
```

| Service | Image | What it does |
|---|---|---|
| `postgres` | PostgreSQL 17, by digest (`../lib/images.env`) | `ssl=on`; `pg_hba.conf` has `hostssl` lines only, so a plaintext connection is refused ("no pg_hba.conf entry ... no encryption") |
| `db-roles` (job) | the same | `../lib/db-roles.sql` as the superuser over `verify-full`: roles `oidf_migrator`, `pf_runtime`, `pf_clients`, database `oidf`, schema `pf`, as [database-migrations.md](../../../docs/operator/database-migrations.md#roles) |
| `db-migrate` (job) | Temurin 17 JRE, by digest | `oidf-db-migrate.jar migrate`, `grants --runtime-role pf_runtime --apply`, `validate`, as `oidf_migrator` over `verify-full` with a password file |
| `pf-secrets` | PostgreSQL's (for `install`) | puts the age identity and the SSF secret key on a tmpfs, owned by PingFederate's uid, and holds it |
| `pingfederate` | this repository's image, target `capability`, production profile | `STANDALONE`; boots from the mounted `data.zip.age` (`PF_ARCHIVE_FILE`, `PF_ARCHIVE_AGE_KEY_FILE`); data store `oidfruntime` on `verify-full`; SSF on the `tables` dialect with the `jdbc` lease backend; `in-memory-state` accepted (no Redis on one node) |

PingFederate starts only after both jobs completed (`service_completed_successfully`): a database the release's
migrations have not reached never meets it.

`smoke.sh` waits for ready, reads the start-up audit in `server.log` (`STANDALONE`, production, no code refusal, no
component refused or failed) and takes a `client_credentials` token for `reference-smoke`, every call checked against
the stack's CA. `/agentic-identity/info` carries the same topology, but in production it needs an operator token
DPoP-bound to the caller, which this example does not configure.

Run on 2026-10-08 (Docker Desktop 29.4, macOS, slot 30): smoke passed at 05:04:39Z; the audit said `STANDALONE (from
OIDF_CLUSTER_MODE ...); OAuth clients in files; lease backend jdbc` and `SSF READY`.
