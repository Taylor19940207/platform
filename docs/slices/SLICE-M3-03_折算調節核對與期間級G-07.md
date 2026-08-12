# SLICE-M3-03　折算調節核對與期間級 G-07

> 狀態：**事前契約 第二版（走查修訂後）**，待確認。**尚未批准進 migration。**
> 風險：**第一級**（尾差自動結案、期間級守衛、不可逆語意）。
>
> 對應基線：設計書 v1.1 §25.8（`RECONCILING`）、§25.13 守衛表（G-07）、
> §26.5、§26.12（INV-24）、D-26-05；手冊 v1.2 §20 MVP 3、AC-FX-001。
> 前置：`SLICE-M3-02 折算與 CTA`（CLOSED／PASS，migration 0030–0035）。

## 為什麼是這一刀

折算引擎已能產生結果並可重演，但**沒有人檢查那個結果自洽**。目前只有函式內部
的算式保證借貸平衡；一旦引擎有缺陷、或凍結集合與產出對不上，系統沒有任何獨立的
第二次驗算會發現。而期間主線（`ADJ_APPROVED → CALCULATING` 及其後）要能解鎖，
第一個前置就是 **G-07 從「有沒有匯率版本」升級為「這一期的折算是否真的做完且對得起來」**。

因此本刀做兩件事：**折算調節核對**（run 級，產生可稽核的差異清單）與
**期間級 G-07 判定**（period 級，聚合所有 FX run 的結論）。

**不做**：B-06 折算／核對畫面、現金流（REQ-CFS-001）、`ADJ_APPROVED → CALCULATING`
的實際解鎖（見 §七）。

## 一、調節對象（四項比較，同一 FX run 內）

調節的對象是**同一個 FX run**，不跨 run、不跨期間。四項比較缺一不可：

| # | 比較 | 判準 |
|---|---|---|
| C1 | **折算前功能幣快照** vs 凍結的來源快照 | FX run 的 `BalanceSnapshotLine`（功能幣）必須逐列等於 `SOURCE_CALCULATION_RUN` payload 的 lines；且功能幣借貸合計必須平衡 |
| C2 | **報告幣 `TranslationResult`** vs 功能幣快照 ×（凍結的）方法與匯率 | 每一列的 `result_debit／result_credit` 必須等於由**凍結 payload** 重算的值；`source_debit／source_credit` 必須等於快照軋差後的餘額 |
| C3 | **CTA** vs 報告幣借貸合計差額 | `TranslationAdjustmentLine` 的金額必須等於「非 CTA 列的報告幣貸方合計 − 借方合計」，且方向一致 |
| C4 | **折算後報告幣借貸平衡** | 含 CTA 之後，報告幣借貸合計必須相等 |

- 四項比較各自產生零到多筆 `TranslationDifference`；**沒有差異時仍必須留下
  調節物件**（否則「有沒有核對過」與「核對過但沒差異」無法區分）。

### C2 的實作界線（寫死，否則不是第二次驗算）

「獨立重算」必須是**獨立的公式實作**，不是同一支函式跑兩次：

| 不得 | 可以 |
|---|---|
| 呼叫 `fn_fx_materialize()`／`fn_fx_materialize_verified()` | 共用 `fn_fx_verify_manifest()` |
| 讀 `TranslationResult` 當期望值 | 共用 SHA-256 helper |
| 讀任何現行主檔 | 共用**純數值**的 rounding helper（無 I/O、無查表） |
| — | 只讀**已驗證**的 Manifest payload |

重算函式必須**逐列輸出 expected value**，再與 `TranslationResult` 比對；
兩者的差額就是 C2 的差異。共用計算主體會讓引擎缺陷同時出現在兩邊而互相抵銷——
那時調節永遠通過，等於沒有第二次驗算。

## 二、差異分類（六值，職責明確）

    ROUNDING_DIFFERENCE   純算術尾差（幣別最小單位層級）
    MISSING_RATE          所需匯率在凍結集合中不存在或不涵蓋所需期間
    METHOD_UNRESOLVED     科目分類缺失、或分類在凍結政策中沒有對應規則
    SOURCE_MISMATCH       C1 不成立：功能幣快照與凍結來源不一致
    CTA_MISMATCH          C3／C4 不成立：CTA 金額或方向與合計差額不符
    UNEXPLAINED           以上皆非

**缺率、方法未解析、來源不符一律不得歸入尾差。** 以 CHECK 強制：
`reason_class = 'ROUNDING_DIFFERENCE'` 是 `RESOLVED_BY_POLICY` 的**必要條件**
（另需 §四之一的算術推導）；其餘五類**不得**被自動結案。
人可以用 `EXPLAINED`／`ACCEPTED_EXCEPTION` 記錄調查結論，但**那不改變 G-07**——
修復路徑是重新建立正確的 FX run 並重新選定，不是把差異標掉。

> 這條是本刀最容易被繞過的地方：把缺率當尾差吃掉，報表看起來乾淨，
> 而真正的問題是「有一段金額根本沒有匯率可折算」。

`resolution_status` 沿用 0023 已凍結的詞彙（共用詞彙，不共用實體）：
`OPEN／EXPLAINED／RESOLVED／RESOLVED_BY_POLICY／ACCEPTED_EXCEPTION`。
狀態在欄位裡，不在實體名稱裡（§26.5 L1165）。

**但「還有多少 OPEN」不是 G-07 的判準**——見 §六之三：
`MISSING_RATE`／`METHOD_UNRESOLVED`／`SOURCE_MISMATCH`／`CTA_MISMATCH`
只要**存在**，無論處於哪一種 `resolution_status`，G-07 一律失敗。
人可以用 `EXPLAINED` 記錄調查結論，但不能把硬錯誤變成 ready。

## 三、`RoundingTolerance`：最小範圍，不假裝完整 scope 鏈

D-26-05 的完整 scope 鏈是
`ReportingUnit → CurrencyPair → TranslationMethod → AccountClass → OutputProfile`，
但 `OutputProfile` 尚未實作。**本刀不假裝它存在**，採最小範圍：

    Tenant → Engagement → ReportingUnit → Currency

- 版本化（`series_id`／`version_no`／`supersedes_*`，新版本向後指）。
- **R4 批准**；未批准的版本不得被 run 凍結（比照 0032 的批准函式與欄位級權限）。
- **凍結位置在 `TranslationReconciliation` 自己身上，不在 FX run 的 Manifest。**
  FX run 完成時 Manifest 已封存（0012 的 append-only），而調節是**後續**工作，
  無法再追加條目；硬要追加就得改已關閉的 M3-02 模型。因此：

      TranslationReconciliation
      ├─ calculation_run_id
      ├─ tolerance_version_id
      ├─ tolerance_content_hash        凍結當時的 tolerance 內容雜湊（SHA-256）
      ├─ single_limit_snapshot
      ├─ cumulative_limit_snapshot
      ├─ scope_snapshot                jsonb：四層 scope 的實際值
      └─ reconciliation_input_hash     FX run 的 frozen_set 與 result hash ＋
                                       上述 tolerance 快照的合併雜湊

  **FX replay 仍引用原 FX Manifest**（M3-02 的行為完全不變）；
  **重新調節＝建立新的 reconciliation**，使用當時的 tolerance 版本。
  不動已關閉的 M3-02 Manifest。
- **日後 `OutputProfile` 落地時只能新增更細的版本，不得改寫既有版本**——
  既有 run 凍結的是當時的 scope 形狀，追溯改寫會讓舊 run 的結論失去意義。
  屆時新版本帶較細的 scope，舊版本原樣保留。

## 四之一、`ROUNDING_DIFFERENCE` 必須有算術推導，不得由「差額很小」推定

基線的措辭是「原因經**系統證實**為純算術尾差」（D-26-05）。金額門檻只回答
「小不小」，不回答「是不是尾差」。在本系統內，引擎與 C2 使用**同一份凍結方法與
同樣的逐行 `ROUND_HALF_UP`**，因此兩者不一致時的正常解釋是：結果被修改、
引擎或調節器有缺陷、或來源與方法不一致——**都不是尾差**。

因此每一筆 `ROUNDING_DIFFERENCE` 必須保存可驗證的推導：

    rounding_basis               被捨入的那個乘積（軋差後餘額 × 匯率）
    unrounded_amount             未捨入值
    rounded_amount               已捨入值
    currency_minor_unit          凍結的最小單位
    rounding_mode                'ROUND_HALF_UP'
    expected_rounding_residual   rounded_amount − unrounded_amount

**只有 `actual_difference = expected_rounding_residual` 才允許
`reason_class = 'ROUNDING_DIFFERENCE'`**（DB CHECK ＋ 建立函式雙重把關）；
其餘一律 `UNEXPLAINED` 或對應的硬錯誤類別。

> **Case-001 產生零筆尾差是完全合法的結果。** 目前的內部折算流程不會產生
> 這類 residual（引擎與 C2 同法同率）。Tolerance 能力先建好，等 `OutputProfile`
> 或與外部系統核對真的產生可證明的尾差時再使用。
> **不得為了測 INV-24 而人工把任意小差額命名成尾差**——那正是本節要防的事。
> INV-24 的驗收改以**直接建構**的尾差樣本（帶完整推導欄位）進行，
> 不經折算引擎產生。

## 四之二、INV-24：兩層同時滿足，且不得淨額互抵

自動判定 `RESOLVED_BY_POLICY` 必須**同時**滿足：

    abs(single_difference) <= single_limit
      AND
    sum(abs(all_rounding_differences)) <= cumulative_limit

- 累積範圍：**同一 FX run × 同一報告幣**（＝ D-26-05 的「同期間 × 同幣別 ×
  同折算 run」在本刀的具體化）。
- **一律取絕對值加總，禁止淨額互抵。** 正負尾差互相抵銷後淨額為零，不代表
  沒有重大差異——那正是 INV-24 存在的理由。
- 任一條件不滿足 → **全部**尾差維持 `OPEN`（不是只把超限的那一筆留下）。
  理由：累積超限時，「哪幾筆該留」沒有非任意的答案；把它變成人的判斷。
- 自動結案時記錄 `threshold_policy_version_id`（凍結的 tolerance 版本）與
  當次的 `single_limit`／`cumulative_limit`／實際累積值，紀錄完整保留。

## 五、不可變性

調節結果屬 `CalculationRun` 產出，沿用 0031 已凍結的語意：

- `TranslationReconciliation`／`TranslationDifference` 一經建立即**不可
  UPDATE／DELETE**（`FX_OUTPUT_IMMUTABLE`）。
- **例外只有一個**：`resolution_status` 由 `OPEN` 走向終態的人工處理，
  透過 system-only 函式寫入，且只允許 `OPEN → EXPLAINED／ACCEPTED_EXCEPTION`；
  已是終態者不得再改。自動結案（`RESOLVED_BY_POLICY`）在建立時就決定，事後不得補。
  **人工終態只是調查紀錄，不影響 G-07**（§六之三條件 7）。
- **重新核對＝建立新的 reconciliation，且必須綁新的 FX run**——不原地結案。
  同一 run 至多一份 reconciliation（唯一鍵）。

## 六、期間級 G-07 判定

**G-07 從「有沒有 APPROVED 匯率版本」升級為「這一期的折算是否真的做完且對得起來」。**
以唯讀函式 `fn_period_fx_readiness(period_revision_id)` 回傳逐項結論，
比照 0028 的 `fn_period_transition_spec`：**DB 是唯一裁決點，畫面讀同一份事實**。

### 六之一、判定對象：顯式選定，不用 `created_at` 猜

「最新的 `COMPLETED` run 自動取代舊 run」**不安全**：測試或誤操作產生的 run 會
自動成為權威結論、同時完成的 run 沒有穩定排序、而且答不出「誰決定母公司該採哪一版」。

**新增顯式選擇物件：**

    PeriodFxRunSelection
    ├─ period_revision_id / reporting_unit_id
    ├─ selected_run_id                 必須為 COMPLETED 的 FX run
    ├─ selected_reconciliation_id      必須為該 run 的 FINALIZED 調節
    ├─ selected_by / selected_at       **案件層 R4**（system-only 函式，欄位級權限）
    └─ supersedes_selection_id         向後版本化；已批准的 selection 不改寫

- G-07 **只檢查目前 selection 指向的 run**。`FAILED`、replay、以及未被選定的其他
  `COMPLETED` run 都不構成現行結論——舊 run 的 OPEN 差異因此自然不阻擋，
  也不需要靠 `created_at` 猜取代關係。
- `selected_run_id` 與 `selected_reconciliation_id` 必須互相對應（同一 run），
  且與 selection 的期間、報告單位、租戶、案件一致（父鏈守衛，比照 0032）。

### 六之二、範圍：一個 PeriodRevision 對一個報告單位

現行模型中 `ReportingPeriod` 只屬**一個** `ReportingUnit`，因此「該 revision 的
所有報告單位」目前不成立。本刀的判定範圍寫死為：

    PeriodRevision → 其 ReportingPeriod 的 ReportingUnit → 一個現行 PeriodFxRunSelection

未來 group period composition 落地後再擴成多單位聚合；**現在不預留假的多單位邏輯**。

### 六之三、八項條件

全部成立才算 G-07 通過：

| # | 條件 | 不成立時的穩定代碼 |
|---|---|---|
| 1 | 存在現行 `PeriodFxRunSelection` | `G07_RUN_NOT_SELECTED` |
| 2 | 選定 run 的 Manifest 完整性通過（0035） | `G07_MANIFEST_INTEGRITY_FAILED` |
| 3 | 匯率版本、幣別指派、折算政策均已凍結於該 run 的 Manifest | `G07_INPUT_NOT_FROZEN` |
| 4 | 所需 rate／date／coverage 完整（CLOSING 對期末、AVERAGE 涵蓋全期、每筆權益事件都有 HISTORICAL） | `G07_RATE_INCOMPLETE` |
| 5 | 選定 run 狀態為 `COMPLETED` 且非 replay | `G07_RUN_NOT_COMPLETED` |
| 6 | 選定調節為 `FINALIZED` 且屬該 run | `G07_RECONCILIATION_NOT_FINALIZED` |
| 7 | **不存在任何 `reason_class ≠ 'ROUNDING_DIFFERENCE'` 的差異**（無論 `resolution_status`） | `G07_HARD_DIFFERENCE_PRESENT` |
| 8 | 所有 `ROUNDING_DIFFERENCE` 均為 `RESOLVED_BY_POLICY` 且滿足 INV-24 兩層門檻 | `G07_TOLERANCE_VIOLATION` |

**條件 7 是本刀最重要的一條。** G-07 的 `output_capability = NONE`（§28 守衛表），
它是硬守衛；若只擋 `OPEN`，R4 把 `MISSING_RATE` 標成 `ACCEPTED_EXCEPTION` 就能讓
「有一段金額根本沒有匯率可折算」的期間變成 ready。因此：

- 硬錯誤（`MISSING_RATE`／`METHOD_UNRESOLVED`／`SOURCE_MISMATCH`／`CTA_MISMATCH`）
  **只要存在就失敗**，狀態無關。
- `UNEXPLAINED` 同樣使 G-07 失敗（本刀採嚴格版：**任何非尾差差異都不得使
  G-07 通過**）。`ACCEPTED_EXCEPTION` 因此在本刀**只作為調查紀錄**，不改變判定。
- **修復路徑是重新建立正確的 FX run 並重新選定**，不是把差異標掉。

本函式**唯讀**，不改任何狀態；`app_runtime` 只獲 EXECUTE。

## 七、期間狀態機邊界（不要誤讀）

**本刀只讓 G-07 的判定能力成立，不解鎖任何遷移。**
`ADJ_APPROVED → CALCULATING` 在 0028 的規格函式中維持 `NOT_IMPLEMENTED`。

解鎖還缺：

| # | 條件 | 現況 |
|---|---|---|
| 1 | **G-07 期間級判定** | 本刀交付 |
| 2 | **G-03：B 基礎（遞延稅）狀態判定** | 未實作。`AMENDED` 取代鏈亦未完成（里程碑 2 的 ACCEPTED_DEVIATION 之三） |
| 3 | `CALCULATING → RECONCILING` 之後各段（G-06／G-09／G-10） | 未實作，維持 fail closed |
| 4 | REQ-CFS-001 現金流支持資料 | 未實作；**未完成前 MVP 3 不得關閉** |

**「G-07 已完成」≠「`ADJ_APPROVED → CALCULATING` 可走」。** 期間遷移是所有守衛的
合取；本刀只補上其中一個。0028 的規格函式不因本刀而改動——那份規格是既有
期間測試的回歸釘子。

## 八、不做

- B-06 折算／核對畫面與 replay 入口（DB 能力已具備，畫面另開一刀）。
- REQ-CFS-001 現金流支持資料。
- 解鎖 `ADJ_APPROVED → CALCULATING` 或任何其後遷移。
- `OutputProfile` 與完整的 D-26-05 scope 鏈。
- 基礎間調節（`basis_reconciliation`，0023 已有）——本刀是**折算**調節，
  另立實體：前者的軸是 `from_basis → to_basis`，後者的軸是功能幣 → 報告幣，
  硬塞進同一張表會逼出一個沒有意義的 `from_basis`。
- 差異的指派、到期日與催辦（`owner_id`／`due_date` 欄位保留，流程不做）。
- 多報告單位的期間聚合（現行模型一個 `ReportingPeriod` 只屬一個 `ReportingUnit`）。
- 以尾差能力做任何「讓 Case-001 產生尾差」的人工安排（見 §四之一）。

## 九、驗收

1. **四項比較**各自能產生差異，且無差異時仍留下 `FINALIZED` 的調節物件。
   Case-001 的正控制：`ROUNDING_DIFFERENCE` **零筆**、其餘類別零筆、G-07 通過。
2. **C2 是獨立重算**：竄改 `TranslationResult` 的某一列金額（owner 級）→
   產生 `UNEXPLAINED` → G-07 不通過。
   **反證：把 C2 改成讀 `TranslationResult` 當期望值 → 本條轉紅。**
3. **單筆過門檻** → 該筆維持 `OPEN`，G-07 不通過。
4. **單筆皆小但累積過門檻** → **全部**尾差維持 `OPEN`，G-07 不通過。
5. **正負尾差淨額為零但絕對值累積超標** → 仍維持 `OPEN`。
   **反證：把累積判定改成淨額 → 本條轉紅。**
   （3～5 的尾差樣本以**直接建構**方式產生，帶完整推導欄位，不經折算引擎——
   見 §四之一。）
6. **尾差必須有算術推導**：`actual_difference ≠ expected_rounding_residual` 時
   不得標為 `ROUNDING_DIFFERENCE`；缺推導欄位者一律拒絕。
   **反證：拿掉推導比對、只留金額門檻 → 本條轉紅。**
7. **硬錯誤不得被人工放行**：`MISSING_RATE`／`METHOD_UNRESOLVED`／
   `SOURCE_MISMATCH`／`CTA_MISMATCH` 標成 `EXPLAINED` 或 `ACCEPTED_EXCEPTION`
   後，G-07 仍回 `G07_HARD_DIFFERENCE_PRESENT`。
   **反證：把條件 7 改成只擋 `OPEN` → 本條轉紅。**
8. **`UNEXPLAINED` 同樣阻擋** G-07（本刀採嚴格版）。
9. **顯式選定**：
   (a) 沒有 selection → `G07_RUN_NOT_SELECTED`；
   (b) 非 R4 不得建立 selection；
   (c) selection 指向 `FAILED` 或 replay run → 拒絕；
   (d) 指向的調節不屬該 run → 拒絕；
   (e) 存在另一個較新的 `COMPLETED` run 但**未被選定**時，判定不受它影響；
   (f) 未被選定的舊 run 的 OPEN 差異**不阻擋** G-07。
   **反證：把判定改成「取 `created_at` 最新的 COMPLETED run」→ (e)(f) 轉紅。**
10. **tolerance 凍結在 reconciliation 上**：建立調節後改版 tolerance，
    既有調節的 `single_limit_snapshot`／`cumulative_limit_snapshot`／
    `tolerance_content_hash` 不變、結論不變；新的調節才採新版本。
    **反證：判定時回查現行 tolerance → 本條轉紅。**
11. **未批准的 tolerance 不得使用** → 建立調節時即拒絕。
12. **Manifest 被竄改時 G-07 不得通過**（條件 2，沿用 0035 的六種竄改樣本）。
13. **不可變性**：調節與差異不得 UPDATE／DELETE；`resolution_status` 只能
    由 `OPEN` 走向終態，終態不得再改；同一 run 至多一份調節。
14. **跨租戶與跨案件**：調節、tolerance、selection 的 run／報告單位／期間
    必須同租戶同案件（比照 0032 的父鏈守衛）；跨租戶與同租戶跨案件各一條負面測試。
15. **`fn_period_fx_readiness` 唯讀**：`app_runtime` 不得以它改變任何狀態；
    0028 的規格函式與既有期間測試（DB 31＋端到端 37）**斷言一字不改**全綠。
16. 完整測試一輪全綠。

## 十、風險

**第一級。** 四個真正的風險：

1. **尾差成為垃圾桶**——把缺率、方法未解析、來源不符掃進 `ROUNDING_DIFFERENCE`
   自動結案。緩解：CHECK 強制只有尾差可自動結案，驗收 6 反證。
2. **淨額互抵**——正負相消後看起來沒有差異。緩解：一律絕對值加總，驗收 5 反證。
3. **C2 退化成抄結果**——若重算直接讀 `TranslationResult`，調節就永遠通過。
   緩解：重算只讀凍結 payload（與 0034 同一原則），驗收 2 以竄改產出反證。
4. **「G-07 完成」被誤讀為期間可遷移**——緩解：§七 明列還缺 G-03 等三項，
   且本刀**不動** 0028 的規格函式。
5. **硬錯誤被人工標掉而放行**——G-07 是 `output_capability = NONE` 的硬守衛，
   只擋 `OPEN` 等於把它交給流程。緩解：條件 7 與驗收 7 的反證。
6. **權威結論由 `created_at` 決定**——誤操作或測試產生的 run 會自動成為結論。
   緩解：`PeriodFxRunSelection` 顯式選定＋驗收 9 的反證。

實作順序（契約確認後）：
migration（`RoundingToleranceVersion` ＋ R4 批准函式與欄位級權限 →
`TranslationReconciliation`（含 tolerance 快照與 `reconciliation_input_hash`）／
`TranslationDifference`（含算術推導欄位）＋不可變與父鏈守衛 →
獨立重算函式（不呼叫引擎、不讀 `TranslationResult`）＋ INV-24 判定 →
`PeriodFxRunSelection` ＋ R4 選定函式 → `fn_period_fx_readiness`）
→ DB 負面測試（2～15）→ Case-001 的無差異正控制（尾差零筆）
→ 直接建構的尾差樣本驗 INV-24 → 期間套件回歸（斷言不改）→ 完整一輪。
**畫面不在本刀。**
