#!/bin/sh
# replace-portal-domain.sh
# This script replaces the portal domain in the Oathkeeper config template with environment variables.

if [ -z "$PM4ML_DOMAIN" ]; then
  echo "PM4ML_DOMAIN environment variable must be set."
  exit 1
fi

INPUT_FILE="/config.yaml.template"
OUTPUT_FILE="/tmp/config.yaml"

# Replace the placeholder with the actual domain
sed -e "s|__PM4ML_DOMAIN__|$PM4ML_DOMAIN|g" "$INPUT_FILE" > "$OUTPUT_FILE"

echo "Replaced portal domain in $OUTPUT_FILE"