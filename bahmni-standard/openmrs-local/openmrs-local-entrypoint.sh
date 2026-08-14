#!/bin/bash
set -euo pipefail

state_file=/opt/hcsba/state/imported.json
if [[ ! -s "$state_file" ]]; then
  echo "Refusing to start OpenMRS: no imported local snapshot marker at $state_file" >&2
  exit 42
fi

export OMRS_DB_PASSWORD="$(</run/secrets/openmrs_local_db_password)"
export OPENMRS_OIDC_CLIENT_SECRET="$(</run/secrets/openmrs_oidc_client_secret)"

if [[ -z "$OMRS_DB_PASSWORD" || -z "$OPENMRS_OIDC_CLIENT_SECRET" ]]; then
  echo "Refusing to start OpenMRS: a required local secret is empty" >&2
  exit 43
fi

# The database snapshot already contains the promoted HCSBA metadata. Replaying Initializer/OCL
# imports would both alter parity and make the first local boot needlessly expensive. This path is
# generated from the read-only configuration mount and is safe to clear only after the local
# snapshot marker above has proven that this is the isolated container.
rm -rf /openmrs/data/configuration
mkdir -p /openmrs/data/configuration

# The upstream image follows the redirect returned by GET / during its bootstrap probe.
# With oauth2login enabled that redirect targets the public Keycloak hostname, which is not
# reachable until the reverse proxy itself is allowed to start. Accepting the local 302 avoids
# that circular dependency while retaining the same bootstrap trigger.
sed -i 's/curl -sL /curl -s /' /openmrs/startup.sh

exec ./bahmni_startup.sh
