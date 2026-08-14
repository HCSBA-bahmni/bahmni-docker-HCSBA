"""Fail-closed verification of the HCSBA realm after import/configuration."""

from __future__ import annotations

import argparse
import base64
import json
import sys
import time
from pathlib import Path

from sync_openmrs_users import Http, keycloak_token, secret_file


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def jwt_payload(token: str) -> dict:
    parts = token.split(".")
    require(len(parts) == 3, "Client Credentials did not return a JWT")
    encoded = parts[1] + "=" * (-len(parts[1]) % 4)
    return json.loads(base64.urlsafe_b64decode(encoded))


def verify_client_credentials(base_url: str, client_id: str, secret_path: Path) -> None:
    response, _ = Http(base_url).request(
        "POST",
        "/realms/hcsba/protocol/openid-connect/token",
        {
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": secret_file(str(secret_path)),
        },
        form=True,
    )
    payload = jwt_payload(response.get("access_token", ""))
    audience = payload.get("aud", [])
    if isinstance(audience, str):
        audience = [audience]
    require(payload.get("azp") == client_id, f"{client_id} token has an invalid authorized party")
    require("openmrs" in audience, f"{client_id} token lacks the OpenMRS audience")
    require(payload.get("typ") in {"Bearer", "at+jwt"}, f"{client_id} token has an invalid type")
    require(int(payload.get("exp", 0)) > int(time.time()), f"{client_id} token is expired")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keycloak-url", required=True)
    parser.add_argument("--expected-issuer", required=True)
    parser.add_argument("--expected-backchannel-logout-url", required=True)
    parser.add_argument("--keycloak-admin", required=True)
    parser.add_argument("--keycloak-password-file", required=True)
    parser.add_argument("--secrets-directory", required=True)
    args = parser.parse_args()

    public = Http(args.keycloak_url)
    discovery, _ = public.request("GET", "/realms/hcsba/.well-known/openid-configuration")
    require(discovery.get("issuer") == args.expected_issuer, "OIDC issuer does not match the public hostname")

    token = keycloak_token(args.keycloak_url, args.keycloak_admin, secret_file(args.keycloak_password_file))
    admin = Http(args.keycloak_url + "/admin/realms/hcsba", {"Authorization": f"Bearer {token}"})
    realm, _ = admin.request("GET", "")
    require(realm.get("registrationAllowed") is False, "Self-registration must be disabled")
    require(realm.get("bruteForceProtected") is True, "Brute-force protection must be enabled")
    require(realm.get("otpPolicyCodeReusable") is False, "OTP reuse must be disabled")
    require(realm.get("loginTheme") == "hcsba", "The HCSBA login theme is not active")

    clients, _ = admin.request("GET", "/clients?max=1000")
    by_id = {client["clientId"]: client for client in clients}
    expected_technical = {"openelis", "odoo-connect", "odoo10-connect", "reports", "sms-service"}
    require("openmrs" in by_id, "Human OpenMRS client is missing")
    require(expected_technical.issubset(by_id), "One or more technical clients are missing")
    require(by_id["openmrs"].get("standardFlowEnabled") is True, "Authorization Code Flow is disabled")
    for client_id in expected_technical:
        require(by_id[client_id].get("serviceAccountsEnabled") is True, f"{client_id} lacks Client Credentials")
        require(by_id[client_id].get("standardFlowEnabled") is False, f"{client_id} permits human login")

    secret_files = {
        "openelis": "openelis-client-secret",
        "odoo-connect": "odoo-connect-client-secret",
        "odoo10-connect": "odoo10-connect-client-secret",
        "reports": "reports-client-secret",
        "sms-service": "sms-service-client-secret",
    }
    secret_directory = Path(args.secrets_directory)
    for client_id, filename in secret_files.items():
        verify_client_credentials(args.keycloak_url, client_id, secret_directory / filename)

    openmrs_uuid = by_id["openmrs"]["id"]
    openmrs_client, _ = admin.request("GET", f"/clients/{openmrs_uuid}")
    require(openmrs_client.get("frontchannelLogout") is False, "OpenMRS front-channel logout must be disabled")
    openmrs_attributes = openmrs_client.get("attributes", {})
    require(
        openmrs_attributes.get("backchannel.logout.url") == args.expected_backchannel_logout_url,
        "OpenMRS back-channel logout URL does not match the deployment",
    )
    require(
        openmrs_attributes.get("backchannel.logout.session.required") == "true",
        "OpenMRS back-channel logout must include the client session id",
    )
    mappers, _ = admin.request("GET", f"/clients/{openmrs_uuid}/protocol-mappers/models")
    claims = {mapper.get("config", {}).get("claim.name") for mapper in mappers}
    require({"openmrs_roles", "openmrs_provider", "openmrs_system_id"}.issubset(claims), "OpenMRS claims are incomplete")

    required_actions, _ = admin.request("GET", "/authentication/required-actions")
    configure_otp = next(action for action in required_actions if action.get("alias") == "CONFIGURE_TOTP")
    require(configure_otp.get("enabled") is True and configure_otp.get("defaultAction") is True, "TOTP is not mandatory")
    require(configure_otp.get("config", {}).get("add-recovery-codes") == "true", "Recovery codes are not generated with TOTP")

    executions, _ = admin.request("GET", "/authentication/flows/browser/executions")
    recovery = next(item for item in executions if item.get("displayName") == "Recovery Authentication Code Form")
    require(recovery.get("requirement") == "ALTERNATIVE", "Recovery codes are not enabled as an OTP alternative")
    print(json.dumps({"realm": "hcsba", "issuer": args.expected_issuer, "status": "verified"}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Keycloak verification failed: {type(error).__name__}: {error}", file=sys.stderr)
        raise SystemExit(1)
