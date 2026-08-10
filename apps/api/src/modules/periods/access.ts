// B-02 期間工作台的讀模型。
//
// 「下一步」一律讀 0028 的 `fn_period_transition_spec` —— **同一份 DB 事實**。
// 在這裡自行推導遷移表，就會有第二份規則，而兩份規則遲早分岔。
// 阻擋數量是讀取模型（給使用者可行動的原因），**不是裁決**：
// 能不能遷移永遠由 POST 時的 DB 重新判定。
import { query } from "../../../../../packages/database/src/psql.ts";
import type { Session } from "../../../../../packages/auth/src/session.ts";

export interface PeriodCtx {
  period_revision_id: string; revision_no: string; status: string;
  engagement_id: string; client: string; unit: string; calendar: string;
  period_label: string; period_end: string; is_initial_period: string;
}

export const loadPeriod = (s: Session, revisionId: string): PeriodCtx | null =>
  query<PeriodCtx>(
    `SELECT pr.period_revision_id, pr.revision_no::text, pr.status,
            rp.engagement_id, ce.name AS client, ru.name AS unit,
            fc.name AS calendar, rp.label AS period_label,
            rp.end_date::text AS period_end, rp.is_initial_period::text
       FROM period_revision pr
       JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
       JOIN client_engagement ce ON ce.engagement_id = rp.engagement_id
       JOIN reporting_unit ru ON ru.reporting_unit_id = rp.reporting_unit_id
       JOIN fiscal_calendar fc ON fc.fiscal_calendar_id = rp.fiscal_calendar_id
      WHERE pr.period_revision_id = :'r'::uuid`,
    { r: revisionId }, { tenantId: s.tenantId })[0] ?? null;

export interface TransitionSpec {
  requested_to: string; required_role: string | null;
  availability: string; unavailable_code: string | null; unavailable_reason: string | null;
}

/** 目前狀態的合法遷移。非法遷移在此**根本不存在**，不是被過濾掉。 */
export const transitionsFrom = (s: Session, status: string): TransitionSpec[] =>
  query<TransitionSpec>(
    `SELECT requested_to, NULLIF(required_role::text,'') AS required_role,
            availability, unavailable_code, unavailable_reason
       FROM fn_period_transition_spec(:'st')`,
    { st: status }, { tenantId: s.tenantId });

/**
 * 未達成條件的**讀取模型**。與 0022 的聚合守衛查同樣的事實，但只回數字，
 * 不下「能不能遷移」的結論——那是 DB 的事。
 */
export interface Blockers {
  completeBatches: number; unmappedLines: number;
  adjustmentsNotApproved: number; adjustmentsSodFailed: number;
}
export const blockersOf = (s: Session, p: PeriodCtx): Blockers => {
  const one = (sql: string): number => Number(query<{ n: string }>(sql,
    { r: p.period_revision_id, pe: p.period_end }, { tenantId: s.tenantId })[0]?.n ?? 0);
  return {
    completeBatches: one(
      `SELECT count(*) AS n FROM import_batch ib
         JOIN data_coverage dc ON dc.import_batch_id = ib.import_batch_id
          AND dc.batch_version = ib.batch_version
        WHERE ib.declared_period_revision_id = :'r'::uuid AND ib.status = 'ACCEPTED'
          AND dc.granularity = 'BALANCE' AND dc.completeness_status = 'COMPLETE'`),
    unmappedLines: one(
      `SELECT count(*) AS n FROM import_batch ib
         JOIN source_ledger_line sll ON sll.import_batch_id = ib.import_batch_id
        WHERE ib.declared_period_revision_id = :'r'::uuid AND ib.status = 'ACCEPTED'
          AND NOT EXISTS (SELECT 1 FROM mapping_rule mr
             WHERE mr.engagement_id = ib.engagement_id
               AND mr.source_account_code = sll.account_code AND mr.approved_at IS NOT NULL
               AND (mr.effective_from IS NULL OR mr.effective_from <= :'pe'::date)
               AND (mr.effective_to   IS NULL OR mr.effective_to   >= :'pe'::date))`),
    adjustmentsNotApproved: one(
      `SELECT count(*) AS n FROM adjustment
        WHERE period_revision_id = :'r'::uuid AND status <> 'APPROVED'`),
    adjustmentsSodFailed: one(
      `SELECT count(*) AS n FROM adjustment
        WHERE period_revision_id = :'r'::uuid
          AND (reviewed_by IS NULL OR approved_by IS NULL
            OR reviewed_by = prepared_by OR approved_by = reviewed_by
            OR approved_by = prepared_by)`),
  };
};

/** 本期物件計數與一鍵回位。 */
export interface PeriodObjects {
  batches: Record<string, string>[]; adjustments: string;
  runs: Record<string, string>[]; packages: string;
}
export const objectsOf = (s: Session, p: PeriodCtx): PeriodObjects => ({
  batches: query<Record<string, string>>(
    `SELECT import_batch_id, status, identity_status FROM import_batch
      WHERE declared_period_revision_id = :'r'::uuid ORDER BY created_at DESC LIMIT 20`,
    { r: p.period_revision_id }, { tenantId: s.tenantId }),
  adjustments: query<{ n: string }>(
    `SELECT count(*) AS n FROM adjustment WHERE period_revision_id = :'r'::uuid`,
    { r: p.period_revision_id }, { tenantId: s.tenantId })[0]?.n ?? "0",
  runs: query<Record<string, string>>(
    `SELECT calculation_run_id, status, run_type FROM calculation_run
      WHERE period_revision_id = :'r'::uuid ORDER BY created_at DESC LIMIT 10`,
    { r: p.period_revision_id }, { tenantId: s.tenantId }),
  packages: query<{ n: string }>(
    `SELECT count(*) AS n FROM evidence_package p
       JOIN calculation_run r ON r.calculation_run_id = p.calculation_run_id
      WHERE r.period_revision_id = :'r'::uuid`,
    { r: p.period_revision_id }, { tenantId: s.tenantId })[0]?.n ?? "0",
});
