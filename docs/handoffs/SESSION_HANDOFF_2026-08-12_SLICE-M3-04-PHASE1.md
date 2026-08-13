# SESSION HANDOFF　SLICE-M3-04 現金流支持資料（持續更新的唯一交接入口）

> 檔名保留 `PHASE1` 是為了不讓既有連結失效；本檔內容已推進至 **2b 第二刀 A 完成**。
> 後續 M3-04 換機交接持續更新本檔，不再為每一小段新增 handoff。

最近完整測試基準：**3A（1,426／1,426）**，工作區乾淨；
`111219d` 以前已 push，其後（範圍定案文件 ＋ 3A）尚未 push。
完整測試 **1,426** 零失敗：單元 66 ／ DB 整合 923 ／ 端到端 437。
**46 份 migration**（可從零重建）。

**權威契約：`docs/slices/SLICE-M3-04_現金流支持資料.md` 第五版**（經五輪走查凍結）。
新 session 只要先讀 `SESSION_START.md`、本 handoff、該契約與 0039～0045，
就能直接開始 **2b 第三刀：CFS 非同步計算閉環**（範圍見下，已定案）。

## 現在切在哪裡

契約、模型、結構守衛、角色工作流、**支持 run 的建立入口**與 **Manifest 的
system-only 凍結入口**已完成且全綠。下一步是 **2b 第三刀：CFS 非同步計算閉環**——支持資料列、判定、K1～K4、
結果雜湊與 replay 合為一刀（理由見下）。各段已獨立提交，不得回頭重做或混改。

## 第一段交付（0039／0040／0041）

| migration | 解決什麼 |
|---|---|
| **0039** | 模型與守衛：十四張表 ＋ 三支粒度函式。`fn_manifest_verify` 成為通用入口（由 `fn_fx_verify_manifest` 改名），**舊名保留為相容 wrapper**——M3-02／M3-03 的行為與斷言完全不動 |
| **0040** | 三個結構缺口：`source_ledger_line_id` 實際是 **bigint**（0039 誤寫 uuid）且兩個來源引用**都沒有外鍵**；零活動缺 `reason`、兩張表的 `content_hash` 可空；`calculation_run` 只能歸屬**一個**批次 |
| **0041** | 用途封套必須指向**該 dataset 自己的** `DataCoverage` |

### 0040 的多批次橋接（容易誤讀的一項）

一期的現金流支持資料可能來自多個已接受批次；任選一個填進 `import_batch_id`，
run 的來源歸屬就會說謊。因此新增 `calculation_run_source_batch` 橋接
（每個批次都必須 `ACCEPTED`，且與 run 同租戶／案件／期間），
並把 `calculation_run.import_batch_id` 放寬為可空——
**但只對 `CASH_FLOW_SUPPORT` 開分支**：該 scope **不得**填單一批次，
`NO_FX`／`FX_TRANSLATION` 仍**必須**指明來源批次。既有行為完全不變，
且有一條測試專門釘住這個不變（`0040：NO_FX run 仍必須指明來源批次`）。

### 0041 的 `data_coverage_id`（本段最重要的修正）

0040 的 fact guard 以「**整個批次最細的** `DataCoverage`」取粒度：

    WHERE dc.import_batch_id = … ORDER BY fn_granularity_rank(...) DESC LIMIT 1

同一批次若同時有 `BALANCE` 與 `DOCUMENT` 的 dataset，**`BALANCE` 的 fact 就能
冒用 `DOCUMENT` 粒度**——封套與真實 dataset 因此分離，而粒度是完整度判定與
例外路徑的判準。

0041 讓封套直接引用 `data_coverage_id`（NOT NULL），守衛驗六件事：
底層 `source_dataset` 同租戶且其 `import_batch_id` 等於封套宣告的批次；
`DataCoverage` 同租戶同批次；覆蓋度與資料集的 `batch_version` 一致；
**覆蓋度粒度＝資料集粒度**；批次屬本案件；批次的宣告期間與封套一致。
fact 的 `actual_granularity` 改為**直接等於封套所指的那一筆**。
封套建立後不可 UPDATE／DELETE，更正走新 dataset。

## 第二段：2a 已關閉，下一步只做 2b

### 2a　角色工作流函式（0042，CLOSED／PASS）

0042 未回改 0039～0041。全部寫入入口為 **system-only 函式**：固定
`SET search_path = pg_catalog, public`、`REVOKE ALL … FROM PUBLIC` 後明示授權，
驗 `current_tenant()`、角色作用域與完整父鏈；`app_runtime` 對現金流各表維持只有 SELECT。

| # | 函式 | 角色 |
|---|---|---|
| 1 | `CashFlowClassSetVersion` 建立／批准 | R4；批准時檢查**恰好一個** `FX_EFFECT_ON_CASH` 與**至少一筆**現金科目 membership |
| 2 | `CashFlowPolicyVersion` 建立／批准 | R4 |
| 3 | `CashFlowMappingVersion` 建立、R3 覆核、R4 批准 | R2 建立／R3 覆核／R4 批准 |
| 4 | `CashFlowCoverageException` 批准 | R4（逐分類，不得整期豁免） |
| 5 | `CashFlowOpeningBalanceSetVersion` 建立／批准 | R4 |
| 6 | `PeriodCashFlowSourceSelection` 選定 | R4；版本鏈由**取代鏈**判斷、不得分叉 |
| 7 | 零活動的 R2 確認、R3 覆核 | R2 ＋ R3（四組資料齊備才完整） |

另完成：十一張表的父鏈與版本鏈守衛、`CashFlowZeroActivityAttestation`、映射的
R2→R3→R4／SoD／生效區間重疊／靜態粒度相容、Coverage 有效結論的父鏈，以及
`DATA_PRESENT` fail closed（只能留給 2b 的系統衍生入口）。

cashflow DB 測試由 36 增至 **144**；既有 36 條的斷言與預期錯誤未弱化。
九項控制分五批反證，皆在反轉後轉紅、還原後全綠。2a 的提交為 `6ad2e82`。

### 2b　計算與判定（分刀進行；2026-08-13 走查後重排）

1. ~~支持資料 run（`calculation_scope = 'CASH_FLOW_SUPPORT'`）與多批次來源橋接~~
   **已完成（0043，提交 `62700c6`／`6f2bf0a`，CLOSED／PASS）**；
2. ~~A：CFS Manifest 的 system-only 凍結入口 ＋ `fn_manifest_verify` 驗證~~
   **已完成（0044 ＋ 0045 hardening）**；
3. **第三刀＝CFS 非同步計算閉環**（2026-08-13 定案，範圍已擴大）：支持資料列、
   `DATA_PRESENT`、粒度、完整度、K1～K4、結果雜湊與 replay **合為一刀**；**← 下一刀**
4. 契約 26 條驗收與指名反證，完成後跑完整一輪。

**為什麼第 3～6 項不能再拆開交付**（走查結論，不得改回）：
`CashFlowSupportLine` 與 Run 終態都**不可變**。若先寫出結果並把 Run 標成
`COMPLETED`，之後才發現粒度不足或 K1～K4 不成立，就沒有合法途徑撤回結果；
反之若 Run 一直停在 `RUNNING`，這一刀也不能誠實宣稱「結果雜湊與 replay 已完成」。
不可變輸出與後續控制之間會留下結構性矛盾，因此必須一次閉環。

### 第三刀定案：CFS 非同步計算閉環

流程固定：**凍結 Run＋Job → 只讀 Manifest 解析候選列 → `DATA_PRESENT`／粒度／
完整度／K1～K4 → 原子寫入支持列＋雜湊＋Run/Job 終態 → replay 走同一路徑**。

1. **BackgroundJob 接軌**：凍結入口同交易建立 Manifest／Run／橋接／`CALCULATION_RUN`
   Job（冪等鍵＝`calculation_run_id`）；worker 依 Manifest scope 分流，
   `CASH_FLOW_SUPPORT` **不得**落入既有 NO_FX 計算路徑；租約、fencing、重試與
   Run/Job 終態原子性沿用 M2-03。建立入口只凍結與排程，不同步計算（§27.4）。
2. **只從凍結內容解析支持列**：每筆凍結 fact 必須**恰好**命中一條凍結映射
   （ACCOUNT→account_id／JOURNAL_LINE・SUBLEDGER→source_ledger_line_id／
   DOCUMENT→source_document_id），且符合凍結的期間終了日與生效區間；
   0 條 → `CFS_UNMAPPED_SOURCE`，>1 條 → `CFS_MAPPING_AMBIGUOUS`。
   無預設分類、不得回查現行主檔、金額幣別原樣承接。
   **SCOPE 需升版補凍結**：`period_end_date`、`materialization_contract_version`、
   來源 run 的 functional／reporting 幣別；缺欄位的舊 CFS Manifest **fail closed**，
   不得回查期間或 Run 主檔補值。
3. **支持列的 DB 最後防線**：父 Run 為 `CASH_FLOW_SUPPORT`／`RUNNING`；橋接集合與
   Manifest SCOPE **完全一致**且至少一筆；租戶／案件／期間／單位一致；fact、映射、
   分類、金額、幣別、例外等於凍結解析結果；`(run_id, source_fact_id)` 唯一；
   寫入後不可 UPDATE／DELETE。**0043 的「無橋接不得產出」暫留邊界在此正式關閉。**
4. **輸出前完成判定**：候選列先在交易內產生，全部控制通過前不得寫入正式支持列。
   `DATA_PRESENT` 只能由系統依候選 fact 衍生；粒度用 SCOPE 綁定的
   `data_coverage_id` 判定，不足須有凍結且已批准的例外；完整度與 K1～K4 只讀凍結
   內容；與既有 `ZERO_ACTIVITY`／例外矛盾時 fail closed，不得覆寫。
   **replay 只重新衍生判定，不新增或修改期間級 coverage。**
   確定性失敗＝Run `FAILED`／Job `COMPLETED`／支持列 0／穩定代碼／同交易終結。
5. **CFS 結果雜湊**：`fn_calc_result_hash` 新增明確的 `CASH_FLOW_SUPPORT` 分支，
   **未知 scope 直接拒絕**（不得再走泛用 ELSE）。canonical 至少涵蓋分類／source kind／
   activity、`source_fact_id` 與凍結 fact 的 content hash、`mapping_rule_id` 與該條
   凍結規則的 deterministic hash、功能幣與報告幣金額與幣別、使用的例外 ID、固定排序；
   排除 run／列 ID 與時間戳。**只改命中的映射規則、金額不變，雜湊也必須改變。**
6. **Replay**：新 Run＋新 Job，`replay_of_run_id` 指向原 Run 並引用同一 Manifest；
   橋接由**凍結 SCOPE 重建**，不讀現行來源選定；**來源批次日後成為 `SUPERSEDED`
   仍應可重演**——不得用「目前必須 ACCEPTED」破壞凍結重演；過程不得讀
   `cash_flow_source_fact`、映射／分類主檔或現行 coverage；hash 一致才完成，
   不一致則 replay Run 失敗、零支持列、原 Run 永不修改；worker 重試不得產生
   第二個 Run 或重複支持列。
7. **SECURITY DEFINER 通則**：本刀新增的 helper 一律不授權 app_runtime、函式內自驗
   `current_tenant()`、跨租戶已知 UUID 得到穩定拒絕；測試掃描
   `fn_cf_*`／`fn_cfs_*`／`fn_cash_flow_*` 三種前綴的權限，避免第三次同型漏洞。

**允許拆 3A～3D 分提交，但不得分開宣稱完成**：
(A) ~~Manifest 契約升版＋私有解析器~~ **已完成（0046）** →
(B) `DATA_PRESENT`／粒度／完整度／K1～K4 →
(C) 支持列原子落地＋結果雜湊 →
(D) BackgroundJob、replay、競態與完整收口。

**明確不做仍維持**：畫面、期間遷移解鎖、完整現金流量表、證據包、正式交付，
以及平台反推 `FX_EFFECT_ON_CASH`。

### 3A 已交付（0046）——閉環尚未完成，不得宣稱第三刀完成

`SCOPE` 補凍結 `materialization_contract_version`（`cfs-mat-1`）、期間起訖日、
功能幣／報告幣與其指派 ID；`fn_cf_parse_support_candidates(run)` 只讀凍結 payload
解析候選列，未映射／多重映射／分類不在集合內／未知契約版本一律 fail closed。
私有化並驗 `current_tenant()`。cashflow DB 測試 284 → **308**。

**3A 的四個實作決定**：
1. **契約版本先於結構驗**：版本決定其餘欄位怎麼解讀，因此
   `fn_cf_manifest_assert_contract` 把版本檢查排在 singleton 之前。
2. **命中條件只寫一次**：一次收集命中規則到 jsonb 陣列，再由陣列長度判 0／1／多，
   不要為了取 `mapping_rule_id` 把命中條件抄第二遍。
3. **「舊集合」不能用竄改模擬**：竄改會先被 `fn_manifest_verify` 以完整性理由擋下。
   真正的舊集合是**雜湊自洽卻缺欄位**，測試因此手工建一份（`MFOLD`）。
4. **反證要單獨跑**：生效區間過濾與多重映射判定會互相遮蔽——兩個一起拿掉時，
   前者不會轉紅。已各自單獨反證過。

**3B～3D 尚未開始**：判定（`DATA_PRESENT`／粒度／完整度／K1～K4）、支持列原子落地
＋結果雜湊、BackgroundJob／replay／競態。目前 run 仍停在 `RUNNING`、零支持列、
無 result hash——這是 3A 的正確狀態，**不是可交付的閉環**。

### 第三刀動工前已拍板的三件事（保留為紀錄）

1. **計算引擎放 SQL 還是 worker（TS）**：FX 在 SQL（`fn_fx_translation_run`），
   NO_FX 在 worker。**worker 是以 owner 身分連線**（`asRuntime: false`），
   因此「app_runtime 不得直接寫入」兩種放法都擋不住它，不構成選擇依據。
2. **0040 的橋接守衛擋 replay**：`fn_run_source_batch_guard` 對每筆橋接都要求
   `ACCEPTED`；replay 由凍結 SCOPE 重建橋接，來源批次日後轉 `SUPERSEDED` 就會被擋。
   要讓「凍結重演」成立必須 `CREATE OR REPLACE` 該守衛加 replay 例外
   （限「該批次確實在原 Run 的凍結 SCOPE 內」），並補一條反證：**未被凍結的批次
   不得藉 replay 混入**。
3. **`DATA_PRESENT` 是期間級副作用**：它寫進 `cash_flow_class_period_coverage`
   （per period×unit×policy），不在 run 之下。原 Run 寫、replay 不得寫——
   replay 必須以 coverage 列數增量為 0 釘住。

**結果雜湊與 replay 為什麼從第 2 項移到第 3 項**（走查結論，不得改回）：
在 `CashFlowSupportLine` 落地前**沒有真實輸出可以雜湊或重演**。若在第 2 刀就宣稱
「結果雜湊與 replay 完成」，實際上只會是拿 Manifest 的集合雜湊冒充 result hash——
replay 比對的必須是**實際輸出**，不是輸入凍結值。第 2 刀只交付「輸入凍結與驗證」。

**尚未完成的兩條界線，不得誤寫成 2a 已完成**：

- `CFS_MAPPING_AMBIGUOUS` 現在只驗**同一版本內**的規則重疊；跨版本由取代鏈決定
  現行版本，本來就不是「映射歧義」。2b 的動態判定只對現行批准版本執行。
- 粒度目前只有建立規則時的**靜態相容性**；「實際 DataCoverage 是否足夠」尚未實作，
  必須由 2b 以封套綁定的那一筆 `data_coverage_id` 判定。

2b 明確不做畫面，也不解鎖期間遷移；先讓計算、凍結、重演與控制總額在 DB 層閉合。

### 已完成的上一刀範圍　2b 第二刀 A（0044）當初定案的五點

**範圍固定為以下五項**（2026-08-13 定案）：

1. `app_runtime` **不得直接建立** `CASH_FLOW_SUPPORT` Manifest；
2. 由**單一 trusted 函式**在同一交易／snapshot 內解析輸入、建立 canonical entries、
   計算集合雜湊；
3. **Manifest ＋ entries ＋ Run ＋ 來源橋接同生共死**；
4. 驗證使用**既有的 `fn_manifest_verify`**（0039 已建立，由 `fn_fx_verify_manifest`
   改名而來）——**不另寫第二套**；
5. 鎖定來源批次**與實際引用的批准版本**，補齊 TOCTOU、竄改、缺項、重複項與
   半套寫入的測試。

**一項必要的測試調整（不是重做也不是弱化 0043）**：0043 的正控制目前刻意允許
「零 Manifest entry 仍建立 Run」——那是 0043 明文留下的過渡邊界
（斷言：`0043：本刀只建立 run——不產生支持資料列、不凍結 Manifest 條目`）。
第二刀真正封存之後，**這條過渡性正控制必須改成完整 Manifest**，否則新控制
不可能成立。改它是**關閉 0043 自己寫下的邊界**，與「既有斷言不得修改」的紀律
不衝突——差別在於 0043 檔頭已寫明它是暫留項。

### 2b 第一項　支持 run 的建立入口（0043，CLOSED／PASS）

0040 讓 run 的來源改由橋接凍結，卻沒有入口——app_runtime 對 `calculation_run`
有 INSERT（NO_FX 要用）、對橋接只有 SELECT，因此建得出「scope 是現金流、
卻零筆來源」的 run。0043 把建立收斂成單一 system-only 入口
`fn_cash_flow_support_run_create(manifest, batches[], actor, engine_version)`：
案件層 **R2**（比照 `fn_fx_translation_run`）、至少一筆／不重複／不含空值、
依 `import_batch_id` 遞增順序 `FOR UPDATE` 後才寫入、run 與橋接同一交易。
每筆批次的 ACCEPTED／期間／案件仍由 **0040 的 trigger** 判定，本刀不重寫一份。

cashflow DB 測試由 144 增至 **204**；既有 0039～0042 斷言零刪改（diff 為純新增）。
九項控制分四批反證，皆在反轉後轉紅、還原後全綠。提交為 `62700c6`（0043）
與 `6f2bf0a`（權限斷言）。

**0042 的權限掃描有一個名稱過濾漏洞**：`proname LIKE 'fn_cf%'` 的 `_` 是
**單字元萬用字元**，等於要求第五個字元是 `f`，`fn_cash_flow_support_run_create`
因此被靜默排除。既有三條不改，另立四條以 `^fn_(cf|cash_flow)_` 涵蓋兩種命名。
**下一刀新增 `fn_cash_flow_*` 命名的函式時，別以為 0042 那三條會掃到它。**

**三件下一刀必須知道的事**：

1. **system-only 用執行身分當邊界，不是 GUC。** app_runtime 的 `calculation_run`
   INSERT 收不回（NO_FX 要用），所以 trigger 比對 `current_user` 與表 owner。
   `fn_calculation_run_insert_guard` 因此**必須維持 SECURITY INVOKER**——改成
   DEFINER 的話 `current_user` 會變成 owner，檢查對誰都通過，等於沒寫。
2. **「至少一筆橋接」只在函式層強制**（已與使用者確認）。0040 有一條既有斷言
   單獨建立無橋接的 run，加 `DEFERRABLE` 約束會讓它在 commit 轉紅。真正的防線
   是權限邊界；owner 直插屬既有的邊界外。**關閉時限（已確認）：「無橋接不得產出」
   的最後防線補在第 3 項的支持資料列寫入路徑**，不得再往後拖。
3. ~~CASH_FLOW_SUPPORT manifest 仍可由 app_runtime 直接 INSERT~~ **已於 0044 關閉**
   （scope-specific INSERT trigger ＋ 唯一凍結入口）。

**測試設計上的兩個實測結論**：

- **每條負面測試各用一份新的 Manifest**（`mfn()` 助手），並逐條回驗
  「沒有留下半套 run」。共用一份時，控制一被拿掉，第一條就佔用它、後面全部以
  `CFS_RUN_MANIFEST_ALREADY_USED` 連鎖失敗——反證時分不出是哪一項控制在守。
- **跨案件 fixture 不得沿用 `adjustment.test.sh` 的 …099 期間鏈**：聚合模式下
  它已存在（撞主鍵會讓整段 fixture 中止），而且它的 `reporting_unit` 沒有
  `legal_entity_id`，掛批次會先撞 0024 的歸屬守衛。現金流用 …098 系列自建。
  fixture 的 heredoc 也不再吞 stderr，建立失敗即 fail closed。


### 2b 第二刀 A　Manifest 的 system-only 凍結入口（0044，CLOSED／PASS）

唯一對外入口 `fn_cash_flow_support_freeze_and_run(period, unit, policy, mapping,
batches[], actor, engine)`，案件層 **R2**。**政策與映射版本由參數顯式帶入**——
不得由「最新已批准」推導（驗收 1 的反證）；權威來源選定取既有
`fn_current_cf_source_selection`（取代鏈）。

執行順序就是本函式的全部重點：**先鎖 → 單一 statement 物化 → 只驗物化後的集合 →
寫入 → 結構契約查證**。PL/pgSQL 每個 statement 各有 snapshot，「同一個函式」證明
不了「同一份輸入」。九種條目、所有內嵌陣列以穩定 ID 排序；canonical 與集合雜湊
逐字沿用 0034 的 `fn_fx_freeze_entry2`，驗證沿用 `fn_manifest_verify`，另加薄函式
`fn_cf_manifest_assert_contract`（scope／singleton／條件式期初證據／來源 run 1 或 2 筆／
object_id 非空）——**沒有第二套 canonical 或 hash**。

cashflow DB 測試 204 → **284**（含 0045 的 hardening）。十項控制分三批反證轉紅；
第四批（兩把鎖）**不轉紅**，兩個結論見下。

### 0045　走查後的三項收口（與 0044 同一刀交付）

1. **SECURITY DEFINER helper 一律私有化 ＋ 驗租戶**：`fn_cf_manifest_assert_contract`
   與 `fn_calc_result_hash` 原本都授權 app_runtime 且不驗租戶——等於兩支拿已知 UUID
   探測他人 Manifest／Run 是否存在（甚至取得結果雜湊）的工具。兩支都撤回授權並加
   `current_tenant()` 查證。**新增 SECURITY DEFINER helper 時預設就該這樣做**：
   凍結路徑以 owner 身分呼叫它們，app_runtime 從來不需要。
2. **來源 run 的凍結補完**：FX payload 補上 `translation_policy_rule_id`、逐筆
   component 與 CTA 的政策／匯率版本證據；新增 `fn_calc_result_hash(run)` 並在
   **凍結當下復驗**來源 run 的 `result_content_hash`——輸出若被資料修復破壞，
   不得把「損壞行＋舊雜湊」一起封存。測試已釘住「**只用凍結 payload** 就能重算出
   來源 FX run 的結果雜湊」。
3. **改選競態的記載更正**：`fn_cf_select_source`（0042）本來就 `FOR UPDATE OF pr`，
   與凍結鎖同一列 → 該邊界不存在，已改為雙 session 測試（凍結交易未提交時，
   改選會被期間列鎖擋住）。

`fn_calc_result_hash` 的兩條公式是**既有生成端的鏡像**（FX 取自
`fn_fx_materialize`；NO_FX 取自 worker 的 canonical 結果雜湊）。生成端一個在 SQL、
一個在 TypeScript，沒有共用位置，因此**防分岔靠測試**：cashflow 釘引擎產生的折算
run，端到端 `calculation-run` 套件釘 worker 產生的 NO_FX run。**改動任一端的公式，
那兩條斷言就會轉紅——不要只改一邊。**

**三件下一刀必須知道的事**：
1. **凍結函式不再自己檢查來源批次**：0043 的 helper 是那份唯一實作。反證時把凍結
   函式裡的批次檢查與 `FOR UPDATE` 拿掉不會轉紅——擋住競態的一直是 helper 的鎖。
   錯誤碼不變，但現在是在 manifest 物化**之後**由 helper 拋出（整份回滾）。
2. **期間鎖沒有測試能單獨證明它**：任何兩次同期間的凍結都共用政策／映射／選定那
   幾列的 `FOR UPDATE`。保留它是為了「先鎖期間、再解析現行選定」的順序保證；
   不要因為看起來多餘就拿掉，也不要宣稱測試證明過它。版本列鎖同樣**擋不住取代鏈
   被接上**（新版本是 INSERT，不 UPDATE 舊列）——顯式帶入政策／映射版本之後，
   後續版本被建立也不會改變本次凍結的輸入，不必假裝鎖擋得住它。
3. **`fn_cfs_*` 是第三個命名前綴**，不匹配 0043 加的 `^fn_(cf|cash_flow)_` 權限掃描。
   目前那兩支是 SECURITY INVOKER 所以無妨；**日後若有人用 `fn_cfs_*` 命名 SECURITY
   DEFINER 函式，會靜默漏掃**——加函式時記得一併擴充掃描的正規式。

**既有 0043 斷言的變更**（皆為關閉 0043 檔頭明文留下的過渡邊界，已獲授權）：
正控制改走凍結入口（並多帶一筆批次，橋接三筆）、「零條目 Manifest」改為「已完整
凍結」、`CFS_RUN_MANIFEST_ALREADY_USED` 改用新 run 的 manifest、helper 權限斷言
改為 `true/false/false`。0039～0042 的斷言未動。

**測試 fixture 的三個實測陷阱**：
- `balance_snapshot_line` 必須在 run 轉 `COMPLETED` **之前**寫入（0013 的
  `trg_bsl_run_state`）；來源 run 的 `result_content_hash` 一律用
  `fn_calc_result_hash()` 實算，填假雜湊會讓凍結當下的復驗永遠測不到。
- **折算 run 不要手工拼**：`translation_result` 需要 component、CTA component 需要
  `translation_adjustment_line` → `entry` → 折算政策與匯率版本，且 component 引用的
  版本必須與該 run 凍結的 manifest 一致。現金流第三期改為呼叫**引擎**
  `fn_fx_translation_run`（前置：幣別指派、匯率版本走完 R2→R3→R4、折算政策＋規則、
  `fn_period_fx_select_inputs`），這樣拿到的才是真實的輸出與 result hash。
- `reporting_period` 對 `(reporting_unit_id, fiscal_calendar_id, daterange)` 有排除
  約束，聚合模式下與別的領域檔撞月份會讓整段 fixture 中止；新期間請挑沒人用過的年份。

## 2026-08-13 端到端 fixture 退化與修復（94c0b29）

`351eb86` 的 B-06 畫面種子為同一期間加入一筆 `ACCEPTED` 批次與一筆 `RUNNING` run。
四支既有端到端測試卻用「只按期間查批次」或 `LIMIT 1` 找自己剛建立的物件，開始回傳
多列或抓到 seed 的 run。舊 handoff 所寫的 1,144 全綠是 B-06 種子變更前的事實，
其後沒有完整重跑，不能拿來代表當時 HEAD。

修復規則已成為測試契約：

- 批次以測試自己可計算的 `file_sha256` ＋期間＋上傳者定位；
- 同內容重複上傳另以 `created_at > since` 排除較早批次；
- run 以該測試自己的 `request_key` 反查，不用 `LIMIT 1`；
- 每次取得 ID 後立刻回驗父鏈與雜湊（run 另驗來源批次）；
- 計數型斷言只計該測試自己的批次／run，不看全表。

這次修復使端到端斷言由 427 增至 **436**；修復後基線為 1,153，2a 加入後為 1,261。
日後 seed 增加資料時，**不得假設「某期間只有一批」或「第一列就是我的資料」**。

## 已踩過、2b 仍須遵守的測試陷阱

1. **被更前面的守衛以別的理由擋住**：fact 的測試需要**真正的**支持資料集
   （否則先撞封套守衛）；矩陣測試需要**存在的**來源列（否則先撞跨租戶檢查）。
2. **`INSERT … SELECT … LIMIT 1` 空集合假綠**——改用明確建立的 manifest。
3. **bash 3.2 全形斷詞第五次**（`$var（`）——新測試檔一律 `${var}`。
4. **不可逆或已占用的 fixture 讓反證失效**：粒度反證第一版用了**已被封套**的
   dataset，`duplicate key` 先擋下，拿掉檢查後仍轉不紅。

**schema 事實**（實測得知，寫給下一位）：
- `source_dataset` 對 `(import_batch_id, granularity)` 有唯一鍵——
  同一批次**無法**有兩個 `BALANCE` dataset。
- `source_dataset`／`data_coverage` 只能在批次 `DRAFT`／`UPLOADED`／`VALIDATING`
  時寫入（接受後來源集合已封存）；fixture 要先建再轉 `ACCEPTED`。
- `calculation_run` 建立時必須是 `RUNNING`，結果狀態由執行交易寫入。
- 一份 manifest 只能有一個原始 run（`calc_run_manifest_origin_uq`）。

## 契約中尚未實作、2b 必須遵守的邊界

- **P0 只收集與映射，不重建**（GB-04）。支持資料列**沒有任何可以放推算結果的
  欄位**——要重建就得先加欄位，那個動作會很顯眼。
- **沒有預設分類**：未映射就是未映射，由完整度判定擋下。
- **`FX_EFFECT_ON_CASH` 在 P0 不由平台計算**——由「期末 − 期初 − 三大活動」
  反推會讓 K2 變成恆等式、永遠驗不出東西。
- **零活動是合法的**：`DATA_PRESENT`（只能由系統依 fact 衍生）／
  `ZERO_ACTIVITY_CONFIRMED`／`COVERAGE_EXCEPTION` 三者有其一即可。
- 本刀**不解鎖任何期間遷移**、不做畫面、不做完整現金流量表。

## MVP 3 全域剩餘

1. **REQ-CFS-001**（本刀，2b 第 2～7 項未完）——未完成前 **MVP 3 不得關閉**。
2. **G-03：B 基礎（遞延稅）判定**；`AMENDED` 取代鏈亦未完成。
3. **對外輸出／`OutputProfile` 核對**——`ROUNDING_DIFFERENCE` 的真正使用場景。
4. 折算結果就緒的**正式 Guard ID**（須走 CR，BACKLOG 已記）。
