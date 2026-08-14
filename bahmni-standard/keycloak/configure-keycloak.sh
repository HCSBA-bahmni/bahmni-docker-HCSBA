#!/bin/bash
set -euo pipefail

KCADM=/opt/keycloak/bin/kcadm.sh
ADMIN_PASSWORD="$(</run/secrets/keycloak_admin_password)"

"$KCADM" config credentials --server http://keycloak:8080 --realm master \
  --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$ADMIN_PASSWORD" >/dev/null

# OpenMRS already has exact usernames containing spaces. Self-registration is disabled and
# username editing remains admin-only; keep Keycloak's length and IDN-homograph validators,
# but remove only the incompatible prohibited-character validator.
"$KCADM" update users/profile -r hcsba -f /opt/hcsba/user-profile-hcsba.json >/dev/null
"$KCADM" update realms/hcsba -s loginTheme=hcsba >/dev/null

client_uuid() {
  "$KCADM" get clients -r hcsba -q "clientId=$1" --fields id --format csv --noquotes \
    | tr -d '\r' | head -n 1
}

set_client_secret() {
  local client_id="$1"
  local secret_file="$2"
  local uuid
  uuid="$(client_uuid "$client_id")"
  if [[ -z "$uuid" ]]; then
    echo "Keycloak client not found: $client_id" >&2
    exit 1
  fi
  "$KCADM" update "clients/$uuid" -r hcsba -s "secret=$(<"/run/secrets/$secret_file")" >/dev/null
}

ensure_service_client() {
  local client_id="$1"
  local display_name="$2"
  local uuid
  uuid="$(client_uuid "$client_id")"
  if [[ -n "$uuid" ]]; then
    return
  fi
  "$KCADM" create clients -r hcsba -s "clientId=$client_id" -s "name=$display_name" \
    -s enabled=true -s protocol=openid-connect -s clientAuthenticatorType=client-secret \
    -s publicClient=false -s bearerOnly=false -s standardFlowEnabled=false \
    -s implicitFlowEnabled=false -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=true >/dev/null
  uuid="$(client_uuid "$client_id")"
  "$KCADM" create "clients/$uuid/protocol-mappers/models" -r hcsba \
    -s name="OpenMRS audience" -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
    -s 'config."included.client.audience"=openmrs' -s 'config."access.token.claim"=true' \
    -s 'config."introspection.token.claim"=true' >/dev/null
}

ensure_service_client openelis "OpenELIS technical account"
ensure_service_client odoo-connect "Odoo connector technical account"
ensure_service_client odoo10-connect "Odoo 10 connector technical account"
ensure_service_client reports "Bahmni Reports technical account"
ensure_service_client sms-service "Bahmni SMS technical account"

set_client_secret openmrs openmrs_oidc_client_secret
set_client_secret openelis openelis_oidc_client_secret
set_client_secret odoo-connect odoo_connect_oidc_client_secret
set_client_secret odoo10-connect odoo10_connect_oidc_client_secret
set_client_secret reports reports_oidc_client_secret
set_client_secret sms-service sms_service_oidc_client_secret

OPENMRS_CLIENT_UUID="$(client_uuid openmrs)"
OPENMRS_BACKCHANNEL_LOGOUT_URL="${OPENMRS_BACKCHANNEL_LOGOUT_URL:-${BAHMNI_PUBLIC_URL}/openmrs/oauth2backchannellogout}"
# Keep redirect URIs deterministic when the same realm is used first against shared DEV and
# later against the isolated localhost clone. No wildcard redirect is accepted.
"$KCADM" update "clients/$OPENMRS_CLIENT_UUID" -r hcsba \
  -s "rootUrl=$BAHMNI_PUBLIC_URL" \
  -s "baseUrl=$BAHMNI_PUBLIC_URL/bahmni/" \
  -s frontchannelLogout=false \
  -s 'redirectUris=["'"$BAHMNI_PUBLIC_URL"'/openmrs/oauth2login","'"$BAHMNI_LOCAL_DEV_URL"'/openmrs/oauth2login"]' \
  -s 'webOrigins=["'"$BAHMNI_PUBLIC_URL"'","'"$BAHMNI_LOCAL_DEV_URL"'"]' \
  -s 'attributes."backchannel.logout.url"="'"$OPENMRS_BACKCHANNEL_LOGOUT_URL"'"' \
  -s 'attributes."backchannel.logout.session.required"=true' \
  -s 'attributes."backchannel.logout.revoke.offline.tokens"=true' \
  -s 'attributes."post.logout.redirect.uris"="'"$BAHMNI_PUBLIC_URL"'/bahmni/login?loggedOut=1##'"$BAHMNI_LOCAL_DEV_URL"'/bahmni/login?loggedOut=1"' >/dev/null

if ! "$KCADM" get "clients/$OPENMRS_CLIENT_UUID/protocol-mappers/models" -r hcsba \
  --fields name --format csv --noquotes | tr -d '\r' | grep -Fxq "OpenMRS system ID"; then
  "$KCADM" create "clients/$OPENMRS_CLIENT_UUID/protocol-mappers/models" -r hcsba \
    -s name="OpenMRS system ID" -s protocol=openid-connect \
    -s protocolMapper=oidc-usermodel-attribute-mapper \
    -s 'config."user.attribute"=openmrs_system_id' \
    -s 'config."claim.name"=openmrs_system_id' \
    -s 'config."jsonType.label"=String' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true' >/dev/null
fi

# Recovery codes must be an alternative to TOTP in the conditional 2FA flow.
while IFS=',' read -r execution_id display_name; do
  if [[ "$display_name" == "Recovery Authentication Code Form" ]]; then
    # Keycloak 26 updates an execution requirement through the parent flow
    # endpoint; /authentication/executions/{id} is read-only apart from
    # priority/configuration sub-resources.
    "$KCADM" update "authentication/flows/browser/executions" -r hcsba \
      -s "id=$execution_id" -s requirement=ALTERNATIVE --no-merge >/dev/null
  fi
done < <("$KCADM" get authentication/flows/browser/executions -r hcsba \
  --fields id,displayName --format csv --noquotes)

echo "Keycloak realm hcsba configured."
