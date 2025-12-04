# Secrets rendered by Vault Agent from Vault KV store
# These values are fetched from vault at path: secrets/pm4ml

{{ with secret "secrets/pm4ml" -}}
AUTH_CLIENT_SECRET={{ .Data.auth_client_secret }}
PORTAL_PASSWORD={{ .Data.portal_password }}
{{- end }}
