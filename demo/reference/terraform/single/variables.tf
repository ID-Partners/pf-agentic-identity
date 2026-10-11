variable "pf_admin_host" {
  description = "The LOCAL authoring PingFederate's admin API, https://localhost:<port>"
  type        = string

  validation {
    condition     = can(regex("^https://(localhost|127\\.0\\.0\\.1)(:[0-9]+)?$", var.pf_admin_host))
    error_message = "pf_admin_host must be a local endpoint: author locally and ship the archive."
  }
}

variable "pf_admin_password" {
  description = "The authoring PingFederate's administrator password (.local/<name>/secrets/pf-admin)"
  type        = string
  sensitive   = true
}

# PF_TERRAFORM_PRODUCT_VERSION in build/pf-version.env; tools/pf-version-check.py holds this default to it.
variable "pf_product_version" {
  description = "The PingFederate product version the provider is told: major.minor"
  type        = string
  default     = "13.1"
}

variable "pf_base_url" {
  description = "The stack's issuer, https://pf.reference.test:<the slot's runtime port>"
  type        = string
}

variable "stack_ca_pem" {
  description = "The stack CA's certificate, PEM (gen-tls.sh's ca.crt)"
  type        = string
}

variable "runtime_tls_p12_base64" {
  description = "The runtime certificate as base-64 PKCS#12 (gen-tls.sh's pf.p12)"
  type        = string
  sensitive   = true
}

variable "runtime_tls_password" {
  description = "pf.p12's password"
  type        = string
  sensitive   = true
}

variable "runtime_role_password" {
  description = "pf_runtime's password"
  type        = string
  sensitive   = true
}

variable "clients_role_password" {
  description = "pf_clients' password (the cluster's client storage; unused by single)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "smoke_client_secret" {
  description = "reference-smoke's client secret"
  type        = string
  sensitive   = true
}
