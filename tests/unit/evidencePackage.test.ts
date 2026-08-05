import { test } from "node:test";
import assert from "node:assert/strict";
import { legalPackageTransition, stagingVerdict, artifactObjectKey,
  pkgReasonCodeOf, isDeterministicPkgFailure, resolveTraceability,
  type CoverageRow } from "../../packages/domain/src/evidencePackage.ts";

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

test("追溯解析：混合 scope／granularity——精確優先於 wildcard、弱鏈決定等級", () => {
  const cov: CoverageRow[] = [
    { id: "c-wild", accountScope: "*", granularity: "BALANCE" },
    { id: "c-500", accountScope: "500", granularity: "JOURNAL" },
    { id: "c-600", accountScope: "600", granularity: "DOCUMENT" },
  ];
  const r = resolveTraceability([
    { outputCode: "6001", sourceCodes: ["500"] },          // 精確 JOURNAL 覆蓋 wildcard
    { outputCode: "6401", sourceCodes: ["600"] },          // 精確 DOCUMENT
    { outputCode: "6602", sourceCodes: ["610", "620"] },   // 只有 wildcard → BALANCE
    { outputCode: "9999", sourceCodes: ["500", "610"] },   // JOURNAL＋BALANCE → 弱鏈 BALANCE
  ], cov);
  assert.equal(r[0].level, "JOURNAL");
  assert.deepEqual(r[0].coverageIds, ["c-500"]);
  assert.equal(r[1].level, "DOCUMENT");
  assert.equal(r[2].level, "BALANCE");
  assert.deepEqual(r[2].coverageIds, ["c-wild"]);
  assert.equal(r[3].level, "BALANCE");                     // 不得宣稱高於最弱來源
  assert.deepEqual(r[3].coverageIds, ["c-500", "c-wild"]);
});

test("追溯解析：無來源或無 coverage → UNKNOWN（誠實標示，不猜測）", () => {
  const r = resolveTraceability([
    { outputCode: "adj-only", sourceCodes: [] },
    { outputCode: "1001", sourceCodes: ["100"] },
  ], []);
  assert.equal(r[0].level, "UNKNOWN");
  assert.equal(r[1].level, "UNKNOWN");
  assert.deepEqual(r[1].coverageIds, []);
});
