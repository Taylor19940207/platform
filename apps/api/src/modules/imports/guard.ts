// 以批次為脈絡的**逐動作**授權閘。
//
// 取代舊的萬用 b04Guard。舊守衛只問「有沒有被指派這個案件」，於是同一份判斷
// 同時替接受批次、建立映射、批准映射、送覆核、建立調整、建立計算與產證據包
// 授權——動作之間的權限差異全部消失，而且它用的是「案件層 ∪ 租戶層」的聯集，
// 租戶層角色因此能隱式取得客戶資料。
//
// 這裡改成：呼叫端必須明確指定「這個動作允許哪些角色」，且一律只看**案件層**
// 授權（§26.3：R1～R5、R7 屬 EngagementAssignment；Tenant 內每個 Engagement
// 都必須明示授權）。
import type { AuthenticatedContext } from "../../http/context.ts";
import { esc, page, type Respond } from "../../http/respond.ts";
import { audit } from "../audit.ts";
import { engagementRolesOf, tenantRolesOf } from "../engagements/access.ts";
import { loadBatch, type BatchCtx } from "./access.ts";

export type BatchGate =
  | { ok: true; b: BatchCtx; roles: Set<string> }
  | { ok: false; res: void };

export interface ObjectRef { objectType: string; objectId: string }

/**
 * `objectRef` 讓呼叫端指定 CVA 要記在哪個物件上。預設記 import_batch；
 * 但以 run 或 package 為入口的動作必須記回**它自己的**物件——
 * 把 package 的越權記成 import_batch，稽核軌跡就答不出「他想拿的是哪一份」。
 */
export function batchGate(ctx: AuthenticatedContext, send: Respond, batchId: string,
                          action: string, allowed: readonly string[],
                          objectRef?: ObjectRef): BatchGate {
  const s = ctx.session;
  const b = loadBatch(s, batchId);
  if (!b) return { ok: false, res: send(404, page("404", "", "<h2>批次不存在</h2>")) };
  const roles = engagementRolesOf(s, b.engagement_id);
  if (!allowed.some((x) => roles.has(x))) {
    // 兩種範圍分開留痕：稽核軌跡要答得出「缺的是角色種類還是授權範圍」
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", `${action}.denied`, s.userId,
      objectRef?.objectType ?? "import_batch", objectRef?.objectId ?? batchId,
      { reason: `本動作需本案件的 ${allowed.join("／")} 角色（§24.6）`, action,
        engagement_roles: [...roles].sort(), tenant_roles: [...tenantRolesOf(s)].sort() });
    return { ok: false, res: send(403, page("拒絕", "<b>⛔ 無權執行</b>",
      `<h2>⛔ 本動作需本案件的 ${esc(allowed.join("／"))} 角色</h2>
       <p>此次嘗試已寫入稽核軌跡。</p><p><a href="/">回 B-00</a></p>`)) };
  }
  return { ok: true, b, roles };
}

/**
 * §24.6 逐動作角色（本刀凍結）。
 *
 * `/b04` GET 刻意**不開給 R7**：該畫面目前混有 Adjustment 清單、建立調整表單
 * 與 B-06 入口，開給 R7 會與「調整只允許 R2／R3／R4」的政策直接矛盾。
 * R7 的完整映射工作畫面等 B-04 拆掉混雜區塊後再開——現在採嚴格子集。
 * 同理 R6：矩陣雖給它 ImportBatch 的 `R`，但那應是獨立受限的批次查詢畫面，
 * 不是整個 B-04。
 */
export const B04 = {
  view:    ["R2", "R3", "R4"],
  preview: ["R2", "R3", "R4", "R7"],
  accept:  ["R2"],
  map:     ["R2", "R7"],
  approve: ["R4"],
  submit:  ["R2"],
} as const;
