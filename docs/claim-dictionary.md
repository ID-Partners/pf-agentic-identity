# Claim dictionary

Every claim this platform mints or verifies, the spec it comes from, and — where we depart from that
spec — the reason. Fetched from the source documents on 2026-07-31, not recalled.

The point of this file is that a reviewer can tell, for any claim, whether it is standard, an
extension, or a deliberate divergence, without reading the code.

---

## Client Attestation JWT

`draft-ietf-oauth-attestation-based-client-auth-11` (3 September 2026). Issued by the platform backend
acting as Client Attester; verified by PingFederate.

| Claim | Spec status | Value here |
|---|---|---|
| `typ` (header) | REQUIRED | `oauth-client-attestation+jwt` |
| `sub` | REQUIRED | **In transition** (divergence 5). Legacy: the opaque agent instance identifier. Flipped (`OIDF_ATTESTATION_SUB=client_id`, default off): the **registered OAuth client id**, which is what the draft means by `sub`. Never the user, never the device, in either mode. |
| `agent_id` | extension | The **opaque agent instance identifier** — the pseudonymous per-instance identity, always emitted. Same value the instance id has always had, so audit joins and CAEP revocation keys survive the `sub` flip. See divergence 5. |
| `exp` | REQUIRED | `iat + 15 min` — see *Attestation lifetime* below |
| `cnf.jwk` | REQUIRED (MUST use `jwk`) | The Secure Enclave P-256 public key |
| `iat` | OPTIONAL | Always set |
| `iss` | **Removed from the spec in -08** | **Retained** — see divergence 1 |
| `key_storage` | OpenID4VCI 1.0 Appendix D | `iso_18045_moderate` — see divergence 3 |
| `user_authentication` | OpenID4VCI 1.0 Appendix D | `iso_18045_moderate` — see divergence 3 |
| `authenticator_ref` | extension | Reference to the bound passkey credential (not the credential itself) |
| `agent_build` | extension | Agent platform build/version |
| `uv_policy` | extension | The user-verification reuse window in force, seconds |
| `status` | extension here; `draft-ietf-oauth-status-list-21` §6.2 | Only with a Token Status List on (X-E12): `{"status_list": {"idx": <n>, "uri": <list URL>}}`. `idx` is the instance's own index (random, unique, never reused; IOM `attrs.statusIdx`, or `agent_identity.status_idx` for a workload agent). `uri` is the list the attester serves: `ENROLMENT_STATUS_LIST_URL` for a device instance, `OIDF_ATTESTER_STATUS_LIST_URL/<list>` (one list per attester issuer) for a workload agent. ABCA defines no `status`; it allows claims it does not define. A verifier in `status_list` mode refuses an attestation without it. |

Permitted `key_storage` / `user_authentication` values, verbatim from Appendix D:
`iso_18045_high` (VAN.5), `iso_18045_moderate` (VAN.4), `iso_18045_enhanced-basic` (VAN.3),
`iso_18045_basic` (VAN.2).

**Shape.** Appendix D.1 defines each as "A non-empty array of case sensitive strings" (OpenID4VCI 1.0, read
2026-10-19). The device attester mints a single string, so the authorization server accepts both: a string is read
as an array of one, and an array is relied on for its weakest value.

**At the authorization server** (from plan item X-E08, F-0760). A client's `attestation_min_key_storage` and
`attestation_min_user_authentication`, or the server-wide `OIDF_ATTESTATION_MIN_KEY_STORAGE` and
`OIDF_ATTESTATION_MIN_USER_AUTHENTICATION`, set the lowest level accepted, compared on ISO/IEC 18045's order:
basic < enhanced-basic < moderate < high. A level below the minimum, a missing claim, or a value outside the four
(another ecosystem's value, another spelling, an empty array) is refused `invalid_client_attestation`. The attested
levels also reach the RAR plugin's PDP request, as `att_key_storage` and `att_user_authentication` for the governance
engine and under `context.attestation` for AuthZEN, so a policy can require a level per `authorization_details` type.
A level the attestation does not assert, or that the server does not recognise, is left out, so such a policy denies.

## Client Attestation PoP JWT

Same draft. Minted per request by the iOS agent, signed by the Secure Enclave key.

| Claim | Spec status | Value here |
|---|---|---|
| `typ` (header) | REQUIRED | `oauth-client-attestation-pop+jwt` |
| `aud` | REQUIRED | PF's **configured** base URL — not the URL the request arrived on. The documented `aud` trap. |
| `jti` | REQUIRED | Fresh UUID; replay-cached per client |
| `iat` | REQUIRED | Max age 300 s, skew 60 s |
| `challenge` | OPTIONAL | Present when the attester requires it |
| `iss` | **Removed in -08** | Set to the attestation's `sub`, for symmetry with divergence 1 |

Transport headers: `OAuth-Client-Attestation`, `OAuth-Client-Attestation-PoP`. A third,
`OAuth-Client-Attestation-Challenge`, exists in the draft. Registered token endpoint auth methods:
`attest_jwt_client_auth` and `attest_jwt_client_auth_dpop`.

## Instance-key proof JWT — repo extension, no spec equivalent

Used by the *workload* attester (`POST /federation/attestation`), not on the iOS path.

`typ` = `oauth-attestation-instance-proof+jwt`. **This value is not registered in any draft, and that
is correct**: the OAuth attestation draft has no issuance-side proof concept at all — it starts once
the client already holds an attestation. This is a local extension covering how a caller proves
possession of the key it is asking to have attested.

Claims: `aud` (required, the attester issuer), `jti` (required), `iat` and `exp` (both required since 0.6.0,
`exp` after `iat` by at most 300 s, accepted from `iat` - 60 s to `exp` + 60 s, and the `jti` remembered until
`exp` + 60 s: CAS §4.3, plan item S4c), `challenge` (optional — note the claim name is `challenge`, not `nonce`).

## DPoP proof

RFC 9449.

| Claim | Value |
|---|---|
| `typ` (header) | `dpop+jwt` |
| `jwk` (header) | The Secure Enclave public key |
| `htm` / `htu` / `iat` / `jti` | Per RFC |
| `cnf.jkt` (on the access token) | base64url SHA-256 JWK thumbprint (RFC 7638) of the same enclave key |

Every agent-path access token is sender-constrained. No bare bearer tokens.

## Delegation — `act`

RFC 8693.

| Claim | Value |
|---|---|
| `sub` | **The human** on whose behalf the agent acts |
| `act` | A **JSON object** |
| `act.sub` | The **agent instance identifier** |

Two rules that are easy to get wrong and are both enforced here:

- **`act` is a JSON object, not a string.** `gke-spiffe-demo/pf/terraform/token-exchange.tf` (in pf-agentic-identity-domain-authority)
  currently emits it as a JSON *string* for consumers to decode. That is a deviation from RFC 8693 and
  is being corrected, not carried forward.
- **Nested prior actors are informational only** and MUST NOT feed access-control decisions. Only the
  outermost `act` — the current actor — may be authorised on.

## CAEP events

SSF 1.0 and CAEP 1.0, both Final (2 September 2025). URIs under
`https://schemas.openid.net/secevent/caep/event-type/`.

| Event | Required event-specific claims |
|---|---|
| `device-compliance-change` | `previous_status`, `current_status` — each `compliant` or `not-compliant` |
| `session-revoked` | none |
| `credential-change` | `credential_type` (`fido2-platform` for a passkey), `change_type` ∈ create/revoke/update/delete |
| `assurance-level-change` | `namespace`, `current_level`; optional `previous_level`, `change_direction` |

`namespace` is MAY, not MUST, so a custom assurance namespace is first-class. The four other CAEP
types (`token-claims-change`, `session-established`, `session-presented`, `risk-level-change`) are not
used here. Eight total, no more.

## OpenID Federation

OpenID Federation 1.0 Final (17 February 2026); a Final 1.1 (5 May 2026) also exists.

| Item | Value |
|---|---|
| Entity statement `typ` | `entity-statement+jwt` |
| `authority_hints` | REQUIRED for any entity with ≥1 superior; MUST NOT appear for trust anchors **with no superiors**. PingFederate is an intermediate here, so it carries them, pointing at the trust anchor the deployment configures ([`lighthouse`](https://github.com/dphhyland/pf-oidf-modules/blob/main/deploy/lighthouse), in the deploying repo). |
| `metadata_policy` | Narrow-only. §6.1.1: a policy "cannot be repealed or made more permissive by Intermediate Entities that are subordinate in the Trust Chain." Composition fails closed. |

Note an anchor acting as an intermediate in a nested federation *does* carry `authority_hints` — the
rule is about having superiors, not about being an anchor.

---

## Deliberate divergences

### 1. `iss` retained on the attestation and PoP

Draft -08 removed `iss` from both JWTs; -11 (re-read 2026-10-12) still defines it on neither: §4 lists the
attestation's claims and §5.1 the PoP's, and neither names `iss`. Our attesters keep emitting it, and the verifier
uses it when it is there. On the PoP it is optional: one without `iss` is accepted, and one that has it must name the
attestation's client (`ClientAttestationVerifier`, pinned by `ClientAttestationVerifierTest`).

**Since 0.8.0 the verifier also accepts an attestation without `iss`** (plan item X-E04, F-0740), from another
implementation's attester. It names the attester in this order: the client's bound attester when it is bound to
exactly one; else the subject of the `trust_chain` header's self-issued first statement; else the one attester whose
trusted keys include the header's `kid`. If none applies, it refuses with `invalid_client_attestation`. Each only
names a candidate: the resolver establishes trust in it as it would for an `iss`, the signature must verify under its
keys, and the client's binding check applies. A present `iss` is used as before and must match the signature.

**Why `iss` is kept:** this repo's `ClientAttestationVerifier` resolves the attester's signing keys *by* its identity —
through `FederationAttesterKeyResolver`, which walks an OpenID Federation trust chain from the attester
up to the anchor. Removing `iss` would mean falling back to the draft's suggested `x5c` / `kid`+`jku`
resolution and discarding the federation-based trust path, which is the whole point of the
architecture. The draft explicitly puts attester trust establishment **out of scope** (§10.8), so this
is filling a gap the spec declines to fill rather than contradicting it.

**Revisit if:** the draft later defines a federation-based resolution mechanism of its own, or one of its own for
naming the attester of an attestation without `iss`.

### 2. Reuse within the 15-minute window, where EUDI mandates single-use

The EUDI ARF requires a Wallet Instance Attestation to be sent to **at most one** verifier
(TS3 §2.2.1.1), explicitly to prevent issuer linkability, with once-only attestation mandatory.
-11 permits reuse, in the same words as -10 (§10.2, re-read 2026-10-12): the design "deliberately allows for a
Client Instance to re-use a single Client Attestation JWT in multiple interactions/requests". We reuse by default.

**Single use is opt-in** (plan item X-E06, F-0750, 0.8.0). A client's `attestation_single_use` extended property, or
`OIDF_ATTESTATION_SINGLE_USE` for every client, makes each attestation authenticate once. Once the attestation, its
proof and the `authorization_details` check have passed, the verifier records a digest of the attestation's decoded
header, payload and signature in the replay store until no node can accept it. The digest is of the decoded segments,
not the string presented, because jose4j verifies the same signature with padding or whitespace appended or the last
character's unused bits flipped. A second presentation, in any spelling, is refused `use_fresh_attestation` (401); a
store outage is 503. An attestation without its key cannot be spent on the client's behalf, since the record follows
the proof. A refusal after the verifier accepts - the token-endpoint filter's own later checks, or PingFederate
refusing the request - has still spent the attestation, so the client's retry needs a fresh one. The cost is one
issuance call to the attester per authenticated request, so two for a PAR followed by its token request, and
`OIDF_ATTESTER_ISSUANCE_REQUESTS_PER_MINUTE` (60 by default, F-0060) limits those per caller: a deployment that turns
single use on raises that limit to its single-use clients' request rate. It is the setting for a deployment that wants
the ARF's posture, or that wants a leaked attestation and key to buy one token rather than the rest of the window.

**Why:** the linkability argument does not apply. An ARF wallet presents its WIA to many independent
PID and attestation providers, so a reused artefact becomes a cross-provider correlation handle. Our
attestation is presented to exactly one verifier — our own PingFederate — so there is no second party
to correlate with. The instance identity is pseudonymous regardless — carried as `agent_id`, and as
`sub` until the divergence-5 flip — and the flipped `sub` is a registered client id; so in either mode
that single verifier learns no user identity from the attestation.

**Revisit if:** the attestation is ever presented to a second relying party. At that moment this
divergence becomes a real privacy defect, not a justified simplification, and single use becomes the default for
those clients.

### 3. `iso_18045_moderate`, not `iso_18045_high`

**Why:** the EUDI ARF distinguishes a **WSCD** — a tamper-resistant device meeting LoA High — from a
**keystore**, defined as "a hardware-backed repository and service that generates, stores, and uses
non-critical cryptographic assets", and it lists secure enclaves explicitly in that second category.
TS3 §2.3.2 requires `iso_18045_high` only "for a KA about a WSCD".

The Apple Secure Enclave is a keystore by that taxonomy. Asserting `iso_18045_high` would be a false
security claim, and a downstream policy that trusts it would be relying on an assurance we cannot
demonstrate. The value is pinned in code and asserted in a test so it cannot drift upward by accident.

**Revisit if:** a certification is obtained that actually supports a higher claim.

### 4. Attestation lifetime: 15 minutes

Not a divergence so much as a number the specs leave open, recorded here because the brief asked for
it to be defended.

The attestation asserts device posture and the user-verification policy in force. Both go stale, and a
long-lived attestation asserting current posture is fiction. The EUDI ARF caps the analogous WIA below
24 hours (`WUA_33`) and requires the provider to verify instance integrity immediately before signing.

Fifteen minutes because re-minting is cheap: it costs one round trip and — while the `LAContext` is
still live — **no user prompt**. So the usual argument for long lifetimes (user friction) does not
apply. CAEP covers the residual window between mints, and server-side UV recency (5 minutes) is
checked independently at every issuance.

### 5. `agent_id`: the instance identity as its own claim, and the `sub` flip

Historically this attestation's `sub` was the opaque instance identifier — which diverged from the
draft (whose `sub` names the OAuth client) and would have needed one registered client per phone to
authenticate at a token endpoint. The SPIFFE/workload path never had this problem: its attester
resolves the workload to a client and mints `sub` = client id from the start.

The reconciliation (Phase 2.5) makes the instance identity a claim of its own:

- **`agent_id` is always emitted**, carrying exactly the value the instance id has always had — a
  rename, not a new identifier, so audit joins, CAEP revocation keys and any live token stay valid.
  It is 256 random bits minted at enrolment, never derived from the user or device, and unique only
  within its issuer: the full identity of an acting instance is the pair (`iss`, `agent_id`).
- **`sub` flips to the registered client id** behind `OIDF_ATTESTATION_SUB=client_id`
  (with `OIDF_AGENT_CLIENT_ID` naming the client; the flag without the client id refuses to start).
  Default off: until the flip, `sub` and `agent_id` carry the same value, so nothing that still reads
  `sub` breaks — and precisely because the two are equal then, a consumer wrongly reading `sub` for
  the instance identity still passes on the legacy path. The device-path test fixtures therefore run
  the flip ON and assert the two values **differ** (`DeviceAttestationMinterTest`).

Migration order: mint on both paths (nothing reads it) → switch consumers (a no-op while the values
are equal) → flip `sub` → delete the flag. Downstream, `agent_id` is what the delegation `act.sub`
and the PDP's actor attribute carry; `sub`/`client_id` name the agent *type* and are never a
per-instance identity.

**-11 (re-read 2026-10-12):** §4's `sub` now names the client "unless specified otherwise by a profile as
described in Section 13", and §13 lets a profile redefine `sub` if it says how the profile is recognised and what
replaces the §7.1 and §7.5 checks. That is a conformant home for the legacy mode, but this repo's profile does not
take it (PROFILE §6 has `sub` as the client id), and F-0062's decision stands: flip at 1.0 and drop the legacy mode.

**Revisit if:** the ABCA draft ever defines its own per-instance claim — at which point `agent_id`
should migrate to the standard name.

---

## Profile conformance status

A separate axis from the divergences above. Those record where this implementation departs from
[ABCA]; this records where it departs from **our own**
[ai-agent-attestation-profile-1_0.md](ai-agent-attestation-profile-1_0.md), which fixes what ABCA
leaves open. The profile is an opt-in posture, not the shipped default: narrowing the defaults to meet
it would break any deployment currently signing with an RS-family algorithm, and flipping `sub` by
default is the migration divergence 5 already governs. So the code is built to *permit* conformance
and a test pins that it does, rather than imposing it on everyone.

| Profile requirement | Shipped default | How a deployment conforms |
|---|---|---|
| §3 — `PS256`/`ES256` only | `DEFAULT_ASYMMETRIC_ALGORITHMS`, ten algorithms wide, including the RS family and `EdDSA`. Excludes `none` and all MACs. | `attestationAlgorithms`/`popAlgorithms`/`dpopAlgorithms` set to `{PS256, ES256}` |
| §5 — `exp` ≤ `iat` + 18h | No ceiling. `exp` itself is always enforced, and issuance already mints 15-minute attestations by default (divergence 4), but nothing bounded `exp - iat` at the verifier until now. | `maxAttestationLifetimeSeconds(64800)`. When set, an attestation with no `iat` is rejected rather than exempted |
| §6 — `agent_id` always present (a duty the profile puts on the *attester*; an AS enforcing it too is defence-in-depth, not required for conformance) | Not required at the AS. `agent_id` is always *minted*, but the verifier did not require it — and naming it in `requiredDisclosedClaims` was silently a no-op before this, because unrecognised claim names are treated as satisfied. That arm is still permissive — rejecting would fail a client's authentication at runtime, since the config is built per request from per-client `extproperties` — but it now logs a WARN once per distinct unrecognised name, so a typo is visible rather than silent. | `requiredDisclosedClaims(Set.of("agent_id"))` |
| §6 — `sub` = agent type | Device path puts the instance id in `sub` unless `OIDF_ATTESTATION_SUB=client_id`. SPIFFE/workload path already mints `sub` = client id. | Set the flag; see divergence 5 for the migration |

`ProfileConformanceTest` (in `libs/client-attestation`) asserts each of these against a config built to
satisfy the profile, and deliberately pins the *gap* too: if someone later narrows the shipped
defaults, `theShippedDefaultsAreBroaderThanTheProfile` and `theCeilingIsOffUnlessTheDeploymentSetsIt`
fail and this table gets revisited. Each rejection test has a control proving it rejects for the
profiled reason rather than incidentally.

**Revisit if:** an external conformance claim is made against the profile, at which point the defaults
should move and these tests invert.
