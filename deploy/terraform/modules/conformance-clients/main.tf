# The OpenID conformance suites' side of the rig: the clients the suite acts as, the one test user it signs in as, and
# the login form it drives. Test-only by construction - never part of a deployment profile. Public halves of keys
# only: conformance/gen-keys.sh writes the key pairs, PF gets the public JWKS here and the suite the private ones.
# Moved from conformance/terraform (clients.tf, ciba.tf, cimd.tf, attester-keys.tf, authn.tf).

variable "jwks" {
  description = "Public JWKS by key name: fapi2-client1, fapi2-client2, ssf-receiver, ciba-client1, ciba-client2, cimd-client with cimd_client_id, and fapi2-attest-client1 and -client2 with fapi2_attestation"
  type        = map(string)
}

variable "suite_base_urls" {
  description = "Origins of the conformance suites allowed as redirect targets"
  type        = list(string)
}

variable "suite_alias" {
  description = "The alias in the suite configuration; part of every redirect URI"
  type        = string
}

variable "access_token_manager_id" {
  description = "base's access_token_manager_id"
  type        = string
}

variable "openid_connect_policy_id" {
  description = "base's openid_connect_policy_id"
  type        = string
}

variable "fapi2_client" {
  description = "fapi2's client output"
  type        = any
}

variable "ssf_receiver" {
  description = "Make the SSF receiver the suite acts as (needs the ssf feature's ssf.manage scope)"
  type        = bool
  default     = true
}

variable "ciba" {
  description = "The FAPI-CIBA clients' request policy and delivery; null for none"
  type = object({
    request_policy_id           = string
    delivery_mode               = optional(string, "POLL")
    notification_suite_base_url = optional(string, "https://www.certification.openid.net")
  })
  default = null
}

variable "cimd_client_id" {
  description = "The attester-cimd profile's client id, its Client Identifier URL; empty for none"
  type        = string
  default     = ""
}

variable "attester" {
  description = "The attester-keys profile's client: the transit key it is signed with and its workloads' JWT-SVID keys; null for none"
  type = object({
    signing_key_ref = string
    spiffe_bundle   = string
  })
  default = null
}

variable "attester_client_secret" {
  description = "The attester-keys client's secret"
  type        = string
  sensitive   = true
  default     = null
}

variable "fapi2_attestation" {
  description = "Add the fapi2-attestation plan's two clients, authenticated by attest_jwt_client_auth bridged to private_key_jwt (needs jwks fapi2-attest-client1 and -client2)"
  type        = bool
  default     = false
}

variable "test_user_password" {
  description = "Password of the one test user the suite signs in as"
  type        = string
  sensitive   = true
}

variable "after" {
  description = "base's ready output"
  type        = any
  default     = null
}

resource "terraform_data" "after" {
  input = var.after
}

locals {
  suite_callbacks = [for base in var.suite_base_urls : "${base}/test/a/${var.suite_alias}/callback"]

  # The suite gives its second client a redirect URI with a query string, and checks the parameters come back on the
  # callback. PF matches exactly, so each client is registered with the form the suite sends for it.
  fapi2_redirect_uris = {
    client1 = local.suite_callbacks
    client2 = [for uri in local.suite_callbacks : "${uri}?dummy1=lorem&dummy2=ipsum"]
  }

  # Compact: PF re-serialises a JWKS, so a pretty-printed one never reads back equal.
  jwks = { for name, set in var.jwks : name => jsonencode(jsondecode(set)) }
}

# ── FAPI 2.0 Security Profile: private_key_jwt + DPoP ───────────────────────────────────────────────
#
# Two because the plan needs a second client to show that a code, a request_uri and a token issued to the first are no
# use to anyone else. The consent page stays: one module has the user refuse.
resource "pingfederate_oauth_client" "fapi2" {
  for_each = toset(["client1", "client2"])

  client_id = "conformance-fapi2-${each.key}"
  name      = "Conformance suite - FAPI 2.0 ${each.key}"

  grant_types   = ["AUTHORIZATION_CODE", "REFRESH_TOKEN"]
  redirect_uris = local.fapi2_redirect_uris[each.key]

  client_auth = {
    type                                  = "PRIVATE_KEY_JWT"
    token_endpoint_auth_signing_algorithm = "PS256"
    enforce_replay_prevention             = true
  }
  jwks_settings = { jwks = local.jwks["fapi2-${each.key}"] }

  require_pushed_authorization_requests = var.fapi2_client.require_pushed_authorization_requests
  require_proof_key_for_code_exchange   = var.fapi2_client.require_proof_key_for_code_exchange
  require_dpop                          = var.fapi2_client.require_dpop
  restricted_response_types             = var.fapi2_client.restricted_response_types

  restrict_scopes   = true
  restricted_scopes = ["openid", "profile", "email", "offline_access"]

  default_access_token_manager_ref = { id = var.access_token_manager_id }

  oidc_policy = {
    id_token_signing_algorithm = "PS256"
    policy_group               = { id = var.openid_connect_policy_id }
  }

  bypass_approval_page = false

  depends_on = [terraform_data.after]
}

# ── FAPI 2.0 with attest_jwt_client_auth (X-E09): the suite as an attested client ─────────────────────
#
# The FAPI 2.0 clients again, for the suite's client_attestation variant. The suite sends only the OAuth-Client-Attestation
# headers; ClientAttestationAuthFilter verifies them against the suite's attester (oidf.mock.attesters) and forwards a
# private_key_jwt signed with the client's bridge key (OIDF_BRIDGE_SIGNING_KEYS, which also binds the client to that
# attester). PF's own authentication of the client is therefore PRIVATE_KEY_JWT, and its JWKS is the bridge key's
# public half. attestation_required refuses a request that comes without an attestation.
resource "pingfederate_oauth_client" "fapi2_attest" {
  for_each = var.fapi2_attestation ? toset(["client1", "client2"]) : toset([])

  client_id = "conformance-fapi2-attest-${each.key}"
  name      = "Conformance suite - FAPI 2.0 attested ${each.key}"

  grant_types   = ["AUTHORIZATION_CODE", "REFRESH_TOKEN"]
  redirect_uris = local.fapi2_redirect_uris[each.key]

  client_auth = {
    type                                  = "PRIVATE_KEY_JWT"
    token_endpoint_auth_signing_algorithm = "PS256"
    enforce_replay_prevention             = true
  }
  jwks_settings = { jwks = local.jwks["fapi2-attest-${each.key}"] }

  require_pushed_authorization_requests = var.fapi2_client.require_pushed_authorization_requests
  require_proof_key_for_code_exchange   = var.fapi2_client.require_proof_key_for_code_exchange
  require_dpop                          = var.fapi2_client.require_dpop
  restricted_response_types             = var.fapi2_client.restricted_response_types

  restrict_scopes   = true
  restricted_scopes = ["openid", "profile", "email", "offline_access"]

  default_access_token_manager_ref = { id = var.access_token_manager_id }

  oidc_policy = {
    id_token_signing_algorithm = "PS256"
    policy_group               = { id = var.openid_connect_policy_id }
  }

  extended_parameters = {
    attestation_required = { values = ["true"] }
  }

  bypass_approval_page = false

  depends_on = [terraform_data.after]
}

# ── Shared Signals: the suite as a receiver ─────────────────────────────────────────────────────────
#
# private_key_jwt, so the archive holds no secret for it. Not DPoP-bound: the SSF servlet takes a plain bearer token.
resource "pingfederate_oauth_client" "ssf_receiver" {
  count     = var.ssf_receiver ? 1 : 0
  client_id = "conformance-ssf-receiver"
  name      = "Conformance suite - SSF receiver"

  grant_types = ["CLIENT_CREDENTIALS"]

  client_auth = {
    type                                  = "PRIVATE_KEY_JWT"
    token_endpoint_auth_signing_algorithm = "PS256"
    enforce_replay_prevention             = true
  }
  jwks_settings = { jwks = local.jwks["ssf-receiver"] }

  restrict_scopes  = true
  exclusive_scopes = ["ssf.manage"]

  default_access_token_manager_ref = { id = var.access_token_manager_id }

  depends_on = [terraform_data.after]
}

# ── FAPI-CIBA ID1 ───────────────────────────────────────────────────────────────────────────────────
#
# FAPI 1.0 Advanced clients: PS256 everywhere, signed backchannel requests, no user code, a refresh token for the
# refresh module. No PAR, PKCE or DPoP - CIBA has no front channel. Deliberately NOT in OIDF_FAPI2_CLIENTS: FAPI 1.0
# lets a client assertion name the token endpoint as its audience, and one module checks exactly that.
resource "pingfederate_oauth_client" "ciba" {
  for_each = var.ciba == null ? toset([]) : toset(["client1", "client2"])

  client_id = "conformance-ciba-${each.key}"
  name      = "Conformance suite - FAPI-CIBA ${each.key}"

  grant_types = ["CIBA", "REFRESH_TOKEN"]

  client_auth = {
    type                                  = "PRIVATE_KEY_JWT"
    token_endpoint_auth_signing_algorithm = "PS256"
    enforce_replay_prevention             = true
  }
  jwks_settings = { jwks = local.jwks["ciba-${each.key}"] }

  ciba_delivery_mode                    = var.ciba.delivery_mode
  ciba_notification_endpoint            = var.ciba.delivery_mode == "PING" ? "${var.ciba.notification_suite_base_url}/test/a/${var.suite_alias}/ciba-notification-endpoint" : null
  ciba_polling_interval                 = 2
  ciba_require_signed_requests          = true
  ciba_request_object_signing_algorithm = "PS256"
  ciba_user_code_supported              = false
  request_policy_ref                    = { id = var.ciba.request_policy_id }

  restrict_scopes   = true
  restricted_scopes = ["openid", "profile", "email", "offline_access"]

  default_access_token_manager_ref = { id = var.access_token_manager_id }

  oidc_policy = {
    id_token_signing_algorithm = "PS256"
    policy_group               = { id = var.openid_connect_policy_id }
  }

  # There is no page to approve on; the simulator is the approval.
  bypass_approval_page = true

  depends_on = [terraform_data.after]
}

# ── attester-cimd: the CIMD client ──────────────────────────────────────────────────────────────────
#
# Its id is its Client Identifier URL. PingFederate authenticates it at the token endpoint by attest_jwt_client_auth,
# bridged to private_key_jwt; the JWKS is the bridge key's public half.
resource "pingfederate_oauth_client" "cimd" {
  count = var.cimd_client_id == "" ? 0 : 1

  client_id   = var.cimd_client_id
  name        = "Rig CIMD client - payments agents"
  grant_types = ["CLIENT_CREDENTIALS"]

  client_auth = {
    type                                  = "PRIVATE_KEY_JWT"
    token_endpoint_auth_signing_algorithm = "PS256"
    enforce_replay_prevention             = true
  }
  jwks_settings = { jwks = local.jwks["cimd-client"] }

  default_access_token_manager_ref = { id = var.access_token_manager_id }

  depends_on = [terraform_data.after]
}

# ── attester-keys: a PingFederate-store attestation client signed with an OpenBao transit key (X-B04) ─

resource "pingfederate_oauth_client" "attester_transit" {
  count = var.attester == null ? 0 : 1

  client_id                        = "conformance-attester-transit"
  name                             = "Conformance rig - attester signing with a transit key"
  grant_types                      = ["CLIENT_CREDENTIALS"]
  client_auth                      = { type = "SECRET", secret = var.attester_client_secret }
  restrict_scopes                  = false
  bypass_approval_page             = true
  persistent_grant_expiration_type = "SERVER_DEFAULT"

  # Listed in OIDF_ATTESTER_SIGNING_KEYS for this issuer by the compose overlay; anything else is refused.
  extended_parameters = {
    attestation_issuer          = { values = ["https://attester.example.com"] }
    attestation_trust_domain    = { values = ["rig.example"] }
    attestation_spiffe_bundle   = { values = [var.attester.spiffe_bundle] }
    attestation_instances       = { values = [jsonencode([{ spiffe_id = "spiffe://rig.example/agent" }])] }
    attestation_signing_key_ref = { values = [var.attester.signing_key_ref] }
  }

  depends_on = [terraform_data.after]
}

# ── the suite's user: one account, one HTML form ────────────────────────────────────────────────────
#
# The suite drives this page itself (the `browser` block of its configuration), so the form stays the stock one - the
# selectors in conformance/suite/*.template.json are written against it. It is the only adapter mapped to a grant,
# which is what lets PF use it without an authentication policy choosing for it.

resource "pingfederate_password_credential_validator" "suite_user" {
  validator_id = "conformanceUsers"
  name         = "Conformance suite user"

  plugin_descriptor_ref = {
    id = "org.sourceid.saml20.domain.SimpleUsernamePasswordCredentialValidator"
  }

  attribute_contract = {}

  configuration = {
    tables = [
      {
        name = "Users"
        rows = [
          {
            fields = [
              { name = "Username", value = "suite-user" },
              { name = "Relax Password Requirements", value = "true" },
            ]
            sensitive_fields = [
              { name = "Password", value = var.test_user_password },
              { name = "Confirm Password", value = var.test_user_password },
            ]
            default_row = false
          },
        ]
      },
    ]
    fields = []
  }
}

resource "pingfederate_idp_adapter" "login_form" {
  adapter_id = "conformanceLogin"
  name       = "Conformance login form"

  plugin_descriptor_ref = {
    id = "com.pingidentity.adapters.htmlform.idp.HtmlFormIdpAuthnAdapter"
  }

  configuration = {
    tables = [
      {
        name = "Credential Validators"
        rows = [
          {
            fields = [
              {
                name  = "Password Credential Validator Instance"
                value = pingfederate_password_credential_validator.suite_user.id
              },
            ]
            default_row = false
          },
        ]
      },
    ]
    fields = []
  }

  attribute_contract = {
    core_attributes = [
      { name = "policy.action" },
      { name = "username", masked = false, pseudonym = true },
    ]
  }

  attribute_mapping = {
    attribute_contract_fulfillment = {
      "policy.action" = { source = { type = "ADAPTER" }, value = "policy.action" }
      "username"      = { source = { type = "ADAPTER" }, value = "username" }
    }
  }
}

# The persistent grant is keyed by the username the form authenticated.
resource "pingfederate_oauth_idp_adapter_mapping" "login_form" {
  mapping_id = pingfederate_idp_adapter.login_form.id

  attribute_contract_fulfillment = {
    "USER_KEY"  = { source = { type = "ADAPTER" }, value = "username" }
    "USER_NAME" = { source = { type = "ADAPTER" }, value = "username" }
  }
}

output "fapi2_client_ids" {
  description = "For fapi2's clients (OIDF_FAPI2_CLIENTS)"
  value       = concat([for c in pingfederate_oauth_client.fapi2 : c.client_id], [for c in pingfederate_oauth_client.fapi2_attest : c.client_id])
}

output "ciba_client_ids" {
  description = "For fapi2's resource_clients (OIDF_FAPI_RESOURCE_CLIENTS)"
  value       = [for c in pingfederate_oauth_client.ciba : c.client_id]
}
