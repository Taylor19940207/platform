// 案件層的角色事實：「這個人在這個案件持有哪些角色」。
//
// 放在 engagements 而非任何單一物件模組：角色是 Engagement 的事實，
// 不屬於調整、映射或匯入。留在 adjustments/ 的話，Mapping、Import、Evidence
// 之後都會反向依賴 Adjustment 模組。
//
// **本檔不做裁決**：回傳的是持有清單，能不能讀寫某個物件由各模組依
// §24.6 權限矩陣自行以白名單判斷——「有任何角色」不等於「有這個物件的權限」。
import { query } from "../../../../../packages/database/src/psql.ts";
import type { Session } from "../../../../../packages/auth/src/session.ts";

export function rolesOf(s: Session, engagementId: string): Set<string> {
  return new Set(query<{ role: string }>(
    `SELECT role FROM role_assignment
      WHERE user_id = :'u'::uuid AND revoked_at IS NULL
        AND (engagement_id IS NULL OR engagement_id = :'e'::uuid)`,
    { u: s.userId, e: engagementId }, { tenantId: s.tenantId }).map((r) => r.role));
}
