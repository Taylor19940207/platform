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
