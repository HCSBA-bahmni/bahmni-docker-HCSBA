"""Synchronize OpenMRS users, exact role names and Provider state to Keycloak.

The utility is deliberately pre-cutover: it reads OpenMRS with Basic Auth before
oauth2login disables that scheme. Secrets are read only from files and no user
identifiers or temporary passwords are written to stdout.
"""

from __future__ import annotations

import argparse
import base64
import csv
import json
import os
import secrets
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


def secret_file(path: str) -> str:
    value = Path(path).read_text(encoding="utf-8").strip()
    if not value:
        raise RuntimeError(f"Credential file is empty: {path}")
    return value


class Http:
    def __init__(self, base_url: str, headers: dict[str, str] | None = None) -> None:
        self.base_url = base_url.rstrip("/")
        self.headers = headers or {}

    def request(
        self,
        method: str,
        path: str,
        body: Any = None,
        expected: tuple[int, ...] = (200,),
        form: bool = False,
    ) -> tuple[Any, dict[str, str]]:
        headers = {"Accept": "application/json", **self.headers}
        data = None
        if body is not None:
            if form:
                data = urllib.parse.urlencode(body).encode()
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            else:
                data = json.dumps(body).encode()
                headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base_url + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                payload = response.read()
                result = json.loads(payload) if payload else None
                return result, dict(response.headers.items())
        except urllib.error.HTTPError as error:
            payload = error.read()
            if error.code not in expected:
                detail = ""
                try:
                    document = json.loads(payload) if payload else {}
                    message = document.get("errorMessage") or document.get("error")
                    if message:
                        detail = f": {message}"
                except (UnicodeDecodeError, json.JSONDecodeError):
                    pass
                raise RuntimeError(
                    f"{method} {path.split('?', 1)[0]} returned HTTP {error.code}{detail}"
                ) from error
            return None, dict(error.headers.items())


def paged_openmrs(http: Http, resource: str) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    start = 0
    page_size = 100
    while True:
        separator = "&" if "?" in resource else "?"
        page, _ = http.request("GET", f"{resource}{separator}limit={page_size}&startIndex={start}&v=full")
        rows = page.get("results", [])
        result.extend(rows)
        if len(rows) < page_size:
            break
        start += len(rows)
        if start > 100000:
            raise RuntimeError("OpenMRS pagination safety limit exceeded")
    return result


def role_name(role: dict[str, Any]) -> str:
    return str(role.get("name") or role.get("display") or "").strip()


def provider_locations(provider: dict[str, Any]) -> list[str]:
    locations: list[str] = []
    for attribute in provider.get("attributes") or []:
        kind = attribute.get("attributeType") or {}
        if (kind.get("display") or kind.get("name")) != "Login Locations":
            continue
        value = attribute.get("value")
        if isinstance(value, dict):
            value = value.get("uuid") or value.get("display") or value.get("name")
        if value:
            locations.append(str(value))
    return locations


@dataclass
class OpenmrsUser:
    username: str
    system_id: str
    first_name: str
    last_name: str
    email: str
    roles: set[str]
    provider: bool
    login_locations: list[str]
    enabled: bool


def normalize_user(user: dict[str, Any], providers: dict[str, tuple[bool, list[str]]]) -> OpenmrsUser:
    person = user.get("person") or {}
    preferred = person.get("preferredName") or {}
    person_uuid = str(person.get("uuid") or "")
    provider, locations = providers.get(person_uuid, (False, []))
    attributes = person.get("attributes") or []
    email = str(user.get("email") or "")
    if not email:
        for attribute in attributes:
            kind = attribute.get("attributeType") or {}
            if str(kind.get("display") or kind.get("name") or "").lower() in {"email", "e-mail"}:
                email = str(attribute.get("value") or "")
                break
    return OpenmrsUser(
        username=str(user.get("username") or "").strip(),
        system_id=str(user.get("systemId") or "").strip(),
        first_name=str(preferred.get("givenName") or "").strip(),
        last_name=str(preferred.get("familyName") or "").strip(),
        email=email.strip(),
        roles={name for name in (role_name(role) for role in user.get("roles") or []) if name},
        provider=provider,
        login_locations=locations,
        enabled=not bool(user.get("retired")),
    )


def load_identity_source(path: str) -> tuple[set[str], list[OpenmrsUser], str, int]:
    source = json.loads(Path(path).read_text(encoding="utf-8"))
    roles = {str(role).strip() for role in source.get("roles", []) if str(role).strip()}
    users = [
        OpenmrsUser(
            username=str(item.get("username") or "").strip(),
            system_id=str(item.get("system_id") or "").strip(),
            first_name=str(item.get("first_name") or "").strip(),
            last_name=str(item.get("last_name") or "").strip(),
            email=str(item.get("email") or "").strip(),
            roles={str(role).strip() for role in item.get("roles", []) if str(role).strip()},
            provider=bool(item.get("provider")),
            login_locations=[str(location) for location in item.get("login_locations", []) if location],
            enabled=bool(item.get("enabled")),
        )
        for item in source.get("users", [])
        if str(item.get("username") or "").strip()
    ]
    location_policy = str(source.get("login_location_policy") or "provider_attributes")
    global_locations = int(source.get("global_login_locations") or 0)
    if location_policy not in {"provider_attributes", "global_fallback"}:
        raise RuntimeError(f"Unsupported login location policy: {location_policy}")
    return roles, users, location_policy, global_locations


def keycloak_token(url: str, username: str, password: str) -> str:
    http = Http(url)
    document, _ = http.request(
        "POST",
        "/realms/master/protocol/openid-connect/token",
        {"grant_type": "password", "client_id": "admin-cli", "username": username, "password": password},
        form=True,
    )
    return str(document["access_token"])


def secure_csv(path: Path, rows: list[tuple[str, str]]) -> None:
    if not rows:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(path, flags, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["username", "temporary_password"])
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("plan", "apply", "validate"))
    parser.add_argument("--openmrs-url")
    parser.add_argument("--identity-source")
    parser.add_argument("--keycloak-url", default="http://127.0.0.1:18080")
    parser.add_argument("--realm", default="hcsba")
    parser.add_argument("--client", default="openmrs")
    parser.add_argument("--openmrs-username-file")
    parser.add_argument("--openmrs-password-file")
    parser.add_argument("--keycloak-admin", default="kc-bootstrap-admin")
    parser.add_argument("--keycloak-password-file", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    if args.identity_source:
        roles, users, location_policy, global_locations = load_identity_source(args.identity_source)
    else:
        required = {
            "--openmrs-url": args.openmrs_url,
            "--openmrs-username-file": args.openmrs_username_file,
            "--openmrs-password-file": args.openmrs_password_file,
        }
        missing = [name for name, value in required.items() if not value]
        if missing:
            parser.error("required without --identity-source: " + ", ".join(missing))
        openmrs_username = secret_file(args.openmrs_username_file)
        openmrs_password = secret_file(args.openmrs_password_file)
        basic = base64.b64encode(f"{openmrs_username}:{openmrs_password}".encode()).decode()
        openmrs = Http(args.openmrs_url.rstrip("/") + "/openmrs/ws/rest/v1", {"Authorization": f"Basic {basic}"})

        roles = {name for name in (role_name(item) for item in paged_openmrs(openmrs, "/role?includeAll=true")) if name}
        raw_providers = paged_openmrs(openmrs, "/provider?includeAll=true")
        providers: dict[str, tuple[bool, list[str]]] = {}
        for provider in raw_providers:
            person = provider.get("person") or {}
            person_uuid = str(person.get("uuid") or "")
            if person_uuid:
                providers[person_uuid] = (not bool(provider.get("retired")), provider_locations(provider))
        users = [normalize_user(item, providers) for item in paged_openmrs(openmrs, "/user?includeAll=true")]
        users = [user for user in users if user.username]
        location_policy = "provider_attributes"
        global_locations = 0

    missing_system_ids = sorted(user.username for user in users if user.enabled and not user.system_id)
    missing_locations = sorted(
        user.username
        for user in users
        if user.enabled
        and user.provider
        and not user.login_locations
        and not (location_policy == "global_fallback" and global_locations > 0)
    )
    unknown_user_roles = sorted({role for user in users for role in user.roles if role not in roles})
    if missing_system_ids or missing_locations or unknown_user_roles:
        output = Path(args.output)
        output.mkdir(parents=True, exist_ok=True)
        (output / "preflight-errors.json").write_text(
            json.dumps(
                {
                    "missing_system_id": missing_system_ids,
                    "provider_without_login_locations": missing_locations,
                    "unknown_openmrs_roles": unknown_user_roles,
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        print("Preflight failed; details were written to the protected output directory.")
        return 2

    token = keycloak_token(args.keycloak_url, args.keycloak_admin, secret_file(args.keycloak_password_file))
    keycloak = Http(
        args.keycloak_url.rstrip("/") + f"/admin/realms/{urllib.parse.quote(args.realm)}",
        {"Authorization": f"Bearer {token}"},
    )
    clients, _ = keycloak.request("GET", "/clients?clientId=" + urllib.parse.quote(args.client))
    if len(clients) != 1:
        raise RuntimeError("Expected exactly one Keycloak openmrs client")
    client_uuid = clients[0]["id"]
    existing_roles, _ = keycloak.request("GET", f"/clients/{client_uuid}/roles?max=10000")
    role_by_name = {item["name"]: item for item in existing_roles}
    missing_roles = roles - set(role_by_name)
    extra_roles = set(role_by_name) - roles

    if args.mode == "apply":
        for name in sorted(missing_roles):
            keycloak.request("POST", f"/clients/{client_uuid}/roles", {"name": name}, expected=(201,))
        for name in sorted(extra_roles):
            keycloak.request("DELETE", f"/clients/{client_uuid}/roles/{urllib.parse.quote(name, safe='')}", expected=(204,))
        refreshed, _ = keycloak.request("GET", f"/clients/{client_uuid}/roles?max=10000")
        role_by_name = {item["name"]: item for item in refreshed}

    existing_users, _ = keycloak.request("GET", "/users?briefRepresentation=false&max=10000")
    keycloak_users = {
        str(item.get("username")).casefold(): item
        for item in existing_users
        if item.get("username") and not item.get("serviceAccountClientId")
    }
    temporary_passwords: list[tuple[str, str]] = []
    mismatches = 0
    source_usernames = {user.username.casefold() for user in users}

    for user in users:
        current = keycloak_users.get(user.username.casefold())
        representation = {
            "username": user.username,
            "firstName": user.first_name,
            "lastName": user.last_name,
            "enabled": user.enabled,
            "emailVerified": False,
            "attributes": {
                "openmrs_system_id": [user.system_id],
                "openmrs_provider": ["true" if user.provider else "false"],
            },
            "requiredActions": ["UPDATE_PASSWORD", "CONFIGURE_TOTP", "CONFIGURE_RECOVERY_AUTHN_CODES"],
        }
        if user.email:
            representation["email"] = user.email
        created = False
        if current is None:
            mismatches += 1
            if args.mode == "apply":
                _, headers = keycloak.request("POST", "/users", representation, expected=(201,))
                user_id = headers["Location"].rstrip("/").rsplit("/", 1)[-1]
                password = secrets.token_urlsafe(18)
                keycloak.request(
                    "PUT",
                    f"/users/{user_id}/reset-password",
                    {"type": "password", "value": password, "temporary": True},
                    expected=(204,),
                )
                temporary_passwords.append((user.username, password))
                created = True
            else:
                continue
        else:
            user_id = current["id"]
            attributes = current.get("attributes") or {}
            expected_attributes = representation["attributes"]
            if (
                bool(current.get("enabled")) != user.enabled
                or attributes.get("openmrs_system_id") != expected_attributes["openmrs_system_id"]
                or attributes.get("openmrs_provider") != expected_attributes["openmrs_provider"]
            ):
                mismatches += 1
            if args.mode == "apply":
                # Existing users keep credentials and completed required actions.
                representation.pop("requiredActions")
                keycloak.request("PUT", f"/users/{user_id}", representation, expected=(204,))

        if args.mode == "apply" or not created:
            assigned, _ = keycloak.request("GET", f"/users/{user_id}/role-mappings/clients/{client_uuid}")
            assigned_names = {item["name"] for item in assigned}
            if assigned_names != user.roles:
                mismatches += 1
            if args.mode == "apply":
                add = [role_by_name[name] for name in sorted(user.roles - assigned_names)]
                remove = [role_by_name[name] for name in sorted(assigned_names - user.roles) if name in role_by_name]
                if add:
                    keycloak.request("POST", f"/users/{user_id}/role-mappings/clients/{client_uuid}", add, expected=(204,))
                if remove:
                    keycloak.request("DELETE", f"/users/{user_id}/role-mappings/clients/{client_uuid}", remove, expected=(204,))

    extra_users = [item for name, item in keycloak_users.items() if name not in source_usernames]
    if extra_users:
        mismatches += len(extra_users)
        if args.mode == "apply":
            for item in extra_users:
                item["enabled"] = False
                keycloak.request("PUT", f"/users/{item['id']}", item, expected=(204,))

    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    secure_csv(output / "initial-passwords.csv", temporary_passwords)
    report = {
        "mode": args.mode,
        "openmrs_roles": len(roles),
        "active_users": sum(1 for user in users if user.enabled),
        "retired_users": sum(1 for user in users if not user.enabled),
        "providers": sum(1 for user in users if user.enabled and user.provider),
        "login_location_policy": location_policy,
        "global_login_locations": global_locations,
        "created_users": len(temporary_passwords),
        "mismatches_before_apply": mismatches + len(missing_roles) + len(extra_roles),
    }
    (output / "sync-report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report))
    if args.mode == "validate" and report["mismatches_before_apply"]:
        return 3
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Synchronization failed: {type(error).__name__}: {error}", file=sys.stderr)
        raise SystemExit(1)
