// 映射與來源 TB 的**事實**讀取。不含授權結論——授權由各動作依 §24.6 自行判斷。
import { query } from "../../../../../packages/database/src/psql.ts";
import type { Session } from "../../../../../packages/auth/src/session.ts";
import { cents, type TbAccountLine, type CurrentMapping }
  from "../../../../../packages/domain/src/mapping.ts";

/**
 * 目前生效映射：每來源科目取「該報告期間生效」的最高已批准版本。
 * 生效以期間終了日判定（TB 為期末餘額）；NULL 生效日＝不限。
 * 版本凍結（CalculationInputManifest）屬下一刀 CalculationRun。
 */
export function currentMappings(s: Session, engagementId: string, periodEnd: string): CurrentMapping[] {
  return query<{ source_account_code: string; target_account_id: string;
                 target_code: string; target_name: string; version_no: number }>(
    `SELECT DISTINCT ON (mr.source_account_code)
            mr.source_account_code, mr.target_account_id, mr.version_no,
            a.code AS target_code, a.name AS target_name
       FROM mapping_rule mr JOIN account a ON a.account_id = mr.target_account_id
      WHERE mr.engagement_id = :'e'::uuid AND mr.approved_at IS NOT NULL
        AND (mr.effective_from IS NULL OR mr.effective_from <= :'pe'::date)
        AND (mr.effective_to   IS NULL OR mr.effective_to   >= :'pe'::date)
      ORDER BY mr.source_account_code, mr.version_no DESC`,
    { e: engagementId, pe: periodEnd }, { tenantId: s.tenantId })
    .map((r) => ({ sourceAccountCode: r.source_account_code, targetAccountId: r.target_account_id,
                   targetCode: r.target_code, targetName: r.target_name, versionNo: Number(r.version_no) }));
}

/** 批次的 TB 科目彙總列。 */
export function tbLines(s: Session, batchId: string): TbAccountLine[] {
  return query<{ account_code: string; account_name: string; debit: string; credit: string }>(
    `SELECT account_code, MAX(account_name) AS account_name,
            SUM(debit) AS debit, SUM(credit) AS credit
       FROM source_ledger_line WHERE import_batch_id = :'b'::uuid
      GROUP BY account_code ORDER BY account_code`,
    { b: batchId }, { tenantId: s.tenantId })
    .map((r) => ({ accountCode: r.account_code, accountName: r.account_name ?? "",
                   debitCents: cents(r.debit), creditCents: cents(r.credit) }));
}
