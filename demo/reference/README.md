# Reference stacks

Two docker compose stacks that run PingFederate with this repository's modules on the production profile, with the
infrastructure a deployment needs around it (plan item C-6). They are examples to read and adapt, and the place the
cluster verification suite (C-7) and the licensed CI jobs run. They are not deployments: [Example-only
parts](#example-only-parts) lists what a real one does differently.

| Stack | What runs | Proves |
|---|---|---|
| [`single/`](single/README.md) | PostgreSQL 17 (TLS only), the `db-roles` and `db-migrate` jobs, one PingFederate (`STANDALONE`) | the image boots from an age-encrypted archive on the production profile, with its data stores on `verify-full` TLS and the families migrated by `oidf-db-migrate.jar` before it starts |
| [`cluster/`](cluster/README.md) | the same data tier plus a `pf-client-storage` job, Redis 7 (TLS only, ACL), OpenBao and an agent per node, a PingFederate console and two engines, HAProxy | what [clustering.md](../../docs/operator/clustering.md) says a clustered production node needs, on three nodes; profiles `spire` and `mdm` add a SPIRE server and agent, and `services/device-enrolment` |

Both need Docker with compose v2, `terraform`, `curl`, `openssl`, `unzip` and `python3`, and either this checkout's
Maven build or a release (`PF_RELEASE`, as the rig). Like the rig, they need your Ping DevOps licence details in
`~/.pingidentity/config` (or `PING_DEVOPS_CONFIG`): every PingFederate node fetches its own evaluation licence, and no
script here reads the file - docker hands it to the containers as an env file.

```sh
REF_SLOT=3 reference/single/up.sh        # build, author the archive, boot; then
REF_SLOT=3 reference/single/smoke.sh     # ready, the start-up audit, and a token
REF_SLOT=3 reference/single/down.sh

REF_SLOT=4 reference/cluster/up.sh [--profile spire] [--profile mdm]
REF_SLOT=4 reference/cluster/smoke.sh    # every node's audit, a token through HAProxy and through each engine
REF_SLOT=4 reference/cluster/down.sh
```

`reference/lib/data-tier-test.sh` runs the cluster's data tier alone, with no PingFederate and no licence, and asserts
what its jobs left; Build's `reference-data-tier` job runs it on every pull request.

## Slots

Every port a stack publishes is its slot's, so stacks in parallel worktrees - or a rig and a stack - never collide.
A slot is a whole number from 0 to 44 (`REF_SLOT`, required); its twenty ports start at 57100 + 20 x slot
(`conformance/layout.sh`'s `pfai_slot_ports`, which the rig's `PF_RIG_SLOT` uses too). All bind 127.0.0.1.

| Offset | Name | Used by |
|---|---|---|
| 0, 1, 2 | `RIG_HTTPS`, `RIG_HTTP`, `RIG_ADMIN` | the rig with `PF_RIG_SLOT` (its 9031, 9080, 9999) |
| 3, 4 | `RIG_AUTHOR_ADMIN`, `RIG_AUTHOR_RUNTIME` | the rig's authoring PingFederate |
| 5 | `RUNTIME` | the issuer's port: single's PingFederate, the cluster's HAProxy |
| 6 | `ADMIN` | single's admin console and API, the cluster console's |
| 7, 8 | `ENGINE_1`, `ENGINE_2` | each engine's own runtime port, past HAProxy |
| 9, 10 | `HAPROXY_API`, `HAPROXY_STATS` | HAProxy's runtime API (admin level: drain an engine) and its stats page |
| 11, 12, 13 | `POSTGRES`, `REDIS`, `OPENBAO` | the data tier, TLS only |
| 14, 15 | `AUTHOR_ADMIN`, `AUTHOR_RUNTIME` | the stack's authoring PingFederate (`lib/author.sh`) |
| 16, 17 | `SPIRE`, `MDM` | reserved for the `spire` profile; `device-enrolment` (`mdm`) |
| 18, 19 | - | spare |

Each stack instance is named `REF_NAME` (default `ref-<stack>-s<slot>`): the compose project, the prefix of every
container, and the directory `<stack>/.local/<name>/` that holds what it generated. Every container, network and
volume carries the label `owner=$REF_OWNER` (default `pf-agentic-identity`).

## The issuer

`https://pf.reference.test:<RUNTIME port>`. `pf.reference.test` resolves only on the stack's network, where single's
PingFederate (or the cluster's HAProxy) carries it as an alias and listens on the same port number it is published
on, so a client in the network and one on the host (`https://localhost:<port>`) reach the same server on the same
port, and the server certificate names both. Checked on Docker Desktop 29.4 (macOS, 2026-10-08): discovery fetched
inside the network says `"issuer": "https://pf.reference.test:57705"`, and the heartbeat answers 200 there and on
`localhost` with the certificate checked against the stack's CA.

## What up.sh generates

Everything under `<stack>/.local/<name>/`, git-ignored, kept between runs, never printed, never exported to the public
tree:

| Path | What | Made by |
|---|---|---|
| `tls/ca.crt`, `ca.key` | the stack's CA, kept once made (C-7 issues its recording SET receiver's certificate from it); the archive puts it in PingFederate's trusted CAs ([Trust](#trust)) | `lib/gen-tls.sh` |
| `tls/<server>.crt`, `.key` | a leaf for PostgreSQL, Redis, OpenBao and PingFederate (`pf.p12` for its import), reissued when its names change | `lib/gen-tls.sh` |
| `secrets/*` | the roles' passwords, Redis's `oidf` password, the cluster password, the SSF secret key, the smoke client's secret, the authoring administrator's password, the age identity; `*.curl`, the scripts' `curl -K` files for the administrator and smoke client | `lib/gen-secrets.sh` |
| `data.zip.age` | the config archive, authored on a localhost PingFederate by `reference/terraform/<stack>` and encrypted to the age recipient; the plaintext is deleted | `lib/author.sh` |
| `oidf-db-migrate.jar`, `context/` | the migration runner and the image's build context, staged for the production profile | `lib/build-image.sh` |

`REF_REAUTHOR=1` authors the archive again (once per name otherwise: the issuer's port is in it). `SKIP_BUILD=1` reuses
the image and the stage.

## File ownership on Linux

A bind-mounted file keeps the host's owner and mode inside the container. Docker Desktop's file sharing hides that on
a Mac; a Linux host does not, and a container whose user is not the file's owner cannot read a `0600` file. C-7's first
run on the Linux runner (2026-10-08, rootful Docker, the runner uid 1000) failed that way: the archive was `0600` to
uid 1000, PingFederate runs as 9031, and the entrypoint, unable to read it, called it plaintext.

The rule the stacks keep: the host's boundary is the `0700` directories (`.local/`, `.local/<name>/`, `tls/`,
`secrets/`), so no other host user reaches anything here; inside them, keys and secrets stay `0600`, and a container
reads them only as root or as the host's own uid. A container that runs as some other uid gets its own copy, made by
a root step: `install -o <uid> -m 400` onto a tmpfs or into the container. Only files that are not secret are `0644`.
The stacks assume rootful Docker, or rootless Docker (where root in a container is the host's user), and no
`userns-remap`, under which root in a container could read none of the `0600` files.

| Container (uid it runs as) | Host file it reads | Host mode | How it reads it |
|---|---|---|---|
| `postgres` (root, then postgres 70) | `tls/postgres.key`, `secrets/postgres-superuser` | 0600 | as root: the key `install`ed to postgres, the password read by the image's entrypoint before it drops to postgres |
| `db-roles`, `db-migrate`, `pf-client-storage` (root, `user: "0:0"`) | `secrets/` (dir 0700), `secrets/oidf-migrator`, `secrets/pf-clients` | 0600 | as root |
| `pf-secrets` (single; root) | `secrets/age.key`, `secrets/ssf-secret-key` | 0600 | as root, `install`ed 0400 to uid 9031 on the tmpfs PingFederate mounts read-only |
| `redis` (root, then redis 999) | `tls/redis.key`, `redis/users.acl` | 0600 | as root, `install`ed 0400 to redis |
| `openbao` (root, then openbao) | `tls/openbao.key` | 0600 | as root, `install`ed 0400 to openbao |
| `bao-init` (the host's uid) | `secrets/`, writes `bao/` | 0600 / 0700 | as their owner |
| `agent-*` (root, then 9031) | `bao/<node>/role-id`, `secret-id` | 0600 | as root, `install`ed 0400 to 9031; the agent renders the node's secrets 0400 onto its tmpfs |
| `suite-secrets` (C-7 only; root) | `suite/introspect-secret` | 0600 | as root, `install`ed 0400 to 9031 on each node's tmpfs |
| `receiver` (C-7 only; the host's uid) | `tls/receiver.key`, writes `suite/receiver/` | 0600 / 0700 | as their owner |
| `device-enrolment` (mdm; root) | `secrets/enrolment-signing.jwk` | 0600 | as root |
| PingFederate nodes (9031) | `data.zip.age` | **0644** | age ciphertext: the identity that opens it reaches 9031 only through the tmpfs. `author.sh` and `up.sh` set 0644, and the image's entrypoint refuses an archive it cannot read as unreadable, naming its mode and owner |
| PingFederate nodes (9031), `haproxy` (99), every client | `tls/ca.crt`, `tls/*.crt`, `service-points.conf`, the client storage SQL | 0644 | not secret |
| `haproxy` (99), `spire-*`, every job | the tracked configuration and scripts (`haproxy.cfg`, `server.hcl`, `agent.hcl`, `pg_hba.conf`, `lib/*.sh`) | as checked out | not secret |

## Slots on Linux

Linux gives outgoing connections local ports from `net.ipv4.ip_local_port_range`, 32768-60999 by default, and every
slot's ports (57100-57999) are inside it. A connection the host makes to a published port can be handed another
slot port as its own, and while it is open a container stopped on that port cannot start again: C-7's Redis and
console faults on the Linux runner (2026-10-08) failed `docker start` with "address already in use", and the
console stayed down for the rolling upgrade after them. Reserve the slots' range once per host:

```sh
echo 'net.ipv4.ip_local_reserved_ports = 57100-57999' | sudo tee /etc/sysctl.d/60-pfai-slots.conf
sudo sysctl -p /etc/sysctl.d/60-pfai-slots.conf
```

`up.sh` warns and `cluster/suite.sh` refuses to start when the slot's ports are in the range and not reserved
(`ref_slot_ports_reserved`, `lib/common.sh`). The runner VM reserves them in its provisioning
(`tools/ci/runner-vm.lima.yaml`). Docker Desktop binds published ports on the Mac, outside the VM the containers run
in, and the check does nothing there.

## Trust

Every server in a stack has a certificate from the stack's CA, and every client checks it with the host name:
PgJDBC with `sslmode=verify-full` and `sslrootcert`, the modules' Redis client with `OIDF_REDIS_CA_FILE`, HAProxy's
health checks with `verify required`, and the scripts' `curl --cacert`. PingFederate's own outbound TLS - and the
modules' platform HTTP client, which uses the JVM's default trust - trusts the CA because the archive carries it in
PingFederate's trusted CAs (`pingfederate_certificate_ca`), replicated to every node. A `-Djavax.net.ssl.trustStore` in
`JAVA_OPTS` does not do it: PingFederate sets that property to its own store,
`server/default/data/ping-ssl-client-trust-cas.jks` (`jcmd <pid> VM.system_properties` on a 13.1.3 engine, 2026-10-08,
showed that path although `JAVA_OPTS` named another). One caveat, [F-0585](../../docs/findings.md#f-0585): the
modules read that store once, when the JVM's default TLS context is first made, which on a node's first boot is
before the archive's CAs reach it - so the modules trust the stack CA only from the node's first restart. The stacks
do not depend on it: their PostgreSQL and Redis clients are given the CA file. No JDK switch is set anywhere, which
the production profile would refuse.

## Example-only parts

- **Secrets on disk.** `.local/` holds every password and key in files. A deployment keeps them in its secret store;
  the cluster shows the shape with OpenBao and an agent per node, but its unseal key and root token are in `.local/`
  too, with one share.
- **Evaluation licences.** Each node fetches one with your DevOps credentials.
- **One host.** Every container on one Docker network; HAProxy is the only front door, with no TLS of its own
  (passthrough) and no redundancy.
- **The Terraform.** `reference/terraform/modules/pf-reference` configures what the stacks need to boot and hand out
  one token; a deployment's own configuration replaces it.
- **HAProxy's runtime API.** `stats socket ipv4@0.0.0.0:9999 level admin` (`haproxy/haproxy.cfg`), unauthenticated: published to 127.0.0.1
  only, but any container on the stack's network can drain or disable an engine with it. A deployment binds it to a
  Unix socket or a management network.
- **The SPIRE agent's Docker socket.** The `spire` profile's agent mounts `/var/run/docker.sock` for the `docker`
  workload attestor and runs with the host's pid namespace; read-only or not, that socket is root on the host.
- **The profiles.** `spire` and `mdm` start the services; the attester's SPIRE reader (X-B07) and device-enrolment's
  production configuration (IOM registry, App Attest, MDM) are Phase 5 and 6.
