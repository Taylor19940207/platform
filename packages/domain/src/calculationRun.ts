// PREVIEW CalculationRun（SLICE-M2-02B；設計書 §25.3／§26.9、INV-17／29）。
// 與 migrations/0012 的觸發器同語意：應用層先判定，DB 是最後防線。
//
// 職責分工（沿用 ADR-M2-002）：
//   CalculationRun.status  = 結果狀態（RUNNING／COMPLETED／FAILED；SUPERSEDED 保留不用）
//   BackgroundJob.status   = 非同步執行進度的唯一權威
// 可重試失敗期間 Run 保持 RUNNING；重試耗盡才與 Job 同交易進入失敗終態。

export type CalculationRunStatus = "RUNNING" | "COMPLETED" | "FAILED" | "SUPERSEDED";

/** 計算引擎版本：入 manifest（引擎升級也可能改變結果，§25.3）。 */
export const ENGINE_VERSION = "calc-engine-1";
/** canonical 序列化版本：入 manifest（序列化一改，內容相同也會算出不同雜湊，§26.9）。 */
export const CANONICALIZATION_VERSION = "sqlcanon-1";

const LEGAL: Record<CalculationRunStatus, CalculationRunStatus[]> = {
  RUNNING: ["COMPLETED", "FAILED"],
  COMPLETED: [],          // 終態：重演＝新 run（replay_of_run_id），原 run 永不修改
  FAILED: [],
  SUPERSEDED: [],         // §25.11 語意保留，本刀不使用
};

export function legalRunTransition(from: CalculationRunStatus, to: CalculationRunStatus): boolean {
  return LEGAL[from].includes(to);
}

/**
 * 控制與失敗判定的機器代碼（驗收 #13：機器代碼＋客戶可理解原因）。
 * 建立被拒 → 不建 run，代碼與原因寫入 ControlViolationAttempt；
 * 執行失敗 → 寫入 run.failure_reason_code／failure_reason。
 */
export const RUN_REASON = {
  BATCH_NOT_ACCEPTED: "批次尚未接受（G-01 接受判定式），不得建立計算執行",
  G02_UNMAPPED: "重要來源餘額尚未全數映射（G-02），不得建立計算執行",
  ROLE_REQUIRED: "建立計算執行需 R2 或 R3 角色（B-06，§28.3）",
  CONTEXT_MISMATCH: "輸入組合與案件／期間歸屬不一致（§24.1A）",
  REQUEST_KEY_REUSED: "相同 request key 但請求內容不同——冪等鍵不得重用於不同請求",
  REPLAY_TARGET_NOT_COMPLETED: "只能重演已 COMPLETED 的 run",
  REPLAY_FAILED: "重演失敗：凍結內容遺失、損壞或雜湊不符（INV-29，不得改讀目前工作物件）",
  RESULT_MISMATCH: "重演結果與原 run 不一致（凍結內容完好但計算結果不同）",
  CONTROL_TOTAL_MISMATCH: "控制總額勾稽不一致（G-09）——結果交易已整筆回滾",
  INFRA_RETRY_EXHAUSTED: "基礎設施故障重試耗盡；輸入未受影響，可明示重新執行（新 run）",
  NON_RETRYABLE_SYSTEM: "系統性錯誤；輸入未受影響，請通報維運後明示重新執行（新 run）",
} as const;

export type RunReasonCode = keyof typeof RUN_REASON;

/** 從 fn_assert 的錯誤訊息萃取機器代碼（訊息格式：`CODE:...` 或 `CODE`）。 */
export function reasonCodeOf(message: string): RunReasonCode | null {
  for (const code of Object.keys(RUN_REASON) as RunReasonCode[])
    if (message.includes(code)) return code;
  return null;
}

/** 重演／控制類失敗是確定性結論（工作完成、run 失敗），不是基礎設施故障。 */
export function isDeterministicRunFailure(message: string): boolean {
  const code = reasonCodeOf(message);
  return code === "REPLAY_FAILED" || code === "RESULT_MISMATCH" || code === "CONTROL_TOTAL_MISMATCH";
}
