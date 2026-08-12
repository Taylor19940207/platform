// B-06 折算與核對（§28）。
//
// **所有判斷讀 DB 的兩支 readiness 函式**——`fn_period_fx_input_readiness`
// 與 `fn_period_fx_result_readiness`。畫面不在 TypeScript 建第二套規則：
// 按鈕能不能按、為什麼不能按，都來自同一份 DB 事實（與 0028／B-02 同一模式）。
// 按鈕不可用時**保留顯示原因**，而不是隱藏——使用者要看得到缺什麼。
import { query, exec } from "../../../../../packages/database/src/psql.ts";
import type { Session } from "../../../../../packages/auth/src/session.ts";
import type { AuthenticatedContext } from "../../http/context.ts";
import { esc, page, type Respond } from "../../http/respond.ts";
import { engagementRolesOf, tenantRolesOf } from "../engagements/access.ts";
import { audit } from "../audit.ts";
import { loadPeriod, type PeriodCtx } from "../periods/access.ts";

// §24.6：折算執行屬 R2；結論選定是批准行為，屬 R4；R3 覆核可讀。
const FX = {
  view:         ["R2", "R3", "R4"],
  selectInputs: ["R2"],
  run:          ["R2"],
  reconcile:    ["R2"],
  replay:       ["R2", "R3"],
  selectRun:    ["R4"],
} as const;

interface Row { [k: string]: string }
const q = (s: Session, sql: string, p: Record<string, string> = {}): Row[] =>
  query<Row>(sql, p, { tenantId: s.tenantId });

/** 期間層授權。DB 的函式仍會再驗一次角色——這裡只是第一道。 */
function gate(ctx: AuthenticatedContext, send: Respond, action: keyof typeof FX,
              revision: string): { ok: false } | { ok: true; p: PeriodCtx } {
  const s = ctx.session;
  const p = loadPeriod(s, revision);
  if (!p) { send(404, page("404", "", "<h2>期間不存在</h2>")); return { ok: false }; }
  const roles = engagementRolesOf(s, p.engagement_id);
  const allowed = FX[action] as readonly string[];
  if (!allowed.some((r) => roles.has(r))) {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", `b06.fx.${action}.denied`, s.userId,
      "period_revision", p.period_revision_id,
      { code: "ROLE_REQUIRED", reason: `本動作需本案件的 ${allowed.join("／")} 角色（§24.6）`,
        action, engagement_roles: [...roles].sort(), tenant_roles: [...tenantRolesOf(s)].sort() });
    send(403, page("拒絕", "<b>⛔ 無權執行</b>",
      `<h2>⛔ 本動作需本案件的 ${esc(allowed.join("／"))} 角色</h2>
       <p>此次嘗試已寫入稽核軌跡。</p><p><a href="/b06/fx?revision=${revision}">← 回折算頁</a></p>`));
    return { ok: false };
  }
  return { ok: true, p };
}

const readiness = (s: Session, fn: string, rev: string): Row[] =>
  q(s, `SELECT seq::text, condition, ok::text, COALESCE(code,'') AS code,
               COALESCE(detail,'') AS detail
          FROM ${fn}(:'r'::uuid) ORDER BY seq`, { r: rev });

const rdyTable = (rows: Row[]): string =>
  `<table><tr><th>#</th><th>條件</th><th>結果</th><th>代碼</th><th>說明</th></tr>` +
  rows.map((r) => `<tr><td>${esc(r.seq)}</td><td>${esc(r.condition)}</td>
    <td><span class="badge st-${r.ok === "true" ? "ACCEPTED" : "QUARANTINED"}">${
      r.ok === "true" ? "通過" : "未達成"}</span></td>
    <td><code>${esc(r.code)}</code></td><td class="note">${esc(r.detail)}</td></tr>`).join("") +
  `</table>`;

/** 未通過時的第一個代碼——按鈕停用的原因就是它。 */
const firstBlocker = (rows: Row[]): string =>
  rows.find((r) => r.ok !== "true")?.code ?? "";

const btn = (label: string, action: string, hidden: Record<string, string>,
             blocker: string, blockerText: string): string =>
  blocker
    ? `<span class="note">⛔ ${esc(label)}：<code>${esc(blocker)}</code>　${esc(blockerText)}</span>`
    : `<form method="post" action="${action}" style="display:inline">${
        Object.entries(hidden).map(([k, v]) =>
          `<input type="hidden" name="${k}" value="${esc(v)}">`).join("")
      }<button>${esc(label)}</button></form>`;

export async function fxPage(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const rev = ctx.url.searchParams.get("revision") ?? "";
  const g = gate(ctx, send, "view", rev); if (!g.ok) return;
  const s = ctx.session; const p = g.p;
  const roles = engagementRolesOf(s, p.engagement_id);
  const inRdy = readiness(s, "fn_period_fx_input_readiness", rev);
  const resRdy = readiness(s, "fn_period_fx_result_readiness", rev);
  const inBlock = firstBlocker(inRdy);
  const resReady = q(s, `SELECT fn_period_fx_result_ready(:'r'::uuid) AS v`, { r: rev })[0]?.v ?? "";

  const sel = q(s, `SELECT s.input_selection_id, s.version_no::text, cr.request_content_hash,
                           erv.label AS rate_label, erv.status AS rate_status,
                           tpv.label AS policy_label,
                           (tpv.approved_at IS NOT NULL)::text AS policy_approved
                      FROM period_fx_input_selection s
                      JOIN calculation_run cr ON cr.calculation_run_id = s.source_run_id
                      JOIN exchange_rate_version erv ON erv.rate_version_id = s.exchange_rate_version_id
                      JOIN translation_policy_version tpv
                        ON tpv.policy_version_id = s.translation_policy_version_id
                     WHERE s.input_selection_id = fn_current_fx_input_selection(:'r'::uuid)`,
                  { r: rev })[0];

  const runs = q(s, `SELECT cr.calculation_run_id, cr.status, cr.engine_version,
                            COALESCE(cr.replay_of_run_id::text,'') AS replay_of,
                            COALESCE(cr.failure_reason_code,'') AS fail_code,
                            left(COALESCE(cr.result_content_hash,''),12) AS rhash,
                            COALESCE(rc.reconciliation_id::text,'') AS recon,
                            (SELECT count(*)::text FROM translation_difference d
                              WHERE d.reconciliation_id = rc.reconciliation_id) AS diffs
                       FROM calculation_run cr
                       JOIN calculation_input_manifest m ON m.manifest_id = cr.manifest_id
                       LEFT JOIN translation_reconciliation rc
                         ON rc.calculation_run_id = cr.calculation_run_id
                      WHERE cr.period_revision_id = :'r'::uuid
                        AND m.calculation_scope = 'FX_TRANSLATION'
                      ORDER BY cr.created_at`, { r: rev });

  const cur = q(s, `SELECT rs.selected_run_id, rs.version_no::text, u.display_name AS by_name
                      FROM period_fx_run_selection rs
                      JOIN app_user u ON u.user_id = rs.selected_by
                     WHERE rs.run_selection_id = fn_current_fx_run_selection(:'r'::uuid)`,
                { r: rev })[0];

  // 選定結論的折算結果（報告幣）與 CTA
  const lines = cur ? q(s, `SELECT b.account_code, b.posting_layer, tr.currency_code,
                                   tr.result_debit, tr.result_credit
                              FROM translation_result tr
                              JOIN balance_snapshot_line b
                                ON b.snapshot_line_id = tr.source_snapshot_line_id
                             WHERE tr.calculation_run_id = :'x'::uuid
                             ORDER BY b.account_code`, { x: cur.selected_run_id }) : [];
  const cta = cur ? q(s, `SELECT a.code, a.name, tl.debit, tl.credit, te.rule_type
                            FROM translation_adjustment_line tl
                            JOIN translation_adjustment_entry te
                              ON te.translation_entry_id = tl.translation_entry_id
                            JOIN account a ON a.account_id = tl.account_id
                           WHERE te.calculation_run_id = :'x'::uuid`,
                          { x: cur.selected_run_id })[0] : undefined;
  const diffs = cur ? q(s, `SELECT d.check_id, d.reason_class, d.resolution_status,
                                   COALESCE(d.account_code,'') AS account_code,
                                   d.actual_difference, d.comparison_context, d.detail
                              FROM translation_difference d
                              JOIN translation_reconciliation rc USING (reconciliation_id)
                             WHERE rc.calculation_run_id = :'x'::uuid ORDER BY d.line_no`,
                            { x: cur.selected_run_id }) : [];

  // 選項（僅在需要時查）
  const opts = roles.has("R2") ? {
    src: q(s, `SELECT cr.calculation_run_id, left(cr.calculation_run_id::text,8) AS short
                 FROM calculation_run cr
                 JOIN calculation_input_manifest m ON m.manifest_id = cr.manifest_id
                WHERE cr.period_revision_id = :'r'::uuid AND cr.status = 'COMPLETED'
                  AND m.calculation_scope = 'NO_FX' ORDER BY cr.created_at DESC`, { r: rev }),
    rate: q(s, `SELECT rate_version_id, label FROM exchange_rate_version
                 WHERE engagement_id = :'e'::uuid AND status = 'APPROVED' ORDER BY label`,
              { e: p.engagement_id }),
    pol: q(s, `SELECT policy_version_id, label FROM translation_policy_version
                WHERE engagement_id = :'e'::uuid AND approved_at IS NOT NULL ORDER BY label`,
             { e: p.engagement_id }),
    tol: q(s, `SELECT tolerance_version_id, source_currency || '→' || target_currency ||
                      '（單筆 ' || single_limit || '／累積 ' || cumulative_limit || '）' AS label
                 FROM rounding_tolerance_version
                WHERE engagement_id = :'e'::uuid AND approved_at IS NOT NULL ORDER BY label`,
             { e: p.engagement_id }),
  } : null;

  const sel1 = (name: string, rows: Row[], idKey: string, labelKey: string) =>
    `<select name="${name}">${rows.map((r) =>
      `<option value="${r[idKey]}">${esc(r[labelKey] ?? "")}</option>`).join("")}</select>`;

  const ctxBar =
    `<span>畫面 <b>B-06 折算與核對</b></span><span>客戶 <b>${esc(p.client)}</b></span>` +
    `<span>單位 <b>${esc(p.unit)}</b></span><span>期間 <b>${esc(p.period_label)}</b></span>` +
    `<span>狀態 <b>${esc(p.status)}</b></span>`;

  return send(200, page("B-06 折算與核對", ctxBar, `
    <h2>折算輸入（現行選定）</h2>
    ${sel ? `<p>來源 run ｜匯率版本 <b>${esc(sel.rate_label)}</b>（${esc(sel.rate_status)}）
             ｜政策 <b>${esc(sel.policy_label)}</b>（${sel.policy_approved === "true" ? "已批准" : "未批准"}）
             ｜第 ${esc(sel.version_no)} 版</p>`
          : `<p class="note">尚未選定折算輸入。</p>`}
    ${opts ? `<form class="up" method="post" action="/b06/fx/select-inputs">
        <input type="hidden" name="revision" value="${rev}">
        來源 run ${sel1("source_run", opts.src, "calculation_run_id", "short")}
        匯率版本 ${sel1("rate_version", opts.rate, "rate_version_id", "label")}
        折算政策 ${sel1("policy_version", opts.pol, "policy_version_id", "label")}
        <button>選定輸入（R2）</button>
        <span class="note">選輸入是作業；選結論是 R4 的批准。</span>
      </form>` : ""}

    <h2>G-07 輸入就緒</h2>
    ${rdyTable(inRdy)}
    <p>${btn("執行折算（R2）", "/b06/fx/run", { revision: rev }, inBlock,
             "輸入就緒未通過，折算不會產生任何 run（output_capability = NONE）")}</p>

    <h2>本期折算 run</h2>
    ${runs.length ? `<table><tr><th>run</th><th>狀態</th><th>結果雜湊</th><th>調節</th>
        <th>差異</th><th>動作</th></tr>${runs.map((r) => `<tr>
        <td>${r.calculation_run_id.slice(0, 8)}${r.replay_of ? "<br><span class=\"note\">replay</span>" : ""}</td>
        <td><span class="badge st-${r.status === "COMPLETED" ? "ACCEPTED" : "QUARANTINED"}">${esc(r.status)}</span>
            ${r.fail_code ? `<br><code>${esc(r.fail_code)}</code>` : ""}</td>
        <td><code>${esc(r.rhash)}</code></td>
        <td>${r.recon ? "已完成" : "—"}</td>
        <td>${r.recon ? esc(r.diffs) : "—"}</td>
        <td>${r.status === "COMPLETED" && !r.replay_of ? `
          ${!r.recon && opts ? `<form method="post" action="/b06/fx/reconcile" style="display:inline">
             <input type="hidden" name="revision" value="${rev}">
             <input type="hidden" name="run" value="${r.calculation_run_id}">
             ${opts.tol.length ? sel1("tolerance", opts.tol, "tolerance_version_id", "label")
                               : `<span class="note">無已批准的容許值版本</span>`}
             ${opts.tol.length ? `<button>產生調節結果（R2）</button>` : ""}</form>` : ""}
          ${r.recon && roles.has("R4") ? `<form method="post" action="/b06/fx/select-run" style="display:inline">
             <input type="hidden" name="revision" value="${rev}">
             <input type="hidden" name="run" value="${r.calculation_run_id}">
             <input type="hidden" name="recon" value="${r.recon}">
             <button>選定現行結論（R4）</button></form>` : ""}
          ${roles.has("R2") || roles.has("R3") ? `<form method="post" action="/b06/fx/replay" style="display:inline">
             <input type="hidden" name="revision" value="${rev}">
             <input type="hidden" name="run" value="${r.calculation_run_id}">
             <button>重演</button></form>` : ""}` : ""}</td></tr>`).join("")}</table>`
      : `<p class="note">本期尚無折算 run。</p>`}

    <h2>現行結論</h2>
    <p class="note">「產生調節結果」是 R2 執行的**系統核對**，不是 R3 的專業覆核——
       期間尚未進入 <code>RECONCILING</code>。「選定現行結論」是 R4 指定本期採用哪一版
       折算結果，**不是最終交付批准**：期間包的最終批准在折算與核對之後（§25.3），
       本頁不解鎖任何期間遷移。</p>
    ${cur ? `<p>run ${esc(cur.selected_run_id.slice(0, 8))}　由 ${esc(cur.by_name)} 選定（第 ${esc(cur.version_no)} 版）</p>
      <table><tr><th>科目</th><th>分層</th><th>幣別</th><th>借</th><th>貸</th></tr>
      ${lines.map((l) => `<tr><td>${esc(l.account_code)}</td><td>${esc(l.posting_layer)}</td>
        <td>${esc(l.currency_code)}</td><td>${esc(l.result_debit)}</td>
        <td>${esc(l.result_credit)}</td></tr>`).join("")}</table>
      ${cta ? `<p><b>外幣報表折算差額（CTA）</b>：${esc(cta.code)} ${esc(cta.name)}　
        借 ${esc(cta.debit)}／貸 ${esc(cta.credit)}　（${esc(cta.rule_type)}，已物化為折算調整分錄）</p>`
            : `<p class="note">本 run 無 CTA。</p>`}
      <h3>調節差異</h3>
      ${diffs.length ? `<table><tr><th>檢查</th><th>科目</th><th>類別</th><th>比較基準</th>
        <th>差額</th><th>狀態</th><th>說明</th></tr>${diffs.map((d) => `<tr>
        <td>${esc(d.check_id)}</td><td>${esc(d.account_code)}</td>
        <td><code>${esc(d.reason_class)}</code></td><td class="note">${esc(d.comparison_context)}</td>
        <td>${esc(d.actual_difference)}</td><td>${esc(d.resolution_status)}</td>
        <td class="note">${esc(d.detail)}</td></tr>`).join("")}</table>`
        : `<p class="note">零差異。內部核對只會產生零差異或硬差異——不產生尾差。</p>`}`
      : `<p class="note">尚未選定現行結論。</p>`}

    <h2>折算結果就緒</h2>
    ${rdyTable(resRdy)}
    <p>整體結論：<code>${esc(resReady)}</code>
       ${resReady === "POST_FX_RECONCILIATION_READY"
         ? `<span class="note">——期間主線的其餘守衛（G-03 等）仍未實作，本頁不解鎖任何遷移。</span>`
         : ""}</p>
    <p><a href="/b02?revision=${rev}">← 回 B-02 期間工作台</a></p>`));
}

// ── 動作。DB 函式仍會再驗角色與父鏈；這裡只轉成 HTTP。 ──
const fail = (send: Respond, rev: string, e: unknown): void => {
  const m = String(e).replace(/^Error: psql: ERROR:\s*/, "").split("\n")[0];
  send(409, page("折算被拒", "<b>⛔</b>",
    `<h2>⛔ 動作被拒</h2><p>${esc(m)}</p>
     <p class="note">此判定來自資料庫守衛，畫面不重寫規則。</p>
     <p><a href="/b06/fx?revision=${rev}">← 回折算頁</a></p>`),
    { "x-error-code": m.split(":")[0] });
};
const back = (send: Respond, rev: string): void =>
  send(302, "", { location: `/b06/fx?revision=${rev}` });

async function act(ctx: AuthenticatedContext, send: Respond, action: keyof typeof FX,
                   run: (rev: string, f: Record<string, string>, actor: string) => void): Promise<void> {
  const f = await ctx.form();
  const rev = f["revision"] ?? "";
  const g = gate(ctx, send, action, rev); if (!g.ok) return;
  try { run(rev, f, ctx.session.userId); back(send, rev); } catch (e) { fail(send, rev, e); }
}

export const fxSelectInputs = (c: AuthenticatedContext, s: Respond) =>
  act(c, s, "selectInputs", (rev, f, actor) =>
    exec(`SELECT fn_period_fx_select_inputs(:'r'::uuid, :'s'::uuid, :'x'::uuid, :'p'::uuid, :'a'::uuid)`,
      { r: rev, s: f["source_run"] ?? "", x: f["rate_version"] ?? "",
        p: f["policy_version"] ?? "", a: actor }, { tenantId: c.session.tenantId }));

export const fxRun = (c: AuthenticatedContext, s: Respond) =>
  act(c, s, "run", (rev, _f, actor) => {
    const sel = query<Row>(
      `SELECT s.source_run_id, s.exchange_rate_version_id, s.translation_policy_version_id,
              s.reporting_unit_id, rp.engagement_id
         FROM period_fx_input_selection s
         JOIN period_revision pr ON pr.period_revision_id = s.period_revision_id
         JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
        WHERE s.input_selection_id = fn_current_fx_input_selection(:'r'::uuid)`,
      { r: rev }, { tenantId: c.session.tenantId })[0];
    if (!sel) throw new Error("Error: psql: ERROR:  FX_INPUT_NOT_SELECTED: 本期尚未選定折算輸入");
    exec(`SELECT fn_fx_translation_run(:'t'::uuid, :'e'::uuid, :'r'::uuid, :'u'::uuid,
             :'s'::uuid, :'x'::uuid, :'p'::uuid, :'a'::uuid, 'fx-1.0.0')`,
      { t: c.session.tenantId, e: sel.engagement_id, r: rev, u: sel.reporting_unit_id,
        s: sel.source_run_id, x: sel.exchange_rate_version_id,
        p: sel.translation_policy_version_id, a: actor }, { tenantId: c.session.tenantId });
  });

export const fxReconcile = (c: AuthenticatedContext, s: Respond) =>
  act(c, s, "reconcile", (rev, f, actor) =>
    exec(`SELECT fn_translation_reconcile(:'x'::uuid, :'t'::uuid, :'a'::uuid, 'recon-1.0.0')`,
      { x: f["run"] ?? "", t: f["tolerance"] ?? "", a: actor }, { tenantId: c.session.tenantId }));

export const fxSelectRun = (c: AuthenticatedContext, s: Respond) =>
  act(c, s, "selectRun", (rev, f, actor) =>
    exec(`SELECT fn_period_fx_select_run(:'r'::uuid, :'x'::uuid, :'c'::uuid, :'a'::uuid)`,
      { r: rev, x: f["run"] ?? "", c: f["recon"] ?? "", a: actor },
      { tenantId: c.session.tenantId }));

export const fxReplay = (c: AuthenticatedContext, s: Respond) =>
  act(c, s, "replay", (rev, f, actor) =>
    exec(`SELECT fn_fx_translation_replay(:'x'::uuid, :'a'::uuid, 'fx-1.0.0')`,
      { x: f["run"] ?? "", a: actor }, { tenantId: c.session.tenantId }));
