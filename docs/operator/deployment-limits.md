# Deployment limits

What a release built from this repository does not support yet, and what goes wrong if you deploy it that way
anyway. One section per limit; each names the release expected to lift it.

## Clustering, from 0.7.0

From 0.7.0 a PingFederate cluster is supported in one shape, the one [reference/cluster](../../demo/reference/cluster/README.md)
runs and the cluster verification suite (plan item C-7) drove on 2026-10-08
([clustering.md, On the reference cluster](clustering.md#on-the-reference-cluster)), **and only for the components
that stack runs**: PingFederate's own OAuth clients and tokens, the jdbc leases and SSF's transmitter (push streams
and emission). The shape:

- a `CLUSTERED_CONSOLE` and `CLUSTERED_ENGINE` nodes, each with `OIDF_CLUSTER_MODE` set to its mode and the
  production profile ([clustering.md](clustering.md#what-a-clustered-production-node-needs));
- PingFederate's OAuth clients in a database (JDBC client storage: `service-points.conf`'s `client.manager` on
  every node, and PingFederate's own `oauth-client-management-postgresql.sql`);
- `OIDF_LEASE_BACKEND=jdbc` on a PostgreSQL data store, with the platform migrations applied
  ([Leases](clustering.md#leases));
- one Redis for every node (`OIDF_REDIS_URL`) for the state the modules share through it;
- SSF on the `tables` dialect (`OIDF_SSF_STORE_DIALECT=tables`), so push streams, the receiver's inbox and the
  emission outbox are shared ([SSF push streams](clustering.md#ssf-push-streams)).

In that shape the suite measured: a client registered through the console's admin API reaching the other engine
within 724 ms, a disable within 60.4 s; a killed lease holder's job (`ssf-stream-sweeper`) taken over by the other
engine in 31.5 s; 1,000 SSF events on three push streams delivered once each and in order, with an engine killed
half way and without; PostgreSQL's and an engine's loss recovered with no PingFederate restart; Redis killed and
paused with no effect - nothing the stack runs reads Redis, so this says nothing of the Redis-backed state below; the
console stopped for ten minutes with no error on the runtime; and a rolling replacement of every node under load with
no failed request. A deployment of another shape - the `ldm` dialect, the `redis` lease backend, client storage in
files - is not what was verified.

**Not verified on a cluster in 0.7.0: federation, client attestation (the AS side and the attester), automatic
registration, the SSF receiver, hosting, the operator APIs and FAPI.** The reference cluster switches them off, so
the suite has not run a challenge on one engine and a token on the other, a replayed proof, evidence binding,
a registration written by an engine, or the registration-sweeper, ssf-poll-receiver and federation-key-observer
leases ([F-0601](../findings.md#f-0601), [U-0601](../findings.md#u-0601)). Their state is shared through Redis
and the data stores as [clustering.md](clustering.md) describes, and a clustered production node refuses them
without those stores, but that is read from the code, not driven on two nodes. Run them on one node, or on a cluster
only after your own test of these paths, until F-0601 closes.

What remains, each re-read on origin/main `d9099491` (this branch's merge base) on 2026-10-09:

| Limit | What it means | Until |
|---|---|---|
| The SSF `ldm` dialect is single-node | its push stream leases, receiver inbox and emission outbox are in each node's memory (`LocalStreamLeases`, `LocalReceiverInbox`, `LocalEmissionOutbox`), so a clustered production node refuses SSF on it, naming `OIDF_SSF_STORE_DIALECT=tables` (Phase 4 decision 3; [F-0150](../findings.md#f-0150), [F-0387](../findings.md#f-0387) and the S10f family, accepted by David until 2027-06-30) | 1.1.0 (S10f) |
| The `redis` lease backend | a Redis failover can lose a lease and its fence counter, so two nodes may run one job at once; a clustered production node takes it only with `redis-lease` accepted ([F-0515](../findings.md#f-0515)) | use `jdbc` |
| The challenge endpoints' per-caller caps | each endpoint's `ChallengeRateLimiter` is a map in its servlet with no store behind it, so each node grants a caller its own allowance - 60 requests a minute by default, 120 on two nodes. The challenges themselves, spent proofs and evidence bindings are shared through Redis | - |
| The RAR models document | read once per PingFederate process (`OIDF_RAR_MODELS_FILE` or `OIDF_RAR_MODELS`, `RarModels`): nodes given different documents answer the same request differently. Give every node the same one | - |
| The client storage window | an engine serves a client it has cached for about a minute after the client is disabled, its secret changed or it is deleted (60.4 s at most over 20 trials; [U-0027](../findings.md#u-0027)). A new client is seen at once | PingFederate's |
| Federation, attestation, auto-registration, the SSF receiver, hosting, the operator APIs and FAPI on a cluster | not verified (above): the reference cluster switches them off, so the suite has not run the challenge, replay, attested-load, engine-written registration, registration-sweeper, ssf-poll-receiver and federation-key-observer scenarios on two nodes ([F-0601](../findings.md#f-0601), [U-0601](../findings.md#u-0601)) | 0.8.0 |
| SSF and readiness under the faults | the fault scenarios ran a token load only: no SSF emission ran during the Redis, PostgreSQL, engine-kill and console faults or the rolling upgrade, so "no SET lost" there is not measured (SSF with an engine killed is, in its own scenario); ready stayed 200 through 30 s of PostgreSQL loss while the leases were lost and PingFederate answered 500/503 ([F-0601](../findings.md#f-0601)) | 0.8.0 |
| A rolling upgrade across a schema change | ran once, on 2026-10-08, from `aaf7389d`'s image to this branch's across V310, with no failed request ([F-0602](../findings.md#f-0602)); the weekly job rolls between two containers of one image, so run `reference/cluster/suite.sh` with `SUITE_ROLL_FROM_PREV=1` before a release whose migrations change | - |
| A private CA on a new engine | an engine's modules trust only the CAs PingFederate held when its JVM started, and a new engine receives the configuration's trusted CAs with its first replication, so its outbound calls to a host under a private CA fail until it restarts once ([F-0585](../findings.md#f-0585)); reference/cluster restarts each engine once after its first replication | 0.8.0 |
| `spire` and `mdm`, and load | the reference cluster's `spire` and `mdm` profiles are outside the suite, and the suite's load is a request every 200 ms: capacity under production load is the 1.0 gates' (programme plan, 1.0 gates 3 and 5) | 1.0.0 |

Up to 0.6.x one PingFederate node was supported ([F-0007](../findings.md#f-0007)).

## The device path, until 0.9.0

services/device-enrolment is not production-usable until Phase 6: a device enrols `UNKNOWN`, re-minting needs
`COMPLIANT`, and nothing in this repository can make it so. Its README says why
(services/device-enrolment).
