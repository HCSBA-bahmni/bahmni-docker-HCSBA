#!/bin/bash
set -euo pipefail

export MYSQL_PWD="$(</run/secrets/openmrs_local_db_root_password)"

case "${1:-}" in
  import)
    dump_name="${2:-}"
    if [[ ! "$dump_name" =~ ^openmrs-[0-9]{8}-[0-9]{6}\.sql\.gz$ ]] || [[ ! -f "/snapshot/$dump_name" ]]; then
      echo "Invalid or missing snapshot name: $dump_name" >&2
      exit 64
    fi
    mysql -uroot <<SQL
DROP DATABASE IF EXISTS \`${MYSQL_DATABASE}\`;
CREATE DATABASE \`${MYSQL_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO \`${MYSQL_USER}\`@'%';
FLUSH PRIVILEGES;
SQL
    gzip -dc "/snapshot/$dump_name" | mysql -uroot "$MYSQL_DATABASE"
    mysql -uroot "$MYSQL_DATABASE" < /opt/hcsba/isolate-clone.sql
    ;;
  backup)
    backup_name="${2:-}"
    if [[ ! "$backup_name" =~ ^local-before-replace-[0-9]{8}-[0-9]{6}\.sql\.gz$ ]]; then
      echo "Invalid local backup name: $backup_name" >&2
      exit 64
    fi
    mysqldump --single-transaction --quick --routines --triggers --events --hex-blob \
      --set-gtid-purged=OFF --no-tablespaces --column-statistics=0 \
      -uroot "$MYSQL_DATABASE" | gzip -1 > "/snapshot/$backup_name"
    ;;
  check-isolation)
    mysql -N -uroot "$MYSQL_DATABASE" <<'SQL'
SELECT COUNT(*) FROM scheduler_task_config WHERE start_on_startup <> 0 OR started <> 0;
SELECT COUNT(*) FROM global_property WHERE property LIKE 'atomfeed.publish.%' AND LOWER(property_value) = 'true';
SQL
    ;;
  metadata-counts)
    mysql -N -uroot "$MYSQL_DATABASE" <<'SQL'
SELECT 'users', COUNT(*) FROM users WHERE retired = 0
UNION ALL SELECT 'roles', COUNT(*) FROM role
UNION ALL SELECT 'concepts', COUNT(*) FROM concept WHERE retired = 0
UNION ALL SELECT 'providers', COUNT(*) FROM provider WHERE retired = 0
UNION ALL SELECT 'locations', COUNT(*) FROM location WHERE retired = 0;
SQL
    ;;
  *)
    echo "Usage: $0 import <snapshot>|backup <file>|check-isolation|metadata-counts" >&2
    exit 64
    ;;
esac
