// B-07 預覽證據包的 HTTP route（SLICE-M2-02C）。
//
// 授權一律案件層且沿父鏈反查（見 guard.ts）。CVA 記在**動作自己的物件**上：
// 建立與清單記 calculation_run，檢視與下載記 evidence_package——
// 把 package 的越權記成 import_batch，稽核軌跡就答不出「他想拿的是哪一份」。
import { createHash, randomUUID } from "node:crypto";
import { query, exec } from "../../../../../packages/database/src/psql.ts";
import { RENDER_VERSION, PKG_REASON, type PkgReasonCode }
  from "../../../../../packages/domain/src/evidencePackage.ts";
import { idempotencyKey } from "../../../../../packages/domain/src/backgroundJob.ts";
import { getObject } from "../../../../../packages/database/src/objectstore.ts";
import { config } from "../../../../../packages/config/src/index.ts";
import type { AuthenticatedContext } from "../../http/context.ts";
import { esc, page, type Respond } from "../../http/respond.ts";
import { audit } from "../audit.ts";
import type { BatchCtx } from "../imports/access.ts";
import { b04CtxBar } from "../imports/views.ts";
import { runGate } from "../calculations/guard.ts";
import { packageGate, B07 } from "./guard.ts";

const b07Refuse = (ctx: AuthenticatedContext, send: Respond, b: BatchCtx | null,
                   action: string, code: PkgReasonCode,
                   ref: { objectType: string; objectId: string }, detail = ""): void => {
  const s = ctx.session;
  audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", action, s.userId,
    ref.objectType, ref.objectId,
    { code, reason: PKG_REASON[code], detail });
  send(code === "ROLE_REQUIRED" ? 403 : 409,
    page("拒絕", b ? b04CtxBar(b, "B-07") : "<b>⛔</b>",
      `<h2>⛔ ${esc(code)}</h2><p>${esc(PKG_REASON[code])}</p>` +
      (detail ? `<p class="note">${esc(detail)}</p>` : "") +
      `<p>此次嘗試已寫入稽核軌跡。</p><p><a href="/">回 B-00</a></p>`));
};

// ── 產包（precheck 同步 → Package(GENERATING)＋Job＋事件同交易；產生非同步） ──
export async function createPackage(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const f = await ctx.form();
  // 歸屬沿 run → batch → engagement 反查；CVA 記在 calculation_run 上
  const rg = runGate(ctx, send, f["run"] ?? "", "evidence.create", B07.create,
    `SELECT calculation_run_id, import_batch_id, engagement_id, status, run_type
       FROM calculation_run r WHERE r.calculation_run_id = :'r'::uuid`,
    { objectType: "calculation_run", objectId: f["run"] ?? "" });
  if (!rg.ok) return;
  const run = rg.run, g = rg.b;
  if (run.status !== "COMPLETED")
    return b07Refuse(ctx, send, g.b, "evidence.create.rejected", "RUN_NOT_COMPLETED",
      { objectType: "calculation_run", objectId: run.calculation_run_id }, `run 目前為 ${run.status}`);
  // G-09 復驗（precheck；worker 終態交易另有契約 D 全套）
  const tot = query<{ ok: boolean }>(
    `SELECT COALESCE(SUM(debit),0) = COALESCE(SUM(credit),0) AS ok
       FROM balance_snapshot_line WHERE calculation_run_id = :'r'::uuid`,
    { r: run.calculation_run_id }, { tenantId: s.tenantId })[0];
  if (!tot?.ok)
    return b07Refuse(ctx, send, g.b, "evidence.create.rejected", "CONTROL_TOTAL_MISMATCH",
      { objectType: "calculation_run", objectId: run.calculation_run_id });
  const cutoff = query<{ id: string }>(
    `SELECT audit_event_id::text AS id FROM audit_event
      WHERE event_type='calculation_run.completed' AND object_id = :'r'::uuid
      ORDER BY audit_event_id LIMIT 1`,
    { r: run.calculation_run_id }, { tenantId: s.tenantId })[0];
  if (!cutoff)
    return b07Refuse(ctx, send, g.b, "evidence.create.rejected", "CUTOFF_EVENT_MISSING",
      { objectType: "calculation_run", objectId: run.calculation_run_id });
  const requestKey = f["request_key"] ?? "";
  if (!/^[0-9a-f-]{36}$/.test(requestKey))
    return send(400, page("錯誤", b04CtxBar(g.b, "B-07"), "<h2>request_key 缺漏或格式錯誤</h2>"));
  const rch = createHash("sha256")
    .update(`B07PKG|${run.calculation_run_id}|${RENDER_VERSION}`).digest("hex");
  const existing = query<{ package_id: string; request_content_hash: string }>(
    `SELECT package_id, request_content_hash FROM evidence_package
      WHERE request_key = :'rk'::uuid`, { rk: requestKey }, { tenantId: s.tenantId });
  if (existing[0]) {
    if (existing[0].request_content_hash === rch)
      return send(302, "", { location: `/b07/package?id=${existing[0].package_id}` });
    return b07Refuse(ctx, send, g.b, "evidence.create.rejected", "REQUEST_KEY_REUSED",
      { objectType: "calculation_run", objectId: run.calculation_run_id });
  }
  const pkgId = randomUUID();
  const ik = idempotencyKey("EVIDENCE_PACKAGE", pkgId, 1, RENDER_VERSION);
  try {
    exec(`BEGIN;
      INSERT INTO evidence_package (package_id, tenant_id, engagement_id, calculation_run_id,
        request_key, request_content_hash, audit_cutoff_event_id, render_version, created_by)
      VALUES (:'p'::uuid, :'t'::uuid, :'e'::uuid, :'r'::uuid,
        :'rk'::uuid, :'rch', :'cut'::bigint, :'rv', :'u'::uuid);
      INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version,
        rule_version, idempotency_key, max_attempts)
      VALUES (:'t'::uuid, 'EVIDENCE_PACKAGE', :'p'::uuid, 1, :'rv', :'ik', ${config.jobMaxAttempts});
      INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
      VALUES (:'t'::uuid, 'DOMAIN_EVENT', 'evidence_package.created', :'u'::uuid,
        'evidence_package', :'p'::uuid,
        jsonb_build_object('run', :'r', 'cutoff', (:'cut')::bigint, 'render', :'rv'));
      COMMIT;`,
      { p: pkgId, t: s.tenantId, e: run.engagement_id, r: run.calculation_run_id,
        rk: requestKey, rch, rv: RENDER_VERSION, u: s.userId, ik, cut: cutoff.id },
      { tenantId: s.tenantId });
  } catch (e) {
    const msg = String(e);
    if (msg.includes("evidence_package_tenant_id_request_key_key")) {
      const again = query<{ package_id: string; request_content_hash: string }>(
        `SELECT package_id, request_content_hash FROM evidence_package
          WHERE request_key = :'rk'::uuid`, { rk: requestKey }, { tenantId: s.tenantId });
      if (again[0]?.request_content_hash === rch)
        return send(302, "", { location: `/b07/package?id=${again[0].package_id}` });
      return b07Refuse(ctx, send, g.b, "evidence.create.rejected", "REQUEST_KEY_REUSED",
      { objectType: "calculation_run", objectId: run.calculation_run_id });
    }
    throw e;
  }
  return send(302, "", { location: `/b07/package?id=${pkgId}` });
}

// ── B-07 清單 ──
export async function list(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const rg = runGate(ctx, send, ctx.url.searchParams.get("run") ?? "", "b07.view", B07.list,
    `SELECT calculation_run_id, import_batch_id, engagement_id, status, run_type
       FROM calculation_run r WHERE r.calculation_run_id = :'r'::uuid`,
    { objectType: "calculation_run", objectId: ctx.url.searchParams.get("run") ?? "" });
  if (!rg.ok) return;
  const run = rg.run, g = rg.b;
  const pkgs = query<Record<string, string>>(
    `SELECT p.package_id, p.status, p.failure_reason_code, p.created_at,
            p.package_content_hash, j.status AS job_status, j.attempt_count
       FROM evidence_package p
       LEFT JOIN background_job j ON j.subject_id = p.package_id AND j.job_type='EVIDENCE_PACKAGE'
      WHERE p.calculation_run_id = :'r'::uuid ORDER BY p.created_at DESC LIMIT 20`,
    { r: run.calculation_run_id }, { tenantId: s.tenantId });
  return send(200, page("B-07 證據包", b04CtxBar(g.b, "B-07 交付、預覽與證據包"),
    `<h2>預覽證據包（run ${run.calculation_run_id.slice(0, 8)}）</h2>
     <p class="note">預覽級底稿：DRAFT・UNREVIEWED・未折算——不建立交付紀錄。</p>
     <form class="up" method="post" action="/b07/package">
       <input type="hidden" name="run" value="${run.calculation_run_id}">
       <input type="hidden" name="request_key" value="${randomUUID()}">
       <button>產生預覽證據包（R2／R3／R4）</button>
     </form>
     <table><tr><th>Package</th><th>狀態</th><th>Job</th><th>package hash</th><th>建立</th><th></th></tr>
     ${pkgs.map((p) => `<tr><td>${p.package_id.slice(0, 8)}</td>
       <td><span class="badge st-${p.status === "READY" ? "ACCEPTED" : p.status === "FAILED" ? "QUARANTINED" : "UPLOADED"}">${p.status}</span>${p.failure_reason_code ? ` <span class="note">${esc(p.failure_reason_code)}</span>` : ""}</td>
       <td>${esc(p.job_status ?? "")}（${esc(p.attempt_count ?? "0")}）</td>
       <td class="note">${(p.package_content_hash ?? "").slice(0, 12)}</td>
       <td class="note">${esc(String(p.created_at).slice(0, 19))}</td>
       <td><a href="/b07/package?id=${p.package_id}">開啟</a></td></tr>`).join("")}
     </table>
     <p><a href="/b06/run?id=${run.calculation_run_id}">← 回 B-06 執行結果</a></p>`));
}

// ── Package 狀態頁 ──
export async function packageView(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const pg = packageGate(ctx, send, ctx.url.searchParams.get("id") ?? "", "b07.package.view",
    B07.pkgView, `SELECT p.*, r.import_batch_id, j.status AS job_status, j.attempt_count
       FROM evidence_package p
       JOIN calculation_run r ON r.calculation_run_id = p.calculation_run_id
       LEFT JOIN background_job j ON j.subject_id = p.package_id AND j.job_type='EVIDENCE_PACKAGE'
      WHERE p.package_id = :'p'::uuid`);
  if (!pg.ok) return;
  const p = pg.pkg, g = pg.b;
  const idx = query<Record<string, string>>(
    `SELECT section, item_count, content_hash FROM evidence_package_index
      WHERE package_id = :'p'::uuid ORDER BY section`,
    { p: p.package_id }, { tenantId: s.tenantId });
  return send(200, page("B-07 證據包狀態", b04CtxBar(g.b, "B-07 證據包"),
    `<div style="background:#fff3e0;border:1px solid #d9a05b;border-radius:6px;padding:10px 14px;font-weight:600">
       PREVIEW 證據包——DRAFT・UNREVIEWED・未折算（NO_FX），不得作為入帳或交付依據
     </div>
     <p>Package <b>${p.package_id.slice(0, 8)}</b>｜狀態
        <span class="badge st-${p.status === "READY" ? "ACCEPTED" : p.status === "FAILED" ? "QUARANTINED" : "UPLOADED"}">${p.status}</span>｜
        Job ${esc(p.job_status ?? "—")}（第 ${esc(p.attempt_count ?? "0")} 次）</p>
     ${p.status === "FAILED" ? `<p>⛔ <b>${esc(p.failure_reason_code)}</b>：${esc(p.failure_reason)}</p>` : ""}
     ${p.status === "READY" ? `
     <p>package_content_hash＝<code>${esc(p.package_content_hash)}</code><br>
        artifact＝<code>${esc(p.artifact_object_key)}</code>（${esc(p.artifact_byte_size)} bytes，
        SHA-256 <code>${esc(p.artifact_sha256)}</code>，render ${esc(p.render_version)}）</p>
     <p><a href="/b07/download?id=${p.package_id}"><b>下載底稿（PREVIEW_DRAFT）</b></a>
        <span class="note">下載＝讀已保存位元組並驗 hash，不重新渲染</span></p>
     <h2>內容索引</h2>
     <table><tr><th>節</th><th>筆數</th><th>content hash</th></tr>
     ${idx.map((i) => `<tr><td>${esc(i.section)}</td><td>${esc(i.item_count)}</td><td class="note">${esc(i.content_hash)}</td></tr>`).join("")}
     </table>` : ""}
     <p><a href="/b07?run=${p.calculation_run_id}">← 回 B-07 清單</a></p>`));
}

// ── 下載：只讀已保存位元組並驗 hash（READY 限定） ──
export async function download(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const pg = packageGate(ctx, send, ctx.url.searchParams.get("id") ?? "", "b07.download",
    B07.download, `SELECT p.*, r.import_batch_id FROM evidence_package p
       JOIN calculation_run r ON r.calculation_run_id = p.calculation_run_id
      WHERE p.package_id = :'p'::uuid`);
  if (!pg.ok) return;
  const p = pg.pkg, g = pg.b;
  if (p.status !== "READY")
    return b07Refuse(ctx, send, g.b, "evidence.download.rejected", "PACKAGE_NOT_READY",
      { objectType: "evidence_package", objectId: p.package_id }, `目前為 ${p.status}`);
  const bytes = getObject(p.artifact_object_key);
  const sha = createHash("sha256").update(bytes).digest("hex");
  if (sha !== p.artifact_sha256) {
    // 雜湊不符**不是使用者違規**：使用者做的事完全合法，是保存的位元組壞了。
    // 記成 CONTROL_VIOLATION_ATTEMPT 會讓越權統計混入基礎設施故障，
    // 也會讓「誰試圖越權」的查詢答錯。改記為控制前置檢查失敗。
    audit(s.tenantId, "CONTROL_PRECHECK", "evidence.artifact_integrity_failed", s.userId,
      "evidence_package", p.package_id,
      { code: "ARTIFACT_HASH_MISMATCH", expected_hash: p.artifact_sha256, actual_hash: sha });
    return send(500, page("完整性失敗", b04CtxBar(g.b, "B-07"),
      `<h2>⛔ ARTIFACT_HASH_MISMATCH</h2><p>${esc(PKG_REASON.ARTIFACT_HASH_MISMATCH)}</p>`));
  }
  return send.bytes(200, bytes, {
    "content-type": p.artifact_mime_type,
    "content-length": String(bytes.length),
    "content-disposition":
      `attachment; filename="PREVIEW_DRAFT_evidence_${p.calculation_run_id.slice(0, 8)}_${p.package_id.slice(0, 8)}.html"`,
  });
}
