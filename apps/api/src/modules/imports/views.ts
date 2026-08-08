// 匯入批次的畫面元件。是 view，不是 access——放在 access 會讓「取得事實」與
// 「怎麼呈現」混在同一個模組，之後每個需要脈絡列的畫面都會被迫依賴資料存取層。
import { esc } from "../../http/respond.ts";
import type { BatchCtx } from "./access.ts";

export function b04CtxBar(b: BatchCtx, screen: string): string {
  return `<span>畫面 <b>${esc(screen)}</b></span><span>客戶 <b>${esc(b.client)}</b></span>` +
    `<span>法人 <b>${esc(b.entity)}</b></span><span>期間 <b>${esc(b.period)}</b></span>` +
    `<span>批次 <b>${b.import_batch_id.slice(0, 8)}</b>（${b.status}）</span>`;
}
