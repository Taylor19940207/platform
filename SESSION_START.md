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
7. `packages/domain/src/importBatch.ts`、二十四份 `packages/database/migrations/*.sql`、`packages/database/src/psql.ts`。
8. **API 已模組化**：`apps/api/src/server.ts` 只剩 54 行（health、開發登入、Session 建構、
   dispatcher、listen）。業務路由在 `apps/api/src/modules/<domain>/`，經
   `apps/api/src/http/dispatch.ts` 分派；`http/{context,respond}.ts` 是 HTTP 邊界。
   讀 API 請從 `http/dispatch.ts` 的路由表起手，不要從 server.ts 找功能。
9. 三層測試：`tests/unit/`、`tests/integration/`、`tests/acceptance/`。

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

里程碑 1 與里程碑 2 的 `SLICE-M2-01`／`02A`／`03`／`02B`／`02C`／`M2-04`／`M2-05`／`M2-06`
均已完成並關閉。
現有 24 份 migration；完整實跑結果為 **764/764**（單元 58、DB 整合 357、端到端 349），
最新一輪全綠（HEAD `2e19c9b`，已 push）。

`SLICE-M2-04` 的關閉收口為 **0021**：映射來源批次必須為 `ACCEPTED`——未經接受的批次
（含 QUARANTINED）不得成為正式映射的來源脈絡。DB 以 `FOR UPDATE` 鎖住來源批次列消除
TOCTOU；應用層 `/b04/map` 先判定並回 409 ＋ `SOURCE_BATCH_NOT_ACCEPTED`，DB 仍是最後防線。
既有映射不因來源批次日後轉 `SUPERSEDED` 而被追溯刪除或改寫。

## API 模組化拆層已完成（2026-08-08～10）

`server.ts` 由 2,018 行降為 **54 行**。這不是為了行數——是為了讓「授權在哪裡判斷」
變成看得見的事。舊結構有一個萬用守衛（`b04Guard`）同時替映射、調整、計算與證據包
授權，且用「案件層 ∪ 租戶層」的聯集；六類既有授權缺口就藏在那裡面。

    apps/api/src/
    ├── server.ts        health、開發登入、Session 建構、dispatcher、listen
    ├── http/            context（已驗證身分的請求脈絡）／respond／dispatch（路由表）
    └── modules/<domain>/  access（事實讀取）・guard（逐動作授權）
                           service（交易編排）・views／routes（HTTP 與 HTML）

**分層契約**（每個模組一致）：
route 讀表單、從 Session 取身分、呼叫 guard 與 service、轉成 HTTP；
service 不 import `node:http` 型別也不產生 HTML，未知 DB 錯誤原樣上拋不偽裝成 409；
**DB 守衛不搬進 TypeScript**，仍是最後防線。不加 Repository 層——現有 SQL 與 DB
守衛是控制的本體，多包一層泛型只會隱藏交易邊界。

**授權原則（不可退讓）**：一律**案件層逐動作**判斷。
`engagementRolesOf()` 只查 `engagement_id = :e`；`tenantRolesOf()` 只查 `IS NULL`；
兩者**不得聯集**——§26.3 明定 R1～R5、R7 屬 EngagementAssignment，Tenant 內每個
Engagement 必須明示授權，租戶層角色不得隱式取得客戶資料。
拒絕時 CVA 分開記錄 `engagement_roles` 與 `tenant_roles`，稽核軌跡才答得出
「缺的是角色種類還是授權範圍」。

**拆層期間封閉的六類既有授權缺口**（皆非拆層造成，皆有反證過的負面測試）：

| # | 缺口 | 修補 |
|---|---|---|
| 1 | R1／R6 可讀 Adjustment（只判 `roles.size > 0`） | §24.6 白名單 `ADJUSTMENT_READERS` |
| 2 | 租戶層 R2／R3／R4 可跨案件讀寫 | `engagementRolesOf` 拆出，聯集函式刪除 |
| 3 | `/b04/submit` **完全沒有角色檢查** | 逐動作白名單（`imports/guard.ts` 的 `B04`） |
| 4 | B-06／B-07 用萬用守衛，且信任請求附帶的 batch | `runGate`／`packageGate` 沿父鏈反查歸屬 |
| 5 | `/upload` 把租戶層角色算進授權 | 只接受案件層 R1／R2 |
| 6 | 同案件跨法人錯配（A 法人 TB 掛 B 法人期間） | 應用層驗到 ReportingUnit．legal_entity_id ＋ **migration 0024 DB 守衛** |

**驗證紀律**：每個授權修補都以「反轉該條件後測試必須轉紅」實測過。
只加負面測試不夠——用來反證的使用者必須是**角色種類正確、作用域錯誤**的樣本，
否則反轉作用域時測試不會紅（種子因此有租戶層庚 R3、辛 R2）。

**測試分級（2026-08-08 實測後建立）**——日常不要每次都跑完整 764 條：

| 指令 | 範圍 | 耗時 |
|---|---|---|
| `pnpm test:db:<domain>` | mapping／adjustment／period／basis 各自單跑（自行重建 DB 並補齊前置） | 9～15 秒 |
| `pnpm test:quick` | 單元＋DB 整合全部 | 48 秒 |
| `pnpm test`（＝`test:full`） | 完整 764 條 | **約 4～5 分鐘** |
| `pnpm test:acceptance:<suite>` | 九支端到端各自單跑 | 8～54 秒 |
| `pnpm test:timing` | 逐 suite 耗時 | — |

完整一輪只在**切片收口與 push 前**跑。連續兩輪不機械套用：
worker／租約／競態／冪等＝收口跑兩輪；migration／RLS／會計不變條件＝至少完整一輪，
重要版本可兩輪；純檔案搬移＝相關測試反覆跑，最後完整一輪；UI 文案與布局＝相關測試＋實機走查。

DB 整合測試已拆為共用底座（`tests/integration/lib/harness.sh`）＋四個可單跑的領域檔
（`tests/integration/db/`），其餘領域仍在聚合入口 `tests/integration/db.test.sh`。
fixture **幂等**：單跑時自行建立前置，聚合時偵測到既有狀態就跳過——不維護兩套種子。

`PSQL_MODE` 維持 `docker`（本機未裝 psql）：實測 `docker exec` 只佔 262 秒中的約 30 秒，
原訂「完整測試超過 20 分鐘就做連線池」的觸發條件遠未達成，因此不做連線池。

**跑 `pnpm test` 前必須先停掉 `pnpm dev`**——端到端測試會自己 spawn API（8091～8099）
與 worker，8080 的 dev worker 會搶同一批 `UPLOADED` 批次造成偽失敗；測試會重建 `cbfc_dev`，
跑完以 `pnpm db:seed` 還原。

2026-08-04 已另做實際瀏覽器走查：甲上傳與接受、G-02 未映射阻擋、甲建立草稿、乙批准、覆蓋率 100%、G-02 通過、PREVIEW 非正式輸出與控制總額勾稽均正常；2026-03／04 預覽也確認按報告期解析生效版本。

完整對話、證據、走查資料與接續注意事項見：

- `docs/handoffs/SESSION_HANDOFF_2026-08-04.md`（里程碑 1 ＋ 映射切片）
- `docs/handoffs/SESSION_HANDOFF_2026-08-04_SLICE-M2-02A.md`（調整生命週期 ＋ 覆核回饋硬化）
- `docs/handoffs/SESSION_HANDOFF_2026-08-04_SLICE-M2-03.md`（背景工作可靠性）
- `docs/handoffs/SESSION_HANDOFF_2026-08-05_MILESTONE-2-EXIT-REVIEW.md`（里程碑 2 阻擋盤點、
  三項待修正判定、SLICE-M2-04 邊界）
- `docs/handoffs/SESSION_HANDOFF_2026-08-06_SLICE-M2-04.md`（B-00 五佇列 ＋ UNVERIFIABLE
  人工確認；0019／0020 硬化與 **0021 關閉收口**；M2-04 已正式關閉）
- `docs/handoffs/SESSION_HANDOFF_2026-08-07_SLICE-M2-05.md`（期間生命週期
  §25.8 完整狀態機、DB 唯一裁決點、fail closed 穩定代碼）
- `docs/handoffs/SESSION_HANDOFF_2026-08-07_SLICE-M2-06.md`（多基礎與四類規則最小
  資料模型、0023、審查節奏決議）
- `docs/handoffs/SESSION_HANDOFF_2026-08-10_ROUTE-SERVICE.md`（**最新接續入口**：
  API 模組化拆層、六類授權缺口封閉、0024、測試分級）

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

**里程碑 2 的 02 系列（映射→調整→計算→證據包）已收官，`SLICE-M2-04` 亦已正式關閉**
（0021 收口，520/520 連續兩輪全綠）。里程碑 2 離開條件盤點見
`docs/reviews/MILESTONE-2_EXIT_REVIEW.md`（提交 `6ab32d3`），目前**尚不能宣告離開**。

`SLICE-M2-05 期間生命週期`已完成：狀態機由四值簡化擴為 §25.8 完整 13 值，
DB 為唯一裁決點（`app_runtime` 對 `period_revision` 只餘 INSERT／SELECT），
未實作的守衛一律 fail closed 並回 `Gxx_NOT_IMPLEMENTED:` 穩定代碼。

`SLICE-M2-06 多基礎與四類規則最小資料模型`已完成（migration 0023）：
`BookBasis`（案件範圍＋RLS）／`PostingLayer`（平台參照主檔，`app_runtime` 唯讀）／
`BasisSourcePolicyVersion`／構成模型（`BasisCompositionVersion` ＋ `ConstitutiveLayerItem`）／
調節模型（`BasisReconciliation` ＋ Line ＋ Difference，`DRAFT → FINALIZED`）／
`TaxBasisObservation`／`Rule`＋`RuleVersion`（四類規則，無引擎）。
`adjustment.basis` 硬約束欄位已 DROP，改為 `basis_from_id`／`basis_to_id`／`posting_layer_id`。
**REQ-BAS-001 與 REQ-RUL-001 的阻擋項因此清除。**

三條不可退讓的實作原則寫在 0023 檔頭：代碼不驅動約束（新增第四基礎零 DDL）；
構成與調節分屬不同模型（§26.1 L1074）；守衛未實作即 fail closed
（`AMENDED_NOT_IMPLEMENTED:`、`INV24_THRESHOLD_NOT_IMPLEMENTED:`、
`AUTO_POST_NOT_IMPLEMENTED:`、`RECON_RUN_PREDATES_BASIS_MODEL:`）。

下一刀：**自動保存、儲存狀態與 Session 恢復**（NFR-UX-001／NFR-INT-002）——
**這是里程碑 2 離開盤點的最後一個阻擋項**，完成後即可重跑離開複核。

範圍限定在 **B-05 Adjustment 草稿**，不做全平台通用編輯框架：
dirty 時 5 秒內嘗試自動保存；blur、切換案件、送覆核、Session 到期前立即保存；
畫面顯示「未保存／保存中／已保存／保存失敗／版本衝突」；
`object_version` ＋ `edit_session_id` ＋ `client_save_sequence`（§26.9 三層版本語意）；
已獲伺服器確認的草稿不得遺失；**不使用 IndexedDB／localStorage 保存客戶財務內容**；
Session 恢復後回到原案件、期間與 Adjustment；兩個分頁衝突不得互相覆蓋；
PREVIEW run 繼續只讀 manifest 凍結內容。
Adjustment 驗證完成後，再把同一套能力擴到映射草稿。

**不要再做結構重構**——拆層已於 2e19c9b 結束，server.ts 54 行已達目標，
不得為了行數繼續拆。

**審查節奏（2026-08-07 決議）**：審查預算按不可逆性投放。
第一級（資料模型、跨租戶、安全、會計口徑、金額精度、狀態機、版本與稽核軌跡）
維持先寫短契約與負面測試再實作；第二級（API 契約、併發、草稿恢復、權限與工作流程）
直接實作但必須有整合測試與失敗案例；第三級（畫面布局、文案、篩選）直接做並實機走查，
不建立切片文件。折算屬第一級，將來仍需較完整的事前契約。
門檻不變：基線不隨意更改、每刀明列不做事項、DB 不變條件與租戶隔離必須有負面測試、
關鍵操作維持交易原子性與可重演性、完整測試不得退化、真正偏離基線才寫 ADR／CR、
每個切片必須交付可執行程式。
**每個負面測試必須先證明前置狀態成立，再驗證拒絕理由**——避免「以錯誤理由通過」的假綠。

不重開已關閉切片、不擴寫大型規格、不修改兩份正式基線。

## 第一次回覆使用者時

請先回報：

1. 你實際讀到哪些文件與章節，並確認兩份權威基線均可讀取；
2. 你對目前完成範圍、不可弱化控制及環境決定的理解；
3. 你準備先驗證或實作的最小範圍；
4. 在使用者確認前，不做跨里程碑擴張，也不重寫既有基線。
