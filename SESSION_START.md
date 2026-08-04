# 新 Session 啟動交接

## 你現在接手的是什麼

這是「中日跨境財務轉換平台」的實作專案。前期已完成《產品研究與要件手冊 v1.2》與《基本設計書 v1.1》，並依兩份基線完成里程碑 1 的端到端原型：

`登入 → EngagementContext → TB 匯入 → 原檔與雜湊 → Worker 驗證借貸與法人歸屬 → QUARANTINED／VALIDATED → B-00 顯示`

現有 RLS、ImportBatch 七狀態、`identity_status` 正交軸、G-01、INV-28、SOD-07、不可變來源事實及稽核軌跡都是有意的產品控制，不得因重構環境或框架而弱化。

## 開始前的閱讀順序

先做只讀盤點，不要一進來就改程式：

1. `docs/GOVERNANCE.md`：文件權威順序與「證據先於文件」規則。
2. `README.md`：目前可執行方式、已完成里程碑與目錄結構。
3. `docs/baseline/產品研究與要件手冊_v1.2.md`：產品範圍、P0／P1、REQ／NFR／AC。先讀目錄、Part II～VII 與 §20A；涉及某項需求時再追讀其完整上下文。
4. `docs/baseline/基本設計書_v1.1.md` §24～§28：系統邊界與角色、狀態流程、領域資料模型、模組架構、畫面操作。若要新增里程碑 2 功能，這五節必讀；若只驗證本機環境，可先讀 §27 與相關 ADR。
5. `docs/adr/ADR-LOCAL-001.md` 與 `docs/SANDBOX.md`：只用來理解沙箱原型的來源；沙箱已不是權威環境。
6. `package.json`、`.env.example`、`docker-compose.yml`、`scripts/dev.mjs`、`scripts/env.sh`。
7. `packages/domain/src/importBatch.ts`、四份 `packages/database/migrations/*.sql`、`packages/database/src/psql.ts`、API 與 Worker。
8. 三層測試：`tests/unit/`、`tests/integration/`、`tests/acceptance/`。

CR-001／CR-002、稽核報告及歷史版本只在需要追查決策原因時閱讀，不得取代已合併的 v1.2／v1.1 正式基線。工程細節以 repo 內 Markdown 與現行程式為準，PDF 供閱讀。

## 已做出的環境決定

- 權威開發環境是使用者自己的 **macOS 本機**，日後原始碼會推送 Git。
- Node.js 22 LTS（最低 `22.18`）＋ pnpm。
- API、Worker及未來前端在 Mac Host 執行。
- PostgreSQL 16、Redis 7、MinIO 由 Docker Desktop／根目錄 `docker-compose.yml` 管理。
- 所有本機設定由 `.env.local` 注入；repo 只提供 `.env.example`。
- `PSQL_MODE=docker` 是 Mac 預設，透過 `docker exec` 使用容器內 psql；本機不必安裝 psql。`PSQL_MODE=local` 僅為可選模式。
- `.env.local`、`var/`、`infra/local/`、密鑰、資料卷、上傳檔案及 log 不得提交 Git。
- `/usr/lib/postgresql`、`su claude`、`/tmp` PostgreSQL socket 等舊沙箱假設已移出主流程。
- Node 22 原生執行 TypeScript是目前刻意保留的開發方案，不是殘留錯誤；等 Next.js／正式建置鏈導入時再集中替換。

## 目前進度與下一步

環境重構已完成兩個 commit，業務規則、資料模型及狀態機沒有被修改。`pnpm install` 與單元測試已可執行；完整 DB／端到端測試宣稱為 48/48，舊 acceptance test 的 `|| true` 假陽性已移除。由於先前執行環境沒有 Docker daemon，仍需在使用者的 Mac 實機完成最後驗證：

盤點時已知還有一個小缺口：Docker Compose 預設自動讀取的是 `.env`，不是 `.env.local`。目前 Compose 有預設值，所以不改設定時可以啟動；但只要使用者修改 `.env.local` 的 DB port／帳密，Compose 與應用就會不一致。實機驗證前須將 README 與固定指令統一為 `docker compose --env-file .env.local ...`，或提供等價的單一包裝指令；不要再維護第二份 `.env`。

```bash
cp .env.example .env.local
docker compose --env-file .env.local up -d
docker compose --env-file .env.local ps
pnpm install
pnpm db:migrate
pnpm db:seed
pnpm test
pnpm dev
```

驗證瀏覽器可開啟 `http://localhost:8080`，並確認 `docker compose --env-file .env.local restart` 後資料仍存在。若失敗，先診斷並修好 Mac 開發基線；不要同時開始里程碑 2。

Mac 基線通過後，下一個產品里程碑才是：

`科目映射 → 集團科目 TB → Adjustment 草稿 → PREVIEW CalculationRun → 證據包`

開始該里程碑前，先把要件手冊中的對應 REQ／AC 與基本設計書 §24～§28 做成一個小型實作切片及驗收清單，不再擴寫新的大型規格文件。新想法記入 `docs/BACKLOG.md`；只有符合 `docs/GOVERNANCE.md` 的四種例外才修改基線。

## 第一次回覆使用者時

請先回報：

1. 你實際讀到哪些文件與章節，並確認兩份權威基線均可讀取；
2. 你對目前完成範圍、不可弱化控制及環境決定的理解；
3. 你準備先驗證或實作的最小範圍；
4. 在使用者確認前，不做跨里程碑擴張，也不重寫既有基線。
