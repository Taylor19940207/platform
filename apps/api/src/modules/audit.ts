// 稽核軌跡寫入（§25.18）。DomainEvent 與 ControlViolationAttempt 同表以 kind 區分；
// 一般欄位驗證錯誤不得寫入——那走應用日誌。
//
// 放在 modules/ 而非 http/：寫稽核是**使用案例編排**的一部分（Service 的責任），
// 與 HTTP 無關。Service 可以 import 它，且不會因此碰到 IncomingMessage。
import { exec } from "../../../../packages/database/src/psql.ts";

export function audit(tenantId: string, kind: string, eventType: string, actor: string | null,
               objectType: string, objectId: string, payload: object): void {
  exec(`INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
        VALUES (:'t'::uuid, :'k', :'e', ${actor ? ":'a'::uuid" : "NULL"}, :'ot', :'oi'::uuid, :'pl'::jsonb)`,
    { t: tenantId, k: kind, e: eventType, ...(actor ? { a: actor } : {}),
      ot: objectType, oi: objectId, pl: JSON.stringify(payload) }, { tenantId });
}

/**
 * DomainEvent 的 SQL 片段（不執行），供併入狀態遷移的同一交易。
 *
 * 事件在 COMMIT 之後另行插入時，一旦插入失敗，狀態已永久前進而事件不存在——
 * 驗收「每個遷移都有 DomainEvent」就不再成立。生命週期事件必須與狀態同進同出。
 * `prefix` 讓同一交易能容納多個事件（如批准同時寫 approved 與 materialized）
 * 而不撞參數名，也不與快照片段的參數衝突。
 */
export function auditSql(tenantId: string, kind: string, eventType: string, actor: string,
                  objectType: string, objectId: string, payload: object, prefix = "ev"):
    { sql: string; params: Record<string, string> } {
  const p = prefix;
  return {
    sql: `INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
          VALUES (:'${p}t'::uuid, :'${p}k', :'${p}e', :'${p}a'::uuid, :'${p}ot', :'${p}oi'::uuid, :'${p}pl'::jsonb);`,
    params: { [`${p}t`]: tenantId, [`${p}k`]: kind, [`${p}e`]: eventType, [`${p}a`]: actor,
              [`${p}ot`]: objectType, [`${p}oi`]: objectId, [`${p}pl`]: JSON.stringify(payload) },
  };
}
