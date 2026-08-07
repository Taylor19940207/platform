# SLICE-M2-06　多基礎與四類規則最小資料模型（§14／§26.5）

> 狀態：**定稿待實作**。已收入兩輪走查裁決（§5 A–D、§5A E–H），**本文件為最後一輪走查**。
> 後續實作細節在程式與測試中解決；只有跨租戶、會計口徑、不可變性或資料遺失問題才停下來。

**範圍**：把「三基礎、兩橋樑、四類規則」從硬編佔位變成**真正的資料模型**——
`BookBasis`、`PostingLayer`、構成模型與調節模型落表，四類 `rule_type` 分離，
既有 `Adjustment`／`JournalEntry`／`CalculationRun`／`Manifest` 接上基礎與分層。
**不做規則引擎、不做計算。**

**基線對應**：手冊 §14（L622-634 三基礎兩橋樑四類規則）、§15 多基礎資料模型（L652）、
REQ-BAS-001／REQ-RUL-001（P0，L559-561）、AC-BAS-001（L846）、
設計書 §26.1 建模原則（L1074）、§26.3 兩個控制面（L1103）、§26.5 C 基礎與分層（L1140-1200）、
§26.7 D 稅務（L1258-1282 GB-02 落點）、§26.8 F 規則與調整（L1284-）、
§24.4 GB-02／GB-03／GB-05、§26.12 INV-01／02／03／04／05／11／18／21／23／24。

核心價值驗證：**新增第四種基礎（例如 IFRS）時，不需要改動任何核心實體結構，
也不需要重建任何歷史事實。** 若這一條不成立，本刀就沒有做到 AC-BAS-001。

---

## 0　用語對照（本刀採用基線名稱）

走查指示中的三個名詞，基線有**刻意不同**的落法。依 `docs/GOVERNANCE.md` 權威順序
（手冊 v1.2 ＞ 設計書 v1.1 ＞ 切片），本刀一律採基線名稱，並在此標明對應關係，
避免日後查基線查不到。

| 指示用語 | 本刀採用 | 理由（基線出處） |
|---|---|---|
| `BasisComposition` 以 `CONSTITUTIVE／RECONCILING` **分流** | **兩個模型，不是一個 enum**：`BasisComposition`＋`ConstitutiveLayerItem`（構成）／ `BasisReconciliation`＋`ReconciliationLine`＋`ReconciliationDifference`（調節） | §26.1 L1074 明文：「構成與調節分屬不同模型……兩者數學性質相反，**不共用實體**——否則每個查詢都得記得排除另一種，遲早有人漏掉」。做成同一張表的角色欄，等於把基線點名的錯誤實作出來 |
| `UnexplainedDifference` | **`ReconciliationDifference`**，狀態由 `reason_class` ＋ `resolution_status` 承載 | §26.5 L1165：原命名的缺陷是「一旦原因確認為尾差，它就不再是 unexplained，但實體名稱已把狀態寫死」。「還有多少未解釋差異」一律查 `resolution_status = OPEN` |
| 「B 基礎只由 `TaxBasisObservation` 權威匯入，不得用 A 推算，也不得建立 `BasisComposition`」 | 語意完全採用，但**約束由 `source_mode = DIRECT_AUTHORITATIVE_IMPORT` 驅動，不寫 `code = 'B'`** | §26.7 L1275-1281：「約束寫成 `book_basis_code = B → 禁止 Composition` 是把資料當成程式邏輯」。改由 `source_mode` 驅動後，日後增加另一個直接匯入的稅務或監管口徑不需改動任何約束——**這正是「新增第四種基礎不重建核心實體」能成立的原因** |

**「版本化」的落點**：構成模型版本化（`BasisCompositionVersion`，見 3.4）；
`BasisReconciliation` 是某次 `CalculationRun` 的**結果**，不版本化——
重算＝新 reconciliation ／新 run（§25.3 run 不可修改）。

---

## 1　現況缺陷（實查）

| # | 事實 | 影響 |
|---|---|---|
| 1 | `adjustment.basis text NOT NULL DEFAULT 'GROUP_GAAP' CHECK (basis IN ('GROUP_GAAP'))`（0007:29） | 四類規則被硬編成一類。**AC-BAS-001「新增基礎不需重建核心實體」目前不成立**——加一個基礎要改 CHECK、改欄位語意 |
| 2 | 無 `book_basis`／`posting_layer` 表，全庫無 `basis_id`／`layer_id` 外鍵 | §14 的三基礎兩橋樑在資料層不存在 |
| 3 | 無 `Rule`／`RuleVersion` 實體 | `rule_type` 無處保存，四類規則無法「不可混記」 |
| 4 | `balance_snapshot_line.posting_layer CHECK ('SOURCE_TB','ADJUSTMENT')`（0012:156） | 兩個值是 02B 的計算輸出分層權宜命名，**不是 §26.5 的 PostingLayer 代碼** |
| 5 | `journal_entry`／`journal_line` 不帶分層 | 物化分錄無法回答「這筆記在哪一層」，INV-03／INV-04 無判定依據 |
| 6 | 無 `BasisComposition`／`BasisReconciliation`／`ReconciliationDifference` | INV-01／INV-02 無對應物；差異無處保存＝**只能靜默吸收** |
| 7 | 無 `TaxBasisObservation`、無 `BasisSourcePolicyVersion` | GB-02「B 不得由平台推算」目前靠「沒有 B」成立，不是靠控制成立 |
| 8 | `reporting_unit.unit_scope` 已有 `LEGAL_ENTITY／CONSOLIDATION_GROUP`（0001:49）；`period_revision → reporting_period.reporting_unit_id` 可解析（0002:18） | INV-03 的**判定依據已存在**，本刀可直接建守衛 |
| 9 | `data_coverage.granularity` 已凍結為 `BALANCE／JOURNAL／SUBLEDGER／DOCUMENT`（0003:218） | 規則的 `required_granularity` 必須沿用同一組值，**不得另造** |

---

## 2　本刀實作邊界

```
  建立主檔與分層               建立兩個模型                    接上既有事實
  ────────────────             ─────────────────               ─────────────────
  BookBasis     A B C          BasisCompositionVersion         adjustment
   （案件範圍）                 └ ConstitutiveLayerItem          basis_from_id/basis_to_id
  PostingLayer  6 值                                            posting_layer_id
   （平台參照）                BasisReconciliation              rule_version_id
  Rule/RuleVersion 4 類         ├ ReconciliationLine
                                └ ReconciliationDifference     journal_entry
  BasisSourcePolicyVersion                                      posting_layer_id（僅此，無 basis_id）
  TaxBasisObservation
   （B 的唯一權威來源）                                         balance_snapshot_line
                                                                 posting_layer_id（新 run 必填）
                                                               manifest
                                                                 BASIS_COMPOSITION 凍結
```

**做**：主檔、分層、四類規則的**結構與約束**；INV-01／02／03／04／05／21 的 DB 守衛；
既有實體的最小接線；以既有 PREVIEW run 的快照逐科目驗證 INV-01
（`C = LOCAL_BOOK + GROUP_GAAP_ADJ`，Case-001 12/12）。

**不做**：任何規則的自動執行、任何金額的自動計算。
`BasisReconciliation` 本刀**只建立結構、生命週期與 INV-02 守衛**；
調節結果由**人工／測試建立並綁定既有 `CalculationRun`**——
若改由 worker 自動產生，那是新增計算邏輯，與本刀邊界矛盾。

---

## 3　凍結的設計語意

### 3.1　BookBasis：案件範圍的可擴充主檔，不做三張分表

```
book_basis
  basis_id            uuid PK
  tenant_id           uuid NOT NULL → tenant           -- RLS
  engagement_id       uuid NOT NULL → client_engagement
  code                text          -- 'A' | 'B' | 'C' | 未來任意（案件內唯一）
  jurisdiction        text          -- JP / CN / …
  framework           text          -- JP_GAAP / JP_TAX / CN_CAS / IFRS …
  source_mode         text NOT NULL CHECK (source_mode IN
                        ('COMPOSED','DIRECT_AUTHORITATIVE_IMPORT'))
  basis_source_policy_version_id  uuid → basis_source_policy_version
                                        -- DIRECT_AUTHORITATIVE_IMPORT 時必填
  permits_group_layer boolean NOT NULL DEFAULT false   -- INV-04 的獨立政策判定（見 3.3）
  UNIQUE (engagement_id, code)
```

**基礎帶 `tenant_id ＋ engagement_id` 並受 RLS。** A／B／C 是**客戶案件內的口徑**：
`framework`、集團政策、`basis_source_policy_version` 都可能因客戶而異。
每個租戶各自建立自己的基礎是正確的資料歸屬，也不影響「新增基礎零 DDL」——
新增仍然只是 INSERT。（`PostingLayer` 相反，見 3.2。）

**不做三張分表**（無 `a_balance`／`b_balance`／`c_balance`）：基礎是**資料**，
不是結構。餘額一律經 `basis_id` 區分。§15 L654 的理由照抄：
「若第一版做成單軌，日後加入第二軌會迫使資產歷史與期初全部重建。」

**`code` 不得驅動任何約束。** 所有約束一律由 `source_mode`／`scope_type`／`rule_type`／
`permits_group_layer` 這類**語意欄位**驅動。走查請特別檢查：
全部 migration 內不得出現 `code = 'B'` 之類的判斷。

MVP 每案件凍結設定（§26.7 L1281）：

| code | source_mode | permits_group_layer |
|---|---|---|
| A | COMPOSED | false |
| B | DIRECT_AUTHORITATIVE_IMPORT | false |
| C | COMPOSED | **true** |

### 3.2　PostingLayer：平台級參照主檔，與 BookBasis 分離的正交軸

```
posting_layer                          -- 平台級參照主檔：無 tenant_id、無 engagement_id
  layer_id     uuid PK
  code         text UNIQUE  -- LOCAL_BOOK / LOCAL_TAX_ADJ / GROUP_GAAP_ADJ
                            -- DEFERRED_TAX / CONSOLIDATION / TRANSLATION_ADJUSTMENT
  scope_type   text NOT NULL CHECK (scope_type IN ('ENTITY','GROUP'))
  rule_type    text          CHECK (rule_type IN
                 ('LOCAL_TAX','GROUP_GAAP','DEFERRED_TAX','CONSOLIDATION'))
```

**層是平台語彙，不是客戶口徑**：`LOCAL_BOOK`／`CONSOLIDATION` 的語意不因客戶而異，
且 `scope_type` 與 `rule_type` 的對應是 §26.5 的結構事實。因此不帶租戶、
`app_runtime` **只有 SELECT**，種子由 migration 建立。

**與 BookBasis 分離的理由**：同一個基礎由多個分層構成，同一個分層也可能參與多個基礎的構成。
把層併進基礎欄位，等於預先假設「一基礎一層」，加第四個基礎時必然重建。
這是與 `identity_status` 相同的**正交軸**原則。

`scope_type` 凍結對應（§26.5 L1143-1144）：

| layer | scope_type | rule_type |
|---|---|---|
| `LOCAL_BOOK` | ENTITY | —（來源帳，不屬四類規則） |
| `LOCAL_TAX_ADJ` | ENTITY | LOCAL_TAX |
| `GROUP_GAAP_ADJ` | ENTITY | GROUP_GAAP |
| `DEFERRED_TAX` | ENTITY | DEFERRED_TAX |
| `CONSOLIDATION` | **GROUP** | CONSOLIDATION |
| `TRANSLATION_ADJUSTMENT` | ENTITY | **NULL**（見下） |

**`TRANSLATION_ADJUSTMENT` 的 `rule_type` 種為 NULL，不是任選一個。**
基線 §26.5 L1223 的表述是「帶 `rule_type`（GROUP_GAAP **或** CONSOLIDATION）」——
那是**逐筆分錄**的歸屬，隨 `translation_run_id` 於折算時決定，不是層的固定屬性。
單一 CHECK 欄位放不下「或」；種一個值等於替折算刀預先做決定。
因此該層 `rule_type IS NULL`，逐筆歸屬由折算刀（MVP 3）落在分錄上。

連帶：`rule_type` 一致性守衛（3.6）遇到 `posting_layer.rule_type IS NULL` 時
**顯式拒絕**（`LAYER_RULE_TYPE_UNSET:`），不是默默通過——
本刀該層無任何合法寫入路徑，因此「引用它」只可能是錯誤。
**不得依賴 `NULL = x → NULL` 的默默通過**，那正是 0006／0007 點名的繞過型態。

### 3.3　INV-03／INV-04：兩個獨立的守衛

```
INV-03  ENTITY layer 只能寫入 unit_scope = 'LEGAL_ENTITY' 的單位
        GROUP  layer 只能寫入 unit_scope = 'CONSOLIDATION_GROUP'
        單位經 period_revision → reporting_period.reporting_unit_id 解析
        違反 → INV03_SCOPE_MISMATCH:

INV-04  posting_layer.scope_type = 'GROUP' 的調整，
        其 basis_to_id 所指基礎必須 permits_group_layer = true
        違反 → INV04_GROUP_ADJ_INTO_LOCAL_BASIS:
```

兩者掛在 `adjustment` 的寫入與狀態遷移守衛上，並於物化時由 `journal_entry` 繼承
（`posting_layer_id` 自 `adjustment` 帶入且不可變），**不重新判定、也不放寬**。

> **為什麼用 `permits_group_layer` 而不是 composition 反查**（走查裁決 C）：
> composition 反查是**循環論證**——把 GROUP layer 誤加進 A 的 composition 之後，
> 反查反而會說 A「允許 GROUP」，於是守衛替錯誤配置背書。
> 它能描述現況，不能阻止錯誤配置。**顯式語意欄位才是獨立的政策判定**，
> 且仍然滿足「代碼不驅動約束」。
>
> 連帶約束：`permits_group_layer = false` 的基礎，其 `BasisCompositionVersion`
> **不得納入任何 `scope_type = 'GROUP'` 的層**（`INV04_GROUP_LAYER_IN_LOCAL_BASIS:`）。
> 這是把上述誤配置直接堵在構成模型入口。

### 3.4　構成模型：BasisCompositionVersion（版本化）

```
basis_composition_version
  basis_composition_version_id  uuid PK          -- 子表與 manifest 引用的唯一 ID
  composition_series_id         uuid NOT NULL    -- 同一組成政策的版本序列
  version_no                    int  NOT NULL
  tenant_id / engagement_id     NOT NULL         -- RLS
  basis_id                      uuid NOT NULL → book_basis
  effective_from / effective_to date
  status        text NOT NULL CHECK (status IN ('DRAFT','APPROVED','RETIRED'))
  approved_by   uuid → app_user        -- APPROVED 時必填
  approved_at   timestamptz
  approval_role text                   -- R4 批准角色快照（不得由現行指派推導，INV-11）
  UNIQUE (composition_series_id, version_no)

constitutive_layer_item                -- 僅此實體參與基礎餘額加總
  basis_composition_version_id  uuid NOT NULL → basis_composition_version
  layer_id                      uuid NOT NULL → posting_layer
  sign                          smallint NOT NULL CHECK (sign IN (1, -1))
  include_condition             jsonb
  PRIMARY KEY (basis_composition_version_id, layer_id)
```

**主鍵形狀說明**：`basis_composition_version_id` 是**版本列自己的代理鍵**，
子表與 `CalculationInputManifest` 一律引用它；
`(composition_series_id, version_no)` 是政策序列的自然唯一鍵。
兩者缺一都會出現「子表引用一個不存在的單一 ID」——首版的缺陷，本版修正。

凍結語意：

| # | 語意 | 依據 |
|---|---|---|
| a | **只有 `ConstitutiveLayerItem` 參與基礎餘額加總。** 任何「這一層要不要算進去」的問題，答案只在這張表 | §26.5 L1157 |
| b | INV-01：`sum(ConstitutiveLayerItem 對應事實) = 該 basis 的餘額`（每 unit × period_revision × basis × account） | INV-01 |
| c | `source_mode = DIRECT_AUTHORITATIVE_IMPORT` 的基礎**不得存在任何 `BasisCompositionVersion`**，且必須有 `basis_source_policy_version_id` | INV-05／GB-02 |
| d | **生效日不得自動影響已 LOCKED 的 `PeriodRevision`。** 追溯變更須先走重開／重編決策並重新批准 | INV-21 |
| e | 版本必須進 `CalculationInputManifest` 凍結，`object_id = basis_composition_version_id` | INV-17／INV-21／INV-29 |
| f | `permits_group_layer = false` 的基礎不得納入 GROUP scope 的層（3.3） | INV-04 |
| g | `APPROVED` 後 header 與 item 皆不可變；改政策＝**新 `version_no`**，舊版本保留可重演 | INV-21 |

MVP 凍結組成：

```
A = LOCAL_BOOK(+1)
C = LOCAL_BOOK(+1) + GROUP_GAAP_ADJ(+1)
B = 無 composition（DIRECT_AUTHORITATIVE_IMPORT）
```

**`LOCAL_TAX_ADJ` 不出現在任何 composition，這是刻意的，不是漏列。**
A→B 是**調節橋樑**不是構成關係：B 由權威匯入（3.6），不由 A 加上稅務調整層算出來——
那正是 GB-02 禁止的「平台推算 B」。因此 `LOCAL_TAX` 調整的去處是
`ReconciliationLine`（解釋 A 與 B 之差），不是 `ConstitutiveLayerItem`。
`DEFERRED_TAX` 與 `CONSOLIDATION` 兩層同理，本刀無構成用途。

d 的落法：`basis_composition_version` 的 UPDATE 守衛拒絕修改已被任一 LOCKED revision 的
manifest 引用的版本；新政策＝新 `version_no`。**不得原地改寫。**

### 3.5　BasisSourcePolicyVersion（最小版）

`book_basis.basis_source_policy_version_id` 若只是一個 uuid 字串，
INV-05 就沒有參照完整性可言——「必須有權威來源政策」會退化成「必須填一個 UUID」。
因此本刀落最小實體：

```
basis_source_policy_version
  basis_source_policy_version_id  uuid PK
  policy_series_id                uuid NOT NULL
  version_no                      int  NOT NULL
  tenant_id / engagement_id       NOT NULL          -- RLS：案件歸屬
  source_kind    text NOT NULL CHECK (source_kind IN
                   ('TAX_RETURN','TAX_WORKPAPER','REGULATORY_FILING','OTHER_AUTHORITATIVE'))
  confirmation_role  role_code NOT NULL -- 「指定稅務專業角色」的權威定義（見 3.6）
  description    text NOT NULL          -- 權威來源與取得方式
  effective_from / effective_to  date
  status         text NOT NULL CHECK (status IN ('DRAFT','APPROVED','RETIRED'))
  approved_by    uuid → app_user        -- APPROVED 時必填
  approved_at    timestamptz
  approval_role  text                   -- 批准角色快照（INV-11 同理，不由現行指派推導）
  UNIQUE (policy_series_id, version_no)
```

約束：

- `book_basis.source_mode = 'DIRECT_AUTHORITATIVE_IMPORT'` → `basis_source_policy_version_id`
  **NOT NULL**，且所指版本 `status = 'APPROVED'`、同 tenant 同 engagement
  （`BASIS_SOURCE_POLICY_REQUIRED:`／`BASIS_SOURCE_POLICY_NOT_APPROVED:`）。
- `source_mode = 'COMPOSED'` → 該欄必須為 NULL（避免出現「既組成又直接匯入」的混合語意）。
- `APPROVED` 後不可變；改政策＝新 `version_no`。
- `confirmation_role` 為 `role_code`（0001 的既有 ENUM），**不硬編 R1**——
  哪一個角色算「指定稅務專業角色」由**政策版本**決定，日後客戶或法域不同時換政策版本即可，
  不改任何約束。

**本刀不做**：政策文件附件、法源登錄簿連結、政策的覆核流程 UI。

### 3.6　B 基礎：權威匯入，平台不得推算

```
tax_basis_observation                  -- 時點存量（§26.7：不是年度數字按月分攤）
  observation_id          uuid PK
  tenant_id / engagement_id / reporting_unit_id  NOT NULL
  as_of_date              date NOT NULL
  book_basis_id           uuid NOT NULL → book_basis
                            -- 必為 source_mode = DIRECT_AUTHORITATIVE_IMPORT
  account_id              uuid → account            -- 見下：MISSING 時可空
  amount                  numeric(20,2)             -- 見下：MISSING 時可空
  evidence_status         text NOT NULL CHECK (evidence_status IN
                            ('PROVISIONAL','FILED','AMENDED','MISSING'))
  source_dataset_id       uuid → source_dataset     -- 見下：MISSING 時可空
  confirmed_by            uuid → app_user           -- 見下：非 MISSING 時必填
  confirmed_role          role_code                 -- **由 DB 寫入的快照**，不接受呼叫端宣告
  confirmed_at            timestamptz
  missing_reason          text                      -- MISSING 時必填
  owner_id                uuid → app_user           -- MISSING 時必填（負責人）
  due_date                date                      -- MISSING 時必填（截止日）

-- 唯一性約束全部列；NULL account_id 視為相同值
CREATE UNIQUE INDEX tax_basis_observation_uq
  ON tax_basis_observation (book_basis_id, reporting_unit_id, as_of_date, account_id)
  NULLS NOT DISTINCT;
```

**唯一性為什麼要 `NULLS NOT DISTINCT`**：`account_id` 可空時 PostgreSQL 視 NULL 互不相等，
同一基礎同一日期可以插入**無限多列**整體缺漏的 `MISSING`。
PG16 的 `NULLS NOT DISTINCT` 解掉這一點（環境已凍結為 PostgreSQL 16）。
**不使用部分索引**——本刀沒有取代鏈，沒有需要排除的歷史列。

**`AMENDED` 本刀 fail closed（裁決 E）**：

```
寫入 evidence_status = 'AMENDED' → AMENDED_NOT_IMPLEMENTED:
```

該值保留在 CHECK 內（語意屬基線，不從值域刪除），但無寫入路徑。
理由：修正申告的正確落法是**取代鏈**，而取代鏈需要原子函式、延遲外鍵、權限封鎖、
競態處理與 `ImpactAssessment`（D-25-03／D-25-07）——現在做會明顯擴張本刀。
留到真正實作更正申告與 `ImpactAssessment` 時一起做。
本刀不預留 `superseded_by_observation_id` 欄位：**沒實作的形狀不先佔位**。

**`MISSING` 是一種「已登記的缺漏」，不是一列缺席的資料。**
欄位必填規則因此**依 `evidence_status` 分流**：

| evidence_status | `account_id`／`amount`／`source_dataset_id` | `confirmed_by`／`confirmed_role`／`confirmed_at` | `missing_reason`／`owner_id`／`due_date` |
|---|---|---|---|
| `PROVISIONAL`／`FILED` | **必填** | `confirmed_by` **必填且經角色驗證**（見下）；`confirmed_role`／`confirmed_at` **由 DB 寫入** | 必須為 NULL |
| `AMENDED` | 本刀無寫入路徑（fail closed，見下） | — | — |
| `MISSING` | 可空（`account_id` 可空代表整體缺漏） | 必須為 NULL——**沒有數字就沒有人能確認它** | **必填**（§24.4 GB-02 補充：標記缺漏、影響、負責人與截止日） |

違反 → `TAX_OBS_FIELD_CONTRACT:`。

**`confirmed_by IS NOT NULL` 不等於「經指定稅務專業角色確認」。**
只驗非空的話，任何使用者 UUID 都能填進去，GB-02 就只是一個外鍵而已。
因此建立非 `MISSING` 的 observation 時，DB **必須**逐項驗證：

```
① 解析政策：該 observation 的 book_basis
     → book_basis.basis_source_policy_version_id
     → basis_source_policy_version.confirmation_role      （政策說了算，不硬編 R1）

② 驗證角色指派：confirmed_by 在同一 tenant 且範圍涵蓋本 engagement，
   持有 role = 該 confirmation_role 的 role_assignment，
   且 revoked_at IS NULL（有效未撤銷）
     —— role_assignment.engagement_id IS NULL（租戶層）或 = 本案件（案件層）皆算涵蓋
     違反 → TAX_CONFIRMER_ROLE_INVALID:

③ 快照由 DB 寫入：NEW.confirmed_role := 該 confirmation_role
   NEW.confirmed_at := COALESCE(NEW.confirmed_at, now())
     —— 呼叫端自行宣告的 confirmed_role 一律被覆寫，不是被信任
     建立後 confirmed_by／confirmed_role 不可變更（改寫比較基準＝同一個洞的第二條路）
```

②③ 是**一起**成立才有意義：只驗角色不寫快照，角色日後撤銷時歷史無從還原
（INV-11：責任歸屬不得被追溯改變）；只寫快照不驗角色，等於讓呼叫端自己蓋章。

`evidence_status` 四值語意採 §24.4 GB-02 補充：
`PROVISIONAL` 可用於期中試算但輸出須標暫定；`FILED` 才可形成正式結論；
`AMENDED` 觸發重算評估且**歷史期間版本不覆寫**；
`MISSING` **硬性阻擋**正式遞延稅結論與期間包批准。

**「缺 observation 即拒絕」掛在具體操作上，不是掛在空氣中。**
「某個時點值不存在一列」這件事，DB 沒有觸發時機可以拒絕。因此 INV-05 的檢查落在
**涉及該直接匯入基礎的 `BasisReconciliation` 之 FINALIZE**（3.7）——
建立當下還沒有任何 `ReconciliationLine`，沒有可比對的涵蓋範圍：

```
FINALIZE 一筆 from_basis 或 to_basis 為 DIRECT_AUTHORITATIVE_IMPORT 的 reconciliation 時，
該 reconciliation 涉及的每個 (reporting_unit_id, as_of_date, account_id) 必須存在
  evidence_status ≠ 'MISSING' ∧ confirmed_by IS NOT NULL
的 TaxBasisObservation
否則 → INV05_TAX_OBSERVATION_MISSING:（訊息列出缺漏的科目與日期）
```

建立 reconciliation 當下只驗**端點本身**：兩個 basis 存在、同租戶同案件、
`from_basis_id ≠ to_basis_id`。涵蓋範圍的檢查一律在 FINALIZE。

`as_of_date` 取 `period_revision → reporting_period.end_date`（期末時點）。

其他凍結語意：

| # | 語意 | 依據 |
|---|---|---|
| a | 該基礎**不得存在 `BasisCompositionVersion`**（3.4c）——平台無從「推算」 | GB-02／INV-05 |
| b | **G-03 在本刀仍 fail closed。** B 基礎的模型存在**不等於**遞延稅結論可用 | §25.13 G-03 |

> **不得被誤讀**：本刀讓 B「有地方放」，不讓 B「能算出東西」。
> `RECONCILING → PENDING_PKG_APPR` 維持 M2-05 凍結的 `G03_NOT_IMPLEMENTED:`，
> 本刀**不解除**。遞延稅計算屬 REQ-TAX-101（P1）。

本刀不新增稅務專業角色的指派 UI，也不做匯入路徑——資料經種子與 DB 建立（見 §6）。

### 3.7　調節模型：BasisReconciliation（不與構成共用實體，有明確完成點）

```
basis_reconciliation
  reconciliation_id  uuid PK
  tenant_id / engagement_id / reporting_unit_id / period_revision_id  NOT NULL
  from_basis_id / to_basis_id  uuid NOT NULL → book_basis   -- CHECK (from ≠ to)
  calculation_run_id           uuid NOT NULL → calculation_run   -- 結果必繫於某次 run
  status             text NOT NULL DEFAULT 'DRAFT'
                       CHECK (status IN ('DRAFT','FINALIZED'))
  finalized_by / finalized_at
  UNIQUE (calculation_run_id, reporting_unit_id, from_basis_id, to_basis_id)

reconciliation_line
  line_id            uuid PK
  reconciliation_id  uuid NOT NULL → basis_reconciliation
  account_id / amount
  source_adjustment_id  uuid → adjustment
  source_rule_version_id uuid → rule_version
  -- CHECK：兩者恰有一個非空（來源必須說得出是誰造成的）
  description        text NOT NULL

reconciliation_difference          -- 顯式保存的殘差，不得靜默吸收
  diff_id            uuid PK
  reconciliation_id  uuid NOT NULL → basis_reconciliation
  reporting_unit_id / period_revision_id / from_basis_id / to_basis_id
  account_id / dimensions / amount
  reason_class       UNEXPLAINED | ROUNDING | TIMING | MAPPING
                     | SOURCE_DATA | POLICY | OTHER
  resolution_status  OPEN | EXPLAINED | RESOLVED
                     | RESOLVED_BY_POLICY | ACCEPTED_EXCEPTION
  owner_id / due_date
  threshold_policy_version_id
  resolution_ref
```

**INV-02 的完成點在 FINALIZE，不在每一列。**
逐列即時平衡是做不到的——第一列插入時必然不平。生命週期因此凍結為：

```
DRAFT      可新增／修改／刪除 Line 與 Difference
FINALIZE   一次驗 INV-02：
             to_basis.balance − from_basis.balance
                 = sum(ReconciliationLine) + sum(ReconciliationDifference)
           不成立 → 整筆交易拒絕（INV02_RECONCILIATION_IMBALANCE:）
           涉直接匯入基礎者另驗 INV-05（3.6）
FINALIZED  header、line、difference 全部不可變
           重算 → 建立新的 reconciliation（新 run），不修改舊結果
```

> **範圍聲明（不是永久架構決策）**：
> **本刀不提供 `FINALIZED` 後的差異結案功能。**
> 未來若需要結案追蹤，應以**獨立、append-only 的差異處理紀錄**擴充，
> **不應直接改寫已凍結的會計結果**。
>
> 因此「結案必須建立新 run」**不是**本刀凍結的架構結論，只是本刀沒有做結案功能的結果。
> `owner_id`／`due_date` 在本刀的語意是 **FINALIZE 當時的責任快照**，
> 不是一個可被更新的待辦欄位。

**殘差必須有去處。** 不允許「差一塊錢就算了」——差額若無法落入 `ReconciliationLine`，
就必須成為一筆 `ReconciliationDifference`。這是「尾差不得靜默吸收」在資料層的唯一落點。

**尾差自動結案（INV-24）**：`resolution_status = 'RESOLVED_BY_POLICY'` 必須**同時**滿足

```
單筆容許值   ∧   同期間 × 同幣別 × 同折算 run 的累積容許值
```

**本刀 `MaterialityThreshold` 不存在** → 兩個容許值都無法判定 →
自動結案路徑 **fail closed**，代碼 `INV24_THRESHOLD_NOT_IMPLEMENTED:`。
差異一律以 `OPEN` 建立，只能由人以理由改為 `EXPLAINED`／`ACCEPTED_EXCEPTION`
（且僅限 `DRAFT` 期間；FINALIZED 後不可變）。
**「守衛未實作 ≠ 守衛通過」**（M2-05 的凍結原則，沿用）。

「還有多少未解釋差異」一律查 `resolution_status = 'OPEN'`，**不依 `reason_class` 判斷**。

### 3.8　四類規則：Rule／RuleVersion 最小版（無引擎）

```
rule
  rule_id       uuid PK
  scope_level   text NOT NULL CHECK (scope_level IN ('PLATFORM','TENANT','CLIENT'))
  tenant_id     uuid → tenant              -- 見下方三層 CHECK
  engagement_id uuid → client_engagement   -- 見下方三層 CHECK
  rule_type     text NOT NULL CHECK (rule_type IN
                  ('LOCAL_TAX','GROUP_GAAP','DEFERRED_TAX','CONSOLIDATION'))
  jurisdiction / framework
  code / name
  -- 三層歸屬 CHECK：
  --   PLATFORM → tenant_id IS NULL     AND engagement_id IS NULL
  --   TENANT   → tenant_id IS NOT NULL AND engagement_id IS NULL
  --   CLIENT   → tenant_id IS NOT NULL AND engagement_id IS NOT NULL
  -- 且 CLIENT 時 engagement 必須屬於該 tenant（觸發器驗，外鍵表達不了）

rule_version
  rule_version_id        uuid PK          -- adjustment 與 reconciliation_line 引用它
  rule_id                uuid NOT NULL → rule
  version_no             int  NOT NULL
  posting_layer_id       uuid NOT NULL → posting_layer   -- 見下
  effective_from / effective_to
  supersedes_version_id  uuid → rule_version
  legal_reference        text        -- 法源或集團政策引用
  trigger_condition      jsonb       -- 保存，本刀不執行
  journal_template       jsonb       -- 保存，本刀不執行
  automation_level       text NOT NULL DEFAULT 'SUGGEST_ONLY'
                           CHECK (automation_level IN ('SUGGEST_ONLY','AUTO_POST'))
  required_granularity   text NOT NULL CHECK (required_granularity IN
                           ('BALANCE','JOURNAL','SUBLEDGER','DOCUMENT'))
  drafted_by             uuid NOT NULL → app_user   -- 建立後不可變
  peer_reviewed_by       uuid → app_user            -- DRAFT 可空；首次設定後不可變
  status                 text NOT NULL DEFAULT 'DRAFT'
                           CHECK (status IN ('DRAFT','ACTIVE','RETIRED'))
  UNIQUE (rule_id, version_no)
```

**`required_granularity` 沿用 `data_coverage.granularity` 的既有四值**
（`BALANCE／JOURNAL／SUBLEDGER／DOCUMENT`，0003:218）。
**不另造 `LINE`**——INV-23 是「規則所需粒度 vs 實際涵蓋粒度」的比較，
兩邊用不同值域就比不了，也會產生兩套詞彙。

**SOD-H3 的正確語意（首版寫錯，本版修正）**：

```
drafted_by        NOT NULL、建立後不可變
peer_reviewed_by  DRAFT 可為 NULL（否則 DRAFT 根本無法存在）
                  一旦設定為非 NULL，之後不可變更（不可改寫比較基準）
DRAFT → ACTIVE    明確檢查：peer_reviewed_by IS NOT NULL
                            AND peer_reviewed_by <> drafted_by
                  違反 → SODH3_PEER_REVIEW_REQUIRED:
```

把 `peer_reviewed_by` 從建立起就設 NOT NULL 會讓草稿無法存在；
但只把它設成可空又不檢查，等於 `NULL = x → NULL` 的繞過。
**兩件事分開：可空是生命週期的需要，檢查掛在進 ACTIVE 的那一刻。**

**「四類規則不可混記」（AC-BAS-001）的落法——兩段檢查**：

```
① 建立 RuleVersion 時：
     posting_layer.rule_type = rule.rule_type
     posting_layer.rule_type IS NULL → 拒絕（LAYER_RULE_TYPE_UNSET:）
     違反 → RULE_TYPE_LAYER_MISMATCH:

② Adjustment 引用規則時：
     adjustment.posting_layer_id = rule_version.posting_layer_id
     違反 → ADJ_LAYER_RULE_MISMATCH:
     且只允許引用 status = 'ACTIVE' 的 RuleVersion（RULE_VERSION_NOT_ACTIVE:）
```

比對「層是否相同」比比對「rule_type 是否相同」更嚴：後者允許同類型不同層的錯配。

**平台規則本刀唯讀，且不種任何列。**
`scope_level = 'PLATFORM'` 的結構與 RLS 政策本刀建立，但**不種入任何平台規則列**：
`drafted_by` NOT NULL 而平台身分與發布流程尚不存在（`PlatformRoleAssignment` 未落地），
**不得用某租戶的 `app_user` 假冒平台發布者**（§26.3 兩個控制面）。
`app_runtime` 對 `scope_level = 'PLATFORM'` 的列只有 SELECT，無 INSERT／UPDATE／DELETE。
本刀可達的規則因此只有 `TENANT`／`CLIENT` 兩層——測試亦以此二層驗證。

**本刀不做**：`resolveApplicableRules()`、`RuleEvaluator`、任何自動建議。
`automation_level` 一律 `SUGGEST_ONLY`（GB-05：任何自動結果初始狀態為建議）；
`AUTO_POST` 只保留值，**寫入即拒絕**（`AUTO_POST_NOT_IMPLEMENTED:`）。
`required_granularity` 只保存，INV-23 的執行判定隨規則引擎（MVP 3+）。

### 3.9　與既有實體的最小連接

| 既有物件 | 本刀變更 | 不做什麼 |
|---|---|---|
| `adjustment` | `basis` 硬約束欄位 **DROP**，改為 §26.8 形狀：`basis_from_id`／`basis_to_id`（NOT NULL）／`posting_layer_id`（NOT NULL）／`rule_version_id`（可空）。既有列以 A→C ＋ `GROUP_GAAP_ADJ` 回填。`fn_adjustment_attribution_guard` 同步改守新三欄（建立後不可變） | 不動 §25.7 狀態機、不動三段 SoD、不動 G-08 四項證據 |
| `adjustment_version_snapshot` | **不動。** `content` 內既有的 `basis` 字段原樣保留 | **不追溯改寫歷史快照**——那是當時的事實 |
| `journal_entry`／`journal_line` | `journal_entry` 增 **`posting_layer_id` 一欄**（自 `adjustment` 物化時帶入，不可變）。INV-03／INV-04 於此繼承 | **不增 `basis_id`**（理由見下）、不改 INV-06（僅 APPROVED 後物化）、不改不可變性 |
| `balance_snapshot_line` | 保留 `posting_layer` 兩值不改寫，新增 `posting_layer_id` 可空外鍵；**必填與否由 manifest 版本界線判定**（見下） | **既有 run 的列不回寫、不重算** |
| `calculation_input_manifest`／`entry` | `object_type` 增 `BASIS_COMPOSITION`；建立 run 時凍結所引用的 `basis_composition_version_id` 與其 `ConstitutiveLayerItem` 集合 | 不改 `frozen_set_content_hash` 演算法、不改 canonical 規則（改了就要升版分流） |
| `mapping_rule` | 不動 | 映射是 A 基礎內的科目對應，與基礎軸正交 |
| `period_revision` | 不動 | 期間狀態機（0022）不因本刀改變 |

**凍結決定——事實只歸屬「層」，不歸屬「基礎」**：

`JournalEntry` **不帶 `basis_id`**。在構成模型下，一筆事實屬於某個 `PostingLayer`；
「哪些基礎包含它」由 `ConstitutiveLayerItem` 回答（§26.5：僅此實體參與加總）。
若在分錄上釘死 `basis_id = C`，日後新增的基礎 D 只要在其 composition 納入
`GROUP_GAAP_ADJ`，同一筆事實就會**同時**經由 composition 被算進 D、又帶著寫死的
`basis_id = C`——出現兩個彼此競爭的加總鍵，而且錯的那一個查得到。
橋樑歸屬（A→C）已由 `adjustment.basis_from_id`／`basis_to_id` 保存，那是**調整的語意**，
不是分錄的加總鍵，兩者不重複。

**凍結決定——新舊快照的界線由 DB 判定，不靠 worker 紀律**：

```
版本界線 = 該 run 的 manifest 是否含 object_type = 'BASIS_COMPOSITION' 的 entry

  含      → 新增 BalanceSnapshotLine 必須有 posting_layer_id
            違反 → BSL_POSTING_LAYER_REQUIRED:
  不含    → 允許 posting_layer_id IS NULL（本 run 早於分層模型）

歷史列一律不回寫（既有 fn_forbid_mutation 已擋 UPDATE／DELETE）
新 run 對應：SOURCE_TB → LOCAL_BOOK      ADJUSTMENT → GROUP_GAAP_ADJ
```

「新 run 一律填」若只是 worker 的約定，忘了填就是靜默降級；
以 manifest 是否凍結 composition 作界線，**同一個判準同時決定「這是新 run」與
「因此必須有層」**，DB 自己就能裁決。

理由：改寫歷史快照會使既有 `result_content_hash` 與 02C 的證據包 hash 全部失效，
且違反「已交付／已凍結結果不可變」。**兩種表達並存是遷移的正常狀態，不是缺陷**；
`posting_layer_id IS NULL` 明確代表「本 run 早於分層模型」，不是「未知」。

### 3.10　新增第四種基礎不得重建核心實體（AC-BAS-001 的可執行版）

驗收以**可執行測試**表達，不以文字宣稱：

```
測試：在既有 engagement 內以純 INSERT 新增
        BookBasis（code='D', framework='IFRS', source_mode='COMPOSED',
                   permits_group_layer=false）
      ＋ BasisCompositionVersion v1（LOCAL_BOOK +1, GROUP_GAAP_ADJ +1）
      ＋ 一筆掛在該基礎的 Adjustment 與物化 JournalEntry
必須：零 DDL（無 ALTER／無 CREATE TYPE／無 CHECK 修改）
      既有 A／B／C 的任何一筆事實皆未被修改（逐列 hash 比對）
      既有測試全數維持綠燈
```

任何需要改 DDL 才能加基礎的設計，本刀視為未達成。

---

## 4　驗收清單

| # | 條件 | 驗證位置 |
|---|---|---|
| 1 | `book_basis` A／B／C 三筆可**分別查詢**餘額與調整；查詢路徑不因基礎不同而分歧（AC-BAS-001） | DB 整合＋端到端 |
| 2 | **新增第四基礎零 DDL**（3.10 全條件），既有事實逐列未變 | DB 整合 |
| 3 | 全部 migration 內**不存在以 `code` 值驅動的約束**（`code = 'B'` 等）；約束一律由 `source_mode`／`scope_type`／`rule_type`／`permits_group_layer` 驅動 | 原始碼掃描＋DB 整合 |
| 4 | `source_mode = DIRECT_AUTHORITATIVE_IMPORT` 的基礎建立 `BasisCompositionVersion` → 拒絕（INV-05）；缺 `basis_source_policy_version_id`／所指版本非 APPROVED → 拒絕 | DB 整合 |
| 4b | `source_mode = COMPOSED` 卻填 `basis_source_policy_version_id` → 拒絕（無混合語意） | DB 整合 |
| 5 | INV-05 掛在**具體操作**上：FINALIZE 涉直接匯入基礎的 reconciliation 時，缺對應非 MISSING observation → 拒絕（`INV05_TAX_OBSERVATION_MISSING:`），訊息列出缺漏科目與日期 | DB 整合＋端到端 |
| 5b | `TaxBasisObservation` 欄位契約依 `evidence_status` 分流（3.6 表）：`MISSING` 缺 `missing_reason`／`owner_id`／`due_date` → 拒絕；`MISSING` 帶 `confirmed_by` → 拒絕；非 `MISSING` 缺 `amount`／`source_dataset_id`／`confirmed_by` → 拒絕 | DB 整合 |
| 5c | 唯一性：同一 `(basis, unit, as_of_date)` 插入**第二列** `account_id IS NULL` 的 MISSING → 拒絕（`NULLS NOT DISTINCT` 對全部列生效，不得因 NULL 相異而放行） | DB 整合 |
| 5d | `AMENDED` 寫入 → 拒絕（`AMENDED_NOT_IMPLEMENTED:`）；該值仍存在於 CHECK 值域內（語意不從基線刪除）；全庫無 `superseded_by_observation_id` 之類的取代鏈佔位欄 | DB 整合＋原始碼掃描 |
| 5e | **稅務確認角色**：`confirmed_by` 無有效角色指派／角色 ≠ 政策的 `confirmation_role`／指派已 `revoked_at` → 拒絕（`TAX_CONFIRMER_ROLE_INVALID:`）。**負面測試須先斷言前置狀態**：該使用者確實存在、確實在本案件、只是角色不符或已撤銷——不得以「使用者不存在」的理由假綠通過 | DB 整合 |
| 5f | `confirmed_role` 為 **DB 寫入的快照**：呼叫端宣告任意 `confirmed_role` 一律被覆寫為政策角色；建立後 `confirmed_by`／`confirmed_role` 不可變更；日後撤銷該角色指派，既有 observation 的快照**不變**（INV-11） | DB 整合 |
| 5g | `basis_source_policy_version.confirmation_role` 為 `role_code` 且 NOT NULL；**全庫無硬編 `'R1'` 的稅務確認判斷**（換政策版本即可換角色，不改約束） | 原始碼掃描＋DB 整合 |
| 6 | **B 基礎存在不解除 G-03**：`RECONCILING → PENDING_PKG_APPR` 仍回 `G03_NOT_IMPLEMENTED:` | DB 整合＋端到端 |
| 7 | INV-01：以既有 PREVIEW run 的快照逐科目驗 `C = LOCAL_BOOK + GROUP_GAAP_ADJ`，與既有 Case-001 12/12 集團 TB **完全一致**（本刀不改變任何金額） | DB 整合＋端到端 |
| 8 | INV-02 的完成點：`DRAFT` 期間可自由增修 Line／Difference 不受平衡檢查；**FINALIZE 時殘差未落入 Line 或 Difference → 整筆交易拒絕**（`INV02_RECONCILIATION_IMBALANCE:`） | DB 整合 |
| 8b | `FINALIZED` 後 header／line／difference 全部不可變；重算＝新 reconciliation（新 run），舊結果未被修改 | DB 整合 |
| 9 | **尾差不得靜默吸收**：`RESOLVED_BY_POLICY` 一律 fail closed（`INV24_THRESHOLD_NOT_IMPLEMENTED:`）；差異只能以 `OPEN` 建立 | DB 整合＋端到端 |
| 10 | 「未解釋差異數」查 `resolution_status = 'OPEN'` 得到正解；把某筆 `reason_class` 改為 `ROUNDING` **不改變**該計數 | DB 整合 |
| 11 | INV-03：ENTITY layer 的調整落在 CONSOLIDATION_GROUP 單位 → 拒絕；GROUP layer 落在 LEGAL_ENTITY 單位 → 拒絕（單位經 `period_revision → reporting_period` 解析） | DB 整合 |
| 12 | INV-04：GROUP scope 層的調整其 `basis_to` 為 `permits_group_layer = false` → 拒絕；**且** `permits_group_layer = false` 的基礎其 composition 納入 GROUP scope 層 → 拒絕（誤配置堵在入口） | DB 整合 |
| 13 | 四類不可混記兩段檢查：① `posting_layer.rule_type ≠ rule.rule_type` → 拒絕；`posting_layer.rule_type IS NULL` → **顯式拒絕**（`LAYER_RULE_TYPE_UNSET:`，非默默通過）② `adjustment.posting_layer_id ≠ rule_version.posting_layer_id` → 拒絕；引用非 ACTIVE 版本 → 拒絕 | DB 整合 |
| 14 | SOD-H3 生命週期正確：`DRAFT` 可存在且 `peer_reviewed_by` 為 NULL；設定後不可變更；`DRAFT → ACTIVE` 時 `peer_reviewed_by` 為 NULL 或等於 `drafted_by` → 拒絕；`drafted_by` NOT NULL 且不可變 | DB 整合 |
| 14b | `automation_level = 'AUTO_POST'` 寫入 → 拒絕（`AUTO_POST_NOT_IMPLEMENTED:`）；`required_granularity` 只接受既有四值，`'LINE'` 等新值 → 拒絕 | DB 整合 |
| 15 | INV-21：已被 LOCKED revision 的 manifest 引用的 `BasisCompositionVersion` 不可修改；`APPROVED` 後 header 與 item 皆不可變；新政策＝新 `version_no`，舊版本仍可重演 | DB 整合 |
| 16 | Manifest 凍結 `BASIS_COMPOSITION` entry（`object_id = basis_composition_version_id`）；重演讀凍結內容並驗 `content_hash`（INV-29） | DB 整合＋端到端 |
| 17 | **既有 run 的 `balance_snapshot_line` 未被回寫**（`posting_layer` 原值保留、`posting_layer_id` 為 NULL）；既有 `result_content_hash` 與證據包 hash 全部維持有效 | DB 整合＋端到端 |
| 18 | 版本界線由 DB 判定：manifest **含** `BASIS_COMPOSITION` entry 的 run，插入無 `posting_layer_id` 的快照列 → 拒絕（`BSL_POSTING_LAYER_REQUIRED:`）；**不含**者允許 NULL | DB 整合 |
| 19 | `adjustment.basis` 已 DROP；新三欄建立後不可變更；既有列回填後語意等價（A→C ＋ `GROUP_GAAP_ADJ`）；**`adjustment_version_snapshot.content` 內的舊 `basis` 字段原樣保留未被改寫** | DB 整合 |
| 20 | 所有新守衛例外以**穩定機器前綴**回傳，API 以前綴擷取並映射為 409 ＋ `x-error-code` ＋ CVA 留痕，**非 500、不依中文文案判斷** | 端到端 |
| 21 | 跨租戶／跨案件：`book_basis`／`basis_source_policy_version`／`basis_composition_version`／`tax_basis_observation`／`basis_reconciliation` 皆受 RLS，不可見不可寫（INV-18） | DB 整合 |
| 21b | `posting_layer` 為平台參照主檔：`app_runtime` 可 SELECT、**不可 INSERT／UPDATE／DELETE** | DB 整合 |
| 21c | `rule` 三層歸屬 CHECK：`PLATFORM`（tenant/engagement 皆 NULL）／`TENANT`（tenant 非空、engagement NULL）／`CLIENT`（皆非空且 engagement 屬該 tenant）；違反任一組合 → 拒絕。`PLATFORM` 列 `app_runtime` 唯讀；**本刀不種任何 PLATFORM 列**（無合法平台發布者） | DB 整合 |
| 22 | 既有 **594 條零退化** | 全套 |

---

## 5　走查裁決紀錄（第一輪，已收入本版）

| # | 議題 | 裁決 | 落點 |
|---|---|---|---|
| A | `Rule`／`RuleVersion` 是否屬本刀 | **納入**，只落表與約束、不做引擎（否則 REQ-RUL-001 仍不能關閉） | 3.8 |
| B | `BookBasis`／`PostingLayer` 的範圍 | **分開處理**：`PostingLayer` 平台級參照主檔；**`BookBasis` 帶 `tenant_id ＋ engagement_id` 並受 RLS**——A／B／C 是案件內的口徑，`framework`／集團政策／`basis_source_policy_version` 都可能不同 | 3.1／3.2 |
| B2 | `rule` 的隔離 | **三層**，且 `CLIENT` 另有 `engagement_id`；三種組合以 CHECK 強制，`CLIENT` 的 engagement 須屬該 tenant。平台規則**唯讀／不種列**——不得用租戶 `app_user` 假冒平台發布者 | 3.8 |
| C | INV-04 的判定依據 | **改用 `book_basis.permits_group_layer` 顯式欄位**。composition 反查是循環論證：GROUP layer 被誤加進 A 之後，反查會說 A「允許 GROUP」，無法阻止錯誤配置 | 3.3 |
| D | `adjustment.basis` 的處置 | **DROP**，守衛與測試同步替換；`adjustment_version_snapshot.content` 內的舊 `basis` 字段**保留不追溯改寫** | 3.9 |

## 5A　走查裁決紀錄（第二輪，本文件最後一輪走查）

| # | 議題 | 裁決 | 落點 |
|---|---|---|---|
| E | `TaxBasisObservation` 的 `AMENDED` | **本刀不支援**：寫入即 `AMENDED_NOT_IMPLEMENTED:`；**移除**取代鏈欄位；唯一索引改為對全部列 `NULLS NOT DISTINCT`、不留部分索引。取代鏈需要原子函式、延遲外鍵、權限封鎖、競態與 `ImpactAssessment`，留到真正實作更正申告時一起做 | 3.6 |
| F | `FINALIZED` 後的不可變性 | **維持完全不可變**（安全的嚴格子集）。但文字改為**範圍聲明**：本刀不提供 FINALIZED 後的差異結案功能；未來以獨立、append-only 的差異處理紀錄擴充，**不改寫已凍結的會計結果**。「結案必須建新 run」不是永久架構決策；`owner_id`／`due_date` 是 FINALIZE 當時的責任快照 | 3.7 |
| G | `PLATFORM` 規則零列 | **同意**。表與讀取政策先建立，發布流程之後再接；沒有合法平台發布身分就不種假資料——這不是缺漏 | 3.8 |
| **H** | **稅務確認角色（新增阻塞，本輪補上）** | `confirmed_by IS NOT NULL` **不足以**證明「經指定稅務專業角色確認」。`BasisSourcePolicyVersion` 增 `confirmation_role role_code NOT NULL`；建立非 MISSING 的 observation 時 DB 必須驗有效未撤銷的角色指派、角色等於政策的 `confirmation_role`，且 `confirmed_role` **由 DB 寫入快照**，不接受呼叫端宣告。直接落實 GB-02，且不硬編 R1 | 3.5／3.6 |

首版另有六處欄位契約不足，第一輪已一併補正：
主鍵形狀（3.4／3.8）、`BasisSourcePolicyVersion` 實體（3.5）、
`RuleVersion` 工作流與 `required_granularity` 值域（3.8）、
INV-02 的完成點與 reconciliation 生命週期（3.7）、
`TaxBasisObservation` 的 `MISSING` 欄位契約與 INV-05 掛載點（3.6）、
新舊快照界線的 DB 判定（3.9）。

---

## 6　明確不做

- **完整規則引擎**：`resolveApplicableRules()`、`RuleEvaluator`、自動建議與自動過帳。
  `AUTO_POST` 寫入即拒絕。
- **固定資產多基礎運算**：`FixedAsset`／`AssetEvent`／逐基礎折舊與事件重算（REQ-AST-101，P1）。
- **遞延稅計算**：`DeferredTaxItem`／`TaxRateVersion`／暫時性差異判定／可實現性判斷。
  G-03 維持 fail closed。
- **完整合併**：`GroupMembership` 生效期間化、抵銷分錄產生、合併報表。
  §24 GB-03 的邊界不變——平台止於「可被合併的資料包」，
  `snapshot_purpose` 不得出現 `CONSOLIDATED_FINANCIAL_STATEMENT`。
- **折算**：`TranslationResult`／匯率版本／CTA（INV-20）。`TRANSLATION_ADJUSTMENT`
  本刀只建層值，無任何寫入路徑。
- **`BasisReconciliation` 的自動產生**：worker 不新增任何調節計算邏輯；
  本刀的調節結果由人工／測試建立並綁定既有 run。
- **`TaxBasisObservation` 的匯入 UI 與稅務角色指派畫面**：本刀只建結構與約束，
  資料經種子與 DB 建立。使用者入口屬後續刀。
- **平台控制面**：`PlatformRoleAssignment`、平台規則發布流程，以及任何 `PLATFORM` 規則列。
- **`MaterialityThreshold`**：因此尾差自動結案 fail closed（3.7）。
- **`AMENDED` 與觀測值取代鏈**：修正申告的落地（原子函式、延遲外鍵、權限封鎖、競態、
  `ImpactAssessment`）整組留待更正申告刀；本刀 fail closed，**不預留佔位欄位**。
- **`FINALIZED` 後的差異結案功能**：見 3.7 的範圍聲明。

## 7　後續驗收（不在本刀）

- `MaterialityThreshold` 落地後，解除 `INV24_THRESHOLD_NOT_IMPLEMENTED:`，
  並補「單筆低於門檻但累積已重大」的負面測試（INV-24 的真正證明）。
- `TaxBasisObservation` 匯入入口與稅務專業角色指派落地後，B 基礎才有使用者可達的路徑；
  `evidence_status = MISSING` 的硬性阻擋須連到期間包批准。
- 更正申告刀落地後，`AMENDED` 才有寫入路徑：取代鏈（原子函式、延遲外鍵、權限封鎖、
  競態處理）＋ `ImpactAssessment`（D-25-03／D-25-07），且歷史期間版本不覆寫。
  屆時唯一索引須由「全部列」收窄為「僅現行列」。
- 差異結案追蹤落地時，以**獨立 append-only 的處理紀錄**擴充，
  **不改寫已 `FINALIZED` 的會計結果**（3.7 範圍聲明）。
- 平台控制面落地後，`PLATFORM` 規則才有合法作者；在此之前該 scope 永遠無列。
- 規則引擎落地後，`required_granularity` 與 `DataCoverage.granularity` 的比對（INV-23）
  才真正生效；在此之前該欄位只是保存。
- 折算刀落地後，`TRANSLATION_ADJUSTMENT` 層的寫入路徑、其逐筆 `rule_type` 歸屬，
  與 INV-20（CTA 必須物化、不得由兩幣別金額相減推導）。
- 固定資產刀落地後，AC-BAS-001 的「各 BookBasis 可有不同耐用年限、方法、殘值」
  才在資產層成立；本刀只在餘額與調整層成立。

---

## 8　實作順序（走查通過後）

```
1  migration 0023：平台參照主檔 posting_layer（6 層種子，app_runtime 唯讀）
2  migration 0023：basis_source_policy_version（含 confirmation_role）→ book_basis
                   （案件範圍＋RLS）＋每案件 A/B/C 種子
3  migration 0023：rule / rule_version（三層 CHECK、SOD-H3 生命週期、rule_type 兩段檢查）
4  migration 0023：構成模型＋INV-01／INV-04（入口）／INV-05／INV-21 守衛
5  migration 0023：tax_basis_observation（evidence_status 欄位契約＋確認角色驗證與
                   DB 寫入的角色快照＋AMENDED fail closed）
6  migration 0023：調節模型＋DRAFT/FINALIZED 生命週期＋INV-02／INV-05 於 FINALIZE／INV-24 fail closed
7  migration 0023：既有實體接線（adjustment 欄位改造＋回填、journal_entry、
                   balance_snapshot_line 版本界線、INV-03／INV-04 繼承）
8  migration 0023：manifest BASIS_COMPOSITION 凍結
9  API：穩定前綴 → 409 映射（沿用 0022 模式）＋ CVA
10 測試三層補齊；完成後跑一次完整測試，收口時連跑兩輪
```

`0023` 為單一 migration（同一刀不拆多份），沿用 M2-05 的做法。
