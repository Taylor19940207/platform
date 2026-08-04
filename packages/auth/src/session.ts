// 開發用 session：HMAC-SHA256 簽章 cookie。真機換正式 IdP／SSO。
import { createHmac, randomBytes } from "node:crypto";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { config, REPO_ROOT } from "../../config/src/index.ts";

const SECRET_PATH = join(REPO_ROOT, "var/session.secret");
function secret(): string {
  if (config.sessionSecret) return config.sessionSecret;   // 由 .env.local 注入
  if (!existsSync(SECRET_PATH)) {
    mkdirSync(dirname(SECRET_PATH), { recursive: true });
    writeFileSync(SECRET_PATH, randomBytes(32).toString("hex"));
  }
  return readFileSync(SECRET_PATH, "utf8");
}

export interface Session { userId: string; tenantId: string }

export function sign(s: Session): string {
  const body = Buffer.from(JSON.stringify(s)).toString("base64url");
  const mac = createHmac("sha256", secret()).update(body).digest("base64url");
  return `${body}.${mac}`;
}
export function verify(token: string | undefined): Session | null {
  if (!token) return null;
  const [body, mac] = token.split(".");
  if (!body || !mac) return null;
  const want = createHmac("sha256", secret()).update(body).digest("base64url");
  if (mac !== want) return null;
  try { return JSON.parse(Buffer.from(body, "base64url").toString()) as Session; }
  catch { return null; }
}
