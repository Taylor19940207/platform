# SESSION HANDOFF 2026-08-05　SLICE-M2-02B：PREVIEW CalculationRun 與輸入凍結

切片契約：`docs/slices/SLICE-M2-02B_PREVIEW_CalculationRun與輸入凍結.md`
（首版經走查補六項語意後定稿 `5d0aad1`；實作依定稿與四個護欄，未再改文件）。

## 落地內容

| 層 | 內容 |
|---|---|
| migration 0012 | `calculation_input_manifest`＋`calculation_manifest_entry`（不可變；entry 分開保存 `concurrency_version`／`domain_version_kind/value`）、`calculation_run`（§25.3 四狀態；`run_type` CHECK 僅 `PREVIEW`；partial unique＝一份 Manifest 恰一個原始 run；replay 必須同 Manifest；終態不可修改；COMPLETED 需 result hash、FAILED 需機器代碼＋人可讀原因）、`balance_snapshot_line`（不可變；run×層×科目唯一）、`background_job` 擴充 `CALCULATION_RUN` 型別＋INV-18 主體檢查、RLS 全覆蓋 |
| domain | `calculationRun.ts`：狀態機、`ENGINE_VERSION`／`CANONICALIZATION_VERSION`、`RUN_REASON` 機器代碼表、確定性失敗分流判定 |
| API | `POST /b06/run`：單一交易（同 snapshot）「解析映射集合 → 對同一集合驗 G-02 → 凍結 19 類 entry → Manifest＋Run＋Job＋事件」；冪等三情形（同 key 同內容→原 run；同 key 異內容→409；新 key→新 run）；R2／R3 限定。`POST /b06/replay`：新 run 引用同一 Manifest。`GET /b06`／`/b06/run`：B-06 骨架（PREVIEW・未折算 NO_FX 醒目標示、控制總額、Manifest 摘要、重演） |
| worker | `CALCULATION_RUN` 認領一般化；單一交易：INV-29 完整性驗證（entry hash 逐筆重算比對）→ 從凍結 payload 計算（不回查任何 current 資料）→ 快照 → G-09 三重控制總額 → `result_content_hash`（canonical、排除 run_id／時間戳）→ Run＋Job 終態＋事件。確定性失敗（REPLAY_FAILED 等）＝Run FAILED＋Job COMPLETED；基礎設施故障 RETRY_WAIT 期間 Run 保持 RUNNING，耗盡才同交易雙終態（護欄 3） |

## 四個護欄的落點

1. Manifest／Run 分離：partial unique（`manifest_id WHERE replay_of_run_id IS NULL`）＋
   replay 同 Manifest 觸發器——無隱含一對一。
2. 原始建立＝單一交易同 snapshot；replay＝新 Run＋Job 引用既有 Manifest（不重建）。
3. 終態同交易；可重試期間 Run 保持 RUNNING（驗收含全庫矛盾組合掃描＝0）。
4. 無 DeliveryRecord／ExportJob；`run_type` CHECK 僅 PREVIEW（DB 層測試驗證 OFFICIAL 被拒）。

## 測試

**347/347，EXIT=0**（單元 43、DB 整合 147、端到端 157＝20＋25＋62＋29＋21）。
既有 301 條零退化。新驗收要點：Case-001 調整後集團 TB 與
`expected_adjusted_group_tb_2026-03.csv`（新檔，不覆寫既有預期）逐科目 12/12；
控制總額借貸各 59,000,000；同 key 冪等三情形；映射改版後重演原 run 結果 hash
完全一致、新 run 才採新版本（6401＝31,300,000）；竄改凍結內容（停用觸發器模擬
儲存損壞）→ replay run `FAILED/REPLAY_FAILED` 外顯、原 run 不受影響、無半套輸出。

## 過程中發現

- `server.ts` 重複 import `idempotencyKey`（02A 已引入）——啟動即失敗，移除即可。
  教訓：改大檔前先 `node --check`。

## 明確未做（依切片文件）

OFFICIAL run／交付；02C 證據包；未批准調整入 PREVIEW；折算（MVP 3，輸出已標
`NO_FX`）；比較期間／期間組成／重要性門檻入 manifest；PREVIEW TTL 清理；
SUPERSEDED 失效鏈。**02C 開工前必修**：`mapping_rule` 事件原子化（BACKLOG 既定期限）。

**下一刀**：`SLICE-M2-02C 預覽證據包`（先寫一頁切片與驗收清單）。

## 2026-08-05 關閉章節（逐行審查四缺口＋兩項次要邊界）

上方寫於首輪 347/347 之後；使用者逐行審查發現四個弱化「凍結、不可變、
DB 最後防線」宣稱的缺口，已全部修正（migration 0013），切片自此正式關閉。

| # | 缺口 | 修正 |
|---|---|---|
| ① | entry 只禁 UPDATE/DELETE，Run 建立後仍可 INSERT；worker 未重算 frozen_set_content_hash；hash 只蓋 canonical、計算卻讀 payload——單獨竄改 payload 偵測不到 | Manifest 封存觸發器（有 Run 引用即拒絕新 entry）；worker 補集合層 hash 重算；canonicalization 升 **v2**（content_hash 涵蓋 canonical＋payload::text），驗證端依 manifest 記錄的版本分流（INT-e3） |
| ② | balance_snapshot_line 可向終態 Run 追加新列——result_content_hash 固定後結果仍可變 | 快照 INSERT 觸發器：父 Run 必須 RUNNING；DB 測試改於 RUNNING 階段寫入並新增終態拒絕案例 |
| ③ | 新表只有 RLS（看列自身 tenant_id），無父項歸屬守衛——0008 已防過的 FK＋RLS 缺口在新表重演 | entry↔Manifest、Run↔Manifest／batch／created_by、snapshot↔Run 的租戶／案件／期間一致性觸發器（§24.1A／INV-18） |
| ④ | 建立交易用預設 READ COMMITTED——逐 statement 換 snapshot，「同一 snapshot」只對 TEMP 物化的映射集合成立 | 建立交易改 `BEGIN ISOLATION LEVEL REPEATABLE READ`（TB／映射／調整／CoA 同一快照） |

次要：request_key 唯一改 **(tenant_id, request_key)**（跨租戶 UUID 碰撞不互相阻擋，
API 併發回查同步改約束名）；終態欄位互斥（COMPLETED 無失敗欄位、FAILED 無結果
欄位、RUNNING／建立時不得預填）。

新增測試：DB 整合 147 → 157（封存、終態快照拒絕、三類歸屬、互斥三態、約束改名）；
端到端 21 → 23（**單獨竄改 payload → replay FAILED**、**封存後追加 entry 被 DB 拒絕**）。

**測試 347 → 359（單元 43、DB 整合 157、端到端 159），全綠。**
下一步依序：`mapping_rule` 事件原子化（BACKLOG 既定期限）→ `SLICE-M2-02C 預覽證據包`。

### 0014 收口（關閉審查兩項 P1＋兩小項）——02B 至此正式鎖定

| # | P1 缺口 | 修正 |
|---|---|---|
| ① | 封存／終態 guard 只讀父列不加鎖：外部 INSERT 可在「檢查時尚無 Run／仍 RUNNING、提交時已有 Run／已終態」的間隙穿過，留下未被 result_content_hash 涵蓋的快照 | entry guard 與 Run insert guard 皆 `FOR UPDATE` 鎖 Manifest；snapshot guard `FOR UPDATE` 鎖 Run；worker 計算交易一開始鎖 Run。**兩個雙 session 確定性測試**驗證競爭者阻塞至提交後被拒（封存／不得追加結果） |
| ② | §24.1A 期間歸屬可繞過：只比對「Run 與 Manifest 填同一 period_revision_id」，未驗期間屬於案件、也未驗等於批次宣告期間；Manifest 自身歸屬未驗 | 新增 Manifest INSERT 歸屬守衛（案件×租戶、期間∈案件、created_by∈租戶）；Run insert guard 補「期間∈案件」與「期間＝批次宣告期間」——「兩邊填同一錯誤期間」的構造被 DB 測試證明擋下 |

小項：RUNNING 互斥補 `failure_reason`；canonicalization／hash 演算法**白名單雙層
fail closed**（manifest CHECK 於寫入端＋worker 斷言於讀取端——未知版本不再落入 v2 預設）。

過程中的測試修正：0014 前置種子與 02A 區既有 E99 期間撞主鍵導致 heredoc 靜默中止
（`PSQL_C >/dev/null` 吞掉 stderr 的教訓）——改為沿用既有 PR99、只補 E1 第二期間。

**測試 359 → 367（DB 整合 165），全綠。02B 正式關閉。**
下一步依序：`mapping_rule` 事件原子化 → `SLICE-M2-02C 預覽證據包`。
