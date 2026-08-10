// 上傳的使用案例編排（里程碑 1 垂直切片；§25.5）。
//
// 物件儲存邊界（順序不可調換）：
//   1. 先寫 write-once object
//   2. 再以**單一 DB 交易**建立 Batch＋Document＋Job＋Event
//
// 物件寫入失敗 → DB 零紀錄（根本還沒開始寫）。
// DB 交易失敗 → 可能留下沒有任何 DB 引用的 staging 孤兒物件，但**不會**留下
// 半套批次。反過來做（先寫 DB 再寫物件）則會產生「批次說檔案已落地、實際沒有」
// 的資料，那是不可恢復的謊；孤兒物件只是浪費空間。
// 孤兒清理排程記 BACKLOG，本刀不擴建清理系統。
import { createHash, randomUUID } from "node:crypto";
import { exec } from "../../../../../packages/database/src/psql.ts";
import { putObject } from "../../../../../packages/database/src/objectstore.ts";
import { idempotencyKey } from "../../../../../packages/domain/src/backgroundJob.ts";
import { config } from "../../../../../packages/config/src/index.ts";
import { auditSql } from "../audit.ts";

export interface UploadInput {
  tenantId: string;
  engagementId: string;
  legalEntityId: string;
  periodRevisionId: string;
  csv: string;
  /** 上傳者：一律取自 Session 的自然人，**不接受表單傳入**。 */
  uploadedBy: string;
  /**
   * 真正的資料提供者。
   *
   * R1 自己上傳時等於 uploadedBy；R2 代傳時應是被代傳的那位提供者——
   * 永遠把 R2 記成提供者會讓補件與逾期 KPI 算錯人。提供者選單屬 B-00 那一刀，
   * 在那之前呼叫端傳入已驗證的值即可。**「兩欄目前相同」不是規則，是現況。**
   */
  providedBy: string;
  detectionRuleVersion: string;
}

export function upload(input: UploadInput): { batchId: string; sha256: string; bytes: number } {
  const data = Buffer.from(input.csv, "utf8");
  const sha = createHash("sha256").update(data).digest("hex");
  const batchId = randomUUID();
  const key = `${input.tenantId}/${batchId}/tb.csv`;
  putObject(key, data);
  // 上傳為單一交易：ImportBatch、SourceDocument、BackgroundJob 與 uploaded 事件同進同出。
  //
  // job 若改在「認領時」才建立，會留下這條路徑：批次已 UPLOADED → 程式崩潰
  // → job 從未建立 → 永遠沒人處理。那與原本的卡住問題等價，只是換了位置。
  //
  // 原檔紀錄先落地，最後才轉 UPLOADED——§25.5「UPLOADED＝檔案已落地」。
  const ev = auditSql(input.tenantId, "DOMAIN_EVENT", "import_batch.uploaded", input.uploadedBy,
    "import_batch", batchId, { sha256: sha, bytes: data.length });
  exec(`BEGIN;
        INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id,
                declared_legal_entity_id, declared_period_revision_id,
                uploaded_by, provided_by, file_name, file_sha256, status)
        VALUES ('${batchId}'::uuid, :'t'::uuid, :'e'::uuid, :'le'::uuid, :'pr'::uuid,
                :'u'::uuid, :'pb'::uuid, 'tb.csv', :'sha', 'DRAFT');
        INSERT INTO source_document (tenant_id, import_batch_id, file_name,
                content_sha256, object_key, byte_size)
        VALUES (:'t'::uuid, '${batchId}'::uuid, 'tb.csv', :'sha', :'k', ${data.length});
        UPDATE import_batch SET status='UPLOADED' WHERE import_batch_id = '${batchId}'::uuid;
        INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version,
                rule_version, idempotency_key, max_attempts)
        SELECT :'t'::uuid, 'IMPORT_VALIDATION', '${batchId}'::uuid, ib.batch_version,
               :'rv', :'ik', ${config.jobMaxAttempts}
          FROM import_batch ib WHERE ib.import_batch_id = '${batchId}'::uuid;
        ${ev.sql}
        COMMIT;`,
    { t: input.tenantId, e: input.engagementId, le: input.legalEntityId,
      pr: input.periodRevisionId, u: input.uploadedBy, pb: input.providedBy,
      sha, k: key, rv: input.detectionRuleVersion,
      ik: idempotencyKey("IMPORT_VALIDATION", batchId, 1, input.detectionRuleVersion),
      ...ev.params }, { tenantId: input.tenantId });
  return { batchId, sha256: sha, bytes: data.length };
}
