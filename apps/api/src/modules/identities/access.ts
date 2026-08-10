// B-03 身分確認所需的批次脈絡。
//
// 刻意**不併進通用的 loadBatch()**：這裡多取了 uploaded_by、batch_version、
// current_identity_assessment_id、file_sha256 與法人識別碼——那是 SOD-07 與
// 「只接受 current assessment」的判定依據，不是每個畫面都該拿到的東西。
// 把它塞進通用讀取，等於讓所有畫面都順手取得身分判定的原料。
import { query } from "../../../../../packages/database/src/psql.ts";

export const loadIdentityContext = (tenantId: string, batchId: string) => query<Record<string, string>>(
  `SELECT ib.import_batch_id, ib.engagement_id, ib.status, ib.identity_status,
          ib.batch_version, ib.uploaded_by, ib.current_identity_assessment_id,
          ib.file_sha256, ce.name AS client, le.name AS entity,
          le.authoritative_code, rp.label AS period
     FROM import_batch ib
     JOIN client_engagement ce ON ce.engagement_id = ib.engagement_id
     JOIN legal_entity le ON le.legal_entity_id = ib.declared_legal_entity_id
     JOIN period_revision pr ON pr.period_revision_id = ib.declared_period_revision_id
     JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
    WHERE ib.import_batch_id = :'b'::uuid`,
  { b: batchId }, { tenantId })[0];
