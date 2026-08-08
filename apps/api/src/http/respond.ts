// HTTP 邊界：回應成形（狀態碼、Header、HTML）。
//
// Service 不得 import 本檔——「不依賴 HTML」是這次拆層的驗收條件之一。
// 版面與跳脫函式一字未改地自 server.ts 移入：拆層的回歸差異必須等於零，
// 順手美化版面會讓「HTML 行為不變」這條驗收失去意義。
import type { ServerResponse } from "node:http";

export const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g,
  (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c] as string));

// ── 共通版面：每個作業畫面固定顯示脈絡（§28.9 EngagementContext） ──
export function page(title: string, ctxBar: string, body: string): string {
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

/** 回應函式：狀態碼 ＋ HTML ＋ 額外 Header（如 x-error-code）。 */
export type Respond = (code: number, body: string, headers?: Record<string, string>) => void;

export function responder(res: ServerResponse): Respond {
  return (code, body, headers = {}) => {
    res.writeHead(code, { "content-type": "text/html; charset=utf-8", ...headers });
    res.end(body);
  };
}

