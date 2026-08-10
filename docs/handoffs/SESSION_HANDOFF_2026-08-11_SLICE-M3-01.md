# SESSION HANDOFF　2026-08-11　SLICE-M3-01 B-02 期間工作台

基準：`4053404`（已 push，工作區乾淨）｜完整測試 **858/858**（單元 66、DB 整合 365、
端到端 427）｜29 份 migration。

切片文件：`docs/slices/SLICE-M3-01_期間工作台.md`（走查修訂後定稿，風險中低）。

## 這一刀做了什麼

期間狀態機（0022）在里程碑 2 已是**能力完整、入口缺席**：13 個狀態、角色矩陣、
覆核覆蓋評估、fail closed 全部就緒，使用者卻只能用 `POST /period/transition` 打它。
本刀補上 `GET /b02?revision=…`，整條流程第一次以**期間**串起來，不新增控制面。

### 0028　遷移規格的唯一可查詢來源

0022 把合法遷移表與角色矩陣寫在 trigger 的 `CASE`／`IF` 裡。對 DB 沒有問題——它本來
就是唯一裁決點——但畫面無從得知「這一期現在能做什麼」。若堅持無 migration，工程最後
只能在 TypeScript 重寫一次，正好違反本刀最重要的原則。

    fn_period_transition_spec(from_status) 唯讀
      → requested_to, required_role, availability, unavailable_code, unavailable_reason

trigger 改為呼叫它，B-02 讀同一份。**不是新增控制，是換存放形式**——既有期間測試
（DB 29＋端到端 37）斷言一字未改全綠，即為回歸判準。

**`required_role` 對 `NOT_IMPLEMENTED` 的列一律 NULL。** 守衛都還沒實作，「誰可以發起」
當然也還沒決定；填一個角色等於憑空發明規則，而且會讓角色檢查搶在 fail closed 之前
觸發——0022 對那些遷移本來就沒有角色檢查。（實作時我先填了角色，被既有測試擋下。）

### 0029　期間發起人的角色作用域（走查後追加）

0022 起的角色驗證寫成：

```sql
AND (ra.engagement_id IS NULL OR ra.engagement_id = v_eng)
```

`IS NULL` 分支把**租戶層指派**當成對所有案件有效。租戶層 R4 因此能直接 POST 推動任何
案件的期間——**畫面擋得住，DB 擋不住**，而 DB 才是唯一裁決點。B-02 的整頁 403 只是讓
這個洞不容易被點到。

0029 以 `CREATE OR REPLACE` 改為嚴格相等 `ra.engagement_id = v_eng`（**不改寫 0028**）。
這不是收緊政策：§26.3 明定 R1～R5、R7 屬 EngagementAssignment，遷移用的 R2／R4 都在
其中，未指定案件的指派對期間遷移本就沒有意義。代碼仍為 `ACTOR_ROLE_NOT_HELD`。

同時 `REVOKE ALL ON FUNCTION … FROM PUBLIC` 再 GRANT：PostgreSQL 預設把新函式的
EXECUTE 授予 PUBLIC，0028 只寫了 GRANT，「只有 app_runtime 可執行」在實況上並不成立。
該函式只回常數，不構成資料外洩，但**權限敘述必須與實況一致**——否則下一份唯讀函式
就會沿用同一個錯誤模板。實測 `proacl = {dev=X/dev,app_runtime=X/dev}`。

### 授權

完整 B-02 為**案件層 R2／R3／R4**。**R1 排除**——§24.6 註③限制「R1 僅看得到自身提交
狀態，非期間全貌」；讓 R1 看到期間狀態、阻擋項與全部調整／計算數量會越過該限制。
R1 維持 B-00 與上傳入口；**本刀不另建 R1 精簡版**（要做是獨立一刀，且需先想清楚
「自身提交狀態」的邊界）。

B-00 補上 B-02 入口（超出切片範圍表，但入口缺席正是本刀的理由），可見範圍與 B-02
授權**同一組角色**——用比 B-02 寬的角色列出期間，等於在 B-00 洩漏 B-02 擋掉的東西。

## 反證（每一條都實測轉紅後還原）

| # | 反轉的條件 | 轉紅 |
|---|---|---|
| 1 | 作用域併回租戶層（`engagementRolesOf ∪ tenantRolesOf`） | 端到端 9 條 |
| 2 | 「下一步」改成在 TypeScript 列出全部 13 狀態 | 端到端 11 條 |
| 3 | B-00 期間清單放寬到 R1 | 端到端 1 條 |
| 4 | 拿掉 CONDITIONAL 條件判定／把條件反向 | 端到端 1、2 條 |
| 5 | 0029 的作用域改回 `IS NULL` 分支 | 端到端 7 條、DB 3 條 |

## 兩個可重用的教訓

**一、CONDITIONAL 只有條件成立時才該畫成不可用。**
實機走查抓到：首期的 `SETUP → OPEN` 按鈕可用，畫面卻同時印「非首期…本版不可用」。
對可用功能謊稱不存在，與把未實作畫成可點是**同一種錯，只是方向相反**。修正後兩個
分支各有測試，並各以 DB 的實際結論對照（首期真的走得過去、非首期真的 `G10`）。

**二、DB 整合套件會重建資料庫並重跑 migration。**
第一次做 0029 的反證時我直接改資料庫裡的函式，DB 套件仍 31/0 ——`fx_reset` 把嚴格版
從檔案重新裝回去了。**反證必須改 migration 檔案本身**，否則是假綠。

## 測試

| 套件 | 條數 | 備註 |
|---|---|---|
| `tests/acceptance/period-workbench.test.ts` | **61** | 本刀新增 |
| `tests/integration/db/period.test.sh` | 31 | +2（0029 作用域） |
| `tests/acceptance/period-lifecycle.test.ts` | 37 | 斷言未改，證明 0028／0029 未改變行為 |

`period-workbench` 的關鍵設計：

- **逐 13 狀態**把畫面所列的「下一步」與 `fn_period_transition_spec` **完全比對**。
  多列一個或少列一個都轉紅——這是防「TypeScript 第二份遷移表」的主釘子。
- **繞道測試用「角色種類正確、作用域錯誤」的樣本**（租戶層庚 R3、辛 R2、己 R4）。
  只用「案件層 R4 用錯角色」證明的是角色矩陣，不是作用域。
- **負面測試先斷言前置成立**：租戶層 R2 的 `OPEN → IN_PREPARATION` 案例先建立完整 TB
  前置並斷言 count = 1、畫面不再顯示該未達成條件，再以**案件層 R2 的正控制**走通同一條
  遷移，證明拒絕理由不是 G-01。前置用完拆除並斷言回復。
- 前置批次的 `data_coverage` 必須在批次 `ACCEPTED` **之前**寫入（已接受的批次來源集合
  已封存）；拆除時 `data_coverage` append-only、`import_batch` 身分凍結，兩者都得明確
  停用觸發器——這正是「不可變事實」該有的阻力。

## 下一刀：MVP 3 折算與對帳（第一級風險）

**先寫事前契約，契約確認後才寫 migration，不先做畫面。** 契約至少須凍結：

1. **幣別角色**：`ReportingUnitCurrencyAssignment`（role × currency × 有效期間 × 批准），
   INV-22 同一時點只能有一個 `FUNCTIONAL`；`ReportingUnit.current_functional_currency`
   僅為快取，不是歷史真相（D-26-06）。
2. **匯率版本**：`ExchangeRate`（來源、`rate_type` 期末／期中／歷史、幣別對、日期、版本），
   版本隨期間鎖定凍結；G-07「匯率版本未指定或未凍結」擋整期折算。
3. **折算方法**：資產負債採期末、損益採期中或合理近似、部分權益採歷史（手冊 §233-238）。
4. **金額精度與尾差**：`ROUNDING_TOLERANCE` 不是財務重要性（D-26-05）；INV-24 要求
   單筆與**同期間 × 同幣別 × 同折算 run 的累積**容許值同時滿足。
5. **CTA 顯式物化**：INV-20——不得由兩幣別金額相減推導，必須是
   `PostingLayer = TRANSLATION_ADJUSTMENT` 的顯式分錄，帶 `rule_type` 與 `translation_run_id`。
6. **CalculationRun 凍結集合與重演**：AC-FX-001「指定實體、期間與匯率版本重跑結果一致；
   每個折算數字可追到來源、類型與日期，折算差額可勾稽」。既有 `CalculationInputManifest`
   必須把 CurrencyAssignment 與 ExchangeRate 版本納入凍結集合。

另：INV-19「同一 SnapshotLine 下每個 `amount_role` 至多一筆 TranslationResult」；
`TranslationResult.source_amount_ref` 必須指向被折算的來源金額，使折算可反查。
