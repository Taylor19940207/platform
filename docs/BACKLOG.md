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
| 2026-08-06<br>2026-08-10 | **DB 守衛例外 → HTTP 狀態的統一映射**（P2，單一工作項，不阻擋任何切片）。應用層預檢通過後、寫入前條件被併發改變時，DB 守衛會安全拒絕，**資料不受污染**——問題只在回應語意：目前回 500 而非對應的 409。已知實例：`/b04/map` 看到 ACCEPTED 後、寫入前批次轉 `SUPERSEDED`（0021 `SOURCE_BATCH_NOT_ACCEPTED`）；`/b03/identity/confirm` 預檢後狀態改變或角色被撤銷（`fn_sod07_guard` 等）。**現在不做**：資料安全已有 DB 防線，缺陷只在極窄併發下出現；要做就得同時替多個 DB 函式補穩定代碼、建共用解析器並補多條競態測試，等於再開一輪基礎設施收尾。等真正需要統一錯誤邊界時**一次做完**——DB stable code → HTTP status ＋ `x-error-code`，未知錯誤仍維持 500。0022 已建立該模式（`Gxx_NOT_IMPLEMENTED:` 前綴 → 409）可直接沿用。**不得**用中文錯誤文案猜狀態碼：文案會改，代碼不會 | SLICE-M2-04 關閉複核（0021）＋ B-03 拆層 | 不需改基線 |
| 2026-08-10 | **staging 孤兒物件清理排程**。上傳的邊界是「先寫 write-once object → 再以單一 DB 交易建立 Batch＋Document＋Job＋Event」。DB 交易失敗時**不會**留下半套批次，但會留下沒有任何 DB 引用的孤兒物件。反過來做（先寫 DB 再寫物件）會產生「批次說檔案已落地、實際沒有」的不可恢復謊言，因此順序不改。需要的是定期比對 object key 與 `source_document.object_key` 的清理排程；本刀刻意不擴建完整清理系統 | SLICE-M2-04 拆層（上傳） | 不需改基線 |
| ~~2026-08-10~~ | ~~**provided_by 的真實提供者選單**~~ **→ 同日於 B-00 拆層完成**：B-00 上傳表單提供該案件有效 R1 的選單；後端 `resolveProvider` 重新驗證選定者確實是同案件的有效 R1（不信任表單 UUID）；R1 自己上傳自動為本人；無可選 R1 時回 `PROVIDER_REQUIRED` 並顯示「尚未設定資料提供者」，**不靜默把 R2 當提供者** | SLICE-M2-04 拆層（上傳） | 已完成 |
| ~~2026-08-10~~ | ~~**`/admin/jobs` 尚未模組化**~~ **→ 同日完成**：已移入 `modules/admin/routes.ts`。`/health` 與 `/login` 留在入口層 | SLICE-M2-04 拆層 | 已完成 |
| 2026-08-11 | **匯率版本的自然人層 SoD 為本切片的嚴格子集**：§24.6 只指定角色（R6 建立／R2 提交／R3 覆核／R4 批准），未指定自然人。SLICE-M3-02 另加一條實例級限制 `submitted_by ≠ reviewed_by`（`FX_RATE_SELF_REVIEW_DENIED`），但**允許** `reviewed_by = approved_by`——要求三個不同自然人會讓 2～3 人的事務所無法運作。日後基線改版時應把「最低限度的獨立覆核」統一寫進 §24／§25，與調整鏈的三段 SoD 一併整理 | SLICE-M3-02 契約走查 | 需改基線（例外：現行矩陣未涵蓋實例級控制）——累積使用證據後開 CR |
| 2026-08-12 | **FAILED replay 的診斷產出是否保留**（P2，不阻擋 M3-02）。`fn_fx_translation_replay` 在結果雜湊不符時，`fn_fx_materialize` 已寫入該 replay run 的 SnapshotLine／TranslationResult／CTA，之後才把 run 標成 `FAILED`。資料不會被當成正式結果——狀態明確為 FAILED，正式輸出只接受 COMPLETED——但 FAILED 的 replay run 仍帶著一份快照與 CTA。要保留它當診斷證據（可比對「哪一列變了」），還是失敗即清除，屬證據包／保存政策（D-26-04）那一刀的決定。**Manifest 完整性失敗的路徑不受影響**：0035 在物化之前就攔下，FAILED run 是乾淨的 | SLICE-M3-02 0035 走查 | 不需改基線 |
