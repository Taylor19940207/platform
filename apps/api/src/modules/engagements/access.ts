// 案件層的角色事實：「這個人在這個案件持有哪些角色」。
//
// 放在 engagements 而非任何單一物件模組：角色是 Engagement 的事實，
// 不屬於調整、映射或匯入。留在 adjustments/ 的話，Mapping、Import、Evidence
// 之後都會反向依賴 Adjustment 模組。
//
// **本檔不做裁決**：回傳的是持有清單，能不能讀寫某個物件由各模組依
// §24.6 權限矩陣自行以白名單判斷——「有任何角色」不等於「有這個物件的權限」。
//
// ── 為什麼要分成三個函式 ────────────────────────────────────
// §26.3 明定 R1～R5、R7 屬 `EngagementAssignment`（案件層），
// R6／R8-Tenant／R9 屬 `TenantMembership`（租戶層）。兩者是不同的授權範圍，
// 混在一個 `rolesOf()` 裡（`engagement_id IS NULL OR engagement_id = :e`）會讓
// 「租戶層被授予 R2／R3／R4」隱式取得**該租戶所有案件**的客戶資料——
// Tenant 內的每個 Engagement 都必須明示授權，不得由租戶層角色推導。
//
// 因此：業務物件一律用 engagementRolesOf()；技術／治理面才用 tenantRolesOf()。
//
// 歷史：曾有一個 rolesOf()／allAssignedRolesOf() 回傳兩者聯集，讓租戶層角色隱式
// 取得客戶資料，且六個 B-04 動作共用同一份授權判斷。B-04／B-06／B-07 全部改為
// 逐動作、案件層授權後，該函式已無使用者，於本刀刪除。
import { query } from "../../../../../packages/database/src/psql.ts";
import type { Session } from "../../../../../packages/auth/src/session.ts";

/** 案件層授權（EngagementAssignment）。業務物件的權限判斷一律用這個。 */
export function engagementRolesOf(session: Session, engagementId: string): Set<string> {
  return new Set(query<{ role: string }>(
    `SELECT role FROM role_assignment
      WHERE user_id = :'u'::uuid AND revoked_at IS NULL
        AND engagement_id = :'e'::uuid`,
    { u: session.userId, e: engagementId }, { tenantId: session.tenantId }).map((r) => r.role));
}

/** 租戶層授權（TenantMembership）。技術與治理用途；**不得**據以存取客戶業務資料。 */
export function tenantRolesOf(session: Session): Set<string> {
  return new Set(query<{ role: string }>(
    `SELECT role FROM role_assignment
      WHERE user_id = :'u'::uuid AND revoked_at IS NULL
        AND engagement_id IS NULL`,
    { u: session.userId }, { tenantId: session.tenantId }).map((r) => r.role));
}
