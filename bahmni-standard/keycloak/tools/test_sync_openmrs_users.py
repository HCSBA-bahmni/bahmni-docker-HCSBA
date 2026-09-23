import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("sync_openmrs_users.py")
SPEC = importlib.util.spec_from_file_location("sync_openmrs_users", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class NormalizationTest(unittest.TestCase):
    def test_preserves_exact_roles_provider_and_login_locations(self):
        provider = {
            "attributes": [{
                "attributeType": {"display": "Login Locations"},
                "value": {"uuid": "location-uuid", "display": "Ward"},
            }]
        }
        locations = MODULE.provider_locations(provider)
        user = MODULE.normalize_user(
            {
                "username": "clinician",
                "systemId": "system-id",
                "retired": False,
                "person": {
                    "uuid": "person-uuid",
                    "preferredName": {"givenName": "Ana", "familyName": "Perez"},
                },
                "roles": [{"name": "Nurse"}, {"display": "Bahmni User"}],
            },
            {"person-uuid": (True, locations)},
        )

        self.assertEqual({"Nurse", "Bahmni User"}, user.roles)
        self.assertTrue(user.provider)
        self.assertEqual(["location-uuid"], user.login_locations)
        self.assertEqual("system-id", user.system_id)

    def test_local_source_preserves_global_login_location_fallback(self):
        source = {
            "roles": ["Provider"],
            "login_location_policy": "global_fallback",
            "global_login_locations": 7,
            "users": [{
                "username": "clinician",
                "system_id": "clinician",
                "first_name": "Ana",
                "last_name": "Perez",
                "roles": ["Provider"],
                "provider": True,
                "login_locations": [],
                "enabled": True,
            }],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "identities.json"
            path.write_text(json.dumps(source), encoding="utf-8")
            roles, users, policy, locations = MODULE.load_identity_source(str(path))

        self.assertEqual({"Provider"}, roles)
        self.assertEqual("global_fallback", policy)
        self.assertEqual(7, locations)
        self.assertEqual("clinician", users[0].username)

    def test_keycloak_username_matching_is_case_insensitive(self):
        source_name = "Lab Manager"
        keycloak_users = {"lab manager".casefold(): {"username": "lab manager"}}
        self.assertIsNotNone(keycloak_users.get(source_name.casefold()))


if __name__ == "__main__":
    unittest.main()
