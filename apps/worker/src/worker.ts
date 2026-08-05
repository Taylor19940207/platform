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
import { config } from "../../../packages/config/src/index.ts";

const INTERVAL = config.pollMs;
const RULE_VERSION = "detect-r1";   // 識別規則版本：寫入每筆評估（CR-002 B-3），亦為 job 冪等鍵之一
const WORKER_ID = `${hostname()}#${process.pid}`;
const LEASE = config.jobLeaseSeconds;

/** 業務裁決：這是結論，不是故障——不重試，直接隔離。 */
class BusinessRejection extends Error {}

interface ClaimedCore {
  job_id: string; claim_token: string; attempt_count: number; max_attempts: number;
  tenant_id: string; job_type: "IMPORT_VALIDATION" | "CALCULATION_RUN";
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
         WHERE job_type IN ('IMPORT_VALIDATION','CALCULATION_RUN')
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
        VALUES (${lit(j.tenant_id)}::uuid, ${lit(j.import_batch_id)}::uuid, ${j.batch_version}, 'BALANCE', 'UNKNOWN');
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
        SELECT fn_assert((SELECT status = 'RUNNING' FROM calculation_run
          WHERE calculation_run_id = ${RUN}::uuid), 'RUN_NOT_RUNNING');

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
