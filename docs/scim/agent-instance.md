# The AgentInstance SCIM resource type

A provisioning system reads agent instances and suspends, reactivates or revokes them through SCIM 2.0 (RFC 7643,
RFC 7644). Since 0.8.0 (plan item X-E14) the attester serves them at `/federation/scim/v2`. One resource type,
`AgentInstance`, covers both registers that keep an `agent_id`'s status:

| Register | Store | `register` value |
|---|---|---|
| Device instances | the Identity Object Model, `idm.entry` rows of class `agentInstance` (`OIDF_INSTANCE_REGISTRY_DATA_STORE_ID`) | `device_instance` |
| Workload agents | `agent_identity` (`OIDF_AGENT_REGISTRY_MODE`) | `workload_agent` |

The token endpoint reads the same registers at every attested request. A suspension or revocation made here refuses the
instance's next request, even though its attestation has not expired
([attestation-token-endpoint.md](../configuration/attestation-token-endpoint.md)).

## Schema

URN: `urn:idpartners:params:scim:schemas:core:1.0:AgentInstance`, in the `urn:idpartners:params:scim:schemas:core:1.0:`
namespace the Identity Object Model's `ProtocolState` resource uses. The definition, in RFC 7643 §7 form, is
[agent-instance.schema.json](agent-instance.schema.json). The endpoint serves that same file at `/Schemas`, and a test
fails if the two differ.

| Attribute | Type | Mutability | Device instance | Workload agent |
|---|---|---|---|---|
| `id` | string | readOnly | the instance id | the `agent_id` |
| `register` | string | readOnly | `device_instance` | `workload_agent` |
| `status` | string | readWrite | `active`, `suspended` or `revoked` | the same |
| `active` | boolean | readWrite | `status` is `active` | the same |
| `status_reason` | string | readWrite | not returned (it is kept in the instance's ledger entry) | the reason recorded with the last change |
| `owner.value` | string | readOnly | the owner's PingOne subject: the `involvedParty` row's `pingoneUserId`, the key the SCIM user store writes | the OAuth `client_id` the agent was minted under |
| `owner.type` | string | readOnly | `user` | `client` |
| `owner.issuer` | string | readOnly | absent | the attester (`iss`) that minted it |
| `device.value` | string | readOnly | the device's id | absent |
| `issuer` | string | readOnly | the agent platform's entity id | the attester (`iss`) |
| `meta.created` | dateTime | readOnly | enrolment time | minting time |
| `meta.lastModified` | dateTime | readOnly | the last status change (its ledger entry's time), else enrolment time | the last status change, else minting time |
| `meta.version` | string | readOnly | `W/"<status>"` | `W/"<row version>"` |
| `meta.location` | reference | readOnly | `/federation/scim/v2/AgentInstances/{id}` | the same |

`id` is the `agent_id` that attestations carry and that CAEP and the SSF transmitter key on
([claim-dictionary.md](../claim-dictionary.md)). A workload agent's `instance_subject` is left out: the operator API
shows it, and a provisioner does not need it.

**Reserved:** `status_idx`, the instance's index in the client revocation list, is to be added when that list is
published as a Token Status List (plan item X-E12). It is not in the schema yet, and a PATCH that names it is refused as
read-only.

`status` has the three values the registers share. The Identity Object Model's `record_status` also has `expired` and
`superseded`. The registry reads both as `revoked`, so an instance in either is an `AgentInstance` that is revoked and
stays that way.

## Operations

All of them need a PingFederate-issued operator access token, DPoP-bound in production
([operator-authentication.md](../operator/operator-authentication.md)). Reads need `oidf.admin.scim.read`, and a PATCH
needs `oidf.admin.scim`. Responses are `application/scim+json` with `Cache-Control: no-store`. The endpoint is off (404)
unless `OIDF_SCIM_AGENT_INSTANCES=true`.

| Request | Answer |
|---|---|
| `GET /AgentInstances/{id}` | the resource, with `ETag` set to its version; 404 when neither register holds the id |
| `GET /AgentInstances?filter=...&startIndex=&count=` | a `ListResponse`, ordered by register and then by id |
| `PATCH /AgentInstances/{id}` | the changed resource with its new `ETag` |
| `GET /Schemas`, `/Schemas/{urn}`, `/ResourceTypes`, `/ResourceTypes/AgentInstance`, `/ServiceProviderConfig` | discovery (RFC 7644 §4) |
| `POST`, `PUT`, `DELETE` | 405: instances are enrolled and minted elsewhere, and never deleted |

### Filters

A filter is one or more `eq` comparisons joined by `and`. It can compare `id`, `status`, `active`, `register`,
`owner.value` (or `owner`), `device.value` (or `device`) and `issuer`. Attribute names and operators are case-insensitive
(ASCII letters only) and may carry the schema URN. Values compare exactly. A `status` value that is not `active`,
`suspended` or `revoked` is 400 `invalidFilter`, not read as any status. Any other filter is also 400 `invalidFilter`:
another operator, `or`, `not`, brackets, a value path, or another attribute.

A filter must name an `id`, an `owner.value` or a `device.value`, because the registers are not listed whole. Without one
the request is 400 `tooMany`. A filter that would yield more than 200 instances is also 400 `tooMany`. An owner value is
looked up in both registers: as a PingOne subject among device owners, and as a `client_id` among workload agents.

### PATCH

The body is a `PatchOp` (RFC 7644 §3.5.2) with `replace` or `add` operations on `status`, `active` and
`status_reason`, given by path or as a value object without a path:

```json
{
  "schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
  "Operations": [
    {"op": "replace", "path": "status", "value": "suspended"},
    {"op": "replace", "path": "status_reason", "value": "INC-1234"}
  ]
}
```

- `active: false` is `suspended`, and `active: true` is `active`. An `active` that contradicts `status` in the same body
  is 400 `invalidValue`.
- `status_reason` is recorded in the register's audit row, at most 256 characters. Without it the reason recorded is
  `changed through SCIM`. A reason with no status change is 400 `invalidValue`. Name an incident or a ticket, never a
  person: the reason is kept.
- **Revoked is terminal.** A PATCH that moves a revoked instance anywhere else is 400 `invalidValue`. A PATCH to the
  status the instance already has writes nothing and answers 200.
- **Atomic, as the operator API.** A device instance moves only while it is still in the status it was read in, and its
  ledger entry (`agentLifecycleEvent`) is written in the same statement (`IomInstanceRegistry.changeStatus`). A workload
  agent moves only at the row version it was read at, with its `agent_status_audit_log` row in the same transaction
  (`JdbcAgentRegistry.changeStatus`). Both registers tell the status-change hook with source `scim`, so an outbound CAEP
  channel (`OIDF_CLIENT_REVOCATION_CAEP`) sends the change on as it would an operator's.
- **Versions** (RFC 7644 §3.14). `If-Match` with a version other than the current one is 412. A change that another
  change overtook between the read and the write is 412 when the request carried `If-Match`, and 409 when it did not.
  A device instance's row has no version column, so its version is its status. Suspending and then reactivating an
  instance therefore gives it back the version it had.
- Any other attribute is 400: `mutability` for a read-only attribute (including `status_idx`), and `invalidPath` for an
  attribute that is not in the schema. `remove` is 400 `mutability`.

### Errors

Every error uses the RFC 7644 §3.12 schema (`urn:ietf:params:scim:api:messages:2.0:Error`) with `status` as a string.
The operator authenticator's refusals (401, 403, 429, 503) are written in the same schema. Their status code and
headers (`WWW-Authenticate`, `DPoP-Nonce`, `Retry-After`) are kept. When a register is configured but has not started,
the answer is 503. When neither register is configured, it is also 503.

## Audit

Each change emits `agent_instance.scim_status_changed` (audited), with `agent_id`, `register`, `from_status`,
`to_status`, `actor` and `status_reason`. Each refused change emits `agent_instance.scim_status_refused` with the reason
`terminal`, `precondition_failed` or `conflict`. Both count in `oidf_scim_agent_instance_changes_total{register,
to_status, outcome}` ([metrics.md](../operator/metrics.md)).

## Conformance vectors

[agent-instance-vectors.json](agent-instance-vectors.json) holds the SCIM exchanges any implementation of this resource
type must answer the same way: reads, filters, PATCH by `status` and by `active`, revoked as terminal, `If-Match`,
read-only attributes and discovery. Each vector runs against a fresh instance in each register it names. The file
describes its own placeholders and its subset rule. `AgentInstanceScimContractTest` runs every vector against this
endpoint for both registers. idp-scim-service, which owns the Identity Object Model's `agentInstance` class, keeps a copy
beside a pointer to this page.

## Two registers, one schema

Device instances and workload agents live in different stores today, so one endpoint reads two registers. Moving
workload agents into the Identity Object Model, which would leave one register, is recorded as a later option and is
not part of this release.
