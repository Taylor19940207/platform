// 身分人工確認的使用案例編排（SLICE-M2-04／CTX-d）。
//
// **本檔不重寫任何守衛。** SOD-07（上傳者不得確認自己上傳的批次）、
// identity 遷移白名單、Resolution 的歸因一致性與角色有效性，最終裁決都在
// DB（migrations/0019／0020 的 fn_sod07_guard 等）。這裡做的是使用案例編排：
// 把 Resolution、identity_status 與 DomainEvent 放進**同一個交易**。
//
// 三者同生共死不是風格問題：Resolution 寫成功而狀態沒動，批次會停在
// PENDING_CONFIRMATION 卻已有確認紀錄；狀態動了而事件沒寫，稽核軌跡就答不出
// 「誰在什麼時候確認的」。
import { exec } from "../../../../../packages/database/src/psql.ts";

export interface ConfirmInput {
  batchId: string;
  batchVersion: number;
  assessmentId: string;
  reason: string;
  evidenceRef: string;
  actorId: string;
  tenantId: string;
}

export function confirmIdentity(input: ConfirmInput): void {
  const ev = input.evidenceRef;
  exec(`BEGIN;
    INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id,
           batch_version, resolved_by, acting_role, reason, evidence_ref, detection_rule_version)
    VALUES (:'t'::uuid, :'aid'::uuid, :'b'::uuid, ${input.batchVersion}, :'u'::uuid, 'R2',
           :'rs', ${ev ? ":'ev'" : "NULL"},
           (SELECT detection_rule_version FROM source_identity_assessment WHERE assessment_id = :'aid'::uuid));
    UPDATE import_batch SET identity_status = 'MANUALLY_RESOLVED'
     WHERE import_batch_id = :'b'::uuid;
    INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
    VALUES (:'t'::uuid, 'DOMAIN_EVENT', 'import_batch.identity_resolved', :'u'::uuid,
           'import_batch', :'b'::uuid,
           jsonb_build_object('assessment_id', :'aid', 'reason', :'rs',
             'evidence_ref', ${ev ? ":'ev'" : "NULL"},
             'detection_rule_version',
             (SELECT detection_rule_version FROM source_identity_assessment WHERE assessment_id = :'aid'::uuid),
             'alias_table_version', NULL));
    COMMIT;`,
    { t: input.tenantId, aid: input.assessmentId, b: input.batchId,
      u: input.actorId, rs: input.reason, ...(ev ? { ev } : {}) },
    { tenantId: input.tenantId });
}
