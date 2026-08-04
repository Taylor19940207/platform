// 科目映射（SLICE-M2-01；設計書 §26.8 MappingRule 最小版、守衛 G-02）。
// 與 migrations/0005 的觸發器同語意：應用層先判定，DB 是最後防線。
// 金額一律以「分」為單位的 bigint 運算——絕不用浮點加總。

export interface TbAccountLine {
  accountCode: string;
  accountName: string;
  debitCents: bigint;
  creditCents: bigint;
}

export interface CurrentMapping {
  sourceAccountCode: string;
  targetAccountId: string;
  targetCode: string;
  targetName: string;
  versionNo: number;
}

export interface GroupTbRow {
  targetAccountId: string;
  targetCode: string;
  targetName: string;
  debitCents: bigint;
  creditCents: bigint;
  sourceCodes: string[];
}

export const cents = (s: string | number): bigint =>
  BigInt(Math.round(Number(s || 0) * 100));

export const fmtCents = (c: bigint): string =>
  (Number(c) / 100).toLocaleString("en-US");

/** 套用目前生效映射：多對一加總；未映射科目另列（不得靜默吸收）。 */
export function applyMappings(lines: TbAccountLine[], mappings: CurrentMapping[]):
    { rows: GroupTbRow[]; unmapped: TbAccountLine[] } {
  const bySource = new Map(mappings.map((m) => [m.sourceAccountCode, m]));
  const byTarget = new Map<string, GroupTbRow>();
  const unmapped: TbAccountLine[] = [];
  for (const l of lines) {
    const m = bySource.get(l.accountCode);
    if (!m) { unmapped.push(l); continue; }
    const r = byTarget.get(m.targetAccountId) ?? {
      targetAccountId: m.targetAccountId, targetCode: m.targetCode,
      targetName: m.targetName, debitCents: 0n, creditCents: 0n, sourceCodes: [],
    };
    r.debitCents += l.debitCents;
    r.creditCents += l.creditCents;
    r.sourceCodes.push(l.accountCode);
    byTarget.set(m.targetAccountId, r);
  }
  const rows = [...byTarget.values()].sort((a, b) => a.targetCode.localeCompare(b.targetCode));
  return { rows, unmapped };
}

export interface Coverage {
  totalCents: bigint;      // 全部來源餘額（借＋貸）
  mappedCents: bigint;
  unmappedCents: bigint;   // 未映射影響金額（借＋貸）
  ratio: number;           // 按金額的覆蓋率 0～1
  unmappedAccounts: string[];
}

export function coverage(lines: TbAccountLine[], mappings: CurrentMapping[]): Coverage {
  const { unmapped } = applyMappings(lines, mappings);
  const total = lines.reduce((a, l) => a + l.debitCents + l.creditCents, 0n);
  const un = unmapped.reduce((a, l) => a + l.debitCents + l.creditCents, 0n);
  return {
    totalCents: total, mappedCents: total - un, unmappedCents: un,
    ratio: total === 0n ? 1 : Number(((total - un) * 10000n) / total) / 10000,
    unmappedAccounts: unmapped.map((u) => u.accountCode),
  };
}

/**
 * G-02（§25.13）：重要來源餘額均已映射或有批准例外。
 * 本切片尚無例外批准機制——任何未映射餘額即阻擋（例外路徑見 BACKLOG）。
 */
export function g02Check(cov: Coverage):
    { ok: true } | { ok: false; guard: "G-02"; reasons: string[] } {
  if (cov.unmappedAccounts.length === 0) return { ok: true };
  return {
    ok: false, guard: "G-02",
    reasons: [
      `未映射科目 ${cov.unmappedAccounts.length} 個（${cov.unmappedAccounts.join("、")}）`,
      `影響金額（借＋貸）${fmtCents(cov.unmappedCents)}`,
    ],
  };
}

export function totalsOf(lines: { debitCents: bigint; creditCents: bigint }[]):
    { debitCents: bigint; creditCents: bigint } {
  return {
    debitCents: lines.reduce((a, l) => a + l.debitCents, 0n),
    creditCents: lines.reduce((a, l) => a + l.creditCents, 0n),
  };
}
