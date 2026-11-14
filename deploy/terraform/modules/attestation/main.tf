# OAuth 2.0 Attestation-Based Client Authentication and the client attester. Neither needs a PingFederate object of its
# own: the token-endpoint filter and the attester are the modules, switched on by their settings, and the clients they
# authenticate carry their trust in extended properties - which base declares (extended_properties) and which this
# module's needs_extended_properties output says it needs.
#
# Evidence sources (SPIFFE, cloud workload tokens, CIMD, devices) are the attester's settings, not PingFederate's; the
# deployment profile (private/plans/agentic-idp-profiles.md, phase 2) renders them.

variable "auth_enabled" {
  description = "Authenticate clients at the token endpoint by attestation (OIDF_ATTESTATION_AUTH_ENABLED)"
  type        = bool
  default     = true
}

variable "issuer_enabled" {
  description = "Run the client attester's issuance endpoint, /federation/attestation (OIDF_ATTESTATION_ISSUER_ENABLED)"
  type        = bool
  default     = false
}

output "needs_extended_properties" {
  description = "Always: attestation clients carry attestation_* extended properties PingFederate otherwise drops"
  value       = true
}

output "env" {
  description = "The modules' settings this feature implies"
  value = {
    OIDF_ATTESTATION_AUTH_ENABLED   = tostring(var.auth_enabled)
    OIDF_ATTESTATION_ISSUER_ENABLED = tostring(var.issuer_enabled)
  }
}
