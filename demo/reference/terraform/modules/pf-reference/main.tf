# The PingFederate configuration both reference stacks share, applied to a localhost authoring PingFederate and
# exported as the stack's config archive (reference/lib/author.sh). An example: it configures what the stack needs
# to boot on the production profile and hand out one token, and nothing a deployment would add on top.

locals {
  # verify-full against the stack's CA: PgJDBC refuses a server whose certificate the CA did not issue or whose
  # name is not the host dialled.
  jdbc_url = "jdbc:postgresql://${var.postgres_host}:${var.postgres_port}/${var.postgres_database}?sslmode=verify-full&sslrootcert=${var.postgres_ca_file}"
}

resource "pingfederate_server_settings" "this" {
  federation_info = {
    base_url         = var.pf_base_url
    saml_2_entity_id = var.pf_base_url
  }
}

# The runtime certificate, issued by the stack's CA for pf.reference.test, localhost and the node names; HAProxy
# checks it (check-ssl verify required) and a module calling the issuer checks the host name against it.
resource "pingfederate_keypairs_ssl_server_key" "runtime" {
  key_id    = "pf-reference-tls"
  file_data = var.runtime_tls_p12_base64
  format    = "PKCS12"
  password  = var.runtime_tls_password
}

resource "pingfederate_keypairs_ssl_server_settings" "this" {
  runtime_server_cert_ref     = { id = pingfederate_keypairs_ssl_server_key.runtime.id }
  active_runtime_server_certs = [{ id = pingfederate_keypairs_ssl_server_key.runtime.id }]
  admin_console_cert_ref      = { id = pingfederate_keypairs_ssl_server_key.runtime.id }
  active_admin_console_certs  = [{ id = pingfederate_keypairs_ssl_server_key.runtime.id }]
}

# The stack's CA in PingFederate's trusted CAs. PingFederate points javax.net.ssl.trustStore at its own store
# (server/default/data/ping-ssl-client-trust-cas.jks: jcmd on a 13.1.3 node, 2026-10-08, showed it in place of the
# -Djavax.net.ssl.trustStore JAVA_OPTS gave), so this list - replicated to every node - is the JVM's default trust,
# which libs/platform's HTTP client and anything else on the default SSLContext use, host names checked.
resource "pingfederate_certificate_ca" "stack" {
  ca_id     = "pf-reference-ca"
  file_data = replace(replace(var.stack_ca_pem, "/-----[A-Z ]+-----/", ""), "/\\s/", "")
}

# The modules' tables (oidf-db-migrate.jar's families) as pf_runtime: OIDF_SSF_DATA_STORE_ID,
# OIDF_LEASE_DATA_STORE_ID and OIDF_AUTHORITY_DATA_STORE_ID name this id.
resource "pingfederate_data_store" "oidf" {
  data_store_id = "oidfruntime"
  jdbc_data_store = {
    name                         = "oidf runtime (pf_runtime)"
    driver_class                 = "org.postgresql.Driver"
    connection_url               = local.jdbc_url
    user_name                    = "pf_runtime"
    password                     = var.runtime_role_password
    validate_connection_sql      = "SELECT 1"
    min_pool_size                = 2
    max_pool_size                = 20
    blocking_timeout             = 5000
    idle_timeout                 = 5
    allow_multi_value_attributes = false
  }
}

# PingFederate's OAuth client storage, as pf_clients in schema pf (its search_path; the pf-client-storage job made
# the tables from PingFederate's own PostgreSQL script). Bound below; read only on a node whose service-points.conf
# names ClientManagerJdbcImpl.
resource "pingfederate_data_store" "clients" {
  count         = var.client_storage ? 1 : 0
  data_store_id = "pfclients"
  jdbc_data_store = {
    name                         = "PingFederate OAuth clients (pf_clients)"
    driver_class                 = "org.postgresql.Driver"
    connection_url               = "${local.jdbc_url}&currentSchema=pf"
    user_name                    = "pf_clients"
    password                     = var.clients_role_password
    validate_connection_sql      = "SELECT 1"
    min_pool_size                = 2
    max_pool_size                = 20
    blocking_timeout             = 5000
    idle_timeout                 = 5
    allow_multi_value_attributes = false
  }
}

resource "pingfederate_config_store" "client_storage" {
  count        = var.client_storage ? 1 : 0
  bundle       = "org.sourceid.oauth20.domain.ClientManagerJdbcImpl"
  setting_id   = "PingFederateDSJNDIName"
  string_value = pingfederate_data_store.clients[0].data_store_id
}

# OAuth basics: one JWT access token manager and a client_credentials mapping, enough for the smoke client.
resource "pingfederate_oauth_server_settings" "this" {
  authorization_code_timeout     = 60
  authorization_code_entropy     = 30
  refresh_token_length           = 42
  persistent_grant_lifetime      = -1
  persistent_grant_lifetime_unit = "DAYS"
  roll_refresh_token_values      = false
  refresh_rolling_interval       = 0
  disallow_plain_pkce            = true
  default_scope_description      = ""
  scopes = [
    { name = "reference.smoke", description = "The reference stacks' smoke check", dynamic = false },
  ]
}

resource "pingfederate_oauth_access_token_manager" "jwt" {
  manager_id = "referenceJwt"
  name       = "Reference JWT access tokens"
  plugin_descriptor_ref = {
    id = "com.pingidentity.pf.access.token.management.plugins.JwtBearerAccessTokenManagementPlugin"
  }
  configuration = {
    fields = [
      { name = "Token Lifetime", value = "10" },
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

resource "pingfederate_oauth_access_token_mapping" "client" {
  access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.jwt.id }
  context                  = { type = "CLIENT_CREDENTIALS" }
  attribute_contract_fulfillment = {
    "sub" = { source = { type = "CONTEXT" }, value = "ClientId" }
  }
}

# The one smoke client, on single only. With client_storage the client belongs in PostgreSQL, and the authoring
# PingFederate keeps clients in its own XML files (its service-points.conf is the image's), so a client made here would
# ride in the archive's files and no clustered node would see it: reference/lib/smoke-client.sh registers it through
# the running console's admin API instead (seen 2026-10-08: invalid_client on both engines until it did).
resource "pingfederate_oauth_client" "smoke" {
  count       = var.client_storage ? 0 : 1
  client_id   = "reference-smoke"
  name        = "Reference stack smoke check"
  grant_types = ["CLIENT_CREDENTIALS"]
  client_auth = {
    type   = "SECRET"
    secret = var.smoke_client_secret
  }
  restrict_scopes                  = true
  restricted_scopes                = ["reference.smoke"]
  default_access_token_manager_ref = { id = pingfederate_oauth_access_token_manager.jwt.id }
}
