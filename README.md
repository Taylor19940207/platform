# 中日跨境財務轉換平台（platform）

依《基本設計書 v1.1》§27 的模組化單體架構。文件權威順序與基線凍結規則見 `docs/GOVERNANCE.md`。
正式工程基線已放在 `docs/baseline/`；新 session 的閱讀與交接入口為 `SESSION_START.md`。
尚未決策、需要等真實使用證據再討論的產品議題統一放在 `docs/FUTURE_DISCUSSIONS.md`；
可排程工作仍以 `docs/BACKLOG.md` 為準。

**權威開發環境：macOS ＋ Docker Desktop。** 應用程式（API／Worker／前端）在 Host 上執行，
PostgreSQL 16／Redis 7／MinIO 由 Docker Compose 提供。雲端沙箱方案已移至 `docs/SANDBOX.md`，
不作為主要執行方式。

## 前置需求

- Docker Desktop（含 Docker Compose）
- Node.js 22 LTS（≥ 22.18；`nvm install 22`）
- pnpm（`corepack enable` 即可，版本由 package.json 的 packageManager 指定）

## 啟動（全新環境）

```bash
git clone <repo> && cd platform
cp .env.example .env.local        # 依需要調整；預設即可跑
docker compose --env-file .env.local up -d  # PostgreSQL / Redis / MinIO（named volume）
pnpm install
pnpm db:migrate                   # 建立 schema（可從零重建）
pnpm db:seed                      # 開發種子資料
pnpm dev                          # API + Worker
```

瀏覽器開 <http://localhost:8080> → 開發模式登入 → B-00 個人工作台。

## 測試

```bash
pnpm test          # 單元 66 ＋ DB 整合 896 ＋ 端到端驗收 437，共 1,399 條
pnpm test:quick    # 單元＋DB 整合——切片收口前的快速基線
pnpm test:db:cashflow # 只跑現金流 DB 套件；其他領域同樣使用 test:db:<domain>
pnpm test:timing   # 逐 suite 耗時，決定要優化什麼之前先量
```

**跑測試前先停掉 `pnpm dev`**：端到端測試會自己 spawn API（8091～8099）與 worker，
8080 的 dev worker 會與之競爭同一批 `UPLOADED` 批次。測試會重建 `cbfc_dev` 資料，
跑完以 `pnpm db:seed` 還原開發資料。

測試直接打真實 PostgreSQL（compose 的 db 容器），不用 mock——守衛與 RLS 的行為就是被測目標。

## 設定

所有連線一律由 `.env.local` 注入（範本：`.env.example`）。程式內不寫死路徑、主機、使用者。
Docker Compose 不會自行讀取 `.env.local`，所以 Compose 指令須帶 `--env-file .env.local`。
`PSQL_MODE=docker`（預設）透過 `docker exec` 進 db 容器執行 SQL，本機免裝 psql；
已裝 psql 者可改 `PSQL_MODE=local`。

**不進 git**：`.env.local`、`var/`（物件儲存、session 密鑰）、資料庫資料（named volume）、log。

## 現況

- [x] monorepo 骨架（§27 結構）＋ PostgreSQL 16＋45 份 migration（可從零重建）
- [x] RLS 租戶隔離（§24.9／INV-18）；G-01／INV-28／SOD-07 為 DB 觸發器（最後防線）
- [x] ImportBatch 七狀態 × identity_status 正交軸（§25.5／CR-002）
- [x] **里程碑 1**：登入 → 選 客戶/法人/期間 → 上傳 TB → 雜湊＋平衡＋歸屬驗證 → B-00（驗收 20/20）
- [x] 開發環境：macOS＋Docker Compose 為權威；設定全數走 `.env.local`（Mac 實機 48/48 → 87/87 → 92/92（跨機驗證））
- [x] **里程碑 2 第一刀（SLICE-M2-01）**：ACCEPTED TB → 版本化映射（批准 SOD／不可覆寫／§24.1A 歸屬）→ G-02 → 集團 TB 預覽＋最小 B-04；Case-001 與 Excel 逐科目比對 12/12（`docs/slices/`、`tests/fixtures/case-001/`）
- [x] **里程碑 2 第二刀（SLICE-M2-02A）**：Adjustment 完整生命週期 `DRAFTING → PENDING_REVIEW → PENDING_APPROVAL → APPROVED → 物化 JournalEntry／Line`；三個 SoD 掛在三個不同遷移（G-04／SOD-01、G-05／SOD-02、**AC-WFL-001**）＋ G-08 四項證據＋`object_version` 樂觀鎖＋退回里程碑（`docs/slices/`、`docs/adr/ADR-M2-001.md`）
- [x] **SLICE-M2-03 背景工作可靠性**：`BackgroundJob` 租約＋`claim_token` fencing＋心跳＋安全重領＋冪等鍵＋錯誤四分類；結果寫入單一交易，`VALIDATING` 成為交易內狀態（`docs/adr/ADR-M2-002.md`）。**已含 2026-08-05 逐行審查四項關閉修正**（失敗寫回 fencing、fence 列鎖、重領守衛封後門、冪等鍵原始碼去 NUL）
- [x] **里程碑 2 第三刀（SLICE-M2-02B）**：PREVIEW CalculationRun ＋ CalculationInputManifest 凍結（同交易解析＋G-02＋Manifest＋Job＋事件）；重演＝新 run 引用同一 Manifest；result_content_hash 排除身分欄位；B-06 骨架；Case-001 調整後集團 TB 12/12（`docs/slices/`）
- [x] **里程碑 2 第四刀（SLICE-M2-02C）**：預覽證據包——非同步產包（GENERATING→READY/FAILED）、HTML artifact 一次生成保存＋下載驗 hash、audit cutoff、逐科目範圍追溯（Case-001 12/12 BALANCE）、staging 安全重試、契約 D 上游驗證；來源三表補不可變（`docs/slices/`）
- [x] **SLICE-M2-04 B-00 待辦整合與身分確認**：五佇列（待身分確認／待覆核／待批准／被退回／未完成草稿）＋ UNVERIFIABLE 人工確認（B-03）；`current_identity_assessment_id` 指標與身分判定成對寫入；確認狀態正向白名單；映射草稿保存不可變來源批次脈絡。**0021 關閉收口**：映射來源批次必須為 ACCEPTED（DB `FOR UPDATE` 鎖列＋應用層 409／`SOURCE_BATCH_NOT_ACCEPTED`）
- [x] **SLICE-M2-05 期間生命週期（§25.8）**：`PeriodRevision` 由四值簡化擴為完整 13 狀態；`SETUP → OPEN → IN_PREPARATION → IN_REVIEW → ADJ_APPROVED` ＋ `AWAITING_REVIEWER` 由覆蓋評估決定落點；**守衛未實作一律 fail closed**（`Gxx_NOT_IMPLEMENTED:` 穩定代碼）；DB 為唯一裁決點（`app_runtime` 的 UPDATE／DELETE 已撤回）；`ReviewerEligibilityEvaluation` 最小版不可變快照
- [x] **SLICE-M2-06 多基礎與四類規則最小模型（0023）**：`BookBasis`（案件範圍＋RLS）／`PostingLayer`（平台參照主檔）／構成與調節分屬不同模型／`TaxBasisObservation`／`Rule`＋`RuleVersion`；新增第四基礎零 DDL
- [x] **NFR-UX-001／INT-002 自動保存與 Session 恢復（0025–0027）**：內容雜湊冪等鍵、W 窗口以**伺服器確認**計、離線退避、beforeunload；行為測試在 vm 沙箱執行出貨程式本身
- [x] **🏁 里程碑 2 離開複核通過**（2026-08-10，`docs/reviews/MILESTONE-2_EXIT_REVIEW_2026-08-10.md`）
- [x] **SLICE-M3-01 B-02 期間工作台（0028／0029）**：`fn_period_transition_spec` 為遷移規格的**唯一可查詢來源**，trigger 與畫面讀同一份；完整 B-02 為案件層 R2／R3／R4；0029 修正期間發起人的角色**作用域**（租戶層指派不得發起遷移）並撤回 PUBLIC EXECUTE
- [x] **SLICE-M3-02 折算與 CTA（0030–0035）**：`Currency`／幣別角色指派（INV-22）／匯率版本四狀態＋觀測／`translation_category`／折算政策與 CTA 落點／權益折算批次集合／期初已折算餘額；**保留盈餘由延續橋接得出，不乘匯率**（CAS 19 §12）；CTA 物化為 `TranslationAdjustmentEntry`（INV-20）；**Manifest 只讀重演＋自身完整性驗證**（SHA-256）。Case-001 12/12、CTA 97,159.00 借方、RE 373,695.00
- [x] **SLICE-M3-03 折算調節核對與期間級 G-07（0036–0038）**：`RoundingToleranceVersion`（幣別對）／`TranslationReconciliation`＋`TranslationDifference`（六類差異、算術推導）／`PeriodFxInputSelection`（R2）與 `PeriodFxRunSelection`（R4）；C2 為**獨立重算**（不呼叫引擎、不讀結果）；兩支 readiness 拆開輸入與結果，**硬差異只要存在就失敗**
- [~] **SLICE-M3-04 現金流支持資料（0039–0045）**：第一段模型與結構守衛、第二段 2a 角色工作流、2b 第一項支持 run 建立入口均已完成；0042 含十一張表的父鏈／版本鏈、十九支 system-only 函式、映射 R2→R3→R4＋SoD、零活動 R2 確認＋R3 覆核；0043 是現金流 run 的唯一 system-only 建立入口（R2、多批次來源同交易凍結、FOR UPDATE 防 TOCTOU）。0044 是 CFS Manifest 的唯一 system-only 凍結入口（顯式版本輸入、單一 snapshot 物化、結構契約查證）。尚待 2b 的支持資料列＋結果雜湊與 replay、完整度與 K1～K4、期間級就緒判定
- [ ] **MVP 3 剩餘**：現金流 2b（未完成前 MVP 3 不得關閉）／G-03 與 `AMENDED` 取代鏈／對外輸出核對（`OutputProfile`）／結果就緒的正式 Guard ID（CR）

## 結構

```
apps/        api（模組化單體宿主）｜worker（背景驗證）｜web（Next.js 佔位）
packages/    domain（狀態機）｜database（migration＋轉接層）｜auth｜contracts｜config
scripts/     dev.mjs｜env.sh（傳輸層）｜sandbox/（非主流程）
tests/       unit（66）｜integration（DB 守衛 896 條）｜acceptance（端到端 437 條）｜fixtures/case-001
docs/        GOVERNANCE｜BACKLOG｜FUTURE_DISCUSSIONS｜adr/｜slices/｜handoffs/
```
