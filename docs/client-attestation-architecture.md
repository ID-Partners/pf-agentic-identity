# Client Attestation — architecture, state, and gaps

What the client attestation pipeline is, what it does today, which standards it meets, what proves
that, and what is still missing. Written from the source on 2026-08-17, refreshed 2026-08-22 (§5, §6
and §8's test-coverage claims) and 2026-09-26 (PingFederate 13.1.3: §2.1, §4.2, §5.3 and three §6 items),
not recalled: every claim below was read at the file it describes, and every test count came from a
surefire run, not a grep.

This is the map. It does not restate the specs (see
[openid-client-attestation-service-1_0.md](openid-client-attestation-service-1_0.md)), the claim
layouts ([claim-dictionary.md](claim-dictionary.md)), or the per-module detail (the module READMEs) —
it says how they fit together and where the edges are.

---

## 1. What this is

An agent instance is ephemeral. It gets scheduled, runs, and dies; there is no sensible way to hand it
a client secret, and one registered OAuth client per running pod is not identity, it is an inventory
problem. So the pipeline splits the job in two.

**Issuance.** The instance proves *what it is* — a SPIFFE JWT-SVID, a GKE/EKS/AKS/Azure/GCP workload
token, or a Wallet Instance Attestation — to a **Client Attester**, and proves possession of a key it
just generated. The attester reverse-maps that evidence onto a registered OAuth client and mints a
short-lived **Client Attestation** JWT: `sub` = the client id, `cnf.jwk` = the instance's own key,
plus the workload facts and an RFC 9396 entitlement ceiling.

**Verification.** The instance then authenticates at PingFederate's token endpoint with that
attestation plus a fresh proof of possession — `attest_jwt_client_auth`. The attestation is the only
credential. No secret ever reaches the instance, the credential expires in minutes, and the authority
it can ask for is bounded at mint time rather than argued about at the token endpoint.

Both halves implement `draft-ietf-oauth-attestation-based-client-auth-11`. The issuance half has no
equivalent in that draft — the draft starts once the client already holds an attestation — so this
repo wrote the missing half up as its own spec draft, published in
[openid-client-attestation-service-1_0.md](openid-client-attestation-service-1_0.md).

---

## 2. Architecture

### 2.1 Components, by pipeline position

| Position | Module | Role | Artifact |
|---|---|---|---|
| Issue | `servlets/attestation-issuer` | The Client Attester: issuance endpoint, evidence validators, discovery, minting, per-client signing keys | `attestation-issuer-<version>.jar` |
| Issue (device) | `libs/device-instance`, `libs/app-attest`, `services/device-enrolment` | The device-resident path: App Attest → enrolment → instance registry → device attestation minter | `device-instance-<version>.jar`, `app-attest-<version>.jar`, `device-enrolment-<version>.jar` |
| Identity | `libs/agent-registry` | Mints/resolves `agent_id`, the per-running-instance pseudonym | `agent-registry-<version>.jar` |
| Verify | `libs/client-attestation` | The AS-side verifier, DPoP validation, challenge + replay stores, RAR containment | `client-attestation-<version>.jar` |
| Verify (trust) | `libs/openid-federation` | Attester trust via OpenID Federation trust chains; AS capability advertisement | `openid-federation-<version>.jar` |
| Enforce | `servlets/pf-integration` | The `/as/token.oauth2` filter, the OGNL issuance criterion and claim hooks, PF client store | `oidf.jar` |
| Consume | `plugins/rar-paz-plugin` | Bounds the PingAuthorize RAR decision by the attested ceiling | `pf.plugins.pf-rar-paz-plugin.jar` |
| Consume (RS) | `services/demo-rs` | Resource-server side: AS signature, DPoP proof, `cnf.jkt` equality, RFC 8693 `act` chain | `demo-rs-<version>.jar` |

Three of these load into PingFederate and the classloader they land on matters. `oidf.jar`,
`attestation-issuer` and their libraries are merged into `pf-runtime.war` at root context by
[`assemble-pf-runtime-war.sh`](../image/assemble-pf-runtime-war.sh) — that is why
`/federation/attestation` serves with no `/oidf` prefix. The same jars are *also* copied into
`server/default/deploy/` by the [Dockerfile](../image/Dockerfile), because the OGNL
hooks run on PF's engine classloader, which cannot see `pf-runtime.war/WEB-INF/lib`.

### 2.2 Issuance flow

```mermaid
sequenceDiagram
    participant W as Workload / instance
    participant A as Attester (attestation-issuer)
    participant R as AgentRegistry
    participant V as OpenBao transit

    W->>A: GET /federation/attestation/challenge (optional)
    A-->>W: {attestation_challenge, expires_in}
    W->>W: generate instance key; sign instance-key proof
    W->>A: POST /federation/attestation<br/>{instance_key, instance_attestation, proof, [authorization_details], [asserted_context]}
    A->>A: resolve client FROM EVIDENCE (try each client's trust config)
    A->>A: validate instance-key proof: sig under presented JWK, typ, aud,<br/>challenge consume, jti replay
    A->>A: custom proof claims; WIA cnf must equal instance_key
    A->>A: workload introspection; asserted-context narrowing (the model's meet)
    A->>A: RAR ceiling - rar-model authorize(requested, ceiling, INHERIT); empty = the full ceiling
    A->>R: resolveOrMint(iss, client_id, format, subject) (OIDF_AGENT_REGISTRY_MODE not off)
    R-->>A: agent_id and its status
    A-->>W: 403 instance_not_authorized when suspended or revoked (before the evidence is bound)
    A->>V: sign (or inline JWK, dev)
    V-->>A: signature
    A-->>W: 200 {attestation, expires_in}  Cache-Control: no-store
```

The step worth pausing on is the first one inside the attester. **The workload never names a client.**
It presents only its evidence; the attester tries every attestation client's trust config, and the
client whose bundle cryptographically verifies the evidence *and* whose bindings contain the resulting
identity is the match. A `client_id` in the body is accepted and ignored. Two clients matching the same
identity is a configuration fault and is rejected rather than resolved arbitrarily
(`AttestationIssuanceServlet:578-650`).

An `agent_id` anywhere in the request — top level or smuggled inside an `authorization_details` entry —
is rejected outright, not ignored (`:699`, `:756`). It is the attester's to mint.

### 2.3 Token-endpoint flow

```mermaid
sequenceDiagram
    participant W as Workload / instance
    participant F as ClientAttestationAuthFilter<br/>(webapp classloader)
    participant PF as PingFederate token endpoint
    participant O as OGNL issuance criterion<br/>(engine classloader)
    participant P as PingAuthorize (via RAR plugin)

    W->>F: POST /as/token.oauth2<br/>OAuth-Client-Attestation + (PoP | DPoP)
    alt no attestation header
        F->>PF: pass through untouched
    else attestation present
        F->>F: ClientAttestationVerifier.verify(...)
        F->>F: refresh grant: token bound to this cnf key? (X-E15)
        F->>F: mint bridge client_assertion (ES256, iss=sub=client_id)
        F->>PF: forward with client_id + client_assertion,<br/>client_secret dropped, Authorization suppressed
    end
    PF->>PF: native private_key_jwt authentication
    PF->>O: access-token mapping issuance criterion
    O->>O: verify the SAME attestation again (own replay cache)
    O->>P: publish attestation context (request attribute)
    P-->>PF: bounded authorization_details
    PF-->>F: token response (held while attested)
    F->>F: bind the issued refresh_token to the cnf key (X-E15)
    F-->>W: access token (cnf.jkt bound; act chain), refresh token
```

**Why a servlet Filter and not an SDK plugin.** PingFederate has no native support for
`attest_jwt_client_auth` and no SDK extension point for client authentication. The filter is
registered in the deploy image's web.xml, as [`filters.xml`](../image/filters.xml) declares it, and
the war assembler fails the build unless the mapping is present exactly once, over exactly its declared paths and
after `OidfAutoRegistration`
(`build/war-assembler`).

**Why it is verified once.** The filter runs on the webapp classloader and the OGNL criterion on the
engine classloader, and either can verify an attestation. Verifying spends the PoP `jti` and any
challenge, so a second verification of the same request would report a replay as soon as both
classloaders share a Redis store. The filter therefore publishes what it verified as a server-side
request attribute and the criterion reuses it; only a deployment without the filter has the criterion
verify for itself
(`ClientAttestationAuthFilter:59-64`,
`ClientAttestationUtils:128-138`).

**Refresh tokens are bound to the instance key (X-E15, F-0767).** ABCA-11 §10.3 says "the refresh token MUST be bound
to the Client Instance Key, and the Client Instance MUST use the same key that was present in the cnf claim of the
Client Attestation that was used when the refresh token was issued". PingFederate binds a refresh token to the client
only, and the bridge assertion names only the client, so the filter keeps the binding itself
(`RefreshTokenBinding`). For an attested token request it holds PingFederate's response with the response belt's
wrapper (`IssuedDetailsBelt.Held`). A 2xx JSON body with a `refresh_token` is bound before the client sees it: the
SHA-256 of the token, the RFC 7638 thumbprint of the `cnf` key, the client and the grant's expiry go into the attestation
store. On `grant_type=refresh_token`, a token bound to another key or another client is refused 400 `invalid_grant`
(RFC 6749 §5.2), and so is a bound token presented without an attestation. In combined mode the bound key is the DPoP
key, because the verifier holds the DPoP proof to the `cnf` key. A rotated token is bound too, and the one it
replaces stays bound through PingFederate's grace period. A token with no binding (issued before 0.8.0) passes under `OIDF_ATTESTATION_REFRESH_BINDING=on`, the
default, with `attestation.refresh.unbound`, and is refused under `strict`. The store failing either way is 503:
an unreadable binding refuses the refresh, and an unwritable one withholds the issued token and revokes its grant. A
client's `attestation_refresh_binding` can only raise the server's level. `off` needs the `refresh-binding-off` risk
under production.

**Fail-closed, and the one way it is not.** An invalid attestation is rejected at the filter with the
draft's error codes and never reaches PF; an internal error returns 500 rather than falling through
credential-less. A request with *no* attestation header passes through untouched, so the filter can
never widen access — PF still enforces whatever that client is configured for. The exception is the
bridge signing keys: with none configured, an attestation-bearing request also passes through
unbridged. That is not a security hole (PF then rejects it for want of a credential), but it would mean
the whole method is silently inert on a deployment that forgot to configure it — so the filter now
refuses to start instead, unless `OIDF_ATTESTATION_REQUIRE_BRIDGE_KEY=false` says the operator meant
it. A single client with no key is the narrower case: that client cannot authenticate, and every other
client is unaffected.

### 2.4 The three key hierarchies

Easy to conflate, so stated separately.

| Hierarchy | Who holds the private key | Configured by | Code |
|---|---|---|---|
| **Attester signing** — signs the minted attestation | The attester, per client | `attestation_signing_key_ref` (OpenBao transit, key never leaves the vault) **or** `attestation_signing_jwk` (inline, development only - refused in production). Exactly one. In production every transit key must be listed in `OIDF_ATTESTER_SIGNING_KEYS` with the issuers it signs for; federation and CIMD clients are signed with `OIDF_ATTESTER_SIGNING_KEY_REF` and never with a key their entry names. A rotated key signs within `OIDF_ATTESTER_SIGNING_KEY_REFRESH_SECONDS` (X-B04) | `SigningKeyPolicy` over `AttesterSigningKey` |
| **Instance key** — signs the PoP/DPoP, and the issuance-time proof | The instance itself; generated locally, public half carried as `cnf.jwk` | nothing — presented per request | `InstanceKeyProofValidator`, `DpopProofValidator` |
| **Bridge signing** — signs the `client_assertion` the filter hands PF | **Per client**, like attester signing | `OIDF_BRIDGE_SIGNING_KEYS` maps client id → `key_ref` (OpenBao transit) or `jwk` (inline, dev); `OIDF_BRIDGE_SIGNER_BACKING` declares which, and is enforced. The public half is the client's **own registered JWKS** — from its entity statement or from an administrator — so nothing is injected at registration | `BridgeSigners` |

Attester *trust* on the AS side is a fourth, separate thing: `FederationAttesterKeyResolver` walks an
OpenID Federation trust chain from the attester to the anchor; `StaticAttesterKeyResolver` is a
pre-registered map marked dev/demo only; `FallbackAttesterKeyResolver` tries the static list first and
federation for everything else.

A chain that validates can be made not enough (plan item X-E07, F-0755, from 0.8.0). With
`OIDF_ATTESTATION_REQUIRED_TRUST_MARKS`, or a client's `attestation_required_trust_marks`, which adds to the global
list for that client and can never remove a type from it, the attester must also hold a valid OpenID Federation Trust Mark of each listed type.
`AttesterTrustMarkGate` checks them with `TrustMarkValidator` against the anchor the chain reached, once the chain
validates. The anchor's `trust_mark_issuers` must recognise the issuer for the type (OIDFED §7), and the mark must be
signed, about the attester and unexpired (§7.3). An attester without one is refused `invalid_client_attestation`
(401) and the gate emits `attestation.attester.trust_marks_refused`. A required mark left unchecked (the
resolution budget ran out, or the issuer's chain, the anchor's configuration or the issuer's status endpoint could
not be fetched) is 503 `temporarily_unavailable`, like an unreachable chain, and is never cached. A statically trusted attester
(`oidf.mock.attesters`) holds no marks, so any requirement refuses it: the check fails closed. A verdict that lets an
attester through is reused until the earliest of the marks' `exp`, the chain's expiry and
`OIDF_ATTESTATION_TRUST_MARK_CACHE_MAX_SECONDS` (3600 by default, 0 to 86400). A reused verdict asks no status
endpoint: with `OIDF_FEDERATION_TRUST_MARK_STATUS_CHECK` on, the cap bounds how long a mark revoked at its issuer stays
accepted; with it off, the default, a revoked mark is accepted until its own `exp`.
`oidf_attestation_attester_trust_marks_total{outcome}` counts `satisfied`, `cached`, `missing` and `unchecked`.
Both lists are empty by default, and then no mark is checked.

The bridge key deserves its own note because it is the least documented and the most load-bearing. It
is a **single deployment-held key that can mint a `private_key_jwt` for any attestation client** — it
is registered in all of their JWKS. Compromise it and you can authenticate as any of them without any
attestation at all. The filter also suppresses the `Authorization` header on the bridged request
(`BridgeAuthRequest:262-271`) so PF cannot read stale Basic credentials that no longer match the
injected parameters, and drops `client_secret` for the same reason.

### 2.5 Client metadata resolution

Before the attester can reverse-map evidence onto a client, it needs the set of attestation clients and
each one's issuance config — evidence type, trust bundle, bindings, ceiling, signing key. The CAS spec
draft (§6.2) names three sources and ranks them by who vouches for the metadata: **OpenID Federation**
(the trust anchor vouches — high), **CIMD** (an unsigned document at an HTTPS URL — low, self-asserted),
and **local registration** (the operator vouches). The spec says try them in that order, first hit wins.

What the code does
(`AttesterResolvers.fromEnvironment`):

| Order | Source | Enabled by | Produces config via | Vouched by, in practice |
|---|---|---|---|---|
| 1 | OpenID Federation entity | `OIDF_ATTESTER_FEDERATION_ENTITY` | `OpenIdFederationClientResolver` → `FederationClientMapping.toConfig` | The **trust anchor**: the entity's chain is validated to one of the pinned anchors (`OIDF_FEDERATION_TRUST_ANCHOR_JWKS`) and the bindings are read from its verified configuration. Since 2026-09-25; before that, its own self-signature only |
| 2 | CIMD | `OIDF_CIMD_CLIENTS` (with `OIDF_CIMD_TRUST_BUNDLES`) | `CimdClientResolver` → `CimdDocument.parse` → `AttestationIssuanceConfig.fromProperties` | The **operator** for the issuer, evidence type, trust root, subject prefixes and signing key; TLS + control of the client's URL for its instances and ceilings only, one document per client (since 2026-10-08, X-B02; before that one document at `OIDF_ATTESTER_CIMD_URL` named every client's trust roots) - see §6 |
| 3 | PF client store | always | `PfIssuanceClientResolver` → `AttestationIssuanceConfig.fromProperties` | The operator, via `attestation_*` extended properties; `isEnabled()` filtered |

Three things to know about the chain, all of which shape §6:

- **The order follows the spec** since 2026-09-25: federation, then CIMD, then the PF store. Resolution is
  first-match per client id with no field-level merge (`ChainClientResolver`), so a client id present in
  two sources yields the higher-assurance copy, whole. (CIMD used to be tried first.)
- **Both external sources build one config per client.** The federation source groups an entity's
  `spiffe_client_bindings` entries by `client_id` (`FederationClientMapping.toConfig`, X-B03), with the client's
  `spiffe_client_ceilings` entry as its client-level ceiling; `CimdDocument.parse` does the same for a CIMD document
  (2026-10-08). So the instance-⊆-client containment rule fires for both, and the attester's
  `OIDF_ATTESTER_EXTERNAL_CEILINGS` cap (`ExternalCeilings.apply`) then narrows every ceiling either declares.
- **Registration status is a PF-store concept only.** `PfIssuanceClientResolver:77` drops disabled
  clients before they can match. CIMD and federation have no status of their own: presence in the document
  is the gate. For federation the anchor is the status - an entity it stops vouching for loses its clients
  within the 300 s TTL, and only an outage serves the last answer. A CIMD client's last good document is served
  through a fetch failure for at most `OIDF_CIMD_MAX_STALE_SECONDS` (1 hour by default), and a document that
  fetches but is refused drops the client at once. There is no check on any
  path that the client is registered for `attest_jwt_client_auth` — on PF the bridge means every
  working client is registered as `private_key_jwt`, so a naive check would reject all of them; the
  signal `PfIssuanceClientResolver:82` actually uses is the presence of `attestation_issuer`.

---

## 3. What is implemented

### 3.1 Surfaces

| Method + path | Class | Notes |
|---|---|---|
| `POST /federation/attestation` | `AttestationIssuanceServlet` | Issuance. `200 {"attestation","expires_in"}`, `Cache-Control: no-store` |
| `GET /federation/attestation/challenge` | `AttestationIssuanceChallengeServlet` | The attester's challenge endpoint (CAS §4.1), for the instance-key proof. `{"attestation_challenge","expires_in"}`, issued into `oidf:cas:challenge:*` |
| `POST /federation/attestation-challenge` | `ClientAttestationChallengeServlet` | The authorization server's (ABCA-11 §6.3), for the PoP at the token endpoint. Ships in the `client-attestation` jar, not the issuer. `{"attestation_challenge","expires_in"}`, issued into `oidf:as:challenge:*`. Neither surface accepts the other's challenges, and each endpoint answers any method but its own with 405 |
| `GET /.well-known/client-attester`, `/federation/.well-known/client-attester` | `AttesterConfigurationServlet` | Deployment discovery: endpoints, evidence types read off the validator registry, `evidence_audience`, `pop_audience`, active resolver plugins |
| `GET /federation/attester-configuration?client_id=` | same | Per-client view: issuer, evidence audience, trust domain, RAR type names. Ceiling, bindings and signing config deliberately withheld |
| `GET /.well-known/client-attestation-service` | `ClientAttestationServiceMetadataServlet` | The CAS 1.0 §5 document. Reads the same config the issuance servlet enforces, so advertisement cannot drift from enforcement |
| Filter over `/as/token.oauth2` | `ClientAttestationAuthFilter` | Registered as `ClientAttestationAuth` by the deploy image |

### 3.2 Verification pipeline

In order, from `ClientAttestationVerifier.verify` — the ordering is the point, authentication
completes before any authorisation happens:

1. `OAuth-Client-Attestation` required. Exactly one of `OAuth-Client-Attestation-PoP` or `DPoP`; both
   or neither is `invalid_client`.
2. A `~` anywhere in the attestation is refused — that is the retired SD-JWT presentation encoding.
3. Attestation: `typ` must be one of `OIDF_ATTESTATION_ACCEPTED_TYPS` (default `oauth-client-attestation+jwt`;
   ABCA-11 §4 lets a profile name another, and a client's `attestation_accepted_typs` can only narrow the list);
   `iss` resolves the attester's keys through `AttesterKeyResolver` (using a `trust_chain` JWS header if present);
   expiry maps to `use_fresh_attestation`, not a generic failure.
4. `cnf.jwk` asserted public-only. A `client_id` request parameter, if present, must equal `sub`.
5. Required-disclosure policy: every claim in `requiredDisclosedClaims` must be there, else
   `insufficient_disclosure`. `workload` must be a non-empty object, `authorization_details` a non-empty array and
   `agent_id` a non-blank string; any other name must be present with a value other than null. Until 0.8.0 any other
   name passed unchecked, so a misspelling switched its requirement off (F-0735); the filter now logs each global
   name and its check at start.
6. Proof of possession:
   - **PoP mode** — `typ=oauth-client-attestation-pop+jwt`, verified under the `cnf` key; `aud` must be
     in the accepted set (an *empty* accepted set is `invalid_client` "Server misconfigured", not a
     pass); PoP `iss`, when present, must equal `sub`; `iat` freshness with skew; challenge consumed;
     `jti` replay-checked.
   - **DPoP combined mode** — full RFC 9449 validation, then `Jwks.assertSameKey(cnf, proof.jwk)`;
     the challenge comes from `nonce`, and a missing or unknown one is `use_dpop_nonce` (ABCA-11 §5.2, from
     0.8.0; before, `use_attestation_challenge`); `jti` replay-checked. The nonce is the authorization server's
     challenge store's, not PingFederate's, so PingFederate's own `dpop_proof_require_nonce` must be off where the
     filter handles combined mode; the profile tool refuses the two together (F-0732, below).
7. Minimum levels (plan item X-E08, F-0760): `key_storage` and `user_authentication` (OpenID4VCI 1.0 Appendix D) are
   read as the level the attestation can be relied on for, a string or an array taken at its weakest value, and
   compared with the client's minimum on ISO/IEC 18045's order (basic < enhanced-basic < moderate < high). A level
   below it, a missing claim, or a value outside the four is `invalid_client_attestation`, with the
   `attestation.level.refused` event. No minimum, the default, checks nothing. Checked after the proof, so only a
   caller holding the attested key learns which level fell short.
8. *Then* the token gate (`AuthorizationDetailsGate`, plan item S1b): the request's `authorization_details`
   strictly within the attestation's, by `libs/rar-model`'s `contains`, after the `_principal_sub` and
   `_agent_id` markers come off; 400 `invalid_authorization_details` when not.

`DpopProofValidator` explicitly does not do replay or challenge binding — those are the caller's, and
the verifier supplies them.

### 3.3 Issuance pipeline

From `AttestationIssuanceServlet.issue`: require `instance_key` / `svid` (alias
`instance_attestation`) / `proof` → resolve the client from evidence → validate the instance-key proof
(signature under the *presented* JWK, `typ`, `aud` = attester issuer, challenge consume, `jti` replay
at 300s; a store that cannot answer is 503 `temporarily_unavailable`) → deployment-required custom proof
claims (evidence for policy only, never copied into the minted JWT) → if the evidence binds a key (a WIA
`cnf`) it must equal `instance_key` → workload introspection merged over binding metadata → optional
asserted-context resolution, **intersected** into the ceiling and never unioned → RAR ceiling
(`authorize`, or the full ceiling when nothing was requested) → `agent_id` → the evidence policy (lifetime,
whole and remaining, at most `OIDF_ATTESTER_MAX_EVIDENCE_LIFETIME_SECONDS`, one audience when
`OIDF_ATTESTER_REQUIRE_SINGLE_AUDIENCE_EVIDENCE`) → bind the evidence's digest, the SHA-256 of its JWS
Signing Input, to the instance key's thumbprint and the client for as long as the evidence lives, last so a
request refused by any check never takes the binding (first presenter wins, the same presenter may return,
anyone else is 401 `instance_attestation_bound` and an `attestation.evidence.conflict` audit event naming
both keys) → mint and sign, `exp` never past the evidence's. The minted `workload` carries
`instance_attestation_sha256`, `_type` and `_exp` and never the evidence itself (0.3.0's `workload.svid`
and `workload.instance_attestation` are gone; see §6).

One thing the code comments promise and the code does not deliver: step 6 reads "resolve the granted
entitlement against the effective ceiling, then apply any selector-conditioned downscoping the policy
requires" (`AttestationIssuanceServlet:226-227`). Only the first clause exists. The introspected
selectors and the binding's metadata (`version`, region, whatever the operator declared) are merged
into `workloadAttributes` and passed to the minter as `workload.attributes` — they are **never read by
any ceiling computation**. The only narrowing that happens is the asserted-context intersection, and
that is keyed on a caller-supplied discriminator, not on evidenced attributes. See §6 and §8.

SPIRE's selectors come from the SPIRE entry reader,
`services/spire-entry-reader` (plan item X-B07): a read-only sidecar
beside SPIRE Server that answers over mutual TLS with every registration entry for a SPIFFE id. Since 0.8.0 the
attester reads it (X-B08) with a PingFederate SSL client key pair, keeps only the selectors every entry holds, and adds
them to the instance's verified selectors as `spire:*`; the old unauthenticated GET is gone ([F-0140](findings.md#f-0140)).
Attestations never carry them.

The `agent_id` policy follows `OIDF_AGENT_REGISTRY_MODE` (X-A22, since 0.8.0): `off`, the default, means no
claim and issuance proceeds (0.7.0's behaviour); `memory` or `database` means every attestation carries
`agent_id` or the request is refused - never minted without. A registry that did not start (the
`AgentRegistryListener` part of ATTESTATION_ISSUER failed or was refused) or does not answer is 503
`temporarily_unavailable`; an agent an operator suspended or revoked (`/federation/attestation/agents/*`) is 403
`instance_not_authorized`, "this agent instance is suspended" or "... revoked", before the evidence is bound. The
operator's reason is never in the answer. Since X-E11 the token endpoint reads the registry too, at every attested
request when `OIDF_CLIENT_REVOCATION_MODE` is live (the default once a register is configured), so an agent's
attestations already minted stop authenticating once it is suspended or revoked (401 `invalid_client`), rather than at
their `exp`; the device-instance registry is read the same way
([attestation-token-endpoint.md](configuration/attestation-token-endpoint.md)). The token-endpoint filter makes that
check. The OGNL issuance criterion makes the same one for a request the filter did not verify (a deployment without the
filter), but it runs in PingFederate's engine copy, which cannot read the registers, so there a check that applies
refuses every attested token. Start-up cannot detect such a deployment (nothing of this repository starts in a webapp
without the filter), so it is not refused there: the criterion's first call logs one line naming
`OIDF_CLIENT_REVOCATION_MODE` and the filter, ERROR under production and WARN under development, and the refusal stands.

Since X-E13 a status change is also announced. Both registers report each committed move to a status-change hook
(`ClientStatusChangeListener` in `libs/platform`), whichever path made it: an operator API, SCIM, or an inbound CAEP
signal. With `OIDF_CLIENT_REVOCATION_CAEP=true` the SSF transmitter turns each move into a SET about
`{"format": "opaque", "id": agent_id}`:

- CAEP `session-revoked` for revoked;
- RISC `account-disabled` for suspended;
- RISC `account-enabled` for reactivated.

A change that an inbound SET caused is not sent back to the stream whose audience is that SET's issuer. This
platform's own receiver acts on the same subjects, so two deployments round-trip each other's revocations. Tokens
already issued still live until they expire (F-0772): PingFederate's grants are not keyed by `agent_id`. See
the SSF module.

Since X-E12 the same statuses are also published as a Token Status List (`draft-ietf-oauth-status-list-21`), so a
verifier that cannot read the registers can still see a revocation:

- **The index.** Every workload agent (`agent_identity.status_idx`, V202) and device instance (IOM `attrs.statusIdx`) is
  given an index when it is registered or enrolled. The index is random in [0, 2^20), unique in its register and never
  reused. It is random because §12.4 and §12.5.1 name "non-sequential, pseudo-random or random indices" as the
  mitigation for tracking, and a sequence would leak enrolment order. The IOM schema belongs to idp-scim-service, so
  there the index is kept unique by a check under a PostgreSQL advisory lock rather than a constraint.
- **The list.** It is not a second copy of the statuses. Each entry is the register's own status of the instance that
  holds the index, read from PostgreSQL when the list is rendered, so every node of a cluster serves the same list. A
  node holds a rendering for at most 5 seconds; the status-change hook (X-E13) drops it at once on the node that made the
  change. The list is 2 bits wide: VALID, INVALID for revoked, SUSPENDED.
- **Who serves it.** The attester (`OIDF_ATTESTER_STATUS_LIST_URL`) serves one list per attester issuer at
  `/federation/attestation/status/{list}`, signed under `SigningKeyPolicy` with `OIDF_ATTESTER_SIGNING_KEY_REF`. The
  enrolment service (`ENROLMENT_STATUS_LIST_URL`) serves its device instances' list, signed with the key its
  attestations are signed with. Each list's `ttl` and `exp` come from `OIDF_ATTESTER_STATUS_LIST_TTL` or
  `ENROLMENT_STATUS_LIST_TTL`, and `Cache-Control: max-age` is what is left of it.
- **The claim.** With a list on, both minters add `status: {status_list: {idx, uri}}`.
- **The check.** `OIDF_CLIENT_REVOCATION_MODE=status_list` or `both`, or a client's `attestation_revocation_mode`, has
  the token endpoint read the entry through B06's `StatusListClient`. The client moved to `libs/oidf-jose` for this; it
  verifies the list with the keys the attestation verified under. An entry that is not VALID, an index outside the list,
  or an attestation without the claim is 401 `invalid_client`. A list that cannot be fetched or verified is 503,
  fail-closed. The OGNL criterion runs the same check, and unlike the register check it can, since the list is fetched
  over HTTP.

### 3.4 Evidence catalogue

`InstanceAttestationValidators.defaults()` — the id is the client's `attestation_evidence`:

| Id | Validator | Format family |
|---|---|---|
| `spiffe-jwt` | `SpiffeInstanceAttestationValidator` | `spiffe` |
| `gke-sa-token` | `GkeTokenValidator` | `spiffe` |
| `gcp-id-token` | `GcpSaTokenValidator` | `spiffe` |
| `eks-sa-token` | `EksTokenValidator` | `spiffe` |
| `aws-sts-web-identity` | `AwsStsWebIdentityValidator` | `spiffe` |
| `aks-sa-token` | `AksWorkloadIdentityValidator` | `spiffe` |
| `azure-mi-token` | `AzureManagedIdentityValidator` | `spiffe` |
| `wallet-instance-attestation` | `WalletInstanceAttestationValidator` | `wallet` |

The wallet entry is registered with an **unconfigured key resolver** so the id is always discoverable
and config-validatable, and any actual WIA fails loudly until wallet-provider trust is configured. It is
the one non-cloud type that requires `attestation_trust_domain`: for a wallet it is the provider pin (from
0.8.0, F-0632).
Adding an evidence type means registering one plugin — supported-types, trust-domain requirements and
the discovery document are all derived from this registry.

### 3.5 Error codes

Issuance (`POST /federation/attestation`, CAS §4.6) and verification (`ClientAttestationException`). The issuance
endpoint answers with the draft's codes only (F-0392, 0.7.0); the validators' internal reasons `invalid_svid` and
`spiffe_id_not_authorized` stay in the log and the metrics, and are answered as `invalid_instance_attestation` and
`instance_not_authorized`:

| Issuance code | HTTP | | Verification code |
|---|---|---|---|
| `invalid_request` | 400 | | `invalid_client` |
| `invalid_client` | 401 | | `invalid_client_attestation` |
| | | | `use_attestation_challenge` |
| | | | `use_dpop_nonce` |
| `invalid_instance_attestation` | 400 | | `use_fresh_attestation` |
| `invalid_instance_proof` | 400 | | `invalid_authorization_details` |
| `instance_not_authorized` | 403 | | `insufficient_disclosure` |
| `access_denied` | 403 | | |
| `instance_attestation_bound` | 401 | | |
| `server_error` | 500 | | `temporarily_unavailable` |
| `temporarily_unavailable` | 503, or 429 with `Retry-After` past the per-address limit | | |

At the filter, `use_attestation_challenge` and `use_dpop_nonce` return 400 with a fresh challenge in
`OAuth-Client-Attestation-Challenge` or `DPoP-Nonce` (from 0.8.0, plan item X-E02: `ErrorChallenge`, counted against
the challenge endpoint's per-caller cap; over the cap the 400 goes out without the challenge header but with
`Retry-After`, the seconds until the cap's window lets the caller mint again, and a store that cannot record the
challenge, or is refused outright by its settings, makes the answer 503 `temporarily_unavailable`; so does a store
refused or unreachable when the filter builds the verifier, where `AttestationSupport` throws `StoreUnavailableException`),
`temporarily_unavailable` 503 (the challenge or
replay store could not answer; the code is RFC 6749 §4.1.2.1's, which RFC 6749 defines for the
authorization endpoint only, so its use here is plan item S3a's decision) and everything else 401; an
internal error is 500 `server_error`.

**Combined mode and PingFederate's DPoP nonce (F-0732).** The filter's `use_dpop_nonce` nonce comes from the
authorization server's challenge store (`oidf:as:challenge:*`), and the filter forwards the `DPoP` header to
PingFederate unchanged. PingFederate has a DPoP nonce requirement of its own, `dpop_proof_require_nonce`
(`deploy/terraform/modules/base`, `modules/fapi2`; the profile's `fapi2.dpop_require_nonce`, off by default). With
both on, PingFederate answers `use_dpop_nonce` with its nonce, which the filter's store refuses, and the filter's nonce
is unknown to PingFederate, so a generic RFC 9449 client loops between two issuers. PingFederate's must be off where
the filter handles nonces; only then does a client find the nonce where RFC 9449 §8 puts one. `tools/profile.py`
(`check`, and `render` and `author`, which run the same validation) refuses a profile that turns on
`fapi2.dpop_require_nonce` while `attestation.auth` is on, naming both and saying to turn PingFederate's off, since
the filter issues the nonce. A configuration made outside the profile tool is not checked.

### 3.6 Configuration

**Per-client PF extended properties — verification** (read by `AttestationPolicyResolver` from
PingFederate's client manager, for the filter and the criterion alike from 0.6.0): `attestation_pop_max_age`,
`attestation_dpop_max_age`, `attestation_clock_skew`, `attestation_challenge_required`, `attestation_expected_htu`,
`attestation_accepted_algs`, `attestation_pop_algs`, `attestation_dpop_algs`, `attestation_required_claims`,
`attestation_single_use`, `attestation_accepted_typs`, `attestation_min_key_storage`,
`attestation_min_user_authentication`. Each can only tighten the server's policy, which comes from
`ClientAttestationConfig`: skew 60 s, PoP and DPoP max age 300 s, asymmetric algorithms only (`RS*`/`PS*`/`ES*`/`EdDSA` -
no `none`, no MACs), the attestation `typ` values `OIDF_ATTESTATION_ACCEPTED_TYPS` names, challenge not required, the
required disclosures `OIDF_ATTESTATION_REQUIRED_CLAIMS` names, and attestations reusable within their lifetime unless
`OIDF_ATTESTATION_SINGLE_USE` is on, and no minimum key-storage or user-authentication level unless
`OIDF_ATTESTATION_MIN_KEY_STORAGE` or `OIDF_ATTESTATION_MIN_USER_AUTHENTICATION` sets one (a client's own minimum may
only be the same or higher). A value that does not parse or would loosen the policy
refuses the client (401 `invalid_client`); the pf-integration README's "Each client's attestation policy" has the rules.

`attestation_required` is written onto a client by the registration paths and declared in terraform, and from 0.6.0
the filter enforces it: a token request for the client without an attestation is refused (401 `invalid_client`).

**Per-client PF extended properties — issuance** (`AttestationIssuanceConfig`): `attestation_issuer`,
`attestation_issued_ttl`, `attestation_spiffe_bundle`, `attestation_bundle_url`,
`attestation_entitlement`, `attestation_signing_key_ref`, `attestation_signing_jwk`,
`attestation_instances`, `attestation_trust_domain`, `attestation_evidence`,
`attestation_evidence_issuer`, `attestation_asserted_context_resolver` (from 0.8.0 read off a PF client, and once set
every request must carry a well-formed `asserted_context` bound to the verified evidence), and
`attestation_asserted_context_policy` (reserved for package B10B; a client that sets it is refused until then).
`forbidden-in-production`: set under production it refuses that client only, and the others keep issuing (X-B04).

**Environment / system properties** (sysprop first, then env):

| Setting | Effect | Set in the checked-in deploy config? |
|---|---|---|
| `oidf.redis.url` → `OIDF_REDIS_URL` → `REDIS_URL` (+ `OIDF_REDIS_CA_FILE`) | Cluster-wide challenge, replay and evidence-binding store; `rediss://` only under the production profile. Unset = per-node in-memory | No — a resource of whichever environment deploys this, so set outside this repo |
| `OIDF_ATTESTER_MAX_EVIDENCE_LIFETIME_SECONDS`, `OIDF_ATTESTER_REQUIRE_SINGLE_AUDIENCE_EVIDENCE` | The evidence policy: the lifetime the attester accepts, whole and remaining (86400; production may only shorten it) and whether evidence must name one audience (`false`) | No - the defaults are the safe ones |
| `OIDF_BRIDGE_SIGNER_BACKING` + `OIDF_BRIDGE_SIGNING_KEYS` (+ `OIDF_BRIDGE_VAULT_ADDR`/`_TOKEN` when `vault`) | Per-client bridge signing. Unconfigured, `ATTESTATION_AUTH` is `FAILED_CONFIG` (its surfaces answer 503, the war keeps serving) unless the component is switched off with `OIDF_ATTESTATION_AUTH_ENABLED=false` (0.6.0; `OIDF_ATTESTATION_REQUIRE_BRIDGE_KEY=false` is now its alias). Each client entry also names its `"attesters"` | No — deployment secrets, set per environment |
| `OIDF_ATTESTATION_REQUIRE_ATTESTER_BINDING` / `oidf.attestation.require.attester.binding` | **Default true.** A client whose bridge entry names no `attesters` is refused at the token endpoint: federation trust says an attester is genuine, the binding says it is this client's, and without one any trusted attester can mint an attestation naming any client and be bridged as it. `=false` lets unbound clients accept any trusted attester; an explicit binding is still enforced | No — the default is the safe one |
| ~~`OIDF_BRIDGE_PRIVATE_JWK`~~ | **Superseded and refused.** Setting it now fails startup with a message naming where the key should move to, because a security setting that silently does nothing is worse than one that is absent | Must be unset |
| `OIDF_REQUIRE_METADATA_POLICY` / `oidf.require.metadata.policy` | **Default true.** Refuses federation registration when no superior in the trust chain declares a `metadata_policy` for the entity type being registered — without one the leaf's self-published `scope`, `grant_types` and `response_types` are granted verbatim | No — the default is the safe one, so a deployment only sets this to relax it |
| `oidf.mock.attesters` | Static attester trust, bypassing federation trust chains | **Never, from 0.6.0.** The image ignores an `oidf-mock-attesters.json` in the build context (R-I3); a development deployment mounts the file and sets the property itself, and production refuses it. Which attesters an AS believes is a demo's decision about its own trust |
| `OIDF_ATTESTATION_REQUIRED_TRUST_MARKS` | The Trust Mark types every client's attester must hold (X-E07); a client's `attestation_required_trust_marks` adds to it; `OIDF_ATTESTATION_TRUST_MARK_CACHE_MAX_SECONDS` (3600) caps how long a passing verdict is reused | No - empty by default; set it where only accredited attesters may sign attestations |
| `oidf.attestation.required.claims` | Global required-disclosure default | No, from 0.6.0 - the image no longer writes `workload`; set `OIDF_ATTESTATION_REQUIRED_CLAIMS=workload` to keep it (R-I3) |
| `OIDF_FEDERATION_TRUST_CONTROLLER_HOST` | Attester trust chain resolution (AS side). Required even in mock mode, or token-endpoint attestation auth NPEs | Yes — staging and production |
| `OIDF_FEDERATION_TRUST_ANCHOR_JWKS` | The trust controller's public Federation Entity Keys, pinned out of band (OIDFED §4). **Required with the line above**: without it no chain validates, and the filters say so at startup. Captured with `tools/pin-trust-anchor.py` | Staging pinned in the demo repo; production not yet — its anchor is not deployed |
| `OIDF_ATTESTER_OP_ISSUER`, with the two lines above | Federation-backed **wallet-provider** trust (the superseded `OIDF_TRUST_CONTROLLER_HOST` and `OIDF_TRUST_ANCHOR_JWKS` still read, with a warning) | No |
| `OIDF_WALLET_PROVIDER_JWKS` | Static wallet-provider trust map; development only from 0.8.0, refused by the production profile (F-0632) | No |
| `OIDF_WALLET_ATTESTATION_TYPES`, `OIDF_WALLET_ATTESTATION_AUD_REQUIRED` | The WIA `typ` values accepted (default `oauth-client-attestation+jwt`), and whether a WIA needs an `aud` (default true) | Only for a wallet provider that needs them |
| `OIDF_WALLET_STATUS_*` (seven settings) | WIA revocation through a Token Status List: the providers that must carry `status`, the size and cache caps, the `ttl` clamp and the stale grace (from 0.8.0, F-0635) | No; the attester needs egress to each status list host |
| `OIDF_CIMD_CLIENTS` + `OIDF_CIMD_TRUST_BUNDLES`, `OIDF_ATTESTER_FEDERATION_ENTITY`, `OIDF_ATTESTER_SIGNING_KEY_REF` (`OIDF_ATTESTER_SIGNING_JWK` in development only) | Extra client-metadata sources and the key they are signed with (`OIDF_ATTESTER_CIMD_URL` was removed in 0.8.0 and is refused when set) | No |
| `OIDF_ATTESTER_SIGNING_KEYS` | The OpenBao transit keys the attester may sign with, each with the issuers it signs for; required in production for any key ref | Production, when a client names a key ref |
| `OIDF_ATTESTER_SIGNING_KEY_REFRESH_SECONDS` | How soon a rotated transit key signs (300 s) | No |
| `OIDF_ATTESTER_SPIRE_READER_URL` + `_TRUST_DOMAIN`, `_CA_FILE`, `_CLIENT_KEY_PAIR` (and `_TIMEOUT_MS`, `OIDF_ATTESTER_SPIRE_FAILURE_MODE`) | The SPIRE entry reader over mutual TLS; unset = no SPIRE selectors | No |
| `OIDF_ENTRA_AGENT_DIRECTORY` | Registers the Entra asserted-context resolver | No |
| `OIDF_ATTESTATION_SUB=client_id` + `OIDF_AGENT_CLIENT_ID` | Device path: flips `sub` to the registered client id (divergence 5). Flag without the client id refuses to start | No |

**Servlet init-params**: `challengeRequired`, `customClaimsRequired` / `customClaimsSupported`,
`challengeEndpointEnabled`, `attestationSigningAlgValuesSupported`, `openBaoUrl` / `openBaoToken`,
`replayCacheMaxEntries`; and on each challenge endpoint, for its own challenges only, `challengeCacheMaxEntries`,
`challengeTtlSeconds`, `challengeRateLimitPerWindow`, `challengeRateLimitWindowSeconds` and
`challengeRateLimitMaxCallers`.

### 3.7 Storage

`AttestationSupport` holds process-wide singletons so each challenge endpoint shares state with what
consumes its challenges - the authorization server's with the token-endpoint hook, the attester's with the
attester - across classloaders. With no Redis URL it is per-node LRU+TTL
(`InMemoryAttestationChallengeService` / `InMemoryAttestationReplayCache` /
`InMemoryEvidenceBindingStore`, defaults 8192 entries / 300 s; `InMemoryRefreshTokenBindingStore`, 65536 entries,
each until its token expires, refusing a new one when full rather than evicting). With one, `RedisAttestationStore`
implements the four interfaces over platform's `RedisClient` (`platform.redis`, plan item C-2; client-attestation's
`MiniRedisClient` until 0.5.0), a dependency-free RESP client: issue is
`SET … EX`, consume is `DEL`, first-seen is `SET … NX EX`, bind is `SET … NX PX` then `GET` and compare, and a
refresh token's binding (X-E15) is `SET oidf:as:refresh:<sha256> "<jkt> <client>" PX`, read with `GET` and dropped
with `DEL`.
One view per namespace - `oidf:as:*`, `oidf:cas:*`, `oidf:fed:endpoint:*`, `oidf:admin:dpop:*` - over one
shared client. `rediss://` verifies the server's certificate and name (the HTTPS algorithm, SNI) and
completes the handshake before `AUTH`; the production profile refuses `redis://`. Every verdict is
three-valued, and **an unreachable Redis is `STORE_UNAVAILABLE`, answered 503 `temporarily_unavailable`**,
never a replay - availability is never traded for a replayable credential, and an outage is never
recorded as a finding about the client.

---

## 4. Standards alignment

Status vocabulary: **Implemented** — the clause is met; **Partial** — met on one path or under
configuration that is not the default; **Divergence** — deliberate, defended in
[claim-dictionary.md](claim-dictionary.md); **Extension** — no spec equivalent exists; **Not
implemented** — stated so it is not mistaken for coverage.

The **Id** column is the join key. A test pins a row by carrying that id in a `@Requirement`
annotation, and the coverage dashboard reports which rows nothing pins (`docs/coverage-dashboard.md` - not
tracked: `python3 tools/coverage-report.py` writes it after `mvn verify`, and CI publishes it as the
`coverage-dashboard` artefact of every Build run whose reactor build completes). A row reads `—` where no
clause id could be verified against the document itself; that is a gap in the citation, not in the code, and
it is left visible rather than filled with a plausible guess.

### 4.1 `draft-ietf-oauth-attestation-based-client-auth-11`

| Id | Requirement | Where | Status |
|---|---|---|---|
| — | Attestation JWT `typ=oauth-client-attestation+jwt` | `ClientAttestationVerifier:38`, `AttestationMinter:31` | Implemented |
| `CLAIM-DICT divergence 5` | `sub` names the OAuth client | `AttestationMinter` (workload path, always); `DeviceAttestationMinter` (device path, behind a flag) | Partial — divergence 5 |
| `ABCA-11 §7.1` | `cnf.jwk`, public-only, REQUIRED | `Jwks.assertPublicOnly`, `AttestationMinter` | Implemented |
| — | `exp` REQUIRED; expiry ⇒ `use_fresh_attestation` | `verifyAttestation` | Implemented |
| `CLAIM-DICT divergence 1` | `iss` removed in -08 | Our attesters keep it; one without it is accepted, the attester named by the client's one bound attester, the `trust_chain` leaf or a unique `kid` (0.8.0, X-E04) | Divergence 1, both accepted |
| `ABCA-11 §5.1` | PoP JWT `typ=oauth-client-attestation-pop+jwt`, `aud`, `jti`, `iat` | `verifyPopMode` | Implemented |
| `ABCA-11 §7.2` | PoP signed by the `cnf` key, allowlisted algorithm, audience is this server's issuer and nothing else (item 7; §5.1's single audience, as a string or a one-member array) | `verifyPopMode`, `requireSoleAudience`, `JwtCodec` | Implemented - the token endpoint URL and a second audience are refused since 0.4.0 (S4a, F-0110) |
| — | `attest_jwt_client_auth` at the token endpoint | `ClientAttestationAuthFilter` | Implemented |
| `ABCA-11 §7.3` | `attest_jwt_client_auth_dpop` / `dpop_combined`, DPoP key = `cnf` key | `verifyDpopMode`, `Jwks.assertSameKey` | Implemented |
| `ABCA-11 §5.2` | Combined mode's challenge is the DPoP nonce: `use_dpop_nonce` with a `DPoP-Nonce` header (RFC 9449 §8) | `enforceChallenge`, `ErrorChallenge`, `ClientAttestationAuthFilter.refuseVerification` | Implemented (0.8.0, X-E02). The nonce is a challenge from `oidf:as:challenge:*`, so one fetched from the challenge endpoint still works; the endpoint returns it in `DPoP-Nonce` as well |
| `ABCA-11 §6.1` | A `use_attestation_challenge` refusal carries a fresh challenge in `OAuth-Client-Attestation-Challenge` (MUST) | `ErrorChallenge`, `ClientAttestationAuthFilter.refuseVerification` | Implemented at the token-endpoint filter (0.8.0, X-E02). The issuance criterion, for a deployment without the filter, answers only true or false and so cannot set a header. Over the per-caller challenge cap the refusal goes out without one (a deliberate abuse guard) |
| — | Both proof headers, or neither, is an error | `verify:91-98` | Implemented |
| `ABCA-11 §10.3` | A refresh token issued under attestation is bound to the Client Instance Key; refreshing needs the attestation mechanism and the same `cnf` key | `RefreshTokenBinding`, `ClientAttestationAuthFilter` | Implemented since 0.8.0 (X-E15, F-0767): bound at issue, `invalid_grant` for another key, another client or no attestation; tokens from before 0.8.0 pass under `on` and are refused under `strict` |
| `ABCA-11 §6.3` | Challenge endpoint: a `POST`, answered with `attestation_challenge` and `Cache-Control: no-store`; `use_attestation_challenge` | `ClientAttestationChallengeServlet`, `enforceChallenge` | Implemented, off by default. Its challenges are the authorization server's alone (`oidf:as:challenge:*`); the attester has its own endpoint (CAS §4.1). The endpoint is named in the Entity Configuration's `openid_provider` metadata, not in PingFederate's own discovery documents (F-0115) |
| `ABCA-11 §7.4` | Error codes `use_attestation_challenge` / `use_fresh_attestation` / `invalid_client_attestation`, beside `invalid_client` | `ClientAttestationException` | Implemented. `invalid_client_attestation` since 0.8.0 (F-0735) for a refused attestation or proof: an untrusted attester, its signature, `typ`, `cnf`, lifetime ceiling, and every PoP or combined-mode DPoP check; `invalid_client` stays for a missing attestation or proof, a `client_id` other than `sub`, and a server that cannot check the proof, and is the answer to a valid attestation whose client may not authenticate: a hosted agent's standing, and since X-E11 an `agent_id` a register holds suspended or revoked (`ClientRevocation`) |
| — | SD-JWT presentation encoding (retired) | Actively refused | Implemented |
| — | Attester trust establishment (§10.8, out of scope in the draft) | `FederationAttesterKeyResolver` | Extension |
| `CLAIM-DICT divergence 2` | Single-use attestation | Reused within the 15-minute window by default; single use per client (`attestation_single_use`) or for all (`OIDF_ATTESTATION_SINGLE_USE`), refused `use_fresh_attestation` on reuse | Divergence 2, single use opt-in (0.8.0, X-E06) |
| `PROFILE §6(2)` | Per-instance identity claim | `agent_id` | Extension — divergence 5 |
| `CAS §4.3` | Instance-key proof at issuance (`oauth-attestation-instance-proof+jwt`) | `InstanceKeyProofValidator` | Extension — the draft has no issuance side |

### 4.2 The OAuth RFCs

| Id | Requirement | Where | Status |
|---|---|---|---|
| `RFC9449 §4.2` | DPoP proof: `typ=dpop+jwt`, self-signature under the `jwk` header, no private key, alg allowlist | `DpopProofValidator` | Implemented |
| `RFC9449 §4.3` | DPoP proof checking: `htm`, `htu`, `ath`, freshness; `htu` compared after RFC 3986 syntax- and scheme-based normalisation | `DpopProofValidator`, `services/demo-rs`; at the token endpoint the expected `htu` is `ClientAttestationUtils.endpointUrl` | Implemented - the expected `htu` is the URL PingFederate advertises for the endpoint, never one rebuilt from the `Host` header, since 0.4.0 (S4a, F-0111) |
| `RFC9449 §6.1` | `cnf.jkt` equals the presented proof key's thumbprint | `DelegatedTokenValidator` | Implemented |
| — | RFC 9449 replay of the DPoP proof | Caller's job; supplied by the verifier, **not** by `services/demo-rs` | Partial — `unverified.md` item 10 |
| `RFC9396 §6.1` | `authorization_details` containment, every field by its type's rule | `libs/rar-model`, asked by the token gate and the issuer (S1b) and by the RAR plugin for a PDP's answer and on refresh (S1c) | Implemented |
| `RFC9396 §7.1` | Processing at issuance (`AuthorizationDetailProcessor`) | `plugins/rar-paz-plugin` | Implemented |
| `RFC8693 §4.1` | `act` as a JSON object; outermost actor only is authorisable | `services/demo-rs` `ActChain`, `services/gm-api` `TokenClaims` | Implemented on the reading side |
| `UNVERIFIED item 8` | `act` minted as a JSON string, not an object | `delegationActChain` | Divergence being corrected — whether PF can emit the object form is unresolved |
| `RFC8693 §1.1` | Principal is the subject, agent is the actor | `plugins/rar-paz-plugin` | Implemented |
| — | RFC 7800 `cnf` | Attestation `cnf.jwk`; access token `cnf.jkt` | Implemented |
| `RFC7515 §4.1.9` | `typ` matching is case-insensitive and tolerates an `application/` prefix | `JwtCodec.requireType` | Implemented |
| `RFC7518 §3.3` | RSASSA-PKCS1-v1_5 (`RS256`/`384`/`512`): "A key of size 2048 bits or larger MUST be used" | `LocalJwkSigner` refuses a smaller key when it is built | Implemented (0.6.0, HJOSE) |
| `RFC7518 §3.4` | ECDSA signatures are fixed-width `r‖s`, not ASN.1/DER; P-256, P-384 and P-521 only, each with its own hash | `LocalJwkSigner`, `OpenBaoTransitSigner` | Implemented - `LocalJwkSigner` refuses another curve, and a declared `alg` that is not its curve's, since 0.6.0 (HJOSE) |
| `RFC7518 §3.5` | RSASSA-PSS (`PS256`/`384`/`512`), MGF1 with the same hash, salt the hash's length; 2048 bits or larger | `LocalJwkSigner` | Implemented (0.6.0, HJOSE; F-0112) |
| `RFC8725 §3.1` | Algorithm verification — no confusion between key types, no `none`; one algorithm per key | `DelegatedTokenValidator`, `JwtCodec`, `LocalJwkSigner` | Implemented - every `JwtCodec` verifier refuses `none` and the MAC algorithms, and tries only asymmetric keys not marked `enc`, since 0.6.0 (HJOSE) |
| `RFC8725 §3.2` | Only algorithms the application accepts; the claims of an unverified JWT decide nothing | `JwtCodec`, `UnverifiedClaims` | Implemented (0.6.0, HJOSE) - the oidf-jose README lists every read before a signature is checked |
| `RFC8725 §3.8` | Issuer validated | `DelegatedTokenValidator` | Implemented |
| `RFC8725 §3.9` | Audience validated | `DelegatedTokenValidator` | Implemented |
| `RFC6750 §2.1` | Bearer credentials in the `Authorization` header, and no other scheme | `SsfHttp.authorize` | Implemented |
| `RFC6750 §3` | `WWW-Authenticate` on an unauthenticated request | `SsfHttp.authorize` | Implemented |
| `RFC6750 §3.1` | `invalid_token` is 401, `insufficient_scope` is 403 | `SsfHttp.authorize` | Implemented |
| `RFC7662 §2.2` | Introspection response: `active`, space-separated `scope` | `PfIntrospectionReceiverAuthenticator` | Implemented |
| — | RFC 7517 / 7519 / 7638 | `libs/oidf-jose` throughout | Implemented, no clause-level id |
| — | RFC 8705 mTLS client authentication | — | Not implemented |
| — | RFC 9126 PAR | `ClientAttestationAuthFilter` over `/as/par.oauth2` (PAR itself is PF's) | Implemented - an attestation authenticates its client at PAR as at the token endpoint |
| — | FAPI 2.0 Security Profile | `Fapi2ProfileFilter`; the `conformance/` rig | Assessed for PF with ordinary FAPI clients (`private_key_jwt`, DPoP, PAR): the suite's plan 50 PASSED, 0 FAILED on 13.1.3 (2026-09-24, and 2026-09-25 on a fresh archive). Attestation clients were not in that run - see §6 |

### 4.3 OpenID Federation 1.0 (Final, 17 Feb 2026)

The clause-by-clause OpenID Federation rows live in [federation/conformance-matrix.md](federation/conformance-matrix.md), which the coverage report reads alongside this file. The rows here are where attestation and federation meet.

| Id | Requirement | Where | Status |
|---|---|---|---|
| `CLAIM-DICT divergence 1` | Attester keys resolved through a trust chain to the anchor | `FederationAttesterKeyResolver` | Extension — ABCA puts attester trust out of scope at §10.8 |
| — | Wallet-provider keys likewise, from the resolved `openid_wallet_provider.jwks` only (OIDFED §5.2.1; §3.1.1: Federation Entity Keys "SHOULD NOT be used in other protocols") | `FederationWalletProviderKeyResolver` | Implemented, unconfigured by default (F-0630) |
| `ABCA-11 §8` | AS advertises `attest_jwt_client_auth` / `attest_jwt_client_auth_dpop`, PoP methods, alg lists, `challenge_endpoint` | `AttestationMetadataConfig` | Implemented |

### 4.4 CAS 1.0 draft-00 — this repo's own spec

Does the implementation match the text it published?

| Id | Section | Status |
|---|---|---|
| `CAS §3` | §3 instance authentication requirements | Implemented |
| `CAS §4` | §4 issuance API — challenge endpoint, attestation endpoint, instance-key proof, processing rules, errors | Implemented |
| `CAS §5` | §5 discovery metadata | Implemented — and `ClientAttestationServiceMetadataServlet` reads the same config the issuance servlet enforces, so the document cannot drift from behaviour |
| `CAS §6` | §6 associating instance identity with a client id | **Partial** — resolution is by evidence rather than by a supplied `client_id` (good), and all three metadata sources exist. §6.2 rule 1 (federation → CIMD → registration order) and rule 2 (federation MUST chain-validate to the anchor, and revocation lands within one cache lifetime) are met since 2026-09-25 (`AttesterResolversTest`, `OpenIdFederationClientResolverTest`). Rule 3 (CIMD MUST NOT supply instance trust roots) is met since 2026-10-08 (X-B02) - see the next row |
| `CAS §6.2` | §6.2 rule 3 — CIMD trust roots | **Implemented** 2026-10-08 (X-B02, F-0067): trust roots come only from `OIDF_CIMD_TRUST_BUNDLES`, named per client in `OIDF_CIMD_CLIENTS`; a document carrying a trust root, an issuer or a key is refused (`CimdDocumentTest`); the fetch enforces the CIMD URL rules, no special-use address, a 5 KiB cap and `client_id` equal to the URL fetched (`CimdClientIdTest`, `CimdClientResolverTest`) |
| `CAS §7` | §7 down-scoping at issuance | **Partial** — rules 1–3 (subset semantics, empty request = full ceiling, `narrowing_behavior: reject`) are met. Rule 4 (a PDP or context-dependent narrowing) is not; the selector-conditioned downscoping the code comments describe is comment-only (§3.3); and the registration-time `instances[i].entitlement ⊆ entitlement` check is inert for CIMD/federation-sourced clients because they never carry a client ceiling |
| `CAS §9` | §9.1 evidence reuse - the Instance Attestation never embedded, bound to its first presenter | Implemented since 0.4.0 (S3b, F-0002): `workload` carries `instance_attestation_sha256`, `_type` and `_exp`; `EvidenceBindingStore` binds last, after every other check, keyed on the SHA-256 of the evidence's JWS Signing Input so a re-encoded token meets the same binding; a second key or client is `instance_attestation_bound` and an `attestation.evidence.conflict` audit event naming both keys (`AttestationIssuanceServletTest`). Detectable, not preventable: a thief who presents first wins |
| `CAS §8` | §8 lifetime / rotation / revocation | Partial. Lifetime and rotation: yes. Revocation: the token endpoint refuses a suspended or revoked `agent_id` (X-E11), or one its attester's Token Status List marks so (X-E12), and with `OIDF_CLIENT_REVOCATION_CAEP` the change goes out as CAEP or RISC to every SSF stream that hears it (X-E13), so the CAEP loop is closed on this side. Still open: tokens already issued live until they expire (F-0772); the inbound side depends on PingOne emitting CAEP (`unverified.md` items 7 and 12); and a federation client's revocation at the anchor does not revoke issuance, because no chain is walked |

### 4.5 Everything else

| Id | Standard | Where | Status |
|---|---|---|---|
| `CAS §5.3.2` | SPIFFE / SPIRE — JWT-SVID validation, trust domains, SPIRE's selectors through the entry reader | `SpiffeSvidValidator`, `SpireReaderClient`, `SpireSelectors` | Implemented |
| `CAS §5.3.1` | Cloud workload OIDC tokens (GKE, GCP SA, EKS, AWS STS web identity, AKS, Azure MI) | Six validators, each mapping onto a SPIFFE identity | Implemented |
| `ABCA-11 §4` | OID4VCI 1.0 Appendix E Wallet Attestation (a Client Attestation JWT): `typ` required, `exp`, `nbf`/`iat`, `cnf.jwk` | `WalletInstanceAttestationValidator` | Implemented, but refuses until wallet trust is configured. Diverges from HAIP 1.0 §4.4.1: no `x5c` trust, and `aud` required unless `OIDF_WALLET_ATTESTATION_AUD_REQUIRED=false` (F-0634, accepted). From 0.8.0 a WIA's optional `status` (OID4VCI Appendix E) is checked against its Token Status List (draft-ietf-oauth-status-list-21 §8.3): INVALID, SUSPENDED, another value or an index outside the list refused, a list that cannot be fetched or verified 503 (F-0635; attester README) |
| `CLAIM-DICT divergence 3` | OpenID4VCI 1.0 Appendix D `key_storage` / `user_authentication` | Device path, `iso_18045_moderate` | Divergence 3 |
| `OID4VCI §Appendix D.2` | OpenID4VCI 1.0 Appendix D levels enforced at the AS | `ClientAttestation.level`, `ClientAttestationVerifier.enforceMinimumLevels`; the levels go to the PDP as `att_key_storage` / `att_user_authentication` (governance engine) and `context.attestation.key_storage` / `user_authentication` (AuthZEN) | Implemented (X-E08, F-0760). A string is read as an array of one (Appendix D.1 defines an array; the device attester mints a string) |
| — | `draft-ietf-oauth-client-id-metadata-document` (CIMD), -02 | `CimdClientId`, `CimdDocument`, `CimdClientResolver` | Implemented for the attester as fetcher (2026-10-08): §3 URL rules (a query refused, not only discouraged), §4 `client_id`, §4.1 no shared secret or private key, §5 200 only and no redirect, §5.2 no error or invalid document cached and a 60 s floor, §8.6 no special-use address (F-0610), §8.7 a 5 KiB cap. Open-world CIMD (any URL presented becomes a client) is not supported |
| `APPLE-APPATTEST §Verify the attestation(1)` | Apple App Attest — chain to Apple's root CA | `libs/app-attest` | Implemented |
| `APPLE-APPATTEST §Verify the assertion(3)` | Apple App Attest — assertion counter advances | `libs/app-attest`, `libs/device-instance` | Implemented |
| `SSF §7.1` | SSF 1.0 stream configuration | `servlets/ssf` | Implemented |
| `SSF §8.1.1.1` | SSF 1.0 stream endpoints | `servlets/ssf` | Implemented |
| `CAEP §3.1` | CAEP 1.0 session revoked | `servlets/ssf` | Implemented as a transmitter and receiver. The audit-log source of the signal is unresolved. A revoked instance or agent is a source since X-E13 (`ClientRevocationCaep`) |
| `CAEP §3.5` | CAEP 1.0 device compliance change | `servlets/ssf`, `libs/device-instance` | Implemented; `unverified.md` item 12 — whether PingOne emits it at all is unknown |
| `RFC8417 §2.2` | Security Event Token claims | `SetVerifier`, `SetMinter` | Implemented |
| `RFC9493 §3.2` | Subject identifier formats | `SubjectId` | Implemented |
| `RFC8935 §2.4` | Push-based SET delivery | `servlets/ssf` | Implemented |
| `RFC8936 §2.3` | Poll-based SET delivery | `servlets/ssf` | Implemented |
| `AUTHZEN-1.0 §6` | Access Evaluation API | `services/gm-api`, `plugins/rar-paz-plugin`; as a PEP, the federation policy hook (`libs/openid-federation` `federation.policy`) | Implemented |
| `AUTHZEN-1.0 §5.5` | Decision and its `context`, read by a PEP: a permit only narrows a registration; `reason_admin` stays in the logs, `reason_user` is shown only when allowed; context not understood is ignored or refuses the permit | `AuthZenFederationPolicyDecisionPoint`, `RegistrationPolicy` | Implemented |
| `AUTHZEN-1.0 §9.2` | PDP metadata discovery, with the §9.2.3 identifier check | `AuthZenFederationPolicyDecisionPoint` | Implemented |
| `AUTHZEN-1.0 §10.1` | HTTPS JSON binding, as a PEP: POST, `X-Request-ID` echoed, an HTTP error never read as a decision | `AuthZenFederationPolicyDecisionPoint`, `FederationRuntimeConfig` (https required) | Implemented |
| `AUTHZEN-1.0 §8.5` | Resource Search API | `services/gm-api` | Implemented |
| `GRANT-MGMT §6.3` | Grant resource URL | `services/gm-api` | Implemented — §6.4 query and §6.5 revoke need a running PF and are untested here |
| `PF-SDK §CustomDataSourceDriver.retrieveValues` | PF custom data source contract | `plugins/instance-registry-datasource` | Implemented |
| `PF-SDK §AuthorizationDetailProcessor.enrich` | PF RAR processor contract | `plugins/rar-paz-plugin` | Implemented |
| `NIST-800-63B §6.1.2.1` | Binding requires at least AAL2 | `services/device-enrolment` | Implemented |

---

## 5. Test coverage

Counts are no longer written down here. They went stale twice — this paragraph reported six modules
from a run on 2026-08-22 long after the reactor had grown to fifteen — so the numbers now live on the
coverage dashboard, which `tools/coverage-report.py` generates from the jacoco reports and the
`@Requirement` annotations. It is not tracked (from 2026-09-27): CI generates it on every Build run whose
reactor build completes and publishes it as the `coverage-dashboard` artefact, and the generator exits 1 when
a module that has tests left no report, so a build that skipped them cannot pass as green. Locally,
`python3 tools/coverage-report.py` after `mvn verify` writes `docs/coverage-dashboard.md`. Read the totals,
the gate status and the pinned-requirement inventory there.

The tables below say which tests pin which §4 row. They are about *what* is asserted, not how many —
which is why they survive a module count changing and the paragraph above them did not.

### 5.1 Keyed to §4

| §4 row | Tests | What they actually assert |
|---|---|---|
| ABCA attestation + PoP verification | `ClientAttestationVerifierTest` (18) | PoP and DPoP happy paths; DPoP key must equal `cnf`; expired ⇒ `use_fresh`; both proof headers rejected; missing proof rejected; wrong PoP `aud` rejected; `client_id` mismatch rejected; a **private** key in `cnf` rejected; replay rejected; challenge required-but-missing ⇒ `use_challenge`; valid challenge accepted, stale/unknown rejected; `agent_id` carried through in both modes; a PoP whose `iss` is the `agent_id` rather than the client id still rejected |
| ABCA challenge endpoint | `AttestationChallengeServiceTest` (4) | Consumable once; unknown rejected; unique; expired rejected |
| ABCA replay | `AttestationReplayCacheTest` (4), `RedisAttestationStoreTest` (11) | First-use/replay; `(jti, client)` pairs independent; blank `jti` rejected; bounded cache evicts but stays usable. Redis: same contract cross-instance, **wrong password fails closed**, **Redis down fails closed**, survives stale connections |
| ABCA `agent_id` extension | `ClientAttestationTest` (3), `AttestationMinterTest` (5) | Null when absent, parsed when present, doesn't perturb other fields; omitted rather than emitted blank |
| RFC 9449 DPoP | `DpopProofValidatorTest` (11, in oidf-jose since 0.6.0) | Valid accepted; `htu` ignores query/fragment; wrong method/URI/`typ` rejected; `htm` compared exactly (F-0226); missing `jti` rejected; stale rejected; tampered signature rejected; disallowed alg rejected |
| RFC 9396 containment | `AuthorizationDetailsGateTest` (20), `AsVectorRunnerTest` and `CasVectorRunnerTest` (the shared vectors through the token gate, the mint, the configuration and the asserted context), `RarModelVectorsTest` in `libs/rar-model`; `RarEntitlementTest` (8) for the unused old check | Grants within entitlement; denies region/action outside; denies when nothing attested but something requested; grants nothing when nothing requested; missing `type` invalid; array parsing |
| RFC 9396 at issuance | `AttestationAwareRarProcessorTest` (21), `PrincipalPerFlowTest` (8), `ClientAssertedPrincipalTest` (9), `AttestationSubjectTest` (7), `ModelContainmentTest` (16), `ModelGateTest` (9), `RefreshVectorsTest` (149), `ShadedJarCheck` (2) | A non-PERMIT always throws; fail-open only for an unreachable PDP, and it strips the internal `_principal_sub` and `_agent_id` markers; PERMIT merges and strips; a PDP that answered badly throws with its text, the principal hashed and no cause; the principal per OAuth flow, and payments refused before the PDP without an authenticated one. Subject parses the PF hook attribute shape, `agent_id`, `iss` and `rar_models_fingerprint` when published. The containment model: a detail it cannot read is refused before the PDP, a PDP answer it does not find within the request is refused, a refresh must be strictly within its grant, an attestation context with no fingerprint or another one is refused, and the library's `contains` vectors run through PingFederate's parse and refresh loop; the shaded jar carries the model only under its relocated package |
| RFC 8693 `act` | `ClientAttestationUtilsTest` (3) | Prefers `agent_id` as the acting party; falls back to `client_id` when null or blank |
| OIDF attester trust | `FederationAttesterKeyResolverTest` (11), `AttesterTrustMarkGateTest` (15), `FallbackAttesterKeyResolverTest` (1), `RequiredTrustMarksTest` (3) | Resolves chain-validated keys; prefers dedicated attester metadata keys; rejects an unreachable attester; with Trust Marks required, trusts an attester holding one the anchor recognises and refuses one whose issuer it does not, refuses a static attester, reuses a verdict until the marks' `exp`, the chain's expiry or the one-hour cap, and answers a budget-cut mark, or one whose issuer, anchor or status endpoint cannot be fetched, 503 |
| OIDF trust anchor keys | `TrustAnchorTest`, `TrustChainValidatorAnchorKeyTest`, `TrustChainValidatorIntermediateTest`, `HttpTrustControllerGatewayAnchorTest`, `FederationRuntimeConfigTrustAnchorTest`, `ConfiguredAnchorAgreementTest`, filter init tests | Only pinned keys verify the anchor's statements, whatever its host serves; an intermediate's keys must be the ones the anchor's statement asserts; a superior without `jwks` cannot vouch; the anchor's entity configuration verifies before its fetch endpoint is used and is retrieved once more on a mismatch; unusable key sets (private, symmetric, no or duplicate `kid`) refused; a host without keys refuses every chain and names the variable; mock attesters still resolve |
| OIDF AS advertisement | `AttestationMetadataConfigTest` (2), `MetadataPolicyTest` | Defaults advertise the plain JWT format and both PoP methods; `one_of`/`value` exercised over `attest_jwt_client_auth` |
| CAS §4 issuance | `AttestationIssuanceServletTest` (104) | Happy path issues an attestation that verifies; unknown SPIFFE id, wrong SVID audience, proof signed by the wrong key, replayed proof all rejected; request exceeding entitlement denied; no clients configured rejected; missing fields rejected; `agent_id` absent with no registry, emitted when configured, registry receives the **resolved** instance subject not the raw SVID, a **failing registry fails the request** (503), a suspended or revoked agent is 403 `instance_not_authorized` with no evidence binding taken, and a registry that should be on but did not start is 503 (A22); GKE evidence with fetched bundle; WIA binding a different key rejected; refusal when no wallet trust; declared format narrows the search; bundle-fetch failure with no cache is a server error; SPIRE selectors introspected; malformed `authorization_details` ⇒ `invalid_request`; challenge consumed once then refused; required custom claim missing/blank rejected |
| CAS §5 discovery | `AttesterConfigurationServletTest` (17), `ClientAttestationServiceMetadataServletTest` (10) | Global document advertises endpoints and proof requirements; `agent_id_supported` reflects the flag both ways; per-client view withholds ceiling/bindings/signing; unknown client ⇒ 404; base URL prefers forwarded headers and omits default ports. CAS doc: challenge-required adds `challenge` to proof claims; endpoint can be disabled; custom claims from init-params and environment; formats follow the registered validators; `agent_id` in `attestation_claims_issued` exactly when the registry is on (A22) |
| CAS §6/§7 client resolution and down-scoping | `AttestationIssuanceConfigTest` (10), `SpiffeBindingTest` (5), `ChainClientResolverTest` (5), `CimdClientResolverTest`, `CimdDocumentTest`, `CimdClientIdTest`, `CimdClientsTest`, `EntraDirectoryAssertedContextResolverTest` (6) | Bindings/metadata/entitlement parsing; wildcard archetype covers its prefix; exact entry beats an overlapping wildcard; **instance entitlement exceeding the client ceiling is rejected**; CIMD: the draft's URL and document rules, trust roots only from the operator, 200 only, no redirect, the size cap, bounded staleness and an invalid document dropped at once |
| SPIFFE | `SpiffeSvidValidatorTest` (7), `SpireReaderClientTest` (18), `SpireSelectorsTest` (11), `PfClientKeyMaterialTest` (3) | Wrong audience / expired / wrong trust domain / unknown kid / bad signature / malformed SPIFFE id all rejected |
| Cloud evidence | `GkeTokenValidatorTest` (6), `GcpSaTokenValidatorTest` (6), `EksTokenValidatorTest` (5), `AwsStsWebIdentityValidatorTest` (6), `AksWorkloadIdentityValidatorTest` (5), `AzureManagedIdentityValidatorTest` (6) | Correct mapping onto a SPIFFE id, then wrong-issuer / wrong-audience / expired / bad-subject rejections; AWS also covers an assumed-role ARN with the session dropped |
| HAIP / WIA | `WalletInstanceAttestationValidatorTest` (27), `FederationWalletProviderKeyResolverTest` (10) | Every refusal, each counted under its check: missing or unlisted `typ`, unsupported `alg`, missing `iss`/`sub`, no or another pinned provider, untrusted provider, no keys, `x5c` without a resolvable `kid`, wrong signing key, `exp` past, `nbf`/`iat` ahead, wrong or missing `aud` (and accepted without one when not required), missing or private `cnf`; two instances of one wallet type get two agent keys; keys only from the resolved `openid_wallet_provider.jwks`, a superior's metadata and policy applied, the old fallbacks refused; **unconfigured wallet trust refuses rather than accepts** |
| WIA revocation (Token Status List) | `StatusListTest` (7), `StatusListTokenTest` (12), `StatusListClientTest` (24), `WalletInstanceAttestationStatusTest` (9), `AttestationIssuanceServletTest` (8 of its tests) | draft-21 Appendix C.1-C.4 decode exactly; every §5.1/§8.3 refusal of the token (signature, MAC, `typ`, `sub`, `iat`/`nbf`, `exp`, `ttl`, `bits`, `lst`); a 256 MiB bomb refused at a 1 MiB cap; the last index read and one past refused; content type, redirects (three followed, a fourth and https→http refused), body cap, outbound rules; `ttl` clamped, `exp` before `ttl`, stale grace 0 against 60 s, one fetch for 16 callers, LRU at 256 and within the byte budget, keyed by provider as well as URI, at most four fetches at once; end to end a VALID WIA minted, INVALID refused 400 and audited, SUSPENDED refused, an unreachable list 503 with `Retry-After`, a required provider without `status` refused, a list signed by another key refused, and **an expired WIA refused with no fetch made** |
| Attester signing keys | `AttesterSigningKeyTest` (11), `SigningKeyPolicyTest` (18), `RemoteJwksCacheTest` (4) | Picks transit by key-ref vs local by inline JWK; rejects neither-or-both; rejects transit without a vault configured; **an inline key refused in production; a key ref outside `OIDF_ATTESTER_SIGNING_KEYS`, or listed for another issuer, refused - a hosted agent's key among them (F-0625)**; a rotated key signs with a new `kid` after one refresh interval, and a failed re-read keeps the old signer; a key that does not build, or is not published in `OIDF_FEDERATION_ATTESTER_JWKS`, is a `DEGRADED` part |
| Evidence registry | `InstanceAttestationValidatorsTest` (9) | Defaults carry every built-in type; cloud types share the SPIFFE family; each declares its trust-domain/bundle needs; unknown type is a client fault; duplicate ids are a config error; `with()` replaces rather than duplicates; format sniffed with SPIFFE fallback |

### 5.2 Where coverage is absent

Stated plainly, because the shape of the gaps is not random — the enforcement points on the PF side
are the thin part.

| Not covered | Why it matters |
|---|---|
| ~~`ClientAttestationAuthFilter` — no tests at all~~ **CLOSED** | `ClientAttestationAuthFilterTest` now covers `doFilter` end to end (15 tests): a valid attestation minted into the bridge assertion (`client_secret` dropped, `Authorization` suppressed, assertion `iss`/`sub` correct), an attestation signed by an untrusted key rejected (401 `invalid_client`), multiple `OAuth-Client-Attestation` headers rejected (400 `invalid_request`), and a client with no bridge key configured rejected rather than passed through (401) |
| ~~`TokenEndpointAutoRegistrationFilter` — no tests~~ **CLOSED** | 5 tests now, including a `client_assertion` with no `trust_chain` header and one with a blank subject — neither reaches `RegistrationService` |
| ~~`ClientAttestationUtils` — 3 tests, all on actor preference~~ **Stale, not a gap.** `validateClientAttestation` is covered by `VerifyOnceTest` (the single-verify contract); `attestationClaim`/`delegationActChain` by `AttestationClaimSourceTest` (omission with no verified context, flat and workload-nested reads, the attacker-controlled-header case rejected). `ClientAttestationAuthFilterTest`'s `doFilter` tests exercise the same path again, end to end | These are what actually gate token issuance, and they are exercised — this row was simply out of date |
| No end-to-end test spanning issuance → token endpoint | Every test is unit-level. `AttestationMinterTest` does verify a minted attestation through `ClientAttestationVerifier`, which is the closest thing to a seam test, but nothing exercises the HTTP path |
| ~~`MiniRedisClient` `rediss://` (TLS)~~ **Closed.** The client is platform's `RedisClient` since 0.5.0; `RedisClientTlsTest` and the TLS half of `RedisLiveTest`, which CI runs against a TLS Redis, test the `rediss://` path | Recorded as F-0183 and closed in 0.6.0 |
| ~~Signature verification in the OGNL claim hooks~~ **Half-closed.** `attestationClaim` no longer base64-decodes the header — it reads `VERIFIED_ATTESTATION_ATTRIBUTE`, published only once the filter has verified (see [the design doc](attestation-client-auth-design.md), Change 3). `delegationActChain`'s `act` claim is still an unverified read of the caller's `subject_token`, by design: the token-exchange processor validates that token separately, before any issuance | The one remaining unverified read is deliberate and documented, not an oversight |
| **`OpenIdFederationClientResolver`** | `OpenIdFederationClientResolverTest` runs a real federation from the test kit: a chain that validates to the pinned anchor resolves; an entity the anchor does not vouch for, or a configuration that is not an entity statement, is refused; the answer is kept for its TTL; an outage serves the last answer; an entity the anchor stops vouching for loses its clients within one TTL; malformed bindings are skipped. `attestationClients` and `parse` are gated. `AttesterResolversTest` pins the federation → CIMD → PF order and that a federation entity with no pinned anchor stops the attester starting |
| ~~`PfIssuanceClientResolver` — no test class~~ **CLOSED** | `PfIssuanceClientResolverTest` (8 tests): unknown/disabled clients excluded, a client missing `attestation_issuer` skipped, one misconfigured client doesn't take the rest of the store down with it |
| Selector-conditioned downscoping | `spireSelectorsAreIntrospectedIntoWorkloadAttributes` asserts the selectors appear in the payload; nothing asserts the granted ceiling changes — because it does not (§3.3) |
| Issuance driven through federation | `AttestationIssuanceServletTest` injects prebuilt configs via `setClientResolver`; no test runs `issue()` behind a real federation resolver. CIMD is covered since 2026-10-08 (`aCimdClientWithTwoInstancesIssuesForBothAndRefusesAThird`) |

### 5.3 How they run

`mvn package` at the repo root, tests on. Two `provided` PF jars (`pf-protocolengine`,
`pingfederate-sdk` 13.1.3.0) must be `install:install-file`d first — see
`.github/actions/pf-provided-jars/action.yml` for the
exact steps. CI (`build.yml`) runs the full reactor with tests and
coverage gates (`mvn verify`) on every push to `main` and every pull request. This repo has no deploy
workflow.

---

## 6. What still needs to be done

Each item: what is missing, why it matters, what closes it.

### Blocking for production

**~~Attestations carry raw platform evidence.~~ CLOSED 2026-09-27 (S3b, F-0002).** Every SPIFFE-shaped
evidence type embedded the raw token as `workload.svid`, and the wallet path embedded the WIA as
`workload.instance_attestation`; the plugin and the token mappings forward `workload` whole, so the
token reached the PDP and the access token, and since its audience is the attester anyone who read an
attestation could present it for a key of their own until it expired. The attestation now carries
`instance_attestation_sha256`, `_type` and `_exp` and nothing that can be presented; the evidence binds
to the first instance key and client that present it, for as long as it lives (`EvidenceBindingStore`,
Redis `SET NX`), keyed on the digest of what its signature covers so a re-encoded token meets the same
binding; a second presenter is 401 `instance_attestation_bound` and an `attestation.evidence.conflict`
audit event naming both keys. What remains is stated in the attester's README: a thief who
presents first wins, detectably but not preventably, until evidence is itself key-bound.

**CIMD hands the attester its own trust roots - CLOSED 2026-10-08 (X-B02, F-0067).** The CIMD source is
now the operator's list of clients, `OIDF_CIMD_CLIENTS`, each keyed by its Client Identifier URL with its issuer,
evidence type, trust root (a name in `OIDF_CIMD_TRUST_BUNDLES`), subject prefixes, lifetime limit and signing key.
The attester fetches one Client ID Metadata Document per client from that URL and `CimdDocument.parse` takes only
the instances, their entitlements and metadata, the client ceiling and a lifetime from its
`oauth_client_attestation` member (CAS §6.1); `instance_trust`, `bundle`, `bundle_url`, `trust_domain`,
`evidence_type`, `evidence_issuer`, `issuer`, `signing_jwk` and `signing_key_ref` are refused naming CAS §6.2 rule 3,
the document's `client_id` must be the URL fetched, and a shared secret or a private key anywhere in it is refused
(CIMD draft -02 §4, §4.1). The fetch has no exemption from the outbound rules (in production not even
`OIDF_FETCH_HOST_ALLOWLIST`, §8.6), single-flight per client with no lock shared between clients, takes exactly 200,
follows no redirect, reads at most 5 KiB by default, never caches an error, and drops a client whose document is refused at
once. `OIDF_ATTESTER_CIMD_URL` was removed in 0.8.0 (B02B): set, it is refused in every profile, naming
`OIDF_CIMD_CLIENTS`, and `tools/cimd-split.py` converts its document. Pinned by `CimdDocumentTest`,
`CimdClientIdTest`, `CimdClientsTest`, `CimdClientResolverTest`, `AttesterResolversTest`,
`ClientAttestationServiceMetadataServletTest` and
`AttestationIssuanceServletTest.aCimdClientWithTwoInstancesIssuesForBothAndRefusesAThird`. Mitigated before that
by M-1 (2026-09-27): outside development the start-up audit refused the attester while the old variable was set.

**Federation-resolved clients are chain-validated - CLOSED 2026-09-25.** `OpenIdFederationClientResolver` used
to verify the entity configuration against its **own inline `jwks`** - tamper-evidence, not trust - so revoking
the entity at the anchor changed nothing at the attester. It now validates the entity's chain to one of the
pinned anchors (`FederationRuntimeConfig.trustAnchors()`, the same set every other federation check uses),
reads `spiffe_client_bindings` from the verified configuration, fetches statements older than its 300 s TTL
afresh, serves the last answer on a transport failure only, and drops it on a failed chain - so revocation
at the anchor stops issuance within one TTL (§6.2 rule 2). Slice 1 in §8.

**~~The shipped image trusts static attester keys.~~ CLOSED.** The Dockerfile used to ship
`oidf-mock-attesters.json` and write `oidf.mock.attesters` into `run.properties.subst.default`
unconditionally, so every image built here pre-trusted `mock-attester-1` — and anyone holding its
private half could mint attestations that AS accepted with no federation chain. The file is no longer
in this repo, and from 0.6.0 (R-I3) the image ignores one in the build context: a development
deployment mounts the file and sets the property itself, and production refuses it. Absent it, attester trust resolves through
federation trust chains, and the build says which resolver is live. A demo that wants static trust
supplies its own; no consumer inherits another's attesters.

**A private attester key is committed — in the demo repo.** This repo's copy is gone: the
`mock-attester-1` private JWK that sat in `CimdClientResolverTest` is now generated per run. What
remains is the deploying repo's [`attestation-demo-clients.tf`](https://github.com/dphhyland/pf-oidf-modules/blob/main/deploy/pingfederate/terraform/attestation-demo-clients.tf),
which carries the same inline EC **private** JWK, the hardcoded issuer `https://attester.example.com`,
and a "throwaway" client secret — plus two more copies in its harness. That key is public, so it is
rotate-or-accept, and it is `pf-oidf-modules`' call now that nothing built here trusts it. *Closes
when:* the demo clients move to transit-backed signing, or the file moves to a demo-only tree that is
never applied to a real environment. From 0.8.0 (X-B04, F-0626) a production deployment refuses an inline
attester key outright, so those demo clients issue only under `OIDF_DEPLOYMENT_PROFILE=development`.

**~~The bridge key is a single key that authenticates as any attestation client.~~ CLOSED.**
`OIDF_BRIDGE_PRIVATE_JWK` was one deployment-held key whose public half was injected into every
attestation client's JWKS, so it could mint an assertion for any of them — and a client registered
before the key existed never carried it. Signing is now per client, against the key the client is
already registered with, which removes both the shared credential and the ordering trap. See
[the design](attestation-client-auth-design.md). *Superseded text — closed when:* the
threat model is written down and either the key is scoped per client or the risk is explicitly
accepted in writing.

**~~The token-endpoint method is inert in the checked-in deploy config.~~ CLOSED** by the second half
of its own closing condition: the filter refuses to start rather than degrading silently. A deployment
that wants to run without attestation-based client authentication has to say so
(`OIDF_ATTESTATION_REQUIRE_BRIDGE_KEY=false`), and gets a warning naming what it has turned off.

**~~`ClientAttestationAuthFilter` is untested.~~ CLOSED.** See §5.2 — `ClientAttestationAuthFilterTest`
now asserts the fail-closed behaviour directly (untrusted key, multi-header, no bridge key configured),
not just in a javadoc comment.

**The issuance criterion is bound to an unverified ATM id.**
The deploying repo's [`access-token-mappings.tf`](https://github.com/dphhyland/pf-oidf-modules/blob/main/deploy/pingfederate/terraform/access-token-mappings.tf) says `attestATM` is "almost certainly
the mapping — CONFIRM via GET /oauth/accessTokenMappings". If it is wrong, the gate silently applies to
nothing. *Closes when:* the id is confirmed against a live server and the comment is deleted.

**Four extended properties the issuer reads are not declared in terraform.**
`extended-properties.tf` declares `attestation_required` (which the filter enforces from 0.6.0) but omits
`attestation_evidence`, `attestation_bundle_url`, `attestation_evidence_issuer` and
`attestation_asserted_context_resolver`. PF rejects an `extended_parameters` entry whose name is not
declared, so as it stands that terraform cannot create a client using cloud evidence, a remote trust
bundle, or asserted context — the whole non-SPIFFE catalogue. The file's own header warns it "MAY be
missing" names; it is. *Closes when:* the four names are added and the singleton is reconciled against
the live list as the header instructs.

### Production hardening

**Selector-conditioned downscoping (closed in 0.8.0, X-B09).** A client's and an instance's
`conditional_ceilings` narrow the ceiling unless the instance's verified selectors satisfy them: an unsatisfied rule's
ceiling is intersected in at step 6, after the evidence, the SPIRE read and the key proof, through the `CeilingPolicy`
SPI. Rules match only the verified selectors, never binding metadata, and missing evidence keeps a narrowing in place
(owner decision, 2026-10-14). The attester README has
the rule shape and where rules live.

**Closed (X-B03): the instance-⊆-client containment check was inert for external sources.**
Neither external source set a client ceiling, so a CIMD or federation binding's entitlement was bounded by
nothing but itself. CIMD documents now carry one (B02A), the federation source reads `spiffe_client_ceilings`,
and the operator's `OIDF_ATTESTER_EXTERNAL_CEILINGS` cap narrows both, so an external client is granted at
most instance ∩ client ∩ cap (F-0620, F-0621). Slice 2 in §8.

**Wallet trust is unconfigured everywhere.** Neither `OIDF_ATTESTER_OP_ISSUER` (with the federation's
trust controller) nor `OIDF_WALLET_PROVIDER_JWKS` is set in any deploy config, so the WIA path is
discoverable and always fails. The two-variable split this paragraph used to describe is gone: the wallet
path reads `OIDF_FEDERATION_TRUST_CONTROLLER_HOST` and `OIDF_FEDERATION_TRUST_ANCHOR_JWKS` through
`FederationRuntimeConfig`, like the AS side, and the old names are superseded (checked 2026-10-08).
*Closes when:* a rig profile sets it (Phase 5, REL5).

**No Redis in the checked-in config means per-node replay state.** With two verification points on two
classloaders and a clustered PF, in-memory caches mean a PoP `jti` can be spent once per node, and an
evidence binding won on one node is unknown to the next. `DEMO-MINT-DEPLOY.md` says staging has
`OIDF_REDIS_URL` set outside the repo; production is unstated. Since 0.4.0 the store over `rediss://`
verifies its peer and the production profile refuses `redis://` (S3a, F-0023 closed); making Redis a
requirement when clustered is C-1 (Phase 4). *Closes when:* Redis is a documented requirement for any
clustered deployment rather than an optional upgrade.

**The divergence-5 `sub` flip is unfinished.** `OIDF_ATTESTATION_SUB=client_id` is default-off, so on
the device path `sub` still carries the instance identity — the thing the draft says is the client id.
The migration order is written down in `claim-dictionary.md`; steps 3 and 4 (flip, delete the flag)
have not happened. *Closes when:* consumers are confirmed to read `agent_id`, the flag is flipped, and
it is removed.

**`services/demo-rs` has no replay cache wired.** `DelegatedTokenValidator` reports the DPoP proof's
`jti` precisely so a caller can cache it; no caller exists. A resource server that skips it accepts a
captured proof for as long as it stays fresh. `AttestationReplayCache` already exists and is the thing
to wire. (`unverified.md` item 10.)

**~~No FAPI 2.0 assessment.~~ Half-closed, 2026-09-24.** PingFederate itself is assessed: the
conformance rig runs the suite's FAPI 2.0 Security Profile plan against PF 13.1.3 with ordinary FAPI
clients (`private_key_jwt`, DPoP, PAR, PKCE) - 50 PASSED, 0 FAILED, the REVIEW and WARNING modules
explained in [conformance/README.md](../demo/README.md) - and `Fapi2ProfileFilter` supplies the two
rules PF can't apply per client. PAR turned out not to be an absence: PF implements it, and the
attestation filter is mapped over it. The mTLS sender constraint is one - PF 13.x issues no
certificate-bound access tokens (RFC 8705 §3) - so DPoP is the sender constraint used. What is still
open is the attestation path: the rig runs with attestation inert, so no FAPI 2.0 plan has seen an
`attest_jwt_client_auth` client. *Closes when:* that path is run through the plan, or the reasons it
cannot be are written down.

**Whether PF can emit `act` as a JSON object is unresolved.** RFC 8693 defines `act` as an object; the
existing mapping emits a JSON *string* for consumers to decode. `ActChain` parses both and reports the
legacy form so the deviation stays visible. This directly affects the delegation claim the pipeline
produces. (`unverified.md` item 8.)

**~~The OGNL claim hooks trust an unverified decode.~~ Half-closed, 2026-08-22 (`146df7b`).**
`attestationClaim` no longer decodes the header: it reads the context the token-endpoint filter publishes
once it has verified (`VERIFIED_ATTESTATION_ATTRIBUTE`), and with no verified context it returns nothing
rather than unverified claims. `delegationActChain` still reads the `act` claim of the caller's
`subject_token` without checking its signature, by design and documented at the method: the
token-exchange processor validates that token before any token issues. *Closes when:* that remaining
coupling is enforced in code, or accepted in writing.

**~~`RarContainment` duplicates `RarEntitlement`.~~ Closed, 2026-09-27 (PRs #37 and #36).** The token gate and
the issuer (S1b) and the RAR plugin (S1c) all ask `libs/rar-model`; the plugin shades and relocates it,
`RarContainment` and its contract test are gone, `RarEntitlement` was deleted in 0.7.0 (F-0100), and
the attestation context's `rar_models_fingerprint` shows the two classloaders hold one model.

### Nice to have

- ~~The metadata resolution chain runs CIMD → federation → PF store.~~ **Closed 2026-09-25 (`13bd3fa`).**
  It now runs federation → CIMD → PF store, descending assurance as the spec says, and the first source
  that knows a client wins, so the highest-assurance source wins a collision. Pinned by
  `AttesterResolversTest.aFederationEntityComesFirstThenCimdThenThePingFederateStore`.
- ~~`ClientAttestationServiceMetadataServlet:138` advertises `cimd` as an active metadata source off
  `OIDF_CIMD_TRUST_BUNDLES`; the resolver chain is enabled by `OIDF_ATTESTER_CIMD_URL`.~~ **Closed 2026-10-08
  (X-B02).** Both read `OIDF_CIMD_CLIENTS` through `CimdClients.fromSettings`, so `cimd` is advertised exactly
  when the resolver has it (`ClientAttestationServiceMetadataServletTest.cimdIsAdvertisedExactlyWhenTheResolverHasIt`).
- Challenges are off by default on both the issuance and verification sides. Nothing is wrong with
  that, but it means the anti-replay story rests entirely on `jti` caching.
- SPIRE is read only when `OIDF_ATTESTER_SPIRE_READER_URL` is set, and its selectors are verified evidence
  selectors (`spire:*`), never signed into the attestation: `workload.attributes` carries only the binding's declared
  metadata (X-B08, closing F-0140).
- `EntraDirectoryAssertedContextResolver` is an MVP: a static JSON directory in an environment
  variable.
- Attester key resolution depends on retaining `iss` (divergence 1). Worth revisiting if the draft ever
  defines a federation-based resolution mechanism of its own.

---

## 7. Related documents

| Document | What it is for |
|---|---|
| [openid-client-attestation-service-1_0.md](openid-client-attestation-service-1_0.md) | The CAS 1.0 draft-00 spec — normative text for the issuance side |
| [ai-agent-attestation-profile-1_0.md](ai-agent-attestation-profile-1_0.md) | The AI Agent Profile of ABCA-11 draft-00 — pins down what ABCA leaves open (algorithms, lifetime, `sub`/`agent_id`) for AI agent fleets specifically; attester trust establishment is deliberately out of scope |
| [claim-dictionary.md](claim-dictionary.md) | Every claim, its spec status, and the five numbered deliberate divergences |
| unverified.md | The thirteen assumptions that could not be confirmed against an authoritative source |
| libs/client-attestation/README.md | The verifier module in detail |
| servlets/attestation-issuer/README.md | The issuer module in detail |
| servlets/pf-integration/README.md | The PF glue: filters, OGNL hooks, key resolvers |
| services/device-enrolment/README.md | The device path and its enrolment ceremony |
| [build/pingfederate/README.md](../image/README.md) | How the AS image is built, and what a deployment supplies |
| DEMOS.md | Which demos exercise this pipeline and how to bring them up |

---

## 8. Next work

The gaps in §6, cut into slices that are each independently shippable and tested, ordered by
dependency and blast radius. Suggested order: **0 → 5 → 1 → 2 → 4 → 3**. Slices 0 and 5 are small and
unblock a real staging cut; 3 is the biggest and, from a security stance, the least urgent (the spec's
rule 4 is a MAY) — but it is the one that delivers the stage the design always intended.

### Slice 0 — CIMD trust-root allowlist

**Done 2026-10-08 (X-B02, package B02A)**, in a different shape from the one below: one document per client from
an operator list rather than one document for all, trust roots named per client rather than keyed by the
document's `trust_domain`, and the document refused whole rather than a field dropped. See the closed item in §6.

- `CimdMapping.toConfig`: refuse `bundle` and `bundle_url` from the document — `invalid_client` at
  config parse, with a log line naming the rule. Resolve trust roots from `OIDF_CIMD_TRUST_BUNDLES`
  (trust-domain → JWKS map) keyed by the entry's `trust_domain`; **fail closed** when the domain is not
  in the map.
- `CimdClientResolver`: enforce the spec's fetch rules — HTTPS only; refuse private/loopback
  resolution; response size cap; the document's `client_id` must equal the fetched URL.
- Move `OIDF_CIMD_TRUST_BUNDLES` reading into a shared helper so the metadata servlet advertises `cimd`
  off the same setting that makes it safe.
- Tests, `CimdClientResolverTest`: bundle in document refused; unknown trust domain refused;
  allowlisted domain resolves; `client_id` mismatch refused; `http://` refused.

### Slice 1 — Federation trust-chain validation for federation-resolved clients

**Done 2026-09-25** — as below, with one addition: statements older than the resolver's TTL are fetched
afresh rather than served from the validator's cache, or revocation would wait for the anchor's last
statement to expire. The wallet-provider path reads the same anchor set.

- `OpenIdFederationClientResolver`: after the entity-configuration fetch, validate the chain to the
  anchor via `TrustChainValidator` — the pattern is `FederationAttesterKeyResolver:43-46`; anchor from
  `OIDF_FEDERATION_TRUST_ANCHORS`, gateway from `OIDF_FEDERATION_TRUST_CONTROLLER_HOST`. Read
  `spiffe_client_bindings` from the **chain-validated leaf**, not the raw fetch. Keep the 300 s cache so
  revoking membership revokes issuance within one lifetime; serve stale on *transport* failure only —
  never on a failed chain, or revocation is defeated.
- `AttesterResolvers`: reorder to federation → CIMD → PF store. Note in this doc that
  first-match-per-client-id now means the higher-assurance source wins a collision.
- Tests, extending `OpenIdFederationClientResolverTest`: chain-valid entity resolves; chain-invalid or revoked
  entity refused; transport failure serves stale; chain failure does not; bindings come from the
  validated leaf.

### Slice 2 — Ceiling containment for external sources

**Done (X-B03, package B03)**, with a different second half from the one below: a binding with no client
ceiling over it is not refused. The operator's `OIDF_ATTESTER_EXTERNAL_CEILINGS` cap narrows every external
ceiling instead, and production refuses an external client with no cap. See the closed item in §6.

- `CimdMapping.toConfig`: map a document-level `entitlement` (client ceiling) to `P_ENTITLEMENT` so
  the instance-⊆-client rule fires; and change the rule to refuse an external-source binding
  entitlement that has **no** client ceiling to sit under, rather than silently accepting it.
- Tests, `AttestationIssuanceConfigTest` / `CimdClientResolverTest`: external binding exceeding the
  document ceiling rejected; binding entitlement with no document ceiling rejected.

### Slice 3 — Selector-conditioned downscoping

**Done** in 0.8.0 (X-B09), with two changes to the sketch that was here. A rule is
`{"require": {selector: values}, "ceiling": [RAR]}` and narrows **unless** the verified selectors satisfy it, not when
they match: a workload that loses or hides a selector must not escape a narrowing, which is what makes B08's
`downscope` mode safe. And rules match `InstanceIdentity.selectors()`, not `workloadAttributes`, whose binding metadata
nobody proved. Rules come from the operator (PingFederate extended property, `OIDF_CIMD_CLIENTS`) and from client
documents (CIMD, federation), since each can only narrow; `conditional_ceilings_supported` is advertised. The AuthZEN
PDP remains a later `CeilingPolicy`.

### Slice 4 — Test the enforcement points

*Hardening. Parallelisable with 1–3.* **Mostly done** as of 2026-08-22.

- ~~`ClientAttestationAuthFilterTest` (none today): bridge assertion claims, TTL, alg; `Authorization`
  suppressed; `client_secret` dropped; pass-through with no header; multi-header 400; fail-closed 500;
  unbridged pass-through when the key is missing.~~ **Done** — 15 tests, `doFilter` covered end to end.
- ~~`PfIssuanceClientResolverTest` (none today): disabled client excluded from `attestationClients()`;
  client without `attestation_issuer` excluded.~~ **Done** — 8 tests, plus a misconfigured client not
  taking the rest of the store down with it.
- ~~`ClientAttestationUtils`: `validateClientAttestation` happy and deny paths via a stubbed
  request.~~ **Already covered** — `VerifyOnceTest` predates this slice.
- ~~`AttesterResolvers` has no test file at all, and `OpenIdFederationClientResolverTest` covers only the
  statement checks.~~ **Done** with slice 1.
- Still open: no test spans issuance → token endpoint end to end. (The Redis client's `rediss://` path, once
  untested, is tested by `RedisClientTlsTest` and `RedisLiveTest` since 0.5.0.)

### Slice 5 — Deploy hygiene

*Blocking items from §6 that are configuration, not code.*

- ~~`oidf.mock.attesters` out of the base Dockerfile into a dev-only overlay.~~ **Done** — the file is consumer-supplied and the property is conditional on it.
- `extended-properties.tf`: add `attestation_evidence`, `attestation_bundle_url`,
  `attestation_evidence_issuer`, `attestation_asserted_context_resolver`. (`attestation_required` is wired: the
  filter enforces it from 0.6.0.)
- ~~`OIDF_BRIDGE_PRIVATE_JWK` as a documented deploy secret; consider making the filter refuse to start
  without it rather than degrading silently.~~ **Done** — per-client keys, and it does refuse.
- Confirm the `attestATM` mapping id against a live server and delete the "CONFIRM" comment.
- The demo private attester JWK out of `attestation-demo-clients.tf`.

### Open question, recorded rather than answered

Should issuance check that the client is registered for `attest_jwt_client_auth`? On PingFederate the
bridge means every working client is registered as `private_key_jwt`, so a naive check would reject all
of them. The signal `PfIssuanceClientResolver:82` already uses — presence of `attestation_issuer` — is
the honest one for the PF store; federation and CIMD would need their own. Not in any slice above.
