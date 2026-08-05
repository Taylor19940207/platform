// 匯入驗證工作器（§27.4 非同步邊界；§25.5 第一條流程；SLICE-M2-03 可靠性）。
//
// 契約：docs/slices/SLICE-M2-03_背景工作可靠性.md
// 可觀察性：docs/adr/ADR-M2-002.md
//   ImportBatch.status   = 業務結果狀態（VALIDATING 為交易內瞬時狀態，外部觀察不到）
//   BackgroundJob.status = 非同步執行進度（QUEUED/RUNNING/RETRY_WAIT/COMPLETED/FAILED）
//
// 流程：
//   認領 job（RUNNING ＋ 新 claim_token）        ImportBatch 保持 UPLOADED
//     → 讀物件、解析、計算（交易外，無 DB 效果）
//     → 單一交易：驗證 claim_token → UPLOADED→VALIDATING → 寫來源事實
//                → VALIDATING→VALIDATED/QUARANTINED → DomainEvent → job COMPLETED
//
// 基礎設施故障：資料交易回滾，ImportBatch 仍為 UPLOADED，job 轉 RETRY_WAIT；
// 重試耗盡 → job FAILED，批次仍為 UPLOADED——客戶不需重新上傳同一份檔案。
//
// 佇列：Postgres FOR UPDATE SKIP LOCKED（沙箱替代，見 ADR-LOCAL-001）。
// 註：worker 以受信後端身分跨租戶處理（dev 角色）；真機應改專用角色並逐租戶 set_config。
import { createHash, randomUUID } from "node:crypto";
import { hostname } from "node:os";
import { query, exec } from "../../../packages/database/src/psql.ts";
import { getObject } from "../../../packages/database/src/objectstore.ts";
import { classifyIdentity, identityStatusOf, type EvidenceKind }
  from "../../../packages/domain/src/importBatch.ts";
import { cents, fmtCents } from "../../../packages/domain/src/mapping.ts";
import { classifyError, verdictFor, type JobErrorClass }
  from "../../../packages/domain/src/backgroundJob.ts";
import { reasonCodeOf, isDeterministicRunFailure, RUN_REASON }
  from "../../../packages/domain/src/calculationRun.ts";
import { PKG_REASON, pkgReasonCodeOf, isDeterministicPkgFailure, stagingVerdict,
  artifactObjectKey, resolveTraceability, sectionCanonical } from "../../../packages/domain/src/evidencePackage.ts";
import { putObject } from "../../../packages/database/src/objectstore.ts";
import { config } from "../../../packages/config/src/index.ts";

const INTERVAL = config.pollMs;
const RULE_VERSION = "detect-r1";   // 識別規則版本：寫入每筆評估（CR-002 B-3），亦為 job 冪等鍵之一
const WORKER_ID = `${hostname()}#${process.pid}`;
const LEASE = config.jobLeaseSeconds;

/** 業務裁決：這是結論，不是故障——不重試，直接隔離。 */
class BusinessRejection extends Error {}

interface ClaimedCore {
  job_id: string; claim_token: string; attempt_count: number; max_attempts: number;
  tenant_id: string; job_type: "IMPORT_VALIDATION" | "CALCULATION_RUN" | "EVIDENCE_PACKAGE";
  subject_id: string; subject_version: number;
}
interface Claimed extends ClaimedCore {
  import_batch_id: string; batch_version: number; file_sha256: string;
  declared_legal_entity_id: string; object_key: string; declared_code: string | null;
}

/** SQL 字面值跳脫（worker 以受信身分執行，值來自 DB 自身，非使用者輸入）。 */
const lit = (s: string) => `'${String(s).replace(/'/g, "''")}'`;

/**
 * 認領：QUEUED、退避到期的 RETRY_WAIT、或租約逾時的 RUNNING。
 * 每次認領產生新的 claim_token——只比對 claimed_by 不是真正的 fencing，
 * worker ID 被重用時舊 worker 可能誤用新租約。
 */
function claim(): ClaimedCore | null {
  const token = randomUUID();
  const rows = query<ClaimedCore>(
    `UPDATE background_job j
        SET status = 'RUNNING', claim_token = ${lit(token)}::uuid,
            claimed_by = ${lit(WORKER_ID)}, claimed_at = now(),
            lease_expires_at = now() + interval '${LEASE} seconds',
            attempt_count = j.attempt_count + 1
      WHERE j.job_id = (
        SELECT job_id FROM background_job
         WHERE job_type IN ('IMPORT_VALIDATION','CALCULATION_RUN','EVIDENCE_PACKAGE')
           AND (status = 'QUEUED'
             OR (status = 'RETRY_WAIT' AND next_attempt_at <= now())
             OR (status = 'RUNNING'    AND lease_expires_at <= now()))
         ORDER BY next_attempt_at, created_at LIMIT 1 FOR UPDATE SKIP LOCKED)
     RETURNING j.job_id, j.claim_token, j.attempt_count, j.max_attempts,
       j.tenant_id, j.job_type, j.subject_id, j.subject_version`,
    {}, { asRuntime: false });
  return rows[0] ?? null;
}

/** 匯入工作的主體細節（認領後載入；同 worker 內讀取，無競態意義上的差異）。 */
function loadImportDetail(c: ClaimedCore): Claimed {
  const [r] = query<Omit<Claimed, keyof ClaimedCore | "import_batch_id" | "batch_version">>(
    `SELECT ib.file_sha256, ib.declared_legal_entity_id,
            (SELECT object_key FROM source_document sd
              WHERE sd.import_batch_id = ib.import_batch_id LIMIT 1) AS object_key,
            le.authoritative_code AS declared_code
       FROM import_batch ib
       JOIN legal_entity le ON le.legal_entity_id = ib.declared_legal_entity_id
      WHERE ib.import_batch_id = ${lit(c.subject_id)}::uuid`,
    {}, { asRuntime: false });
  return { ...c, ...r, import_batch_id: c.subject_id, batch_version: c.subject_version };
}

/** 心跳：只有持有 claim_token 的人能延長租約。 */
function heartbeat(j: ClaimedCore): void {
  const rows = query<{ ok: number }>(
    `UPDATE background_job
        SET lease_expires_at = now() + interval '${LEASE} seconds'
      WHERE job_id = ${lit(j.job_id)}::uuid
        AND claim_token = ${lit(j.claim_token)}::uuid
        AND lease_expires_at > now()
     RETURNING 1 AS ok`, {}, { asRuntime: false });
  if (rows.length === 0) throw new Error("LEASE_LOST：心跳失敗，租約已不屬於本 worker");
}

/** 事件 SQL 片段：與狀態遷移併入同一交易（不得事後補寫）。 */
function eventSql(tenantId: string, eventType: string, objectId: string,
                  payload: object, alias: string, objectType = "import_batch"): string {
  return `INSERT INTO audit_event (tenant_id, kind, event_type, object_type, object_id, payload)
          VALUES (${lit(tenantId)}::uuid, 'DOMAIN_EVENT', ${lit(eventType)}, ${lit(objectType)},
                  ${lit(objectId)}::uuid, ${lit(JSON.stringify(payload))}::jsonb); -- ${alias}`;
}

/**
 * 交易內的 fencing 斷言＋列鎖：租約已被接手就整批放棄。
 * FOR UPDATE 把 job 列鎖到 COMMIT——沒有列鎖時，「檢查通過 → 租約到期 →
 * 他人重領並寫入」可與本交易後續寫入交錯；鎖住後競爭者的認領
 * （FOR UPDATE SKIP LOCKED）在本交易結束前拿不到這一列。
 */
function fenceSql(j: ClaimedCore): string {
  return `WITH fence AS (
            SELECT job_id FROM background_job
             WHERE job_id = ${lit(j.job_id)}::uuid
               AND claim_token = ${lit(j.claim_token)}::uuid
               AND lease_expires_at > now()
               FOR UPDATE)
          SELECT fn_assert(EXISTS (SELECT 1 FROM fence), 'LEASE_LOST');`;
}

/** TB 解析：#key=value 中繼資料列 ＋ CSV（account_code,account_name,debit,credit） */
function parseTb(text: string): { meta: Record<string, string>;
    lines: { code: string; name: string; debit: string; credit: string }[]; errors: string[] } {
  const meta: Record<string, string> = {};
  const lines: { code: string; name: string; debit: string; credit: string }[] = [];
  const errors: string[] = [];
  let headerSeen = false;
  for (const [i, rawLine] of text.split("\n").entries()) {
    const line = rawLine.trim();
    if (!line) continue;
    if (line.startsWith("#")) {
      const eq = line.indexOf("=");
      if (eq > 1) meta[line.slice(1, eq).trim()] = line.slice(eq + 1).trim();
      continue;
    }
    if (!headerSeen) { headerSeen = true; continue; }   // 表頭列
    const cols = line.split(",");
    if (cols.length < 4) { errors.push(`第 ${i + 1} 列欄位不足`); continue; }
    const [code, name, debit, credit] = cols.map((c) => c.trim());
    if (!/^-?\d+(\.\d{1,2})?$/.test(debit) || !/^-?\d+(\.\d{1,2})?$/.test(credit)) {
      errors.push(`第 ${i + 1} 列金額格式錯誤`); continue;
    }
    lines.push({ code, name, debit, credit });
  }
  return { meta, lines, errors };
}

/**
 * 交易外：讀物件、解析、計算。此處不得有任何 DB 效果。
 * 業務裁決以 BusinessRejection 表達——與基礎設施故障是兩回事。
 */
function evaluate(j: Claimed) {
  const data = getObject(j.object_key);                     // 失敗＝基礎設施故障
  const sha = createHash("sha256").update(data).digest("hex");
  if (sha !== j.file_sha256)
    throw new BusinessRejection("雜湊不符：物件內容與上傳宣告不一致");

  const { meta, lines, errors } = parseTb(data.toString("utf8"));
  if (errors.length) throw new BusinessRejection(`解析失敗：${errors.slice(0, 3).join("；")}`);
  if (lines.length === 0) throw new BusinessRejection("檔案沒有資料列");

  let debit = 0n, credit = 0n;   // 以「分」為單位的整數運算——金額絕不用浮點
  for (const l of lines) { debit += cents(l.debit); credit += cents(l.credit); }
  const diff = debit - credit;

  const detectedCode = meta["legal_entity_code"] ?? null;
  const evidence: EvidenceKind = detectedCode ? "AUTHORITATIVE_ID" : "NONE";
  const result = classifyIdentity(j.declared_code, detectedCode, evidence);
  const idStatus = identityStatusOf(result);

  return { sha, lines, diff, detectedCode, evidence, result, idStatus };
}

/**
 * 單一交易寫入全部 DB 效果。
 *
 * VALIDATING 在此交易內出現又離開（ADR-M2-002）：外部永遠觀察不到，
 * 因此「批次卡在 VALIDATING」結構性不可能發生。
 */
function commitResult(j: Claimed, r: ReturnType<typeof evaluate>): void {
  const quarantineReason =
    r.result === "CONFLICT"
      ? `身分不一致：宣告法人代碼 ${j.declared_code}，檔案內為 ${r.detectedCode}（CONFLICT，無人工豁免）`
      : r.diff !== 0n ? `借貸不平衡：差額 ${fmtCents(r.diff)}（G-01）` : null;

  // VALUES 只放逐列資料；tenant／batch／ds.id 由外層 SELECT 帶入
  // （VALUES 清單內無法引用同一 CTE 的欄位）。
  const lineRows = r.lines.map((l) => {
    const lineSha = createHash("sha256").update(`${l.code}|${l.debit}|${l.credit}`).digest("hex");
    return `(${lit(l.code)}, ${lit(l.code)}, ${lit(l.name)},` +
      ` ${lit(l.debit)}::numeric, ${lit(l.credit)}::numeric, ${lit(lineSha)})`;
  }).join(",\n           ");

  exec(`BEGIN;
        ${fenceSql(j)}
        UPDATE import_batch SET status='VALIDATING' WHERE import_batch_id = ${lit(j.import_batch_id)}::uuid;
        UPDATE import_batch SET hash_verified=true WHERE import_batch_id = ${lit(j.import_batch_id)}::uuid;
        WITH ds AS (
          INSERT INTO source_dataset (tenant_id, import_batch_id, batch_version, granularity,
                  content_sha256, row_count)
          VALUES (${lit(j.tenant_id)}::uuid, ${lit(j.import_batch_id)}::uuid, ${j.batch_version},
                  'BALANCE', ${lit(r.sha)}, ${r.lines.length})
          RETURNING source_dataset_id AS id
        )
        INSERT INTO source_ledger_line (tenant_id, source_dataset_id, import_batch_id,
                source_row_id, account_code, account_name, debit, credit, content_sha256)
        SELECT ${lit(j.tenant_id)}::uuid, ds.id, ${lit(j.import_batch_id)}::uuid,
               v.source_row_id, v.account_code, v.account_name, v.debit, v.credit, v.content_sha256
          FROM ds, (VALUES
           ${lineRows}
        ) AS v(source_row_id, account_code, account_name, debit, credit, content_sha256);
        INSERT INTO data_coverage (tenant_id, import_batch_id, batch_version, granularity, completeness_status)
        VALUES (${lit(j.tenant_id)}::uuid, ${lit(j.import_batch_id)}::uuid, ${j.batch_version}, 'BALANCE', 'COMPLETE');
        INSERT INTO source_identity_assessment (tenant_id, import_batch_id, batch_version,
                detected_identity, match_result, evidence_kind, detection_rule_version)
        VALUES (${lit(j.tenant_id)}::uuid, ${lit(j.import_batch_id)}::uuid, ${j.batch_version},
                ${lit(JSON.stringify(r.detectedCode ? [{ kind: "legal_entity_code", value: r.detectedCode }] : []))}::jsonb,
                ${lit(r.result)}, ${lit(r.evidence)}, ${lit(RULE_VERSION)});
        UPDATE import_batch SET identity_status=${lit(r.idStatus)}::identity_status
         WHERE import_batch_id = ${lit(j.import_batch_id)}::uuid;
        ${eventSql(j.tenant_id, "import_batch.identity_assessed", j.import_batch_id,
          { declared: j.declared_code, detected: r.detectedCode, evidence: r.evidence, result: r.result }, "identity")}
        ${quarantineReason
          ? `UPDATE import_batch SET status='QUARANTINED', quarantine_reason=${lit(quarantineReason)}
              WHERE import_batch_id = ${lit(j.import_batch_id)}::uuid;
             ${eventSql(j.tenant_id, "import_batch.quarantined", j.import_batch_id, { reason: quarantineReason }, "quar")}`
          : `UPDATE import_batch SET status='VALIDATED' WHERE import_batch_id = ${lit(j.import_batch_id)}::uuid;
             ${eventSql(j.tenant_id, "import_batch.validated", j.import_batch_id,
               { rows: r.lines.length, identity: r.idStatus }, "valid")}`}
        UPDATE background_job SET status='COMPLETED'
               ${quarantineReason
                 ? `, last_error_class='BUSINESS_VALIDATION',
                    last_error_message=${lit(quarantineReason)}`
                 : ""}
         WHERE job_id = ${lit(j.job_id)}::uuid AND claim_token = ${lit(j.claim_token)}::uuid;
        COMMIT;`, {}, { asRuntime: false });
}

/** 業務裁決：批次隔離、工作視為完成（結論已產生，不是故障）。 */
function commitBusinessRejection(j: Claimed, reason: string): void {
  exec(`BEGIN;
        ${fenceSql(j)}
        UPDATE import_batch SET status='VALIDATING' WHERE import_batch_id = ${lit(j.import_batch_id)}::uuid;
        UPDATE import_batch SET status='QUARANTINED', quarantine_reason=${lit(reason)}
         WHERE import_batch_id = ${lit(j.import_batch_id)}::uuid;
        ${eventSql(j.tenant_id, "import_batch.quarantined", j.import_batch_id, { reason }, "quar")}
        UPDATE background_job SET status='COMPLETED', last_error_class='BUSINESS_VALIDATION',
               last_error_message=${lit(reason)}
         WHERE job_id = ${lit(j.job_id)}::uuid AND claim_token = ${lit(j.claim_token)}::uuid;
        COMMIT;`, {}, { asRuntime: false });
}

/**
 * 執行失敗：批次維持 UPLOADED（不污染業務狀態），只改 job。
 * 失敗寫回同樣受 fencing 約束：必須「持有 token 且租約仍有效」——
 * 租約到期後本 worker 已無權，寫回落空（0 列）時不得靜默當成功，
 * 也不得改任何狀態（新持有者或下一個認領者才有權）。
 */
function recordJobFailure(j: ClaimedCore, cls: JobErrorClass, message: string): void {
  const v = verdictFor(cls, j.attempt_count, j.max_attempts, config.jobBackoffSeconds);
  if (v.next === "NONE") {
    // LEASE_LOST：新持有者才有權，舊 worker 不得改任何狀態
    console.warn(`[worker] 租約已被接手，放棄 job ${j.job_id.slice(0, 8)}`);
    return;
  }
  const msg = message.slice(0, 500);
  const fence = `WHERE job_id = ${lit(j.job_id)}::uuid
                   AND claim_token = ${lit(j.claim_token)}::uuid
                   AND lease_expires_at > now()`;
  const rows = v.next === "RETRY_WAIT"
    ? query<{ ok: number }>(
        `UPDATE background_job
            SET status='RETRY_WAIT', last_error_class=${lit(cls)}::job_error_class,
                last_error_message=${lit(msg)},
                next_attempt_at = now() + interval '${v.backoff} seconds'
          ${fence} RETURNING 1 AS ok`, {}, { asRuntime: false })
    : query<{ ok: number }>(
        `UPDATE background_job
            SET status='FAILED', last_error_class=${lit(cls)}::job_error_class,
                last_error_message=${lit(msg)}
          ${fence} RETURNING 1 AS ok`, {}, { asRuntime: false });
  if (rows.length === 0) {
    console.warn(`[worker] job ${j.job_id.slice(0, 8)} 失敗寫回落空（租約已到期或被接手），` +
      `不改任何狀態，交由下一個認領者處理`);
    return;
  }
  if (v.next === "RETRY_WAIT")
    console.warn(`[worker] job ${j.job_id.slice(0, 8)} 第 ${j.attempt_count} 次失敗（${cls}），` +
      `${v.backoff}s 後重試：${msg.slice(0, 120)}`);
  else
    console.error(`[worker] job ${j.job_id.slice(0, 8)} 終止（${cls}）：${msg.slice(0, 200)}　` +
      `批次維持 UPLOADED，不需重新上傳`);
}

// ═══════════ CALCULATION_RUN（SLICE-M2-02B） ═══════════
// 契約：docs/slices/SLICE-M2-02B_PREVIEW_CalculationRun與輸入凍結.md
//   計算只讀 Manifest 凍結內容（INV-29）；結果、Run 終態、Job 終態、完成事件同一交易；
//   可重試失敗期間 Run 保持 RUNNING，耗盡才與 Job 同交易進入失敗終態（護欄 3）。

interface ClaimedCalc extends ClaimedCore { manifest_id: string; replay_of_run_id: string | null }

function loadCalcDetail(c: ClaimedCore): ClaimedCalc {
  const [r] = query<{ manifest_id: string; replay_of_run_id: string | null }>(
    `SELECT manifest_id, replay_of_run_id FROM calculation_run
      WHERE calculation_run_id = ${lit(c.subject_id)}::uuid`, {}, { asRuntime: false });
  return { ...c, ...r };
}

/**
 * 單一交易：完整性驗證（INV-29）→ 從凍結 payload 計算 → 快照 → G-09 → result hash
 * →（replay 時）與原 run 比對 → Run COMPLETED ＋ Job COMPLETED ＋ 完成事件。
 * 任一 fn_assert 失敗即整筆回滾——不留半套輸出。
 */
function commitCalcResult(j: ClaimedCalc): void {
  const RUN = lit(j.subject_id);
  const M = lit(j.manifest_id);
  const T = lit(j.tenant_id);
  const replayCompare = j.replay_of_run_id
    ? `SELECT fn_assert(
         (SELECT result_content_hash FROM calculation_run
           WHERE calculation_run_id = ${lit(j.replay_of_run_id)}::uuid) = (SELECT h FROM _res),
         'RESULT_MISMATCH：重演結果雜湊與原 run 不一致');`
    : "";
  exec(`BEGIN;
        ${fenceSql(j)}
        -- 交易一開始鎖 Run（0014①）：外部快照寫入在本交易期間阻塞於此鎖，
        -- 終態提交後重讀即被拒——「算完 hash、尚未終態」的間隙不存在。
        WITH runlock AS (
          SELECT status FROM calculation_run
           WHERE calculation_run_id = ${RUN}::uuid FOR UPDATE)
        SELECT fn_assert((SELECT status = 'RUNNING' FROM runlock), 'RUN_NOT_RUNNING');

        -- 白名單 fail closed（0014 小項②）：未知版本不得落入任何預設分支
        SELECT fn_assert((SELECT hash_algorithm = 'sha256'
            AND canonicalization_version IN ('sqlcanon-1','sqlcanon-2')
          FROM calculation_input_manifest WHERE manifest_id = ${M}::uuid),
          'REPLAY_FAILED:UNKNOWN_CANONICALIZATION_OR_ALGORITHM');

        -- INV-29：凍結內容存在且逐筆雜湊相符——依 manifest 記錄的標準化版本分流驗證
        -- （INT-e3）。v2 涵蓋 canonical＋payload：計算實際讀 payload，兩者都要驗。
        SELECT fn_assert((SELECT count(*) FROM calculation_manifest_entry
          WHERE manifest_id = ${M}::uuid) > 0, 'REPLAY_FAILED:MANIFEST_EMPTY');
        SELECT fn_assert(NOT EXISTS (
          SELECT 1 FROM calculation_manifest_entry e
            JOIN calculation_input_manifest m ON m.manifest_id = e.manifest_id
           WHERE e.manifest_id = ${M}::uuid
             AND encode(sha256(convert_to(
                   CASE WHEN m.canonicalization_version = 'sqlcanon-1'
                        THEN e.content_canonical
                        ELSE e.content_canonical || E'\n' || e.payload::text END,'UTF8')),'hex')
                 <> e.content_hash),
          'REPLAY_FAILED:CONTENT_HASH_MISMATCH');
        -- 集合層：重算 frozen_set_content_hash——偵測 entry 集合被擴充或抽換
        SELECT fn_assert(
          (SELECT frozen_set_content_hash FROM calculation_input_manifest
            WHERE manifest_id = ${M}::uuid)
          = encode(sha256(convert_to((SELECT string_agg(content_hash, E'\n' ORDER BY content_canonical)
              FROM calculation_manifest_entry WHERE manifest_id = ${M}::uuid),'UTF8')),'hex'),
          'REPLAY_FAILED:SET_HASH_MISMATCH');

        -- 只讀凍結 payload；不回查 mapping_rule／account／source_ledger_line（INV-29）
        CREATE TEMP TABLE _src ON COMMIT DROP AS
          SELECT x->>'code' AS code, x->>'name' AS name,
                 (x->>'debit')::numeric AS debit, (x->>'credit')::numeric AS credit
            FROM calculation_manifest_entry e, jsonb_array_elements(e.payload) x
           WHERE e.manifest_id = ${M}::uuid AND e.object_type = 'SOURCE_TB';
        CREATE TEMP TABLE _m ON COMMIT DROP AS
          SELECT payload->>'source_code' AS source_code,
                 (payload->>'target_account_id')::uuid AS target_account_id,
                 payload->>'target_code' AS target_code, payload->>'target_name' AS target_name
            FROM calculation_manifest_entry
           WHERE manifest_id = ${M}::uuid AND object_type = 'MAPPING_RULE';
        SELECT fn_assert(NOT EXISTS (
          SELECT 1 FROM _src s LEFT JOIN _m m ON m.source_code = s.code
           WHERE m.source_code IS NULL), 'REPLAY_FAILED:MAPPING_INCOMPLETE');

        INSERT INTO balance_snapshot_line
          (tenant_id, calculation_run_id, posting_layer, account_id, account_code, account_name, debit, credit)
        SELECT ${T}::uuid, ${RUN}::uuid, 'SOURCE_TB', m.target_account_id, m.target_code,
               MAX(m.target_name), SUM(s.debit), SUM(s.credit)
          FROM _src s JOIN _m m ON m.source_code = s.code
         GROUP BY m.target_account_id, m.target_code;
        INSERT INTO balance_snapshot_line
          (tenant_id, calculation_run_id, posting_layer, account_id, account_code, account_name, debit, credit)
        SELECT ${T}::uuid, ${RUN}::uuid, 'ADJUSTMENT', (l->>'account_id')::uuid, l->>'code',
               MAX(l->>'name'), SUM((l->>'debit')::numeric), SUM((l->>'credit')::numeric)
          FROM calculation_manifest_entry e, jsonb_array_elements(e.payload->'lines') l
         WHERE e.manifest_id = ${M}::uuid AND e.object_type = 'ADJUSTMENT'
         GROUP BY (l->>'account_id')::uuid, l->>'code';

        -- G-09 控制總額：來源層＝凍結 TB 合計；調整層＝凍結分錄合計；整體借貸平衡
        SELECT fn_assert(
          (SELECT COALESCE(SUM(debit),0)::text||'|'||COALESCE(SUM(credit),0)::text
             FROM balance_snapshot_line WHERE calculation_run_id = ${RUN}::uuid AND posting_layer='SOURCE_TB')
          = (SELECT COALESCE(SUM(debit),0)::text||'|'||COALESCE(SUM(credit),0)::text FROM _src),
          'CONTROL_TOTAL_MISMATCH:SOURCE');
        SELECT fn_assert(
          (SELECT COALESCE(SUM(debit),0)::text||'|'||COALESCE(SUM(credit),0)::text
             FROM balance_snapshot_line WHERE calculation_run_id = ${RUN}::uuid AND posting_layer='ADJUSTMENT')
          = (SELECT COALESCE(SUM((l->>'debit')::numeric),0)::text||'|'||COALESCE(SUM((l->>'credit')::numeric),0)::text
               FROM calculation_manifest_entry e, jsonb_array_elements(e.payload->'lines') l
              WHERE e.manifest_id = ${M}::uuid AND e.object_type = 'ADJUSTMENT'),
          'CONTROL_TOTAL_MISMATCH:ADJUSTMENT');
        SELECT fn_assert(
          (SELECT COALESCE(SUM(debit),0) = COALESCE(SUM(credit),0)
             FROM balance_snapshot_line WHERE calculation_run_id = ${RUN}::uuid),
          'CONTROL_TOTAL_MISMATCH:UNBALANCED');

        -- canonical 結果 hash：排序後的（層｜科目｜借｜貸），排除 run_id 與時間戳
        CREATE TEMP TABLE _res ON COMMIT DROP AS
          SELECT encode(sha256(convert_to(COALESCE(
                   string_agg(posting_layer||'|'||account_code||'|'||debit::text||'|'||credit::text,
                              E'\n' ORDER BY posting_layer, account_code), ''),'UTF8')),'hex') AS h
            FROM balance_snapshot_line WHERE calculation_run_id = ${RUN}::uuid;
        ${replayCompare}

        UPDATE calculation_run SET status='COMPLETED', result_content_hash=(SELECT h FROM _res)
         WHERE calculation_run_id = ${RUN}::uuid;
        UPDATE background_job SET status='COMPLETED'
         WHERE job_id = ${lit(j.job_id)}::uuid AND claim_token = ${lit(j.claim_token)}::uuid;
        ${eventSql(j.tenant_id, "calculation_run.completed", j.subject_id,
          { replay_of: j.replay_of_run_id, attempts: j.attempt_count }, "done", "calculation_run")}
        COMMIT;`, {}, { asRuntime: false });
}

/** 確定性失敗（REPLAY_FAILED 等）＝結論：Run FAILED ＋ Job COMPLETED ＋ 事件，同一交易。 */
function commitCalcVerdictFailure(j: ClaimedCalc, message: string): void {
  const code = reasonCodeOf(message) ?? "REPLAY_FAILED";
  const human = `${RUN_REASON[code]}（${message.slice(0, 300)}）`;
  exec(`BEGIN;
        ${fenceSql(j)}
        UPDATE calculation_run SET status='FAILED',
               failure_reason_code=${lit(code)}, failure_reason=${lit(human)}
         WHERE calculation_run_id = ${lit(j.subject_id)}::uuid AND status='RUNNING';
        UPDATE background_job SET status='COMPLETED', last_error_class='BUSINESS_VALIDATION',
               last_error_message=${lit(human.slice(0, 500))}
         WHERE job_id = ${lit(j.job_id)}::uuid AND claim_token = ${lit(j.claim_token)}::uuid;
        ${eventSql(j.tenant_id, "calculation_run.failed", j.subject_id,
          { code, reason: human.slice(0, 300) }, "fail", "calculation_run")}
        COMMIT;`, {}, { asRuntime: false });
  console.warn(`[worker] calc run ${j.subject_id.slice(0, 8)} 確定性失敗（${code}）`);
}

/**
 * 基礎設施故障：RETRY_WAIT 只改 job（Run 保持 RUNNING）；
 * 耗盡或系統性錯誤 → Run FAILED ＋ Job FAILED ＋ 事件，同一交易（護欄 3）。
 */
function recordCalcInfraFailure(j: ClaimedCalc, cls: JobErrorClass, message: string): void {
  const v = verdictFor(cls, j.attempt_count, j.max_attempts, config.jobBackoffSeconds);
  if (v.next !== "FAILED") { recordJobFailure(j, cls, message); return; }
  const code = cls === "NON_RETRYABLE_SYSTEM" ? "NON_RETRYABLE_SYSTEM" : "INFRA_RETRY_EXHAUSTED";
  const msg = message.slice(0, 500);
  try {
    exec(`BEGIN;
          ${fenceSql(j)}
          UPDATE background_job SET status='FAILED', last_error_class=${lit(cls)}::job_error_class,
                 last_error_message=${lit(msg)}
           WHERE job_id = ${lit(j.job_id)}::uuid AND claim_token = ${lit(j.claim_token)}::uuid;
          UPDATE calculation_run SET status='FAILED',
                 failure_reason_code=${lit(code)},
                 failure_reason=${lit(`${RUN_REASON[code as "INFRA_RETRY_EXHAUSTED"]}（${msg.slice(0, 200)}）`)}
           WHERE calculation_run_id = ${lit(j.subject_id)}::uuid AND status='RUNNING';
          ${eventSql(j.tenant_id, "calculation_run.failed", j.subject_id,
            { code, reason: msg.slice(0, 200), attempts: j.attempt_count }, "fail", "calculation_run")}
          COMMIT;`, {}, { asRuntime: false });
    console.error(`[worker] calc run ${j.subject_id.slice(0, 8)} 終止（${code}）：${msg.slice(0, 160)}`);
  } catch (e2) {
    console.warn(`[worker] calc 失敗寫回落空（${String(e2).slice(0, 120)}），交由下一個認領者`);
  }
}

function runCalculation(c: ClaimedCore): void {
  const j = loadCalcDetail(c);
  try {
    commitCalcResult(j);
  } catch (e) {
    const msg = String(e);
    if (msg.includes("LEASE_LOST")) { recordJobFailure(j, "LEASE_LOST", msg); return; }
    if (isDeterministicRunFailure(msg)) {
      try { commitCalcVerdictFailure(j, msg); }
      catch (e2) { recordCalcInfraFailure(j, classifyError(e2), String(e2)); }
      return;
    }
    recordCalcInfraFailure(j, classifyError(e), msg);
  }
}

// ═══════════ EVIDENCE_PACKAGE（SLICE-M2-02C） ═══════════
// 契約：docs/slices/SLICE-M2-02C_預覽證據包.md（實作契約 A～D）
//   交易外：讀不可變資料組節、計算逐節與整包 hash、渲染 HTML → staging（契約 B）
//   終態交易：契約 D 驗證 → 索引＋artifact 登記＋Package READY＋Job 終態＋事件

interface ClaimedPkg extends ClaimedCore {
  package_id: string; calculation_run_id: string; manifest_id: string;
  engagement_id: string; import_batch_id: string; render_version: string;
  audit_cutoff_event_id: string; result_content_hash: string;
}

function loadPkgDetail(c: ClaimedCore): ClaimedPkg {
  const [r] = query<Omit<ClaimedPkg, keyof ClaimedCore | "package_id">>(
    `SELECT p.calculation_run_id, p.engagement_id, p.render_version,
            p.audit_cutoff_event_id, r.manifest_id, r.import_batch_id, r.result_content_hash
       FROM evidence_package p
       JOIN calculation_run r ON r.calculation_run_id = p.calculation_run_id
      WHERE p.package_id = ${lit(c.subject_id)}::uuid`, {}, { asRuntime: false });
  return { ...c, ...r, package_id: c.subject_id };
}

const sha256hex = (b: Buffer | string): string =>
  createHash("sha256").update(b).digest("hex");
const esc2 = (s: unknown) => String(s ?? "").replace(/[&<>"]/g,
  (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[ch] as string));

interface Section { name: string; title: string; headers: string[]; rows: string[][] }
interface BuiltPackage {
  sections: { name: string; count: number; hash: string }[];
  packageContentHash: string;
  html: Buffer;
  artifactSha256: string;
}

function renderSection(s: Section, hash: string): string {
  const pad = (r: string[]) => [...r, ...Array(Math.max(0, s.headers.length - r.length)).fill("")];
  return `<h2>${esc2(s.title)}（§hash ${esc2(hash.slice(0, 12))}）</h2>
<table><tr>${s.headers.map((h) => `<th>${esc2(h)}</th>`).join("")}</tr>
${s.rows.map((r) => `<tr>${pad(r).map((c) => `<td>${esc2(c)}</td>`).join("")}</tr>`).join("\n")}</table>`;
}

const TRACE_LABEL: Record<string, string> = {
  BALANCE: "BALANCE（餘額級）", JOURNAL: "JOURNAL（分錄級）",
  SUBLEDGER: "SUBLEDGER（明細級）", DOCUMENT: "DOCUMENT（憑證級）",
  UNKNOWN: "UNKNOWN（無法判定）",
};

/** 交易外：全部讀不可變／凍結資料，不查 current（INV-29 同一精神）。 */
function buildPackage(j: ClaimedPkg): BuiltPackage {
  const q = <T = Record<string, string>>(sql: string) => query<T>(sql, {}, { asRuntime: false });
  const M = lit(j.manifest_id); const RUN = lit(j.calculation_run_id);
  const B = lit(j.import_batch_id); const T = lit(j.tenant_id);

  const batch = q(`SELECT batch_version::text, COALESCE(file_sha256,'') AS file_sha256
                     FROM import_batch WHERE import_batch_id = ${B}::uuid`)[0];
  // 凍結來源的 batch_version：讀 Manifest SOURCE_TB entry（不信任任何 current 值）
  const frozenBv = q(`SELECT domain_version_value AS bv FROM calculation_manifest_entry
                       WHERE manifest_id = ${M}::uuid AND object_type='SOURCE_TB'`)[0]?.bv ?? batch.batch_version;
  const srcTb = q(`SELECT x->>'code' AS code, COALESCE(x->>'name','') AS name,
                          x->>'debit' AS debit, x->>'credit' AS credit
                     FROM calculation_manifest_entry e, jsonb_array_elements(e.payload) x
                    WHERE e.manifest_id = ${M}::uuid AND e.object_type='SOURCE_TB'
                    ORDER BY x->>'code'`);
  // dataset join 帶 granularity 條件——多粒度時不得配錯 dataset hash（P1-②）
  const coverage = q(`SELECT dc.data_coverage_id::text AS id, dc.account_scope, dc.granularity,
                             dc.completeness_status, sd.source_dataset_id::text AS dataset_id,
                             sd.content_sha256 AS dataset_sha
                        FROM data_coverage dc
                        JOIN source_dataset sd ON sd.import_batch_id = dc.import_batch_id
                         AND sd.batch_version = dc.batch_version
                         AND sd.granularity = dc.granularity
                       WHERE dc.import_batch_id = ${B}::uuid
                         AND dc.batch_version = ${lit(frozenBv)}::int
                       ORDER BY dc.data_coverage_id`);
  const mappings = q(`SELECT e.payload->>'source_code' AS source_code,
                             e.payload->>'version_no' AS version_no,
                             COALESCE(e.payload->>'effective_from','-') AS eff_from,
                             COALESCE(e.payload->>'effective_to','-') AS eff_to,
                             e.payload->>'target_code' AS target_code,
                             e.payload->>'target_name' AS target_name,
                             COALESCE(e.payload->>'created_by_name','') AS created_by_name,
                             COALESCE(e.payload->>'approved_by_name','') AS approved_by_name,
                             COALESCE(e.payload->>'approved_at','') AS approved_at
                        FROM calculation_manifest_entry e
                       WHERE e.manifest_id = ${M}::uuid AND e.object_type='MAPPING_RULE'
                       ORDER BY e.payload->>'source_code'`);
  const adjustments = q(`SELECT e.object_id::text AS adjustment_id,
                             e.payload->>'business_version' AS business_version,
                             e.payload->>'title' AS title, (e.payload->'lines')::text AS lines,
                             COALESCE(a.legal_basis,'') AS legal_basis,
                             COALESCE(a.evidence_ref,'') AS evidence_ref,
                             COALESCE(a.judgment_reason,'') AS judgment_reason,
                             COALESCE(a.language_tag,'') AS language_tag,
                             COALESCE(e.payload->>'prepared_by_name','') AS prepared_by,
                             COALESCE(e.payload->>'prepared_at','') AS prepared_at,
                             COALESCE(e.payload->>'reviewed_by_name','') AS reviewed_by,
                             COALESCE(e.payload->>'reviewed_at','') AS reviewed_at,
                             COALESCE(e.payload->>'approved_by_name','') AS approved_by,
                             COALESCE(e.payload->>'approved_at','') AS approved_at
                        FROM calculation_manifest_entry e
                        JOIN adjustment a ON a.adjustment_id = e.object_id
                       WHERE e.manifest_id = ${M}::uuid AND e.object_type='ADJUSTMENT'
                       ORDER BY e.object_id`);
  const manifest = q(`SELECT calculation_scope, hash_algorithm, canonicalization_version,
                             frozen_set_content_hash
                        FROM calculation_input_manifest WHERE manifest_id = ${M}::uuid`)[0];
  const snapshot = q(`SELECT posting_layer, account_code, account_name,
                             debit::text AS debit, credit::text AS credit
                        FROM balance_snapshot_line WHERE calculation_run_id = ${RUN}::uuid
                       ORDER BY account_code, posting_layer`);
  const objIds = [j.calculation_run_id, j.import_batch_id,
    ...q(`SELECT DISTINCT object_id::text AS id FROM calculation_manifest_entry
           WHERE manifest_id = ${M}::uuid AND object_id IS NOT NULL`).map((r) => r.id)];
  // audit_event_id 為 bigint：一律以十進位字串傳遞並 ::bigint，不經 Number()（P2）
  const events = q(`SELECT audit_event_id::text AS id, event_type, object_type,
                           object_id::text AS object_id
                      FROM audit_event
                     WHERE tenant_id = ${T}::uuid AND kind='DOMAIN_EVENT'
                       AND audit_event_id <= ${lit(j.audit_cutoff_event_id)}::bigint
                       AND object_id IN (${objIds.map(lit).join("::uuid,")}::uuid)
                     ORDER BY audit_event_id`);
  const docs = q(`SELECT file_name, content_sha256, object_key, byte_size::text AS byte_size
                    FROM source_document WHERE import_batch_id = ${B}::uuid
                   ORDER BY source_document_id`);

  // 追溯判定：真實 lineage——輸出科目 → 映射來源科目 → coverage（精確優先、弱鏈決定等級）
  const tbCodes = new Set(srcTb.map((l) => l.code));
  const byTarget = new Map<string, string[]>();
  for (const m of mappings) {
    if (!tbCodes.has(m.source_code)) continue;
    byTarget.set(m.target_code, [...(byTarget.get(m.target_code) ?? []), m.source_code]);
  }
  const outputs = [...new Set(snapshot.map((s) => s.account_code))].sort()
    .map((code) => ({ outputCode: code, sourceCodes: byTarget.get(code) ?? [] }));
  const trace = resolveTraceability(outputs, coverage.map((c) => ({
    id: c.id, accountScope: c.account_scope,
    granularity: c.granularity as "BALANCE" | "JOURNAL" | "SUBLEDGER" | "DOCUMENT",
    completeness: c.completeness_status as "COMPLETE" | "PARTIAL" | "UNKNOWN" })));

  const sections: Section[] = [
    { name: "source", title: "來源", headers: ["類型", "識別", "欄位A", "欄位B", "欄位C", "欄位D", "欄位E"],
      rows: [["批次", j.import_batch_id, `v${batch.batch_version}`, `sha=${batch.file_sha256}`],
        ...srcTb.map((l) => ["TB科目", l.code, l.name, l.debit, l.credit]),
        ...coverage.map((c) => ["涵蓋", c.id, c.account_scope, c.granularity,
          c.completeness_status, `dataset=${c.dataset_id}`, c.dataset_sha])] },
    { name: "mapping", title: "映射",
      headers: ["來源科目", "版本", "生效", "失效", "集團科目", "集團科目名稱", "建立者", "批准者", "批准時間"],
      rows: mappings.map((m) => [m.source_code, `v${m.version_no}`, m.eff_from, m.eff_to,
        m.target_code, m.target_name, m.created_by_name, m.approved_by_name, m.approved_at]) },
    { name: "adjustment", title: "調整", headers: ["調整", "欄位", "值"],
      rows: adjustments.flatMap((a) => {
        const id8 = a.adjustment_id.slice(0, 8);
        return [[id8, "標題", `${a.title}（bv${a.business_version}）`],
          [id8, "法源／政策", a.legal_basis], [id8, "附件", a.evidence_ref],
          [id8, "判斷理由", a.judgment_reason], [id8, "語言標籤", a.language_tag],
          [id8, "編製", `${a.prepared_by}＠${a.prepared_at}`],
          [id8, "覆核", `${a.reviewed_by}＠${a.reviewed_at}`],
          [id8, "批准", `${a.approved_by}＠${a.approved_at}`],
          [id8, "分錄", a.lines]];
      }) },
    { name: "calculation", title: "計算", headers: ["層", "集團科目", "名稱", "借方", "貸方"],
      rows: [["META", "frozen_set_content_hash", manifest.frozen_set_content_hash],
        ["META", "result_content_hash", j.result_content_hash],
        ...snapshot.map((s) => [s.posting_layer, s.account_code, s.account_name, s.debit, s.credit])] },
    { name: "rule_versions", title: "規則版本", headers: ["項目"],
      rows: [[`engine=calc-engine-1`], [`canonicalization=${manifest.canonicalization_version}`],
        [`detect=detect-r1`], ["RuleVersion 實體＝未實作（如實標示）"]] },
    { name: "process_level", title: "流程等級", headers: ["項目"],
      rows: [["PREVIEW"], ["期間包批准＝未完成"], ["月次／季次流程分級＝未實作（如實標示）"]] },
    { name: "control_exceptions", title: "控制例外", headers: ["項目"],
      rows: [["未折算（NO_FX，折算屬 MVP 3）"], ["無正式覆核與期間批准（PREVIEW）"], ["其餘控制例外＝未評估"]] },
    { name: "traceability", title: "追溯判定（逐科目範圍；AC-AUD-001）",
      headers: ["集團科目", "data_coverage_id", "追溯等級", "完整度"],
      rows: trace.map((t) => [t.outputCode, t.coverageIds.join("；") || "—",
        TRACE_LABEL[t.level], t.completeness]) },
    { name: "events", title: `事件時間軸（≤ cutoff ${j.audit_cutoff_event_id}）`,
      headers: ["#", "事件", "物件類型", "物件"],
      rows: events.map((e) => [e.id, e.event_type, e.object_type, e.object_id.slice(0, 8)]) },
    { name: "attachments", title: "附件索引", headers: ["檔名", "SHA-256", "object key", "bytes"],
      rows: docs.map((d) => [d.file_name, d.content_sha256, d.object_key, d.byte_size]) },
  ];
  const hashed = sections.map((s) => ({ name: s.name, count: s.rows.length,
    hash: sha256hex(sectionCanonical(s.headers, s.rows)) }));
  // aggregate 公式與 0016 READY 守衛一致：section|hash 依節名 byte 序聚合
  const packageContentHash = sha256hex(
    [...hashed].sort((a, b) => (a.name < b.name ? -1 : 1))
      .map((s) => `${s.name}|${s.hash}`).join("\n"));

  const warn = "DRAFT・UNREVIEWED・未折算（NO_FX）——非正式輸出，不得作為入帳或交付依據";
  const td = (r: string[]) => `<tr>${r.map((x) => `<td>${esc2(x)}</td>`).join("")}</tr>`;
  const html = Buffer.from(`<!DOCTYPE html><html lang="zh-Hant"><meta charset="utf-8">
<title>PREVIEW 證據包（run ${esc2(j.calculation_run_id.slice(0, 8))}）</title>
<style>body{font-family:sans-serif;margin:24px;color:#1b1f24}table{border-collapse:collapse;margin:8px 0}
th,td{border:1px solid #ccc;padding:4px 8px;font-size:13px}h2{margin-top:24px}
.warn{background:#fff3e0;border:2px solid #d9a05b;padding:12px;font-weight:700}</style>
<div class="warn">${esc2(warn)}</div>
<h1>預覽證據包（底稿）</h1>
<table>${td(["run", j.calculation_run_id])}${td(["manifest frozen hash", manifest.frozen_set_content_hash])}
${td(["result hash", j.result_content_hash])}${td(["package_content_hash", packageContentHash])}
${td(["render_version", j.render_version])}${td(["audit_cutoff_event_id", j.audit_cutoff_event_id])}
${td(["calculation_scope", manifest.calculation_scope])}</table>
<p>追溯等級依實際 DataCoverage <b>逐科目範圍</b>判定（見「追溯判定」節）；各範圍不得宣稱高於所列等級。</p>
${sections.map((s, i) => renderSection(s, hashed[i].hash)).join("\n")}
<h2>逐節 hash 對照表</h2>
<table><tr><th>節</th><th>筆數</th><th>content hash</th></tr>
${hashed.map((s) => td([s.name, String(s.count), s.hash])).join("")}</table>
<div class="warn">${esc2(warn)}</div></html>`, "utf8");

  // 契約 D-3（JS 端斷言）：artifact 必須內嵌與索引一致的逐節 hash
  for (const s of hashed)
    if (!html.includes(s.hash)) throw new Error(`UPSTREAM_VERIFY_FAILED:SECTION_HASH_NOT_EMBEDDED:${s.name}`);
  return { sections: hashed, packageContentHash, html, artifactSha256: sha256hex(html) };
}

/** 契約 B：write-once staging——已存在則核對 hash，同沿用、異即確定性失敗。 */
function stagePut(key: string, html: Buffer, wantSha: string): void {
  try { putObject(key, html); } catch (e) {
    if (!String(e).includes("不可覆寫")) throw e;
    const existing = getObject(key);
    if (stagingVerdict(sha256hex(existing), wantSha) === "CONFLICT")
      throw new Error("ARTIFACT_CONFLICT：staging 物件已存在且內容不符");
  }
}

function commitPackage(j: ClaimedPkg, b: BuiltPackage, key: string): void {
  const P = lit(j.package_id); const M = lit(j.manifest_id); const RUN = lit(j.calculation_run_id);
  const idxRows = b.sections.map((s) =>
    `(${lit(j.tenant_id)}::uuid, ${P}::uuid, ${lit(s.name)}, ${s.count}, ${lit(s.hash)})`).join(",\n");
  exec(`BEGIN;
        ${fenceSql(j)}
        WITH pkglock AS (
          SELECT status FROM evidence_package WHERE package_id = ${P}::uuid FOR UPDATE)
        SELECT fn_assert((SELECT status = 'GENERATING' FROM pkglock), 'PKG_NOT_GENERATING');
        -- 契約 D-1：Manifest 逐筆＋集合 hash（02B 同式，版本感知）
        SELECT fn_assert(NOT EXISTS (
          SELECT 1 FROM calculation_manifest_entry e
            JOIN calculation_input_manifest m ON m.manifest_id = e.manifest_id
           WHERE e.manifest_id = ${M}::uuid
             AND encode(sha256(convert_to(
                   CASE WHEN m.canonicalization_version = 'sqlcanon-1'
                        THEN e.content_canonical
                        ELSE e.content_canonical || E'\n' || e.payload::text END,'UTF8')),'hex')
                 <> e.content_hash),
          'UPSTREAM_VERIFY_FAILED:MANIFEST_ENTRY_HASH');
        SELECT fn_assert(
          (SELECT frozen_set_content_hash FROM calculation_input_manifest WHERE manifest_id = ${M}::uuid)
          = encode(sha256(convert_to((SELECT string_agg(content_hash, E'\n' ORDER BY content_canonical)
              FROM calculation_manifest_entry WHERE manifest_id = ${M}::uuid),'UTF8')),'hex'),
          'UPSTREAM_VERIFY_FAILED:MANIFEST_SET_HASH');
        -- 契約 D-2：快照重算 ＝ run.result_content_hash
        SELECT fn_assert(
          (SELECT result_content_hash FROM calculation_run WHERE calculation_run_id = ${RUN}::uuid)
          = (SELECT encode(sha256(convert_to(COALESCE(string_agg(
               posting_layer||'|'||account_code||'|'||debit::text||'|'||credit::text,
               E'\n' ORDER BY posting_layer, account_code),''),'UTF8')),'hex')
               FROM balance_snapshot_line WHERE calculation_run_id = ${RUN}::uuid),
          'UPSTREAM_VERIFY_FAILED:SNAPSHOT_HASH_MISMATCH');
        -- 契約 D-4：cutoff 事件屬於該 run
        SELECT fn_assert(EXISTS (
          SELECT 1 FROM audit_event
           WHERE audit_event_id = ${lit(j.audit_cutoff_event_id)}::bigint
             AND event_type = 'calculation_run.completed'
             AND object_id = ${RUN}::uuid),
          'UPSTREAM_VERIFY_FAILED:CUTOFF_EVENT');
        INSERT INTO evidence_package_index (tenant_id, package_id, section, item_count, content_hash)
        VALUES ${idxRows};
        UPDATE evidence_package SET status='READY',
               package_content_hash=${lit(b.packageContentHash)},
               artifact_object_key=${lit(key)}, artifact_sha256=${lit(b.artifactSha256)},
               artifact_mime_type='text/html; charset=utf-8', artifact_byte_size=${b.html.length}
         WHERE package_id = ${P}::uuid;
        UPDATE background_job SET status='COMPLETED'
         WHERE job_id = ${lit(j.job_id)}::uuid AND claim_token = ${lit(j.claim_token)}::uuid;
        ${eventSql(j.tenant_id, "evidence_package.completed", j.package_id,
          { run: j.calculation_run_id, package_content_hash: b.packageContentHash }, "done", "evidence_package")}
        COMMIT;`, {}, { asRuntime: false });
}

function commitPkgVerdictFailure(j: ClaimedPkg, message: string): void {
  const code = pkgReasonCodeOf(message) ?? "UPSTREAM_VERIFY_FAILED";
  const human = `${PKG_REASON[code]}（${message.slice(0, 300)}）`;
  exec(`BEGIN;
        ${fenceSql(j)}
        UPDATE evidence_package SET status='FAILED',
               failure_reason_code=${lit(code)}, failure_reason=${lit(human)}
         WHERE package_id = ${lit(j.package_id)}::uuid AND status='GENERATING';
        UPDATE background_job SET status='COMPLETED', last_error_class='BUSINESS_VALIDATION',
               last_error_message=${lit(human.slice(0, 500))}
         WHERE job_id = ${lit(j.job_id)}::uuid AND claim_token = ${lit(j.claim_token)}::uuid;
        ${eventSql(j.tenant_id, "evidence_package.failed", j.package_id,
          { code, reason: human.slice(0, 300) }, "fail", "evidence_package")}
        COMMIT;`, {}, { asRuntime: false });
  console.warn(`[worker] package ${j.package_id.slice(0, 8)} 確定性失敗（${code}）`);
}

function recordPkgInfraFailure(j: ClaimedPkg, cls: JobErrorClass, message: string): void {
  const v = verdictFor(cls, j.attempt_count, j.max_attempts, config.jobBackoffSeconds);
  if (v.next !== "FAILED") { recordJobFailure(j, cls, message); return; }
  const code = cls === "NON_RETRYABLE_SYSTEM" ? "NON_RETRYABLE_SYSTEM" : "INFRA_RETRY_EXHAUSTED";
  const msg = message.slice(0, 500);
  try {
    exec(`BEGIN;
          ${fenceSql(j)}
          UPDATE background_job SET status='FAILED', last_error_class=${lit(cls)}::job_error_class,
                 last_error_message=${lit(msg)}
           WHERE job_id = ${lit(j.job_id)}::uuid AND claim_token = ${lit(j.claim_token)}::uuid;
          UPDATE evidence_package SET status='FAILED',
                 failure_reason_code=${lit(code)},
                 failure_reason=${lit(`${PKG_REASON[code as "INFRA_RETRY_EXHAUSTED"]}（${msg.slice(0, 200)}）`)}
           WHERE package_id = ${lit(j.package_id)}::uuid AND status='GENERATING';
          ${eventSql(j.tenant_id, "evidence_package.failed", j.package_id,
            { code, reason: msg.slice(0, 200), attempts: j.attempt_count }, "fail", "evidence_package")}
          COMMIT;`, {}, { asRuntime: false });
    console.error(`[worker] package ${j.package_id.slice(0, 8)} 終止（${code}）`);
  } catch (e2) {
    console.warn(`[worker] package 失敗寫回落空（${String(e2).slice(0, 120)}），交由下一個認領者`);
  }
}

function runPackage(c: ClaimedCore): void {
  const j = loadPkgDetail(c);
  try {
    const built = buildPackage(j);
    const key = artifactObjectKey(j.tenant_id, j.package_id, j.render_version);
    stagePut(key, built.html, built.artifactSha256);
    heartbeat(j);
    commitPackage(j, built, key);
  } catch (e) {
    const msg = String(e);
    if (msg.includes("LEASE_LOST")) { recordJobFailure(j, "LEASE_LOST", msg); return; }
    if (isDeterministicPkgFailure(msg)) {
      try { commitPkgVerdictFailure(j, msg); }
      catch (e2) { recordPkgInfraFailure(j, classifyError(e2), String(e2)); }
      return;
    }
    recordPkgInfraFailure(j, classifyError(e), msg);
  }
}

function runJob(j: Claimed): void {
  try {
    const r = evaluate(j);        // 交易外；無 DB 效果
    heartbeat(j);                 // 長時間解析後先確認租約仍在自己手上
    commitResult(j, r);
  } catch (e) {
    if (e instanceof BusinessRejection) {
      try { commitBusinessRejection(j, e.message); }
      catch (e2) { recordJobFailure(j, classifyError(e2), String(e2)); }
      return;
    }
    recordJobFailure(j, classifyError(e), String(e));
  }
}

function tick(): void {
  try {
    for (let i = 0; i < 10; i++) {
      const c = claim();
      if (!c) break;
      if (c.job_type === "CALCULATION_RUN") {
        console.log(`[worker] 計算執行 ${c.subject_id.slice(0, 8)}…（第 ${c.attempt_count} 次）`);
        runCalculation(c);
      } else if (c.job_type === "EVIDENCE_PACKAGE") {
        console.log(`[worker] 產生證據包 ${c.subject_id.slice(0, 8)}…（第 ${c.attempt_count} 次）`);
        runPackage(c);
      } else {
        console.log(`[worker] 驗證批次 ${c.subject_id.slice(0, 8)}…（第 ${c.attempt_count} 次）`);
        runJob(loadImportDetail(c));
      }
    }
  } catch (e) { console.error("[worker]", String(e)); }
}

console.log(`worker polling every ${INTERVAL}ms（lease ${LEASE}s, max ${config.jobMaxAttempts} attempts）`);
setInterval(tick, INTERVAL);
tick();
