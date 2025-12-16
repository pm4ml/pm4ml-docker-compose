#!/usr/bin/env sh

set -e

# Usage function
usage() {
    cat << EOF
Vault Secrets Creator

Usage: $0 <SECRET_NAME>

Arguments:
    SECRET_NAME    Name of the secret to create in Vault

Examples:
    $0 AUTH_CLIENT_SECRET
    $0 PORTAL_PASSWORD
    $0 CC_TOKEN

The script will prompt for the secret value after you provide the name.
Secrets are stored at: shared-secrets/pm4ml
EOF
    exit 1
}

# Check arguments
if [ $# -ne 1 ]; then
    echo "Error: SECRET_NAME argument is required"
    echo ""
    usage
fi

SECRET_NAME="$1"

# Validate secret name (alphanumeric and underscores only)
if ! echo "$SECRET_NAME" | grep -qE '^[A-Z_][A-Z0-9_]*$'; then
    echo "Error: Invalid secret name. Use uppercase letters, numbers, and underscores only."
    echo "Example: AUTH_CLIENT_SECRET, DATABASE_PASSWORD"
    exit 1
fi

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

# Get existing secrets first
echo "Fetching existing secrets from shared-secrets/pm4ml..."
if vault kv get -format=json shared-secrets/pm4ml > /tmp/existing-secrets.json 2>/dev/null; then
    EXISTING_SECRETS="found"
else
    EXISTING_SECRETS="none"
fi

if [ "$EXISTING_SECRETS" = "none" ]; then
    echo "No existing secrets found. This will create a new secret store."
else
    echo "Existing secrets found. Will add/update: $SECRET_NAME"
fi
echo ""

# Prompt for the secret value
echo "Enter value for $SECRET_NAME:"
read -r SECRET_VALUE
if [ -z "$SECRET_VALUE" ]; then
    echo "Error: Secret value cannot be empty"
    exit 1
fi

echo ""
echo "Creating/updating secret '$SECRET_NAME' in Vault at shared-secrets/pm4ml..."

# Extract existing data and build the patch command
if [ "$EXISTING_SECRETS" = "found" ]; then
    # Use patch to preserve existing secrets
    vault kv patch shared-secrets/pm4ml "$SECRET_NAME=$SECRET_VALUE"
else
    # Create new secret
    vault kv put shared-secrets/pm4ml "$SECRET_NAME=$SECRET_VALUE"
fi

if [ $? -eq 0 ]; then
    echo "✓ Secret '$SECRET_NAME' successfully created/updated in Vault"
    echo ""
    echo "Secret stored at: shared-secrets/pm4ml"
    echo "  - $SECRET_NAME: [SET]"
else
    echo "✗ Failed to create/update secret"
    exit 1
fi

echo ""
echo "=== Done ==="
