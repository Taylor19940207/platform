// B-07 的逐動作授權閘。
//
// 授權鏈一律沿**父鏈反查**：
//   清單／建立      CalculationRun → ImportBatch → Engagement
//   檢視／下載      EvidencePackage → CalculationRun → ImportBatch → Engagement
//
// **不得**改用 EvidencePackage.engagement_id 單獨授權：那是冗餘欄位，
// 同租戶下一旦錯配（或日後被寫錯），授權就會落在錯誤的案件上。
// 權威歸屬只有一條——沿父鏈走到 Engagement。
import { query } from "../../../../../packages/database/src/psql.ts";
import type { AuthenticatedContext } from "../../http/context.ts";
import { page, type Respond } from "../../http/respond.ts";
import { batchGate, type BatchGate } from "../imports/guard.ts";

/**
 * §24.6：本刀凍結為案件層 R2／R3／R4 的**嚴格子集**。
 *
 * R5 的「R*」是限授權範圍內唯讀，範圍來自尚未落地的「審計師授權」物件——
 * 沒有範圍就放行等於把「限範圍」讀成「不限範圍」。R7／R8／R9 同理，
 * 各自的授權範圍模型落地後再開。
 */
export const B07 = {
  create:   ["R2", "R3", "R4"],
  list:     ["R2", "R3", "R4"],
  pkgView:  ["R2", "R3", "R4"],
  download: ["R2", "R3", "R4"],
} as const;

/** 以 package 為入口：沿 package → run → batch 反查後再判案件層角色。 */
export function packageGate(ctx: AuthenticatedContext, send: Respond, packageId: string,
                            action: string, allowed: readonly string[], sql: string):
    { ok: true; b: BatchGate & { ok: true }; pkg: Record<string, string> } | { ok: false; res: void } {
  const pkg = query<Record<string, string>>(sql, { p: packageId },
    { tenantId: ctx.session.tenantId })[0];
  if (!pkg) return { ok: false, res: send(404, page("404", "", "<h2>Package 不存在</h2>")) };
  const g = batchGate(ctx, send, pkg.import_batch_id, action, allowed,
    { objectType: "evidence_package", objectId: pkg.package_id });
  if (!g.ok) return { ok: false, res: g.res };
  return { ok: true, b: g, pkg };
}
