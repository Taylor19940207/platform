// B-06 的逐動作授權閘。
//
// 兩個入口形狀：
//   * 帶 batch 的（建立、清單）——直接以該批次的案件層角色判斷；
//   * 帶 run 的（重演、單次結果檢視）——**由 CalculationRun 反查歸屬**，
//     不信任請求附帶的 batch。呼叫端若能自帶 batch，就能拿自己有權的案件批次
//     去換取別的案件的 run；RLS 擋得住跨租戶，擋不住同租戶跨案件。
import { query } from "../../../../../packages/database/src/psql.ts";
import type { AuthenticatedContext } from "../../http/context.ts";
import { page, type Respond } from "../../http/respond.ts";
import { batchGate, type BatchGate } from "../imports/guard.ts";

/** §24.6：建立、重演、清單與單次結果檢視均為案件層 R2／R3。 */
export const B06 = {
  create:  ["R2", "R3"],
  replay:  ["R2", "R3"],
  view:    ["R2", "R3"],
  runView: ["R2", "R3"],
} as const;

export type RunGate = BatchGate & { run?: Record<string, string> };

/**
 * 以 run 為入口的授權：run → import_batch → engagement，逐層反查後再判角色。
 *
 * `sql` 讓呼叫端用自己的查詢一次取回需要的欄位（避免為了授權多查一次），
 * 但**必須**選出 import_batch_id——授權就是靠它反查歸屬。省略時取整列。
 */
const RUN_BY_ID = `SELECT r.* FROM calculation_run r WHERE r.calculation_run_id = :'r'::uuid`;

export function runGate(ctx: AuthenticatedContext, send: Respond, runId: string,
                        action: string, allowed: readonly string[], sql = RUN_BY_ID):
    { ok: true; b: BatchGate & { ok: true }; run: Record<string, string> } | { ok: false; res: void } {
  const run = query<Record<string, string>>(sql,
    { r: runId }, { tenantId: ctx.session.tenantId })[0];
  if (!run) return { ok: false, res: send(404, page("404", "", "<h2>Run 不存在</h2>")) };
  const g = batchGate(ctx, send, run.import_batch_id, action, allowed);
  if (!g.ok) return { ok: false, res: g.res };
  return { ok: true, b: g, run };
}
