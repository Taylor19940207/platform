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

## 2026-08-05 收口章節（逐行審查四項 P1＋一項 P2）——02C 正式關閉

| # | 缺口 | 修正 |
|---|---|---|
| ① | 來源列不可修改但「來源集合」未封存：批次驗證完成後仍可新增 source_document／coverage／dataset——同 run 再產包得到不同內容 | migration **0016**：封存點＝批次離開 DRAFT／UPLOADED／VALIDATING（鎖批次列，0014 並發紀律同式）；「同 run＋cutoff＋render → 同 hash」自此有結構性保證 |
| ② | 逐科目追溯實為「第一筆 coverage 套全部科目」；dataset join 漏 granularity 條件 | domain `resolveTraceability`：輸出科目 → 映射來源 → coverage（**精確 scope 優先於 wildcard、弱鏈決定等級、無來源＝UNKNOWN 誠實標示**）；混合 scope／granularity 單元測試；join 補 granularity |
| ③ | 逐節 hash 未涵蓋名稱、法源、附件、判斷理由等實際顯示內容——canonical 與 HTML 兩套內容可漂移 | buildPackage 重構：**同一份 canonical rows 同時產生 hash 與 HTML**（渲染器只吃 rows）；端到端漂移測試：改法源一欄 → adjustment 節 hash 與 package hash 均改變 |
| ④ | GENERATING／FAILED 互斥漏 MIME、byte size、completed_at 等欄位；READY 未驗固定章節與 aggregate | 0016 補全三態欄位互斥；READY 於 **DB 重算 aggregate**（`section|hash` 依 COLLATE "C" 聚合）並驗固定 10 節——直接 SQL 無法造出「不完整但看似 READY」的包 |
| P2 | `audit_event_id`（bigint）經 `Number()`——超出 JS 安全整數會錯指 cutoff | API 與 worker 一律十進位字串傳遞＋`::bigint` |

**測試 414 → 420（單元 48、DB 整合 191、端到端 181），全綠。02C 正式關閉。**

## 2026-08-05 final hardening（0017；第二輪逐行審查四項 P1＋一項 P2）

| # | 缺口 | 修正 |
|---|---|---|
| ① | canonical／HTML 大改但 `render_version` 仍 html-1——跨部署重產同 run 可得不同 hash | 升 **html-2**（canonical JSON＋完整度欄＋凍結人名——canonical 規則改變＝render 升版） |
| ② | coverage 只按 batch_id 查詢，多版本會混入；guard 未限定版本 | worker 以 **Manifest SOURCE_TB entry 的 batch_version** 定位；0017 guard：Dataset／Coverage 版本必須等於批次當前版本 |
| ③ | `\|`＋換行串接可碰撞（`["a\|b","c"]`＝`["a","b\|c"]`） | canonical 改 **JSON 序列化**（domain `sectionCanonical`，worker 共用）；注入碰撞單元測試 |
| ④ | 映射／調整人名即時讀 `app_user.display_name`——改名即 hash 漂移 | Manifest 建立時凍結 **actor ID＋當時顯示名稱＋時間** 進 entry payload；worker 只讀凍結快照，app_user JOIN 移除；端到端證明改名後重產 hash 不漂移 |
| P2 | `resolveTraceability` 忽略 completeness——PARTIAL／UNKNOWN 照樣顯示高等級 | 規則寫死：**UNKNOWN 完整度 → 等級降 UNKNOWN；PARTIAL 保級但併列呈現**；追溯列加「完整度」欄；匯入 worker 對通過 G-01 的整份 TB 記 `COMPLETE`（餘額級完整性已驗證） |

過程教訓：python 字串替換未命中時靜默跳過——`data_coverage` 的 COMPLETE 改寫首輪沒生效，
由端到端 12/12 BALANCE 轉紅抓回。**改字串前先 grep 錨點。**

**測試 420 → 423（單元 50、端到端 182），全綠。02C 至此正式關閉。**
下一個 session 從「里程碑 2 離開條件盤點」開始。

開始盤點時一併閱讀 `docs/FUTURE_DISCUSSIONS.md`，但不要把觀察中議題直接擴成新範圍。
目前 `DISC-001` 記錄「控制強度與事務所實用性的平衡」：既定計畫不變；待職員與税理士
能走通上傳至正式交付的完整流程後，以實際完成時間、角色切換、阻擋與恢復情況重開討論。

## 2026-08-05 第三輪收口（0018；三項 P1＋一項 P2）

| # | 缺口 | 修正 |
|---|---|---|
| ① | G-01 通過即記 `COMPLETE`——平衡只證明「收到的資料內部平衡」，不證明「應有資料全部收到」；證據包過度宣稱 | 撤銷推定：完整度只接受**提供者顯式聲明**（檔內 `#completeness=COMPLETE/PARTIAL`，聲明受 file hash 涵蓋；未聲明＝UNKNOWN）。Case-001 fixtures 加入合成聲明——不用平衡替代 |
| ② | render 升版但 worker 不分流——GENERATING 的 html-1 工作會被以新版內容產生卻登記舊版 | **renderer map fail closed**：worker 只接受明確支援版本（現為 html-3）；未知／停止支援 → `UNSUPPORTED_RENDER_VERSION` FAILED。端到端：html-1 進行中工作在新 worker 下 FAILED，不冒充 |
| ③ | 來源節仍讀 current import_batch、缺 SOURCE_TB entry 時回退 current；`fn_import_batch_guard` 同狀態放行使 ACCEPTED 批次身分欄可被改寫 | SOURCE_TB payload 凍結 `batch_id＋batch_version＋file_sha256＋lines`；worker 缺／重複 entry 或缺 meta 一律 fail closed 不回退；來源節完全讀 Manifest；migration **0018**：批次離開 DRAFT 後來源身分欄位凍結（計算讀取端相容舊 array payload） |
| P2 | HTML 只顯示姓名，同名者不可辨 | actor 一律「姓名〔穩定 ID〕」（皆出自凍結 payload）——輸出改變依規則升 **html-3** |

連帶：02B 的 payload 竄改測試路徑隨新 payload 形狀改為 `{lines,0,debit}`
（該測試轉綠也反向驗證了 SOURCE_TB meta 結構已生效）。

**測試 423 → 427（DB 192、端到端 185），全綠。**
