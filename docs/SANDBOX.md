# 雲端沙箱執行方案（非主要方式）

權威開發環境是 macOS＋Docker Compose（見 README）。本文件僅供在無 Docker daemon、
無 npm registry 的受限 Linux 沙箱中運行時參考。

| 差異 | 沙箱做法 |
|---|---|
| PostgreSQL | 原生 postgres 16：`scripts/sandbox/db-init.sh`＋`db-start.sh`（以非 root 使用者跑 initdb/pg_ctl） |
| 連線 | `.env.local` 設 `PSQL_MODE=local`、`DB_HOST=/tmp`（unix socket 目錄）、`DB_PORT=5433` |
| 套件 | 零 npm 依賴；Node ≥22.18 原生執行 TypeScript、node:test 測試 |
| 佇列／物件儲存 | Postgres SKIP LOCKED＋檔案系統（與主流程相同的抽象介面） |

其餘指令（`pnpm db:migrate`、`pnpm test` 等）與主流程相同——傳輸層會依 `PSQL_MODE` 自動切換。
歷史背景與替代對照表：`docs/adr/ADR-LOCAL-001.md`。
