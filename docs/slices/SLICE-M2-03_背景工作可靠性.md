# SLICE-M2-03　背景工作可靠性（技術前置，非新業務功能）

**範圍**：新增 `BackgroundJob` 非同步工作物件，讓匯入驗證在崩潰、租約逾時與重複派工下
都不產生錯誤或半套資料，並把 `import_batch` 的狀態遷移與 DomainEvent 原子化。

**不新增客戶業務功能**；新增內部管理用的診斷查詢（API／SQL）。
**畫面不在本刀**——診斷 UI 放後續，避免與「不新增使用者可見功能」自相矛盾。

**基線對應**：§27.4 L1620「非同步作業的共同要求：**具冪等鍵、可重試、失敗有明確終態與
人可讀原因、進度可查詢、不吞掉錯誤。任何非同步作業的失敗都不得讓業務物件停在中間狀態**」、
§27.5 L1627-1628（冪等與逾時契約）、ADR-04（獨立 worker 進程＋佇列）、
D-25-06（正交屬性不進主狀態機）。

核心價值驗證：**worker 在任何一步被 kill，批次都不會永久卡住、不會被誤判為業務拒絕，
重啟後自動恢復，且不產生重複的來源事實。**

## 目前的實際缺陷（`apps/worker/src/worker.ts`）

| # | 缺陷 | 後果 |
|---|---|---|
| 1 | `claim()` 只是 `UPDATE status='VALIDATING'`，無租約、無 worker 識別 | 認領後崩潰即**永久卡住**，無人能重領 |
| 2 | `processBatch()` 跨多次 `exec` 寫 dataset／ledger_line／coverage／assessment | 中途崩潰留下**半套來源事實**；這些表不可變（`trg_sll_immutable`），清不掉 |
| 3 | 無租約即無安全重領；一旦加上重領，第 2 點會**複製**來源事實 | 重領、交易化與冪等鍵必須一起做 |
| 4 | `catch (e) { quarantine(b, ...) }` 把**任何**例外都判為 QUARANTINED | 基礎設施故障被記成業務裁決，產生假的「不予接受」，且依基線 QUARANTINED 後須重傳新批次——DB 瞬斷不該逼客戶重新上傳同一份檔案 |
| 5 | worker 的 `audit()` 與狀態遷移分屬不同交易 | 與 02A 修正前同一問題：狀態已前進而事件不存在 |

## 凍結的設計語意

### 1　BackgroundJob：非同步工作有自己的狀態

凍結的是 `ImportBatch.status` 七狀態，**不是禁止非同步工作擁有自己的狀態**。

```
BackgroundJob
├─ job_id
├─ job_type          = IMPORT_VALIDATION
├─ subject_id        = import_batch_id
├─ subject_version   = import_batch.batch_version
├─ rule_version      = detection_rule_version
├─ idempotency_key   （上列四欄的 canonical hash——推導值，非另一個真相來源）
├─ status            = QUEUED | RUNNING | RETRY_WAIT | COMPLETED | FAILED
├─ claimed_by        （診斷用）
├─ claim_token       （寫入權威）
├─ claimed_at / lease_expires_at / next_attempt_at
├─ attempt_count / max_attempts
├─ last_error_class / last_error_message
└─ created_at / updated_at / completed_at / failed_at

UNIQUE (job_type, subject_id, subject_version, rule_version)
```

這同時滿足「ImportBatch 不停在中間狀態」與「失敗有明確 FAILED 終態」。

**冪等鍵是結構化唯一約束，不是字串相加。** 四個欄位各自保存並建複合 UNIQUE；
`idempotency_key` 為其 canonical hash，只作為對外識別與稽核用的推導值，
不得被獨立填寫或當成第二個真相來源。

### 1b　Job 必須在上傳交易中建立

若 job 在「認領時」才建立，會留下這條路徑：`ImportBatch` 已 UPLOADED → 程式崩潰
→ job 從未建立 → **永遠沒人處理**。這與原本的卡住問題等價，只是換了個位置。

```
上傳交易（單一交易）：
  建立 ImportBatch／SourceDocument
  DRAFT → UPLOADED
  建立 BackgroundJob(QUEUED)
  寫 import_batch.uploaded DomainEvent
  COMMIT

worker：
  QUEUED／到期工作 → RUNNING
```

`ImportBatch`、`BackgroundJob` 與 `uploaded` 事件三者必須同交易。

**認領條件**：

```sql
status = 'QUEUED'
OR (status = 'RETRY_WAIT' AND next_attempt_at <= now())
OR (status = 'RUNNING'    AND lease_expires_at <= now())   -- 租約逾時，安全重領
```

### 2　claim_token 才是 fencing token

`claimed_by + lease_expires_at` **不是真正的 fencing**：worker ID 被重用時，
舊 worker 恢復後可能誤用新租約。每次認領產生新的 `claim_token`（UUID）。

heartbeat、完成與失敗寫回**一律**比對三者並斷言影響一列：

```sql
WHERE job_id = :job AND claim_token = :token AND lease_expires_at > now()
```

`claimed_by` 只留作診斷。

### 3　單一交易解決「不留半套」，冪等鍵解決「不產生第二份」

兩者不可互相取代（§27.4 明文要求冪等鍵）。

冪等鍵見 §1：`UNIQUE (job_type, subject_id, subject_version, rule_version)`。
衍生資料另補自然唯一性：

```
source_dataset             UNIQUE (import_batch_id, batch_version, granularity)
data_coverage              UNIQUE (import_batch_id, batch_version, granularity, account_scope)
source_identity_assessment UNIQUE (import_batch_id, batch_version, detection_rule_version)
```

⚠️ `source_dataset` 與 `data_coverage` **目前沒有 `batch_version` 欄位**，
須先補欄位（由 `import_batch.batch_version` 回填）才能建這兩條 UNIQUE。
`source_identity_assessment` 已有 `batch_version` 與 `detection_rule_version`，可直接建。

「單一交易」指**全部 DB 效果**。讀物件、CSV 解析與雜湊計算在交易外完成。

### 4　執行流程

```
認領 job（RUNNING ＋ claim_token）      ImportBatch 保持 UPLOADED
        ↓
讀物件 → 解析 CSV → 計算（交易外，無 DB 效果）
        ↓
最終單一交易：
  驗證 claim_token 仍有效（否則整批放棄）
  UPLOADED → VALIDATING
  寫入全部來源事實
  VALIDATING → VALIDATED 或 QUARANTINED
  寫 DomainEvent
  job → COMPLETED
```

基礎設施故障：資料交易回滾 → **ImportBatch 仍為 UPLOADED** → job 轉 `RETRY_WAIT`
→ 重試耗盡 → job `FAILED`，**ImportBatch 不進 QUARANTINED**。

### 5　錯誤四分類

| 類別 | 處置 |
|---|---|
| `BUSINESS_VALIDATION` | 立即 QUARANTINED（雜湊不符、G-01 不平衡、身分 CONFLICT、解析失敗） |
| `RETRYABLE_INFRASTRUCTURE` | 退避重試；ImportBatch 保持 UPLOADED |
| `NON_RETRYABLE_SYSTEM` | job FAILED，人工處理；ImportBatch 保持 UPLOADED |
| `LEASE_LOST` | 舊 worker 立即停止寫入，**不得改任何業務狀態、也不得改 job 狀態**（新持有者才有權） |

### 6　凍結的具體參數

| 參數 | 正式預設 | 理由 |
|---|---|---|
| 租約長度 | 60 秒 | 遠大於單批處理時間，又能讓崩潰在一分鐘內被回收 |
| heartbeat 間隔 | 20 秒 | 租約長度的 1/3，容得下一次漏跳 |
| `max_attempts` | 5 | **首次執行 ＋ 4 次重試** |
| 退避 | 5s → 15s → 45s → 135s | 指數退避，總等待 < 4 分鐘 |

**測試環境必須可覆寫這四個參數**（經 `.env.local`／環境變數）。驗收的是比例、狀態
與行為，不是讓測試真的等四分鐘；kill／到期／重領測試在正式參數下會慢到無法執行。

## 一個必須明說的後果：VALIDATING 不再可觀察

上述流程把 `UPLOADED → VALIDATING → VALIDATED/QUARANTINED`（三個狀態、**兩次遷移**）
收進同一交易，因此 **`VALIDATING` 成為交易內的瞬時狀態，外部永遠查不到**。

§25.5 的狀態機本身仍被完整遵守（兩次遷移都真實發生、都過守衛），改變的只是可觀察性。
進度可觀察性移到 `BackgroundJob.status`（`RUNNING`／`RETRY_WAIT`），
這正是 §27.5 L1637 把可觀測性放在工作器契約裡的位置。

職責分工因此變得乾淨：

    ImportBatch.status    = 業務結果狀態
    BackgroundJob.status  = 非同步執行進度

它讓「批次卡在 VALIDATING」這個問題**結構性消失**，而不是靠租約回收去補救；
基礎設施故障也不再污染 `ImportBatch`。代價是 B-00 不會再出現 VALIDATING 徽章。

決定與後續指引記於 `docs/adr/ADR-M2-002.md`。

## 驗收清單

| # | 條件 | 驗證位置 |
|---|---|---|
| 1 | **上傳交易**同時建立 `ImportBatch`(UPLOADED)、`BackgroundJob`(QUEUED) 與 `uploaded` 事件；三者同進同出，不存在「已 UPLOADED 但無 job」的批次 | DB 整合＋端到端 |
| 2 | 認領將 job 轉 RUNNING 並產生新的 `claim_token`；`ImportBatch` 保持 UPLOADED | DB 整合 |
| 3 | 租約未到期時，第二個 worker 不得認領同一 job；`RETRY_WAIT` 且 `next_attempt_at` 未到亦不得認領 | DB 整合 |
| 3b | 租約到期後可安全重領，`attempt_count` 遞增，且產生**不同**的 `claim_token` | DB 整合 |
| 4 | **Fencing**：持舊 `claim_token` 的寫回被拒絕並整批回滾（即使 `claimed_by` 相同） | DB 整合 |
| 5 | heartbeat 延長租約；持舊 token 的 heartbeat 無效 | DB 整合 |
| 6 | `UNIQUE (job_type, subject_id, subject_version, rule_version)`：同一批次同一版本同一規則版本不得建立第二個 job；`idempotency_key` 為推導值且與四欄一致 | DB 整合 |
| 6b | `next_attempt_at` 可保存可查詢；退避序列 5→15→45→135（比例正確即可，測試環境縮短） | DB 整合＋端到端 |
| 7 | 三條衍生資料 UNIQUE 生效：重複寫入被 DB 拒絕 | DB 整合 |
| 8 | 全部 DB 效果單一交易：中途失敗後四張來源事實表均為零列，且 `ImportBatch` 仍為 UPLOADED | 端到端 |
| 9 | **重領不產生重複來源事實**：重領處理後 `source_ledger_line` 筆數與單次處理相同 | 端到端 |
| 10 | **worker 被 kill 後重啟自動恢復**：批次不停在中間狀態，最終達成 VALIDATED／QUARANTINED | 端到端 |
| 11 | `RETRYABLE_INFRASTRUCTURE`：退避重試，`ImportBatch` 全程保持 UPLOADED，**不得** QUARANTINED | 端到端 |
| 12 | 重試耗盡：job → `FAILED` 且有人可讀原因；`ImportBatch` **仍為 UPLOADED**，客戶不需重新上傳 | 端到端 |
| 13 | `BUSINESS_VALIDATION`（雜湊不符／G-01 不平衡／身分 CONFLICT）**立即** QUARANTINED，不重試 | 端到端 |
| 14 | `LEASE_LOST`：舊 worker 不得改業務狀態，也不得改 job 狀態 | DB 整合＋端到端 |
| 15 | `import_batch` 狀態遷移與 DomainEvent 同一交易；事件插入失敗則狀態回滾 | 端到端 |
| 16 | 診斷查詢：可列出逾時未完成的 job 及其 `claimed_by`、`claimed_at`、`lease_expires_at`、`attempt_count`、`last_error_class`／`message`（**API／SQL，不做畫面**） | DB 整合＋API |
| 17 | 既有 227 條測試全數不退化（七狀態語意、G-01／INV-28、`identity_status` 正交軸不變） | 全套 |

## 明確不做（切片收窄，**不是**修改基線）

1. **每租戶並行上限與優先序**（§27.5 L1634-1635）：本切片只有單一 worker 與單一
   `job_type`，不實作。
2. **BullMQ／Redis 佇列**：維持 ADR-LOCAL-001 的 Postgres `FOR UPDATE SKIP LOCKED`。
3. **階段性進度**（§27.5 L1637）：本刀只做 job 層級狀態，不做「卡在讀取／映射／規則哪一步」
   ——後者屬 CalculationRun。
4. **診斷畫面**：本刀只做診斷 API／查詢。
5. **`mapping_rule` 的事件原子化**：已獨立記入 BACKLOG，不在本刀。

## 部署注意

現行 DB 若已有停在 `VALIDATING` 的批次（本機目前為 0 筆），新流程不會再產生這種列，
但既有列不會自動消失，需要一次性人工處置。正式環境部署前應確認並記錄。

**下一刀**（本切片通過後）：`SLICE-M2-02B PREVIEW CalculationRun ＋ CalculationInputManifest`。
