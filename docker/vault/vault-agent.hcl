exit_after_auth = false
pid_file = "/tmp/vault-agent-pid"

vault {
  address = "http://vault:8233"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path   = "/vault/role-id"
      secret_id_file_path = "/vault/secret-id"
    }
  }

  sink "file" {
    config = {
      path = "/vault/token"
    }
  }
}

template {
  source      = "/vault/config/secrets.env.tpl"
  destination = "/vault/secrets/app.env"
  command     = "sh -c 'echo Secrets rendered at $(date)'"
}
