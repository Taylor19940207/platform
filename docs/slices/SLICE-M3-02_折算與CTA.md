# SLICE-M3-02　折算與外幣報表折算差額（CTA）

> 狀態：**事前契約草案，待走查確認**。風險：**第一級**（幣別、金額精度、CTA 物化、
> 匯率版本凍結）。依 2026-08-07 的審查節奏決議，第一級風險先寫契約與負面測試，
> **契約確認後才寫 migration，不先做畫面**。
>
> 對應基線：手冊 v1.2 REQ-FX-001／AC-FX-001／§20 MVP 3；設計書 v1.1 §25.3、§26.6、
> §26.11、§26.12（INV-19／20／22／24）、D-26-05／D-26-06、§28 B-06。

## 為什麼是這一刀

里程碑 2 交付的 `CalculationRun` 一律 `calculation_scope = 'NO_FX'`（0012 的 CHECK），
所有金額只有一種幣別。中國母公司要的是**人民幣**口徑，而日本子公司的帳是**日圓**——
沒有折算，整條鏈的終點就還不是母公司拿得到的東西。這是 MVP 3 的第一個必要條件。

折算也是全案最容易出錯的地方：它同時牽涉幣別角色、匯率版本、方法選擇、精度與尾差，
而且 **CTA 是「算出來的差」而不是「抄來的數」**——錯了不會有任何來源檔案能對照。
因此本刀的產出首先是**六項凍結決定**，其次才是實作。

## 一、幣別角色（INV-22／D-26-06）

**決定：新增 `ReportingUnitCurrencyAssignment`（role × currency × 有效期間 × 批准）。**

- `currency_role`：本刀只實作 **`FUNCTIONAL`（功能幣）** 與 **`REPORTING`（報告幣）**。
  `TRANSACTION`／`SECONDARY_REPORTING` 明列不做（見 §八）。
- **INV-22 兩半都要**：
  (a) 同一 `ReportingUnit` 在**同一時點**只能有一個有效的 `FUNCTIONAL` 指派——
      以排除約束（`daterange` ＋ `EXCLUDE USING gist`）在 DB 強制，不是應用層檢查；
  (b) `CalculationRun` 必須**凍結所使用的指派版本**（見 §六）。
- `ReportingUnit.current_functional_currency` **維持快取語意**（D-26-06），
  折算一律讀有效期間指派，**不得**讀該欄位。快取與指派不一致時以指派為準；
  本刀不新增「同步快取」的觸發器（那會讓快取看起來像真相）。
- 指派需批准（`approved_by`／`approved_at`）。未批准的指派不得被 run 凍結——
  否則「功能幣是誰決定的」在稽核上沒有答案。
- 幣別代碼採 ISO 4217；每個幣別的**最小單位小數位**（JPY 0、CNY 2）為主檔事實，
  不寫死在程式（見 §四）。

不同功能幣的分公司或海外營運單位建成**獨立 ReportingUnit**（D-26-06），本刀不做
單一單位內多功能幣。

## 二、匯率版本（G-07）

**決定：新增 `ExchangeRate`（來源、`rate_type`、幣別對、日期、版本），版本隨期間鎖定凍結。**

- `rate_type ∈ {CLOSING（期末）, AVERAGE（期中）, HISTORICAL（歷史）}`。
- 唯一性：`(rate_version_id, from_currency, to_currency, rate_type, rate_date)`。
- **匯率版本是不可變的集合**：發布後不得改列。改率＝發新版本，既有 run 仍指向舊版本。
- **G-07 的落點與嚴格程度**：`output_capability = NONE`——§28 的守衛表明定 G-07
  「連預覽都不產生」。因此：
  - 現行 `NO_FX` run **維持合法**，不需要匯率版本（它不宣稱任何折算結果）；
  - `FX_TRANSLATION` run 若匯率版本未指定或未凍結，**建立即拒絕**，回穩定代碼
    `G07_RATE_VERSION_NOT_FROZEN:`，不建立半套 run，也不產生預覽。
- **授權**：§24.6 的 `匯率版本 ExchangeRate` 列為 `R2: R S`、`R3: R V`、`R4: R A`、
  `R6: C U`。即：**R6 建立與維護匯率資料，R2 提交，R3 覆核，R4 批准**——
  R2 不得自行批准自己要用的匯率。G-07 的「誰能處理」欄寫 R2／R6，與此一致
  （指定版本是 R2 的事，補資料是 R6 的事）。發布（凍結）視為批准動作，屬 R4。
- 缺率的處理：**逐筆 fail closed**，不得回退到其他 rate_type。缺一筆歷史匯率就
  拒絕整個 run，代碼 `FX_RATE_MISSING:`，並列出缺哪個幣別對、哪個 rate_type、哪一天。

## 三、折算方法（`TranslationPolicyVersion`）

**決定：方法是資料，不是程式碼分支。**

沿用 0023 已凍結的原則——約束由屬性驅動，不得由代碼驅動。折算政策是一張
「科目性質 → rate_type」的對照表並版本化：

| 適用範圍（依 `Account.account_class` 與 `balance_behavior`） | rate_type |
|---|---|
| 資產、負債（STOCK） | `CLOSING` |
| 損益（FLOW） | `AVERAGE` |
| 權益－實收資本等出資項目 | `HISTORICAL`（逐筆） |
| 權益－期初未分配利潤 | `HISTORICAL`（＝前期期末率） |

- 手冊 §233–238 只說「通常」「或以合理方法確定的近似匯率」——因此**方法必須是
  每個客戶批准的政策版本**，不是平台寫死的規則。MVP 3 的離開條件也寫「方法／粒度
  獲確認」：`TranslationPolicyVersion` 帶 `approved_by`／`approved_at`，**未批准的
  政策版本不得被 run 凍結**。
- **權益的歷史匯率是逐筆的**（§28 B-06 線框寫明「權益：歷史匯率（逐筆）」）。
  本刀的決定：需要歷史匯率的科目，若找不到對應的 `HISTORICAL` 觀測，
  **fail closed**（`FX_RATE_MISSING:`），**不得**回退到期末率。
  「靜默用期末率折算實收資本」會直接把 CTA 算錯，且沒有任何跡象。
- 政策版本不涵蓋的科目類別 → 同樣 fail closed（`FX_METHOD_UNRESOLVED:`），
  不設「其他一律期末率」的預設。預設值在這裡就是靜默的錯。

## 四、金額精度與尾差（D-26-05／INV-24）

**決定（在契約層凍結，實作不得自行選擇）：**

| 項目 | 決定 |
|---|---|
| 匯率精度 | `numeric(18,8)`——保存來源提供的位數，不得預先四捨五入 |
| 金額精度 | 目標幣別的**最小單位**（CNY 2 位、JPY 0 位），由幣別主檔決定 |
| 捨入模式 | **`ROUND_HALF_UP`**，逐筆（逐 `BalanceSnapshotLine` × `amount_role`）套用 |
| 捨入時點 | **折算後立即捨入並保存**；不保存未捨入的中間值當作真相 |
| 合計方式 | 合計＝**已捨入金額的加總**，不得由未捨入值另算一次（兩者會不一致） |

捨入模式與時點是 AC-FX-001「重跑結果一致」的一部分：兩台機器對同一輸入必須得到
**逐位元相同**的結果，因此不能依賴任何語言預設的浮點行為——一律 `numeric`。

**尾差（`RoundingTolerance`）**：
- 依 D-26-05 獨立於財務重要性，scope 為
  `ReportingUnit → CurrencyPair → TranslationMethod → AccountClass → OutputProfile`，
  **另行設定與批准**。
- **INV-24 兩層同時滿足**才可自動結案：單筆容許值 **且**
  「同期間 × 同幣別 × 同折算 run」的**累積**容許值。任一層不滿足 → 差異維持 `OPEN`。
- 自動結案標記 `RESOLVED_BY_POLICY` 並記錄政策版本；**紀錄完整保留**，
  不得刪除或合併（§28 B-06 要求把「已自動結案」連同政策版本與累計檢查顯示出來）。
- 本刀**不實作**自動結案的畫面操作，只實作判定與紀錄。

## 五、CTA 顯式物化（INV-20）

**決定：CTA 是一筆系統產生的分錄，不是兩個金額的差。**

INV-20 已明定不得由兩幣別金額相減推導（JPY 與 CNY 單位不同，相減無意義）。本刀要
額外解決兩個**現有模型與 INV-20 對不上的地方**——這正是先寫契約的理由：

**(a) CTA 分錄的 `rule_type` 放哪裡。**
0023 把 `posting_layer.TRANSLATION_ADJUSTMENT` 的 `rule_type` 設為 `NULL`，
並在檔頭寫明「NULL 是有意義的值：逐筆分錄的歸屬隨折算刀」，同時以
`LAYER_RULE_TYPE_UNSET` 顯式拒絕規則版本引用該層。
**決定：維持該層 `rule_type = NULL`，`rule_type` 落在分錄上**——
同一個 TRANSLATION_ADJUSTMENT 層同時承載實體層 CTA（`GROUP_GAAP`）與合併層 CTA
（`CONSOLIDATION`），把它塞回層上就必須拆成兩個層，那是代碼驅動約束的變形。
CTA 分錄的 `rule_type` 必填且只允許這兩值。

**(b) 系統產生的分錄目前無路可走。**
現況 `journal_entry.adjustment_id` 為 **NOT NULL**，且 `fn_journal_entry_layer_guard`
假設分錄一定來自 Adjustment。CTA 沒有 Adjustment。
**決定：新增 `source_kind ∈ {ADJUSTMENT, SYSTEM_TRANSLATION}` 與 `translation_run_id`**，
並以 XOR 約束強制：
- `ADJUSTMENT`：`adjustment_id` 必填、`translation_run_id` 必為 NULL（現行行為不變）；
- `SYSTEM_TRANSLATION`：`adjustment_id` 必為 NULL、`translation_run_id` 必填、
  `posting_layer_id` 必為 `TRANSLATION_ADJUSTMENT`、`rule_type` 必填。
- **`app_runtime` 不得直接寫入 `SYSTEM_TRANSLATION` 分錄**——只能由折算函式在同一
  交易內產生。人手寫得出來的 CTA 不是算出來的 CTA。
- 既有的 `adjustment_version_id` 必填規則只適用 `ADJUSTMENT`；
  `SYSTEM_TRANSLATION` 以 `translation_run_id` 承擔同等的可追溯責任。

**(c) CTA 的金額怎麼定。** 折算後**借貸兩方各自加總**（皆為已捨入的目標幣金額），
差額即為 CTA，記入 TRANSLATION_ADJUSTMENT 層使報表回到平衡。這個數字必須能被
逐科目重算驗證（見 §七的算例），而不是「補平用的插栓」。

## 六、凍結集合與重演（AC-FX-001）

**決定：擴充既有的 `CalculationInputManifest`，不另立一套。**

現況 `calculation_manifest_entry` 已是通用的
`(object_type, object_id, domain_version_kind, domain_version_value, content_hash)`
結構，因此折算只需新增 `object_type`：

    exchange_rate_version         匯率版本
    translation_policy_version    折算政策版本
    currency_assignment           幣別角色指派（INV-22 (b)）
    rounding_tolerance_set        尾差容許值版本集合

- `calculation_run.calculation_scope` 的 CHECK 由 `= 'NO_FX'` 放寬為
  `IN ('NO_FX','FX_TRANSLATION')`。**`NO_FX` 的既有行為完全不變**——
  既有 calculation-run 與 evidence-package 測試即為回歸判準，斷言不得修改。
- `frozen_set_content_hash` 與 `result_content_hash` 涵蓋上述新條目；
  兩者仍**排除** run_id 與時間戳（0012 已凍結的規則）。
- **重演**沿用 02B 的語意：新 run 帶 `replay_of_run_id` 引用**同一份 Manifest**，
  失敗屬 replay run，原 run 永不修改。AC-FX-001 的「指定實體、期間與匯率版本重跑
  結果一致」即以此證明。
- **`TranslationResult` 提供反查**：掛在 `BalanceSnapshotLine` 之下，
  `amount_role` ＋ `currency_code` ＋ `amount` ＋ `source_amount_ref`（被折算的來源金額）
  ＋ `fx_rate_ref`（用了哪一筆匯率）＋ `translation_method` ＋ `translation_run_id`。
  **INV-19**：同一 SnapshotLine 下每個 `amount_role` 至多一筆——DB 唯一索引。
- `balance_snapshot_line.posting_layer` 的 CHECK 由 `('SOURCE_TB','ADJUSTMENT')`
  增加 `'TRANSLATION_ADJUSTMENT'`。
- **雙幣寬表不做**：設計書已註明 `amount_functional`／`amount_reporting` 寬表僅為
  查詢效能，**不是模型的一部分**；`TranslationResult` 是邏輯真相。

## 七、驗收算例（Case-001，手算）

沿用 `tests/fixtures/case-001/expected_adjusted_group_tb_2026-03.csv`（JPY，調整後集團 TB，
借貸各 59,000,000）。功能幣 JPY、報告幣 CNY。匯率版本 `2026-03 v1`：

| rate_type | 幣別對 | 率 |
|---|---|---|
| `CLOSING` 2026-03-31 | JPY→CNY | 0.048120 |
| `AVERAGE` 2026-03 | JPY→CNY | 0.047950 |
| `HISTORICAL`（實收資本，出資日） | JPY→CNY | 0.050000 |
| `HISTORICAL`（期初未分配利潤＝前期期末） | JPY→CNY | 0.049000 |

| 科目 | JPY 淨額 | 方法 | CNY |
|---|---:|---|---:|
| 1001 库存现金 | 350,000 D | CLOSING | 16,842.00 D |
| 1002 银行存款 | 9,650,000 D | CLOSING | 464,358.00 D |
| 1122 应收账款 | 5,600,000 D | CLOSING | 269,472.00 D |
| 1405 库存商品 | 2,300,000 D | CLOSING | 110,676.00 D |
| 1601 固定资产 | 4,600,000 D | CLOSING | 221,352.00 D |
| 2202 应付账款 | 3,900,000 C | CLOSING | 187,668.00 C |
| 2221 应交税费 | 800,000 C | CLOSING | 38,496.00 C |
| 4001 实收资本 | 10,000,000 C | HISTORICAL | 500,000.00 C |
| 4104 未分配利润 | 2,100,000 C | HISTORICAL | 102,900.00 C |
| 6001 主营业务收入 | 42,000,000 C | AVERAGE | 2,013,900.00 C |
| 6401 主营业务成本 | 21,700,000 D | AVERAGE | 1,040,515.00 D |
| 6602 管理费用 | 14,600,000 D | AVERAGE | 700,070.00 D |

借方合計 **2,823,285.00**、貸方合計 **2,842,964.00**。

    CTA ＝ 2,842,964.00 − 2,823,285.00 ＝ 19,679.00（借方）

物化為 `PostingLayer = TRANSLATION_ADJUSTMENT`、`rule_type = GROUP_GAAP`、
`source_kind = SYSTEM_TRANSLATION` 的分錄，帶 `translation_run_id`。加入後借貸皆為
2,842,964.00。**這個數字是驗收判準**——不是「系統算出多少就是多少」。

**捨入判準另用一個刻意不整除的案例**（上表以整除設計，好讓 CTA 唯一可驗）：
`HISTORICAL` 改 0.0481233 時，1001 為 350,000 × 0.0481233 ＝ 16,843.155 →
`ROUND_HALF_UP` 2 位 → **16,843.16**。若實作用了 banker's rounding 會得 16,843.15，
測試必須轉紅。

## 八、不做

- **不解鎖期間狀態機**：`ADJ_APPROVED → CALCULATING` 與其後各段在 0028 的規格函式中
  維持 `NOT_IMPLEMENTED`。折算在本刀屬 **`CalculationRun` 範圍**（沿用 02B 的
  `run_type = PREVIEW`），期間仍停在 `ADJ_APPROVED`。理由：解鎖 `CALCULATING` 需要
  同時具備 G-07、調節核對與 G-03（B 基礎），那是下一刀；現在動它會讓 0028 的規格與
  期間套件 68 條斷言變成「計畫中的差異」而不是回歸釘子。**解鎖條件寫在本節，
  不留給下一個 session 猜。**
- **不做 REQ-CFS-001（現金流）**：它與 REQ-FX-001 同屬 §20 的 MVP 3 列，但本刀只做折算。
  `CashFlowClass` 維持 P0 的「保存與映射」，不重建現金流量表。
- 不做 `TRANSACTION`／`SECONDARY_REPORTING` 兩個 `amount_role`。
- 不做首次導入的期初與歷史匯率橋接（REQ-PER-101／AC-PER-101）——那是獨立一刀。
- 不做合併層 CTA（`rule_type = CONSOLIDATION`）的**產生**：本刀只保留該值的合法性，
  合併與抵銷不在 MVP 3。
- 不做匯率來源的自動抓取或 API 整合（R6 手動維護）。
- 不做 B-06 的折算畫面。畫面在契約與 DB 驗證完成後另開一刀。
- 不做雙幣寬表、不做交易級外幣重估（後者是 A 基礎的既有結果，§24 邊界已排除）。

## 九、驗收

1. **INV-22 (a)**：同一 ReportingUnit 同一時點插入第二個有效 `FUNCTIONAL` → DB 拒絕。
2. **INV-22 (b)**：run 的 Manifest 含 `currency_assignment` 條目；
   指派其後變更不影響既有 run 的重演結果。
3. **G-07**：`FX_TRANSLATION` run 未指定或未凍結匯率版本 → 建立即拒絕、
   **不產生任何 run 與預覽**、`output_capability = NONE`；`NO_FX` run 不受影響。
4. **缺率 fail closed**：缺一筆 `HISTORICAL` → 整個 run 拒絕並列出缺哪一筆；
   **反證：加入「找不到就用期末率」的回退 → 測試必須轉紅**。
5. **算例**：§七逐科目 12/12 相符，CTA ＝ 19,679.00 借方，且 CTA 為
   `SYSTEM_TRANSLATION` 分錄而非計算欄位。
6. **INV-20 反證**：把 CTA 改成由兩幣別合計相減求得 → 測試必須轉紅
   （相減得到的是同一個數字，因此判準必須釘在**分錄是否存在與可追溯**，不是數值）。
7. **INV-19**：同一 SnapshotLine 同一 `amount_role` 插入第二筆 → DB 拒絕。
8. **捨入**：§七的 `ROUND_HALF_UP` 案例；改成 banker's rounding → 轉紅。
9. **INV-24**：單筆通過但累積超限的尾差 → 維持 `OPEN`，不得自動結案；
   **反證：只檢查單筆 → 測試必須轉紅**。
10. **重演**：同一 Manifest 重跑，`result_content_hash` 完全相同；
    改匯率版本後重跑 → 產生新 run，舊 run 不變。
11. **`SYSTEM_TRANSLATION` 不可人手寫入**：`app_runtime` 直接 INSERT → 拒絕。
12. **既有 `NO_FX` 行為不變**：calculation-run 33 條與 evidence-package 31 條
    **斷言一字不改**全綠。
13. 完整測試一輪全綠。

## 十、風險

**第一級。** 三個真正的風險：

1. **CTA 算錯而無人察覺**——它沒有來源檔案可對照。緩解：§七的手算算例是唯一判準，
   且驗收 6 釘住「必須是分錄」而非「數字對就好」。
2. **靜默回退**（缺率用期末率、未涵蓋科目用預設方法）——會產生看起來正常、實際錯誤的
   報表。緩解：全部 fail closed，驗收 4 與 §三的方法未解析各有反證。
3. **精度與捨入不確定**——重演不一致會讓 AC-FX-001 直接不成立。緩解：精度、捨入模式、
   捨入時點、合計方式四項在契約層凍結，實作不得自行選擇。

實作順序（契約確認後）：
migration（幣別指派 → 匯率 → 政策 → 尾差 → JE 系統來源 → TranslationResult ＋ manifest 擴充）
→ DB 負面測試（1／2／3／4／7／9／11）→ 折算函式 → 算例驗收（5／6／8／10）
→ `NO_FX` 回歸（12）→ 完整一輪（13）。**畫面不在本刀。**
