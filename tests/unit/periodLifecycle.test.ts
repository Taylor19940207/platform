import { test } from "node:test";
import assert from "node:assert/strict";
import { extractDbCode, httpStatusForCode, displayTextForCode, isNotImplemented,
  validateTransitionRequest } from "../../packages/domain/src/periodLifecycle.ts";

const UUID = "99999999-0000-0000-0000-000000000001";

test("代碼以前綴擷取，不依中文文案", () => {
  assert.equal(extractDbCode("ERROR:  G10_NOT_IMPLEMENTED: 前期銜接守衛尚未實作"), "G10_NOT_IMPLEMENTED");
  assert.equal(extractDbCode("ERROR:  OPTIMISTIC_LOCK_CONFLICT: 期間狀態已由他人變更"), "OPTIMISTIC_LOCK_CONFLICT");
  assert.equal(extractDbCode("CROSS_TENANT_DENIED: 期間不屬於目前租戶"), "CROSS_TENANT_DENIED");
  // 文案改了代碼仍擷取得到
  assert.equal(extractDbCode("ERROR:  G07_NOT_IMPLEMENTED: 換成完全不同的說明文字"), "G07_NOT_IMPLEMENTED");
});

test("psql 實際輸出格式：剝掉 psql:／ERROR: 前綴，且不誤認 CONTEXT 等標籤", () => {
  // 這是 psql 真正回來的樣子——單元測試餵理想化字串會漏掉這個 bug
  const real = [
    // String(e) 會加上 Error: 前綴，psql.ts 再加 psql:，psql 自己加 ERROR:
    "Error: psql: ERROR:  G07_NOT_IMPLEMENTED: 匯率版本凍結守衛尚未實作",
    "CONTEXT:  PL/pgSQL function fn_period_transition_guard() line 89 at RAISE",
    'SQL statement "UPDATE period_revision SET status = p_to"',
  ].join("\n");
  assert.equal(extractDbCode(real), "G07_NOT_IMPLEMENTED");
  // 只有 CONTEXT／DETAIL／HINT 而無代碼時，不得誤把標籤當代碼
  assert.equal(extractDbCode("Error: psql: ERROR:  deadlock detected\nDETAIL:  Process 1 waits"), null);
  assert.equal(extractDbCode("Error: psql: ERROR:  OPTIMISTIC_LOCK_CONFLICT: x"), "OPTIMISTIC_LOCK_CONFLICT");
  assert.equal(extractDbCode("CONTEXT:  PL/pgSQL function foo() line 1"), null);
  assert.equal(extractDbCode("HINT:  Try again"), null);
});

test("擷取不到代碼回 null（未知錯誤不猜、不吞）", () => {
  assert.equal(extractDbCode('ERROR:  invalid input syntax for type uuid: "x"'), null);
  assert.equal(extractDbCode("ERROR:  deadlock detected"), null);
  assert.equal(httpStatusForCode(null), 500, "未知錯誤必須是 500，不得偽裝成業務衝突");
});

test("HTTP 映射：預設 409，權限 403，找不到／跨租戶 404", () => {
  assert.equal(httpStatusForCode("ILLEGAL_TRANSITION"), 409);
  assert.equal(httpStatusForCode("OPTIMISTIC_LOCK_CONFLICT"), 409);
  assert.equal(httpStatusForCode("NO_OP_TRANSITION"), 409);
  assert.equal(httpStatusForCode("G02_PERIOD_UNMAPPED"), 409);
  assert.equal(httpStatusForCode("ROLE_NOT_PERMITTED"), 403);
  assert.equal(httpStatusForCode("ACTOR_ROLE_NOT_HELD"), 403);
  assert.equal(httpStatusForCode("TRANSITION_ACTOR_REQUIRED"), 403);
  assert.equal(httpStatusForCode("PERIOD_NOT_FOUND"), 404);
  // 跨租戶不揭露物件是否存在
  assert.equal(httpStatusForCode("CROSS_TENANT_DENIED"), 404);
  assert.equal(displayTextForCode("CROSS_TENANT_DENIED"), displayTextForCode("PERIOD_NOT_FOUND"));
});

test("尚未實作的守衛可被識別（畫面須明示非「已驗證通過」）", () => {
  for (const c of ["G10_NOT_IMPLEMENTED", "G07_NOT_IMPLEMENTED", "G03_NOT_IMPLEMENTED",
                   "G06_NOT_IMPLEMENTED", "G09_NOT_IMPLEMENTED", "RECONCILE_NOT_IMPLEMENTED"]) {
    assert.equal(isNotImplemented(c), true, c);
  }
  assert.equal(isNotImplemented("ILLEGAL_TRANSITION"), false);
  assert.equal(isNotImplemented(null), false);
});

test("格式驗證：合法請求通過", () => {
  assert.deepEqual(
    validateTransitionRequest({ revision: UUID, expectedFrom: "SETUP", to: "OPEN", actingRole: "R4" }),
    { ok: true });
});

test("格式驗證：非 UUID／非法角色／非法狀態／空欄位皆拒絕", () => {
  const base = { revision: UUID, expectedFrom: "SETUP", to: "OPEN", actingRole: "R4" };
  const cases: [Partial<typeof base>, string][] = [
    [{ revision: "not-a-uuid" }, "revision"],
    [{ revision: "" }, "revision"],
    [{ actingRole: "SUPERUSER" }, "acting_role"],
    [{ actingRole: "" }, "acting_role"],
    [{ actingRole: "R0" }, "acting_role"],
    [{ expectedFrom: "BANANA" }, "expected_from"],
    [{ expectedFrom: "" }, "expected_from"],
    [{ to: "BANANA" }, "to"],
    [{ to: "" }, "to"],
  ];
  for (const [patch, field] of cases) {
    const r = validateTransitionRequest({ ...base, ...patch });
    assert.equal(r.ok, false, JSON.stringify(patch));
    assert.equal(r.ok === false && r.field, field);
  }
});

test("格式驗證不複製遷移守衛：非法遷移組合在格式上仍合法", () => {
  // SETUP → DELIVERED 是非法遷移，但格式正確——判定屬 DB，本層不得代為裁決
  assert.deepEqual(
    validateTransitionRequest({ revision: UUID, expectedFrom: "SETUP", to: "DELIVERED", actingRole: "R1" }),
    { ok: true });
  // AWAITING_REVIEWER 不可直接指定，但那是 DB 的判定，不是格式問題
  assert.deepEqual(
    validateTransitionRequest({ revision: UUID, expectedFrom: "IN_REVIEW", to: "AWAITING_REVIEWER", actingRole: "R2" }),
    { ok: true });
});
