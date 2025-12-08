exit_after_auth = false
pid_file = "/tmp/vault-agent-pid"

vault {
  address = "http://vault:8233"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path   = "/vault/auth-data/role-id"
      secret_id_file_path = "/vault/auth-data/secret-id"
    }
  }

  sink "file" {
    config = {
      path = "/vault/token"
    }
  }
}

template_config {
  exit_on_retry_failure = false
  static_secret_render_interval = "1m"
  max_connections_per_host = 20
}

template {
  source      = "/vault/config/secrets.env.tpl"
  destination = "/shared-secrets/app.env"
  command     = "sh -c 'echo Secrets rendered at $(date)'"
}
