// 期間生命週期（SLICE-M2-05；設計書 §25.8）。
//
// **本檔不做任何裁決。** §27 M7 明定所有守衛條件的唯一裁決點是
// attemptTransition，而該裁決點實作在 DB（migrations/0022）：
//   DB   = 唯一裁決者（合法遷移表、角色矩陣、期間級聚合、fail closed）
//   API  = 呼叫它，把穩定機器代碼映射為 HTTP 狀態＋CVA 留痕
//   本檔 = 只有型別與顯示文案
//
// 同一規則寫兩次就會有一次寫錯（02A 缺口 2 的教訓），所以這裡刻意不重寫守衛。

export type PeriodStatus =
  | "SETUP" | "OPEN" | "IN_PREPARATION" | "IN_REVIEW" | "AWAITING_REVIEWER"
  | "ADJ_APPROVED" | "CALCULATING" | "RECONCILING" | "PENDING_PKG_APPR"
  | "LOCKED" | "DELIVERED" | "REOPENED" | "PREVIEW_ONLY";

/**
 * 從 DB 例外訊息擷取穩定機器代碼。
 *
 * 代碼一律以 `CODE: 說明` 形式出現在訊息開頭——**不得依中文文案判斷**，
 * 文案會改，代碼不會。擷取不到就回 null，由呼叫端當成未預期錯誤（500），
 * 不猜、不吞。
 */
// psql 自己的欄位標籤——長得跟穩定代碼一樣（大寫＋冒號），必須排除。
// 少了這份清單，`ERROR:  ...` 之後的 `CONTEXT:  PL/pgSQL function …` 會被誤認為代碼。
const PSQL_LABELS = new Set([
  "ERROR", "FATAL", "PANIC", "WARNING", "NOTICE", "INFO", "LOG", "DEBUG",
  "CONTEXT", "DETAIL", "HINT", "LINE", "QUERY", "STATEMENT", "WHERE", "PL",
]);

export function extractDbCode(message: string): string | null {
  for (const line of message.split("\n")) {
    // 先剝掉傳輸層前綴（psql:）與嚴重性前綴，否則 `ERROR:` 自己就會被當成代碼——
    // 那會讓 deadlock、UUID 語法錯誤等未知故障被誤判為業務衝突（409），
    // 永遠不會出現 500。
    // 實際字串長這樣：`Error: psql: ERROR:  CODE: 說明`
    // ——JS 的 String(e) 前綴、傳輸層前綴、嚴重性前綴要逐層剝到穩定為止。
    let t = line.trim();
    for (;;) {
      const before = t;
      t = t.replace(/^(?:Error|error):\s*/, "")
           .replace(/^psql:\s*/i, "")
           .replace(/^(?:ERROR|FATAL|PANIC|WARNING|NOTICE):\s*/, "");
      if (t === before) break;
    }
    const m = /^([A-Z][A-Z0-9_]{2,}):/.exec(t);
    if (m && !PSQL_LABELS.has(m[1])) return m[1];
  }
  return null;
}

/**
 * 穩定代碼 → HTTP 狀態。
 *
 * 預設 409（衝突：目前狀態不允許這次遷移）。少數例外：
 *   權限類 → 403；找不到或跨租戶 → 404（跨租戶不揭露物件是否存在）。
 */
export function httpStatusForCode(code: string | null): number {
  switch (code) {
    case null: return 500;
    case "ACTOR_ROLE_NOT_HELD":
    case "ROLE_NOT_PERMITTED":
    case "TRANSITION_ACTOR_REQUIRED":
      return 403;
    case "PERIOD_NOT_FOUND":
    case "CROSS_TENANT_DENIED":
      return 404;
    default:
      return 409;
  }
}

/** 顯示文案（僅供畫面；判定一律以 DB 代碼為準）。 */
const TEXT: Record<string, string> = {
  ILLEGAL_TRANSITION: "此狀態不允許這個遷移（不得跳關）",
  ROLE_NOT_PERMITTED: "你目前的角色不得發起這個遷移",
  ACTOR_ROLE_NOT_HELD: "你未在本案件持有該角色的有效指派",
  OPTIMISTIC_LOCK_CONFLICT: "期間狀態已被他人變更，請重新載入後再操作",
  NO_OP_TRANSITION: "目標狀態與目前狀態相同，不構成遷移",
  REQUIRED_DATA_INCOMPLETE: "本期尚無「已接受且聲明完整」的 BALANCE 批次",
  G02_PERIOD_UNMAPPED: "本期尚有來源餘額未映射，不得進入覆核",
  ADJ_NOT_ALL_APPROVED: "本期尚有調整未批准",
  PERIOD_SOD_VIOLATION: "本期有調整不滿足逐筆職責分離復驗",
  G10_NOT_IMPLEMENTED: "前期銜接守衛尚未實作，非首期無法開期",
  G07_NOT_IMPLEMENTED: "匯率版本凍結守衛尚未實作",
  RECONCILE_NOT_IMPLEMENTED: "折算差額與調節核對尚未實作",
  G03_NOT_IMPLEMENTED: "B 基礎（遞延稅）守衛尚未實作",
  G06_NOT_IMPLEMENTED: "期間參與者去重計數守衛尚未實作",
  G09_NOT_IMPLEMENTED: "控制總額守衛與 ExportJob 尚未實作",
  CROSS_TENANT_DENIED: "找不到該期間",
  PERIOD_NOT_FOUND: "找不到該期間",
};

export function displayTextForCode(code: string | null): string {
  return (code && TEXT[code]) || "此操作未被允許";
}

/** 尚未實作的守衛：畫面須明示「不是已驗證通過」。 */
export function isNotImplemented(code: string | null): boolean {
  return code !== null && code.endsWith("_NOT_IMPLEMENTED");
}

const STATUSES: readonly string[] = [
  "SETUP", "OPEN", "IN_PREPARATION", "IN_REVIEW", "AWAITING_REVIEWER", "ADJ_APPROVED",
  "CALCULATING", "RECONCILING", "PENDING_PKG_APPR", "LOCKED", "DELIVERED",
  "REOPENED", "PREVIEW_ONLY",
];

/**
 * 請求格式驗證——**只驗型別與格式，不做任何守衛裁決**。
 *
 * 這不侵犯「DB 為唯一裁決點」：能不能遷移仍完全由 DB 判定。這裡擋掉的是
 * 「連送進 DB 都不成形」的請求（非 UUID、不存在的狀態值、空欄位），
 * 否則會變成沒有穩定前綴的 PostgreSQL 錯誤而落入未知 500——
 * 那是可預期的請求格式錯誤，不是 DB 故障。
 *
 * 一般欄位驗證錯誤不寫 ControlViolationAttempt（§25.18：只有狀態遷移與
 * 權限控制的拒絕才進不可變軌跡）。
 */
export function validateTransitionRequest(input: {
  revision: string; expectedFrom: string; to: string; actingRole: string;
}): { ok: true } | { ok: false; field: string; reason: string } {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(input.revision)) {
    return { ok: false, field: "revision", reason: "不是合法的 UUID" };
  }
  if (!/^R[1-9]$/.test(input.actingRole)) {
    return { ok: false, field: "acting_role", reason: "不是合法的角色代碼（R1～R9）" };
  }
  if (!STATUSES.includes(input.expectedFrom)) {
    return { ok: false, field: "expected_from", reason: "不是合法的期間狀態" };
  }
  if (!STATUSES.includes(input.to)) {
    return { ok: false, field: "to", reason: "不是合法的期間狀態" };
  }
  return { ok: true };
}
