#!/usr/bin/env sh

set -e

echo "=== Vault Secrets Creator ==="
echo ""

# Check if vault is available
if ! command -v vault > /dev/null 2>&1; then
    echo "Error: vault command not found"
    exit 1
fi

# Wait for vault to be ready
echo "Waiting for Vault to be ready..."
until vault status > /dev/null 2>&1; do
    echo "Vault is not ready yet, waiting..."
    sleep 2
done
echo "Vault is ready"
echo ""

# Login to vault using AppRole
if [ -f /vault/auth-data/role-id ] && [ -f /vault/auth-data/secret-id ]; then
    echo "Logging in to Vault using AppRole..."
    ROLE_ID=$(cat /vault/auth-data/role-id)
    SECRET_ID=$(cat /vault/auth-data/secret-id)

    # Login and extract the client token
    VAULT_TOKEN=$(vault write -field=token auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID")
    export VAULT_TOKEN

    echo "Successfully logged in to Vault"
    echo ""
else
    echo "Error: AppRole credentials not found"
    echo "Please ensure vault is initialized and AppRole credentials are available"
    exit 1
fi

# Prompt for AUTH_CLIENT_SECRET
echo "Enter AUTH_CLIENT_SECRET:"
read -r AUTH_CLIENT_SECRET
if [ -z "$AUTH_CLIENT_SECRET" ]; then
    echo "Error: AUTH_CLIENT_SECRET cannot be empty"
    exit 1
fi

# Prompt for PORTAL_PASSWORD
echo "Enter PORTAL_PASSWORD:"
read -r PORTAL_PASSWORD
if [ -z "$PORTAL_PASSWORD" ]; then
    echo "Error: PORTAL_PASSWORD cannot be empty"
    exit 1
fi

echo ""
echo "Creating secrets in Vault at shared-secrets/pm4ml..."

# Create secrets in vault (using KV v2 command)
vault kv put shared-secrets/pm4ml \
    AUTH_CLIENT_SECRET="$AUTH_CLIENT_SECRET" \
    PORTAL_PASSWORD="$PORTAL_PASSWORD"

if [ $? -eq 0 ]; then
    echo "✓ Secrets successfully created in Vault"
    echo ""
    echo "Secrets stored at: shared-secrets/pm4ml"
    echo "  - AUTH_CLIENT_SECRET: [SET]"
    echo "  - PORTAL_PASSWORD: [SET]"
else
    echo "✗ Failed to create secrets"
    exit 1
fi

echo ""
echo "=== Done ==="
