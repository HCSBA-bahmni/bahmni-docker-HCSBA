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

# Stage only the versioned EIS registration delta on every isolated-local start.
# The snapshot already contains the broader clinical configuration; replaying all
# of it can collide with historical concepts. Initializer keeps persistent
# checksums and applies only new or changed EIS files without touching .205.
rm -rf /openmrs/data/configuration
mkdir -p \
  /openmrs/data/configuration/addresshierarchy \
  /openmrs/data/configuration/concepts \
  /openmrs/data/configuration/conceptsources \
  /openmrs/data/configuration/globalproperties \
  /openmrs/data/configuration/idgen \
  /openmrs/data/configuration/liquibase \
  /openmrs/data/configuration/personattributetypes \
  /openmrs/data/configuration/relationshiptypes

configuration_source=/opt/hcsba/current-configuration
cp "$configuration_source/addresshierarchy/addressConfiguration.xml" /openmrs/data/configuration/addresshierarchy/
cp "$configuration_source/addresshierarchy/addresshierarchy.csv" /openmrs/data/configuration/addresshierarchy/
cp "$configuration_source/concepts/eisContact.csv" /openmrs/data/configuration/concepts/
cp "$configuration_source/concepts/eisDemographics.csv" /openmrs/data/configuration/concepts/
cp "$configuration_source/concepts/eisHealthInsurers.csv" /openmrs/data/configuration/concepts/
cp "$configuration_source/conceptsources/sources.csv" /openmrs/data/configuration/conceptsources/
cp "$configuration_source/globalproperties/gp_eis_registration.xml" /openmrs/data/configuration/globalproperties/
cp "$configuration_source/idgen/identifierSource.csv" /openmrs/data/configuration/idgen/
cp "$configuration_source/liquibase/eis_patient_identifiers.xml" /openmrs/data/configuration/liquibase/
cp "$configuration_source/liquibase/eis_registration_contact_order.xml" /openmrs/data/configuration/liquibase/
cp /opt/hcsba/eis-liquibase.xml /openmrs/data/configuration/liquibase/liquibase.xml
cp "$configuration_source/personattributetypes/personAttributeTypes.csv" /openmrs/data/configuration/personattributetypes/
cp "$configuration_source/relationshiptypes/relationshiptypes.csv" /openmrs/data/configuration/relationshiptypes/

# The upstream image follows the redirect returned by GET / during its bootstrap probe.
# With oauth2login enabled that redirect targets the public Keycloak hostname, which is not
# reachable until the reverse proxy itself is allowed to start. Accepting the local 302 avoids
# that circular dependency while retaining the same bootstrap trigger.
sed -i 's/curl -sL /curl -s /' /openmrs/startup.sh

exec ./bahmni_startup.sh
