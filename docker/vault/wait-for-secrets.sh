#!/bin/sh
# Wait for Vault Agent to render secrets before starting the service

set -e

SECRETS_FILE="/vault/shared-secrets/app.env"
MAX_WAIT=30
WAIT_COUNT=0

echo "Waiting for Vault secrets to be rendered..."

while [ ! -f "$SECRETS_FILE" ]; do
  if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    echo "ERROR: Timeout waiting for $SECRETS_FILE"
    echo "vault-agent may not have started or failed to render secrets"
    exit 1
  fi

  echo "Waiting for $SECRETS_FILE... ($WAIT_COUNT/$MAX_WAIT)"
  sleep 1
  WAIT_COUNT=$((WAIT_COUNT + 1))
done

echo "✓ Secrets file found, loading environment variables..."

# Source the secrets file to export variables
set -a
. "$SECRETS_FILE"
set +a

echo "✓ Secrets loaded successfully"
echo "Starting service: $@"

# Execute the original command
exec "$@"
