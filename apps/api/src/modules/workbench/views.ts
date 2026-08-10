// B-00 的呈現。查詢在 queries.ts，這裡只負責 HTML。
//
// **不渲染使用者無權執行的按鈕**（接受、B-04、身分確認、上傳表單都逐案件判斷）。
// 這是使用性而非安全性——後端各 route 仍會再判一次；畫面上看不到，
// 不代表打得進去的請求會通過。
import { esc } from "../../http/respond.ts";
import type { Scope } from "./queries.ts";

type Row = Record<string, string>;

export const four = (r: Row) =>
  `<td>${esc(r.client)}</td><td>${esc(r.entity)}</td><td>${esc(r.period)}</td>`;

export const qSec = (title: string, rows: string[], count: number) =>
  `<h3>${esc(title)}（${count}）</h3>` + (count
    ? `<table><tr><th>客戶</th><th>法人</th><th>期間</th><th>狀態</th><th>項目</th><th></th></tr>${rows.join("")}</table>`
    : `<p class="note">無</p>`);

/** 批次列的動作欄：每一格都依**該批次所屬案件**的角色決定要不要渲染。 */
export function batchAction(sc: Scope, b: Row): string {
  const eng = b.engagement_id;
  const canAccept = sc.has(eng, "R2");                     // 接受＝資料接受動作，僅 R2
  const canIdentity = sc.has(eng, "R2", "R3", "R4");
  const canB04 = sc.has(eng, "R2", "R3", "R4");            // R7 暫不給連結（完整 B-04 未開放）
  if (b.status === "VALIDATED"
      && (b.identity_status === "MATCHED" || b.identity_status === "MANUALLY_RESOLVED")) {
    return canAccept
      ? `<form method="post" action="/b04/accept" style="margin:0"><input type="hidden" name="batch" value="${b.import_batch_id}"><button>接受</button></form>`
      : `<span class="note">—</span>`;
  }
  if (b.status === "VALIDATED" && b.identity_status === "PENDING_CONFIRMATION") {
    return canIdentity ? `<a href="/b03/identity?batch=${b.import_batch_id}">身分確認</a>`
                       : `<span class="note">—</span>`;
  }
  if (b.status === "ACCEPTED") {
    return canB04 ? `<a href="/b04?batch=${b.import_batch_id}">B-04 映射</a>`
                  : `<span class="note">—</span>`;
  }
  return "";
}

export function uploadForm(opt: { eng: Row[]; entities: Row[]; periods: Row[]; providers: Row[] }): string {
  if (!opt.eng.length) return "";
  // 沒有可選的 R1 時**不靜默把上傳者當提供者**：那會讓補件與逾期 KPI 算錯人。
  const providerField = opt.providers.length
    ? `資料提供者 <select name="provided_by">${opt.providers
        .map((p) => `<option value="${p.user_id}">${esc(p.display_name)}</option>`).join("")}</select>`
    : `<span class="note">⚠ 尚未設定資料提供者（本案件沒有有效的 R1 指派）</span>`;
  return `<h2>上傳試算表（TB）</h2>
    <form class="up" method="post" action="/upload">
      客戶 <select name="engagement">${opt.eng
        .map((r) => `<option value="${r.engagement_id}">${esc(r.name)}</option>`).join("")}</select>
      法人 <select name="legal_entity">${opt.entities
        .map((r) => `<option value="${r.legal_entity_id}">${esc(r.name)}</option>`).join("")}</select>
      期間 <select name="period_revision">${opt.periods
        .map((r) => `<option value="${r.period_revision_id}">${esc(r.label)}</option>`).join("")}</select><br>
      ${providerField}<br>
      <textarea name="csv" rows="6" cols="80"
placeholder="#legal_entity_code=1234567890123
account_code,account_name,debit,credit
1100,現金,1000,0
4000,売上,0,1000"></textarea><br>
      <button>上傳</button>
      <span class="note">上傳後由背景工作驗證：借貸平衡（G-01）＋檔案歸屬比對（identity_status）</span>
    </form>`;
}
