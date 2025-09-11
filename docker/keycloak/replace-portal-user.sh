#!/bin/sh
# replace-portal-user.sh
# This script replaces the portal user and password in the Keycloak realm template with environment variables.

set -e

TEMPLATE_FILE="/tmp/pm4ml-realm.json.template"
OUTPUT_FILE="/tmp/pm4ml-realm.json"

if [ -z "$PORTAL_USER" ] || [ -z "$PORTAL_PASSWORD" ]; then
  echo "PORTAL_USER and PORTAL_PASSWORD environment variables must be set."
  exit 1
fi

if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "Template file $TEMPLATE_FILE not found!"
  exit 1
fi

sed \
  -e "s|__PORTAL_USER__|$PORTAL_USER|g" \
  -e "s|__PORTAL_PASSWORD__|$PORTAL_PASSWORD|g" \
  "$TEMPLATE_FILE" > "$OUTPUT_FILE"

# Optionally print a message
# echo "Replaced portal user and password in $OUTPUT_FILE"
