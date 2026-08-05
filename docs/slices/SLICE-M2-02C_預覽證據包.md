# SLICE-M2-02C　預覽證據包

**範圍**：`COMPLETED 的 PREVIEW CalculationRun → 產生不可變 EvidencePackage（預覽級）
→ 內容索引＋整包 hash → 可下載的單一底稿檔（醒目標示 DRAFT・UNREVIEWED・未折算）`。
以 Case-001 的 run 產包、逐項核對索引與雜湊通過為完成條件。

## 基線對應（抽取，不修改基線）

| 主題 | 基線位置 |
|---|---|
| 證據包內容：來源雜湊、映射版、規則版、計算、分錄、法源、附件索引、批准紀錄 | 手冊 §00A「證據包」、REQ-AUD-001／AC-AUD-001；設計書 §26.9 EvidencePackage |
| **必須揭露各輸出數字的實際追溯等級（BALANCE／JOURNAL／DOCUMENT），不得將餘額級表述為分錄級；抽樣重演深度 ≤ 實際 DataCoverage** | AC-AUD-001（CR-001 三級達成度）；D-26-03 |
| 證據包與輸出共用同一 run_id——審計師拿到的證據對應該次輸出 | 設計書 §25.3「輸出綁定 run」、§26.9 |
| 預覽包：DRAFT／UNREVIEWED 標示、不建立正式交付紀錄、不計入完成度、不可作為過帳依據；預覽不入 SUPERSEDED 鏈 | 設計書 §24.7（SOD-06 預覽包）、§25.8 PREVIEW_ONLY、§25.9、INV-09 |
| `output_capability=PREVIEW` 與 `delivery_quality` 互斥（品質欄位僅 OFFICIAL 適用） | 設計書 §25.9／INV-27 |
| 草稿／預覽輸出與正式輸出分屬兩條路徑，檔名、標頭與封面明確區隔 | 手冊 AC-EXIT-001、§19 審計與現金流驗收 |
| 匯出前控制總額檢查（G-09）；失敗訊息可指回來源 | 設計書 §24.8 共通規則、§25.13 G-09 |
| 不可變性與保存掛點（retention 屬 D-26-04，不在本刀） | 設計書 §26.9、INV-26 語意 |

## 本刀凍結的設計決策

1. **輸入＝單一 COMPLETED 的 PREVIEW run**：包內容全部derive自該 run 的 Manifest、
   快照與既有不可變資料（journal、approval 快照、audit 事件、source_document 索引）——
   **不重新查詢任何 current 物件**（INV-29 同一精神）。FAILED／RUNNING run 不可產包。
2. **EvidencePackage＝不可變 DB 實體**＋內容索引（每節：類型、筆數、content hash）＋
   整包 `package_content_hash`（canonical 內容聚合，排除 package_id／時間戳——與 02B
   的 hash 紀律一致）。同一 run 重複產包＝冪等（同 run 已有包→回傳原包；內容必然相同）。
3. **本刀輸出格式＝單一自包含 HTML 底稿檔**（封面＋各節內容＋雜湊對照表），由既有
   node:http 直接產生下載；Excel／壓縮包／正式 ExportJob 屬後續。檔名前綴
   `PREVIEW_DRAFT_`，封面與每頁標頭帶「DRAFT・UNREVIEWED・未折算（NO_FX）・
   不得作為入帳或交付依據」。
4. **追溯等級誠實揭露**：依 run Manifest 內 SOURCE_TB 的 granularity（Case-001＝BALANCE）
   逐節標示「本包可反查至餘額級；不得宣稱分錄級／憑證級」（AC-AUD-001 分級）。
   重演深度聲明＝「依 Manifest 重演 run」（02B 已提供），不宣稱超出 DataCoverage 的深度。
5. **不建立 DeliveryRecord、不產生 delivery_quality、不入 SUPERSEDED 鏈**（INV-27／09；
   02B 護欄 4 延續）——預覽證據包是診斷／覆核輔助，不是交付。
6. **產包同一交易**：EvidencePackage＋內容索引＋DomainEvent 同交易寫入；產包為同步
   讀取衍生（無新計算），不需 BackgroundJob。

## 包內容（各節與來源）

| 節 | 內容 | 來源（全部凍結／不可變資料） |
|---|---|---|
| 封面 | DRAFT・UNREVIEWED・NO_FX 警語、run／manifest／package hash、追溯等級聲明 | run＋manifest |
| 來源 | ImportBatch、batch_version、檔案 SHA-256、TB 科目彙總 | Manifest SOURCE_TB entry |
| 映射 | 解析出的每條 MappingRule（版本、生效區間、目標科目）＋批准人／時間 | Manifest MAPPING entry＋mapping_rule 不可變已批准列 |
| 調整 | Adjustment（批准時 business_version）＋物化 JournalEntry／Line＋G-08 四項證據欄＋編製／覆核／批准三人與時間 | Manifest ADJUSTMENT entry＋adjustment／journal（APPROVED 後不可變） |
| 計算 | frozen_set_content_hash、engine／canonicalization 版本、快照兩層、G-09 控制總額、result_content_hash | manifest＋balance_snapshot_line |
| 事件 | 該 run 與其輸入物件的 DomainEvent 時間軸（uploaded→accepted→drafted→approved→created→completed） | audit_event（append-only） |
| 附件索引 | source_document（檔名、SHA-256、object key、大小）——索引不內嵌檔案本體 | source_document（不可變） |

## 驗收清單

| # | 條件 |
|---|---|
| 1 | 只有 `COMPLETED` 的 PREVIEW run 可產包；RUNNING／FAILED → 409＋機器代碼留痕；R2／R3 限定，越權 403＋留痕 |
| 2 | EvidencePackage＋索引＋DomainEvent 同一交易；包與索引不可 UPDATE／DELETE（DB 觸發器）；歸屬守衛（package↔run 同租戶）＋RLS |
| 3 | 同一 run 重複產包＝回傳原包（冪等；`UNIQUE(calculation_run_id)`），不產生第二個包 |
| 4 | `package_content_hash` 為 canonical 內容聚合（排除 package_id／時間戳）；同 run 產包內容必然重現同 hash |
| 5 | 包內來源雜湊與 `import_batch.file_sha256`、映射版本集合與 Manifest、分錄與 journal_line、快照與 balance_snapshot_line **逐項一致**（Case-001 核對） |
| 6 | 追溯等級聲明＝BALANCE 級（依 Manifest granularity），內文不出現「分錄級／憑證級」宣稱 |
| 7 | 下載檔檔名 `PREVIEW_DRAFT_` 前綴；封面與標頭帶 DRAFT・UNREVIEWED・未折算警語；G-09 控制總額表在包內 |
| 8 | 不存在 DeliveryRecord／delivery_quality 寫入路徑；產包後全庫掃描仍無任何交付紀錄 |
| 9 | 批准鏈完整：調整節含編製／覆核／批准三個不同自然人與時間；映射節含批准人≠建立者 |
| 10 | 事件時間軸節涵蓋 run 生命週期全部 DomainEvent，且與 audit_event 筆數一致 |
| 11 | 包建立後竄改上游（如停用觸發器改快照）不影響已產包內容（包自持凍結內容或 hash 可偵測）——以 hash 對照表驗證 |
| 12 | 產包拒絕與失敗均保存機器代碼＋客戶可理解原因（ControlViolationAttempt） |

## 明確不做（BACKLOG 或後續刀）

正式（OFFICIAL）證據包與 ExportJob／DeliveryRecord；Excel／壓縮包格式與
FileExchangeAdapter；附件檔案本體內嵌（僅索引）；審計師唯讀視圖（R5，P1）；
retention／TTL（D-26-04）；抽樣重演 UI（重演本身 02B 已具備）；折算相關內容（MVP 3）。

**流程**：本文件走查通過 → migration（EvidencePackage 實體＋守衛）→ API（產包＋下載）
→ 三層測試 → Case-001 逐項核對 → 更新 handoff → 里程碑 2 檢視（02 系列收官）。
