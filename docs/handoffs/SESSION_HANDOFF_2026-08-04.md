# 2026-08-04 對話與執行交接包

> 用途：在另一台電腦或新的 Codex Session 接續目前專案。
> 本文件是工程交接紀錄，不是正式產品基線；若與正式基線衝突，仍依
> `docs/GOVERNANCE.md` 的權威順序判斷。

## 接續時的必要閱讀順序

1. `SESSION_START.md`
2. `docs/GOVERNANCE.md`
3. `docs/baseline/產品研究與要件手冊_v1.2.md`
4. `docs/baseline/基本設計書_v1.1.md`
5. `README.md`
6. `docs/slices/SLICE-M2-01_科目映射切片.md`
7. 本交接包
8. 現有程式、migration 與三層測試

## 產品目的與不可弱化控制

本產品是「中日跨境財務轉換平台」，讓使用者匯入各法人 TB，經過來源保存、
身分與借貸驗證、科目映射、調整及計算後，產生可重演、可覆核、可追溯的集團
財務輸出。核心操作原則是「正常資料自動複用，使用者只處理例外」。

下列控制不得因 UI、框架、重構或開發便利性而弱化：

- Tenant／Engagement RLS 隔離及跨案件歸屬檢查。
- ImportBatch 七狀態與 `identity_status` 正交語意。
- G-01 借貸平衡與 INV-28 接受硬阻擋。
- 原檔、雜湊、來源事實及 audit event 的不可變性。
- SOD-07 以自然人判定，建立者不得批准自己的實例。
- G-02：任何未映射重要餘額都不得進入覆核或正式輸出。
- 草稿不能被當成已批准版本；已批准版本不可 UPDATE／DELETE，改版只能新增版本。
- PREVIEW 必須清楚標示非正式輸出，不能作為入帳或交付依據。

## 使用者提供的 Mac 權威開發環境驗證

使用者已在本機完成下列基線驗證：

- Docker Desktop 29.6.2；`cbfc-db`、`cbfc-redis`、`cbfc-minio` 正常，DB healthy。
- pnpm 10.28.0，與 `packageManager` 指定一致。
- migration 與 seed 可從零完成。
- `pnpm dev`、首頁與 `/health` 正常。
- Docker Compose restart 後資料卷持久保存。
- macOS bash 3.2 相容問題已修正：`migrate.sh`、`seed.sh`、`db.test.sh`
  的輸出語句由 `$DB` 改成 `${DB}`；不涉及業務規則。

對應提交：

```text
fc4124b 修正 macOS bash 3.2 相容性
1229305 SLICE-M2-01 科目映射切片
8f0507f 映射切片硬化
```

## 已完成里程碑

### 里程碑 1

已完成：

`登入 → EngagementContext → TB 匯入 → 原檔與雜湊 → Worker 驗證 → QUARANTINED／VALIDATED → 接受`

### SLICE-M2-01：科目映射

已完成：

- 去識別化案件 fixture：日本 TB 兩期、日／中科目表、人工映射表、Excel 預期集團 TB。
- 映射建立、另一自然人批准、版本保存、已批准版本不可改寫。
- 自動複用、未映射清單、按金額覆蓋率、G-02 硬阻擋、控制總額勾稽。
- RLS 與目標科目案件歸屬的 API／DB 雙層拒絕及留痕。
- B-04 最小 UI：已映射／未映射／草稿衝突、影響金額、草稿、R4 批准、PREVIEW。
- 2026-03 建立 15 條後，2026-04 零新增操作自動複用。
- Excel 預期集團 TB 逐科目 12/12 一致。
- 新科目 631 是唯一 G-02 例外，補映射後通過。

## `8f0507f` 三項硬化與額外競態修正

1. **SOD 防繞過**
   - migration `0006_mapping_hardening.sql` 將 `created_by` 改為 NOT NULL。
   - 禁止草稿階段改寫 `created_by` 後自批。
   - 修補 SQL 三值邏輯對 NULL 的失效即放行。

2. **精確金額**
   - `cents`／`fmtCents` 改為純字串十進位解析與格式化，不經 JavaScript `Number`。
   - worker G-01 借貸加總使用同一實作。
   - 測試涵蓋 `numeric(20,2)` 邊界 `123456789012345678.99` 與非法輸入拒絕。

3. **報告期生效版本**
   - `currentMappings` 先按報告期間終了日過濾 `effective_from`／`effective_to`，再取最高已批准版本。
   - 2026-03 的來源科目 600 使用 v1 → 6401；2026-04 起使用 v2 → 6602。

4. **上傳／worker 競態**
   - 原檔與 `source_document` 先落地，最後才把批次切到 `UPLOADED`。
   - 使 `UPLOADED` 符合「檔案已落地」語意，避免 worker 搶到 `object_key = null`。

使用者回報目前測試為 **92/92**：單元 12、DB 整合 35、端到端 45。
這個數字是使用者在本機的完整實跑結果；本次 UI 走查沒有再次重跑整套測試。

## 2026-08-04 實際瀏覽器走查

在提交 `8f0507f`、未修改程式的情況下，實際完成：

1. 職員甲上傳一份平衡 TB：

   ```csv
   #legal_entity_code=1234567890123
   account_code,account_name,debit,credit
   777,走查新科目,123.45,0
   4000,売上,0,123.45
   ```

2. 批次狀態依序通過 `UPLOADED → VALIDATED/MATCHED → ACCEPTED`。
3. 在兩科目未映射時按 G-02，得到硬阻擋：2 科目、影響金額 246.90。
4. 甲建立草稿：
   - `4000 → 6001 主营业务收入 v1`
   - `777 → 6602 管理费用 v1`
5. 草稿存在時覆蓋率仍為 0%，證明草稿不會被當成生效映射。
6. 甲嘗試批准，先被 R4 權限矩陣 403 擋下並留痕。
7. 切換資深乙批准兩筆草稿，覆蓋率依序為 50% 與 100%。
8. G-02 通過並記錄 `mapping.review_ready` DomainEvent。
9. PREVIEW 顯示非正式輸出橫幅；來源與集團 TB 借貸均為 123.45，勾稽一致。
10. 稽核軌跡可找到 upload、validated、accepted、G-02 rejected、drafted、
    approve denied、approved、review ready、preview generated。

走查批次：`4f20c801-6ae7-4958-baa7-62f14f9c1b70`。

### 生效日的畫面驗證

- 2026-03 預覽：來源 600 → 6401，金額 21,700,000。
- 2026-04 預覽：來源 600、631 → 6602，合計 1,850,000。

這證明 UI 預覽使用的是按報告期間解析後的生效版本，而不是單純取全域最高版本。

## 走查時發現但不推翻切片結論的項目

開始走查時，8080 被一個由 PID 1 收養的舊版孤立 API 程序占用，且沒有 worker；
停止舊程序並以目前提交重新執行 `pnpm dev` 後，API 與 worker 均正常。

資料庫中另有一筆既存批次停在 `VALIDATING / NOT_CHECKED`。目前 worker 認領流程是
先把 `UPLOADED` 改為 `VALIDATING`，若程序在認領後、完成前崩潰，沒有 lease、heartbeat
或逾時重領機制，該批次可能永久卡住。這不推翻 B-04 映射切片，但應加入上線前
可靠性 backlog，至少需要：

- 認領租約或 `validation_started_at`。
- 逾時重領／隔離策略。
- 重啟恢復整合測試。
- 管理者可見的卡住批次診斷與安全重試方式。

## 下一個最小工作範圍

下一刀依既定順序：

`Adjustment 草稿 → 雙人批准 → PREVIEW CalculationRun → CalculationInputManifest 凍結 → 證據包`

先建立一頁切片文件與驗收清單，不先擴寫大型規格，也不修改兩份正式基線。
切片至少要凍結以下語意：

1. Adjustment 版本化、不可改寫、建立者不得批准自己的調整。
2. 每次計算新增 CalculationRun；不得覆寫既有結果。
3. PREVIEW 永遠不能冒充正式輸出。
4. CalculationInputManifest 記錄並凍結：
   - ImportBatch 與來源檔案雜湊；
   - 當時解析出的映射 rule ID／version／生效區間；
   - Adjustment version；
   - 科目表及計算／控制規則版本；
   - 執行者、時間與輸出雜湊。
5. 證據包能以單一 CalculationRun 為根，收集輸入清單、控制結果、勾稽、稽核事件及輸出。

範圍外想法繼續記入 `docs/BACKLOG.md`；只有符合 `docs/GOVERNANCE.md` 四種例外時才修改基線。

## 新 Session 的第一個動作

先執行只讀確認：

```bash
git status --short
git log -3 --oneline
docker compose --env-file .env.local ps
pnpm test
```

若只需延續文件設計，可先不重跑測試；但開始改 Adjustment／CalculationRun 程式前，
應確認 HEAD、migration 6 份及 92/92 基線仍成立。

外部完整版開發文件位於本機：`/Users/taylor/Documents/交付 3`。使用者已確認另一台
電腦也有該資料夾，因此不納入 repo；它不得取代 repo 內兩份正式 Markdown 基線。
