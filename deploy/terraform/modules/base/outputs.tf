output "access_token_manager_id" {
  description = "The JWT access token manager every feature's clients default to"
  value       = pingfederate_oauth_access_token_manager.jwt.id
}

output "openid_connect_policy_id" {
  description = "The default OpenID Connect policy, or null without openid_connect"
  value       = var.openid_connect ? pingfederate_openid_connect_policy.this[0].id : null
}

# What a feature's clients wait on: their scopes and exclusive scopes exist once these do, and so does the
# client_credentials mapping and the extended properties a client's properties need. A reference is all a dependency
# takes; the values are only something to refer to (the singletons have no id).
output "ready" {
  description = "Refers to the authorization-server settings, the client_credentials mapping and the extended properties, for a feature's clients to wait on"
  value = {
    oauth_server_settings = length(pingfederate_oauth_server_settings.this.scopes)
    client_mapping        = pingfederate_oauth_access_token_mapping.client.id
    extended_properties   = length(pingfederate_extended_properties.modules)
  }
}

output "env" {
  description = "The modules' settings this configuration implies"
  value = var.postgres == null ? {} : {
    OIDF_SSF_DATA_STORE_ID       = pingfederate_data_store.oidf[0].data_store_id
    OIDF_LEASE_DATA_STORE_ID     = pingfederate_data_store.oidf[0].data_store_id
    OIDF_AUTHORITY_DATA_STORE_ID = pingfederate_data_store.oidf[0].data_store_id
  }
}
