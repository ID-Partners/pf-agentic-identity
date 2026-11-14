# Shared Signals (SSF) transmitter: the scopes that guard its streams, the client the servlet introspects receiver
# tokens with, and optionally an event-raising (provisioner) client. Receivers are the deployment's own clients.
# Moved from conformance/terraform (oauth-server.tf, clients.tf).

variable "naming" {
  description = "base's naming"
  type        = object({ id = string, display = string })
}

variable "pf_base_url" {
  description = "The issuer: the transmitter's, and where it introspects"
  type        = string
}

variable "access_token_manager_id" {
  description = "base's access_token_manager_id"
  type        = string
}

variable "introspection_client_secret" {
  description = "The introspection client's secret (OIDF_SSF_INTROSPECTION_CLIENT_SECRET)"
  type        = string
  sensitive   = true
}

variable "emitter" {
  description = "Make a client holding ssf.provision, which raises events through POST /ssf/events:emit"
  type        = bool
  default     = false
}

variable "emitter_client_secret" {
  description = "The emitter client's secret, with emitter"
  type        = string
  sensitive   = true
  default     = null
}

variable "after" {
  description = "base's ready output"
  type        = any
  default     = null
}

resource "terraform_data" "after" {
  input = var.after
}

# The servlet cannot validate a receiver's token itself; it asks PF (RFC 7662), and PF wants to know who is asking. This
# client can do that and nothing else - it has no grant that yields a token. A secret and not a key: SsfConfiguration
# takes an id and a secret and speaks HTTP Basic.
resource "pingfederate_oauth_client" "introspection" {
  client_id = "${var.naming.id}-ssf-rs"
  name      = "SSF servlet - token introspection"

  grant_types = ["ACCESS_TOKEN_VALIDATION"]

  client_auth = {
    type   = "SECRET"
    secret = var.introspection_client_secret
  }
}

# Holds ssf.provision and nothing else. A secret rather than a key so that a stdlib-only script can get its token.
resource "pingfederate_oauth_client" "emitter" {
  count     = var.emitter ? 1 : 0
  client_id = "${var.naming.id}-ssf-emitter"
  name      = "${var.naming.display} - SSF event operator"

  grant_types = ["CLIENT_CREDENTIALS"]

  client_auth = {
    type   = "SECRET"
    secret = var.emitter_client_secret
  }

  restrict_scopes  = true
  exclusive_scopes = ["ssf.provision"]

  default_access_token_manager_ref = { id = var.access_token_manager_id }

  depends_on = [terraform_data.after]
}

output "exclusive_scopes" {
  description = "For base's exclusive_scopes: the only thing between a token and every stream the transmitter holds"
  value = [
    { name = "ssf.manage", description = "Manage Shared Signals streams", dynamic = false },
    # Raises events and deprovisions subjects across every receiver's streams. Never granted to a receiver - the
    # servlet refuses a configuration where the two are the same.
    { name = "ssf.provision", description = "Raise Shared Signals events", dynamic = false },
  ]
}

output "env" {
  description = "The modules' settings this feature implies"
  value = {
    OIDF_SSF_ENABLED                 = "true"
    OIDF_SSF_ISSUER                  = var.pf_base_url
    OIDF_SSF_INTROSPECTION_ENDPOINT  = "${var.pf_base_url}/as/introspect.oauth2"
    OIDF_SSF_INTROSPECTION_CLIENT_ID = pingfederate_oauth_client.introspection.client_id
    OIDF_SSF_PROVISIONER_SCOPE       = "ssf.provision"
  }
}
