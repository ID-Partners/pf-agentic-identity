# OpenID Federation: the entity, automatic registration, hosted subordinates and the federation operator API.
#
# PingFederate's part is the operator API's tokens: their own access token manager, so that they - and only they - carry
# the audience the API checks (OIDF_OPERATOR_AUDIENCE), the oidf.admin.* exclusive scopes, and optionally a client that
# holds them. The rest is the modules' settings. Federation clients carry extended properties, which base declares.
# Moved from conformance/terraform (tokens.tf, oauth-server.tf, clients.tf).

variable "naming" {
  description = "base's naming"
  type        = object({ id = string, display = string })
}

variable "pf_base_url" {
  description = "The issuer, which the operator tokens carry"
  type        = string
}

variable "auto_registration" {
  description = "Automatic registration (OpenID Federation 1.0 §12.1) at the token, authorization and PAR endpoints"
  type        = bool
  default     = true
}

variable "hosting" {
  description = "Host subordinate entities for this authority, /federation/agents and /federation/resources"
  type        = bool
  default     = false
}

variable "operator_api" {
  description = "The federation operator API, /federation/admin, and its token manager; null switches it off"
  type = object({
    audience = optional(string, "pf-agentic-identity-operator")
    # A client holding every oidf.admin.* scope, DPoP-bound; false leaves registering operators to the deployment.
    client = optional(bool, false)
  })
  default = {}
}

variable "operator_client_secret" {
  description = "The operator client's secret, with operator_api.client"
  type        = string
  sensitive   = true
  default     = null
}

# base's authorization-server settings and client_credentials mapping: the operator client names an exclusive scope and
# a mapping that must exist first.
variable "after" {
  description = "base's ready output"
  type        = any
  default     = null
}

locals {
  operator        = var.operator_api != null
  operator_client = local.operator && try(var.operator_api.client, false)
}

resource "terraform_data" "after" {
  input = var.after
}

resource "pingfederate_oauth_access_token_manager" "operator" {
  count      = local.operator ? 1 : 0
  manager_id = "${var.naming.id}Operator"
  name       = "${var.naming.display} federation operator tokens"

  plugin_descriptor_ref = {
    id = "com.pingidentity.pf.access.token.management.plugins.JwtBearerAccessTokenManagementPlugin"
  }

  configuration = {
    fields = [
      { name = "Token Lifetime", value = "10" },
      { name = "Use Centralized Signing Key", value = "true" },
      { name = "JWS Algorithm", value = "PS256" },
      { name = "Issuer Claim Value", value = var.pf_base_url },
      { name = "Audience Claim Value", value = var.operator_api.audience },
      { name = "Type Header Value", value = "at+jwt" },
    ]
    tables = []
  }

  attribute_contract = {
    extended_attributes = [{ name = "sub", multi_valued = false }]
  }
}

resource "pingfederate_oauth_access_token_mapping" "operator" {
  count                    = local.operator ? 1 : 0
  access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.operator[0].id }
  context                  = { type = "CLIENT_CREDENTIALS" }

  attribute_contract_fulfillment = {
    "sub" = { source = { type = "CONTEXT" }, value = "ClientId" }
  }
}

# services/harness FederationSmokeHarness live enrols, suspends, re-keys and revokes a hosted agent through the operator
# API, which takes a DPoP-bound token carrying the route's scope. A secret rather than a key, so that the harness needs
# nothing but its secrets file.
resource "pingfederate_oauth_client" "operator" {
  count     = local.operator_client ? 1 : 0
  client_id = "${var.naming.id}-federation-operator"
  name      = "${var.naming.display} - federation operator"

  grant_types = ["CLIENT_CREDENTIALS"]

  client_auth = {
    type   = "SECRET"
    secret = var.operator_client_secret
  }

  require_dpop     = true
  restrict_scopes  = true
  exclusive_scopes = ["oidf.admin.read", "oidf.admin.entities", "oidf.admin.keys"]

  default_access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.operator[0].id }

  depends_on = [terraform_data.after, pingfederate_oauth_access_token_mapping.operator]
}

output "exclusive_scopes" {
  description = "For base's exclusive_scopes: the operator API's, which only the operator client holds"
  value = [
    { name = "oidf.admin.read", description = "Read the federation administration API", dynamic = false },
    { name = "oidf.admin.entities", description = "Create, change and remove hosted entities", dynamic = false },
    { name = "oidf.admin.keys", description = "Rotate and revoke hosted entities' keys", dynamic = false },
  ]
}

output "needs_extended_properties" {
  description = "Always: federation clients carry trust_chain, status and the rest as extended properties"
  value       = true
}

output "operator_client_id" {
  description = "The operator client's id, or null"
  value       = local.operator_client ? pingfederate_oauth_client.operator[0].client_id : null
}

output "env" {
  description = "The modules' settings this feature implies"
  value = merge(
    {
      OIDF_FEDERATION_ENABLED        = "true"
      OIDF_AUTO_REGISTRATION_ENABLED = tostring(var.auto_registration)
      OIDF_HOSTING_ENABLED           = tostring(var.hosting)
      OIDF_OPERATOR_API_ENABLED      = tostring(local.operator)
    },
    local.operator ? { OIDF_OPERATOR_AUDIENCE = var.operator_api.audience } : {},
  )
}
