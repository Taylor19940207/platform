// SLICE-M2-02B 端到端驗收：PREVIEW CalculationRun 與輸入凍結。
// 契約：docs/slices/SLICE-M2-02B_PREVIEW_CalculationRun與輸入凍結.md
// 流程：ACCEPTED TB ＋ 15 條映射 ＋ 1 筆批准調整 → 建 Run（凍結）→ worker 計算
//       → 與 expected_adjusted_group_tb 逐科目勾稽 → 冪等 → 重演 → 竄改偵測。
import { spawn, execSync, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { raw } from "../../packages/database/src/psql.ts";

const API = "http://127.0.0.1:8096";
const U_JIA = "aaaaaaaa-0000-0000-0000-000000000001";     // 甲 R2/R3/R4
const U_YI  = "aaaaaaaa-0000-0000-0000-000000000002";     // 乙 R2/R3/R4
const U_BING = "aaaaaaaa-0000-0000-0000-000000000003";    // 丙 R4（無 R2/R3）
const T1 = "11111111-1111-1111-1111-111111111111";
const ENG_A = "eeeeeeee-0000-0000-0000-000000000001";
const LE_A = "cccccccc-0000-0000-0000-000000000001";
const PR1 = "99999999-0000-0000-0000-000000000001";
const PR2 = "99999999-0000-0000-0000-000000000002";
const FIX = "tests/fixtures/case-001";

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
async function post(cookie: string, path: string, fields: Record<string, string>) {
  return fetch(`${API}${path}`, { method: "POST", redirect: "manual",
    headers: { cookie, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(fields).toString() });
}
const get = async (cookie: string, path: string): Promise<string> =>
  (await fetch(`${API}${path}`, { headers: { cookie } })).text();
async function upload(cookie: string, pr: string, csvPath: string): Promise<number> {
  return (await post(cookie, "/upload", { engagement: ENG_A, legal_entity: LE_A,
    period_revision: pr, csv: readFileSync(csvPath, "utf8") })).status;
}
async function waitWorker(): Promise<void> {
  for (let i = 0; i < 20; i++) {
    if (sql("SELECT count(*) FROM import_batch WHERE status IN ('UPLOADED','VALIDATING')") === "0") return;
    await sleep(500);
  }
}
async function waitFor(pred: () => boolean, ms = 15000): Promise<boolean> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) { if (pred()) return true; await sleep(400); }
  return false;
}
const accountId = (code: string): string =>
  sql(`SELECT a.account_id FROM account a JOIN chart_of_accounts c ON c.coa_id = a.coa_id
       WHERE c.engagement_id = '${ENG_A}' AND a.code = '${code}'`);
const runField = (run: string, col: string): string =>
  sql(`SELECT COALESCE(${col}::text,'') FROM calculation_run WHERE calculation_run_id='${run}'`);
const violations = (code: string): number =>
  Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'
              AND payload->>'code'='${code}'`));
const K = (n: number) => `00000000-0000-4000-8000-00000000000${n}`;

// ── 重置環境 ──
execSync("bash packages/database/src/seed.sh cbfc_dev", { stdio: "ignore" });
execSync("rm -rf var/objects");
const api = spawn("node", ["apps/api/src/server.ts"],
  { env: { ...process.env, PORT: "8096" }, stdio: "ignore" });
let worker: ChildProcess | null =
  spawn("node", ["apps/worker/src/worker.ts"], { env: { ...process.env, POLL_MS: "400" }, stdio: "ignore" });

try {
  await sleep(1200);
  console.log("══ SLICE-M2-02B PREVIEW CalculationRun 驗收（Case-001） ══");
  const jia = await login(U_JIA);
  const yi = await login(U_YI);
  const bing = await login(U_BING);

  // ── 前置：TB 匯入與接受 ──
  await upload(jia, PR1, `${FIX}/jp_tb_2026-03.csv`);
  await upload(jia, PR2, `${FIX}/jp_tb_2026-04.csv`);
  await waitWorker();
  const B1 = sql(`SELECT import_batch_id FROM import_batch WHERE declared_period_revision_id='${PR1}'`);
  const B2 = sql(`SELECT import_batch_id FROM import_batch WHERE declared_period_revision_id='${PR2}'`);
  await post(jia, "/b04/accept", { batch: B1 });

  // 1 G-02 未通過 → 不建 run ＋ 留痕（機器代碼）
  check("G-02 未通過 → 不得建立 Run（409＋G02_UNMAPPED 留痕）",
    (await post(jia, "/b06/run", { batch: B1, request_key: K(1) })).status === 409
    && violations("G02_UNMAPPED") >= 1
    && sql("SELECT count(*) FROM calculation_run") === "0");

  // 前置：15 條映射（甲建、乙批准）
  const manual = readFileSync(`${FIX}/manual_mapping.csv`, "utf8").trim().split("\n").slice(1)
    .map((l) => l.split(","));
  for (const [srcCode, , tgtCode] of manual)
    await post(jia, "/b04/map", { batch: B1, source_code: srcCode, target: accountId(tgtCode) });
  for (const id of sql(`SELECT mapping_rule_id FROM mapping_rule WHERE approved_at IS NULL`).split("\n"))
    await post(yi, "/b04/approve", { batch: B1, rule: id });

  // 2 未 ACCEPTED 批次 → 不得建立
  check("未 ACCEPTED 批次 → 409＋BATCH_NOT_ACCEPTED 留痕",
    (await post(jia, "/b06/run", { batch: B2, request_key: K(2) })).status === 409
    && violations("BATCH_NOT_ACCEPTED") >= 1);

  // 前置：一筆已批准調整（甲編製 → 乙覆核 → 丙批准；物化 JournalEntry/Line）
  await post(jia, "/b05/create", { batch: B1, title: "集團折舊政策差異追加" });
  const ADJ = sql(`SELECT adjustment_id FROM adjustment ORDER BY created_at DESC LIMIT 1`);
  await post(jia, "/b05/save", { adj: ADJ, base_object_version: "1", title: "集團折舊政策差異追加",
    legal_basis: "母公司折舊政策 v3", evidence_ref: "附件 A-12", judgment_reason: "耐用年限差異",
    language_tag: "zh-Hant", lines: "6602,200000,0\n1601,0,200000" });
  await post(jia, "/b05/submit", { adj: ADJ });
  await post(yi, "/b05/review", { adj: ADJ });
  await post(bing, "/b05/approve", { adj: ADJ });
  check("前置：調整已批准並物化 JournalLine（2 列）",
    sql(`SELECT count(*) FROM journal_line`) === "2");

  // 3 RBAC：丙（僅 R4）→ 403
  check("建立 Run 限 R2／R3：丙（R4）→ 403＋ROLE_REQUIRED 留痕",
    (await post(bing, "/b06/run", { batch: B1, request_key: K(3) })).status === 403
    && violations("ROLE_REQUIRED") >= 1);

  // 4 建立 Run（K1）→ 同交易產生 Run＋Manifest＋Job＋事件
  const r1 = await post(jia, "/b06/run", { batch: B1, request_key: K(4) });
  check("建立 PREVIEW Run → 302", r1.status === 302);
  const RUN1 = sql(`SELECT calculation_run_id FROM calculation_run WHERE import_batch_id='${B1}'`);
  check("Run＋Manifest＋Job＋建立事件同交易存在",
    RUN1.length === 36
    && sql(`SELECT count(*) FROM background_job WHERE subject_id='${RUN1}'`) === "1"
    && sql(`SELECT count(*) FROM audit_event WHERE event_type='calculation_run.created'
            AND object_id='${RUN1}'`) === "1");
  check("Manifest 凍結 19 筆輸入（SCOPE 1＋TB 1＋映射 15＋調整 1＋COA 1）",
    sql(`SELECT count(*) FROM calculation_manifest_entry cme JOIN calculation_run r
         ON r.manifest_id = cme.manifest_id WHERE r.calculation_run_id='${RUN1}'`) === "19",
    sql(`SELECT count(*) FROM calculation_manifest_entry cme JOIN calculation_run r
         ON r.manifest_id = cme.manifest_id WHERE r.calculation_run_id='${RUN1}'`));

  // 5 worker 完成計算
  check("worker 完成：Run COMPLETED ＋ Job COMPLETED",
    await waitFor(() => runField(RUN1, "status") === "COMPLETED", 20000)
    && sql(`SELECT status FROM background_job WHERE subject_id='${RUN1}'`) === "COMPLETED",
    `run=${runField(RUN1, "status")}`);
  check("result_content_hash 已寫入（64 hex）", runField(RUN1, "result_content_hash").length === 64);

  // 6 與現行 Excel＋批准調整的預期逐科目勾稽
  const expected = readFileSync(`${FIX}/expected_adjusted_group_tb_2026-03.csv`, "utf8").trim()
    .split("\n").slice(1)
    .map((l) => { const [code, , d, c] = l.split(",");
      return `${code}|${Number(d).toFixed(2)}|${Number(c).toFixed(2)}`; });
  const actual = sql(`SELECT account_code||'|'||SUM(debit)::text||'|'||SUM(credit)::text
      FROM balance_snapshot_line WHERE calculation_run_id='${RUN1}'
     GROUP BY account_code ORDER BY account_code`).split("\n").filter(Boolean);
  const diffs = expected.filter((e) => !actual.includes(e))
    .concat(actual.filter((a) => !expected.includes(a)));
  check(`調整後集團 TB 與預期逐科目一致（${expected.length}/${expected.length}）`,
    diffs.length === 0 && actual.length === expected.length,
    diffs.length ? `差異：${diffs.join(" ")}` : "");
  check("控制總額：借貸各 59,000,000（G-09 已於結果交易內勾稽）",
    sql(`SELECT SUM(debit)::text||'|'||SUM(credit)::text FROM balance_snapshot_line
         WHERE calculation_run_id='${RUN1}'`) === "59000000.00|59000000.00");

  // 7 PREVIEW 標示
  const pg = await get(jia, `/b06/run?id=${RUN1}`);
  check("結果頁醒目標示 PREVIEW 非正式・未折算（NO_FX）",
    pg.includes("PREVIEW") && pg.includes("未折算") && pg.includes("NO_FX")
    && pg.includes("不得作為入帳或交付依據"));

  // 8 冪等契約三情形
  const again = await post(jia, "/b06/run", { batch: B1, request_key: K(4) });
  check("同 key 同內容 → 回原 run（不建第二個）",
    again.status === 302 && (again.headers.get("location") ?? "").includes(RUN1)
    && sql(`SELECT count(*) FROM calculation_run WHERE import_batch_id='${B1}'`) === "1");
  await post(jia, "/b04/accept", { batch: B2 });
  check("同 key 異內容 → 409＋REQUEST_KEY_REUSED 留痕",
    (await post(jia, "/b06/run", { batch: B2, request_key: K(4) })).status === 409
    && violations("REQUEST_KEY_REUSED") >= 1);

  // 9 建立後的版本變動不影響既有 run；新 run 才採用新版本
  await post(jia, "/b04/map", { batch: B1, source_code: "610", target: accountId("6401") });
  const d610 = sql(`SELECT mapping_rule_id FROM mapping_rule
                    WHERE source_account_code='610' AND approved_at IS NULL`);
  await post(yi, "/b04/approve", { batch: B1, rule: d610 });
  // 重演原 run：結果必須與原 run 完全一致（讀凍結內容，不讀新映射）
  await post(jia, "/b06/replay", { run: RUN1 });
  const REPLAY1 = sql(`SELECT calculation_run_id FROM calculation_run
                       WHERE replay_of_run_id='${RUN1}'`);
  check("重演 run 完成且結果 hash 與原 run 完全一致（INT-d／INV-29）",
    await waitFor(() => runField(REPLAY1, "status") === "COMPLETED", 20000)
    && runField(REPLAY1, "result_content_hash") === runField(RUN1, "result_content_hash"),
    `replay=${runField(REPLAY1, "status")}`);
  check("原 run 未被修改（狀態與 hash 不變、無失敗欄位）",
    runField(RUN1, "status") === "COMPLETED" && runField(RUN1, "failure_reason_code") === "");
  // 新 run（新 key）→ 採用新映射版本，結果不同且可解釋
  await post(jia, "/b06/run", { batch: B1, request_key: K(5) });
  const RUN2 = sql(`SELECT calculation_run_id FROM calculation_run
                    WHERE import_batch_id='${B1}' AND replay_of_run_id IS NULL
                    AND calculation_run_id <> '${RUN1}'`);
  check("新 run 採用新生效映射（610→6401）：6401 = 31,300,000",
    await waitFor(() => runField(RUN2, "status") === "COMPLETED", 20000)
    && sql(`SELECT SUM(debit)::text FROM balance_snapshot_line
            WHERE calculation_run_id='${RUN2}' AND account_code='6401'`) === "31300000.00"
    && runField(RUN2, "result_content_hash") !== runField(RUN1, "result_content_hash"));

  // 10 竄改凍結內容 → 重演外顯失敗（REPLAY_FAILED），原 run 不變
  sql(`ALTER TABLE calculation_manifest_entry DISABLE TRIGGER trg_cme_immutable`);
  sql(`UPDATE calculation_manifest_entry SET content_canonical = content_canonical || 'X'
       WHERE object_type='SOURCE_TB' AND manifest_id =
         (SELECT manifest_id FROM calculation_run WHERE calculation_run_id='${RUN1}')`);
  sql(`ALTER TABLE calculation_manifest_entry ENABLE TRIGGER trg_cme_immutable`);
  await post(jia, "/b06/replay", { run: RUN1 });
  const REPLAY2 = sql(`SELECT calculation_run_id FROM calculation_run
                       WHERE replay_of_run_id='${RUN1}' AND calculation_run_id <> '${REPLAY1}'`);
  check("凍結內容損壞 → replay run FAILED（REPLAY_FAILED 外顯，INT-e）",
    await waitFor(() => runField(REPLAY2, "status") === "FAILED", 20000)
    && runField(REPLAY2, "failure_reason_code") === "REPLAY_FAILED"
    && runField(REPLAY2, "failure_reason").length > 0,
    `replay2=${runField(REPLAY2, "status")}/${runField(REPLAY2, "failure_reason_code")}`);
  check("失敗的 replay 不留半套輸出；原 run 仍 COMPLETED 不受影響",
    sql(`SELECT count(*) FROM balance_snapshot_line WHERE calculation_run_id='${REPLAY2}'`) === "0"
    && runField(RUN1, "status") === "COMPLETED");

  // 10b 單獨竄改 payload（canonical 完好）→ v2 hash 仍偵測（0013①）
  sql(`ALTER TABLE calculation_manifest_entry DISABLE TRIGGER trg_cme_immutable`);
  sql(`UPDATE calculation_manifest_entry SET payload = jsonb_set(payload,'{lines,0,debit}','"999999.00"')
       WHERE object_type='SOURCE_TB' AND manifest_id =
         (SELECT manifest_id FROM calculation_run WHERE calculation_run_id='${RUN2}')`);
  sql(`ALTER TABLE calculation_manifest_entry ENABLE TRIGGER trg_cme_immutable`);
  await post(jia, "/b06/replay", { run: RUN2 });
  const REPLAY3 = sql(`SELECT calculation_run_id FROM calculation_run WHERE replay_of_run_id='${RUN2}'`);
  check("單獨竄改 payload → replay FAILED（content_hash v2 涵蓋 payload）",
    await waitFor(() => runField(REPLAY3, "status") === "FAILED", 20000)
    && runField(REPLAY3, "failure_reason_code") === "REPLAY_FAILED"
    && runField(RUN2, "status") === "COMPLETED",
    `replay3=${runField(REPLAY3, "status")}`);

  // 10c Manifest 封存：Run 建立後不得追加 entry（0013①，DB 最後防線）
  let sealErr = "";
  try {
    sql(`INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type,
           domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
         SELECT tenant_id, manifest_id, 'SCOPE', 'SCOPE', '99', 'x', 'x', '{}'::jsonb
           FROM calculation_run WHERE calculation_run_id='${RUN1}'`);
  } catch (e) { sealErr = String(e); }
  check("Manifest 封存：Run 建立後追加 entry 被 DB 拒絕", sealErr.includes("封存"));

  // 11 單一真相來源：Run 終態與 Job 終態不存在矛盾組合
  check("無矛盾組合：Run 終態 ⇔ Job 終態（全庫掃描）",
    sql(`SELECT count(*) FROM calculation_run r
         JOIN background_job j ON j.subject_id = r.calculation_run_id
        WHERE (r.status IN ('COMPLETED','FAILED')) <> (j.status IN ('COMPLETED','FAILED'))`) === "0");

  // 12 事件完整性
  check("建立／重演建立／完成／失敗事件皆存在",
    Number(sql(`SELECT count(DISTINCT event_type) FROM audit_event WHERE kind='DOMAIN_EVENT'
      AND event_type IN ('calculation_run.created','calculation_run.replay_created',
                         'calculation_run.completed','calculation_run.failed')`)) === 4);
} finally {
  worker?.kill(); api.kill();
}

const failed = results.filter(([, ok]) => !ok);
console.log(`\n通過 ${results.length - failed.length} ／ 失敗 ${failed.length}`);
process.exit(failed.length ? 1 : 0);
