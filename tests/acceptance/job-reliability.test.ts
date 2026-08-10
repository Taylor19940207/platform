// SLICE-M2-03 端到端驗收：背景工作可靠性。
// 契約：docs/slices/SLICE-M2-03_背景工作可靠性.md
// 可觀察性：docs/adr/ADR-M2-002.md（VALIDATING 為交易內狀態，進度以 BackgroundJob 為權威）
//
// 租約參數在此縮短（JOB_LEASE_SECONDS 等），驗收的是比例、狀態與行為，
// 不是讓測試真的等四分鐘。
import { spawn, execSync, type ChildProcess } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { raw } from "../../packages/database/src/psql.ts";

const API = "http://127.0.0.1:8094";
const U_JIA = "aaaaaaaa-0000-0000-0000-000000000001";
const T1 = "11111111-1111-1111-1111-111111111111";
// R2 代傳時必須指定真正的資料提供者（該案件的有效 R1）
const PROVIDER_R1 = "aaaaaaaa-0000-0000-0000-000000000005";
const ENG_A = "eeeeeeee-0000-0000-0000-000000000001";
const LE_A = "cccccccc-0000-0000-0000-000000000001";
const PR1 = "99999999-0000-0000-0000-000000000001";

// 測試用租約參數：租約 3 秒、退避 1 秒起、最多 3 次
const JOB_ENV = {
  JOB_LEASE_SECONDS: "3", JOB_HEARTBEAT_SECONDS: "1",
  JOB_MAX_ATTEMPTS: "3", JOB_BACKOFF_SECONDS: "1,1,1", POLL_MS: "400",
};

const results: [string, boolean, string][] = [];
const check = (name: string, ok: boolean, detail = "") => {
  results.push([name, ok, detail]);
  console.log(`  ${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  " + detail : ""}`);
};
const sql = (q: string): string => raw(q, { db: "cbfc_dev" });

async function login(userId: string): Promise<string> {
  const r = await fetch(`${API}/login?u=${userId}&t=${T1}`, { redirect: "manual" });
  return (r.headers.get("set-cookie") ?? "").split(";")[0];
}
async function upload(cookie: string, csv: string): Promise<number> {
  const r = await fetch(`${API}/upload`, { method: "POST", redirect: "manual",
    headers: { cookie, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ engagement: ENG_A, legal_entity: LE_A,
      period_revision: PR1, provided_by: PROVIDER_R1, csv }).toString() });
  return r.status;
}
const latestBatch = (): string =>
  sql(`SELECT import_batch_id FROM import_batch ORDER BY created_at DESC LIMIT 1`);
const batchField = (b: string, col: string): string =>
  sql(`SELECT COALESCE(${col}::text,'') FROM import_batch WHERE import_batch_id='${b}'`);
const jobField = (b: string, col: string): string =>
  sql(`SELECT COALESCE(${col}::text,'') FROM background_job WHERE subject_id='${b}'`);

const BALANCED = "#legal_entity_code=1234567890123\naccount_code,account_name,debit,credit\n" +
  "1002,普通預金,4000.00,0\n4000,売上,0,4000.00\n";
const UNBALANCED = "#legal_entity_code=1234567890123\naccount_code,account_name,debit,credit\n" +
  "1002,普通預金,4000.00,0\n4000,売上,0,3000.00\n";

function startWorker(extraEnv: Record<string, string> = {}): ChildProcess {
  return spawn("node", ["apps/worker/src/worker.ts"],
    { env: { ...process.env, ...JOB_ENV, ...extraEnv }, stdio: "ignore" });
}
async function waitFor(predicate: () => boolean, ms = 15000): Promise<boolean> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await sleep(300);
  }
  return false;
}

execSync("bash packages/database/src/seed.sh cbfc_dev", { stdio: "ignore" });
execSync("rm -rf var/objects");
const api = spawn("node", ["apps/api/src/server.ts"],
  { env: { ...process.env, ...JOB_ENV, PORT: "8094" }, stdio: "ignore" });
let worker: ChildProcess | null = null;

try {
  await sleep(1200);
  console.log("══ SLICE-M2-03 背景工作可靠性驗收 ══");
  const jia = await login(U_JIA);

  // ── 1 上傳交易同時建立批次與工作 ──
  check("上傳 → 302", await upload(jia, BALANCED) === 302);
  const B1 = latestBatch();
  check("上傳交易同時建立 BackgroundJob(QUEUED)：不存在『已 UPLOADED 但無 job』的批次",
    batchField(B1, "status") === "UPLOADED" && jobField(B1, "status") === "QUEUED"
    && jobField(B1, "attempt_count") === "0");
  check("上傳事件與批次同交易寫入",
    sql(`SELECT count(*) FROM audit_event WHERE event_type='import_batch.uploaded'
         AND object_id='${B1}'`) === "1");
  check("冪等鍵四欄齊備（job_type/subject/version/rule）",
    jobField(B1, "job_type") === "IMPORT_VALIDATION" && jobField(B1, "subject_version") === "1"
    && jobField(B1, "rule_version") === "detect-r1" && jobField(B1, "idempotency_key").length === 64);
  check("孤兒批次為零：每個 UPLOADED 批次都有對應工作",
    sql(`SELECT count(*) FROM import_batch ib WHERE ib.status='UPLOADED'
         AND NOT EXISTS (SELECT 1 FROM background_job j WHERE j.subject_id=ib.import_batch_id)`) === "0");

  // ── 2 正常處理 ──
  worker = startWorker();
  check("worker 處理後批次 VALIDATED／MATCHED",
    await waitFor(() => batchField(B1, "status") === "VALIDATED"),
    batchField(B1, "status"));
  check("工作轉 COMPLETED，租約已釋放",
    jobField(B1, "status") === "COMPLETED" && jobField(B1, "claim_token") === "");
  check("來源事實完整：2 列", sql(`SELECT count(*) FROM source_ledger_line
         WHERE import_batch_id='${B1}'`) === "2");
  check("狀態遷移與 DomainEvent 同交易：validated 事件存在",
    sql(`SELECT count(*) FROM audit_event WHERE event_type='import_batch.validated'
         AND object_id='${B1}'`) === "1");
  worker.kill(); worker = null; await sleep(400);

  // ── 3 業務裁決：立即隔離，不重試 ──
  await upload(jia, UNBALANCED);
  const B2 = latestBatch();
  worker = startWorker();
  check("業務裁決（G-01 不平衡）→ 立即 QUARANTINED",
    await waitFor(() => batchField(B2, "status") === "QUARANTINED"), batchField(B2, "status"));
  check("業務裁決不重試：attempt_count 維持 1，工作 COMPLETED",
    jobField(B2, "attempt_count") === "1" && jobField(B2, "status") === "COMPLETED"
    && jobField(B2, "last_error_class") === "BUSINESS_VALIDATION");
  worker.kill(); worker = null; await sleep(400);

  // ── 4 基礎設施故障：重試，且絕不污染批次狀態 ──
  await upload(jia, BALANCED);
  const B3 = latestBatch();
  // 刪掉物件檔案 → getObject 失敗 → RETRYABLE_INFRASTRUCTURE
  execSync("rm -rf var/objects");
  worker = startWorker();
  check("基礎設施故障 → 工作進 RETRY_WAIT，不是 QUARANTINED",
    await waitFor(() => jobField(B3, "status") === "RETRY_WAIT"
      || jobField(B3, "status") === "FAILED"), jobField(B3, "status"));
  check("重試期間批次全程維持 UPLOADED（業務狀態未被污染）",
    batchField(B3, "status") === "UPLOADED");
  check("退避時間可保存可查詢（next_attempt_at 在未來）",
    sql(`SELECT (next_attempt_at > created_at)::text FROM background_job WHERE subject_id='${B3}'`) === "true");
  check("重試耗盡 → 工作 FAILED 且有人可讀原因",
    await waitFor(() => jobField(B3, "status") === "FAILED", 20000)
    && jobField(B3, "last_error_class") === "RETRYABLE_INFRASTRUCTURE"
    && jobField(B3, "last_error_message").length > 0, jobField(B3, "last_error_class"));
  check("重試耗盡後批次仍為 UPLOADED——客戶不需重新上傳同一份檔案",
    batchField(B3, "status") === "UPLOADED");
  check("attempt_count 達上限 3", jobField(B3, "attempt_count") === "3");
  check("失敗批次未留下任何來源事實",
    sql(`SELECT count(*) FROM source_ledger_line WHERE import_batch_id='${B3}'`) === "0"
    && sql(`SELECT count(*) FROM source_dataset WHERE import_batch_id='${B3}'`) === "0"
    && sql(`SELECT count(*) FROM data_coverage WHERE import_batch_id='${B3}'`) === "0"
    && sql(`SELECT count(*) FROM source_identity_assessment WHERE import_batch_id='${B3}'`) === "0");
  worker.kill(); worker = null; await sleep(400);

  // ── 5 crash-reclaim（確定性）──
  // 不與真實 SIGKILL 競速——原寫法允許 wasRunning === COMPLETED（worker 太快），
  // 整段 crash-reclaim 可能從未被執行。改以 SQL 直接構造「已認領但從未提交」的
  // 死 worker 狀態（這正是 SIGKILL-after-claim 的語意），使重領路徑必然被命中。
  await upload(jia, BALANCED);
  const B4 = latestBatch();
  sql(`UPDATE background_job SET status='RUNNING', claim_token=gen_random_uuid(),
       claimed_by='dead-worker#999', claimed_at=now(),
       lease_expires_at=now() + interval '1 second', attempt_count=1
       WHERE subject_id='${B4}'`);
  check("死 worker 已認領（RUNNING, attempt 1），批次未進 VALIDATING（ADR-M2-002）",
    jobField(B4, "status") === "RUNNING" && batchField(B4, "status") === "UPLOADED",
    `job=${jobField(B4, "status")} batch=${batchField(B4, "status")}`);
  check("租約逾時後可被診斷為 stalled",
    await waitFor(() => sql(`SELECT (lease_expires_at <= now())::text
      FROM background_job WHERE subject_id='${B4}'`) === "true", 8000));
  worker = startWorker();
  check("重啟後自動恢復：批次最終達成 VALIDATED",
    await waitFor(() => batchField(B4, "status") === "VALIDATED", 20000),
    `${batchField(B4, "status")} / job=${jobField(B4, "status")}`);
  check("crash-reclaim 確實發生：attempt_count = 2 且認領者已易主",
    jobField(B4, "attempt_count") === "2" && jobField(B4, "claimed_by") !== "dead-worker#999",
    `attempts=${jobField(B4, "attempt_count")} by=${jobField(B4, "claimed_by")}`);
  check("重領不產生重複來源事實：仍為 2 列",
    sql(`SELECT count(*) FROM source_ledger_line WHERE import_batch_id='${B4}'`) === "2");
  check("重領不產生重複資料集／涵蓋／評估（各 1 筆）",
    sql(`SELECT count(*) FROM source_dataset WHERE import_batch_id='${B4}'`) === "1"
    && sql(`SELECT count(*) FROM data_coverage WHERE import_batch_id='${B4}'`) === "1"
    && sql(`SELECT count(*) FROM source_identity_assessment WHERE import_batch_id='${B4}'`) === "1");
  worker.kill(); worker = null; await sleep(400);

  // ── 6 VALIDATING 不可觀察（ADR-M2-002） ──
  check("全程未出現外部可觀察的 VALIDATING 批次",
    sql(`SELECT count(*) FROM import_batch WHERE status='VALIDATING'`) === "0");

  // ── 7 診斷 API（§24.6：技術維運＝R6） ──
  const denied = await fetch(`${API}/admin/jobs`, { headers: { cookie: jia } });
  check("無 R6 者（甲）存取診斷 API → 403 ＋ 違規留痕",
    denied.status === 403
    && Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'
         AND event_type='admin.jobs.denied'`)) >= 1);
  const ops = await login("aaaaaaaa-0000-0000-0000-000000000004");   // 系管丁：R6
  const diag = await (await fetch(`${API}/admin/jobs`, { headers: { cookie: ops } })).json() as
    { jobs: Record<string, unknown>[]; stalled_count: number };
  check("診斷 API 列出工作與卡住計數", Array.isArray(diag.jobs) && diag.jobs.length >= 4);
  const j3 = diag.jobs.find((x) => x.subject_id === B3);
  check("診斷含認領者、認領時間、租約、重試次數與失敗原因",
    !!j3 && j3.status === "FAILED" && j3.attempt_count === 3
    && j3.last_error_class === "RETRYABLE_INFRASTRUCTURE"
    && typeof j3.last_error_message === "string" && j3.claimed_by !== null
    && "lease_expires_at" in j3 && "next_attempt_at" in j3);
  check("診斷 API 提供 stalled 判定欄位", diag.jobs.every((x) => "stalled" in x));
} finally {
  worker?.kill(); api.kill();
  // 等子行程真正退出——殘留 worker 會搶先認領下一支測試的工作（跨測試競態）
  await Promise.all([api, worker].map((p) => p && p.exitCode === null && p.signalCode === null
    ? new Promise((res) => { const t = setTimeout(() => p.kill("SIGKILL"), 3000); p.once("exit", () => { clearTimeout(t); res(null); }); })
    : null));
}

const failed = results.filter(([, ok]) => !ok);
console.log(`\n通過 ${results.length - failed.length} ／ 失敗 ${failed.length}`);
if (failed.length) process.exit(1);
