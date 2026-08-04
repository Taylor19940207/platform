// API（§27 模組化單體宿主）。里程碑 1 垂直切片：
//   登入 → 選 客戶/法人/期間（EngagementContext）→ 上傳 TB → B-00 顯示結果。
// 畫面為走查骨架（真機換 Next.js）；控制邏輯（脈絡伺服器端驗證、雜湊、審計）是正式的。
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createHash, randomUUID } from "node:crypto";
import { query, exec } from "../../../packages/database/src/psql.ts";
import { putObject } from "../../../packages/database/src/objectstore.ts";
import { sign, verify, type Session } from "../../../packages/auth/src/session.ts";
import { config } from "../../../packages/config/src/index.ts";
import { acceptancePredicate, type ImportBatchStatus, type IdentityStatus }
  from "../../../packages/domain/src/importBatch.ts";
import { applyMappings, coverage, g02Check, totalsOf, cents, fmtCents,
  type TbAccountLine, type CurrentMapping } from "../../../packages/domain/src/mapping.ts";

const PORT = config.port;
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g,
  (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c] as string));

// ── 共通版面：每個作業畫面固定顯示脈絡（§28.9 EngagementContext） ──
function page(title: string, ctxBar: string, body: string): string {
  return `<!DOCTYPE html><html lang="zh-Hant"><meta charset="utf-8">
<title>${esc(title)}</title><style>
body{font-family:"Hiragino Sans","Noto Sans CJK TC",sans-serif;margin:0;color:#1b1f24}
.ctx{background:#1b1f24;color:#fff;padding:8px 20px;font-size:13px;display:flex;gap:18px}
.ctx b{color:#ffd27f}.wrap{max-width:960px;margin:0 auto;padding:20px}
table{border-collapse:collapse;width:100%;font-size:13.5px;margin:12px 0}
th,td{border:1px solid #dfe4ea;padding:7px 10px;text-align:left}
th{background:#f7f9fb}
.badge{display:inline-block;padding:1px 8px;border-radius:999px;font-size:11.5px;border:1px solid}
.st-VALIDATED{color:#3d6b4a;border-color:#b7d2bf;background:#ebf3ed}
.st-QUARANTINED,.st-CONFLICT{color:#a8402f;border-color:#e3bcb3;background:#fbeeeb}
.st-UPLOADED,.st-VALIDATING,.st-NOT_CHECKED,.st-PENDING_CONFIRMATION{color:#8a5a2b;border-color:#d9c1a0;background:#faf4ec}
.st-MATCHED,.st-ACCEPTED{color:#3d6b4a;border-color:#b7d2bf;background:#ebf3ed}
form.up{border:1px solid #dfe4ea;border-radius:8px;padding:14px 18px;margin:14px 0;background:#f7f9fb}
input,select,button,textarea{font:inherit;margin:4px 0}
button{background:#1b1f24;color:#fff;border:0;border-radius:6px;padding:7px 16px;cursor:pointer}
.note{color:#7a8593;font-size:12.5px}</style>
<div class="ctx">${ctxBar}</div><div class="wrap">${body}</div></html>`;
}

function cookies(req: IncomingMessage): Record<string, string> {
  return Object.fromEntries((req.headers.cookie ?? "").split(";")
    .map((p) => p.trim().split("=")).filter((kv) => kv.length === 2) as [string, string][]);
}
function session(req: IncomingMessage): Session | null { return verify(cookies(req)["s"]); }

function audit(tenantId: string, kind: string, eventType: string, actor: string | null,
               objectType: string, objectId: string, payload: object): void {
  exec(`INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
        VALUES (:'t'::uuid, :'k', :'e', ${actor ? ":'a'::uuid" : "NULL"}, :'ot', :'oi'::uuid, :'pl'::jsonb)`,
    { t: tenantId, k: kind, e: eventType, ...(actor ? { a: actor } : {}),
      ot: objectType, oi: objectId, pl: JSON.stringify(payload) }, { tenantId });
}

// ── EngagementContext 伺服器端驗證（§24.1A：不得信任前端下拉選單） ──
function validateContext(s: Session, engagementId: string, legalEntityId: string,
                         periodRevisionId: string): { ok: boolean; reason?: string } {
  const rows = query<{ n: string }>(
    `SELECT count(*) AS n FROM legal_entity le
       JOIN period_revision pr ON pr.period_revision_id = :'pr'::uuid
       JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
      WHERE le.legal_entity_id = :'le'::uuid
        AND le.engagement_id = :'e'::uuid
        AND rp.engagement_id = :'e'::uuid`,
    { pr: periodRevisionId, le: legalEntityId, e: engagementId }, { tenantId: s.tenantId });
  if (Number(rows[0]?.n) !== 1) return { ok: false, reason: "物件與 Engagement 不一致" };
  const assigned = query<{ n: string }>(
    `SELECT count(*) AS n FROM role_assignment
      WHERE user_id = :'u'::uuid AND revoked_at IS NULL
        AND (engagement_id IS NULL OR engagement_id = :'e'::uuid)`,
    { u: s.userId, e: engagementId }, { tenantId: s.tenantId });
  if (Number(assigned[0]?.n) === 0) return { ok: false, reason: "未被指派此案件" };
  return { ok: true };
}

/** 使用者在該案件的角色集合（含租戶層指派）。 */
function rolesOf(s: Session, engagementId: string): Set<string> {
  return new Set(query<{ role: string }>(
    `SELECT role FROM role_assignment
      WHERE user_id = :'u'::uuid AND revoked_at IS NULL
        AND (engagement_id IS NULL OR engagement_id = :'e'::uuid)`,
    { u: s.userId, e: engagementId }, { tenantId: s.tenantId }).map((r) => r.role));
}

interface BatchCtx {
  import_batch_id: string; engagement_id: string; status: ImportBatchStatus;
  identity_status: IdentityStatus; hash_verified: boolean;
  client: string; entity: string; period: string; period_end: string;
}
function loadBatch(s: Session, batchId: string): BatchCtx | null {
  const rows = query<BatchCtx>(
    `SELECT ib.import_batch_id, ib.engagement_id, ib.status, ib.identity_status, ib.hash_verified,
            ce.name AS client, le.name AS entity, rp.label AS period, rp.end_date AS period_end
       FROM import_batch ib
       JOIN client_engagement ce ON ce.engagement_id = ib.engagement_id
       JOIN legal_entity le ON le.legal_entity_id = ib.declared_legal_entity_id
       JOIN period_revision pr ON pr.period_revision_id = ib.declared_period_revision_id
       JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
      WHERE ib.import_batch_id = :'b'::uuid`,
    { b: batchId }, { tenantId: s.tenantId });
  return rows[0] ?? null;
}

/**
 * 目前生效映射：每來源科目取「該報告期間生效」的最高已批准版本。
 * 生效以期間終了日判定（TB 為期末餘額）；NULL 生效日＝不限。
 * 版本凍結（CalculationInputManifest）屬下一刀 CalculationRun。
 */
function currentMappings(s: Session, engagementId: string, periodEnd: string): CurrentMapping[] {
  return query<{ source_account_code: string; target_account_id: string;
                 target_code: string; target_name: string; version_no: number }>(
    `SELECT DISTINCT ON (mr.source_account_code)
            mr.source_account_code, mr.target_account_id, mr.version_no,
            a.code AS target_code, a.name AS target_name
       FROM mapping_rule mr JOIN account a ON a.account_id = mr.target_account_id
      WHERE mr.engagement_id = :'e'::uuid AND mr.approved_at IS NOT NULL
        AND (mr.effective_from IS NULL OR mr.effective_from <= :'pe'::date)
        AND (mr.effective_to   IS NULL OR mr.effective_to   >= :'pe'::date)
      ORDER BY mr.source_account_code, mr.version_no DESC`,
    { e: engagementId, pe: periodEnd }, { tenantId: s.tenantId })
    .map((r) => ({ sourceAccountCode: r.source_account_code, targetAccountId: r.target_account_id,
                   targetCode: r.target_code, targetName: r.target_name, versionNo: Number(r.version_no) }));
}

/** 批次的 TB 科目彙總列。 */
function tbLines(s: Session, batchId: string): TbAccountLine[] {
  return query<{ account_code: string; account_name: string; debit: string; credit: string }>(
    `SELECT account_code, MAX(account_name) AS account_name,
            SUM(debit) AS debit, SUM(credit) AS credit
       FROM source_ledger_line WHERE import_batch_id = :'b'::uuid
      GROUP BY account_code ORDER BY account_code`,
    { b: batchId }, { tenantId: s.tenantId })
    .map((r) => ({ accountCode: r.account_code, accountName: r.account_name ?? "",
                   debitCents: cents(r.debit), creditCents: cents(r.credit) }));
}

function b04CtxBar(b: BatchCtx, screen: string): string {
  return `<span>畫面 <b>${esc(screen)}</b></span><span>客戶 <b>${esc(b.client)}</b></span>` +
    `<span>法人 <b>${esc(b.entity)}</b></span><span>期間 <b>${esc(b.period)}</b></span>` +
    `<span>批次 <b>${b.import_batch_id.slice(0, 8)}</b>（${b.status}）</span>`;
}

function readBody(req: IncomingMessage): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
  const url = new URL(req.url ?? "/", "http://x");
  const send = (code: number, body: string, headers: Record<string, string> = {}) => {
    res.writeHead(code, { "content-type": "text/html; charset=utf-8", ...headers });
    res.end(body);
  };
  try {
    if (url.pathname === "/health") {
      const [row] = query<{ ok: number }>("SELECT 1 AS ok", {}, { asRuntime: false });
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify({ ok: true, db: row?.ok === 1 }));
    }

    // ── 登入（開發用：列出種子使用者；真機換 SSO） ──
    if (url.pathname === "/" && !session(req)) {
      const users = query<{ user_id: string; email: string; display_name: string; tenant_id: string }>(
        "SELECT user_id, email, display_name, tenant_id FROM app_user WHERE is_active", {}, { asRuntime: false });
      return send(200, page("登入", "<b>未登入</b>",
        `<h2>登入（開發模式）</h2><p class="note">走查骨架：點選身分即登入。真機環境換 SSO／IdP。</p>` +
        users.map((u) => `<p><a href="/login?u=${u.user_id}&t=${u.tenant_id}">${esc(u.display_name)}（${esc(u.email)}）</a></p>`).join("")));
    }
    if (url.pathname === "/login") {
      const s: Session = { userId: url.searchParams.get("u") ?? "", tenantId: url.searchParams.get("t") ?? "" };
      return send(302, "", { "set-cookie": `s=${sign(s)}; HttpOnly; Path=/`, location: "/" });
    }

    const s = session(req);
    if (!s) return send(302, "", { location: "/" });

    // ── B-00 個人工作台（只顯示被指派的案件——WKB-a） ──
    if (url.pathname === "/") {
      const engagements = query<{ engagement_id: string; name: string }>(
        `SELECT DISTINCT ce.engagement_id, ce.name FROM client_engagement ce
           JOIN role_assignment ra ON (ra.engagement_id = ce.engagement_id OR ra.engagement_id IS NULL)
          WHERE ra.user_id = :'u'::uuid AND ra.revoked_at IS NULL ORDER BY ce.name`,
        { u: s.userId }, { tenantId: s.tenantId });
      const assignedIds = new Set(engagements.map((e) => e.engagement_id));
      const batches = query<Record<string, string>>(
        `SELECT DISTINCT ib.import_batch_id, ib.created_at, ce.name AS client, le.name AS entity,
                rp.label AS period, ib.status, ib.identity_status, ib.file_name, ib.quarantine_reason
           FROM import_batch ib
           JOIN client_engagement ce ON ce.engagement_id = ib.engagement_id
           JOIN legal_entity le ON le.legal_entity_id = ib.declared_legal_entity_id
           JOIN period_revision pr ON pr.period_revision_id = ib.declared_period_revision_id
           JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
           JOIN role_assignment ra ON (ra.engagement_id = ib.engagement_id OR ra.engagement_id IS NULL)
                AND ra.user_id = :'u'::uuid AND ra.revoked_at IS NULL
          ORDER BY ib.created_at DESC LIMIT 50`,
        { u: s.userId }, { tenantId: s.tenantId });
      // 選單只列被指派案件底下的法人與期間（前端便利；權威判定在 validateContext）
      const les = query<Record<string, string>>(
        `SELECT legal_entity_id, name, engagement_id FROM legal_entity`, {}, { tenantId: s.tenantId })
        .filter((r) => assignedIds.has(r.engagement_id));
      const prs = query<Record<string, string>>(
        `SELECT pr.period_revision_id, rp.label, rp.engagement_id FROM period_revision pr
           JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id`, {}, { tenantId: s.tenantId })
        .filter((r) => assignedIds.has(r.engagement_id));
      // B-00 每列固定四欄：客戶／法人／期間／狀態（WKB-c）
      return send(200, page("B-00 個人工作台",
        `<span>畫面 <b>B-00 個人工作台</b></span><span>使用者 <b>${esc(s.userId.slice(-4))}</b></span>`,
        `<h2>上傳試算表（TB）</h2>
         <form class="up" method="post" action="/upload">
           客戶 <select name="engagement">${engagements.map((r) => `<option value="${r.engagement_id}">${esc(r.name)}</option>`).join("")}</select>
           法人 <select name="legal_entity">${les.map((r) => `<option value="${r.legal_entity_id}">${esc(r.name)}</option>`).join("")}</select>
           期間 <select name="period_revision">${prs.map((r) => `<option value="${r.period_revision_id}">${esc(r.label)}</option>`).join("")}</select><br>
           <textarea name="csv" rows="6" cols="80"
placeholder="#legal_entity_code=1234567890123
account_code,account_name,debit,credit
1100,現金,1000,0
4000,売上,0,1000"></textarea><br>
           <button>上傳</button>
           <span class="note">上傳後由背景工作驗證：借貸平衡（G-01）＋檔案歸屬比對（identity_status）</span>
         </form>
         <h2>批次狀態</h2>
         <table><tr><th>客戶</th><th>法人</th><th>期間</th><th>狀態</th><th>身分比對</th><th>檔案</th><th>說明</th><th>動作</th></tr>
         ${batches.map((b) => `<tr><td>${esc(b.client)}</td><td>${esc(b.entity)}</td><td>${esc(b.period)}</td>
           <td><span class="badge st-${b.status}">${b.status}</span></td>
           <td><span class="badge st-${b.identity_status}">${b.identity_status}</span></td>
           <td>${esc(b.file_name)}</td><td class="note">${esc(b.quarantine_reason ?? "")}</td>
           <td>${b.status === "VALIDATED" && b.identity_status === "MATCHED"
             ? `<form method="post" action="/b04/accept" style="margin:0"><input type="hidden" name="batch" value="${b.import_batch_id}"><button>接受</button></form>`
             : b.status === "ACCEPTED" ? `<a href="/b04?batch=${b.import_batch_id}">B-04 映射</a>` : ""}</td></tr>`).join("")}
         </table><p class="note">此頁只顯示您被指派的案件；未指派案件的名稱與數量不會出現（WKB-a）。</p>`));
    }

    // ── 上傳（POST /upload；走查骨架用 urlencoded 表單。分段續傳 A7/A8 屬下一里程碑） ──
    if (url.pathname === "/upload" && req.method === "POST") {
      const raw = (await readBody(req)).toString("utf8");
      const fields = Object.fromEntries(new URLSearchParams(raw));
      const engagement = fields["engagement"] ?? "";
      const legal_entity = fields["legal_entity"] ?? "";
      const period_revision = fields["period_revision"] ?? "";
      const csv = (fields["csv"] ?? "").replace(/\r\n/g, "\n");

      // 伺服器端脈絡驗證：繞過 UI 直接呼叫也會被擋，並記錄違規嘗試（CTX-a）
      const v = validateContext(s, engagement, legal_entity, period_revision);
      if (!v.ok) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "context.mismatch", s.userId,
          "import_batch", randomUUID(), { reason: v.reason, engagement, legal_entity, period_revision });
        return send(403, page("拒絕", "<b>⛔ 歸屬驗證失敗</b>",
          `<h2>⛔ ${esc(v.reason)}</h2><p>此次嘗試已寫入稽核軌跡。</p><p><a href="/">回 B-00</a></p>`));
      }

      const data = Buffer.from(csv, "utf8");
      const sha = createHash("sha256").update(data).digest("hex");
      const batchId = randomUUID();
      const key = `${s.tenantId}/${batchId}/tb.csv`;
      putObject(key, data);
      exec(`INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id,
              declared_legal_entity_id, declared_period_revision_id,
              uploaded_by, provided_by, file_name, file_sha256, status)
            VALUES (:'id'::uuid, :'t'::uuid, :'e'::uuid, :'le'::uuid, :'pr'::uuid,
                    :'u'::uuid, :'u'::uuid, 'tb.csv', :'sha', 'DRAFT')`,
        { id: batchId, t: s.tenantId, e: engagement, le: legal_entity, pr: period_revision,
          u: s.userId, sha }, { tenantId: s.tenantId });
      // 原檔紀錄先落地，最後才轉 UPLOADED——§25.5「UPLOADED＝檔案已落地」，
      // 順序顛倒會讓 worker 在紀錄寫入前搶到批次（object_key 為 null 的競態）。
      exec(`INSERT INTO source_document (tenant_id, import_batch_id, file_name, content_sha256, object_key, byte_size)
            VALUES (:'t'::uuid, :'id'::uuid, 'tb.csv', :'sha', :'k', ${data.length})`,
        { t: s.tenantId, id: batchId, sha, k: key }, { tenantId: s.tenantId });
      exec(`UPDATE import_batch SET status='UPLOADED' WHERE import_batch_id = :'id'::uuid`,
        { id: batchId }, { tenantId: s.tenantId });
      audit(s.tenantId, "DOMAIN_EVENT", "import_batch.uploaded", s.userId,
        "import_batch", batchId, { sha256: sha, bytes: data.length });
      return send(302, "", { location: "/" });
    }

    // ═══════════ SLICE-M2-01：B-04 科目映射 ═══════════
    // 共通入口檢查：批次存在＋使用者被指派該案件（歸屬完整性 §24.1A）
    const b04Guard = (batchId: string, action: string):
        { ok: true; b: BatchCtx; roles: Set<string> } | { ok: false; res: void } => {
      const b = loadBatch(s, batchId);
      if (!b) return { ok: false, res: send(404, page("404", "", "<h2>批次不存在</h2>")) };
      const roles = rolesOf(s, b.engagement_id);
      if (roles.size === 0) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", `${action}.denied`, s.userId,
          "import_batch", batchId, { reason: "未被指派此案件", action });
        return { ok: false, res: send(403, page("拒絕", "<b>⛔ 未被指派</b>",
          `<h2>⛔ 未被指派此案件</h2><p>此次嘗試已寫入稽核軌跡。</p><p><a href="/">回 B-00</a></p>`)) };
      }
      return { ok: true, b, roles };
    };

    // ── 接受批次（VALIDATED → ACCEPTED；G-01 接受判定式，DB 觸發器為最後防線） ──
    if (url.pathname === "/b04/accept" && req.method === "POST") {
      const fields = Object.fromEntries(new URLSearchParams((await readBody(req)).toString("utf8")));
      const g = b04Guard(fields["batch"] ?? "", "batch.accept");
      if (!g.ok) return;
      if (!g.roles.has("R2")) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "batch.accept.denied", s.userId,
          "import_batch", g.b.import_batch_id, { reason: "接受需 R2 角色" });
        return send(403, page("拒絕", b04CtxBar(g.b, "B-04"), "<h2>⛔ 接受需 R2 角色</h2>"));
      }
      const pred = acceptancePredicate({ status: g.b.status,
        identityStatus: g.b.identity_status, hashVerified: g.b.hash_verified });
      if (!pred.ok) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "batch.accept.rejected", s.userId,
          "import_batch", g.b.import_batch_id, { guard: pred.guard, reasons: pred.reasons });
        return send(409, page("拒絕", b04CtxBar(g.b, "B-04"),
          `<h2>⛔ ${pred.guard}：不滿足接受判定式</h2><ul>${pred.reasons.map((r) => `<li>${esc(r)}</li>`).join("")}</ul><p><a href="/">回 B-00</a></p>`));
      }
      exec(`UPDATE import_batch SET status='ACCEPTED' WHERE import_batch_id = :'b'::uuid`,
        { b: g.b.import_batch_id }, { tenantId: s.tenantId });
      audit(s.tenantId, "DOMAIN_EVENT", "import_batch.accepted", s.userId,
        "import_batch", g.b.import_batch_id, {});
      return send(302, "", { location: `/b04?batch=${g.b.import_batch_id}` });
    }

    // ── B-04 映射工作畫面 ──
    if (url.pathname === "/b04" && req.method === "GET") {
      const g = b04Guard(url.searchParams.get("batch") ?? "", "b04.view");
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
            <form method="post" action="/b04/submit" style="display:inline;margin:0">
              <input type="hidden" name="batch" value="${g.b.import_batch_id}">
              <button>映射完成確認（G-02）</button></form>　<a href="/">回 B-00</a></p>`));
    }

    // ── 建立映射草稿 ──
    if (url.pathname === "/b04/map" && req.method === "POST") {
      const fields = Object.fromEntries(new URLSearchParams((await readBody(req)).toString("utf8")));
      const g = b04Guard(fields["batch"] ?? "", "mapping.create");
      if (!g.ok) return;
      if (!g.roles.has("R2") && !g.roles.has("R7")) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "mapping.create.denied", s.userId,
          "import_batch", g.b.import_batch_id, { reason: "建立映射需 R2 或 R7" });
        return send(403, page("拒絕", b04CtxBar(g.b, "B-04"), "<h2>⛔ 建立映射需 R2 或 R7 角色</h2>"));
      }
      const sourceCode = fields["source_code"] ?? "";
      const target = fields["target"] ?? "";
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
      const next = query<{ v: string }>(
        `SELECT COALESCE(MAX(version_no), 0) + 1 AS v FROM mapping_rule
          WHERE engagement_id = :'e'::uuid AND source_account_code = :'sc'`,
        { e: g.b.engagement_id, sc: sourceCode }, { tenantId: s.tenantId })[0].v;
      const [row] = query<{ mapping_rule_id: string }>(
        `INSERT INTO mapping_rule (tenant_id, engagement_id, source_account_code,
                target_account_id, version_no, created_by)
         VALUES (:'t'::uuid, :'e'::uuid, :'sc', :'a'::uuid, ${Number(next)}, :'u'::uuid)
         RETURNING mapping_rule_id`,
        { t: s.tenantId, e: g.b.engagement_id, sc: sourceCode, a: target, u: s.userId },
        { tenantId: s.tenantId });
      audit(s.tenantId, "DOMAIN_EVENT", "mapping_rule.drafted", s.userId,
        "mapping_rule", row.mapping_rule_id, { source_code: sourceCode, target, version: Number(next) });
      return send(302, "", { location: `/b04?batch=${g.b.import_batch_id}` });
    }

    // ── 批准映射（R4；批准人 ≠ 建立者） ──
    if (url.pathname === "/b04/approve" && req.method === "POST") {
      const fields = Object.fromEntries(new URLSearchParams((await readBody(req)).toString("utf8")));
      const g = b04Guard(fields["batch"] ?? "", "mapping.approve");
      if (!g.ok) return;
      const ruleId = fields["rule"] ?? "";
      if (!g.roles.has("R4")) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "mapping.approve.denied", s.userId,
          "mapping_rule", ruleId, { reason: "批准需 R4 角色（§24.6 權限矩陣）" });
        return send(403, page("拒絕", b04CtxBar(g.b, "B-04"), "<h2>⛔ 批准映射需 R4 角色</h2>"));
      }
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
      exec(`UPDATE mapping_rule SET approved_by = :'u'::uuid, approved_at = now()
             WHERE mapping_rule_id = :'m'::uuid`,
        { u: s.userId, m: ruleId }, { tenantId: s.tenantId });
      audit(s.tenantId, "DOMAIN_EVENT", "mapping_rule.approved", s.userId, "mapping_rule", ruleId, {});
      return send(302, "", { location: `/b04?batch=${g.b.import_batch_id}` });
    }

    // ── 集團科目 TB 預覽（非正式輸出；§25.9 output_capability=PREVIEW） ──
    if (url.pathname === "/b04/preview" && req.method === "GET") {
      const g = b04Guard(url.searchParams.get("batch") ?? "", "b04.preview");
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
    if (url.pathname === "/b04/submit" && req.method === "POST") {
      const fields = Object.fromEntries(new URLSearchParams((await readBody(req)).toString("utf8")));
      const g = b04Guard(fields["batch"] ?? "", "mapping.submit");
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

    send(404, page("404", "", "<h2>找不到頁面</h2>"));
  } catch (e) {
    send(500, page("錯誤", "", `<h2>伺服器錯誤</h2><pre>${esc(String(e))}</pre>`));
  }
});

server.listen(PORT, "127.0.0.1", () =>
  console.log(`api listening on http://127.0.0.1:${PORT}`));
