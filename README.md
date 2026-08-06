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
pnpm test          # 單元 50 ＋ DB 整合 204 ＋ 端到端驗收 233（里程碑 1 之 20 ＋ 映射 27 ＋ 調整 62 ＋ 工作可靠性 29 ＋ 計算執行 23 ＋ 證據包 24 ＋ 工作台身分確認 48），共 487 條
```

**跑測試前先停掉 `pnpm dev`**：端到端測試會自己 spawn API（8091～8098）與 worker，
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

- [x] monorepo 骨架（§27 結構）＋ PostgreSQL 16＋18 份 migration（32 張表；可從零重建）
- [x] RLS 租戶隔離（§24.9／INV-18）；G-01／INV-28／SOD-07 為 DB 觸發器（最後防線）
- [x] ImportBatch 七狀態 × identity_status 正交軸（§25.5／CR-002）
- [x] **里程碑 1**：登入 → 選 客戶/法人/期間 → 上傳 TB → 雜湊＋平衡＋歸屬驗證 → B-00（驗收 20/20）
- [x] 開發環境：macOS＋Docker Compose 為權威；設定全數走 `.env.local`（Mac 實機 48/48 → 87/87 → 92/92（跨機驗證））
- [x] **里程碑 2 第一刀（SLICE-M2-01）**：ACCEPTED TB → 版本化映射（批准 SOD／不可覆寫／§24.1A 歸屬）→ G-02 → 集團 TB 預覽＋最小 B-04；Case-001 與 Excel 逐科目比對 12/12（`docs/slices/`、`tests/fixtures/case-001/`）
- [x] **里程碑 2 第二刀（SLICE-M2-02A）**：Adjustment 完整生命週期 `DRAFTING → PENDING_REVIEW → PENDING_APPROVAL → APPROVED → 物化 JournalEntry／Line`；三個 SoD 掛在三個不同遷移（G-04／SOD-01、G-05／SOD-02、**AC-WFL-001**）＋ G-08 四項證據＋`object_version` 樂觀鎖＋退回里程碑（`docs/slices/`、`docs/adr/ADR-M2-001.md`）
- [x] **SLICE-M2-03 背景工作可靠性**：`BackgroundJob` 租約＋`claim_token` fencing＋心跳＋安全重領＋冪等鍵＋錯誤四分類；結果寫入單一交易，`VALIDATING` 成為交易內狀態（`docs/adr/ADR-M2-002.md`）。**已含 2026-08-05 逐行審查四項關閉修正**（失敗寫回 fencing、fence 列鎖、重領守衛封後門、冪等鍵原始碼去 NUL）
- [x] **里程碑 2 第三刀（SLICE-M2-02B）**：PREVIEW CalculationRun ＋ CalculationInputManifest 凍結（同交易解析＋G-02＋Manifest＋Job＋事件）；重演＝新 run 引用同一 Manifest；result_content_hash 排除身分欄位；B-06 骨架；Case-001 調整後集團 TB 12/12（`docs/slices/`）
- [x] **里程碑 2 第四刀（SLICE-M2-02C）**：預覽證據包——非同步產包（GENERATING→READY/FAILED）、HTML artifact 一次生成保存＋下載驗 hash、audit cutoff、逐科目範圍追溯（Case-001 12/12 BALANCE）、staging 安全重試、契約 D 上游驗證；來源三表補不可變（`docs/slices/`）
- [ ] 里程碑 2 檢視：02 系列收官（下一步：折算 MVP 3 或正式交付能力，先做切片文件）

## 結構

```
apps/        api（模組化單體宿主）｜worker（背景驗證）｜web（Next.js 佔位）
packages/    domain（狀態機）｜database（migration＋轉接層）｜auth｜contracts｜config
scripts/     dev.mjs｜env.sh（傳輸層）｜sandbox/（非主流程）
tests/       unit｜integration（DB 守衛 192 條）｜acceptance（端到端 185 條）｜fixtures/case-001
docs/        GOVERNANCE｜BACKLOG｜FUTURE_DISCUSSIONS｜adr/｜slices/｜handoffs/
```
