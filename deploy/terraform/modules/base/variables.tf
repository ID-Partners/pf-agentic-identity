variable "naming" {
  description = "The id stem and display stem every object this module makes is named from, e.g. { id = \"conformance\", display = \"Conformance\" } gives conformanceJwt, \"Conformance JWT access tokens\""
  type        = object({ id = string, display = string })
  default     = { id = "agenticIdp", display = "Agentic IdP" }
}

# PF derives its issuer, every endpoint in discovery and the audiences it accepts on a client assertion from this.
# It is baked into the exported archive: set it to the origin clients will use, before authoring.
variable "pf_base_url" {
  description = "The origin PingFederate advertises: https://host[:port], no path, no trailing slash"
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+$", var.pf_base_url))
    error_message = "pf_base_url is an https origin with no path and no trailing slash."
  }
}

# The runtime certificate (F-0362): one that names the issuer's host, so a module in PingFederate calling
# PingFederate at its own issuer passes the host check. The admin console takes the same certificate.
variable "runtime_tls" {
  description = "The runtime and admin console certificate: base-64 PKCS#12 and the key id it is stored under"
  type = object({
    p12_base64 = string
    key_id     = optional(string, "pf-runtime-tls")
  })
  # The keystore holds the private key: never in plan output or logs.
  sensitive = true
}

variable "runtime_tls_password" {
  description = "The PKCS#12's password"
  type        = string
  sensitive   = true
}

# PingFederate points javax.net.ssl.trustStore at its own store, so this list is the JVM's default trust: the modules'
# HTTP client and anything else on the default SSLContext check chains and host names against it.
variable "trusted_cas" {
  description = "CA certificates for PingFederate's trusted CAs, by id: PEM or the base-64 of the DER encoding"
  type        = map(string)
  default     = {}
}

variable "scopes" {
  description = "The common scopes, beyond those the features add; null takes the default"
  nullable    = false
  type = list(object({
    name        = string
    description = string
    dynamic     = optional(bool, false)
  }))
  default = [
    { name = "openid", description = "OpenID Connect" },
    { name = "profile", description = "Profile" },
    { name = "email", description = "Email" },
    { name = "offline_access", description = "Refresh tokens" },
  ]
}

# Exclusive scopes: no client carries one unless it names it. The features add theirs (ssf.*, oidf.admin.*).
variable "exclusive_scopes" {
  description = "Exclusive scopes, from the features"
  type = list(object({
    name        = string
    description = string
    dynamic     = optional(bool, false)
  }))
  default = []
}

# Server-wide authorization settings the features own: fapi2 sets PAR, the authorization response's iss and DPoP.
# Unset fields are left to PingFederate's defaults.
variable "oauth_server" {
  description = "Authorization-server settings the features set (fapi2's oauth_server output)"
  type = object({
    par_status                               = optional(string)
    par_reference_timeout                    = optional(number)
    par_reference_length                     = optional(number)
    include_issuer_in_authorization_response = optional(bool)
    dpop_proof_enforce_replay_prevention     = optional(bool)
    dpop_proof_lifetime_seconds              = optional(number)
    dpop_proof_require_nonce                 = optional(bool)
  })
  default = {}
}

variable "access_token_lifetime_minutes" {
  description = "The JWT access token manager's token lifetime, in minutes"
  type        = number
  default     = 10
}

variable "user_token_mapping" {
  description = "Map a signed-in user's key into the access token's sub (authorization code and CIBA grants)"
  type        = bool
  default     = true
}

variable "openid_connect" {
  description = "Make a default OpenID Connect policy: without one, a request for the openid scope is a server_error"
  type        = bool
  default     = true
}

# The extended properties the modules read or write on a client: docs/extended-properties.json's list. PingFederate
# drops a property it has not been told about, silently (F-0041), so a deployment whose clients carry federation or
# attestation properties needs them. Null makes none; an empty list would remove PingFederate's.
variable "extended_properties" {
  description = "The extended property names to declare, and which hold several values; null declares none"
  type = object({
    names        = list(string)
    multi_valued = optional(list(string), ["trust_chain", "contacts"])
  })
  default = null
}

variable "postgres" {
  description = "The PostgreSQL the modules' tables (and optionally PingFederate's OAuth clients) live in; null for none"
  type = object({
    host           = optional(string, "postgres")
    port           = optional(number, 5432)
    database       = optional(string, "oidf")
    ca_file        = string
    client_storage = optional(bool, false)
  })
  default = null
}

variable "postgres_passwords" {
  description = "pf_runtime's password, and pf_clients' when postgres.client_storage"
  type = object({
    runtime = string
    clients = optional(string, "")
  })
  sensitive = true
  default   = null
}

# A client_credentials client a deployment's smoke check takes a token with. With postgres.client_storage it is not
# made here: the authoring server keeps clients in its own XML files, so a client made here would ride in the archive
# and no clustered node would see it (reference/lib/smoke-client.sh registers it through the console instead).
variable "smoke_client" {
  description = "The smoke-check client's id and scope; null for none"
  type = object({
    client_id         = string
    name              = optional(string, "Smoke check")
    scope             = string
    scope_description = optional(string, "Smoke check")
  })
  default = null
}

variable "smoke_client_secret" {
  description = "The smoke-check client's secret"
  type        = string
  sensitive   = true
  default     = null
}
