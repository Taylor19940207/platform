// ImportBatch 狀態機（設計書 §25.5）。
// 與 packages/database/migrations/0003 的 fn_import_batch_guard 同語意：
// 應用層先判定（並記錄 ControlViolationAttempt），DB trigger 是最後防線。

export type ImportBatchStatus =
  | "DRAFT" | "UPLOADED" | "VALIDATING" | "QUARANTINED"
  | "VALIDATED" | "ACCEPTED" | "SUPERSEDED";

export type IdentityStatus =
  | "NOT_CHECKED" | "MATCHED" | "PENDING_CONFIRMATION"
  | "MANUALLY_RESOLVED" | "CONFLICT";

const TRANSITIONS: Record<ImportBatchStatus, ImportBatchStatus[]> = {
  DRAFT:       ["UPLOADED"],
  UPLOADED:    ["VALIDATING"],
  VALIDATING:  ["QUARANTINED", "VALIDATED"],
  VALIDATED:   ["ACCEPTED", "QUARANTINED"],
  ACCEPTED:    ["SUPERSEDED"],
  QUARANTINED: [],          // 終態：重傳＝新批次（version+1），本批次保留
  SUPERSEDED:  [],          // 終態：INV-08 要求 superseded_by_id
};

export function canTransition(from: ImportBatchStatus, to: ImportBatchStatus): boolean {
  return TRANSITIONS[from].includes(to);
}

export interface AcceptancePredicateInput {
  status: ImportBatchStatus;
  identityStatus: IdentityStatus;
  hashVerified: boolean;
}

/** G-01 接受判定式（§25.13）＝ INV-28 的執行路徑。三條件缺一不可。 */
export function acceptancePredicate(b: AcceptancePredicateInput):
  { ok: true } | { ok: false; guard: "G-01/INV-28"; reasons: string[] } {
  const reasons: string[] = [];
  if (b.status !== "VALIDATED") reasons.push(`status=${b.status}（須為 VALIDATED）`);
  if (b.identityStatus !== "MATCHED" && b.identityStatus !== "MANUALLY_RESOLVED")
    reasons.push(`identity_status=${b.identityStatus}（須為 MATCHED 或 MANUALLY_RESOLVED）`);
  if (!b.hashVerified) reasons.push("完整雜湊驗證未通過");
  return reasons.length === 0 ? { ok: true } : { ok: false, guard: "G-01/INV-28", reasons };
}

/** 證據強度分級（CR-002 主題四）：僅權威識別符可產生 CONFLICT。 */
export type EvidenceKind = "AUTHORITATIVE_ID" | "APPROVED_ALIAS" | "FUZZY_NAME" | "NONE";
export type MatchResult = "MATCH" | "CONFLICT" | "UNVERIFIABLE";

export function classifyIdentity(declared: string | null, detected: string | null,
                                 evidence: EvidenceKind): MatchResult {
  if (evidence === "AUTHORITATIVE_ID" && declared && detected)
    return declared === detected ? "MATCH" : "CONFLICT";
  if (evidence === "APPROVED_ALIAS" && declared && detected && declared === detected)
    return "MATCH";
  return "UNVERIFIABLE";   // 模糊名稱：不升 MATCH、不降 CONFLICT
}

export function identityStatusOf(r: MatchResult): IdentityStatus {
  return r === "MATCH" ? "MATCHED"
       : r === "CONFLICT" ? "CONFLICT"
       : "PENDING_CONFIRMATION";
}
