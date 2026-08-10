// B-03 身分確認（UNVERIFIABLE 人工確認）的 HTTP route（SLICE-M2-04）。
//
// 授權一律**案件層**（§26.3）：檢視 R2／R3／R4、確認 R2。
// SOD-07 的最終裁決在 DB（fn_sod07_guard）——這裡的預檢只是為了給人看得懂的
// 訊息與正確的狀態碼，不是唯一判定。
import type { AuthenticatedContext } from "../../http/context.ts";
import { esc, page, type Respond } from "../../http/respond.ts";
import { query } from "../../../../../packages/database/src/psql.ts";
import { audit } from "../audit.ts";
import { engagementRolesOf, tenantRolesOf } from "../engagements/access.ts";
import { loadIdentityContext } from "./access.ts";
import { confirmIdentity } from "./service.ts";

/** §24.6：檢視需案件層 R2／R3／R4；確認（資料接受動作）僅 R2。 */
export const B03 = { view: ["R2", "R3", "R4"], confirm: ["R2"] } as const;

export async function identityView(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const b = loadIdentityContext(s.tenantId, ctx.url.searchParams.get("batch") ?? "");
  if (!b) return send(404, page("404", "", "<h2>批次不存在</h2>"));
  // 案件層授權（§26.3）：租戶層角色不得取得客戶工作資料
  const roles = engagementRolesOf(s, b.engagement_id);
  if (!B03.view.some((x) => roles.has(x))) {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "identity.view.denied", s.userId,
      "import_batch", b.import_batch_id,
      { reason: `檢視身分確認頁需本案件的 ${B03.view.join("／")} 角色（§24.6）`,
        engagement_roles: [...roles].sort(), tenant_roles: [...tenantRolesOf(s)].sort() });
    return send(403, page("拒絕", "<b>⛔</b>", "<h2>⛔ 未被指派此案件</h2><p>此次嘗試已寫入稽核軌跡。</p>"));
  }
  const assessments = query<Record<string, string>>(
    `SELECT assessment_id, evidence_kind, match_result, detected_identity::text AS detected,
            detection_rule_version, assessed_at::text AS assessed_at
       FROM source_identity_assessment WHERE import_batch_id = :'b'::uuid
      ORDER BY assessed_at, assessment_id`,
    { b: b.import_batch_id }, { tenantId: s.tenantId });
  const ctxBar = `<span>畫面 <b>B-03 身分確認</b></span><span>客戶 <b>${esc(b.client)}</b></span>
    <span>法人 <b>${esc(b.entity)}</b></span><span>期間 <b>${esc(b.period)}</b></span>
    <span>批次 <b>${b.import_batch_id.slice(0, 8)}（v${b.batch_version}）</b></span>`;
  const confirmable = b.status === "VALIDATED" && b.identity_status === "PENDING_CONFIRMATION";
  return send(200, page("B-03 身分確認", ctxBar,
    `<h2>宣告目標</h2>
     <table><tr><th>客戶</th><th>法人</th><th>法人權威代碼</th><th>期間</th><th>批次版本</th><th>檔案 SHA-256</th></tr>
     <tr><td>${esc(b.client)}</td><td>${esc(b.entity)}</td><td>${esc(b.authoritative_code ?? "—")}</td>
     <td>${esc(b.period)}</td><td>v${esc(b.batch_version)}</td><td class="note">${esc(b.file_sha256 ?? "")}</td></tr></table>
     <h2>偵測證據（全部評估，含歷史）</h2>
     <table><tr><th>current</th><th>證據強度</th><th>偵測值</th><th>判定</th><th>規則版本</th><th>別名表版本</th><th>評估時間</th></tr>
     ${assessments.map((a) => `<tr>
       <td>${a.assessment_id === b.current_identity_assessment_id ? "✓ current" : "（歷史）"}</td>
       <td>${esc(a.evidence_kind)}</td><td class="note">${esc(a.detected)}</td>
       <td><span class="badge st-${a.match_result === "MATCH" ? "MATCHED" : a.match_result === "CONFLICT" ? "CONFLICT" : "PENDING_CONFIRMATION"}">${a.match_result}</span></td>
       <td>${esc(a.detection_rule_version)}</td><td>—（本刀無別名表）</td>
       <td class="note">${esc(a.assessed_at.slice(0, 19))}</td></tr>`).join("")}
     </table>
     ${b.identity_status === "CONFLICT"
       ? `<p>⛔ <b>CONFLICT 不提供人工豁免</b>（§25.5）。出路只有三條：修正宣告目標、
          重新上傳正確檔案、或以新版識別規則重新偵測。</p>`
       : b.identity_status === "MANUALLY_RESOLVED"
       ? `<p>✅ 已人工確認（MANUALLY_RESOLVED）。可回 <a href="/">B-00</a> 執行接受（G-01 判定式）。</p>`
       : confirmable ? `
     <h2>人工確認（資料接受角色 R2；上傳者不得確認自己——SOD-07）</h2>
     <form class="up" method="post" action="/b03/identity/confirm">
       <input type="hidden" name="batch" value="${b.import_batch_id}">
       <input type="hidden" name="assessment_id" value="${b.current_identity_assessment_id}">
       確認理由（必填）<br><textarea name="reason" rows="3" cols="70"
         placeholder="例：已向客戶電話確認為 A 商事株式会社之試算表"></textarea><br>
       證據參照（選填）<input name="evidence_ref" size="40"><br>
       <button>確認歸屬（寫入不可變紀錄）</button>
       <span class="note">確認不會自動接受——接受仍須另行執行並通過 G-01 三條件（CTX-g）</span>
     </form>` : `<p class="note">批次目前為 ${esc(b.status)}／${esc(b.identity_status)}，不在可確認狀態。</p>`}
     <p><a href="/">回 B-00</a></p>`));
}

export async function identityConfirm(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const f = await ctx.form();
  const b = loadIdentityContext(s.tenantId, f["batch"] ?? "");
  if (!b) return send(404, page("404", "", "<h2>批次不存在</h2>"));
  const roles = engagementRolesOf(s, b.engagement_id);
  if (!B03.confirm.some((x) => roles.has(x))) {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "identity.confirm.denied", s.userId,
      "import_batch", b.import_batch_id,
      { code: "ROLE_REQUIRED", reason: "確認需該案件的有效 R2 指派（資料接受角色）",
        engagement_roles: [...roles].sort(), tenant_roles: [...tenantRolesOf(s)].sort() });
    return send(403, page("拒絕", "<b>⛔</b>", "<h2>⛔ 確認需該案件的有效 R2 指派</h2>"));
  }
  if (b.uploaded_by === s.userId) {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "identity.confirm.denied", s.userId,
      "import_batch", b.import_batch_id,
      { code: "SOD_07", reason: "上傳者不得確認自己上傳的批次（角色切換無效）" });
    return send(403, page("拒絕", "<b>⛔</b>",
      "<h2>⛔ SOD-07：上傳者不得確認自己上傳的批次</h2><p>與當下角色無關。此次嘗試已寫入稽核軌跡。</p>"));
  }
  // 一般欄位驗證錯誤：409＋機器代碼，不寫 CVA（§25.18）
  if (!(f["reason"] ?? "").trim())
    return send(409, page("欄位錯誤", "<b>⛔</b>",
      "<h2>REASON_REQUIRED</h2><p>確認理由為必填。</p>"));
  if (b.status !== "VALIDATED" || b.identity_status !== "PENDING_CONFIRMATION") {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "identity.confirm.rejected", s.userId,
      "import_batch", b.import_batch_id,
      { code: "STATE_NOT_CONFIRMABLE", status: b.status, identity_status: b.identity_status });
    return send(409, page("拒絕", "<b>⛔</b>",
      `<h2>⛔ STATE_NOT_CONFIRMABLE</h2><p>需 VALIDATED＋PENDING_CONFIRMATION（目前 ${esc(b.status)}／${esc(b.identity_status)}）。</p>`));
  }
  if ((f["assessment_id"] ?? "") !== b.current_identity_assessment_id) {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "identity.confirm.rejected", s.userId,
      "import_batch", b.import_batch_id,
      { code: "NOT_CURRENT_ASSESSMENT", selected: f["assessment_id"] ?? "" });
    return send(409, page("拒絕", "<b>⛔</b>",
      "<h2>⛔ NOT_CURRENT_ASSESSMENT</h2><p>只能確認 current assessment——重新解析後的舊評估不可沿用（CTX-e）。</p>"));
  }
  // 交易編排移入 service：Resolution＋MANUALLY_RESOLVED＋DomainEvent 同生共死。
  // DB 的 fn_sod07_guard 等守衛仍是最後防線，未被改寫成 TypeScript 唯一判定。
  confirmIdentity({
    batchId: b.import_batch_id, batchVersion: Number(b.batch_version),
    assessmentId: b.current_identity_assessment_id,
    reason: f["reason"].trim(), evidenceRef: (f["evidence_ref"] ?? "").trim(),
    actorId: s.userId, tenantId: s.tenantId });
  return send(302, "", { location: `/b03/identity?batch=${b.import_batch_id}` });
}
