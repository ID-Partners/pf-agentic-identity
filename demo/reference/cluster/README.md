# reference/cluster

A PingFederate console and two engines on the production profile, behind HAProxy, with what
[clustering.md](../../../docs/operator/clustering.md) says a clustered production node needs. [../README.md](../README.md)
has the slots, the issuer, trust and what `up.sh` generates.

```sh
REF_SLOT=4 ./up.sh [--profile spire] [--profile mdm]
REF_SLOT=4 ./smoke.sh
REF_SLOT=4 ./down.sh
REF_SLOT=4 ./suite.sh        # the cluster verification suite (C-7): boot, every scenario, logs, down
```

## Services

| Service | What it does |
|---|---|
| `postgres`, `db-roles`, `db-migrate` | as [single](../single/README.md) |
| `pf-client-storage` (job) | PingFederate's own `oauth-client-management-postgresql.sql`, taken from the pinned image, run as `pf_clients` in schema `pf`: idempotent, and all or nothing - both tables there, nothing; neither, the script in one transaction; one, refused |
| `redis` | Redis 7, TLS only (`--port 0`); ACL user `oidf` held to `oidf:*` and `oidf-registration:*` and the commands the modules' client sends to a master; `default` off (`../lib/redis-acl.sh`) |
| `openbao`, `bao-init` (job) | OpenBao on file storage over TLS; `bao-init` initialises it with one share, unseals it, writes `secret/pf/<node>` and an AppRole per node that reads only its own path |
| `agent-console`, `agent-engine-1`, `agent-engine-2` | a `bao agent` per node, as uid 9031, rendering the node's `oidf.env` (`OIDF_REDIS_URL`, `PF_RUN_pf_cluster_auth_pwd`), the SSF secret key and (the console's) age identity to a tmpfs the node mounts read-only |
| `console` | `CLUSTERED_CONSOLE`; the only node with the archive; up.sh asks it to replicate (`POST /pf-admin-api/v1/cluster/replicate`: the image's own hook replicates only after a bulk import) and registers `reference-smoke` through its admin API |
| `engine-1`, `engine-2` | `CLUSTERED_ENGINE`, no archive: each takes the console's configuration. Each listens on its own slot port, published, so C-7 can address one engine past HAProxy |
| `haproxy` | HAProxy 3.2, `mode tcp` (TLS passes through to the engines), round robin, each engine checked with `check-ssl verify required ca-file` on `/pf/heartbeat.ping` with the issuer's name, and followed by name through Docker's DNS (`resolvers docker`), so a replaced engine on a new address comes back into rotation (F-0603); the admin runtime API on the slot's `HAPROXY_API` port (drain an engine: `set server engines/engine-1 state drain`), stats on `HAPROXY_STATS` |

Every PingFederate node sets `OIDF_CLUSTER_MODE` to match `OPERATIONAL_MODE`; cluster authentication
(`pf.cluster.auth.pwd`, from OpenBao) and encryption (`PF_RUN_pf_cluster_encrypt=true`); `DNS_PING` - the image's
discovery protocol - over the alias `pf-cluster` all three share; JDBC OAuth client storage (`service-points.conf`
with `client.manager=...ClientManagerJdbcImpl`, a copy of the image's file with that one line changed and checked,
mounted on every node because replication cannot carry it); `OIDF_REDIS_URL` (`rediss://`, user `oidf`) with
`OIDF_REDIS_CA_FILE`; `OIDF_LEASE_BACKEND=jdbc` on the data store; SSF on the `tables` dialect; and a `mem_limit`
(`REF_PF_MEM_LIMIT`, default 1536m: the image's `JAVA_RAM_PERCENTAGE=75.0` sizes the heap from it).

## Profiles

- **`spire`**: a SPIRE 1.13.3 server (trust domain `reference.test`, `join_token` node attestation, SQLite) and agent
  (the `docker` workload attestor, through the host's Docker socket). up.sh generates the agent's one-time join token
  on the server and exports the server's trust bundle to `.local/<name>/spire/bundle.pem` for the attestation client.
  Phase 5 (X-B07) adds the attester's SPIRE reader that uses it.
- **`mdm`**: `services/device-enrolment` from this checkout's build on the Temurin 17 JRE, `OIDF_DEPLOYMENT_PROFILE=
  development`, `REGISTRY=memory`, a generated EC signing key, on the slot's `MDM` port. Phase 6 adds its production
  configuration: the IOM registry, App Attest, an MDM such as Intune (X-A16), and an IdP (its README's PingOne
  section). A release publishes no device-enrolment, so `mdm` needs the reactor.

## The cluster suite

`suite.sh` boots the stack (`up.sh`, `smoke.sh`), adds `suite/compose.suite.yml` - the SSF settings the push scenario
needs on every node and `receiver`, a recording SET receiver with a certificate from the stack's CA - and runs
services/cluster-suite's scenarios with `mvn -Pcluster`. It keeps
`results.json`, a summary, `docker stats` every 10 s and every container's log under `SUITE_OUT` (default
`.local/<name>/suite-<time>/`), and always takes the stack down (`SUITE_REUSE=1` runs against a stack already up and
leaves it). `SUITE_ROLL_FROM_PREV=1` boots the nodes on an earlier commit's image (`suite/build-prev-image.sh`) for the
rolling upgrade across a schema change. The dated results are in
[clustering.md](../../../docs/operator/clustering.md#on-the-reference-cluster); the weekly licensed job is
`cluster` in .github/workflows/licensed.yml.

`up.sh` restarts each engine once after the console's first replication: an engine's JVM trusts the CAs PingFederate
held when it started, and a new engine gets the stack's CA only with that replication (F-0585).

## Smoke check

`smoke.sh`: each node's start-up audit says its mode, the production profile, `OAuth clients in database` and `lease
backend jdbc`, with no code refusal and no component `REFUSED` or `FAILED_CONFIG` (an engine's audit can show SSF
`FAILED_DEPENDENCY`: it starts before the console replicates the data stores, and the component supervisor starts SSF
once they arrive - ready is checked as well); `cluster/status` lists one console and two engines; and `reference-smoke`
takes a token through HAProxy and through each engine on its own port, all over TLS checked against the stack's CA.
An engine can take a few seconds to see a client registered a moment before (its client storage cache, U-0027), so
the token is asked for until it comes or `REF_TOKEN_WAIT` (180) seconds pass.

## Verified

On this Mac (Docker Desktop 29.4, 12 CPUs, 19 GiB for Docker), PingFederate 13.1.3.0, this branch, slot 31, 2026-10-08:

- `up.sh --profile spire --profile mdm` from nothing, then `smoke.sh`: passed at 05:38:05Z. The console replicated
  with `cluster/status` reporting no replication required; engine-1 issued a token at once and engine-2 after 3 s.
- The engines took the console's configuration without its master key: neither had an archive, each created its own
  key at boot (`MasterKeySetImpl ... created key`), and after "Deploying configuration from cluster" both reached
  their data stores with the replicated passwords (SSF ready, the leases acquired on PostgreSQL).
- `jcmd <pid> VM.system_properties` on an engine: `pf.cluster.auth.pwd` set (not shown), `pf.cluster.encrypt=true`
  (PingFederate 13.1's `PF_RUN_<property>` environment form applied), `pf.operational.mode=CLUSTERED_ENGINE`, and
  `javax.net.ssl.trustStore` PingFederate's own store ([Trust](../README.md#trust)), which holds the stack CA from the
  archive (160 entries with it, 159 before).
- `DNS_PING` on the compose alias found every node: the console listed two engines. The image still logs `Not using
  invalid host (${DISCOVERY_INITIAL_HOST})` for the unused TCPPING list; it is harmless.
- `docker stats` with every service and both profiles up and idle: about 2.5 GiB in all (each PingFederate 600-700
  MiB of its 1.5 GiB limit). The limits add up to 4.5 GiB for the three PingFederate nodes and under 0.5 GiB for the
  rest, so the stack fits the 8 GB a GitHub-hosted runner has; C-7 measures it under load.
- With every node starting at once, the engines' first JDBC lease renewals and SSF push ticks missed their deadline
  for about ten seconds ("the deadline passed before the statement was made") and recovered by themselves (the
  lease re-acquired with the next token). C-7's lease scenarios start from a settled cluster.
