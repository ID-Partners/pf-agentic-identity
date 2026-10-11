# Operator documentation

What someone who runs a PingFederate built from this repository needs: how to move between releases, and,
from Phase 7 of the production programme, installation, the reference stacks, the deployment profile,
clustering, the database and Redis, observability, a hardening checklist and the runbooks (plan items D-5 and
D-7).

What is here now:

- [clustering.md](clustering.md) - from 0.7.0, how a node reads its topology (`OIDF_CLUSTER_MODE`, else PingFederate's
  `pf.operational.mode`), what a clustered production node needs - Redis and data stores for every store, JDBC OAuth
  client storage and a lease backend - and that a console node runs no background jobs.
- [components.md](components.md) - from 0.6.0, the nine components and their `OIDF_<NAME>_ENABLED` switches: how an
  unset switch is inferred in each profile, what a component's surfaces answer while it is failed or off, the retry
  with backoff, and what PingFederate does with an `init` that throws.
- [database-migrations.md](database-migrations.md) - from 0.7.0, `oidf-db-migrate.jar`: the migration families, the
  `info`, `validate`, `migrate`, `adopt` and `grants` commands, a migrator role with DDL and a runtime role with rows
  only, and the upgrade from a 0.6.x database PingFederate or an operator built. 0.7.0 PingFederate creates no table.
- [database.md](database.md) - from 0.7.0, how the modules reach PostgreSQL: PingFederate data stores in production,
  the deadline on every statement and the retries, and the PgJDBC URL parameters (`connectTimeout`, `socketTimeout`,
  `loginTimeout`, `tcpKeepAlive`, `sslmode=verify-full` with `sslrootcert`) and role-level `statement_timeout` to set.
- [deployment-limits.md](deployment-limits.md) - what a release does not support yet, and what goes wrong if
  you deploy it that way: from 0.7.0, a cluster supported in one shape and only for what the cluster suite
  verified, the `ldm` dialect single-node, and the device path until 0.9.0.
- [health.md](health.md) - the health endpoints, `/agentic-identity/health/{live,ready}`, the detail and
  `/agentic-identity/info`: what ready means and who may read the detail.
- [issued-details.md](issued-details.md) - from 0.6.0, what holds the `authorization_details` a token carries to the
  client attestation's ceiling: the issuance criterion to add to your access-token mappings, the token endpoint's
  response belt, the refresh that must repeat its details, and what each refuses.
- [logging.md](logging.md) - from 0.7.0, where this repository's lines land in `server.log`, the `ctx[tid=.. rid=..
  traceparent=..]` each ends with (`OIDF_LOG_CORRELATION`), the reference a refusal gives (PingFederate's own ids), the
  logger names and levels, and the line each war writes as it stops.
- [metrics.md](metrics.md) - from 0.7.0, `/agentic-identity/metrics`: Prometheus text for an `oidf.metrics.read`
  scrape, per node, every loaded copy's metrics under a `copy` label, every family (SSF backlog, leases, keys, Redis,
  JDBC) and the alerts to start from; production scraping waits on U-0566.
- [operator-authentication.md](operator-authentication.md) - how the operator APIs will take PingFederate-issued,
  DPoP-bound access tokens with a scope per surface (built in 0.6.0, used from plan item S8b): what PingFederate
  needs, the settings, every refusal.
- [startup-audit.md](startup-audit.md) - the banner each war logs as it starts: version, profile, accepted risks,
  insecure TLS and each component's state, line by line, and what its listener does at shutdown.
- [upgrading/](upgrading/) - one guide per move between releases. [0.1.5-to-0.3.0.md](upgrading/0.1.5-to-0.3.0.md)
  is the move from the last PingFederate 13.0 release to the first 13.1.3 one;
  [0.5.0-to-0.6.0.md](upgrading/0.5.0-to-0.6.0.md) the move to the release that enforces the production profile, the
  preflight run first; [0.6.x-to-0.7.0.md](upgrading/0.6.x-to-0.7.0.md) the move to the release whose database is
  migrated by `oidf-db-migrate.jar`, `adopt` first.

The release notes themselves live in [docs/releases](../releases/README.md); each release's "Before you deploy"
list is the short form of its upgrade guide. Until the operator set exists, the module READMEs and
[docs/federation/operations.md](../federation/operations.md) are where the operational detail is.
