# ── admin API (the local authoring PingFederate only) ───────────────────────────────────────────────

variable "pf_admin_host" {
  description = "Admin API of the LOCAL authoring PingFederate, e.g. https://localhost:19999"
  type        = string

  validation {
    condition     = can(regex("^https://(localhost|127\\.0\\.0\\.1)(:[0-9]+)?$", var.pf_admin_host))
    error_message = "pf_admin_host must be a local endpoint: author locally and ship the archive."
  }
}

variable "pf_admin_username" {
  description = "Admin username on the authoring PingFederate"
  type        = string
  default     = "administrator"
}

variable "pf_admin_password" {
  description = "Admin password on the authoring PingFederate (TF_VAR_pf_admin_password; never commit)"
  type        = string
  sensitive   = true
}

# PF_TERRAFORM_PRODUCT_VERSION in build/pf-version.env; tools/pf-version-check.py holds this default to it.
variable "pf_product_version" {
  description = "The PingFederate product version the provider is told: major.minor"
  type        = string
  default     = "13.1"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.pf_product_version))
    error_message = "pf_product_version is major.minor, e.g. 13.1."
  }
}

# ── the deployment ──────────────────────────────────────────────────────────────────────────────────

variable "naming" {
  description = "The id and display stems objects are named from (modules/base)"
  type        = object({ id = string, display = string })
  default     = { id = "agenticIdp", display = "Agentic IdP" }
}

variable "pf_base_url" {
  description = "The origin PF advertises, baked into the archive: https://host[:port], no trailing slash"
  type        = string
}

variable "runtime_tls" {
  description = "The runtime certificate: base-64 PKCS#12, and the key id to store it under"
  type = object({
    p12_base64 = string
    key_id     = optional(string, "pf-runtime-tls")
  })
  # The keystore holds the private key: never in plan output or logs.
  sensitive = true
}

variable "trusted_cas" {
  description = "CA certificates for PingFederate's trusted CAs, by id: PEM or base-64 DER"
  type        = map(string)
  default     = {}
}

variable "scopes" {
  description = "Common scopes, beyond the features'; null takes modules/base's (openid, profile, email, offline_access)"
  type = list(object({
    name        = string
    description = string
    dynamic     = optional(bool, false)
  }))
  default = null
}

variable "user_token_mapping" {
  description = "Map a signed-in user's key into the access token's sub"
  type        = bool
  default     = true
}

variable "openid_connect" {
  description = "Make a default OpenID Connect policy"
  type        = bool
  default     = true
}

# docs/extended-properties.json's extended_properties list. Needed whenever clients carry federation or attestation
# properties (PingFederate drops undeclared ones silently, F-0041): a check below refuses those features without it.
variable "extended_properties" {
  description = "The extended property names to declare; null declares none"
  type        = list(string)
  default     = null
}

variable "postgres" {
  description = "The PostgreSQL the modules' tables (and optionally PF's OAuth clients) live in; null for none (modules/base)"
  type = object({
    host           = optional(string, "postgres")
    port           = optional(number, 5432)
    database       = optional(string, "oidf")
    ca_file        = string
    client_storage = optional(bool, false)
  })
  default = null
}

variable "smoke_client" {
  description = "A client_credentials client a smoke check takes a token with; null for none (modules/base)"
  type = object({
    client_id         = string
    name              = optional(string, "Smoke check")
    scope             = string
    scope_description = optional(string, "Smoke check")
  })
  default = null
}

# ── the features: null leaves a feature out ─────────────────────────────────────────────────────────

variable "features" {
  description = "Which features to configure, each with its options; see each module under deploy/terraform/modules"
  type = object({
    fapi2 = optional(object({
      par_status         = optional(string, "REQUIRED")
      dpop_require_nonce = optional(bool, false)
      clients            = optional(list(string), [])
      resource_clients   = optional(list(string), [])
    }))
    attestation = optional(object({
      auth_enabled   = optional(bool, true)
      issuer_enabled = optional(bool, false)
    }))
    federation = optional(object({
      auto_registration = optional(bool, true)
      hosting           = optional(bool, false)
      operator_api = optional(object({
        audience = optional(string, "pf-agentic-identity-operator")
        client   = optional(bool, false)
      }))
    }))
    ciba = optional(object({
      authenticator = optional(object({
        plugin_id     = string
        name          = string
        descriptor_id = string
        fields        = optional(list(object({ name = string, value = string })), [])
        tables        = optional(list(any), [])
      }))
      transaction_lifetime = optional(number, 180)
    }))
    ssf = optional(object({
      emitter = optional(bool, false)
    }))
  })
  default = {}

  # A validation fails the plan; a `check` block would only warn. The cross-variable reference needs Terraform 1.9
  # (versions.tf). var.conformance's validation reads this variable, so this one must not read var.conformance.
  validation {
    # F-0041: federation and attestation clients carry extended properties that PingFederate drops unless they are
    # declared. The conformance attester's client is covered by var.conformance's validation.
    condition     = var.extended_properties != null || (var.features.federation == null && var.features.attestation == null)
    error_message = "federation and attestation clients carry extended properties PingFederate drops unless declared: set extended_properties (docs/extended-properties.json)."
  }
}

# The conformance suites' clients, user and login form (modules/conformance-clients); null for a deployment.
variable "conformance" {
  description = "The conformance rig's suite-facing objects; null leaves them out"
  type = object({
    jwks            = map(string)
    suite_base_urls = list(string)
    suite_alias     = optional(string, "pf-agentic-identity")
    ssf_receiver    = optional(bool, true)
    ciba = optional(object({
      delivery_mode               = optional(string, "POLL")
      notification_suite_base_url = optional(string, "https://www.certification.openid.net")
    }))
    cimd_client_id    = optional(string, "")
    fapi2_attestation = optional(bool, false)
    attester = optional(object({
      signing_key_ref = string
      spiffe_bundle   = string
    }))
  })
  default = null

  validation {
    condition = var.conformance == null || (
      var.features.fapi2 != null && var.openid_connect && var.user_token_mapping &&
      (!try(var.conformance.ssf_receiver, false) || var.features.ssf != null) &&
      (try(var.conformance.ciba, null) == null || var.features.ciba != null)
    )
    error_message = "The conformance clients need fapi2, openid_connect and user_token_mapping, ssf for the SSF receiver, and ciba for the CIBA clients."
  }

  validation {
    # F-0041 for the conformance attester's client: its attestation_* extended parameters are dropped unless declared.
    condition     = try(var.conformance.attester, null) == null || var.extended_properties != null
    error_message = "The conformance attester's client carries extended properties PingFederate drops unless declared: set extended_properties (docs/extended-properties.json)."
  }

  validation {
    # The fapi2-attestation clients are refused without an attestation by an extended property (attestation_required),
    # and they authenticate by attest_jwt_client_auth, which features.attestation switches on.
    condition = !try(var.conformance.fapi2_attestation, false) || (
      var.extended_properties != null && try(var.features.attestation.auth_enabled, false)
    )
    error_message = "The fapi2-attestation clients need extended_properties and features.attestation with auth on."
  }
}

# ── secrets: one sensitive object, so the rest of the inputs (and the env output) are not ───────────

variable "secrets" {
  description = "Every secret the configuration carries; each is needed only with the feature that uses it"
  type = object({
    runtime_tls_password              = string
    postgres_runtime_password         = optional(string)
    postgres_clients_password         = optional(string, "")
    smoke_client_secret               = optional(string)
    ssf_introspection_client_secret   = optional(string)
    ssf_emitter_client_secret         = optional(string)
    federation_operator_client_secret = optional(string)
    test_user_password                = optional(string)
    attester_client_secret            = optional(string)
  })
  sensitive = true
}
