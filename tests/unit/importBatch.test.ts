import { test } from "node:test";
import assert from "node:assert/strict";
import { canTransition, acceptancePredicate, classifyIdentity, identityStatusOf }
  from "../../packages/domain/src/importBatch.ts";

test("§25.5 合法遷移鏈", () => {
  assert.ok(canTransition("DRAFT", "UPLOADED"));
  assert.ok(canTransition("VALIDATING", "QUARANTINED"));
  assert.ok(canTransition("VALIDATED", "ACCEPTED"));
});

test("§25.5 非法遷移被拒", () => {
  assert.equal(canTransition("DRAFT", "VALIDATED"), false);
  assert.equal(canTransition("QUARANTINED", "VALIDATED"), false);  // 終態
  assert.equal(canTransition("ACCEPTED", "DRAFT"), false);
});

test("G-01/INV-28：三條件缺一不可", () => {
  const base = { status: "VALIDATED", identityStatus: "MATCHED", hashVerified: true } as const;
  assert.equal(acceptancePredicate(base).ok, true);
  assert.equal(acceptancePredicate({ ...base, identityStatus: "CONFLICT" }).ok, false);
  assert.equal(acceptancePredicate({ ...base, identityStatus: "NOT_CHECKED" }).ok, false);
  assert.equal(acceptancePredicate({ ...base, hashVerified: false }).ok, false);
  assert.equal(acceptancePredicate({ ...base, status: "UPLOADED" }).ok, false);
});

test("CR-002 證據分級：模糊名稱不升 MATCH 不降 CONFLICT", () => {
  assert.equal(classifyIdentity("1234", "1234", "AUTHORITATIVE_ID"), "MATCH");
  assert.equal(classifyIdentity("1234", "9999", "AUTHORITATIVE_ID"), "CONFLICT");
  assert.equal(classifyIdentity("A社", "A株式会社", "FUZZY_NAME"), "UNVERIFIABLE");
  assert.equal(classifyIdentity("A社", "A社", "FUZZY_NAME"), "UNVERIFIABLE");
  assert.equal(classifyIdentity(null, null, "NONE"), "UNVERIFIABLE");
});

test("MatchResult → identity_status 對映", () => {
  assert.equal(identityStatusOf("MATCH"), "MATCHED");
  assert.equal(identityStatusOf("CONFLICT"), "CONFLICT");
  assert.equal(identityStatusOf("UNVERIFIABLE"), "PENDING_CONFIRMATION");
});
