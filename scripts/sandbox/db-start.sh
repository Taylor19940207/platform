#!/usr/bin/env bash
set -euo pipefail
PGBIN=/usr/lib/postgresql/16/bin
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PGDATA="$ROOT/infra/local/pgdata"
if su claude -s /bin/bash -c "$PGBIN/pg_ctl -D '$PGDATA' status" >/dev/null 2>&1; then
  echo "PostgreSQL 已在運行"; exit 0
fi
su claude -s /bin/bash -c "$PGBIN/pg_ctl -D '$PGDATA' -l '$ROOT/infra/local/pg.log' start" >/dev/null
echo "PostgreSQL 啟動（127.0.0.1:5433，socket /tmp）"
