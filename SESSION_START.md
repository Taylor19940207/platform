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
7. `packages/domain/src/importBatch.ts`、四十三份 `packages/database/migrations/*.sql`、`packages/database/src/psql.ts`。
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
均已完成並關閉；里程碑 3 的 **`SLICE-M3-01 B-02 期間工作台`（2026-08-11）與
`SLICE-M3-02 折算與 CTA`與 `SLICE-M3-03 折算調節核對與期間級 G-07`
（皆 2026-08-12，CLOSED／PASS）亦已正式關閉**。
現有 43 份 migration；完整實跑結果為 **1,321**（單元 66、DB 整合 819、端到端 436），
最新一輪全綠（HEAD `a564ea5`，已 push）。

**進行中：`SLICE-M3-04 現金流支持資料`的第一段、第二段 2a 與 2b 第一項已完成**。
0039～0041 建立模型、結構守衛與用途封套；0042 完成十一張表的父鏈／版本鏈守衛、
十九支 system-only 工作流函式、零活動的 R2 確認＋R3 覆核，以及映射的
R2→R3→R4／SoD／重疊／靜態粒度控制；**0043 把現金流支持 run 的建立收斂成單一
system-only 入口**（案件層 R2、多批次來源在同一交易內凍結、`FOR UPDATE` 使批次
狀態變更不得穿過建立交易；已複核通過並 push）。**下一步是 2b 第二刀 A：CFS Manifest
的 system-only 凍結入口與 `fn_manifest_verify` 驗證**——結果雜湊與 replay 已改排到
支持資料列那一刀（沒有真實輸出前重演等於拿 Manifest 雜湊冒充結果雜湊）。
不得回頭重做 2a／0043，也不得把後續畫面混進同一刀。
細節見 `docs/handoffs/SESSION_HANDOFF_2026-08-12_SLICE-M3-04-PHASE1.md`。

## 🏁 里程碑 2 已完成（2026-08-10 離開複核通過）

複核報告：`docs/reviews/MILESTONE-2_EXIT_REVIEW_2026-08-10.md`。
前次盤點的五個阻擋項全部關閉，各有**反證過**的負面測試；期間另封閉六類既有
授權／歸屬缺口。MVP 1 與 MVP 2 的離開條件六句全部成立。

**三項已知限制標為 ACCEPTED_DEVIATION，不得寫成完成**——三者方向一致：
現行行為都**比目標更嚴**，不存在「已放行但未驗證」的資料。
1. `CalendarUsage` 未落地，首期唯一約束暫時較寬（不分用途）。
2. R5／R7／R8 的授權範圍物件未完成，讀取白名單採嚴格子集 R2／R3／R4。
3. `AMENDED` 取代鏈未完成，寫入即 fail closed。

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

**測試分級（2026-08-08 實測後建立）**——日常不要每次都跑完整 1,321 條：

| 指令 | 範圍 | 耗時 |
|---|---|---|
| `pnpm test:db:<domain>` | mapping／adjustment／period／basis／fx／**cashflow** 各自單跑（自行重建 DB 並補齊前置） | 依領域實測 |
| `pnpm test:quick` | 單元＋DB 整合全部 | 依本機實測 |
| `pnpm test`（＝`test:full`） | 完整 1,321 條 | **依本機實測為準** |
| `pnpm test:acceptance:<suite>` | 十支端到端各自單跑 | 8～54 秒 |
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
- `docs/handoffs/SESSION_HANDOFF_2026-08-10_ROUTE-SERVICE.md`（API 模組化拆層、
  六類授權缺口封閉、0024、測試分級）
- `docs/reviews/MILESTONE-2_EXIT_REVIEW_2026-08-10.md`（里程碑 2 離開複核通過；
  PASS／ACCEPTED_DEVIATION／DEFERRED 逐條判定）
- `docs/handoffs/SESSION_HANDOFF_2026-08-11_SLICE-M3-01.md`（B-02 期間工作台、
  0028 遷移規格函式、0029 角色作用域修補）
- `docs/handoffs/SESSION_HANDOFF_2026-08-12_SLICE-M3-02.md`（折算與 CTA、
  0030～0035、Manifest 重演與完整性）
- `docs/handoffs/SESSION_HANDOFF_2026-08-12_SLICE-M3-03.md`（折算調節核對、
  兩支 readiness、0036～0038）
- `docs/handoffs/SESSION_HANDOFF_2026-08-12_SLICE-M3-04-PHASE1.md`（**最新接續入口**：
  檔名保留以避免交接連結分岔；內容已更新至 0043／2b 第一刀關閉，
  下一步為 2b 第二刀 A：CFS Manifest system-only 凍結入口）

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

## `SLICE-M3-01 B-02 期間工作台`已完成並關閉（2026-08-11）

切片文件：`docs/slices/SLICE-M3-01_期間工作台.md`。期間狀態機（0022）原本是
「能力完整、入口缺席」——13 個狀態與全部守衛就緒，使用者卻只能用
`POST /period/transition` 打它。本刀補上畫面，整條流程第一次以**期間**串起來。

**0028　遷移規格的唯一可查詢來源**：`fn_period_transition_spec(from_status)` 唯讀，
0022 的 trigger 改為呼叫它，B-02 讀同一份。不是新增控制，是換存放形式——既有期間
測試（DB 29＋端到端 37）斷言一字未改全綠。`required_role` 對 `NOT_IMPLEMENTED` 的列
一律 NULL：守衛未實作＝誰可發起也未決定，填角色會憑空發明規則，並讓角色檢查搶在
fail closed 之前觸發。

**授權**：完整 B-02 為案件層 R2／R3／R4。**R1 排除**——§24.6 註③限制「R1 僅看得到
自身提交狀態，非期間全貌」；R1 維持 B-00 與上傳入口。B-00 補上 B-02 入口，可見範圍
與 B-02 授權**同一組角色**（用比 B-02 寬的角色列期間，等於在 B-00 洩漏 B-02 擋掉的東西）。

**0029　期間發起人的角色作用域**（走查後追加）：0022 起的角色驗證寫成
`(ra.engagement_id IS NULL OR ra.engagement_id = v_eng)`，`IS NULL` 分支把租戶層
指派當成對所有案件有效——畫面擋得住，DB 擋不住。改為嚴格相等（§26.3：遷移用的
R2／R4 都屬 EngagementAssignment）。同時 `REVOKE ALL … FROM PUBLIC`：PostgreSQL 預設
把新函式的 EXECUTE 授予 PUBLIC，0028 只寫了 GRANT，權限敘述與實況不符。

**兩個可重用的教訓**：
1. 實機走查抓到「首期的 SETUP → OPEN 按鈕可用、畫面卻印非首期不可用」——
   **CONDITIONAL 只有條件成立時才該畫成不可用**。對可用功能謊稱不存在，
   與把未實作畫成可點是同一種錯，只是方向相反。
2. DB 整合套件會重建資料庫並重跑 migration，**直接改資料庫裡的函式做反證會假綠**；
   反證必須改 migration 檔案本身。

## `SLICE-M3-02 折算與 CTA`已完成並關閉（2026-08-12，CLOSED／PASS）

切片文件：`docs/slices/SLICE-M3-02_折算與CTA.md`（含關閉判定表）。
交付 migration **0030～0035**：資料模型與守衛 → 硬化 → 主檔工作流與父鏈 →
折算引擎 → Manifest 可重演 → Manifest 完整性驗證。

**會計結論**：Case-001 調整後集團 TB 59,000,000 JPY → 借 2,823,285.00／
貸 2,920,444.00 CNY，**CTA ＝ 97,159.00 借方**；RE 勾稽 373,695.00；
捨入 350,000 × 0.0481233 → 16,843.16。
**保留盈餘不得以餘額乘匯率求得**（CAS 19 §12 應用指南），由前期已鎖定的期末
已折算值延續；權益的逐筆歷史匯率靠 `EquityTranslationLotSetVersion`。

**三條在該刀確立的原則**：
1. **權限是邊界，函式是流程，GUC 只是標記**——自訂 GUC 任何連線都能
   `set_config`，批准欄以**欄位級權限**擋住。
2. **只讀 Manifest 才叫可重演**——「同一批現行資料跑兩次相同」只是確定性。
3. **用 Manifest 之前先驗 Manifest**——不可變 trigger 擋不住資料修復與
   owner 操作；驗證與生成共用同一套 canonical 規則。

**兩項已接受的邊界**：更換匯率版本須同步建立相容的 lot set；
FAILED replay 的診斷產出保存政策留待證據包切片（BACKLOG 已記）。

### MVP 3 尚未完成

1. **REQ-CFS-001 現金流支持資料**——未完成前 **MVP 3 不得關閉**。
2. **B-06 折算／核對畫面與 replay 入口**（DB 能力已具備）。
3. **折算調節核對、`RoundingTolerance`／INV-24**。
4. **G-03／G-07 的期間級聚合判定**。

**3 與 4 完成後才解鎖 `ADJ_APPROVED → CALCULATING`**（0028 的規格函式維持
`NOT_IMPLEMENTED`）。

## `SLICE-M3-03 折算調節核對與期間級 G-07`已完成並關閉（2026-08-12，CLOSED／PASS）

切片文件含 **20/20 驗收對照表**。交付 migration **0036～0038**。

**一個在契約走查中發現的循環**：基線的 G-07 掛在 `ADJ_APPROVED → CALCULATING`，
只能回答「**開始計算**所需的輸入是否齊備」。若把「run COMPLETED → 調節 FINALIZED
→ R4 選定」也塞進 G-07，就變成「還沒進 CALCULATING，卻要先完成計算與調節」。
因此拆成兩支唯讀函式：
- `fn_period_fx_input_readiness`＝現行 G-07（六項輸入條件，`G07_*`）
- `fn_period_fx_result_readiness`＝折算結果與調節（七項，`POSTFX_*`，
  整體回 `POST_FX_RECONCILIATION_READY`）。**暫不自行命名 G-13**，
  新增正式 Guard ID 須走 CR（BACKLOG 已記）。

**其他關鍵決定**：
- **內部核對不產生尾差**——引擎與 C2 同法同率，C1～C4 只會是零差異或硬差異；
  `ROUNDING_DIFFERENCE` 保留給日後的對外輸出／`OutputProfile` 核對。
  Case-001 調節「所有類別零筆」是**正確結果**，INV-24 的樣本明標為 schema-level。
- **硬差異只要存在就失敗，狀態無關**——G-07 是 `output_capability = NONE` 的硬守衛；
  只擋 `OPEN` 的話，把 `MISSING_RATE` 標成 `ACCEPTED_EXCEPTION` 就能讓期間變 ready。
- **權威輸入與結論都要顯式選定**：`PeriodFxInputSelection`（R2）與
  `PeriodFxRunSelection`（R4），現行版本由**取代鏈**判斷而非 `created_at`。
- tolerance 是**幣別對**、凍結在 reconciliation 上（FX Manifest 已封存）。

**本刀不解鎖任何遷移**：`ADJ_APPROVED → CALCULATING` 還缺 G-03；
`CALCULATING → RECONCILING` 還缺其餘守衛。0028 的規格函式未改動。

下一刀：**B-06 折算／核對畫面與 replay 入口**（DB 能力已具備），
或先做 **REQ-CFS-001 現金流**——後者未完成前 MVP 3 不得關閉。

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
