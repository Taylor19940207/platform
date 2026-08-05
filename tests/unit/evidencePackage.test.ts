import { test } from "node:test";
import assert from "node:assert/strict";
import { legalPackageTransition, stagingVerdict, artifactObjectKey,
  pkgReasonCodeOf, isDeterministicPkgFailure }
  from "../../packages/domain/src/evidencePackage.ts";

test("契約 A：GENERATING → READY／FAILED；終態不可離開（重產＝新 package）", () => {
  assert.ok(legalPackageTransition("GENERATING", "READY"));
  assert.ok(legalPackageTransition("GENERATING", "FAILED"));
  assert.equal(legalPackageTransition("READY", "GENERATING"), false);
  assert.equal(legalPackageTransition("READY", "FAILED"), false);
  assert.equal(legalPackageTransition("FAILED", "READY"), false);
});

test("契約 B：staging 裁決——同 hash 沿用、異 hash 確定性失敗；object key 確定性", () => {
  assert.equal(stagingVerdict("abc", "abc"), "REUSE");
  assert.equal(stagingVerdict("abc", "def"), "CONFLICT");
  assert.equal(artifactObjectKey("t1", "p1", "html-1"), "t1/evidence/p1/html-1.html");
  assert.equal(artifactObjectKey("t1", "p1", "html-1"), artifactObjectKey("t1", "p1", "html-1"));
});

test("契約 D：確定性失敗與基礎設施故障分流", () => {
  assert.ok(isDeterministicPkgFailure("UPSTREAM_VERIFY_FAILED:SNAPSHOT_HASH"));
  assert.ok(isDeterministicPkgFailure("ARTIFACT_CONFLICT"));
  assert.equal(isDeterministicPkgFailure("connection reset"), false);
  assert.equal(pkgReasonCodeOf("psql: ERROR: RUN_NOT_COMPLETED..."), "RUN_NOT_COMPLETED");
  assert.equal(pkgReasonCodeOf("nothing"), null);
});
