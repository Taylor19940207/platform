// B-06 PREVIEW CalculationRun 的 HTTP route（SLICE-M2-02B）。
//
// 授權逐動作判斷且一律案件層（見 guard.ts 的 B06 表）。以 run 為入口者
// **由 CalculationRun 反查 ImportBatch 與 Engagement**，不採信請求附帶的 batch。
// 交易、冪等契約與 manifest 凍結邏輯逐字沿用，不在拆層時改動。
import { createHash, randomUUID } from "node:crypto";
import { query, exec } from "../../../../../packages/database/src/psql.ts";
import { ENGINE_VERSION, CANONICALIZATION_VERSION, RUN_REASON, reasonCodeOf }
  from "../../../../../packages/domain/src/calculationRun.ts";
import { idempotencyKey } from "../../../../../packages/domain/src/backgroundJob.ts";
import { cents, fmtCents } from "../../../../../packages/domain/src/mapping.ts";
import { config } from "../../../../../packages/config/src/index.ts";
import type { AuthenticatedContext } from "../../http/context.ts";
import { esc, page, type Respond } from "../../http/respond.ts";
import { audit } from "../audit.ts";
import { batchGate } from "../imports/guard.ts";
import { b04CtxBar } from "../imports/views.ts";
import type { BatchCtx } from "../imports/access.ts";
import { runGate, B06 } from "./guard.ts";

const b06Refuse = (ctx: AuthenticatedContext, send: Respond,
                   b: BatchCtx | null, action: string, code: keyof typeof RUN_REASON,
                   detail = ""): void => {
  const s = ctx.session;
  audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", action, s.userId,
    "calculation_run", b?.import_batch_id ?? s.userId,
    { code, reason: RUN_REASON[code], detail });
  send(code === "ROLE_REQUIRED" ? 403 : 409,
    page("拒絕", b ? b04CtxBar(b, "B-06") : "<b>⛔</b>",
      `<h2>⛔ ${esc(code)}</h2><p>${esc(RUN_REASON[code])}</p>` +
      (detail ? `<p class="note">${esc(detail)}</p>` : "") +
      `<p>此次嘗試已寫入稽核軌跡。</p><p><a href="/">回 B-00</a></p>`));
};

// ── 建立 PREVIEW Run（R2／R3；同一交易：解析＋G-02＋Manifest＋Run＋Job＋事件） ──
export async function createRun(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const f = await ctx.form();
  const g = batchGate(ctx, send, f["batch"] ?? "", "calculation.create", B06.create);
  if (!g.ok) return;
  if (g.b.status !== "ACCEPTED")
    return b06Refuse(ctx, send, g.b, "calculation.create.rejected", "BATCH_NOT_ACCEPTED",
      `批次目前為 ${g.b.status}`);
  const requestKey = f["request_key"] ?? "";
  if (!/^[0-9a-f-]{36}$/.test(requestKey))
    return send(400, page("錯誤", b04CtxBar(g.b, "B-06"), "<h2>request_key 缺漏或格式錯誤</h2>"));
  // 冪等契約：同 key 同內容 → 原 run；同 key 異內容 → 409
  const rch = createHash("sha256")
    .update(`B06RUN|${g.b.engagement_id}|${g.b.declared_period_revision_id}|${g.b.import_batch_id}`)
    .digest("hex");
  const existing = query<{ calculation_run_id: string; request_content_hash: string }>(
    `SELECT calculation_run_id, request_content_hash FROM calculation_run
      WHERE request_key = :'rk'::uuid`, { rk: requestKey }, { tenantId: s.tenantId });
  if (existing[0]) {
    if (existing[0].request_content_hash === rch)
      return send(302, "", { location: `/b06/run?id=${existing[0].calculation_run_id}` });
    return b06Refuse(ctx, send, g.b, "calculation.create.rejected", "REQUEST_KEY_REUSED");
  }
  const runId = randomUUID();
  const maniId = randomUUID();
  const ik = idempotencyKey("CALCULATION_RUN", runId, 1, ENGINE_VERSION);
  try {
    // REPEATABLE READ：READ COMMITTED 是逐 statement 換 snapshot——TEMP 表只保證
    // G-02 與 Manifest 用同一映射集合，TB／調整／CoA 仍可能來自不同時間點。
    exec(`BEGIN ISOLATION LEVEL REPEATABLE READ;
      SELECT fn_assert((SELECT status FROM import_batch
        WHERE import_batch_id = :'b'::uuid AND engagement_id = :'e'::uuid) = 'ACCEPTED',
        'BATCH_NOT_ACCEPTED');

      -- 同一交易 snapshot：解析集合 → 對同一份集合驗 G-02 → 寫入 Manifest（護欄 2）
      CREATE TEMP TABLE _tb ON COMMIT DROP AS
        SELECT account_code, MAX(COALESCE(account_name,'')) AS account_name,
               SUM(debit) AS debit, SUM(credit) AS credit
          FROM source_ledger_line WHERE import_batch_id = :'b'::uuid
         GROUP BY account_code;
      CREATE TEMP TABLE _map ON COMMIT DROP AS
        SELECT DISTINCT ON (mr.source_account_code)
               mr.mapping_rule_id, mr.source_account_code, mr.version_no,
               mr.effective_from, mr.effective_to,
               mr.target_account_id, a.code AS target_code, a.name AS target_name,
               mr.created_by, cu.display_name AS created_by_name,
               mr.approved_by, au.display_name AS approved_by_name, mr.approved_at
          FROM mapping_rule mr JOIN account a ON a.account_id = mr.target_account_id
          JOIN app_user cu ON cu.user_id = mr.created_by
          JOIN app_user au ON au.user_id = mr.approved_by
         WHERE mr.engagement_id = :'e'::uuid AND mr.approved_at IS NOT NULL
           AND (mr.effective_from IS NULL OR mr.effective_from <= :'pe'::date)
           AND (mr.effective_to   IS NULL OR mr.effective_to   >= :'pe'::date)
         ORDER BY mr.source_account_code, mr.version_no DESC;
      SELECT fn_assert(NOT EXISTS (
        SELECT 1 FROM _tb t LEFT JOIN _map m ON m.source_account_code = t.account_code
         WHERE m.source_account_code IS NULL),
        'G02_UNMAPPED:'||COALESCE((SELECT string_agg(t.account_code,'、' ORDER BY t.account_code)
          FROM _tb t LEFT JOIN _map m ON m.source_account_code = t.account_code
         WHERE m.source_account_code IS NULL),''));

      CREATE TEMP TABLE _adj ON COMMIT DROP AS
        SELECT je.adjustment_id, je.business_version, adj.title,
               adj.prepared_by, pu.display_name AS prepared_by_name, adj.prepared_at,
               adj.reviewed_by, ru.display_name AS reviewed_by_name, adj.reviewed_at,
               adj.approved_by, qu.display_name AS approved_by_name, adj.approved_at,
               jsonb_agg(jsonb_build_object('line_no', jl.line_no, 'account_id', jl.account_id,
                 'code', a.code, 'name', a.name,
                 'debit', jl.debit::text, 'credit', jl.credit::text) ORDER BY jl.line_no) AS lines,
               string_agg(jl.line_no||':'||a.code||':'||jl.debit::text||':'||jl.credit::text,
                 ';' ORDER BY jl.line_no) AS canon_lines
          FROM journal_entry je
          JOIN journal_line jl ON jl.entry_id = je.entry_id
          JOIN account a ON a.account_id = jl.account_id
          JOIN adjustment adj ON adj.adjustment_id = je.adjustment_id
          JOIN app_user pu ON pu.user_id = adj.prepared_by
          JOIN app_user ru ON ru.user_id = adj.reviewed_by
          JOIN app_user qu ON qu.user_id = adj.approved_by
         WHERE je.engagement_id = :'e'::uuid AND je.period_revision_id = :'pr'::uuid
         GROUP BY je.adjustment_id, je.business_version, adj.title,
                  adj.prepared_by, pu.display_name, adj.prepared_at,
                  adj.reviewed_by, ru.display_name, adj.reviewed_at,
                  adj.approved_by, qu.display_name, adj.approved_at;

      CREATE TEMP TABLE _entries (
        object_type text, object_id uuid, concurrency_version int,
        domain_version_kind text, domain_version_value text,
        content_canonical text, payload jsonb) ON COMMIT DROP;
      INSERT INTO _entries SELECT 'SCOPE', NULL, NULL, 'SCOPE', '1',
        'SCOPE|NO_FX|engine=' || :'ev' || '|engagement=' || :'e' || '|period_revision=' || :'pr'
          || '|batch=' || :'b',
        jsonb_build_object('calculation_scope','NO_FX','engine_version', :'ev');
      INSERT INTO _entries SELECT 'SOURCE_TB', :'b'::uuid, NULL, 'BATCH_VERSION',
        (SELECT batch_version::text FROM import_batch WHERE import_batch_id = :'b'::uuid),
        'SOURCE_TB|' || :'b' || '|v' ||
          (SELECT batch_version FROM import_batch WHERE import_batch_id = :'b'::uuid) ||
          '|sha=' || (SELECT COALESCE(file_sha256,'') FROM import_batch WHERE import_batch_id = :'b'::uuid) ||
          '|' || (SELECT COALESCE(string_agg(account_code||':'||debit::text||':'||credit::text,
                    ';' ORDER BY account_code),'') FROM _tb),
        jsonb_build_object(
          'batch_id', :'b',
          'batch_version', (SELECT batch_version FROM import_batch WHERE import_batch_id = :'b'::uuid),
          'file_sha256', (SELECT COALESCE(file_sha256,'') FROM import_batch WHERE import_batch_id = :'b'::uuid),
          'lines', (SELECT COALESCE(jsonb_agg(jsonb_build_object('code',account_code,'name',account_name,
            'debit',debit::text,'credit',credit::text) ORDER BY account_code),'[]'::jsonb) FROM _tb));
      INSERT INTO _entries
        SELECT 'MAPPING_RULE', m.mapping_rule_id, NULL, 'MAPPING_VERSION_NO', m.version_no::text,
          'MAPPING|'||m.source_account_code||'|v'||m.version_no||'|'||
            COALESCE(m.effective_from::text,'-')||'|'||COALESCE(m.effective_to::text,'-')||'|'||
            m.target_code||'|'||m.target_name||'|'||m.target_account_id,
          jsonb_build_object('source_code',m.source_account_code,'version_no',m.version_no,
            'effective_from',m.effective_from,'effective_to',m.effective_to,
            'target_account_id',m.target_account_id,'target_code',m.target_code,
            'target_name',m.target_name,
            'created_by',m.created_by,'created_by_name',m.created_by_name,
            'approved_by',m.approved_by,'approved_by_name',m.approved_by_name,
            'approved_at',m.approved_at)
        FROM _map m;
      INSERT INTO _entries
        SELECT 'ADJUSTMENT', a.adjustment_id, NULL, 'BUSINESS_VERSION', a.business_version::text,
          'ADJUSTMENT|'||a.adjustment_id||'|bv'||a.business_version||'|'||a.canon_lines,
          jsonb_build_object('adjustment_id',a.adjustment_id,'business_version',a.business_version,
            'title',a.title,'lines',a.lines,
            'prepared_by',a.prepared_by,'prepared_by_name',a.prepared_by_name,'prepared_at',a.prepared_at,
            'reviewed_by',a.reviewed_by,'reviewed_by_name',a.reviewed_by_name,'reviewed_at',a.reviewed_at,
            'approved_by',a.approved_by,'approved_by_name',a.approved_by_name,'approved_at',a.approved_at)
        FROM _adj a;
      INSERT INTO _entries
        SELECT 'CHART_OF_ACCOUNTS', c.coa_id, NULL, 'COA_VERSION', c.version_no::text,
          'COA|'||c.coa_id||'|v'||c.version_no,
          jsonb_build_object('coa_id',c.coa_id,'version_no',c.version_no,'name',c.name)
        FROM chart_of_accounts c WHERE c.engagement_id = :'e'::uuid;

      -- 基礎組成（SLICE-M2-06）：凍結本案件全部已批准的組成版本。
      -- 「哪些層構成哪個基礎」是計算輸入的一部分——不凍結的話，組成 v2 落地後
      -- 重演同一個 run 會得到不同的基礎餘額，而且不會有任何錯誤訊息（INV-21／INV-29）。
      INSERT INTO _entries
        SELECT 'BASIS_COMPOSITION', c.basis_composition_version_id, NULL,
          'COMPOSITION_VERSION_NO', c.version_no::text,
          'BASIS_COMPOSITION|'||b.code||'|'||c.basis_composition_version_id||'|v'||c.version_no||'|'||
            COALESCE((SELECT string_agg(pl.code||':'||i.sign, ';' ORDER BY pl.code)
                        FROM constitutive_layer_item i
                        JOIN posting_layer pl ON pl.layer_id = i.layer_id
                       WHERE i.basis_composition_version_id = c.basis_composition_version_id),''),
          jsonb_build_object('basis_id', c.basis_id, 'basis_code', b.code,
            'source_mode', b.source_mode, 'version_no', c.version_no,
            'items', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                         'layer_code', pl.code, 'layer_id', i.layer_id, 'sign', i.sign)
                       ORDER BY pl.code),'[]'::jsonb)
                        FROM constitutive_layer_item i
                        JOIN posting_layer pl ON pl.layer_id = i.layer_id
                       WHERE i.basis_composition_version_id = c.basis_composition_version_id))
        FROM basis_composition_version c JOIN book_basis b ON b.basis_id = c.basis_id
       WHERE c.engagement_id = :'e'::uuid AND c.status = 'APPROVED';
      -- 沒有已批准的組成就沒有分層語意可凍結。若放行，這個 run 會與 0023 之前的
      -- 歷史 run 長得一模一樣（無組成 entry、快照無分層），等於靜默降級。
      SELECT fn_assert((SELECT count(*) FROM _entries WHERE object_type = 'BASIS_COMPOSITION') > 0,
        'BASIS_COMPOSITION_NOT_APPROVED:本案件沒有已批准的基礎組成版本');

      -- frozen hash 只涵蓋計算輸入（entries）；run_id／建立者／時間不入 hash。
      -- v2：entry hash 涵蓋 canonical＋payload（計算實際讀 payload，兩者都要蓋到）
      INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id,
        period_revision_id, calculation_scope, hash_algorithm, canonicalization_version,
        frozen_set_content_hash, created_by)
      SELECT :'mani'::uuid, :'t'::uuid, :'e'::uuid, :'pr'::uuid, 'NO_FX', 'sha256', :'cv',
        encode(sha256(convert_to((SELECT string_agg(
          encode(sha256(convert_to(content_canonical || E'\n' || payload::text,'UTF8')),'hex'),
          E'\n' ORDER BY content_canonical) FROM _entries),'UTF8')),'hex'),
        :'u'::uuid;
      INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
        concurrency_version, domain_version_kind, domain_version_value,
        content_canonical, content_hash, payload)
      SELECT :'t'::uuid, :'mani'::uuid, object_type, object_id, concurrency_version,
        domain_version_kind, domain_version_value, content_canonical,
        encode(sha256(convert_to(content_canonical || E'\n' || payload::text,'UTF8')),'hex'),
        payload
      FROM _entries;

      INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id,
        period_revision_id, import_batch_id, manifest_id, run_type, status,
        request_key, request_content_hash, engine_version, created_by)
      VALUES (:'run'::uuid, :'t'::uuid, :'e'::uuid, :'pr'::uuid, :'b'::uuid, :'mani'::uuid,
        'PREVIEW', 'RUNNING', :'rk'::uuid, :'rch', :'ev', :'u'::uuid);
      INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version,
        rule_version, idempotency_key, max_attempts)
      VALUES (:'t'::uuid, 'CALCULATION_RUN', :'run'::uuid, 1, :'ev', :'ik', ${config.jobMaxAttempts});
      INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
      VALUES (:'t'::uuid, 'DOMAIN_EVENT', 'calculation_run.created', :'u'::uuid,
        'calculation_run', :'run'::uuid,
        jsonb_build_object('manifest_id', :'mani', 'batch', :'b', 'scope', 'NO_FX'));
      COMMIT;`,
      { b: g.b.import_batch_id, e: g.b.engagement_id, pr: g.b.declared_period_revision_id,
        pe: g.b.period_end, t: s.tenantId, u: s.userId, run: runId, mani: maniId,
        rk: requestKey, rch, ik, ev: ENGINE_VERSION, cv: CANONICALIZATION_VERSION },
      { tenantId: s.tenantId });
  } catch (e) {
    const msg = String(e);
    const code = reasonCodeOf(msg);
    if (code === "G02_UNMAPPED" || code === "BATCH_NOT_ACCEPTED"
        || code === "BASIS_COMPOSITION_NOT_APPROVED")
      return b06Refuse(ctx, send, g.b, "calculation.create.rejected", code,
        msg.split(`${code}:`)[1]?.split("\n")[0] ?? "");
    if (msg.includes("calculation_run_tenant_request_key_uq")) {   // 併發同 key：回查
      const again = query<{ calculation_run_id: string; request_content_hash: string }>(
        `SELECT calculation_run_id, request_content_hash FROM calculation_run
          WHERE request_key = :'rk'::uuid`, { rk: requestKey }, { tenantId: s.tenantId });
      if (again[0]?.request_content_hash === rch)
        return send(302, "", { location: `/b06/run?id=${again[0].calculation_run_id}` });
      return b06Refuse(ctx, send, g.b, "calculation.create.rejected", "REQUEST_KEY_REUSED");
    }
    throw e;
  }
  return send(302, "", { location: `/b06/run?id=${runId}` });
}

// ── 重演：新 run 引用同一份 Manifest（原 run 永不修改） ──
export async function replay(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const f = await ctx.form();
  // 歸屬由 run 反查，不採信請求附帶的 batch
  const rg = runGate(ctx, send, f["run"] ?? "", "calculation.replay", B06.replay,
    `SELECT r.calculation_run_id, r.import_batch_id, r.status, r.engagement_id
       FROM calculation_run r WHERE r.calculation_run_id = :'r'::uuid`);
  if (!rg.ok) return;
  const orig = rg.run, g = rg.b;
  if (orig.status !== "COMPLETED")
    return b06Refuse(ctx, send, g.b, "calculation.replay.rejected", "REPLAY_TARGET_NOT_COMPLETED",
      `原 run 狀態為 ${orig.status}`);
  const runId = randomUUID();
  const ik = idempotencyKey("CALCULATION_RUN", runId, 1, ENGINE_VERSION);
  exec(`BEGIN;
    INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id,
      period_revision_id, import_batch_id, manifest_id, run_type, status, replay_of_run_id,
      request_key, request_content_hash, engine_version, created_by)
    SELECT :'run'::uuid, tenant_id, engagement_id, period_revision_id, import_batch_id,
      manifest_id, 'PREVIEW', 'RUNNING', :'orig'::uuid,
      :'rk'::uuid, 'REPLAY|' || :'orig', engine_version, :'u'::uuid
    FROM calculation_run WHERE calculation_run_id = :'orig'::uuid;
    INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version,
      rule_version, idempotency_key, max_attempts)
    VALUES (:'t'::uuid, 'CALCULATION_RUN', :'run'::uuid, 1, :'ev', :'ik', ${config.jobMaxAttempts});
    INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
    VALUES (:'t'::uuid, 'DOMAIN_EVENT', 'calculation_run.replay_created', :'u'::uuid,
      'calculation_run', :'run'::uuid, jsonb_build_object('replay_of', :'orig'));
    COMMIT;`,
    { run: runId, orig: orig.calculation_run_id, rk: randomUUID(), u: s.userId,
      t: s.tenantId, ev: ENGINE_VERSION, ik }, { tenantId: s.tenantId });
  return send(302, "", { location: `/b06/run?id=${runId}` });
}

// ── B-06 執行清單 ──
export async function list(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const g = batchGate(ctx, send, ctx.url.searchParams.get("batch") ?? "", "b06.view", B06.view);
  if (!g.ok) return;
  const runs = query<Record<string, string>>(
    `SELECT r.calculation_run_id, r.status, r.replay_of_run_id, r.result_content_hash,
            r.failure_reason_code, r.created_at,
            j.status AS job_status, j.attempt_count
       FROM calculation_run r
       LEFT JOIN background_job j ON j.subject_id = r.calculation_run_id
            AND j.job_type = 'CALCULATION_RUN'
      WHERE r.import_batch_id = :'b'::uuid ORDER BY r.created_at DESC LIMIT 50`,
    { b: g.b.import_batch_id }, { tenantId: s.tenantId });
  return send(200, page("B-06 計算執行", b04CtxBar(g.b, "B-06 計算執行、折算與調節"),
    `<h2>PREVIEW CalculationRun</h2>
     <p class="note">本刀輸出為「科目映射＋已批准調整、<b>未折算（NO_FX）</b>」預覽；折算屬 MVP 3。</p>
     <form class="up" method="post" action="/b06/run">
       <input type="hidden" name="batch" value="${g.b.import_batch_id}">
       <input type="hidden" name="request_key" value="${randomUUID()}">
       <button>建立 PREVIEW 計算執行（R2／R3）</button>
       <span class="note">同一請求重送不會產生第二個 run；再次點按此頁重新產生的 key 才建立新 run</span>
     </form>
     <table><tr><th>Run</th><th>種類</th><th>Run 狀態</th><th>執行進度（Job）</th><th>結果 hash</th><th>建立</th><th></th></tr>
     ${runs.map((r) => `<tr><td>${r.calculation_run_id.slice(0, 8)}</td>
       <td>${r.replay_of_run_id ? `重演 ← ${r.replay_of_run_id.slice(0, 8)}` : "原始"}</td>
       <td><span class="badge st-${r.status === "COMPLETED" ? "ACCEPTED" : r.status === "FAILED" ? "QUARANTINED" : "UPLOADED"}">${r.status}</span>${r.failure_reason_code ? ` <span class="note">${esc(r.failure_reason_code)}</span>` : ""}</td>
       <td>${esc(r.job_status ?? "")}（${esc(r.attempt_count ?? "0")}）</td>
       <td class="note">${(r.result_content_hash ?? "").slice(0, 12)}</td>
       <td class="note">${esc(String(r.created_at).slice(0, 19))}</td>
       <td><a href="/b06/run?id=${r.calculation_run_id}">開啟</a></td></tr>`).join("")}
     </table>
     <p><a href="/b04?batch=${g.b.import_batch_id}">← 回 B-04</a>　<a href="/">回 B-00</a></p>`));
}

// ── Run 詳情：PREVIEW 快照、控制總額、Manifest 摘要、重演 ──
export async function runView(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  // 歸屬由 run 反查，不採信請求附帶的 batch
  const rg = runGate(ctx, send, ctx.url.searchParams.get("id") ?? "", "b06.run.view", B06.runView,
    `SELECT r.*, j.status AS job_status, j.attempt_count, j.last_error_class,
            m.frozen_set_content_hash, m.canonicalization_version, m.calculation_scope
       FROM calculation_run r
       JOIN calculation_input_manifest m ON m.manifest_id = r.manifest_id
       LEFT JOIN background_job j ON j.subject_id = r.calculation_run_id
            AND j.job_type = 'CALCULATION_RUN'
      WHERE r.calculation_run_id = :'r'::uuid`);
  if (!rg.ok) return;
  const run = rg.run, g = rg.b;
  const entries = query<{ object_type: string; n: string }>(
    `SELECT object_type, count(*) AS n FROM calculation_manifest_entry
      WHERE manifest_id = :'m'::uuid GROUP BY object_type ORDER BY object_type`,
    { m: run.manifest_id }, { tenantId: s.tenantId });
  const lines = query<Record<string, string>>(
    `SELECT posting_layer, account_code, account_name, debit, credit
       FROM balance_snapshot_line WHERE calculation_run_id = :'r'::uuid
      ORDER BY account_code, posting_layer`,
    { r: run.calculation_run_id }, { tenantId: s.tenantId });
  const fmt = (v: string) => v && v !== "0.00" ? fmtCents(cents(v)) : "";
  const tot = (col: "debit" | "credit") =>
    lines.reduce((a, l) => a + cents(l[col]), 0n);
  return send(200, page("B-06 PREVIEW 執行結果", b04CtxBar(g.b, "B-06 計算執行結果"),
    `<div style="background:#fff3e0;border:1px solid #d9a05b;border-radius:6px;padding:10px 14px;font-weight:600">
       PREVIEW（預覽）——非正式輸出、<u>未折算（calculation_scope=NO_FX）</u>，
       不建立交付紀錄，不得作為入帳或交付依據
     </div>
     <p>Run <b>${run.calculation_run_id.slice(0, 8)}</b>
        ${run.replay_of_run_id ? `（重演 ← ${run.replay_of_run_id.slice(0, 8)}）` : "（原始）"}｜
        狀態 <span class="badge st-${run.status === "COMPLETED" ? "ACCEPTED" : run.status === "FAILED" ? "QUARANTINED" : "UPLOADED"}">${run.status}</span>｜
        Job ${esc(run.job_status ?? "—")}（第 ${esc(run.attempt_count ?? "0")} 次）</p>
     ${run.status === "FAILED" ? `<p>⛔ <b>${esc(run.failure_reason_code)}</b>：${esc(run.failure_reason)}</p>` : ""}
     ${run.status === "COMPLETED" ? `
     <h2>調整後集團 TB（未折算）</h2>
     <table><tr><th>層</th><th>集團科目</th><th>名稱</th><th>借方</th><th>貸方</th></tr>
     ${lines.map((l) => `<tr><td class="note">${l.posting_layer === "SOURCE_TB" ? "來源 TB" : "調整"}</td>
       <td>${esc(l.account_code)}</td><td>${esc(l.account_name)}</td>
       <td style="text-align:right">${fmt(l.debit)}</td><td style="text-align:right">${fmt(l.credit)}</td></tr>`).join("")}
     <tr><th colspan="3">控制總額（G-09 已於結果交易內勾稽）</th>
       <th style="text-align:right">${fmtCents(tot("debit"))}</th>
       <th style="text-align:right">${fmtCents(tot("credit"))}</th></tr>
     </table>
     <p class="note">result_content_hash＝<code>${esc(run.result_content_hash)}</code>（canonical 結果，排除 run_id 與時間戳）</p>
     <form method="post" action="/b06/replay" style="margin:8px 0">
       <input type="hidden" name="run" value="${run.calculation_run_id}">
       <button>依 Manifest 重演（建立 replay run）</button>
     </form>
     <p><a href="/b07?run=${run.calculation_run_id}">→ B-07 產生預覽證據包</a></p>` : ""}
     <h2>Manifest（凍結輸入）</h2>
     <p class="note">frozen_set_content_hash＝<code>${esc(run.frozen_set_content_hash)}</code>｜
        canonicalization＝${esc(run.canonicalization_version)}｜scope＝${esc(run.calculation_scope)}</p>
     <table><tr><th>輸入類型</th><th>筆數</th></tr>
     ${entries.map((e2) => `<tr><td>${esc(e2.object_type)}</td><td>${esc(e2.n)}</td></tr>`).join("")}
     </table>
     <p><a href="/b06?batch=${run.import_batch_id}">← 回 B-06 清單</a></p>`));
}
