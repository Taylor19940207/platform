// 上傳的 HTTP route。
//
// 授權與歸屬全部在 guard；交易編排全部在 service。這裡只做：讀表單、
// 從 Session 取身分、呼叫兩者、把結果轉成 HTTP。
import { randomUUID } from "node:crypto";
import type { AuthenticatedContext } from "../../http/context.ts";
import { esc, page, type Respond } from "../../http/respond.ts";
import { audit } from "../audit.ts";
import { checkUpload, resolveProvider } from "./guard.ts";
import { upload as uploadService } from "./service.ts";

/** 識別規則版本：與 worker 一致，構成 job 冪等鍵的一部分。 */
const DETECTION_RULE_VERSION = "detect-r1";

export async function upload(ctx: AuthenticatedContext, send: Respond): Promise<void> {
  const s = ctx.session;
  const fields = await ctx.form();
  const engagement = fields["engagement"] ?? "";
  const legalEntity = fields["legal_entity"] ?? "";
  const periodRevision = fields["period_revision"] ?? "";
  const csv = (fields["csv"] ?? "").replace(/\r\n/g, "\n");

  // 伺服器端授權與歸屬驗證：繞過 UI 直接呼叫也會被擋，並記錄違規嘗試（CTX-a）
  const v = checkUpload(s, engagement, legalEntity, periodRevision);
  if (!v.ok) {
    // 拒絕時 ImportBatch 尚不存在——記成 import_batch 會讓稽核人以為該批次曾存在。
    // 這裡的物件是「一次上傳請求」，不是批次。
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "context.mismatch", s.userId,
      "upload_request", randomUUID(),
      { code: v.code, reason: v.reason, engagement, legal_entity: legalEntity,
        period_revision: periodRevision,
        engagement_roles: v.engagementRoles, tenant_roles: v.tenantRoles });
    return send(403, page("拒絕", "<b>⛔ 歸屬驗證失敗</b>",
      `<h2>⛔ ${esc(v.reason)}</h2><p>此次嘗試已寫入稽核軌跡。</p><p><a href="/">回 B-00</a></p>`));
  }

  // provided_by＝真正的資料提供者：R1 自己上傳即本人；R2 代傳須選定該案件的
  // 有效 R1，且後端重新驗證，不信任表單 UUID。
  const pv = resolveProvider(s, engagement, v.roles, fields["provided_by"] ?? "");
  if (!pv.ok) {
    audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "upload.provider.rejected", s.userId,
      "upload_request", randomUUID(),
      { code: pv.code, reason: pv.reason, engagement,
        selected: fields["provided_by"] ?? "" });
    return send(409, page("拒絕", "<b>⛔ 資料提供者</b>",
      `<h2>⛔ ${esc(pv.reason)}</h2><p>此次嘗試已寫入稽核軌跡。</p><p><a href="/">回 B-00</a></p>`),
      { "x-error-code": pv.code });
  }

  // uploaded_by 一律取自 Session；表單傳什麼都不採信。
  uploadService({
    tenantId: s.tenantId, engagementId: engagement, legalEntityId: legalEntity,
    periodRevisionId: periodRevision, csv,
    uploadedBy: s.userId, providedBy: pv.providedBy,
    detectionRuleVersion: DETECTION_RULE_VERSION });
  return send(302, "", { location: "/" });
}
