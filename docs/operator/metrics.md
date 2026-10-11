# Metrics

`GET /agentic-identity/metrics` answers every metric this repository's code counts on one PingFederate node, in the
Prometheus text format, to a scrape with an operator token carrying `oidf.metrics.read` (plan item O-5, since 0.7.0).
This page says how to scrape it, what the `copy` label means, every family it renders and the alerts worth writing.

## The endpoint

- **Path.** `/agentic-identity/metrics` on PingFederate's runtime port (`pf-runtime.war`), and on gm-api's own port
  in `gm-api.war`, which serves its own. `MetricsServlet` in libs/platform-pf.
- **Methods.** `GET` and `HEAD`; anything else is `405` with `Allow: GET, HEAD`, before a token is looked at.
- **Answer.** `200`, `Content-Type: text/plain; version=0.0.4; charset=utf-8`, `Cache-Control: no-store`. Prometheus's
  [exposition formats](https://prometheus.io/docs/instrumenting/exposition_formats/) page (read 2026-10-07):
  "`text/plain` with parameters: `version=0.0.4`", "The last line must end with a line feed character.", "Only one
  `TYPE` line may exist for a given metric name." and "All lines for a given metric must be provided as one single
  group". The renderer (`PrometheusText` in libs/platform) writes one `# HELP` and one `# TYPE` a family and every
  copy's series under it.
- **Kinds.** A counter is a `counter`; a gauge a `gauge`; a timer a `histogram` - `_bucket` by rising `le` with
  `le="+Inf"` equal to `_count`, then `_sum` and `_count` - plus a separate `gauge` family `<name>_max`, the longest
  single recording since the copy was loaded. A gauge that cannot be read is `NaN`.
- **Per node.** Scrape each node on its own address, never through the load balancer: the counters are the node's,
  and a load-balanced scrape mixes nodes into one series that goes up and down.

## Authentication

The route is `metrics.read`, scope `oidf.metrics.read`, checked by the operator authenticator as every other
operator route is ([operator-authentication.md](operator-authentication.md#the-routes)): `401` with no token or a bad
one, `403` without the scope, `429` after repeated failures and `503` when the authenticator cannot be built. A
success is **not** written to PingFederate's audit log: a scrape every 15 seconds on every node would bury the
audit log in lines that say nothing. `admin.request.authorised` is still emitted and counted in
`oidf_events_total{code="admin.request.authorised"}`; a refusal is audited as before.

In development a bearer token is taken. In production the authenticator takes only a sender-constrained token - DPoP
or certificate-bound - with one exception, for scrapers, decided in [U-0566](../findings.md#u-0566) ("prometheous -
private_key_jwt", David, 2026-10-08):

- Prometheus's `<oauth2>` block ([configuration](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#oauth2),
  read 2026-10-07) has no DPoP, and PingFederate 13.x issues no certificate-bound access token (no `cnf.x5t#S256`,
  RFC 8705 section 3; [U-0566](../findings.md#u-0566) records the scan of the 13.1.3 image). So no token Prometheus
  can get is sender-constrained.
- **`OIDF_METRICS_CLIENT_IDS`** names the PingFederate clients whose tokens bound to nothing this route - and only this
  route - takes in production, with `oidf.metrics.read`. Any other client's unbound token is refused with the DPoP
  challenge as before, a listed client's token without the scope is a `403`, and every other operator route refuses
  the listed client's unbound token. Unset, production refuses every unbound token. Each such scrape is counted in
  `oidf_operator_unbound_scrapes_total` and logged at DEBUG only; the event's `binding` is `none`.
- The client authenticates to PingFederate **with a key, never a shared secret**. That is what the exception rests on:
  the token is unbound, so a token that leaks can be replayed until it expires, but only to read metrics, and only
  one minted for a key-holding client. Give the operator access token manager a short lifetime for it (minutes).

### Prometheus: the JWT bearer grant

Prometheus cannot send a `private_key_jwt` client assertion (RFC 7523 section 2.2). What it signs is the JWT bearer
*grant* (section 2.1), `grant_type: urn:ietf:params:oauth:grant-type:jwt-bearer`, with `client_certificate_key_file`.
From prometheus/common v0.72.0 (`config/oauth_assertion.go`), it POSTs `grant_type`, `assertion` and `scope` - and no
`client_id`, so add one with `endpoint_params`. The assertion's `iss` is `iss` (default the `client_id`), `sub` the
`client_id`, `aud` `audience` (default the `token_url`), with `jti`, `iat`, an `exp` ten minutes out, and `kid` from
`client_certificate_key_id`; the algorithm is RS256, RS384 or RS512.

PingFederate 13.1 takes that grant through an IdP connection ([Configuring an OAuth assertion grant IdP
connection](https://docs.pingidentity.com/pingfederate/13.1/administrators_reference_guide/pf_configuring_oauth_assertion_grant_idp_connection.html),
read 2026-10-08): "For JWT bearer grant requests (grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer),
PingFederate supports the following assertion types: A standard JWT, as defined in the JSON Web Token (JWT) Profile
for OAuth 2.0 Client Authentication and Authorization Grants specification". Its [grant type
parameters](https://docs.pingidentity.com/pingfederate/13.1/developers_reference_guide/pf_oauth_grant_type_param.html)
say of `assertion`: "A JSON Web Token (JWT), as defined in RFC7523, section 2.1", and "The client_id parameter is not
required when the Allow unidentified clients to request extension grants checkbox is selected" - leave that checkbox
clear, so the token names the client and `OIDF_METRICS_CLIENT_IDS` can check it.

1. **The key.** An RSA key for Prometheus, and a certificate for it (self-signed will do: PingFederate checks the
   signature against the certificate it holds, nothing else about it).
2. **The IdP connection** (Authentication, Integration, IdP Connections): connection type **OAuth Assertion Grant**,
   partner entity ID the assertion's `iss` (`prometheus`), the certificate as its signature-verification certificate,
   and an OAuth assertion grant attribute mapping into the operator access token manager
   ([operator-authentication.md](operator-authentication.md)). Keep this connection's mapping for the operator token
   manager only, and no other assertion-grant connection mapping into it.
3. **The client** (`prometheus`): grant type **extension grants** (the admin API's `EXTENSION`), restricted to the
   scope `oidf.metrics.read`, the operator access token manager, and no client secret - the assertion is how it
   proves itself.
4. **This server:** `OIDF_METRICS_CLIENT_IDS=prometheus`.

```yaml
scrape_configs:
  - job_name: pingfederate-oidf
    scheme: https
    metrics_path: /agentic-identity/metrics
    oauth2:
      client_id: prometheus
      grant_type: urn:ietf:params:oauth:grant-type:jwt-bearer
      client_certificate_key_file: /etc/prometheus/oidf-scraper.key
      client_certificate_key_id: oidf-scraper-1
      signature_algorithm: RS256
      token_url: https://pf.example.com/as/token.oauth2
      scopes: [oidf.metrics.read]
      endpoint_params:
        client_id: prometheus
    tls_config:
      ca_file: /etc/prometheus/pf-ca.pem
    static_configs:
      - targets: ['pf-node-1.internal:9031', 'pf-node-2.internal:9031']
```

Not yet shown on a running PingFederate: the steps above follow the 13.1 documentation and admin API model
(`IdpConnection.idpOAuthGrantAttributeMapping`, `ConnectionCredentials.certs`, the client grant type `EXTENSION`),
not a rig run; [U-0566](../findings.md#u-0566) says what is left to check.

### Any other scraper: private_key_jwt

A scraper that can send a `private_key_jwt` client assertion (RFC 7523 section 2.2) uses the client-credentials grant
instead: a client with client authentication **Private Key JWT**, its JWKS or JWKS URL, the client-credentials grant,
the scope `oidf.metrics.read` and the operator access token manager; list its client id in `OIDF_METRICS_CLIENT_IDS`.

### Development

A development or staging scrape can use a client secret, since development takes any bearer token:

```yaml
    oauth2:
      client_id: prometheus
      client_secret_file: /etc/prometheus/oidf-client-secret
      token_url: https://pf.example.com/as/token.oauth2
      scopes: [oidf.metrics.read]
```

## The `copy` label

Every series carries `copy`, the loaded copy of libs/platform that counted it. PingFederate loads the code more than
once (classloaders), and each copy has its own registry:

| `copy` | Which copy | What it counts |
|---|---|---|
| `webapp` | `pf-runtime.war`'s (or `gm-api.war`'s) `WEB-INF/lib` | the servlets, filters, stores, SSF, federation, the endpoint itself |
| `engine` | `server/default/deploy` | the OGNL issuance criteria and access-token mappings: attestation decisions (finding F-0170) |
| `rar` | the RAR plugin's relocated copy | the PDP calls, answers and breakers |
| `cibasim` | the CIBA simulator plugin's relocated copy | its own |
| `other` | anything else | - |

The webapp renders its own registry and those the other copies hand it: a copy that is not the webapp's puts a
supplier of its metrics, in JDK types only, on the request it runs in (attribute
`com.pingidentity.ps.oidf.metrics.copies`), and the webapp's correlation filter keeps it after the chain. So a copy
appears once it has run in a request on this node - the engine's after the first token request an OGNL criterion
checks, the RAR plugin's after the first authorization request with `authorization_details`. At most eight other
copies are kept; a copy redeployed from a new location replaces the one with its label; one whose supplier throws or
no longer links is dropped. What is left out is counted in `oidf_metrics_copy_refused_total{from_copy,reason}`.

The same family can appear under several copies - `oidf_events_total` is counted by each. Sum over `copy` for the
node's total; keep `copy` to see where an event was decided.

## The families

The unit is in the name. Labels are bounded: each has a declared set of values or a cap, and a value outside it is
counted as `other`. No label carries a key, a subject, a token, an address or SQL. Every family is catalogued, with
its labels, under `"metrics"` in its module's `META-INF/oidf-events/*.json`, and `MetricsCataloguedTest` holds the
catalogues and the code to each other.

### The endpoint and the registries

| Family | Kind | Labels | What |
|---|---|---|---|
| `oidf_metrics_scrape_seconds` | timer | | rendering one answer, every copy's supplier included |
| `oidf_metrics_copies` | gauge | | copies rendered, the webapp's included |
| `oidf_metrics_copy_refused_total` | counter | `from_copy`, `reason` (`full`, `malformed`, `supplier`, `duplicate`, `clash`, `bounds`) | copies, or a copy's metrics, left out |
| `oidf_metrics_label_folds_total` | counter | `metric` | label values counted as `other` |
| `oidf_metrics_refused_total` | counter | | registrations a full registry refused |
| `oidf_events_total` | counter | `code`, `outcome` | catalogued events emitted |
| `oidf_events_dropped_fields`, `oidf_events_uncatalogued` | gauge | | events carrying an undeclared field, or an undeclared code |

### SSF

| Family | Kind | Labels | What |
|---|---|---|---|
| `oidf_ssf_backlog_sets` | gauge | `stage` (`outbox`, `queued`, `held`, `dead`) | SETs waiting at each stage; `outbox` counts raised events not yet fanned out to their streams |
| `oidf_ssf_backlog_oldest_seconds` | gauge | `stage` | the oldest's age; `0` when the stage is empty, `NaN` when it could not be counted |
| `oidf_ssf_backlog_sample_age_seconds` | gauge | | seconds since this node counted |
| `oidf_ssf_sets_dropped_total` | counter | `source`, `reason` | PingFederate events that raised no SET, or a SET that did not go everywhere |
| `oidf_ssf_push_attempts_total` | counter | `outcome` | push POSTs |
| `oidf_ssf_dead_sets_total` | counter | `source` | SETs moved to the dead-SET record |
| `oidf_ssf_stream_lease_claimed_total`, `_lost_total` | counter | | push stream leases claimed, and lost - the lease steal, counted on the node it was taken from |
| `oidf_ssf_stream_paused_total` | counter | `cause` (`receiver`, `operator`, `push_refused`, `push_failing`, `inactivity`) | streams paused |
| `oidf_ssf_queue_trimmed_total` | counter | | SETs trimmed off a full stream queue (`OIDF_SSF_STREAM_QUEUE_MAX`) |
| `oidf_ssf_outbox_appended_total` | counter | | raised events written to the emission outbox |
| `oidf_ssf_outbox_fanned_out_total` | counter | `outcome` (`fanned_out`, `retry`, `dropped`, `expired`) | outbox rows a worker took |
| `oidf_ssf_receiver_inbox_pending`, `_oldest_pending_seconds` | gauge | | inbound SETs not yet acted on |
| `oidf_ssf_receiver_action_dead_total` | counter | | inbound SETs given up on |

The backlog is counted by a webapp job, `ssf-backlog-sampler`, every `OIDF_METRICS_SAMPLE_SECONDS` (default 15, 5 to
300; [configuration](../configuration/metrics.md)), with one aggregate query a stage and a 2-second deadline each; a
scrape never queries the database. The tables are the cluster's, so every node reports the same rows: take `max`
across nodes, not `sum`. The `ldm` store is counted only at `outbox`, its node-local outbox; its queues are not.
`outbox` is the outbox's own count, `EmissionOutbox.stats()`, one query on the tables store.

### Leases

| Family | Kind | Labels | What |
|---|---|---|---|
| `oidf_lease_held` | gauge | `lease` | 1 while this node holds it |
| `oidf_lease_acquired_total`, `oidf_lease_lost_total` | counter | `lease` | leases taken, and lost before they were given back |
| `oidf_lease_operation_seconds` | timer | `backend` (`local`, `jdbc`, `redis`), `op` (`acquire`, `renew`, `release`), `outcome` (`ok`, `refused`, `unavailable`, `error`) | every backend call |
| `oidf_lease_fencing_refusals_total` | counter | `lease` | fenced writes refused because the lease had moved |

### Federation keys

| Family | Kind | Labels | What |
|---|---|---|---|
| `oidf_federation_signing_keys` | gauge | `state` (`active`, `pending`, `retired`) | keys in this node's view |
| `oidf_federation_active_key_age_seconds` | gauge | | since the active key was recorded |
| `oidf_federation_subordinates` | gauge | `state` (`in_sync`, `rollover_pending`, `diverged`, `unreachable`) | active pinned subordinates, as this node's monitor last read them |
| `oidf_federation_key_monitor_age_seconds` | gauge | | since the key monitor last ran; past 30 s it has stopped |
| `oidf_federation_key_activations_total` | counter | `kind` | changes of the active key |
| `oidf_federation_key_activation_skipped_total` | counter | | reads of a key this node had no private key for |
| `oidf_federation_subordinate_changes_total` | counter | `action`, `outcome` | subordinate pin changes |

### Redis

| Family | Kind | Labels | What |
|---|---|---|---|
| `oidf_redis_command_seconds` | timer | `command` (`SET`, `GET`, `DEL`, `INCR`, `PEXPIRE`, `EVALSHA`, `EVAL`, `PING`, `other`), `outcome` (`ok`, `error_reply`, `io`, `closed`) | every command, the wait for a connection included |
| `oidf_redis_permit_wait_seconds` | timer | | the wait for one of `OIDF_REDIS_POOL_SIZE` connections |
| `oidf_redis_failovers_total` | counter | | masters forgotten through Sentinel |

### JDBC

| Family | Kind | Labels | What |
|---|---|---|---|
| `oidf_jdbc_connection_seconds` | timer | `outcome` (`ok`, `timeout`, `transient`, `error`) | taking a connection |
| `oidf_jdbc_statement_seconds` | timer | `op` (`query`, `update`), `outcome` | each statement, its connection included |
| `oidf_jdbc_transactions_total` | counter | `outcome` | transactions ended; `ok` once committed and the connection restored |
| `oidf_jdbc_retries_total` | counter | | runs retried after a transient SQLState |

`timeout` is a statement cancelled by its timeout or refused at its deadline (SQLState `57014`, PostgreSQL's
`query_canceled`, or `HYT00`); `transient` one a retry may cure.

### Executors, components, RAR, discovery, attester

`oidf_executor_runs_total`, `_failures_total` and `_run_seconds` by `executor`; `oidf_component_retries_total` by
`component`; the RAR plugin's `oidf_rar_pdp_calls_total`, `_answers_total`, `oidf_rar_pdp_breakers` and
`oidf_rar_context_dropped_total` (under `copy="rar"`); `oidf_discovery_attestation_members_total`; and the attester's
`oidf_attester_cloud_evidence_refusals_total`. Their labels are in their catalogues.

## Alerts

Starting points; tune the windows to your traffic.

```yaml
groups:
  - name: oidf
    rules:
      - alert: OidfSsfBacklogOld
        expr: max(oidf_ssf_backlog_oldest_seconds{stage="queued"}) > 900
        for: 10m
      - alert: OidfSsfBacklogNotSampled
        expr: max(oidf_ssf_backlog_sample_age_seconds) > 120 or absent(oidf_ssf_backlog_sample_age_seconds)
        for: 5m
      - alert: OidfSsfDeadSets
        expr: sum(increase(oidf_ssf_dead_sets_total[1h])) > 0
      - alert: OidfSsfSetsDropped
        expr: sum by (reason) (increase(oidf_ssf_sets_dropped_total[15m])) > 0
      - alert: OidfKeyMonitorStopped
        expr: oidf_federation_key_monitor_age_seconds > 120
        for: 5m
      - alert: OidfNoActiveFederationKey
        expr: max(oidf_federation_signing_keys{state="active"}) < 1
        for: 5m
      - alert: OidfLeaseFencingRefused
        expr: sum(increase(oidf_lease_fencing_refusals_total[15m])) > 0
      - alert: OidfJdbcTimeouts
        expr: sum(rate(oidf_jdbc_statement_seconds_count{outcome="timeout"}[5m])) > 0.1
        for: 10m
      - alert: OidfRedisErrors
        expr: sum(rate(oidf_redis_command_seconds_count{outcome="io"}[5m])) > 0.1
        for: 10m
      - alert: OidfMetricsCopyRefused
        expr: sum(increase(oidf_metrics_copy_refused_total[1h])) > 0
```

`OidfMetricsCopyRefused` says a copy's metrics are missing from the answer: read `reason`. `OidfKeyMonitorStopped`
and `OidfSsfBacklogNotSampled` catch a job that has stopped, which the other gauges cannot show because they keep their
last value.

## What it does not do yet

- **The engine's and the RAR plugin's copies on a running PingFederate** are proven in unit tests that load platform
  twice in one JVM, not yet on a rig ([U-0565](../findings.md#u-0565)).
- **A separate lease-steal counter.** A steal is counted once, as `oidf_ssf_stream_lease_lost_total` on the node the
  stream was taken from. The claim takes any lease whose `expires_at` has passed, and a release sets `expires_at` to
  now, so the claiming node does not know which of its claims were steals and keeps no counter of its own.
