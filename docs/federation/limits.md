# Limits

What the federation support doesn't do, and where it is stricter than OpenID Federation 1.0 asks. Read this
before you promise a partner something. Each item says what happens instead.

## Not built

- **Checking old chain statements, status responses and delegations with an entity's historical keys.** From 0.8.0
  a Trust Mark another issuer signed with a key it has since retired can be checked with that key from the issuer's
  historical keys endpoint (§8.7), when `OIDF_FEDERATION_HISTORICAL_KEYS_CONSUME=true` - off by default, and only a key
  that was valid when the mark was signed, never one revoked as compromised, and never for a mark without `exp`
  ([operations](operations.md#trust-marks-under-a-retired-key)). Nothing else is: a statement in a chain is checked
  only with its superior's `jwks` (§10.2: "verify that the signature of ES[j] validates with a public key in
  ES[j+1]["jwks"]"), and one signed with a key since rotated fails and is fetched again; a Trust Mark status response
  and a delegation are checked with current keys only, because they are fresh or anchor-given. The other way round
  works from 0.7.0: PingFederate's own Entity Configuration carries its retired keys for their grace, so a peer
  checking something PingFederate signed just before a rotation still finds the key.
- **Rotation across a cluster.** From 0.7.0 one node - the `federation-key-observer` lease holder - records the keys
  PingFederate publishes and moves the active key, after `OIDF_FEDERATION_KEY_ACTIVATION_DELAY_SECONDS`; every node
  signs with that key ([operations.md](operations.md#changing-pingfederates-signing-key)). What is left: signing lags
  PingFederate's own key change by the delay; an engine whose PingFederate has not got the active key yet signs with
  its own current key until it has (`federation.key.activation_skipped`); and with the leases outside the authority's
  database the observer's history write is fenced only by the lease's local clock (F-0525). The Entity Configuration
  a node serves is built on that node, so two nodes can briefly publish different `jwks` while a tick passes (U-0025).
- **A held rollover only delays.** A rollover signed by a pinned key is applied after a hold (a day by default), or
  earlier on an operator's approval (S7b). Until then the old pin is served, so a subordinate that stops signing with
  its old pinned key at once fails its chains for the hold, plus one monitor interval, plus a Subordinate Statement's
  lifetime (25 h 4 min with the defaults): it must keep signing with an old key that long, or have its rollover
  approved early. There is no automatic path ([operations](operations.md#subordinate-monitor-and-change-control)).
- **Two-person approval is as strong as the operator clients.** Operators are compared by the token's `sub`: two
  people on one PingFederate client are one actor (refused), one person with two clients passes.
- **The subordinate monitor is one node's look.** Under the database store the elected node's fetches decide every
  state; a subordinate that answers that node differently from others is judged by what that node saw. Under the
  settings store each node judges its own look, and nothing is applied.
- **A self-signed agent rolling its own keys.** From 0.8.0 an operator re-keys a self-signed agent through
  `POST /federation/admin/entities/rotate-key` with its new public keys (`federation_jwks`), and the agent publishes its
  configuration again under the new key ([operations](operations.md#self-signed-agents)). The agent cannot do it
  itself, by signing a new key set with its old key: a stolen key could then pin the thief's key, so that waits for a
  hold-and-approve step like the one subordinates have. The authority does not publish a re-keyed agent's old keys
  at its historical keys endpoint either - §8.7 lets "Each Federation Entity" publish "its previously used Federation
  Entity Keys", and these were the agent's keys, not the authority's.
- **Other ways to authenticate at the federation endpoints.** `private_key_jwt` only (§8.8 lets a federation
  choose others).
- **The policy engine stopping a suspension or a revocation.** Deliberately: at `hosted_entity_suspend` and
  `hosted_entity_revoke` the policy engine is asked and its answer recorded, but nothing it says stops either, so an
  engine that is down or says no can never leave a compromised agent live. Every other step it can be asked at, it
  can refuse ([operations](operations.md#policy-at-each-step)).
- **A change seen at once on every node's resolve endpoint.** The node that suspends, revokes or re-keys an agent, or
  grants or revokes one of its Trust Marks, drops what its resolve endpoint kept about the agent at once. Another node
  in a cluster can answer from what it kept for up to `OIDF_FEDERATION_RESOLUTION_RESOLVE_CACHE_SECONDS` (60 by
  default); set it to 0 to close that window (F-0678).
- **The policy engine on a resolve response that was kept.** A response the resolve endpoint answers from what it
  kept (up to 60 seconds, F-0383) is served without asking again, whoever asks: with `resolve` listed, a permit for
  one anonymous caller is served to the next anonymous caller for the same request within the minute.
- **Per-client policy settings beyond two.** A client can ask about its own tokens
  (`federation_pdp_token_issuance=true`) and fail closed (`federation_pdp_fail_open=false`); every other PDP setting
  is the deployment's.
- **Per-client rate limits.** Deliberately: a stranger could spend a client's allowance in its name. Registration
  is limited by how many chains are checked at once, and so is endpoint client authentication; put a per-source
  rate limit in front of PingFederate if unauthenticated load worries you.
- **A different `client_id`.** A client registered from the federation is known by its Entity Identifier.
  §12.2.2 lets an OP issue another; this one doesn't.
- **Client authentication methods other than `private_key_jwt`** (and the attestation methods) for a relying
  party registering at the authorization or PAR endpoint. `client_secret_*` and `tls_client_auth` are refused as
  `invalid_client_metadata`.
- **Reading a request object by reference.** A `request_uri` other than PingFederate's own PAR one is never
  fetched - it would let anyone make PingFederate fetch any URL.
- **Checking an encrypted request object's claims.** Only its header can be read before PingFederate decrypts
  it, so the §12.1.1.1 checks on its claims can't be made there. PingFederate still decrypts it and checks the
  signature inside against the keys the relying party registered - but only after the relying party is registered,
  so under the production profile an encrypted request object never registers or renews one (it is refused with
  `invalid_request_object`; development registers it with a warning). A relying party registers with a signed request
  object or at PAR, and may then send encrypted ones. `OIDF_AUTO_REGISTRATION_ENCRYPTED_REQUEST_OBJECTS=refuse`
  turns every such request away instead.
- **A log of the Trust Marks PingFederate has issued.** Whether a mark is active comes from PingFederate's own
  signature on it and the grant it was issued under. A mark someone was given before its grant was revoked
  verifies until it expires, for anyone who doesn't ask the status endpoint.
- **Being a relying party in someone else's federation.** PingFederate registers others; it doesn't register
  itself with other OPs.
- **Keeping state without a database.** Hosted agents, Trust Mark grants and the key history live in the
  authority's database when one is configured, and in memory when not: with a warning under the development
  profile, and under production only with the `in-memory-state` risk accepted (the component that keeps them is
  refused otherwise, from 0.6.0). In memory they are gone at the next restart. A database must be PostgreSQL in
  production.

## Stricter than the specification

Each of these is a choice, made so that a gap fails closed. Each is a setting where it can safely be one.

- **A chain with no metadata policy for the role being registered is refused** (`OIDF_REQUIRE_METADATA_POLICY`,
  on by default). The specification would register the entity with whatever it asked for.
- **A critical claim or policy operator that isn't understood is refused.** This implementation understands
  none beyond the ones the specification defines, so any `crit` or `metadata_policy_crit` naming one fails the
  chain, as §3.2 and §6.1.3.2 require of anything not understood.
- **An empty `permitted` naming constraint permits nothing**, where the text could be read as permitting
  everything.
- **A peer chain must end at the same trust anchor** as the main one, where §4.4 says it SHOULD.
- **An entity that authenticates at the Trust Mark endpoint is given only its own marks.** §8.6.1 lets an
  endpoint hand one entity's marks to another; this one doesn't.
- **A client assertion at a federation endpoint may not be valid for more than ten minutes**, so its `jti` is
  remembered for as long as it could be used.
- **The resolve endpoint resolves only entities PingFederate knows** - itself, its subordinates and the agents
  it hosts - unless `OIDF_FEDERATION_RESOLVE_DISCOVERY=any` (§18.1).
- **One caller gets 30 resolutions a minute** (`OIDF_FEDERATION_RESOLUTION_RESOLVE_SUBJECTS_PER_MINUTE`). A request
  answered from a kept response (up to 60 seconds) is free; every other one counts, repeated and failing ones too,
  and one more is 503 with a `Retry-After`. Behind a load balancer, list it in `OIDF_TRUSTED_PROXIES`, or every
  client behind it shares one minute.

## About the conformance results

The OpenID Foundation suite's federation plans are alpha, and a run against a suite you host is not a
certification. PingFederate passes both plans it can be tested with, with a warning on every module about
PingFederate's own vendor metadata; [conformance](conformance.md) has the detail. The relying-party plan doesn't
apply: PingFederate isn't a federation relying party.
