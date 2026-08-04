# SLICE-M2-03 完成紀錄（2026-08-04）

> 工程交接紀錄，非正式產品基線。
> 實作契約：`docs/slices/SLICE-M2-03_背景工作可靠性.md`
> 可觀察性決定：`docs/adr/ADR-M2-002.md`

## 完成範圍

新增 `BackgroundJob` 非同步工作物件。**不新增客戶業務功能**；新增內部診斷 API。

職責分工（ADR-M2-002）：

    ImportBatch.status    = 業務結果狀態
    BackgroundJob.status  = 非同步執行進度（QUEUED/RUNNING/RETRY_WAIT/COMPLETED/FAILED）

## 五個原始缺陷的修法

| # | 缺陷 | 修法 |
|---|---|---|
| 1 | 認領無租約，崩潰即永久卡住 | 租約 ＋ `claim_token` ＋ 心跳 ＋ 到期安全重領 |
| 2 | 跨多次 exec 寫入，崩潰留半套來源事實 | 全部 DB 效果收進單一交易；讀檔／解析／計算在交易外 |
| 3 | 重領會複製來源事實 | 單一交易（回滾即乾淨起點）＋ 三條衍生資料 UNIQUE |
| 4 | 任何例外都判 QUARANTINED | 錯誤四分類；基礎設施故障不碰 `ImportBatch` |
| 5 | 事件與狀態不同交易 | 事件併入結果交易 |

## 關鍵設計

**`claim_token` 才是 fencing token。** 只比對 `claimed_by` 不是真正的 fencing——
worker ID 被重用時，舊 worker 恢復後可能誤用新租約。每次認領產生新 UUID；
心跳、完成、失敗寫回一律比對 `job_id ＋ claim_token ＋ lease_expires_at > now()`。

**Job 在上傳交易中建立**（不是認領時）。否則會留下「批次已 UPLOADED → 崩潰 →
job 從未建立 → 永遠沒人處理」，與原本的卡住問題等價。

**冪等鍵是結構化唯一約束**：`UNIQUE (job_type, subject_id, subject_version, rule_version)`；
`idempotency_key` 為其 canonical hash，屬推導值。衍生資料另補三條自然唯一性
（`source_dataset`／`data_coverage` 原本沒有 `batch_version`，本刀補上並回填）。

**錯誤四分類**：`BUSINESS_VALIDATION`（立即隔離，不重試）／`RETRYABLE_INFRASTRUCTURE`
（退避重試，批次維持 UPLOADED）／`NON_RETRYABLE_SYSTEM`（FAILED，人工處理）／
`LEASE_LOST`（舊 worker 完全停手，不得改任何狀態）。未知例外預設為可重試——
寧可留下 FAILED 的工作紀錄，也不要偽造一筆業務拒絕。

**`VALIDATING` 成為交易內狀態**：`UPLOADED → VALIDATING → VALIDATED/QUARANTINED`
（三個狀態、兩次遷移）全在同一交易，外部觀察不到。「批次卡在 VALIDATING」
**結構性消失**，而不是靠租約回收補救。

## 實作期間發現的兩個問題

1. **`max_attempts` 設定未被套用**：worker 從資料列讀 `max_attempts`，但 API 建立 job
   時沒寫該欄，DB 用預設 5——`JOB_MAX_ATTEMPTS` 環境變數完全無效。已改為建立時寫入
   `config.jobMaxAttempts`。此問題由測試發現（期望 3 次、實際 5 次）。
2. **G-01 不平衡走 `commitResult` 的隔離分支，未記錄 `last_error_class`**：
   行為正確但診斷不一致（同為業務裁決，走不同路徑卻只有一條有分類）。已補齊。

另有一個 SQL 錯誤（`ds.id` 不能在 `VALUES` 清單內引用）在自測時被攔下——
值得記錄的是**它的失敗處置是對的**：分類為可重試、批次維持 UPLOADED、退避後重試，
沒有變成假的 QUARANTINED。

## 測試

**288/288，EXIT=0**（單元 38、DB 整合 116、端到端 134＝20＋25＋62＋27）。
既有 227 條在 worker 全面改寫後零退化。

租約參數可經環境變數覆寫（`JOB_LEASE_SECONDS`／`JOB_HEARTBEAT_SECONDS`／
`JOB_MAX_ATTEMPTS`／`JOB_BACKOFF_SECONDS`），測試用 3 秒租約與 1 秒退避。

## 2026-08-04 走查

| # | 操作 | 結果 |
|---|---|---|
| 1 | 上傳（無 worker） | 批次 UPLOADED、工作 QUEUED attempts=0 |
| 2 | 啟動 worker | 正常完成（快到來不及 kill——真正的 SIGKILL 測試在驗收測試內） |
| 3 | 模擬已死 worker（RUNNING ＋ 租約過期 ＋ 陌生 token） | 批次仍 UPLOADED，**未卡在 VALIDATING** |
| 4 | 診斷 API | `stalled_count=1`，列出 `claimed_by=dead-worker#999`、租約時間、`attempts=1/3` |
| 5 | 啟動新 worker | 自動重領 → VALIDATED／MATCHED，attempts=2，新認領者 |
| 6 | 重領後來源事實 | ledger_line=2、dataset=1、coverage=1、assessment=1（**無重複**） |
| 7 | 全庫 VALIDATING 批次 | 0 |
| 8 | 稽核事件 | uploaded → identity_assessed → validated |

## 明確未做

每租戶並行上限與優先序、BullMQ／Redis、階段性進度、診斷畫面（本刀只做 API）、
`mapping_rule` 事件原子化（BACKLOG）。

**下一刀**：`SLICE-M2-02B PREVIEW CalculationRun ＋ CalculationInputManifest`。

## 2026-08-05 關閉章節（逐行審查四項修正）

上方「已完成」寫於首輪測試全綠之後；使用者逐行審查另發現四項缺口——
**測試全綠不等於封住**。已全部修正，切片自此正式關閉。

| # | 缺口 | 修正 |
|---|---|---|
| ① | `recordJobFailure()` 未驗 `lease_expires_at > now()`，也未斷言影響列數——租約到期後仍可寫回失敗狀態 | 失敗寫回加入租約有效條件並以 `RETURNING` 斷言列數；0 列＝租約已失，記 log 放棄、不改任何狀態，交由下一個認領者處理 |
| ② | `commitResult()`／`commitBusinessRejection()` 的 fencing 用 `SELECT EXISTS` 未取列鎖——檢查通過後租約到期、他人重領，寫入可交錯 | `fenceSql` 改為 CTE ＋ `FOR UPDATE`：job 列鎖至 COMMIT，競爭者的 `SKIP LOCKED` 認領在交易結束前拿不到列（雙 session 列鎖測試驗證） |
| ③ | `fn_background_job_guard()` 同狀態提前返回——`RUNNING→RUNNING` 到期重領完全繞過認領檢查（新 token、attempt_count 遞增） | migration **0011**：同狀態捷徑僅限非重領欄位更新（心跳）；重領必走完整認領檢查，且**活租約不可被搶**（舊租約未到期即拒絕） |
| ④ | `packages/domain/src/backgroundJob.ts` 冪等鍵分隔符為**原始 NUL byte**，整檔被 git 視為二進位 | 改為六字元跳脫序列（同一字元，雜湊不變——以修正前後同輸入向量釘死）；檔案恢復為文字 |

**過程中另發現並修復**：`scripts/dev.mjs` 只攔 SIGINT，`kill` 送 SIGTERM 時子行程變殭屍——
一個拉取前舊程式碼的殭屍 worker 持續搶測試批次並以舊邏輯寫入（缺 `batch_version` →
假隔離）。已補 SIGTERM 處理；這也再次驗證 README「跑測試前先停 dev」警語的必要性。

**測試 288 → 299（單元 39、DB 整合 126、端到端 134），全綠。**
下一刀維持：`SLICE-M2-02B PREVIEW CalculationRun ＋ CalculationInputManifest`。

### 2026-08-05 補遺（關閉章節後的兩項收尾）

1. **`/admin/jobs` 補 R6 角色閘**：原先只驗登入——租戶內任何使用者都能讀租約、
   認領者與失敗原因。診斷屬技術維運資料，依 §24.6 權限矩陣掛 **R6 系統管理員**
   （租戶層角色；種子新增「系管丁」）。無 R6 → 403 ＋ `ControlViolationAttempt`。
2. **SIGKILL 驗收改為確定性 crash-reclaim**：原寫法允許 `wasRunning === COMPLETED`
   （worker 太快，crash 段可能整段沒執行），且「重領」斷言實為恆真的
   `attempt_count >= 1`。改以 SQL 構造「已認領但從未提交」的死 worker 狀態
   （即 SIGKILL-after-claim 的語意），嚴格斷言 `attempt_count = 2` 且認領者易主。

**測試 299 → 301（端到端 136），全綠。**
