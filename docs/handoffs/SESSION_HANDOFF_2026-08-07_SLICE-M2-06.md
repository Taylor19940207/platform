# SESSION HANDOFF 2026-08-07　SLICE-M2-06 多基礎與四類規則最小資料模型

契約：`docs/slices/SLICE-M2-06_多基礎與四類規則最小模型.md`（兩輪走查裁決 A–H 已收入）
實作：`packages/database/migrations/0023_multi_basis_and_rules.sql`（單一 migration）
測試：**712/712** 連續兩輪全綠（單元 58／DB 整合 357／端到端 297），較 594 增 118 條。

## 這一刀關掉了什麼

里程碑 2 離開盤點的 **REQ-BAS-001／REQ-RUL-001** 阻擋項。
`adjustment.basis CHECK ('GROUP_GAAP')` 這個硬編佔位已 DROP，
換成 `basis_from_id`／`basis_to_id`／`posting_layer_id`／`rule_version_id`。

新實體：`book_basis`、`posting_layer`、`basis_source_policy_version`、
`basis_composition_version` ＋ `constitutive_layer_item`、
`basis_reconciliation` ＋ `reconciliation_line` ＋ `reconciliation_difference`、
`tax_basis_observation`、`rule` ＋ `rule_version`。

## 三條實作原則（0023 檔頭，走查請優先查這三條）

1. **代碼不驅動約束**。全檔沒有 `code = 'A'/'B'/'C'` 的判斷（種子與回填的兩行以
   `-- seed-data` 標記並被測試掃描排除）。約束一律由 `source_mode`／`scope_type`／
   `rule_type`／`permits_group_layer` 驅動——這才是「新增第四基礎零 DDL」成立的原因，
   DB 測試以純 INSERT 建立 D／IFRS 基礎逐條驗證。
2. **構成與調節分屬不同模型**（§26.1 L1074）。`BasisComposition` 用於計算、
   `BasisReconciliation` 用於解釋，不共用實體、不做單一實體的角色 enum。
3. **守衛未實作 ≠ 守衛通過**。fail closed 一律回穩定機器前綴：
   `AMENDED_NOT_IMPLEMENTED:`（取代鏈留待更正申告刀）、
   `INV24_THRESHOLD_NOT_IMPLEMENTED:`（無 MaterialityThreshold → 尾差不得自動結案）、
   `AUTO_POST_NOT_IMPLEMENTED:`、`RECON_RUN_PREDATES_BASIS_MODEL:`、
   `BASIS_COMPOSITION_NOT_APPROVED`。G-03 **不因 B 基礎存在而解除**。

## 幾個容易被誤讀的設計決定

| 決定 | 為什麼 |
|---|---|
| `JournalEntry` 只帶 `posting_layer_id`，**不帶 `basis_id`** | 事實屬於「層」，「哪些基礎包含它」由 `ConstitutiveLayerItem` 回答。釘死 `basis_id` 會在新增基礎後產生兩個競爭的加總鍵 |
| INV-04 用 `book_basis.permits_group_layer`，不用 composition 反查 | 反查是循環論證：GROUP 層被誤加進 A 之後，反查會說 A「允許 GROUP」。另在構成模型入口再堵一次 |
| INV-02 的完成點在 `FINALIZE`，不在每一列 | 逐列即時平衡做不到（第一列必然不平）。`fn_reconciliation_finalize` 取 `FOR UPDATE`，子列守衛取 `FOR SHARE`，消除「驗完平衡後才插入」的競態 |
| 新舊快照界線由 **manifest 是否含 `BASIS_COMPOSITION`** 判定 | 「新 run 一律填層」若只是 worker 約定，忘了填就是靜默降級。同一判準同時決定「這是新 run」與「因此必須有層」；歷史 run 一律不回寫，既有 `result_content_hash` 與證據包 hash 全數維持有效 |
| `fn_basis_account_balance` 讀 manifest 凍結的組成版本，不讀「目前生效」 | 否則組成 v2 落地後重驗同一筆調節會得到不同結論（INV-21／INV-29）。0023 之前的 run 因此 fail closed，不得把 `SOURCE_TB` 靜默當成 `LOCAL_BOOK` |
| 稅務確認角色由 `BasisSourcePolicyVersion.confirmation_role` 指定 | `confirmed_by IS NOT NULL` 不等於「經指定稅務專業角色確認」。DB 驗有效未撤銷的角色指派，並**無條件覆寫** `confirmed_role` 快照——不硬編 R1，換法域換政策版本即可 |
| `PLATFORM` 規則零列 | `drafted_by` NOT NULL 而平台發布身分尚不存在。RLS 的 `WITH CHECK (tenant_id = current_tenant())` 使 app_runtime 寫不出平台列——機制上唯讀，不靠自律 |
| `LOCAL_TAX_ADJ` 不在任何組成中 | A→B 是調節橋樑不是構成關係（B 權威匯入）。刻意留白，不是漏列 |

## 實作期間修掉的兩個「以錯誤理由通過」風險

- `trg_adjustment_wiring` 刻意命名排在 `trg_adjustment_tenant` **之後**（PostgreSQL 依名稱順序觸發）：
  否則跨租戶插入會先撞上「基礎不屬於本案件」，讓 INV-18 的負面測試以錯誤理由通過。
- `fn_tax_observation_guard` 把 UPDATE 的不可變性檢查移到角色檢查**之前**：
  否則「改寫確認人」會先被角色檢查擋下，身分凍結那條規則其實從未被驗證。

## 後續驗收（不在本刀）

- `MaterialityThreshold` → 解除尾差自動結案 fail closed，補「單筆低於門檻但累積已重大」測試。
- 更正申告刀 → `AMENDED` 取代鏈＋`ImpactAssessment`；屆時唯一索引須由「全部列」收窄為「僅現行列」。
- 差異結案追蹤 → 以獨立 append-only 紀錄擴充，**不改寫已 FINALIZED 的會計結果**。
- 平台控制面 → `PLATFORM` 規則才有合法作者。
- 規則引擎 → `required_granularity` 與 `DataCoverage.granularity` 的 INV-23 比對才生效。
- 折算刀 → `TRANSLATION_ADJUSTMENT` 的寫入路徑與逐筆 `rule_type` 歸屬、INV-20。

## 下一刀

**自動保存、儲存狀態與 Session 恢復**（NFR-UX-001／NFR-INT-002）。
完成後里程碑 2 離開盤點的阻擋清單即清空，可重跑
`docs/reviews/MILESTONE-2_EXIT_REVIEW.md`，之後轉向可操作產品。

`cbfc_dev` 已還原種子。跑 `pnpm test` 前務必先停 `pnpm dev`。
