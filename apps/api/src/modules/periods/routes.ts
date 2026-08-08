// 期間生命週期的 HTTP route（§28 畫面操作）。
//
// 責任邊界：
//   API = 證明「呼叫者是誰」——p_actor 一律取自登入 Session，
//         **不接受請求自行傳 actor**（所有連線共用 app_runtime，
//         DB 無法證明呼叫者本人就是該自然人）。
//   DB  = 證明「這個人是否真的持有該角色、並允許這次遷移」。
// 本檔不重寫任何守衛，只做：讀表單 → 格式驗證 → 呼叫 Service → 轉成 HTTP。
import { displayTextForCode, validateTransitionRequest }
  from "../../../../../packages/domain/src/periodLifecycle.ts";
import type { AuthenticatedContext } from "../../http/context.ts";
import { esc, page, type Respond } from "../../http/respond.ts";
import { attemptTransition } from "./service.ts";

const CTX_BAR = `<span>畫面 <b>期間生命週期</b></span>`;

export async function transition(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const f = await ctx.form();
  const revision = f["revision"] ?? "";
  const expectedFrom = f["expected_from"] ?? "";
  const to = f["to"] ?? "";
  const actingRole = f["acting_role"] ?? "";
  // 格式驗證只擋「連送進 DB 都不成形」的請求，不做守衛裁決。
  // 一般欄位驗證錯誤不寫 CVA（§25.18）。
  const v = validateTransitionRequest({ revision, expectedFrom, to, actingRole });
  if (!v.ok) {
    return send(400, page("請求格式錯誤", CTX_BAR,
      `<h2>⛔ 請求格式錯誤</h2><p>欄位 <b>${esc(v.field)}</b>：${esc(v.reason)}</p>`),
      { "x-error-code": "INVALID_REQUEST" });
  }
  const r = attemptTransition({ revisionId: revision, expectedFrom, to, actingRole,
    actorId: ctx.session.userId, tenantId: ctx.session.tenantId });
  if (r.ok) {
    return send(200, page("期間狀態已更新", CTX_BAR,
      `<h2>✓ 期間狀態：${esc(r.landed)}</h2>
           ${r.landed !== to ? `<p class="note">你請求 <b>${esc(to)}</b>，系統依覆核覆蓋評估判給
             <b>${esc(r.landed)}</b>。</p>` : ""}`),
      { "x-period-status": r.landed });
  }
  return send(r.httpStatus, page("期間遷移被拒", CTX_BAR,
    `<h2>⛔ ${esc(r.code)}</h2><p>${esc(displayTextForCode(r.code))}</p>
         ${r.notImplemented
           ? `<p class="note">此守衛<b>尚未實作</b>，因此此遷移在本版不可用——
                這不代表守衛已驗證通過。</p>` : ""}
         <p class="note">此次嘗試已寫入稽核軌跡。</p>`),
    { "x-error-code": r.code });
}
