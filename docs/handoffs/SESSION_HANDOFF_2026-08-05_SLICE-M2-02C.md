# SESSION HANDOFF 2026-08-05　SLICE-M2-02C：預覽證據包

切片契約：`docs/slices/SLICE-M2-02C_預覽證據包.md`
（首版經走查七點修訂、第二輪補實作契約 A～D 後定稿；決策 2「POST 先建
GENERATING Package」經走查確認保留。）

## 落地內容

| 層 | 內容 |
|---|---|
| migration 0015 | `evidence_package`（三態＋身分凍結＋終態互斥＋cutoff 屬於該 run＋重產同 run 守衛＋(tenant, request_key) 唯一）、`evidence_package_index`（不可變；GENERATING 期間才可寫入、終態封存、鎖父列）、`background_job` 擴充 `EVIDENCE_PACKAGE`＋INV-18、**契約 C**：source_dataset／data_coverage／source_document 補 UPDATE/DELETE 禁止與批次歸屬守衛、RLS |
| domain | `evidencePackage.ts`：狀態機、`RENDER_VERSION`、PKG_REASON 機器代碼、`stagingVerdict`（REUSE/CONFLICT）、確定性 object key |
| API | `POST /b07/package`（precheck 同步：R2/R3/R4＋指派、run COMPLETED、G-09 復驗、cutoff 存在；Package(GENERATING)＋Job＋事件同交易；冪等三情形）；`GET /b07`／`/b07/package`（狀態與索引）；`GET /b07/download`（READY 限定、讀已保存位元組並驗 artifact_sha256，不重新渲染）；B-06 加入口 |
| worker | `EVIDENCE_PACKAGE`：交易外讀不可變資料組 10 節（含逐科目追溯、audit timeline ≤ cutoff、三個誠實節）→ 逐節 hash＋package_content_hash（排除 package 身分與時間戳）→ HTML 渲染（**不含 package_id**，artifact 亦確定性）→ staging（write-once；已存在讀回核對 hash，同沿用異即 ARTIFACT_CONFLICT）→ fenced 終態交易：**契約 D 四項驗證**（manifest 逐筆＋set hash、快照重算＝result hash、逐節 hash 內嵌斷言、cutoff 屬於 run）→ 索引＋artifact 登記＋READY＋Job COMPLETED＋事件。確定性失敗＝Package FAILED＋Job COMPLETED；infra 耗盡＝雙終態同交易 |

## 驗收要點（端到端 19 條全綠）

- Case-001 追溯判定 **12/12 科目範圍明示 BALANCE**（AC-AUD-001 逐科目範圍；
  內文無分錄級／憑證級宣稱）；索引 10 節、traceability item_count=12。
- **hash 確定性**：事件增長後第二包 `package_content_hash` 與 `artifact_sha256`
  完全一致（audit cutoff 生效；artifact 不含 package 身分）。
- 契約 B 實測：預置異內容 staging 物件 → `ARTIFACT_CONFLICT`；契約 D 實測：
  保持借貸平衡的快照竄改（G-09 過但重算 hash 不符）→ `UPSTREAM_VERIFY_FAILED`，
  既有包不受影響且下載 hash 驗證通過。
- 冪等三情形、R6 拒絕、非 READY 下載 409、Package/Job 終態矛盾掃描＝0、
  無任何交付紀錄實體。

## 過程中發現

1. artifact 原含 `<title>` 內的 package_id → 同 run 兩包 section hash 全同但
   artifact 位元組不同。改為 run id——身分欄位不入內容的紀律也適用於 artifact。
2. 上游竄改若破壞借貸平衡會先被 G-09 precheck 擋在 409（正確行為）；
   要打到契約 D 必須用「保持平衡的竄改」——測試據此設計。
3. 契約 C 的 UPDATE 測試需先確保目標列存在（0 列 UPDATE 不觸發 trigger）。

## 明確未做（依切片文件）

OFFICIAL 證據包／ExportJob／DeliveryRecord；Excel／壓縮包；附件本體內嵌；
R5／R7 掛載；明示重產 UI；staging 孤兒清理排程；retention（D-26-04）；折算（MVP 3）。

**測試 369 → 414（單元 46、DB 整合 188、端到端 180），全綠。**
**里程碑 2 的 02 系列收官。**下一步：里程碑 2 檢視 → 決定下一刀。
