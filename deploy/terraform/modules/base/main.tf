# What every deployment's PingFederate needs, whatever the features: its issuer, its runtime certificate and trusted
# CAs, the authorization-server settings (one resource, a singleton, so the features hand their scopes and settings in
# rather than owning it), one JWT access token manager and its mappings, a default OpenID Connect policy, the modules'
# extended properties and data stores, and an optional smoke-check client.
#
# Moved from conformance/terraform (server-settings.tf, runtime-tls.tf, tokens.tf, oauth-server.tf,
# extended-properties.tf) and reference/terraform/modules/pf-reference.

locals {
  smoke_scopes = var.smoke_client == null ? [] : [{ name = var.smoke_client.scope, description = var.smoke_client.scope_description, dynamic = false }]

  # verify-full against the deployment's CA: PgJDBC refuses a server whose certificate the CA did not issue or whose
  # name is not the host dialled.
  jdbc_url = var.postgres == null ? null : "jdbc:postgresql://${var.postgres.host}:${var.postgres.port}/${var.postgres.database}?sslmode=verify-full&sslrootcert=${var.postgres.ca_file}"
}

resource "pingfederate_server_settings" "this" {
  federation_info = {
    base_url = var.pf_base_url
    # The admin API will not accept an empty entity id. Nothing here does SAML.
    saml_2_entity_id = var.pf_base_url
  }
  notifications = {
    expired_certificate_administrative_console_warning_days  = 14
    expiring_certificate_administrative_console_warning_days = 14
    notify_admin_user_password_changes                       = false
    thread_pool_exhaustion_notification_settings = {
      email_address       = ""
      notification_mode   = "LOGGING_ONLY"
      thread_dump_enabled = true
    }
  }
}

# ── TLS ─────────────────────────────────────────────────────────────────────────────────────────────

resource "pingfederate_keypairs_ssl_server_key" "runtime" {
  key_id    = var.runtime_tls.key_id
  file_data = var.runtime_tls.p12_base64
  format    = "PKCS12"
  password  = var.runtime_tls_password
}

resource "pingfederate_keypairs_ssl_server_settings" "this" {
  runtime_server_cert_ref     = { id = pingfederate_keypairs_ssl_server_key.runtime.id }
  active_runtime_server_certs = [{ id = pingfederate_keypairs_ssl_server_key.runtime.id }]
  admin_console_cert_ref      = { id = pingfederate_keypairs_ssl_server_key.runtime.id }
  active_admin_console_certs  = [{ id = pingfederate_keypairs_ssl_server_key.runtime.id }]
}

resource "pingfederate_certificate_ca" "trusted" {
  for_each = var.trusted_cas

  ca_id = each.key
  # The API takes the base-64 DER: a PEM loses its armour and line breaks, which leaves a DER's base-64 unchanged.
  file_data = replace(replace(each.value, "/-----[A-Z ]+-----/", ""), "/\\s/", "")
}

# ── the modules' storage ────────────────────────────────────────────────────────────────────────────

# The modules' tables (oidf-db-migrate.jar's families) as pf_runtime: OIDF_SSF_DATA_STORE_ID,
# OIDF_LEASE_DATA_STORE_ID and OIDF_AUTHORITY_DATA_STORE_ID name this id.
resource "pingfederate_data_store" "oidf" {
  count         = var.postgres == null ? 0 : 1
  data_store_id = "oidfruntime"
  jdbc_data_store = {
    name                         = "oidf runtime (pf_runtime)"
    driver_class                 = "org.postgresql.Driver"
    connection_url               = local.jdbc_url
    user_name                    = "pf_runtime"
    password                     = var.postgres_passwords.runtime
    validate_connection_sql      = "SELECT 1"
    min_pool_size                = 2
    max_pool_size                = 20
    blocking_timeout             = 5000
    idle_timeout                 = 5
    allow_multi_value_attributes = false
  }
}

# PingFederate's OAuth client storage, as pf_clients in schema pf (its search_path; the tables come from PingFederate's
# own PostgreSQL script). Read only on a node whose service-points.conf names ClientManagerJdbcImpl: what a cluster needs.
resource "pingfederate_data_store" "clients" {
  count         = try(var.postgres.client_storage, false) ? 1 : 0
  data_store_id = "pfclients"
  jdbc_data_store = {
    name                         = "PingFederate OAuth clients (pf_clients)"
    driver_class                 = "org.postgresql.Driver"
    connection_url               = "${local.jdbc_url}&currentSchema=pf"
    user_name                    = "pf_clients"
    password                     = var.postgres_passwords.clients
    validate_connection_sql      = "SELECT 1"
    min_pool_size                = 2
    max_pool_size                = 20
    blocking_timeout             = 5000
    idle_timeout                 = 5
    allow_multi_value_attributes = false
  }
}

resource "pingfederate_config_store" "client_storage" {
  count        = try(var.postgres.client_storage, false) ? 1 : 0
  bundle       = "org.sourceid.oauth20.domain.ClientManagerJdbcImpl"
  setting_id   = "PingFederateDSJNDIName"
  string_value = pingfederate_data_store.clients[0].data_store_id
}

resource "pingfederate_extended_properties" "modules" {
  count = var.extended_properties == null ? 0 : 1
  # A description on each: PingFederate answers an empty one where none was sent, and the provider then cannot match
  # the set it planned with the one it read back.
  items = [for name in var.extended_properties.names : {
    name         = name
    description  = "Read or written by the OIDF modules (docs/extended-properties.json)"
    multi_valued = contains(var.extended_properties.multi_valued, name)
  }]
}

# ── OAuth and OpenID Connect ────────────────────────────────────────────────────────────────────────

resource "pingfederate_oauth_server_settings" "this" {
  # PKCE with S256 only, codes that live a minute, no refresh token rotation: sound for every profile, and what FAPI
  # 2.0 §5.3.2.1-2 asks. Requiring PKCE is per client.
  disallow_plain_pkce            = true
  authorization_code_timeout     = 60
  authorization_code_entropy     = 30
  roll_refresh_token_values      = false
  refresh_rolling_interval       = 0
  refresh_token_length           = 42
  persistent_grant_lifetime      = -1
  persistent_grant_lifetime_unit = "DAYS"

  # What the features set: fapi2's PAR, iss and DPoP. Null leaves PingFederate's default.
  par_status                               = var.oauth_server.par_status
  par_reference_timeout                    = var.oauth_server.par_reference_timeout
  par_reference_length                     = var.oauth_server.par_reference_length
  include_issuer_in_authorization_response = var.oauth_server.include_issuer_in_authorization_response
  dpop_proof_enforce_replay_prevention     = var.oauth_server.dpop_proof_enforce_replay_prevention
  dpop_proof_lifetime_seconds              = var.oauth_server.dpop_proof_lifetime_seconds
  dpop_proof_require_nonce                 = var.oauth_server.dpop_proof_require_nonce

  # Not used by any profile, but required by the API.
  bypass_activation_code_confirmation = false
  device_polling_interval             = 5
  pending_authorization_timeout       = 600
  default_scope_description           = ""

  scopes           = concat(var.scopes, local.smoke_scopes)
  exclusive_scopes = length(var.exclusive_scopes) == 0 ? null : var.exclusive_scopes
}

# Three separate PS256 settings exist in PingFederate and they are easy to confuse: the access token's signature (here),
# a client assertion's (each client's token_endpoint_auth_signing_algorithm) and the ID token's (each client's
# oidc_policy). FAPI 2.0 permits PS256, ES256 and EdDSA and nothing weaker.
resource "pingfederate_oauth_access_token_manager" "jwt" {
  manager_id = "${var.naming.id}Jwt"
  name       = "${var.naming.display} JWT access tokens"

  plugin_descriptor_ref = {
    id = "com.pingidentity.pf.access.token.management.plugins.JwtBearerAccessTokenManagementPlugin"
  }

  configuration = {
    fields = [
      # MINUTES - the plugin descriptor says so ("Defines how long, in minutes"). Ten also keeps an SSF receiver's
      # token under the hour past which the SSF suite warns.
      { name = "Token Lifetime", value = tostring(var.access_token_lifetime_minutes) },
      # PF's own rotating OAuth/OIDC keys, the ones published at /pf/JWKS.
      { name = "Use Centralized Signing Key", value = "true" },
      { name = "JWS Algorithm", value = "PS256" },
      { name = "Issuer Claim Value", value = var.pf_base_url },
      { name = "Type Header Value", value = "at+jwt" },
    ]
    tables = []
  }

  attribute_contract = {
    extended_attributes = [{ name = "sub", multi_valued = false }]
  }
}

# Client credentials: there is no user, so the subject is the client.
resource "pingfederate_oauth_access_token_mapping" "client" {
  access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.jwt.id }
  context                  = { type = "CLIENT_CREDENTIALS" }

  attribute_contract_fulfillment = {
    "sub" = { source = { type = "CONTEXT" }, value = "ClientId" }
  }
}

# Authorization code and CIBA: the subject is the user the grant was made for.
resource "pingfederate_oauth_access_token_mapping" "user" {
  count                    = var.user_token_mapping ? 1 : 0
  access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.jwt.id }
  context                  = { type = "DEFAULT" }

  attribute_contract_fulfillment = {
    "sub" = { source = { type = "OAUTH_PERSISTENT_GRANT" }, value = "USER_KEY" }
  }
}

resource "pingfederate_openid_connect_policy" "this" {
  count     = var.openid_connect ? 1 : 0
  policy_id = "${var.naming.id}Oidc"
  name      = "${var.naming.display} OpenID Connect policy"

  access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.jwt.id }

  id_token_lifetime = 5

  attribute_contract = {
    extended_attributes = []
  }

  attribute_mapping = {
    attribute_contract_fulfillment = {
      "sub" = { source = { type = "TOKEN" }, value = "sub" }
    }
  }
}

# Without a default policy, a request for the openid scope is a server_error at the authorization endpoint ("No default
# OpenID Connect Policy found") rather than anything a client could act on.
resource "pingfederate_openid_connect_settings" "this" {
  count              = var.openid_connect ? 1 : 0
  default_policy_ref = { id = pingfederate_openid_connect_policy.this[0].id }
}

resource "pingfederate_oauth_client" "smoke" {
  count       = var.smoke_client != null && !try(var.postgres.client_storage, false) ? 1 : 0
  client_id   = var.smoke_client.client_id
  name        = var.smoke_client.name
  grant_types = ["CLIENT_CREDENTIALS"]
  client_auth = {
    type   = "SECRET"
    secret = var.smoke_client_secret
  }
  restrict_scopes                  = true
  restricted_scopes                = [var.smoke_client.scope]
  default_access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.jwt.id }

  depends_on = [pingfederate_oauth_server_settings.this]
}
