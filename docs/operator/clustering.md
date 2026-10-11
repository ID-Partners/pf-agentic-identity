# Clustering

How a node built from this repository tells whether it is one of a PingFederate cluster, what a clustered node needs
under the production profile, and what a console node does not run. From 0.7.0 (plan item C-1). [The reference
cluster](#the-reference-cluster) (C-6) runs the modules on a console and two engines; the cluster verification suite
(C-7) runs its scenarios on it, and [On the reference cluster](#on-the-reference-cluster) has its dated results;
[deployment-limits.md](deployment-limits.md) says which cluster shape is supported and what is not.

## Which topology a node has

Every copy of the modules reads one topology, from two process-wide sources, so the webapp's copy and the engine's
copy (where the OGNL criteria run) agree without either telling the other:

| Source | Read | Notes |
|---|---|---|
| `OIDF_CLUSTER_MODE` (environment) | First. One of `STANDALONE`, `CLUSTERED_ENGINE`, `CLUSTERED_CONSOLE`, `CLUSTERED_DUAL`, in any case | This repository's setting ([cluster-topology](../configuration/cluster-topology.md)). Set, it wins. |
| `pf.operational.mode` (JVM system property) | When `OIDF_CLUSTER_MODE` is unset | PingFederate's own: `run.properties` says it, and PingFederate's start-up makes every `run.properties` entry a system property of its JVM. The image's `OPERATIONAL_MODE` writes it. |

The rules:

- `OIDF_CLUSTER_MODE` set and `pf.operational.mode` naming another of the four modes is a **mismatch**: the
  topology is unknown.
- Neither set, either blank, or a value that is none of the four names is **unknown**. PingFederate itself treats
  anything but the three clustered names as standalone (its internal `ModeSupport`, read with javap on 13.1.3 on
  2026-10-06); the modules are stricter on purpose, because a node that cannot say it is alone must not keep shared
  state in its own memory.
- The SDK's `ClusterAccessor` has no mode - only `getNodeIndex()` and `getNodeTags()` - so it gives the node index
  alone, which the banner and `/agentic-identity/info` show.

Under the production profile an unknown topology refuses **every component**: each answers 503, ready is 503, and
PingFederate's own endpoints keep serving. Under development it is a WARN. Set `OIDF_CLUSTER_MODE` on every node to say
what it is; on a standalone PingFederate whose `run.properties` says `STANDALONE`, nothing needs setting.

## What a clustered production node needs

`CLUSTERED_ENGINE`, `CLUSTERED_CONSOLE` and `CLUSTERED_DUAL` are clustered. The lifecycle listener decides once, as
each war starts and before any servlet or filter starts, and a refusal names what to change. Under development each is
a WARN.

| Requirement | Without it | Why |
|---|---|---|
| **Redis** (`OIDF_REDIS_URL`) and **PingFederate data stores** for every store with an in-memory fallback | The component that would keep the state in memory is refused, **even with `in-memory-state` in `OIDF_ACCEPTED_RISKS`**: the attestation challenges, spent proofs and evidence bindings (ATTESTATION_AUTH, ATTESTATION_ISSUER), the federation endpoints' spent client assertions when endpoint authentication is on (FEDERATION), automatic registration's spent request objects (AUTO_REGISTRATION), the SSF store (SSF), the hosted-entity registry, Trust Marks and key history (HOSTING, FEDERATION), the agent registry (ATTESTATION_ISSUER). The admin API's Trust Mark routes answer 503 while the rest of it serves, and the operator APIs' DPoP proofs without Redis leave the operator authenticator unusable, with that as its problem | A second node does not see the first node's memory, so a spent proof or a redeemed challenge passes there |
| **JDBC OAuth client storage** in PingFederate (`ClientManager.isBackendDatabase()` true) | FEDERATION and AUTO_REGISTRATION are refused - the components that write clients | A client one engine writes to its own configuration files is not seen by the others until the configuration is replicated |
| **A cluster lease backend**: `OIDF_LEASE_BACKEND=jdbc` (or `redis` with `redis-lease` accepted) | SSF_RECEIVER and AUTO_REGISTRATION are refused - the owners of the SSF poll loop and the registration expiry sweeper | Each of those must run on one node of the cluster at a time ([Leases](#leases)) |
| **The SSF `tables` dialect** (`OIDF_SSF_STORE_DIALECT=tables`, the default, with migrations V303-V305 and V307-V310) | SSF is refused on a clustered node whose SSF store is `ldm` (single-node in 0.7.0) or in memory, and SSF_RECEIVER with it | Each push stream is leased to one node in the SSF database ([SSF push streams](#ssf-push-streams)), the receiver's inbox is shared there ([SSF receiver](#ssf-receiver)), and so are the emission outbox, the logout replay keys and the sign-offs waiting for confirmation ([SSF emission](#ssf-emission)); the `ldm` and in-memory stores keep them in each node's memory, so every node would deliver every stream and act on every SET it was sent |

The OGNL criterion runs in the engine's copy, which no start function reaches: it asks the same in-memory rule each
time it would use its stores, and denies the token when the rule says no.

On a standalone node the production profile allows in-memory state only with `in-memory-state` accepted, as it has
since 0.6.0.

## Leases

From 0.7.0 (plan item C-4) a job that must run on one node of a cluster at a time runs on the node that holds its
**lease**: the registration expiry sweeper (lease `registration-sweeper`), the SSF poll receiver
(`ssf-poll-receiver`), the federation key observer (`federation-key-observer`, S6b: it records the signing keys
PingFederate publishes and moves the cluster's active key - [operations.md](../federation/operations.md#changing-pingfederates-signing-key))
and the subordinate monitor (`federation-subordinate-monitor`, S7b: it watches the pinned subordinates and applies a
held rollover - [operations.md](../federation/operations.md#subordinate-monitor-and-change-control); a clustered node
whose leases are local runs it nowhere).
Every node that runs jobs ticks; the one that holds the lease runs the job.

| `OIDF_LEASE_BACKEND` | Where the lease is | A clustered production node |
|---|---|---|
| unset, `local` | this node's memory | refused: it elects nothing across nodes, so every node would run the job |
| `jdbc` | the `oidf_lease` table (migration V10, platform family), on `OIDF_LEASE_DATA_STORE_ID`'s PingFederate data store; `OIDF_LEASE_JDBC_URL` for development | the backend to use |
| `redis` | `oidf:lease:<name>` in `OIDF_REDIS_URL`'s Redis, with a fence counter `oidf:lease:fence:<name>` | only with `redis-lease` in `OIDF_ACCEPTED_RISKS` (below) |

The settings are on [platform-lease](../configuration/platform-lease.md). The banner's topology line and
`/agentic-identity/info` say which backend the node registered (`lease backend jdbc`); a refused backend registers
none, and its reason is a refusal in code. `jdbc` with neither `OIDF_LEASE_DATA_STORE_ID` nor `OIDF_LEASE_JDBC_URL`
is refused under every profile.

**Clocks.** A lease expires on the backend's clock only. The `jdbc` backend takes, renews and releases a lease in one
auto-commit statement each, against PostgreSQL's `now()`, which is "a traditional PostgreSQL equivalent to
transaction_timestamp()", the "start time of the current transaction" (PostgreSQL documentation,
`functions-datetime.html`, read 2026-10-06). Its take is one `INSERT ... ON CONFLICT DO UPDATE`, which "guarantees an
atomic INSERT or UPDATE outcome; provided there is no independent error, one of those two outcomes is guaranteed, even
under high concurrency" (`sql-insert.html`, read 2026-10-06). The `redis` backend's lease is a `PX` TTL set in one Lua
script: "Redis guarantees the script's atomic execution" (`eval-intro`, read 2026-10-06). A node compares no wall
clocks: it acts on a lease until the monotonic instant taken before it sent the request, plus the TTL, less a tenth
of the TTL - before the backend's expiry, since the backend started its TTL after the request left. A node whose
clock is an hour out elects as any other (`JdbcLeaseManagerTest.aNodeClockSkewedByAnHourChangesNothing`).

**Fencing.** Each lease carries a token that rises whenever a new holder takes it, or any holder takes it after it
expired, and never on a renewal or a release; a holder that takes its own unexpired lease again (a retried request)
keeps its token, and a write fenced on a `Held` the node has already declared lost is refused before it is sent; the `jdbc` row is kept at release, and the Redis fence counter has no TTL, so a token is never given twice.
A write to the leases' own database can be fenced on it: `JdbcLeases.requireHeld` reads the row `FOR SHARE` by name,
holder and token while `expires_at > clock_timestamp()`, inside the write's transaction, so the write commits before
the lease changes hands or is refused. The key observer writes that way when its leases are in the authority's database
(`OIDF_LEASE_DATA_STORE_ID` or `OIDF_LEASE_JDBC_URL` naming what `OIDF_AUTHORITY_DATA_STORE_ID` or
`OIDF_AUTHORITY_JDBC_URL` names); otherwise it checks `Held.stillHeld()` just before each write and says so at start-up
(F-0525). SSF push delivery fences its writes this way too, on its own lease table in the SSF
database ([SSF push streams](#ssf-push-streams)). The sweeper's
writes (disabling a client in PingFederate) and the poll receiver's (acknowledgements to the transmitter) are outside
that database: they are fenced only as far as the node's own judgement reaches - before each disable the sweeper
renews the lease when it is due and stops its pass when it has lost it, and the poll is cut off at what is left of the
lease. The poll receiver's acknowledgements need no fence: what is to be acknowledged is kept in the receiver's inbox
in the SSF database, not in the node, so the next holder sends what the last one admitted and had not yet
acknowledged, and a node that sent acknowledgements and died before marking them sends them again, which RFC 8936
§2.4 allows ([SSF receiver](#ssf-receiver)).

**What Redis cannot promise.** "Redis uses by default asynchronous replication", and "acknowledged writes can still be
lost during a failover" (`replication`, read 2026-10-06). A failover can lose a lease and its fence counter, so two
nodes may run a job at once and a token may repeat. That is why a clustered production node takes `redis` only with
`redis-lease` accepted ([F-0515](../findings.md#f-0515)).

**Failover time.** A lease lasts `OIDF_LEASE_TTL_SECONDS` (default 30, 5 to 300) without a renewal. Its holder ticks
every third of it (or every job interval, if shorter), renews when two thirds or less are left, and stops acting a
tenth before it expires. A node that dies holding a lease leaves its job without a runner for at most the TTL and one
tick - 40 s at the default; a node that stops cleanly gives the lease back at once. On the reference cluster
(C-7, 2026-10-08) the other engine held `ssf-stream-sweeper`, token plus one, 31.5 s after its holder was killed. A backend that cannot answer is
"not leader": the job stops on that node, with one ERROR when the backend stops answering and one INFO when it
answers again.

**What it reports.** Metrics by lease: `oidf_lease_held` (1 while this node holds it), `oidf_lease_acquired_total`,
`oidf_lease_lost_total`; events `platform.lease.acquired` and `platform.lease.lost` (operational: lease, holder,
token, backend). A holder id is `n<node index>-<32 hex>`, drawn once per copy of the modules.

**Upgrading a cluster.** Apply V10 (`oidf-db-migrate.jar migrate`, then `grants` again for the runtime role) to the
database `OIDF_LEASE_DATA_STORE_ID` names, and set `OIDF_LEASE_BACKEND=jdbc` on every node, before the nodes start
0.7.0. Without them a clustered production node refuses SSF_RECEIVER and AUTO_REGISTRATION, as it did before.

### SSF push streams

From 0.7.0 (plan item S10a) SSF push delivery is not one job with one leader: every node runs the push engine, and it
takes **streams by lease, one per worker** (plan item S10b): each node's dispatcher claims as many streams as it has
free workers (`OIDF_SSF_PUSH_WORKERS`, 4, 1-32), so a cluster has at most workers x nodes POSTs in flight - 8 on two
nodes at the default - and never two for one stream. The leases are rows of `ssf_stream_lease` (SSF migration V303) in the SSF
database - not `oidf_lease`, since a write is fenced only in the database that holds its lease, and
`OIDF_LEASE_DATA_STORE_ID` may name another database than `OIDF_SSF_DATA_STORE_ID`. So SSF needs no lease backend
setting; it needs the `tables` dialect, with V303-V306 applied.

- **One deliverer per stream.** A claim is one statement that locks the due rows `FOR UPDATE SKIP LOCKED` and gives
  each this node's holder id, its `epoch` plus one and `expires_at = now() + OIDF_SSF_STREAM_LEASE_SECONDS` (30 s,
  15-300). A row another node holds, or is claiming, is skipped, not waited for: PostgreSQL 16's `SELECT` (read
  2026-10-07), "With SKIP LOCKED, any selected rows that cannot be immediately locked are skipped", which "can be used
  to avoid lock contention with multiple consumers accessing a queue-like table". Poll streams have no row.
- **Fenced writes.** The ack, the dead SET's move (V306), the failed attempt and the pause each read the row by holder and epoch,
  unexpired on `clock_timestamp()`, `FOR SHARE`, as the first statement of their transaction: the write commits
  before the stream can be claimed again, or writes nothing.
- **A POST ends inside the lease.** The node renews when two thirds or less of the TTL are left, stops acting a tenth
  before `expires_at`, and starts no POST with 10 s (the POST's deadline) or less left. Another node claims only
  after `expires_at`, on the database's clock, so no two nodes start a POST for one stream within each other's lease.
  A JVM paused past its deadline, or a socket write stalled after it, can still put a SET on the wire late; its ack
  is then fenced out, but the next holder may have posted later SETs by the time it lands, so the receiver can see it
  out of order as well as twice, and deduplicates by `jti`.
- **Failover.** A node that dies holding a stream leaves it undelivered for at least the lease TTL (30 s by default),
  then until a surviving node's dispatcher next claims: one tick (`OIDF_SSF_PUSH_RETRY_BACKOFF_SECONDS`, 5 s) while it
  has a free worker, and while all its workers are busy until one hands its stream back - a batch is at most
  `OIDF_SSF_PUSH_BATCH_SIZE` (50) POSTs of up to 10 s each, and a full batch wakes the dispatcher at once. A node that stops cleanly hands its stream back
  at once. The next holder posts the stream's first SET again, so a SET whose POST succeeded but whose ack was
  never written is sent twice. On the reference cluster (C-7, 2026-10-08) an engine killed half way through 1,000
  events on three streams lost nothing and repeated nothing: the survivor delivered the rest, every SET once and in
  order. RFC 8935 §2 allows a repeat: "The SET Transmitter MAY transmit the same SET to the SET
  Recipient multiple times, regardless of the response from the SET Recipient." A receiver deduplicates by `jti`.
- **Fairness.** A stream is released after its SETs that are due, its first retry or pause, or a batch of
  `OIDF_SSF_PUSH_BATCH_SIZE` (50), and the claim takes the least recently released stream first, so one stream's
  backlog does not starve the others. A stream that fails waits out its backoff whole (full jitter, capped at
  `OIDF_SSF_PUSH_RETRY_BACKOFF_MAX_SECONDS`, raised by a receiver's `Retry-After`), and holds no worker meanwhile.
- **Not on `ldm`.** The `ldm` dialect is single-node in 0.7.0 (S10f deferred): its stream leases are in each node's
  memory, so a clustered production node refuses SSF on it, naming `OIDF_SSF_STORE_DIALECT=tables`. An in-memory SSF
  store is refused on a clustered node already.

What it reports: `oidf_ssf_stream_lease_claimed_total`, `oidf_ssf_stream_lease_lost_total` and the event
`ssf.push.stream_lease_lost` (operational; the reason is the step - renew, ack, attempt, dead (a dead SET's move) or
pause - and the field the epoch); and the push engine's `oidf_ssf_push_attempts_total{outcome}`, `oidf_ssf_dead_sets_total{source}` and events
`ssf.push.delivered_nonstandard`, `ssf.push.set_dead`, `ssf.push.stream_paused` and `ssf.push.retry_after_clamped`.
`StreamLeasesOnPostgresTest` runs two nodes on one database with sixteen threads, and a node whose POST stalls past
its lease; `PushEngineOnPostgresTest` runs two nodes of four workers each against twelve scripted receivers and a
120-SET stream (no more than eight in flight, every SET once and in order, batches of at most 50).

- **Status changes compare and set** (plan item S10c, V308). A stream's row carries `row_version`, and every status or
  configuration write - a receiver's PATCH, PUT or status change, an operator's pause or resume, the deliverer's pause,
  the inactivity sweep - is an `UPDATE ... WHERE row_version = <the version it read>`, so writes on two nodes cannot overwrite one another;
  one that loses reads again, at most three times, then answers 503 with `Retry-After: 1`. A status change, its
  stream-updated SET at the head of the queue and a disable's purge are one transaction. The activity stamp (`last_activity_at`) and `last_verification_at` are written
  without a version, by design: they change no configuration. A push stream's run of
  failures is `ssf_stream_lease.failing_since` on the database's clock, so it is paused after
  `OIDF_SSF_PUSH_PAUSE_AFTER_SECONDS` (24 h) whichever nodes made the attempts. The inactivity sweep is the leader job
  `ssf-stream-sweeper`, one node a minute, and two sweeps that overlap at a failover pause a stream once.
  `StreamHoldOnPostgresTest` runs two nodes on one database: sixteen threads mixing the writes lose none.

**Upgrading a cluster.** Apply the SSF family's V303-V308 (`oidf-db-migrate.jar migrate`, then `grants`
again: V304 adds a sequence the runtime role needs `USAGE` on, and V306 the table `ssf_dead_sets`, V307 the receiver inbox; V308 adds columns
only) before any node starts 0.7.0: a node that reads a stream without V308's columns fails.

### SSF receiver

From 0.7.0 (plan item S10e, [F-0043](../findings.md#f-0043)) the SSF receiver keeps what it receives in an
**inbox** in the SSF database: `ssf_receiver_inbox` (SSF migration V307), one row per SET keyed by its issuer and
`jti`. Before, each node kept a window of the last 10,000 `jti`s in memory, ran the handlers before it answered, and
kept the poll's pending acknowledgements in fields, so a cluster acted twice on a SET pushed to two nodes and lost an
acknowledgement with a node.

- **202 after commit.** A pushed SET is verified and admitted - `INSERT ... ON CONFLICT (iss, jti) DO NOTHING` - and
  only then answered with an empty 202; a SET admitted before, on this node or another, is a duplicate and is answered
  the same way. RFC 8935 §2 (read 2026-10-07): "Once the SET has been validated and persisted, the SET Recipient
  SHOULD immediately return a response indicating that the SET was successfully delivered. The SET Recipient SHOULD
  NOT perform further processing of the SET beyond the required validation steps prior to sending this response."
  An inbox that cannot be written is a 503 with `Retry-After: 30`, never a 202, so the transmitter delivers again.
- **(iss, jti).** RFC 7519 §4.1.7: "collisions MUST be prevented among values produced by different issuers as well",
  and "The "jti" value is a case-sensitive string": the key is both, compared bytewise (`COLLATE "C"`).
- **Action workers.** Every node runs `ssf-receiver-actions` (no lease): every 5 s, and at once after an admit, it
  claims due SETs with `FOR UPDATE SKIP LOCKED` for 60 s, rebuilds each from the stored, verified SET (not verified
  again: the transmitter's keys may have rotated), and runs each handler that has not yet succeeded for it. A
  handler that succeeded is recorded and never runs for that SET again; a failure is tried again after 5 s, doubling
  to 300 s, and after `OIDF_SSF_RECEIVER_ACTION_ATTEMPTS` (10, 1-50) failures the SET is **dead**: an ERROR, the
  event `ssf.receiver.action_dead` and `oidf_ssf_receiver_action_dead_total`. A node that dies holding a claim leaves
  its SETs to another worker after 60 s, so a handler can run twice. The instance
  registry's handler changes nothing the second time (suspending a suspended instance), but the grants handler is
  not idempotent: run again, it revokes every grant the user was issued since the first run - a user who signed in
  again in between loses the new grant.
- **Poll acknowledgements.** A polled SET is admitted with `ack_due`; whichever node holds `ssf-poll-receiver` sends
  `ack` and `setErrs` from the inbox and marks exactly those after the transmitter's 200. RFC 8936 §2: "Once a SET is
  acknowledged, the SET Recipient SHALL be responsible for retention, if needed" - so nothing is acknowledged before
  it is stored.
- **Order.** SETs are acted on oldest first by `received_at`, not by CAEP's `event_timestamp`; a retried SET can land
  after a newer one about the same subject ([F-0551](../findings.md#f-0551)).
- **Retention.** A finished SET's stored SET is dropped at once; its key is kept for
  `OIDF_SSF_RECEIVER_INBOX_RETENTION_SECONDS` (7 days, 1 hour to 30 days) to recognise a redelivery, then purged.
- **Not on `ldm` or in memory.** Their inbox is each node's memory ([F-0550](../findings.md#f-0550)): a clustered
  production node refuses SSF on those stores already, and SSF_RECEIVER with an inbox that is not shared.

What it reports: `oidf_ssf_receiver_inbox_pending`, `oidf_ssf_receiver_inbox_oldest_pending_seconds` (as the node's
worker last counted them), `oidf_ssf_receiver_action_dead_total`, and the events `ssf.receiver.action_retry` and
`ssf.receiver.action_dead`. `ReceiverInboxOnPostgresTest` runs two nodes on one database: one SET pushed to both at
once sixteen times, a node that dies between commit and action, and a poll lease that moves before its
acknowledgements are sent.

**Upgrading.** Apply V307 (`oidf-db-migrate.jar migrate`, then `grants` again) before any node starts this version.
The first boot starts with an empty inbox: a SET delivered before the upgrade and delivered again after it is acted on
again. A rerun of the grants handler revokes any grant the user was issued since the first run, so a session-revoked
replayed after the user signed in again ends the new session too. The same happens when a node dies mid-action (its
60 s claim passes to another worker) and when a transmitter delivers a SET again after
`OIDF_SSF_RECEIVER_INBOX_RETENTION_SECONDS`.

### SSF emission

From 0.7.0 (plan item S10d, [F-0017](../findings.md#f-0017)) an event the transmitter raises is one row of the
**emission outbox** in the SSF database (`ssf_emission_outbox`, SSF migration V309), and it is fanned out - a SET minted
and queued for every stream that hears it - by whichever node's worker takes the row first. Before, the node that saw
the event did it all on PingFederate's thread, one statement per stream: a crash part way left some streams without the
SET, and a store error dropped the event.

- **Fan-out on any node.** Every node runs `OIDF_SSF_OUTBOX_WORKERS` (2) workers, `ssf-outbox-fanout-<n>` (no lease):
  every second each takes the oldest due row whose subject has no older row (`FOR UPDATE SKIP LOCKED`), and the streams,
  the SETs, their insert and the row's delete are one transaction. A node that dies mid fan-out rolls back and the row
  is taken again; a second fan-out of a row to a stream inserts nothing. A row raised on one node is fanned out by any.
- **Order per subject.** A row waits while an older row about its subject is there, on any node - held or backing off -
  so one subject's SETs are queued in the order its events were written. Two nodes raising events about one subject in
  the same instant are ordered by when each wrote its row.
- **Sources only enqueue.** The audit appender, the logout filter and the hooks hand the event to a bounded hand-off in
  the node's memory (`OIDF_SSF_EMISSION_QUEUE_CAPACITY`, 10000) and return; `ssf-outbox-writer` writes it to the
  outbox. A store that is down holds the hand-off until it answers (`ssf.outbox.write_failed`, once per run); what is
  still in the hand-off when a node stops is lost.
- **The bridge's 5 s window stays per node.** Two observers of one PingFederate event - the logout filter and the audit
  record of the same logout - are suppressed within 5 s on the node that saw both; on two nodes each raises its own.
- **Logout replay shared.** A logout's id_token_hint raises one session-revoked per session and `iat` within its bound
  on every node: the key is written to `ssf_logout_replay` in the event's own transaction ([F-0402](../findings.md#f-0402)).
- **Not on `ldm` or in memory.** Their outbox and replay keys are each node's memory ([F-0560](../findings.md#f-0560));
  a clustered production node refuses SSF on those stores already.

What it reports: `oidf_ssf_outbox_appended_total`, `oidf_ssf_outbox_fanned_out_total{outcome}` (`fanned_out`, `retry`,
`dropped`, `expired`), and the events `ssf.set.dropped` (`queue_full`, `fanout_failed`, `expired`) and
`ssf.outbox.write_failed`. `EmissionOutboxOnPostgresTest` runs two nodes on one database: 2,000 events from sixteen
threads to six streams with four workers per node (one SET per event per stream, each subject in order, no row left), a
node that appends and never fans out, a worker that fails mid fan-out, `emitNow` racing the other node's workers, one
hint at both nodes, and a store that stops.

**Upgrading.** Apply V309 (`oidf-db-migrate.jar migrate`, then `grants` again: it adds `ssf_emission_outbox`, its id
sequence and `ssf_logout_replay`) before any node starts this version.

**Sign-offs waiting for confirmation** (F-0401, SSF migration V310). A logout's session-revoked is raised when the user
confirms PingFederate's sign-off, which is a later request that a load balancer may send to another engine. The logout
filter records the pending sign-off in `ssf_logout_pending`, keyed by the SHA-256 of PingFederate's `RequestStateRef`,
and the confirmation filter on whichever engine takes the confirmation moves it to the resume reference and takes it,
in one `DELETE ... RETURNING`, so two confirmations raise one signal (`LogoutPendingsOnPostgresTest`: two stores on one
database, and ten double submits). Apply V310 and run `grants` again before any node starts this version.

**Long polls stay per node.** An RFC 8936 long poll is held by the node that took the request, in memory
(`oidf-ssf-long-poll-1`, at most 256 at once), and answered when that node's 250 ms tick reads a SET for the stream
in the shared store - queued on any node. Nothing about a held poll is shared: a node that stops answers nothing, and
the receiver polls again. A proxy or receiver timeout shorter than `OIDF_SSF_POLL_LONG_POLL_WAIT_SECONDS` cuts a held
poll off; set both above it.

### Jobs that stay per node

These run on every node that runs jobs, each for its own node, and need no lease: the subordinate statement refresh
(one per federation service instance, `subordinate-refresh-<8 hex>`, since each warms its own cache - F-0202),
the attestation policy scan, the bridge signer check, the issuance client resolver's refresh and the SSF long-poll
tick, the federation key monitor (`federation-key-monitor`), which installs the cluster's active key on its node, and
the SSF receiver's action worker (`ssf-receiver-actions`), whose claims share the work ([SSF receiver](#ssf-receiver)),
and the SSF emission outbox's writer and fan-out workers (`ssf-outbox-writer`, `ssf-outbox-fanout-<n>`), whose row locks
share it ([SSF emission](#ssf-emission)).

### Caches that stay per node

Each node keeps each client's attestation policy for 30 s (pf-integration README, "Each client's attestation
policy"). A registration, auto-registration or expiry written through this project applies at once on the node that
wrote it, in the filter's and the engine criterion's copies alike (F-0300), and up to 30 s later on every other node:
nothing tells them. An administrator's edit in PingFederate's console takes up to 30 s on every node.

## Console nodes

A `CLUSTERED_CONSOLE` node serves PingFederate's administration, not runtime traffic. On it, the modules' managed
executors start no background job (`ManagedExecutors.every` and `after` return nothing, with one INFO line per job:
`Job <name> not started: this node is CLUSTERED_CONSOLE (from ...), and a console node runs no background jobs`). The
The federation key monitor is one of those jobs, so a console node keeps the federation key view it read at start-up;
nothing on a console node should sign with the federation keys. The
image's healthcheck does not ask a console node for the modules' health
([build/pingfederate/pf-healthcheck.sh](../../image/pf-healthcheck.sh)).

## What a node reports

- The start-up audit's `topology` line: the mode, where it was read, the node index, where PingFederate keeps OAuth
  clients and the lease backend - `STANDALONE (from pf.operational.mode, node index 1792761714); OAuth clients in files;
  lease backend none` ([startup-audit.md](startup-audit.md)).
- `/agentic-identity/info`: the same under `topology` - `mode`, `source`, `node_index`, `problem`, `client_storage`,
  `lease_backend` ([health.md](health.md)).
- The event `platform.topology.resolved`, once per webapp start: success, or failure `unknown`.
- Each refusal is a refusal in code: listed in the banner, logged at ERROR once, and a `platform.profile.refused`
  event.

## The reference cluster

[`reference/cluster`](../../demo/reference/cluster/README.md) (from 0.7.0, plan item C-6) is a docker compose stack that
puts the requirements above together on one machine: a `CLUSTERED_CONSOLE` and two `CLUSTERED_ENGINE` nodes on the
production profile behind HAProxy (TCP passthrough), PostgreSQL 17 over TLS with the migrator, runtime and
client-storage roles, Redis 7 over TLS with an ACL user, and OpenBao handing each node its secrets. It is an example
to read and adapt, and where C-7's suite and the licensed CI jobs run; [reference/README.md](../../demo/reference/README.md)
lists the parts that are example-only. What it shows about PingFederate 13.1.3, each seen on 2026-10-08:

- **Client storage.** `service-points.conf` is not replicated, so each node mounts a copy of the image's with
  `client.manager=org.sourceid.oauth20.domain.ClientManagerJdbcImpl` - the stock file has CRLF line endings, and only
  that line changes. The tables come from PingFederate's own
  `server/default/conf/oauth-client-management/sql-scripts/oauth-client-management-postgresql.sql`, and the data
  store from the configuration store's `PingFederateDSJNDIName` (bundle `org.sourceid.oauth20.domain.ClientManagerJdbcImpl`).
  A client made on a PingFederate whose own `service-points.conf` keeps XML storage goes to its files, even with that
  binding: an archive authored that way carried the smoke client in its files, and both engines answered
  `invalid_client` until it was registered through the console's admin API.
  **The windows** (C-7, 2026-10-08, 20 trials, an engine asked every 100 ms): a client registered through the
  console's admin API took a token from the other engine within 28 ms at the median, 101 ms at p95 and 724 ms at
  most - an engine reads a client it has not cached from the database. A client disabled the same way kept taking
  tokens there for 60.0 s at the median and 60.4 s at most: an engine serves a client it has cached for about a
  minute after the change, so plan on a disable, a secret change or a deletion reaching every engine a minute later
  ([U-0027](../findings.md#u-0027)). A console replication afterwards did not bring a disabled client back.
- **Replication.** The image's hook replicates only after a bulk import, so a console booting from a drop-in archive
  must be asked (`POST /pf-admin-api/v1/cluster/replicate`). An engine with no archive takes the console's
  configuration without the console's master key: it makes its own at boot, and the replicated data store
  passwords worked.
- **Cluster settings.** PingFederate 13.1's environment form `PF_RUN_<property>` sets `pf.cluster.auth.pwd` and
  `pf.cluster.encrypt` (both read back from the running JVM); the image's `DNS_PING` discovery works over a compose
  network alias the three nodes share.
- **Trust.** PingFederate sets `javax.net.ssl.trustStore` to its own trusted-CA store, so a CA the modules' outbound
  calls must trust goes into PingFederate's trusted CAs, not `JAVA_OPTS` - and until
  [F-0585](../findings.md#f-0585) is fixed, the modules see a CA added there only after the node restarts. A
  new engine gets the CA with its first replication, after it started, so `up.sh` restarts each engine once after
  it; C-7 saw an engine's SSF introspection at the issuer fail PKIX until it did (2026-10-08).
- **A replaced engine.** HAProxy follows the engines by name through Docker's DNS (`resolvers docker`): a container
  recreated in a rolling upgrade comes back on a new address, and with the name resolved once at start both servers
  stayed DOWN on the old addresses ([F-0603](../findings.md#f-0603), found by C-7 on 2026-10-08).

## Verified

On the rig, PingFederate 13.1.3.0 on Java 21, 2026-10-06, this branch's modules (U-0026):

- **Standalone** (the image's `run.properties`, `pf.operational.mode=STANDALONE`): `jcmd <pid> VM.system_properties`
  lists `pf.operational.mode=STANDALONE`, and the webapp read it - the banner said `STANDALONE (from
  pf.operational.mode, node index 1792761714); OAuth clients in files; lease backend none`, with no code refusals.
  `ClusterAccessor.getNodeIndex()` answered a large number on a standalone node, not 0 or -1, and
  `PfInternals.isBackendDatabase()` linked and answered `false` on the image's XML client storage.
- **Console**: see the dated note under [U-0026](../findings.md#u-0026).
- **Leases** (package LEASE, 2026-10-06, rig `pf-p4-lease` with the federation profile, development): unset, the
  banner said `lease backend local` and the log `Lease registration-sweeper acquired by n781248606-... with token 1
  (local)`. With `OIDF_LEASE_BACKEND=jdbc`, `OIDF_LEASE_JDBC_URL` to a throwaway PostgreSQL 16 with V10 applied and
  `OIDF_LEASE_TTL_SECONDS=15`: `lease backend jdbc`, the sweeper's lease acquired with token 1 (`jdbc`), the row's
  `expires_at` moved on by the renewals, and `docker stop` gave it back - `expires_at` set to the moment of the stop.
  A clustered production node with the jdbc backend on a PingFederate data store has not been run: that is C-6 and
  C-7's.
- **The reference cluster** (package REF, 2026-10-08, slot 31): every node's banner said its mode `from
  OIDF_CLUSTER_MODE`, `OAuth clients in database; lease backend jdbc`, with no code refusal; each engine's leases were
  acquired on the PingFederate data store (`Lease ssf-stream-sweeper acquired ... with token 1 (jdbc)`), and a token
  was issued through HAProxy and by each engine ([reference/cluster/README.md](../../demo/reference/cluster/README.md#verified)).
  The scenarios - failover, windows, SSF delivery across engines - are C-7's, [below](#on-the-reference-cluster).

### On the reference cluster

The cluster verification suite (plan item C-7, services/cluster-suite) on
[reference/cluster](../../demo/reference/cluster/README.md): a console and two engines behind HAProxy, PostgreSQL 17,
Redis 7 and OpenBao, PingFederate 13.1.3.0, on this Mac (Docker Desktop 29.4, 12 CPUs, 19 GiB for Docker), slot 37,
branch `prod/p4-cluster-verify`. Run 1 at `1f5b8247` booted from nothing (its smoke check passed at 15:49Z on 2026-10-08) and ran
every scenario; run 2 at `547667fb` booted from nothing again (smoke at 16:48Z) and ran the topology and fault scenarios with the fault
recovery timed on the load rather than on ready (run 1 had timed it on ready, which PostgreSQL's loss does not
change, and called a recovered outage a failure); run 3 at `547667fb` booted on an earlier commit's image
(`SUITE_ROLL_FROM_PREV=1`, smoke at 17:11Z) and rolled it to HEAD's; run 4 did the same at `70b4cac2`, this branch
merged with origin/main. The whole stack peaked at 2.31 GiB of memory and 4.9 CPUs under the
suite's load (`docker stats` every 10 s).

| Scenario | When (UTC, 2026-10-08) | What was measured | Result |
|---|---|---|---|
| Topology | 15:51 | every node's start-up audit: its mode from `OIDF_CLUSTER_MODE`, `OAuth clients in database`, `lease backend jdbc`, no code refusal; `cluster/status` one console and two engines, no replication required | pass |
| Client storage (U-0027) | 15:51-16:13 | 20 trials through the console, engine-2 asked every 100 ms: registration window p50 28 ms, p95 101 ms, max 724 ms; disable window p50 59,984 ms, p95 60,308 ms, max 60,424 ms; after a replication no disabled client took a token in 60 s | pass |
| Leases | 16:13-16:19 | 143 samples over 5 min: `ssf-stream-sweeper` one unexpired row, held by an engine, its token unchanged; holder (engine-1) killed: engine-2 held it with token 4 -> 5 after 31,534 ms (bound: TTL 30 s + a tick + 2 s = 42 s); engine-1 ready again 26 s after its start | pass |
| SSF push, steady | 16:19-16:20 | 1,000 events through both engines on three push streams: 3,000 SETs delivered, 0 duplicates, 0 missing, 0 out of order, never two POSTs in flight for one stream (engine-2 2,880, engine-1 120) | pass |
| SSF push, engine killed | 16:20-16:22 | engine-1 killed after 500 of 1,000 events: 3,000 delivered, 0 duplicates (bound 150), 0 missing, 0 out of order; 11 emissions answered 503 while the survivor's introspection still reached the dead engine through HAProxy, and were retried | pass |
| Challenges across nodes | 16:22 | not run: the stack switches federation, attestation and auto-registration off | expected fail, [F-0601](../findings.md#f-0601) |
| Redis killed (run 2) | 16:50-16:51 | nothing on this stack reads Redis (federation, attestation and auto-registration are off), so this shows only that its loss does not touch the rest. 30 s down under a token through HAProxy every 200 ms: 204 requests, 0 failures, both engines ready throughout (nothing this stack runs needs Redis for a client_credentials token or for ready), the load clean 0.1 s after Redis started again, no PingFederate restart | pass |
| Redis paused 30 s (run 2) | 16:51-16:52 | 201 requests, 0 failures, ready throughout, no restart | pass |
| PostgreSQL killed (run 2) | 16:52 | 30 s down: PingFederate served tokens for 24 s, then answered 500 and 503 (19 of 213 requests) until PostgreSQL answered again 32 s after the kill; ready stayed 200; each engine's lease loop logged one ERROR ("the jdbc lease backend is not answering") and `ssf-stream-sweeper` was held again 0.1 s after the database answered; no restart | pass |
| Engine killed (run 2) | 16:52-16:54 | engine-1 killed under load: HAProxy marked it down after 17.8 s and no request through it failed; started again, ready after 27.9 s and back in rotation 4.1 s later | pass |
| Console stopped 10 min (run 2) | 16:54-17:06 | 3,008 requests through the engines, 0 failures; the console ready again 28.6 s after its start; a client disabled before the stop still disabled in the admin API and refused by both engines for 60 s after it | pass |
| Rolling upgrade | 16:38-16:42 | each engine drained at HAProxy (15 s), replaced, ready (41 s, 38 s), restarted once for the CA (30 s, 29 s) and back in rotation, then the console replaced and replicated, under a token every 200 ms: 1,189 requests, 0 failures; the lease never held by the console nor taken without its token going up by one | pass |
| Rolling upgrade across a schema change (run 3) | 17:16-17:19 | the stack booted on image A, built from `aaf7389d` (origin/main before V310; 30 migrations), with the database migrated by HEAD's `oidf-db-migrate.jar` to V310 before A started; then every node rolled to HEAD's image as above: 1,091 requests, 0 failures, no lease violation, every node on HEAD's image, whose schema checks said CURRENT (V310). Run 4 at `70b4cac2` (this branch merged with main, 17:37-17:41) the same, 1,078 requests, 0 failures, with every node on A having said `verdict=AHEAD expected_head=V309 database_head=V310` before the roll | pass |

**On the Linux runner.** The licensed `cluster` job ran the same suite on the self-hosted runner - an Ubuntu VM
under Lima, aarch64, 6 CPUs and 12 GiB, rootful Docker, slot 2 - at `6ff2b037`:
run 37855351775, the job 23:44Z on
2026-10-08 to 00:43Z on 2026-10-09 (59 minutes, its build and boot included; the scenarios 23:50-00:41Z). Every
scenario passed, the challenges F-0601's expected fail:

| Scenario | Linux runner (UTC, 2026-10-08/09) | Result |
|---|---|---|
| Topology | 23:50 | pass |
| Client storage | 23:50-00:11: registration window p50 12 ms, p95 109 ms, max 350 ms; disable window p50 60,019 ms, max 60,119 ms | pass |
| Leases | 00:11-00:18: 136 samples, one engine holder; engine-1 killed, engine-2 held it after 32,576 ms (token 6 -> 7) | pass |
| SSF push, steady and engine killed | 00:18-00:22: 3,000 SETs each time, 0 duplicates, 0 missing, 0 out of order; 11 emissions retried on 503 with the engine killed | pass |
| Redis killed, Redis paused | 00:22-00:23: 208 and 200 requests, 0 failures | pass |
| PostgreSQL killed | 00:23-00:24: 1 of 212 requests got no answer in 10 s, 22 s into the outage; 0 failures after it returned; no restart | pass |
| Engine killed | 00:24-00:25: marked down after 15.7 s, 0 failures; ready again after 25.7 s | pass |
| Console stopped 10 min | 00:25-00:37: 3,027 requests, 0 failures; the disabled client still disabled | pass |
| Rolling upgrade | 00:37-00:41: each engine drained (15 s), its one kept-alive session shut at HAProxy, replaced (ready 36 s), restarted once (27 s), back in rotation at 94 s; 1,184 requests, 0 failures | pass |

The stack peaked at 2.37 GiB of memory over 231 `docker stats` samples. Two runs before it failed on Linux only, and
the fixes are in the reference stacks: PingFederate (uid 9031) could not read the archive, `0600` to the runner's uid
([reference/README.md](../../demo/reference/README.md#file-ownership-on-linux)), and a container stopped on a slot port
could not start again because Linux had given the port to an outgoing connection
([Slots on Linux](../../demo/reference/README.md#slots-on-linux)). The roll also now shuts the sessions HAProxy's drain
leaves on an engine: with TCP passthrough a client's kept-alive connection stays on the engine until it is closed.

Not measured, under [F-0601](../findings.md#f-0601): the fault and roll scenarios ran a token load with no SSF
emission each second, so SET loss under those faults is measured only for the engine kill in "SSF push, engine
killed"; ready stayed 200 through PostgreSQL's loss while the leases were lost (recorded, not asserted); and a client
written through MgmtFactory on an engine ([U-0601](../findings.md#u-0601)). The lease failover bound is the
stack's TTL (the default 30 s; the spec named 15 s, and the suite reads `OIDF_LEASE_TTL_SECONDS` from engine-1).

**The roll's order.** The suite rolls the engines, then the console, between two images on one PingFederate version
(13.1.3.0 on both): only the modules change. Ping's upgrade FAQ (read 2026-10-09,
docs.pingidentity.com/pingfederate/12.2/upgrading_pingfederate/pf_upgrade_faq.html) puts the console first for a
PingFederate upgrade: "Failing to upgrade and start the Admin Console and perform cluster replication results in
upgraded engine nodes missing key configuration changes needed to process transactions", and "You can mix
maintenance releases on a cluster but not major and minor releases." A PingFederate version upgrade follows Ping's
order, not the suite's.

To run it again: `REF_SLOT=<slot> reference/cluster/suite.sh` (each PingFederate node fetches its own licence with the
DevOps user and key in `~/.pingidentity/config`); `SUITE_ROLL_FROM_PREV=1` boots on an earlier commit's image for the
schema-crossing roll. The weekly `cluster` job in .github/workflows/licensed.yml
runs it on the self-hosted runner and keeps `results.json` and every log.

