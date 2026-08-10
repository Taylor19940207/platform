# SESSION HANDOFF 2026-08-10　Route／Service 拆層與六類授權缺口封閉

HEAD `2e19c9b`（已 push）。**764/764** 全綠（單元 58／DB 整合 357／端到端 349）。
24 份 migration。`apps/api/src/server.ts` **2,018 → 54 行**。

## 這一輪做了什麼

把 API 從單一巨型 handler 拆成模組化單體。**拆層本身不是目的**——目的是讓
「授權在哪裡判斷」變成看得見的事。舊結構有一個萬用守衛 `b04Guard` 同時替映射、
調整、計算與證據包授權，而且用「案件層 ∪ 租戶層」的聯集；六類既有授權缺口
就藏在那個聯集裡，拆層過程才逐一顯形。

順序（每一刀獨立提交、獨立驗證）：

| Commit | 內容 |
|---|---|
| `89552b8` | Period 試點（只搬 `/period/transition`），建立樣板 |
| `da03268` | Adjustment（access／service／routes 四小步） |
| `c2bea3f` | 權限硬化：R1／R6 不得讀 Adjustment；`rolesOf` 移出 Adjustment |
| `4e1efae` | 權限硬化：作用域——租戶層角色不得隱式讀取任一案件 |
| `34a05ba` | ImportBatch 事實存取 ＋ `/b05/create` 逐動作授權 |
| `3e5ba2a` | Mapping ＋ 逐動作授權（`/b04/submit` 安全修補） |
| `f9daa6a` | B-06 ＋ 歸屬由 CalculationRun 反查 |
| `b5c276f` | B-07 ＋ `b04Guard`／`allAssignedRolesOf` 退休 |
| `5f0b176` | B-03 身分確認 |
| `3934bca` | 上傳 ＋ 兩缺口 ＋ **migration 0024** |
| `2e19c9b` | B-00 三層授權 ＋ `/admin/jobs` ＋ provided_by |

## 封閉的六類既有授權缺口

全部**非拆層造成**，全部有反證過的負面測試。

1. **R1／R6 可讀 Adjustment**——`b05Guard` 只判 `roles.size > 0`，而 `rolesOf`
   含租戶層指派，R6 必然通過。§24.6 L449 明定兩者為「–」。
2. **租戶層 R2／R3／R4 可跨案件讀寫**——聯集查詢讓租戶層角色取得該租戶
   所有案件的資料。`engagementRolesOf`／`tenantRolesOf` 拆開，聯集函式刪除。
3. **`/b04/submit` 完全沒有角色檢查**——只過萬用守衛就寫
   `mapping.review_ready`。R1、R6、租戶層角色都能送出映射覆核。
4. **B-06／B-07 信任請求附帶的 batch**——可拿自己有權的案件批次去換別的案件的
   run／package。改為 `runGate`／`packageGate` 沿父鏈反查歸屬。
5. **`/upload` 把租戶層角色算進授權**——知道案件 UUID 即可上傳。
6. **同案件跨法人錯配**——只驗「法人與期間都屬同案件」，沒驗該期間的
   ReportingUnit 是哪個法人。Case-001 同案件就有兩個法人。
   應用層 ＋ **migration 0024 DB 守衛**雙層。

## 驗證紀律（比修補本身更值得記住）

**只加負面測試不夠。** 反證用的使用者必須是「角色種類正確、作用域錯誤」的樣本：
一開始 B-06 的測試用 R1／R6／租戶層 R4，三者**連白名單都不在**，因此把作用域
改回聯集時它們不會轉紅——作用域根本沒被釘住。種子因此新增租戶層庚（R3）與
辛（R2），它們的角色在白名單內、只有範圍錯，才能真正反證。

每個授權修補都以「反轉該條件後測試必須轉紅」實測過，紀錄在各 commit message。

## 分層契約

    route     讀表單、從 Session 取身分、呼叫 guard／service、轉成 HTTP
    guard     逐動作授權（案件層）＋ 歸屬反查；拒絕時寫 CVA
    service   交易編排；不 import node:http 型別、不產生 HTML；
              未知 DB 錯誤**原樣上拋**，不偽裝成 409
    access    事實讀取，不含授權結論
    DB        RLS、SoD、狀態機、不變條件的最終裁決——**不搬進 TypeScript**

不加 Repository 層：現有 SQL 與 DB 守衛是控制的本體，多包一層泛型只會隱藏交易邊界。

授權原則：`engagementRolesOf()` 只查 `engagement_id = :e`，`tenantRolesOf()` 只查
`IS NULL`，**不得聯集**。CVA 分開記錄 `engagement_roles` 與 `tenant_roles`。

## 拆層期間犯的錯（同類會再犯，先記下來）

- **模組 import 深度寫錯三次**（`../` 層數）。`node --check` 抓不到——那是執行期
  解析。改為每建一個新模組檔就先起 API 打 `/health`，不等測試。
- **搬函式漏搬相依**：`randomUUID`、`cents` 漏 import；`b06Refuse` 原本閉包在
  請求層的 `s` 上，移到模組層後 `s` 不存在（ReferenceError → 500 而非 409）。
  語法檢查對兩者都無感；靠各模組自己的端到端套件抓到。
- **差點製造假綠**：新測試插在既有 CVA 增量斷言之前，讓那個 `+1` 變成 `+2`，
  測試會以**錯誤理由**變紅。增量斷言會被後插的測試污染。

## 不做的事

- **P2「DB 守衛例外 → HTTP 狀態的統一映射」現在不做**（BACKLOG 已合併為單一條目）。
  資料安全已有 DB 防線，缺陷只在極窄併發下回 500 而非 409。要做就得同時替多個
  DB 函式補穩定代碼、建共用解析器並補多條競態測試，等於再開一輪基礎設施收尾。
  等真正需要統一錯誤邊界時一次做完，未知錯誤仍維持 500。
- **不再為了行數繼續拆分**。server.ts 54 行已達目標。

## 下一刀

**自動保存、儲存狀態與 Session 恢復**（NFR-UX-001／NFR-INT-002）——
里程碑 2 離開盤點的**最後一個阻擋項**。範圍限定 B-05 Adjustment 草稿，
不做全平台通用編輯框架；驗證完成後再擴到映射草稿。
完成後重跑 `docs/reviews/MILESTONE-2_EXIT_REVIEW.md`。

`cbfc_dev` 已還原種子。跑 `pnpm test` 前務必先停 `pnpm dev`。
