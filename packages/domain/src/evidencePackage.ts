// 預覽證據包（SLICE-M2-02C；手冊 AC-AUD-001、設計書 §26.9）。
// 與 migrations/0015 的觸發器同語意：應用層先判定，DB 是最後防線。

export type EvidencePackageStatus = "GENERATING" | "READY" | "FAILED";

/** 底稿渲染版本：入 Package 與 object key——render 升版＝明示重產的正當理由。 */
export const RENDER_VERSION = "html-3";
// html-2（0017）：canonical JSON、追溯完整度欄、人名凍結快照。
// html-3（0018）：來源節完全讀 Manifest（SOURCE_TB payload 凍結 batch meta）、
// actor 顯示「姓名〔穩定 ID〕」——輸出內容改變＝render 升版；worker 依版本分流，
// 未支援版本 fail closed（不得以新版內容冒充舊版登記）。

const LEGAL: Record<EvidencePackageStatus, EvidencePackageStatus[]> = {
  GENERATING: ["READY", "FAILED"],
  READY: [],            // 終態：重產＝新 package（regenerated_from_id），原包永久保留
  FAILED: [],
};

export function legalPackageTransition(from: EvidencePackageStatus, to: EvidencePackageStatus): boolean {
  return LEGAL[from].includes(to);
}

export const PKG_REASON = {
  RUN_NOT_COMPLETED: "只有 COMPLETED 的 PREVIEW run 可產生證據包",
  ROLE_REQUIRED: "產生／下載預覽證據包需 R2、R3 或 R4 角色（§24.6 權限矩陣）",
  REQUEST_KEY_REUSED: "相同 request key 但請求內容不同——冪等鍵不得重用於不同請求",
  PACKAGE_NOT_READY: "Package 尚未 READY，不可下載（GENERATING／FAILED）",
  ARTIFACT_HASH_MISMATCH: "已保存 artifact 與登記雜湊不符——內容完整性失敗，不得提供下載",
  ARTIFACT_CONFLICT: "staging 物件已存在且內容不符——確定性完整性失敗（契約 B）",
  UPSTREAM_VERIFY_FAILED: "產包前驗證失敗：上游凍結資料損壞或不一致（契約 D），不得包裝為證據",
  CUTOFF_EVENT_MISSING: "找不到該 run 的 calculation_run.completed 事件（audit cutoff）",
  CONTROL_TOTAL_MISMATCH: "控制總額勾稽不一致（G-09）",
  UNSUPPORTED_RENDER_VERSION: "worker 不支援此 render 版本——不得以其他版本內容冒充登記；請明示重產（新 package＋現行版本）",
  INFRA_RETRY_EXHAUSTED: "基礎設施故障重試耗盡；可明示重新產包（新 package）",
  NON_RETRYABLE_SYSTEM: "系統性錯誤；請通報維運後明示重新產包（新 package）",
} as const;

export type PkgReasonCode = keyof typeof PKG_REASON;

export function pkgReasonCodeOf(message: string): PkgReasonCode | null {
  for (const code of Object.keys(PKG_REASON) as PkgReasonCode[])
    if (message.includes(code)) return code;
  return null;
}

/** 契約 D／B 的確定性失敗：結論不重試（Package FAILED＋Job COMPLETED）。 */
export function isDeterministicPkgFailure(message: string): boolean {
  const code = pkgReasonCodeOf(message);
  return code === "UPSTREAM_VERIFY_FAILED" || code === "ARTIFACT_CONFLICT"
      || code === "CUTOFF_EVENT_MISSING" || code === "CONTROL_TOTAL_MISMATCH"
      || code === "UNSUPPORTED_RENDER_VERSION";
}

/** 契約 B：staging 物件已存在時的裁決。 */
export function stagingVerdict(existingSha256: string, wantSha256: string): "REUSE" | "CONFLICT" {
  return existingSha256 === wantSha256 ? "REUSE" : "CONFLICT";
}

/** 契約 B：object key 由 package_id＋render_version 確定性產生。 */
export function artifactObjectKey(tenantId: string, packageId: string, renderVersion: string): string {
  return `${tenantId}/evidence/${packageId}/${renderVersion}.html`;
}

/** 固定章節集合：READY 守衛（0016）與 worker 共用同一份清單。 */
export const PACKAGE_SECTIONS = [
  "source", "mapping", "adjustment", "calculation", "rule_versions",
  "process_level", "control_exceptions", "traceability", "events", "attachments",
] as const;

// ── 逐科目範圍追溯（AC-AUD-001）：依實際 lineage 解析，不得把單一 coverage 套全部 ──

export type Granularity = "BALANCE" | "JOURNAL" | "SUBLEDGER" | "DOCUMENT";
const GRAN_ORDER: Record<Granularity, number> = { BALANCE: 0, JOURNAL: 1, SUBLEDGER: 2, DOCUMENT: 3 };

export type Completeness = "COMPLETE" | "PARTIAL" | "UNKNOWN";
const COMP_ORDER: Record<Completeness, number> = { UNKNOWN: 0, PARTIAL: 1, COMPLETE: 2 };

export interface CoverageRow {
  id: string; accountScope: string; granularity: Granularity; completeness: Completeness;
}
export interface TraceInput { outputCode: string; sourceCodes: string[] }
export interface TraceResult {
  outputCode: string; coverageIds: string[];
  level: Granularity | "UNKNOWN"; completeness: Completeness;
}

/**
 * 輸出科目 → 來源科目（映射 lineage）→ coverage → 等級。
 * scope 語意（本刀）：`*`＝全部；否則為單一來源科目代碼的精確匹配，**精確優先於 wildcard**。
 * 等級＝各來源「可用最高等級」中的**最低**——輸出範圍不得宣稱高於任一來源的實際涵蓋
 * （AC-AUD-001／INV-23 精神：弱鏈決定等級）。
 * 無 TB 來源（純調整科目）或來源無 coverage → `UNKNOWN`（誠實標示，不猜測）。
 */
export function resolveTraceability(outputs: TraceInput[], coverages: CoverageRow[]): TraceResult[] {
  return outputs.map((o) => {
    if (o.sourceCodes.length === 0)
      return { outputCode: o.outputCode, coverageIds: [], level: "UNKNOWN", completeness: "UNKNOWN" };
    const perSource = o.sourceCodes.map((src) => {
      const specific = coverages.filter((c) => c.accountScope === src);
      return specific.length ? specific : coverages.filter((c) => c.accountScope === "*");
    });
    if (perSource.some((f) => f.length === 0))
      return { outputCode: o.outputCode, coverageIds: [], level: "UNKNOWN", completeness: "UNKNOWN" };
    const involved = perSource.flat();
    const ids = [...new Set(involved.map((c) => c.id))].sort();
    // 完整度＝所有涉及 coverage 的最弱值；UNKNOWN 完整度不得宣稱任何等級（降 UNKNOWN），
    // PARTIAL 保留等級但必須併列呈現（0017 P2 規則）
    const compNum = Math.min(...involved.map((c) => COMP_ORDER[c.completeness]));
    const completeness = (Object.keys(COMP_ORDER) as Completeness[])
      .find((x) => COMP_ORDER[x] === compNum)!;
    if (completeness === "UNKNOWN")
      return { outputCode: o.outputCode, coverageIds: ids, level: "UNKNOWN", completeness };
    const levelNum = Math.min(...perSource.map((f) => Math.max(...f.map((c) => GRAN_ORDER[c.granularity]))));
    const level = (Object.keys(GRAN_ORDER) as Granularity[])
      .find((g) => GRAN_ORDER[g] === levelNum)!;
    return { outputCode: o.outputCode, coverageIds: ids, level, completeness };
  });
}

/**
 * 逐節 canonical＝canonical JSON（0017 P1-③）：JSON escaping 消除分隔符注入——
 * ["a|b","c"] 與 ["a","b|c"] 必得不同 canonical。HTML 由同一份 rows 渲染。
 */
export function sectionCanonical(headers: string[], rows: string[][]): string {
  return JSON.stringify([headers, ...rows]);
}
