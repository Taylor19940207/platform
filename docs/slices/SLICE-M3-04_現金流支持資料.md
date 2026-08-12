# SLICE-M3-04　現金流支持資料（REQ-CFS-001）

> 狀態：**事前契約 第一版，待走查**。**尚未批准進 migration。**
> 風險：**第一級**（母公司批准的方法版本、完整度判定、控制總額勾稽、凍結與重演）。
>
> 對應基線：手冊 v1.2 **REQ-CFS-001（P0）**、§20 MVP 3、§299–301（資料粒度）；
> 設計書 v1.1 **GB-04**（收集 vs 重建）、§26.11 `CashFlowClass`、§25.13 G-09、
> INV-23（粒度不足不得自動執行）、D-26-03。
> 前置：`SLICE-M3-02`／`SLICE-M3-03`（皆 CLOSED／PASS）。

## 一、邊界：P0 是**支持資料**，不是現金流量表

GB-04 寫得很清楚：**P0 僅保存母公司確認的方法與粒度，並收集、映射支持資料；
直接法重建屬 P1（REQ-CFS-101），且重建結果永遠標示為「建議」。**

因此本刀的產出是**可被母公司系統或 Excel 使用的支持資料包**，不是報表：

| 做 | 不做 |
|---|---|
| 保存母公司批准的方法／粒度／證據版本 | **不產生完整合併現金流量表** |
| `CashFlowClass` 主檔與版本 | **不做直接法重建**（REQ-CFS-101，P1） |
| 科目／分錄／必要明細 → `CashFlowClass` 的映射 | **不自動識別非現金項** |
| 粒度不足時 fail closed 或走批准例外 | 不做分類建議引擎（GB-05：任何自動結果初始狀態一律是「建議」） |
| 必要分類的完整度判定 | 不做關係人現金流的自動抵銷 |
| 支持資料輸出與控制總額勾稽 | 不解鎖任何期間遷移 |
| 政策、映射、來源粒度與輸出結果的凍結與重演 | 不做 `OutputProfile`／正式交付包 |

> **本刀最容易越界的地方**：一旦系統開始「把未分類的金額歸到某一類」，
> 它就從收集變成重建。因此**沒有預設分類**——未映射就是未映射，
> 由完整度判定擋下，不由演算法補完。

## 二、母公司批准的方法與粒度：`CashFlowPolicyVersion`

現金流的方法（直接法／間接法）與粒度是**母公司的決定**，不是平台的推論
（§24.6：R4「決定輸出與現金流粒度」）。

    CashFlowPolicyVersion
    ├─ engagement_id / reporting_unit_id
    ├─ method            DIRECT | INDIRECT          母公司採用的列報方法
    ├─ granularity       ACCOUNT | JOURNAL | SUBLEDGER | DOCUMENT
    │                    支持資料所需的**最低**粒度；沿用 DataCoverage 的既有四值
    ├─ required_classes  必要分類集合（見 §五）
    ├─ evidence_version  母公司確認文件的版本識別（外部證據）
    ├─ series_id / version_no / supersedes_policy_version_id
    └─ approved_by / approved_at    **案件層 R4**（system-only 函式）

- **`method` 與 `granularity` 都不得由平台推導**；未經 R4 批准的版本不得被使用。
- 版本鏈與不可改寫的規則沿用 M3-03（現行版本由**取代鏈**判斷，不按時間；
  不得從同一舊版分叉出兩個現行版本）。
- **`evidence_version` 必填**：母公司「確認了什麼」必須指得到一份外部文件，
  否則「已批准的方法」只是系統裡的一個字串。

## 三、`CashFlowClass` 主檔與版本

    CashFlowClassSetVersion            一次批准一整套分類（與權益 lot set 同理）
    ├─ engagement_id
    ├─ series_id / version_no / supersedes_set_version_id
    ├─ approved_by / approved_at       案件層 R4
    └─ CashFlowClass［］
       ├─ code / name
       ├─ activity          OPERATING | INVESTING | FINANCING
       ├─ direction         INFLOW | OUTFLOW | EITHER
       └─ is_required       是否屬「必要分類」（§五）

- **以集合為批准與凍結單位**：單一分類的版本鏈證明不了「沒有漏掉一個必要分類」
  ——漏掉的那一個不存在，沒有版本鏈會指向它（與 `EquityTranslationLotSetVersion`
  同一個理由）。
- `activity` 三值是準則層的結構事實，不是可配置政策；`code` 由母公司決定。
- **不預先塞入任何預設分類集合**：分類是母公司口徑的一部分。

## 四、映射：科目／分錄／必要明細 → `CashFlowClass`

    CashFlowMappingVersion
    ├─ engagement_id / policy_version_id      綁定方法與粒度版本
    ├─ series_id / version_no / supersedes_*
    ├─ approved_by / approved_at              R4 批准；R2 建立、R3 覆核（比照 MappingRule）
    └─ CashFlowMappingRule［］
       ├─ source_kind      ACCOUNT | JOURNAL_LINE | SUBLEDGER_ITEM | DOCUMENT
       ├─ source_ref       依 source_kind 的具體外鍵（不是可空 text，比照 0031）
       ├─ cash_flow_class_id
       ├─ effective_from / effective_to       生效日（比照 MappingRule）
       └─ evidence_ref
- **`source_kind` 必須不高於政策的 `granularity`**：政策說只到 `ACCOUNT`，
  就不得出現 `JOURNAL_LINE` 的規則——那是在宣稱擁有沒有取得的資料。
- **一對一，不做條件式映射**（沿用 SLICE-M2-01 的邊界；條件式在 BACKLOG）。
- 同一 `source_ref` 在同一生效期間內至多一條規則；重疊即拒絕
  （`CFS_MAPPING_AMBIGUOUS`）。

## 五、必要分類的完整度判定

「完整」不是「每一筆都有分類」，而是**母公司宣告的必要分類都拿得到資料**。

    完整度判定（per period_revision × reporting_unit × policy_version）
    ├─ 每個 is_required 的 CashFlowClass 至少有一筆已映射的支持資料
    ├─ 所有納入的來源事實都命中恰好一條映射規則
    └─ 實際 DataCoverage.granularity ≥ 政策要求的 granularity

未達成時的穩定代碼：

| 代碼 | 意義 |
|---|---|
| `CFS_POLICY_NOT_APPROVED` | 未選定或未批准的方法版本 |
| `CFS_CLASS_SET_NOT_APPROVED` | 未選定或未批准的分類集合 |
| `CFS_MAPPING_NOT_APPROVED` | 未選定或未批准的映射版本 |
| `CFS_GRANULARITY_INSUFFICIENT` | 實際 `DataCoverage` 粒度低於政策要求（INV-23） |
| `CFS_UNMAPPED_SOURCE` | 有來源事實未命中任何映射規則 |
| `CFS_MAPPING_AMBIGUOUS` | 同一來源命中多條規則 |
| `CFS_REQUIRED_CLASS_EMPTY` | 必要分類沒有任何支持資料 |

### 粒度不足：fail closed，或**批准例外**

INV-23 的原則是「粒度不足時不得自動執行」。但現金流常常真的拿不到 JOURNAL 粒度，
因此提供一條**顯式的例外路徑**（比照 G-02 的「已批准例外」）：

    CashFlowCoverageException
    ├─ period_revision_id / reporting_unit_id / policy_version_id
    ├─ cash_flow_class_id            例外的範圍（不得整期一次豁免）
    ├─ actual_granularity            實際取得的粒度
    ├─ reason / evidence_ref         必填
    └─ approved_by / approved_at     **案件層 R4**

- **例外必須逐分類申請**，不得「整期粒度不足一次豁免」——那等於取消判定。
- 有例外時，輸出的每一列必須標記 `coverage_exception_id`，
  **支持資料本身要看得出哪一段是在粒度不足下產生的**。
- 沒有例外且粒度不足 → `CFS_GRANULARITY_INSUFFICIENT`，**不產生輸出**。

## 六、支持資料輸出與控制總額勾稽

    CashFlowSupportRun（沿用 CalculationRun 的形狀？見下）
    └─ CashFlowSupportLine［］
       ├─ cash_flow_class_id / activity
       ├─ amount（功能幣）/ amount_reporting（報告幣，可空）
       ├─ source_kind / source_ref / mapping_rule_id
       ├─ coverage_exception_id（可空）
       └─ period_revision_id / reporting_unit_id

**待走查拍板的一項**：現金流支持資料是**另立 `CashFlowSupportRun`**，
還是**沿用 `CalculationRun` 並新增 `calculation_scope = 'CASH_FLOW_SUPPORT'`**？
本契約傾向**後者**——凍結集合、Manifest 完整性驗證、replay 與結果雜湊
（0034／0035）已經是通用能力，另立一套會出現第二份「凍結與重演」實作，
那正是 M3-02 走查反覆擋下的模式。若走查同意，本刀只需擴充 `calculation_scope`
與新增 manifest 條目型別，不重建。

### 控制總額勾稽（G-09 的資料層對應物）

支持資料必須與**已折算的財務資料**對得起來，否則它只是一堆分類標籤：

| # | 勾稽 | 判準 |
|---|---|---|
| K1 | 現金及約當現金的期初＋淨變動＝期末 | 以現金類科目的 TB 餘額為準（來自選定的 FX run 或 NO_FX run） |
| K2 | 三大活動（OPERATING／INVESTING／FINANCING）合計＝現金淨變動 | 分類金額加總 |
| K3 | 每一列都追得到來源事實與映射規則 | `source_ref` 與 `mapping_rule_id` 皆非空 |
| K4 | 幣別一致 | 支持資料的幣別＝所引用 run 的功能幣；報告幣欄位僅在引用 FX run 時填寫 |

不成立時 `CFS_CONTROL_TOTAL_MISMATCH`，**輸出標記為不可用**（比照 G-09 的
`output_capability = NONE`）。

> **K1 的現金科目來自哪裡**是走查要拍的第二項：由 `CashFlowClassSetVersion`
> 明示「哪些集團科目屬現金及約當現金」，或由 `Account` 上另一個受控屬性？
> 本契約傾向**前者**（母公司口徑的一部分，隨分類集合一起批准）。

## 七、凍結與重演

沿用 M3-02／M3-03 已凍結的模式，**不另立第二套**：

- Manifest 新增條目型別：`CASH_FLOW_POLICY_VERSION`、`CASH_FLOW_CLASS_SET_VERSION`、
  `CASH_FLOW_MAPPING_VERSION`、`CASH_FLOW_COVERAGE_EXCEPTION`、
  `SOURCE_CALCULATION_RUN`（重用）。
- payload 保存**實際使用到的每一個值**（分類集合、命中的映射規則、例外、
  來源 TB 的現金科目餘額），canonical 為 payload 的文字投影，SHA-256。
- 產出前先 `fn_fx_verify_manifest`（該函式與 FX 無關，是通用的凍結集合驗證——
  本刀順帶改名為 `fn_manifest_verify`，**行為不變**）。
- replay 只讀凍結 payload，結果雜湊涵蓋**金額與來源證據**（分類、映射規則、例外）。

## 八、期間狀態機邊界

**本刀不解鎖任何遷移。** `ADJ_APPROVED → CALCULATING` 仍缺 G-03；
`CALCULATING → RECONCILING` 的守衛與 `RECONCILING` 之後各段亦未實作。
現金流支持資料是 `RECONCILING` 階段「關係人與現金流核對」的資料前提，
但**本刀只交付資料與判定能力**，0028 的規格函式不動。

## 九、驗收

1. **方法與粒度不得由平台推導**：未選定或未批准的政策版本 → `CFS_POLICY_NOT_APPROVED`；
   非 R4 不得批准。**反證：讓判定自行取「最新已批准版本」→ 轉紅。**
2. **`evidence_version` 必填**：缺母公司確認文件 → 拒絕建立政策版本。
3. **分類以集合為批准單位**：集合不可變、版本向後指、不得分叉；
   單獨新增一個分類到已批准集合 → 拒絕。
4. **映射粒度不得高於政策**：政策為 `ACCOUNT` 而規則為 `JOURNAL_LINE` → 拒絕。
   **反證：拿掉該檢查 → 轉紅。**
5. **映射唯一**：同一來源同一生效期間兩條規則 → `CFS_MAPPING_AMBIGUOUS`。
6. **未映射即未映射**：有來源事實未命中規則 → `CFS_UNMAPPED_SOURCE`，
   **不得**被歸入任何預設分類。**反證：加入「其他」預設分類 → 轉紅。**
7. **必要分類完整度**：某個 `is_required` 分類沒有任何支持資料 →
   `CFS_REQUIRED_CLASS_EMPTY`。
8. **粒度不足 fail closed**：`DataCoverage.granularity` 低於政策要求且無例外 →
   `CFS_GRANULARITY_INSUFFICIENT`，不產生任何輸出。
9. **例外必須逐分類且經 R4 批准**：整期一次豁免 → 拒絕；有例外時輸出的相關列
   必須帶 `coverage_exception_id`。**反證：允許整期豁免 → 轉紅。**
10. **控制總額 K1～K4**：任一不成立 → `CFS_CONTROL_TOTAL_MISMATCH` 且輸出不可用。
    正控制：Case-001 的現金科目期初＋淨變動＝期末。
11. **凍結與重演**：改動現行政策／分類集合／映射後，舊 run 重演結果與雜湊不變；
    新 run 才採新版本。**反證：重演時回查現行主檔 → 轉紅。**
12. **結果雜湊涵蓋來源證據**：只改映射規則而金額不變時，雜湊必須改變。
13. **跨租戶與跨案件**：政策、分類集合、映射、例外、來源 run 的父鏈全驗
    （比照 0032）；跨租戶與同租戶跨案件各一條負面測試。
14. **不越界**：本刀不產生任何「現金流量表」實體；輸出型別只有支持資料列。
15. 完整測試一輪全綠；既有斷言一字不改。

## 十、風險

**第一級。** 四個真正的風險：

1. **從收集滑向重建**——一旦系統替未分類金額補上分類，P0 就變成 P1，
   而輸出會被當成報表使用。緩解：無預設分類、驗收 6 的反證、§一的邊界表。
2. **粒度不足被靜默接受**——「拿不到 JOURNAL 就當 ACCOUNT 用」會讓支持資料
   看起來完整。緩解：INV-23 的 fail closed ＋ 逐分類的批准例外 ＋ 輸出標記。
3. **控制總額不勾稽**——分類標籤加總與財務資料對不上時仍輸出。
   緩解：K1～K4 與 `output_capability = NONE` 的處理。
4. **第二套凍結與重演**——另立一套 run／manifest 會產生兩份「可重演」實作。
   緩解：§六與§七的重用決定（待走查拍板）。

實作順序（契約確認後）：
migration（`CashFlowPolicyVersion` → `CashFlowClassSetVersion` ＋ 分類 →
`CashFlowMappingVersion` ＋ 規則 → `CashFlowCoverageException` →
`calculation_scope` 擴充與 manifest 新條目 → 支持資料列 →
完整度與控制總額判定函式 → 期間級就緒判定）
→ DB 負面測試（1～9、13）→ Case-001 的正控制與控制總額勾稽（10）
→ 凍結與重演（11／12）→ 完整一輪。**畫面不在本刀。**
