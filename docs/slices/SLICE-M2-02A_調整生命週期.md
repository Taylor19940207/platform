# SLICE-M2-02A　Adjustment 完整生命週期（真實案件可驗證）

**範圍**：`DRAFTING → PENDING_REVIEW → PENDING_APPROVAL → APPROVED → 物化 JournalEntry／JournalLine`。
以 Case-001 建立**一筆人工 GROUP_GAAP 重大調整**、經 R3 獨立覆核與 R4 批准後進入正式事實
為完成條件。

**基線對應**：**AC-WFL-001（手冊 §849）**、SOD-01／G-04（§24.7、§25.13 L926）、
SOD-02／G-05（同上 L927）、G-08 必要證據齊備／AC-EVD-001（§25.13 L930）、
`output_capability`（§25.9 L843）、`object_version`／`base_object_version` 樂觀鎖
（§26.9 L1255-1257）、`business_version` 版本鏈（§26.9 L1351，解釋見 ADR-M2-001）、
JournalEntry／Line 與 `materializeJournal(adjustment_version)`（§26 L1216、§27 M5 L1529）、
B-05 調整編製・升級・覆核・批准（§28 L2034，守衛 G-04／05／08）、
ControlViolationAttempt（§25.18 L613）、§25.12 退回與例外矩陣（L910-911）。

核心價值驗證：**一筆調整能被正確編製、獨立覆核、批准並物化；未批准的工作中資料
永遠不會污染正式事實。**

## 唯一驗證場景

Case-001 的人工 GROUP_GAAP 調整，以集團科目編製一筆平衡分錄。
本切片**只接受 `MAJOR` fixture，不實作重要性分類引擎**；因此所有進入本切片的調整
都走完整三段式。這不是宣稱所有正式產品調整都是重大。

## 狀態與守衛

```
DRAFTING
   │ G-08：四項證據完整（法源／政策・附件・判斷理由・語言標籤）
   ▼
PENDING_REVIEW
   │ G-04／SOD-01：prepared_by ≠ reviewed_by　【無豁免】
   ▼
PENDING_APPROVAL
   │ G-05／SOD-02：reviewed_by ≠ approved_by　【重大調整】
   │ AC-WFL-001  ：prepared_by ≠ approved_by　【見下方說明】
   ▼
APPROVED
   └─ 物化 JournalEntry／JournalLine（與批准同一交易，同步）
```

角色固定：R2 編製／R3 覆核／R4 批准。
**兩個 SoD 必須落在不同的狀態遷移**，不得合併成單一「建立者不得批准」判斷。

### AC-WFL-001：編製人不得批准自己的重大調整

`prepared_by ≠ approved_by` **推導不出來**：SOD-01（`prepared_by ≠ reviewed_by`）
與 SOD-02（`reviewed_by ≠ approved_by`）同時成立時，仍允許
「甲編製 → 乙覆核 → 甲批准」。而手冊 §849 AC-WFL-001 明確要求
**「編製人不能批准自己的重大調整」**。

依 `docs/GOVERNANCE.md` 權威順序（手冊 v1.2 > 設計書 v1.1），本條為**高權威文件的
直接要求**，設計書 §25.13 守衛表未列出屬設計層遺漏。本切片以 `AC-WFL-001` 之名
獨立落實，**不冒充 SOD-02、不擴充 SOD-02 的定義**。

因此本切片的 MAJOR fixture 強制三個自然人互異：

    prepared_by ≠ reviewed_by     （SOD-01／G-04）
    reviewed_by ≠ approved_by     （SOD-02／G-05）
    prepared_by ≠ approved_by     （AC-WFL-001）

退回路徑：`PENDING_REVIEW → DRAFTING`、`PENDING_APPROVAL → DRAFTING`。
從 `PENDING_APPROVAL` 退回時**既有覆核失效**，修正後必須重新覆核。

## 驗收清單

| # | 條件 | 驗證位置 |
|---|---|---|
| 1 | 三段狀態完整存在且不可跳關；`DRAFTING → PENDING_APPROVAL` 或 `→ APPROVED` 的直接遷移被拒 | DB 整合＋端到端 |
| 2 | G-08 四項（法源／政策、附件、判斷理由、語言標籤）**缺一不可**；缺任一項不得進入 PENDING_REVIEW、不得批准；缺漏項目逐一列出 | 單元＋端到端 |
| 3 | G-04／SOD-01：`prepared_by = reviewed_by` 時拒絕遷移，**無豁免**；同一自然人切換角色亦被拒（實例級，非角色級） | DB 整合＋端到端 |
| 4 | G-05／SOD-02：`reviewed_by = approved_by` 時拒絕 `PENDING_APPROVAL → APPROVED` | DB 整合＋端到端 |
| 5 | **AC-WFL-001**：`prepared_by = approved_by` 時拒絕批准——**編製人即使具備 R4 角色，也不得批准自己編製的重大調整**。獨立於 3／4，須以「甲編製 → 乙覆核 → 甲批准」情境驗證（該情境同時滿足 SOD-01 與 SOD-02） | 單元＋DB 整合＋端到端 |
| 6 | 繞過 UI 直接呼叫 API 的 2／3／4／5 各情境同樣被拒，並寫入 `ControlViolationAttempt` | 端到端 |
| 7 | 兩個退回節點皆記錄退回人、時間、原因分類與說明；**不建立新 Adjustment、不建立替代／superseding 版本**；`adjustment_id` 不變；**退回作為業務里程碑遞增 `business_version` 並留下不可變 snapshot 與事件**（ADR-M2-001）；退回次數與理由可查 | DB 整合＋端到端 |
| 8 | 從 `PENDING_APPROVAL` 退回後既有覆核失效，未重新覆核不得再進 `PENDING_APPROVAL`（§25.12 L911） | 端到端 |
| 9 | 草稿伺服器端保存；編輯只遞增 `object_version`，不產生 `business_version` 節點；以 `base_object_version` 樂觀鎖比對，衝突時**拒絕並顯示衝突**，不靜默覆蓋 | DB 整合＋端到端 |
| 10 | **關閉瀏覽器再登入，已保存草稿仍存在且內容一致** | 端到端 |
| 11 | 批准前 `JournalLine` 為零；批准後才物化，且與批准同一交易（批准失敗則無殘留分錄） | DB 整合＋端到端 |
| 12 | 已批准 Adjustment 不可 UPDATE／DELETE；變更＝新增 `business_version`（DB 觸發器最後防線） | DB 整合 |
| 13 | Case-001 可建立一筆**借貸平衡**的 GROUP_GAAP 調整；不平衡分錄不得送覆核 | 端到端 |
| 14 | G-04 失敗或無合格獨立覆核人時，控制判定記錄 `output_capability = PREVIEW` ＋ `reasons = [G-04, SOD-01]`；**不寫入 `delivery_quality`**（該欄屬 DeliveryRecord，02A 不存在）；B-05 明確顯示「只能預覽、不可正式交付」 | DB 整合＋端到端 |
| 15 | 編製、送覆核、退回、覆核、批准、物化皆寫入 DomainEvent | 端到端 |
| 16 | 跨 Tenant／跨案件不可見不可寫；調整指向的集團科目須屬同一 Tenant × 案件（§24.1A） | DB 整合 |
| 17 | **狀態遷移與 business version 快照同一交易**：快照失敗時狀態與 `business_version` 全部回滾，不得留下「狀態已前進、不可變版本不存在」的資料 | 端到端 |
| 18 | **同狀態 UPDATE 不得繞過守衛**：`reviewed_by`／`approved_by` 只能在對應遷移設定或清空；`business_version` 只能隨遷移前進一格；已送出的表頭凍結。併發的第二次覆核不得覆蓋第一位覆核人 | DB 整合 |
| 19 | **草稿保存是原子操作**：任一明細解析失敗或科目不存在即整筆拒絕（409），表頭、明細與 `object_version` 全部不變；不得靜默略過後回報成功 | 端到端 |
| 20 | **PREVIEW 降級不殘留**：合法獨立覆核完成後清除 `output_capability`／`control_reasons`；違規嘗試仍永久留在 AuditEvent。B-05 不得同時顯示 APPROVED 與「只能預覽」 | 端到端 |
| 21 | **跨租戶錯配寫入被 DB 拒絕**（INV-18）：`tenant_id` 與 `engagement_id`／`period_revision_id`／`prepared_by`／父物件／科目屬不同租戶時一律拒絕——RLS 只比對列自己的 `tenant_id`，不保證父物件同租戶 | DB 整合 |

## 明確不做（切片收窄，**不是**修改基線）

1. **SOD-03 降級**：基線保留「非重大調整可由覆核人兼批准人」的能力。本切片不實作
   重要性分類與降級流程，只測重大調整的完整三段式。SOD-03 未被移除。
2. **G-08 批准例外**：基線允許取得批准例外後達 `OFFICIAL ＋ WITH_CONTROL_EXCEPTION`。
   本切片不實作，必要證據缺漏一律硬擋。
3. **未批准 Adjustment 進入 PREVIEW**：基線 §26 L1078 明寫「未批准的工作中資料留在
   `AdjustmentLine`，**只有 PREVIEW run 讀得到**」。02B 第一版只讀
   `ACCEPTED TB ＋ 生效映射 ＋ APPROVED Adjustment`，未批准調整不進 CalculationRun。
   這是嚴格子集，基線能力未移除。
4. **PREVIEW 產物**：02A 沒有 CalculationRun，只記錄「只能預覽」的資格與理由，
   **不真正產生預覽檔**。實際 PREVIEW 產物到 02B 才驗證。
5. **`delivery_quality` 與 INV-27**：`delivery_quality` 屬**不可變的 DeliveryRecord**。
   02A 尚未建立 CalculationRun、輸出或 DeliveryRecord，因此該欄**不寫入 Adjustment**。
   INV-27（`output_capability ≠ OFFICIAL → delivery_quality IS NULL`）於 02B 真正
   建立輸出／交付紀錄時才套用。
6. 其他：ReversingAdjustment、多基礎／匯率折算、期間狀態機遷移、正式交付、
   Next.js 完整前端。

## 控制判定的欄位形狀（02A 最終）

    output_capability = PREVIEW
    reasons           = [G-04, SOD-01]

不寫 `official_eligible`（基線無此欄位，且可由 `output_capability` 完全推導，
並存會產生兩個可互相矛盾的真相來源）。
不寫 `delivery_quality`（屬 DeliveryRecord，02A 不存在該物件——見「明確不做」第 5 點）。

**下一刀**（本切片通過後）：背景工作可靠性（job lease／heartbeat／安全重領／冪等／
worker 重啟恢復／卡住任務診斷，一併解決 backlog 的 VALIDATING 永久卡住）
→ SLICE-M2-02B PREVIEW CalculationRun ＋ Manifest。
