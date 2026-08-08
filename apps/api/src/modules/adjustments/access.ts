// 調整（B-05）的讀取與歸屬：資料存取與「這個人在這個案件有哪些角色」。
//
// 從 server.ts 的請求閉包中抽出，改為顯式接收 tenantId／Session——
// Service 不該靠閉包拿到身分，那會讓「身分只能來自 Session」這條規則看不出來。
// 這裡**不做任何裁決**：角色清單只是事實，能不能做由 route（權限矩陣）與
// DB 守衛（SoD、狀態機、不變條件）決定。
import { query } from "../../../../../packages/database/src/psql.ts";
import type { AdjustmentStatus } from "../../../../../packages/domain/src/adjustment.ts";

export interface AdjRow {
  adjustment_id: string; engagement_id: string; period_revision_id: string;
  status: AdjustmentStatus; title: string;
  legal_basis: string | null; evidence_ref: string | null;
  judgment_reason: string | null; language_tag: string | null;
  prepared_by: string; reviewed_by: string | null; approved_by: string | null;
  object_version: number; business_version: number;
  output_capability: string | null; control_reasons: string[];
  period_end: string; period_label: string; client: string;
}
export interface AdjLineRow {
  adjustment_line_id: string; line_no: number; target_account_id: string;
  code: string; name: string; debit: string; credit: string;
}

export const loadAdj = (tenantId: string, adjId: string): AdjRow | null => query<AdjRow>(
  `SELECT adj.adjustment_id, adj.engagement_id, adj.period_revision_id, adj.status, adj.title,
          adj.legal_basis, adj.evidence_ref, adj.judgment_reason, adj.language_tag,
          adj.prepared_by, adj.reviewed_by, adj.approved_by,
          adj.object_version, adj.business_version,
          adj.output_capability, adj.control_reasons,
          rp.end_date AS period_end, rp.label AS period_label, ce.name AS client
     FROM adjustment adj
     JOIN client_engagement ce ON ce.engagement_id = adj.engagement_id
     JOIN period_revision pr ON pr.period_revision_id = adj.period_revision_id
     JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
    WHERE adj.adjustment_id = :'a'::uuid`,
  { a: adjId }, { tenantId })[0] ?? null;

export const adjLines = (tenantId: string, adjId: string): AdjLineRow[] => query<AdjLineRow>(
  `SELECT al.adjustment_line_id, al.line_no, al.target_account_id, al.debit, al.credit,
          a.code, a.name
     FROM adjustment_line al JOIN account a ON a.account_id = al.target_account_id
    WHERE al.adjustment_id = :'a'::uuid ORDER BY al.line_no`,
  { a: adjId }, { tenantId });
