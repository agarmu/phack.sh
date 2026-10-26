#!/usr/bin/env bash
set -euo pipefail
# TCP is unavailable during the entrypoint's temporary initialization server.
check_database() {
  PGPASSWORD="$(cat "$2")" PGCONNECT_TIMEOUT=3 \
    psql --host 127.0.0.1 --username "$1" --dbname "$1" --no-password \
    --no-psqlrc --quiet --tuples-only --command 'SELECT 1' >/dev/null
}
password_dir=${CMS_POSTGRES_PASSWORD_DIR:-/run}
check_database cms "$password_dir/cms-postgres-password"
check_database cms_demo "$password_dir/cms-demo-postgres-password"
