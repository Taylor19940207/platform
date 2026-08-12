# SESSION HANDOFF　2026-08-12　SLICE-M3-03 折算調節核對與期間級 G-07（CLOSED／PASS）

完整測試 **1,108**（單元 66、DB 整合 615、端到端 427）零失敗｜38 份 migration。
切片文件：`docs/slices/SLICE-M3-03_折算調節核對與期間級G-07.md`（含 **20/20 驗收對照表**）。

## 交付

| migration | 內容 |
|---|---|
| 0036 | `RoundingToleranceVersion`（幣別對 scope）、`TranslationReconciliation`、`TranslationDifference`、`PeriodFxInputSelection`／`PeriodFxRunSelection` 與全部守衛 |
| 0037 | C2 的獨立重算、`fn_translation_reconcile`（唯一入口、單一交易）、INV-24、兩個選定函式（先鎖 `period_revision` FOR UPDATE） |
| 0038 | `fn_period_fx_input_readiness`（現行 G-07）、`fn_period_fx_result_readiness`、引擎的 InputSelection 前置檢查 |

## 契約走查抓到的一個循環（最重要的一項）

基線的 G-07 掛在 `ADJ_APPROVED → CALCULATING`，只能回答「**開始計算**所需的輸入
是否齊備」。把「run `COMPLETED` → 調節 `FINALIZED` → R4 選定」也塞進 G-07，
就變成「還沒進 `CALCULATING`，卻要先完成計算與調節才准進去」。

因此拆成兩支唯讀函式：

    fn_period_fx_input_readiness    現行 G-07，六項輸入條件（G07_*）
    fn_period_fx_result_readiness   折算結果與調節，七項（POSTFX_*），
                                    整體回 POST_FX_RECONCILIATION_READY

後者**暫不自行命名 G-13**——新增正式 Guard ID 須走 CR（BACKLOG 已記）。

## 其他關鍵決定

- **內部核對不產生尾差。** 引擎與 C2 使用同一份凍結方法與同樣的
  `ROUND_HALF_UP`，因此 C1～C4 只會是零差異或硬差異；捨入殘差是**計算證據**
  而非 C2 的差異。`ROUNDING_DIFFERENCE` 保留給日後的對外輸出／`OutputProfile`
  核對。**Case-001 調節「所有類別零筆」是正確結果**，不是漏測；INV-24 的樣本
  一律明標為 schema-level fixture。
- **硬差異只要存在就失敗，狀態無關。** G-07 是 `output_capability = NONE` 的
  硬守衛；只擋 `OPEN` 的話，R4 把 `MISSING_RATE` 標成 `ACCEPTED_EXCEPTION`
  就能讓「有一段金額根本沒有匯率可折算」的期間變成 ready。人工終態只是調查紀錄，
  修復路徑是重建正確的 FX run 並重新選定。
- **權威輸入與結論都要顯式選定**：`PeriodFxInputSelection`（R2，選輸入是作業）與
  `PeriodFxRunSelection`（R4，選結論是批准）。現行版本由**取代鏈**判斷而非
  `created_at`——用時間猜會讓測試或誤操作產生的 run 自動成為權威結論。
- **tolerance 是幣別對**（JPY→CNY 與 USD→CNY 不共用），且**凍結在 reconciliation
  上**而非 FX Manifest——FX run 完成時 Manifest 已封存，調節是後續工作。
- **C2 必須是獨立公式**：不呼叫 `fn_fx_materialize`、不讀 `translation_result`
  當期望值、不讀現行主檔。共用計算主體會讓引擎缺陷同時出現在兩邊而互相抵銷。

## 實作時抓到的一個真缺陷

C1 的 `FULL JOIN` 把 run 過濾寫在 `ON` 子句，導致**其他 run 的快照全被保留**，
Case-001 一度出現 79 筆假的 `SOURCE_MISMATCH`。過濾移進子查詢後歸零。
教訓：`FULL JOIN` 的 `ON` 只決定配對，不決定保留範圍——限制條件要放進子查詢。

## 測試

fx 領域 **250 條**（193 → 250），DB 整合 557 → 615。既有斷言**一字未改**，
只補了 InputSelection fixture（契約已預先聲明為預期的 fixture 變更）。

**六個反證**各自轉紅後還原。其中 C2 那條原本 **0 條紅**——happy path 下引擎與
重算本來就一致，沒有測試注入不一致；補上「owner 級竄改 `TranslationResult`
→ 必須抓出 `UNEXPLAINED 100.00` 且不得歸為尾差」之後才真正釘住。

**每個穩定代碼都有專屬案例**（§19，全部先斷言前置狀態）。隔離手法值得記住：
部分狀態會被 Selection 建立函式提前擋住（那是好事），因此 readiness 自己的防禦
分支以 **owner-level 直接寫入 selection** 驗證；過程中需要兩個額外的報告單位——
一個沒有幣別指派、一個沒有權益 lot set——否則 `G07_CURRENCY_ASSIGNMENT_MISSING`
與 `G07_POLICY_NOT_APPROVED`／`G07_SOURCE_RUN_NOT_READY` 會被更前面的條件遮住。

## MVP 3 尚未完成

1. **REQ-CFS-001 現金流支持資料**——未完成前 **MVP 3 不得關閉**。
2. **B-06 折算／核對畫面與 replay 入口**（DB 能力已具備）。
3. **G-03：B 基礎（遞延稅）判定**；`AMENDED` 取代鏈亦未完成。
4. **對外輸出／`OutputProfile` 核對**——`ROUNDING_DIFFERENCE` 的真正使用場景。
5. 折算結果就緒的**正式 Guard ID**（須走 CR）。

**本刀不解鎖任何遷移**：`ADJ_APPROVED → CALCULATING` 還缺 G-03；
`CALCULATING → RECONCILING` 還缺其餘守衛。0028 的規格函式未改動，
期間套件（DB 31＋端到端 37）斷言未變。
