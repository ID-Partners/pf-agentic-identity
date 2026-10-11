# Configuration

Every setting the federation support reads, what it defaults to, what it does, and what happens when it's
wrong. The rows are generated: each component's settings catalogue is the one place a row is written, and
[docs/configuration](../configuration/README.md) holds a page per component, which CI keeps equal to the
catalogues while `tools/settings-scan.py` keeps the catalogues equal to the code. This page says how a setting is
read and what "wrong" means, points each part of the federation at the pages its settings are on, and keeps what
a row has no room for. [Operations](operations.md) shows the settings in use.

## How a setting is read

Most settings are environment variables, and most can also be a Java system property, usually the same name in
lower case with `.` for `_` (`OIDF_PDP_MODE` is `oidf.pdp.mode`). The system property wins. A generated row names
the property wherever there is one, and a few keep an underscore (`OIDF_ATTESTATION_REQUIRE_HOSTED_AGENT` is
`oidf.attestation.require_hosted_agent`). They are read once, when the
first component asks, and kept for as long as PingFederate runs; change one and restart.

The exceptions:

- The federation servlet's own settings (this entity's metadata, CORS) are servlet init-params first, then the
  environment variable, with no system property. Nothing in this repo sets an init-param; they matter only if you
  edit `web.xml`.
- The hosted-entity settings are init-param, then system property, then environment variable. Three of their
  system properties keep an underscore: `oidf.authority.entity_id`, `oidf.authority.admin_token`,
  `oidf.authority.data_store_id`.
- The `OIDF_FETCH_*` settings and `OIDF_EVENTS_MAX_VALUE_LENGTH` are environment variables only.

A generated row's Setting column lists every place its setting is read from, in the order they are tried.

## When a setting is wrong

One of these happens, and each generated row says which, in bold, at the start of its "When it's wrong" cell:

- **Doesn't start** - the component that reads it fails at deploy, taking `pf-runtime.war` with it, and the log
  names the setting. Most settings are like this: a value that doesn't parse is refused rather than quietly read
  as the default. A switch is `true` or `false`, in any case, and anything else is refused - unless its row says
  otherwise.
- **First request** - a servlet that starts lazily fails on its first request, and only its paths fail.
- **Per request** - nothing at start-up; the requests that need it fail.
- **Not checked** - nothing checks the value; the row says what a wrong one leads to.

## Where the rows are

| Part of the federation | Pages |
|---|---|
| Trust anchors | [federation-runtime](../configuration/federation-runtime.md), [federation-entity](../configuration/federation-entity.md) (`OIDF_FEDERATION_TRUST_ANCHORS`) |
| This entity and its signing keys | [federation-entity](../configuration/federation-entity.md) (`OIDF_FEDERATION_SIGNING_ALG`, `OIDF_FEDERATION_KEY_REFRESH_SECONDS`, `OIDF_FEDERATION_KEY_ACTIVATION_DELAY_SECONDS`), [federation-runtime](../configuration/federation-runtime.md) (`OIDF_FEDERATION_SUBORDINATE_CONSTRAINTS`) |
| Fetching | [outbound-fetch](../configuration/outbound-fetch.md), [federation-entity](../configuration/federation-entity.md) (`OIDF_FEDERATION_IGNORE_SSL_ERRORS`, one setting for every reader, and its init-param `ignoreSslErrors`) |
| Registration and its lifetime | [federation-runtime](../configuration/federation-runtime.md), [registration](../configuration/registration.md) (the init-params of `/federation/register` and the registration filters) |
| Trust Marks and key history | [federation-runtime](../configuration/federation-runtime.md) |
| Hosted entities and the admin API | [hosted-entities](../configuration/hosted-entities.md), [hosted-entity-signing](../configuration/hosted-entity-signing.md) (OpenBao), [federation-runtime](../configuration/federation-runtime.md) (`OIDF_AUTHORITY_METADATA_POLICY`), [registration](../configuration/registration.md) (`OIDF_REGISTERED_CLIENTS_ENABLED`) |
| Policy decisions (AuthZEN 1.0) | [federation-runtime](../configuration/federation-runtime.md) |
| Client authentication at the federation endpoints | [federation-runtime](../configuration/federation-runtime.md) |
| Events and logging | [pf-audit](../configuration/pf-audit.md) |
| Neighbours: attestation and FAPI | [federation-runtime](../configuration/federation-runtime.md) (the attestation filter and bridge keys), [attestation-token-endpoint](../configuration/attestation-token-endpoint.md), [rar-models](../configuration/rar-models.md), [fapi2-profile](../configuration/fapi2-profile.md) |

What follows, part by part, is what the rows leave out.

## Trust anchors

- `OIDF_FEDERATION_TRUST_ANCHOR_JWKS` as a map is written `{"https://ta.example.org": {"keys": [...]}}`.
  Registration, the OGNL criteria, the attestation filter, resolve, endpoint client authentication and the
  attestation issuer's wallet trust all use it. A single set with no controller host counts as nothing pinned.
- `OIDF_FEDERATION_SELF_ANCHOR` is tried after any pinned anchors. There is nothing to pin, and a key rotation
  needs no change.
- `OIDF_FEDERATION_TRUST_CONTROLLER_HOST` must be one of the pinned anchors. Set with no anchor keys, the
  registration filters log an error and requests go straight to PingFederate's own client authentication, and
  resolve is off. Unset, with no anchor map and no self anchor, the token-endpoint filter doesn't start, so neither
  does PingFederate.
- `OIDF_FEDERATION_TRUST_CONTROLLER_BASE_URL` is for a controller served under a context path, such as
  `https://pf.example/oidf`.
- `OIDF_FEDERATION_TRUST_ANCHORS` is required, though its row's default reads "Unset": unset or blank, or with an
  entry that is not an Entity Identifier, the federation servlet doesn't start. An issuer is matched to an anchor
  with or without a trailing slash and whatever the case of its scheme and host.
- The superseded `OIDF_TRUST_CONTROLLER_HOST`, `OIDF_TRUST_ANCHOR_JWKS` and `OIDF_TRUST_CONTROLLER_IGNORE_SSL` are
  compared with their new names as strings, so the same JSON written differently counts as different, and
  PingFederate doesn't start.

## This entity

- With `OIDF_FEDERATION_SUBORDINATES` set, or a subordinate pinned, PingFederate publishes fetch and list endpoints.
- Each subordinate's Subordinate Statement carries the keys pinned for it, never the keys its own Entity
  Configuration lists (since 0.7.0, finding F-0012). `OIDF_FEDERATION_SUBORDINATE_STORE` says where the pins are:
  `settings` (the default) reads `OIDF_FEDERATION_SUBORDINATE_PINS`, written `{"<entity id>": {"jwks": {"keys":
  [...]}, "entity_types": [...], "intermediate": true}}`; `database` keeps them in the authority's store (migration
  V105), where the operator API asks for enrolments and changes and an operator approves them. Under production
  every `OIDF_FEDERATION_SUBORDINATES` entry needs a pin, or the federation servlet is `FAILED_CONFIG` naming the ones
  without; under development an entry with no pin is served with its live keys, with a WARN.
  [Operations](operations.md#pinned-subordinates) has the enrolment.
- The subordinate monitor and change control (since 0.7.0, plan item S7b): `OIDF_FEDERATION_SUBORDINATE_APPROVAL`
  (`single`, or `two-person` to refuse an approval by the operator who asked), `OIDF_FEDERATION_SUBORDINATE_APPROVAL_TTL_SECONDS`
  (604800: an operator's change not approved by then is withdrawn), `OIDF_FEDERATION_SUBORDINATE_ROLLOVER_HOLD_SECONDS`
  (86400, 60 to 604800; production refuses less than 86400 under the database store: how long a rollover signed by a pinned key is held),
  `OIDF_FEDERATION_SUBORDINATE_MONITOR_SECONDS` (240: how often each subordinate is looked at) and
  `OIDF_FEDERATION_SUBORDINATE_UNREACHABLE_SECONDS` (900). [Operations](operations.md#subordinate-monitor-and-change-control)
  has what each does.
- `OIDF_FEDERATION_ATTESTER_JWKS` with a key that isn't public stops PingFederate starting because it would
  otherwise publish the key.
- `OIDF_FEDERATION_SUBORDINATE_CONSTRAINTS` is written `{"max_path_length": 0, "naming_constraints": {"permitted":
  [...], "excluded": [...]}, "allowed_entity_types": [...]}`.
- The init-params `tokenEndpointAuthMethodsSupported`, `clientAttestationSigningAlgValuesSupported`,
  `clientAttestationPopSigningAlgValuesSupported`, `dpopSigningAlgValuesSupported`,
  `clientAttestationPopMethodsSupported` and `attestationChallengeEndpointEnabled` default to the attestation
  profile's values.
- The init-param `clientAttestationFormatsSupported` has no effect. `trustControllerHost` had none either (the
  controller comes from `OIDF_FEDERATION_TRUST_CONTROLLER_HOST`) and was removed in 0.6.0: set, the federation servlet
  doesn't start.

## Fetching

Every fetch the federation makes on a stranger's say-so - a chain's statements, an RP's key set, a Trust Mark's
status - goes through the outbound URL policy.

## Registration

- With `OIDF_AUTO_REGISTRATION_FAIL_CLOSED` on, a refusal is a 401 or 503 at the token endpoint, the
  `OIDF_AUTO_REGISTRATION_AUTHZ_ERROR_MODE` answer at the authorization endpoint, and JSON at PAR.
- The init-params `subordinateStatementCacheMaxEntries`, `trustChainEntryMaxAgeSeconds` and
  `acceptedSigningAlgorithms` are read on `/federation/register` and both registration filters;
  `trustControllerHost` and `trustControllerBaseUrl` on `/federation/register` only.
- The registration response is signed as the federation endpoints sign: `OIDF_FEDERATION_SIGNING_ALG`, with
  PingFederate's current key for it. The `signingAlgorithm` init-params of `/federation/register` and of the
  federation servlet were removed in 0.7.0, and either one set stops its servlet starting.

## Signing keys

- Every signer reads PingFederate's current key through one shared reader: the federation endpoints, the
  registration response, the self-anchor's own keys and the SSF transmitter's SETs. RS256 and PS256 use
  PingFederate's RSA key, ES256 its P-256 key and ES384 its P-384 key - the keys `/pf/JWKS` publishes.
- A key is read again every `OIDF_FEDERATION_KEY_REFRESH_SECONDS` (default 30, 0 to 300). A read that fails keeps
  the last key for at most 300 seconds more; after that, or with no key at all, signing answers 503.
- `OIDF_SSF_SIGNING_ALGORITHM` is SSF's own choice from the same four, read through the same reader; its key never
  enters the federation key history.
- For `OIDF_FEDERATION_SIGNING_ALG` the key read is the cluster's active key, by its `kid`: a key PingFederate starts
  publishing becomes active only after `OIDF_FEDERATION_KEY_ACTIVATION_DELAY_SECONDS` (default 3600, 0 to 86400),
  and is in the Entity Configuration's `jwks` from the first tick that sees it
  ([operations.md](operations.md#changing-pingfederates-signing-key)).

## Registration lifetime

- The OGNL criterion follows `OIDF_REGISTRATION_EXPIRY_ENFORCEMENT` too.

## Trust Marks

- `OIDF_FEDERATION_TRUST_MARK_TYPES` is written `{"<type>": {"lifetime_seconds": 86400, "subjects": "hosted" or
  "any", "delegation": "<jwt>", "ref": "https://...", "logo_uri": "https://..."}}`. Grants are made through the
  admin API and kept in the authority's database, or in memory.
- `OIDF_FEDERATION_TRUST_MARKS` is written `[{"trust_mark_type": "...", "trust_mark": "<jwt>"}]`.

## Key history

- The key history and the key observations (`OIDF_FEDERATION_HISTORICAL_KEYS`) are kept in the authority's database
  (V103, V104), or in each node's memory - which a clustered production node refuses.
- `OIDF_FEDERATION_KEY_HISTORY_GRACE_SECONDS` must be at least the longest of every Trust Mark type's
  `lifetime_seconds`, `OIDF_REGISTRATION_MAX_TTL_SECONDS` and 3600: shorter is FAILED_CONFIG under production.

## Hosted entities and the admin API

- `OIDF_AUTHORITY_METADATA_POLICY` is written by role, `{"oauth_client": {"scope": {"subset_of": [...]}}}`.

## Policy decisions (AuthZEN 1.0)

All of these are checked when PingFederate starts, whatever the mode.

- With `OIDF_PDP_MODE=local` and no `OIDF_REGISTRATION_ALLOWED_SCOPES`, nothing is asked.
- With `OIDF_PDP_DISCOVER=true`, a discovery that fails counts as no decision.

## Client authentication at the federation endpoints

- `OIDF_FEDERATION_ENDPOINT_AUTH` is written `{"federation_fetch_endpoint": "required",
  "federation_resolve_endpoint": "optional"}`, naming any of the seven federation endpoints. Spent `jti` values
  are kept where attestation keeps its replays (Redis when `OIDF_REDIS_URL` is set).

## Events and logging

Nothing beyond the rows.

## Neighbours: attestation and FAPI

The same modules carry client attestation and a FAPI 2.0 filter. The
pf-integration README has the detail.

- `OIDF_ATTESTATION_REQUIRE_HOSTED_AGENT`: a revoked hosted agent is refused (401) whatever it says.
- `OIDF_BRIDGE_PRIVATE_JWK` and `OIDF_BRIDGE_PREVIOUS_PUBLIC_JWK` are removed (bridge keys are per client now). Set
  at all, the attestation filter doesn't start: `BridgeSigners` refuses them and names where the key goes.
- `OIDF_RAR_MODELS_FILE` and `OIDF_RAR_MODELS` are environment variables only, with no system property. A document
  the model refuses stops `pf-runtime.war` (PingFederate's runtime endpoints answer 503) when attestation
  authentication is configured; otherwise the attester fails from its first request and the issuance criterion
  per request.
