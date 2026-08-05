import { test } from "node:test";
import assert from "node:assert/strict";
import { legalPackageTransition, stagingVerdict, artifactObjectKey,
  pkgReasonCodeOf, isDeterministicPkgFailure, resolveTraceability, sectionCanonical,
  RENDER_VERSION, type CoverageRow } from "../../packages/domain/src/evidencePackage.ts";

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
    { id: "c-wild", accountScope: "*", granularity: "BALANCE", completeness: "COMPLETE" },
    { id: "c-500", accountScope: "500", granularity: "JOURNAL", completeness: "COMPLETE" },
    { id: "c-600", accountScope: "600", granularity: "DOCUMENT", completeness: "COMPLETE" },
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

test("0017③：canonical JSON 消除分隔符注入——舊管線串接的碰撞必須分開", () => {
  assert.notEqual(sectionCanonical(["h"], [["a|b", "c"]]),
                  sectionCanonical(["h"], [["a", "b|c"]]));
  assert.notEqual(sectionCanonical(["h"], [["a\nb"]]),
                  sectionCanonical(["h"], [["a"], ["b"]]));
  assert.equal(sectionCanonical(["h"], [["a", "b"]]), sectionCanonical(["h"], [["a", "b"]]));
});

test("0017 P2：完整度規則——UNKNOWN 降 UNKNOWN、PARTIAL 保級併列；render 已升 html-2", () => {
  assert.equal(RENDER_VERSION, "html-2");
  const cov: CoverageRow[] = [
    { id: "c-p", accountScope: "500", granularity: "JOURNAL", completeness: "PARTIAL" },
    { id: "c-u", accountScope: "600", granularity: "DOCUMENT", completeness: "UNKNOWN" },
  ];
  const r = resolveTraceability([
    { outputCode: "A", sourceCodes: ["500"] },
    { outputCode: "B", sourceCodes: ["600"] },
    { outputCode: "C", sourceCodes: ["500", "600"] },
  ], cov);
  assert.equal(r[0].level, "JOURNAL");      // PARTIAL：保留等級
  assert.equal(r[0].completeness, "PARTIAL");
  assert.equal(r[1].level, "UNKNOWN");      // UNKNOWN 完整度：不得宣稱任何等級
  assert.equal(r[2].level, "UNKNOWN");      // 混合含 UNKNOWN → 整體降 UNKNOWN
  assert.equal(r[2].completeness, "UNKNOWN");
});
