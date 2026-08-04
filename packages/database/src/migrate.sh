#!/usr/bin/env bash
# 依序套用 migrations/*.sql；每份包在交易內；記錄於 schema_migrations。
set -euo pipefail
. "$(cd "$(dirname "$0")/../../../scripts" && pwd)/env.sh"
DB="${1:-$DB_NAME}"
DIR="$(cd "$(dirname "$0")/../migrations" && pwd)"
psql_run -d "$DB" <<<"CREATE TABLE IF NOT EXISTS schema_migrations (filename text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"
for f in "$DIR"/*.sql; do
  name="$(basename "$f")"
  done_already=$(psql_run -d "$DB" <<<"SELECT 1 FROM schema_migrations WHERE filename='$name'")
  if [ "$done_already" = "1" ]; then continue; fi
  { cat "$f"; echo "; INSERT INTO schema_migrations(filename) VALUES ('$name');"; } | psql_run -d "$DB" -1 -f -
  echo "APPLIED  $name"
done
echo "migration 完成（${DB}）"
