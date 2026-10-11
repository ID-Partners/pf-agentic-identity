# reference/cluster's PingFederate configuration: modules/pf-reference applied to a localhost authoring PingFederate by
# reference/lib/author.sh, which exports the result as the stack's archive and encrypts it with age. Never applied to
# the stack's own nodes: they boot from that archive, the console replicates it, and the engines take it from the console.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    pingfederate = {
      source  = "pingidentity/pingfederate"
      version = "~> 1.10"
    }
  }
}

provider "pingfederate" {
  https_host      = var.pf_admin_host
  admin_api_path  = "/pf-admin-api/v1"
  username        = "administrator"
  password        = var.pf_admin_password
  product_version = var.pf_product_version
  # The authoring server's own certificate, on 127.0.0.1: pf_admin_host refuses any other host.
  insecure_trust_all_tls              = true
  x_bypass_external_validation_header = true
}

module "pf_reference" {
  source = "../modules/pf-reference"

  pf_base_url            = var.pf_base_url
  stack_ca_pem           = var.stack_ca_pem
  runtime_tls_p12_base64 = var.runtime_tls_p12_base64
  runtime_tls_password   = var.runtime_tls_password
  runtime_role_password  = var.runtime_role_password
  client_storage         = true
  clients_role_password  = var.clients_role_password
  smoke_client_secret    = var.smoke_client_secret
}
