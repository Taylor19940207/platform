# SLICE-M3-04　現金流支持資料（REQ-CFS-001）

> 狀態：**事前契約 第四版（走查三輪修訂後）**，待確認。**尚未批准進 migration。**
> 風險：**第一級**（母公司批准的方法版本、完整度判定、控制總額勾稽、凍結與重演）。
>
> 對應基線：手冊 v1.2 **REQ-CFS-001（P0）**、§20 MVP 3、§299–301（資料粒度）；
> 設計書 v1.1 **GB-04**（收集 vs 重建）、§26.11 `CashFlowClass`、§25.13 G-09、
> INV-23（粒度不足不得自動執行）、D-26-03。
> 前置：`SLICE-M3-02`／`SLICE-M3-03`（皆 CLOSED／PASS）。

## 一、邊界：P0 是**支持資料**，不是現金流量表

GB-04 寫得很清楚：**P0 僅保存母公司確認的方法與粒度，並收集、映射支持資料；
直接法重建屬 P1（REQ-CFS-101），且重建結果永遠標示為「建議」。**

因此本刀的產出是**可被母公司系統或 Excel 使用的支持資料包**，不是報表：

| 做 | 不做 |
|---|---|
| 保存母公司批准的方法／粒度／證據版本 | **不產生完整合併現金流量表** |
| `CashFlowClass` 主檔與版本 | **不做直接法重建**（REQ-CFS-101，P1） |
| 科目／分錄／必要明細 → `CashFlowClass` 的映射 | **不自動識別非現金項** |
| 粒度不足時 fail closed 或走批准例外 | 不做分類建議引擎（GB-05：任何自動結果初始狀態一律是「建議」） |
| 必要分類的完整度判定 | 不做關係人現金流的自動抵銷 |
| 支持資料輸出與控制總額勾稽 | 不解鎖任何期間遷移 |
| 政策、映射、來源粒度與輸出結果的凍結與重演 | 不做 `OutputProfile`／正式交付包 |

> **本刀最容易越界的地方**：一旦系統開始「把未分類的金額歸到某一類」，
> 它就從收集變成重建。因此**沒有預設分類**——未映射就是未映射，
> 由完整度判定擋下，不由演算法補完。

## 二、母公司批准的方法與粒度：`CashFlowPolicyVersion`

現金流的方法（直接法／間接法）與粒度是**母公司的決定**，不是平台的推論
（§24.6：R4「決定輸出與現金流粒度」）。

    CashFlowPolicyVersion
    ├─ engagement_id / reporting_unit_id
    ├─ method                 DIRECT | INDIRECT      母公司採用的列報方法
    ├─ required_granularity   BALANCE | JOURNAL | SUBLEDGER | DOCUMENT
    │                         支持資料所需的**最低**粒度；沿用 DataCoverage 的既有四值
    │                         （**不是** ACCOUNT——ACCOUNT 是 source_kind，對應 BALANCE）
    ├─ class_set_version_id   引用已批准的分類集合；**必要性只由集合的 is_required 定義**
    ├─ evidence_version       母公司確認文件的版本識別（外部證據）
    ├─ series_id / version_no / supersedes_policy_version_id
    └─ approved_by / approved_at    **案件層 R4**（system-only 函式）

- **必要分類不得在 Policy 與 ClassSet 各存一份**——兩份清單遲早分岔，
  而分岔時沒有非任意的方式決定哪一份算數。Policy 只引用 `class_set_version_id`。

- **`method` 與 `granularity` 都不得由平台推導**；未經 R4 批准的版本不得被使用。
- 版本鏈與不可改寫的規則沿用 M3-03（現行版本由**取代鏈**判斷，不按時間；
  不得從同一舊版分叉出兩個現行版本）。
- **`evidence_version` 必填**：母公司「確認了什麼」必須指得到一份外部文件，
  否則「已批准的方法」只是系統裡的一個字串。

## 三、`CashFlowClass` 主檔與版本

    CashFlowClassSetVersion            一次批准一整套分類（與權益 lot set 同理）
    ├─ engagement_id
    ├─ series_id / version_no / supersedes_set_version_id
    ├─ approved_by / approved_at       案件層 R4
    └─ CashFlowClass［］
       ├─ code / name
       ├─ kind              ACTIVITY | FX_EFFECT_ON_CASH（控制項，不屬三大活動）
       ├─ activity          OPERATING | INVESTING | FINANCING（kind = ACTIVITY 時必填）
       ├─ direction         INFLOW | OUTFLOW | EITHER
       └─ is_required       是否屬「必要分類」（§五）

    CashFlowCashAccountMembership          現金及約當現金的科目範圍
    ├─ class_set_version_id
    ├─ account_id
    └─ cash_role         CASH | CASH_EQUIVALENT

**現金範圍隨分類集合一起批准、凍結與重演，不放進 `Account`。**
不同母公司可能對同一科目有不同認定（尤其約當現金的三個月門檻），
`Account` 上的屬性表達不了「這是誰的口徑」。

- **以集合為批准與凍結單位**：單一分類的版本鏈證明不了「沒有漏掉一個必要分類」
  ——漏掉的那一個不存在，沒有版本鏈會指向它（與 `EquityTranslationLotSetVersion`
  同一個理由）。
- `activity` 三值是準則層的結構事實，不是可配置政策；`code` 由母公司決定。
- **不預先塞入任何預設分類集合**：分類是母公司口徑的一部分。
- **批准時的兩項最低要求**（否則等於批准了一個空集合）：
  1. 恰好**一個** `kind = 'FX_EFFECT_ON_CASH'` 的控制項目（多於一個或沒有皆拒絕）；
  2. 至少**一筆** `CashFlowCashAccountMembership`——沒有現金科目範圍，
     K1／K2 就沒有計算對象。

## 三之二、金額事實：`CashFlowSourceFact`

**目前的模型沒有「本期現金流金額」這個事實。** 現有的候選來源都不是：

| 來源 | 為什麼不是 |
|---|---|
| `Account` | 只是科目主檔，沒有本期金額 |
| `journal_line` | 平台的**調整分錄**，不等於匯入的現金流支持資料 |
| `source_document` | 有附件，沒有可勾稽的金額 |
| `source_ledger_line` | 多半是**期末 TB 餘額**——把餘額當成本期現金流，就是自行重建 |

若直接從這些產生 `CashFlowSupportLine.amount`，實作者只能現場決定怎麼算，
產品就從「收集支持資料」滑向「自行重建現金流」——正是 GB-04 禁止的那件事。

因此補上最小的金額事實：

    CashFlowSourceFact
    ├─ period_revision_id / reporting_unit_id
    ├─ source_dataset_id / import_batch_id
    ├─ actual_granularity        BALANCE | JOURNAL | SUBLEDGER | DOCUMENT
    ├─ source_kind               ACCOUNT | JOURNAL_LINE | SUBLEDGER_ITEM | DOCUMENT
    ├─ account_id
    ├─ source_ledger_line_id / source_document_id     依 source_kind **XOR**
    ├─ source_row_id             來源列識別（可追回原檔）
    ├─ signed_amount_functional / functional_currency
    ├─ signed_amount_reporting  / reporting_currency（可空；有 FX 時必填）
    ├─ evidence_ref
    └─ content_hash

**語意寫死（DB 強制）：**

1. **金額由提供者提交，或自明確的現金流支持資料集匯入；平台不從 TB 餘額
   自行推算。** 沒有 `CashFlowSourceFact` 就沒有現金流金額——不得由
   `source_ledger_line` 的餘額推導。
2. `CashFlowMappingRule` 決定 **`CashFlowSourceFact` 如何分類**（不是分類科目本身）。
3. `CashFlowSupportLine` 引用 **`source_fact_id` ＋ `mapping_rule_id`**，
   只做保存、分類與輸出，**不做任何金額運算**。
4. **K1／K2 使用這些已提交的 signed amount 勾稽，不反推缺失金額。**
5. `actual_granularity` 必須來自該 fact **所屬資料集**的 `DataCoverage`，
   不得逐列自填。

**帶正負號**（`signed_*`）而非借貸兩欄：現金流的方向是流入／流出，
用借貸表示會在「同一分類同時有流入與流出」時失去可加性。

## 四、映射：`CashFlowSourceFact` → `CashFlowClass`

    CashFlowMappingVersion
    ├─ engagement_id / policy_version_id      綁定方法與粒度版本
    ├─ series_id / version_no / supersedes_*
    ├─ approved_by / approved_at              R4 批准；R2 建立、R3 覆核（比照 MappingRule）
    └─ CashFlowMappingRule［］
       ├─ source_kind      ACCOUNT | JOURNAL_LINE | SUBLEDGER_ITEM | DOCUMENT
       ├─ source_ref       依 source_kind 的具體外鍵（不是可空 text，比照 0031）
       │                   規則比對的對象是 CashFlowSourceFact 的同名欄位
       ├─ cash_flow_class_id
       ├─ effective_from / effective_to       生效日（比照 MappingRule）
       └─ evidence_ref
- **粒度相容性由**同一支 DB 函式**判定**，不得在各處各寫一份排序：

      fn_granularity_satisfies(p_actual text, p_required text) → boolean
      序：BALANCE < JOURNAL < SUBLEDGER < DOCUMENT
      source_kind 的對應：ACCOUNT→BALANCE、JOURNAL_LINE→JOURNAL、
                          SUBLEDGER_ITEM→SUBLEDGER、DOCUMENT→DOCUMENT

  三條規則：
  1. **實際 `DataCoverage.granularity` 必須滿足政策的 `required_granularity`**；
  2. **映射規則的 `source_kind` 也必須被實際 `DataCoverage` 支持**；
  3. 政策要求 `JOURNAL` 時，**只有 ACCOUNT 層映射不算完整**；
     政策只要求 `BALANCE` 而實際取得 `JOURNAL` 時，**可以保留更細的來源**
     （更細不是錯，只有更粗才是）。
- **一對一，不做條件式映射**（沿用 SLICE-M2-01 的邊界；條件式在 BACKLOG）。
- 同一 `source_ref` 在同一生效期間內至多一條規則；重疊即拒絕
  （`CFS_MAPPING_AMBIGUOUS`）。

## 五、必要分類的完整度判定

「完整」不是「每一筆都有分類」，而是**母公司宣告的必要分類都拿得到資料**。

**「沒有資料」不等於「不完整」**：某個必要分類本期可能合法地為零活動。
逼它一定要有金額，會把零活動期間判成失敗，而使用者唯一的出路是造一筆假資料。
因此改為**逐期確認**：

    CashFlowClassPeriodCoverage
    ├─ period_revision_id / reporting_unit_id / policy_version_id
    ├─ cash_flow_class_id
    ├─ status    DATA_PRESENT              有已映射的 CashFlowSourceFact
    │            | ZERO_ACTIVITY_CONFIRMED 本期確認無活動（需確認人與理由）
    │            | COVERAGE_EXCEPTION      粒度不足，走已批准例外（§五之二）
    ├─ confirmed_by / confirmed_at         R2 確認；ZERO_ACTIVITY_CONFIRMED 時必填
    ├─ reviewed_by / reviewed_at           R3 覆核；ZERO_ACTIVITY_CONFIRMED 時必填
    └─ evidence_ref                        ZERO_ACTIVITY_CONFIRMED 時必填

**寫入權限逐狀態釘死：**

| status | 誰寫入 |
|---|---|
| `DATA_PRESENT` | **只能由系統依 `CashFlowSourceFact` 衍生**，不得人工宣告 |
| `ZERO_ACTIVITY_CONFIRMED` | 走 R2 確認 ＋ R3 覆核的 system-only 函式 |
| `COVERAGE_EXCEPTION` | 必須帶 `coverage_exception_id`，且引用**已批准的逐分類例外** |

`ZERO_ACTIVITY_CONFIRMED` 只有在 **R2 確認 ＋ R3 覆核 ＋ 理由與證據齊備**
三者同時成立時才算完整。**本刀不另造自然人互斥規則**——是否允許同一人兼
R2／R3，沿用既有的實例級控制政策，不在此新增 SoD。

    完整度判定（per period_revision × reporting_unit × policy_version）
    ├─ 每個 is_required 的 CashFlowClass 都有一筆 CashFlowClassPeriodCoverage，
    │  且 status 為上述三者之一
    ├─ 所有納入的來源事實都命中恰好一條映射規則
    └─ 粒度相容（§四的 fn_granularity_satisfies）

未達成時的穩定代碼：

| 代碼 | 意義 |
|---|---|
| `CFS_POLICY_NOT_APPROVED` | 未選定或未批准的方法版本 |
| `CFS_CLASS_SET_NOT_APPROVED` | 未選定或未批准的分類集合 |
| `CFS_MAPPING_NOT_APPROVED` | 未選定或未批准的映射版本 |
| `CFS_GRANULARITY_INSUFFICIENT` | 實際 `DataCoverage` 粒度低於政策要求（INV-23） |
| `CFS_UNMAPPED_SOURCE` | 有來源事實未命中任何映射規則 |
| `CFS_MAPPING_AMBIGUOUS` | 同一來源命中多條規則 |
| `CFS_REQUIRED_CLASS_UNCONFIRMED` | 必要分類既無資料、也未確認零活動、也無已批准例外 |
| `CFS_ZERO_ACTIVITY_UNCONFIRMED` | 標為零活動但缺確認人或證據 |

### 五之二、粒度不足：fail closed，或**批准例外**

INV-23 的原則是「粒度不足時不得自動執行」。但現金流常常真的拿不到 JOURNAL 粒度，
因此提供一條**顯式的例外路徑**（比照 G-02 的「已批准例外」）：

    CashFlowCoverageException
    ├─ period_revision_id / reporting_unit_id / policy_version_id
    ├─ cash_flow_class_id            例外的範圍（不得整期一次豁免）
    ├─ actual_granularity            實際取得的粒度
    ├─ reason / evidence_ref         必填
    └─ approved_by / approved_at     **案件層 R4**

- **例外必須逐分類申請**，不得「整期粒度不足一次豁免」——那等於取消判定。
- 有例外時，輸出的每一列必須標記 `coverage_exception_id`，
  **支持資料本身要看得出哪一段是在粒度不足下產生的**。
- 沒有例外且粒度不足 → `CFS_GRANULARITY_INSUFFICIENT`，**不產生輸出**。

## 六、支持資料輸出與控制總額勾稽

**拍板：沿用 `CalculationRun`，新增 `calculation_scope = 'CASH_FLOW_SUPPORT'`。**
產出用獨立的 `CashFlowSupportLine`，但**共用** Manifest、SHA-256、replay、
狀態與結果雜湊——不另建 `CashFlowSupportRun`，否則會出現第二份
「凍結與重演」實作。

    CalculationRun（calculation_scope = 'CASH_FLOW_SUPPORT'）
    └─ CashFlowSupportLine［］
       ├─ cash_flow_class_id / kind / activity
       ├─ source_fact_id          **金額的唯一來源**（不在此重算）
       ├─ mapping_rule_id         命中的分類規則
       ├─ signed_amount_functional / signed_amount_reporting（自 fact 原樣帶出）
       ├─ coverage_exception_id（可空）
       └─ period_revision_id / reporting_unit_id

**支持資料列不做金額運算**：`signed_amount_*` 一律自 `CashFlowSourceFact`
原樣帶出。這一條讓「收集」與「重建」在資料層就分得開——重建會需要一個
可以放推算結果的欄位，而這裡沒有。

### 六之一、權威來源的顯式選定

「前期已選定 run」目前只有 FX 有物件（`PeriodFxRunSelection`）；**NO_FX 沒有
對應的正式選定**，首期的「經批准的期初證據」也還沒有資料形狀。兩者都不能
留給實作臨場決定，否則又會退回「按時間找最新版」。

    PeriodCashFlowSourceSelection
    ├─ period_revision_id / reporting_unit_id
    ├─ current_run_id                  本期的來源 run（FX 或 NO_FX）
    ├─ opening_source_kind             PRIOR_SELECTED_RUN | FIRST_PERIOD_EVIDENCE
    ├─ prior_run_id                    PRIOR_SELECTED_RUN 時必填
    ├─ opening_balance_set_version_id  FIRST_PERIOD_EVIDENCE 時必填
    ├─ series_id / version_no / supersedes_selection_id
    └─ selected_by / selected_at       **案件層 R4**（system-only 函式）

規則（DB 強制）：
- **FX 情境**：`current_run_id` 必須**等於**現行 `PeriodFxRunSelection`
  所選定的 run——兩個選定不得各說各話。
- **NO_FX 情境**：由本物件明確選定，**不按時間找最新**。
- `PRIOR_SELECTED_RUN`：`prior_run_id` 必須是**顯式前期**
  （`reporting_period.previous_reporting_period_id`）的**已選定結果**。
- **首期只能用 `FIRST_PERIOD_EVIDENCE`**；非首期不得使用它。
- XOR：兩個來源欄位恰有一個非空。

首期的期初證據也用集合版本，理由與分類集合相同——單列的版本鏈證明不了
「沒有漏掉一個現金科目」：

    CashFlowOpeningBalanceSetVersion
    ├─ engagement_id / reporting_unit_id / period_revision_id
    ├─ series_id / version_no / supersedes_set_version_id
    ├─ evidence_ref                    必填
    └─ approved_by / approved_at       **案件層 R4**
    └─ CashFlowOpeningBalanceLine［］
       ├─ account_id
       ├─ functional_amount / currency
       └─ reporting_amount / reporting_currency（可空；有 FX 時必填）

整套一起批准、凍結與重演。否則「經批准的期初證據」仍只是一句話。

### 六之二、控制總額勾稽（G-09 的資料層對應物）

**現金的期初與期末來源必須凍結，不得臨時查詢：**

| 項目 | 來源 |
|---|---|
| 期初現金 | 依 `PeriodCashFlowSourceSelection.opening_source_kind`：前期已選定 run，或首期的已批准 `CashFlowOpeningBalanceSetVersion` |
| 期末現金 | `PeriodCashFlowSourceSelection.current_run_id` |
| 現金科目範圍 | 凍結的 `CashFlowCashAccountMembership`（隨分類集合） |

| # | 勾稽 | 判準 |
|---|---|---|
| K1 | **功能幣**：期初現金 ＋ 經營 ＋ 投資 ＋ 融資 ＝ 期末現金 | **不含**匯率變動影響 |
| K2 | **報告幣**：期初現金 ＋ 經營 ＋ 投資 ＋ 融資 ＋ **匯率變動對現金及約當現金的影響** ＝ 期末現金 | 只在引用 FX run 時檢查 |
| K3 | 每一列都追得到來源事實與映射規則 | `source_ref` 與 `mapping_rule_id` 皆非空 |
| K4 | 幣別一致 | 支持資料的幣別＝所引用 run 的功能幣；報告幣欄位僅在引用 FX run 時填寫 |

**`FX_EFFECT_ON_CASH` 是獨立的控制項，不是第四種活動。**
它不得被歸入 OPERATING／INVESTING／FINANCING 任何一類。

**P0 不計算它。** 若由「期末 − 期初 − 三大活動」反推，K2 就變成恆等式，
永遠成立、永遠驗不出任何事——那既是殘差反推（本刀明令禁止），也讓控制總額
失去意義。因此：

- `CashFlowClassSetVersion` 必須包含一個 `kind = 'FX_EFFECT_ON_CASH'` 的
  控制項目（`activity` 為 NULL，不屬三大活動之一）；
- 它的金額與其他分類一樣，**由映射的支持資料提供**，或以
  `ZERO_ACTIVITY_CONFIRMED` 確認為零（同一幣別時本來就是零）；
- K2 因此是**真正的檢查**：提供的值若讓等式不成立即 `CFS_CONTROL_TOTAL_MISMATCH`。

跨幣別時漏掉它，K2 對不上；把它塞進三大活動，分類會失真——兩者都會被擋下。

不成立時 `CFS_CONTROL_TOTAL_MISMATCH`，**輸出標記為不可用**（比照 G-09 的
`output_capability = NONE`）。

## 七、凍結與重演

沿用 M3-02／M3-03 已凍結的模式，**不另立第二套**：

- Manifest 新增條目型別：`CASH_FLOW_POLICY_VERSION`、`CASH_FLOW_CLASS_SET_VERSION`、
  `CASH_FLOW_MAPPING_VERSION`、`CASH_FLOW_COVERAGE_EXCEPTION`、
  `SOURCE_CALCULATION_RUN`（重用）。
- payload 保存**實際使用到的每一個值**（分類集合、命中的映射規則、例外、
  來源 TB 的現金科目餘額），canonical 為 payload 的文字投影，SHA-256。
- 產出前先驗凍結集合。該驗證與 FX 無關，是通用能力，因此**新增
  `fn_manifest_verify(manifest_id)`**；`fn_fx_verify_manifest` **保留為相容
  wrapper**（直接轉呼叫新函式），**不改名、不移除**——已關閉的 M3-02／M3-03
  行為與測試斷言因此完全不動。
- replay 只讀凍結 payload，結果雜湊涵蓋**金額與來源證據**（分類、映射規則、例外）。

## 八、期間狀態機邊界

**本刀不解鎖任何遷移。** `ADJ_APPROVED → CALCULATING` 仍缺 G-03；
`CALCULATING → RECONCILING` 的守衛與 `RECONCILING` 之後各段亦未實作。
現金流支持資料是 `RECONCILING` 階段「關係人與現金流核對」的資料前提，
但本刀只交付資料與判定能力，0028 的規格函式不動。

## 九、驗收

1. **方法與粒度不得由平台推導**：未選定或未批准的政策版本 → `CFS_POLICY_NOT_APPROVED`；
   非 R4 不得批准。**反證：讓判定自行取「最新已批准版本」→ 轉紅。**
2. **`evidence_version` 必填**：缺母公司確認文件 → 拒絕建立政策版本。
3. **分類以集合為批准單位**：集合不可變、版本向後指、不得分叉；
   單獨新增一個分類到已批准集合 → 拒絕。
4. **映射粒度不得超出實際取得**：`required_granularity = 'BALANCE'`
   而規則為 `JOURNAL_LINE`、且實際 `DataCoverage` 只有 `BALANCE` → 拒絕
   （`ACCOUNT` 只屬 `source_kind`，對應 `BALANCE`）。
   **反證：拿掉該檢查 → 轉紅。**
5. **映射唯一**：同一來源同一生效期間兩條規則 → `CFS_MAPPING_AMBIGUOUS`。
6. **未映射即未映射**：有來源事實未命中規則 → `CFS_UNMAPPED_SOURCE`，
   **不得**被歸入任何預設分類。**反證：加入「其他」預設分類 → 轉紅。**
7. **必要分類完整度（零活動是合法的）**：
   (a) 必要分類既無資料、也未確認零活動、也無例外 → `CFS_REQUIRED_CLASS_UNCONFIRMED`；
   (b) 標為 `ZERO_ACTIVITY_CONFIRMED` 但缺確認人或證據 → `CFS_ZERO_ACTIVITY_UNCONFIRMED`；
   (c) **零活動期間必須能通過完整度判定**（正控制）。
   **反證：把判定改回「必要分類至少要有一筆金額」→ (c) 轉紅。**
7A. **粒度相容性只有一份實作**：政策要 `JOURNAL` 而映射只到 `ACCOUNT` → 拒絕；
   政策只要 `BALANCE` 而實際取得 `JOURNAL` → **接受**（更細不是錯）。
   **反證：在判定函式外另寫一份粒度排序 → 兩處不一致時測試轉紅。**
8. **粒度不足 fail closed**：`DataCoverage.granularity` 低於政策要求且無例外 →
   `CFS_GRANULARITY_INSUFFICIENT`，不產生任何輸出。
9. **例外必須逐分類且經 R4 批准**：整期一次豁免 → 拒絕；有例外時輸出的相關列
   必須帶 `coverage_exception_id`。**反證：允許整期豁免 → 轉紅。**
10. **控制總額 K1～K4**：任一不成立 → `CFS_CONTROL_TOTAL_MISMATCH` 且輸出不可用。
    (a) 功能幣 K1 **不含** FX effect；
    (b) 跨幣別時 K2 **必須含** FX effect——把它拿掉後等式不成立即轉紅；
    (c) **`FX_EFFECT_ON_CASH` 不得由殘差反推**：改成「期末 − 期初 − 三大活動」
        後 K2 變成恆等式，此時應有一條測試證明「即使金額明顯錯誤 K2 仍通過」
        → 該測試存在即代表反推被引入，必須轉紅；
    (d) 期初現金來自**前期已選定 run**（首期用經批准的期初證據）、
        期末來自**本期選定 run**；改成臨時查詢現行餘額 → 轉紅。
11. **凍結與重演**：改動現行政策／分類集合／映射後，舊 run 重演結果與雜湊不變；
    新 run 才採新版本。**反證：重演時回查現行主檔 → 轉紅。**
12. **結果雜湊涵蓋來源證據**：只改映射規則而金額不變時，雜湊必須改變。
12A. **權威來源選定**：
    (a) FX 情境下 `current_run_id` ≠ 現行 `PeriodFxRunSelection` → 拒絕；
    (b) 非首期使用 `FIRST_PERIOD_EVIDENCE` → 拒絕；首期使用
        `PRIOR_SELECTED_RUN` → 拒絕；
    (c) `prior_run_id` 不屬顯式前期的已選定結果 → 拒絕；
    (d) 非 R4 不得選定。
    **反證：把期初改成「查前期最新的 COMPLETED run」→ (c) 轉紅。**
12B. **首期期初證據**：未批准的 `CashFlowOpeningBalanceSetVersion` 不得使用；
    集合不可變、版本向後指、不得分叉；缺 `evidence_ref` → 拒絕。
12C. **零活動需雙人流程**：缺 `reviewed_by`／`reviewed_at` →
    `CFS_ZERO_ACTIVITY_UNCONFIRMED`。
12D. **分類集合的最低要求**：沒有或超過一個 `FX_EFFECT_ON_CASH` → 批准被拒；
    沒有任何現金科目 membership → 批准被拒。
12E. **金額事實**：
    (a) 沒有 `CashFlowSourceFact` 時不得產生任何 `CashFlowSupportLine`；
    (b) `source_ledger_line` 有餘額但沒有 fact → 完整度判定為未確認，
        **不得**由餘額推導金額。**反證：加入「以 TB 餘額補金額」→ 轉紅**；
    (c) `CashFlowSupportLine.signed_amount_*` 必須逐欄等於其 fact 的值
        （支持資料列不做金額運算）；
    (d) `actual_granularity` 與該 fact 所屬資料集的 `DataCoverage` 不符 → 拒絕；
    (e) `source_kind` 與 `source_ledger_line_id`／`source_document_id` 的 XOR。
12F. **逐期覆蓋的寫入權限**：
    (a) 人工寫入 `DATA_PRESENT` → 拒絕（只能由系統依 fact 衍生）；
    (b) `COVERAGE_EXCEPTION` 缺 `coverage_exception_id` 或引用未批准的例外 → 拒絕。
13. **跨租戶與跨案件**：政策、分類集合、映射、例外、來源 run 的父鏈全驗
    （比照 0032）；跨租戶與同租戶跨案件各一條負面測試。
14. **不越界**：本刀不產生任何「現金流量表」實體；輸出型別只有支持資料列。
15. 完整測試一輪全綠；既有斷言一字不改。

## 十、風險

**第一級。** 四個真正的風險：

1. **從收集滑向重建**——一旦系統替未分類金額補上分類，P0 就變成 P1，
   而輸出會被當成報表使用。緩解：無預設分類、驗收 6 的反證、§一的邊界表。
2. **粒度不足被靜默接受**——「拿不到 JOURNAL 就當 ACCOUNT 用」會讓支持資料
   看起來完整。緩解：INV-23 的 fail closed ＋ 逐分類的批准例外 ＋ 輸出標記。
3. **控制總額不勾稽**——分類標籤加總與財務資料對不上時仍輸出。
   緩解：K1～K4 與 `output_capability = NONE` 的處理。
4. **第二套凍結與重演**——另立一套 run／manifest 會產生兩份「可重演」實作。
   緩解：§六與§七的重用決定（待走查拍板）。

實作順序（契約確認後）：
migration（`CashFlowPolicyVersion` → `CashFlowClassSetVersion` ＋ 分類
＋ 現金科目 membership →
`CashFlowMappingVersion` ＋ 規則 → `CashFlowCoverageException` →
`CashFlowOpeningBalanceSetVersion` ＋ 明細 → `PeriodCashFlowSourceSelection` →
`CashFlowSourceFact` → `CashFlowClassPeriodCoverage` →
`calculation_scope` 擴充與 manifest 新條目 → 支持資料列 →
完整度與控制總額判定函式 → 期間級就緒判定）
→ DB 負面測試（1～9、13）→ Case-001 的正控制與控制總額勾稽（10）
→ 凍結與重演（11／12）→ 完整一輪。**畫面不在本刀。**
