# CIBA (OpenID Connect Client Initiated Backchannel Authentication). PingFederate implements CIBA itself - the
# backchannel endpoint, poll and ping, signed request objects, the hint rules. What it needs is an authentication
# device (an OOB authenticator) and a request policy that turns the login hint into the grant's user.
#
# The default authenticator is plugins/ciba-sim, which answers whatever an operator recorded at POST /ciba-sim/decision:
# a test stand-in, never a production authenticator. For a real device pass the PingOne MFA plugin's (or another
# OOBAuthPlugin's) descriptor and configuration. Moved from conformance/terraform/ciba.tf.

variable "naming" {
  description = "base's naming"
  type        = object({ id = string, display = string })
}

variable "authenticator" {
  description = "The OOB authenticator: its plugin id, name, descriptor and configuration; the default is the ciba-sim test stand-in"
  type = object({
    plugin_id     = string
    name          = string
    descriptor_id = string
    fields        = optional(list(object({ name = string, value = string })), [])
    tables        = optional(list(any), [])
  })
  default = {
    plugin_id     = "cibaSim"
    name          = "CIBA simulator (test only)"
    descriptor_id = "com.pingidentity.ps.oidf.cibasim.SimOobAuthenticator"
  }
}

variable "transaction_lifetime" {
  description = "Seconds a backchannel request stays pending"
  type        = number
  default     = 180
}

locals {
  simulator = var.authenticator.descriptor_id == "com.pingidentity.ps.oidf.cibasim.SimOobAuthenticator"
}

resource "pingfederate_oauth_out_of_band_auth_plugin" "this" {
  plugin_id = var.authenticator.plugin_id
  name      = var.authenticator.name

  plugin_descriptor_ref = {
    id = var.authenticator.descriptor_id
  }

  configuration = {
    fields = var.authenticator.fields
    tables = var.authenticator.tables
  }

  # The one attribute the identity hint mapping fills.
  attribute_contract = {
    extended_attributes = [{ name = "subject" }]
  }
}

# Who the login_hint names becomes the grant's user, and base's DEFAULT access token mapping turns USER_KEY into the
# token's sub.
resource "pingfederate_oauth_ciba_server_policy_request_policy" "this" {
  policy_id = "${var.naming.id}Ciba"
  name      = "${var.naming.display} CIBA policy"

  authenticator_ref = { id = pingfederate_oauth_out_of_band_auth_plugin.this.id }

  transaction_lifetime            = var.transaction_lifetime
  allow_unsigned_login_hint_token = false
  require_token_for_identity_hint = false

  identity_hint_contract = {
    extended_attributes = []
  }
  identity_hint_contract_fulfillment = {
    attribute_contract_fulfillment = {
      "IDENTITY_HINT_SUBJECT" = { source = { type = "REQUEST" }, value = "IDENTITY_HINT_SUBJECT" }
    }
  }
  identity_hint_mapping = {
    attribute_contract_fulfillment = {
      "USER_KEY" = { source = { type = "REQUEST" }, value = "IDENTITY_HINT_SUBJECT" }
      "subject"  = { source = { type = "REQUEST" }, value = "IDENTITY_HINT_SUBJECT" }
    }
  }
}

# Without a default policy the backchannel endpoint answers every request with a server error.
resource "pingfederate_oauth_ciba_server_policy_settings" "this" {
  default_request_policy_ref = { id = pingfederate_oauth_ciba_server_policy_request_policy.this.id }
}

output "request_policy_id" {
  description = "The request policy CIBA clients name"
  value       = pingfederate_oauth_ciba_server_policy_request_policy.this.id
}

output "simulator" {
  description = "Whether the authenticator is the ciba-sim test stand-in"
  value       = local.simulator
}

output "env" {
  description = "The modules' settings this feature implies"
  value       = local.simulator ? { OIDF_CIBA_SIM_ENABLED = "true", OIDF_CIBA_SIM_DIR = "/opt/ciba-sim" } : {}
}
