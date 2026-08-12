# SLICE-M3-03　折算調節核對與期間級 G-07

> 狀態：**事前契約 第一版，待走查**。**尚未批准進 migration。**
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

- **C2 是獨立重算，不是抄結果**。它以與引擎相同的凍結輸入重算一次，因此能發現
  引擎缺陷與產出被竄改兩類問題。重算與引擎共用 `fn_fx_verify_manifest`
  的完整性前提（凍結集合本身先驗過，見 0035）。
- 四項比較各自產生零到多筆 `TranslationDifference`；**沒有差異時仍必須留下
  調節物件**（否則「有沒有核對過」與「核對過但沒差異」無法區分）。

## 二、差異分類（六值，職責明確）

    ROUNDING_DIFFERENCE   純算術尾差（幣別最小單位層級）
    MISSING_RATE          所需匯率在凍結集合中不存在或不涵蓋所需期間
    METHOD_UNRESOLVED     科目分類缺失、或分類在凍結政策中沒有對應規則
    SOURCE_MISMATCH       C1 不成立：功能幣快照與凍結來源不一致
    CTA_MISMATCH          C3／C4 不成立：CTA 金額或方向與合計差額不符
    UNEXPLAINED           以上皆非

**缺率、方法未解析、來源不符一律不得歸入尾差。** 以 CHECK 強制：
`reason_class = 'ROUNDING_DIFFERENCE'` 是 `RESOLVED_BY_POLICY` 的**必要條件**；
其餘五類**不得**被自動結案，只能由人以 `EXPLAINED`／`ACCEPTED_EXCEPTION` 處理
（後者需 R4 批准與理由）。

> 這條是本刀最容易被繞過的地方：把缺率當尾差吃掉，報表看起來乾淨，
> 而真正的問題是「有一段金額根本沒有匯率可折算」。

`resolution_status` 沿用 0023 已凍結的詞彙：
`OPEN／EXPLAINED／RESOLVED／RESOLVED_BY_POLICY／ACCEPTED_EXCEPTION`。
狀態在欄位裡，不在實體名稱裡（§26.5 L1165）——「還有多少未解釋差異」一律查
`resolution_status = 'OPEN'`。

## 三、`RoundingTolerance`：最小範圍，不假裝完整 scope 鏈

D-26-05 的完整 scope 鏈是
`ReportingUnit → CurrencyPair → TranslationMethod → AccountClass → OutputProfile`，
但 `OutputProfile` 尚未實作。**本刀不假裝它存在**，採最小範圍：

    Tenant → Engagement → ReportingUnit → Currency

- 版本化（`series_id`／`version_no`／`supersedes_*`，新版本向後指）。
- **R4 批准**；未批准的版本不得被 run 凍結（比照 0032 的批准函式與欄位級權限）。
- **run 凍結**：manifest 新增 `ROUNDING_TOLERANCE_VERSION` 條目，payload 保存
  `single_limit`、`cumulative_limit` 與 scope 四欄。
- **日後 `OutputProfile` 落地時只能新增更細的版本，不得改寫既有版本**——
  既有 run 凍結的是當時的 scope 形狀，追溯改寫會讓舊 run 的結論失去意義。
  屆時新版本帶較細的 scope，舊版本原樣保留。

## 四、INV-24：兩層同時滿足，且不得淨額互抵

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
- **重新核對＝建立新的 reconciliation，且必須綁新的 FX run**——不原地結案。
  同一 run 至多一份 reconciliation（唯一鍵）。

## 六、期間級 G-07 判定

**G-07 從「有沒有 APPROVED 匯率版本」升級為「這一期的折算是否真的做完且對得起來」。**
判定對象是該 `PeriodRevision` 納入的**所有** FX run（每個報告單位至少一個現行 run）。
以唯讀函式 `fn_period_fx_readiness(period_revision_id)` 回傳逐項結論，
比照 0028 的 `fn_period_transition_spec`：**DB 是唯一裁決點，畫面讀同一份事實**。

八項條件，全部成立才算 G-07 通過：

| # | 條件 | 不成立時的穩定代碼 |
|---|---|---|
| 1 | 每個 FX run 的 Manifest 完整性通過（0035） | `G07_MANIFEST_INTEGRITY_FAILED` |
| 2 | 匯率版本、幣別指派、折算政策均已凍結於該 run 的 Manifest | `G07_INPUT_NOT_FROZEN` |
| 3 | 所需 rate／date／coverage 完整（CLOSING 對期末、AVERAGE 涵蓋全期、每筆權益事件都有 HISTORICAL） | `G07_RATE_INCOMPLETE` |
| 4 | FX run 狀態為 `COMPLETED` | `G07_RUN_NOT_COMPLETED` |
| 5 | 該 run 未被 supersede（見下） | `G07_RUN_SUPERSEDED` |
| 6 | 調節已完成（`FINALIZED`） | `G07_RECONCILIATION_NOT_FINALIZED` |
| 7 | 不存在 `resolution_status = 'OPEN'` 的**非尾差**項目 | `G07_OPEN_DIFFERENCES` |
| 8 | 尾差僅能依 INV-24 結案（即不存在 `RESOLVED_BY_POLICY` 卻不滿足兩層門檻者） | `G07_TOLERANCE_VIOLATION` |

- **「未被 supersede」的定義**：同一 `(period_revision, reporting_unit)` 下存在
  更新的 `COMPLETED` FX run 時，較舊者視為被取代。**`FAILED` 與 replay run
  一律不計入**——replay 是驗證行為，不是新的結論。本刀為 `calculation_run`
  補一個唯讀判定，不新增狀態欄（狀態在既有欄位裡，不另立第二個真相）。
- 每個報告單位都必須有一個現行 FX run；缺一個即 `G07_RUN_MISSING`。
- 本函式**唯讀**，不改任何狀態；`app_runtime` 只獲 EXECUTE。

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

## 九、驗收

1. **四項比較**各自能產生差異，且無差異時仍留下 `FINALIZED` 的調節物件。
2. **C2 是獨立重算**：把 `TranslationResult` 的某一列金額竄改（owner 級）→
   調節產生 `UNEXPLAINED`（金額不符且非尾差級）→ G-07 不通過。
3. **單筆過門檻** → 該筆維持 `OPEN`，G-07 不通過。
4. **單筆皆小但累積過門檻** → **全部**尾差維持 `OPEN`，G-07 不通過。
5. **正負尾差淨額為零但絕對值累積超標** → 仍維持 `OPEN`。
   **反證：把累積判定改成淨額 → 本條轉紅。**
6. **缺率被錯分為 ROUNDING**：`MISSING_RATE` 的差異不得被自動結案。
   **反證：把 `RESOLVED_BY_POLICY` 的 `reason_class` 限制拿掉 → 轉紅。**
7. **現行 tolerance 改版不影響舊 run**：改版後重演舊 run，結論與門檻值不變；
   新 run 才採新版本。
8. **未批准的 tolerance 不得使用** → 建立調節時即拒絕。
9. **Manifest 被竄改時期間級 G-07 不得通過**（條件 1，沿用 0035 的六種竄改樣本）。
10. **`FAILED`／被 supersede 的 FX run 不得被算作完成**：
    只有 `FAILED` run 時 G-07 回 `G07_RUN_NOT_COMPLETED`；
    存在較新的 `COMPLETED` run 時，舊 run 不影響判定，且舊 run 的 OPEN 差異
    不得阻擋（否則永遠無法重算修正）。
11. **不可變性**：調節與差異不得 UPDATE／DELETE；`resolution_status` 只能
    由 `OPEN` 走向終態，且終態不得再改。
12. **跨租戶與跨案件**：調節的 run、tolerance、報告單位必須同租戶同案件
    （比照 0032 的父鏈守衛）。
13. **`fn_period_fx_readiness` 唯讀**：`app_runtime` 不得以它改變任何狀態；
    0028 的規格函式與既有期間測試（DB 31＋端到端 37）**斷言一字不改**全綠。
14. 完整測試一輪全綠。

## 十、風險

**第一級。** 四個真正的風險：

1. **尾差成為垃圾桶**——把缺率、方法未解析、來源不符掃進 `ROUNDING_DIFFERENCE`
   自動結案。緩解：CHECK 強制只有尾差可自動結案，驗收 6 反證。
2. **淨額互抵**——正負相消後看起來沒有差異。緩解：一律絕對值加總，驗收 5 反證。
3. **C2 退化成抄結果**——若重算直接讀 `TranslationResult`，調節就永遠通過。
   緩解：重算只讀凍結 payload（與 0034 同一原則），驗收 2 以竄改產出反證。
4. **「G-07 完成」被誤讀為期間可遷移**——緩解：§七 明列還缺 G-03 等三項，
   且本刀**不動** 0028 的規格函式。

實作順序（契約確認後）：
migration（`RoundingToleranceVersion` ＋批准函式與欄位級權限 → manifest 新增
`ROUNDING_TOLERANCE_VERSION` → `TranslationReconciliation`／`TranslationDifference`
＋不可變與父鏈守衛 → 核對函式（獨立重算＋INV-24 判定）→
`fn_period_fx_readiness`）
→ DB 負面測試（3～13）→ Case-001 的無差異正控制與人工注入差異的反證
→ 期間套件回歸（斷言不改）→ 完整一輪。**畫面不在本刀。**
