# Backlog

新想法記在這裡，不開 CR、不改基線文件（規則見 GOVERNANCE.md）。
格式：日期｜一句話｜來源（程式／測試／訪談）｜若要動基線須滿足哪條例外

尚未形成可排程工作的產品問題、討論背景與未來驗證條件，集中記錄於
`docs/FUTURE_DISCUSSIONS.md`；形成決策後再回到本表或其他權威文件落地。

| 日期 | 事項 | 來源 | 基線例外 |
|---|---|---|---|
| 2026-08-04 | 一對多／條件式映射（手冊 §18 已定義；切片限一對一） | SLICE-M2-01 | 不需改基線 |
| 2026-08-04 | 映射例外批准——G-02「已批准例外」路徑與重要性門檻（§25.14） | SLICE-M2-01 | 不需改基線 |
| 2026-08-04 | 期間狀態機：G-02 正式掛載 IN_PREPARATION→IN_REVIEW（切片暫掛「映射完成確認」動作） | SLICE-M2-01 | 不需改基線 |
| 2026-08-04 | ChartOfAccountsVersion 完整版本鏈（D-26-02；現為 CoA 上的 version_no 欄位） | SLICE-M2-01 | 不需改基線 |
| 2026-08-04 | 集團 TB 預覽的輸入凍結（CalculationInputManifest）——現用目前生效映射，屬下一刀 CalculationRun | SLICE-M2-01 | 不需改基線 |
| 2026-08-04 | UNVERIFIABLE 批次的人工確認 UI（SourceIdentityResolution 已有 DB 防線與 SOD-07，缺畫面） | 里程碑 1 | 不需改基線 |
| 2026-08-04 | 映射草稿的刪除／撤回操作（現只能改版不能清草稿） | SLICE-M2-01 | 不需改基線 |
| ~~2026-08-04~~ | ~~Worker 認領後若在 `VALIDATING` 階段崩潰，需有 lease／heartbeat、逾時重領或安全隔離與重試~~ **已由 SLICE-M2-03 解決**（`BackgroundJob` 租約＋fencing＋安全重領；`VALIDATING` 成為交易內狀態） | 2026-08-04 走查 | 已完成 |
| 2026-08-04 | 設計書 §25.13 守衛表未列 `prepared_by ≠ approved_by`，但手冊 §849 AC-WFL-001 明確要求「編製人不能批准自己的重大調整」。SOD-01 ∧ SOD-02 推導不出該條（甲編製→乙覆核→甲批准可通過）。02A 已依權威順序以 AC-WFL-001 之名獨立落實；日後基線改版應補為正式守衛編號 | SLICE-M2-02A 規劃 | 需改基線（例外 4：真實案件證明現行設計錯誤）——留待累積實作證據後開 CR |
| 2026-08-04 | 設計書 §25.12 退回矩陣「調整不換版」與 §26.9「business_version 於提交、退回、覆核、批准等里程碑產生」字面衝突。已由 ADR-M2-001 統一解釋（不建立替代調整，但退回是業務里程碑）；日後改版建議把 §25.12 措辭改為「不建立替代調整」 | SLICE-M2-02A 規劃 | 不需改基線（ADR 已處理；措辭澄清需 CR） |
| 2026-08-04 | ~~`mapping_rule` 的 DomainEvent 仍在狀態異動的交易外~~ **→ 2026-08-05 已修**：drafted／approved 與狀態異動併入單一 statement（CTE），併發落空整句回滾；preview_generated／review_ready 為純事件（無配對狀態異動），單一 INSERT 本身即原子。驗收含「資料與事件無單邊」全表掃描與重複批准防重測試 | SLICE-M2-02A 覆核 | 不需改基線 |
| 2026-08-04 | `import_batch` 的 DomainEvent 同樣在交易外（upload／accept／worker 的 quarantined／identity_assessed／validated）。~~併入 SLICE-M2-03 處理~~ **已完成**：上傳與結果寫入皆為單一交易，事件與狀態同進同出 | SLICE-M2-02A 覆核 | 已完成 |
| 2026-08-05 | 事務所實際可用性驗證：控制強度、合法恢復路徑、角色切換與税理士批准效率；詳細討論框架見 `docs/FUTURE_DISCUSSIONS.md` DISC-001 | 產品定位討論；待真實使用者走查 | 不需改基線；先收集證據 |
| 2026-08-06 | **DB 守衛例外 → HTTP 狀態的統一映射**（P2，不阻擋任何切片關閉）。應用層先檢查通過、但在 INSERT 前條件被併發改變時，DB 會安全拒絕，外層卻回 500 而非對應的 409。實例：`/b04/map` 看到 ACCEPTED 後、寫入前批次被轉 `SUPERSEDED`（0021 的 `SOURCE_BATCH_NOT_ACCEPTED`）。**資料不會被污染**——DB 是最後防線且已擋下；問題只在回應語意。應統一把 DB 守衛的穩定機器代碼映射為對應 HTTP 狀態，而非逐點補檢查 | SLICE-M2-04 關閉複核（0021） | 不需改基線 |
