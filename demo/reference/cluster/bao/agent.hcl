# One PingFederate node's OpenBao agent: AppRole login with the role and secret ids bao-init made for this node
# (REF_NODE), then the node's secrets rendered onto the tmpfs the node mounts read-only. Runs as uid 9031, so the
# files are PingFederate's and nobody else's.
pid_file = "/tmp/bao-agent.pid"

vault {
  address = "https://openbao:8200"
  ca_cert = "/tls/ca.crt"
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/approle/role-id"
      secret_id_file_path                 = "/approle/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
}

template_config {
  exit_on_retry_failure = true
}

# OIDF_REDIS_URL has no _FILE form, and pf.cluster.auth.pwd is PingFederate's: both go in an env file the node's
# command sources before it runs /opt/pf-entrypoint.sh.
template {
  destination = "/run/oidf/oidf.env"
  perms       = "0400"
  contents    = <<-EOT
  {{- with secret (printf "secret/data/pf/%s" (env "REF_NODE")) -}}
  OIDF_REDIS_URL=rediss://oidf:{{ .Data.data.redis_password }}@redis:6379
  PF_RUN_pf_cluster_auth_pwd={{ .Data.data.cluster_password }}
  {{- end }}
  EOT
}

template {
  destination = "/run/oidf/ssf-secret-key"
  perms       = "0400"
  contents    = "{{ with secret (printf \"secret/data/pf/%s\" (env \"REF_NODE\")) }}{{ .Data.data.ssf_secret_key }}{{ end }}"
}

# Only the console boots from the archive; an engine's age_key is empty.
template {
  destination = "/run/oidf/age.key"
  perms       = "0400"
  contents    = "{{ with secret (printf \"secret/data/pf/%s\" (env \"REF_NODE\")) }}{{ .Data.data.age_key }}{{ end }}"
}
