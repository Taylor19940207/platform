# SLICE-M2-02B　PREVIEW CalculationRun 與輸入凍結

**範圍**：`ACCEPTED TB ＋ 已批准 Adjustment → 建立 PREVIEW CalculationRun（非同步）
→ CalculationInputManifest 凍結 → 調整後集團 TB 快照（未折算）→ 依 Manifest 重演`。
以 Case-001 與既有 Excel／映射預覽／批准調整逐項勾稽通過為完成條件。

## 基線對應（抽取，不修改基線）

| 主題 | 基線位置 |
|---|---|
| Run 記錄輸入版本集合、不可修改、重跑同集合同結果 | 設計書 §25.3；AC-RUL-001（手冊 §19） |
| Manifest 不可變：object_id＋版本＋content_hash＋不可變內容（或引用）、`hash_algorithm`、`canonicalization_version` | 設計書 §26.9；手冊 §00A `CalculationInputManifest` |
| 三層版本語意：`object_version`（併發）／`business_version`（里程碑）／Manifest（凍結）不可混用 | 設計書 §26.9；手冊 §16（CR-002-04） |
| 凍結「實際解析結果」而非識別碼——凍結會變動的識別碼等於沒有凍結 | 設計書 §26.9「把 frozen set 做完整」 |
| INV-17（凍結集合完整＋整體 hash、同集合重跑同結果）、INV-29（重演只讀凍結內容並驗 hash；不得改讀目前工作物件） | 設計書 §26.12 |
| INV-07（`run_type=PREVIEW → release_mode=PREVIEW_ONLY`；OFFICIAL 不讀 AdjustmentLine）、INV-25（`is_official` 為推導值） | 設計書 §26.12 |
| PREVIEW 無正式交付能力：不建 DeliveryRecord、不入 SUPERSEDED 鏈 | 設計書 §25.9／§26.9（INV-09、INV-27 語意） |
| Run 一律非同步；重試不得產生第二個 run | 設計書 §27.4 |
| 工作器決定性：禁 wall-clock／隨機／外部即時查詢；`engine_version` 入 run；逾時 FAILED 不留 RUNNING | 設計書 §27.5 |
| 重演流程與 REPLAY_FAILED 外顯；草稿前進≠重演失敗；標準化版本不得造成假性失敗 | 設計書 §27.5；手冊 AC-INTG-002 子案例 INT-d／INT-e／INT-e2／INT-e3 |
| 原始版本不可覆寫、可重演審計 | 手冊 REQ-ING-002、REQ-AUD-001 |
| B-06 計算執行畫面主要角色 R2／R3 | 設計書 §28.3 |

## 本刀凍結的設計決策

1. **前置條件與 TOCTOU 防護**：目標批次 `ACCEPTED`（G-01 既有守衛）＋ G-02 通過＋輸入歸屬經伺服器端驗證（§24.1A）。**解析映射集合 → 對「同一份集合」驗 G-02 → 寫入 Manifest 必須在單一短交易、同一資料庫 snapshot 內完成**（以 CTE 或同交易查詢實作）——不得先驗 G-02、之後另查 current mappings 建 Manifest，否則併發批准新版本時凍結的集合與被驗證的集合不同。任一前置不成立即拒絕建立，不產生 run 資料列。
2. **每次執行＝新 Run**：不存在「重新整理舊結果」。任何輸入變動後想看新結果＝建立新 `calculation_run_id`；舊 run 及其輸出保留（保留政策屬 D-26-04 掛點，本刀不實作清理）。
3. **Manifest 於建立交易內凍結**：Run、Manifest、`BackgroundJob`、建立 DomainEvent **同一交易**產生；worker 只消費已凍結的輸入，不在執行期解析任何「目前版本」。
4. **02B 只產生 PREVIEW**：`run_type=PREVIEW`、輸出強制 `release_mode=PREVIEW_ONLY`；不建立 DeliveryRecord、不產生任何 OFFICIAL 資格；畫面醒目標示非正式輸出。
5. **只納入已批准 Adjustment**：讀 INV-06 物化後的 `JournalEntry／Line`。Manifest 同時保存 **Adjustment ID、批准時 `business_version`、與實際 Journal 內容**——不得只引用「目前的 Adjustment」。「PREVIEW 讀未批准 AdjustmentLine」屬 §26.9 完整能力，留後續刀。
6. **計算範圍明示未折算**：本刀輸出＝「科目映射＋已批准調整、**未折算**」。Manifest 凍結 `calculation_scope = NO_FX`（或等價明確語意），輸出畫面與資料標示「未折算——折算屬 MVP 3」；不得讓「集團 TB」名稱使人誤以為已完成幣別折算。匯率、重要性門檻、期間組成等尚未實作的輸入類型**不偽造欄位**。
7. **02C 證據包不混入本刀**。

## Run 狀態與 BackgroundJob 的關係（單一真相來源）

- `CalculationRun.status ∈ {RUNNING, COMPLETED, FAILED, SUPERSEDED}`（§25.3 四狀態，不增不減）。`RUNNING` 涵蓋「已建立～執行完成前」全程；**細粒度執行進度（排隊、退避、重領）以 `BackgroundJob.status` 為唯一權威**（ADR-M2-002 同一分工：Run＝結果狀態，Job＝執行進度）。
- **結果寫入、Run 終態（COMPLETED／FAILED）、Job 終態、完成 DomainEvent 必須同一交易**——不存在「Run COMPLETED 但 Job RETRY_WAIT」或「有結果沒事件」的組合。
- `SUPERSEDED` 屬 §25.11 下游失效鏈，本刀無退回／重算鏈，**不使用**，語意保留。

## 重演（replay）建立什麼

原 Run、Manifest、輸出**均不可修改**，因此重演不得把原 Run 改成任何失敗狀態：

- 重演＝建立**新 Run**，帶 `replay_of_run_id`，**引用同一份 Manifest**（不重建、不複製凍結內容；Manifest 本身不可變）。
- 重演流程依 §27.5：讀 manifest 凍結內容 → 以 manifest 記錄的 `hash_algorithm`＋`canonicalization_version` 重算並比對 content_hash → 相符則重算並與原 run 的 result hash 比對。
- 結果落在 **replay run 自己身上**：一致 → `COMPLETED`＋比對結論；凍結內容遺失／損壞／hash 不符 → replay run `FAILED`（原因代碼 `REPLAY_FAILED`，外顯）。原 run 永遠不變。

## 計算內容 hash 與執行 metadata 分離

- `frozen_set_content_hash` **只涵蓋計算輸入**（manifest entries 的 canonical 內容）。`run_id`、`manifest_id`、建立者、建立時間屬**稽核 metadata**，保存但**不入 hash**——否則相同輸入的兩個 run 永遠得到不同 hash，重演比對失去基礎。
- 結果側同理：run 完成時保存 `result_content_hash`＝canonical 快照內容（排序後的科目列與金額）之 hash，**排除 run_id 與時間戳**。相同輸入 → 相同 `frozen_set_content_hash` → 重演後相同 `result_content_hash`。

## Manifest entry 的版本欄位（三種語意分開保存）

每筆 entry：`object_type`、`object_id`、`concurrency_version`（=`object_version`，**可為 NULL**）、
`domain_version_kind`＋`domain_version_value`、`content_hash`、`payload` 或不可變引用。

| 輸入 | concurrency_version | domain_version_kind／value |
|---|---|---|
| ImportBatch／SourceDataset | NULL（不可變事實無併發版） | `BATCH_VERSION`／batch_version |
| MappingRule（解析結果） | NULL（已批准版不可變） | `MAPPING_VERSION_NO`／version_no |
| Adjustment＋JournalEntry | NULL（物化分錄不可變） | `BUSINESS_VERSION`／批准時 business_version |
| ChartOfAccounts | NULL | `COA_VERSION`／version_no |

**不得把三種 domain 版本填進同一個 `object_version` 欄位假裝同一語意**（§26.9 三層版本）。
不可變事實以 `content_hash` 為完整性依據，`concurrency_version` 一律 NULL。

## Manifest 至少凍結（實際解析結果，非「目前最新版」指標）

- Tenant、ClientEngagement、PeriodRevision（含期間起訖）。
- 納入的 ImportBatch ID＋`batch_version`、SourceDataset、來源檔案 SHA-256。
- **報告期當時解析出的**每條 MappingRule ID、version_no、生效區間與目標科目（含科目代碼／名稱快照）。
- 納入的 Adjustment ID、批准時 `business_version`、物化 JournalEntry／Line 內容。
- ChartOfAccounts version。
- `calculation_scope = NO_FX`、計算規則與控制規則版本、`engine_version`。
- 執行參數、建立者、建立時間（稽核 metadata，不入 content hash）。
- 每筆輸入的 canonical hash ＋ 整體 `frozen_set_content_hash`，另存 `hash_algorithm` 與 `canonicalization_version`。

## 角色與輸出實體

- **建立 PREVIEW Run＝R2／R3**（B-06 主要角色，§28.3），且須被指派該案件；繞過 UI 直接呼叫 API 的越權請求 → 403＋`ControlViolationAttempt`。
- 本刀物化實體＝**`BalanceSnapshotLine` 最小切片**：`calculation_run_id` 必填、帶 posting 層
  （來源 TB 層／調整層）與集團科目；同一 run 內（科目 × 層）唯一——重試與重領不產生重複列。
- 控制總額（G-09 語意）於結果交易內驗證：來源批次＋物化分錄的借貸合計＝快照合計，不符即整筆交易失敗。

## 冪等契約（兩層，寫死）

| 情形 | 行為 |
|---|---|
| 相同 request key ＋ 相同請求內容 | 回傳**原 run**（不建第二個） |
| 相同 request key ＋ 不同請求內容 | **409**，不建 run |
| 使用者明示再次執行 | 新 request key → 新 `calculation_run_id` |
| worker 層 | 冪等鍵＝`calculation_run_id`（§27.4）；重試／重領不產生第二個 run、不產生重複產物 |

## 驗收清單

| # | 條件 |
|---|---|
| 1 | 未 `ACCEPTED`、G-02 未通過、或輸入歸屬錯誤（跨 Tenant／案件／期間組合）時**不得建立**可執行 Run；API 與 DB 雙層拒絕並寫入 ControlViolationAttempt |
| 2 | Run＋Manifest＋BackgroundJob＋建立 DomainEvent 同一交易產生；G-02 驗證與 Manifest 寫入使用**同一份解析集合**（同交易 snapshot，無 TOCTOU） |
| 3 | 冪等契約三情形逐一驗證：同 key 同內容→原 run；同 key 異內容→409；明示再次執行→新 run ID |
| 4 | Run 建立後，映射改版／新調整批准**不改變**既有 run 的 Manifest 與結果（INT-d） |
| 5 | 依 Manifest 重演舊 run：建立 replay run（`replay_of_run_id`），結果與原 run 的 `result_content_hash` 完全一致；原 run 不被修改 |
| 6 | 新 Run 才採用新生效映射或新批准 Adjustment（新舊 run 結果差異可解釋） |
| 7 | 重演與計算**只讀 Manifest 指定版本**，程式路徑上不存在重新查詢 current mapping 的呼叫（INV-29） |
| 8 | 凍結內容遺失／損壞／hash 不符 → replay run `FAILED`（`REPLAY_FAILED` 外顯），不得改讀目前工作物件（INT-e）；草稿前進不算失敗（INT-e2）；依 manifest 記錄的演算法與標準化版本驗證（INT-e3） |
| 9 | TB＋已批准 Adjustment 以精確十進位（bigint 分）合成；快照借貸平衡且與來源批次＋分錄控制總額勾稽一致（G-09 語意，結果交易內強制） |
| 10 | PREVIEW 輸出醒目標示「非正式・未折算」；不產生 DeliveryRecord；資料層不存在 `PREVIEW` 取得 OFFICIAL 資格的路徑（INV-07／25／27 語意） |
| 11 | 執行失敗不留半套輸出（單一交易）；BackgroundJob 退避重試、到期重領後不產生重複產物（自然唯一鍵），批次與期間業務狀態不被污染；**Run 終態與 Job 終態、結果、完成事件同交易，不存在矛盾組合** |
| 12 | Run、Manifest、快照輸出不可 UPDATE／DELETE（DB 觸發器最後防線） |
| 13 | 控制判定結果保存**機器代碼＋客戶可理解原因**（供未來「為什麼沒通過」畫面），與 §25.18 事件分類一致 |
| 14 | 決定性：禁 wall-clock／隨機／外部查詢；同凍結集合重跑之 **canonical result payload／`result_content_hash` 完全一致**（run_id、時間戳等身分欄位排除於 hash 之外） |
| 15 | 建立 Run 限 R2／R3 且被指派該案件；越權直接 API → 403＋留痕 |
| 16 | **Case-001 勾稽**：PREVIEW 調整後集團 TB 與新 fixture `expected_adjusted_group_tb`（Excel 集團 TB ＋ 02A 批准調整，另檔新增、不覆寫既有預期）逐項一致，並與 B-04 映射預覽、已批准調整分別勾稽 |

## 明確不做（記入 BACKLOG 或後續刀）

OFFICIAL run 與正式交付；02C 證據包；未批准調整納入 PREVIEW；折算／匯率與雙幣
（MVP 3——本刀輸出明示 `NO_FX`）；比較期間、期間組成、重要性門檻入 manifest；
PREVIEW TTL 清理（D-26-04）；`SUPERSEDED` 失效鏈；`mapping_rule` 事件原子化
（BACKLOG 既有約束：最晚 02C／證據包前修正）。

**流程**：本文件走查通過（已完成 2026-08-05）→ migration → domain →
BackgroundJob／worker → API／B-06 骨架 → 三層測試 → Case-001 勾稽 →
更新 handoff → 才進 `SLICE-M2-02C 預覽證據包`。
