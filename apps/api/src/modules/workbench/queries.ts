// B-00 個人工作台的讀模型。
//
// 三層分開，不再用單一 bizEng 同時決定所有事情：
//   1. **資料可見性**：哪些案件的資料可以出現在這個區塊
//   2. **動作權限**：哪些按鈕／連結可以渲染（後端仍會再判一次）
//   3. **待辦條件**：SOD-01／AC-WFL-001／SOD-02 等物件層條件
//
// 混成一份時，「有任何業務角色」就會同時決定看得到什麼與能做什麼——
// R1 因此看得到調整待辦，R4 因此看得到上傳表單。
import { query } from "../../../../../packages/database/src/psql.ts";
import type { Session } from "../../../../../packages/auth/src/session.ts";

export interface Eng { engagement_id: string; name: string }

/** 案件層指派（engagement_id 明確匹配、未撤銷）。租戶層指派一律不計入。 */
export interface Scope {
  /** role → 該角色被明確指派的案件 */
  byRole: Map<string, Eng[]>;
  /** 批次狀態清單的可見範圍：R1／R2／R3／R4／R7 */
  visible: Eng[];
  has(engagementId: string, ...roles: string[]): boolean;
  any(...roles: string[]): boolean;
}

const ROLES = ["R1", "R2", "R3", "R4", "R5", "R7"] as const;

export function scopeOf(s: Session): Scope {
  const rows = query<{ role: string; engagement_id: string; name: string }>(
    `SELECT ra.role, ce.engagement_id, ce.name
       FROM role_assignment ra
       JOIN client_engagement ce ON ce.engagement_id = ra.engagement_id
      WHERE ra.user_id = :'u'::uuid AND ra.revoked_at IS NULL
        AND ra.engagement_id IS NOT NULL
      ORDER BY ce.name`,
    { u: s.userId }, { tenantId: s.tenantId });
  const byRole = new Map<string, Eng[]>();
  for (const r of ROLES) byRole.set(r, []);
  const seen = new Set<string>();
  for (const r of rows) {
    const list = byRole.get(r.role);
    if (!list) continue;                       // R6 等租戶層／技術角色不進工作台
    if (!seen.has(`${r.role}|${r.engagement_id}`)) {
      seen.add(`${r.role}|${r.engagement_id}`);
      list.push({ engagement_id: r.engagement_id, name: r.name });
    }
  }
  // R5 暫不進工作台資料：其唯讀以尚未落地的「審計師授權範圍」為界。
  const visibleRoles = ["R1", "R2", "R3", "R4", "R7"];
  const vis = new Map<string, Eng>();
  for (const r of visibleRoles) for (const e of byRole.get(r) ?? []) vis.set(e.engagement_id, e);
  const has = (eng: string, ...roles: string[]) =>
    roles.some((r) => (byRole.get(r) ?? []).some((e) => e.engagement_id === eng));
  return {
    byRole, visible: [...vis.values()].sort((a, b) => a.name.localeCompare(b.name)),
    has, any: (...roles) => roles.some((r) => (byRole.get(r) ?? []).length > 0),
  };
}

/** SQL IN 清單。空集合以不存在的 UUID 表示——**不得**退化成「不加條件」。 */
const inList = (rows: Eng[]): string =>
  rows.length ? rows.map((r) => `'${r.engagement_id}'`).join(",")
              : "'00000000-0000-0000-0000-000000000000'";
export const engIn = (sc: Scope, ...roles: string[]): string =>
  inList([...new Map(roles.flatMap((r) => (sc.byRole.get(r) ?? [])
    .map((e) => [e.engagement_id, e] as const))).values()]);

// ── 佇列 1：待身分確認（R2） ──
export const pendingIdentity = (s: Session, sc: Scope) =>
  query<Record<string, string>>(
    `SELECT ib.import_batch_id, ib.batch_version, ce.name AS client, le.name AS entity,
            rp.label AS period, ib.status
       FROM import_batch ib
       JOIN client_engagement ce ON ce.engagement_id = ib.engagement_id
       JOIN legal_entity le ON le.legal_entity_id = ib.declared_legal_entity_id
       JOIN period_revision pr ON pr.period_revision_id = ib.declared_period_revision_id
       JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
      WHERE ib.identity_status = 'PENDING_CONFIRMATION' AND ib.status = 'VALIDATED'
        AND ib.engagement_id IN (${engIn(sc, "R2")})
      ORDER BY ib.created_at DESC`, {}, { tenantId: s.tenantId });

const adjQ = (s: Session, where: string, engInList: string) =>
  query<Record<string, string>>(
    `SELECT a.adjustment_id, a.title, a.status, ce.name AS client, ru.name AS entity,
            rp.label AS period, last.reason_category
       FROM adjustment a
       JOIN client_engagement ce ON ce.engagement_id = a.engagement_id
       JOIN period_revision pr ON pr.period_revision_id = a.period_revision_id
       JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
       JOIN reporting_unit ru ON ru.reporting_unit_id = rp.reporting_unit_id
       LEFT JOIN LATERAL (SELECT milestone, reason_category
              FROM adjustment_version_snapshot v WHERE v.adjustment_id = a.adjustment_id
             ORDER BY v.business_version DESC, v.occurred_at DESC LIMIT 1) last ON true
      WHERE ${where} AND a.engagement_id IN (${engInList})
      ORDER BY a.updated_at DESC`, {}, { tenantId: s.tenantId });

/** 佇列 2：待覆核（R3；SOD-01 不含自己編製）。 */
export const pendingReview = (s: Session, sc: Scope) =>
  adjQ(s, `a.status = 'PENDING_REVIEW' AND a.prepared_by <> '${s.userId}'`, engIn(sc, "R3"));

/** 佇列 3：待批准（R4；AC-WFL-001 ≠編製人 ∧ SOD-02 ≠覆核人）。 */
export const pendingApproval = (s: Session, sc: Scope) =>
  adjQ(s, `a.status = 'PENDING_APPROVAL' AND a.prepared_by <> '${s.userId}'
           AND a.reviewed_by <> '${s.userId}'`, engIn(sc, "R4"));

/** 佇列 4：被退回（本人編製、DRAFTING、最新里程碑 RETURNED）。 */
export const returned = (s: Session, sc: Scope) =>
  adjQ(s, `a.status = 'DRAFTING' AND a.prepared_by = '${s.userId}'
           AND last.milestone = 'RETURNED'`, engIn(sc, "R2", "R3", "R4"));

/** 佇列 5a：本人的調整草稿。 */
export const draftAdjustments = (s: Session, sc: Scope) =>
  adjQ(s, `a.status = 'DRAFTING' AND a.prepared_by = '${s.userId}'`, engIn(sc, "R2", "R3", "R4"));

/** 佇列 5b：本人的映射草稿。四欄脈絡來自不可變的來源批次（0020）。 */
export const draftMappings = (s: Session, sc: Scope) =>
  query<Record<string, string>>(
    `SELECT mr.mapping_rule_id, mr.source_account_code, mr.source_import_batch_id,
            ce.name AS client, COALESCE(le.name, '—') AS entity, COALESCE(rp.label, '—') AS period
       FROM mapping_rule mr
       JOIN client_engagement ce ON ce.engagement_id = mr.engagement_id
       LEFT JOIN import_batch ib ON ib.import_batch_id = mr.source_import_batch_id
       LEFT JOIN legal_entity le ON le.legal_entity_id = ib.declared_legal_entity_id
       LEFT JOIN period_revision pr ON pr.period_revision_id = ib.declared_period_revision_id
       LEFT JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
      WHERE mr.created_by = :'u'::uuid AND mr.approved_at IS NULL
        AND mr.engagement_id IN (${engIn(sc, "R2", "R3", "R4")})
      ORDER BY mr.created_at DESC`, { u: s.userId }, { tenantId: s.tenantId });

/** 批次狀態清單：R1／R2／R3／R4／R7。 */
export const batches = (s: Session, sc: Scope) =>
  sc.visible.length ? query<Record<string, string>>(
    `SELECT ib.import_batch_id, ib.engagement_id, ib.created_at, ce.name AS client,
            le.name AS entity, rp.label AS period, ib.status, ib.identity_status,
            ib.file_name, ib.quarantine_reason
       FROM import_batch ib
       JOIN client_engagement ce ON ce.engagement_id = ib.engagement_id
       JOIN legal_entity le ON le.legal_entity_id = ib.declared_legal_entity_id
       JOIN period_revision pr ON pr.period_revision_id = ib.declared_period_revision_id
       JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
      WHERE ib.engagement_id IN (${engIn(sc, "R1", "R2", "R3", "R4", "R7")})
      ORDER BY ib.created_at DESC LIMIT 50`, {}, { tenantId: s.tenantId }) : [];

/** 上傳表單的可選項：只在 R1／R2 的案件內。 */
export const uploadOptions = (s: Session, sc: Scope) => {
  const eng = [...new Map((sc.byRole.get("R1") ?? []).concat(sc.byRole.get("R2") ?? [])
    .map((e) => [e.engagement_id, e] as const)).values()];
  if (!eng.length) return { eng, entities: [], periods: [], providers: [] };
  const ids = inList(eng);
  const entities = query<Record<string, string>>(
    `SELECT legal_entity_id, name, engagement_id FROM legal_entity
      WHERE engagement_id IN (${ids}) ORDER BY name`, {}, { tenantId: s.tenantId });
  const periods = query<Record<string, string>>(
    `SELECT pr.period_revision_id, rp.label, rp.engagement_id FROM period_revision pr
       JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
      WHERE rp.engagement_id IN (${ids}) ORDER BY rp.label`, {}, { tenantId: s.tenantId });
  // 真正的資料提供者：該案件有效的 R1 指派。**不含**上傳者自己（除非他就是 R1）。
  const providers = query<Record<string, string>>(
    `SELECT DISTINCT ra.user_id, u.display_name, ra.engagement_id
       FROM role_assignment ra JOIN app_user u ON u.user_id = ra.user_id
      WHERE ra.role = 'R1' AND ra.revoked_at IS NULL AND u.is_active
        AND ra.engagement_id IN (${ids})
      ORDER BY u.display_name`, {}, { tenantId: s.tenantId });
  return { eng, entities, periods, providers };
};
