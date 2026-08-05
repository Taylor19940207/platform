# SLICE-M2-04　B-00 待辦整合與 UNVERIFIABLE 人工確認（走查修訂版）

**範圍**：`B-00「等我處理的事項」佇列（待身分確認／待覆核／待批准／被退回・待補證據／
未完成草稿）＋ 一鍵回到工作物件 ＋ UNVERIFIABLE 人工確認畫面（明確選定 assessment →
寫入不可變 Resolution 與事件 → 依 G-01 決定能否接受）`。不新增控制語意，但**補
Resolution 的 DB 最後防線（migration 0019）**——現有觸發器只驗 `uploaded_by ≠
resolved_by`，歸屬、版本、角色與狀態皆可被直接 SQL 繞過。

## 基線對應（抽取，不修改基線）

| 主題 | 基線位置 |
|---|---|
| B-00 P0：等我處理的事項（含**待身分確認**）、未完成草稿、一鍵回位 | 設計書 §28.3 B-00 規格 |
| 每列四欄脈絡不因版面隱藏；只顯示有權且被指派；未指派之名稱／計數／匯總不得出現；撤銷即時生效 | AC-WKB-001（WKB-a/b/c）；§28.3 |
| B-00 P1（本刀不做）：截止日、**背景工作進度**、容量 | §28.3 |
| 覆核佇列＝SOD-01（≠編製人）；**批准佇列＝AC-WFL-001（≠編製人）∧ SOD-02（重大調整 ≠ 覆核人）**——現行系統只收 MAJOR，完整三人分離直接套用 | §24.7 SOD-01／02；手冊 AC-WFL-001；02A 既有守衛 |
| UNVERIFIABLE 由資料接受角色確認；上傳者不得確認自己（實例級，角色切換無效） | 手冊 §12／§13；SOD-07 |
| Resolution 不可覆寫，含確認者、時間、理由、證據、規則版本；**效力只及該批次版本** | §00A；§26.6；CTX-d／d2／e |
| `SourceIdentityResolutionPerformed`＝DomainEvent；**一般欄位驗證錯誤不進不可變軌跡** | §25.18 |
| 確認後仍須 G-01 三條件才可 ACCEPTED；CONFLICT 永無豁免；狀態軸正交 | §25.13 G-01／INV-28；CTX-c／g |
| 證據強度分級呈現 | §25.5；CTX-f |

## 本刀凍結的設計決策

1. **佇列定義（全部依「該案件的有效業務角色指派」過濾＋四欄脈絡）**：
   - **待身分確認**：`identity_status = PENDING_CONFIRMATION` 且主狀態非
     QUARANTINED／SUPERSEDED 的批次；觀看者對該案件具有效 **R2** 指派。
   - **待覆核**：`PENDING_REVIEW` 且 `prepared_by ≠ 觀看者`（SOD-01）；觀看者具
     有效 **R3** 指派。
   - **待批准**：`PENDING_APPROVAL` 且 `prepared_by ≠ 觀看者`（AC-WFL-001）**且
     `reviewed_by ≠ 觀看者`（SOD-02——現行全為 MAJOR，直接套完整三人分離）**；
     觀看者具有效 **R4** 指派。**甲編製、乙覆核後，只有丙看見待批准；甲、乙皆不見。**
   - **被退回／待補證據**：觀看者自己編製、`DRAFTING` 且最新里程碑 `RETURNED`
     的調整（附退回理由分類）。
   - **未完成草稿**：觀看者自己 `DRAFTING` 的調整＋自己建立且未批准的映射草稿。
   - 自己編製但已進入 PENDING_REVIEW／PENDING_APPROVAL 的項目**不列入自己的任何
     可處理佇列**（它已不是草稿；唯讀「等待他人」區屬後續，本刀不做）。
2. **B-00 不沿用泛用指派查詢**：現行 `engagement_id IS NULL` 的租戶層角色會被視為
   全案件指派——**R6 系統管理員因此可見全部客戶，違反 WKB-a**。本刀明定：每個佇列
   依所需業務角色（R2／R3／R4）過濾，且該角色必須是**該案件的有效指派**
   （`engagement_id` 明確匹配、未撤銷）；**租戶層 R6 不因此取得 B-00 客戶工作
   存取權**。負面驗收：系管丁登入 B-00 看不到任何客戶名稱、計數與明細。
3. **一鍵回位**：批次→確認頁／B-04、調整→B-05、映射草稿→B-04（工作物件層；
   游標級位置屬後續）。
4. **確認頁**：宣告目標（客戶×法人×期間＋法人權威代碼）、**全部** Assessment 列
   （evidence_kind、偵測值、match_result、識別規則版本、別名表版本、評估時間——
   多筆並存全部顯示）、批次版本與檔案雜湊、必填理由、選填證據參照。
5. **提交必須明確選定 assessment，「仍有效」＝current 指標**：0019 於 `import_batch`
   增 `current_identity_assessment_id`——worker 建立 Assessment 時**同一交易**更新
   此指標；人工確認**只能選中該 ID**（歷史 Assessment 全部顯示，但只有 current
   可提交）；Resolution 明確保存 assessment ID 與該筆規則版本；重解析切換 current
   後，舊 Resolution 不自動沿用（CTX-e）。`POST` 攜帶 `assessment_id`，伺服器重驗
   「＝current ∧ 該批次目前版本 ∧ UNVERIFIABLE」。同批次新舊兩筆評估並存時，
   只能解析明確選定且＝current 的那一筆（測試明列）。
6. **資料接受角色＝R2（本刀）**；客戶政策指定角色屬後續，如實標示。
7. **SOD-07 應用層先判**：上傳者可開啟確認頁但提交 403＋CVA；DB 為最後防線。
8. **確認＝單一交易**：Resolution＋`identity_status → MANUALLY_RESOLVED`＋DomainEvent
   （`import_batch.identity_resolved`；payload 含理由、證據參照、該筆 assessment 的
   規則版本、別名表版本＝本刀 `null`）同生共死。**確認不自動接受**（CTX-g）。
9. **migration 0019：Resolution 歸屬、版本、角色與狀態防繞過（DB 最後防線）**——
   `source_identity_resolution` INSERT 觸發器補齊：
   - assessment、resolution、batch **同租戶且同批次**；
   - 三者 `batch_version` 相同，**且等於批次目前版本**；
   - 該 assessment 的 `match_result = 'UNVERIFIABLE'`；
   - **`assessment_id ＝ import_batch.current_identity_assessment_id`**（重解析後
     舊評估不可沿用）；
   - `resolved_by` 為有效使用者，且對該案件具**有效 R2 指派**；
   - **允許確認狀態＝正向白名單**：`import_batch.status = 'VALIDATED'` ∧
     `identity_status = 'PENDING_CONFIRMATION'`（不是「非 QUARANTINED／SUPERSEDED」
     的負向表述——DRAFT／UPLOADED／VALIDATING／ACCEPTED 一律不可確認）；
   - **並發要求**：guard 以 `FOR UPDATE` 鎖住 ImportBatch 列**與當下使用的 R2
     `role_assignment` 列**——「資格檢查通過」到交易提交之間，批次狀態變更與
     角色撤銷不得交錯。
   並修 `fn_import_batch_guard` 的 identity 遷移白名單：
   - `NOT_CHECKED → MATCHED／PENDING_CONFIRMATION／CONFLICT`：**僅限
     `status = 'VALIDATING'` 階段**（worker 交易內寫入的唯一合法路徑，
     不作「保留既有路徑」的籠統描述）；
   - `PENDING_CONFIRMATION → MANUALLY_RESOLVED`：僅限 `status = 'VALIDATED'`
     且**已存在對應 current assessment 的有效 Resolution**；
   - `current_identity_assessment_id` 只能於 `VALIDATING` 階段更新；
   - 其他 identity 遷移一律拒絕——關掉 0018 同狀態提前返回留下的
     「直接 SQL 改寫 identity_status」後門。
10. **CVA 邊界（§25.18）**：權限、指派、SOD-07、繞過狀態守衛的拒絕寫 CVA；
    **理由空白等一般欄位驗證錯誤回 409＋機器代碼，不寫 CVA**（不得把欄位錯誤
    灌進不可變軌跡）。
11. CONFLICT 不入佇列、確認頁拒絕提交（三條出路文案照 §25.5）。

## 驗收清單

| # | 條件 |
|---|---|
| 1 | 五佇列項目正確（決策 1 定義）；空佇列顯示「無」而非隱藏 |
| 2 | 每列四欄脈絡（WKB-c）；一鍵直達對應工作物件 |
| 3 | WKB-a／b：未指派案件之名稱與計數不出現；撤銷指派後即消失且既有連結被拒 |
| 4 | **三人分離**：甲編製→乙見待覆核（甲不見）；乙覆核後→**只有丙見待批准，甲、乙皆不見**（AC-WFL-001＋SOD-02） |
| 5 | **R6 負面**：系管丁登入 B-00 看不到任何客戶名稱、計數與明細（租戶層角色不取得客戶工作存取權） |
| 6 | 確認頁完整呈現（決策 4）；同批次多筆 assessment 全部顯示 |
| 7 | 提交攜帶 `assessment_id`；選定非 current、過期版本或非 UNVERIFIABLE 評估 → 409 拒絕；**同批次新舊兩筆評估並存時，只能解析明確選定且＝current 的那一筆**；worker 建立 Assessment 與更新 current 指標同一交易 |
| 8 | 角色與 SOD：非 R2 提交 → 403＋CVA；上傳者本人提交 → 403＋CVA（應用層），直接 SQL 由 DB 觸發器拒絕；**理由空白 → 409＋機器代碼，不寫 CVA** |
| 9 | 確認單一交易：Resolution＋MANUALLY_RESOLVED＋DomainEvent 同生共死；payload 含理由／證據參照／該筆 assessment 規則版本 |
| 10 | 確認後可接受（G-01）；**確認不自動接受**（CTX-g）；CONFLICT 不入佇列且不可確認（CTX-c） |
| 11 | 效力只及批次版本（CTX-e）：新批次版本需重新確認，原紀錄並存不可覆寫 |
| 12 | **0019 防繞過（DB 測試逐條）**：跨租戶／跨批次 assessment 拒絕；batch_version 三方不一致拒絕；非 current assessment 拒絕；對 MATCH／CONFLICT 評估建 Resolution 拒絕；resolved_by 無該案件有效 R2 指派拒絕；**狀態白名單**（非 VALIDATED＋PENDING_CONFIRMATION 一律拒絕）；identity 遷移白名單（非 VALIDATING 階段寫入判定拒絕、已判定不得改寫、**無 Resolution 直接 UPDATE 為 MANUALLY_RESOLVED 拒絕**） |
| 13 | 既有 427 條零退化 |

## 明確不做（B-00 P1 或後續刀）

背景工作技術進度、截止日、容量（§28.3 P1）；唯讀「等待他人」區；自動保存與
Session 恢復（第 4 刀）；期間生命週期；別名表管理；游標級回位；R1 表面 A；
客戶政策指定資料接受角色；粒度不足升級佇列（隨多基礎／規則刀）。

**流程**：本文件定稿（2026-08-05 二輪走查通過）→ **migration 0019（含 current
assessment 指標）** → worker 寫入 current 指標（與 Assessment 同交易）→
domain／query → API／B-00 → 三層測試（0019 防繞過逐條＋佇列過濾＋SOD 呈現＋
確認交易原子性）→ Case-001 走查（no-id 批次確認→接受全流程）→ 更新 handoff →
期間生命週期切片。
