# Logging

Where the lines this repository writes land in a PingFederate built from it, what each line carries so that it can be
followed back to one request, which reference a caller is given when it is refused, how to change what is logged, and
the line a war writes as it stops. From 0.7.0 (plan item O-6).

## Where the lines land

Every line the shipped modules write goes through one logger, libs/platform's `PlatformLog`
(platform README, "Logging"). Inside PingFederate it writes through
commons-logging, which `server/default/lib` routes to log4j (`log4j-jcl.jar`), so each line reaches PingFederate's
`server.log` at its own level, in PingFederate's own pattern. That holds for every place the code runs:

| Where | Before 0.7.0 | From 0.7.0 |
|---|---|---|
| `pf-runtime.war`, `oidf.war`, the engine's copy in `server/default/deploy` | commons-logging, in 93 classes, and `PlatformLog` in the rest | `PlatformLog` |
| The RAR plugin (`pf.plugins.pf-rar-paz-plugin.jar`) | `java.util.logging`: every line in `server.log` as `ERROR [SystemErr]`, whatever its level (F-0075) | `PlatformLog`, its relocated copy: `INFO`, `WARN` and so on, under the class's own name |
| `gm-api.war` | `java.util.logging`, the same `ERROR [SystemErr]` (F-0520) | `PlatformLog` |

`tools/log-scan.py` holds the shipped code to that in CI: commons-logging, `java.util.logging`, `System.Logger` and
log4j are refused outside `platform.log`, except where `tools/log-allow.txt` says why (PingFederate's audit columns, the
SSF bridge's appender on PingFederate's audit logger).

## What each line carries

PingFederate 13.1.3's stock `server.log` pattern is `%d %X{trackingid} %-5p [%c] %m%n` (its `log4j2.xml`, read on the
rig on 2026-10-06): the tracking id, and nothing else of the request. From 0.7.0 the image ships a copy of that file
whose `server.log` pattern alone differs: `%d %X{trackingid} %X{httprequestid} %-5p [%c] %m%n`, so every line,
PingFederate's own included, prints the request id (F-0395; `build/pingfederate/Dockerfile` fails the build if the stock
pattern ever changes). A server profile's own `log4j2.xml` replaces it. Every line this repository writes also ends
with the ids its thread has, whatever the pattern:

```
2026-10-06 09:17:23,137  INFO  [com.pingidentity.ps.oidf.servlet.trustanchor.FederationErrors] Federation endpoint refused a request: ref=0PDzPzzMSplZwG5bzQ9KCRFit status=404 ... ctx[rid=0PDzPzzMSplZwG5bzQ9KCRFit traceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-5b1e0d6c8a2f4e31-01]
```

| Field | What it is | Where it comes from |
|---|---|---|
| `tid` | PingFederate's tracking id, `tid:` and a hash of the session's id | PingFederate's endpoint code, which sets it after this repository's filters have run: on the rig (2026-10-06) it was absent before the chain at the token, PAR and federation endpoints and present after it, and the RAR plugin sees it. At the token endpoint each request without a session had its own. On this repository's own threads, `oidf-<job>-<8 hex>` |
| `rid` | PingFederate's request id (`httprequestid`) | PingFederate's request filter, before any of ours: the value of the header PingFederate's `requestHeaderForCorrelationId` setting names (admin API `/serverSettings/generalSettings`), when the request sends one PingFederate accepts, else 25 random letters and digits. Set to `X-Correlation-Id` on the rig, a request sending `X-Correlation-Id: probe-corr-0001` had `rid=probe-corr-0001` |
| `traceparent` | The W3C Trace Context header | Ours: the one the request sent, when it is a valid version-`00` value or a higher version read as the Recommendation's versioning section says (sent on as `00`, its sampled flag kept), else one generated for it (`CorrelationFilter`, first of this repository's filters); on a background job, a new one per run |

A field the thread does not have is left out, and a line with none has no `ctx[...]`. Each value is cut to 64
characters of letters, digits and `:_-/.+=`, so a header cannot forge a line.

Every outbound call this repository makes (`OutboundHttp`) sends a `traceparent` with the request's trace-id and a new
parent-id - W3C Trace Context: "A vendor receiving a traceparent request header MUST send it to outgoing requests", and
the one mutation allowed is "Update parent-id". A thread with no trace sends a new one. PingFederate's audit lines
written through the SDK keep `traceparent` beside `trackingid`, `transactionid` and `httprequestid`.

### Printing the ids in the pattern instead

`OIDF_LOG_CORRELATION=off` (environment, or the system property `oidf.log.correlation`; the
[platform-log](../configuration/platform-log.md) catalogue) turns the suffix off, for a `log4j2.xml` that prints the ids
itself, for example:

```xml
<pattern>%d %X{trackingid} %X{httprequestid} %X{traceparent} %-5p [%c] %m%n</pattern>
```

The keys are log4j `ThreadContext` keys, so PingFederate's own lines print them too. Leave the suffix on (the default)
with PingFederate's stock pattern: it is the only place `rid` and `traceparent` appear.

## The reference a refusal gives

A refusal's response quotes a reference, and the log line that explains it carries the same one. From 0.7.0 it is
PingFederate's own id for the request:

1. the tracking id, when the thread has one (the RAR plugin, and anything after PingFederate's endpoint code);
2. else the request id - which is what this repository's filters see, since PingFederate sets the tracking id after
   them. With `requestHeaderForCorrelationId` set, it is the caller's own correlation id;
3. else `oidf-<16 hex>`, which only a thread off any request needs.

Every line this repository writes ends with `ctx[tid=.. rid=..]`, so the reference always finds ours, and the image's
`server.log` pattern prints `%X{httprequestid}`, so it finds PingFederate's own lines for the request too - which
PingFederate's stock pattern (`%X{trackingid}` only) did not, as a request refused at our filters never reaches the
endpoint code that sets a tracking id. On the rig (2026-10-06 19:02 UTC) an ID-JAG token exchange refused by
`IdJagDetailsFilter` answered `(reference 3FUbN5RCCf2w77Yq9pjozHulx)`, and `server.log`'s third column on the refusal's
lines read `3FUbN5RCCf2w77Yq9pjozHulx`. With a `log4j2.xml` of your own, add `%X{httprequestid}` to its `server.log`
pattern (and set `OIDF_LOG_CORRELATION=off` if you print `%X{traceparent}` too).

This applies to the OAuth refusals (`reference ...` in `error_description`), the federation endpoints' refusals
(`ref=`), the front-channel registration and pushed-details error pages, and the attestation issuer's
`X-Correlation-Id` header, which was a random UUID until 0.7.0.

## Levels

`INFO` is the default: PingFederate's `log4j2.xml` as shipped gives `com.pingidentity` `INFO` and the image changes
nothing (R-I3). `log4j2.xml` is the one control; this repository sets no level in code. The logger names:

| Logger | What |
|---|---|
| `com.pingidentity.ps.oidf` | everything this repository writes in PingFederate, by class: `com.pingidentity.ps.oidf.servlet...`, `com.pingidentity.ps.oidf.platform...`, `com.pingidentity.ps.oidf.rar...` (the RAR plugin) |
| `com.pingidentity.ps.oidf.<family>.event.<category>` | the catalogued events' lines, one logger per category ([federation operations, "Reading the logs"](../federation/operations.md#reading-the-logs)) |
| `au.com.idpartners.gm` | gm-api |

Lines that say a request succeeded, one per request, are `DEBUG` from 0.7.0: the RAR plugin's `RAR governance:` line
(it was `INFO`), and gm-api's `query`, `evaluate`, `MCP evaluate` and `MCP search` lines. Refusals, failures and
state changes stay at `INFO` and above. To see the RAR plugin's line again:

```xml
<Logger name="com.pingidentity.ps.oidf.rar.AttestationAwareRarProcessor" level="DEBUG"/>
```

PingFederate re-reads `log4j2.xml` every 30 seconds (`monitorInterval="30"`).

## The line a war writes as it stops

Each war's lifecycle listener writes two lines as it stops: one before it closes what its copy started (executors, the
metrics MXBean, Redis pools), and one after, naming how each close ended and any still running when the five-second
budget ran out.

Until 0.7.0 those lines never reached `server.log` (F-0210). On the rig (2026-10-06, `docker stop -t 30`) the listener
runs on `JettyShutdownThread` after PingFederate's own shutdown has begun, and by then the log4j context every logger
made at start-up belongs to is stopped - its configuration a `NullConfiguration`, `INFO` off - so a line through the
class's own logger is dropped. log4j has started a new context by then, which still writes `server.log` (PingFederate's
and Jetty's last lines go through it). From 0.7.0 the listener writes through a logger asked for at that moment, which
belongs to the running context; and if even that one is stopping or stopped, it appends the line to
`${pf.log.dir}/server.log` in PingFederate's layout and writes it to standard error, which `docker logs` shows.

```
2026-10-06 09:17:30,961 oidf-stop-3fa2c1d0 INFO  [com.pingidentity.ps.oidf.platform.pf.lifecycle.LifecycleListener] Lifecycle listener: / (ROOT) stopped; closed 2: ... ctx[tid=oidf-stop-3fa2c1d0 traceparent=...]
```

Start-up and shutdown run under their own tracking ids, `oidf-start-<8 hex>` and `oidf-stop-<8 hex>`, and each
background job's run under `oidf-<executor>-<8 hex>`.

## Secrets

No line carries a secret. `SecretInLogGuardTest`, in each shipped module, sets every catalogued `"type": "secret"`
setting to a canary, adds a client secret, a private JWK's `d`, a compact JWS, a DPoP proof and a bearer token, and
fails on any canary - or its base64url or base64 form - in any message or stack trace. Every module's test drives the
start-up audit over its catalogues and the shutdown lines. Debug lines are written while the guard runs, whatever the
level, and an exception a refusal throws is logged as a caller would log it, so one that echoes a credential fails too.

The modules that are handed credentials also drive their own refusals and failures with the canaries:

| Module | Paths driven |
|---|---|
| `platform` | its own test (testkit is built on it): every catalogue's refusals with each secret a URL carrying a password, and the Redis configuration's line |
| `platform-pf` | the production sweep and banner; the operator APIs' refusals (wrong static bearer, bearer where DPoP is required, a forged DPoP token and proof); the stop line |
| `pf-integration` | `Fapi2ProfileFilter`'s refusals on the token endpoint, with a client secret in `Authorization` and the form, a forged assertion, a private key in a JWS header and forged DPoP proofs |
| `rs-validation` | `ResourceServerFilter`'s refusals: a bearer where DPoP is required, a forged token and proof, a real token with a forged proof |
| `oidf-jose` | `DpopProofValidator` and `JwtCodec` refusing forged proofs and tokens |
| `client-attestation` | `ClientAttestationVerifier` refusing a forged attestation and proofs, an untrusted attester whose `cnf` carries a `d`, and a client secret where the attestation belongs |
| `ssf` | the receiver's introspection: an inactive bearer, an endpoint that fails echoing what it was sent, one that answers no JSON, and one nobody answers |
| `attestation-issuer` | the issuance endpoint's refusals and failures through `doPost`: an unknown client, a failing client store, a body that is not JSON |
| `rar-paz-plugin` | the processor's permit (its `DEBUG` summary), deny, an unreachable PDP failed open and closed, and a PDP that answered badly, with credentials in the detail's fields |
| `gm-api` | the token refusals reachable without a running PingFederate: a refused `act` carrying a bearer and a JWS, an absent token |

The rest - `openid-federation`, `shared-signals`, `agent-registry`, `device-instance`, `device-enrolment`,
`instance-registry-datasource`, `ciba-sim`, `rar-model`, `preflight` and `db-migrate` - are guarded on their start-up
and shutdown lines only; U-0521 tracks driving their refusals.
