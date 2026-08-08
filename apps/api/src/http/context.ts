// HTTP 邊界：把 node:http 的請求收斂成「已驗證身分的請求脈絡」。
//
// 這一層存在的理由只有一個：**讓 Service 不必認識 IncomingMessage。**
// Service 需要的是 tenantId／userId／已解析的表單值，不是 socket。
// 身分只能從這裡取得——Session 是伺服器端簽章的，請求本體不得自帶 actor
// （所有連線共用 app_runtime，DB 無法證明呼叫者本人就是該自然人）。
import type { IncomingMessage } from "node:http";
import { verify, type Session } from "../../../../packages/auth/src/session.ts";

export function readBody(req: IncomingMessage): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

export function cookies(req: IncomingMessage): Record<string, string> {
  return Object.fromEntries((req.headers.cookie ?? "").split(";")
    .map((p) => p.trim().split("=")).filter((kv) => kv.length === 2) as [string, string][]);
}

export function sessionOf(req: IncomingMessage): Session | null {
  return verify(cookies(req)["s"]);
}

export interface AuthenticatedContext {
  readonly url: URL;
  readonly method: string;
  readonly session: Session;
  /** 表單欄位。請求本體只能讀一次，因此在此記憶化。 */
  form(): Promise<Record<string, string>>;
  rawBody(): Promise<string>;
}

export function authenticatedContext(
  req: IncomingMessage, url: URL, session: Session,
): AuthenticatedContext {
  let bodyPromise: Promise<string> | null = null;
  const raw = (): Promise<string> => {
    bodyPromise ??= readBody(req).then((b) => b.toString("utf8"));
    return bodyPromise;
  };
  return {
    url, method: req.method ?? "GET", session,
    rawBody: raw,
    async form() {
      return Object.fromEntries(new URLSearchParams(await raw()));
    },
  };
}
