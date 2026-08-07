# SESSION HANDOFF — SLICE-M2-05 期間生命週期（2026-08-07）

> **狀態：已完成**（594/594 連續兩輪全綠）。
> 契約：`docs/slices/SLICE-M2-05_期間生命週期.md`（走查兩輪收緊後定稿）。

## 本次完成

`PeriodRevision` 的狀態機由**四值簡化**擴為 §25.8 的**完整 13 值**，
並讓已有控制證據的遷移真正由期間狀態驅動。

```
SETUP → OPEN → IN_PREPARATION → IN_REVIEW → ADJ_APPROVED
                                    ↕
                            AWAITING_REVIEWER（由覆蓋評估決定落點）
```

`CALCULATING` 之後的所有主線遷移 **fail closed**。

## 動工前實查到的既成事實

`period_revision.status` 的 CHECK 只允許 `SETUP／OPEN／LOCKED／REOPENED`——
**`OPEN→LOCKED` 的簡化不是風險，是已經寫死在 DB 裡的事實**。
而且 `DEFAULT 'OPEN'`：新建 revision 直接跳過 `SETUP`，繞開 R4 與 G-10。
另外沒有任何遷移守衛，應用層也完全不驅動期間狀態。

## migration 0022 的結構性封口

「唯一裁決點」不只是把規則寫進 trigger，還必須封掉所有繞道。以下七項**全部先以
實測重現、修完再以同一組探測驗證**：

| # | 繞道 | 封法 | 代碼 |
|---|---|---|---|
| 1 | 只有 UPDATE trigger，`INSERT status='DELIVERED'` 跳過狀態機 | INSERT 守衛：只能 SETUP、`revision_no=1`、該期間尚無其他修訂、與父期間同租戶 | `PERIOD_INSERT_MUST_BE_SETUP`／`REVISION_CHAIN_NOT_IMPLEMENTED` |
| 2 | `revision_no`／`tenant_id` 未凍結 | 身分欄位**無條件**凍結（不論狀態是否變動） | `REVISION_IDENTITY_IMMUTABLE` |
| 3 | 相信呼叫者傳的角色；`app_runtime` 可自行 `set_config` 後直接 UPDATE | DB 自查 `role_assignment`；`REVOKE UPDATE, DELETE ON period_revision FROM app_runtime` | `ACTOR_ROLE_NOT_HELD`／`permission denied` |
| 4 | `IN_REVIEW → AWAITING_REVIEWER` 可直接指定 | `AWAITING_REVIEWER` 從合法目標中完全移除，只能由覆蓋評估改寫落點 | `ILLEGAL_TRANSITION` |
| 5 | Evaluation 只指向可變現況、且可直接 INSERT 偽造 | 複製角色指派快照值；撤回寫入權只留 SECURITY DEFINER；結果一致性 CHECK ＋ 父物件歸屬 trigger | `permission denied`／CHECK |
| 6 | 遷移未寫 DomainEvent | `period.transitioned` 在同交易寫入（`from`／`requested`／`landed`） | — |
| 7 | 後段只有 G-07，其餘回 `ILLEGAL_TRANSITION` | 合法遷移表補完後段，各自回自己的代碼 | `G07`／`RECONCILE`／`G03`／`G06`／`G09_NOT_IMPLEMENTED` |

### 第二輪複核再找到的三個 P1

**跨租戶（已實測可利用）**：`dev` 是 superuser 且 `bypassrls=true`，
`SECURITY DEFINER` **完全繞過 RLS**（`FORCE ROW LEVEL SECURITY` 對 superuser 無效）。
以 T1 的 session 帶 T2 的 revision UUID 與 T2 的 R4，成功把 T2 的期間推到 `OPEN`。
修法：兩個函式各自比對 `current_tenant()`、固定 `SET search_path`、
`REVOKE ALL FROM PUBLIC`（`CREATE FUNCTION` 預設授權 PUBLIC，配 SECURITY DEFINER
等於人人可用 owner 權限執行）、helper 不授權 `app_runtime`。

**假 revision 鏈**：INSERT 只檢查 SETUP，仍可建 `revision_no=99`、同期間多條修訂、
與父期間不同租戶。

**併發與假事件**：先 SELECT 後 UPDATE 無鎖、無 expected state；
同狀態請求 trigger 直接放行但函式仍寫一筆假事件。
修法：`p_expected_from` ＋ `SELECT ... FOR UPDATE` ＋ `OPTIMISTIC_LOCK_CONFLICT`／
`NO_OP_TRANSITION`，兩者都不寫成功事件。

**第三輪再補**：`DELETE` 同屬繞道——尚無子資料的修訂可被直接刪除，
既有 DomainEvent 會留下孤立引用。已 `REVOKE DELETE`。

## 責任邊界

- **API 證明「呼叫者是誰」**：`p_actor` 一律取自登入 Session，**不接受請求自帶 actor**。
- **DB 證明「這個人是否真的持有該角色、並允許這次遷移」**。

DB 無法證明呼叫者本人就是 `p_actor`（所有連線共用 `app_runtime`）——
這條界線寫在 migration 檔頭，不假裝 DB 能做身分認證。

## 其他凍結語意

- **首期以顯式欄位保存**：`reporting_period.is_initial_period` ＋ partial unique index。
  用「目前最早日期」推導會在補進歷史期間時**翻案過去的判定**。
  ⚠️ 已知偏差：基線 §26 L1120 的 `CalendarUsage(purpose=GROUP_REPORTING)` 現行 schema
  不存在，故唯一約束只能落在 `(reporting_unit_id, fiscal_calendar_id)`；落地後須收窄。
  另註明 `period_kind='OPENING'` **不等於** `is_initial_period`。
- **期間日期凍結**：`start_date`／`end_date`／`period_kind` 建立後不可變更——
  `end_date` 是 M2-01 映射生效日的判定基準，改動會追溯改變「當時採用哪一版映射」。
- **`OPEN` 的離開條件**：至少一份 `ACCEPTED ＋ BALANCE ＋ COMPLETE` 的批次。
  `COMPLETE` 由提供者在檔案內 `#completeness=COMPLETE` 顯式聲明且受 file hash 涵蓋
  （02C「完整度不推定」），不由 G-01 平衡反推。
- **零調整期間視為覆蓋完整**，直接進 `IN_REVIEW`，不卡 `AWAITING_REVIEWER`。
- **`PREVIEW_ONLY`／`REOPENED` 只保留狀態值**，本刀只驗不得被任意跳入。
  未來重開須建立新 `PeriodRevision`（`revision_no+1`），不得原地修改。

## 實作期間由測試抓到的兩個 production bug

1. **`extractDbCode` 把 `ERROR` 自己當成代碼**（regex 的 `^` 分支先命中）。
   後果：`httpStatusForCode("ERROR")` 落到 default **409**，於是 deadlock、
   UUID 語法錯誤等未知故障全被回報成業務衝突，**永遠不會出現 500**。單元測試抓到。
2. **改完後又把 `CONTEXT:` 當成代碼**。psql 實際字串是
   `Error: psql: ERROR:  CODE: 說明`——`Error:` 與 `psql:` 前綴沒被剝掉，
   比對落到第二行的 `CONTEXT:`。端到端抓到；單元測試沒抓到是因為餵了理想化字串。
   修法：逐層剝除前綴到穩定，並排除 psql 欄位標籤清單。

## 測試

**594/594，EXIT=0**（單元 58、DB 整合 255、端到端 281），連續兩輪一致。
相對基準 520 零退化：單元 +8、DB +29、端到端 +37。

事件計數一律採「本次操作前後增量」——`audit_event` 是 append-only，
`db:seed` 也不清，全庫總數會被先前測試污染。

## 2026-08-07 Case-001 走查

| # | 操作 | 結果 |
|---|---|---|
| 前置 | 上傳 2026-03 TB、接受、15 條映射批准 | ACCEPTED／COMPLETE／15 條 |
| 1 | 丁（僅 R6）冒充 R4 開期 | 403 `ACTOR_ROLE_NOT_HELD` |
| 2 | 乙以 R2 開期 | 403 `ROLE_NOT_PERMITTED` |
| 3 | 乙以 R4 開期 | 200 → `OPEN` |
| 4 | 重送同一請求 | 409 `OPTIMISTIC_LOCK_CONFLICT` |
| 5 | 甲 R2 → IN_PREPARATION | 200 → `IN_PREPARATION` |
| 6 | 甲 R2 → IN_REVIEW（零調整） | 200 → `IN_REVIEW`；評估 `scope=0 covered=true` |
| 7 | 乙 R4 → ADJ_APPROVED | 200 → `ADJ_APPROVED` |
| 8 | → CALCULATING | 409 `G07_NOT_IMPLEMENTED` |
| 9／10 | 跳入 PREVIEW_ONLY／REOPENED | 409 `ILLEGAL_TRANSITION` |
| 11 | 本次新增 `period.transitioned` | **4**（＝4 次成功遷移，無假事件） |

## 尚未做

`PREVIEW_ONLY`／`REOPENED` 的進出路徑、`CALCULATING` 之後各段（待 G-07／G-03／
G-06／G-09 能力就緒）、`RequiredDataPolicy` 版本化、`CalendarUsage`。

## 下一步（依里程碑 2 離開複核順序）

1. 多基礎／四類規則最小資料模型。
2. 自動保存／儲存狀態／Session 恢復（NFR-UX-001 為阻擋項）。
3. 重跑里程碑 2 離開複核 → 稅理士批准／正式交付 → 折算（MVP 3）。
