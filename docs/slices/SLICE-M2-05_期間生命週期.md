# SLICE-M2-05　ReportingPeriod 期間生命週期（§25.8）

> 狀態：**定稿待實作**（走查一輪後收緊）。

**範圍**：把 `PeriodRevision` 的狀態機由目前的四值簡化擴為 §25.8 的**完整語意**，
並讓已有控制證據的遷移真正由期間狀態驅動；尚無守衛的遷移一律 **fail closed**。

**基線對應**：§25.8（L805-819）、§25.13 守衛表（G-02／G-03／G-04／G-05／G-06／
G-07／G-09／G-10）、§26.10 `ReviewerEligibilityEvaluation`（L1366）、
§27 M7 `attemptTransition(object, to_state, actor)`——**所有守衛條件的唯一裁決點**（L1531）。

核心價值驗證：**期間狀態不再是裝飾欄位，而是「這一期現在能做什麼」的唯一權威；
守衛未實作等於不得通過，不是預設放行。**

## 現況缺陷（實查）

| # | 事實 | 影響 |
|---|---|---|
| 1 | `period_revision.status` 的 CHECK 只允許 `SETUP／OPEN／LOCKED／REOPENED` | **`OPEN→LOCKED` 簡化已寫進 DB**，與 §25.8 的 13 狀態不符 |
| 2 | 無任何期間狀態遷移守衛函式 | 狀態可任意跳關，無最後防線 |
| 3 | 應用層完全不驅動期間狀態 | G-02 通過只寫 DomainEvent（M2-01 的暫掛）；調整批准、CalculationRun、證據包都不改期間狀態 |
| 4 | `participation_event`／`period_composition`／`approval`／`reviewer_eligibility` 表皆不存在 | G-06 與 `AWAITING_REVIEWER` 的判定依據缺席 |

## 本刀實作邊界

```
SETUP → OPEN → IN_PREPARATION → IN_REVIEW → ADJ_APPROVED
                                    ↕
                            AWAITING_REVIEWER
```

DB **接受完整 13 個狀態值**（少一個就等於在 DB 層重新定義基線狀態機），
但 `CALCULATING` 之後的所有遷移 **fail closed**。

## 凍結的設計語意

### 1　守衛未實作 ≠ 守衛通過

| 守衛 | 現況 | 本刀處置 |
|---|---|---|
| G-02 映射覆蓋率 | **底層控制證據已存在（單批次判定），期間級聚合判定尚未實作** | 本刀實作期間級聚合，驅動 `IN_PREPARATION → IN_REVIEW` |
| G-04／SOD-01 | **底層為單筆 Adjustment 守衛，期間級聚合尚未實作** | 本刀實作「全期逐筆成立」聚合 |
| G-05／SOD-02 | **同上，單筆守衛已存在，期間級聚合尚未實作** | 本刀實作，驅動 `IN_REVIEW → ADJ_APPROVED` |
| G-10 前期已 LOCKED 且期初已銜接 | 無期初銜接概念 | 非首期 `SETUP → OPEN` **fail closed** |
| G-07 匯率版本凍結 | 折算屬 MVP 3 | `ADJ_APPROVED → CALCULATING` **fail closed** |
| G-03 B 基礎 | 無遞延稅模型 | `RECONCILING → PENDING_PKG_APPR` **fail closed** |
| G-06 參與者去重 ≥ 2 | 無 `ParticipationEvent` | `PENDING_PKG_APPR → LOCKED` **fail closed** |
| G-09 控制總額 | 無 `ExportJob` | `LOCKED → DELIVERED` **fail closed** |

**不得把「底層有單點控制」說成「期間守衛已完成」。** G-02 目前是單批次判定，
G-04／G-05 是單筆調整守衛；期間級要的是「全期所有物件皆成立」的聚合結論，
那是本刀要新寫的東西。

**fail closed 的範圍**：`ADJ_APPROVED → CALCULATING` **以及其後所有主線遷移**均 fail closed。
不可讀成「允許進入 `CALCULATING`、只是之後不能走」——`CALCULATING` 本身就進不去。

**穩定代碼必須可解析，不得只存在於中文文案。** DB 例外訊息一律以固定前綴開頭：

```
G07_NOT_IMPLEMENTED: 匯率版本守衛尚未實作，ADJ_APPROVED → CALCULATING 在本版不可用
G10_NOT_IMPLEMENTED: …
G03_NOT_IMPLEMENTED: …   G06_NOT_IMPLEMENTED: …   G09_NOT_IMPLEMENTED: …
```

API 以**前綴**擷取代碼，統一轉成 **409 ＋ `x-error-code`**；
**不得依中文文案判斷**（文案會改，代碼不會）。訊息本文仍須明白寫出
「此守衛尚未實作，因此此遷移在本版不可用」，避免日後被誤讀為「已驗證通過」。

### 2　「首期」以顯式欄位保存，不得推導

`SETUP → OPEN` 的非首期須通過 G-10，因此「是不是首期」必須是**可信的既存事實**。
**不得**用「目前最早日期的期間」推導——日後補進歷史期間，同一筆資料的判定結果會改變，
等於讓過去的通過紀錄被追溯翻案。

```
reporting_period.is_initial_period  boolean NOT NULL DEFAULT false
```

建立期間時明確保存，並以 **DB 唯一約束**強制，不能只靠 UI 宣告：

```sql
CREATE UNIQUE INDEX reporting_period_initial_uq
  ON reporting_period (reporting_unit_id, fiscal_calendar_id)
  WHERE is_initial_period;
```

`is_initial_period = false` 時，G-10 尚未實作 → `SETUP → OPEN` 一律拒絕。

⚠️ **與基線的已知偏差（實查）**：基線 §26 L1120 定義 `CalendarUsage (calendar_id,
reporting_unit_id, purpose)`，`purpose = LOCAL_STATUTORY／GROUP_REPORTING／TAX`，
但**現行 schema 沒有 `CalendarUsage`，`fiscal_calendar` 也沒有 purpose 欄**。
因此本刀的唯一約束只能落在 `(reporting_unit_id, fiscal_calendar_id)`，
**無法限定 GROUP_REPORTING**。`CalendarUsage` 落地後，此約束必須收窄為
「同一 ReportingUnit × GROUP_REPORTING Calendar 只能有一個首期」。已記入後續驗收。

另注意：`reporting_period.period_kind` 已有 `REGULAR／OPENING／ADJUSTMENT`。
**`OPENING` 不等於 `is_initial_period`**——前者是期間種類（期首期間），
後者是「本單位在此曆別下的第一期」。兩者不得混用。

### 3　`OPEN` 的離開條件

同一 `period_revision_id` 下**至少一份**批次滿足全部三項：

```
import_batch.status = 'ACCEPTED'
DataCoverage.granularity = 'BALANCE'
DataCoverage.completeness_status = 'COMPLETE'
```

「至少一份 ACCEPTED」太寬——只有附件或 JOURNAL 粒度的批次也會讓期間通過。
本條明確代表 **MVP 目前只要求完整 TB**，且**沒有假裝「必要資料政策」已經存在**；
未來由版本化的 `RequiredDataPolicy` 取代本收窄。

可行性已實查：`COMPLETE` 由提供者在 TB 檔案內以 `#completeness=COMPLETE` 顯式聲明，
該聲明受 file hash 涵蓋（02C「完整度不推定」）。worker 不推定、不由 G-01 平衡反推。
因此本條件今天即可達成，不需新增宣告 UI。

### 4　遷移角色與 `AWAITING_REVIEWER` 的進入方式

| 遷移 | 發起角色 |
|---|---|
| `SETUP → OPEN` | R4 |
| `OPEN → IN_PREPARATION` | R2 |
| `IN_PREPARATION → IN_REVIEW` | R2 發起 |
| `IN_REVIEW → ADJ_APPROVED` | R4 |
| `AWAITING_REVIEWER → IN_REVIEW` | R2 重新發起評估 |

**`AWAITING_REVIEWER` 不是使用者可直接選擇的目標狀態。** R2 請求進入 `IN_REVIEW` 時，
由 DB 評估覆核範圍是否完整覆蓋，再決定實際落點：

```
R2 請求 IN_REVIEW
   ├─ 覆蓋成立   → 實際進 IN_REVIEW
   └─ 覆蓋不成立 → 實際進 AWAITING_REVIEWER（並保存當次 Evaluation）
```

**零調整期間視為覆蓋完整**：期間沒有任何待覆核 Adjustment 時，覆核範圍為空集合，
應直接進 `IN_REVIEW`，不得卡進 `AWAITING_REVIEWER`。
零調整期間的兩人參與控制屬 G-06，留給後續。

### 5　`ReviewerEligibilityEvaluation`（最小版）

| 內容 | 說明 |
|---|---|
| 表頭（不可變） | `period_revision_id`、`evaluated_at`、`policy_version` |
| 候選人角色指派快照 | 評估當時的 `role_assignment`，不是事後查詢現況 |
| 每筆待覆核 Adjustment × 候選人 | `eligible`、`exclusion_reason`（如 SOD-01 自我覆核） |
| 覆蓋結論 | 是否**完整覆蓋**全部待覆核物件 |

重新評估**建立新 Evaluation**，不修改舊紀錄。判定：

```
完整覆蓋      → IN_REVIEW
無法完整覆蓋  → AWAITING_REVIEWER
人員或指派改變 → 重新評估，通過才回 IN_REVIEW
```

評估的是**範圍是否被完整覆蓋**，不是平面的人員清單（§26.10）。

### 6　`attemptTransition`：DB 為唯一權威

§27 M7 明定所有守衛條件的唯一裁決點。**不在 TypeScript 與 DB 各寫一套**——
同一規則寫兩次就會有一次寫錯（02A 缺口 2 的教訓）。

```
DB 期間遷移函式／觸發器  = 唯一裁決者（含所有聚合判定與 fail closed）
API                      = 呼叫它，把 DB 的穩定機器代碼映射為 HTTP 狀態＋CVA 留痕
domain（TypeScript）     = 只保留型別與顯示文案，不做裁決
```

這也正好建立 BACKLOG P2「DB 守衛例外 → HTTP 狀態統一映射」所要的模式。

### 7　本刀只保留狀態值、不實作進出路徑者

- **`PREVIEW_ONLY`**：只保留狀態值與未來語意。**現有預覽包不得被迫改寫期間狀態。**
- **`REOPENED`**：本刀不實作。未來重開必須**建立新的 `PeriodRevision` 列、
  `revision_no + 1`**，不得原地修改舊列——舊 revision 必須完整保留且仍可重演。

兩者本刀只驗「不得被任意跳入」。

## 驗收清單

| # | 條件 | 驗證位置 |
|---|---|---|
| 1 | `period_revision.status` 接受 §25.8 全 13 值；既有四值資料原地相容 | DB 整合 |
| 2 | 非法遷移一律拒絕（跳關、回頭、終態復活） | DB 整合 |
| 3 | `SETUP → OPEN`：`is_initial_period=true` 可通過；**false 一律 fail closed**（`G10_NOT_IMPLEMENTED:`）。唯一約束確保同一 ReportingUnit × Calendar 只能有一個首期 | DB 整合＋端到端 |
| 4 | `OPEN → IN_PREPARATION`：須有 ACCEPTED ＋ BALANCE ＋ COMPLETE 的批次；僅 ACCEPTED 但 `completeness_status` 為 UNKNOWN／PARTIAL 時拒絕 | DB 整合＋端到端 |
| 5 | `IN_PREPARATION → IN_REVIEW`：期間級 G-02 聚合；任一批次有未映射餘額即拒絕 | DB 整合＋端到端 |
| 6 | `IN_REVIEW → ADJ_APPROVED`：全期調整皆 APPROVED 且逐筆 G-04／G-05 成立 | DB 整合＋端到端 |
| 6b | 遷移角色：`SETUP→OPEN` R4、`OPEN→IN_PREPARATION` R2、`IN_PREPARATION→IN_REVIEW` R2、`IN_REVIEW→ADJ_APPROVED` R4、`AWAITING_REVIEWER→IN_REVIEW` R2；角色不符即拒絕並留痕 | DB 整合＋端到端 |
| 6c | **`AWAITING_REVIEWER` 不可由使用者直接指定為目標狀態**；只能由「R2 請求 IN_REVIEW」時的 DB 覆蓋評估決定落點 | DB 整合＋端到端 |
| 6d | **零調整期間視為覆蓋完整**：無待覆核 Adjustment 時 R2 請求 IN_REVIEW 直接進 `IN_REVIEW`，不得卡進 `AWAITING_REVIEWER` | DB 整合＋端到端 |
| 7 | **`ADJ_APPROVED → CALCULATING` 以及其後所有主線遷移均 fail closed**（`CALCULATING` 本身即進不去）；錯誤以 `Gxx_NOT_IMPLEMENTED:` 固定前綴回傳，API 以前綴擷取代碼、不依文案判斷 | DB 整合＋端到端 |
| 8 | `PREVIEW_ONLY`／`REOPENED` **不得被任意跳入**；現有預覽包與證據包流程不改變期間狀態 | DB 整合＋端到端 |
| 9 | 覆核人無法完整覆蓋 → `AWAITING_REVIEWER`；**不改變 `revision_no`**；保存當次 Evaluation | DB 整合＋端到端 |
| 10 | 覆核人到位後重新評估 → 回 `IN_REVIEW`；**舊 Evaluation 不可變、新增一筆** | DB 整合 |
| 11 | 期間狀態遷移與 DomainEvent 同一交易 | 端到端 |
| 12 | API 把 DB 機器代碼映射為 HTTP 狀態（非 500）＋ CVA 留痕 | 端到端 |
| 13 | 跨租戶／跨案件期間不可見不可寫（INV-18／§24.1A） | DB 整合 |
| 14 | 既有 520 條零退化 | 全套 |

## 後續驗收（不在本刀）

- `PREVIEW_ONLY` 的進出路徑：非終態、可回流、不建立交付紀錄、不計入完成度。
- `REOPENED`：建立新 `PeriodRevision`（`revision_no+1`）、舊 revision 不可變且可重演、
  已交付者通知母公司與已授權審計師。
- `CALCULATING` 之後各段：待 G-07／G-03／G-06／G-09 各自的能力就緒。
- `CalendarUsage` 落地後，首期唯一約束須由 `(reporting_unit_id, fiscal_calendar_id)`
  收窄為「同一 ReportingUnit × **GROUP_REPORTING** Calendar 只能有一個首期」。

## 明確不做

折算與匯率版本（MVP 3）、遞延稅／B 基礎、`ExportJob`／`DeliveryRecord` 正式交付、
期初銜接差異解釋、`PeriodCompositionVersion`、`RequiredDataPolicy` 版本化、
通知母公司與審計師的外部動作。
