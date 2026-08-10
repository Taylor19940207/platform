// 技術維運診斷 API。
//
// §24.6：技術維運＝R6 系統管理員。這是**唯一**應該看租約、認領者與失敗原因的角色，
// 也是唯一以租戶層指派授權的路由——它看的是基礎設施狀態，不是客戶業務資料。
import { query } from "../../../../../packages/database/src/psql.ts";
import { isStalled } from "../../../../../packages/domain/src/backgroundJob.ts";
import type { AuthenticatedContext } from "../../http/context.ts";
import type { Respond } from "../../http/respond.ts";
import { audit } from "../audit.ts";

// ── 診斷：背景工作狀態（SLICE-M2-03 第 16 條；管理用途，本刀只做 API 不做畫面） ──
export async function jobs(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  // 診斷屬技術維運資料（§24.6 權限矩陣：技術維運＝R6 系統管理員）。
  // 只驗登入等於把租約、認領者與失敗原因暴露給租戶內任何使用者。
  const isR6 = query<{ n: string }>(
    `SELECT count(*) AS n FROM role_assignment
      WHERE user_id = :'u'::uuid AND role = 'R6' AND revoked_at IS NULL`,
    { u: s.userId }, { tenantId: s.tenantId });
  if (Number(isR6[0]?.n) === 0) {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "admin.jobs.denied", s.userId,
      "admin_api", s.userId, { reason: "診斷 API 需 R6 系統管理員角色" });
    return send.bytes(403, Buffer.from(JSON.stringify({ error: "診斷 API 需 R6 系統管理員角色" })),
      { "content-type": "application/json; charset=utf-8" });
  }
  const jobs = query<Record<string, string>>(
    `SELECT job_id, job_type, subject_id, subject_version, status,
            claimed_by, claimed_at, lease_expires_at, next_attempt_at,
            attempt_count, max_attempts, last_error_class, last_error_message,
            created_at, updated_at, completed_at, failed_at
       FROM background_job ORDER BY created_at DESC LIMIT 200`,
    {}, { tenantId: s.tenantId });
  // 卡住＝RUNNING 但租約已過期。這是本刀之前唯一無法回答的問題。
  return send.bytes(200, Buffer.from(JSON.stringify({
    jobs: jobs.map((j) => ({
      ...j,
      stalled: isStalled(j.status as "RUNNING", j.lease_expires_at ?? null),
    })),
    stalled_count: jobs.filter((j) =>
      isStalled(j.status as "RUNNING", j.lease_expires_at ?? null)).length,
  }, null, 2)), { "content-type": "application/json; charset=utf-8" });
}
