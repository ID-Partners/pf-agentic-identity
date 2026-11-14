# Deployment-profile Terraform

PingFederate configuration for an agentic IdP, split by feature. `agentic-idp/` is the one root; it composes the
modules below from `var.features` and is applied to a **local authoring PingFederate** only. The result is exported as
the deployment's config archive, and the deployment boots from that archive. The provider block refuses any admin host
that is not localhost.

| Module | PingFederate objects | Module settings in its `env` output |
|---|---|---|
| `base` (always) | issuer, runtime TLS certificate, trusted CAs, the authorization-server settings singleton, JWT access token manager and mappings, default OpenID Connect policy, extended properties, PostgreSQL data stores, smoke client | data store ids |
| `fapi2` | none: its `oauth_server` output feeds `base`, and its `client` output feeds each FAPI client | `OIDF_FAPI_ENABLED`, `OIDF_FAPI2_CLIENTS`, `OIDF_FAPI_RESOURCE_CLIENTS` |
| `attestation` | none: attestation clients carry extended properties, which `base` declares | `OIDF_ATTESTATION_AUTH_ENABLED`, `OIDF_ATTESTATION_ISSUER_ENABLED` |
| `federation` | operator token manager and mapping, optional operator client; `oidf.admin.*` scopes | `OIDF_FEDERATION_ENABLED`, `OIDF_AUTO_REGISTRATION_ENABLED`, `OIDF_HOSTING_ENABLED`, `OIDF_OPERATOR_API_ENABLED`, `OIDF_OPERATOR_AUDIENCE` |
| `ciba` | OOB authenticator (ciba-sim by default, test only), request policy, CIBA settings | `OIDF_CIBA_SIM_*` with the simulator |
| `ssf` | introspection client, optional emitter client; `ssf.*` scopes | `OIDF_SSF_ENABLED`, `OIDF_SSF_ISSUER`, introspection endpoint and client |
| `conformance-clients` | the OpenID conformance suites' clients, test user and login form: test only | none |

The root's `env` output merges the modules' settings. It also sets every modelled feature that is left out to
`false`, because in the development profile an unset component switch counts as on.

The modules take only variables and read no files, so a deployment can use them from a copy. Secrets go in the root's
single `secrets` variable, which is marked sensitive; the other inputs and the `env` output are not sensitive.

Nothing applies the root by hand: a profile (`profiles/<name>.yaml`) sets its inputs and `tools/profile.py author`
applies it, with fresh state, to a fresh authoring PingFederate and exports the archive. The conformance rig
(`conformance/up.sh`, the `conformance-*` profiles) and the reference stacks (`reference/lib/author.sh`, `minimal`) both
author this way; they had Terraform of their own until phase 3 of `private/plans/agentic-idp-profiles.md`.
