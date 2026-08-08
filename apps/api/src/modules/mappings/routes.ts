// B-04 科目映射的 HTTP route（SLICE-M2-01）。
//
// 授權**逐動作**判斷（見 imports/guard.ts 的 B04 表），不再共用一個萬用守衛：
//   /b04 GET  R2／R3／R4     /b04/preview  R2／R3／R4／R7
//   /b04/map  R2／R7          /b04/approve  R4          /b04/submit  R2
// 一律只看案件層授權；租戶層角色不得隱式取得客戶資料。
import { randomUUID } from "node:crypto";
import { query, exec } from "../../../../../packages/database/src/psql.ts";
import { applyMappings, coverage, g02Check, totalsOf, fmtCents }
  from "../../../../../packages/domain/src/mapping.ts";
import { acceptancePredicate } from "../../../../../packages/domain/src/importBatch.ts";
import type { AuthenticatedContext } from "../../http/context.ts";
import { esc, page, type Respond } from "../../http/respond.ts";
import { audit, auditSql } from "../audit.ts";
import { batchGate, B04 } from "../imports/guard.ts";
import { b04CtxBar } from "../imports/views.ts";
import { tbLines, currentMappings } from "./access.ts";

// ── B-04 映射工作畫面 ──
export async function view(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const g = batchGate(ctx, send, ctx.url.searchParams.get("batch") ?? "", "b04.view", B04.view);
  if (!g.ok) return;
  const lines = tbLines(s, g.b.import_batch_id);
  const maps = currentMappings(s, g.b.engagement_id, g.b.period_end);
  const { rows, unmapped } = applyMappings(lines, maps);
  const cov = coverage(lines, maps);
  const bySource = new Map(maps.map((m) => [m.sourceAccountCode, m]));
  const drafts = query<Record<string, string>>(
    `SELECT mr.mapping_rule_id, mr.source_account_code, mr.version_no, mr.created_by,
            a.code AS target_code, a.name AS target_name
       FROM mapping_rule mr JOIN account a ON a.account_id = mr.target_account_id
      WHERE mr.engagement_id = :'e'::uuid AND mr.approved_at IS NULL
      ORDER BY mr.source_account_code, mr.version_no`,
    { e: g.b.engagement_id }, { tenantId: s.tenantId });
  const accounts = query<Record<string, string>>(
    `SELECT a.account_id, a.code, a.name FROM account a
       JOIN chart_of_accounts c ON c.coa_id = a.coa_id
      WHERE c.engagement_id = :'e'::uuid ORDER BY a.code`,
    { e: g.b.engagement_id }, { tenantId: s.tenantId });
  const draftBySource = new Map(drafts.map((d) => [d.source_account_code, d]));
  const fmt = (c: bigint) => c === 0n ? "" : fmtCents(c);
  return send(200, page("B-04 科目與維度映射", b04CtxBar(g.b, "B-04 科目與維度映射"),
    `<h2>映射狀態</h2>
     <p>覆蓋率（按金額）<b>${(cov.ratio * 100).toFixed(1)}%</b>｜
        未映射科目 <b>${cov.unmappedAccounts.length}</b> 個｜
        未映射影響金額（借＋貸）<b>${fmtCents(cov.unmappedCents)}</b></p>
     <table><tr><th>來源科目</th><th>名稱</th><th>借方</th><th>貸方</th><th>映射狀態</th><th>集團科目</th><th>版本</th></tr>
     ${lines.map((l) => {
       const m = bySource.get(l.accountCode);
       const d = draftBySource.get(l.accountCode);
       const st = m ? `<span class="badge st-MATCHED">已映射</span>${d ? ` <span class="badge st-PENDING_CONFIRMATION">草稿待批（衝突檢視）</span>` : ""}`
                    : d ? `<span class="badge st-PENDING_CONFIRMATION">草稿待批</span>`
                        : `<span class="badge st-QUARANTINED">未映射</span>`;
       return `<tr><td>${esc(l.accountCode)}</td><td>${esc(l.accountName)}</td>
         <td style="text-align:right">${fmt(l.debitCents)}</td><td style="text-align:right">${fmt(l.creditCents)}</td>
         <td>${st}</td><td>${m ? esc(`${m.targetCode} ${m.targetName}`) : d ? `<span class="note">${esc(`${d.target_code} ${d.target_name}`)}（草稿）</span>` : "—"}</td>
         <td>${m ? `v${m.versionNo}` : ""}</td></tr>`;
     }).join("")}
     </table>
     <h2>建立映射（草稿 → 需另一自然人批准）</h2>
     <form class="up" method="post" action="/b04/map">
       <input type="hidden" name="batch" value="${g.b.import_batch_id}">
       來源科目 <select name="source_code">${lines.filter((l) => !bySource.has(l.accountCode))
         .map((l) => `<option value="${esc(l.accountCode)}">${esc(l.accountCode)} ${esc(l.accountName)}</option>`).join("")}
         ${lines.filter((l) => bySource.has(l.accountCode))
         .map((l) => `<option value="${esc(l.accountCode)}">${esc(l.accountCode)} ${esc(l.accountName)}（改版）</option>`).join("")}</select>
       → 集團科目 <select name="target">${accounts.map((a) =>
         `<option value="${a.account_id}">${esc(a.code)} ${esc(a.name)}</option>`).join("")}</select>
       <button>建立草稿</button>
     </form>
     ${drafts.length ? `<h2>待批准草稿</h2>
     <table><tr><th>來源科目</th><th>集團科目</th><th>版本</th><th></th></tr>
     ${drafts.map((d) => `<tr><td>${esc(d.source_account_code)}</td>
       <td>${esc(`${d.target_code} ${d.target_name}`)}</td><td>v${d.version_no}</td>
       <td><form method="post" action="/b04/approve" style="margin:0">
         <input type="hidden" name="batch" value="${g.b.import_batch_id}">
         <input type="hidden" name="rule" value="${d.mapping_rule_id}">
         <button>批准（R4）</button></form></td></tr>`).join("")}
     </table><p class="note">建立者不得批准自己的草稿（實例級 SOD；DB 觸發器為最後防線）。</p>` : ""}
     <p><a href="/b04/preview?batch=${g.b.import_batch_id}">→ 產生集團科目 TB 預覽</a>
        　<a href="/b06?batch=${g.b.import_batch_id}">→ B-06 計算執行（PREVIEW Run）</a>
        <form method="post" action="/b04/submit" style="display:inline;margin:0">
          <input type="hidden" name="batch" value="${g.b.import_batch_id}">
          <button>映射完成確認（G-02）</button></form>　<a href="/">回 B-00</a></p>
     <h2>調整（B-05）</h2>
     <form class="up" method="post" action="/b05/create">
       <input type="hidden" name="batch" value="${g.b.import_batch_id}">
       標題 <input name="title" size="40" value="GROUP_GAAP 調整">
       <button>建立調整草稿（R2）</button>
       <span class="note">本切片只收 MAJOR 重大調整，走完整三段式 R2→R3→R4</span>
     </form>
     ${(() => {
       const adjs = query<Record<string, string>>(
         `SELECT adjustment_id, title, status, business_version FROM adjustment
           WHERE engagement_id = :'e'::uuid ORDER BY created_at DESC LIMIT 20`,
         { e: g.b.engagement_id }, { tenantId: s.tenantId });
       return adjs.length ? `<table><tr><th>調整</th><th>狀態</th><th>bv</th><th></th></tr>
         ${adjs.map((a) => `<tr><td>${esc(a.title)}</td>
           <td><span class="badge st-${a.status === "APPROVED" ? "ACCEPTED" : "UPLOADED"}">${a.status}</span></td>
           <td>${esc(a.business_version)}</td>
           <td><a href="/b05?adj=${a.adjustment_id}">開啟 B-05</a></td></tr>`).join("")}</table>` : "";
     })()}`));
}

// ── 建立映射草稿 ──
export async function createMapping(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const fields = await ctx.form();
  const g = batchGate(ctx, send, fields["batch"] ?? "", "mapping.create", B04.map);
  if (!g.ok) return;
  const sourceCode = fields["source_code"] ?? "";
  const target = fields["target"] ?? "";
  // 來源批次必須已接受（0021）：未經接受的批次不得成為正式映射的來源脈絡。
  // 應用層先判定並回穩定機器代碼；DB 觸發器（含 FOR UPDATE）仍是最後防線，
  // 不信任應用層——少了這層，繞過 UI 直接呼叫會得到 DB 例外與 HTTP 500。
  if (g.b.status !== "ACCEPTED") {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "mapping.create.rejected", s.userId,
      "import_batch", g.b.import_batch_id,
      { guard: "SOURCE_BATCH_NOT_ACCEPTED", reason: "映射來源批次尚未接受",
        batch_status: g.b.status, source_code: sourceCode });
    return send(409, page("拒絕", b04CtxBar(g.b, "B-04"),
      `<h2>⛔ SOURCE_BATCH_NOT_ACCEPTED：來源批次尚未接受</h2>
       <p>目前狀態 <b>${esc(g.b.status)}</b>；映射的來源脈絡必須是已接受（ACCEPTED）的批次。</p>
       <p class="note">此次嘗試已寫入稽核軌跡。</p>`),
      { "x-error-code": "SOURCE_BATCH_NOT_ACCEPTED" });
  }
  // 歸屬完整性（§24.1A）：目標科目必須屬於本案件的科目表；DB 觸發器為最後防線
  const okTarget = query<{ n: string }>(
    `SELECT count(*) AS n FROM account a JOIN chart_of_accounts c ON c.coa_id = a.coa_id
      WHERE a.account_id = :'a'::uuid AND c.engagement_id = :'e'::uuid`,
    { a: target, e: g.b.engagement_id }, { tenantId: s.tenantId });
  if (Number(okTarget[0]?.n) !== 1) {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "mapping.create.rejected", s.userId,
      "import_batch", g.b.import_batch_id,
      { guard: "歸屬/§24.1A", reason: "目標科目不屬於本案件", source_code: sourceCode, target });
    return send(403, page("拒絕", b04CtxBar(g.b, "B-04"),
      `<h2>⛔ 歸屬違規：目標科目不屬於本案件的科目表</h2><p>此次嘗試已寫入稽核軌跡。</p>`));
  }
  // 狀態異動與 DomainEvent 同一 statement（事件原子化）：事件寫入失敗＝整句回滾，
  // 不存在「映射已生效而事件不存在」（BACKLOG 2026-08-04 條目）
  const ruleId = randomUUID();
  exec(`WITH ins AS (
          INSERT INTO mapping_rule (mapping_rule_id, tenant_id, engagement_id,
                 source_account_code, target_account_id, version_no, created_by,
                 source_import_batch_id)
          VALUES (:'m'::uuid, :'t'::uuid, :'e'::uuid, :'sc', :'a'::uuid,
                  (SELECT COALESCE(MAX(version_no), 0) + 1 FROM mapping_rule
                    WHERE engagement_id = :'e'::uuid AND source_account_code = :'sc'),
                  :'u'::uuid, :'b'::uuid)
          RETURNING mapping_rule_id, version_no)
        INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
        SELECT :'t'::uuid, 'DOMAIN_EVENT', 'mapping_rule.drafted', :'u'::uuid,
               'mapping_rule', ins.mapping_rule_id,
               jsonb_build_object('source_code', :'sc', 'target', :'a', 'version', ins.version_no)
          FROM ins`,
    { m: ruleId, t: s.tenantId, e: g.b.engagement_id, sc: sourceCode, a: target, u: s.userId,
      b: g.b.import_batch_id },
    { tenantId: s.tenantId });
  return send(302, "", { location: `/b04?batch=${g.b.import_batch_id}` });
}

// ── 批准映射（R4；批准人 ≠ 建立者） ──
export async function approveMapping(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const fields = await ctx.form();
  const g = batchGate(ctx, send, fields["batch"] ?? "", "mapping.approve", B04.approve);
  if (!g.ok) return;
  const ruleId = fields["rule"] ?? "";
  const rule = query<{ created_by: string }>(
    `SELECT created_by FROM mapping_rule
      WHERE mapping_rule_id = :'m'::uuid AND engagement_id = :'e'::uuid AND approved_at IS NULL`,
    { m: ruleId, e: g.b.engagement_id }, { tenantId: s.tenantId })[0];
  if (!rule) return send(404, page("404", b04CtxBar(g.b, "B-04"), "<h2>草稿不存在或已批准</h2>"));
  if (rule.created_by === s.userId) {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "mapping.approve.rejected", s.userId,
      "mapping_rule", ruleId, { guard: "SOD", reason: "建立者不得批准自己建立的映射版本" });
    return send(403, page("拒絕", b04CtxBar(g.b, "B-04"),
      "<h2>⛔ SOD：建立者不得批准自己建立的映射版本</h2><p>此次嘗試已寫入稽核軌跡。</p>"));
  }
  // 批准與事件同一 statement；併發下 UPDATE 落空（已被批准）→ fn_assert 整句回滾
  try {
    exec(`WITH upd AS (
            UPDATE mapping_rule SET approved_by = :'u'::uuid, approved_at = now()
             WHERE mapping_rule_id = :'m'::uuid AND approved_at IS NULL
             RETURNING mapping_rule_id),
          ev AS (
            INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
            SELECT :'t'::uuid, 'DOMAIN_EVENT', 'mapping_rule.approved', :'u'::uuid,
                   'mapping_rule', upd.mapping_rule_id, '{}'::jsonb
              FROM upd)
          SELECT fn_assert(EXISTS (SELECT 1 FROM upd), 'ALREADY_APPROVED')`,
      { u: s.userId, m: ruleId, t: s.tenantId }, { tenantId: s.tenantId });
  } catch (e) {
    if (String(e).includes("ALREADY_APPROVED"))
      return send(409, page("拒絕", b04CtxBar(g.b, "B-04"),
        "<h2>⛔ 草稿已被批准或不存在（併發）</h2>"));
    throw e;
  }
  return send(302, "", { location: `/b04?batch=${g.b.import_batch_id}` });
}

// ── 集團科目 TB 預覽（非正式輸出；§25.9 output_capability=PREVIEW） ──
export async function preview(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const g = batchGate(ctx, send, ctx.url.searchParams.get("batch") ?? "", "b04.preview", B04.preview);
  if (!g.ok) return;
  if (g.b.status !== "ACCEPTED")
    return send(409, page("拒絕", b04CtxBar(g.b, "B-04 預覽"),
      `<h2>⛔ 批次尚未 ACCEPTED，不產生預覽</h2><p><a href="/">回 B-00</a></p>`));
  const lines = tbLines(s, g.b.import_batch_id);
  const maps = currentMappings(s, g.b.engagement_id, g.b.period_end);
  const { rows, unmapped } = applyMappings(lines, maps);
  const cov = coverage(lines, maps);
  const g02 = g02Check(cov);
  const src = totalsOf(lines);
  const grp = totalsOf(rows);
  const un = totalsOf(unmapped);
  const tied = grp.debitCents + un.debitCents === src.debitCents
            && grp.creditCents + un.creditCents === src.creditCents;
  audit(s.tenantId, "DOMAIN_EVENT", "group_tb.preview_generated", s.userId,
    "import_batch", g.b.import_batch_id,
    { mapped_rows: rows.length, unmapped: cov.unmappedAccounts.length, g02_ok: g02.ok });
  const fmt = (c: bigint) => c === 0n ? "" : fmtCents(c);
  return send(200, page("集團科目 TB（預覽）", b04CtxBar(g.b, "B-04 集團 TB 預覽"),
    `<div style="background:#fff3e0;border:1px solid #d9a05b;border-radius:6px;padding:10px 14px;font-weight:600">
       PREVIEW（預覽）——非正式輸出、未經覆核批准，不得作為入帳或交付依據
     </div>
     <p>G-02 ${g02.ok ? `<span class="badge st-MATCHED">通過</span>`
                      : `<span class="badge st-QUARANTINED">阻擋</span> ${(g02 as { reasons: string[] }).reasons.map(esc).join("；")}`}</p>
     <h2>集團科目 TB</h2>
     <table><tr><th>集團科目</th><th>名稱</th><th>借方</th><th>貸方</th><th>來源科目</th></tr>
     ${rows.map((r) => `<tr><td>${esc(r.targetCode)}</td><td>${esc(r.targetName)}</td>
       <td style="text-align:right">${fmt(r.debitCents)}</td><td style="text-align:right">${fmt(r.creditCents)}</td>
       <td class="note">${r.sourceCodes.map(esc).join("、")}</td></tr>`).join("")}
     ${unmapped.length ? `<tr><td colspan="2"><b>未映射（不得靜默吸收）</b></td><td></td><td></td><td></td></tr>` +
       unmapped.map((l) => `<tr><td>—</td><td>${esc(l.accountCode)} ${esc(l.accountName)}</td>
         <td style="text-align:right">${fmt(l.debitCents)}</td><td style="text-align:right">${fmt(l.creditCents)}</td>
         <td><span class="badge st-QUARANTINED">未映射</span></td></tr>`).join("") : ""}
     </table>
     <h2>控制總額勾稽</h2>
     <table><tr><th></th><th>借方</th><th>貸方</th></tr>
     <tr><td>來源 TB</td><td style="text-align:right">${fmtCents(src.debitCents)}</td><td style="text-align:right">${fmtCents(src.creditCents)}</td></tr>
     <tr><td>集團 TB（含未映射）</td><td style="text-align:right">${fmtCents(grp.debitCents + un.debitCents)}</td><td style="text-align:right">${fmtCents(grp.creditCents + un.creditCents)}</td></tr>
     <tr><td>勾稽</td><td colspan="2">${tied ? `<span class="badge st-MATCHED">一致</span>` : `<span class="badge st-QUARANTINED">不一致</span>`}</td></tr>
     </table>
     <p><a href="/b04?batch=${g.b.import_batch_id}">← 回 B-04</a></p>`));
}

// ── 映射完成確認（G-02 守衛；繞過 UI 直接呼叫亦被擋並留痕） ──
export async function submitMapping(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const fields = await ctx.form();
  const g = batchGate(ctx, send, fields["batch"] ?? "", "mapping.submit", B04.submit);
  if (!g.ok) return;
  if (g.b.status !== "ACCEPTED")
    return send(409, page("拒絕", b04CtxBar(g.b, "B-04"), "<h2>⛔ 批次尚未 ACCEPTED</h2>"));
  const cov = coverage(tbLines(s, g.b.import_batch_id), currentMappings(s, g.b.engagement_id, g.b.period_end));
  const g02 = g02Check(cov);
  if (!g02.ok) {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "mapping.submit.rejected", s.userId,
      "import_batch", g.b.import_batch_id,
      { guard: "G-02", reasons: g02.reasons, unmapped_cents: String(cov.unmappedCents) });
    return send(409, page("G-02 阻擋", b04CtxBar(g.b, "B-04"),
      `<h2>⛔ G-02：重要來源餘額尚未全數映射</h2>
       <ul>${g02.reasons.map((r) => `<li>${esc(r)}</li>`).join("")}</ul>
       <p class="note">映射例外批准機制屬後續切片；本切片任何未映射餘額即阻擋。</p>
       <p><a href="/b04?batch=${g.b.import_batch_id}">回 B-04 處理未映射科目</a></p>`));
  }
  audit(s.tenantId, "DOMAIN_EVENT", "mapping.review_ready", s.userId,
    "import_batch", g.b.import_batch_id, { coverage_ratio: cov.ratio });
  return send(200, page("G-02 通過", b04CtxBar(g.b, "B-04"),
    `<h2>✓ G-02 通過：映射完成，可進入覆核</h2>
     <p class="note">期間狀態機（IN_PREPARATION → IN_REVIEW）屬後續切片；本次僅記錄 DomainEvent。</p>
     <p><a href="/b04/preview?batch=${g.b.import_batch_id}">查看集團 TB 預覽</a>　<a href="/">回 B-00</a></p>`));
}

// ═══════════ SLICE-M2-02A：B-05 調整編製・覆核・批准 ═══════════
// 契約：docs/slices/SLICE-M2-02A_調整生命週期.md
// 三個守衛掛在三個不同的狀態遷移；DB 觸發器（0007）為最後防線。
