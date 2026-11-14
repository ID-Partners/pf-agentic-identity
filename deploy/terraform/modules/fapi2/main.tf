# FAPI 2.0 Security Profile (Final), authorization-server requirements. PingFederate enforces half of it server-wide and
# half per client, and both halves are set: a server-wide PAR requirement means a client made later without its flags
# still cannot make a front-channel authorization request.
#
# This module makes nothing. Its oauth_server output goes to base's single authorization-server settings resource, its
# client output onto each FAPI client, and its env to the modules. Moved from conformance/terraform/oauth-server.tf.

variable "par_status" {
  description = "Pushed authorization requests: REQUIRED (FAPI 2.0), ENABLED or DISABLED"
  type        = string
  default     = "REQUIRED"

  validation {
    condition     = contains(["DISABLED", "ENABLED", "REQUIRED"], var.par_status)
    error_message = "par_status is DISABLED, ENABLED or REQUIRED."
  }
}

variable "dpop_require_nonce" {
  description = "Require a server-provided DPoP nonce (optional in the profile)"
  type        = bool
  default     = false
}

variable "clients" {
  description = "The client ids the modules hold to the profile (OIDF_FAPI2_CLIENTS); * is every client"
  type        = list(string)
  default     = []
}

variable "resource_clients" {
  description = "More clients the resource-server checks apply to (OIDF_FAPI_RESOURCE_CLIENTS), e.g. FAPI-CIBA clients"
  type        = list(string)
  default     = []
}

output "oauth_server" {
  description = "The server-wide half: for base's oauth_server"
  value = {
    # §5.3.2.2: PAR is supported, and an authorization request that did not come through it is rejected.
    par_status = var.par_status
    # §5.3.2.2: request_uri lifetime under 600 seconds. A minute is ample for a redirect.
    par_reference_timeout = 60
    par_reference_length  = 24
    # §5.3.2.2: iss in the authorization response (RFC 9207), which is what stops a mix-up attack.
    include_issuer_in_authorization_response = true
    # DPoP: a proof is single-use within its lifetime.
    dpop_proof_enforce_replay_prevention = true
    dpop_proof_lifetime_seconds          = 120
    dpop_proof_require_nonce             = var.dpop_require_nonce
  }
}

output "client" {
  description = "The per-client half, for every FAPI 2.0 client"
  value = {
    require_pushed_authorization_requests = true
    require_proof_key_for_code_exchange   = true
    require_dpop                          = true
    restricted_response_types             = ["code"] # the wire value; PF rejects "CODE"
  }
}

output "env" {
  description = "The modules' settings this feature implies"
  value = merge(
    { OIDF_FAPI_ENABLED = "true" },
    length(var.clients) == 0 ? {} : { OIDF_FAPI2_CLIENTS = join(",", var.clients) },
    length(var.resource_clients) == 0 ? {} : { OIDF_FAPI_RESOURCE_CLIENTS = join(",", var.resource_clients) },
  )
}
