import { test } from "node:test";
import assert from "node:assert/strict";
import { legalJobTransition, idempotencyKey, backoffSeconds, attemptsExhausted,
  verdictFor, classifyError, isStalled } from "../../packages/domain/src/backgroundJob.ts";

const SCHEDULE = [5, 15, 45, 135];

test("§27.4 工作狀態機：合法遷移", () => {
  assert.ok(legalJobTransition("QUEUED", "RUNNING"));
  assert.ok(legalJobTransition("RUNNING", "COMPLETED"));
  assert.ok(legalJobTransition("RUNNING", "RETRY_WAIT"));
  assert.ok(legalJobTransition("RUNNING", "FAILED"));
  assert.ok(legalJobTransition("RETRY_WAIT", "RUNNING"));
  assert.ok(legalJobTransition("RUNNING", "RUNNING"), "租約逾時後由他人重領");
});

test("§27.4 工作狀態機：COMPLETED／FAILED 為終態", () => {
  assert.equal(legalJobTransition("COMPLETED", "RUNNING"), false);
  assert.equal(legalJobTransition("FAILED", "RUNNING"), false);
  assert.equal(legalJobTransition("FAILED", "QUEUED"), false);
  assert.equal(legalJobTransition("QUEUED", "COMPLETED"), false);
});

test("冪等鍵是四個結構化欄位的推導值，且對欄位變動敏感", () => {
  const a = idempotencyKey("IMPORT_VALIDATION", "batch-1", 1, "detect-r1");
  assert.equal(a, idempotencyKey("IMPORT_VALIDATION", "batch-1", 1, "detect-r1"));
  assert.notEqual(a, idempotencyKey("IMPORT_VALIDATION", "batch-1", 2, "detect-r1"));
  assert.notEqual(a, idempotencyKey("IMPORT_VALIDATION", "batch-1", 1, "detect-r2"));
  assert.notEqual(a, idempotencyKey("IMPORT_VALIDATION", "batch-2", 1, "detect-r1"));
});

test("退避序列：5→15→45→135，超出長度取最後一項（不無限增長）", () => {
  assert.equal(backoffSeconds(1, SCHEDULE), 5);
  assert.equal(backoffSeconds(2, SCHEDULE), 15);
  assert.equal(backoffSeconds(3, SCHEDULE), 45);
  assert.equal(backoffSeconds(4, SCHEDULE), 135);
  assert.equal(backoffSeconds(9, SCHEDULE), 135);
  assert.equal(backoffSeconds(0, SCHEDULE), 5);
});

test("max_attempts = 首次執行 ＋ 4 次重試", () => {
  assert.equal(attemptsExhausted(4, 5), false);
  assert.equal(attemptsExhausted(5, 5), true);
  assert.equal(attemptsExhausted(6, 5), true);
});

test("BUSINESS_VALIDATION：立即隔離，工作視為完成，不重試", () => {
  const v = verdictFor("BUSINESS_VALIDATION", 1, 5, SCHEDULE);
  assert.equal(v.next, "COMPLETED");
  assert.equal(v.quarantine, true);
  assert.equal(v.backoff, 0);
});

test("RETRYABLE_INFRASTRUCTURE：退避重試，不隔離；耗盡後 FAILED", () => {
  const first = verdictFor("RETRYABLE_INFRASTRUCTURE", 1, 5, SCHEDULE);
  assert.equal(first.next, "RETRY_WAIT");
  assert.equal(first.quarantine, false, "基礎設施故障不得判為業務隔離");
  assert.equal(first.backoff, 5);
  const last = verdictFor("RETRYABLE_INFRASTRUCTURE", 5, 5, SCHEDULE);
  assert.equal(last.next, "FAILED");
  assert.equal(last.quarantine, false, "重試耗盡仍不得隔離——客戶不需重新上傳");
});

test("NON_RETRYABLE_SYSTEM：直接 FAILED，不隔離、不重試", () => {
  const v = verdictFor("NON_RETRYABLE_SYSTEM", 1, 5, SCHEDULE);
  assert.equal(v.next, "FAILED");
  assert.equal(v.quarantine, false);
});

test("LEASE_LOST：舊 worker 完全停手，不得改任何狀態", () => {
  const v = verdictFor("LEASE_LOST", 1, 5, SCHEDULE);
  assert.equal(v.next, "NONE");
  assert.equal(v.quarantine, false);
});

test("錯誤分類：未知故障預設可重試，不得偽造業務拒絕", () => {
  assert.equal(classifyError(new Error("connection reset by peer")), "RETRYABLE_INFRASTRUCTURE");
  assert.equal(classifyError(new Error("ENOENT: no such file")), "RETRYABLE_INFRASTRUCTURE");
  assert.equal(classifyError(new Error("LEASE_LOST：心跳失敗")), "LEASE_LOST");
  assert.equal(classifyError(new Error('syntax error at or near "x"')), "NON_RETRYABLE_SYSTEM");
  assert.equal(classifyError(new Error("invalid reference to FROM-clause entry")), "NON_RETRYABLE_SYSTEM");
});

test("卡住判定：RUNNING 且租約已過期", () => {
  const now = new Date("2026-08-04T12:00:00Z");
  assert.equal(isStalled("RUNNING", "2026-08-04T11:59:00Z", now), true);
  assert.equal(isStalled("RUNNING", "2026-08-04T12:01:00Z", now), false);
  assert.equal(isStalled("RETRY_WAIT", "2026-08-04T11:59:00Z", now), false);
  assert.equal(isStalled("RUNNING", null, now), false);
});
