# 里程碑 2 離開複核（MILESTONE-2 EXIT REVIEW・第二次）

日期：2026-08-10｜基準：`46772ff`（**793/793** 全綠：單元 66／DB 整合 363／端到端 364；
27 份 migration；工作區乾淨、已 push）
對照基線：《產品研究與要件手冊 v1.2》§20（MVP 1／MVP 2 列與離開條件）、§19 AC。
前次複核：`docs/reviews/MILESTONE-2_EXIT_REVIEW.md`（2026-08-05，基準 `8b7266e`，427 條）。

## 判定用語

| 標記 | 意義 |
|---|---|
| **PASS** | 需求、AC 與離開條件均有實作與**測試證據** |
| **ACCEPTED_DEVIATION** | 有已知收窄，但不影響 §20 的離開條件；附理由、風險與承接階段 |
| **DEFERRED** | 明確不屬於本里程碑（MVP 3 以後） |
| **FAIL** | 沒有證據，或違反離開條件 |

「有實作但沒有測試」一律不計為 PASS。下表每一列的證據都指得到具體的
migration、模組或測試套件。

---

## MVP 1｜資料與映射

| 需求 | 判定 | 證據 |
|---|---|---|
| REQ-ING-001 匯入 TB＋granularity／coverage／完整性 | **ACCEPTED_DEVIATION** | TB 全鏈（0003）＋coverage 與完整度**顯式聲明**（0017／0018，不推定）。**GL／明細／證憑匯入未做**——§20 的 MVP 1 離開條件只及集團科目 TB，故不阻擋；追溯升級到 JOURNAL 粒度時才需要（DEFERRED 至該刀） |
| REQ-ING-002 原始檔、雜湊、版本不可覆寫 | **PASS** | ObjectStore write-once；來源三表不可變＋封存（0015／0016）；批次身分凍結（0018）；上傳為單一交易（uploads/service.ts）。milestone1 27 條 |
| REQ-MAP-001 科目映射 | **ACCEPTED_DEVIATION** | 科目 1:1 映射＋版本＋SOD＋生效日＋來源批次脈絡（0005／0006／0021）；mapping-slice 40 條。**維度／關係人／現金流映射未做**——離開條件為「穩定產生集團科目 TB」，Case-001 跨期複用 12/12 成立 |
| REQ-BAS-001 A／B／C 及未來新增 BookBasis | **PASS** | `book_basis`（案件範圍＋RLS）／`posting_layer`（平台參照主檔）／構成模型（0023）。**AC-BAS-001 以可執行測試證明**：新增第四基礎（D／IFRS）全程零 DDL，既有 A／B／C 逐列雜湊未變；四類規則不可混記（兩段檢查）。multi-basis 16 條＋DB basis 領域 102 條 |
| REQ-CTX-001 宣告目標＋身分比對＋伺服器端歸屬驗證 | **PASS** | CONFLICT 無豁免、證據分級、SOD-07（0019／0020）；**B-03 人工確認使用者入口已存在**（identities 模組），AC-CTX-001 的 CTX-d／d2 可完成；歸屬驗證補到 ReportingUnit 層＋DB 守衛（0024）。workbench-identity 64 條 |
| NFR-UX-001 W 窗口自動保存＋儲存狀態 | **PASS** | 0025／0026／0027 併發欄位與約束；`autosaveClientSource` 狀態機。**行為測試在 vm 沙箱執行出貨程式本身**（非副本），以非零 RTT 驗證：每次編輯在 W 內取得**伺服器確認**、儲存延遲自 dirty 起算、請求途中編輯必補送、409 不風暴、離線退避＋online 恢復、beforeunload 警告、提交前等待確認。單元 8 條＋adjustment-slice 89 條 |

**MVP 1 離開條件三句**
1. 可重複匯入並穩定產生集團科目 TB — **成立**（Case-001 兩期，12/12 逐科目）
2. 錯誤客戶的檔案被阻止 — **成立**（CONFLICT 鏈＋0024 同案件跨法人錯配 DB 守衛）
3. 工作中資料不因關閉瀏覽器而遺失 — **成立**（自動保存＋伺服器確認才顯示已保存＋
   beforeunload 警告＋Session 恢復回原 Adjustment）

---

## MVP 2｜調整與覆核

| 需求 | 判定 | 證據 |
|---|---|---|
| REQ-RUL-001 四類規則分開 | **PASS** | `rule`／`rule_version` 三層歸屬＋SOD-H3 生命週期；`posting_layer.rule_type` 與規則類型兩段一致性檢查；`required_granularity` 沿用 `data_coverage` 既有四值（0023） |
| REQ-RUL-002 手工調整、證據、理由、轉回 | **ACCEPTED_DEVIATION** | 手工調整全鏈＋G-08 四項證據＋三段 SoD＋退回里程碑（0007–0009，ADR-M2-001）。**規則建議引擎未做**（`AUTO_POST` 寫入即拒絕，GB-05）——屬 MVP 3 以後（DEFERRED） |
| REQ-PER-001 期初、累積調整、比較期、跨期延續 | **ACCEPTED_DEVIATION** | §25.8 完整 13 狀態機、DB 為唯一裁決點、首期顯式欄位（0022）；period-lifecycle 37 條。**`CALCULATING` 之後各段 fail closed**（`Gxx_NOT_IMPLEMENTED:`）——那些守衛屬折算與交付（MVP 3／4），本里程碑不要求 |
| REQ-WFL-001 準備、覆核、批准、退回、鎖定與重開 | **ACCEPTED_DEVIATION** | 調整層全鏈✅；期間層狀態機✅。**`REOPENED` 只保留狀態值**，重開須建新 `PeriodRevision`——已寫入切片後續驗收，不阻擋（無重開需求前不得以原地改寫代替） |
| REQ-EVD-001 法源、政策、附件、評論 | **ACCEPTED_DEVIATION** | G-08 強制四項（文字參照），缺證據不得批准。**附件檔案實體與評論未做**——AC-EVD-001 以文字參照成立 |
| REQ-AUD-001 稽核軌跡＋可導出證據包 | **PASS（預覽級）** | append-only 軌跡、DomainEvent／CVA／CONTROL_PRECHECK 三分流；預覽證據包 hash 鏈＋逐科目追溯＋重演（0015–0018）；evidence-package 31 條。OFFICIAL 交付包屬 MVP 4（DEFERRED） |
| REQ-WKB-001 跨客戶工作台：待辦、未完成草稿、一鍵回位 | **PASS** | B-00 五佇列（待身分確認／待覆核／待批准／被退回／未完成草稿）＋四欄脈絡＋一鍵回位；**三層授權分開**（資料可見性／動作權限／待辦條件），計數與明細用同一份查詢結果 |
| NFR-INT-002 物件級併發、同人兩分頁＝兩來源、Session 恢復 | **PASS** | `object_version` 樂觀鎖＋「本次 UPDATE 影響列數」驗證；`edit_session_id`（INT-a2）；`client_save_sequence`＋內容雜湊冪等鍵（INT-a3，0026）；Session 到期回原畫面（INT-b）。背景保存回 401 而非 302 靜默吞掉 |

**MVP 2 離開條件三句**
1. 每筆可追溯 — **成立**（調整層版本鏈＋不可變快照；期間層狀態機為邊界）
2. 審計師可用底稿測試轉換調整 — **成立**（預覽證據包＋重演逐位元一致＋逐科目追溯 12/12）
3. 一名職員可同時處理多家客戶並切換而不遺失工作 — **成立**（五佇列可見＋一鍵回位＋
   自動保存＋Session 恢復）

---

## 三項已知限制（不阻擋離開，但不得寫成完成）

| # | 限制 | 判定 | 風險 | 承接階段 |
|---|---|---|---|---|
| 1 | **`CalendarUsage` 未落地**，首期唯一約束只能落在 `(reporting_unit_id, fiscal_calendar_id)`，無法限定 `purpose = GROUP_REPORTING`（基線 §26 L1120） | **ACCEPTED_DEVIATION** | 低。現行約束**較嚴**（不分用途只允許一個首期），不會放行錯誤資料；風險是同一單位日後要為法定與稅務曆各設首期時會被擋 | `CalendarUsage` 落地時收窄；已記入 SLICE-M2-06 後續驗收 |
| 2 | **R5／R7／R8 的授權範圍物件未完成**，B-05／B-06／B-07 的讀取白名單暫採嚴格子集（R2／R3／R4） | **ACCEPTED_DEVIATION** | 低。fail closed——比矩陣**更嚴**。R5 的 `R*` 以「審計師授權（實體×期間×到期日）」為範圍，該物件不存在；無範圍放行等於把「限範圍」讀成「不限範圍」 | 審計師授權物件落地時一併開放；理由寫在各 `guard.ts` |
| 3 | **`AMENDED` 取代鏈未完成**，`tax_basis_observation` 寫入 `AMENDED` 即 fail closed | **ACCEPTED_DEVIATION** | 低。取代鏈需原子函式、延遲外鍵、權限封鎖、競態與 `ImpactAssessment`（D-25-03／D-25-07）。目前拒絕寫入，不會產生半套的更正申告資料 | 更正申告刀；屆時唯一索引由「全部列」收窄為「僅現行列」 |

三項皆**不觸及** §20 的 MVP 1／MVP 2 離開條件，且方向一致：**現行行為比目標更嚴**，
不存在「已放行但未驗證」的資料。

## 一項不阻擋的 P2

**DB 守衛例外 → HTTP 狀態的統一映射**（BACKLOG 單一條目）。應用層預檢通過後、
寫入前條件被併發改變時，DB 安全拒絕、**資料不受污染**，但目前回 500 而非 409。
決定暫緩：要做就得同時替多個 DB 函式補穩定代碼、建共用解析器並補多條競態測試。
**FAIL 判定不成立**——離開條件不涉回應語意，且無資料風險。

---

## 複核結論

**里程碑 2 通過離開條件，可宣告完成。**

前次複核（2026-08-05）列出的五個阻擋項全部關閉，各有反證過的負面測試：

| 前次阻擋 | 關閉於 | 反證 |
|---|---|---|
| REQ-BAS-001／RUL-001 | SLICE-M2-06（0023） | 新增第四基礎零 DDL；掃描全 migration 無 code 驅動的約束 |
| REQ-CTX-001 | SLICE-M2-04＋identities 模組 | 反轉作用域 → 租戶層 R2 測試轉紅 |
| REQ-PER-001／WFL-001 | SLICE-M2-05（0022） | fail closed 各段獨立驗證 |
| REQ-WKB-001 | SLICE-M2-04＋B-00 三層授權 | 三層合回單一 bizEng → R1 可見調整待辦，轉紅 |
| NFR-UX-001／INT-002 | 0025–0027＋autosave 狀態機 | 五次反轉（雜湊、401、硬上限、世代比對、延遲基準）各自轉紅 |

期間另封閉**六類既有授權／歸屬缺口**（非前次盤點列出，拆層過程顯形）：
R1／R6 可讀 Adjustment、租戶層跨案件讀寫、`/b04/submit` 無角色檢查、
B-06／B-07 信任請求附帶的 batch、`/upload` 租戶層授權、同案件跨法人錯配。

### 未達成但已明確歸屬的項目（DEFERRED）

折算與匯率（MVP 3）、正式交付與 OFFICIAL 證據包（MVP 4）、規則建議引擎、
固定資產多基礎、遞延稅計算、完整合併、GL／明細／證憑匯入、附件實體與評論、
映射草稿的自動保存。以上皆非 MVP 1／MVP 2 離開條件所要求。

### 下一階段建議

基礎控制建設到此告一段落。下一里程碑的第一刀應是**可見的產品流程**，
而非再一輪基礎設施；候選見 handoff。
