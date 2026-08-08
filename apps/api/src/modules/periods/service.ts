// 期間生命週期的使用案例編排（SLICE-M2-05／§25.8）。
//
// **本檔不做任何守衛裁決。** §27 M7 明定唯一裁決點是 `attemptTransition`，
// 而它實作在 DB（migrations/0022）：合法遷移表、角色矩陣、期間級聚合、
// 樂觀鎖、覆核覆蓋評估、跨租戶比對、成功事件 `period.transitioned`——全部在那裡。
// 這裡只負責：呼叫它、把穩定機器代碼轉成 typed result、拒絕時留下 CVA。
//
// 邊界（拆層驗收條件）：
//   * 不 import node:http 的任何型別，也不產生 HTML。
//   * `actorId` 只能由 route 從 Session 傳入——請求本體不得自帶 actor。
//   * 未知的 DB 錯誤**原樣往上拋**，不偽裝成 409：分不出來的錯誤是 500，
//     把它歸成業務衝突會讓真正的故障永遠不出現在錯誤率上。
import { query } from "../../../../../packages/database/src/psql.ts";
import { extractDbCode, httpStatusForCode, isNotImplemented, type PeriodStatus }
  from "../../../../../packages/domain/src/periodLifecycle.ts";
import { audit } from "../audit.ts";

export interface TransitionInput {
  revisionId: string;
  expectedFrom: string;
  to: string;
  actingRole: string;
  actorId: string;
  tenantId: string;
}

export type PeriodTransitionResult =
  | { ok: true; landed: PeriodStatus }
  | { ok: false; code: string; httpStatus: number; notImplemented: boolean };

export function attemptTransition(input: TransitionInput): PeriodTransitionResult {
  const { revisionId, expectedFrom, to, actingRole, actorId, tenantId } = input;
  try {
    const [row] = query<{ landed: string }>(
      `SELECT fn_period_attempt_transition(:'r'::uuid, :'ef', :'to', :'u'::uuid, :'role') AS landed`,
      { r: revisionId, ef: expectedFrom, to, u: actorId, role: actingRole },
      { tenantId });
    // 不在此補寫事件：DB 已於同一交易寫入權威的 period.transitioned
    // （含 from／requested／landed）。此處若補第二筆，遷移已提交而事件失敗時
    // 會回 500，但期間其實已成功遷移——客戶看到的狀態與真實狀態不一致。
    return { ok: true, landed: row.landed as PeriodStatus };
  } catch (e) {
    // 代碼以前綴擷取，不依中文文案判斷（文案會改，代碼不會）
    const code = extractDbCode(String(e));
    if (code === null) throw e;              // 未預期錯誤不吞、不猜
    audit(tenantId, "CONTROL_VIOLATION_ATTEMPT", "period.transition.rejected", actorId,
      "period_revision", revisionId,
      { guard: code, requested: to, expected_from: expectedFrom, acting_role: actingRole });
    return { ok: false, code, httpStatus: httpStatusForCode(code), notImplemented: isNotImplemented(code) };
  }
}
