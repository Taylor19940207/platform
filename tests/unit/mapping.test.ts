import { test } from "node:test";
import assert from "node:assert/strict";
import { applyMappings, coverage, g02Check, totalsOf, cents, fmtCents,
  type TbAccountLine, type CurrentMapping } from "../../packages/domain/src/mapping.ts";

const L = (code: string, d: number, c: number): TbAccountLine =>
  ({ accountCode: code, accountName: code, debitCents: cents(d), creditCents: cents(c) });
const M = (src: string, tgt: string): CurrentMapping =>
  ({ sourceAccountCode: src, targetAccountId: `id-${tgt}`, targetCode: tgt, targetName: tgt, versionNo: 1 });

const lines = [L("111", 8_200_000, 0), L("112", 1_450_000, 0), L("500", 0, 9_650_000)];
const maps = [M("111", "1002"), M("112", "1002"), M("500", "6001")];

test("多對一映射正確加總（111＋112 → 1002）", () => {
  const { rows, unmapped } = applyMappings(lines, maps);
  assert.equal(unmapped.length, 0);
  const bank = rows.find((r) => r.targetCode === "1002")!;
  assert.equal(bank.debitCents, cents(9_650_000));
  assert.deepEqual(bank.sourceCodes.sort(), ["111", "112"]);
});

test("未映射科目逐一列出且含影響金額", () => {
  const { unmapped } = applyMappings(lines, [M("111", "1002")]);
  assert.deepEqual(unmapped.map((u) => u.accountCode).sort(), ["112", "500"]);
  const cov = coverage(lines, [M("111", "1002")]);
  assert.equal(cov.unmappedCents, cents(1_450_000) + cents(9_650_000));
});

test("覆蓋率按金額計算：無映射 0、全映射 1", () => {
  assert.equal(coverage(lines, []).ratio, 0);
  assert.equal(coverage(lines, maps).ratio, 1);
  assert.equal(coverage([], []).ratio, 1);   // 空 TB 視為已覆蓋
});

test("G-02：有未映射餘額即阻擋並指出科目與金額；全映射放行", () => {
  const blocked = g02Check(coverage(lines, [M("111", "1002")]));
  assert.equal(blocked.ok, false);
  if (!blocked.ok) {
    assert.equal(blocked.guard, "G-02");
    assert.ok(blocked.reasons.some((r) => r.includes("112") && r.includes("500")));
  }
  assert.equal(g02Check(coverage(lines, maps)).ok, true);
});

test("控制總額勾稽：映射後＋未映射 ＝ 來源總額", () => {
  const partial = [M("111", "1002")];
  const { rows, unmapped } = applyMappings(lines, partial);
  const src = totalsOf(lines);
  const grp = totalsOf(rows);
  const un = totalsOf(unmapped);
  assert.equal(grp.debitCents + un.debitCents, src.debitCents);
  assert.equal(grp.creditCents + un.creditCents, src.creditCents);
});

test("大額精確：numeric(20,2) 上限位數不經 Number、無精度損失", () => {
  // 18 位整數＋2 位小數超出 IEEE-754 53-bit：Number 路徑會失真，字串路徑必須精確
  assert.equal(cents("123456789012345678.99"), 12345678901234567899n);
  assert.equal(cents("-123456789012345678.99"), -12345678901234567899n);
  assert.equal(fmtCents(12345678901234567899n), "123,456,789,012,345,678.99");
  assert.equal(fmtCents(-12345678901234567899n), "-123,456,789,012,345,678.99");
  assert.equal(cents("100.5"), 10050n);      // 一位小數補零
  assert.equal(cents("0"), 0n);
  assert.equal(fmtCents(10000n), "100");     // 小數為零時省略
  assert.throws(() => cents("1,000"));       // 非純十進位一律拒絕，不靜默解析
});

test("借貸平衡的來源全數映射後，集團 TB 借貸仍平衡", () => {
  const { rows } = applyMappings(lines, maps);
  const t = totalsOf(rows);
  assert.equal(t.debitCents, t.creditCents);
});
