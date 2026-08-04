# ADR-LOCAL-001：沙箱環境替代方案

日期：2026-08-03　狀態：ACCEPTED（僅適用雲端沙箱）

> **2026-08-03 更新**：權威開發環境已定為 macOS＋Docker Compose（README）。本 ADR 描述的替代方案降為次要執行路徑，操作方式移至 docs/SANDBOX.md。設定一律由 .env.local 注入，PSQL_MODE 切換傳輸。

## 背景
開發沙箱的 npm registry 與 PyPI 均被網路策略擋下（403），Docker 只有 CLI 無 daemon。
但 PostgreSQL 16 伺服器、redis-server、Node 22（原生 TS type stripping ＋ node:test）可用。

## 決定
| 設計書／計畫要求 | 沙箱替代 | 真機還原方式 |
|---|---|---|
| PostgreSQL（Docker） | 原生 PostgreSQL 16（port 5433，socket /tmp） | docker compose 之 db 服務 |
| pg／Drizzle 驅動 | psql 子行程轉接層（packages/database/src/psql.ts） | 換 pg 驅動，介面不變 |
| NestJS 模組化單體 | node:http ＋ 資料夾邊界對應 M1–M10 | scaffold NestJS，搬移邏輯 |
| Next.js 前端 | api 送出最小 HTML（走查骨架） | scaffold Next.js |
| BullMQ ＋ Redis 佇列 | Postgres 表 ＋ FOR UPDATE SKIP LOCKED | 換 BullMQ；冪等鍵語意不變 |
| MinIO 物件儲存 | 檔案系統目錄（ObjectStore 介面後） | 換 S3 介面實作 |
| Vitest | node:test | 換 Vitest（斷言語法相容） |

## 不變的東西
schema 與 migration、RLS 政策、DB 觸發器（G-01／INV-28／SOD-07）、狀態機語意、
測試案例——這些是資產，跨環境直接沿用。轉接層是消耗品。
