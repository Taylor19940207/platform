// 調整生命週期的使用案例編排（SLICE-M2-02A／§25.7）。
//
// 邊界：不 import node:http 型別，不產生 HTML，身分只由呼叫端從 Session 傳入。
// **SQL 逐字沿用**——這一刀是拆層，不是改會計行為。SoD、版本遞增、快照與物化
// 的交易邊界一律不動；DB 觸發器（0007／0008／0009）仍是最後防線。
//
// 稽核分工：使用案例被拒時的 ControlViolationAttempt 寫在這裡（Service 的責任）；
// 「未被指派此案件」屬 route 層的存取閘（發生在使用案例被呼叫之前），留在 route。
import { createHash, randomUUID } from "node:crypto";
import { query, exec } from "../../../../../packages/database/src/psql.ts";
import { canSubmit, canReview, canApprove, legalTransition, previewOnlyJudgment,
  decimalOf, cents, type AdjustmentState, type GuardResult }
  from "../../../../../packages/domain/src/adjustment.ts";
import { audit, auditSql } from "../audit.ts";
import { adjLines, type AdjRow, type AdjLineRow } from "./access.ts";

type Refusal = Extract<GuardResult, { ok: false }>;

export type AdjustmentOutcome =
  | { ok: true; kind?: undefined }
  | { ok: false; kind: "ROLE"; need: string }
  | { ok: false; kind: "GUARD"; verdict: Refusal }
  | { ok: false; kind: "VERSION_CONFLICT"; base: number; current: number }
  | { ok: false; kind: "LINES_INVALID"; errors: { lineNo: number; error: string }[] }
  | { ok: false; kind: "CONCURRENT_CONFLICT"; base: number }
  /** 同來源同序號**同內容**重送：真的是重試，回報成功並附目前版本。 */
  | { ok: true; kind: "IDEMPOTENT_REPLAY"; objectVersion: number }
  /** 同來源同序號但**內容不同**：序號被重用，必須拒絕——否則會宣稱保存成功而存的是舊內容。 */
  | { ok: false; kind: "IDEMPOTENCY_KEY_REUSED"; objectVersion: number }
  /**
   * 同來源的舊請求晚到：**拒絕**，不是成功。
   * 它沒有被套用，回報成功會讓前端清掉 dirty——那正是「已保存卻沒存」。
   */
  | { ok: false; kind: "STALE_SEQUENCE"; objectVersion: number };

export interface Actor { userId: string; tenantId: string; roles: Set<string> }

/** domain 判定所需的狀態物件（與 DB 守衛同語意）。 */
export const stateOf = (r: AdjRow, lines: AdjLineRow[]): AdjustmentState => ({
  status: r.status, preparedBy: r.prepared_by, reviewedBy: r.reviewed_by,
  evidence: { legalBasis: r.legal_basis, evidenceRef: r.evidence_ref,
              judgmentReason: r.judgment_reason, languageTag: r.language_tag },
  lines: lines.map((l) => ({ debitCents: cents(l.debit), creditCents: cents(l.credit) })),
});

/**
 * business version 里程碑快照的 SQL 片段（不執行）。
 *
 * 必須與狀態遷移在**同一交易**內送出：先更新狀態再另行插入快照，一旦快照失敗
 * 就會留下「狀態已前進、不可變版本不存在」的資料——這是覆核回饋指出的缺口。
 */
const snapshotSql = (a: Actor, r: AdjRow, lines: AdjLineRow[], bv: number, nextStatus: string,
                     milestone: string, role: string,
                     reasonCategory: string | null, reasonNote: string | null):
    { sql: string; params: Record<string, string> } => {
  const content = JSON.stringify({
    title: r.title, status: nextStatus,
    evidence: { legal_basis: r.legal_basis, evidence_ref: r.evidence_ref,
                judgment_reason: r.judgment_reason, language_tag: r.language_tag },
    lines: lines.map((l) => ({ line_no: l.line_no, account: l.code,
                               debit: l.debit, credit: l.credit })),
  });
  return {
    sql: `INSERT INTO adjustment_version_snapshot
            (tenant_id, adjustment_id, business_version, milestone, actor_id, acting_role,
             reason_category, reason_note, content, content_sha256)
          VALUES (:'t'::uuid, :'a'::uuid, ${bv}, :'sm'::adjustment_milestone, :'u'::uuid,
                  :'sr'::role_code,
                  ${reasonCategory ? ":'src'" : "NULL"}, ${reasonNote ? ":'srn'" : "NULL"},
                  :'sc'::jsonb, :'sh');`,
    params: { t: a.tenantId, a: r.adjustment_id, sm: milestone, u: a.userId, sr: role,
              ...(reasonCategory ? { src: reasonCategory } : {}),
              ...(reasonNote ? { srn: reasonNote } : {}),
              sc: content, sh: createHash("sha256").update(content).digest("hex") },
  };
};

const cvaGuard = (a: Actor, r: AdjRow, action: string, g: Refusal, extra: object = {}): void => {
  audit(a.tenantId, "CONTROL_VIOLATION_ATTEMPT", `${action}.rejected`, a.userId,
    "adjustment", r.adjustment_id, { guard: g.guard, reasons: g.reasons, ...extra });
};
const cvaRole = (a: Actor, r: AdjRow, action: string, need: string): void => {
  audit(a.tenantId, "CONTROL_VIOLATION_ATTEMPT", `${action}.denied`, a.userId,
    "adjustment", r.adjustment_id, { reason: `需 ${need} 角色（§24.6 權限矩陣）` });
};

// ── 建立草稿（R2） ───────────────────────────────────────────
export interface CreateInput { engagementId: string; periodRevisionId: string; title: string }

export function createDraft(a: Actor, input: CreateInput):
    { ok: true; adjustmentId: string } | { ok: false; kind: "BASIS_NOT_CONFIGURED" } {
  // 多基礎橋樑（SLICE-M2-06）：本刀的 B-05 只建 A→C ＋ GROUP_GAAP_ADJ 的調整。
  // 基礎是案件內的口徑，缺了就明白拒絕——不得以任意基礎頂替，也不得靜默寫 NULL。
  const br = query<{ from_id: string; to_id: string; layer_id: string }>(
    `SELECT a.basis_id AS from_id, c.basis_id AS to_id, l.layer_id
       FROM book_basis a, book_basis c, posting_layer l
      WHERE a.engagement_id = :'e'::uuid AND a.code = 'A'
        AND c.engagement_id = :'e'::uuid AND c.code = 'C'
        AND l.code = 'GROUP_GAAP_ADJ'`,
    { e: input.engagementId }, { tenantId: a.tenantId })[0];
  if (!br) return { ok: false, kind: "BASIS_NOT_CONFIGURED" };

  const adjId = randomUUID();
  const ev = auditSql(a.tenantId, "DOMAIN_EVENT", "adjustment.drafted", a.userId,
    "adjustment", adjId, { title: input.title });
  exec(`BEGIN;
        INSERT INTO adjustment (adjustment_id, tenant_id, engagement_id, period_revision_id,
                title, prepared_by, basis_from_id, basis_to_id, posting_layer_id)
        VALUES ('${adjId}'::uuid, :'t'::uuid, :'e'::uuid, :'pr'::uuid, :'ti', :'u'::uuid,
                :'bf'::uuid, :'bt'::uuid, :'bl'::uuid);
        ${ev.sql}
        COMMIT;`,
    { t: a.tenantId, e: input.engagementId, pr: input.periodRevisionId,
      ti: input.title, u: a.userId,
      bf: br.from_id, bt: br.to_id, bl: br.layer_id, ...ev.params }, { tenantId: a.tenantId });
  return { ok: true, adjustmentId: adjId };
}

// ── 儲存草稿（object_version 樂觀鎖；不產生 business_version） ──
export interface SaveInput {
  baseObjectVersion: number; title: string; legalBasis: string; evidenceRef: string;
  judgmentReason: string; languageTag: string; linesText: string;
  /** 編輯來源。同一自然人的不同分頁**必須**取得不同值（§26.9）。 */
  editSessionId: string;
  /** 冪等鍵：同來源遞增。重試與亂序到達靠它去重。 */
  clientSaveSequence: number;
}

/**
 * 保存內容的正規化雜湊。冪等鍵的第三個成分——**沒有它，同序號不同內容會被
 * 當成重試而靜默丟棄**。明細先正規化（去空白、去空行）再入雜湊，
 * 避免純排版差異造成假的「內容不同」。
 */
function saveContentHash(input: SaveInput): string {
  const lines = input.linesText.replace(/\r\n/g, "\n").split("\n")
    .map((x) => x.trim()).filter(Boolean).join("\n");
  return createHash("sha256").update(JSON.stringify([
    input.title, input.legalBasis, input.evidenceRef,
    input.judgmentReason, input.languageTag, lines,
  ])).digest("hex");
}

/** 保存後回讀伺服器確認的版本——前端顯示的「已保存」必須以此為準。 */
export function currentObjectVersion(tenantId: string, adjustmentId: string): number {
  return Number(query<{ v: string }>(
    `SELECT object_version::text AS v FROM adjustment WHERE adjustment_id = :'a'::uuid`,
    { a: adjustmentId }, { tenantId })[0]?.v ?? 0);
}

export function save(a: Actor, r: AdjRow, input: SaveInput): AdjustmentOutcome {
  if (r.status !== "DRAFTING") {
    const verdict: Refusal = { ok: false, guard: "狀態",
      reasons: [`調整已離開草稿階段（${r.status}），不可編輯`] };
    cvaGuard(a, r, "adjustment.save", verdict);
    return { ok: false, kind: "GUARD", verdict };
  }
  // 冪等與亂序必須在樂觀鎖**之前**判定：重送的請求其 base 版本必然已過期，
  // 先判樂觀鎖的話，使用者會看到自己跟自己衝突——那是假衝突。
  const contentHash = saveContentHash(input);
  if (input.editSessionId && r.edit_session_id === input.editSessionId
      && r.client_save_sequence !== null && r.client_save_sequence !== "") {
    const lastSeq = Number(r.client_save_sequence);
    if (input.clientSaveSequence === lastSeq) {
      // 冪等鍵必須涵蓋內容：同序號帶不同內容時回報成功，等於宣稱存了實際沒存的東西。
      if (r.last_save_content_hash === contentHash) {
        return { ok: true, kind: "IDEMPOTENT_REPLAY", objectVersion: r.object_version };
      }
      audit(a.tenantId, "CONTROL_VIOLATION_ATTEMPT", "adjustment.save.rejected", a.userId,
        "adjustment", r.adjustment_id,
        { code: "IDEMPOTENCY_KEY_REUSED", edit_session_id: input.editSessionId,
          client_save_sequence: input.clientSaveSequence });
      return { ok: false, kind: "IDEMPOTENCY_KEY_REUSED", objectVersion: r.object_version };
    }
    if (input.clientSaveSequence < lastSeq) {
      return { ok: false, kind: "STALE_SEQUENCE", objectVersion: r.object_version };
    }
  }
  const base = input.baseObjectVersion;
  if (base !== r.object_version) {
    // 樂觀鎖衝突：拒絕並顯示，絕不靜默覆蓋（§26.9）
    audit(a.tenantId, "CONTROL_VIOLATION_ATTEMPT", "adjustment.save.conflict", a.userId,
      "adjustment", r.adjustment_id,
      { reason: "object_version 衝突", base_object_version: base, current: r.object_version });
    return { ok: false, kind: "VERSION_CONFLICT", base, current: r.object_version };
  }
  // 明細先全部解析並解析科目；任何一列不合法就整筆拒絕。
  // 舊版把未知科目靜默略過後回傳成功——那不符合「伺服器已確認保存」。
  const parsed = input.linesText.replace(/\r\n/g, "\n").split("\n")
    .map((x) => x.trim()).filter(Boolean)
    .map((line, i) => {
      const [code = "", d = "0", c = "0"] = line.split(",").map((x) => x.trim());
      let debit: string, credit: string;
      try { debit = decimalOf(cents(d)); credit = decimalOf(cents(c)); }
      catch { return { lineNo: i + 1, code, error: `金額格式錯誤：${d}／${c}` }; }
      const acc = query<{ account_id: string }>(
        `SELECT a.account_id FROM account a JOIN chart_of_accounts ch ON ch.coa_id = a.coa_id
          WHERE ch.engagement_id = :'e'::uuid AND a.code = :'c'`,
        { e: r.engagement_id, c: code }, { tenantId: a.tenantId })[0];
      if (!acc) return { lineNo: i + 1, code, error: `集團科目不存在於本案件：${code}` };
      return { lineNo: i + 1, code, accountId: acc.account_id, debit, credit };
    });
  const bad = parsed.filter((p) => "error" in p) as { lineNo: number; error: string }[];
  if (bad.length) {
    audit(a.tenantId, "CONTROL_VIOLATION_ATTEMPT", "adjustment.save.rejected", a.userId,
      "adjustment", r.adjustment_id, { reason: "明細解析失敗", errors: bad });
    return { ok: false, kind: "LINES_INVALID", errors: bad };
  }
  const good = parsed as { lineNo: number; accountId: string; debit: string; credit: string }[];
  const lineParams: Record<string, string> = {};
  const lineValues = good.map((p, i) => {
    lineParams[`la${i}`] = p.accountId;
    lineParams[`ld${i}`] = p.debit;
    lineParams[`lc${i}`] = p.credit;
    return `(:'t'::uuid, :'a'::uuid, ${i + 1}, :'la${i}'::uuid, :'ld${i}'::numeric, :'lc${i}'::numeric)`;
  }).join(",\n                   ");
  // 表頭與明細必須同進同出：舊版「更新表頭 → 刪明細 → 逐列插入」中途失敗會留下半套草稿。
  //
  // 樂觀鎖必須驗證「本次 UPDATE 真的影響了一列」，不能事後比對版本號：
  // 若另一請求先把 5 改成 6，本請求的 UPDATE 影響 0 列，但事後查到的版本
  // 同樣是 6（＝base+1），會被誤判為成功，接著刪掉並覆蓋對方的明細。
  const ev = auditSql(a.tenantId, "DOMAIN_EVENT", "adjustment.draft_saved", a.userId,
    "adjustment", r.adjustment_id, { object_version: base + 1, lines: good.length });
  try {
    exec(`BEGIN;
          WITH updated AS (
            UPDATE adjustment SET title = :'ti', legal_basis = :'lb', evidence_ref = :'er',
                   judgment_reason = :'jr', language_tag = :'lt',
                   object_version = object_version + 1,
                   edit_session_id = :'es'::uuid, client_save_sequence = ${input.clientSaveSequence},
                   last_save_content_hash = :'ch',
                   last_saved_at = now(), last_saved_by = :'u'::uuid
             WHERE adjustment_id = :'a'::uuid AND object_version = ${base}
            RETURNING 1
          )
          SELECT fn_assert(EXISTS (SELECT 1 FROM updated), 'OPTIMISTIC_LOCK_CONFLICT');
          DELETE FROM adjustment_line WHERE adjustment_id = :'a'::uuid;
          ${lineValues ? `INSERT INTO adjustment_line
            (tenant_id, adjustment_id, line_no, target_account_id, debit, credit)
           VALUES ${lineValues};` : ""}
          ${ev.sql}
          COMMIT;`,
      { t: a.tenantId, a: r.adjustment_id, ti: input.title,
        lb: input.legalBasis, er: input.evidenceRef,
        jr: input.judgmentReason, lt: input.languageTag,
        es: input.editSessionId, u: a.userId, ch: contentHash,
        ...lineParams, ...ev.params },
      { tenantId: a.tenantId });
  } catch (e) {
    if (!String(e).includes("OPTIMISTIC_LOCK_CONFLICT")) throw e;
    // 真併發：預檢時版本還相符，交易內才被別人搶先。整筆回滾，不覆蓋對方。
    audit(a.tenantId, "CONTROL_VIOLATION_ATTEMPT", "adjustment.save.conflict", a.userId,
      "adjustment", r.adjustment_id, { reason: "併發競態：UPDATE 未命中", base_object_version: base });
    return { ok: false, kind: "CONCURRENT_CONFLICT", base };
  }
  return { ok: true };
}

// ── 送覆核（R2；G-08 ＋ 分錄成立性） ─────────────────────────
export function submit(a: Actor, r: AdjRow): AdjustmentOutcome {
  if (!a.roles.has("R2")) { cvaRole(a, r, "adjustment.submit", "R2"); return { ok: false, kind: "ROLE", need: "R2" }; }
  const lines = adjLines(a.tenantId, r.adjustment_id);
  const verdict = canSubmit(stateOf(r, lines));
  if (!verdict.ok) { cvaGuard(a, r, "adjustment.submit", verdict); return { ok: false, kind: "GUARD", verdict }; }
  const bv = r.business_version + 1;
  const snap = snapshotSql(a, r, lines, bv, "PENDING_REVIEW", "SUBMITTED", "R2", null, null);
  const ev = auditSql(a.tenantId, "DOMAIN_EVENT", "adjustment.submitted", a.userId,
    "adjustment", r.adjustment_id, { business_version: bv });
  // 狀態、里程碑快照與 DomainEvent 同一交易：任一失敗都不得留下
  // 「狀態已前進、版本或事件不存在」的資料
  exec(`BEGIN;
        UPDATE adjustment SET status = 'PENDING_REVIEW', business_version = ${bv}
         WHERE adjustment_id = :'a'::uuid;
        ${snap.sql}
        ${ev.sql}
        COMMIT;`, { ...snap.params, ...ev.params }, { tenantId: a.tenantId });
  return { ok: true };
}

// ── 覆核通過（R3；G-04／SOD-01） ─────────────────────────────
export function review(a: Actor, r: AdjRow): AdjustmentOutcome {
  if (!a.roles.has("R3")) { cvaRole(a, r, "adjustment.review", "R3"); return { ok: false, kind: "ROLE", need: "R3" }; }
  const lines = adjLines(a.tenantId, r.adjustment_id);
  const verdict = canReview(stateOf(r, lines), a.userId);
  if (!verdict.ok) {
    // G-04 失敗 → 只能預覽（§25.9 L862）。02A 不產生預覽檔，只記錄資格與理由。
    if (verdict.guard === "G-04／SOD-01") {
      const j = previewOnlyJudgment([verdict.guard, ...verdict.reasons]);
      exec(`UPDATE adjustment SET output_capability = :'oc', control_reasons = :'cr'::jsonb
             WHERE adjustment_id = :'a'::uuid`,
        { a: r.adjustment_id, oc: j.outputCapability, cr: JSON.stringify(j.reasons) },
        { tenantId: a.tenantId });
    }
    cvaGuard(a, r, "adjustment.review", verdict);
    return { ok: false, kind: "GUARD", verdict };
  }
  const bv = r.business_version + 1;
  const snap = snapshotSql(a, r, lines, bv, "PENDING_APPROVAL", "REVIEWED", "R3", null, null);
  // 合法的獨立覆核完成 → 清除先前 G-04 失敗留下的「只能預覽」臨時判定。
  // 違規嘗試永久留在 AuditEvent；輸出資格必須反映目前狀態，正式資格留給 02B 決定。
  const ev = auditSql(a.tenantId, "DOMAIN_EVENT", "adjustment.reviewed", a.userId,
    "adjustment", r.adjustment_id, { business_version: bv, preview_downgrade_cleared: true });
  exec(`BEGIN;
        UPDATE adjustment SET status = 'PENDING_APPROVAL', reviewed_by = :'u'::uuid,
               reviewed_at = now(), business_version = ${bv},
               output_capability = NULL, control_reasons = '[]'::jsonb
         WHERE adjustment_id = :'a'::uuid;
        ${snap.sql}
        ${ev.sql}
        COMMIT;`, { ...snap.params, ...ev.params, u: a.userId }, { tenantId: a.tenantId });
  return { ok: true };
}

// ── 退回至草稿（兩個節點皆可；理由必填） ─────────────────────
export function returnToDraft(a: Actor, r: AdjRow, category: string, note: string): AdjustmentOutcome {
  const need = r.status === "PENDING_REVIEW" ? "R3" : "R4";
  if (!a.roles.has(need)) { cvaRole(a, r, "adjustment.return", need); return { ok: false, kind: "ROLE", need }; }
  const t = legalTransition(r.status, "DRAFTING");
  if (!t.ok) { cvaGuard(a, r, "adjustment.return", t); return { ok: false, kind: "GUARD", verdict: t }; }
  if (!category || !note) {
    const verdict: Refusal = { ok: false, guard: "退回理由",
      reasons: ["退回必須記錄理由分類與說明（§25.12）"] };
    cvaGuard(a, r, "adjustment.return", verdict);
    return { ok: false, kind: "GUARD", verdict };
  }
  const lines = adjLines(a.tenantId, r.adjustment_id);
  const bv = r.business_version + 1;
  // 從 PENDING_APPROVAL 退回：既有覆核失效，修正後須重新覆核（§25.12 L911）
  const clearReview = r.status === "PENDING_APPROVAL";
  const snap = snapshotSql(a, r, lines, bv, "DRAFTING", "RETURNED", need, category, note);
  const ev = auditSql(a.tenantId, "DOMAIN_EVENT", "adjustment.returned", a.userId,
    "adjustment", r.adjustment_id,
    { from: r.status, business_version: bv, reason_category: category,
      review_invalidated: clearReview });
  exec(`BEGIN;
        UPDATE adjustment SET status = 'DRAFTING', business_version = ${bv}
               ${clearReview ? ", reviewed_by = NULL, reviewed_at = NULL" : ""}
         WHERE adjustment_id = :'a'::uuid;
        ${snap.sql}
        ${ev.sql}
        COMMIT;`, { ...snap.params, ...ev.params }, { tenantId: a.tenantId });
  return { ok: true };
}

// ── 批准（R4；G-08 複查 ＋ G-05／SOD-02 ＋ AC-WFL-001）＋ 同交易物化 ──
export function approve(a: Actor, r: AdjRow): AdjustmentOutcome {
  if (!a.roles.has("R4")) { cvaRole(a, r, "adjustment.approve", "R4"); return { ok: false, kind: "ROLE", need: "R4" }; }
  const lines = adjLines(a.tenantId, r.adjustment_id);
  const verdict = canApprove(stateOf(r, lines), a.userId);
  if (!verdict.ok) { cvaGuard(a, r, "adjustment.approve", verdict); return { ok: false, kind: "GUARD", verdict }; }
  const bv = r.business_version + 1;
  // 批准與物化必須在同一交易：批准失敗不得留下殘留分錄（切片驗收 11）。
  // psql 單次呼叫＋BEGIN/COMMIT＝單一交易；ON_ERROR_STOP=1 使中途失敗整批回滾。
  const entryId = randomUUID();
  const values = lines.map((l, i) =>
    `('${a.tenantId}'::uuid, '${entryId}'::uuid, ${i + 1}, '${l.target_account_id}'::uuid,` +
    ` ${decimalOf(cents(l.debit))}, ${decimalOf(cents(l.credit))})`).join(",\n               ");
  const snap = snapshotSql(a, r, lines, bv, "APPROVED", "APPROVED", "R4", null, null);
  const evA = auditSql(a.tenantId, "DOMAIN_EVENT", "adjustment.approved", a.userId,
    "adjustment", r.adjustment_id, { business_version: bv }, "ea");
  const evM = auditSql(a.tenantId, "DOMAIN_EVENT", "journal.materialized", a.userId,
    "adjustment", r.adjustment_id, { entry_id: entryId, lines: lines.length }, "em");
  exec(`BEGIN;
        UPDATE adjustment SET status = 'APPROVED', approved_by = :'u'::uuid,
               approved_at = now(), business_version = ${bv}
         WHERE adjustment_id = :'a'::uuid;
        -- 分層自 Adjustment 帶入（不重新決定；DB 守衛要求兩者一致）。
        -- 不帶 basis_id：一筆事實屬於某個層，「哪些基礎包含它」由組成模型回答。
        INSERT INTO journal_entry (entry_id, tenant_id, engagement_id, period_revision_id,
                adjustment_id, business_version, entry_date, posting_layer_id)
        VALUES ('${entryId}'::uuid, :'t'::uuid, :'e'::uuid, :'pr'::uuid,
                :'a'::uuid, ${bv}, :'ed'::date,
                (SELECT posting_layer_id FROM adjustment WHERE adjustment_id = :'a'::uuid));
        INSERT INTO journal_line (tenant_id, entry_id, line_no, account_id, debit, credit)
        VALUES ${values};
        ${snap.sql}
        ${evA.sql}
        ${evM.sql}
        COMMIT;`,
    { ...snap.params, ...evA.params, ...evM.params, u: a.userId, e: r.engagement_id,
      pr: r.period_revision_id, ed: r.period_end }, { tenantId: a.tenantId });
  return { ok: true };
}
