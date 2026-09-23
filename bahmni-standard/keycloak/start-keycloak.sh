#!/bin/bash
set -euo pipefail

read_secret() {
  local name="$1"
  local path="/run/secrets/$2"
  if [[ ! -s "$path" ]]; then
    echo "Required secret is missing: $2" >&2
    exit 1
  fi
  printf -v "$name" '%s' "$(<"$path")"
  export "$name"
}

read_secret KC_DB_PASSWORD keycloak_db_password
read_secret KC_BOOTSTRAP_ADMIN_PASSWORD keycloak_admin_password
read_secret OPENMRS_OIDC_CLIENT_SECRET openmrs_oidc_client_secret
read_secret OPENELIS_OIDC_CLIENT_SECRET openelis_oidc_client_secret
read_secret ODOO_CONNECT_OIDC_CLIENT_SECRET odoo_connect_oidc_client_secret
read_secret ODOO10_CONNECT_OIDC_CLIENT_SECRET odoo10_connect_oidc_client_secret
read_secret REPORTS_OIDC_CLIENT_SECRET reports_oidc_client_secret
read_secret SMS_SERVICE_OIDC_CLIENT_SECRET sms_service_oidc_client_secret

exec /opt/keycloak/bin/kc.sh start --optimized --import-realm
