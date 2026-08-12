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
import { engagementRolesOf, tenantRolesOf } from "../engagements/access.ts";
import { audit } from "../audit.ts";
import { loadPeriod, transitionsFrom, blockersOf, objectsOf,
         type TransitionSpec } from "./access.ts";

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

/**
 * §24.6 期間列＋§28：完整 B-02 為案件層 R2／R3／R4。
 *
 * **R1 不得查看完整期間工作台**——註③明確限制「R1 僅看得到自身提交狀態，
 * 非期間全貌」。R1 維持 B-00 與上傳入口；要給它精簡版是獨立一刀，
 * 且需先想清楚「自身提交狀態」的邊界。
 */
const B02_VIEW = ["R2", "R3", "R4"] as const;

export async function workbench(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const p = loadPeriod(s, ctx.url.searchParams.get("revision") ?? "");
  if (!p) return send(404, page("404", "", "<h2>期間不存在</h2>"));
  const roles = engagementRolesOf(s, p.engagement_id);
  if (!B02_VIEW.some((x) => roles.has(x))) {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "b02.view.denied", s.userId,
      "period_revision", p.period_revision_id,
      { reason: `期間工作台需本案件的 ${B02_VIEW.join("／")} 角色（§24.6 註③：R1 僅看得到自身提交狀態）`,
        engagement_roles: [...roles].sort(), tenant_roles: [...tenantRolesOf(s)].sort() });
    return send(403, page("拒絕", "<b>⛔ 無權讀取</b>",
      "<h2>⛔ 目前角色無權查看期間工作台</h2><p>此次嘗試已寫入稽核軌跡。</p>"));
  }

  // 「下一步」讀 0028 的規格函式——與 DB 判定用的是同一份事實
  const specs = transitionsFrom(s, p.status);
  const b = blockersOf(s, p);
  const o = objectsOf(s, p);
  const ctxBar =
    `<span>畫面 <b>B-02 期間工作台</b></span><span>客戶 <b>${esc(p.client)}</b></span>` +
    `<span>單位 <b>${esc(p.unit)}</b></span><span>曆別 <b>${esc(p.calendar)}</b></span>` +
    `<span>期間 <b>${esc(p.period_label)}</b>（rev ${esc(p.revision_no)}）</span>`;

  const reasonFor = (to: string): string => {
    if (p.status === "OPEN" && to === "IN_PREPARATION" && b.completeBatches === 0)
      return "尚無「已接受且聲明完整」的 BALANCE 批次";
    if (p.status === "IN_PREPARATION" && to === "IN_REVIEW" && b.unmappedLines > 0)
      return `尚有 ${b.unmappedLines} 列來源餘額未映射`;
    if (p.status === "IN_REVIEW" && to === "ADJ_APPROVED") {
      if (b.adjustmentsNotApproved > 0) return `尚有 ${b.adjustmentsNotApproved} 筆調整未批准`;
      if (b.adjustmentsSodFailed > 0) return `有 ${b.adjustmentsSodFailed} 筆調整不滿足逐筆職責分離`;
    }
    return "";
  };

  /**
   * CONDITIONAL 的條件是否成立。目前唯一一條：G-10 只擋**非首期**的 SETUP → OPEN。
   * 這不是重寫遷移表——遷移表仍全數來自 DB；這裡評估的是 0022 trigger
   * 用同一份事實判定的那個條件，與「未達成條件」一樣屬讀取模型。
   * 條件不成立時把它畫成不可用，等於對首期謊稱功能不存在。
   */
  const conditionBites = (t: TransitionSpec): boolean =>
    p.status === "SETUP" && t.requested_to === "OPEN" && p.is_initial_period !== "true";

  const steps = specs.map((t) => {
    const notImpl = t.availability === "NOT_IMPLEMENTED"
      || (t.availability === "CONDITIONAL" && conditionBites(t));
    const hasRole = t.required_role !== null && roles.has(t.required_role);
    const why = reasonFor(t.requested_to);
    const action = notImpl
      ? `<span class="badge st-QUARANTINED">守衛尚未實作</span>
         <span class="note">${esc(t.unavailable_reason ?? "")}</span>`
      : !hasRole
      ? `<span class="note">需 ${esc(t.required_role ?? "—")} 角色</span>`
      : `<form method="post" action="/period/transition" style="display:inline">
           <input type="hidden" name="revision" value="${p.period_revision_id}">
           <input type="hidden" name="expected_from" value="${esc(p.status)}">
           <input type="hidden" name="to" value="${esc(t.requested_to)}">
           <input type="hidden" name="acting_role" value="${esc(t.required_role ?? "")}">
           <button>前往 ${esc(t.requested_to)}</button></form>`;
    return `<tr><td><b>${esc(t.requested_to)}</b></td>
      <td>${esc(t.required_role ?? "—")}</td>
      <td>${notImpl ? "不可用" : "可用"}</td>
      <td>${action}</td><td class="note">${esc(why)}</td></tr>`;
  }).join("");

  return send(200, page("B-02 期間工作台", ctxBar,
    `<h2>期間狀態　<span class="badge st-${esc(p.status)}">${esc(p.status)}</span></h2>
     <p class="note">修訂 ${esc(p.revision_no)}｜${p.is_initial_period === "true"
       ? "本單位在此曆別下的<b>首期</b>" : "非首期"}｜期末 ${esc(p.period_end)}</p>
     <h2>下一步</h2>
     ${specs.length
       ? `<table><tr><th>目標狀態</th><th>所需角色</th><th>可用性</th><th>動作</th><th>未達成條件</th></tr>${steps}</table>
          <p class="note">此表由 DB 的遷移規格（<code>fn_period_transition_spec</code>）產生，
             與實際判定用的是同一份事實；能否遷移仍由送出時的 DB 重新判定。</p>`
       : `<p class="note">此狀態沒有後續遷移。</p>`}
     <h2>本期物件</h2>
     <table><tr><th>物件</th><th>數量</th><th></th></tr>
       <tr><td>匯入批次</td><td>${o.batches.length}</td><td>${o.batches.map((x) =>
         `<a href="/b04?batch=${x.import_batch_id}">${x.import_batch_id.slice(0, 8)}（${esc(x.status)}）</a>`)
         .join("　") || "—"}</td></tr>
       <tr><td>調整</td><td>${esc(o.adjustments)}</td><td class="note">見 B-00 佇列</td></tr>
       <tr><td>計算執行</td><td>${o.runs.length}</td><td>${o.runs.map((x) =>
         `<a href="/b06/run?id=${x.calculation_run_id}">${x.calculation_run_id.slice(0, 8)}（${esc(x.status)}）</a>`)
         .join("　") || "—"}</td></tr>
       <tr><td>證據包</td><td>${esc(o.packages)}</td><td class="note">見 B-07</td></tr>
     </table>
     <p><a href="/b06/fx?revision=${p.period_revision_id}">→ B-06 折算與核對</a>　
        <a href="/">← 回 B-00</a></p>`));
}
