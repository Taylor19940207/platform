// 匯入批次的 HTTP route。目前只有「接受批次」——它改變 ImportBatch 狀態，
// 屬 imports 而非 mappings，儘管它由 B-04 畫面觸發。
import { exec } from "../../../../../packages/database/src/psql.ts";
import { acceptancePredicate } from "../../../../../packages/domain/src/importBatch.ts";
import type { AuthenticatedContext } from "../../http/context.ts";
import { esc, page, type Respond } from "../../http/respond.ts";
import { audit, auditSql } from "../audit.ts";
import { batchGate, B04 } from "./guard.ts";
import { b04CtxBar } from "./views.ts";

// ── 接受批次（VALIDATED → ACCEPTED；G-01 接受判定式，DB 觸發器為最後防線） ──
export async function accept(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const fields = await ctx.form();
  const g = batchGate(ctx, send, fields["batch"] ?? "", "batch.accept", B04.accept);
  if (!g.ok) return;
  const pred = acceptancePredicate({ status: g.b.status,
    identityStatus: g.b.identity_status, hashVerified: g.b.hash_verified });
  if (!pred.ok) {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "batch.accept.rejected", s.userId,
      "import_batch", g.b.import_batch_id, { guard: pred.guard, reasons: pred.reasons });
    return send(409, page("拒絕", b04CtxBar(g.b, "B-04"),
      `<h2>⛔ ${pred.guard}：不滿足接受判定式</h2><ul>${pred.reasons.map((r) => `<li>${esc(r)}</li>`).join("")}</ul><p><a href="/">回 B-00</a></p>`));
  }
  // 狀態與事件同交易（與 SLICE-M2-03 的其餘 import_batch 事件一致）
  const evAcc = auditSql(s.tenantId, "DOMAIN_EVENT", "import_batch.accepted", s.userId,
    "import_batch", g.b.import_batch_id, {});
  exec(`BEGIN;
        UPDATE import_batch SET status='ACCEPTED' WHERE import_batch_id = :'b'::uuid;
        ${evAcc.sql}
        COMMIT;`,
    { b: g.b.import_batch_id, ...evAcc.params }, { tenantId: s.tenantId });
  return send(302, "", { location: `/b04?batch=${g.b.import_batch_id}` });
}
