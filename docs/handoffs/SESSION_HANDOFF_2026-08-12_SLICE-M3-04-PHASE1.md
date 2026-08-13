# SESSION HANDOFF　SLICE-M3-04 現金流支持資料（持續更新的唯一交接入口）

> 檔名保留 `PHASE1` 是為了不讓既有連結失效；本檔內容已推進至 **2b 第二刀 A 完成**。
> 後續 M3-04 換機交接持續更新本檔，不再為每一小段新增 handoff。

最近完整測試基準：**2b 第二刀 A ＋ hardening（1,399／1,399）**，工作區乾淨。
**尚未 push**（`25d84dd` 之後的提交）。
完整測試 **1,399** 零失敗：單元 66 ／ DB 整合 896 ／ 端到端 437。
**45 份 migration**（可從零重建）。

**權威契約：`docs/slices/SLICE-M3-04_現金流支持資料.md` 第五版**（經五輪走查凍結）。
新 session 只要先讀 `SESSION_START.md`、本 handoff、該契約與 0039～0045，
就能直接開始 **2b 第三刀：支持資料列 ＋ 結果雜湊與 replay**（範圍見下）。

## 現在切在哪裡

契約、模型、結構守衛、角色工作流、**支持 run 的建立入口**與 **Manifest 的
system-only 凍結入口**已完成且全綠。下一步是 **2b 第三刀：`CashFlowSupportLine`
原樣承接 ＋ 結果雜湊與 replay**（同一刀，見下）。各段已獨立提交，不得回頭重做或混改。

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
3. `CashFlowSupportLine` 原樣承接已接受 fact 的 signed amount 與命中映射，
   **結果雜湊與 replay 併在同一刀**；**← 下一刀**
4. `DATA_PRESENT` 只能由系統依已接受 fact 衍生；
5. 以實際 `DataCoverage` 判定 run-level 粒度是否滿足政策；
6. 完整度的穩定代碼、K1～K4 控制總額與期間級就緒判定；
7. 契約 26 條驗收與指名反證，完成後跑完整一輪。

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

cashflow DB 測試 204 → **281**（含 0045 的 hardening）。十項控制分三批反證轉紅；
第四批（兩把鎖）**不轉紅**，兩個結論見下。

### 0045　走查後的三項收口（與 0044 同一刀交付）

1. **結構驗證 helper 私有化**：`fn_cf_manifest_assert_contract` 原本是
   SECURITY DEFINER 卻授權 app_runtime 且不驗租戶——等於一支拿已知 UUID 探測
   他人 Manifest 的工具。撤回授權 ＋ 加 `current_tenant()` 查證。
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
