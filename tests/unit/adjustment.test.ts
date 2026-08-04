import { test } from "node:test";
import assert from "node:assert/strict";
import { legalTransition, g08Check, balanceCheck, sod01Check, sod02Check, acWfl001Check,
  canSubmit, canReview, canApprove, previewOnlyJudgment, decimalOf, imbalanceCents,
  type AdjustmentState } from "../../packages/domain/src/adjustment.ts";

const A = "user-jia", B = "user-yi", C = "user-bing";

const fullEvidence = {
  legalBasis: "企業会計基準第29号", evidenceRef: "attach-001.pdf",
  judgmentReason: "集團政策要求以 CAS 認列", languageTag: "ja-JP",
};
const balanced = [{ debitCents: 12345n, creditCents: 0n }, { debitCents: 0n, creditCents: 12345n }];

const state = (o: Partial<AdjustmentState> = {}): AdjustmentState => ({
  status: "DRAFTING", preparedBy: A, reviewedBy: null,
  evidence: fullEvidence, lines: balanced, ...o,
});

test("§25.12 合法遷移鏈：三段式與兩個退回節點", () => {
  assert.ok(legalTransition("DRAFTING", "PENDING_REVIEW").ok);
  assert.ok(legalTransition("PENDING_REVIEW", "PENDING_APPROVAL").ok);
  assert.ok(legalTransition("PENDING_APPROVAL", "APPROVED").ok);
  assert.ok(legalTransition("PENDING_REVIEW", "DRAFTING").ok);
  assert.ok(legalTransition("PENDING_APPROVAL", "DRAFTING").ok);
});

test("§25.12 不得跳關；APPROVED 為終態", () => {
  assert.equal(legalTransition("DRAFTING", "PENDING_APPROVAL").ok, false);
  assert.equal(legalTransition("DRAFTING", "APPROVED").ok, false);
  assert.equal(legalTransition("PENDING_REVIEW", "APPROVED").ok, false);
  assert.equal(legalTransition("APPROVED", "DRAFTING").ok, false);
  assert.equal(legalTransition("APPROVED", "PENDING_REVIEW").ok, false);
});

test("G-08 四項缺一不可，且逐項列出缺漏", () => {
  assert.ok(g08Check(fullEvidence).ok);
  for (const [k, label] of [["legalBasis", "法源／政策依據"], ["evidenceRef", "附件／支持文件"],
                            ["judgmentReason", "判斷理由"], ["languageTag", "語言標籤"]] as const) {
    const r = g08Check({ ...fullEvidence, [k]: null });
    assert.equal(r.ok, false);
    assert.equal(r.ok === false && r.guard, "G-08");
    assert.ok(r.ok === false && r.reasons[0].includes(label), `應列出缺漏：${label}`);
  }
});

test("G-08：空白字串等同缺漏（不得以空白繞過）", () => {
  assert.equal(g08Check({ ...fullEvidence, languageTag: "" }).ok, false);
  assert.equal(g08Check({ ...fullEvidence, languageTag: "   " }).ok, false);
});

test("分錄成立性：至少兩列且借貸平衡", () => {
  assert.ok(balanceCheck(balanced).ok);
  assert.equal(balanceCheck([{ debitCents: 100n, creditCents: 100n }]).ok, false);   // 單列
  assert.equal(balanceCheck([{ debitCents: 100n, creditCents: 0n },
                             { debitCents: 0n, creditCents: 99n }]).ok, false);      // 不平衡
});

test("借貸差額以 bigint 精確計算（numeric(20,2) 邊界）", () => {
  const big = [{ debitCents: 12345678901234567899n, creditCents: 0n },
               { debitCents: 0n, creditCents: 12345678901234567899n }];
  assert.equal(imbalanceCents(big), 0n);
  assert.ok(balanceCheck(big).ok);
  // 差 1 分也必須被抓到——浮點加總會把這個差額吃掉
  const off = [{ debitCents: 12345678901234567899n, creditCents: 0n },
               { debitCents: 0n, creditCents: 12345678901234567898n }];
  assert.equal(imbalanceCents(off), 1n);
  assert.equal(balanceCheck(off).ok, false);
});

test("decimalOf：純字串轉換，不經 Number", () => {
  assert.equal(decimalOf(0n), "0.00");
  assert.equal(decimalOf(5n), "0.05");
  assert.equal(decimalOf(12345n), "123.45");
  assert.equal(decimalOf(-12345n), "-123.45");
  // 18 位整數位：超出 IEEE-754 53-bit，經 Number 會失真
  assert.equal(decimalOf(12345678901234567899n), "123456789012345678.99");
});

test("G-04／SOD-01：編製人不得覆核自己，無豁免", () => {
  assert.ok(sod01Check(A, B).ok);
  assert.equal(sod01Check(A, A).ok, false);
  assert.equal(sod01Check(A, null).ok, false);          // 覆核人未記錄
});

test("G-05／SOD-02：覆核人不得兼批准人", () => {
  assert.ok(sod02Check(B, C).ok);
  assert.equal(sod02Check(B, B).ok, false);
  assert.equal(sod02Check(null, C).ok, false);          // 未覆核不得批准
});

test("AC-WFL-001：編製人不得批准自己的重大調整", () => {
  assert.ok(acWfl001Check(A, C).ok);
  assert.equal(acWfl001Check(A, A).ok, false);
});

test("AC-WFL-001 推導不出來：甲編製→乙覆核→甲批准 同時滿足 SOD-01 與 SOD-02", () => {
  // 這正是漏掉 AC-WFL-001 時會放行的路徑
  assert.ok(sod01Check(A, B).ok, "SOD-01 成立（甲 ≠ 乙）");
  assert.ok(sod02Check(B, A).ok, "SOD-02 成立（乙 ≠ 甲）");
  assert.equal(acWfl001Check(A, A).ok, false, "AC-WFL-001 必須獨立擋下");
  const r = canApprove(state({ status: "PENDING_APPROVAL", preparedBy: A, reviewedBy: B }), A);
  assert.equal(r.ok, false);
  assert.equal(r.ok === false && r.guard, "AC-WFL-001");
});

test("canSubmit：狀態 → G-08 → 分錄成立性，逐關把守", () => {
  assert.ok(canSubmit(state()).ok);
  assert.equal(canSubmit(state({ status: "PENDING_REVIEW" })).ok, false);
  const noEvidence = canSubmit(state({ evidence: { ...fullEvidence, evidenceRef: null } }));
  assert.equal(noEvidence.ok === false && noEvidence.guard, "G-08");
  const unbalanced = canSubmit(state({ lines: [{ debitCents: 1n, creditCents: 0n },
                                               { debitCents: 0n, creditCents: 2n }] }));
  assert.equal(unbalanced.ok === false && unbalanced.guard, "G-01");
});

test("canReview：只從 PENDING_REVIEW 出發，且擋自我覆核", () => {
  assert.ok(canReview(state({ status: "PENDING_REVIEW" }), B).ok);
  const self = canReview(state({ status: "PENDING_REVIEW" }), A);
  assert.equal(self.ok === false && self.guard, "G-04／SOD-01");
  assert.equal(canReview(state({ status: "DRAFTING" }), B).ok, false);
});

test("canApprove：G-08 複查 → SOD-02 → AC-WFL-001 三關依序", () => {
  const base = state({ status: "PENDING_APPROVAL", preparedBy: A, reviewedBy: B });
  assert.ok(canApprove(base, C).ok);
  const g08 = canApprove({ ...base, evidence: { ...fullEvidence, judgmentReason: "" } }, C);
  assert.equal(g08.ok === false && g08.guard, "G-08");
  const sod02 = canApprove(base, B);
  assert.equal(sod02.ok === false && sod02.guard, "G-05／SOD-02");
  const wfl = canApprove(base, A);
  assert.equal(wfl.ok === false && wfl.guard, "AC-WFL-001");
});

test("控制判定：只有 output_capability 與 reasons，不含交付欄位", () => {
  const j = previewOnlyJudgment(["G-04／SOD-01", "無合格獨立覆核人"]);
  assert.equal(j.outputCapability, "PREVIEW");
  assert.deepEqual(Object.keys(j).sort(), ["outputCapability", "reasons"]);
  // delivery_quality 屬 DeliveryRecord、official_eligible 基線不存在——兩者都不得出現
  assert.equal("deliveryQuality" in j, false);
  assert.equal("officialEligible" in j, false);
});
