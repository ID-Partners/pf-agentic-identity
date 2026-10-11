variable "pf_base_url" {
  description = "The origin PingFederate advertises (the stack's issuer), https://host:port with no trailing slash"
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+$", var.pf_base_url))
    error_message = "pf_base_url is an https origin with no path and no trailing slash."
  }
}

variable "runtime_tls_p12_base64" {
  description = "The runtime certificate as base-64 PKCS#12: reference/lib/gen-tls.sh's pf.p12, issued by the stack's CA"
  type        = string
  sensitive   = true
}

variable "runtime_tls_password" {
  description = "The PKCS#12 file's password (gen-tls.sh's pf.p12.pass)"
  type        = string
  sensitive   = true
}

variable "stack_ca_pem" {
  description = "The stack CA's certificate, PEM (gen-tls.sh's ca.crt): imported into PingFederate's trusted CAs"
  type        = string
}

variable "postgres_host" {
  description = "The PostgreSQL host as PingFederate reaches it; the server certificate must name it (verify-full)"
  type        = string
  default     = "postgres"
}

variable "postgres_port" {
  description = "The PostgreSQL port as PingFederate reaches it"
  type        = number
  default     = 5432
}

variable "postgres_database" {
  description = "The database the families' tables and the client storage schema are in"
  type        = string
  default     = "oidf"
}

variable "postgres_ca_file" {
  description = "The stack CA's PEM file inside the PingFederate container: PgJDBC's sslrootcert"
  type        = string
  default     = "/opt/reference/tls/ca.crt"
}

variable "runtime_role_password" {
  description = "pf_runtime's password: the modules' data store (rows only, after oidf-db-migrate.jar grants)"
  type        = string
  sensitive   = true
}

variable "client_storage" {
  description = "Keep OAuth clients in PostgreSQL (schema pf, role pf_clients) rather than PingFederate's XML files: what a cluster needs"
  type        = bool
  default     = false
}

variable "clients_role_password" {
  description = "pf_clients' password, when client_storage is true"
  type        = string
  sensitive   = true
  default     = ""
}

variable "smoke_client_secret" {
  description = "The secret of reference-smoke, the client_credentials client the stacks' smoke checks take a token with"
  type        = string
  sensitive   = true
}
