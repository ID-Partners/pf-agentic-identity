# Running PingFederate from this repo

This directory turns a clone of this repo into a running PingFederate 13.1.3 with every module in it,
configured to pass the [OpenID Foundation conformance suite](https://www.certification.openid.net/)'s
FAPI 2.0 and Shared Signals plans. It is the repo's own PingFederate configuration - the demo and deploy
repos consume it; nothing here depends on them.

```sh
./up.sh          # ~5 minutes the first time: author, export, build, boot
```

You need Docker, Terraform (>= 1.5), Maven, Node and **your own licence details**. The image bakes no
licence. At boot, the stock Ping image fetches an evaluation licence with your Ping DevOps credentials,
read from `~/.pingidentity/config` (or `$PING_DEVOPS_CONFIG`), a two-line `KEY=VALUE` file:

```
PING_IDENTITY_DEVOPS_USER=<your DevOps email>
PING_IDENTITY_DEVOPS_KEY=<your DevOps key>
```

Get them at https://devops.pingidentity.com/how-to/devopsRegistration/. Nothing licensed and no key
ever lands in git: everything `up.sh` generates is under `.gitignore` here.

When it finishes, PF answers on `https://localhost:9031` (self-signed) with discovery at
`/.well-known/openid-configuration`, the SSF transmitter at `/.well-known/ssf-configuration`, an HTTP
listener on 9080 and the admin console on 9999 (`administrator`, password in `.author.env`). The image
configures none of that for you: the rig's environment (the `env` block of `profiles/conformance-fapi2.yaml`,
rendered into `.context/vars.env`) accepts Ping Identity's licence agreement
(`PING_IDENTITY_ACCEPT_EULA=YES`), turns the plain listener on (`PF_RUN_PF_HTTP_PORT=9080`, which the
image's entrypoint allows only because the rig's profile is `development`), and the container's health is
the image's own healthcheck ([the image README](../image/README.md#the-healthcheck)).
`docker compose down` stops it; `./up.sh` again rebuilds the image from the archive you already have;
`SKIP_AUTHOR=1 ./up.sh` skips re-authoring when only the modules changed.

## What `up.sh` does

| Step | Script | Produces |
|---|---|---|
| 1 | reactor mode: `mvn package` + `stage-modules.sh --profile conformance`; release mode: `stage-from-release.sh --profile conformance` | the conformance profile's module jars, the CIBA simulator among them, and their v2 `MANIFEST`, which names each one - built from this repo, or taken from a release's assets once every one verifies against its `SHA256SUMS`. Run first: authoring stages the simulator from here |
| 2 | `gen-keys.sh` | `keys/` - eight key pairs: the suite's five clients (two FAPI 2.0, the SSF receiver, two CIBA) and, for the OpenID Federation OP plan, the suite's own trust anchor and its relying party's entity and client keys - PF is only ever given public halves; plus an mTLS CA and two client certificates the FAPI-CIBA plan's configuration insists on, and a CA and certificate for a suite run with `suite/suite-compose.yml`; `secrets.env` - a test-user password and two client secrets; from 0.7.0 PingFederate's own runtime certificate, `pf-runtime-tls`, from its own CA, naming `localhost`, `host.docker.internal`, the rig's name and the issuer's host (F-0362; `deploy/terraform/modules/base` imports it and puts the CA in PingFederate's trusted CAs, so a module calling the issuer checks the host name with no JDK switch) |
| 3 | `tools/profile.py author` | from the profile (`profiles/conformance-fapi2.yaml` unless `PF_PROFILE` names another): a **stock** PF 13.1.3 container with its admin API on `localhost:29999`, the cipher-list overlay and the CIBA plugin staged; `deploy/terraform/agentic-idp` applied to it with fresh state - OAuth server settings, a JWT access token manager and mappings, an OIDC policy, a login form and test user, the clients (below); then `data.zip`, PF's config archive, its whole saved state, refused if it would fail the suite. Its working files go to `.profile/` |
| 4 | `compose-context.sh` | `.context/` - the image build (`build/pingfederate/` here, `image/` in the public tree) plus that archive |
| 5 | `tools/profile.py render` | `.context/vars.env` - the same profile's environment, with the suite's origin and alias and the clients' public JWKS filled in |
| 6 | `docker compose up --build` | the image, built with `STAGING_PROFILE=conformance`, running with `.context/vars.env` and your licence details |

Step 3 is how PF is configured **as code**: the profile and the Terraform root it feeds are the source,
`data.zip` the built artefact the image imports at boot. There is no volume; a change made in the console
is gone at the next start. Change the profile or a module under `deploy/terraform/modules/`, run `./up.sh`
again. The provider `terraform init` fetches is the build `deploy/terraform/agentic-idp/.terraform.lock.hcl` records, for Linux and macOS on either architecture; the lock file is
committed, and build.yml's lint job validates the configuration against it (`tools/ci/lint-terraform.sh`,
which also says how to move the provider).

**The clients** (`deploy/terraform/modules/conformance-clients`, and `modules/ssf` for the SSF ones): two FAPI 2.0 clients (`private_key_jwt` + DPoP + PAR + PKCE),
an SSF receiver (`ssf.manage`), an SSF event operator (`conformance-ssf-emitter`, `ssf.provision` - the
provisioner scope the servlet requires for SCIM and `/ssf/events:emit`), and the introspection client
the SSF servlet validates receiver tokens with. The `ssf.*` scopes are the ssf module's; `ssf.manage` and
`ssf.provision` are exclusive, so no client carries either unless named there.

**Federation and attestation are present and switched off.** The image runs the whole module set, and
`profiles/conformance-fapi2.yaml` switches three of its components off: `OIDF_FEDERATION_ENABLED=false`,
`OIDF_AUTO_REGISTRATION_ENABLED=false` and `OIDF_ATTESTATION_AUTH_ENABLED=false` (plan item S-9;
[docs/operator/components.md](../docs/operator/components.md)). A component switched off never starts: its
filters pass every token request to PF's own client authentication, which is what the FAPI, SSF and CIBA plans
test, its endpoints answer 404, and ready ignores it. Before 0.6.0 the rig kept federation inert by naming PF
itself trust anchor and trust controller with no pinned keys, because a module that could not start took
`pf-runtime.war` down; from 0.6.0 that leaves `AUTO_REGISTRATION` enabled and `FAILED_CONFIG` (no pinned
keys) and `FEDERATION` `DEGRADED`, and ready answers 503 ([F-0192](../docs/findings.md#f-0192)). `OIDF_ATTESTATION_REQUIRE_BRIDGE_KEY=false`, the old way to switch
attestation off, is a superseded name for the third switch.

**The federation profile makes PF a trust anchor.** `PF_PROFILE=federation ./up.sh` authors
`profiles/conformance-federation.yaml`, which extends the default profile: it switches federation and automatic registration back on, names PF as its own trust
anchor and controller, and `OIDF_FEDERATION_SELF_ANCHOR` trusts that anchor with the key PF signs with, read
from its own key store, so nothing is pinned before it boots. Attestation stays off. That is the PF the
suite's OpenID Federation plans test. The FAPI, SSF and CIBA plans are run without it.

**The federation-op profile joins PF to the suite's own federation.** For the OP plan the suite hosts a
trust anchor and a relying party beneath it, per plan run, and the RP registers at PF's authorization and
PAR endpoints (OpenID Federation 1.0 §12.1). `PF_PROFILE=federation-op` is
`profiles/conformance-federation-op.yaml`, which extends the federation profile: the suite's anchor pinned beside PF itself, its host let through the outbound URL
policy, `OIDF_REQUIRE_METADATA_POLICY=false` (the suite's anchor publishes no policy), PAR optional instead
of required (the RP sends its request object by value), and the suite's CA among PF's trusted CAs (`material.trusted_cas`) - PF
fetches the RP's `jwks_uri` itself when it checks a request object, and checks the certificate like any
other. So the suite has to be one whose certificate that CA issued: `suite/suite-compose.yml` runs one,
with `keys/suite-tls.crt`.

**The attester-cimd profile is the attester's CIMD source (X-B02).** `PF_PROFILE=attester-cimd` is
`profiles/conformance-attester-cimd.yaml`: one CIMD client listed in `OIDF_CIMD_CLIENTS`, its trust root (`keys/cimd-spiffe`) in
`OIDF_CIMD_TRUST_BUNDLES`, and the document's host let through the outbound rules. `cimd/serve.sh` serves the
client's document, `cimd/payments.json`, over https on port 57443 with `keys/suite-tls.crt`, and
the conformance-clients module registers the PF client whose id is the document's URL (`conformance.cimd_client_id`). Two things the profile leaves to the
run that uses it (REL5): the PingFederate JVM has to trust `keys/suite-tls-ca.crt`, since the CIMD fetch trusts the
JVM's CAs and has no ignore-SSL switch, and the attestation filter's bridge key for the client (`keys/cimd-client`)
has to be configured. Added 2026-10-08, not yet run on a licensed rig.

**A second rig runs beside the first.** `PF_RIG_NAME` names the container, the image and the compose
project, so a rig built from another checkout doesn't replace this one. From 0.7.0 `PF_RIG_SLOT` (0 to 44) gives it
a slot's ports - 57100 + 20 x slot for HTTPS, then HTTP, admin and the authoring server's two - and the name
`pf-rig-s<slot>`, the same slots the reference stacks use ([reference/README.md](reference/README.md#slots));
a port or name set explicitly still wins. Or give it its own ports by hand:

```sh
PF_RIG_NAME=pfai-fed PF_PROFILE=federation PF_PORT_HTTPS=49031 PF_PORT_HTTP=49080 PF_PORT_ADMIN=49999 \
  PF_AUTHOR_ADMIN_PORT=48999 PF_AUTHOR_RUNTIME_PORT=48031 PF_BASE_URL=https://host.docker.internal:49031 ./up.sh
```

## From a release

`layout.sh`, beside this README, decides where the image build, the PingFederate version and the modules are, and in which
mode the rig runs: **reactor** in a checkout with a `pom.xml` (the modules are built here, as above), **release**
when `PF_RELEASE` is set or there is no `pom.xml` (the public tree). In release mode step 5 runs
`stage-from-release.sh` instead of Maven, so the rig needs no JDK or Maven, only `curl` and `sha256sum` or `shasum`:

```sh
PF_RELEASE=0.6.1 ./up.sh                  # fetch v0.6.1's assets anonymously, verify them, stage, boot
PF_RELEASE=/path/to/dist ./up.sh          # a directory of release assets, verified the same way
```

The first release it can stage is 0.6.1, the first with `war-assembler-<version>.jar` among its assets. The
image is built from the same bytes either way: [the image README](../image/README.md#staging-from-a-release)
says what is checked, and Build's image job proves a release's stage equals the reactor's. `SKIP_BUILD=1` reuses
what is staged in both modes. `verify-rar-principal.sh` lends the rig the release's `pf.plugins.pf-rar-paz-plugin.jar`
in release mode, after checking the release against its `SHA256SUMS` again on every run (a directory as well as a
fetched version).

## A PF on a public address

The issuer PF advertises is baked into the archive (the root's `pf_base_url`, from the profile's `pf.base_url` or `--base-url`), and a suite
fails its first check if the issuer in discovery is not byte-for-byte the URL it fetched discovery from.
For a PF that a hosted suite will reach, set the origin before authoring:

```sh
PF_BASE_URL=https://your.host:port ./up.sh     # authors it into the archive and .context/vars.env
```

The suite opens its own TLS handshakes against the token, authorization and userinfo endpoints and fails
anything it does not like about the listener, so the listener has to be PF's own 9031, reached through
a TLS-passthrough TCP proxy and not an HTTP edge that terminates TLS. `.context/` is the build context
a deploy tool wants - `docker build --build-arg STAGING_PROFILE=conformance .context`, or your platform's
equivalent, and the build arg is not optional: `up.sh` stages `modules/` for the conformance profile,
`compose-context.sh` accepts nothing else, and the assembler refuses to build that stage into an image for
the default profile, production (`modules/ was staged for the conformance profile, and this image is being
built for production`; verified 2026-09-27). What comes out is a conformance image: it carries the CIBA
simulator, which runs only where the three settings `.context/vars.env` carries say so
(plugins/ciba-sim). The deployed service needs `.context/vars.env`'s
values plus your DevOps credentials as its variables. The demo repo `pf-oidf-modules` deploys one such PF
(project `pf-conformance`) and keeps the platform-specific pieces.

## Why it is shaped like this

**The cipher list is in two places.** `config-store/com.pingidentity.crypto.SunJCEManager.xml` takes
the CBC and static-ECDH suites out, because the suite offers them and fails a server that accepts.
It is laid over the image *and* carried in the archive; that file's header says why either alone
looks fine and is not.

**The federation module's extended properties are declared.** PingFederate keeps an extended property on a
client only when it has been told about it, and drops the rest without a word; the module marks each client it
registers with `status` and its registration's end. `deploy/terraform/modules/base` declares every name in
`docs/extended-properties.json`, which a test keeps equal to the code - before it did, an RP the OP plan
registered came back unmarked, and its later requests went unchecked.

**A client assertion may name the token endpoint.** A new 13.1 install accepts only its issuer as the
audience of a client assertion (draft RFC 7523bis); an archive upgraded from 13.0 keeps accepting the token
endpoint URL, and the results below were first measured on one. The suites' ordinary clients - the SSF
receiver, the federation OP plan's relying party at the token endpoint - name the token endpoint, as OpenID
Connect Core §9 says to, and on an archive authored fresh on 13.1.3 the SSF plan failed 18 of 19 modules at
the token endpoint. `config-store/org.sourceid.oauth20.domain.AuthzServerManagerImpl.xml` turns the check off,
overlay and archive like the cipher list, and `tools/profile.py author` refuses an archive without it. The FAPI 2.0 clients
are still held to their issuer by the filter below, and a federation RP's assertion at PAR by the
front-channel registration filter. That is a rig's choice, made for one suite: a production PF should have
the check on - see the pf-integration README.

**Two FAPI 2.0 rules are enforced by a filter, not by PingFederate.** 13.1.3 accepts an RS256-signed
DPoP proof where the profile says PS256, ES256 or EdDSA, and cannot be told otherwise: its algorithm list
is a constant (`DpopUtil`, read with `javap` 2026-09-26). The profile says a client assertion's audience is
the issuer alone, as a string; 13.1's one control for that, `Rfc7523bisCompliantAudienceVerification`, is
for the whole server - off here, above - and counts audience values, so even on it lets a one-element
array through. (13.0.3 had neither: it accepted the token endpoint, the PAR endpoint or an array as an
audience.) This repo's `Fapi2ProfileFilter` enforces both rules for the clients `OIDF_FAPI2_CLIENTS`
names, which is the two FAPI clients and deliberately not `*`: the suite's SSF client is an ordinary
OAuth client that addresses its assertion to the token endpoint, and with the rules applied to everyone
the SSF plan went from 19 of 19 to 1 of 19.

**CIBA has an authentication device that is a directory.** PingFederate implements CIBA itself, but
the only out-of-band authenticator it ships wants a PingOne tenant and a phone. `plugins/ciba-sim` is
the stand-in: an `OOBAuthPlugin` that answers `IN_PROGRESS` until an operator has recorded `allow` or
`deny` at `POST /ciba-sim/decision?auth_req_id=...&action=...` - the shape the suite's
`automated_ciba_approval_url` takes - and then `SUCCESS` or `FAILURE`. Nothing is approved by default or
by time: the suite polls the token endpoint expecting `authorization_pending` before it decides, and two
modules never decide. The plugin and the servlet are two classloaders in PF, so the handoff is a file
named by the SHA-256 of the `auth_req_id` (`OIDF_CIBA_SIM_DIR`). The endpoint is an approval oracle
keyed by that id alone, so it answers 404 - and the plugin refuses every transaction - unless
`OIDF_CIBA_SIM_ENABLED=true`, `OIDF_DEPLOYMENT_PROFILE=development` and `OIDF_CIBA_SIM_DIR` is a private
directory both halves check before every request (plugins/ciba-sim);
the rig's profile sets all three because this is a rig, and the jar is only in an image built for the conformance
profile, which `docker-compose.yml` asks for and `up.sh` stages. `tools/profile.py author` stages the jar into the
authoring PF, which is why `up.sh` builds before it authors: `deploy/terraform/modules/ciba` can only instantiate
a plugin PF can see.

**Three more small filters close what the FAPI-CIBA plan measures and PF does not do.** The signed
request object's `exp`/`nbf` window is 720 minutes in 13.0.3 and 13.1.3 alike - compiled in, with no file
shipped for it - and the profile wants 60: a config-store file
(`org.sourceid.openid.ciba.handlers.CibaHelper.xml`, overlay and archive like the cipher list).
UserInfo, the one resource PF serves itself, sends no `x-fapi-interaction-id` and accepts
`?access_token=`, both of which FAPI 1.0 Baseline §6.2.1 forbids: `FapiResourceServerFilter`, which from 0.6.0 holds
only the clients `OIDF_FAPI2_CLIENTS` and `OIDF_FAPI_RESOURCE_CLIENTS` name - the rig's profile puts the FAPI-CIBA clients
on the second. And a
refused request object's `error_description` is jose4j's whole explanation with a Java-formatted date
in it - U+202F, the narrow no-break space, before "PM" - which RFC 6749 §5.2's character set excludes:
`OAuthErrorDescriptionFilter` brings a 4xx's description inside the set and touches nothing else.

**13.1.3 is the base, and it is `jakarta.servlet`.** The modules moved with it (0.2.0;
docs/pf-13_1-jakarta-migration-plan.md); the version is
pinned in `build/pf-version.env`. Two things that were true of 13.0.3 still are: it has no
certificate-bound access tokens, and it accepts RS256 on a DPoP proof. 13.1 does add
`Rfc7523bisCompliantAudienceVerification`, on for a new install and off on an upgraded archive; the rig
sets it off (above), and `Fapi2ProfileFilter` keeps the audience rule for the FAPI clients whatever it is
set to, because the switch is server-wide.

## What the suite says, and what it does not

Against a PF built this way, driven by a suite run locally at release-v5.3.1:

| Plan | Variant | Result |
|---|---|---|
| `openid-ssf-transmitter-test-plan` | discovery, `private_key_jwt` client credentials, poll | 19 of 19 PASSED (again 2026-09-25, on an archive authored fresh on 13.1.3 - 1 of 19 before the audience overlay below; again 2026-09-27, 0.4.0, plan `TVdQER0yiGTQv`; again 2026-09-29, 0.5.0, plan `B1C32vlq6eNRb`; again 2026-10-01, 0.6.0, plan `akGNhQiuPsDqZ`; again 2026-10-08, 0.7.0-SNAPSHOT through the licensed driver, plan `C0hwfXvLPeYeH`; again 2026-10-08 on the self-hosted Linux runner, licensed run 37813420288 at `d9099491`, plan `IacjJxD5Bhmc4`) |
| `openid-ssf-transmitter-caep-test-plan` | the same, under the CAEP Interop Profile - the plan the Foundation certifies SSF against | 13 of 13 PASSED (2026-09-23 local replica, 2026-09-24 the public rig; needs the `/ssf/events:emit` servlet, `SsfEventEmitServlet`, on `main` as `d4a4219`; on 13.1.3 first on 2026-09-27, 0.4.0, plan `3qTCDGKygzp7l`; again 2026-09-29, 0.5.0, plan `af5vHGFKhJWPs`; again 2026-10-01, 0.6.0, plan `dhENYk4JorcZg`; again 2026-10-08 through the licensed driver, plan `5VOnMB1Go4G7B`; again 2026-10-08 on the self-hosted Linux runner, licensed run 37813420288 at `d9099491`, plan `ZctEfjVTOxGty`) |
| `fapi2-security-profile-final-test-plan` | `private_key_jwt`, DPoP, `plain_fapi`, OpenID Connect | 56 modules: 50 PASSED, 3 REVIEW, 2 WARNING, 1 SKIPPED, 0 FAILED (2026-09-24, on 13.1.3; 49/4 on 13.0.3; the same on 2026-09-25 on an archive authored fresh on 13.1.3, on 2026-09-27, 0.4.0, plan `yYAIcz8TxHXIS`, on 2026-09-29, 0.5.0, plan `FTWRpvoSNQpNQ`, and again 2026-10-01, 0.6.0, plan `wk3glGDks0jHK`, and 2026-10-08, 0.7.0-SNAPSHOT through the licensed driver, plan `ZOVeDQOm9b93I`; again 2026-10-08 on the self-hosted Linux runner, licensed run 37813420288 at `d9099491`, plan `dR1OYVZ5GDqUy`) |
| `fapi-ciba-id1-test-plan` | static clients, `private_key_jwt`, poll, `plain_fapi` | 35 modules: 32 PASSED, 3 FAILED (2026-09-24, on 13.0.3 and 13.1.3 alike; the same three on 2026-09-27, 0.4.0, plan `LJh9GLh6lZxGk`, on 2026-09-29, 0.5.0, plan `Elp3NOJhYaiLs`, and again 2026-10-01, 0.6.0, plan `5ICcGR0S3jp6u`, and 2026-10-08, 0.7.0-SNAPSHOT through the licensed driver, plan `wfaRWE9dSuRN7`; again 2026-10-08 on the self-hosted Linux runner, licensed run 37813420288 at `d9099491`, plan `Y5ndZrM35n5pH`) - all three on one PingFederate 13.x product gap, below |
| `openid-federation-deployed-entity-test-plan` (alpha) | discovery, automatic; `PF_PROFILE=federation`, PF its own trust anchor | 5 modules: 5 WARNING, 0 FAILED (2026-09-25, 13.1.3; again 2026-09-27, 0.4.0, plan `rOAmA0sPt7hqd`; again 2026-09-29, 0.5.0, plan `ZM7mLEPCPKzIN`; again 2026-10-01, 0.6.0, plan `1eliSBjpV6dWh`; again 2026-10-08 through the licensed driver, plan `12mHRNh2retpZ`; again 2026-10-08 on the self-hosted Linux runner, licensed run 37813420288 at `d9099491`, plan `jSIc8mVNtL4X1`) - the warning is PF's vendor metadata, below |
| `openid-federation-entity-joined-to-test-federation-op-test-plan` (alpha) | discovery, automatic; `PF_PROFILE=federation-op`, the suite from `suite/suite-compose.yml` | 20 modules: 20 WARNING, 0 FAILED (2026-09-25, 13.1.3; again 2026-09-27, 0.4.0, plan `vy3fs94kYLVp3`; again 2026-09-29, 0.5.0, plan `rAaWZBJDj5VW0`; again 2026-10-01, 0.6.0, plan `SD8FBsZaFQwcJ`; again 2026-10-08 through the licensed driver, the suite on the rig's network, plan `Dx3sa49yVsE3I`; again 2026-10-08 on the self-hosted Linux runner, licensed run 37813420288 at `d9099491`, plan `KfMuRBiyabsfV`) - the same warning; the 13 negative modules attach PF's refusal page |

The 2026-09-27 runs are 0.4.0's: a rig built from the release branch (`PF_RIG_NAME=pfai-rel`, its modules built at
`714e7ce`, PingFederate 13.1.3.0 by its admin API) against this directory's own suite, `suite/suite-compose.yml`, on
port 51643. A suite whose origin is not one of the profile's `conformance.suite_base_urls` needs it added before
authoring, or most FAPI 2.0 modules fail at their first step, PAR (`CheckPAREndpointResponse201WithNoError`, "Invalid
pushed authorization request endpoint response http status code" - most likely PingFederate refusing the suite's
redirect URI, which that run did not read from its answer): `TF_VAR_suite_base_urls='["https://www.certification.openid.net","https://host.docker.internal:51643"]'`
did it here (the rig then took Terraform variables from the environment), and the first FAPI 2.0 run, made without it, failed 37 modules that way (plan `NUqXtDeHzKzcl`).

The 2026-09-29 runs are 0.5.0's: a rig built from its release branch (`PF_RIG_NAME=pfai-rel5`, 13 module jars staged
for the conformance profile at `40fabb8`, whose code is `main` at `4b1fd97`; PingFederate 13.1.3.0 by its admin API)
against the same suite on port 51643, authored with that origin in `suite_base_urls` from the start. Every result is
0.4.0's.

The 2026-10-01 runs are 0.6.0's (2026-10-01 AEST, 2026-09-30T21:04Z-21:37Z UTC): a rig built from `main` at
`600fa6b5`, the release's code (`PF_RIG_NAME=pfai-rel6`, slot 1: `PF_PORT_HTTPS=31031`; 14 jars staged for the
conformance profile - the 13 module jars and `pf.plugins.ciba-sim.jar` - with a MANIFEST naming `600fa6b5127a`;
PingFederate 13.1.3.0 by its admin API) against `suite/suite-compose.yml` on port 51743, authored with that origin in
`suite_base_urls` from the first authoring, and with the rig's environment as committed (then `vars.env`): federation, automatic registration and
attestation authentication `*_ENABLED=false`, `OIDF_FAPI_RESOURCE_CLIENTS` naming the CIBA clients. The FAPI 2.0 plan
ran from a `fapi2.json` rendered at that run from the current template. The two federation plans ran on a second rig,
`pfai-rel6-fed` on slot 2 with the same modules, with `PF_PROFILE=federation` and then `PF_PROFILE=federation-op`,
both with `OIDF_FEDERATION_ENABLED=true`. Every result is 0.5.0's: no module regressed and none improved. Run the plans
one at a time: a first pass that started a second plan while one was running was interrupted by the suite, which
stops a running test when another starts under the same alias (FAPI 2.0 plan `3AWmYPRVHlOHk` ended with 3
INTERRUPTED), and was discarded.

The runs on the self-hosted runner are 0.7.0's code: licensed run
37813420288, dispatched on `main` at
`d9099491` on 2026-10-08 (17:25Z-18:21Z), the image built from that commit on PingFederate 13.1.3's base image, each
plan through `tools/ci/licensed-conformance.sh` against its `expected/<entry>.json` under `--strict-expectations`, one at
a time on the Lima VM (6 CPUs, 12 GiB). Every result is 0.6.0's: no module regressed and none improved. The code the
v0.7.0 tag carries is `d9f7892c`, which adds to it C7's cluster suite, the reference stacks' Linux fixes, the entrypoint's refusal of an unreadable archive and the SSF store's start-up line (F-0125: 21 lines in three SSF classes, no behaviour the plans test); the release's own licensed run is in the 0.7.0 notes' "What we verified".

Expect, and do not be alarmed by, in the FAPI 2.0 plan:

- **WARNING** on discovery - PF publishes vendor metadata the suite does not know.
- **WARNING** on authorization-code reuse - PF refuses the second use, as required, but does not also
  revoke the token the first use produced, which the profile only says it should.
- **REVIEW** on three `request_uri` modules - PF answers a reused, expired or foreign `request_uri`
  with an HTTP 400 error *page*, not a redirect. The suite accepts a picture of the page and asks a
  person to look at it. (A fourth was REVIEW on 13.0.3, which spent a `request_uri` when the
  authorization page was loaded rather than when the user authorized; 13.1.3 follows FAPI 2.0
  §5.3.2.2 NOTE 3 and that module now PASSES.)
- **SKIPPED** on the claims-parameter module - not supported, not advertised, so not tested.

The OP plan's first runs found four things, all fixed: an RP already registered went unchecked on later
requests (PF dropped the module's undeclared extended properties, so the client no longer looked like a
federation client), an RP's later requests weren't held to §12.1.1.1, a token request renewed an RP registered
at the authorization endpoint in an agent's shape, and PF 13.1 refuses the token endpoint as a client
assertion's audience. Each is in the commit that fixed it.

In the federation plans, each module warns once, on the `oauth_authorization_server` block of PF's entity
configuration: it carries PF's own discovery document, and the suite doesn't know PF's `ping_*` endpoints,
its identity-chaining (ID-JAG) parameters or the attestation draft's `client_attestation_pop_methods_supported`.
The same plan, before the entity configuration carried PF's discovery document, failed all five modules on
the `openid_provider` block: no `jwks_uri`, `response_types_supported`, `subject_types_supported` or
`id_token_signing_alg_values_supported`, which OpenID Connect Discovery requires. `render.sh` tells the suite
the anchor keys by reading them from PF's own entity configuration - fine for a rig, where the point is what
PF does with them; a real relying party pins them from somewhere it trusts.

And for FAPI-CIBA, three **FAILED** modules that no configuration and no filter can turn, because
FAPI-CIBA profiles CIBA over FAPI 1.0 Advanced, whose resource servers "shall only support
sender-constrained access tokens via MTLS" - certificate-bound tokens, RFC 8705 §3, `cnf.x5t#S256`.
PingFederate 13.0.3 has no such thing, and neither does 13.1.3: every jar of both was searched for the
claim, for `mtls_endpoint_aliases` and for `tls_client_certificate_bound_access_tokens`, and none of
them is there (DPoP is the one sender-constraint it implements). So `discovery-end-point-verification`
fails on the missing metadata flag, `ensure-mtls-holder-of-key-required` on a token issued without a
certificate, and the happy path `fapi-ciba-id1` on its "client1's TLS cert with client2's access token"
step, which expects a refusal the server cannot make. A certification of this plan is not available
on PingFederate 13.x; the other 32 modules say the rest of CIBA is right.

None of that is a certification. A run that counts is made on the hosted suite, by a person who is
signed in, against a PF the suite can reach. SSF **push** delivery has not been run at all: it needs a
suite PF can call back, which a suite on localhost is not (the servlet's outbound policy refuses
loopback, rightly). CIBA's ping mode is one more thing only the hosted suite can test: PF has to call
the suite's notification endpoint back, the client carries ONE such endpoint, and `ciba.tf` registers
the hosted suite's (`ciba_notification_suite_base_url`). Author with `-var ciba_delivery_mode=PING`,
re-export, and run the ping plan against that image.

## Testing it

**In CI**, `.github/workflows/licensed.yml` runs the seven plan runs below, weekly and before a release, one at a time on
the self-hosted runner that holds the licence (docs/development/ci-runners.md, "Licensed jobs"). Each entry is
`tools/ci/licensed-conformance.sh <entry>`, which runs the same way on any machine with Docker and your licence
details: this rig built with the entry's profile, `suite/suite-compose.yml`'s suite on the rig's network (PF is
`https://<rig name>:9031`, the suite's nginx answers to `host.docker.internal:8443`, so the suite's redirect URIs and
entity identifiers reach it from either container, on Linux as on Docker Desktop), `render.sh`, and `run-plan.py`
against `expected/<entry>.json` with `--strict-expectations`. The entries are `fapi2-security-profile-final`,
`fapi-ciba-id1`, `ssf-transmitter`, `ssf-transmitter-caep`, `federation-deployed-entity` (`PF_PROFILE=federation`)
`federation-op` (`PF_PROFILE=federation-op`) and `fapi2-attestation` (`PF_PROFILE=fapi2-attestation`, with a suite
built from the release and a patch, below), with the variants below. Beside another rig, `PF_RIG_SLOT=<n>`
gives this one a slot's name and ports, as it does for `up.sh`; the suite keeps 8443, so one run at a time per machine.

`expected/<entry>.json` lists the failures a run of that plan is known to have, each with the reason below: `[]`
where nothing fails, and FAPI-CIBA's three on PingFederate 13.x's missing certificate-bound tokens. To remake one,
`tools/ci/licensed-conformance.sh <entry> --write-expected` runs the plan without expectations and writes every
FAILURE and WARNING of each failed module, each with a `why` to fill in from this README; a failure this README does
not explain is a finding, not an expectation.

`suite/render.sh` turns `suite/*.template.json` into the configurations a suite wants, with the
clients' private keys and the test user's password filled in. The rendered files are git-ignored.

**Against a suite you run yourself** (the suite's own `docker compose`, dev mode, no login; it is on
`https://localhost.emobix.co.uk:9643` by default), `suite/run-plan.py` creates the plan, runs every
module and prints each failure's condition and message. A suite on any other origin must be in `suite_base_urls`
when the rig is authored, or PF refuses every redirect (the profile's `conformance.suite_base_urls`, as in the results above):

```sh
suite/render.sh

suite/run-plan.py https://localhost:9643 openid-ssf-transmitter-test-plan suite/ssf-transmitter.json \
  --variant ssf_server_metadata=discovery ssf_delivery_mode=poll ssf_auth_mode=dynamic ssf_profile=default \
            server_metadata=discovery client_registration=static_client client_auth_type=private_key_jwt

suite/run-plan.py https://localhost:9643 fapi2-security-profile-final-test-plan suite/fapi2.json \
  --variant client_auth_type=private_key_jwt sender_constrain=dpop fapi_profile=plain_fapi openid=openid_connect

# FAPI-CIBA, poll mode; the ciba-sim plugin is the "user" and the suite tells it allow or deny
suite/run-plan.py https://localhost:9643 fapi-ciba-id1-test-plan suite/fapi-ciba.json \
  --variant client_auth_type=private_key_jwt ciba_mode=poll fapi_ciba_profile=plain_fapi client_registration=static_client

# OpenID Federation, PF deployed as its own trust anchor (PF_PROFILE=federation). render.sh reads the
# anchor keys the suite is told about from PF's own entity configuration, so it needs PF up first -
# PF_LOCAL_URL says where, when the issuer is host.docker.internal
PF_LOCAL_URL=https://localhost:49031 PF_BASE_URL=https://host.docker.internal:49031 suite/render.sh
suite/run-plan.py https://localhost:9643 openid-federation-deployed-entity-test-plan suite/federation-deployed-entity.json \
  --variant server_metadata=discovery client_registration=automatic

# OpenID Federation, PF as an OP in the suite's own federation (PF_PROFILE=federation-op), against a suite
# whose certificate PF trusts - this directory's own, on 49643 here
SUITE_PORT=49643 docker compose -f suite/suite-compose.yml -p pfai-suite up -d
PF_RIG_NAME=pfai-fed PF_PROFILE=federation-op SUITE_PORT=49643 PF_PORT_HTTPS=49031 PF_PORT_HTTP=49080 \
  PF_PORT_ADMIN=49999 PF_AUTHOR_ADMIN_PORT=48999 PF_AUTHOR_RUNTIME_PORT=48031 PF_BASE_URL=https://host.docker.internal:49031 ./up.sh
PF_BASE_URL=https://host.docker.internal:49031 suite/render.sh
suite/run-plan.py https://localhost:49643 openid-federation-entity-joined-to-test-federation-op-test-plan suite/federation-op.json \
  --variant server_metadata=discovery client_registration=automatic

# the CAEP Interop plan: its last module waits for the operator, and the hook is the operator
suite/run-plan.py https://localhost:9643 openid-ssf-transmitter-caep-test-plan suite/ssf-transmitter.json \
  --variant ssf_server_metadata=discovery ssf_delivery_mode=poll ssf_auth_mode=dynamic \
            server_metadata=discovery client_registration=static_client client_auth_type=private_key_jwt \
  --on-log-marker "Please trigger these events on the transmitter now" \
  --hook "suite/trigger-caep-events.py"
```

`--save-logs DIR` keeps every module's full log, as the suite's `/api/log/<id>` returns it, in
`DIR/<plan id>/<module>.json`, with `DIR/<plan id>/plan.json` holding the plan, its variant, each module's result and
when it ran; the directories are made mode 700 (`.runs/` here is git-ignored for them). A log holds tokens, client
assertions and PingFederate's answers: `tools/ci/licensed-scrub.py --tokens` takes them out, and the licensed job runs
it before it keeps anything. `tools/suite-log-ids.py DIR` then reads the saved logs and compares the requirement ids
the suite logged with the `@Requirement("OIDFED §...")` tags our tests pin - exercised and pinned, exercised and not
pinned, pinned and not exercised; `--check` fails on an id exercised and not pinned that `suite-log-ids.json` does not
explain with a `why`.

The hosted-agent walk is `services/harness`'s `FederationSmokeHarness live https://localhost:<port>` against this rig
under `PF_PROFILE=federation` with `PF_HARNESS=1` (its README): enrol a self-signed
agent, publish, fetch, resolve, register at the token endpoint, suspend, reactivate, re-key, revoke and wait for the
sweeper. `PF_HARNESS=1` lays `profiles/conformance-federation-harness.yaml` over the profile (PF the authority, the operator
API, a three-minute registration lifetime, the operator client in `features.federation.operator_api.client`); without it the federation profiles are exactly
what the conformance plans were pinned on. `PF_EXTRA_VARS` names one more file, for an authority database
(`OIDF_AUTHORITY_JDBC_URL` and its user and password, migrated with `tools/db-migrate`).
`live --client-auth-model` under `PF_PROFILE=federation-op` reads a registered relying party back (U-0004).

A suite running in a container cannot reach this machine's `localhost`. Author with an origin it can
reach and that PF can advertise - `PF_BASE_URL=https://host.docker.internal:9031 ./up.sh` - so the
issuer in discovery and the address the suite dials are the same string. If 9031, 9080 or 9999 are
taken on this machine, `PF_PORT_HTTPS` / `PF_PORT_HTTP` / `PF_PORT_ADMIN` move the host side and the
default issuer follows.

`--expected FILE` lets a run pass with failures that are known and written down: each entry names the
module, the condition that fails and why. A module that fails counts as `EXPECTED` only when every
failure and warning in its log is listed; `--strict-expectations` also fails a run in which a listed
failure didn't happen, so a fix gets recorded as one.

`trigger-caep-events.py` takes the emitter client's secret from `secrets.env` and PF's origin from
`--base`, or else `PF_BASE_URL`, or else `https://localhost:$PF_PORT_HTTPS` as `up.sh` defaults it. It exits non-zero if any of the three events reached
no stream. It needs the `/ssf/events:emit` servlet (`SsfEventEmitServlet` in `servlets/ssf`).

**Against the hosted suite**, for a run that counts: sign in at certification.openid.net, create the
plan with the same variants, and paste the rendered configuration. The redirect URIs for both suites
are already registered (`suite_base_urls`). The suite drives PF's login and consent pages itself; the
`browser` block's selectors are the ids in PF's stock `html.form.login.template.html` and
`oauth.approval.page.template.html`, and restyling those pages means changing the block.

## The RAR plugin on this rig

The image carries no RAR plugin. `verify-rar-principal.sh` lends the rig one for a run: it starts `up.sh` on
its own slot (`PF_RIG_NAME=pfai-rar` by default) with `docker-compose.rar-plugin.yml` mounting the jar, runs
`rar-principal/stub-pdp.py` on the host as an AuthZEN PDP that permits and records every request, configures a
processor instance, the three built-in types, a token-exchange policy and a client through the admin API,
drives client credentials, CIBA, refresh, token exchange and the code flow, prints per flow the user key
PingFederate passed and the `principal_source` the plugin chose, and takes the rig down, image included.
`OLD_PLUGIN_JAR=<an older release's jar>` first rehearses the upgrade from it. The evidence lands in
`.rar-principal/` (git-ignored); the plugin's README records what the
runs showed.

## Overlays

| Overlay | What it adds | Driven by |
|---|---|---|
| `docker-compose.rar-plugin.yml` | the RAR plugin's jar, mounted into the rig's PingFederate | `verify-rar-principal.sh` (above) |
| `docker-compose.spire.yml` | SPIRE Server 1.15.3 (sqlite, join-token node attestation, trust domain `rig.example`, the reader's reference policy), one SPIRE agent (unix workload attestor), the SPIRE entry reader from its image, and a one-shot workload that fetches a JWT-SVID | `spire/smoke.sh` |

**SPIRE beside the rig.** `spire/smoke.sh` brings the overlay up from nothing on the rig's compose project
(`PF_RIG_NAME`, as `up.sh` names it), since the agent needs two things that exist only once SPIRE Server runs - its
trust bundle and a join token. `spire/gen-certs.sh` makes a throwaway CA pair, the reader's server certificate and
two client certificates under `.spire/` (git-ignored). The script then creates two entries for one SPIFFE id with
SPIRE's CLI, reads them through the reader over mutual TLS inside the compose network, shows a client whose key is not
pinned refused with 403, fetches a JWT-SVID for the attester's issuer (`SPIRE_RIG_AUDIENCE`, default
`https://localhost:9031`), and shows the policy refusing an entry create from the reader's image while letting it
count. `SPIRE_RIG_POLICY=off` runs the server without the policy (`spire/server-open.conf`) and skips that
step. It publishes no port. `--keep` leaves it running and `--down` removes only its services and volumes. It builds
the reader's image from `services/spire-entry-reader` (after `mvn -pl services/spire-entry-reader -am -DskipTests
package`) unless `SPIRE_READER_IMAGE` names one. CI's image job runs it on every pull request. PingFederate's side -
its client certificate from `.spire/ca/client-ca`, the pin in `.spire/reader.env`, the attestation client - is B08's.

## The attester's transit signing key on this rig

`docker-compose.attester-keys.yml` (plan item X-B04) adds an OpenBao dev server with one `ecdsa-p256` transit key,
`attestation-es256`, switches the attester on, and lists that key in `OIDF_ATTESTER_SIGNING_KEYS` for
`https://attester.example.com`, so the key-ref rules are the production ones. The conformance-clients module adds one
PingFederate-store client, `conformance-attester-transit`, that names the key, when the root's `conformance.attester`
(`signing_key_ref`, `spiffe_bundle`) is set at author time; unset, the rig authors what it always did. `up.sh` sets it
from `TF_VAR_attester_signing_key_ref` and `TF_VAR_attester_spiffe_bundle`, and passes `TF_VAR_attester_client_secret`
on as the client's secret. The overlay's header has the command, and how to rotate the key during a run: the
attester signs with the new version, under a new `kid`, within the 60 s refresh it sets. REL5 runs it licensed.

## The attestation events over SSF on this rig

`verify-attestation-events.sh` (feature 206, story #339) shows a SOC receiver's stream hearing each attestation event
once per thing that happened, from a booted PingFederate. It boots the rig on slot 38 with the transit-key overlay above,
the agent registry and the SSF tables store on a throwaway PostgreSQL 16, and `OIDF_SSF_REFUSAL_RECEIVERS` naming
`conformance-ssf-receiver`. The attestation client's SPIFFE bundle is a JWKS the script makes, so it signs its own
JWT-SVIDs, and no SPIRE runs. Then, through `services/harness`'s `AttestationEventsHarness`:

1. As `conformance-ssf-receiver`, it creates a poll stream requesting the four event types. The stream is flagged for
   refusals, so `events_delivered` names all four.
2. It drives the events: one attestation, then one request whose proof is signed by another key (refused after the
   evidence matched the client). It rotates `attestation-es256` in OpenBao, waits past the 60 s refresh, and makes a
   second attestation for the same agent, signed under the new `kid`.
3. It polls the stream and checks every SET's signature against the transmitter's `jwks_uri`. It expects one
   `instance-registered` about the `agent_id`, one `attestation-issued` per attestation (`renewal` false, then true),
   one `attestation-refused` (`proof_rejected`, about the client) and one `attester-key-rotated` from the old `kid` to
   the new, and nothing else.

```sh
JAVA=<a JDK 17+ java> conformance/verify-attestation-events.sh    # KEEP_RIG=1 leaves the rig and the database up
```

It writes the SETs to `.attestation-events/sets.jsonl`, and PingFederate's `server.log` beside them. The same run on two
nodes, each event once with no duplicates, needs the attestation issuer on `reference/cluster`, which keeps it off
until [F-0601](../docs/findings.md#f-0601) is closed. Until then, the replay keys that make it hold are tested on
PostgreSQL with two nodes in-process: `JdbcAgentRegistryTest`, `DeviceInstanceRegistrationsOnPostgresTest` and
`AttesterKeyRotatedSetOnPostgresTest`.

## The FAPI 2.0 plan with client_attestation

`PF_PROFILE=fapi2-attestation` (plan item X-E09) is the FAPI 2.0 rig plus two clients the suite authenticates by
`attest_jwt_client_auth`, `conformance-fapi2-attest-client1` and `-client2`, with the suite as their attester. It is
`profiles/conformance-fapi2-attestation.yaml`: attestation auth on, and the two clients registered as
`private_key_jwt` with a bridge key (`keys/fapi2-attest-client1`, `-client2`) and `attestation_required`.
`ClientAttestationAuthFilter` verifies the suite's attestation and PoP and forwards an assertion signed with the
client's bridge key. `up.sh` lays `docker-compose.fapi2-attestation.yml` over the rig, which mounts the two files
`gen-keys.sh` derives for it: the suite's attester key, trusted directly through the development-only
`oidf.mock.attesters`, and `OIDF_BRIDGE_SIGNING_KEYS`, which binds both clients to that attester. The attester's key,
`keys/suite-attester`, is EC P-256 with a self-signed certificate in `x5c`, which the suite requires.

No suite release offers `client_attestation` with the `plain_fapi` profile, only with the VCI ones. So the plan runs
against `release-v5.3.1` with one local patch (plan item X-E09), drafted as a merge request for the suite but not yet submitted; it stays out
of the public tree. The patch does three things:

- It offers the variant.
- It makes the suite retry a PAR or token request answered `use_attestation_challenge` exactly once, on every route
  where the plan sends a PoP. PingFederate spends an attestation challenge when a PoP presents it, and returns a fresh
  one only with that error. draft-ietf-oauth-attestation-based-client-auth allows this (§8.1: the server MAY return one
  on any response). Without the retry, the suite re-presents the challenge it has already spent, and 31 of the 46
  modules failed. U-0766 records the decision to fix this in the suite, not in PingFederate.
- It accepts `expires_in` in the challenge response.

`tools/ci/build-patched-suite.sh` builds the image from the pinned release and the patch. `licensed-conformance.sh
fapi2-attestation` calls it when `SUITE_IMAGE` is unset.

PingFederate's challenge endpoint allows one caller 60 challenges a minute (`challengeRateLimitPerWindow`). The
challenges it puts on refusals count towards that limit. Run back to back from the suite's single address, the plan
went over it, so the entry waits 8 seconds between modules (`run-plan.py --pause`).

No module fails (`expected/fapi2-attestation.json` is empty). `fapi2-security-profile-final-refresh-token` refreshes
with an attestation for a new client instance key and expects a refusal. PingFederate gives one only because it binds
refresh tokens to the instance key (`OIDF_ATTESTATION_REFRESH_BINDING`, on by default; F-0767, X-E15). Before that, the
refresh got new tokens and the module failed.

```sh
PF_PROFILE=fapi2-attestation PF_BASE_URL=https://host.docker.internal:9031 ./up.sh
SUITE_IMAGE="$(../tools/ci/build-patched-suite.sh | tail -1)" SUITE_PORT=49643 \
  docker compose -f suite/suite-compose.yml -p pfai-suite up -d
suite/render.sh
suite/run-plan.py https://localhost:49643 fapi2-security-profile-final-test-plan suite/fapi2-attestation.json \
  --variant client_auth_type=client_attestation sender_constrain=dpop fapi_profile=plain_fapi openid=openid_connect \
  --pause 8 --expected expected/fapi2-attestation.json
```

The suite's origin has to be in the profile's `suite_base_urls` (`TF_VAR_suite_base_urls`, above). `licensed.yml` runs
the entry with the others.

## What is not in git, and must not be

`.author.env`, `keys/`, `secrets.env`, `data*.zip`, `overlay/`, `suite/*.json`, `.context/`,
`.rar-principal/`, `.spire/`, terraform state. A config archive is a plain zip that contains `pf.jwk`, the master key that decrypts
every secret in it, beside the admin password hash. This directory ships it in plaintext into the
image, which the build warns about loudly and correctly. That is tolerable for a
PF whose key was generated minutes ago and protects three public JWKS and two generated secrets, and
for nothing whose master key protects anything real; `tools/profile.py author --age-recipient` encrypts one that does.
