#!/usr/bin/env bash
# 載入 .env.local（若存在）並補預設值。被其他腳本 source。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$REPO_ROOT/.env.local" ]; then set -a; . "$REPO_ROOT/.env.local"; set +a; fi
export PSQL_MODE="${PSQL_MODE:-docker}"
export DB_CONTAINER="${DB_CONTAINER:-cbfc-db}"
export DB_HOST="${DB_HOST:-127.0.0.1}"
export DB_PORT="${DB_PORT:-5433}"
export DB_USER="${DB_USER:-dev}"
export DB_PASSWORD="${DB_PASSWORD:-dev}"
export DB_NAME="${DB_NAME:-cbfc_dev}"

# psql_run [額外 psql 參數…]；SQL 一律由 stdin 餵入（docker 模式下檔案不在容器內）
psql_run() {
  if [ "$PSQL_MODE" = "docker" ]; then
    docker exec -i "$DB_CONTAINER" psql -v ON_ERROR_STOP=1 -qtA -U "$DB_USER" "$@"
  else
    PGPASSWORD="$DB_PASSWORD" psql -v ON_ERROR_STOP=1 -qtA \
      -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$@"
  fi
}
