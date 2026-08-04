#!/usr/bin/env bash
# 初始化本機 PostgreSQL 16 叢集（沙箱無 Docker daemon，直接跑原生 server）。
set -euo pipefail
PGBIN=/usr/lib/postgresql/16/bin
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PGDATA="$ROOT/infra/local/pgdata"
if [ -d "$PGDATA" ]; then echo "已存在：$PGDATA"; exit 0; fi
mkdir -p "$PGDATA" && chown -R claude:claude "$ROOT/infra/local"
su claude -s /bin/bash -c "$PGBIN/initdb -D '$PGDATA' -U dev --auth=trust -E UTF8 --locale=C.UTF-8" >/dev/null
cat >> "$PGDATA/postgresql.conf" <<CONF
listen_addresses = '127.0.0.1'
port = 5433
unix_socket_directories = '/tmp'
CONF
echo "initdb 完成：$PGDATA"
