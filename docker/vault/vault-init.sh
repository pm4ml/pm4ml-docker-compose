#!/usr/bin/env sh

set -ex

check_unseal() {
  while true; do
    if vault status | grep -q "Sealed.*true"; then
      echo "Vault is sealed, waiting 15 seconds before checking again..."
      sleep 15
    else
      echo "Vault is unsealed"
      break
    fi
  done
}

unseal() {
  vault operator unseal $(grep 'Key 1:' /vault/initial-keys/keys | awk '{print $NF}')
  vault operator unseal $(grep 'Key 2:' /vault/initial-keys/keys | awk '{print $NF}')
  vault operator unseal $(grep 'Key 3:' /vault/initial-keys/keys | awk '{print $NF}')
}

init() {
  vault operator init > /vault/initial-keys/keys
  ## Currently printing the keys to the console for backup purposes. In future, we can think of more secure ways to store these.
  cat /vault/initial-keys/keys
}

log_in() {
   # Use AppRole authentication instead of root token for subsequent logins
   if [ -f /vault/auth-data/role-id ] && [ -f /vault/auth-data/secret-id ]; then
      ROLE_ID=$(cat /vault/auth-data/role-id)
      SECRET_ID=$(cat /vault/auth-data/secret-id)
      vault write auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID"
   else
      echo "Warning: AppRole credentials not found, falling back to root token"
      export ROOT_TOKEN=$(grep 'Initial Root Token:' /vault/initial-keys/keys | awk '{print $NF}')
      vault login "$ROOT_TOKEN"
   fi
}

create_token() {
   vault token create -id "$MY_VAULT_TOKEN"
}

enable_app_role_auth() {
  vault auth enable approle
  vault write auth/approle/role/my-role secret_id_ttl=0 token_ttl=1000m token_max_ttl=1000m
}

generate_secret_id() {
  vault read -field role_id auth/approle/role/my-role/role-id > /vault/auth-data/role-id
  vault write -field secret_id -f auth/approle/role/my-role/secret-id > /vault/auth-data/secret-id
}

populate_data() {
  vault secrets enable -path=pki pki
  vault secrets enable -path=secrets kv-v2
  vault secrets tune -max-lease-ttl=97600h pki
  vault write -field=certificate pki/root/generate/internal \
          common_name="example.com" \
          ttl=97600h
  vault write pki/config/urls \
      issuing_certificates="http://127.0.0.1:8233/v1/pki/ca" \
      crl_distribution_points="http://127.0.0.1:8233/v1/pki/crl"
  vault write pki/roles/example.com allowed_domains=example.com allow_subdomains=true allow_any_name=true allow_localhost=true enforce_hostnames=false require_cn=false max_ttl=97600h
  vault write pki/roles/client-cert-role allowed_domains=example.com allow_subdomains=true allow_any_name=true allow_localhost=true enforce_hostnames=false require_cn=false max_ttl=97600h
  vault write pki/roles/server-cert-role allowed_domains=example.com allow_subdomains=true allow_any_name=true allow_localhost=true enforce_hostnames=false require_cn=false max_ttl=97600h

  tee policy.hcl <<EOF
# List, create, update, and delete key/value secrets (KV v2)
path "secrets/data/*"
{
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secrets/metadata/*"
{
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secrets/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "kv/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "pki/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

path "pki_int/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

  vault policy write test-policy policy.hcl
  vault write auth/approle/role/my-role policies=test-policy ttl=1h

  vault secrets enable -path=pki_int pki
  vault secrets tune -max-lease-ttl=43800h pki_int
  vault write pki_int/roles/example.com allowed_domains=example.com allow_subdomains=true allow_any_name=true allow_localhost=true enforce_hostnames=false max_ttl=600h
}

if [ -s /vault/auth-data/secret-id ]; then
   check_unseal
   log_in
   generate_secret_id
else
   init
   unseal
   log_in
   create_token
   enable_app_role_auth
   generate_secret_id
   populate_data
fi

vault status > /vault/auth-data/status
