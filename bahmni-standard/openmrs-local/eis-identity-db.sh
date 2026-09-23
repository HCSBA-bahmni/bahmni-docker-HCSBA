#!/bin/bash
set -euo pipefail

export MYSQL_PWD="$(</run/secrets/openmrs_local_db_root_password)"

verify_schema() {
  local result
  result="$(mysql -N -B -uroot <<'SQL'
SELECT
  (SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='eis_identity') = 1
  AND (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='eis_identity' AND TABLE_NAME='patient_identifier_metadata') = 1
  AND (SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='eis_identity' AND TABLE_NAME='patient_identifier_metadata' AND COLUMN_NAME='patient_identifier_uuid')
      = (SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='openmrs' AND TABLE_NAME='patient_identifier' AND COLUMN_NAME='uuid')
  AND (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='eis_identity' AND TABLE_NAME='patient_identifier_metadata') = 14
  AND (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='eis_identity' AND TABLE_NAME='patient_identifier_metadata' AND INDEX_NAME='uq_eis_metadata_identifier') >= 1;
SQL
)"
  if [[ "$result" != "1" ]]; then
    echo "EIS Identity schema verification failed." >&2
    exit 1
  fi
}

case "${1:-}" in
  migrate)
    MYSQL_HOST=127.0.0.1 \
      MYSQL_ADMIN_USER=root \
      MYSQL_PASSWORD_FILE=/run/secrets/openmrs_local_db_root_password \
      OPENMRS_DATABASE="${MYSQL_DATABASE}" \
      EIS_IDENTITY_GRANTEE="${MYSQL_USER}" \
      bash /opt/hcsba/eis-identity-db-source/apply.sh
    verify_schema
    ;;
  verify)
    verify_schema
    ;;
  *)
    echo "Usage: $0 migrate|verify" >&2
    exit 64
    ;;
esac
