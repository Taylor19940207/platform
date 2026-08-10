# SLICE-M3-02　折算與外幣報表折算差額（CTA）

> 狀態：**事前契約 第二版（走查修訂後）**，待確認；**尚未批准進 migration**。
> 風險：**第一級**（幣別、金額精度、CTA 物化、匯率版本凍結、權益折算）。
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

## 一、幣別角色（INV-22／D-26-06）

**`ReportingUnitCurrencyAssignment`（role × currency × 有效期間 × 批准）。**

- `currency_role`：本刀實作 **`FUNCTIONAL`** 與 **`REPORTING`**。
- **兩個角色都限制同一時點各一個有效指派**，以 `daterange` ＋ `EXCLUDE USING gist`
  在 DB 強制。REPORTING 現在就不允許多值——多值卻沒有選擇規則，等於把「用哪個報告幣」
  留給實作當下猜。日後要第二報告幣時新增 `SECONDARY_REPORTING`（本刀不做）。
- **run 同時凍結兩者**（INV-22 (b)），見 §六。
- `ReportingUnit.current_functional_currency` **維持快取語意**（D-26-06）；折算一律讀
  有效期間指派，**不得**讀該欄位，也不新增同步觸發器——那會讓快取看起來像真相。
- 指派需批准（`approved_by`／`approved_at`）。未批准的指派不得被 run 凍結，
  否則「功能幣是誰決定的」在稽核上沒有答案。
- 幣別代碼採 ISO 4217；**最小單位小數位**（JPY 0、CNY 2）是幣別主檔事實，不寫死在程式。

## 二、匯率：版本與觀測分離

**決定：拆成兩層。**

    ExchangeRateVersion          工作流與不可變版本（DRAFT → SUBMITTED → APPROVED）
    └─ ExchangeRateObservation   實際匯率列

**報價方向（唯一，不接受另一種寫法）：**

    target_amount = source_amount × rate        （rate 為 from_currency → to_currency）

- **只接受直接幣別對**。本刀**不做倒數推算，也不做交叉匯率**：JPY→CNY 就必須有
  JPY→CNY 的觀測，不得由 CNY→JPY 取倒數，也不得經 USD 換算。缺就 fail closed。
  倒數與交叉都會引入第二個捨入點，讓重演與勾稽失去唯一解。
- **各 rate_type 的期間語意不同，不能共用一個模糊的 `rate_date`**：

  | `rate_type` | 期間欄位 | 語意 |
  |---|---|---|
  | `CLOSING` | `measurement_date`（精確計量日） | 資產負債表日即期匯率 |
  | `AVERAGE` | `coverage_start` ／ `coverage_end` | 該區間的平均或合理近似 |
  | `HISTORICAL` | `event_date` | 對應某一次權益事件的發生日 |

  `AVERAGE` 的覆蓋區間必須**涵蓋**所折算期間，否則拒絕（`FX_RATE_COVERAGE_MISMATCH:`）。
  「用 3 月平均折算 2 月」是安靜的錯，必須擋。
- **凍結規則**：`SUBMITTED` 後匯率列與期間欄位凍結；`APPROVED` 後**整版不可變**
  （含新增觀測）。改率＝發新版本，既有 run 仍指向舊版本。
- **G-07 的嚴格程度**：`output_capability = NONE`——§28 守衛表明定「連預覽都不產生」。
  - 既有 `NO_FX` run **維持合法**，不需要匯率版本（它不宣稱任何折算結果）；
  - `FX_TRANSLATION` run 若匯率版本未指定或未 `APPROVED`，**建立即拒絕**，
    穩定代碼 `G07_RATE_VERSION_NOT_FROZEN:`，不建立半套 run，不產生預覽。
- **缺率逐筆 fail closed**：`FX_RATE_MISSING:`，列出缺哪個幣別對、哪個 `rate_type`、
  哪一天／哪個區間。**不得回退到其他 rate_type**。
- **授權**（§24.6 `匯率版本 ExchangeRate` 列）：R6 `C U` 建立與維護、R2 `R S` 提交、
  R3 `R V` 覆核、R4 `R A` 批准。R2 不得自行批准自己要用的匯率。

## 三、折算分類與方法

### 3.1 科目模型不足，必須補分類

現有 `account` 只有 `balance_behavior = STOCK／FLOW`，不足以選擇方法；即使補上
ASSET／LIABILITY／EQUITY 也**分不出實收資本、保留盈餘、股利分配與其他權益變動**，
而這四者的折算處理完全不同。

**決定：新增受控的 `translation_category`（八值，不得由科目代碼推斷）：**

    ASSET  LIABILITY  INCOME  EXPENSE
    EQUITY_CONTRIBUTED  EQUITY_RETAINED  EQUITY_DISTRIBUTION  EQUITY_OTHER

- 掛在 `Account` 上，屬集團科目表的事實（與 `MappingRule` 的目標科目一致）。
- **每個納入 run 的科目必須恰好命中一條 policy rule**：缺漏 → `FX_METHOD_UNRESOLVED:`；
  重疊 → `FX_METHOD_AMBIGUOUS:`。兩者都拒絕整個 run。
- 不設「其他一律期末率」的預設。預設值在這裡就是靜默的錯。

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

`TranslationPolicyVersion` 另須凍結 **CTA 落點**（見 §五）。

### 3.3 `EquityTranslationLot`：權益的歷史匯率需要資料來源

「實收資本逐筆歷史匯率」在 TB 上**無法取得**——TB 只有餘額，沒有每次出資的日期。

**決定：新增 `EquityTranslationLot`（權益折算批次）：**

    account_id                  科目
    event_date                  出資／權益變動日期
    functional_amount           功能幣金額
    exchange_rate_observation_id 歷史匯率觀測（HISTORICAL，event_date 相符）
    evidence_ref / approved_by / approved_at   證據與批准快照
    version / superseded_by     有效版本鏈

- **合計一致性（fail closed）**：某科目所有 **active** lots 的 `functional_amount` 合計
  必須等於該科目的功能幣餘額，否則整個 run 拒絕，代碼 `EQUITY_LOT_SUM_MISMATCH:`，
  並列出科目、餘額與 lots 合計。差一塊錢就代表有一次出資沒被記錄，
  其歷史匯率也就沒被使用——那筆差額會被靜默吸收進 CTA。
- lots 集合的版本被 run 凍結（見 §六）。

### 3.4 保留盈餘：延續橋接，不是「餘額 × 某率」

**這是本版最重要的更正。** 保留盈餘不得以 JPY 餘額乘上任何單一匯率。CAS 19 的處理是
由歷史已折算餘額**延續**：

    期末保留盈餘（報告幣）
      ＝ 前期已鎖定的期末已折算保留盈餘
      ＋ 本期已折算損益
      －  已折算股利／分配
      ±  其他已批准的權益變動

- 在**試算表**層次（本刀的輸出形式），`EQUITY_RETAINED` 一行呈現的是**期初**已折算
  保留盈餘；本期損益仍在 `INCOME`／`EXPENSE` 各科目（已按 `AVERAGE` 折算），
  結帳分錄不在本刀範圍。因此上式在 TB 上自動成立，可作為**勾稽檢查**：
  期末已折算 RE ＝ 期初已折算 RE ＋ 本期已折算損益淨額。
- **期初已折算保留盈餘是明示且經批准的輸入**（`EquityOpeningTranslatedBalance`：
  reporting_unit × period_revision × account × 報告幣金額 × 批准 × 版本），
  由前期鎖定的期末值產生；**首期或找不到時 fail closed**，
  代碼 `FX_OPENING_EQUITY_MISSING:`。
  首次導入的期初橋接方法（REQ-PER-101）本身不在本刀——本刀只要求那個值**存在且經批准**。
- 該輸入的版本被 run 凍結。

## 四、金額精度

| 項目 | 決定 |
|---|---|
| 匯率精度 | `numeric(18,8)`——保存來源提供的位數，不得預先四捨五入 |
| 金額精度 | 目標幣別的**最小單位**（CNY 2 位、JPY 0 位），由幣別主檔決定 |
| 捨入模式 | **`ROUND_HALF_UP`**，**逐行**（逐 `BalanceSnapshotLine`）套用 |
| 捨入時點 | 折算後立即捨入並保存；不保存未捨入的中間值當作真相 |
| 合計方式 | 合計＝**已捨入金額的加總**，不得由未捨入值另算一次 |
| 運算型別 | **全程 `numeric`；任何金額或匯率都不得進入 JavaScript `Number`** |

最後一條是硬性的：`Number` 是 IEEE 754 雙精度，`0.1 + 0.2 !== 0.3`，一旦金額經過它，
AC-FX-001 的「重跑結果一致」就只是碰巧成立。折算計算**在 DB 內以 `numeric` 完成**，
應用層只搬運字串。

**`RoundingTolerance` 與尾差自動結案移到下一刀。** 理由有二：
(a) D-26-05 的 scope 鏈包含尚未實作的 `OutputProfile`；
(b) INV-24 管的是**調節差異的自動結案**，不是 CTA 計算本身。本刀只凍結逐行
`ROUND_HALF_UP`，不引入任何容許值概念——沒有門檻，就沒有「被吃掉的差」。

## 五、CTA：獨立的報告層調整，不冒充一般分錄

### 5.1 為什麼不能塞進 `JournalEntry`

現有 `JournalEntry` 的語意是**借貸平衡**（`fn_journal_entry_*` 守衛與 `journal_line`
的平衡檢查都建立在此）。CTA 是為了補足「折算後借貸總額差」，本質上是**單邊的報告層
調整**：只記借方 97,159 的普通分錄本身不平；硬補一筆貸方對應列，又等於憑空造出一個
不存在的科目餘額，反而修正不了折算差額。

**決定：獨立成新實體，不動 `JournalEntry`。**

    TranslationAdjustmentEntry
    ├─ calculation_run_id / reporting_unit_id / period_revision_id
    ├─ posting_layer_id = TRANSLATION_ADJUSTMENT
    ├─ rule_type ∈ {GROUP_GAAP, CONSOLIDATION}      本刀只產生 GROUP_GAAP
    ├─ translation_policy_version_id / exchange_rate_version_id
    └─ TranslationAdjustmentLine［］
       └─ account_id / debit / credit / 說明

- `rule_type` **落在分錄上，不落在層上**——0023 已把 `TRANSLATION_ADJUSTMENT` 層的
  `rule_type` 設為 `NULL` 並註明「逐筆分錄的歸屬隨折算刀」，同時以
  `LAYER_RULE_TYPE_UNSET` 拒絕規則版本引用該層。同一層要同時承載實體層 CTA
  （`GROUP_GAAP`）與合併層 CTA（`CONSOLIDATION`），塞回層上就得拆成兩個層，
  那是代碼驅動約束的變形。
- **`app_runtime` 不得直接寫入**——只能由折算函式在同一交易內產生。
  人手寫得出來的 CTA 不是算出來的 CTA。
- 完成後物化進 `BalanceSnapshotLine`（`posting_layer = TRANSLATION_ADJUSTMENT`），
  與 `SOURCE_TB`／`ADJUSTMENT` 兩層並列。

### 5.2 CTA 科目必須被凍結

系統若只知道金額而不知道應落在哪個科目，CTA 就無法出現在報表上。
**`TranslationPolicyVersion` 必須凍結：**

    cta_account_id              CTA 科目
    cta_coa_id                  該科目所屬的集團科目表（版本）
    applicable_reporting_unit   適用報告單位
    approved_by / approved_at   批准版本

`cta_account_id` 的科目必須屬於 `cta_coa_id`，且該 COA 必須是本案件的集團科目表——
否則拒絕（`CTA_ACCOUNT_SCOPE_INVALID:`）。

### 5.3 CTA 金額怎麼定

折算後借貸兩方各自加總（皆為已捨入的目標幣金額），差額即為 CTA。它必須能被逐科目
重算驗證（§七），而不是「補平用的插栓」。

## 六、凍結集合與重演（AC-FX-001）

**擴充既有 `CalculationInputManifest`，不另立一套。** 現況
`calculation_manifest_entry` 已是通用的
`(object_type, object_id, domain_version_kind, domain_version_value, content_hash)`
結構，因此只需新增 `object_type`：

    exchange_rate_version              匯率版本
    translation_policy_version         折算政策版本（含 CTA 科目凍結）
    currency_assignment                幣別角色指派（FUNCTIONAL 與 REPORTING 各一筆）
    equity_translation_lot_set         權益折算批次集合
    equity_opening_translated_balance  期初已折算權益餘額

- **每一條都必須同時保存 `object_id` 與 `content_hash`**，不得只存版本 ID——
  同一 ID 的內容若日後漂移（即使有不可變約束，資料修復或遷移仍可能發生），
  只比 ID 的重演會宣稱一致而實際不同。
- `calculation_input_manifest.calculation_scope` 的 CHECK 由 `= 'NO_FX'` 放寬為
  `IN ('NO_FX','FX_TRANSLATION')`（**該欄在 manifest 上，不在 `calculation_run`**）。
  **`NO_FX` 的既有行為完全不變**——calculation-run 33 條與 evidence-package 31 條
  即為回歸判準，斷言不得修改。
- `frozen_set_content_hash` 與 `result_content_hash` 涵蓋新條目；兩者仍**排除**
  run_id 與時間戳（0012 已凍結的規則）。
- **重演**沿用 02B：新 run 帶 `replay_of_run_id` 引用**同一份 Manifest**，失敗屬
  replay run，原 run 永不修改。

### `TranslationResult`：方向明確、可反查

不使用「一個正負不明的 `amount`」，與既有快照的借貸表示保持一致：

    source_snapshot_line_id       被折算的來源行
    amount_role                   本刀固定 REPORTING
    currency_code
    source_debit / source_credit  來源（功能幣）金額
    result_debit / result_credit  折算後（報告幣）金額
    exchange_rate_observation_id  用了哪一筆觀測（HISTORICAL 時指向 lot 的觀測）
    translation_policy_rule_id    命中哪一條政策規則
    equity_lot_id                 逐筆權益折算時指向來源 lot（其餘為 NULL）
    calculation_run_id

- **INV-19**：`(source_snapshot_line_id, amount_role)` 唯一索引。
- **雙幣寬表不做**：設計書已註明 `amount_functional`／`amount_reporting` 寬表僅為查詢
  效能，不是模型的一部分；`TranslationResult` 是邏輯真相。

## 七、驗收算例（Case-001，手算）

來源：`tests/fixtures/case-001/expected_adjusted_group_tb_2026-03.csv`（JPY，調整後集團
TB，借貸各 59,000,000）。功能幣 JPY、報告幣 CNY。匯率版本 `2026-03 v1`（已 APPROVED）：

| `rate_type` | 期間欄位 | JPY→CNY |
|---|---|---|
| `CLOSING` | `measurement_date = 2026-03-31` | 0.048120 |
| `AVERAGE` | `coverage 2026-03-01 ～ 2026-03-31` | 0.047950 |
| `HISTORICAL` | `event_date = 2018-06-15` | 0.061000 |
| `HISTORICAL` | `event_date = 2022-09-01` | 0.051000 |

`EquityTranslationLot`（4001 实收资本，合計 JPY 10,000,000 ＝ 該科目功能幣餘額 ✓）：

| `event_date` | 功能幣 | 觀測 | 報告幣 |
|---|---:|---|---:|
| 2018-06-15 | 7,000,000 | 0.061000 | 427,000.00 |
| 2022-09-01 | 3,000,000 | 0.051000 | 153,000.00 |

`EquityOpeningTranslatedBalance`（4104 未分配利润，經批准）：**CNY 100,380.00**。

| 科目 | 分類 | JPY 淨額 | 方法 | CNY |
|---|---|---:|---|---:|
| 1001 库存现金 | ASSET | 350,000 D | CLOSING | 16,842.00 D |
| 1002 银行存款 | ASSET | 9,650,000 D | CLOSING | 464,358.00 D |
| 1122 应收账款 | ASSET | 5,600,000 D | CLOSING | 269,472.00 D |
| 1405 库存商品 | ASSET | 2,300,000 D | CLOSING | 110,676.00 D |
| 1601 固定资产 | ASSET | 4,600,000 D | CLOSING | 221,352.00 D |
| 2202 应付账款 | LIABILITY | 3,900,000 C | CLOSING | 187,668.00 C |
| 2221 应交税费 | LIABILITY | 800,000 C | CLOSING | 38,496.00 C |
| 4001 实收资本 | EQUITY_CONTRIBUTED | 10,000,000 C | 逐筆 lots | **580,000.00 C** |
| 4104 未分配利润 | EQUITY_RETAINED | 2,100,000 C | **延續橋接（不乘匯率）** | **100,380.00 C** |
| 6001 主营业务收入 | INCOME | 42,000,000 C | AVERAGE | 2,013,900.00 C |
| 6401 主营业务成本 | EXPENSE | 21,700,000 D | AVERAGE | 1,040,515.00 D |
| 6602 管理费用 | EXPENSE | 14,600,000 D | AVERAGE | 700,070.00 D |

借方合計 **2,823,285.00**、貸方合計 **2,920,444.00**。

    CTA ＝ 2,920,444.00 − 2,823,285.00 ＝ 97,159.00（借方）

物化為 `TranslationAdjustmentEntry`（`rule_type = GROUP_GAAP`、
`posting_layer = TRANSLATION_ADJUSTMENT`、落在凍結的 `cta_account_id`），加入後借貸
皆為 2,920,444.00。

**CTA 為借方（權益減項）是合理的**：出資時 1 JPY 值 0.061／0.051 CNY，期末只值
0.048120——功能幣相對報告幣貶值，以歷史匯率入帳的權益在報告幣下高於以期末匯率折算的
淨資產，差額落在借方。**若實作把 CTA 算成貸方，方向就是錯的**，驗收會擋下。

**RE 勾稽**（§3.4 的算式在 TB 上的表現）：
本期已折算損益淨額 ＝ 2,013,900.00 − 1,040,515.00 − 700,070.00 ＝ **273,315.00**；
期末已折算保留盈餘 ＝ 100,380.00 ＋ 273,315.00 ＝ **373,695.00**。

**捨入判準另用刻意不整除的案例**（上表以整除設計，好讓 CTA 唯一可驗）：
觀測改 0.0481233 時，1001 為 350,000 × 0.0481233 ＝ 16,843.155 →
`ROUND_HALF_UP` 2 位 → **16,843.16**。banker's rounding 會得 16,843.15，測試必須轉紅。

## 八、不做

- **不解鎖期間狀態機**：`ADJ_APPROVED → CALCULATING` 及其後各段在 0028 的規格函式中
  維持 `NOT_IMPLEMENTED`。本刀只建立可重演的 `FX_TRANSLATION` **PREVIEW**
  `CalculationRun`；期間仍停在 `ADJ_APPROVED`。**解鎖條件**：下一刀具備調節核對
  （含 INV-24 與 `RoundingTolerance`）與 G-03／G-07 的期間級判定後，才處理該遷移。
- **不做 REQ-CFS-001（現金流）**：**另開 MVP 3 現金流切片；未完成前 MVP 3 不得關閉。**
  現行程式與 schema 中尚無 `CashFlowClass`，不得寫成「維持 P0 保存與映射」。
- **不做 `RoundingTolerance` 與尾差自動結案**（INV-24）——移到下一刀調節核對（見 §四）。
- 不做 `TRANSACTION`／`SECONDARY_REPORTING` 兩個 `amount_role`，也不做第二報告幣。
- 不做首次導入的期初橋接**方法**（REQ-PER-101）；本刀只要求
  `EquityOpeningTranslatedBalance` 存在且經批准。
- 不做合併層 CTA（`rule_type = CONSOLIDATION`）的**產生**：只保留該值的合法性。
- 不做倒數與交叉匯率、不做匯率來源自動抓取（R6 手動維護）。
- 不做 B-06 的折算畫面。畫面在 DB 驗證完成後另開一刀。
- 不做雙幣寬表、不做交易級外幣重估（後者是 A 基礎的既有結果，§24 邊界已排除）。

## 九、驗收

1. **INV-22 (a)**：同一 ReportingUnit 同一時點插入第二個有效 `FUNCTIONAL` → DB 拒絕；
   `REPORTING` 同樣拒絕。
2. **INV-22 (b)**：Manifest 含 `currency_assignment` 兩筆；指派其後變更不影響既有 run 的
   重演結果。
3. **G-07**：`FX_TRANSLATION` run 未指定或匯率版本未 `APPROVED` → **建立即拒絕**、
   不產生任何 run 與預覽；`NO_FX` run 不受影響。
4. **缺率 fail closed**：缺一筆 `HISTORICAL` → 整個 run 拒絕並列出缺哪一筆。
   **反證：加入「找不到就用期末率」的回退 → 測試必須轉紅。**
5. **報價方向與直接幣別對**：只有 CNY→JPY 觀測時，JPY→CNY 折算必須拒絕，
   **不得取倒數**；反證：加入倒數推算 → 轉紅。
6. **`AVERAGE` 覆蓋區間**：以 2 月的 AVERAGE 折算 3 月 → 拒絕。
7. **分類解析**：科目缺 policy rule → `FX_METHOD_UNRESOLVED:`；命中兩條 →
   `FX_METHOD_AMBIGUOUS:`；兩者皆拒絕整個 run。
8. **`EQUITY_RETAINED` 不得乘匯率**：反證——把 4104 改成 `餘額 × CLOSING`
   → 算例轉紅（CTA 不再是 97,159.00）。
9. **lots 合計一致**：把一筆 lot 的 `functional_amount` 改小 → `EQUITY_LOT_SUM_MISMATCH:`
   拒絕整個 run，**不得**把差額靜默併入 CTA。
10. **期初已折算餘額缺失** → `FX_OPENING_EQUITY_MISSING:` 拒絕。
11. **算例**：§七逐科目 12/12 相符；**CTA ＝ 97,159.00 且在借方**；
    RE 勾稽 100,380.00 ＋ 273,315.00 ＝ 373,695.00。
12. **INV-20 反證**：把 CTA 改成由兩幣別合計相減得出 → 轉紅。
    （相減得到同一個數字，因此判準釘在**分錄是否存在、是否可追溯到政策版本與匯率版本**，
    不是數值本身。）
13. **CTA 落點**：`cta_account_id` 不屬於本案件集團科目表 → 拒絕；
    政策版本未凍結 CTA 科目 → 拒絕。
14. **INV-19**：同一 `(source_snapshot_line_id, amount_role)` 插入第二筆 → DB 拒絕。
15. **`TranslationAdjustmentEntry` 不可人手寫入**：`app_runtime` 直接 INSERT → 拒絕。
16. **捨入**：§七的 `ROUND_HALF_UP` 案例；改 banker's rounding → 轉紅。
17. **重演**：同一 Manifest 重跑 `result_content_hash` 完全相同；改匯率版本後重跑 →
    產生新 run，舊 run 不變。**反證：Manifest 只存版本 ID 不存 content hash，
    再竄改該版本內容 → 重演必須失敗**。
18. **既有 `NO_FX` 行為不變**：calculation-run 33 條與 evidence-package 31 條
    **斷言一字不改**全綠。
19. 完整測試一輪全綠。

## 十、風險

**第一級。** 四個真正的風險：

1. **權益折算錯而無人察覺**——保留盈餘若被當成「餘額 × 某率」，數字看起來正常，
   CTA 卻整個錯。緩解：§3.4 的延續橋接、驗收 8 的反證、RE 勾稽等式。
2. **靜默回退**（缺率用期末率、倒數推算、未涵蓋科目用預設方法、lots 差額併入 CTA）——
   會產生看起來正常、實際錯誤的報表。緩解：全部 fail closed，驗收 4／5／7／9 各有反證。
3. **精度與捨入不確定**——重演不一致會讓 AC-FX-001 直接不成立。緩解：精度、捨入模式、
   捨入時點、合計方式、**不得進 JS `Number`** 五項在契約層凍結。
4. **CTA 冒充一般分錄**——塞進 `JournalEntry` 會破壞借貸平衡語意或造出假餘額。
   緩解：獨立實體 `TranslationAdjustmentEntry`。

實作順序（契約確認後）：
migration（幣別指派 → 匯率版本／觀測 → `translation_category` → 政策版本＋CTA 科目 →
權益 lots 與期初已折算餘額 → `TranslationAdjustmentEntry`／Line → `TranslationResult`
＋ manifest 擴充與 `calculation_scope` 放寬）
→ DB 負面測試（1～10、13～15）→ 折算函式（DB 內 `numeric`）
→ 算例驗收（11／12／16／17）→ `NO_FX` 回歸（18）→ 完整一輪（19）。**畫面不在本刀。**
