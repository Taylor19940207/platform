// 匯入批次的**事實**讀取：批次是什麼、屬於誰、目前什麼狀態。
//
// 刻意不含任何授權結論。舊 b04Guard 把「載入批次」與「有沒有權限」綁在一起，
// 於是同一份授權判斷同時服務映射、調整、計算與證據包——這正是授權失準的來源。
// 授權改由各動作依 §24.6 自行判斷（動作 × 角色 × 作用域），本檔只回傳事實。
import { query } from "../../../../../packages/database/src/psql.ts";
import type { Session } from "../../../../../packages/auth/src/session.ts";
import type { ImportBatchStatus, IdentityStatus }
  from "../../../../../packages/domain/src/importBatch.ts";

export interface BatchCtx {
  import_batch_id: string; engagement_id: string; status: ImportBatchStatus;
  identity_status: IdentityStatus; hash_verified: boolean;
  client: string; entity: string; period: string; period_end: string;
  declared_period_revision_id: string;
}
export function loadBatch(s: Session, batchId: string): BatchCtx | null {
  const rows = query<BatchCtx>(
    `SELECT ib.import_batch_id, ib.engagement_id, ib.status, ib.identity_status, ib.hash_verified,
            ib.declared_period_revision_id,
            ce.name AS client, le.name AS entity, rp.label AS period, rp.end_date AS period_end
       FROM import_batch ib
       JOIN client_engagement ce ON ce.engagement_id = ib.engagement_id
       JOIN legal_entity le ON le.legal_entity_id = ib.declared_legal_entity_id
       JOIN period_revision pr ON pr.period_revision_id = ib.declared_period_revision_id
       JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
      WHERE ib.import_batch_id = :'b'::uuid`,
    { b: batchId }, { tenantId: s.tenantId });
  return rows[0] ?? null;
}
