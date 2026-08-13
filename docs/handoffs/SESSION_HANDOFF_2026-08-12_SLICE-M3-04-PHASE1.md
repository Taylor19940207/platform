# SESSION HANDOFF　SLICE-M3-04 現金流支持資料（持續更新的唯一交接入口）

> 檔名保留 `PHASE1` 是為了不讓既有連結失效；本檔內容已推進至 **Phase 2a 完成**。
> 後續 M3-04 換機交接持續更新本檔，不再為每一小段新增 handoff。

基準：**HEAD `6ad2e82`**，已 push，工作區乾淨。
完整測試 **1,261** 零失敗：單元 66 ／ DB 整合 759 ／ 端到端 436。
**42 份 migration**（可從零重建）。

**權威契約：`docs/slices/SLICE-M3-04_現金流支持資料.md` 第五版**（經五輪走查凍結）。
新 session 只要先讀 `SESSION_START.md`、本 handoff、該契約與 0039～0042，
就能直接開始 **2b**。

## 現在切在哪裡

契約、模型、結構守衛與角色工作流已完成且全綠。下一步從**工作流**轉入
**計算與判定**：支持資料 run、Manifest、輸出、完整度與 K1～K4。
2a 已獨立提交並關閉，不得與 2b 重做或混改。

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

### 2b　計算與判定（下一步）

只做以下範圍：

1. 支持資料 run（`calculation_scope = 'CASH_FLOW_SUPPORT'`）與多批次來源橋接；
2. Manifest 凍結、`fn_manifest_verify`、結果雜湊與 replay；
3. `CashFlowSupportLine` 只原樣承接已接受 fact 的 signed amount 與命中映射；
4. `DATA_PRESENT` 只能由系統依已接受 fact 衍生；
5. 以實際 `DataCoverage` 判定 run-level 粒度是否滿足政策；
6. 完整度的穩定代碼、K1～K4 控制總額與期間級就緒判定；
7. 契約 26 條驗收與指名反證，完成後跑完整一輪。

**尚未完成的兩條界線，不得誤寫成 2a 已完成**：

- `CFS_MAPPING_AMBIGUOUS` 現在只驗**同一版本內**的規則重疊；跨版本由取代鏈決定
  現行版本，本來就不是「映射歧義」。2b 的動態判定只對現行批准版本執行。
- 粒度目前只有建立規則時的**靜態相容性**；「實際 DataCoverage 是否足夠」尚未實作，
  必須由 2b 以封套綁定的那一筆 `data_coverage_id` 判定。

2b 明確不做畫面，也不解鎖期間遷移；先讓計算、凍結、重演與控制總額在 DB 層閉合。

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

1. **REQ-CFS-001**（本刀，2b 未完）——未完成前 **MVP 3 不得關閉**。
2. **G-03：B 基礎（遞延稅）判定**；`AMENDED` 取代鏈亦未完成。
3. **對外輸出／`OutputProfile` 核對**——`ROUNDING_DIFFERENCE` 的真正使用場景。
4. 折算結果就緒的**正式 Guard ID**（須走 CR，BACKLOG 已記）。
