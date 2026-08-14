"""Export the isolated local OpenMRS identity contract without exposing DB credentials.

The resulting JSON contains identity metadata and must remain inside the ignored
Keycloak generated directory. It never contains OpenMRS password hashes.
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
from pathlib import Path


def mysql(container: str, sql: str) -> list[list[str]]:
    shell = (
        'MYSQL_PWD="$(cat /run/secrets/openmrs_local_db_root_password)" '
        "mysql -uroot -D openmrs --batch --raw --skip-column-names "
        "--default-character-set=utf8mb4"
    )
    completed = subprocess.run(
        ["docker", "exec", "-i", container, "sh", "-lc", shell],
        input=sql,
        text=True,
        encoding="utf-8",
        capture_output=True,
        check=False,
    )
    if completed.returncode:
        raise RuntimeError("Local OpenMRS identity query failed")
    return [line.split("\t") for line in completed.stdout.splitlines() if line]


def secure_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--container", default="bahmni-hcsba-dev-openmrs-local-db-1")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    roles = [row[0] for row in mysql(args.container, "SELECT role FROM role ORDER BY role;")]
    raw_users = mysql(
        args.container,
        """
        SELECT u.user_id, u.username, u.system_id,
               COALESCE(pn.given_name, ''), COALESCE(pn.family_name, ''),
               COALESCE(u.email, ''), u.retired,
               EXISTS(SELECT 1 FROM provider pr WHERE pr.person_id=u.person_id AND pr.retired=0)
        FROM users u
        LEFT JOIN person_name pn ON pn.person_id=u.person_id AND pn.voided=0 AND pn.preferred=1
        WHERE u.username IS NOT NULL AND TRIM(u.username) <> ''
        ORDER BY u.user_id;
        """,
    )
    roles_by_user: dict[str, list[str]] = {}
    for user_id, role in mysql(args.container, "SELECT user_id, role FROM user_role ORDER BY user_id, role;"):
        roles_by_user.setdefault(user_id, []).append(role)
    locations_by_user: dict[str, list[str]] = {}
    for user_id, location in mysql(
        args.container,
        """
        SELECT u.user_id, COALESCE(l.uuid, pa.value_reference)
        FROM users u
        JOIN provider pr ON pr.person_id=u.person_id AND pr.retired=0
        JOIN provider_attribute pa ON pa.provider_id=pr.provider_id AND pa.voided=0
        JOIN provider_attribute_type pat ON pat.provider_attribute_type_id=pa.attribute_type_id
        LEFT JOIN location l ON l.uuid=pa.value_reference
          OR l.location_id=CAST(pa.value_reference AS UNSIGNED)
        WHERE pat.name='Login Locations'
        ORDER BY u.user_id;
        """,
    ):
        locations_by_user.setdefault(user_id, []).append(location)
    global_locations = int(
        mysql(
            args.container,
            """
            SELECT COUNT(DISTINCT l.location_id)
            FROM location l
            JOIN location_tag_map ltm ON ltm.location_id=l.location_id
            JOIN location_tag lt ON lt.location_tag_id=ltm.location_tag_id
            WHERE l.retired=0 AND lt.retired=0 AND lt.name='Login Location';
            """,
        )[0][0]
    )
    users = [
        {
            "username": username,
            "system_id": system_id,
            "first_name": first_name,
            "last_name": last_name,
            "email": email,
            "enabled": retired == "0",
            "provider": provider == "1",
            "roles": roles_by_user.get(user_id, []),
            "login_locations": locations_by_user.get(user_id, []),
        }
        for user_id, username, system_id, first_name, last_name, email, retired, provider in raw_users
    ]
    secure_json(
        Path(args.output),
        {
            "roles": roles,
            "users": users,
            "login_location_policy": "global_fallback",
            "global_login_locations": global_locations,
        },
    )
    print(json.dumps({"roles": len(roles), "users": len(users), "global_login_locations": global_locations}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Local identity export failed: {type(error).__name__}: {error}", file=os.sys.stderr)
        raise SystemExit(1)
