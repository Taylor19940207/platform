# SLICE-M3-02　折算與外幣報表折算差額（CTA）

> 狀態：**APPROVED_FOR_IMPLEMENTATION**（2026-08-11，第四版收口後批准）。
> 會計算式與 Case-001 算例於第二版走查通過（保留盈餘延續橋接、CTA 97,159.00 借方、
> 100,380.00 首次轉換輸入），第三版封工程語意，第四版寫死四個實作前細節
> （Currency 入 manifest、合計約束的執行時點、PRIOR_RUN 的狀態條件、
> lot set 的版本方向）並裁決匯率的自然人 SoD。**契約至此凍結，開始 migration。**
> 風險：**第一級**。
>
> 對應基線：手冊 v1.2 REQ-FX-001／AC-FX-001／§20 MVP 3；設計書 v1.1 §25.3、§26.6、
> §26.11、§26.12（INV-19／20／22）、D-26-06、§28 B-06。
> 會計法源：《企業會計準則第 19 號——外幣折算》第十二條及應用指南。

## 為什麼是這一刀

里程碑 2 交付的計算一律 `calculation_scope = 'NO_FX'`（0012 的 CHECK 寫在
`calculation_input_manifest` 上），所有金額只有一種幣別。中國母公司要的是**人民幣**
口徑，日本子公司的帳是**日圓**——沒有折算，整條鏈的終點還不是母公司拿得到的東西。

折算也是全案最容易錯而**沒有來源檔案可對照**的地方：CTA 是算出來的差，不是抄來的數。
因此本刀先凍結決定，再實作。

## 一、幣別主檔與幣別角色

### 1.1 `Currency` 平台參照主檔

「JPY 0 位、CNY 2 位由主檔決定」目前**沒有落點**——schema 裡沒有幣別主檔。本刀建立：

    Currency
    ├─ currency_code   ISO 4217
    ├─ minor_unit      最小單位小數位（JPY 0、CNY 2）
    └─ active

- 與 `posting_layer` 同性質：**平台參照主檔**，`app_runtime` **唯讀**（只 GRANT SELECT）。
  不屬任何租戶，不做 RLS。
- 金額精度一律讀 `minor_unit`，**不得**在程式裡寫死幣別與位數的對應。
- **`minor_unit` 必須被 run 凍結**（manifest 條目 `currency_definition`，見 §6.2）。
  只凍結幣別*指派*而不凍結幣別*定義*，CNY 由 2 位改成 0 位時舊 run 的重演就會漂移。
  **折算函式一律讀 manifest 的凍結值，重演時不得回查目前的 `currency` 表。**

### 1.2 `ReportingUnitCurrencyAssignment`（INV-22／D-26-06）

- `currency_role`：本刀實作 **`FUNCTIONAL`** 與 **`REPORTING`**。
- **兩個角色都限制同一時點各一個有效指派**，以 `daterange` ＋ `EXCLUDE USING gist`
  在 DB 強制。REPORTING 現在就不允許多值——多值卻沒有選擇規則，等於把「用哪個報告幣」
  留給實作當下猜。日後要第二報告幣時新增 `SECONDARY_REPORTING`（本刀不做）。
- **run 同時凍結兩者**（INV-22 (b)），見 §六。
- **批准責任為 R4**（§24.6 中「幣別指派」屬客戶政策性質的決定，批准欄為 R4）。
  未批准的指派不得被 run 凍結，否則「功能幣是誰決定的」在稽核上沒有答案。
- `ReportingUnit.current_functional_currency` **維持快取語意**（D-26-06）；折算一律讀
  有效期間指派，**不得**讀該欄位，也不新增同步觸發器——那會讓快取看起來像真相。

## 二、匯率：版本與觀測分離

    ExchangeRateVersion          工作流與不可變版本
    └─ ExchangeRateObservation   實際匯率列

### 2.1 工作流（四狀態，寫死）

    DRAFT → SUBMITTED → REVIEWED → APPROVED

| 遷移 | 角色（§24.6 `匯率版本 ExchangeRate` 列） | 效果 |
|---|---|---|
| 建立與維護 `DRAFT` | R6（`C U`） | 可自由增刪觀測 |
| `DRAFT → SUBMITTED` | R2（`S`） | **觀測列與期間欄位凍結** |
| `SUBMITTED → REVIEWED` | R3（`V`） | 寫入不可變的 `reviewed_by`／`reviewed_at` |
| `REVIEWED → APPROVED` | R4（`A`） | **整版不可變**（含不得新增觀測）；可被 run 凍結 |

退回（`SUBMITTED`／`REVIEWED → DRAFT`）保留，退回理由必填。
改率＝發新版本，既有 run 仍指向舊版本。

**自然人層 SoD（裁決：最低限度的獨立覆核，不要求三人）**

    submitted_by ≠ reviewed_by      強制（穩定代碼 FX_RATE_SELF_REVIEW_DENIED）
    reviewed_by  = approved_by      允許
    created_by   = submitted_by     允許

甲可建立並提交匯率版本，乙必須獨立覆核；乙若同時持有 R4，可接著批准。
**兩人即可運作**，同時避免一個人從提交、覆核一路自簽。這是**實例級**控制——
不禁止同一自然人持有多個角色，只禁止同一自然人在同一版本上同時提交與覆核。
要求三個不同自然人會讓 2～3 人的事務所無法運作。

此為**本切片的嚴格子集**（比 §24.6 的角色矩陣多一條實例級限制），已登記
`docs/BACKLOG.md`，日後併回正式基線時再統一。

### 2.2 報價方向與期間語意

**報價方向（唯一，不接受另一種寫法）：**

    target_amount = source_amount × rate      （rate 為 from_currency → to_currency）

- **只接受直接幣別對**。**不做倒數推算，也不做交叉匯率**：JPY→CNY 就必須有 JPY→CNY
  的觀測，不得由 CNY→JPY 取倒數，也不得經 USD 換算。缺就 fail closed。
  倒數與交叉都會引入第二個捨入點，讓重演與勾稽失去唯一解。
- **各 rate_type 的期間語意不同，不能共用一個模糊的 `rate_date`**：

  | `rate_type` | 期間欄位 | 語意 |
  |---|---|---|
  | `CLOSING` | `measurement_date`（精確計量日） | 資產負債表日即期匯率 |
  | `AVERAGE` | `coverage_start` ／ `coverage_end` | 該區間的平均或合理近似 |
  | `HISTORICAL` | `event_date` | 對應某一次權益事件的發生日 |

  `AVERAGE` 的覆蓋區間必須**涵蓋**所折算期間，否則拒絕（`FX_RATE_COVERAGE_MISMATCH:`）。
  「用 2 月平均折算 3 月」是安靜的錯，必須擋。

### 2.3 G-07 與缺率

- **G-07 的嚴格程度**：`output_capability = NONE`——§28 守衛表明定「連預覽都不產生」。
  - 既有 `NO_FX` run **維持合法**，不需要匯率版本（它不宣稱任何折算結果）；
  - `FX_TRANSLATION` run 若匯率版本未指定或未 `APPROVED`，**建立即拒絕**，
    穩定代碼 `G07_RATE_VERSION_NOT_FROZEN:`，不建立半套 run，不產生預覽。
- **缺率逐筆 fail closed**：`FX_RATE_MISSING:`，列出缺哪個幣別對、哪個 `rate_type`、
  哪一天／哪個區間。**不得回退到其他 rate_type**。

## 三、折算分類與方法

### 3.1 科目模型不足，必須補分類

現有 `account` 只有 `balance_behavior = STOCK／FLOW`，不足以選擇方法；即使補上
ASSET／LIABILITY／EQUITY 也**分不出實收資本、保留盈餘、股利分配與其他權益變動**，
而這四者的折算處理完全不同。

**新增受控的 `translation_category`（八值，不得由科目代碼推斷）：**

    ASSET  LIABILITY  INCOME  EXPENSE
    EQUITY_CONTRIBUTED  EQUITY_RETAINED  EQUITY_DISTRIBUTION  EQUITY_OTHER

- 掛在 `Account` 上，屬集團科目表的事實。
- **每個納入 run 的科目必須恰好命中一條 policy rule**：缺漏 → `FX_METHOD_UNRESOLVED:`；
  重疊 → `FX_METHOD_AMBIGUOUS:`。兩者都拒絕整個 run。
- 不設「其他一律期末率」的預設。預設值在這裡就是靜默的錯。
- **分類必須被 run 凍結**，見 §6.3——否則科目分類日後改變會追溯改寫舊 run 的解釋。

### 3.2 `TranslationPolicyVersion`：方法是資料，不是程式碼分支

沿用 0023 已凍結的原則（約束由屬性驅動、代碼不驅動約束）。政策版本需批准
（MVP 3 離開條件寫明「方法／粒度獲確認」），未批准者不得被 run 凍結。

| `translation_category` | 處理 | 法源 |
|---|---|---|
| `ASSET`／`LIABILITY` | `CLOSING`（資產負債表日即期匯率） | CAS 19 §12 |
| `INCOME`／`EXPENSE` | `AVERAGE`（交易發生日匯率或合理近似） | CAS 19 §12 |
| `EQUITY_CONTRIBUTED` | **逐筆** `HISTORICAL`（見 §3.3） | CAS 19 §12（除未分配利潤外的所有者權益按交易發生日匯率） |
| `EQUITY_DISTRIBUTION` | 逐筆 `HISTORICAL`（宣告或支付日） | 同上 |
| `EQUITY_OTHER` | 逐筆 `HISTORICAL` | 同上 |
| `EQUITY_RETAINED` | **不乘任何匯率**，由延續橋接得出（見 §3.4） | CAS 19 §12 應用指南 |

`TranslationPolicyVersion` 另須凍結 **CTA 落點**（見 §5.2）。

### 3.3 權益折算批次：**以「集合版本」為批准與凍結單位**

「實收資本逐筆歷史匯率」在 TB 上**無法取得**——TB 只有餘額，沒有每次出資的日期。
而且**單筆 lot 的版本鏈證明不了「沒有漏掉第三筆出資」**：漏掉的那筆根本不存在，
沒有任何版本鏈會指向它。因此批准與凍結的單位必須是**整個集合**：

    EquityTranslationLotSetVersion            每個科目一次批准一個完整 set
    ├─ account_id / reporting_unit_id
    ├─ series_id / version_no                 同一科目的版本序列
    ├─ supersedes_set_version_id              **新版本向後指向舊版本**
    ├─ approved_by / approved_at
    └─ EquityTranslationLot［］
       ├─ event_date                          出資／權益變動日期
       ├─ functional_amount                   功能幣金額
       ├─ exchange_rate_observation_id        HISTORICAL 觀測（event_date 相符）
       └─ evidence_ref

- **合計一致性（fail closed）**：set 內所有 lots 的 `functional_amount` 合計必須等於該
  科目的功能幣餘額，否則整個 run 拒絕，代碼 `EQUITY_LOT_SUM_MISMATCH:`，並列出科目、
  餘額與合計。差一塊錢就代表有一次出資沒被記錄，其歷史匯率也就沒被使用——
  那筆差額會被靜默吸收進 CTA。
- **run 凍結的是 `set_version`**（manifest 的 `object_id` 指向它），不是個別 lot。
- `APPROVED` 後 set **完全不可變**——因此**不使用向前的 `superseded_by`**：
  填入該欄本身就是在修改已批准的舊列，與「不可變」直接矛盾。
  建立 v2 時由 **v2 指向 v1**（`supersedes_set_version_id`），v1 一個位元都不動。
  同一 `series_id` 內 `version_no` 唯一且遞增；`supersedes_set_version_id` 必須指向
  同一 series 的前一版；**同一科目同一時點只有一個未被指向的最新版本**。

### 3.4 保留盈餘：延續橋接，不是「餘額 × 某率」

保留盈餘不得以 JPY 餘額乘上任何單一匯率。CAS 19 的處理是由歷史已折算餘額**延續**：

    期末保留盈餘（報告幣）
      ＝ 前期已鎖定的期末已折算保留盈餘
      ＋ 本期已折算損益
      －  已折算股利／分配
      ±  其他已批准的權益變動

- 在**試算表**層次（本刀的輸出形式），`EQUITY_RETAINED` 一行呈現的是**期初**已折算
  保留盈餘；本期損益仍在 `INCOME`／`EXPENSE` 各科目（已按 `AVERAGE` 折算），
  結帳分錄不在本刀範圍。因此上式在 TB 上自動成立，可作為**勾稽檢查**。
- **`EquityOpeningTranslatedBalance` 必須說明它從哪裡來：**

      source_kind = PRIOR_RUN | FIRST_CONVERSION

      PRIOR_RUN         → source_calculation_run_id 必填，且必須同時滿足：
                          ① 該 run 的 status = COMPLETED
                             （CalculationRun **沒有** LOCKED 狀態，鎖定屬期間）
                          ② 該 run 的 PeriodRevision.status = LOCKED
                          ③ 該 PeriodRevision 屬目前期間的**顯式前期**
                          ④ ReportingUnit、Account 與報告幣三者相同
      FIRST_CONVERSION  → evidence_ref 必填（經批准的外部證據）

  **後續期間必須引用前期已鎖定的 run**；只有首次導入能用經批准的外部證據。
  否則每期都可以人工填一個數，形式上批准、實際上沒有延續——那正是「延續橋接」
  最容易退化成的樣子。以 CHECK 強制 XOR，四項條件任一不成立即
  `FX_OPENING_EQUITY_NOT_CONTINUOUS:`。
- **「前期」必須由顯式期間連結判定**，不得用日期減一或 `revision_no` 推導——
  期間可跳號、可有非標準長度，推導出來的「前期」在跨年度或補期時會指錯。
  現況 `reporting_period` **沒有**這個連結，因此本刀新增：

      reporting_period.previous_reporting_period_id   可為 NULL（首期）

  約束：必須屬**同一 `reporting_unit_id` ＋ `fiscal_calendar_id`**；不得指向自己；
  一個期間**至多被一個**後期指向（唯一索引，避免兩期共用同一前期）；
  設定後不可變更（與 `is_initial_period` 同性質的身分事實）。
  `is_initial_period = true` 者該欄必須為 NULL，反之必須非 NULL。
- 缺失 → `FX_OPENING_EQUITY_MISSING:`，拒絕整個 run。
- 首次導入的期初橋接**方法**（REQ-PER-101）不在本刀——本刀只要求那個值存在且經批准。

## 四、金額精度

| 項目 | 決定 |
|---|---|
| 匯率精度 | `numeric(18,8)`——保存來源提供的位數，不得預先四捨五入 |
| 金額精度 | 目標幣別的 `Currency.minor_unit`（CNY 2、JPY 0） |
| 捨入模式 | **`ROUND_HALF_UP`**，**逐行**（逐 `BalanceSnapshotLine`）套用 |
| 捨入時點 | 折算後立即捨入並保存；不保存未捨入的中間值當作真相 |
| 合計方式 | 合計＝**已捨入金額的加總**，不得由未捨入值另算一次 |
| 運算型別 | **全程 `numeric`；任何金額或匯率都不得進入 JavaScript `Number`** |

逐筆權益的捨入在 **component 層**（每筆 lot 各自捨入），彙總＝已捨入 component 的加總。

最後一條是硬性的：`Number` 是 IEEE 754 雙精度，`0.1 + 0.2 !== 0.3`，一旦金額經過它，
AC-FX-001 的「重跑結果一致」就只是碰巧成立。折算計算**在 DB 內以 `numeric` 完成**，
應用層只搬運字串。

**`RoundingTolerance` 與尾差自動結案移到下一刀。** 理由有二：
(a) D-26-05 的 scope 鏈包含尚未實作的 `OutputProfile`；
(b) INV-24 管的是**調節差異的自動結案**，不是 CTA 計算本身。本刀只凍結逐行
`ROUND_HALF_UP`，不引入任何容許值概念——沒有門檻，就沒有「被吃掉的差」。

## 五、CTA：獨立的報告層調整，不冒充一般分錄

### 5.1 為什麼不能塞進 `JournalEntry`

現有 `JournalEntry` 的語意是**借貸平衡**。CTA 是為了補足「折算後借貸總額差」，本質上是
**單邊的報告層調整**：只記借方 97,159 的普通分錄本身不平；硬補一筆貸方對應列，
又等於憑空造出一個不存在的科目餘額，反而修正不了折算差額。

**獨立成新實體，不動 `JournalEntry`：**

    TranslationAdjustmentEntry
    ├─ calculation_run_id / reporting_unit_id / period_revision_id
    ├─ posting_layer_id = TRANSLATION_ADJUSTMENT
    ├─ rule_type ∈ {GROUP_GAAP, CONSOLIDATION}      本刀只產生 GROUP_GAAP
    ├─ translation_policy_version_id / exchange_rate_version_id
    └─ TranslationAdjustmentLine［］
       └─ account_id / debit / credit（**報告幣**）/ 說明

- `rule_type` **落在分錄上，不落在層上**——0023 已把 `TRANSLATION_ADJUSTMENT` 層的
  `rule_type` 設為 `NULL` 並註明「逐筆分錄的歸屬隨折算刀」。同一層要同時承載實體層
  CTA（`GROUP_GAAP`）與合併層 CTA（`CONSOLIDATION`），塞回層上就得拆成兩個層，
  那是代碼驅動約束的變形。
- **`app_runtime` 不得直接寫入**——只能由折算函式在同一交易內產生。

### 5.2 CTA 科目必須被凍結

`TranslationPolicyVersion` 必須凍結：

    cta_account_id              CTA 科目
    cta_coa_id                  該科目所屬的集團科目表（版本）
    applicable_reporting_unit   適用報告單位
    approved_by / approved_at   批准版本

`cta_account_id` 的科目必須屬於 `cta_coa_id`，且該 COA 必須是本案件的集團科目表，
否則拒絕（`CTA_ACCOUNT_SCOPE_INVALID:`）。

### 5.3 CTA 在快照中的幣別落點（**寫死**）

`BalanceSnapshotLine.debit／credit` 是**功能幣**數字且沒有 currency 欄。把 CNY 97,159
直接寫進去，同一張表就會混入 JPY 與 CNY。**決定：**

| 物件 | 內容 |
|---|---|
| CTA 的 `BalanceSnapshotLine` | `posting_layer = TRANSLATION_ADJUSTMENT`、`account_id = cta_account_id`、**`debit = 0`、`credit = 0`** |
| 其 `TranslationResult` | `amount_role = REPORTING`、`currency_code = CNY`、**`result_debit = 97,159.00`**、`result_credit = 0`、`source_debit/credit = 0` |
| `TranslationAdjustmentEntry/Line` | 保存 CTA 的**報告幣調整事實**（金額、科目、政策與匯率版本、run） |

空殼 SnapshotLine 只提供**科目與層的落點**，真正的金額在 `TranslationResult`，
不污染功能幣欄位。**副作用是正確的**：功能幣 TB 仍借貸各 59,000,000——
功能幣下本來就沒有 CTA。

`balance_snapshot_line.posting_layer` 的 CHECK 由 `('SOURCE_TB','ADJUSTMENT')`
擴充為含 `'TRANSLATION_ADJUSTMENT'`（migration 必須同步改，現況只允許前兩者）。

## 六、凍結集合與重演（AC-FX-001）

### 6.1 折算結果：彙總 ＋ 計算明細

**一個科目可能有多筆歷史來源**（4001 有兩筆 lot），但 INV-19 要求每個
`(source_snapshot_line_id, amount_role)` 只有一筆結果。兩者只能靠**兩層**並存：

    TranslationResult                     科目折算彙總（INV-19 唯一性落在這裡）
    ├─ source_snapshot_line_id
    ├─ amount_role = REPORTING            本刀固定
    ├─ currency_code
    ├─ source_debit / source_credit       功能幣（＝ SnapshotLine 的借貸）
    ├─ result_debit / result_credit       報告幣
    ├─ translation_policy_rule_id         命中哪一條政策規則
    └─ calculation_run_id

    TranslationResultComponent［］        計算明細（一筆彙總 → 一至多筆）
    ├─ source_kind
    ├─ source_ref                         來源物件的一般化引用
    ├─ equity_lot_id                      EQUITY_LOT 時必填，其餘必為 NULL
    ├─ exchange_rate_observation_id       見下表
    └─ source_debit / source_credit / result_debit / result_credit

| `source_kind` | 用於 | 匯率觀測 |
|---|---|---|
| `RATE_TRANSLATION` | 一般資產／負債／損益 | **必填** |
| `EQUITY_LOT` | 逐筆權益（每筆 lot 一個 component） | **必填**（該 lot 的 HISTORICAL 觀測） |
| `OPENING_TRANSLATED_BALANCE` | 保留盈餘延續橋接 | **必為 NULL** |
| `CTA_RESIDUAL` | CTA 殘差 | **必為 NULL** |

- **完整性約束（DB 強制，`DEFERRABLE INITIALLY DEFERRED`）**：同一 `TranslationResult`
  的所有 component 的 `result_debit`／`result_credit` 合計必須等於彙總的
  `result_debit`／`result_credit`；`source_debit`／`source_credit` 亦然。
  差額不得存在——那就是無法追溯的金額。
  **執行時點必須寫死**：彙總先建立、component 後插入，普通 row trigger 在第一筆
  component 時必然不平。因此以 `CREATE CONSTRAINT TRIGGER … DEFERRABLE INITIALLY
  DEFERRED` 在**交易結束前**檢查。**不得**依賴應用層或 worker「記得最後再檢查一次」——
  忘記檢查與檢查失敗看起來一模一樣，而前者會留下無法追溯的金額。
- 一般科目與損益也各有**一個** component，追溯模型因此完全一致：
  「彙總怎麼來的」永遠答得出來，而不是只有權益科目答得出來。
- **INV-19**：`(source_snapshot_line_id, amount_role)` 唯一索引，落在彙總層。
- **雙幣寬表不做**：設計書已註明 `amount_functional`／`amount_reporting` 寬表僅為查詢
  效能，不是模型的一部分。

### 6.2 Manifest 擴充

現況 `calculation_manifest_entry` 已是通用的
`(object_type, object_id, domain_version_kind, domain_version_value, content_hash)`
結構，因此只需新增 `object_type`：

    currency_definition                   幣別定義（currency_code ＋ minor_unit）
    exchange_rate_version                 匯率版本
    translation_policy_version            折算政策版本（含 CTA 科目凍結）
    currency_assignment                   幣別角色指派（FUNCTIONAL 與 REPORTING 各一筆）
    equity_translation_lot_set_version    權益折算批次**集合版本**（每個相關科目一筆）
    equity_opening_translated_balance     期初已折算權益餘額（含 source_kind 與來源 run）
    account_translation_classification    科目折算分類（見 §6.3）

- **每一條都必須同時保存 `object_id` 與 `content_hash`**，不得只存版本 ID——
  同一 ID 的內容若日後漂移（即使有不可變約束，資料修復或遷移仍可能發生），
  只比 ID 的重演會宣稱一致而實際不同。
- `calculation_input_manifest.calculation_scope` 的 CHECK 由 `= 'NO_FX'` 放寬為
  `IN ('NO_FX','FX_TRANSLATION')`（**該欄在 manifest 上，不在 `calculation_run`**）。
- `frozen_set_content_hash` 與 `result_content_hash` 涵蓋新條目；兩者仍**排除**
  run_id 與時間戳（0012 已凍結的規則）。
- **重演一律讀 manifest 的凍結值**，不得回查目前的主檔（`currency`、`account`、
  `exchange_rate_observation` 皆同）。這是 §6.3 與 `currency_definition` 存在的理由：
  凍結了卻在重演時回查，等於沒有凍結。
- **重演**沿用 02B：新 run 帶 `replay_of_run_id` 引用**同一份 Manifest**，失敗屬
  replay run，原 run 永不修改。

### 6.3 科目分類的凍結**不得**改動既有 COA 條目

`translation_category` 掛在 `Account` 上，但既有的 `CHART_OF_ACCOUNTS` manifest 條目
只凍結 COA 的 ID、版本與名稱，**沒有**凍結每個科目的分類。

**決定：新增獨立的 `account_translation_classification` 條目，只在 FX run 產生。**

    account_id
    translation_category
    matched_policy_rule_id
    canonical content ＋ content_hash

- **不得擴充既有 `CHART_OF_ACCOUNTS` 條目的 canonical 內容**——那會改變既有 `NO_FX`
  manifest 的 hash，讓里程碑 2 的既有 run 全部無法重演。
- 科目分類日後改變時，舊 run 因為凍結了當時的分類而不受影響。

## 七、驗收算例（Case-001，手算；第二版已通過，第三版僅補結構呈現）

來源：`tests/fixtures/case-001/expected_adjusted_group_tb_2026-03.csv`（JPY，調整後集團
TB，借貸各 59,000,000）。功能幣 JPY、報告幣 CNY。匯率版本 `2026-03 v1`（已 `APPROVED`）：

| `rate_type` | 期間欄位 | JPY→CNY |
|---|---|---|
| `CLOSING` | `measurement_date = 2026-03-31` | 0.048120 |
| `AVERAGE` | `coverage 2026-03-01 ～ 2026-03-31` | 0.047950 |
| `HISTORICAL` | `event_date = 2018-06-15` | 0.061000 |
| `HISTORICAL` | `event_date = 2022-09-01` | 0.051000 |

`EquityTranslationLotSetVersion`（4001 实收资本，set v1，已批准；合計 JPY 10,000,000
＝ 該科目功能幣餘額 ✓）：

| `event_date` | 功能幣 | 觀測 | 報告幣 |
|---|---:|---|---:|
| 2018-06-15 | 7,000,000 | 0.061000 | 427,000.00 |
| 2022-09-01 | 3,000,000 | 0.051000 | 153,000.00 |

`EquityOpeningTranslatedBalance`（4104 未分配利润）：**CNY 100,380.00**，
`source_kind = FIRST_CONVERSION`（Case-001 的 2026-03 為首期，無前期已鎖定 run），
`evidence_ref` 為經批准的期初橋接底稿。

| 科目 | 分類 | JPY 淨額 | 方法 | CNY |
|---|---|---:|---|---:|
| 1001 库存现金 | ASSET | 350,000 D | CLOSING | 16,842.00 D |
| 1002 银行存款 | ASSET | 9,650,000 D | CLOSING | 464,358.00 D |
| 1122 应收账款 | ASSET | 5,600,000 D | CLOSING | 269,472.00 D |
| 1405 库存商品 | ASSET | 2,300,000 D | CLOSING | 110,676.00 D |
| 1601 固定资产 | ASSET | 4,600,000 D | CLOSING | 221,352.00 D |
| 2202 应付账款 | LIABILITY | 3,900,000 C | CLOSING | 187,668.00 C |
| 2221 应交税费 | LIABILITY | 800,000 C | CLOSING | 38,496.00 C |
| 4001 实收资本 | EQUITY_CONTRIBUTED | 10,000,000 C | 逐筆 lots（2 個 component） | **580,000.00 C** |
| 4104 未分配利润 | EQUITY_RETAINED | 2,100,000 C | 延續橋接（不乘匯率） | **100,380.00 C** |
| 6001 主营业务收入 | INCOME | 42,000,000 C | AVERAGE | 2,013,900.00 C |
| 6401 主营业务成本 | EXPENSE | 21,700,000 D | AVERAGE | 1,040,515.00 D |
| 6602 管理费用 | EXPENSE | 14,600,000 D | AVERAGE | 700,070.00 D |

借方合計 **2,823,285.00**、貸方合計 **2,920,444.00**。

    CTA ＝ 2,920,444.00 − 2,823,285.00 ＝ 97,159.00（借方）

**結構呈現**（第三版新增的判準）：

    4001 TranslationResult   source_credit 10,000,000 / result_credit 580,000.00
      ├─ Component EQUITY_LOT  lot#1  7,000,000 → 427,000.00  obs(2018-06-15)
      └─ Component EQUITY_LOT  lot#2  3,000,000 → 153,000.00  obs(2022-09-01)
    4104 TranslationResult   source_credit  2,100,000 / result_credit 100,380.00
      └─ Component OPENING_TRANSLATED_BALANCE  無匯率觀測
    CTA  BalanceSnapshotLine debit 0 / credit 0（功能幣）
         TranslationResult   result_debit 97,159.00  currency CNY
      └─ Component CTA_RESIDUAL  無匯率觀測

**CTA 為借方（權益減項）是合理的**：出資時 1 JPY 值 0.061／0.051 CNY，期末只值
0.048120——功能幣相對報告幣貶值，以歷史匯率入帳的權益在報告幣下高於以期末匯率折算的
淨資產，差額落在借方。**若實作把 CTA 算成貸方，方向就是錯的**，驗收會擋下。

**RE 勾稽**：本期已折算損益淨額 ＝ 2,013,900.00 − 1,040,515.00 − 700,070.00
＝ **273,315.00**；期末已折算保留盈餘 ＝ 100,380.00 ＋ 273,315.00 ＝ **373,695.00**。

**捨入判準另用刻意不整除的案例**（上表以整除設計，好讓 CTA 唯一可驗）：
觀測改 0.0481233 時，1001 為 350,000 × 0.0481233 ＝ 16,843.155 →
`ROUND_HALF_UP` 2 位 → **16,843.16**。banker's rounding 會得 16,843.15，測試必須轉紅。

## 八、不做

- **不解鎖期間狀態機**：`ADJ_APPROVED → CALCULATING` 及其後各段在 0028 的規格函式中
  維持 `NOT_IMPLEMENTED`。本刀只建立可重演的 `FX_TRANSLATION` **PREVIEW**
  `CalculationRun`；期間仍停在 `ADJ_APPROVED`。**解鎖條件**：下一刀具備調節核對
  （含 INV-24 與 `RoundingTolerance`）與 G-03／G-07 的期間級判定後，才處理該遷移。
- **不做 REQ-CFS-001（現金流）**：**另開 MVP 3 現金流切片；未完成前 MVP 3 不得關閉。**
- **不做 `RoundingTolerance` 與尾差自動結案**（INV-24）——移到下一刀調節核對。
- 不做 `TRANSACTION`／`SECONDARY_REPORTING` 兩個 `amount_role`，也不做第二報告幣。
- 不做首次導入的期初橋接**方法**（REQ-PER-101）。
- 不做合併層 CTA（`rule_type = CONSOLIDATION`）的**產生**：只保留該值的合法性。
- 不做倒數與交叉匯率、不做匯率來源自動抓取（R6 手動維護）。
- **不對匯率版本新增自然人層 SoD**（見 §2.1 的待決）。
- 不做 B-06 的折算畫面。畫面在 DB 驗證完成後另開一刀。
- 不做雙幣寬表、不做交易級外幣重估（後者是 A 基礎的既有結果，§24 邊界已排除）。

## 九、驗收

1. **INV-22 (a)**：同一 ReportingUnit 同一時點插入第二個有效 `FUNCTIONAL` → DB 拒絕；
   `REPORTING` 同樣拒絕。
2. **INV-22 (b)**：Manifest 含 `currency_assignment` 兩筆；指派其後變更不影響既有 run 的
   重演結果。
3. **`Currency` 主檔**：`app_runtime` 對 `currency` 只有 SELECT；精度取自 `minor_unit`，
   未寫死於程式。
3A. **`minor_unit` 的凍結（兩條缺一不可）**：
   (a) 建立 run 後把 CNY 的 `minor_unit` 改為 0，**舊 run 重演仍用 manifest 的 2 位**，
       `result_content_hash` 不變；
   (b) 之後建立的**新 run** 使用改後的 0 位，結果**跟著改變**。
   反證：折算函式改成重演時回查目前 `currency` 表 → (a) 轉紅。
4. **匯率四狀態**：`DRAFT → SUBMITTED` 後不得增刪觀測；`REVIEWED` 的
   `reviewed_by/at` 不可覆寫；`APPROVED` 後整版不可變；角色不符者被拒。
4A. **匯率自然人 SoD**：`submitted_by = reviewed_by` → 拒絕，代碼
   `FX_RATE_SELF_REVIEW_DENIED`；`reviewed_by = approved_by` **必須允許**
   （反證：把它一併禁掉 → 兩人事務所路徑轉紅）。
5. **G-07**：`FX_TRANSLATION` run 未指定或匯率版本未 `APPROVED` → **建立即拒絕**、
   不產生任何 run 與預覽；`NO_FX` run 不受影響。
6. **缺率 fail closed**：缺一筆 `HISTORICAL` → 整個 run 拒絕並列出缺哪一筆。
   **反證：加入「找不到就用期末率」的回退 → 轉紅。**
7. **報價方向與直接幣別對**：只有 CNY→JPY 觀測時，JPY→CNY 折算必須拒絕，
   **不得取倒數**；反證：加入倒數推算 → 轉紅。
8. **`AVERAGE` 覆蓋區間**：以 2 月的 AVERAGE 折算 3 月 → 拒絕。
9. **分類解析**：科目缺 policy rule → `FX_METHOD_UNRESOLVED:`；命中兩條 →
   `FX_METHOD_AMBIGUOUS:`；兩者皆拒絕整個 run。
10. **`EQUITY_RETAINED` 不得乘匯率**：反證——把 4104 改成 `餘額 × CLOSING`
    → 算例轉紅（CTA 不再是 97,159.00）。
11. **lot set 合計一致**：把一筆 lot 的 `functional_amount` 改小 →
    `EQUITY_LOT_SUM_MISMATCH:` 拒絕整個 run，**不得**把差額靜默併入 CTA。
11A. **lot set 版本方向**：建立 v2 後 v1 **逐欄位未變**（含 hash）；
    對已 `APPROVED` 的 set 或其 lots 做任何 UPDATE → DB 拒絕。
12. **期初已折算餘額的來源**（四項條件各一條負面測試）：run 非 `COMPLETED`／
    其 PeriodRevision 非 `LOCKED`／非目前期間的顯式前期／單位或科目或報告幣不同
    → 皆 `FX_OPENING_EQUITY_NOT_CONTINUOUS:`；缺失 → `FX_OPENING_EQUITY_MISSING:`；
    `FIRST_CONVERSION` 缺 `evidence_ref` → 拒絕。
12A. **顯式前期連結**：`previous_reporting_period_id` 跨單位或跨曆別 → 拒絕；
    指向自己 → 拒絕；兩個期間指向同一前期 → 拒絕；設定後變更 → 拒絕；
    `is_initial_period = true` 卻有前期（或反之）→ 拒絕。
    **反證：把前期改成「用 end_date 減一期推導」→ 12A 的跨曆別案例轉紅。**
13. **算例**：§七逐科目 12/12 相符；**CTA ＝ 97,159.00 且在借方**；
    RE 勾稽 100,380.00 ＋ 273,315.00 ＝ 373,695.00。
14. **CTA 的產生方式**：**CTA 必須由報告幣下已捨入的借貸合計差額產生；
    不得以功能幣合計與報告幣合計相減。** 反證：改成功能幣合計與報告幣合計相減 → 轉紅。
15. **CTA 幣別落點**：CTA 的 `BalanceSnapshotLine` 的 `debit/credit` 必須為 0；
    功能幣 TB 合計仍為 59,000,000／59,000,000。反證：把 97,159 寫進 SnapshotLine
    的 `debit` → 功能幣合計檢查轉紅。
16. **CTA 落點科目**：`cta_account_id` 不屬於本案件集團科目表 → 拒絕；
    政策版本未凍結 CTA 科目 → 拒絕。
17. **彙總與明細一致**：component 合計 ≠ 彙總 → **交易 COMMIT 時**拒絕
    （`DEFERRABLE INITIALLY DEFERRED`；且必須驗證「彙總已存在、component 尚未插完」
    的中間狀態**不會**誤擋）；
    4001 的彙總必須恰有兩個 `EQUITY_LOT` component，
    `OPENING_TRANSLATED_BALANCE` 與 `CTA_RESIDUAL` 的 component
    帶匯率觀測 → 拒絕。
18. **INV-19**：同一 `(source_snapshot_line_id, amount_role)` 插入第二筆 → DB 拒絕。
19. **`TranslationAdjustmentEntry` 不可人手寫入**：`app_runtime` 直接 INSERT → 拒絕。
20. **捨入**：§七的 `ROUND_HALF_UP` 案例；改 banker's rounding → 轉紅。
21. **重演**：同一 Manifest 重跑 `result_content_hash` 完全相同；改匯率版本後重跑 →
    產生新 run，舊 run 不變。**反證：Manifest 只存版本 ID 不存 content hash，
    再竄改該版本內容 → 重演必須失敗。**
22. **既有 `NO_FX` 不受影響**：calculation-run 33 條與 evidence-package 31 條
    **斷言一字不改**全綠；且既有 `CHART_OF_ACCOUNTS` manifest 條目的 canonical 內容
    與 hash 未變（反證：把 `translation_category` 加進該條目 → 既有 run 重演轉紅）。
23. 完整測試一輪全綠。

## 十、風險

**第一級。** 五個真正的風險：

1. **權益折算錯而無人察覺**——保留盈餘若被當成「餘額 × 某率」，數字看起來正常，
   CTA 卻整個錯。緩解：§3.4 的延續橋接與來源約束、驗收 10／12、RE 勾稽等式。
2. **靜默回退**（缺率用期末率、倒數推算、未涵蓋科目用預設方法、lots 差額併入 CTA）——
   會產生看起來正常、實際錯誤的報表。緩解：全部 fail closed，驗收 6／7／9／11 各有反證。
3. **精度與捨入不確定**——重演不一致會讓 AC-FX-001 直接不成立。緩解：精度、捨入模式、
   捨入時點、合計方式、**不得進 JS `Number`** 五項在契約層凍結。
4. **CTA 冒充一般分錄或污染功能幣欄位**——緩解：獨立實體 ＋ §5.3 的空殼 SnapshotLine
   ＋ 驗收 15。
5. **改動既有 manifest 的 canonical 內容**——會讓里程碑 2 的既有 run 全部無法重演。
   緩解：§6.3 只新增獨立條目，驗收 22 以既有 33＋31 條斷言不改為判準。

實作順序（契約確認後）：
migration（`Currency` → 幣別指派 → `reporting_period.previous_reporting_period_id`
→ 匯率版本／觀測四狀態＋自然人 SoD → `translation_category` →
政策版本＋CTA 科目 → 權益 lot set version（`supersedes` 向後指）→ 期初已折算餘額 →
`TranslationAdjustmentEntry`／Line → `TranslationResult`＋Component＋deferred 合計約束 →
manifest 新條目與 `calculation_scope` 放寬 → `balance_snapshot_line` 的 CHECK）
→ DB 負面測試（1～12A、15～19）→ 折算函式（DB 內 `numeric`，一律讀 manifest 凍結值）
→ 算例驗收（3A／13／14／20／21）→ `NO_FX` 回歸（22）→ 完整一輪（23）。**畫面不在本刀。**
