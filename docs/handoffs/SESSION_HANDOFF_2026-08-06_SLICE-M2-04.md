# SESSION HANDOFF — SLICE-M2-04 B-00 待辦整合與身分確認（2026-08-06）

## 本次完成（切片已完整實作並通過三層測試）

契約：`docs/slices/SLICE-M2-04_B00待辦與身分確認.md`（二輪走查定稿，commit b0329e4）。
實作順序照定稿流程：0019 → worker current 指標 → API／B-00 → 三層測試 → Case-001。

### migration 0019（`0019_identity_resolution_guard.sql`，已套用）

- `import_batch.current_identity_assessment_id`：「仍有效 assessment」的權威指標。
- `fn_sod07_guard` 全面重寫：鎖批次列 `FOR UPDATE`；三方租戶／同批次歸屬；
  `batch_version` 三方一致且＝批次目前版本；`match_result='UNVERIFIABLE'`；
  assessment＝current 指標；正向狀態白名單（VALIDATED＋PENDING_CONFIRMATION）；
  SOD-07 上傳者≠確認者（自然人）；resolved_by 須有該案件有效 R2 指派
  （指派列亦 `FOR UPDATE` 鎖住——撤銷不得與提交交錯）。
- `fn_import_batch_guard` 增 identity 遷移白名單：判定只能於 VALIDATING 寫入
  （worker 唯一合法路徑）；已判定不得改寫；PENDING_CONFIRMATION→MANUALLY_RESOLVED
  僅限 VALIDATED 且已有對應 current assessment 的 Resolution；current 指標只能於
  VALIDATING 更新——關掉 0018 同狀態提前返回留下的直接改寫後門。

### worker

`commitResult` 以明確 `assessment_id` 插入 Assessment，並於**同一交易**更新
`identity_status` 與 `current_identity_assessment_id`（皆在 VALIDATING 階段）。

### API／B-00（server.ts）

- B-00 五佇列：待身分確認（R2）、待覆核（R3、SOD-01）、待批准（R4、AC-WFL-001
  ∧ SOD-02 完整三人分離）、被退回（附 reason_category）、未完成草稿（調整＋映射）。
  全部依「所需業務角色 × `engagement_id` 明確匹配的有效指派」過濾；租戶層
  R6（engagement NULL）不取得任何客戶工作存取權；空佇列顯示「無」。
- `GET /b03/identity`：宣告目標（含法人權威代碼、批次版本、檔案雜湊）、全部
  assessment（含歷史，current 標記）、CONFLICT 三條出路文案、確認表單以 current
  assessment 明確選定、必填理由。
- `POST /b03/identity/confirm`：非 R2→403＋CVA ROLE_REQUIRED；上傳者→403＋CVA
  SOD_07；理由空白→409 REASON_REQUIRED **不寫 CVA**（§25.18 邊界）；狀態白名單
  →409＋CVA STATE_NOT_CONFIRMABLE；非 current→409＋CVA NOT_CURRENT_ASSESSMENT；
  合法確認＝單一交易（Resolution＋MANUALLY_RESOLVED＋DomainEvent
  `import_batch.identity_resolved`，payload 含理由／證據參照／該筆規則版本／
  alias_table_version=null）。確認不自動接受（CTX-g）。

### 測試（487/487）

- 單元 50、DB 整合 **204**（原 190；identity／SOD-07 區全面重寫為 0019 合法路徑：
  B1 判定改於 VALIDATING 寫入；專用批次 BN（NOT_CHECKED）、BC（CONFLICT）、
  BU（UNVERIFIABLE 全流程）、BW（VALIDATING 狀態白名單）；驗收 #12 逐條——
  非 VALIDATING 寫判定、已判定改寫、無 Resolution 直改 MANUALLY_RESOLVED、
  非 current、版本三方不一致、非 UNVERIFIABLE、跨批次、SOD-07、無 R2 指派、
  重複確認、Resolution UPDATE 全部被 DB 拒絕）。
- 端到端 233（新增 `tests/acceptance/workbench-identity.test.ts` 48 條，port 8099）：
  五佇列、三人分離、R6 負面、撤銷即時生效（WKB-b）、確認頁內容、CVA 邊界逐條、
  兩筆評估並存只認 current、確認交易原子性、CTX-g、CTX-e（新批次需重新確認）。
- Case-001 走查：`jp_tb_2026-03.csv` 去識別行上傳 → PENDING_CONFIRMATION →
  乙確認 → 甲接受 → ACCEPTED，15 條來源事實完整。

### 測試重寫時踩過的坑（留給未來）

- db.test.sh 種子 heredoc `ON_ERROR_STOP` 中止會讓後面全部測試連鎖假失敗——
  role_assignment 必須插在 client_engagement **之後**（FK）。
- UUID 字面值只能用 hex（`au…` 不合法）。
- source_identity_assessment 冪等鍵含 detection_rule_version：同批次多筆評估
  必須用不同規則版本。

## 尚未做（依定稿「明確不做」）

背景工作技術進度／截止日／容量（B-00 P1）、唯讀「等待他人」區、自動保存與
Session 恢復、期間生命週期、別名表、游標級回位、客戶政策指定資料接受角色。

## 下一步（依里程碑 2 離開複核順序）

1. **期間生命週期切片**（§25.8 完整語意，不預設 OPEN→LOCKED 簡化）。
2. 多基礎／四類規則最小資料模型。
3. 自動保存／儲存狀態／Session 恢復（NFR-UX-001 為阻擋項）。
4. 重跑里程碑 2 離開複核 → 稅理士批准／正式交付 → 折算（MVP 3）。

環境：`pnpm db:seed` 已還原 cbfc_dev。
