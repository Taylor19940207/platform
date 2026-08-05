# SLICE-M2-02C　預覽證據包（走查修訂版）

**範圍**：`COMPLETED 的 PREVIEW CalculationRun → 非同步產包（BackgroundJob）→
不可變 EvidencePackage＋內容索引＋一次生成並保存的 HTML artifact（ObjectStore）→
下載＝讀已保存位元組並驗 hash`。以 Case-001 產包、索引與雜湊逐項核對、
12/12 科目範圍追溯判定通過為完成條件。

## 基線對應（抽取，不修改基線）

| 主題 | 基線位置 |
|---|---|
| 證據包內容：來源雜湊、映射版、**規則版**、計算、分錄、法源、附件索引、批准、**流程等級、控制例外** | 手冊 §00A、REQ-AUD-001／AC-AUD-001；設計書 §26.9 EvidencePackage |
| **逐科目範圍**揭露追溯等級（BALANCE／JOURNAL／DOCUMENT），不得對整期給單一結論；重演深度 ≤ 實際 DataCoverage | AC-AUD-001（CR-001 三級達成度「逐科目範圍記錄」）；D-26-03 |
| **precheck 同步、實際產生非同步**；證據包與輸出共用 run_id | 設計書 §27.4「輸出產生與證據包打包」、§25.3 |
| 預覽包：DRAFT／UNREVIEWED 標示、不建正式交付、不入 SUPERSEDED 鏈；`regenerated_from_id` 表達重產關係 | 設計書 §24.7、§25.9、§26.9 DeliveryRecord 列（預覽包語意）、INV-09／27 |
| 附件與證據包走物件儲存（ADR-03 `ObjectRetentionStore` 掛點；dev＝檔案系統實作，正式＝MinIO／S3） | 設計書 §26.14、§27.6 |
| 非同步作業：冪等鍵、fencing、租約、重試、終態原子性 | 設計書 §27.4；SLICE-M2-03 既有機制 |
| G-09 控制總額檢查於產出前 | 設計書 §24.8、§25.13 |

## 本刀凍結的設計決策

1. **非同步產包**：`POST` 同步只做 precheck（權限、run `COMPLETED`、G-09 對快照重驗）
   → 建 `BackgroundJob`（`job_type=EVIDENCE_PACKAGE`）→ worker 產生內容與 HTML →
   **Package 終態內容＋索引＋Job 終態＋完成事件同一交易**。沿用 M2-03 全套：
   claim_token fencing、租約、退避重試、確定性失敗分流、終態原子性。
2. **Package 列於 POST 交易先建**（status `GENERATING`，含 `request_key`）——與 02B
   「Run 先建 RUNNING」同構：提供 request-key 冪等的存放處、Job 歸屬守衛的驗證對象
   與唯一鍵錨點；worker 只寫終態內容。`GENERATING` 期間內容欄位全空（互斥守衛）。
3. **HTML artifact 一次生成、保存後不再渲染**：worker 先寫 **staging object**（ObjectStore，
   write-once），成功後在 fenced DB 交易中登記 `object_key`／`mime_type`／`byte_size`／
   `artifact_sha256`／`render_version` 並寫入索引與終態。**下載只讀已保存位元組並驗
   `artifact_sha256`**，不重新查 DB 渲染。DB 交易失敗留下的 staging 物件**不具權威資格**，
   日後清理（BACKLOG）。
4. **冪等與重產契約**（不做 `UNIQUE(calculation_run_id)`）：同 request key＋同內容→原
   package；同 key＋異內容→409；**明示重產→新 `package_id`＋`regenerated_from_id`**
   （render／schema 升版用）；原包永久保留、不入 SUPERSEDED 鏈。本刀 UI 不提供
   明示重產，schema 不封死。
5. **audit timeline 有截止點**：凍結 `audit_cutoff_event_id`＝該 run 的
   `calculation_run.completed` 事件 ID；時間軸節只收 `audit_event_id <= cutoff`；
   **package 自身的 created／completed 事件不納入自身內容 hash**——「同 run＋同 cutoff
   ＋同 render_version → 同 `package_content_hash`」因此成立。
6. **追溯等級逐科目範圍**：由 Manifest 的 batch ID＋batch_version 定位不可變
   `SourceDataset`／`DataCoverage`，把其 **ID、account_scope、granularity 與內容 hash
   凍結進 Package**；對**每一個輸出科目範圍**（Case-001＝12 個集團科目）產生
   `account_code → data_coverage_id → BALANCE` 判定，不對整期給單一結論。
7. **三節誠實補齊**（不省略後宣稱完整）：規則版本節＝實際 `engine_version`／
   `canonicalization_version`／識別與控制規則版本（RuleVersion 實體未實作即如實標示）；
   流程等級節＝`PREVIEW／期間包批准未完成`；控制例外節＝`無／未評估／明確列出限制`。
8. **角色**：建立與下載＝R2／R3／**R4**＋案件指派（§24.6 矩陣 EvidencePackage 之 R X）；
   R5 授權範圍下載與 R7 能力為**本刀尚未掛載的基線能力**，明示留後續。
9. 不建立 DeliveryRecord、不產生 delivery_quality（INV-27／09；02B 護欄 4 延續）。

## 實作契約（走查第二輪寫死）

**A. Package 狀態機（最小三態）**

    GENERATING ──worker 終態交易──▶ READY
               ──重試耗盡／確定性失敗──▶ FAILED

- `GENERATING`：artifact／內容 hash／完成時間**全空**（互斥守衛）；基礎設施重試期間維持此態。
- `READY`：artifact、索引、`package_content_hash`＋`artifact_sha256` **全部齊備**；**只有 READY 可下載**。
- `FAILED`：機器代碼＋人可讀原因齊備，**不得帶 artifact**；重試耗盡與 Job 同交易轉入。
- 不可變語意＝「身分欄位不可變、只允許受控終態遷移、終態不可變」——不是建立後禁止一切 UPDATE。

**B. staging 安全重試**（ObjectStore 為 write-once）

- object key 由 `package_id ＋ render_version` **確定性產生**。
- put：不存在則寫入；**已存在則讀回核對 `artifact_sha256`**——相同即安全沿用（worker 在
  「物件已寫、DB 未提交」崩潰後，重領者據此完成登記）；**不同＝確定性完整性失敗 → FAILED**。
- DB 登記交易仍以 claim-token fencing 保護。

**C. 來源實體不可變前提補齊**（本刀 migration 順手收）

`SourceDataset`／`DataCoverage`／`SourceDocument` 目前**沒有** UPDATE／DELETE 禁止觸發器，
「不可變資料」的宣稱與現況不符。本刀 migration 補：三表 UPDATE／DELETE 禁止、
tenant 與 ImportBatch 歸屬守衛；`DataCoverage` 的 canonical hash 凍結進 Package——
否則產包**之前**仍可能讀到被改寫的 coverage／附件索引。

**D. 產包前驗證（不只 G-09）**

worker 於終態交易內逐項驗證，任一不符 → Package `FAILED`（確定性失敗，不重試）——
**不得把已損壞的上游資料包裝成證據**：

1. Manifest entry 逐筆 hash 與 frozen-set hash（02B 同式）；
2. 快照重算 hash ＝ run 的 `result_content_hash`；
3. artifact 內容索引的逐節 hash 與內容一致；
4. `audit_cutoff_event_id` 恰好屬於該 run（`calculation_run.completed` 且 object_id＝run）。

## 包內容（各節與來源；全部凍結／不可變資料，不查 current）

| 節 | 內容 | 來源 |
|---|---|---|
| 封面 | DRAFT・UNREVIEWED・NO_FX 警語、run／manifest／package／artifact hash、render_version、追溯總表 | package＋manifest |
| 來源 | ImportBatch、batch_version、檔案 SHA-256、TB 彙總；**SourceDataset／DataCoverage ID＋scope＋granularity＋hash** | Manifest SOURCE_TB entry＋不可變 dataset／coverage 列 |
| 映射 | 解析出的每條 MappingRule（版本、生效區間、目標科目）＋批准人／時間 | Manifest MAPPING entry＋已批准不可變列 |
| 調整 | Adjustment（批准時 business_version）＋物化 Journal＋G-08 四項證據＋三人批准鏈 | Manifest ADJUSTMENT entry＋journal／approval 快照 |
| 計算 | frozen_set_content_hash、engine／canonicalization 版本、快照兩層、G-09 控制總額、result_content_hash | manifest＋balance_snapshot_line |
| 規則版本 | engine／canonicalization／識別規則版本；RuleVersion 未實作之如實標示 | manifest＋常數 |
| 流程等級 | `PREVIEW`；期間包批准未完成；月次／季次分級未實作之如實標示 | 固定＋run |
| 控制例外 | 無／未評估／明確限制清單（例如「未折算」「無正式覆核」） | 判定邏輯（凍結進內容） |
| 追溯判定 | **逐輸出科目範圍**：account_code → data_coverage_id → 等級（Case-001 全 BALANCE） | 快照×coverage |
| 事件 | run 生命週期 DomainEvent 時間軸（**≤ audit_cutoff_event_id**） | audit_event（append-only） |
| 附件索引 | source_document（檔名、SHA-256、object key、大小）；不內嵌本體 | source_document |

## 驗收清單

| # | 條件 |
|---|---|
| 1 | 只有 `COMPLETED` PREVIEW run 可產包；RUNNING／FAILED → 409＋機器代碼留痕；R2／R3／R4＋指派，越權 403＋留痕 |
| 2 | precheck 同步、產生非同步：POST 交易＝Package(GENERATING)＋Job＋建立事件；worker 終態交易＝內容＋索引＋artifact 登記＋Job 終態＋完成事件，fencing／租約／重試沿用 M2-03，失敗不留半套（staging 物件無權威資格） |
| 3 | 冪等契約三情形：同 key 同內容→原 package；同 key 異內容→409；schema 支援 `regenerated_from_id`（本刀 UI 不提供，DB 測試驗證可建且原包不變） |
| 4 | `package_content_hash` canonical（排除 package_id／時間戳／自身事件）；**同 run＋同 cutoff＋同 render_version 重產 → 同 hash**（DB 級以第二個 package 驗證） |
| 5 | artifact 一次生成保存：下載讀已保存位元組並驗 `artifact_sha256`；object_key／mime_type／byte_size／render_version 齊備；**下載路徑不存在查 DB 渲染** |
| 6 | **Case-001 追溯判定 12/12 科目範圍均明示 BALANCE**（各含 data_coverage_id），內文無「分錄級／憑證級」宣稱；DataCoverage ID＋scope＋granularity＋hash 已凍結入包 |
| 7 | 包內來源 SHA-256、映射版本集合、分錄、快照、控制總額與上游不可變資料逐項一致（Case-001 核對） |
| 8 | 事件時間軸只含 `<= audit_cutoff_event_id`；cutoff＝run completed 事件；包自身事件不在自身內容 hash 內（產包後新增事件不改變已產包 hash——實測） |
| 9 | 檔名 `PREVIEW_DRAFT_` 前綴；封面與標頭 DRAFT・UNREVIEWED・未折算警語；規則版本／流程等級／控制例外三節存在且如實 |
| 10 | Package／索引不可 UPDATE／DELETE；GENERATING 互斥（內容欄位空）；終態互斥；歸屬守衛（package↔run 同租戶案件）＋RLS＋封存語意（終態後不得追加索引列） |
| 11 | 批准鏈完整：調整節三個不同自然人；映射節批准人≠建立者 |
| 12 | 不存在 DeliveryRecord／delivery_quality 寫入路徑；產包後全庫掃描無交付紀錄 |
| 13 | 產包**後**上游竄改不影響已產包 artifact 與 hash（包自持凍結內容——實測）；產包**前**上游損壞（快照重算≠result hash 等契約 D 四項）→ Package `FAILED`，不包裝損壞資料（實測） |
| 14 | 拒絕與失敗保存機器代碼＋客戶可理解原因 |
| 15 | Package 狀態機（契約 A）：GENERATING 內容全空互斥、READY 齊備、FAILED 帶代碼不帶 artifact；只有 READY 可下載（非 READY 下載 → 409）；重試期間維持 GENERATING，耗盡與 Job 同交易轉 FAILED |
| 16 | staging 安全重試（契約 B）：確定性 object key；預置同內容物件 → 沿用完成登記；預置異內容物件 → 確定性完整性失敗 FAILED（雙情形實測） |
| 17 | 來源實體不可變（契約 C）：SourceDataset／DataCoverage／SourceDocument 三表 UPDATE／DELETE 被 DB 拒絕＋歸屬守衛（DB 測試） |

## 明確不做（BACKLOG 或後續刀）

OFFICIAL 證據包／ExportJob／DeliveryRecord；Excel／壓縮包與 FileExchangeAdapter；
附件本體內嵌；R5 授權範圍下載、R7 能力（基線能力，本刀未掛載）；明示重產 UI；
staging 孤兒物件清理排程；retention／TTL（D-26-04）；折算內容（MVP 3）。

**流程**：文件定稿 → migration（Package／索引／冪等與重產關係／守衛）→
BackgroundJob 擴充 → worker＋ObjectStore artifact（staging→fenced 登記）→
API／B-07 骨架（產包＋下載驗 hash）→ 三層測試 → Case-001 12/12 追溯與 hash 核對
→ 更新 handoff → 里程碑 2 檢視（02 系列收官）。
