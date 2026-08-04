// Adjustment 生命週期（SLICE-M2-02A；設計書 §25.12／§25.13、手冊 §849 AC-WFL-001）。
// 與 migrations/0007 的觸發器同語意：應用層先判定並記錄 ControlViolationAttempt，
// DB 是最後防線。金額一律以「分」為單位的 bigint 運算——絕不用浮點。
import { cents, fmtCents } from "./mapping.ts";

export type AdjustmentStatus =
  "DRAFTING" | "PENDING_REVIEW" | "PENDING_APPROVAL" | "APPROVED";

export type Milestone = "SUBMITTED" | "RETURNED" | "REVIEWED" | "APPROVED";

export type GuardResult =
  | { ok: true }
  | { ok: false; guard: string; reasons: string[] };

/** 合法遷移表（§25.12）。跳關一律拒絕；退回只回 DRAFTING。 */
const LEGAL: Record<AdjustmentStatus, AdjustmentStatus[]> = {
  DRAFTING: ["PENDING_REVIEW"],
  PENDING_REVIEW: ["PENDING_APPROVAL", "DRAFTING"],
  PENDING_APPROVAL: ["APPROVED", "DRAFTING"],
  APPROVED: [],
};

export function legalTransition(from: AdjustmentStatus, to: AdjustmentStatus): GuardResult {
  if (LEGAL[from].includes(to)) return { ok: true };
  return {
    ok: false, guard: "狀態遷移",
    reasons: [`非法狀態遷移 ${from} → ${to}（不得跳關）`],
  };
}

// ── G-08：必要證據齊備（§25.13 L930；AC-EVD-001） ──────────────
export interface Evidence {
  legalBasis: string | null;      // 法源／政策依據
  evidenceRef: string | null;     // 附件／支持文件
  judgmentReason: string | null;  // 判斷理由
  languageTag: string | null;     // 語言標籤
}

const G08_FIELDS: [keyof Evidence, string][] = [
  ["legalBasis", "法源／政策依據"],
  ["evidenceRef", "附件／支持文件"],
  ["judgmentReason", "判斷理由"],
  ["languageTag", "語言標籤"],
];

/**
 * 四項缺一不可。本切片不實作「批准例外」路徑（基線允許取得例外後達
 * OFFICIAL＋WITH_CONTROL_EXCEPTION），任何缺漏一律硬擋。
 */
export function g08Check(e: Evidence): GuardResult {
  const missing = G08_FIELDS
    .filter(([k]) => String(e[k] ?? "").trim() === "")
    .map(([, label]) => label);
  if (missing.length === 0) return { ok: true };
  return {
    ok: false, guard: "G-08",
    reasons: [`必要證據未齊，缺少：${missing.join("、")}`],
  };
}

// ── 分錄成立性：至少兩列且借貸平衡 ────────────────────────────
export interface AdjLine { debitCents: bigint; creditCents: bigint }

export function imbalanceCents(lines: AdjLine[]): bigint {
  return lines.reduce((a, l) => a + l.debitCents - l.creditCents, 0n);
}

export function balanceCheck(lines: AdjLine[]): GuardResult {
  if (lines.length < 2) {
    return { ok: false, guard: "分錄成立性", reasons: ["調整分錄至少需兩列"] };
  }
  const diff = imbalanceCents(lines);
  if (diff === 0n) return { ok: true };
  return {
    ok: false, guard: "G-01",
    reasons: [`借貸不平衡：差額 ${fmtCents(diff)}`],
  };
}

// ── 三條職責分離控制：掛在三個不同的狀態遷移，不得合併 ──────────

/** G-04／SOD-01：編製人不得覆核自己編製的調整。無豁免（設計書 L926）。 */
export function sod01Check(preparedBy: string, reviewedBy: string | null): GuardResult {
  if (!reviewedBy) {
    return { ok: false, guard: "G-04／SOD-01", reasons: ["覆核必須記錄覆核人"] };
  }
  if (preparedBy === reviewedBy) {
    return {
      ok: false, guard: "G-04／SOD-01",
      reasons: ["編製人不得覆核自己編製的調整（自然人判定，角色切換無效）"],
    };
  }
  return { ok: true };
}

/** G-05／SOD-02：重大調整的覆核人不得兼批准人（設計書 L927）。 */
export function sod02Check(reviewedBy: string | null, approvedBy: string): GuardResult {
  if (!reviewedBy) {
    return { ok: false, guard: "G-05／SOD-02", reasons: ["批准前必須完成覆核"] };
  }
  if (reviewedBy === approvedBy) {
    return {
      ok: false, guard: "G-05／SOD-02",
      reasons: ["重大調整的覆核人不得兼任批准人"],
    };
  }
  return { ok: true };
}

/**
 * AC-WFL-001（手冊 §849）：編製人不得批准自己的重大調整。
 *
 * 這條**推導不出來**——SOD-01（prepared ≠ reviewed）與 SOD-02（reviewed ≠ approved）
 * 同時成立時仍允許「甲編製 → 乙覆核 → 甲批准」。依 GOVERNANCE 權威順序
 * （手冊 v1.2 > 設計書 v1.1）獨立落實，不併入也不擴充 SOD-02 的定義。
 */
export function acWfl001Check(preparedBy: string, approvedBy: string): GuardResult {
  if (preparedBy === approvedBy) {
    return {
      ok: false, guard: "AC-WFL-001",
      reasons: ["編製人不得批准自己編製的重大調整，與當下角色無關"],
    };
  }
  return { ok: true };
}

// ── 組合判定：各遷移一次跑完該關卡的所有守衛 ──────────────────

export interface AdjustmentState {
  status: AdjustmentStatus;
  preparedBy: string;
  reviewedBy: string | null;
  evidence: Evidence;
  lines: AdjLine[];
}

/** DRAFTING → PENDING_REVIEW：G-08 ＋ 分錄成立性。 */
export function canSubmit(a: AdjustmentState): GuardResult {
  const t = legalTransition(a.status, "PENDING_REVIEW");
  if (!t.ok) return t;
  const g08 = g08Check(a.evidence);
  if (!g08.ok) return g08;
  return balanceCheck(a.lines);
}

/** PENDING_REVIEW → PENDING_APPROVAL：G-04／SOD-01。 */
export function canReview(a: AdjustmentState, reviewerId: string): GuardResult {
  const t = legalTransition(a.status, "PENDING_APPROVAL");
  if (!t.ok) return t;
  return sod01Check(a.preparedBy, reviewerId);
}

/** PENDING_APPROVAL → APPROVED：G-08 複查 ＋ G-05／SOD-02 ＋ AC-WFL-001。 */
export function canApprove(a: AdjustmentState, approverId: string): GuardResult {
  const t = legalTransition(a.status, "APPROVED");
  if (!t.ok) return t;
  const g08 = g08Check(a.evidence);
  if (!g08.ok) return g08;
  const sod02 = sod02Check(a.reviewedBy, approverId);
  if (!sod02.ok) return sod02;
  return acWfl001Check(a.preparedBy, approverId);
}

// ── 控制判定（§25.9） ─────────────────────────────────────────
export interface ControlJudgment {
  outputCapability: "NONE" | "PREVIEW" | "OFFICIAL";
  reasons: string[];
}

/**
 * G-04 失敗或找不到合格獨立覆核人 → 只能預覽（設計書 L862：G-04 設定 PREVIEW）。
 *
 * 02A 不寫 delivery_quality：該欄屬不可變的 DeliveryRecord，而本切片尚未建立
 * CalculationRun、輸出或 DeliveryRecord。INV-27 於 02B 真正產生輸出時才套用。
 * 也不寫 official_eligible：基線無此欄位，且可由 outputCapability 完全推導。
 */
export function previewOnlyJudgment(reasons: string[]): ControlJudgment {
  return { outputCapability: "PREVIEW", reasons };
}

/**
 * 分（bigint）→ numeric(20,2) 字面值。純字串運算，不經 JavaScript Number——
 * 整數位可達 18 位，超出 IEEE-754 的 53-bit 精度會靜默失真（8f0507f 的同一課）。
 * 與 fmtCents 不同：此處不加千分位，輸出必須是 SQL 可直接接受的字面值。
 */
export const decimalOf = (c: bigint): string => {
  const neg = c < 0n;
  const abs = neg ? -c : c;
  return `${neg ? "-" : ""}${abs / 100n}.${(abs % 100n).toString().padStart(2, "0")}`;
};

/** 物化用：把調整明細轉為正式分錄列（僅在 APPROVED 後呼叫）。 */
export function materializeLines(lines: (AdjLine & { targetAccountId: string })[]):
    { lineNo: number; accountId: string; debit: string; credit: string }[] {
  return lines.map((l, i) => ({
    lineNo: i + 1,
    accountId: l.targetAccountId,
    debit: decimalOf(l.debitCents),
    credit: decimalOf(l.creditCents),
  }));
}

export { cents, fmtCents };
