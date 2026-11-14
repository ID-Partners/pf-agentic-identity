# One agentic IdP's PingFederate configuration, composed from the feature modules under ../modules: base always, each
# feature when var.features names it, and the conformance suites' objects when var.conformance is set. Applied to a
# local authoring PingFederate and exported as the deployment's config archive; never applied to a deployment.
#
# The env output is the other half of the deployment: the modules' settings these features imply, so PingFederate's
# configuration and the modules' never disagree about what is switched on.

locals {
  f = var.features

  # base owns the one authorization-server settings resource; the features hand it their scopes and settings.
  exclusive_scopes = concat(
    local.f.ssf == null ? [] : module.ssf[0].exclusive_scopes,
    local.f.federation == null ? [] : module.federation[0].exclusive_scopes,
  )

  # FAPI 2.0's two rules PingFederate 13.1 cannot apply per client - a client assertion's aud must be the issuer, as a
  # string, and a DPoP proof must be PS256, ES256 or EdDSA - are Fapi2ProfileFilter's, for the clients
  # OIDF_FAPI2_CLIENTS lists and nobody else. PF 13.1.3 accepts RS256 on a proof with no setting to narrow it, and its
  # one audience check (Rfc7523bisCompliantAudienceVerification) is server-wide and set off in the rig by config-store/,
  # so the SSF suite's client keeps its token-endpoint audience. A list and not "*", because the rig is the proof of
  # why: that SSF client is an ordinary OAuth client that addresses its assertion to the token endpoint, as OIDC Core
  # says to, and with the rules on every client the SSF plan went from 19 of 19 to 1 of 19.
  #
  # The FAPI-CIBA plan's clients get FAPI 1.0 Baseline 6.2.1 at UserInfo instead (OIDF_FAPI_RESOURCE_CLIENTS:
  # x-fapi-interaction-id set, an access token in the query refused): their assertions address the token endpoint too,
  # and the FAPI 2.0 audience rule would refuse them.
  # The fapi2-attestation plan's clients (X-E09) are FAPI 2.0 clients too.
  conformance_attest_clients = try(var.conformance.fapi2_attestation, false) ? ["conformance-fapi2-attest-client1", "conformance-fapi2-attest-client2"] : []
  conformance_fapi2_clients  = var.conformance == null ? [] : concat(["conformance-fapi2-client1", "conformance-fapi2-client2"], local.conformance_attest_clients)
  conformance_ciba_clients   = try(var.conformance.ciba, null) == null ? [] : ["conformance-ciba-client1", "conformance-ciba-client2"]

  # In the development profile a component whose switch is unset is on; a feature left out is switched off explicitly.
  switches_off = {
    OIDF_FAPI_ENABLED               = "false"
    OIDF_FEDERATION_ENABLED         = "false"
    OIDF_AUTO_REGISTRATION_ENABLED  = "false"
    OIDF_HOSTING_ENABLED            = "false"
    OIDF_OPERATOR_API_ENABLED       = "false"
    OIDF_ATTESTATION_AUTH_ENABLED   = "false"
    OIDF_ATTESTATION_ISSUER_ENABLED = "false"
    OIDF_SSF_ENABLED                = "false"
  }
}

module "base" {
  source = "../modules/base"

  naming               = var.naming
  pf_base_url          = var.pf_base_url
  runtime_tls          = var.runtime_tls
  runtime_tls_password = var.secrets.runtime_tls_password
  trusted_cas          = var.trusted_cas
  scopes               = var.scopes
  exclusive_scopes     = local.exclusive_scopes
  oauth_server         = local.f.fapi2 == null ? {} : module.fapi2[0].oauth_server
  user_token_mapping   = var.user_token_mapping
  openid_connect       = var.openid_connect
  extended_properties  = var.extended_properties == null ? null : { names = var.extended_properties }
  postgres             = var.postgres
  postgres_passwords = var.postgres == null ? null : {
    runtime = var.secrets.postgres_runtime_password
    clients = var.secrets.postgres_clients_password
  }
  smoke_client        = var.smoke_client
  smoke_client_secret = var.secrets.smoke_client_secret
}

module "fapi2" {
  count  = local.f.fapi2 == null ? 0 : 1
  source = "../modules/fapi2"

  par_status         = local.f.fapi2.par_status
  dpop_require_nonce = local.f.fapi2.dpop_require_nonce
  clients            = concat(local.f.fapi2.clients, local.conformance_fapi2_clients)
  resource_clients   = concat(local.f.fapi2.resource_clients, local.conformance_ciba_clients)
}

module "attestation" {
  count  = local.f.attestation == null ? 0 : 1
  source = "../modules/attestation"

  auth_enabled   = local.f.attestation.auth_enabled
  issuer_enabled = local.f.attestation.issuer_enabled
}

module "federation" {
  count  = local.f.federation == null ? 0 : 1
  source = "../modules/federation"

  naming                 = var.naming
  pf_base_url            = var.pf_base_url
  auto_registration      = local.f.federation.auto_registration
  hosting                = local.f.federation.hosting
  operator_api           = local.f.federation.operator_api
  operator_client_secret = var.secrets.federation_operator_client_secret
  after                  = module.base.ready
}

module "ciba" {
  count  = local.f.ciba == null ? 0 : 1
  source = "../modules/ciba"

  naming               = var.naming
  authenticator        = local.f.ciba.authenticator
  transaction_lifetime = local.f.ciba.transaction_lifetime
}

module "ssf" {
  count  = local.f.ssf == null ? 0 : 1
  source = "../modules/ssf"

  naming                      = var.naming
  pf_base_url                 = var.pf_base_url
  access_token_manager_id     = module.base.access_token_manager_id
  introspection_client_secret = var.secrets.ssf_introspection_client_secret
  emitter                     = local.f.ssf.emitter
  emitter_client_secret       = var.secrets.ssf_emitter_client_secret
  after                       = module.base.ready
}

module "conformance_clients" {
  count  = var.conformance == null ? 0 : 1
  source = "../modules/conformance-clients"

  jwks                     = var.conformance.jwks
  suite_base_urls          = var.conformance.suite_base_urls
  suite_alias              = var.conformance.suite_alias
  access_token_manager_id  = module.base.access_token_manager_id
  openid_connect_policy_id = module.base.openid_connect_policy_id
  fapi2_client             = one(module.fapi2[*].client)
  ssf_receiver             = var.conformance.ssf_receiver
  ciba = var.conformance.ciba == null ? null : {
    request_policy_id           = module.ciba[0].request_policy_id
    delivery_mode               = var.conformance.ciba.delivery_mode
    notification_suite_base_url = var.conformance.ciba.notification_suite_base_url
  }
  cimd_client_id         = var.conformance.cimd_client_id
  fapi2_attestation      = var.conformance.fapi2_attestation
  attester               = var.conformance.attester
  attester_client_secret = var.secrets.attester_client_secret
  test_user_password     = var.secrets.test_user_password
  after                  = module.base.ready
}

# The combination rules (the conformance clients need their features; federation and attestation clients need
# extended_properties, F-0041) are `validation` blocks on var.features and var.conformance in variables.tf. A
# `check` block here would only warn, and the plan and apply would go ahead.
