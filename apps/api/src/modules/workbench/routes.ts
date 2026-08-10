// B-00 個人工作台。讀模型＋呈現，不需要 Service。
//
// 三層授權分開（見 queries.ts）：資料可見性、動作權限、待辦條件。
// 每個區塊只看它自己需要的角色——「有任何業務角色」不再同時決定所有事情。
import type { AuthenticatedContext } from "../../http/context.ts";
import { esc, page, type Respond } from "../../http/respond.ts";
import * as q from "./queries.ts";
import { four, qSec, batchAction, uploadForm } from "./views.ts";

export async function home(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const sc = q.scopeOf(s);
  const qIdentity = q.pendingIdentity(s, sc);
  const qReview = q.pendingReview(s, sc);
  const qApprove = q.pendingApproval(s, sc);
  const qReturned = q.returned(s, sc);
  const qDraftAdj = q.draftAdjustments(s, sc);
  const qDraftMap = q.draftMappings(s, sc);
  const batches = q.batches(s, sc);
  const opt = q.uploadOptions(s, sc);
  const periods = q.periods(s, sc);

  return send(200, page("B-00 個人工作台",
    `<span>畫面 <b>B-00 個人工作台</b></span><span>使用者 <b>${esc(s.userId.slice(-4))}</b></span>`,
    `<h2>等我處理的事項</h2>
     ${qSec("待身分確認", qIdentity.map((r) => `<tr>${four(r)}
        <td><span class="badge st-PENDING_CONFIRMATION">待確認</span></td>
        <td>批次 ${r.import_batch_id.slice(0, 8)}（v${r.batch_version}）</td>
        <td><a href="/b03/identity?batch=${r.import_batch_id}">開啟確認頁</a></td></tr>`), qIdentity.length)}
     ${qSec("待覆核", qReview.map((r) => `<tr>${four(r)}
        <td><span class="badge st-UPLOADED">待覆核</span></td><td>${esc(r.title)}</td>
        <td><a href="/b05?adj=${r.adjustment_id}">開啟 B-05</a></td></tr>`), qReview.length)}
     ${qSec("待批准", qApprove.map((r) => `<tr>${four(r)}
        <td><span class="badge st-UPLOADED">待批准</span></td><td>${esc(r.title)}</td>
        <td><a href="/b05?adj=${r.adjustment_id}">開啟 B-05</a></td></tr>`), qApprove.length)}
     ${qSec("被退回／待補證據", qReturned.map((r) => `<tr>${four(r)}
        <td><span class="badge st-QUARANTINED">被退回</span></td>
        <td>${esc(r.title)}（${esc(r.reason_category ?? "")}）</td>
        <td><a href="/b05?adj=${r.adjustment_id}">開啟 B-05</a></td></tr>`), qReturned.length)}
     ${qSec("未完成草稿", [
        ...qDraftAdj.map((r) => `<tr>${four(r)}
          <td><span class="badge st-UPLOADED">草稿</span></td><td>${esc(r.title)}</td>
          <td><a href="/b05?adj=${r.adjustment_id}">開啟 B-05</a></td></tr>`),
        ...qDraftMap.map((r) => `<tr>${four(r)}
          <td><span class="badge st-UPLOADED">映射草稿</span></td><td>${esc(r.source_account_code)}</td>
          <td>${r.source_import_batch_id
            ? `<a href="/b04?batch=${r.source_import_batch_id}">開啟 B-04</a>`
            : `<span class="note">—（無來源批次脈絡）</span>`}</td></tr>`),
      ], qDraftAdj.length + qDraftMap.length)}
     ${uploadForm(opt)}
     ${periods.length ? `<h2>期間</h2>
     <table><tr><th>客戶</th><th>單位</th><th>期間</th><th>狀態</th><th></th></tr>
     ${periods.map((p) => `<tr><td>${esc(p.client)}</td><td>${esc(p.unit)}</td>
       <td>${esc(p.period_label)}（rev ${esc(p.revision_no)}）</td>
       <td><span class="badge st-${esc(p.status)}">${esc(p.status)}</span></td>
       <td><a href="/b02?revision=${p.period_revision_id}">開啟 B-02</a></td></tr>`).join("")}
     </table>` : ""}
     <h2>批次狀態</h2>
     <table><tr><th>客戶</th><th>法人</th><th>期間</th><th>狀態</th><th>身分比對</th><th>檔案</th><th>說明</th><th>動作</th></tr>
     ${batches.map((b) => `<tr><td>${esc(b.client)}</td><td>${esc(b.entity)}</td><td>${esc(b.period)}</td>
       <td><span class="badge st-${b.status}">${b.status}</span></td>
       <td><span class="badge st-${b.identity_status}">${b.identity_status}</span></td>
       <td>${esc(b.file_name)}</td><td class="note">${esc(b.quarantine_reason ?? "")}</td>
       <td>${batchAction(sc, b)}</td></tr>`).join("")}
     </table><p class="note">此頁只顯示您具業務角色且被指派之案件；未指派案件的名稱與數量不會出現（WKB-a）。</p>`));
}
