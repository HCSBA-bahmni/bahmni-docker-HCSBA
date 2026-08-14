"""Recover credentials for a locally interrupted initial identity import.

Only enabled human users that still have UPDATE_PASSWORD pending and are absent
from the protected initial-password CSV are reset. Identifiers and credentials
are never printed.
"""

from __future__ import annotations

import argparse
import csv
import os
import secrets
import stat
import tempfile
import urllib.parse
from pathlib import Path

from sync_openmrs_users import Http, keycloak_token, secret_file


def read_rows(path: Path) -> list[tuple[str, str]]:
    if not path.exists():
        return []
    with path.open(encoding="utf-8", newline="") as stream:
        return [
            (str(row.get("username") or ""), str(row.get("temporary_password") or ""))
            for row in csv.DictReader(stream)
            if row.get("username") and row.get("temporary_password")
        ]


def atomic_secure_csv(path: Path, rows: list[tuple[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix="initial-passwords-", suffix=".csv", dir=path.parent)
    try:
        os.chmod(temporary, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(["username", "temporary_password"])
            writer.writerows(rows)
        os.replace(temporary, path)
    except Exception:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keycloak-url", required=True)
    parser.add_argument("--realm", default="hcsba")
    parser.add_argument("--keycloak-admin", required=True)
    parser.add_argument("--keycloak-password-file", required=True)
    parser.add_argument("--password-csv", required=True)
    args = parser.parse_args()

    token = keycloak_token(
        args.keycloak_url,
        args.keycloak_admin,
        secret_file(args.keycloak_password_file),
    )
    keycloak = Http(
        args.keycloak_url.rstrip("/") + f"/admin/realms/{urllib.parse.quote(args.realm)}",
        {"Authorization": f"Bearer {token}"},
    )
    path = Path(args.password_csv)
    rows = read_rows(path)
    recorded = {username.casefold() for username, _ in rows}
    users, _ = keycloak.request("GET", "/users?briefRepresentation=false&max=10000")
    candidates = [
        user
        for user in users
        if user.get("enabled")
        and not user.get("serviceAccountClientId")
        and str(user.get("username") or "").casefold() not in recorded
        and "UPDATE_PASSWORD" in (user.get("requiredActions") or [])
    ]
    recovered: list[tuple[str, str]] = []
    for user in candidates:
        password = secrets.token_urlsafe(18)
        keycloak.request(
            "PUT",
            f"/users/{user['id']}/reset-password",
            {"type": "password", "value": password, "temporary": True},
            expected=(204,),
        )
        recovered.append((str(user["username"]), password))
    if recovered:
        atomic_secure_csv(path, rows + recovered)
    print(f"Recovered initial credentials: {len(recovered)}; protected credentials: {len(rows) + len(recovered)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
