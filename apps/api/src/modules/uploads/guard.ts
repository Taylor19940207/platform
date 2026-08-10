// 上傳的授權與歸屬驗證。
//
// 兩個既有缺口在此一併封住（皆非拆層造成，舊 validateContext 即如此）：
//
// 1. **授權把租戶層角色也算進去**（`engagement_id IS NULL OR = :e`），而且只問
//    「有沒有任何角色」。R6 或租戶層 R1／R2 只要知道案件 UUID 就能呼叫 /upload。
//    改為只接受該案件**明確指派**的 R1／R2（§24.6 ImportBatch 列的 C）。
//
// 2. **只驗「法人與期間都屬同案件」**，沒驗期間的 ReportingUnit 究竟是哪個法人。
//    同一案件有多個法人時（Case-001 就有兩個），可以把 A 法人的 TB 掛到
//    B 法人的期間——四層歸屬看似一致，實際錯配。
//    改為逐層驗到 ReportingUnit.legal_entity_id 等於所選法人。
import { query } from "../../../../../packages/database/src/psql.ts";
import type { Session } from "../../../../../packages/auth/src/session.ts";
import { engagementRolesOf, tenantRolesOf } from "../engagements/access.ts";

/** §24.6 ImportBatch 列：建立與提交為 R1（限被指派範圍）與 R2。 */
export const UPLOAD_ROLES = ["R1", "R2"] as const;

export type UploadCheck =
  | { ok: true; roles: Set<string> }
  | { ok: false; code: "ROLE_REQUIRED" | "CONTEXT_MISMATCH"; reason: string;
      engagementRoles: string[]; tenantRoles: string[] };

export function checkUpload(s: Session, engagementId: string, legalEntityId: string,
                            periodRevisionId: string): UploadCheck {
  const roles = engagementRolesOf(s, engagementId);
  const tenant = [...tenantRolesOf(s)].sort();
  if (!UPLOAD_ROLES.some((x) => roles.has(x))) {
    return { ok: false, code: "ROLE_REQUIRED",
      reason: `上傳需本案件的 ${UPLOAD_ROLES.join("／")} 角色（§24.6 ImportBatch 列 C）`,
      engagementRoles: [...roles].sort(), tenantRoles: tenant };
  }
  // 四層歸屬一次驗到底：租戶（RLS）→ 案件 → 法人 → 期間的報告單位。
  // 關鍵是最後兩個條件——ReportingUnit 必須是 LEGAL_ENTITY 型別，
  // 且其 legal_entity_id 就是所選法人。少了它們，同案件跨法人錯配驗不出來。
  const n = query<{ n: string }>(
    `SELECT count(*) AS n
       FROM period_revision pr
       JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
       JOIN reporting_unit ru ON ru.reporting_unit_id = rp.reporting_unit_id
       JOIN legal_entity le ON le.legal_entity_id = :'le'::uuid
      WHERE pr.period_revision_id = :'pr'::uuid
        AND le.engagement_id = :'e'::uuid
        AND rp.engagement_id = :'e'::uuid
        AND ru.engagement_id = :'e'::uuid
        AND ru.unit_scope = 'LEGAL_ENTITY'
        AND ru.legal_entity_id = le.legal_entity_id`,
    { pr: periodRevisionId, le: legalEntityId, e: engagementId }, { tenantId: s.tenantId });
  if (Number(n[0]?.n) !== 1) {
    return { ok: false, code: "CONTEXT_MISMATCH",
      reason: "物件與 Engagement 不一致（法人、期間與該期間的報告單位必須指向同一法人）",
      engagementRoles: [...roles].sort(), tenantRoles: tenant };
  }
  return { ok: true, roles };
}
