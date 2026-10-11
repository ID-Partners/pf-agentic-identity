# The reference cluster's OpenBao: one server, file storage on a volume, TLS from the stack's CA. Example-only: one
# unseal share kept in .local/ (bao-init), no audit device, no HA. A deployment uses its own OpenBao or Vault.
storage "file" {
  path = "/openbao/file"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/run/bao-tls/openbao.crt"
  tls_key_file    = "/run/bao-tls/openbao.key"
  tls_min_version = "tls12"
}

api_addr      = "https://openbao:8200"
disable_mlock = true
ui            = false
