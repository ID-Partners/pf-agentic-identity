output "env" {
  description = "The modules' settings this configuration implies, for the deployment's environment (no secrets)"
  value = merge(
    local.switches_off,
    module.base.env,
    try(module.fapi2[0].env, {}),
    try(module.attestation[0].env, {}),
    try(module.federation[0].env, {}),
    try(module.ciba[0].env, {}),
    try(module.ssf[0].env, {}),
  )
}

output "access_token_manager_id" {
  description = "The JWT access token manager clients default to"
  value       = module.base.access_token_manager_id
}

output "federation_operator_client_id" {
  description = "The federation operator client's id, or null"
  value       = try(module.federation[0].operator_client_id, null)
}
