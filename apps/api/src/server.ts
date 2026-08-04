// API（§27 模組化單體宿主）。里程碑 1 垂直切片：
//   登入 → 選 客戶/法人/期間（EngagementContext）→ 上傳 TB → B-00 顯示結果。
// 畫面為走查骨架（真機換 Next.js）；控制邏輯（脈絡伺服器端驗證、雜湊、審計）是正式的。
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createHash, randomUUID } from "node:crypto";
import { query, exec } from "../../../packages/database/src/psql.ts";
import { putObject } from "../../../packages/database/src/objectstore.ts";
import { sign, verify, type Session } from "../../../packages/auth/src/session.ts";
import { config } from "../../../packages/config/src/index.ts";

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
         <table><tr><th>客戶</th><th>法人</th><th>期間</th><th>狀態</th><th>身分比對</th><th>檔案</th><th>說明</th></tr>
         ${batches.map((b) => `<tr><td>${esc(b.client)}</td><td>${esc(b.entity)}</td><td>${esc(b.period)}</td>
           <td><span class="badge st-${b.status}">${b.status}</span></td>
           <td><span class="badge st-${b.identity_status}">${b.identity_status}</span></td>
           <td>${esc(b.file_name)}</td><td class="note">${esc(b.quarantine_reason ?? "")}</td></tr>`).join("")}
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
      exec(`UPDATE import_batch SET status='UPLOADED' WHERE import_batch_id = :'id'::uuid`,
        { id: batchId }, { tenantId: s.tenantId });
      exec(`INSERT INTO source_document (tenant_id, import_batch_id, file_name, content_sha256, object_key, byte_size)
            VALUES (:'t'::uuid, :'id'::uuid, 'tb.csv', :'sha', :'k', ${data.length})`,
        { t: s.tenantId, id: batchId, sha, k: key }, { tenantId: s.tenantId });
      audit(s.tenantId, "DOMAIN_EVENT", "import_batch.uploaded", s.userId,
        "import_batch", batchId, { sha256: sha, bytes: data.length });
      return send(302, "", { location: "/" });
    }

    send(404, page("404", "", "<h2>找不到頁面</h2>"));
  } catch (e) {
    send(500, page("錯誤", "", `<h2>伺服器錯誤</h2><pre>${esc(String(e))}</pre>`));
  }
});

server.listen(PORT, "127.0.0.1", () =>
  console.log(`api listening on http://127.0.0.1:${PORT}`));
