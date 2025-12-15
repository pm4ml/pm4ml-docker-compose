# Secrets rendered by Vault Agent from Vault KV store
# These values are fetched from vault at path: shared-secrets/pm4ml

{{ with secret "shared-secrets/data/pm4ml" -}}
AUTH_CLIENT_SECRET={{ .Data.data.AUTH_CLIENT_SECRET }}
PORTAL_PASSWORD={{ .Data.data.PORTAL_PASSWORD }}
{{- end }}
