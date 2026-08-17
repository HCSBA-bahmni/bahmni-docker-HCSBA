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
PASSWORD_POLICY="hashAlgorithm(argon2) and length(12) and notUsername and notEmail and passwordHistory(5)"
"$KCADM" update realms/hcsba \
  -s loginTheme=hcsba \
  -s "passwordPolicy=$PASSWORD_POLICY" \
  -s webAuthnPolicyRpEntityName=HCSBA \
  -s "webAuthnPolicyRpId=$KEYCLOAK_PUBLIC_HOST" \
  -s 'webAuthnPolicySignatureAlgorithms=["ES256","RS256"]' \
  -s 'webAuthnPolicyAttestationConveyancePreference=none' \
  -s 'webAuthnPolicyAuthenticatorAttachment=not specified' \
  -s webAuthnPolicyRequireResidentKey=No \
  -s webAuthnPolicyUserVerificationRequirement=preferred \
  -s webAuthnPolicyCreateTimeout=60 \
  -s webAuthnPolicyAvoidSameAuthenticatorRegister=true \
  -s webAuthnPolicyPasswordlessRpEntityName=HCSBA \
  -s "webAuthnPolicyPasswordlessRpId=$KEYCLOAK_PUBLIC_HOST" \
  -s 'webAuthnPolicyPasswordlessSignatureAlgorithms=["ES256","RS256"]' \
  -s 'webAuthnPolicyPasswordlessAttestationConveyancePreference=none' \
  -s 'webAuthnPolicyPasswordlessAuthenticatorAttachment=not specified' \
  -s webAuthnPolicyPasswordlessRequireResidentKey=Yes \
  -s webAuthnPolicyPasswordlessUserVerificationRequirement=required \
  -s webAuthnPolicyPasswordlessCreateTimeout=60 \
  -s webAuthnPolicyPasswordlessAvoidSameAuthenticatorRegister=true \
  -s webAuthnPolicyPasswordlessPasskeysEnabled=true >/dev/null

ensure_required_action() {
  local provider_id="$1"
  local display_name="$2"
  local priority="$3"
  if ! "$KCADM" get authentication/required-actions -r hcsba \
    --fields alias --format csv --noquotes | tr -d '\r' | grep -Fxq "$provider_id"; then
    "$KCADM" create authentication/register-required-action -r hcsba \
      -s "providerId=$provider_id" -s "name=$display_name" >/dev/null
  fi
  "$KCADM" update "authentication/required-actions/$provider_id" -r hcsba \
    -s "alias=$provider_id" -s "name=$display_name" -s "providerId=$provider_id" \
    -s enabled=true -s defaultAction=false -s "priority=$priority" >/dev/null
}

# Registration is opt-in during DEV. This exposes hardware security keys and
# passwordless passkeys without locking out users that currently only have TOTP.
ensure_required_action webauthn-register "Webauthn Register" 20
ensure_required_action webauthn-register-passwordless "Webauthn Register Passwordless" 25

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

# Recovery codes and WebAuthn security keys are alternatives to TOTP in the
# conditional 2FA flow. Passwordless passkeys are handled by Keycloak's default
# username form when webAuthnPolicyPasswordlessPasskeysEnabled is active.
while IFS=',' read -r execution_id display_name; do
  if [[ "$display_name" == "Recovery Authentication Code Form" || \
        "$display_name" == "WebAuthn Authenticator" ]]; then
    # Keycloak 26 updates an execution requirement through the parent flow
    # endpoint; /authentication/executions/{id} is read-only apart from
    # priority/configuration sub-resources.
    "$KCADM" update "authentication/flows/browser/executions" -r hcsba \
      -s "id=$execution_id" -s requirement=ALTERNATIVE --no-merge >/dev/null
  fi
done < <("$KCADM" get authentication/flows/browser/executions -r hcsba \
  --fields id,displayName --format csv --noquotes)

echo "Keycloak realm hcsba configured."
