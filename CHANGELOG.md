# Changelog

Every release of pf-agentic-identity, newest first, in the shape [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
describes: one heading per version with its date, and a few lines on what the version was for. A version is a
tag of this repository (`git tag -l 'v*'`); the dates are the tags' own. Where a version has release notes
under [docs/releases](docs/releases/), the heading links to them. The convention for the version in progress:
it sits under `Unreleased` with the version the poms declare (a `-SNAPSHOT`); the release's pull request gives
it the heading `[<version>] - <date>`, the date the tag is cut, and leaves an empty `Unreleased` for the next
`-SNAPSHOT`.

## [Unreleased] - 0.8.0-SNAPSHOT

## [0.7.0] - 2026-10-11

Phase 4 of the production programme, durable, clustered and rotatable: a console and engines with JDBC client storage,
`jdbc` leases and SSF on the `tables` dialect, verified by a cluster suite for PingFederate's clients and tokens, the
leases and SSF's transmitter (federation, attestation, automatic registration and the SSF receiver are not verified on
a cluster: F-0601); migrations run by `oidf-db-migrate.jar`, a new release asset, with a start-up check per store; the
SSF delivery engine, leased, pooled, held and fanned out through an outbox, with a shared receiver inbox; federation
signing keys rotated without a restart and subordinate keys pinned; a Prometheus endpoint, one logger and correlation
ids; SpotBugs in every build; and boot-smoke, conformance and the cluster suite as licensed jobs a release needs
green. Notes, and the upgrade guide they link: [docs/releases/0.7.0.md](docs/releases/0.7.0.md).

- `tools/db-migrate/pom.xml`: the jar plugin rewrites `oidf-db-migrate.jar` every build (`forceCreation`), as every
  other shaded module's already did, so the release's rebuild makes the bytes its verify build made; the dry run had
  stopped at the byte comparison on it (F-0606).
- The image's `age` and `age-keygen` are age 1.3.2 built from its module source with Go 1.27.2 (the
  `golang:1.27.2-alpine3.24` image, pinned by digest), in the Dockerfile's new `age-build` stage, instead of age's
  own release binaries, which are built with go1.27.0 and failed the image scan with two critical and eight high
  standard-library advisories (F-0708). `go install` checks the module and its dependencies against the Go checksum
  database; the image carries the two binaries and age's licence and no Go.
- `tools/pf-version-check.py` accepts one image FROM besides the pinned PingFederate one: the golang toolchain the
  age build uses, which must be pinned by digest. Dependabot's docker entry bumps it with the PingFederate image.

- `Budget.take()` (libs/platform) takes a request with one atomic update instead of a compare-and-set loop. Behaviour
  is unchanged; the 100% coverage gate no longer needs two threads to collide to reach the retry branch, so the
  java job stops failing at random on it (F-0436).

- `services/cluster-suite` and `reference/cluster/suite.sh`: the cluster verification suite (C-7) on the reference
  cluster - topology, the client storage windows, lease failover, SSF push across two engines with one killed, Redis,
  PostgreSQL, engine and console faults under load, and a rolling replacement of every node - writing `results.json`
  and keeping every log.
- `licensed.yml`'s `cluster` job: the suite weekly (Wednesdays 07:13 UTC) and by hand, on the self-hosted runner's
  licence file; a release needs it green on the tagged commit beside boot-smoke and conformance.
- A cluster of a console and engines with JDBC client storage, the `jdbc` lease backend, one Redis and SSF on the
  `tables` dialect is supported from 0.7.0 for PingFederate's clients and tokens, the leases and SSF's transmitter;
  federation, client attestation, automatic registration, the SSF receiver, hosting, the operator APIs and FAPI are
  not verified on a cluster (F-0601, U-0601); `docs/operator/deployment-limits.md` says what else is not (F-0007).
- The SSF store's start-up line says "cluster-safe" only when its push stream leases are shared (F-0125).
- reference/cluster: HAProxy follows the engines by name through Docker's DNS, so a replaced engine comes back into
  rotation (F-0603), and `up.sh` restarts each engine once after its first replication so it trusts the stack's CA
  (F-0585).
- The image's entrypoint refuses an archive (or a `PF_ARCHIVE_AGE_KEY_FILE`) that exists but its uid cannot read, and
  says so with the uid and the file's mode and owner; it used to call an unreadable archive plaintext. The reference
  stacks run on Linux hosts as well as Docker Desktop: `data.zip.age` is `0644` ciphertext, and every secret reaches a
  non-root container as its own `0400` copy (reference/README.md, "File ownership on Linux").

- `.github/workflows/licensed.yml` replaces `conformance-federation.yml`. **boot-smoke**, nightly: the image built from
  the commit and booted under a licence, live, ready, discovery and a token from PingFederate's own token endpoint,
  then `conformance/fail-soft-matrix.sh`'s negative boots. **conformance**, weekly: FAPI 2.0, FAPI-CIBA, SSF, SSF CAEP
  Interop and both OpenID Federation plans, one at a time, each against `conformance/expected/<entry>.json` with
  `--strict-expectations`. Both by hand too (`gh workflow run licensed.yml -f suites=all`).
- The jobs run only on the self-hosted runner (`[self-hosted, pfai-linux]`) and read the Ping DevOps credentials from
  `~/.pingidentity/config` of its `runner` user; there is no repository secret, environment or variable for the licence.
  Without the file every licensed job is skipped with a notice. What a job prints or keeps is scrubbed of the user
  and key first (`tools/ci/licensed-scrub.py`).
- Release refuses a tag unless `boot-smoke` and a `conformance (<entry>)` for every expectations file are green on its
  commit (step "a green licensed run on this commit"); a dry run warns and carries on.
- `fail-soft-matrix.sh` gains two production-profile boots, from an age-encrypted copy of the rig's archive: a store in
  memory without the `in-memory-state` risk (`ATTESTATION_ISSUER` refused), and a `CLUSTERED_ENGINE` node on
  PingFederate's XML client storage (`FEDERATION` refused). Each checks the `platform.profile.refused` event, the
  component's 503, ready 503, live 200 and PingFederate's own token endpoint.
- `tools/ci/licensed-conformance.sh <entry>` runs one plan the way CI does on any machine with Docker and a licence:
  the suite joins the rig's network and answers to `host.docker.internal`, so the OP plan runs on Linux too.

- Every statement the federation, agent, instance-registry and SSF stores make carries a query timeout from a
  deadline (10 seconds per operation), multi-statement changes run in one transaction, and reads are retried on a
  lost connection, a serialisation failure or a deadlock (DB-5).
- One place makes a store's DataSource (`platform.jdbc.DataSources`, with `PfDataStores` for PingFederate data
  stores); the copies in pf-integration and the SSF servlets are gone. A direct JDBC URL is refused in code under
  the production profile, as its catalogue already classed it.
- rar-model reads and writes JSON with platform's `Json`; its own copy is deleted (F-0130). Fingerprints are unchanged.
- New operator page, [docs/operator/database.md](docs/operator/database.md): PgJDBC timeouts, `sslmode=verify-full`
  and a role-level `statement_timeout`.

- Leases (plan item C-4): `OIDF_LEASE_BACKEND` chooses `local` (the default), `jdbc` (table `oidf_lease`, migration
  V10, on PostgreSQL's clock) or `redis`; each lease carries a fencing token that rises whenever a new holder takes it.
  `ManagedExecutors.leaderEvery` runs a job on the node that holds its lease.
- The registration expiry sweeper and the SSF poll receiver run on `leaderEvery`, so with a `jdbc` lease a clustered
  production node serves AUTO_REGISTRATION and SSF_RECEIVER. S10A's leased push delivery lets a clustered node serve SSF on the
  `tables` dialect (F-0516). A clustered production node takes `redis` leases only with the new `redis-lease` risk (F-0515).
- A Redis URL's userinfo is decoded once (F-0180); a Redis write that outlives its command's deadline is ended
  (F-0181); a hand-set executor claim no longer stops a job (F-0196); each federation service warms its own
  subordinate cache (F-0202); CI fails when platform's live Redis or lease suites skip (F-0182).

- New release asset `oidf-db-migrate.jar` (`tools/db-migrate`): applies every module's versioned migrations, by
  family, with a history in `oidf_schema_history`, one transaction per script and a PostgreSQL advisory lock so two
  runners never interleave. Commands `info`, `validate` (exit 1 on checksum drift, gaps or unknown versions),
  `migrate [--family F] [--target V]`, `adopt --family F --baseline V` (records a database built by hand or by
  0.3.0-0.6.x only if its tables, columns, constraints and indexes match exactly) and `grants --runtime-role R
  [--apply]` (the runtime role's row privileges, no DDL). It refuses a JDBC URL without TLS unless
  `--allow-plaintext`, takes the password only from a file, and prints no secret. Our own runner, not Flyway
  ([docs/operator/database-migrations.md](docs/operator/database-migrations.md)).
- The SSF tables store's schema is the `ssf` migration family: V300 (the four tables), V301 (`owner_client_id` and the
  three SSF 1.0 stream members) and V302 (`push_auth_header` becomes `TEXT`). `JdbcSsfStore` runs no DDL and
  PingFederate no longer creates or alters the SSF tables at start-up, so two nodes no longer race an
  `ALTER TABLE` (F-0018, advanced).
- Stream management refuses a push `authorization_header` over 8192 characters with a 400; any accepted header fits
  sealed at rest (F-0404).
- The BOM no longer manages H2 (F-0255).

- New endpoint `/agentic-identity/metrics` (plan item O-5): every metric this repository counts on the node, in the
  Prometheus text format (`text/plain; version=0.0.4`), for an operator token with `oidf.metrics.read` (route
  `metrics.read`). `GET` and `HEAD`; `Cache-Control: no-store`. Served by `pf-runtime.war` on the runtime port and by
  `gm-api.war` on its own. New operator page: [docs/operator/metrics.md](docs/operator/metrics.md).
- A successful scrape emits `admin.request.authorised` but is not written to PingFederate's audit log; a refused one
  is, as on every operator route.
- Every series carries a `copy` label - `webapp`, `engine`, `rar`, `cibasim` or `other` - naming the loaded copy of
  the code that counted it. The engine's copy, where the OGNL criteria and token mappings decide, and the RAR plugin's
  are rendered beside the webapp's (F-0170): each hands its metrics to the webapp on the request, in JDK types only.
  A metric label may no longer be named `copy`.
- New families: the SSF backlog by stage (`oidf_ssf_backlog_sets`, `oidf_ssf_backlog_oldest_seconds`, sampled every
  `OIDF_METRICS_SAMPLE_SECONDS`, new, default 15, in the [metrics](docs/configuration/metrics.md) catalogue) and
  `oidf_ssf_sets_dropped_total`; lease calls and fencing refusals; the federation signing keys by state and their ages;
  Redis commands, permit waits and failovers; JDBC connections, statements, transactions and retries. The backlog's
  `outbox` stage counts the emission outbox (S10d); S10c's `oidf_ssf_stream_paused_total{cause}` and
  `oidf_ssf_queue_trimmed_total` and S10d's `oidf_ssf_outbox_appended_total` and `oidf_ssf_outbox_fanned_out_total{outcome}`
  are catalogued. Every family is catalogued under `"metrics"` in its module's event catalogue.
- New setting `OIDF_METRICS_CLIENT_IDS` (U-0566): the PingFederate clients whose access tokens bound to nothing may
  scrape `/agentic-identity/metrics` in production, with `oidf.metrics.read`. It is the one production exception to
  the operator APIs' sender-constraint, and only on this route: every other route, and this one for any other client,
  still refuses an unbound token. Each such scrape counts in `oidf_operator_unbound_scrapes_total`. Unset, nothing
  changes. rs-validation's `DelegatedTokenValidator.Builder` gains `allowUnboundWhen(Predicate)` for it.

- Every line the shipped code writes goes through libs/platform's `PlatformLog` (plan item O-6): the RAR plugin and
  gm-api leave `java.util.logging`, whose lines reached `server.log` as `ERROR [SystemErr]` whatever their level
  (F-0075, F-0520), and 93 classes leave commons-logging. `tools/log-scan.py` refuses any other logger in shipped code
  in CI.
- Every line ends with `ctx[tid=.. rid=.. traceparent=..]`: PingFederate's tracking id and request id and a W3C
  `traceparent`, the ones the thread has. `OIDF_LOG_CORRELATION=off` (new, in the
  [platform-log](docs/configuration/platform-log.md) catalogue) turns it off for a `log4j2.xml` that prints
  `%X{httprequestid}` and `%X{traceparent}` itself.
- A new filter, `OidfCorrelation` (`CorrelationFilter`), first of this repository's in `pf-runtime.war` at `/*` and
  added by the lifecycle listener in `oidf.war` and `gm-api.war`, puts the request's `traceparent` on the thread - the
  one it sent if valid, else a new one - and every outbound call sends a child of it. Background jobs, start-up and
  shutdown run under ids of their own (`oidf-<job>-<8 hex>`). PingFederate's audit lines written through the SDK keep
  `traceparent`.
- A refusal's reference is PingFederate's own id: the tracking id where the thread has one, else the request id
  (the caller's own correlation header's value when PingFederate's `requestHeaderForCorrelationId` names one), else
  `oidf-<16 hex>`; it was `oidf-<8 hex>` at our filters (F-0395). The image's `server.log` pattern now prints
  `%X{httprequestid}` after `%X{trackingid}` (`%d %X{trackingid} %X{httprequestid} %-5p [%c] %m%n`; PingFederate's
  stock pattern printed the tracking id only), so the reference finds PingFederate's own lines for the request as well
  as this repository's `ctx[rid=..]` lines. The attestation issuer's `X-Correlation-Id` is the same
  reference, no longer a random UUID.
- The lifecycle listener's shutdown lines reach `server.log` at a JVM stop (F-0210): one before the closes and one
  after, naming any still running when the budget ran out.
- The RAR plugin's per-request `RAR governance:` line, and gm-api's `query`, `evaluate`, `MCP evaluate` and
  `MCP search` lines, are `DEBUG`.
- New operator page: [docs/operator/logging.md](docs/operator/logging.md).

- `reference/single` and `reference/cluster`: docker compose stacks that run PingFederate with the modules on the
  production profile - one node on PostgreSQL 17 over TLS; or a console and two engines behind HAProxy with Redis
  (ACL), OpenBao and an agent per node, profiles `spire` and `mdm` - with the roles, migrations and client storage
  as jobs before PingFederate starts, an age-encrypted archive from `reference/terraform`, and smoke checks (C-6).
- Slot ports: `REF_SLOT` and the rig's `PF_RIG_SLOT` give each stack or rig twenty ports from 57100 + 20 x slot.
- The rig serves its own runtime certificate, from its own CA, naming `localhost`, `host.docker.internal`, the rig and
  the issuer's host, and PingFederate trusts that CA (F-0362).
- The war assembler stamps every staged jar with one entry time, so one stage assembles one war (F-0450).
- Build's new `reference-data-tier` job checks the cluster's data tier on every pull request, and the lint job parses
  every reference compose file.

- SSF push delivery takes one stream at a time by lease (plan item S10a): each push stream has a row in
  `ssf_stream_lease` (SSF migration V303), claimed with `FOR UPDATE SKIP LOCKED` and a fencing epoch, renewed while the
  node delivers, and every ack, failed attempt and dead-letter pause fenced on it. Each stream has one deliverer across
  nodes, the least recently served stream goes next, and a POST ends before its lease could. New setting
  `OIDF_SSF_STREAM_LEASE_SECONDS` (30, 15-300); new event `ssf.push.stream_lease_lost`; new metrics
  `oidf_ssf_stream_lease_claimed_total` and `oidf_ssf_stream_lease_lost_total`.
- A clustered production node serves SSF on the `tables` dialect (F-0516) and refuses it on `ldm`, whose leases are in
  each node's memory.
- SETs go in the order they were queued on the `tables` and in-memory stores (`ssf_pending_sets.seq`, V304; F-0095).
- The stream cap per receiver and the verification interval hold across nodes: the cap is counted and the stream
  inserted in one transaction (F-0386), and the `tables` store keeps a stream's last verification in
  `ssf_streams.last_verification_at` (V305; F-0385).

- SSF push delivery runs on a pool (plan item S10b): each node's dispatcher claims as many push streams as it has free
  workers (`OIDF_SSF_PUSH_WORKERS`, 4, 1-32), and each worker posts a batch of one stream's SETs in queue order
  (`OIDF_SSF_PUSH_BATCH_SIZE`, 50, 1-50) before handing the stream back behind the streams served less recently.
- Each receiver answer is classified as RFC 8935 reads it: 202 delivered; 200 and 204 delivered with the event
  `ssf.push.delivered_nonstandard`; a 400 with `err` exactly `invalid_request` moves that SET to the new dead-SET
  record and the batch goes on; `invalid_issuer`, `invalid_audience`, 404 and 410 pause the stream with the reason;
  anything else, a 400 with another or no `err` included, is retried.
- A refused endpoint pauses the stream instead of dropping each SET; a host that does not resolve is retried (F-0405).
- Retries back off with full jitter between `OIDF_SSF_PUSH_RETRY_BACKOFF_SECONDS` (now 1-60) and the new
  `OIDF_SSF_PUSH_RETRY_BACKOFF_MAX_SECONDS` (900, 60-3600), raised by a receiver's `Retry-After` (seconds or an
  HTTP-date), clamped to the maximum with the event `ssf.push.retry_after_clamped`.
- SETs a receiver refused for good - a push `invalid_request`, a poll `setErrs` entry - are kept in `ssf_dead_sets`
  (SSF migration V306) for `OIDF_SSF_DEAD_SET_RETENTION_SECONDS` (604800, 3600-7776000), at most 10,000 per stream,
  instead of being deleted (F-0361); events `ssf.push.set_dead` and `ssf.poll.set_dead`; metrics
  `oidf_ssf_push_attempts_total{outcome}` and `oidf_ssf_dead_sets_total{source}`.
- A poll answer stops short of 4 MiB, and the receiver halves `maxEvents` after an answer over its cap and doubles it
  back after three clean polls (event `ssf.receiver.poll_shrunk`); `OIDF_SSF_POLL_MAX_EVENTS` is bounded 0-1000
  (F-0406).
- The SSF receiver sends its bearer only to the configuration URL's origin and those in the new
  `OIDF_SSF_RECEIVER_TRANSMITTER_ORIGINS` (F-0407).

- A paused SSF stream now hears and holds the events raised for it, and sends them in order when it is enabled
  again; a disabled stream holds nothing, and disabling one deletes its queue (SSF 1.0 §8.1.2.1, plan item S10c,
  F-0017). Each queue is bounded by the new `OIDF_SSF_STREAM_QUEUE_MAX` (10,000), oldest first, with a WARN and an
  `ssf.stream.queue_trimmed` event per stream.
- A status change the receiver did not ask for - the push engine's, the inactivity sweep's or an operator's - queues
  a stream-updated SET (SSF 1.0 §8.1.5, `sub_id` the stream) at the head of the stream's queue. A stream that is not
  enabled is sent its stream-updated SETs and nothing held behind them.
- A push stream is paused once its pushes have failed for the new `OIDF_SSF_PUSH_PAUSE_AFTER_SECONDS` (24 h) without a
  delivery, not after five failures of one SET. `OIDF_SSF_PUSH_RETRY_MAX_ATTEMPTS` is removed.
- `inactivity_timeout` is enforced (F-0389): the receiver's management calls and polls restart it, and the leader job
  `ssf-stream-sweeper` pauses an enabled stream whose receiver has been idle for longer.
- Every write of a stream compares and sets its row version (SSF migration V308): a PATCH, PUT or status change that
  meets another write re-reads the stream and applies itself again, and after three conflicts answers 503 with
  `Retry-After: 1`.
- New operator API `/ssf/admin/streams/*` on the operator scope `ssf.admin`: `GET {id}`, `POST {id}:pause`,
  `POST {id}:resume` and `POST {id}/sets:retry-dead`. A stream an operator paused keeps its status until an operator
  resumes it: every status change its receiver asks for is a 403.
- New events `ssf.stream.status_changed`, `ssf.stream.queue_trimmed` and `ssf.stream.update_conflict`; new counters
  `oidf_ssf_stream_paused_total{cause}` and `oidf_ssf_queue_trimmed_total`.

- An SSF event is one row of an emission outbox, and a fan-out worker on any node mints and queues its SETs, one per
  subscribed stream, in that row's own transaction (plan item S10d, F-0017). On the `tables` store the outbox is
  `ssf_emission_outbox` (SSF migration V309), shared by every node; a crash part way rolls back and the row is fanned
  out again, and a second fan-out of a row to a stream queues nothing. One subject's events go out in the order they
  were written, on every node.
- The audit source, the logout filter and the hooks (`SsfEventBridge`) only queue the event in a bounded hand-off in
  memory: no store, signing or Kafka on PingFederate's thread. An `ssf-outbox-writer` thread writes the hand-off to the
  outbox and keeps what a store that is down refuses, so a store blip no longer drops events.
- `POST /ssf/events:emit` and SCIM still fan out before they answer, so their answers and SCIM's
  account-disabled-before-removal order are unchanged.
- A logout hint's replay key is kept in `ssf_logout_replay` on the `tables` store: a hint replayed to another node
  raises nothing there (F-0402).
- The Kafka producer is closed when the webapp shuts down, after the workers that publish to it (F-0201).
- New settings `OIDF_SSF_OUTBOX_WORKERS`, `OIDF_SSF_OUTBOX_MAX_ATTEMPTS` and `OIDF_SSF_EMISSION_QUEUE_CAPACITY`; new
  counters `oidf_ssf_outbox_appended_total` and `oidf_ssf_outbox_fanned_out_total{outcome}`; new event
  `ssf.outbox.write_failed`; new `ssf.set.dropped` reasons `queue_full`, `fanout_failed` and `expired`.

- The SSF receiver admits each inbound SET to an inbox keyed by its issuer and `jti` before it answers: a pushed SET
  is answered with an empty 202 only once it is stored, and with 503 and `Retry-After` when it cannot be (plan item
  S10e, F-0043). On the `tables` store the inbox is `ssf_receiver_inbox` (SSF migration V307), shared by every node.
- The receiver's handlers run from the inbox on every node's `ssf-receiver-actions` worker: a failure is tried again
  after 5 s, doubling to 300 s, a handler that succeeded never runs again for that SET, and after
  `OIDF_SSF_RECEIVER_ACTION_ATTEMPTS` (10) failures the SET is dead (`ssf.receiver.action_dead`,
  `oidf_ssf_receiver_action_dead_total`). The grant and instance-registry handlers now throw a failure instead of
  logging it.
- The poll receiver acknowledges from the inbox: whichever node holds the poll lease sends what any node admitted and
  has not acknowledged, so an acknowledgement is no longer lost with its node.
- New settings `OIDF_SSF_RECEIVER_ACTION_ATTEMPTS` and `OIDF_SSF_RECEIVER_INBOX_RETENTION_SECONDS`; new gauges
  `oidf_ssf_receiver_inbox_pending` and `oidf_ssf_receiver_inbox_oldest_pending_seconds`; new events
  `ssf.receiver.action_retry` and `ssf.receiver.action_dead`.

- Every federation signer reads PingFederate's current signing key through one shared `FederationKeys`: the Entity
  Configuration and the other federation endpoints, the explicit registration response, the self-anchor's own keys
  and the SSF transmitter's SETs. A key PingFederate rotates signs within `OIDF_FEDERATION_KEY_REFRESH_SECONDS`
  (new, default 30, 0 to 300) without a restart; until 0.7.0 the federation servlet read the key once, at start-up,
  and the SET minter on its first SET (F-0011, part).
- A signer holds one immutable key snapshot, so a JWS header's `kid` always names the key that signed it
  (OpenID Federation 1.0 §3).
- `OIDF_FEDERATION_SIGNING_ALG` and `OIDF_SSF_SIGNING_ALGORITHM` take `ES256` (PingFederate's P-256 key) and `ES384`
  (its P-384 key) beside `RS256` and `PS256`.
- The explicit registration response is signed with `OIDF_FEDERATION_SIGNING_ALG`, as the federation endpoints sign;
  it was always RS256 (F-0039).
- The Entity Configuration's `jwks` carries the current key and every retired key still in its grace and not revoked,
  each `kid` once; with `OIDF_FEDERATION_HISTORICAL_KEYS` off the retired keys are kept in memory for the same grace.
  When PingFederate goes back to a key a node already moved off, the key that node signed with until then stays in
  its `jwks` for the grace too. A key PingFederate replaces under the same `kid` signs from the next read, with a
  warning in the log.
- New events `federation.key.changed` (audited: the old `kid`, the new one and the algorithm) and
  `federation.key.read_failed`. A key that cannot be read leaves the last one signing for at most 300 seconds past its
  refresh, then signing answers 503.
- The init-params `signingAlgorithm` of the federation servlet and of `/federation/register` are removed.

- A key PingFederate starts signing with is published in the Entity Configuration's `jwks` within 30 seconds, and the
  federation signs with it only once it has been published for `OIDF_FEDERATION_KEY_ACTIVATION_DELAY_SECONDS` (new,
  default 3600, 0 to 86400), as OpenID Federation 1.0 §11.2 orders a rotation (F-0011).
- One node at a time - the holder of the new `federation-key-observer` lease - records the keys PingFederate
  publishes in `federation_key_observed` (migration V104, federation family) on the database's clock, and moves the
  cluster's active key; every node signs with that key. Nothing else writes the key history now, so two nodes reading
  different keys can no longer turn it back.
- The active key never goes back to an older key while PingFederate still publishes the newer one; it returns to an
  older key only after the newer has gone unpublished for a whole delay (`federation.key.returned`).
- A node whose PingFederate has no private key for the active key signs with its own current key and publishes it
  (`federation.key.activation_skipped`).
- New events `federation.key.observed`, `federation.key.activated` (audited), `federation.key.returned` (audited, WARN)
  and `federation.key.activation_skipped`; new metrics `oidf_federation_key_activations_total{kind}` and
  `oidf_federation_key_activation_skipped_total`.
- A Trust Mark is served again from the cache only while it was signed with the key the federation signs with now: a
  key switch mints the next mark anew. An own mark signed with a pending key or a retired key in its grace has status
  `active`, one signed with a revoked key `invalid`.
- `OIDF_FEDERATION_KEY_HISTORY_GRACE_SECONDS` must be at least the longest of every Trust Mark type's
  `lifetime_seconds`, `OIDF_REGISTRATION_MAX_TTL_SECONDS` and an Entity Statement's 3600 seconds.

- A Subordinate Statement about a foreign subordinate carries the keys pinned for it, never the keys its own Entity
  Configuration lists (finding F-0012, plan item S7a): whoever answered at the subordinate's URL used to control the
  keys PingFederate vouched for. The list endpoint's `entity_type` and `intermediate` filters use the pinned Entity
  Types and Intermediate flag. The refresher still looks at each subordinate's live configuration every four
  minutes, on every node, but only reports what it sees (`federation.subordinate.live_differs`).
- Two new settings in the [federation-entity](docs/configuration/federation-entity.md) catalogue:
  `OIDF_FEDERATION_SUBORDINATE_STORE` (`settings`, the default, or `database`) and `OIDF_FEDERATION_SUBORDINATE_PINS`
  (`{"<entity id>": {"jwks", "entity_types", "intermediate"}}`, parsed strictly). Both make FEDERATION present.
- Migration V105 (`federation_subordinate`, `federation_subordinate_key_change`, `federation_subordinate_audit_log`)
  in the federation family, for the database store.
- New operator routes: `GET /federation/admin/subordinates` (`?entity_id=` with this node's last look at its URL),
  `GET /subordinates/audit` on `oidf.admin.read`; `POST /subordinates` (enrol), `/subordinates/keys` (re-pin, with the
  version read and a reason) and `/subordinates/remove` on `oidf.admin.subordinates`. Keys are pinned only when the
  subordinate's live configuration is self-signed with one of them (422 otherwise), unless `force` is true with a
  reason. Events `federation.subordinate.enrolled`, `.changed`, `.removed`, `.refused` (audit) and
  `.unpinned_served`; counter `oidf_federation_subordinate_changes_total{action, outcome}`.

- A subordinate's pin now changes only on an operator's approval or at the end of a held rollover, and never because
  of what answers at its URL (finding F-0012, plan item S7b). Under the database store, `POST
  /federation/admin/subordinates` and `/subordinates/keys` answer 202 with the change's `seq` instead of applying
  it; `POST /subordinates/remove` still applies at once, and withdraws any change waiting for that subordinate.
- New operator routes: `GET /federation/admin/subordinates/changes[?status=&entity_id=]` on `oidf.admin.read`;
  `POST /subordinates/changes/approve` and `/reject` (`{"seq", "reason"?}`) on `oidf.admin.subordinates.approve`;
  `/withdraw` on `oidf.admin.subordinates`, by the operator who asked only. Approval applies a change only if the pin
  has not moved since (409 `moved`); two-person approval refuses the requester (409 `same_actor`).
- The subordinate monitor: one node, elected by the `federation-subordinate-monitor` lease, looks at each pinned
  subordinate every 240 s and records what it saw (migration V106); a configuration self-signed by a pinned key and
  listing another set becomes a rollover held for a day, then applied. States `IN_SYNC`, `ROLLOVER_PENDING`,
  `DIVERGED`, `UNREACHABLE`; FEDERATION's health part `subordinate-monitor` (READY or DEGRADED, never FAILED); gauge
  `oidf_federation_subordinates{state}`.
- Events `federation.subordinate.state_changed`, `.rollover_requested`, `.rollover_applied`, `.change_requested`,
  `.change_approved`, `.change_rejected`, `.change_withdrawn`, `.change_expired` and `.approval_refused`;
  `federation.subordinate.enrolled` and `.changed` are now emitted when the change is approved.
- Five new settings in the [federation-entity](docs/configuration/federation-entity.md) catalogue:
  `OIDF_FEDERATION_SUBORDINATE_ROLLOVER_HOLD_SECONDS` (86400; production refuses less under the database store),
  `OIDF_FEDERATION_SUBORDINATE_APPROVAL` (`single` or `two-person`), `OIDF_FEDERATION_SUBORDINATE_APPROVAL_TTL_SECONDS`
  (604800), `OIDF_FEDERATION_SUBORDINATE_MONITOR_SECONDS` (240) and `OIDF_FEDERATION_SUBORDINATE_UNREACHABLE_SECONDS`
  (900).
- `tools/pin-subordinates.py`: `capture` prints subordinates' public keys, thumbprints, Entity Types and Intermediate
  flag as pins or enrolment bodies; `compare` diffs pins with what is enrolled.

- Every module with Java main code runs SpotBugs 4.10.4 (`spotbugs-maven-plugin` 4.10.4.1) with the find-sec-bugs
  1.14.0 plugin at `verify`, effort Max and threshold Low, so `mvn verify` and the Build workflow's `java` job fail
  on a finding that `build/spotbugs/exclude.xml` does not match (F-0460).
- `build/spotbugs/exclude.xml` holds the scope rules, three pattern groups switched off with their reasons, and the
  baseline of what the first run found on 2026-10-05, grouped by pattern with what was checked.
- F-0466 records request values that reach log lines without `LogSafe`.

- Each JDBC store checks its migration family before PingFederate publishes it (plan item DB-4): the SSF `tables`
  store (`ssf`), the authority's hosted entities, Trust Marks and key history (`federation`) and the agent registry
  (`agent`) read their rows of `oidf_schema_history` and compare them with the scripts the release's own jars carry.
  Behind - a script pending, a gap, or no history - is `FAILED_CONFIG` in every profile, naming the family, both heads
  and the `oidf-db-migrate.jar` command; drift is `FAILED_CONFIG` under production and a WARN under development; a
  database ahead of the release (a rolling upgrade) starts with one WARN. Each check emits the catalogued
  `platform.schema.checked` event. No switch turns it off
  ([docs/operator/database-migrations.md](docs/operator/database-migrations.md#the-start-up-check)) (F-0018, closed).
- The SSF `ldm` store checks the Identity Object Model's own ledger, `idm.schema_migration`, by name:
  `0000-base-schema` and `0001-add-shared-signals-ssf`, and `002-backfill-may-attrs` and
  `006-add-agent-instance-registry` with `receiverInstanceRegistry` on.
- `oidf-db-migrate.jar grants` also grants `SELECT` on `oidf_schema_history`, and `grants --apply` creates the history
  table first when it runs before the first `migrate`.
- PingFederate's image stages `migrations-<version>.jar` beside `platform-<version>.jar`, which now depends on it.
  The plugins that shade platform (RAR, the instance-registry datasource, the CIBA simulator) and
  `oidf-preflight.jar` leave the check out.

- **`tools/build-showcase-docs.mjs --public`** - renders only the Markdown files the public tree exports into
  `showcase/docs.js`, keyed by source path as before, and keeps the text of any link to a file the export does not
  carry. The build without the flag is unchanged and remains the internal page's.
- **`tools/export-public.py --list-sources`** - prints the source path of every file the export carries, from the
  manifest's own selection code; the public build reads it.
- **`tools/build-microsite.py`** - refuses a `docs.js` not built with `--public`, or one carrying a document the
  manifest no longer exports, before it writes anything.
- **The showcase page** - with a public `docs.js` its documentation index lists only what it carries, and a link
  to any other document says it is not published on this site. `tools/check-showcase-links.py` refuses a public
  `docs.js` and asks for the full build.

- attestation-issuer reads `OIDF_ATTESTER_MAX_ISSUED_TTL`, `OIDF_ATTESTER_SIGNING_JWK`,
  `OIDF_ATTESTER_FEDERATION_ENTITY` and `OIDF_ATTESTER_CIMD_URL` through its settings catalogue (F-0420): the federation
  entity and the CIMD document must be an http or https URL with a host.
- `OIDF_REGISTERED_CLIENTS_ENABLED` is read strictly (F-0421): anything but `true` or `false` leaves
  `/federation/registered-clients` off, with an ERROR naming it.
- `OIDF_EVENTS_AUDIT` and `OIDF_EVENTS_MAX_VALUE_LENGTH` are read through the `pf-audit` catalogue (F-0422). A value of
  the audit switch that is neither `true` nor `false` still keeps audit on, now with an ERROR, and a legacy spelling
  (`yes`, `off`, `0` ...) keeps it on too; a value cap that is not a whole number from 16 is refused with an ERROR.
- `OIDF_AUTHORITY_ADMIN_TOKEN`'s catalogue entry moves from pf-integration's `hosted-entities` to platform-pf's
  `operator-auth`, the component that reads it; pf-integration's servlets keep an `adminToken` init-param entry of
  their own (F-0422).
- The RAR plugin reads `OIDF_RAR_EXTRA_TYPES` through its catalogue (F-0423): a list of nothing adds no type, with a
  SEVERE naming it.
- `docs/configuration/README.md` says when each setting takes effect: restart-only, which reads happen at deploy, which
  on first use, and which while PingFederate runs (F-0435).
- The image carries PgJDBC 42.7.13, PostgreSQL's JDBC driver, in `server/default/lib`, checked against a recorded
  sha256, with its BSD-2-Clause licences in `/usr/local/share/licenses/pgjdbc/` (F-0330).
- The descriptions of `OIDF_AUTO_REGISTRATION_REQUIRE_PKCE`, `OIDF_AUTO_REGISTRATION_ENCRYPTED_REQUEST_OBJECTS` and
  the `pkce-off` risk, and `OIDF_ATTESTER_CIMD_URL`'s "when it's wrong", say what the code does (F-0341, F-0296).

- A governed setting of a catalogue that belongs to several components now refuses only the components whose code
  reads it (F-0297): `OIDF_PDP_FAIL_OPEN=true` without its risk refuses `FEDERATION`, `AUTO_REGISTRATION` and
  `HOSTING`, no longer `ATTESTATION_AUTH`; the attester binding switch refuses `ATTESTATION_AUTH` alone; the SSF
  transmitter's governed settings refuse `SSF` alone. `tools/settings-scan.py` refuses a governed entry of such a
  catalogue that names no components.
- `OIDF_SSF_RECEIVER_POLL_URL` and `OIDF_SSF_RECEIVER_JWKS_URL` are forbidden as http in production, as the receiver's
  other URLs are, and so is an unset JWKS URL whose default (`<receiverExpectedIssuer>/pf/JWKS`) is http (F-0364,
  F-0570): RFC 8936 §3, "The SET delivery method described in this specification is based upon HTTP over TLS
  [RFC2818]".
- A receiver-only setting that does not parse or is refused at read, and a combination of the receiver's settings that
  does not hold, now cost `SSF_RECEIVER` alone; the transmitter starts (F-0363).
- The receiver's JWKS is a start dependency: unreachable at start, `SSF_RECEIVER` is `FAILED_DEPENDENCY` and retried;
  unreachable once ready, `DEGRADED` (event `ssf.receiver.jwks_failed`) until a fetch succeeds (F-0331).
- `OIDF_SSF_KAFKA_ENABLED=true` with a Kafka publisher that cannot be built stops SSF, `FAILED_CONFIG` or
  `FAILED_DEPENDENCY`, naming Kafka; it no longer runs `READY` with nothing published (F-0332).
- `oidf-preflight.jar` and `Preflight` judge what a server refuses when a component reads a setting - a removed name, a
  value its type refuses, a name set beside its `_FILE` variant or its superseded name - as `REFUSED (at read):`
  lines, under either profile (F-0427). `--format docker` reads an env file as `docker run --env-file` does, and the
  default reading warns of each quoted value (F-0426). `--process` names the process a file is for and judges that
  process's catalogues (F-0425).

- The resolve endpoint holds a subject's chain and its Trust Marks to one resolution budget (F-0280). A response whose
  marks the budget cut short is answered without them and not kept, so the next request gets the full answer.
  Registration has shared one budget since 0.6.0.
- `Fapi2Profile` is mapped over `/as/device_authz.oauth2` as well (F-0320): PingFederate 13.1.3 authenticates a
  client there by assertion, and FAPI 2.0 §5.3.2.1 holds the assertion's `aud` to the issuer at every endpoint.
- Under production, a due renewal at the authorization or PAR endpoint whose request object is encrypted is deferred
  while the registration is current, rather than refused 400 (F-0340). `federation.registration.refresh_deferred`
  says so with the reason `encrypted_request_object`, once a renewal interval. An expired registration is still
  refused 400 `invalid_request_object`.
- `DELETE /federation/agents/<id>` answers 409 `stale_update` when another operator's change to the entity committed
  first, as the admin API does, rather than 500 (F-0380).
- A Trust Mark issued to hosted entities only checks its subjects in one registry read, and the list endpoint's
  `trust_marked` and `trust_mark_type` filters answer every subordinate in a fixed number of reads (F-0381).
- The resolve cap counts the client address behind a proxy `OIDF_TRUSTED_PROXIES` lists (F-0382), an IPv6 caller by
  its /64 as the other per-caller limits do (`OIDF_RATE_LIMIT_IPV6_PREFIX`, F-0391), and counts every resolution the
  cache could not answer, not distinct subjects (F-0383).
- The challenge endpoints answer a wrong method with fixed text and no longer echo the caller's (F-0396).
- `HostedEntity.withMetadataPolicy` keeps a SELF_SIGNED entity's keys and published configuration, so
  `POST /federation/admin/entities/metadata-policy` sets its policy rather than answering 400 (F-0437).
- Five public test hooks are package-private behind `*TestAccess` classes; platform and client-attestation publish
  test-jars (F-0432).
- The public tree carries `docs/findings.md`, a digest of every finding its documents name, and a link to a finding
  lands on its entry there rather than losing its link (F-0445).

- The start-up audit's `insecure TLS` line lists every copy of platform in the JVM, naming each: `webapp`, `engine`,
  or a plugin's relocation such as `rar` for the RAR plugin's "Skip TLS verification (dev only)"
  ([F-0164](docs/findings.md#f-0164)).
- Managed executors start only in the copy the webapp's lifecycle listener marked; the engine's copy starts none but
  its Redis write watchdog (`ManagedExecutors.copyLocal`) ([F-0200](docs/findings.md#f-0200)).
- A client registered, updated or disabled through this project has its attestation policy read again at once, in
  the filter's and the engine criterion's copies ([F-0300](docs/findings.md#f-0300)).
- A Kubernetes token's namespace and service account are held to Kubernetes' DNS-1123 grammar before they become
  SPIFFE path segments ([F-0366](docs/findings.md#f-0366)).
- The client attestation service metadata, the SSF configuration document and the federation endpoints send CORS
  headers only to listed origins; `*` is refused. New `OIDF_SSF_CORS_ORIGINS`; `corsAllowOrigin` is now an origin list
  with no default ([F-0390](docs/findings.md#f-0390)).
- Per-caller rate limits count an IPv6 client by its /64 (new `OIDF_RATE_LIMIT_IPV6_PREFIX`, 32-128)
  ([F-0391](docs/findings.md#f-0391)).
- The attestation issuance endpoint answers only CAS §4.6's codes and statuses ([F-0392](docs/findings.md#f-0392)).
- gm-api's grant-management metadata believes forwarding headers only from a proxy in `OIDF_TRUSTED_PROXIES`
  ([F-0393](docs/findings.md#f-0393)).

- A token exchange whose `requested_token_type` is `urn:ietf:params:oauth:token-type:id-jag` and which carries
  `authorization_details` is refused with `400 invalid_authorization_details` by the new `IdJagDetails` filter on
  `/as/token.oauth2`, for every client and in every deployment profile. PingFederate 13.1.3 neither validates nor
  enriches those details and signs them into the ID-JAG, so neither the RAR processor, the attestation ceiling nor
  the PDP saw them (F-0325, high).
- Each refusal is the audited event `idjag.details.refused`, in pf-integration's new `idjag` event catalogue.
- `RarEntitlement` and `ClientAttestationException.accessDenied` / `ACCESS_DENIED` are removed from
  libs/client-attestation. Nothing has called them since 0.4.0; the token gate and the attester use libs/rar-model
  (F-0100, low).

- A DPoP proof to an operator API must carry a nonce the server issued: a proof without one is a 401
  `use_dpop_nonce` with the nonce in `DPoP-Nonce` (RFC 9449 §9), and the nonce secret is shared through Redis when it
  is configured. `OIDF_OPERATOR_DPOP_NONCE` (default `true`) turns it off in development; production refuses `false`
  (F-0276). device-enrolment's operator client answers the challenge.
- gm-api reads the `act` claim through rs-validation's `ActChain`: the legacy string form, a level that is not a JSON
  object or names no actor, a chain deeper than 10 and an unparseable claim are an invalid token, as they are for
  rs-validation (F-0228). gm-api.war bundles rs-validation, so its health detail and `/agentic-identity/info` load
  the operator authenticator rather than answering 503 (F-0310).
- `OPERATOR_API` is present on the operator-auth settings (`OIDF_OPERATOR_AUDIENCE`, `OIDF_OPERATOR_BASE_URL`,
  `OIDF_OPERATOR_AUTH_MODE`, `OIDF_OPERATOR_JWKS_URL`, `OIDF_OPERATOR_INTROSPECTION_ENDPOINT`), so production asks for
  `OIDF_OPERATOR_API_ENABLED` when they are set (F-0312); `OIDF_AUTHORITY_ADMIN_TOKEN`'s catalogue entry names
  `components: [OPERATOR_API]`, so production's start-up sweep refuses the operator API naming the token (F-0311) The
  entry used to inherit the catalogue's default components, HOSTING and OPERATOR_API: HOSTING is no longer refused
  while the static bearer is set, and its operator routes still answer 503 naming the token.
- The attester emits `attestation.issuer.client_refused`, audited, for a client whose `attestation_*` configuration is
  refused: the client, the property and a reason, never the value; once per client until the refusal changes
  (F-0336).
- The RAR plugin's `rar.decision.permitted`, `.denied` and `.failopen` are audit events: the plugin bundles
  platform-pf's audit sink, which writes them to PingFederate's audit log through the SDK's `LoggingUtil`, protocol
  `RAR` (F-0376).
- A removed plugin field may be catalogued `"ignored": true`, and the generated configuration pages' Removed tables
  gain a "When still set" column: the RAR plugin's "Deny unless PERMIT" now reads Ignored, which is what the plugin
  does (F-0375).

- RFC 8936 long polls are held in PingFederate (F-0360): the war assembler marks the twelve stock filters on
  `/ssf/poll`'s chain `async-supported`, each named with its reason in `build/pingfederate/filters.xml`'s new
  `<async path="/ssf/poll">` block, and `OidfCorrelation` declares it. The assembler refuses a stock filter on the chain
  that is not named (so a filter a new PingFederate adds fails the build), a name not on it, a stock filter that says
  false, and a stock async servlet a marked filter reaches without a reason; it prints `[async]` or `[sync]` for each
  filter of a chain. A held poll's answer carries the request's `traceparent`.
- The SSF SCIM list is one filtered, paged query on the `tables` store - a `COUNT(*)`, one page and its streams - and a
  user's streams one indexed read, whatever the number of streams (F-0388). `userName` is held unique by its RFC 7613
  key (width-mapped, lower-cased, NFC): a name another user holds is 409 `uniqueness` on `POST`, `PUT` and `PATCH`,
  backed by a unique index. New event `ssf.scim.username_conflict`.
- shared-signals' `CaepRiscEvents.assuranceLevelChange` takes a namespace and a direction and checks both (CAEP 1.0
  §3.4.1); the transmitter builds its assurance-level-change with it (F-0400).
- The logout signal is raised when the user confirms PingFederate's sign-off, and not when they cancel or leave the page
  (F-0401). The logout filter records a pending sign-off; a new filter, `SsfLogoutConfirm` over `*.ping`, raises
  session-revoked on PingFederate's confirmation. New `ssf.logout.signal.refused` reasons `declined` and `not_confirmed`.
- Verification SETs and stream-updated notices carry a `txn` of their own (SSF 1.0 §4.1.9, F-0403).
- SSF migration V310: `ssf_stream_subjects (subject_key)` index, `user_name_key` and `email_key` columns with a unique
  index on `user_name_key`, and the table `ssf_logout_pending`.

- Every copy of the modules reads its cluster topology: `OIDF_CLUSTER_MODE` (new, in the
  [cluster-topology](docs/configuration/cluster-topology.md) catalogue: `STANDALONE`, `CLUSTERED_ENGINE`,
  `CLUSTERED_CONSOLE` or `CLUSTERED_DUAL`, any case), else PingFederate's `pf.operational.mode`. Blank, unrecognised or
  the two disagreeing is an unknown topology, which the production profile refuses for every component (plan item C-1).
- Under production a clustered node refuses every store that would keep its state in the node's memory, even with
  `in-memory-state` accepted; FEDERATION and AUTO_REGISTRATION unless PingFederate keeps OAuth clients in a database
  (`ClientManager.isBackendDatabase()`); SSF_RECEIVER and AUTO_REGISTRATION unless a JDBC lease backend is registered (LEASE);
  and SSF on any dialect but `tables` (S10A).
- A `CLUSTERED_CONSOLE` node starts no background job through the managed executors.
- The federation endpoints' spent client assertions (when endpoint authentication is on), automatic registration's
  spent request objects and the OGNL criterion's attestation stores are held to the in-memory rule; the criterion
  denies the token where the rule says no (F-0335).
- A full in-memory replay cache refuses new proofs instead of forgetting a live jti (F-0306): attestation, the
  attester and automatic registration answer `temporarily_unavailable` (503), the federation endpoints 503. Automatic
  registration also answers 503, not 500, when Redis cannot record a request object's jti.
- The agent registry's JDBC store is held to PostgreSQL (F-0337), and the admin API's Trust Mark routes answer 503
  while the Trust Mark registry would be in memory where the rule says no (F-0370).
- The start-up audit's `topology` line, `/agentic-identity/info`'s new `topology` object and the new event
  `platform.topology.resolved` report the mode, its source, the node index, the client storage and the lease backend.

## [0.6.1] - 2026-10-05

The repository split: the source repository is private from 2026-10-04, and releases are published as well to the
public [ID-Partners/pf-agentic-identity](https://github.com/ID-Partners/pf-agentic-identity), generated from an
allow-list, with 0.3.0 to 0.6.0 mirrored there. The image and the conformance rig can be staged from a release. No
module's behaviour changes. [Release notes](docs/releases/0.6.1.md).

- `tools/export-public.py` builds the tree `ID-Partners/pf-agentic-identity` receives from an allow-list
  (`tools/public-export/manifest.txt`), rewrites or de-links its links, and fails on source code, a dead link, an
  unmapped internal URL, a deny-list hit, a private key or an unexpected binary.
- The Build workflow's `lint` job runs `python3 tools/export-public.py --check` on every pull request.
- The image's `org.opencontainers.image.source` label names the public repository,
  `https://github.com/ID-Partners/pf-agentic-identity`, and the release-download commands in
  `build/pingfederate/README.md` and `docs/operator/preflight.md` use it.

- `build/pingfederate/stage-from-release.sh` stages `modules/` and `assembler/` from a published release's assets
  instead of from the reactor: no Maven and no git, every file checked against the release's `SHA256SUMS` before
  anything is staged, and a fetch that sends no credentials. Build's image job proves its stage equals
  `stage-modules.sh`'s for both profiles, jar for jar. `stage-lib.sh` holds the `MANIFEST` writer both scripts use.
- The conformance rig has a release mode: `PF_RELEASE=<version|dir> conformance/up.sh` stages from a release
  instead of building, and needs no JDK or Maven. `conformance/layout.sh` finds the image build and the
  PingFederate version in this repository and in the public tree.
- Two new release assets: `war-assembler-<version>.jar`, the war assembler the image build runs, and
  `demo-only-ciba-sim.jar`, the rig's CIBA simulator. `tools/ci/assemble-dist.sh` makes the release's `dist/`.
- `ciba-sim` is no longer deployed to GitHub Packages (F-0120).

- `release.yml` publishes every release to the public repository `ID-Partners/pf-agentic-identity` as well as
  here: a `public-preflight` job first proves `PUBLIC_REPO_TOKEN` can push there and that private vulnerability
  reporting is on (a real release with no usable token stops before the internal draft exists), and a
  `publish-public` job, after the release job, commits the public tree `tools/export-public.py` builds as
  `Release <version>`, tags it, creates the public release from the same `dist/` bytes, and downloads every asset
  with no credentials to check it against `SHA256SUMS`. A dry run uploads the tree and the body as artefacts and
  pushes nothing. Nothing on the public side is ever force-pushed; a commit there this workflow did not make is a
  stop.
- A `docs_only` dispatch publishes only the root and docs of `main` or a `v*` tag to the public repository, for
  corrections to released documentation: no build, no tag, no release.
- `tools/public-release-body.py` writes a public release's body: the release page's opening, the "Before you
  deploy" titles linking to the page at its tag, how to verify, the PingFederate line, and the simulator warning,
  within GitHub's release-body limit (U-0465).
- `tools/mirror-releases.sh` mirrors v0.3.0 to v0.6.0 onto the public repository once, by hand, byte for byte,
  with unchanged `SHA256SUMS`; v0.3.0's `pf.plugins.ciba-sim.jar` is not mirrored (F-0120).
- `PROVENANCE.txt`'s `run:` line names the run id, not a URL in this repository.

- The showcase's packaging and release statements describe what SPC built: `public-preflight` before a release,
  `publish-public` after it, the public tree's allow-list, the mirror of 0.3.0 to 0.6.0, the two assets
  `stage-from-release.sh` needs from 0.6.1, and GitHub Packages staying with this repository. The CIBA simulator
  statement no longer says GitHub Packages receives it (F-0120 stopped that).

- Every job in Build, Docs, Mutation, conformance-federation and iOS runs on the runner the repository variable
  `RUNNER_LINUX` (or `RUNNER_MACOS` for iOS) names, and on GitHub's hosted runner when the variable is unset or
  when Dependabot opened the pull request. Nothing is set yet, so every job still runs hosted. Release stays on
  hosted runners.
- `tools/ci/install-lint-tools.sh` records Linux arm64 checksums for actionlint, shellcheck, zizmor, gitleaks,
  grype and syft, so the lint and image steps run on an arm64 Linux runner.
- `.github/workflows/codeql.yml` is removed: the repository is private from 2026-10-04 and code scanning is not
  available to it (F-0460, accepted with a review date). `.github/zizmor.yml` drops its entry, U-0130 (CodeQL
  for Swift) closes as moot, and the showcase's workflow counts lose CodeQL.

- **README.md** - says this is the private source repository and that consumers use the generated public
  repository, `ID-Partners/pf-agentic-identity`, for releases from 0.6.1 (0.3.0 to 0.6.0 mirrored); "Running
  PingFederate" gives both modes, `conformance/up.sh` from the reactor and `PF_RELEASE=<version>
  conformance/up.sh` from a release; "Documentation" links the public export's page; "Provenance" and "License"
  cover the public repository.
- **CONTRIBUTING.md** - who contributes (the people with access to the private repository), that the public
  repository takes issues and no pull requests, and how a public issue reaches the findings register.
- **SECURITY.md** - vulnerabilities are reported through the public repository's private vulnerability
  reporting, which is on (F-0068 closed); the interim paragraph is gone; the latest supported release is the one
  published there; the public tree's generation is in scope.
- **docs/PROVENANCE.md** - a dated section, "two repositories": nothing moved, what the allow-list keeps here,
  that the history published before the flip stays published, and that the showcase and its hosting are
  unchanged.
- **docs/DEMOS.md** - the conformance rig from a release, `demo/up.sh` in the public repository from 0.6.1.
- **docs/releases/README.md** - each release page is published in the public repository at its tag.
- **The "public repository" comments** in `.gitleaksignore`, `.gitignore` and `conformance/.gitignore`, and the
  style guide's sentence on what is public, describe the two repositories.

- The rig's README (`demo/README.md` in the public tree) no longer names `conformance/layout.sh` or shows
  `build/pingfederate/README.md` as link text, which a public reader does not have; it says `layout.sh` beside
  the README and "the image README". Its "Testing it" section says a suite on any origin other than the default
  must be in `suite_base_urls` when the rig is authored, or PingFederate refuses every redirect.
- The public SECURITY.md names the tab as GitHub now labels it, **Security and quality** (github/docs
  `data/features/security-and-quality-tab.yml`, on github.com, read 2026-10-04).

## [0.6.0] - 2026-10-01

Phase 3 of the production programme, secure by default: the production profile enforced from the settings catalogues,
with a preflight jar to run before an upgrade; operator APIs on PingFederate-issued, DPoP-bound OAuth tokens; components
that start, fail and are switched on their own, with a rule per surface; attestation policy held on the filter path, at
every endpoint that authenticates a client and on what is issued; strict settings readers; deadlines on every outbound
call; the image no longer configuring the deployment; reproducible jars and wars; and every high finding targeted at
0.6.0 closed. Notes, and the upgrade guide they link: [docs/releases/0.6.0.md](docs/releases/0.6.0.md).

- The poms begin 0.6.0-SNAPSHOT and the changelog opens Phase 3 (PR #66); no release-note fragment.
- Dependency updates from Dependabot, no fragment: JUnit Jupiter 5.10.2 to 6.1.3 in the BOM (PR #23); the
  maven-minor-and-patch group, 16 updates across the poms (PR #45); `hashicorp/setup-terraform` 3.1.2 to 4.0.1 and
  `actions/setup-java` 5.7.0 to 6.0.1 in the workflows (PR #24); `marked` 12.0.2 to 18.0.13 for the showcase's
  docs build under tools/ (PR #21).

- `pf-entrypoint.sh` keeps the age-encrypted archive and decrypts it on every start of the container, restarts
  included. Until now the first start removed a ciphertext baked into the image's drop-in directory (one mounted
  through `PF_ARCHIVE_FILE` was always kept), and the next start of the same container - `docker restart`, a
  restart policy, a node reboot - found only the plaintext it had written, which production refuses:
  the container stopped with `FATAL: a plaintext archive (...) is refused when OIDF_DEPLOYMENT_PROFILE is
  production` (F-0313).
- `test-entrypoint.sh` starts a case twice on the same filesystem, in both profiles.

- The six cloud evidence validators (`gke-sa-token`, `gcp-id-token`, `eks-sa-token`, `aws-sts-web-identity`,
  `aks-sa-token`, `azure-mi-token`) are now one base class, `CloudTokenValidator`, with each type adding only its own
  claims (plan item H-ATT-1, F-0059). Every check they share is in one place and applied the same way to all six.
- Each type's accepted issuers are pinned by a new setting, `OIDF_ATTESTER_<TYPE>_ISSUERS`
  (`OIDF_ATTESTER_GKE_SA_TOKEN_ISSUERS`, `OIDF_ATTESTER_GCP_ID_TOKEN_ISSUERS`, `OIDF_ATTESTER_EKS_SA_TOKEN_ISSUERS`,
  `OIDF_ATTESTER_AWS_STS_WEB_IDENTITY_ISSUERS`, `OIDF_ATTESTER_AKS_SA_TOKEN_ISSUERS`,
  `OIDF_ATTESTER_AZURE_MI_TOKEN_ISSUERS`). A client's `attestation_evidence_issuer` may now only narrow them. The
  production profile refuses a type with no pin.
- `nbf` is checked when present and `iat` is required, both with the 60 s clock skew, and a token issued to live longer
  than `OIDF_ATTESTER_MAX_CLOUD_TOKEN_LIFETIME_SECONDS` (default 3600, 60 to 86400) is refused. Unset, the maximum is
  5700 s for `azure-mi-token`, whose lifetime Entra picks, and 3600 s for the other five; set, it holds all six. The
  evidence lifetime cap, `OIDF_ATTESTER_MAX_EVIDENCE_LIFETIME_SECONDS`, still bounds every piece of evidence after
  that.
- Only keys whose `use` is absent or `sig` verify a cloud token, from an inline bundle or a fetched one; the key's type
  and curve must fit the token's algorithm, and its `alg`, when it has one, must be the header's. `RemoteJwksCache`
  still keeps every key of a fetched set, whatever its `use`, so a SPIRE bundle's `jwt-svid` keys keep verifying
  `spiffe-jwt` evidence; it now refuses a set of more than 64 keys and holds at most 256 URLs.
- `gcp-id-token` evidence must come from a user-managed service account of a project `OIDF_ATTESTER_GCP_PROJECTS`
  lists, and a `gcp-id-token` binding may not contain `*`. With the list set, a `gke-sa-token`'s cluster and
  `*.svc.id.goog` trust domain must name a listed project, and a `gke-sa-token` binding's `*` may only come last,
  after `spiffe://<trust-domain>/ns/`.
- `azure-mi-token` evidence must carry `tid`, equal to one of `OIDF_ATTESTER_AZURE_TENANTS` or, with no list, the
  tenant in its pinned issuer; and `oid`, one of `OIDF_ATTESTER_AZURE_MANAGED_IDENTITIES` when that is set. An
  `aks-sa-token` that carries `tid` is held to the tenant list.
- `aws-sts-web-identity` evidence's account must be one of `OIDF_ATTESTER_AWS_ACCOUNTS` when that is set, and must
  agree with the token's `https://sts.amazonaws.com/` `aws_account` claim when present.
- A refusal keeps its error code (`invalid_svid` for the token, `invalid_client` for the client's configuration),
  no longer repeats the token's `iss`, `sub`, `kid` or `alg` (F-0365), and is counted in
  `oidf_attester_cloud_evidence_refusals_total{type, check}`, a selector value over its bound under
  `check="selectors"`.

- New platform rule, `platform.net.TrustedProxies` (plan item H-ATT-3): `OIDF_TRUSTED_PROXIES` lists, as CIDR ranges,
  the proxies whose forwarding headers are believed; unset (the default), none is. From a listed proxy the client
  address is the right-most forwarding hop it does not list, and the scheme and host are what it says.
  `OIDF_TRUSTED_PROXIES_HEADERS` chooses `x-forwarded` (the default) or RFC 7239 `forwarded`. The catalogue is
  [`trusted-proxies`](docs/configuration/trusted-proxies.md).
- Both attestation challenge endpoints, the attester's issuance endpoint and the operator APIs' failed-authentication
  limit count callers by that client address, so behind a listed proxy each client has its own allowance
  ([F-0116](docs/findings.md#f-0116), [F-0275](docs/findings.md#f-0275)).
- `POST /federation/attestation` (plan item H-ATT-2, [F-0060](docs/findings.md#f-0060)) reads at most
  `OIDF_ATTESTER_MAX_BODY_BYTES` (32768, 4096 to 262144) and answers `413 invalid_request` beyond it; allows each client
  address `OIDF_ATTESTER_ISSUANCE_REQUESTS_PER_MINUTE` (60) requests a minute, in Redis when `OIDF_REDIS_URL` is set,
  and answers `429 temporarily_unavailable` with `Retry-After` past it; answers every failure, an unexpected exception
  or `Error` included, with an error code and an `X-Correlation-Id` header, a `5xx` or `invalid_client` with a fixed
  description instead of the exception's text; and answers other methods `405`. The codes are CAS §4.6's except
  `invalid_svid`, `spiffe_id_not_authorized` and `invalid_client` at 400, kept unchanged
  ([F-0392](docs/findings.md#f-0392)).
- The attester matches evidence against a cached index of PingFederate's attestation clients, rebuilt every
  `OIDF_ATTESTER_CLIENT_INDEX_REFRESH_SECONDS` (30) and after a miss at most once every 5 s, instead of reading every
  PingFederate client on every request. While PingFederate's clients cannot be read the index it has is served for at
  most four intervals, then the endpoint answers `503 temporarily_unavailable`.
- `/.well-known/client-attester` and `/federation/attester-configuration` build their URLs from `X-Forwarded-*` only
  when a listed proxy sent them, and send `Access-Control-Allow-Origin` only to the origins
  `OIDF_ATTESTER_CORS_ORIGINS` lists, none by default, for `GET` ([F-0061](docs/findings.md#f-0061)).

- Removed the federation code nothing called (plan item H-FED-10, F-0052): `ClientEntityAuthorizer`; the trust
  controller gateway's `fetchEntityConfiguration()`, `fetchMembers()` (its client for `/list`) and both
  `fetchEntityConfigurationOf` overloads; `BridgeSigners.require`; and the deprecated overloads with no caller -
  `JwtCodec.verifyAgainstInlineJwks` and `verifyAgainstKeys` without a `VerificationPolicy`,
  `FederationService.fetchEntityStatement(String, String, String)` and `listSubordinates(String)`, and
  `TrustChainValidationResult.leafMetadata()`. The federation list endpoint itself is unchanged.
- `resetForTests` on `TrustMarkSupport`, `AuthoritySupport`, `KeyHistorySupport`, `FederationRuntimeConfig` and
  `FederationPolicySupport` is package-private, so production code cannot reset process-wide federation state. Tests
  in other packages call `<Class>TestAccess.reset()`, published in openid-federation's test-jar and in a new
  pf-integration test-jar.
- The deprecated members that still have production callers stay, and their javadoc names the release that removes
  them, 1.0.0: the federation event façades (`FederationEvent`, `FederationEvents`, `FederationEventSink`,
  `LoggingEventSink`, the federation `LogSafe`, `PfAuditEventSink`; F-0430) and `AttestationReplayCache.record` and
  `firstSeen` (F-0431).

- Every refusal written to a caller that has not authenticated - the attestation, registration and FAPI filters in
  front of the token, PAR, CIBA, device, introspection and revocation endpoints, the authorization endpoint's error
  page, `/federation/register`, the federation endpoints (`/federation/fetch`, `/list`, `/resolve` and the rest) and a
  hosted entity's published configuration - now carries the error code's fixed description and a correlation id,
  `"error_description": "Client authentication failed (reference oidf-1a2b3c4d)"`, and nothing the request or a peer
  chose (plan item H-FED-4, F-0046). The detail - a trust chain's messages, a claim the attestation carried, the URL the
  request named, what to configure - is on one `server.log` line with the same reference. An operator authenticated
  by `OperatorAuthenticator` still gets the detail.
- `FapiResourceServerFilter` (UserInfo) holds only the clients `OIDF_FAPI2_CLIENTS` names, as `Fapi2ProfileFilter`
  does, and those a new setting, `OIDF_FAPI_RESOURCE_CLIENTS`, adds - FAPI 1.0 clients such as FAPI-CIBA's, which the
  FAPI 2.0 token-endpoint rules would refuse - and finds an access token in the query whatever the spelling of the parameter's name - `access%5Ftoken`,
  `Access_Token`, repeated (H-FED-6, F-0048). Until now it refused a query token and set `x-fapi-interaction-id` for
  every client, and read the query as written.
- `OAuthErrorDescriptionFilter` holds a response only when its status is an error when the body starts; a token
  response goes straight through, unbuffered. A `sendError` or `reset` after it started holding an error is followed:
  what was held is dropped (H-FED-6, F-0048).
- Our audit records no longer empty PingFederate's own audit line (H-FED-7, F-0049). On PingFederate 13.1.3
  `LoggingUtil.cleanup()` removes every audit column on the thread, so an event we wrote from inside PingFederate's
  own request - an OGNL issuance criterion at the token endpoint - left PingFederate's line for that request with no
  event, subject, IP address, client, protocol or host. The writer now copies the thread's audit context, writes, and
  puts it back exactly. Our record no longer picks up PingFederate's client and role as its own either.
- A new event, `fapi.request.refused`, in a new `fapi` catalogue: each refusal of either FAPI filter, with the filter,
  the rule, the client as its subject and the endpoint, written to `server.log` and PingFederate's audit log (protocol
  `FAPI`) and counted in `oidf_events_total` (plan item O-2).

- A hosted entity's suspension, reactivation or revocation, a Trust Mark grant, revocation or reinstatement, and a
  historical key's revocation now apply only to the state they read: of two operators changing one of them at once,
  the second to commit is answered 409 `stale_update` at the federation admin API and writes nothing, its audit line
  and event included (plan item H-FED-3, F-0019).
- `/federation/entity?sub=<this entity>` now serves this entity's Entity Configuration, the same statement as
  `/.well-known/openid-federation`, so both carry `authority_hints` by one rule: none for a Trust Anchor, its configured
  superiors otherwise, never `[]` (H-FED-8).
- The trust chain validator caches only the statements of the route it validated, under keys that treat
  `https://a.example/` and `https://a.example` as one entity, and parses a statement's `metadata_policy` only once the
  route's signatures have verified: a policy that does not parse now fails the chain after the signature check, never
  before it (H-FED-8).
- `TrustMarkIssuer.marked` reads a type's standing grants in one query; a hosted entity's signed Entity Configuration is
  kept for the first quarter of its hour - or of the time until the first Trust Mark it carries expires, if that is
  sooner - and dropped when the entity or its Trust Marks change; the resolve endpoint
  answers each caller address about a capped number of distinct subjects a minute and keeps its responses for up to
  60 s; AuthZEN discovery is read again every ten minutes (H-FED-9, F-0051). Two settings join the
  `federation-resolution` catalogue: `OIDF_FEDERATION_RESOLUTION_RESOLVE_SUBJECTS_PER_MINUTE` (30) and
  `OIDF_FEDERATION_RESOLUTION_RESOLVE_CACHE_SECONDS` (60).

- An encrypted request object, or an encrypted client assertion at PAR, no longer registers or renews a relying party
  at the authorization or PAR endpoint under the production profile: it is refused with 400 `invalid_request_object`
  (plan item H-FED-1, F-0020). Development registers it with a warning. A relying party whose registration is current
  still sends encrypted request objects on to PingFederate.
- `request_object_signing_alg` is never set from a JWE `alg` such as `RSA-OAEP` or `ECDH-ES`: a client is registered
  with its declared algorithm, else its signed proof's, and only when that is an asymmetric JWS algorithm (`RS256`-`RS512`,
  `PS256`-`PS512`, `ES256`-`ES512`, `EdDSA`). Anything else leaves it unset, and PingFederate's default applies.
- The token endpoint names an attested request's client from the `OAuth-Client-Attestation` header's `sub` when the
  request carries neither a client assertion nor `client_id`, and checks that client's registration as well when the
  request names another, so the attested client's registration expiry is enforced (H-FED-2, F-0021).
- An explicitly registered `openid_relying_party` gets OpenID Connect Registration 1.0 §2's defaults for what its
  metadata omits - `response_types` `["code"]`, `grant_types` `["authorization_code"]`, `id_token_signed_response_alg`
  `RS256` - is restricted to its response types, requires PKCE unless `OIDF_AUTO_REGISTRATION_REQUIRE_PKCE=false`, and
  its registration response reports the defaults (H-FED-5, F-0047).

- `JwtCodec.parseUnverifiedClaims` returns an `UnverifiedClaims` (plan item H-JOSE-1,
  [F-0063](docs/findings.md#f-0063)): the claims of a JWT whose signature nobody has checked, typed so that they
  cannot be passed where verified claims are expected, every accessor named `unverified...`. Every call site is
  classed in the oidf-jose README ("Reading a JWT before its signature is checked"): routing, refuse-first or logging.
- Every `JwtCodec` verifier - the claim verifiers, `verifySignature` and `verifyAttestationPop` - refuses `none` and
  the MAC algorithms whatever the caller's algorithm set names, and tries only asymmetric keys not marked
  `"use": "enc"` (RFC 8725 §3.1, §3.2; RFC 7517 §4.2). The `verifyAgainstKeys` and `verifyAgainstInlineJwks` overloads
  that take no `VerificationPolicy`, deprecated here, are removed in the same release by the H-FED-10 bullet above (HFEDD).
- A configured subordinate's keys are asserted in a Subordinate Statement only once its Entity Configuration verifies
  under one of them ([F-0415](docs/findings.md#f-0415)). This is the OpenID Federation §3.2 check, not pinning: a
  party that answers at the subordinate's URL still signs with the keys it lists, which stays open as
  [F-0012](docs/findings.md#f-0012). The trust mark status endpoint decides on the verified
  mark, the Trust Mark validator verifies the anchor configuration it reuses against the anchor's pinned keys, and a
  request object's replay window reads its verified `exp` and `jti`.
- `LocalJwkSigner` (plan item H-JOSE-2, [F-0064](docs/findings.md#f-0064), [F-0112](docs/findings.md#f-0112))
  signs `PS256`, `PS384` and `PS512` with an RSA key, and refuses, when it is built, an RSA key under 2048 bits, an EC
  key off P-256, P-384 and P-521, and an EC key whose declared `alg` is another curve's.
- The attestation filter's start function builds every client's bridge signing key, and again every ten minutes; a
  key that does not build is a `DEGRADED` part of `ATTESTATION_AUTH`, `BridgeSigners`, naming the client.
- `SdJwt` and `SdJwtException` are removed from oidf-jose: nothing used them, and the attestation verifier refuses
  SD-JWT presentations.
- oidf-jose has a `mutation` profile, as openid-federation and pf-integration do.

- The SSF receiver takes RFC 9493's `did`, `uri` and `aliases` subjects and SSF 1.0's complex subject (plan item
  H-SSF-1, finding F-0053, closed), and maps each to the user key or device its handlers act on: an `iss_sub` only when
  its `iss` is the SET's issuer, this PingFederate's `OIDF_SSF_ISSUER` or one in the new
  `OIDF_SSF_RECEIVER_SUBJECT_ISSUERS`; `aliases` by its first identifier in the order `iss_sub`, `email`, `account`,
  `phone_number`, `opaque`, `did`, `uri`; a complex subject by its `user` and `device` members. A subject that maps to
  no one is logged with the reason and counted (`ssf.receiver.subject_unmapped`), and nothing is acted on.
- A received SET carrying `exp` or `sub` is refused as `invalid_request`, the description naming the claim (SSF 1.0
  §4.1.7 and §4.1.2; finding F-0246, closed): a 400 on push, a `setErrs` entry on poll, counted as
  `ssf.receiver.set_refused`. The push endpoint's 400 now carries `Content-Language: en-US` (RFC 8935 §2.3).
- An event whose complex subject carries a member the transmitter declared critical and the receiver does not act on
  is accepted and discarded (SSF 1.0 §3.6), counted as `ssf.receiver.set_discarded`.
- The receiver's poll and stream calls get their token from the transmitter's authorization server by client
  credentials: `OIDF_SSF_RECEIVER_TOKEN_ENDPOINT`, `OIDF_SSF_RECEIVER_CLIENT_ID`, `OIDF_SSF_RECEIVER_CLIENT_SECRET`
  (`client_secret_basic`) or `OIDF_SSF_RECEIVER_CLIENT_KEY` (a private JWK, `private_key_jwt`), and
  `OIDF_SSF_RECEIVER_CLIENT_SCOPE`; the token is kept until shortly before it expires and fetched again after a 401.
  `OIDF_SSF_RECEIVER_POLL_TOKEN` is now development only.
- With `OIDF_SSF_RECEIVER_TRANSMITTER_CONFIGURATION_URL` the receiver creates or finds its own stream at the
  transmitter at start-up and keeps its events (`OIDF_SSF_RECEIVER_EVENTS_REQUESTED`) and, for push
  (`OIDF_SSF_RECEIVER_PUSH_ENDPOINT_URL`), its delivery in step; a transmitter that refuses leaves `SSF_RECEIVER`
  `FAILED_DEPENDENCY`, retried by the supervisor, and a stream it created and cannot accept is deleted again. A
  `configuration_endpoint` or poll `endpoint_url` the transmitter names that is not https leaves `SSF_RECEIVER`
  `FAILED_CONFIG`, and the receiver's token is not sent there (SSF 1.0 §7.1, RFC 8936 §3).
- `OIDF_SSF_RECEIVER_TOKEN_ENDPOINT`, `OIDF_SSF_RECEIVER_TRANSMITTER_CONFIGURATION_URL` and
  `OIDF_SSF_RECEIVER_PUSH_ENDPOINT_URL` are classed forbidden in production when they are http URLs.
- The poll endpoint holds at most 256 long polls at once in each copy; past that a poll is answered at once.
- The poll endpoint caps `maxEvents` (`OIDF_SSF_POLL_MAX_EVENTS_CAP`, 100, 1-1000), records `setErrs` (logged,
  counted as `ssf.poll.set_error`, the SET released), returns nothing for a paused or disabled stream, and treats a
  poll whose `returnImmediately` is not `true` as a long poll, held for up to `OIDF_SSF_POLL_LONG_POLL_WAIT_SECONDS`
  (10, 0-30) off the request thread (plan item H-SSF-2, finding F-0054, closed). PingFederate's own filters do not
  allow async requests, so inside PingFederate the poll is answered at once (finding F-0360).
- New event catalogues `ssf-receiver` and `ssf-poll` in servlets/ssf.

- SSF streams carry SSF 1.0 §8.1.1's optional members (plan item H-SSF-3, finding F-0055, closed): `description`
  (the receiver's, cut at 1,024 characters), and `min_verification_interval` and `inactivity_timeout`, which the
  transmitter gives each new stream from the new `OIDF_SSF_MIN_VERIFICATION_INTERVAL_SECONDS` (30, 0-86400) and
  `OIDF_SSF_INACTIVITY_TIMEOUT_SECONDS` (0 = none, 0-31536000). All three are stored by the JDBC and in-memory stores and
  returned; a receiver echoing a Transmitter-Supplied member on PATCH or PUT must send the stream's value. The `ldm`
  store keeps none of them until the Identity Object Model declares them: there a stream reports the two settings and
  a `description` is refused with a 400.
- A verification request sooner than the stream's `min_verification_interval` after its last is answered 429 with
  `Retry-After`, and nothing is signed.
- `OIDF_SSF_MAX_STREAMS_PER_CLIENT` (10, 1-1000) caps the streams one receiver client may have; one more create is 409.
- A stream create with no `delivery` is a poll stream (SSF 1.0 §8.1.1.1), where it was a 400.
- An `OIDF_SSF_ISSUER` that is not https is `FAILED_CONFIG` in production (a WARN in development); one with a query, a
  fragment or no host is `FAILED_CONFIG` in any profile.
- `OIDF_SSF_BASE_PATH` is removed: every URL the transmitter advertises is the issuer and the path its servlet is
  mapped to.
- SCIM (plan item H-SSF-4, finding F-0056, closed): `GET /ssf/scim/v2/Users/{id}`, and `GET /ssf/scim/v2/Users` with a
  `filter` (a subset of RFC 7644 §3.4.2.2, 400 `invalidFilter` for the rest), `startIndex` and `count`; every error in
  the RFC 7644 §3.12 schema as `application/scim+json`; `PUT` replaces, and is 404 for an unknown id; `POST` of a user
  already recorded is 409 `uniqueness`; `active` false to true puts the subject back on its streams and emits RISC
  `account-enabled`. The endpoint keeps a record per user (the JDBC store's new `ssf_scim_users` table; the `ldm`
  store keeps none until the model has a class for it). A PATCH, PUT or DELETE that deactivates a user the endpoint
  has no record of still emits `account-disabled`, as every deprovision did before.

- Every SET the SSF transmitter mints carries a `txn`, the same on every SET one PingFederate event raises: the audit
  record's or the logout request's PingFederate `transactionid`, or a value minted for that event (plan item H-SSF-5,
  F-0057; SSF 1.0 §4.1.9).
- The audit source's default vocabulary is every PingFederate 13.1.3 audit event that maps to one CAEP or RISC event
  without ambiguity: `SLO`, `SRI_REVOKED` and `AUTHN_SESSIONS_DELETED` to session-revoked, `AUTHN_SESSION_CREATED` to
  session-established, `PWD_CHANGE` to credential-change (`password`, `update`) and `ACCOUNT_DELETE` to RISC
  account-purged. `SESSION_REVOKED`, `SESSION_DELETED` and `AUTHN_SESSION_DELETED`, which no PingFederate 13.1.3 class
  writes, are gone. `OIDF_SSF_AUDIT_EVENT_MAP` takes `session-established`, `account-purged` and
  `credential-change:<credential_type>[:<change_type>]`.
- credential-change carries only a CAEP 1.0 registered `credential_type`; the audit source no longer sends
  `"credential"`, and an unnamed credential is dropped and counted, not guessed. An audit-raised account-disabled
  carries no `reason` (RISC's are `hijacking` and `bulk-account`).
- `SsfEventBridge.onAssuranceLevelChange` raises a CAEP 1.0 §3.4 assurance-level-change with its required `namespace`
  and `current_level`; PingFederate's audit records carry no assurance level, so the audit source never raises one.
- The audit source re-attaches when log4j replaces its configuration (PingFederate's `log4j2.xml` has
  `monitorInterval="30"`) and detaches when the webapp shuts down.
- The logout signal (`LogoutEventFilter`) is raised only for an `id_token_hint` that is an ID token signed and issued
  by this PingFederate, issued within `OIDF_SSF_LOGOUT_HINT_MAX_AGE_SECONDS` (new, default 86400), when PingFederate's
  handling did not fail, and at most once per session and `iat` (plan item H-SSF-6, F-0022). A `logout_token`
  parameter is no longer read. The issuer comes from `PfInternals.issuer` (F-0215).
- A push stream's `authorization_header` is encrypted at rest with AES-256-GCM under the new `OIDF_SSF_SECRET_KEY`
  (and `OIDF_SSF_SECRET_KEY_PREVIOUS` during a rotation); a clear value is sealed on its stream's next write (plan item
  H-SSF-7, F-0058).
- Kafka: `OIDF_SSF_KAFKA_SECURITY_PROTOCOL` defaults to `SSL` and is a choice; `PLAINTEXT` and `SASL_PLAINTEXT` are
  forbidden in production (plan item PR-2). New settings pass the `ssl.*` truststore, keystore and host-name settings
  through (`OIDF_SSF_KAFKA_SSL_TRUSTSTORE_LOCATION`, `_PASSWORD`, `_TYPE`, `OIDF_SSF_KAFKA_SSL_KEYSTORE_LOCATION`,
  `_PASSWORD`, `_TYPE`, `OIDF_SSF_KAFKA_SSL_KEY_PASSWORD`, `OIDF_SSF_KAFKA_SSL_HOSTNAME_VERIFICATION`) and bound the
  producer's timeouts (`OIDF_SSF_KAFKA_REQUEST_TIMEOUT_MS` 10000, `OIDF_SSF_KAFKA_DELIVERY_TIMEOUT_MS` 30000,
  `OIDF_SSF_KAFKA_MAX_BLOCK_MS` 2000; `linger.ms` 0). The JAAS line escapes every value.
- A new event catalogue, `ssf`: `ssf.set.emitted`, `ssf.set.dropped`, `ssf.logout.signal.refused`,
  `ssf.audit.source.attached` and `ssf.audit.source.detached`, each counted in `oidf_events_total` (plan item O-2).

- The "Attestation-aware RAR to PingAuthorize" processor refuses, under the production profile, a configuration with
  "Skip TLS verification (dev only)" or "Trust a client-asserted principal" on, and one with "Fail open on engine
  error" on unless `pdp-fail-open` is in `OIDF_ACCEPTED_RISKS` (plan item PR-3). The rule is the settings catalogue's
  class for each field, applied by platform's read-time rule, so the message names the field, the value, the fix and
  the development escape. It runs when the admin console or the admin API saves the instance, and again at configure,
  which is the only check an imported archive gets. Until 0.6.0 both development switches were saved in production and
  ignored there, with a WARNING at configure. A plaintext PDP URL keeps its own rule, now also classed in the
  catalogue.
- An AuthZEN decision's `context` reaches the granted detail only through the members the new field "AuthZEN context
  members merged into details" names for the detail's type (H-RAR-1, F-0065). The default,
  `sales_agent: @model; account_information: @model`, lets those two types take the members their models declare and
  `payment_initiation` none. A member the field does not name is dropped, counted in
  `oidf_rar_context_dropped_total{form}` and logged by name, never merged; `context.statements` is held to the same
  list by the first part of each name. A listed member that would widen the detail is still refused by the model. An
  entry splits at its last colon, so a URI type (`urn:example:transfer: amount`) can be named.
- `enrich`'s decision step emits `rar.decision.permitted`, `rar.decision.denied` (reason class `pdp_deny`,
  `pdp_widened`, `pdp_unreachable` or `pdp_failed`) and `rar.decision.failopen`, with the type, the principal source,
  the principal hashed and the client id, catalogued in the plugin's new `rar` event catalogue. They go to
  `server.log` under `com.pingidentity.ps.oidf.rar.event` and are counted in the plugin's own
  `oidf_events_total`; they are not audit events (F-0376).
- The settings catalogue records the removed "Deny unless PERMIT" field (removed in 0.4.0) under `removed`, so the
  generated configuration page shows it (F-0231). A stored value is still ignored, not refused.
- The plugin jar carries its own classes and Jackson, rar-model and platform (with platform's HttpCore), each
  relocated, and nothing else: Jackson's unrelocated multi-release classes and the bundled artefacts' Maven
  descriptors are gone, Jackson's service files are relocated with their classes, and the plugin's event index and
  platform's are appended into one. The plugin's README lists the jar's contents.
- Reference PingAuthorize policies for `sales_agent`, `payment_initiation` and `account_information` are files in
  `plugins/rar-paz-plugin/paz/policies`, authored into a Policy Editor by `paz/author-policies.py`, with decision
  tests (`paz/decision-tests.py`: a permit, a deny and a narrowing per type, and the edges below) and a Policy
  Editor compose file that
  needs nothing from outside this repo but Ping's evaluation licence. The three one-off scripts and the compose file
  that mounted a checkout beside this one are gone. No script in `paz/`, and not `probe-decision.sh`, has a default
  secret any more, and the probe now verifies the PDP's certificate (its CA in `PAZ_CA_FILE`), skipping the check
  only for a PDP on `localhost`, `127.0.0.1` or `[::1]`.

- The production profile is enforced from the settings catalogues (plan items PR-5 and PR-2's mechanism). Before
  any filter or servlet starts, the lifecycle listener checks every classed environment variable and system
  property: a forbidden switch set, a risky switch whose risk `OIDF_ACCEPTED_RISKS` does not accept, a required
  setting left unset, a governed value that does not parse, an `OIDF_*` name under a catalogue's family that no
  catalogue declares, and a catalogue that cannot be loaded are each a violation. Under production each refuses the
  components it names: their parts are `REFUSED` before their start runs, their surfaces answer 503, readiness
  answers 503, and PingFederate's own endpoints keep serving (the FAPI exception is under "Before you deploy").
  Server.log lists every violation once, the start-up banner lists them, and PingFederate's audit log gets one
  `platform.profile.refused` event per refusal. Under development nothing is refused and the list is a warning.
- `jdk.internal.httpclient.disableHostnameVerification` is catalogued (F-0195) and forbidden in production with any
  value, refusing every component (F-0035). `OIDF_REDIS_URL` and `REDIS_URL` are refused at start-up when they are
  `redis://` URLs; `REDIS_URL` only when it is the one read, with `OIDF_REDIS_URL` and `oidf.redis.url` unset. The
  catalogue format's `governed` schemes form gains `unless_set` to say so.
- A value read from an init-param, a plugin's field or a client's extended property is refused when its reader reads
  it through the catalogue; ST5F, PLG and ST5S converted the readers of the governed ones in 0.6.0 (F-0298).
- `ProfileRefusals.refuse` and `requireRisk` let a package refuse a component for a condition that is not a setting,
  such as a store in memory without the `in-memory-state` risk.
- `Preflight` runs the same check on an env file before a deployment:
  `java -cp '<jars>/*' com.pingidentity.ps.oidf.platform.settings.Preflight --env-file FILE [--profile production]`,
  exiting 1 when something would be refused.
- The catalogue format (still `format: 1`, every addition optional) gains `governed` - the values a class acts on,
  as a list or as URL schemes - and `components`, per catalogue and per entry; system-property names may carry
  upper-case letters, and a removed name may be a plugin field. The configuration reference shows the governed
  values in the Profile column and names the components each page's violations refuse.
- The development profile reads the legacy spellings of a switch (`yes`, `no`, `1`, `0`, `on`, `off`) as `false`,
  as most readers before 0.6.0 did, with a warning, until 1.0; production refuses them. `OIDF_EVENTS_AUDIT`'s reader
  keeps its own rule: anything but `false` keeps auditing on.
- New events: `platform.profile.refused` (audited) and `platform.component.changed` (counted), in platform's new
  `platform` event catalogue.

- Every pom sets `project.build.outputTimestamp`, the date written on each jar and war entry, so a rebuild of
  one commit makes the same bytes. `tools/set-version.py` sets it with the version - HEAD's commit time, in UTC,
  for a release, and `2000-01-01T00:00:00Z` for a snapshot - and `--check` refuses a pom without it, a value that
  does not parse, and a release that still carries the snapshot's date (plan item P0-5).
- Before anything is published, the release makes the rebuild its deploy will make with `mvn install` and
  compares every rebuilt jar and war with `dist/`, byte for byte, so a mismatch stops it before a draft or a
  package exists. It compares again after the deploy. The wars are no longer let off with a note. A dry run runs
  the same install and comparison, so the step that failed v0.5.0 is exercised before a tag.

- The PingFederate image no longer bakes in configuration: it does not accept Ping Identity's licence agreement,
  open the plain HTTP listener on 9080, log this repository's packages at DEBUG, set `ForceUnsupportedImport`,
  require the `workload` attestation claim or trust mock attesters from the build context. Each is set at run time
  by the deployment (plan item R-I3; [build/pingfederate/README.md](image/README.md#what-the-image-leaves-to-you)).
- `pf-entrypoint.sh` refuses to start without `PING_IDENTITY_ACCEPT_EULA=YES`, and refuses a plain HTTP listener
  (`PF_RUN_PF_HTTP_PORT`) unless `OIDF_DEPLOYMENT_PROFILE=development`. It trims the profile as the Java modules do
  (F-0161).
- The image has OCI labels (`org.opencontainers.image.*`, with the version, commit and build time), `EXPOSE 9031
  9999` and a `HEALTHCHECK` on PingFederate's heartbeat and `/agentic-identity/health/live` - live, not ready.
- The build records its commit in platform-pf's manifest (`-Doidf.build.commit`), so `/agentic-identity/info` and
  the start-up banner report it rather than null (F-0190).
- `oidf.attestation.required.claims` can come from the environment as `OIDF_ATTESTATION_REQUIRED_CLAIMS`.
- age is installed from its checksum-pinned 1.3.2 release binary instead of apk, which reinstalled the base image's
  whole Alpine userland, and the image has no bash (F-0220).

- The RAR plugin calls its PDP through libs/platform's `OutboundHttp` instead of the JDK's `java.net.http`: a 2.5 s
  total deadline by default (connect at most 1 s of it, the body included), a 64 KiB answer cap, HTTP/1.1 and no
  redirects, with the host name always checked (plan item S2c, and S5d's call site in this plugin; F-0010).
- New "PDP TLS trust" field: `jvm-default` (default), `pingfederate-trusted-cas` (PingFederate's trusted CAs through
  the SDK's `TrustedCAAccessor`) or `pinned-ca` with "PDP CA certificates (PEM)".
- At most 32 PDP calls at once per processor instance, and a circuit breaker ("Circuit breaker failures", 5;
  "Circuit breaker open (s)", 30) that counts only transport failures.
- One PDP decision per question per HTTP request, however often PingFederate asks; an optional per-type decision
  cache ("Decision cache types", "Decision cache TTL (s)", at most 60 s) that never holds `payment_initiation` or a
  type requiring an authenticated principal.
- With "AuthZEN batch URL" set (the `authzen` dialect), every detail of a token request is decided in one OpenID
  AuthZEN 1.0 Access Evaluations call; an answer that does not list one decision per evaluation is refused.
- Metrics `oidf_rar_pdp_calls_total`, `oidf_rar_pdp_answers_total` and `oidf_rar_pdp_breakers` in the plugin's own
  metrics MXBean.
- The README and the plugin's skill no longer mention `jdk.internal.httpclient.disableHostnameVerification` as a
  workaround: the plugin does not need it.

- `AttestationPolicyResolver` builds each client's attestation policy for both the token-endpoint filter and the
  OGNL criterion: the server's, tightened by the client's `attestation_*` extended properties. The filter used to
  ignore the properties altogether (F-0009); the criterion read them loosely, so a bad value fell back to the
  default and a large one loosened the policy. Each property is now parsed strictly and can only tighten: a proof
  age or clock skew can only shrink, an algorithm list can only narrow, `attestation_challenge_required` can only
  turn the challenge on, `attestation_required_claims` only adds, and `attestation_expected_htu` can only pin one of
  the token endpoint URLs this server answers at. A value that does not parse or would loosen refuses the client
  with 401 `invalid_client`. The policy is kept 30 s per client; a client manager that cannot answer is 503
  `temporarily_unavailable` (plan item S4c).
- The filter resolves the client from the attestation's `sub` before verifying it, and refuses a verified `sub` that
  is another client. It publishes the SHA-256 of the policy it verified under, and the criterion, reusing that
  verification, refuses a context verified under another policy.
- `attestation_required=true` is enforced: a token request for such a client without `OAuth-Client-Attestation` is
  refused by the filter (401 `invalid_client`) instead of going on to PingFederate's own client authentication.
- A start-up scan, then every 10 minutes, reads every client's properties and lists the clients it would refuse, by
  client id and property, as a `DEGRADED` part of `ATTESTATION_AUTH` (`AttestationPolicyScan`) in the health detail.
- A token exchange's `subject_token` that verifies as one PingFederate signed (its signing keys, its issuer, an `exp`
  not passed, a `typ` of none, `JWT` or `at+jwt`) is published as `verified_subject_token_sub` in the attestation
  context, and only then does `delegationActChain` nest its `act`. The RAR plugin takes a token exchange's principal
  from that member alone (F-0074).
- The filter and the criterion emit `attestation.client.verified` and `attestation.client.refused` for every
  decision, and `attestation.policy.invalid` - in pf-integration's new `attestation` event catalogue - for each
  refused property, all counted in `oidf_events_total` (plan item O-2).

- The attester refuses an instance-key proof without `iat` and `exp`, with `exp` not after `iat`, or with `exp`
  more than 300 s after `iat`, and accepts one only from `iat - 60 s` to `exp + 60 s`: `invalid_instance_proof`,
  with one description that says what to send (CAS §4.3; plan item S4c, finding F-0036). The CAS discovery
  document's `proof_claims_required` lists `iat` and `exp`.
- A spent proof `jti` is remembered until its proof can no longer be accepted, not for a fixed time from first
  use: `exp + 60 s` for an instance-key proof at the attester, `iat + max age + 2 x 60 s` (and never less than
  max age + 60 s from now, the retention before 0.6.0) for a PoP or DPoP proof at the token endpoint. The stores
  take the absolute time through the new `AttestationReplayCache.recordUntil`; memory evicts by it, expired entries
  first when full, and Redis sets `PX` to what is left of it. A retention already past answers the new verdict
  `STALE` without asking the store. The relative `record(client, jti, ttlSeconds)` and `firstSeen` are deprecated.
- `OIDF_ATTESTER_MAX_ISSUED_TTL` (seconds, default 3600, 60 to 64800) caps a client's `attestation_issued_ttl`: above
  it the client is refused in production and clamped with a warning in development; above 64800 s (the AI Agent
  Profile's 18 hours) it is refused in both ([docs/configuration/attestation-issuer.md](docs/configuration/attestation-issuer.md)).
- `ClientAttestationConfig.Builder` refuses a PoP or DPoP max age of 0 or less, and has a `clock(Clock)` for tests;
  a combined-mode DPoP proof's age is also held to that clock.

- `ClientAttestationAuth` is mapped over PingFederate's CIBA backchannel endpoint (`/as/bc-auth.ciba`), device
  authorization endpoint (`/as/device_authz.oauth2`), introspection and revocation as well as the token and PAR
  endpoints, so a client whose only credential is its attestation can authenticate wherever PingFederate authenticates
  a client (plan item S4d). At introspection and revocation it authenticates and bridges only. The war assembler
  refuses a war unless `Fapi2Profile` runs before it on every path they share, automatic registration before it at the
  token endpoint and front-channel registration before it at PAR and the authorization endpoint.
- At the token endpoint, PAR, CIBA and the device endpoint the filter grants `authorize(requested, attestation,
  INHERIT)` and forwards **the granted details**, with the verified agent, in place of what the client sent: a field
  the attestation constrains and the request leaves out takes the attestation's value. A request that asks for no
  details forwards none. PingFederate issues what PAR and CIBA stored and ignores the token request's parameter on
  those grants, so this is what holds the code and CIBA grants to the ceiling (F-0032, with S4D3's belt and criterion
  to come). The token gate in libs/client-attestation has an `INHERIT` entry point for it
  (`ClientAttestationVerifier.verify(..., Omission)`); the OGNL criterion stays strict.
- A signed request object at PAR or CIBA must carry details within the attestation's as they stand (400
  `invalid_authorization_details`); one the filter cannot read is 400 `invalid_request_object`, and a `request_uri` at
  PAR is 400 `invalid_request` (RFC 9126 §2.1). A repeated `authorization_details`, `oidf_requested_access`, `request`
  or `request_uri` is 400 `invalid_request`.
- At the authorization endpoint, `authorization_details` (or a request object carrying them) from a client with
  `attestation_required=true` that did not come through PAR is refused with the error page, never a redirect.
- `attestation_required=true` is enforced at every endpoint the filter authenticates at, not only the token endpoint.

- The RAR plugin's `validate` holds each `authorization_details` entry to its type's model, the two bookkeeping
  markers stripped: an unmodelled type (in development the common-fields model stands in, as it does for `enrich`),
  an undeclared field, a value of the wrong JSON type or a detail over the size limits is refused with the model's
  reason, which names the field and never a value. PingFederate calls `validate` at PAR, the authorization endpoint,
  CIBA's backchannel request, the device authorization endpoint, token exchange and the token endpoint, so such a
  request now fails there with `invalid_authorization_details` rather than later at the resume or the token endpoint
  (RFC 9396 section 5, F-0108). The exception is a token exchange that requests an ID-JAG
  (`requested_token_type=urn:ietf:params:oauth:token-type:id-jag`): PingFederate 13.1.3 calls neither `validate` nor
  `enrich` there and copies the request's `authorization_details` into the ID-JAG it signs (F-0325). A models document that did not load, and an instance whose configure threw, refuse
  every detail there too. `validate` asks no PDP and resolves no principal; each refusal is logged at INFO as
  `RAR validate: refusing type=... flow=... path=...`.
- On the JWT-bearer grant (`grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`), where PingFederate calls
  `validate` and never `enrich`, the plugin refuses a detail of its types with "authorization_details of this type
  are not accepted on the JWT-bearer grant" unless the new field "Types allowed on the JWT-bearer grant" lists the
  type. The field defaults to none. A listed type passes `validate`'s model check and is issued without a PDP
  decision. The field refuses, on save and at configure, a type that "Types requiring an authenticated principal"
  lists (F-0108, U-0017).

- A new OGNL issuance criterion, `@com.pingidentity.ps.oidf.servlet.clientregistration.utils.IssuedDetailsCriterion@withinCeiling(#this)`,
  holds what an access-token mapping is about to issue - PingFederate's `context.OAuthAuthorizationDetails` - to the
  client attestation's `authorization_details` by the model's strict `contains`, on the client-credentials, code,
  CIBA, device and refresh grants the rig drove, and on any other mapping it is added to (plan item S4d, F-0032, F-0033). A request with no attestation passes
  unless its client has `attestation_required=true`; the criterion never throws, and answers `false` while
  `ATTESTATION_AUTH` is failed or refused.
- The same criterion refuses a refresh that sends no `authorization_details` for a grant holding a detail of a type in
  the new setting `OIDF_ATTESTATION_REDECIDE_ON_REFRESH_TYPES` (default `payment_initiation,account_information`), so
  the client repeats its details and PingFederate asks the RAR processor, and the PDP, again (F-0105).
- A response belt, `IssuedDetailsBelt`, is mapped over `/as/token.oauth2` just before ClientAttestationAuth: for an
  attested request it holds the token response (up to 64 KiB) until the `authorization_details` in it are within the
  ceiling, and replaces it with 400 `invalid_authorization_details` when they are not, revoking the grant behind the
  response's refresh token. A larger success is 500 `server_error`. Other requests pass untouched and unbuffered.
- Each refusal is `attestation.issued.refused` in pf-integration's `attestation` catalogue, with `enforcer` and
  `detail_types` (never a value).
- The war assembler checks one more order rule, IssuedDetailsBelt before ClientAttestationAuth.
- [docs/operator/issued-details.md](docs/operator/issued-details.md) describes both checks, the refresh rule and the
  residual risks.

- PingFederate's `/.well-known/openid-configuration` and `/.well-known/oauth-authorization-server` now carry the
  authorization server's attestation members (plan item S-4, F-0115): `attest_jwt_client_auth` and
  `attest_jwt_client_auth_dpop` appended to `token_endpoint_auth_methods_supported`,
  `client_attestation_signing_alg_values_supported`, `client_attestation_pop_signing_alg_values_supported` and
  `challenge_endpoint`. A new filter, `AttestationMetadata`
  (`AttestationMetadataFilter`, registered by `build/pingfederate/filters.xml`), adds them; PingFederate's own members
  are kept first, in its order and with its values.
- The Entity Configuration's `oauth_authorization_server` block carries the same members, added to PingFederate's own
  RFC 8414 document; its `openid_provider` block carries them as before.
- `client_attestation_pop_methods_supported` stays in `openid_provider` alone. ABCA-10 §7.6 reads it, present without
  `none`, as the server asking every client for an attestation, and PingFederate's two documents are read by every
  client, most of which are not asked for one (F-0412).
- With `OIDF_ATTESTATION_AUTH_ENABLED=false`, or no `attest_jwt_client_auth*` method in `tokenEndpointAuthMethodsSupported`,
  none of the four documents advertises an attestation member.
- `/.well-known/client-attester` names the authorization server: `authorization_servers` (its issuer, RFC 9728 §2's
  member) and `authorization_server_metadata` (the issuer's RFC 8414 metadata URL), where a client finds the
  challenge endpoint the token endpoint accepts (F-0118). Its own `challenge_endpoint` is still the attester's.
- A discovery document the filter cannot extend goes out as PingFederate wrote it, and every answer is counted in
  `oidf_discovery_attestation_members_total{document, outcome}`.

- A trust chain resolution spends one `ResolutionBudget`: a wall clock and a number of requests, over platform's
  `Budget`, thread-safe. Every request the resolution causes spends one request from it and is made by its
  deadline: each statement the validator asks for, and the gateway's own requests - an authority's Entity
  Configuration fetched to find its fetch endpoint, and the second retrieval of an anchor's Entity Configuration
  that did not verify (OpenID Federation 1.0 §11.3). A peer chain spends from a child of the same budget. A
  resolution that runs out is refused as `invalid_trust_chain`, saying whether it ran out of time or of requests,
  and never naming what it was fetching (plan item S5b; F-0010 stays open for S5c and S5d).
- `TrustMarkValidator.validate(chain, budget)` holds a Trust Mark validation to one budget: the anchor's
  configuration and each issuer are resolved from children of it, and each status call spends one request and ends
  by its deadline. `validate(chain)` makes a budget from the issuers' validator's options.
- `ValidationRequest.budget(...)` lets a caller hand a validation its own budget; the validation spends from a
  child of it holding at most the request's `maxFetches`.
- `HttpGetClient.get(url, accept, deadline)` and `HttpPostClient.post(..., deadline)` / `postForm(..., deadline)`
  take a `Deadline`. `JdkHttpClient` ends the exchange, the body included, by the sooner of it and its own 15 s
  request timeout, so a slow peer spends the resolution's time rather than a fresh timeout for each request.
- `TrustControllerGateway` gains overloads of `fetchEntityStatement`, `fetchSubordinateStatement` and
  `anchorConfiguration` that take the budget; their defaults forward to the overloads without it, so a gateway
  written before this compiles and behaves as it did.
- `ValidatorOptions.defaults()` reads a new settings catalogue, `federation-resolution`:
  `OIDF_FEDERATION_RESOLUTION_WALL_CLOCK_SECONDS` (45), `OIDF_FEDERATION_RESOLUTION_MAX_REQUESTS` (24),
  `OIDF_FEDERATION_RESOLUTION_MAX_AUTHORITY_HINTS` (10), `OIDF_FEDERATION_RESOLUTION_MAX_ROUTE_ATTEMPTS` (8) and
  `OIDF_FEDERATION_RESOLUTION_CLOCK_SKEW_SECONDS` (60). `ValidatorOptions` gains a seventh component,
  `resolutionWallClock`, and `withResolutionWallClock`; the package-private `TrustChainValidator.FetchBudget` is gone.
- `TrustMarkValidator` rejects a Trust Mark larger than 8192 bytes (`MAX_STATUS_MARK_BYTES`) rather than send it to
  its issuer's status endpoint: a socket write has no timeout, and a larger body could wait past the budget on an
  endpoint that never reads. A Trust Mark check whose budget runs out while it resolves the anchor's configuration
  now says so in each mark's reason. U-0195 stays open: other `OutboundHttp` writes above about 14 KiB can still wait
  on a peer that does not read.

- `POST /federation/register` (OpenID Federation 1.0 §12.2) runs through the same `RegistrationCoordinator` as
  automatic registration: one registration of a client at a time, waiting up to `OIDF_AUTO_REGISTRATION_LOCK_WAIT_MS`
  for another to finish, and at most `OIDF_AUTO_REGISTRATION_MAX_CONCURRENT_RESOLUTIONS` resolved at once. A request
  that gets neither is answered 503 `temporarily_unavailable` with `Retry-After: 2`. The servlet has its own pool, as
  each automatic-registration filter has (plan item S5c; F-0010 stays open for S5d).
- Every registration - explicit, and automatic at the token, authorization and PAR endpoints - spends one
  `ResolutionBudget` of its own, handed to the validator on `ValidationRequest.budget` and to
  `TrustMarkValidator.validate(chain, budget)`, so its chain, peer chain and Trust Marks share it. The budget has the
  `federation-resolution` settings' requests (`OIDF_FEDERATION_RESOLUTION_MAX_REQUESTS`) and their wall clock
  (`OIDF_FEDERATION_RESOLUTION_WALL_CLOCK_SECONDS`) or what is left of the registration's deadline, a new setting
  `OIDF_REGISTRATION_DEADLINE_SECONDS` (25 s, 2 to 300), whichever is shorter. The deadline runs from when the
  request asks to register, so the wait for the client's lock comes off it. This closes the registration half of
  F-0280: the resolve endpoint's `FederationService` and `ClientAttestationUtils` still validate the chain and its
  marks on two budgets.
- A budget that runs out is a federation that could not be answered in time: `Kind.TRANSPORT`, 503
  `temporarily_unavailable`, remembered for the 15 s transport backoff. Before this, S5B's `invalid_trust_chain` made
  it a trust failure: 401 `invalid_client` at the token endpoint, remembered for 60 s. A required Trust Mark the
  budget left unchecked is refused the same way, not as a mark the entity lacks (400 `invalid_client_metadata`).
- The failure memory is keyed on the SHA-256 of the whole chain an attempt started from - every statement in order,
  each with its length, and for an explicit registration the posted Entity Configuration, the statements of its
  `trust_chain` header and its `peer_trust_chain` - with the client id. It was keyed on the first statement alone,
  so a caller who varied the rest of a chain got a fresh resolution each time. Explicit registration now consults
  and fills it: the same failed chain posted again within its backoff is answered with the same refusal and resolves
  nothing. A success clears the client's remembered failures. At most 4096 failures are kept in all, across every
  client and chain, each as its status, code, description and kind rather than the exception with its cause and
  stack trace.
- `POST /federation/register` reads at most `OIDF_REGISTRATION_MAX_BODY_BYTES` of a body (65536, 4096 to 524288). A
  body whose `Content-Length` is larger is refused before any of it is read, and one found larger at the cap -
  chunked, or understated - is refused with no more of it read: 413 `invalid_request`. It used to read the whole body,
  however large.
- A `trust-chain+json` body whose statement is not a JWT is answered 400 `invalid_request`; it was a 500 with a stack
  trace at ERROR (F-0317, found on the rig).
- A lock wait that is not shorter than the deadline stops `/federation/register` and both automatic-registration
  filters starting, naming both settings.

- SSF's push delivery sends each SET through libs/platform's `OutboundHttp`: 2 s to connect and 10 s for the whole
  exchange, the body included (S-10's values), at most 64 KiB of the answer read, and the endpoint's host resolved
  once and the connection pinned to a checked address (plan item S5d; F-0010).
- The SSF receiver's poll, stream management and token calls (1 s to connect, 5 s in all) and its JWKS fetch (1 s and
  2.5 s, at most 64 KiB) go through `OutboundHttp`, with `OIDF_SSF_RECEIVER_INSECURE_TLS` through `TlsTrust.insecureIf`.
- OpenBao's transit signer (1 s and 2.5 s), device-enrolment's calls to the federation authority, its token endpoint
  and PingOne's JWKS (5 s and 10 s), and gm-api's PDP client (`pdpTimeoutMs`, 10 s by default, now on the whole call)
  go through `OutboundHttp`.
- Each failure keeps its caller's outcome - a push retry, a receiver `FAILED_DEPENDENCY`, an enrolment
  `server_error`, a PDP 503 - and its message or log line now names the reason: `HEADER_TIMEOUT`, `DEADLINE`, `TLS`,
  `BODY_TOO_LARGE`, `CONNECT_FAILED` and the rest.
- No shipped module builds its own `java.net.http` client or `HttpURLConnection` for an outbound call any more.

- `OperatorAuthenticator` in libs/platform-pf decides who may use an operator API: a PingFederate-issued access
  token, verified against PingFederate's JWKS or at its introspection endpoint, whose `iss` is PingFederate's (in
  introspection mode, when the answer carries one - PingFederate's answer for a reference token has none), whose
  `aud` holds `OIDF_OPERATOR_AUDIENCE`, carrying the route's scope, and in production bound by DPoP (`htu` from
  `OIDF_OPERATOR_BASE_URL`, never the `Host` header) or a client certificate. The actor is the token's `sub`. Each
  decision is an `admin.request.authorised` or `admin.request.refused` event from the new `operator` catalogue.
  Failed authentications are limited to 10 a minute per client address and changes to 60 a minute per operator
  (plan item S8a). Its settings are the new `operator-auth` catalogue; see
  [docs/operator/operator-authentication.md](docs/operator/operator-authentication.md).
- `TokenIntrospector` in libs/platform asks an RFC 7662 endpoint within 1 s to connect, 2.5 s in all and 64 KiB, and
  reads `cnf` and `token_type`; an active answer is kept at most 30 s.
- rs-validation's `DelegatedTokenValidator` takes an introspection endpoint in place of a JWKS, reports what each
  token was bound to, and, under the development profile only, accepts a token bound to nothing.
- `DpopProofValidator` and `DpopProof` move from client-attestation to oidf-jose, as
  `com.pingidentity.ps.oidf.jose.dpop`, and compare `htm` exactly (F-0225, F-0226). rs-validation no longer depends
  on client-attestation.
- rs-validation's jar is staged into PingFederate beside platform-pf.
- `EventsCataloguedTest` checks platform's `Events.event(component, code)` calls as it does the façade's.

- The federation administration API (`/federation/admin/*`), hosted-entity enrolment (`POST /federation/agents`,
  `/federation/resources`) and revocation (`DELETE .../<id>`), `/federation/registered-clients`, and the health
  detail and `/agentic-identity/info` are operator routes on `OperatorAuthenticator` (plan item S8b): each needs a
  PingFederate-issued access token with its own scope, DPoP-bound in production, and every request - let through or
  refused - is an `admin.request.*` event labelled with its route. The route list is in
  [docs/operator/operator-authentication.md](docs/operator/operator-authentication.md#the-routes); tests in each
  module fail on a mapped path that has no route.
- The actor every change records - in Trust Mark grants, hosted entities' histories, key revocations, the federation
  events and the policy decision point's enrolment questions - is the token's `sub`. `X-Federation-Actor` names
  nobody: it is only the operator event's `claimed_label`, and inside PingFederate server.log carries a digest of it
  (F-0165). The federation events' `actor` is classed `PSEUDONYMOUS_ID`.
- A hosted-entity revocation through `DELETE` records its actor and emits `federation.hosted_entity.revoked`.
- The static bearer `OIDF_AUTHORITY_ADMIN_TOKEN` is one rule in `OperatorAuthenticator`: accepted in development,
  with a WARN per request, never in production. `HealthAccess` and `AdminBearer` are gone (F-0008, F-0194).
- SSF's receiver and provisioner tokens are checked through platform's `TokenIntrospector`
  (`PfIntrospectionReceiverAuthenticator`), whose own HTTP client is gone.
- device-enrolment enrols agents with a DPoP-bound client-credentials token for `oidf.admin.entities`: new settings
  `PF_AUTHORITY_CLIENT_ID`, `PF_AUTHORITY_CLIENT_JWK`, `PF_AUTHORITY_CLIENT_SECRET` and
  `PF_AUTHORITY_TOKEN_ENDPOINT`.
- Inside PingFederate, the server.log copy of every event goes through `PfAuditSink`'s process policy, so any
  field an event classes `DIRECT_ID` - `claimed_label` today, and any another module adds - is written there as a
  digest, not in clear. The audit log's copy is unchanged.
- device-enrolment keeps the token endpoint's answer to a refused client in its own log; the enrolling device hears
  only that the authority refused device-enrolment's client.
- platform-pf publishes a test-jar with `OperatorTestKit`, for the operator surfaces' tests.

- Every `init` of the nine classes that serve a component - `OpenIdFederationServlet`, `OpenIdRegistrationServlet`,
  `TokenEndpointAutoRegistrationFilter`, `FrontChannelAutoRegistrationFilter`, `ClientAttestationAuthFilter`,
  `Fapi2ProfileFilter`, `HostedEntityServlet`, `FederationAdminServlet` and `AttestationIssuanceServlet` - returns,
  whatever happened. What it used to throw is the part's state (`FAILED_CONFIG`, or `FAILED_DEPENDENCY` when a cause
  is an I/O, SQL, timeout or linkage failure) with its reason, and a failed component no longer takes
  `pf-runtime.war` down (plan item S-9, first half).
- A request-path gate, platform-pf's `ComponentGate`, is the first statement of each of those classes' request
  methods. A surface whose part is starting or failed, or whose component has a refused part, answers 503
  `{"error":"temporarily_unavailable",...}` and goes no further; a filter answers so only for its component's own
  traffic and passes the rest to PingFederate; a client assertion the gate cannot read counts as the component's
  traffic, so the floor fails closed. A servlet that is off answers 404 `not_found`; a filter that is off
  passes everything on. Package S9B then replaced this floor with each surface's own rule.
- A supervisor, `platform.component.Supervisor`, starts a part that failed on a dependency again, on a managed
  executor of the webapp's copy only, after a wait drawn between zero and a ceiling of 5 s doubling to 300 s. Each
  attempt counts in `oidf_component_retries_total{component}`. Configuration failures are never retried.
- Nine enable switches, `OIDF_{FEDERATION,AUTO_REGISTRATION,ATTESTATION_AUTH,ATTESTATION_ISSUER,HOSTING,SSF,SSF_RECEIVER,OPERATOR_API,FAPI}_ENABLED`,
  catalogued in platform's new `components.json` ([docs/configuration/components.md](docs/configuration/components.md)).
  The SSF two apply from package ST5C, which moved the SSF start-up onto them.
- `OIDF_ATTESTATION_REQUIRE_BRIDGE_KEY` is now an alias of `OIDF_ATTESTATION_AUTH_ENABLED` and leaves
  federation-runtime's catalogue.
- Explicit registration, hosting, the operator API and the attester's issuance endpoint load at start-up, so their
  parts register at deploy rather than on the first request (finding F-0193, closed).
- The authority's signer, entity id and configuration builder are published in one write, and
  `HostedEntityServlet.configureAuthority` resolves its store, policy and signer before it publishes the registry, so
  a policy that is not one leaves no half-configured authority. `FrontChannelAutoRegistrationFilter` publishes its wiring the same way.
- New operator page, [docs/operator/components.md](docs/operator/components.md); [health.md](docs/operator/health.md)
  says what changed for ready.

- Each surface of a component that is disabled or failed now has its own rule, replacing 0.6.0's first, fail-closed
  floor (plan item S-9, second half). OpenID Federation's endpoints, explicit registration, hosting and the operator
  API answer 404 `not_found` when their component is off and 503 `temporarily_unavailable` (OpenID Federation 1.0
  §8.9's body) when it is failed; SSF's, the attester's and the challenge endpoints answer 404 with no body and 503.
  The automatic registration filters refuse only a request that names a federation client - 401 `invalid_client`
  when automatic registration is off, 503 when it is failed - and pass every other request to PingFederate. The
  attestation filter refuses only attestation traffic (401 when off, 503 when failed) and the clients that
  authenticate only with an attestation. A failed FAPI filter answers 503 only to the clients `OIDF_FAPI2_CLIENTS`
  names (F-0270, closed). The logout filter always lets the logout go on; a disabled or failed SSF only stops the
  emission. The table is in [docs/operator/components.md](docs/operator/components.md#each-surfaces-rule).
- The OGNL criteria - `validateClientAttestation`, `attestationClaim` (`ATTESTATION_AUTH`), `validateTrustChain`,
  `federationPolicy` (`FEDERATION`) - answer `false` (`attestationClaim`: nothing), never a throw, while their
  component is not serving. On PingFederate's engine classloader, which sees none of the webapp's parts,
  platform-pf's new `CriterionGate` decides from the enable switch and the production profile's refusals.
- Ready (`/agentic-identity/health/ready`) is 503 exactly when an enabled component is neither `READY` nor
  `DEGRADED`, and a component that was serving and failed on a dependency counts as `DEGRADED` for the first 15 s of
  that blip while the supervisor retries it; the health detail marks it `"graced": true`.
- Explicit registration without the trust anchor's keys is `DEGRADED`, not `FAILED_CONFIG`: the rest of `FEDERATION`
  serves and counts as ready, and each registration answers 503 until the keys are configured (F-0192, closed).
- The gate reads each part's state from a published snapshot, without a JVM-wide lock on PingFederate's token and
  authorization path (F-0272, closed).
- The conformance rig switches federation, automatic registration and attestation off
  (`OIDF_FEDERATION_ENABLED=false`, `OIDF_AUTO_REGISTRATION_ENABLED=false`, `OIDF_ATTESTATION_AUTH_ENABLED=false`)
  instead of naming itself trust anchor; its federation profile switches the first two back on. New
  `conformance/fail-soft-matrix.sh` boots the rig once per component with its failure injected and checks the table
  and ready.

- client-attestation's two challenge endpoints, attestation-issuer's issuance, CAS metadata and attester-configuration
  servlets, `EvidencePolicy`, `AttesterSigningKey` and rar-model's `RarModels.fromEnvironment` read every setting through
  their settings catalogues - `attestation-challenge`, `attestation-issuer`, `evidence-policy`, openid-federation's
  `hosted-entity-signing` and `rar-models` - strictly (plan item ST-5). A value an entry refuses is the servlet's part
  `FAILED_CONFIG` at deploy, naming the setting, and its path answers 503; before 0.6.0 most of them were ignored with
  a warning, or read leniently, or failed at a first request.
- A client's `attestation_*` extended properties are parsed as the `issuance-client-properties` catalogue says: a value
  an entry refuses is that client's `invalid_client`, naming the property and never its value.
  `attestation_bundle_url` must be an http or https URL, `attestation_spiffe_bundle` a JSON object, and
  `attestation_evidence` is taken in any case.
- Under the production profile the attester's and the authorization server's in-memory stores - the challenges, the
  spent proof `jti`s and, at the attester, the evidence bindings, each namespace its own - need the `in-memory-state`
  accepted risk when `OIDF_REDIS_URL` is unset; without it `ProfileRefusals.refuse` refuses `ATTESTATION_AUTH` (the
  `oidf:as:*` stores) or `ATTESTATION_ISSUER` (the `oidf:cas:*` stores) at deploy, with a reason naming the risk and
  `OIDF_REDIS_URL` (plan item PR-2, Phase 3 plan decisions 9 and 15). `AttestationSupport.requireSharedState` is the
  rule; `AgentRegistrySupport.configureInMemoryRegistry` follows it too. The challenge rate limit's counters need no
  risk.
- rar-model's common-fields fallback reads `OIDF_DEPLOYMENT_PROFILE` as every other module does: `development`,
  trimmed, in any case (finding F-0160, and F-0107 with it).
- The two challenge endpoints emit `attestation.challenge.issued` and `attestation.challenge.refused` (`rate_limited`,
  `store_unavailable`, `method_not_allowed`), with the surface (`AS` or `CAS`) and never the challenge, from
  client-attestation's new `challenge` event catalogue; both are counted in `oidf_events_total` (plan item O-2).
- The challenge endpoints, the CAS metadata servlet and the attester-configuration servlet are parts of their
  component (plan item S-9), registered at deploy: the authorization server's challenge endpoint of `ATTESTATION_AUTH`,
  the rest of `ATTESTATION_ISSUER`. client-attestation depends on platform-pf for the part, the gate and the init-params.

- Every SSF transmitter setting is read through the `ssf-transmitter` catalogue with platform's `Settings`
  (plan item ST-5): the servlet's init-param, then the system property `oidf.ssf.<init-param>`, then
  `OIDF_SSF_<UPPER_SNAKE>`, the order `SsfConfiguration.param` used. The 42 camelCase system properties
  (`oidf.ssf.signingAlgorithm` and the rest) are catalogued under their real names, so nothing that was read stops
  being read (finding F-0235, closed). The five secrets (`OIDF_SSF_JDBC_PASSWORD`, `OIDF_SSF_KAFKA_SASL_PASSWORD`,
  `OIDF_SSF_INTROSPECTION_CLIENT_SECRET`, `OIDF_SSF_RECEIVER_ENDPOINT_AUTH_TOKEN`, `OIDF_SSF_RECEIVER_POLL_TOKEN`) can
  now be given as a file: `OIDF_SSF_JDBC_PASSWORD_FILE`, the system property `oidf.ssf.jdbcPassword.file` or the
  init-param `jdbcPasswordFile` names a file whose content, one trailing newline trimmed, is the value; setting a
  name and its file variant together is refused, naming both. The logout filter's `OIDF_SSF_LOGOUT_ALLOW_SUB_PARAM` is read through `ssf-logout-signal` the same way.
- Values are parsed strictly and every refusal names its setting: the seven switches are `true` or `false`, the six
  numbers whole numbers, the three choices one of their choices (in any case now: `rs256` is `RS256`), and the three
  URLs http or https URLs with a host.
- The transmitter starts once, as the `SSF` component's part, from `SsfConfigurationServlet` (plan item S-9), and
  its whole state - configuration, store, minter, services, receiver and receiver authenticator - is built first and
  published in one write, or not at all (finding F-0040, closed). A setting that does not parse is `FAILED_CONFIG`
  with an ERROR naming it (findings F-0191 and F-0237, closed); a store that cannot be reached is `FAILED_DEPENDENCY`,
  and platform's supervisor starts it again with backoff until it opens - SSF's own 30-second boot retry is gone.
- `OIDF_SSF_ENABLED` and `OIDF_SSF_RECEIVER_ENABLED` now apply (finding F-0271, closed). `SsfReceiverServlet` loads
  at start-up after the transmitter, so the receiver's part registers at deploy (the last servlet of F-0193); a
  receiver nobody configured is `DISABLED` whatever became of the transmitter.
- Every SSF servlet's request methods start with a gate: 503 `temporarily_unavailable` while SSF (or, for the push
  endpoint, the receiver) is starting, failed or refused, and 404 `not_found` while it is off. Until 0.6.0 those
  requests failed inside the servlet with a 500. A refused SSF no longer configures itself and serves (finding F-0295,
  closed).
- Only `SsfConfigurationServlet`'s init-params configure SSF. The other SSF servlets start nothing; until 0.6.0 the
  first of them to initialise could configure the transmitter from its own init-params.
- The store is checked on one connection before it is used, so a database that is down fails at start-up for the
  `ldm` dialect too; H2 and HSQLDB are refused in every profile, as since 0.5.0, now as a configuration failure that
  is not retried.
- In production an in-memory SSF store needs the `in-memory-state` risk, and a store that is not PostgreSQL is
  refused (plan decisions 9, 10 and 15; PR-2), through `ProfileRefusals`, so both show in the start-up audit.
- The receiver's settings (`OIDF_SSF_RECEIVER_*` but the receiver scope) refuse `SSF_RECEIVER` only when the
  production profile refuses one, not the transmitter as well (finding F-0297's SSF part).
- `tools/settings-scan.py` no longer lets a catalogue entry leave out an `oidf.ssf.<camelCase>` property.

- Every federation reader is on `platform.settings` (plan item ST-5): `FederationRuntimeConfig` through the
  `federation-runtime` catalogue, the federation servlet's `FederationConfiguration` and `AttestationMetadataConfig`
  through `federation-entity`, the hosted-entity store and servlet through `hosted-entities`, the hosted entities'
  vault through `hosted-entity-signing`, the registration servlet's and filters' init-params through `registration`,
  `Fapi2ProfileFilter` through `fapi2-profile`, the attestation filter's two global settings through
  `attestation-token-endpoint`, and `OutboundUrlPolicy` through `outbound-fetch`. Each setting is read from its
  entry's sources in its entry's order, its superseded names come from the catalogue (not written out by hand), and
  every value is parsed strictly, a number within the entry's range.
- One setting per variable, whichever class reads it (finding F-0197, closed). `OIDF_FEDERATION_IGNORE_SSL_ERRORS` is
  one entry, in openid-federation's `federation-entity` catalogue: the federation servlet's init-param `ignoreSslErrors`,
  then the system property `oidf.federation.ignore.ssl.errors`, then the environment variable, then the superseded
  `OIDF_TRUST_CONTROLLER_IGNORE_SSL` with a warning. Until 0.6.0 the servlet read the init-param and then the
  environment variable only, and `FederationRuntimeConfig` the system property, the environment variable and the
  superseded name. `HostedEntityServlet` reads its init-params `openBaoUrl` and `openBaoToken`, and without the pair
  leaves OpenBao to `RegistryHostedEntitySigner`, which reads `OIDF_OPENBAO_URL` and `OIDF_OPENBAO_TOKEN` through
  their `hosted-entity-signing` entries. Until 0.6.0 the servlet read each as init-param, then system property
  (`oidf.openbao.url`, `oidf.openbao.token`), then environment variable, and only when the pair was incomplete fell
  back to the signer's reading, which took the superseded `OPENBAO_*`, `BAO_*` and `VAULT_*` names. What is new: the
  superseded names are checked against the new ones even when the new ones are set, and a disagreement is refused.
- `FederationRuntimeConfig` logs its banner the first time it is read: each federation setting that is set and where
  its value came from, such as `OIDF_FEDERATION_IGNORE_SSL_ERRORS from system-property oidf.federation.ignore.ssl.errors`
  - the source and the name, never the value.
- The two automatic-registration limits, `OIDF_AUTO_REGISTRATION_MAX_REQUEST_OBJECT_BYTES` and
  `OIDF_AUTO_REGISTRATION_MAX_CONCURRENT_RESOLUTIONS`, are read as ints from 1 to 2147483647: `4294967297` was read as
  `1` and accepted, and is now refused. The per-client extended property `trust_chain_request_max_age` defaults to 60
  seconds for every reader: the OGNL chain criterion's default, now the attestation criterion's and the token-endpoint
  filter's for an attester's chain too, which used no limit (finding F-0198, closed). The validator drops a presented
  statement older than that and fetches it again, so a stale attester chain costs a fetch per statement, and one whose
  statements cannot be fetched - the host is unreachable, or `OutboundUrlPolicy` refuses it as private (only the trust
  controller is exempt) - now fails where the presented copy passed before. A client whose extended property
  `trust_chain_request_max_age` is `-1` keeps the old behaviour.
- Secrets can be read from a file: `OIDF_PDP_AUTH_TOKEN_FILE`, `OIDF_BRIDGE_VAULT_TOKEN_FILE`,
  `OIDF_AUTHORITY_JDBC_PASSWORD_FILE` and `OIDF_OPENBAO_TOKEN_FILE` (or the system property with `.file`) name a file
  whose content, one trailing newline trimmed, is the value; a name and its file variant set together are refused.
- The federation servlet validates each trust anchor as an Entity Identifier - an https URL with a host and no query,
  fragment or user info - and refuses one that is not, naming it; an issuer is recognised as an anchor with or without
  a trailing slash and whatever the case of its scheme and host (RFC 3986 §6.2.2.1: "the scheme and host are
  case-insensitive"). That is H-FED-8's anchor item; finding F-0050 closes when HFEDL, which has the other three items,
  has merged too.
- `FederationConfiguration` loses its dead methods (H-FED-10's part for this class; finding F-0052 stays open for the
  rest): `trustControllerHost()`, `trustAnchorIssuers()`, `defaultTrustAnchorIssuer()`, `findTrustAnchor(String)`, the
  constructors of 4, 9 and 10 arguments, and the `trustControllerHost` field - the init-param was read and nothing used
  it, and it is now a removed name.
- `OIDF_BRIDGE_PRIVATE_JWK` and `OIDF_BRIDGE_PREVIOUS_PUBLIC_JWK`, removed in 0.1.2, are refused by the catalogue's
  removed-name rule on every federation setting read, where `BridgeSigners` refused them itself.
- `OIDF_FEDERATION_CLIENT_REGISTRATION_TYPES=none` advertises neither registration type, which a list of nothing
  (`" , "`) did before.
- PR-2 for the federation stores (Phase 3 plan, decisions 9, 10 and 15): in production the hosted-entity registry
  kept in memory refuses `HOSTING`, and the Trust Mark registry or the key history kept in memory refuses `FEDERATION`
  when it issues Trust Marks or keeps a key history, unless the `in-memory-state` risk is accepted; a store that is
  not PostgreSQL refuses the same component. Each goes through `ProfileRefusals`, so the start-up audit lists it.
  Under development each is a WARN and the store is used.
- `HOSTING` asks a PingFederate data store what its database is, on one connection, when it starts: a database that
  cannot be reached then is `FAILED_DEPENDENCY`, retried by the supervisor, where until 0.6.0 hosting started and its
  first request failed.

- device-enrolment reads every setting through its `device-enrolment` catalogue with platform's `Settings` (plan
  item ST-5): a switch is `true` or `false` in any case, a number a whole number in its range, a choice one of its
  choices, and a value that does not parse stops the service naming it (`device-enrolment did not start: ...`, exit
  status 1). `REQUIRE_COMPLIANT_DEVICE` is no longer read leniently (finding F-0024, closed). The old `env(...)`
  helper is gone.
- device-enrolment runs the production profile's start-up audit over its own catalogue before it wires anything
  (plan items PR-3 and PR-5). Under production `REQUIRE_COMPLIANT_DEVICE=false`, `APPLE_ALLOW_DEVELOPMENT=true`,
  `PF_AUTHORITY_INSECURE_TLS=true`, a set `PF_AUTHORITY_ADMIN_TOKEN`, a value of any of those four that does not
  parse, and `REGISTRY=memory` without the `in-memory-state` risk each stop the process with exit status 1, every
  violation listed on stderr at once. Under development each is a warning. An `IDM_DATABASE_URL` for a database
  other than PostgreSQL is refused in every profile naming only its scheme, and a malformed DSN naming only why it
  does not parse: neither shows the value, which carries the password.
- gm-api reads `pdpUrl`, `pdpToken`, `audience`, `pdpTimeoutMs`, `issuer` and `grantManagementEndpoint` through its
  `gm-api` catalogue, strictly, init-param first and then the environment as before. The PDP URL must be `https`
  unless `OIDF_DEPLOYMENT_PROFILE=development` (plan item PR-3); an `http` one fails init and leaves `GM_API`
  `FAILED_CONFIG`, the reason naming `pdpUrl`.
- gm-api emits `gm.grant.evaluated` (the PDP's permit or deny, with its reason id), `gm.grant.refused` (the
  authorization server's refusal before the PDP is asked) and `gm.grant.revoked`, from its own `gm` event catalogue
  (plan item O-2): each is audited and counted in `oidf_events_total`, and carries the grant id and client id
  (pseudonymous), never a token, a consent's contents or the PDP's messages.
- ciba-sim refuses under the production profile whatever `OIDF_CIBA_SIM_ENABLED` says - its decision endpoint
  answers 404 and its authenticator fails every request - with one ERROR at the first refusal (plan item PR-3). It
  reads `OIDF_CIBA_SIM_ENABLED` and `OIDF_CIBA_SIM_DIR` strictly through its catalogue.
- The instance-registry data source has a new first field, **PingFederate data store**, the SDK's JDBC data store
  selector: the production way to the registry, through PingFederate's pool and credentials (plan item PR-3). The
  **JDBC URL** field is development only: under the production profile the driver refuses it at configure and
  answers every lookup with the refusal, naming the data store field. A data store that is not PostgreSQL is refused
  under production at the first lookup. A **User verification max age (seconds)** that is not a whole number now
  configures nothing, instead of falling back to 300. libs/platform is shaded into the plugin's jar.
- The attestation flow harness turns the JDK client's host name check off only with `OIDF_HARNESS_INSECURE_TLS=true`,
  read strictly; a live run without it checks the certificate's name as well as its chain (finding F-0162, closed).
- gm-api's example client `GrantManagementClient.java` takes `--cacert FILE` to trust a self-signed or private-CA
  PingFederate; `--insecure` and its trust-all are gone, and so is its exemption from `tools/trust-scan.py` (finding
  F-0163, closed).

- CI refuses a direct setting read outside platform (plan item ST-6): `tools/direct-read-scan.py`, in the Build
  workflow's lint job, fails on `System.getenv`, `System.getProperty`, `System.getProperties`, `Boolean.getBoolean`,
  `Integer.getInteger`, `Long.getLong` and `getInitParameter` - called, statically imported or handed on as a method
  reference such as `System::getenv` - in the main code of any module the root pom lists, outside `libs/platform`
  and platform-pf's `settings` package. Read a setting through `platform.settings` (`Settings`, `Sources`, and
  `InitParams` for a servlet's init-params) instead.
- CI refuses an outbound client outside `platform.http` (plan item ST-6): `tools/outbound-scan.py` fails on
  `java.net.http`, `HttpURLConnection` and `HttpsURLConnection`, `openConnection` and `openStream`, a raw socket, and
  the third-party clients it names (Apache HttpClient, OkHttp, Jetty's client, Netty, Spring's clients, JAX-RS,
  Kafka's and others) - imported, used by name or named in a string for a reflective load. Call through
  `OutboundHttp`, which carries the deadline, the address policy and the TLS trust.
- Each hit is printed as `path:line: what it is, and the allow-list line that would admit it`. The allow-lists,
  `tools/direct-read-allow.txt` and `tools/outbound-allow.txt`, admit a module only if it is never shipped
  (`libs/testkit`, `services/harness`), and anything else by file and line pattern, with a finding id or a reason.
  CI runs both scans with `--check-allow-list`, which also fails a line that admits nothing, so converting a read
  means deleting its line.

- New release asset `oidf-preflight.jar` (plan item ST-7, under F-0025): platform's `Preflight` with platform's classes
  and all 28 settings catalogues of the reactor in one jar, built by a new module, `tools/preflight`.
  `java -jar oidf-preflight.jar --env-file FILE [--profile production|development] [--accepted-risks IDS]` judges an
  env file as the release's start-up sweep would and exits 0 when nothing would be refused, 1 when a component would
  be, and 2 when it cannot read its arguments or the file. `--accepted-risks` judges with that list in place of the
  file's `OIDF_ACCEPTED_RISKS`; `--list` prints every catalogue it holds with its module and entry counts. Its
  manifest names the version, the commit and the catalogues.
- The build fails when a reactor module's catalogue is not in the jar, or differs from the jar's copy: a module that
  gains a catalogue is held until `tools/preflight/pom.xml` takes it in.
- CI runs the jar on java 17, java 21 and the java in PingFederate's image against two fixtures, a clean env file and
  one with a line of each violation kind; the release copies it into its assets and `SHA256SUMS`, and publishes it to
  GitHub Packages as `com.pingidentity.ps.oidf:oidf-preflight`.
- [docs/operator/preflight.md](docs/operator/preflight.md) says how to run it on a Docker env file, a Kubernetes
  ConfigMap and PingFederate's `run.properties`, what each exit status and each line means, and what it cannot check.

## [0.5.0] - 2026-09-29

Phase 2 of the production programme, foundations: the shared `platform` and `platform-pf` libraries, which
most shipped modules now use, a settings catalogue per component with the configuration reference generated from them
and held to the code both ways, events, metrics, health and a start-up audit, managed background threads, a pooled
Redis client, an outbound HTTP client pinned to the addresses it checked, PostgreSQL as the only store database,
and the image built, tested and scanned in CI. Notes: [docs/releases/0.5.0.md](docs/releases/0.5.0.md).

- Plan item C-2: `libs/platform` gains `platform.redis`. `RedisClient` is client-attestation's `MiniRedisClient`
  moved to platform with S3a's rules unchanged - `rediss://` verified by chain, name and SNI with the handshake
  before `AUTH`, `OIDF_REDIS_CA_FILE`, `redis://` refused under the production profile (now through
  `ProfileGuard`), no userinfo in a message - and with a pool bounded by `OIDF_REDIS_POOL_SIZE`, a wait for a
  connection bounded by `OIDF_REDIS_BORROW_TIMEOUT_MS` and every command under `OIDF_REDIS_COMMAND_TIMEOUT_MS`.
  `RedisKeyspace` puts a prefix before every key. The commands leases (C-4) and rate limits (X-A11) need are there:
  `SET` with `NX` and `PX`, `GET`, `DEL`, `INCR`, `PEXPIRE`, `EVALSHA` with the `NOSCRIPT` fallback to `EVAL`, a
  compare-and-delete and a compare-and-extend script, and a fixed-window counter.
- Redis Sentinel: with `OIDF_REDIS_SENTINEL_MASTER` and `OIDF_REDIS_SENTINELS` set (and
  `OIDF_REDIS_SENTINEL_PASSWORD` when the sentinels ask for one), the client finds the master through
  `SENTINEL get-master-addr-by-name`, asking each sentinel in turn within an equal share of the command's deadline,
  checks it with `ROLE`, and finds it again after a failover - a `READONLY` reply or a lost connection. The command
  is retried once on the new master after `READONLY`, or when the master could not be reached; a command that may
  have run is not sent twice. TLS and the CA file apply to the sentinels as to the master.
- The Redis settings are catalogued in `platform-redis.json`, read through `platform.settings`:
  `oidf.redis.url`, `OIDF_REDIS_URL` and `REDIS_URL` in that order, `OIDF_REDIS_CA_FILE` and its property, and the
  six new ones. A value its entry refuses stops the Redis stores as a bad URL does, with the setting named.
- client-attestation's stores run on `RedisClient`; `MiniRedisClient` and client-attestation's own
  `DeploymentProfile` are gone. The keys are byte for byte 0.4.0's (`oidf:as:*`, `oidf:cas:*`,
  `oidf:fed:endpoint:*`, `oidf:admin:dpop:*`), the verdicts are still tri-state, and an outage is still 503. New in
  the register: F-0180, F-0181, F-0182, F-0183, U-0190. F-0007 stays open.

- Plan item C-3: `libs/platform` gains `platform.exec`. `ManagedExecutors.every`, `after` and `single` start a
  job on an executor of its own with one daemon thread named `oidf-<name>-<n>`, registered with the copy's
  lifecycle (closed at shutdown within five seconds), listed per classloader, and counted per run in
  `oidf_executor_runs_total`, `oidf_executor_failures_total` and `oidf_executor_run_seconds`. A run that throws
  is logged and counted and the job carries on. A job runs once in the JVM, whichever classloader starts it, and
  a plugin's relocated copy starts none.
- The registration expiry sweeper, the federation subordinate refresher, and the SSF push delivery, receiver
  poll and boot-retry loops run on it, with their timing, log lines and failure handling unchanged. Their threads
  are renamed (see the Notes).
- `Lifecycle` closes each resource on a thread started through `ManagedExecutors.startDaemon`, so platform.exec
  is the one place the repository's shipped PingFederate code starts a thread; closes F-0131. New in the
  register: F-0200, F-0201, F-0202, U-0210.

- The store suites run on PostgreSQL only, each test class in a database of its own: `libs/testkit` (test
  scope, never shipped) creates it on the server `OIDF_TEST_JDBC_URL` names, or in one Testcontainers 1.21.4
  container per JVM, and drops it afterwards; with neither the class is skipped, and under `CI=true` it fails.
  The hosted-entity, Trust Mark, key-history and agent registries run their shipped migrations there instead
  of on H2, and both durable SSF stores are held to the whole `SsfStore` contract on Postgres (DB-1).
- H2 and HSQLDB support is gone: a `jdbc:h2:` or `jdbc:hsqldb:` authority store URL (`OIDF_AUTHORITY_JDBC_URL`)
  or SSF store URL (`OIDF_SSF_JDBC_URL`) is refused at start-up with a message naming PostgreSQL, a PingFederate
  data store id (`OIDF_AUTHORITY_DATA_STORE_ID`, `OIDF_SSF_DATA_STORE_ID`) whose database reports itself as H2 or
  HSQLDB is refused on its first connection, and H2 leaves every module's test classpath.
- `IDM_TEST_JDBC_URL`, `_USER` and `_PASSWORD` are renamed `OIDF_TEST_JDBC_*`; the old names are read in 0.5.x
  with a warning. Testcontainers moves from 1.19.8 to 1.21.4, which finds Docker Desktop 29 (U-0050, closed).

- New modules `libs/platform` (`com.pingidentity.ps.oidf:platform`, JDK only) and `libs/platform-pf`
  (`com.pingidentity.ps.oidf:platform-pf`, PingFederate's jars provided), the shared base Phase 2 builds on
  (plan item F-1). They hold, so far: a per-classloader registry of what to close at shutdown, a component
  registry in S-9's seven states, a copy of rar-model's JDK-only JSON reader and writer, a logger that writes
  through commons-logging where the loader has it, and the guard an OGNL criterion runs behind.
- `oidf-jose` depends on `platform` and `pf-integration` on `platform-pf`, so `oidf.war` carries both jars and
  `stage-modules.sh` stages both, in both profiles, into the war and onto the engine's classpath. The
  `MANIFEST` is now the one list of staged jars: the image README, the Dockerfile, the SSF and `oidf-war`
  READMEs and the showcase point at it instead of counting.
- docs/development/classloaders.md writes down the classloader rules the
  libraries follow.

- Plan item F-2: `libs/platform-pf` gains `LifecycleListener`, registered by name in `pf-runtime.war` (through
  `build/pingfederate/filters.xml`, which the war assembler writes into its `web.xml`), in `oidf.war` and in
  `gm-api.war`. At start-up it marks the war's copy of platform as the webapp's, registers its metrics MXBean and logs
  one start-up audit banner at INFO after the war's filters and load-on-startup servlets have started; at undeploy it
  closes that copy's managed executors, MXBean and Redis pools within five seconds. It touches only a copy of platform
  its own war's classloader loaded.
- `gm-api.war` bundles `platform-pf` and `platform` in its `WEB-INF/lib`, so it has its own components, metrics and
  banner, and its own health at `/gm-api/agentic-identity/health/{live,ready}`; its two load-on-startup servlets
  register the component `GM_API`.
- New in the register: F-0210, F-0211 and U-0220. Closed: U-0024 (a `@WebListener` in a `WEB-INF/lib` jar runs in
  `pf-runtime.war` without a `web.xml` entry; one in `server/default/deploy` runs nowhere).

- gm-api imports the BOM like every other module and depends on the real coordinates of what PingFederate
  provides (`pingfederate-sdk`, `jakarta.servlet-api`, `jose4j`, `jackson-databind`, `jackson-core`), all
  `provided` and version-less; ciba-sim and instance-registry-datasource take `org.apache.commons:commons-lang3`
  from the BOM. Nothing names `local.pingfederate` any more.
- The `pf-provided-jars` action installs only `pf-protocolengine` and `pingfederate-sdk`; it still extracts
  `pf-lib` and `pf-jetty-lib` for `tools/pf-linkcheck.py` and `tools/pf-provided-versions.py`, which now checks
  `jackson-core` against the image as well.

- Events live in `platform.events` (plan item O-1): the event record, now with a component, the sink interface, the
  per-classloader sink registry, the server-log sink and `LogSafe`, with the rule that an instance's subject is
  never recorded beside its `agent_id`. `FederationEvent`, `FederationEvents`, `FederationEventSink`,
  `LoggingEventSink` and `LogSafe` in openid-federation are delegating façades, deprecated for removal by O-2.
- Every event code and every field it may carry is catalogued as data, in `META-INF/oidf-events/<component>.json`
  of the module that declares it - `federation` in openid-federation, `attestation-issuer` in the attester - with
  one PII class per field (`OPERATIONAL`, `PSEUDONYMOUS_ID`, `DIRECT_ID`, `NETWORK`, `CREDENTIAL_DIGEST`). A field
  its code does not declare is dropped before any log sees it, and counted.
- PingFederate's audit sink is `platform.pf.audit.PfAuditSink` in platform-pf, with the audit log's `protocol`
  column set per component from its catalogue; `PfAuditEventSink` in pf-integration is a delegating shim.
  `OIDF_EVENTS_AUDIT` and `OIDF_EVENTS_MAX_VALUE_LENGTH` are unchanged.
- `EventsCataloguedTest` fails the build on an emitted code or field that is not catalogued, on a catalogued code
  nothing emits unless it is marked `declaredOnly`, and on an emitter whose audit flag or outcome its catalogue
  does not match.

- Plan item O-3: `libs/platform` gains `platform.metrics` - `Metrics.counter`, `timer` and `gauge`, each
  registered once with fixed, bounded labels (a declared set, or a cap past which values count as `other` and a
  fold counter rises), timers with a count, sum, max and fifteen fixed buckets from 1 ms to 60 s, and a lock-free
  hot path. Each loaded copy of platform registers one MXBean, `com.pingidentity.ps.oidf:type=Metrics,copy=...`,
  unregistered through its lifecycle. O-3 itself registers no metric: C-3 (the `oidf_executor_*` counters and
  timer) and O-4 (`oidf_events_total` and its companions) are the first users, both in 0.5.0; O-5 is the
  Prometheus endpoint. New in the register: F-0170, U-0180.

- Plan item O-4: PingFederate's runtime port answers `/agentic-identity/health/live` and
  `/agentic-identity/health/ready` (open, status only; ready is 503 when an enabled component is not ready or
  degraded), and `/agentic-identity/health` and `/agentic-identity/info` (the detail and the versions, only for the
  static admin bearer `OIDF_AUTHORITY_ADMIN_TOKEN`, 404 for anyone else). `libs/platform` gains `platform.health`
  (component parts, readiness, the documents), `libs/platform-pf` the `HealthServlet`.
- The servlets and filters register their parts under S-9's component names from their `init`, and record a
  failure's state and reason before rethrowing it unchanged; whether any of them starts is as before.
- Every event counts itself in `oidf_events_total{code,outcome}`, labels bounded by the event catalogues, with the
  gauges `oidf_events_dropped_fields` and `oidf_events_uncatalogued`. New in the register: F-0190 to F-0194.

- Plan item F-1, its platform-pf part: `libs/platform-pf` gains `platform.pf.internals.PfInternals`, the one class
  that calls PingFederate's internal services - the issuer lookup, the client manager, the token endpoint base URL
  and the discovery document handlers - and `ClientManager.isBackendDatabase()`, which C-1 will read. Every caller
  in pf-integration and attestation-issuer goes through it, and a test keeps any other production class from
  naming those internals again. platform-pf's README lists every PingFederate class and member the reactor links,
  by kind. New in the register: F-0215.

- `libs/platform` gains `platform.profile` and `platform.tls` (plan item PR-1). `DeploymentProfile` is the one
  reading of `OIDF_DEPLOYMENT_PROFILE` - `development`, trimmed, in any case, and production for everything else,
  unset included - and every module reads it there: client-attestation, attestation-issuer, rar-model, the RAR
  plugin and ciba-sim. `AcceptedRisks` reads the new `OIDF_ACCEPTED_RISKS`, and `ProfileGuard` asks whether a
  switch is forbidden, required or an accepted risk under the production profile. Nothing asks it yet: PR-2 and
  PR-5 (Phase 3) wire the switches and refuse components.
- `InsecureTls` is now the only place a trust-all TLS context is built. The federation fetches
  (`OIDF_FEDERATION_IGNORE_SSL_ERRORS`), the RAR plugin's "Skip TLS verification (dev only)", the SSF
  receiver's and introspection's insecure-TLS switches, device-enrolment's `PF_AUTHORITY_INSECURE_TLS` and the
  harness ask it; each use logs one WARN naming its setting. What each switch trusts is unchanged: any
  certificate chain, and the certificate must still name the host dialled - except in the harness, which turns
  the JDK's host-name check off for every run ([F-0162](docs/findings.md#f-0162)).
- `tools/trust-scan.py`, a new step in the lint job, fails on a trust-all trust manager, an always-true
  hostname verifier, a null endpoint identification algorithm or the JDK's hostname flag anywhere else in main
  code (F-0042, CodeQL alerts 4 to 9).
- The RAR plugin and ciba-sim shade and relocate platform, as the RAR plugin already does Jackson and rar-model;
  ciba-sim's jar is now a shaded jar under the same name. rar-model depends on platform.

- `tools/coverage-report.py` also writes `docs/coverage-dashboard.json` (git-ignored, published in the
  `coverage-dashboard` artefact): per module, each jacoco check's methods with their line and branch counters,
  the test counts, and the `@Requirement` ids and matrix rows its tests pin.
- `--gate` fails on a jacoco check or `<include>` pattern that selects no method and on an undeclared
  `@Requirement` prefix, and counts the ids no conformance-matrix row declares.
- `--baseline <json>` ratchets against an earlier build: a check gone or shrunk, a gated method below 100%, or
  fewer pinned matrix rows fails, less the deliberate reductions `tools/coverage-ratchet-allow.txt` names.
  Build's java job runs both, against the newest successful Build on main that the commit descends from
  (`tools/ci/coverage-baseline.sh`, with `actions: read` on that job only).

- `build/pingfederate/Dockerfile` has three targets: `builder` assembles `pf-runtime.war`, `capability` is the
  image with no configuration archive, and `deployment` adds the archive and `overlay/` to it. `deployment` is the
  last stage, so `docker build` with no `--target` builds the image it built before (plan item R-CI6, taking
  plan item R-I3's targets ahead of Phase 3). The bake-ins R-I3 removes - the EULA, DEBUG logging, the 9080
  listener, `ForceUnsupportedImport`, the required claims and the mock attesters - are unchanged.
- Build has an `image` job, and `.github/required-checks.txt` names it, so a release needs it green. It builds
  `capability` for both staging profiles, runs `test-entrypoint.sh --image` in each, runs the war assembler against
  PingFederate's own `pf-runtime.war` (`StockWarGoldenTest`), builds the default target from a placeholder
  archive and without one, publishes a syft SBOM of each image (SPDX JSON, the `image-sbom` artefact), and scans
  each with grype, failing on a HIGH or CRITICAL finding in the layers this repository adds and reporting the
  base image's own without failing.
- `tools/ci/install-lint-tools.sh` installs grype 0.119.0 and syft 1.52.0 by checksum; `.github/grype.yaml` names
  the accepted findings with their reasons; `tools/ci/image-scan-gate.py` decides what is ours.
- `tools/pf-version-check.py` and `tools/pf-version-sync.py` read a `FROM` that names its stage, and treat a
  `FROM` naming an earlier stage as a stage rather than an image.

- New module `build/war-assembler` (`com.pingidentity.ps.oidf:war-assembler`, JDK only, compiled for 17): it
  builds `pf-runtime.war` from the stock war, the staged jars and `build/pingfederate/filters.xml`, which now
  declares the seven filters, their paths and the order rules the script used to write with awk (plan item
  R-I5). It refuses a war in which a declared filter lacks exactly one `<filter>` and one `<filter-mapping>` over
  exactly its paths, an order pair does not hold, a path is one the stock `web.xml` does not serve, the root is
  `metadata-complete="true"`, or a declared filter's class is in no jar, and prints each path's filter chain.
  Published to GitHub Packages with the rest of the reactor from the next release; the release assets do not
  carry it.
- `assemble-pf-runtime-war.sh` keeps its command line and exit codes and is now a wrapper that runs it; the
  `MANIFEST`, profile and namespace checks moved into the assembler with their messages. A refusal still leaves
  no output war, and the wrapper now also removes it when the JVM itself fails. With too few arguments it now exits
  2 with a usage line (it exited 1 on an unbound variable); with more than five it exits 2 too (it ignored the
  extras and assembled). `STOCK_WAR` and `OUT_WAR` naming the same file now exits 2 with nothing touched (the script's
  `cp` failed on it, and its clean-up then deleted the stock war).
- `stage-modules.sh` also stages the assembler, as `assembler/war-assembler.jar` beside `modules/`; the Dockerfile
  copies it with `filters.xml`, and `conformance/compose-context.sh` carries both.

- `platform.http`: an outbound HTTP/1.1 client (`OutboundHttp`) that resolves a host once, checks every address
  it resolves to, and connects only to one of those, with the host name kept as TLS SNI and checked against the
  certificate. Every read is bounded by what is left of a connect, header or total deadline, and the body by a
  cap, whether its length is declared, chunked or delimited by close. GET, POST, PUT, PATCH and DELETE, headers on
  every method, the status always returned, no redirects. With it: `Deadline`, `Budget` (a wall clock and a
  request count, with child budgets), `AddressPolicy` (oidf-jose's URL rules, plus 0.0.0.0/8, 240.0.0.0/4,
  Teredo, the IPv6 forms that embed a non-public IPv4 address, and no exemption for a path a server could
  normalise or decode out of the exempt prefix), `TlsTrust` and a `Bulkhead` seam
  (plan item S5a, part 1). oidf-jose's `JdkHttpClient` (below) and rs-validation's `RemoteJwks` are its callers
  in 0.5.0.
- The platform jar now carries Apache HttpComponents Core 5.4.4, relocated under
  `com.pingidentity.ps.oidf.platform.http.internal.hc5` and minimised; it grew from 227 KB to 448 KB when S5a added
  it, within this release (0.4.0 had no platform jar), and the 0.5.0 jar is 527,323 bytes (built 2026-09-29).

- oidf-jose's `JdkHttpClient` (and `JdkHttpGetClient`, which delegates to it) sends through platform's
  `OutboundHttp` instead of the JDK's `java.net.http` client. `OutboundUrlPolicy` resolves the host once, checks
  every address, and the connection goes to one of those addresses and nowhere else, with TLS still checking the
  certificate against the URL's host. A name that answers publicly for the check and privately for the connection
  (DNS rebinding) now reaches nothing; before, the JDK client resolved the name again and connected where the second
  answer said (finding F-0070, closed). Every federation fetch, entity statement, JWKS, trust mark status and AuthZEN
  PDP request made through these classes is covered; the public API, the 8 s connect and 15 s request timeouts,
  HTTP/1.1, no redirects and the body cap are unchanged.
- The 15 s request timeout now bounds the whole exchange, the body included. The JDK client's stopped once the
  headers arrived, so a peer could trickle a body for as long as it liked.
- A per-origin bulkhead: at most 32 requests to one `scheme://host:port` run at once in each loaded copy of
  oidf-jose. A request that finds all 32 places taken waits for one until its own deadline and then fails as a
  failed fetch (platform's `OutboundHttpException`, reason `BULKHEAD_FULL`), which every caller already handles as
  it handles a timeout. `platform.http.HostBulkhead` is the implementation; there is no setting.
- `OutboundUrlPolicy`'s scheme and address rules are now platform's `AddressPolicy`, so federation fetches refuse
  the addresses platform refuses and the old policy did not: 0.0.0.0/8, 240.0.0.0/4, the three IPv4
  documentation ranges, all of IPv6 ::/96, discard-only 100::/64, Teredo 2001::/32, 2001:db8::/32, and the
  IPv4-translated, NAT64 and 6to4 forms that embed a non-public IPv4 address. A path with a dot segment, a backslash
  or a percent sign left after one decoding is never inside a `trusting()` exemption. The `OIDF_FETCH_*` settings
  mean what they meant.
- A platform `OutboundHttp` read on a silent peer now ends when its thread is interrupted, as the JDK client's did,
  so closing the subordinate refresher's executor still stops a fetch in progress (finding F-0205, closed).

- Plan items ST-1 and ST-2: `platform.settings` holds the strict parsers `FederationRuntimeConfig` used, with
  their messages (`Parsers`), and the settings model - `Setting`, a resolver that returns each value with the
  source and name that supplied it, aliases, removed names, `_FILE` secrets - loaded from one JSON catalogue per
  component at `META-INF/oidf-settings/<component>.json`, read through typed accessors (`Settings`).
  `UnknownKeys.find` lists `OIDF_*` names under a catalogued family that nothing declares; nothing calls it at
  run time yet. `platform-pf` adds `InitParams`, a servlet's or filter's init-params as a source.
- `FederationRuntimeConfig` reads through `Parsers`; its names, precedence, defaults and messages are unchanged.
  `OIDF_AUTHORITY_METADATA_POLICY` and `OIDF_FEDERATION_SUBORDINATE_CONSTRAINTS` are read by `platform.json`
  instead of Jackson, which refuses a few documents Jackson accepted (see "Check that
  `OIDF_AUTHORITY_METADATA_POLICY` and `OIDF_FEDERATION_SUBORDINATE_CONSTRAINTS` are each one well-formed JSON
  object" below).
- docs/development/settings-catalogue.md describes the catalogue
  format, with a worked example.

- Plan item ST-3 (part 1 of 3): `tools/settings-scan.py` checks, in the Build workflow's lint job, that every
  setting the reactor's main code reads is declared in a settings catalogue and that every catalogued setting is
  read. A read is an `OIDF_` name that is the whole of a string literal, a `System.getenv`, `System.getProperty`
  or `getInitParameter` call (or a PingFederate plugin field or a client's `extproperties.` name) whose argument
  is a literal, a constant or a loop over an inline list of them, and the same through any helper method that
  passes its parameter on. A read through one of those calls, or through a helper, whose name it cannot work out
  is refused rather than ignored; a lookup in the whole environment as a map (`System.getenv()` passed on) is not
  seen, beyond the `OIDF_` literal rule. A read through `platform.settings` (`settings.secret(URL_SETTING)`, as
  platform's Redis client reads the `platform-redis` catalogue) reads the entry it names, and with it the entry's
  sources and aliases. `tools/settings-scan-exemptions.txt` lists the modules the scan does not hold to a
  catalogue; in 0.5.0 it names only `libs/testkit` and `services/harness`, neither shipped, and
  `refuse-shipped-exemptions: yes` refuses any exemption outside its not-shipped group.
- Eleven catalogues, one per component, under `src/main/resources/META-INF/oidf-settings/`: `deployment-profile`
  (platform), `pf-audit` (platform-pf), `outbound-fetch` (oidf-jose), `federation-entity` and
  `hosted-entity-signing` (openid-federation), and `federation-runtime`, `registration`,
  `attestation-token-endpoint`, `client-properties`, `fapi2-profile` and `hosted-entities` (pf-integration) - 127
  settings with their sources, defaults, types, profile classes and whether they bear on security. The jars carry
  them; nothing reads them at run time yet.

- Plan item ST-3 (part 2 of 3): eight more settings catalogues, one per component, under
  `src/main/resources/META-INF/oidf-settings/`: `attestation-challenge` (client-attestation's two challenge
  endpoints), `rar-models` (rar-model's `OIDF_RAR_MODELS_FILE` and `OIDF_RAR_MODELS`), `attestation-issuer`,
  `evidence-policy` and `issuance-client-properties` (attestation-issuer, the last its eleven per-client
  `attestation_*` extended properties and `attestation_asserted_context_resolver`), `rar-pdp-processor` (the RAR
  plugin's fifteen configuration fields and `OIDF_RAR_EXTRA_TYPES`), `instance-registry` (the data source's two
  fields and its filter field) and `ciba-simulator` (`OIDF_CIBA_SIM_ENABLED` and `OIDF_CIBA_SIM_DIR`) - 58
  settings with their sources, defaults, types, profile classes and whether they bear on security. A plugin field
  is catalogued under the name PingFederate shows for it, and its entry names the plugin's descriptor id. The
  settings scan no longer exempts these six modules. The jars carry the catalogues; nothing reads them at run
  time yet. New in the register: F-0230, F-0231, F-0232.

- Plan item ST-3, part 3 of 3: servlets/ssf, services/device-enrolment and services/gm-api/servlet have settings
  catalogues - `ssf-transmitter.json` (SsfConfiguration's 43 settings), `ssf-logout-signal.json`
  (`OIDF_SSF_LOGOUT_ALLOW_SUB_PARAM`), `device-enrolment.json` (31 environment variables, the non-OIDF names
  included) and `gm-api.json` (six init-params and their environment fallbacks). Each entry records its default,
  what today's parser does with a wrong value and its profile class. Nothing reads through them yet (ST-5).
- `tools/settings-scan.py` reads computed names: a literal or constant prefix `+` a name, or `+`
  `camelToUpperSnake(name)`. `SsfConfiguration.param(config, "x")` is a read of init-param `x`, system property
  `oidf.ssf.x` and `OIDF_SSF_<X>`, and the scan checks that one call's names are one entry's sources in the order
  `param` tries them. The ST3C group of the scan's exemption file is gone; services/harness joins the "not shipped"
  group.
- The two Postgres SSF stores order a second's SETs by `jti COLLATE "C"`, so the order is the one the store
  contract promises on a database with a linguistic collation too (F-0236). The Build workflow runs the SSF store
  suites on a glibc-collated Postgres as well as the alpine one. New in the register: F-0235, F-0236, F-0237,
  F-0238. F-0025 and F-0026 stay open.

- Plan item ST-4: `tools/config-reference.py` writes the configuration reference from the settings catalogues -
  one page per component in `docs/configuration/`, 24 of them, each saying which catalogue it came from, with the
  style guide's four columns and two more, Profile and Security - and the list of components in
  `docs/configuration/README.md`. The Build workflow's lint job runs it with `--check` and fails, naming the file,
  when a committed page is not what the catalogues generate. The settings A-Z index is written on demand
  (`--index FILE`) and never committed.
- `docs/extended-properties.json` is generated too, from every catalogue's extended-property entries: beside the
  federation module's ten names it now lists 24 more: the nine per-client `attestation_*` properties the token
  endpoint reads, the three `trust_chain_*` limits, and the attester's twelve `attestation_*` names,
  `attestation_asserted_context_resolver` among them. Its `_comment` and shape are unchanged apart from saying
  where it now comes from. The conformance rig's Terraform, which reads the file, declares every one of them,
  each described as read or written by the OIDF modules. Closes F-0041.
- The settings scan's exemption file sets `refuse-shipped-exemptions: yes`: only modules that are never shipped
  may be exempt, each with its reason, and the scan says every shipped module is held to its catalogues. With
  `--check`, the reference is held to the code both ways: the scan holds the code to the catalogues, and the
  generator holds the catalogues to the pages.
- `ConfigurationDocumentedTest` is gone; `FederationClientParamsTest` holds
  `FederationClientParams.EXTENDED_PARAM_NAMES` to pf-integration's `client-properties` catalogue.
- `docs/federation/configuration.md` keeps how a setting is read and what "wrong" means, points each part of the
  federation at the generated pages, and keeps what a row has no room for: examples of the JSON settings'
  shapes, and what the rows leave out.

- New module `libs/shared-signals` (`com.pingidentity.ps.oidf:shared-signals`, package
  `com.pingidentity.ps.oidf.signals`; plan item X-A14): the RFC 8417 SET model, minting behind `oidf-jose`'s
  `SigningKeyProvider` or `JwsSigner`, verification against a supplied key set, the subject identifiers, and the
  CAEP and RISC event types. No HTTP and no PingFederate, so a service outside PingFederate can mint and verify SETs
  with the code `servlets/ssf` uses.
- `SecurityEventToken`, `SetMinter`, `SetVerifier`, `ReceivedSet`, `SubjectId` and `CaepRiscEvents` moved from
  `com.pingidentity.ps.oidf.ssf` to `com.pingidentity.ps.oidf.signals`; no class of the old name is left behind,
  because keeping the package in a second jar would split it across two jars again (the 2026-08-15 unwind in
  PROVENANCE). `SsfEventTypes` stays in `servlets/ssf` as the list the transmitter
  advertises; its URIs are the new `EventTypes`. What needs PingFederate or the network stays in `servlets/ssf`:
  `PfSetSigningKeys` (PingFederate's signing key, resolved on first use as before) and `JwksHttpSource` (the
  receiver's JWKS fetch, which plan item S5d moves onto platform's HTTP client).
- `SubjectId` parses RFC 9493's `did`, `uri` and `aliases`, SSF 1.0's `jwt_id`, `saml_assertion_id` and
  `ip-addresses`, and SSF 1.0's complex subject, and implements SSF 1.0 §8.1.3.1's subject matching (finding U-0033,
  closed). `servlets/ssf` still accepts only the five formats it handled before (`iss_sub`, `email`,
  `phone_number`, `opaque`, `account`) - in stream subjects, the emit API, SCIM ids and an inbound `sub_id` - until
  plan item H-SSF-1 stores, matches and acts on the others.
- The receiver's SET verification is stricter (finding F-0245, closed): `typ` must be `secevent+jwt` (with or without
  `application/`, in any case), not merely contain `secevent`; `alg` must be an asymmetric signature algorithm;
  `iat` must be present and a number; an `exp` that has passed, less 60 seconds, is refused; `events` must be an
  object with at least one member, each an object; a `sub_id` that is not an object is refused.
- `build/pingfederate/stage-modules.sh` stages `shared-signals-<version>.jar` in both profiles, so the image carries
  it and the `MANIFEST` names it.

- Plan item X-B01: each instance-attestation validator now proves a fixed, bounded set of evidence selectors,
  `InstanceIdentity.selectors()`, in one `<evidence type>:<name>` namespace, built only from the claims it verified
  and only after every check passed. Nothing reads them yet and minted attestations are unchanged; X-B09 (Phase 5)
  is to condition ceilings on them. Evidence over the bounds (32 values, 2048 bytes a value) is refused. New in the
  register: F-0140.

- Plan item X-D01: `services/demo-rs` moves to `libs/rs-validation` (`com.pingidentity.ps.oidf:rs-validation`), with
  the package `com.pingidentity.ps.oidf.rs` unchanged. `services/demo-rs` is now a relocation POM: a build that
  depends on `demo-rs` 0.5.0 or later resolves `rs-validation` at the same version.
- `DelegatedTokenValidator` is built with `DelegatedTokenValidator.builder(issuer, audience)`, and `build()` refuses
  without the authorisation server's keys and a `ReplayStore`. The replay store is asked last and refuses a DPoP
  proof it has seen (`invalid_dpop_proof`); a store that cannot answer is a 503. `RedisReplayStore` (`SET NX PX`
  through `platform.redis`) serves more than one node, `InMemoryReplayStore` one.
- The access token's `kid` must name exactly one published key (a token without one is refused, with no fallback
  to trying every key), its `typ` must be RFC 9068's `at+jwt` unless `accessTokenType(...)` says otherwise, and
  `nbf` is checked. The request method and URI are required.
- `act` is strict: a malformed chain, one deeper than 10 levels, and the legacy string form are refused; the string
  form only when this process runs under the development profile, through `allowLegacyStringAct()`.
- New: resource-server DPoP nonces (`DpopNonces`, an HMAC over a time window, with `use_dpop_nonce` and
  `DPoP-Nonce`), mTLS certificate-bound tokens (`cnf.x5t#S256`, under the Bearer scheme when `mtls(true)` is set),
  `RemoteJwks` (the JWKS through `platform.http`, cached by `kid`, refreshed on an unknown `kid` at most every 30 s,
  and its keys no longer used once twice the 10-minute maximum age old while fetches keep failing), and `ResourceServerFilter`, a `jakarta.servlet.Filter` that answers with the RFC 6750 and RFC 9449 challenges.
- Findings: U-0011 and U-0035 closed; F-0225, F-0226, F-0227, F-0228 and F-0229 recorded.

## [0.4.0] - 2026-09-27

Phase 1 of the production programme: the review's blockers closed or mitigated, the findings register, CI
hygiene, and one PingFederate node only until 0.7.0
([docs/operator/deployment-limits.md](docs/operator/deployment-limits.md)). Notes:
[docs/releases/0.4.0.md](docs/releases/0.4.0.md).

- **R-I1 Staging profiles** - `stage-modules.sh --profile production|conformance` (production, the default, leaves
  the CIBA simulator out), a v2 `MANIFEST` naming the profile, a section per module group and a sha256 per jar,
  and an assembler and Dockerfile (`STAGING_PROFILE`, recorded as an image label) that refuse a stage made for
  the other profile.
- **R-I4 Entrypoint hardening** - `umask 077` first; `PF_ARCHIVE_AGE_KEY_FILE` preferred, the inline key piped and
  both variables unset before PingFederate starts; `PF_ARCHIVE_SHA256` checked before the archive is decrypted or
  imported; `PF_ARCHIVE_FILE`, binary or armored age; a plaintext archive refused unless
  `OIDF_DEPLOYMENT_PROFILE=development`; the tmpfs claim corrected; `test-entrypoint.sh`.
- **X-D02 ciba-sim conformance-only** - the decision endpoint (404) and the authenticator (`OOBAuthGeneralException`)
  refuse every request unless `OIDF_CIBA_SIM_ENABLED=true`, `OIDF_DEPLOYMENT_PROFILE=development` and
  `OIDF_CIBA_SIM_DIR` is an existing private directory the plugin owns; the rig sets all three.
- **Information architecture and style** (D-1) - `docs/{operator,configuration,reference,security,development,findings,releases}`
  each with a README saying what belongs there; `SECURITY.md`, `CONTRIBUTING.md` and a pull request template;
  the house style in `docs/development/style-guide.md`, with `tools/doc-lint.py` checking what a machine can
  against a dated baseline, in a new `docs.yml` workflow.
- **Findings register** (D-2) - one YAML file per finding under `docs/findings` (`F-` defects, `U-` unverified
  assumptions), seeded from the 2026-09-26 review, the reviewer reports, the plan's "Found while designing"
  list and `docs/unverified.md`; `tools/findings.py --check` in CI, `--gate` for a release, `list` and `index`
  on demand.
- **CI hygiene** (R-CI1 to R-CI4) - every action pinned to a commit with least-privilege tokens; actionlint,
  zizmor, shellcheck and `terraform validate` in the lint job; the secrets guard's content scan extended to private
  JWKs and every PEM kind, with gitleaks over the whole history beside it; CodeQL for Java, Actions, Python and
  JavaScript; Dependabot; the rig's Terraform lock file committed; CODEOWNERS.

- **iOS reference client** (X-I01a) - `clients/ios`: AgentIdentityKit, a Swift package for the device side of
  `services/device-enrolment` (enrol, re-mint, the user-verification refresh, the counter-race retry) with App
  Attest, the Secure Enclave and PingOne behind protocols, tested with fakes and against the service's own Java; a
  sample app that also captures App Attest vectors; `docs/device/ios-client-contract.md`; a macOS job, `ios.yml`.
  A skeleton until X-I01b.
- **Generated files leave git** (plan decision 18; R-CI5's publish step, brought forward from Phase 2):
  `docs/coverage-dashboard.md` and `.html` and the showcase's rendered documents (now `showcase/docs.js`) are
  generated and git-ignored; a CI Build whose reactor build completes publishes them as its `coverage-dashboard`
  and `showcase` artefacts (a run that fails in `mvn verify` publishes neither); `tools/coverage-report.py` is
  strict by default and exits 1 for a build that left a module without its reports; the Build's `java` job runs
  device-instance's Postgres suite against a service container.
- **Redis verified and tri-state** (S3a) - `rediss://` checks the server's certificate and name and
  completes the handshake before `AUTH`, an optional `OIDF_REDIS_CA_FILE`, `redis://` refused under the
  production profile, a URL's userinfo never quoted in a message; store verdicts are
  `FIRST_USE | REPLAY | STORE_UNAVAILABLE` and `CONSUMED | UNKNOWN | STORE_UNAVAILABLE`, an outage answered
  503 `temporarily_unavailable` and never "replay"; keys under `oidf:as:*`, `oidf:cas:*`,
  `oidf:fed:endpoint:*` and `oidf:admin:dpop:*`. The store interfaces' abstract methods are now `record` and
  `consumeChallenge`.
- **Evidence digested and bound** (S3b) - the attestation carries `workload.instance_attestation_sha256`,
  `_type` and `_exp` and never the evidence (`workload.svid` and `workload.instance_attestation` are gone);
  the digest is the SHA-256 of the evidence's JWS Signing Input, so a re-encoded token is the same evidence;
  evidence binds to the first instance key and client that present it, a second presenter is 401
  `instance_attestation_bound` and an `attestation.evidence.conflict` audit event naming both keys; evidence
  lifetime, whole and remaining, capped at a day in production, the attestation's `exp` never past the
  evidence's.
- **CIMD refused outside development** (M-1) - `OIDF_ATTESTER_CIMD_URL` is honoured only under
  `OIDF_DEPLOYMENT_PROFILE=development`; elsewhere the source is left out with an ERROR naming it, and the CAS
  document does not list `cimd` among its metadata sources.

- **RAR containment model** (S1a) - `libs/rar-model`, JDK only: per-type field rules (`set`, `set_of_values`, `limit`
  with a paired unit, `amount`, `instant_limit`, `equal`, `string`, `object`, `forbidden`), alternatives for a thing
  a type can say two ways, the built-in `sales_agent`, `payment_initiation` and `account_information` models, more
  from `OIDF_RAR_MODELS_FILE` / `OIDF_RAR_MODELS`, strict `contains`, `authorize` with inheritance, and the meet
  `intersect`, over lists held to fixed limits (numbers by the digits they would write); a SHA-256 fingerprint of
  the effective model and the library's semantics; 244 vectors in a test-jar and seeded property tests. The
  library alone: S1b and S1c, below, move the authenticator, the issuer and the plugin onto it, and with them B1
  is closed in this release.

- **S2a, S2b RAR plugin: fail-open and the principal** (blocker B3, F-0003; the "fail-open catches everything"
  high, F-0016) - fail-open is confined to a connection refused or reset, an unresolved name, a deadline, or HTTP
  429/502/503/504, so a 401 from a wrong secret, a body that is not a JSON object, a status line or header the
  client cannot parse (F-0093) and a TLS failure deny; a governance answer's `authorised` must be a boolean;
  "Deny unless PERMIT" is gone and the decision is always deny-unless-PERMIT; the shared secret is an encrypted
  field under the same name (the upgrade from v0.3.0 rehearsed on the rig); the PDP URL must be https and "Skip
  TLS verification" is inert unless `OIDF_DEPLOYMENT_PROFILE=development`; the governance-engine request writes
  the server's attributes last and refuses a field that names one, every `req_`/`att_` mirror included (F-0073);
  `principal_source` is resolved per flow from the user key PingFederate 13.1.3 passes (client credentials
  `client`, refresh and the code flow `authenticated`, CIBA `identity_hint`, token exchange `none` until the
  filter publishes a verified subject, F-0074), and `login_hint` / `_principal_sub` are development-only;
  `payment_initiation` and `account_information` are refused before any PDP call without an authenticated
  principal; the PDP request carries the attester `iss`; logs carry the principal hashed;
  `conformance/verify-rar-principal.sh` drives the flows on the rig.

- **SSF push is no longer starved by paused, disabled or poll backlogs, and no single POST holds it past
  10 s** (S10-0, the B5 stopgap) - the stores select only enabled push streams' SETs; a stream whose delivery
  fails waits out its first SET's backoff as a whole, so the SET that failed goes first and the rest follow
  by `issuedAt`, SETs of the same second by `jti` rather than in the order they were generated (F-0095); the
  POST has deadlines (connect 2 s, exchange 10 s, body read to 4 KiB) and its connection is closed at the
  deadline; the loop starts from the load-on-startup servlet; a store that is down at boot is logged, without
  its `jdbcUrl`, and retried every 30 s instead of failing `pf-runtime.war`; and the stores' push selection
  runs against Postgres in CI (`SsfStoresOnPostgresTest`). An enabled stream with 500 due SETs older than
  another's still fills the batch, and a slow receiver still holds the one thread for up to 10 s a SET, until
  S-10.
- **device-enrolment's unauthenticated `POST /compliance` is gone** (M-2, the B4 mitigation) - compliance
  reaches the registry through a verified SET at PingFederate's SSF receiver and nowhere else; the README
  says why the device path is not production-usable until Phase 6.
- **IOM schema v2 proposed** (X-A03) - docs/device/iom-schema-v2-proposal.md,
  the MAY attributes, view, roles, lease attributes and start-up check the device path needs, written as a
  diff against the model as it is, for David to raise in idp-scim-service.

- **The release waits for its Build** (P0-6, a Phase 0 leftover; F-0069) - `release.yml`'s green-Build gate
  judges the Build workflow's own run on the tagged commit: the newest run a push to `main` or a dispatch
  started, and the latest attempt of each required job in it. A pull request's Build no longer counts, and the
  job's permission `checks: read` is now `actions: read`. The gate reads the runs every 30 seconds for up to 20
  minutes while that run is queued, pending or in progress, then fails on any conclusion but success, after two
  minutes when there is no such run (Build never started on the commit), after three refused reads in a row, and
  at the limit. A `required-checks.txt` that names no job now fails it too; before 0.4.0 it passed. v0.3.0's
  release had failed on a `java` job still running and was re-run by hand.

- **Phase 1 follow-ups** (package HYG, PR #33; plan items X-D02, R-I1, P0-7, M-2, R-CI4 and R-CI5; closes F-0014 and
  F-0066, opens F-0120, F-0121 and U-0130, updates F-0006) - Build's `java` job runs `RedisLiveTest`'s plain half
  on a `redis:7-alpine` service and its TLS half on a TLS-only Redis that `tools/ci/start-tls-redis.sh` starts
  with a CA and a localhost certificate made for the run, and fails if the suite skipped a test; CodeQL does not
  analyse the iOS client's Swift yet, for the reason U-0130 records; the showcase describes the image as the
  staging profiles and the entrypoint left it and the release as its gate runs now; the device-instance,
  device-enrolment and ssf READMEs describe the code as it is.

- **The containment model wired into the token gate and the attester** (S1b, design S-1, blocker B1; PR #37) -
  the authorization server's token gate and the attester compare every `authorization_details` field with
  `libs/rar-model`, a refused request is 400 `invalid_authorization_details`, and an instance ceiling keeps what
  its client's constrains. Closes [F-0034](docs/findings.md#f-0034) and [F-0038](docs/findings.md#f-0038),
  and with S1c [F-0001](docs/findings.md#f-0001); adds [F-0100](docs/findings.md#f-0100) and
  [U-0110](docs/findings.md#u-0110).

- **The RAR plugin asks the containment model** (S1c; PR #36) - the plugin shades and relocates `libs/rar-model`
  and asks it every containment question - a request before the PDP, the PDP's answer after it (narrow, never
  widen), a refresh against its grant - and compares the attestation context's `rar_models_fingerprint` with its
  own. `RarContainment` and its contract test
  are gone. Closes F-0031 and, with S1b, F-0001 (blocker B1); closes F-0106. New in the register: F-0105, F-0106,
  F-0107, F-0108, U-0115 and U-0116.

- **The attestation PoP audience and the DPoP `htu`** (S4a, its audience and `htu` parts; the ceiling refusal
  code is S1b's; PR #34) - a Client Attestation PoP must name this server's issuer and nothing else, and a
  combined-mode DPoP proof the endpoint URL PingFederate advertises, never one rebuilt from the `Host` header.
  Closes F-0110 and F-0111.

- **Separate challenges for the authorization server and the attester** (S4b; PR #35) - the attester gets its
  own challenge endpoint, `GET /federation/attestation/challenge`, issuing into `oidf:cas:challenge:*`; the
  authorization server keeps `POST /federation/attestation-challenge` in `oidf:as:challenge:*`; a challenge from
  either is refused at the other, and each surface's metadata names only its own endpoint. Closes F-0037. New in
  the register: F-0115, F-0116, F-0117, F-0118 and U-0125.

- **Release-note fragments** (D-7, brought forward in part) - a pull request describes what it changes for a
  consumer in `docs/releases/unreleased/<ID>.md`; `tools/release-notes.py check` holds each fragment to four
  headings and a numbered "Before you deploy" of bold-titled items in the Docs workflow, and `assemble <version>`
  folds them into the release's notes and this file when it is cut. 0.4.0's notes were assembled with it.

## [0.3.0] - 2026-09-27

The first release for PingFederate 13.1.3, and the release that completes OpenID Federation. Notes:
[docs/releases/0.3.0.md](docs/releases/0.3.0.md); the move from v0.1.5:
[docs/operator/upgrading/0.1.5-to-0.3.0.md](docs/operator/upgrading/0.1.5-to-0.3.0.md).

- **PingFederate 13.1.3 and `jakarta.servlet`** - the 0.2.0 cut-over, folded in: every servlet, filter and war is
  compiled against 13.1.3 and does not load on 13.0.x; the RAR plugin reads `getJakartaRequest()` and no longer
  links on 13.0 (PR #7); `pf-13.0` is frozen at v0.1.5, with no backports; upgrades are supported from 0.3.0
  onward.
- **OpenID Federation 1.0, complete** (PR #5): trust chains checked as the Final text says, against pinned anchor
  keys; automatic registration at the token, authorization and PAR endpoints and explicit registration, every
  registration ending with its chain; the token endpoint fail-closed; Trust Marks verified, required and issued;
  every federation endpoint; a policy engine asked over AuthZEN; decisions logged as events.
- **The rig** - `conformance/up.sh` runs a configured PingFederate 13.1.3 from a clone, and the FAPI 2.0, SSF,
  CAEP, FAPI-CIBA and both OpenID Federation plans have been run against it (results in
  [conformance/README.md](demo/README.md)).
- **Shared Signals** - streams belong to the receiver that created them; SET expiry is enforced; SCIM
  provisioning takes its own scope; the transmitter emits what the CAEP Interop Profile asks.
- **Attestation** - each client bound to the attesters that may vouch for it; the bridge assertion addressed to
  the issuer alone, as a string; the bank's self-signed agents and their mission (PR #6); App Attest on macOS 27
  (PR #9).
- **Release hygiene** - one PingFederate version in `build/pf-version.env` with the image pinned by digest, one
  project version across the reactor with gm-api in the lockstep, and a release workflow that publishes the
  build it verified, with a dry run (PR #10); the docs describe 13.1.3 (PR #8).

## 0.2.0 - 2026-09-24, never tagged

The modules moved to `jakarta.servlet` and PingFederate 13.1.3 became the base (commit `12626ec`). It was the
working version of `main` until 0.3.0 and was never released; everything it held is in 0.3.0. Plan and evidence:
docs/pf-13_1-jakarta-migration-plan.md.

## [v0.1.5] - 2026-09-24

The last `javax.servlet` release, for PingFederate 13.0.x, on the `pf-13.0` branch: everything up to and
including the FAPI-CIBA rig, built on 13.0.3. Supersedes v0.1.4, which was cut before the CAEP Interop and CIBA
work. A 13.0.x consumer pins here; the branch is frozen from 2026-09-26.

## [v0.1.4] - 2026-09-23

The last release built against `javax.servlet` when it was cut, with the assemble script refusing a war whose
staged jars are compiled against the wrong servlet namespace, the FAPI 2.0 profile filter and the SSF
transmitter conformance work, and SSF stream ownership. `PROVENANCE.txt` began stating which PingFederate line
a build targets.

## [v0.1.3] - 2026-08-30

The agent attestation profile with executable conformance, the coverage pass, and the dormant-defect fixes.

## [v0.1.2] - 2026-08-22

Per-client bridge signing, verified-context claims, and no bundled attester trust - the released artefact stopped
being the vulnerable one.

## [v0.1.1] - 2026-08-22

The first complete published build: the PF module set, wars and plugin jars, with `SHA256SUMS` and
`PROVENANCE.txt` recording the commit, so a consumer can pin a build and tell when it is behind. Carries the
Tier 0/1/2 security work. Supersedes v0.1.0.

## [v0.1.0] - 2026-08-22

The release workflow, so a consumer could tell when it was behind. It published its Maven artefacts and then
failed before creating a release; nothing consumed it.

[0.6.1]: https://github.com/ID-Partners/pf-agentic-identity/releases/tag/v0.6.1
[0.6.0]: https://github.com/ID-Partners/pf-agentic-identity/releases/tag/v0.6.0
[0.5.0]: https://github.com/ID-Partners/pf-agentic-identity/releases/tag/v0.5.0
[0.4.0]: https://github.com/ID-Partners/pf-agentic-identity/releases/tag/v0.4.0
[0.3.0]: https://github.com/ID-Partners/pf-agentic-identity/releases/tag/v0.3.0
