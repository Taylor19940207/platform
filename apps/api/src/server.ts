// API 入口（§27 模組化單體宿主）。
//
// 這裡只剩五件事：health、開發登入、Session 建構、dispatcher、listen。
// 所有業務路由都在 modules/ 下，經 http/dispatch.ts 分派；授權一律**案件層
// 逐動作**判斷（§26.3：Tenant 內每個 Engagement 必須明示授權，租戶層角色
// 不得隱式取得客戶資料），DB 守衛仍是最後防線。
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { query } from "../../../packages/database/src/psql.ts";
import { sign, type Session } from "../../../packages/auth/src/session.ts";
import { config } from "../../../packages/config/src/index.ts";
import { authenticatedContext, cookies, sessionOf } from "./http/context.ts";
import { dispatch } from "./http/dispatch.ts";
import { esc, page, responder } from "./http/respond.ts";

const PORT = config.port;

const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
  const url = new URL(req.url ?? "/", "http://x");
  const send = responder(res);
  try {
    if (url.pathname === "/health") {
      const [row] = query<{ ok: number }>("SELECT 1 AS ok", {}, { asRuntime: false });
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify({ ok: true, db: row?.ok === 1 }));
    }

    // ── 登入（開發用：列出種子使用者；真機換 SSO） ──
    // Session 到期後回到原畫面（NFR-INT-002 INT-b）：把原本要去的位址記在
    // 短期 cookie，登入後導回。**只記路徑**，不記任何業務內容。
    if (url.pathname === "/" && !sessionOf(req)) {
      const users = query<{ user_id: string; email: string; display_name: string; tenant_id: string }>(
        "SELECT user_id, email, display_name, tenant_id FROM app_user WHERE is_active", {}, { asRuntime: false });
      return send(200, page("登入", "<b>未登入</b>",
        `<h2>登入（開發模式）</h2><p class="note">走查骨架：點選身分即登入。真機環境換 SSO／IdP。</p>` +
        users.map((u) => `<p><a href="/login?u=${u.user_id}&t=${u.tenant_id}">${esc(u.display_name)}（${esc(u.email)}）</a></p>`).join("")));
    }
    if (url.pathname === "/login") {
      const s: Session = { userId: url.searchParams.get("u") ?? "", tenantId: url.searchParams.get("t") ?? "" };
      // 只接受本站相對路徑，避免開放轉址
      const raw = cookies(req)["resume"] ?? "";
      const next = /^\/[^/\\]/.test(decodeURIComponent(raw)) ? decodeURIComponent(raw) : "/";
      return send(302, "", { "set-cookie": `s=${sign(s)}; HttpOnly; Path=/`, location: next });
    }

    const s = sessionOf(req);
    if (!s) {
      // 記下原本要去的畫面，登入後回到同一個案件、期間與 Adjustment
      const resume = req.method === "GET" ? url.pathname + url.search : "/";
      return send(302, "", {
        "set-cookie": `resume=${encodeURIComponent(resume)}; HttpOnly; Path=/; Max-Age=600`,
        location: "/" });
    }

    // 身分驗證通過後才建立脈絡。Context 此時**不讀請求本體**——
    // 只有實際呼叫 form() 的 route 才會消耗它，未命中的路由不受影響。
    if (await dispatch(authenticatedContext(req, url, s), send)) return;

    send(404, page("404", "", "<h2>找不到頁面</h2>"));
  } catch (e) {
    send(500, page("錯誤", "", `<h2>伺服器錯誤</h2><pre>${esc(String(e))}</pre>`));
  }
});

server.listen(PORT, "127.0.0.1", () =>
  console.log(`api listening on http://127.0.0.1:${PORT}`));
