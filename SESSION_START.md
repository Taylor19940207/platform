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
7. `packages/domain/src/importBatch.ts`、十八份 `packages/database/migrations/*.sql`、`packages/database/src/psql.ts`、API 與 Worker。
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

macOS 已正式成為權威開發環境；Docker、migration、seed、持久性、API、Worker 與瀏覽器均已實機驗證。macOS bash 3.2 的 `${DB}` 相容修正已提交。

里程碑 1、`SLICE-M2-01` 科目映射切片與 `SLICE-M2-02A` 調整生命週期切片均已完成。
現有 19 份 migration；完整實跑結果為 **487/487**（單元 50、DB 整合 204、端到端 233）。

**跑 `pnpm test` 前必須先停掉 `pnpm dev`**——端到端測試會自己 spawn API（8091～8098）
與 worker，8080 的 dev worker 會搶同一批 `UPLOADED` 批次造成偽失敗；測試會重建 `cbfc_dev`，
跑完以 `pnpm db:seed` 還原。

2026-08-04 已另做實際瀏覽器走查：甲上傳與接受、G-02 未映射阻擋、甲建立草稿、乙批准、覆蓋率 100%、G-02 通過、PREVIEW 非正式輸出與控制總額勾稽均正常；2026-03／04 預覽也確認按報告期解析生效版本。

完整對話、證據、走查資料與接續注意事項見：

- `docs/handoffs/SESSION_HANDOFF_2026-08-04.md`（里程碑 1 ＋ 映射切片）
- `docs/handoffs/SESSION_HANDOFF_2026-08-04_SLICE-M2-02A.md`（調整生命週期 ＋ 覆核回饋硬化）
- `docs/handoffs/SESSION_HANDOFF_2026-08-04_SLICE-M2-03.md`（背景工作可靠性）
- `docs/handoffs/SESSION_HANDOFF_2026-08-05_MILESTONE-2-EXIT-REVIEW.md`（最新接續入口：
  里程碑 2 阻擋盤點、三項待修正判定、SLICE-M2-04 邊界）

跨 session、尚未形成決策的產品議題統一記入 `docs/FUTURE_DISCUSSIONS.md`；目前 DISC-001
追蹤「控制強度與事務所實用性的平衡」。它不改變正式基線或目前計畫；形成可執行決策後，
再依 `docs/GOVERNANCE.md` 落入切片、ADR 或 `docs/BACKLOG.md`。

`SLICE-M2-03 背景工作可靠性`已完成並**正式關閉**：`BackgroundJob` 提供租約、`claim_token`
fencing、心跳、安全重領、冪等鍵與錯誤四分類；`VALIDATING` 已成為交易內狀態，批次不可能
永久卡住（`docs/adr/ADR-M2-002.md`）。2026-08-05 逐行審查的四項缺口已修正並各有邊界測試
（失敗寫回 fencing、fence 列鎖、`RUNNING→RUNNING` 重領守衛、冪等鍵原始碼去 NUL——
migration 0011 與 handoff 關閉章節）。

`SLICE-M2-02B PREVIEW CalculationRun ＋ 輸入凍結`已完成（2026-08-05）：切片文件經走查
六點修訂定稿後實作——同一交易內「解析集合 → 對同一集合驗 G-02 → Manifest ＋ Run ＋
Job ＋ 事件」（無 TOCTOU）；重演＝新 run 帶 `replay_of_run_id` 引用同一份 Manifest，
失敗（`REPLAY_FAILED`）屬 replay run，原 run 永不修改；`frozen_set_content_hash` 與
`result_content_hash` 均排除 run_id／時間戳；輸出為 `BalanceSnapshotLine`（SOURCE_TB／
ADJUSTMENT 兩層，`NO_FX` 未折算）＋ B-06 骨架；Case-001 調整後集團 TB 逐科目 12/12。
詳 `docs/slices/SLICE-M2-02B_PREVIEW_CalculationRun與輸入凍結.md` 與
`docs/handoffs/SESSION_HANDOFF_2026-08-05_SLICE-M2-02B.md`。

`SLICE-M2-02C 預覽證據包`已完成（2026-08-05；前置的 `mapping_rule` 事件原子化同日完成）：
切片文件經兩輪走查（非同步產包、artifact 保存與下載驗 hash、重產契約、audit cutoff、
逐科目範圍追溯、實作契約 A～D）後實作——非同步產包（GENERATING→READY／FAILED）、
HTML artifact 一次生成保存（staging 安全重試）、`package_content_hash` 與 `artifact_sha256`
皆確定性（同 run＋同 cutoff＋同 render 重產完全一致）、Case-001 追溯判定 12/12 科目範圍
明示 BALANCE、契約 D 上游驗證（損壞不包裝）、來源三表補不可變。
詳 `docs/slices/SLICE-M2-02C_預覽證據包.md` 與
`docs/handoffs/SESSION_HANDOFF_2026-08-05_SLICE-M2-02C.md`。

**里程碑 2 的 02 系列（映射→調整→計算→證據包）至此收官。**里程碑 2 離開條件盤點
已完成（`docs/reviews/MILESTONE-2_EXIT_REVIEW.md`，提交 `6ab32d3`），目前尚不能宣告離開。
下一刀定為 `SLICE-M2-04_B00待辦與身分確認`；動工前先依最新 handoff 修正盤點文件的三項
判定，再寫一頁切片與驗收清單。不重開 02 系列、不擴寫大型規格、不修改兩份正式基線。

## 第一次回覆使用者時

請先回報：

1. 你實際讀到哪些文件與章節，並確認兩份權威基線均可讀取；
2. 你對目前完成範圍、不可弱化控制及環境決定的理解；
3. 你準備先驗證或實作的最小範圍；
4. 在使用者確認前，不做跨里程碑擴張，也不重寫既有基線。
