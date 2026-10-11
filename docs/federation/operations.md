# Operations

Running the federation support day to day: pinning trust anchors and rolling their keys, hosting agents,
granting Trust Marks, wiring a policy engine, and reading what it logs. Every setting named here is in
[configuration](configuration.md); what each part does is in [how it works](how-it-works.md).

## Pinning a trust anchor

Nothing validates a chain until PingFederate has its anchors' public keys, and those arrive out of band
(OpenID Federation 1.0 §10(1)): never fetched from the anchor at request time.

1. Get the anchor's keys from somewhere you trust. The best source is the federation operator, through a
   channel separate from the anchor's own website (§11.3). Failing that, capture them once from a network you
   trust with `tools/pin-trust-anchor.py https://anchor.example`, and **compare the printed thumbprints with the
   key the anchor actually holds** before you use them.
2. Set `OIDF_FEDERATION_TRUST_ANCHOR_JWKS`. For one anchor, its JWK Set, with the anchor named in
   `OIDF_FEDERATION_TRUST_CONTROLLER_HOST`. For several, a map of anchor to JWK Set:

   ```json
   {"https://federation.example.org": {"keys": [...]}, "https://partners.example.net": {"keys": [...]}}
   ```

   A set with a private key, a symmetric key, or a key without a `kid` or with a repeated one stops the
   registration filters starting.
3. Restart PingFederate. The first chain that reaches the anchor checks the anchor's own Entity Configuration
   against what you pinned; a wrong capture fails there, loudly.

**PingFederate as its own anchor.** Set `OIDF_FEDERATION_SELF_ANCHOR` to PingFederate's Entity Identifier (its
issuer, an https URL) and name it in `OIDF_FEDERATION_TRUST_ANCHORS` too, so its Entity Configuration says it is
an anchor. Chains that end at PingFederate are then checked with the key it signs with, read from its key store
each time. Don't also pin PingFederate's keys in `OIDF_FEDERATION_TRUST_ANCHOR_JWKS`: that is refused, because the
copy would go stale at the first rotation.

## Rolling an anchor key

An anchor rolls its key by publishing the new one alongside the old for a while (§11.2). On the PingFederate
side:

1. When the anchor announces the new key, add it to the pinned set for that anchor - both keys, old and new.
2. Restart PingFederate. Chains signed with either key now check out.
3. After the anchor has stopped signing with the old key, and every statement it signed with it has expired,
   remove the old key and restart again.

If you remove the old key too early, chains built from statements the anchor signed before the roll fail until
those statements expire - at most their lifetime, often an hour.

## Hosting agents

With `OIDF_AUTHORITY_ENTITY_ID` set and operator authentication configured, PingFederate is a domain authority: it
publishes and signs Entity Configurations for agents that can't publish their own, with a key per agent kept
in OpenBao. Keep the agents in a database (`OIDF_AUTHORITY_JDBC_URL` or `OIDF_AUTHORITY_DATA_STORE_ID`, with the
`V100`-`V101` migrations applied) - in memory they are gone at the next restart.

Every admin call below is an operator route: from 0.6.0 it needs a PingFederate-issued access token with the route's
scope, DPoP-bound in production ([operator-authentication.md](../operator/operator-authentication.md#the-routes)).
The examples use `$TOKEN` and `$PROOF`, a token from your operator client and a fresh DPoP proof for the request; in
development `OIDF_AUTHORITY_ADMIN_TOKEN` also works, as `Authorization: Bearer`.

**Enrol an agent** - the OpenBao transit key must exist already:

```sh
curl -sS https://pf.example.com/federation/agents \
  -H "Authorization: DPoP $TOKEN" -H "DPoP: $PROOF" -H 'Content-Type: application/json' \
  -d '{"id": "payments-agent", "hostingKeyRef": "agent-payments-1",
       "metadata": {"oauth_client": {"client_name": "Payments agent", "scope": "payments.read"}}}'
```

Its Entity Configuration is then at `https://pf.example.com/federation/agents/payments-agent/.well-known/openid-federation`
(the id is built from `OIDF_AUTHORITY_ENTITY_ID`, never the request's `Host`). Optional fields: `listable`
(default false - it stays out of `/federation/list`), `notAfterSeconds`, `ownerRef`, and `metadataPolicy`, which
can only narrow the domain default (`OIDF_AUTHORITY_METADATA_POLICY`). With the policy engine asked at enrolment,
a refusal is a 403.

**Change it** through the admin API, each a POST with an operator token (`oidf.admin.entities`, or `oidf.admin.keys`
for `rotate-key`) and a JSON body naming the agent:

| Route | Body | What happens |
|---|---|---|
| `/federation/admin/entities/suspend` | `{"entity_id", "reason"?}` | Stops resolving at once; can be undone |
| `/federation/admin/entities/reactivate` | `{"entity_id", "reason"?}` | Resolves again |
| `/federation/admin/entities/revoke` | `{"entity_id", "reason"?}` | Stops resolving, for good (a revoked agent is a 409 after) |
| `/federation/admin/entities/metadata` | `{"entity_id", "metadata"}` | Replaces its metadata |
| `/federation/admin/entities/metadata-policy` | `{"entity_id", "metadata_policy"}` | Replaces its own policy, which must only narrow the domain default |
| `/federation/admin/entities/rotate-key` | `{"entity_id", "hosting_key_ref"}` | Moves it to a new OpenBao key, after checking the key signs |

`GET /federation/admin/entities` lists every hosted agent whatever its status; `?entity_id=` gives one, with its
metadata and policy; `/federation/admin/entities/audit?entity_id=` gives its history. Every change records who
made it: the operator token's `sub` - for a client-credentials token, the operator client's id. An
`X-Federation-Actor` header names nobody: it is recorded only as the operator event's `claimed_label`. The token
itself is never logged.

Suspending or revoking stops the agent resolving here straight away. What it doesn't stop is in
[how it works](how-it-works.md#what-stops-when).

## Trust Marks

To issue marks, name the types in `OIDF_FEDERATION_TRUST_MARK_TYPES` and keep the grants in the authority's
database (`V102__trust_mark.sql`). Then grant them:

```sh
curl -sS https://pf.example.com/federation/admin/trust-marks \
  -H "Authorization: DPoP $TOKEN" -H "DPoP: $PROOF" -H 'Content-Type: application/json' \
  -d '{"trust_mark_type": "https://pf.example.com/marks/certified", "sub": "https://rp.example.com"}'
```

Granting a type again revokes every mark issued under the old grant. `POST /federation/admin/trust-marks/revoke`
with `{"trust_mark_type", "sub", "reason"?}` revokes; `GET /federation/admin/trust-marks?sub=` or
`?trust_mark_type=` lists grants, and `/trust-marks/audit` gives one grant's history. A type issued to hosted
agents only can be granted only to an active one.

Revoking a grant makes the status endpoint answer `revoked` straight away. A copy of the mark someone already
has still verifies until it expires, for anyone who doesn't ask the status endpoint - so keep mark lifetimes
short, or have relying parties set `OIDF_FEDERATION_TRUST_MARK_STATUS_CHECK=true`.

## Pinned subordinates

A Subordinate Statement tells a verifier which keys the subordinate signs with, and a chain through it validates
only under those keys (OpenID Federation 1.0 §10.2: "verify that the signature of ES[j] validates with a public key
in ES[j+1]["jwks"]"). Up to 0.6.x PingFederate took them from whatever answered at the subordinate's URL, so whoever
controlled that URL controlled the subordinate's keys (finding F-0012). From 0.7.0 each subordinate's keys, Entity
Types and Intermediate flag are pinned by an operator, and the statement carries the pin. The live Entity
Configuration is only looked at, by the subordinate monitor ([Subordinate monitor and change
control](#subordinate-monitor-and-change-control)).

Confirm the keys with the subordinate's operator out of band first - the RFC 7638 thumbprint of each, over a channel
the URL's owner does not control. `tools/pin-subordinates.py capture <entity-id>...` prints each subordinate's public
`jwks`, thumbprints, Entity Types and Intermediate flag as PingFederate derives them, then the pins (`--format pins`,
the setting's value) or the enrolment bodies (`--format enrol`); it is trust-on-first-use and checks no signature, so
read the thumbprints to the subordinate's operator before you use them. `tools/pin-subordinates.py compare pins.json
subordinates.json` diffs a pins file with `GET /federation/admin/subordinates` output. Then pin them one of two ways:

- **In the settings** (`OIDF_FEDERATION_SUBORDINATE_STORE=settings`, the default): `OIDF_FEDERATION_SUBORDINATE_PINS`
  is `{"https://rp.example.com": {"jwks": {"keys": [...]}, "entity_types": ["openid_relying_party"], "intermediate":
  false}}`. A change is a restart; the operator API reads these pins and refuses changes (409).
- **In the authority's store** (`OIDF_FEDERATION_SUBORDINATE_STORE=database`, migrations V105 and V106): ask to
  enrol through the operator API, with a token carrying `oidf.admin.subordinates`, and have it approved (below):

```sh
curl -sS https://pf.example.com/federation/admin/subordinates \
  -H "Authorization: DPoP $TOKEN" -H "DPoP: $PROOF" -H 'Content-Type: application/json' \
  -d '{"entity_id": "https://rp.example.com", "jwks": {"keys": [...]}, "entity_types": ["openid_relying_party"]}'
```

Before it pins anything, PingFederate fetches the subordinate's Entity Configuration and requires it to be
self-signed with one of the keys proposed. Otherwise it answers 422 with what it found - `unreachable`,
`not_self_signed`, `not_under_proposed_keys` or `invalid` - and pins nothing. When the keys are right but the
subordinate cannot be reached, or has not published them yet, send `"force": true` with a `"reason"` (at most 500
characters); the change is recorded as forced, and its approver sees `forced`. Entity Types or a flag that differ from
what the subordinate publishes are returned as `live_differs` and audited, not refused. A change that passes is not
applied: it is answered 202 with its `seq` and waits for approval.

For `unreachable`, the cause is in the server log, in a WARN line beginning `subordinate enrolment: no Entity
Configuration from`. The cause can be DNS, TLS trust, a timeout, or the outbound fetch policy. That policy refuses a
subordinate whose host resolves into a private range unless
[`OIDF_FETCH_ALLOW_PRIVATE_NETWORKS` or `OIDF_FETCH_HOST_ALLOWLIST`](../configuration/outbound-fetch.md) lets it
through. The rig showed this on 2026-10-07 with `host.docker.internal`.

`POST /federation/admin/subordinates/keys` with `{"entity_id", "version", "jwks", "reason", "entity_types"?,
"intermediate"?}` asks to change a pin, if it is still at `version` (202, pending); `POST /subordinates/remove` with
`{"entity_id", "reason"}` stops vouching for it at once - it only withdraws trust, so it needs no approval - and the
fetch endpoint answers `not_found` from the next request; it also withdraws any change waiting for the subordinate,
a held rollover included (reason `removed`), so a later enrolment is not blocked. `GET /subordinates` lists every pin (`pending` for an
enrolment not yet approved, which is never served); `?entity_id=` shows one with the monitor's last look at its URL
(`monitor`), the change waiting for it (`pending_change`) and, under the settings store, this node's own look
(`live`); `/subordinates/audit?entity_id=` its history. Every change names its operator in the history and
PingFederate's audit log (`federation.subordinate.change_requested`, `.enrolled`, `.changed`, `.removed`,
`.refused`); `oidf_federation_subordinate_changes_total` counts them by action and outcome.

## Subordinate monitor and change control

From 0.7.0 (plan item S7b, finding F-0012) a subordinate's pin changes only three ways, and divergence is never one:

- **An operator's change, approved.** An enrolment or key change waits as a PENDING change.
  `GET /federation/admin/subordinates/changes[?status=pending&entity_id=...]` lists them;
  `POST /subordinates/changes/approve` with `{"seq", "reason"?}` applies one and `/reject` refuses it, both with
  `oidf.admin.subordinates.approve`; `/withdraw` takes it back, by the operator who asked only. Approval applies the
  change only if the pin is still the one it was asked against, by thumbprint: one that moved meanwhile withdraws it
  and answers 409 `moved` (a removal has withdrawn it already: 409 `not_pending`). A change not approved within `OIDF_FEDERATION_SUBORDINATE_APPROVAL_TTL_SECONDS`
  (7 days) is withdrawn by the monitor (`federation.subordinate.change_expired`). One change waits per subordinate
  (409 `change_pending`).
- **Two-person approval.** `OIDF_FEDERATION_SUBORDINATE_APPROVAL=two-person` refuses an approval by the operator who
  asked (409 `same_actor`). Operators are compared by the token's `sub` - for client credentials the client id - so
  two people sharing one operator client are one actor and are refused, and one person holding two clients passes:
  it is as strong as the separation of the clients that carry `oidf.admin.subordinates` and
  `oidf.admin.subordinates.approve`. The development static bearer is one actor holding every scope.
- **A held rollover.** When a subordinate's Entity Configuration is self-signed (§10.2: "For ES[0], verify that its
  signature validates with a public key in ES[0]["jwks"].") by a key whose RFC 7638 thumbprint is in the pin, and
  lists another set, the monitor asks for a ROLLOVER change, held for
  `OIDF_FEDERATION_SUBORDINATE_ROLLOVER_HOLD_SECONDS` (a day; production refuses less), logs a WARN and emits
  `federation.subordinate.rollover_requested` - the alert the hold is for. At the end of the hold it applies the new
  set, as `system:rollover-hold`, only if the pin is still the one the change was asked against and a look at most
  one monitor interval old still shows the new set under a pinned key; a subordinate that cannot be reached keeps it
  waiting. A newer set supersedes it; no set an operator rejected against the pin as it is now is asked for again (a set
  rejected against an earlier pin may be). An operator may approve it before the hold ends, with a reason; under
  `two-person` too one approver is enough, since the rollover's requester is `system:rollover-hold`.

Anything else - a configuration signed by a key outside the pin, not self-signed, or invalid - changes nothing: the
subordinate is DIVERGED. During a hold the old pin is served alone: serving the union would hand whoever holds one
pinned key the keys he lists at once.

**The rollover overlap.** The hold only delays. A chain through this entity validates a subordinate's configuration
against the pinned keys (§10.2: "For each j = 0,...,i-1, verify that the signature of ES[j] validates with a public key
in ES[j+1]["jwks"]."), so from the moment the subordinate signs with a key outside the pin until the new set applies,
its chains fail. The specification asks a Trust Anchor rolling its own keys to "Keep signing the Entity Configuration
and the Entity Statements using the old keys for a long enough time period to allow all Subordinates to have obtained
the new keys." (§11.2); ask each subordinate to do the same: publish the new key beside the old and keep signing with
an old pinned key for the hold, plus one monitor interval, plus a Subordinate Statement's lifetime (3600 s) - 25 h 4 min
with the defaults. A subordinate that cannot wait that long needs its rollover confirmed out of band and approved
early.

**The monitor.** Under the database store one node at a time - whichever holds the `federation-subordinate-monitor`
lease - fetches each active subordinate's Entity Configuration every `OIDF_FEDERATION_SUBORDINATE_MONITOR_SECONDS`
(240) and records what it saw in V106's `federation_subordinate_observation`; its writes are fenced by the lease as the
key observer's are. Every node reads those rows for health and the operator API. A clustered node whose leases are
local elects nothing, so the monitor runs nowhere there and health says so. Under the settings store each node judges
what its own refresher saw, in memory; a rollover there shows ROLLOVER_PENDING and is never applied - re-pin the
setting.

Each active subordinate is in one state: IN_SYNC (self-signed by a pinned key, listing exactly the pin),
ROLLOVER_PENDING (a held rollover waits for the set it lists; under the settings store, any new set signed by a pinned
key), DIVERGED (anything else that answered, a rejected set included) or UNREACHABLE (not fetched for
`OIDF_FEDERATION_SUBORDINATE_UNREACHABLE_SECONDS`, 900). A change of state emits `federation.subordinate.state_changed`,
with a WARN for DIVERGED and UNREACHABLE; the gauge `oidf_federation_subordinates{state}` counts them on each node.
FEDERATION's `subordinate-monitor` health part is READY, or DEGRADED naming the counts and the first five DIVERGED or
UNREACHABLE subordinates, or that no node has looked for the unreachable window; never FAILED, since the pins are
served whatever the monitor sees.

Under production every `OIDF_FEDERATION_SUBORDINATES` entry needs a pin, or the federation servlet is
`FAILED_CONFIG` naming the entries without one. The operator API does not read that list, so with the database store
it still enrols on such a node; restart PingFederate once every entry is pinned. Under development such an entry is
still served with its live keys, with a WARN and `federation.subordinate.unpinned_served` once per subordinate.

## Changing PingFederate's signing key

From 0.7.0 the federation follows PingFederate's key without a restart, and from 0.7.0's key monitor (S6b) a new key
is published before anything is signed with it. OpenID Federation 1.0 §11.2 (quoted 2026-10-07) sets the order:
"Add the new keys to the jwks representing the Trust Anchor's signing keys in its Entity Configuration." - "Keep
signing the Entity Configuration and the Entity Statements using the old keys for a long enough time period to allow
all Subordinates to have obtained the new keys." - "Switch to signing with the new keys." - "After a reasonable time
period, remove the old keys."

Two jobs run with the federation servlet:

- **On every node**, every 30 seconds (`federation-key-monitor`): read the keys this node's PingFederate publishes,
  the cluster's active key and retired keys from the key history, and the observations, and sign with the active key.
- **On one node**, the holder of the `federation-key-observer` lease, every 30 seconds: record each key PingFederate
  publishes for `OIDF_FEDERATION_SIGNING_ALG` in `federation_key_observed` (V104) on the database's clock, and move
  the active key when a newer one has been published for `OIDF_FEDERATION_KEY_ACTIVATION_DELAY_SECONDS`.

The timeline of a rotation, with the default delay of 3600 seconds (an Entity Statement's lifetime):

| When | PingFederate | The federation |
|---|---|---|
| T | You make a new key active (static keys), or its rotation makes the next key active (dynamic keys) | Within a tick or two (the observer's tick, then each node's own) the new `kid` is in every node's Entity Configuration `jwks`, after the active key, and `federation.key.observed` is logged. Statements, Trust Marks and registration responses still carry the old `kid` |
| T + delay | - | At the observer's next tick the new key becomes active: `federation.key.activated` (audited) with the old `kid` and the new one, and the key history retires the old key. Every node signs with the new key within one tick (and one `OIDF_FEDERATION_KEY_REFRESH_SECONDS`) |
| T + delay + grace | - | The old key leaves the `jwks` and `/federation/historical_keys` stops listing it as valid (`OIDF_FEDERATION_KEY_HISTORY_GRACE_SECONDS`) |

Signing therefore lags PingFederate's own change by the delay: PingFederate's tokens carry the new key at T, the
federation's statements at T + delay. `0` signs with a new key at the observer's next tick; before the key monitor a new key
signed from the next read.

What PingFederate 13.1.3 publishes, from its code (`javap -c` of `pf-protocolengine-13.1.3.0.jar`, 2026-10-07): a key
is `CREATED`, `ACTIVE` or `RETIRED`. Static keys are published as the active one and the previous one, with no next
key, so a new static key signs in PingFederate the moment it is saved - the delay is what holds the federation back.
Dynamic keys publish the next key one rotation period early, in `CREATED`; the monitor never activates a key first
seen after the one PingFederate signs with, so it does not run ahead of PingFederate. `getKeyById` answers for a key
in any state, with its private key, which is how a node keeps signing with the active key after PingFederate moved on.

**Switching from dynamic to static keys gets no delay.** Saving static keys replaces every key PingFederate holds, the
dynamic ones included, so the active key's private key is gone at once: every node signs with the new static key
straight away (`federation.key.activation_skipped`) and the observer makes it the active key after the delay. Seen on
the rig on 2026-10-07 (`conformance/verify-key-rotation.sh`). Make that switch when no peer depends on a cached
Entity Configuration; rotations between static keys keep the previous key, and get the full delay.

**Never backwards.** Switching PingFederate back to an older key does not move the active key back while PingFederate
still publishes the newer one. An older key becomes active again only when PingFederate has not published the active
key for a whole delay (`federation.key.returned`, a WARN in the audit log) - for example, after the newer key was
deleted. A key PingFederate replaces under the same `kid` is used from the next read, with a warning in the log;
prefer a new `kid`, because a peer that cached the old key cannot tell them apart.

**Stale engines.** A node whose PingFederate does not yet have the active key - an engine that has not replicated the
new key from the admin node - signs with its own current key, logs `federation.key.activation_skipped`, and carries
that key in its `jwks` beside the active one, so what it signs verifies against this node's own Entity Configuration
(a peer that cached another node's does not have that key - see [limits](limits.md)). It moves to the active key within one
refresh of its PingFederate having it.

**Failover.** When the observer's node stops, another takes the lease within the lease TTL and a tick. If its
PingFederate is stale it keeps the active key: the key was seen by the old observer, and is not given up until it has
gone unseen for a delay.

When the key cannot be read - PingFederate has no key for the algorithm, or answers with the wrong kind -
`federation.key.read_failed` says why, the key read before keeps signing for at most 300 seconds past its
refresh, and after that signing answers 503 until a read works again. With no key at all at start-up the
federation servlet does not start.

Turn key history on (below) in production. Without it the observations and the history are kept in each node's
memory: the delay starts again after a restart, the historical keys endpoint is not served, there is nothing to revoke
a compromised key in, and a clustered node is refused under the production profile.

## Key history

With `OIDF_FEDERATION_HISTORICAL_KEYS=true` (and the federation migrations applied, V103 and V104), the cluster's
active key is recorded in `federation_key_current`, and only the observer's leader changes it. The key it replaces is
published as retired, at `/federation/historical_keys` and in the Entity Configuration's `jwks`, for its grace.
`GET /federation/admin/keys` shows the history; `POST /federation/admin/keys/revoke` with `{"kid", "reason"?}`
revokes a retired key (`unspecified`, `compromised` or `superseded`). A revoked key never signs again and never
becomes active: the federation servlet does not start with one, and a running node answers 503 rather than sign with
it. Rotate PingFederate's signing key before you revoke the one in use.

The grace must cover everything a retired key signed: at least the longest of every Trust Mark type's
`lifetime_seconds`, `OIDF_REGISTRATION_MAX_TTL_SECONDS` (a registration response's `exp` is the registration's end)
and an Entity Statement's 3600 seconds. A shorter grace stops the federation servlet under the production profile
(FAILED_CONFIG, naming the values) and logs a WARN under development. The SSF transmitter and automatic registration
sign with the same keys, so they fail to start on it too.

The observer's writes are fenced by its lease. With `OIDF_LEASE_BACKEND=jdbc` and the leases in the authority's
database (`OIDF_LEASE_DATA_STORE_ID` or `OIDF_LEASE_JDBC_URL` naming what `OIDF_AUTHORITY_DATA_STORE_ID` or
`OIDF_AUTHORITY_JDBC_URL` names), each write checks the lease row in its own transaction, so a leader that lost the
lease cannot write. With the leases anywhere else the write is checked against the lease's local clock just before it
is sent, a start-up WARN says so (not on a standalone node with the `local` lease backend, where there is no second
writer), and F-0525 records the gap.

A Trust Mark this entity mints is kept and served again for half its life, but only while the key that signed it is
the one this entity signs with: a key switch mints the next mark anew. A mark signed with a pending key, or a retired
key in its grace, has status `active`; one signed with a revoked key, `invalid`.

## Wiring a policy engine

1. Point PingFederate at an AuthZEN 1.0 PDP: `OIDF_PDP_MODE=authzen`, `OIDF_PDP_URL` (evaluation at
   `/access/v1/evaluation` under it), or `OIDF_PDP_EVALUATION_URL` for an endpoint elsewhere, or
   `OIDF_PDP_DISCOVER=true` to read it from the PDP's `/.well-known/authzen-configuration`. The URL must be https.
2. Authenticate to it: `OIDF_PDP_AUTH=bearer` or `header` with `OIDF_PDP_AUTH_TOKEN` (the header is
   `CLIENT-TOKEN` unless `OIDF_PDP_AUTH_HEADER` says otherwise, as the RAR plugin sends it).
3. Choose where it is asked: `OIDF_PDP_DECISION_POINTS` - `explicit_registration` and
   `automatic_registration` by default; add `hosted_entity_enrol` and `token_issuance` if you want them.
4. Give it a policy for the actions it will be asked about before you switch it on: every registration waits for
   it, and no decision is a 503.

What it is asked, for an automatic registration at the authorization endpoint:

```json
{
  "subject":  {"type": "federation_entity", "id": "https://rp.example.com",
               "properties": {"entity_types": ["openid_relying_party"], "trust_anchor": "https://ta.example.org"}},
  "action":   {"name": "federation.register.automatic",
               "properties": {"endpoint": "authorization", "entity_type": "openid_relying_party"}},
  "resource": {"type": "openid_provider", "id": "https://pf.example.com"},
  "context":  {"scope": "openid profile", "grant_types": ["authorization_code"],
               "redirect_uris": ["https://rp.example.com/cb"], "chain_expires_at": 1790294400,
               "request": {"tracking_id": "tid:..."}}
}
```

It answers `{"decision": true}` or `false`. A `true` may carry obligations in its `context`, and each only
narrows: `scope`, `grant_types` and `response_types` (keep only these), `registration_ttl_seconds` (a shorter
registration), `require_trust_mark` (a mark the entity must hold). At token issuance they are checks instead: a
token that doesn't meet them is refused. `reason_admin` goes to PingFederate's logs; `reason_user` is shown to
the client only with `OIDF_PDP_SURFACE_USER_REASON=true`.

Only a 200 with a boolean `decision` is an answer (AuthZEN §10.1.2). Anything else - an error status, a timeout
(2 s to connect, 3 s for the answer by default), a body that isn't a decision - is refused with a 503, unless
`OIDF_PDP_FAIL_OPEN=true`, which lets the request through unnarrowed and logs `federation.pdp.failopen`. To test a
PDP by hand, POST the request above to it:

```sh
curl -sS "$OIDF_PDP_URL/access/v1/evaluation" -H 'Content-Type: application/json' \
  -H "CLIENT-TOKEN: $OIDF_PDP_AUTH_TOKEN" -H 'X-Request-ID: manual-1' -d @request.json
```

## Reading the logs

Each decision is written as one line in `server.log`, on a logger named for its family -
`com.pingidentity.ps.oidf.federation.event.registration`, `.chain`, `.pdp` and so on:

```
event=federation.registration.refreshed outcome=success subject=https://agents.example.com/payments-agent partner=https://ta.example.com type=automatic endpoint=token entity_type=oauth_client expires_at=1790294400 previous_expires_at=1790208000 keys_changed=true
```

The parts come in a fixed order - `event`, `outcome`, `reason`, `subject` (the client or entity), `partner` (the
trust anchor, or the issuer), the event's own fields, `desc` - and PingFederate's log layout adds its
timestamp and tracking id in front. A refusal that matters for security is written at WARN; everything else at
INFO. The security-relevant events also go to PingFederate's `audit.log`, with the code as the event, `success` or
`failure`, the subject as the user, the partner as the connection, and the rest of the line as the description.
`OIDF_EVENTS_AUDIT=false` keeps them out of the audit log.

What never reaches an event: tokens (anything shaped like a JWT becomes `jwt:sha256:` and twelve hex digits of
its hash, so lines still correlate), control characters (a forged newline can't split a line), values beyond 512
characters (`OIDF_EVENTS_MAX_VALUE_LENGTH`), the admin token, the policy engine's obligation values, and its
`reason_user`. That covers the event lines only; the modules' ordinary log lines are written with the same care
but not by the same code.

Every code, and every field it may carry, is declared in its component's event catalogue: the federation events in
`libs/openid-federation`'s
`META-INF/oidf-events/federation.json`,
the attester's in `servlets/attestation-issuer`'s
`attestation-issuer.json`.
The catalogue gives each field one PII class - `OPERATIONAL`, `PSEUDONYMOUS_ID` (a client id, an entity
identifier, a workload's subject, and from 0.6.0 `actor`, the operator token's subject), `DIRECT_ID` (can name a
person: the operator events' `claimed_label`, whatever an administrator sends in `X-Federation-Actor`), `NETWORK` or
`CREDENTIAL_DIGEST` (a key's thumbprint, evidence's
SHA-256). The description (`desc=`) is free text with no class: it can carry an administrator's free-text
`reason`, the policy decision point's `reason_admin`, an exception message, client ids and key thumbprints. Inside
PingFederate every class is written to the audit log as it is; server.log carries a `DIRECT_ID` as `sha256:` and
twelve hex digits of it (from 0.6.0, finding F-0165), and every other class, and the description, as it did before the
catalogues existed. Whether to digest or drop more in one log is left to the PII policy of plan item D-6 (the platform
README's "events" section, finding F-0166). A field
an event's catalogue does not declare is dropped before any log sees it, and counted: the first drop of each code
and field is a WARN line naming the field, never its value.

| Event | When | Audit |
|---|---|---|
| `federation.registration.created`, `.refreshed` | A client was registered, or its registration renewed or replaced - explicit or automatic, at which endpoint, until when, and whether its keys changed | Yes |
| `federation.registration.refused` | A registration was refused: the chain, a missing metadata policy, a missing Trust Mark, the policy engine, or PingFederate dropping the extended properties | Yes |
| `federation.registration.expired` | A request found a registration past its end and not renewed; what happened next follows `OIDF_REGISTRATION_EXPIRY_ENFORCEMENT` | Yes |
| `federation.registration.disabled` | An expired client was disabled - by the request that found it, or by the sweeper | Yes |
| `federation.registration.refresh_deferred` | A due renewal failed but the registration hasn't expired, so it stands for now; `encrypted_request_object` when production would not renew from an encrypted request object (said once a renewal interval) | No |
| `federation.registration.expired_at_issuance` | The OGNL criterion found an expired registration at token issuance | Yes |
| `federation.chain.validated`, `.refused` | The OGNL criterion checked a client's chain at token issuance | Refused only |
| `federation.token.refused` | Token issuance refused by the policy engine, or for an obligation the token doesn't meet | Yes |
| `federation.pdp.consulted` | The policy engine answered (read `decision`), or gave no answer (`no_decision`) | Yes |
| `federation.pdp.failopen` | No answer, and `OIDF_PDP_FAIL_OPEN=true` let the request through | Yes |
| `federation.hosted_entity.enrolled`, `.suspended`, `.reactivated`, `.revoked`, `.updated`, `.rotated` | A hosted agent was enrolled or changed, and by whom | Yes |
| `federation.hosted_entity.refused` | The policy engine refused an enrolment | Yes |
| `federation.trust_mark.granted`, `.revoked` | A Trust Mark grant was made or revoked, and by whom | Yes |
| `federation.trust_mark.issued` | PingFederate signed a Trust Mark | Yes |
| `federation.trust_mark.verified` | Another issuer's Trust Mark checked out | No |
| `federation.client.authenticated`, `.refused` | A client authenticated at a federation endpoint, or was refused | Refused only |
| `federation.key.changed` | The key this node signs the federation algorithm with changed | Yes |
| `federation.key.observed` | The key observer saw a key PingFederate publishes for the first time; it is published as pending | No |
| `federation.key.activated`, `.retired`, `.revoked` | The observer made a key the cluster's active key, the key history retired the one before, or a retired key was revoked | Yes |
| `federation.key.returned` | The active key went back to an older one, the newer having gone unpublished for a whole delay | Yes, WARN |
| `federation.key.activation_skipped` | This node's PingFederate has no private key for the active key, so it signs with its own current key | No |
| `federation.key.read_failed` | PingFederate's current key could not be read, or was the wrong kind (`reason` `no_key`, `wrong_key_type` or `unreadable`): the key read before signs for at most 300 seconds more | No |
| `attestation.evidence.conflict` | The attester was shown instance evidence already bound to another instance key or client: read `evidence_sha256`, `evidence_type`, `instance_subject`, `presented_jkt` (the key refused) and `bound_jkt` and `bound_client` (the key and client that hold the binding). Either the rightful holder's evidence has been used elsewhere, or a thief presented it first and the rightful holder is the one refused: `bound_jkt` is then the thief's. Right after a workload restarts with a new key it is most likely neither (the attester's README, "Evidence binding") | Yes, with `protocol` `Client Attestation` |
| `attestation.issuer.client_refused` | A client's `attestation_*` configuration was refused, so the attester skips it and refuses its workloads with `invalid_client`: the subject is the client, `property` the property refused, and the reason `missing`, `malformed`, `above_ttl_cap`, `exceeds_ceiling`, `agent_id_configured` or `refused`. The value is never recorded; `server.log` has the WARN with the full message. Reported once per client until the refusal changes or the client loads again, so an index rebuild does not repeat it | Yes, with `protocol` `Client Attestation` |

Not everything is an event. Serving an Entity Configuration, a fetch, a list or a resolve isn't; a refusal at a
federation endpoint is a line on `com.pingidentity.ps.oidf.servlet.trustanchor.FederationErrors` (INFO for a
refusal, WARN for a 503, ERROR for a fault of ours), and it never reaches the audit log. Nor do a few registration
refusals that happen before any chain is checked - a client an administrator made, a request object that breaks
the rules - which the filters log on their own loggers.

Each audit record carries the caller's address in `ip`. The servlets, both filters and the OGNL criterion enter a
request scope as each request starts and leave it when the request ends, however it ends, so a pooled thread never
carries one caller's address into its next request. The address is the one PingFederate records for its own
events: behind a proxy it is the proxy's, unless PingFederate's incoming proxy settings name the header that carries
the client's (`forwarded_ip_address_header_name` on `pingfederate_incoming_proxy_settings`). `host` is PingFederate's
own - the name of the node that wrote the record - and `protocol` is the component's, from its catalogue:
`OpenID Federation` for the federation events, `Client Attestation` for the attester's. A record written off a
request or by the sweeper has no `ip`. The sweeper's lines carry a
tracking id of their own: from 0.7.0 its managed executor's, `oidf-registration-sweeper-` and eight hex digits
(`oidf-sweep-` before), and, like every line from 0.7.0, end with `ctx[...]` ([docs/operator/logging.md](../operator/logging.md)).

**Turning events into Shared Signals.** The SSF transmitter can listen to the same audit logger and send CAEP
events for the ones you map, for example
`OIDF_SSF_AUDIT_EVENT_MAP=federation.hosted_entity.revoked=account-disabled,federation.registration.disabled=account-disabled`.
Nothing is mapped by default, and only successes with a subject can be. It works only if PingFederate's
`log4j2.xml` declares the `com.pingidentity.sdk.logging.LoggingUtil` logger; SSF says at start-up how many audit
loggers it attached to.

## The registration sweeper

Every five minutes (`OIDF_REGISTRATION_SWEEP_INTERVAL_SECONDS`, `0` turns it off) a background task disables
federation clients whose registration has ended. It never deletes one, and a renewal enables it again; a client
an operator disabled stays disabled. It doesn't run while `OIDF_REGISTRATION_EXPIRY_ENFORCEMENT=log`, which
records expiries and enforces none - the setting for an upgrade, while relying parties catch up. One sweeper
runs per PingFederate, whichever component starts first.

## Upgrading

[The 0.3.0 release notes](../releases/0.3.0.md) say what to do before deploying: declare the extended
properties, apply the migrations, decide about clients registered before expiries were recorded, and
re-assemble `pf-runtime.war`.

To 0.7.0 with subordinates: with an authority store, run `oidf-db-migrate` to V106 first - the start-up schema
check holds the federation family to what the release ships. Under the database store an enrolment or key change
asked for through the operator API now waits for an operator's approval (202, `POST
/federation/admin/subordinates/changes/approve`) instead of applying at once: give the approver
`oidf.admin.subordinates.approve`. Before a production node starts, pin every
`OIDF_FEDERATION_SUBORDINATES` entry ([Pinned subordinates](#pinned-subordinates)): confirm its keys with its operator
out of band, compare them with what `GET /federation/admin/subordinates?entity_id=` shows a development node saw, and
enrol it or add it to `OIDF_FEDERATION_SUBORDINATE_PINS`.

To 0.7.0 with the resolve endpoint enabled: the per-caller cap now counts every resolution the cache could not answer,
not distinct subjects (F-0383), so a caller that repeats a failing resolution, or varies its anchors or entity types,
uses its allowance - 30 a minute unless `OIDF_FEDERATION_RESOLUTION_RESOLVE_SUBJECTS_PER_MINUTE` says otherwise. The
caller is now the client behind a proxy `OIDF_TRUSTED_PROXIES` lists (F-0382): behind a load balancer, list it, or
every client shares one minute; a value of that setting the federation part cannot read stops it at start-up
(`FEDERATION` `FAILED_CONFIG`), as it already stopped the challenge endpoints. A `federation.registration.refresh_deferred`
event with the reason `encrypted_request_object` means an RP whose registration is due keeps sending encrypted request
objects, which production does not renew from (F-0340): it renews with its next signed request object or PAR request,
and is refused once the registration expires.
