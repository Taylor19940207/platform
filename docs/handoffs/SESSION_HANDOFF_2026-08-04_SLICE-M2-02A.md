# SLICE-M2-02A 完成紀錄（2026-08-04）

> 工程交接紀錄，非正式產品基線。與正式基線衝突時依 `docs/GOVERNANCE.md` 權威順序判斷。
> 實作契約：`docs/slices/SLICE-M2-02A_調整生命週期.md`
> 退回版本語意：`docs/adr/ADR-M2-001.md`

## 完成範圍

`DRAFTING → PENDING_REVIEW → PENDING_APPROVAL → APPROVED → 物化 JournalEntry／JournalLine`

三個職責分離控制掛在**三個不同的狀態遷移**，未合併成單一判斷：

| 遷移 | 守衛 |
|---|---|
| DRAFTING → PENDING_REVIEW | G-08 四項證據齊備 ＋ 分錄成立性（至少兩列且借貸平衡） |
| PENDING_REVIEW → PENDING_APPROVAL | G-04／SOD-01：`prepared_by ≠ reviewed_by`（無豁免） |
| PENDING_APPROVAL → APPROVED | G-05／SOD-02：`reviewed_by ≠ approved_by`<br>**AC-WFL-001：`prepared_by ≠ approved_by`** |

## AC-WFL-001 是本切片的關鍵發現

`prepared_by ≠ approved_by` **推導不出來**：SOD-01 ∧ SOD-02 同時成立時仍允許
「甲編製 → 乙覆核 → 甲批准」。手冊 §849 AC-WFL-001 明確要求「編製人不能批准自己的
重大調整」，但設計書 §25.13 守衛表未列出。

依 GOVERNANCE 權威順序（手冊 v1.2 > 設計書 v1.1）以 `AC-WFL-001` 之名獨立落實，
**未冒充也未擴充 SOD-02**。設計層的遺漏已記入 `docs/BACKLOG.md`，標為需 CR。

seed 的角色配置刻意讓「角色齊備」與「實例級控制」正面對撞：**甲同時具備 R2／R3／R4**。
因此 SOD-01 與 AC-WFL-001 被擋下時，唯一可能的原因是自然人判定，不是角色不足。

## 產出

- `packages/database/migrations/0007_adjustment_lifecycle.sql`
  （5 張表：`adjustment`、`adjustment_line`、`adjustment_version_snapshot`、
  `journal_entry`、`journal_line`；狀態守衛、明細凍結、物化守衛、RLS）
- `packages/domain/src/adjustment.ts`（與 DB 守衛同語意的純函式；`decimalOf` 純字串轉換）
- `apps/api/src/server.ts`：B-05 畫面與 `/b05/create|save|submit|review|return|approve`
- `tests/unit/adjustment.test.ts`、`tests/integration/db.test.sh`（+32）、
  `tests/acceptance/adjustment-slice.test.ts`

## 測試

**184/184，EXIT=0**（單元 27、DB 整合 67、端到端 90＝20＋25＋45）。
已在停掉 `pnpm dev` 的乾淨環境下重跑確認。

## 實作期間的兩個實質修正

1. **`materializeLines` 原本用 `Number(cents)/100`**——正是 `8f0507f` 硬化掉的浮點路徑。
   `numeric(20,2)` 整數位可達 18 位會靜默失真。改為純字串 `decimalOf`，
   並在單元測試加入 `123456789012345678.99` 邊界。
2. **證據只在可編輯表單裡渲染**，調整一離開 DRAFTING 就從畫面消失——
   等於 R3 覆核人看不到要覆核的法源、附件與判斷理由。改為證據永遠顯示，
   草稿階段才額外給編輯表單。端到端測試補上「覆核人在 PENDING_REVIEW 看得到四項證據」。

## 2026-08-04 Case-001 走查（提交後、未改程式）

走查批次 `8c63e788-2956-4fb8-9370-70329c9f81f2`、調整 `716fdb53-2997-4675-bb93-2ceba01b7536`。
以三個身分的實際 HTTP session（cookie）對 `pnpm dev` 的 8080 服務操作：

| # | 操作 | 結果 |
|---|---|---|
| 1 | 甲接受批次 | 302 → ACCEPTED |
| 2 | 甲建立調整草稿 | DRAFTING bv=1 ov=1 |
| 3 | 證據空白送覆核 | 409（G-08） |
| 4 | 補三項、缺語言標籤送覆核 | 409（G-08） |
| 5 | 補語言標籤但金額不平衡送覆核 | 409（G-01） |
| 6 | 以過期 ov=1 儲存 | 409，標題未被覆蓋 |
| 7 | 修正平衡後送覆核 | 302 → PENDING_REVIEW bv=2 |
| 8 | 甲（具 R3）自我覆核 | 409（G-04／SOD-01）＋記錄 `output_capability=PREVIEW` |
| 9 | 乙覆核 | 302 → PENDING_APPROVAL bv=3 |
| 10 | 批准前 JournalLine | 0 |
| 11 | 乙（覆核人，具 R4）批准 | 409（G-05／SOD-02） |
| 12 | 甲（編製人，具 R4）批准 | 409（AC-WFL-001） |
| 13 | 三次拒絕後 JournalLine | 仍為 0，狀態未變 |
| 14 | 丙批准 | 302 → APPROVED bv=4；物化 2 列，借方 50,000.00，借貸差 0.00 |
| 15 | 已批准後再編輯（API） | 409 |
| 16 | 已批准後直接下 SQL 改寫 | DB 觸發器拒絕「不可修改」 |
| 17 | 丙從 PENDING_APPROVAL 退回（無說明） | 409（理由必填） |
| 18 | 丙退回（附理由分類與說明） | 302 → DRAFTING bv=4，**覆核人已失效** |
| 19 | 未重新覆核直接批准 | 409 |
| 20 | 退回後調整筆數 | 1（不建立新調整／替代版本） |

business version 里程碑鏈：`bv2 SUBMITTED 職員甲 R2` → `bv3 REVIEWED 資深乙 R3`
→ `bv4 APPROVED 經理丙 R4`。

控制違規留痕齊全：AC-WFL-001、G-01、G-04／SOD-01、G-05／SOD-02、G-08 ×2、
狀態、狀態遷移、退回理由、`adjustment.save.conflict`。

## 下一刀（不得跳過）

**背景工作可靠性**：job lease／認領時間、heartbeat 或逾時判定、安全重領、冪等執行、
worker 重啟恢復測試、卡住任務診斷狀態。這同時解決 backlog 裡 `VALIDATING` 永久卡住
的問題。必須排在 02B 之前——CalculationRun 依設計是非同步的，建在不可靠的 worker 上
後面一定重做。

其後：`SLICE-M2-02B PREVIEW CalculationRun ＋ Manifest` → `SLICE-M2-02C 預覽證據包`。
