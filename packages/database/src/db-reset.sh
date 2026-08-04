#!/usr/bin/env bash
# 從零重建資料庫並套用全部 migration。
set -euo pipefail
. "$(cd "$(dirname "$0")/../../../scripts" && pwd)/env.sh"
DB="${1:-$DB_NAME}"
psql_run -d postgres <<<"DROP DATABASE IF EXISTS $DB"
psql_run -d postgres <<<"CREATE DATABASE $DB"
bash "$(dirname "$0")/migrate.sh" "$DB"
