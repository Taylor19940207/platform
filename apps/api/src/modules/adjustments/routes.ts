// 調整（B-05）的 HTTP route：讀表單 → 存取閘 → 呼叫 Service → 轉成 HTTP。
//
// 這裡不做任何會計裁決，也不寫使用案例層的稽核——被拒時的 CVA 由 service 寫。
// 唯一留在本層的稽核是「未被指派此案件」：那是存取閘，發生在使用案例被呼叫之前，
// 且它的兩種結果（404 物件不存在／403 無指派）本身就是 HTTP 形狀的判斷。
import { query } from "../../../../../packages/database/src/psql.ts";
import type { Session } from "../../../../../packages/auth/src/session.ts";
import { g08Check, balanceCheck } from "../../../../../packages/domain/src/adjustment.ts";
import type { AuthenticatedContext } from "../../http/context.ts";
import { esc, page, type Respond } from "../../http/respond.ts";
import { audit } from "../audit.ts";
import { rolesOf, loadAdj, adjLines, type AdjRow } from "./access.ts";
import * as adjSvc from "./service.ts";

/** 共通入口：調整存在＋使用者被指派該案件。 */
const b05Guard = (ctx: AuthenticatedContext, send: Respond, adjId: string, action: string):
    { ok: true; r: AdjRow; roles: Set<string> } | { ok: false; res: void } => {
  const s = ctx.session;
  const r = loadAdj(s.tenantId, adjId);
  if (!r) return { ok: false, res: send(404, page("404", "", "<h2>調整不存在</h2>")) };
  const roles = rolesOf(s, r.engagement_id);
  if (roles.size === 0) {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", `${action}.denied`, s.userId,
      "adjustment", adjId, { reason: "未被指派此案件", action });
    return { ok: false, res: send(403, page("拒絕", "<b>⛔ 未被指派</b>",
      `<h2>⛔ 未被指派此案件</h2><p>此次嘗試已寫入稽核軌跡。</p>`)) };
  }
  return { ok: true, r, roles };
};

const b05CtxBar = (r: AdjRow): string =>
  `<span>畫面 <b>B-05 調整編製・覆核・批准</b></span><span>客戶 <b>${esc(r.client)}</b></span>` +
  `<span>期間 <b>${esc(r.period_label)}</b></span>` +
  `<span>調整 <b>${r.adjustment_id.slice(0, 8)}</b>（${r.status}）</span>` +
  `<span>bv <b>${r.business_version}</b>／ov <b>${r.object_version}</b></span>`;

const actorOf = (s: Session, roles: Set<string>): adjSvc.Actor =>
  ({ userId: s.userId, tenantId: s.tenantId, roles });

/** 使用案例失敗的統一渲染出口。留痕已由 service 完成，這裡只負責畫面與狀態碼。 */
const renderAdjFailure = (send: Respond, r: AdjRow, out: adjSvc.AdjustmentOutcome & { ok: false }) => {
  if (out.kind === "ROLE")
    return send(403, page("拒絕", b05CtxBar(r), `<h2>⛔ 此操作需 ${esc(out.need)} 角色</h2>`));
  if (out.kind === "VERSION_CONFLICT")
    return send(409, page("併發衝突", b05CtxBar(r),
      `<h2>⛔ 併發衝突：草稿已被他人更新</h2>
       <p>你根據的版本 ov=${out.base}，目前為 ov=${out.current}。</p>
       <p class="note">系統不會靜默覆蓋他人的修改。請重新載入後再編輯。</p>
       <p><a href="/b05?adj=${r.adjustment_id}">重新載入 B-05</a></p>`));
  if (out.kind === "CONCURRENT_CONFLICT")
    return send(409, page("併發衝突", b05CtxBar(r),
      `<h2>⛔ 併發衝突：另一個請求先完成了儲存</h2>
       <p class="note">你的修改未被套用，對方的內容也未被覆蓋。請重新載入後再編輯。</p>
       <p><a href="/b05?adj=${r.adjustment_id}">重新載入 B-05</a></p>`));
  if (out.kind === "LINES_INVALID")
    return send(409, page("草稿未保存", b05CtxBar(r),
      `<h2>⛔ 草稿未保存：明細有 ${out.errors.length} 列不合法</h2>
       <ul>${out.errors.map((b) => `<li>第 ${b.lineNo} 列：${esc(b.error)}</li>`).join("")}</ul>
       <p class="note">整筆拒絕——表頭、明細與 object_version 均未變動。</p>
       <p><a href="/b05?adj=${r.adjustment_id}">回 B-05</a></p>`));
  const gd = out.verdict;
  return send(409, page(`${gd.guard} 阻擋`, b05CtxBar(r),
    `<h2>⛔ ${esc(gd.guard)}</h2><ul>${gd.reasons.map((x) => `<li>${esc(x)}</li>`).join("")}</ul>
     <p class="note">此次嘗試已寫入稽核軌跡。</p>
     <p><a href="/b05?adj=${r.adjustment_id}">回 B-05</a></p>`));
};

// ── B-05 工作畫面 ──
export async function view(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const g = b05Guard(ctx, send, ctx.url.searchParams.get("adj") ?? "", "b05.view");
  if (!g.ok) return;
  const { r } = g;
  const lines = adjLines(s.tenantId, r.adjustment_id);
  const st = adjSvc.stateOf(r, lines);
  const g08 = g08Check(st.evidence);
  const bal = balanceCheck(st.lines);
  const accounts = query<Record<string, string>>(
    `SELECT a.account_id, a.code, a.name FROM account a
       JOIN chart_of_accounts c ON c.coa_id = a.coa_id
      WHERE c.engagement_id = :'e'::uuid ORDER BY a.code`,
    { e: r.engagement_id }, { tenantId: s.tenantId });
  const snaps = query<Record<string, string>>(
    `SELECT s.business_version, s.milestone, s.reason_category, s.reason_note,
            s.occurred_at, u.display_name AS actor
       FROM adjustment_version_snapshot s JOIN app_user u ON u.user_id = s.actor_id
      WHERE s.adjustment_id = :'a'::uuid ORDER BY s.business_version`,
    { a: r.adjustment_id }, { tenantId: s.tenantId });
  const jl = query<{ n: string }>(
    `SELECT count(*) AS n FROM journal_line jl
       JOIN journal_entry je ON je.entry_id = jl.entry_id
      WHERE je.adjustment_id = :'a'::uuid`,
    { a: r.adjustment_id }, { tenantId: s.tenantId })[0];
  const editable = r.status === "DRAFTING";
  const previewOnly = r.output_capability === "PREVIEW";
  const person = (id: string | null) => id ? esc(id.slice(-4)) : "—";
  return send(200, page("B-05 調整編製・覆核・批准", b05CtxBar(r),
    `${previewOnly ? `<div style="background:#fff3e0;border:1px solid #d9a05b;border-radius:6px;padding:10px 14px;font-weight:600">
       只能預覽、不可正式交付　output_capability = PREVIEW　理由：${(r.control_reasons ?? []).map(esc).join("；")}
     </div>` : ""}
     <h2>${esc(r.title)}　<span class="badge st-${r.status === "APPROVED" ? "ACCEPTED" : r.status === "DRAFTING" ? "UPLOADED" : "VALIDATED"}">${r.status}</span></h2>
     <p class="note">編製 ${person(r.prepared_by)}｜覆核 ${person(r.reviewed_by)}｜批准 ${person(r.approved_by)}
        ｜business_version <b>${r.business_version}</b>｜object_version <b>${r.object_version}</b>
        ｜已物化 JournalLine <b>${jl.n}</b></p>

     <h2>G-08 必要證據（四項缺一不可）</h2>
     <p>${g08.ok ? `<span class="badge st-MATCHED">齊備</span>`
                 : `<span class="badge st-QUARANTINED">未齊</span> ${esc(g08.reasons.join("；"))}`}</p>
     <!-- 證據永遠顯示：覆核人（R3）與批准人（R4）必須看得到要覆核的內容，
          不能因為調整已離開草稿階段而隱藏。 -->
     <table><tr><th>項目</th><th>內容</th></tr>
     ${([["法源／政策依據", r.legal_basis], ["附件／支持文件", r.evidence_ref],
         ["判斷理由", r.judgment_reason], ["語言標籤", r.language_tag]] as [string, string | null][])
       .map(([label, v]) => `<tr><td>${label}</td><td>${v ? esc(v)
         : `<span class="badge st-QUARANTINED">未填</span>`}</td></tr>`).join("")}
     </table>
     ${editable ? `<form class="up" method="post" action="/b05/save">
       <input type="hidden" name="adj" value="${r.adjustment_id}">
       <input type="hidden" name="base_object_version" value="${r.object_version}">
       標題 <input name="title" size="40" value="${esc(r.title)}"><br>
       法源／政策依據 <input name="legal_basis" size="50" value="${esc(r.legal_basis ?? "")}"><br>
       附件／支持文件 <input name="evidence_ref" size="50" value="${esc(r.evidence_ref ?? "")}"><br>
       判斷理由 <input name="judgment_reason" size="50" value="${esc(r.judgment_reason ?? "")}"><br>
       語言標籤 <select name="language_tag">
         ${["", "ja-JP", "zh-CN", "zh-TW", "en"].map((t) =>
           `<option value="${t}"${t === (r.language_tag ?? "") ? " selected" : ""}>${t || "（未設定）"}</option>`).join("")}
       </select><br>
       分錄明細（每行 <code>集團科目代碼,借方,貸方</code>）<br>
       <textarea name="lines" rows="4" cols="60">${esc(lines.map((l) => `${l.code},${l.debit},${l.credit}`).join("\n"))}</textarea><br>
       <button>儲存草稿</button>
       <span class="note">儲存只遞增 object_version（併發控制），不產生 business_version 節點</span>
     </form>` : ""}

     <h2>分錄明細</h2>
     <table><tr><th>#</th><th>集團科目</th><th>名稱</th><th>借方</th><th>貸方</th></tr>
     ${lines.map((l) => `<tr><td>${l.line_no}</td><td>${esc(l.code)}</td><td>${esc(l.name)}</td>
       <td style="text-align:right">${esc(l.debit)}</td><td style="text-align:right">${esc(l.credit)}</td></tr>`).join("")}
     </table>
     <p>借貸 ${bal.ok ? `<span class="badge st-MATCHED">平衡</span>`
                      : `<span class="badge st-QUARANTINED">${esc(bal.reasons.join("；"))}</span>`}</p>
     <p class="note">可用集團科目：${accounts.map((a) => esc(a.code)).join("、")}</p>

     <h2>工作流</h2>
     <p>
     ${r.status === "DRAFTING" ? `<form method="post" action="/b05/submit" style="display:inline">
        <input type="hidden" name="adj" value="${r.adjustment_id}"><button>送覆核（R2）</button></form>` : ""}
     ${r.status === "PENDING_REVIEW" ? `<form method="post" action="/b05/review" style="display:inline">
        <input type="hidden" name="adj" value="${r.adjustment_id}"><button>覆核通過（R3）</button></form>` : ""}
     ${r.status === "PENDING_APPROVAL" ? `<form method="post" action="/b05/approve" style="display:inline">
        <input type="hidden" name="adj" value="${r.adjustment_id}"><button>批准（R4）</button></form>` : ""}
     ${r.status === "PENDING_REVIEW" || r.status === "PENDING_APPROVAL"
       ? `<form method="post" action="/b05/return" style="display:inline">
          <input type="hidden" name="adj" value="${r.adjustment_id}">
          理由分類 <select name="reason_category">
            <option>MISSING_EVIDENCE</option><option>CALCULATION_ERROR</option>
            <option>POLICY_MISMATCH</option><option>OTHER</option></select>
          <input name="reason_note" size="24" placeholder="說明（必填）">
          <button>退回至草稿</button></form>` : ""}
     </p>
     <p class="note">SOD-01 編製人不得覆核自己｜SOD-02 覆核人不得兼批准｜
        AC-WFL-001 編製人不得批准自己（三者為自然人判定，具備角色也不得自我放行）</p>

     <h2>business version 里程碑</h2>
     <table><tr><th>bv</th><th>里程碑</th><th>操作人</th><th>理由分類</th><th>說明</th><th>時間</th></tr>
     ${snaps.map((v) => `<tr><td>${esc(v.business_version)}</td><td>${esc(v.milestone)}</td>
       <td>${esc(v.actor)}</td><td>${esc(v.reason_category ?? "")}</td>
       <td>${esc(v.reason_note ?? "")}</td><td class="note">${esc(v.occurred_at)}</td></tr>`).join("")}
     </table>
     <p class="note">退回不建立新調整、不建立替代版本；但退回是業務里程碑，留下不可變節點（ADR-M2-001）。</p>
     <p><a href="/">回 B-00</a></p>`));
}

// ── 儲存草稿（object_version 樂觀鎖；不產生 business_version） ──
export async function save(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const f = await ctx.form();
  const g = b05Guard(ctx, send, f["adj"] ?? "", "adjustment.save");
  if (!g.ok) return;
  const { r } = g;
  const out = adjSvc.save(actorOf(s, g.roles), r, {
    baseObjectVersion: Number(f["base_object_version"] ?? "0"),
    title: f["title"] ?? r.title, legalBasis: f["legal_basis"] ?? "",
    evidenceRef: f["evidence_ref"] ?? "", judgmentReason: f["judgment_reason"] ?? "",
    languageTag: f["language_tag"] ?? "", linesText: f["lines"] ?? "" });
  if (out.ok) return send(302, "", { location: `/b05?adj=${r.adjustment_id}` });
  return renderAdjFailure(send, r, out);
}

// ── 送覆核（R2；G-08 ＋ 分錄成立性） ──
export async function submit(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const f = await ctx.form();
  const g = b05Guard(ctx, send, f["adj"] ?? "", "adjustment.submit");
  if (!g.ok) return;
  const out = adjSvc.submit(actorOf(s, g.roles), g.r);
  if (out.ok) return send(302, "", { location: `/b05?adj=${g.r.adjustment_id}` });
  return renderAdjFailure(send, g.r, out);
}

// ── 覆核通過（R3；G-04／SOD-01） ──
export async function review(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const f = await ctx.form();
  const g = b05Guard(ctx, send, f["adj"] ?? "", "adjustment.review");
  if (!g.ok) return;
  const out = adjSvc.review(actorOf(s, g.roles), g.r);
  if (out.ok) return send(302, "", { location: `/b05?adj=${g.r.adjustment_id}` });
  return renderAdjFailure(send, g.r, out);
}

// ── 退回至草稿（兩個節點皆可；理由必填） ──
export async function returnDraft(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const f = await ctx.form();
  const g = b05Guard(ctx, send, f["adj"] ?? "", "adjustment.return");
  if (!g.ok) return;
  const out = adjSvc.returnToDraft(actorOf(s, g.roles), g.r,
    (f["reason_category"] ?? "").trim(), (f["reason_note"] ?? "").trim());
  if (out.ok) return send(302, "", { location: `/b05?adj=${g.r.adjustment_id}` });
  return renderAdjFailure(send, g.r, out);
}

// ── 批准（R4；G-08 複查 ＋ G-05／SOD-02 ＋ AC-WFL-001）＋ 同交易物化 ──
export async function approve(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const f = await ctx.form();
  const g = b05Guard(ctx, send, f["adj"] ?? "", "adjustment.approve");
  if (!g.ok) return;
  const out = adjSvc.approve(actorOf(s, g.roles), g.r);
  if (out.ok) return send(302, "", { location: `/b05?adj=${g.r.adjustment_id}` });
  return renderAdjFailure(send, g.r, out);
}
