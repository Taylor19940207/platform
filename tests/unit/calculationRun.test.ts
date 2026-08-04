import { test } from "node:test";
import assert from "node:assert/strict";
import { legalRunTransition, reasonCodeOf, isDeterministicRunFailure, RUN_REASON }
  from "../../packages/domain/src/calculationRun.ts";

test("§25.3 Run 狀態機：RUNNING 只能到 COMPLETED／FAILED", () => {
  assert.ok(legalRunTransition("RUNNING", "COMPLETED"));
  assert.ok(legalRunTransition("RUNNING", "FAILED"));
  assert.equal(legalRunTransition("RUNNING", "SUPERSEDED"), false);   // 本刀不使用
});

test("§25.3 終態不可離開：重演＝新 run，原 run 永不修改", () => {
  assert.equal(legalRunTransition("COMPLETED", "RUNNING"), false);
  assert.equal(legalRunTransition("COMPLETED", "FAILED"), false);
  assert.equal(legalRunTransition("FAILED", "RUNNING"), false);
  assert.equal(legalRunTransition("SUPERSEDED", "RUNNING"), false);
});

test("機器代碼萃取：fn_assert 訊息 → 代碼＋人可讀原因（驗收 #13）", () => {
  assert.equal(reasonCodeOf("psql: ERROR:  G02_UNMAPPED:111、112"), "G02_UNMAPPED");
  assert.equal(reasonCodeOf("REPLAY_FAILED:CONTENT_HASH_MISMATCH"), "REPLAY_FAILED");
  assert.equal(reasonCodeOf("something else"), null);
  assert.ok(RUN_REASON.G02_UNMAPPED.includes("G-02"));
});

test("確定性失敗與基礎設施故障分流：重演／控制類＝結論不重試", () => {
  assert.ok(isDeterministicRunFailure("REPLAY_FAILED:MANIFEST_EMPTY"));
  assert.ok(isDeterministicRunFailure("RESULT_MISMATCH"));
  assert.ok(isDeterministicRunFailure("CONTROL_TOTAL_MISMATCH"));
  assert.equal(isDeterministicRunFailure("connection reset by peer"), false);
  assert.equal(isDeterministicRunFailure("BATCH_NOT_ACCEPTED"), false);
});
