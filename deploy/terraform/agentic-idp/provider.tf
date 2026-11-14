# PingFederate is authored against a LOCAL stock PF and shipped as a config archive.
#
# This provider never points at a running deployment: a deployed PF exposes its runtime and not its admin API. It points
# at a stock PF container on this machine, the realised configuration is exported as data.zip, and the deployment's PF
# boots from that.
provider "pingfederate" {
  https_host     = var.pf_admin_host
  admin_api_path = "/pf-admin-api/v1"
  username       = var.pf_admin_username
  password       = var.pf_admin_password
  # Which fields the provider may send: PF_TERRAFORM_PRODUCT_VERSION in build/pf-version.env, which
  # tools/pf-version-check.py holds the default to.
  product_version = var.pf_product_version
  # Self-signed, and on 127.0.0.1: variables.tf refuses any other host.
  insecure_trust_all_tls              = true
  x_bypass_external_validation_header = true
}
