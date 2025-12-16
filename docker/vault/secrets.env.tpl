# Secrets rendered by Vault Agent from Vault KV store
# These values are fetched from vault at path: shared-secrets/pm4ml
# All secrets are dynamically rendered from the KV store

{{ with secret "shared-secrets/data/pm4ml" -}}
{{ range $key, $value := .Data.data -}}
{{ $key }}={{ $value }}
{{ end -}}
{{- end }}
