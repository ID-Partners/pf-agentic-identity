output "oidf_data_store_id" {
  description = "The modules' data store: OIDF_SSF_DATA_STORE_ID, OIDF_LEASE_DATA_STORE_ID and OIDF_AUTHORITY_DATA_STORE_ID"
  value       = pingfederate_data_store.oidf.data_store_id
}

output "clients_data_store_id" {
  description = "PingFederate's OAuth client storage data store, or null without client_storage"
  value       = var.client_storage ? pingfederate_data_store.clients[0].data_store_id : null
}
