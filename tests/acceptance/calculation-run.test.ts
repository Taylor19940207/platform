// SLICE-M2-02B 端到端驗收：PREVIEW CalculationRun 與輸入凍結。
// 契約：docs/slices/SLICE-M2-02B_PREVIEW_CalculationRun與輸入凍結.md
// 流程：ACCEPTED TB ＋ 15 條映射 ＋ 1 筆批准調整 → 建 Run（凍結）→ worker 計算
//       → 與 expected_adjusted_group_tb 逐科目勾稽 → 冪等 → 重演 → 竄改偵測。
import { spawn, execSync, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { setTimeout as sleep } from "node:timers/promises";
import { raw } from "../../packages/database/src/psql.ts";

const API = "http://127.0.0.1:8096";
const U_JIA = "aaaaaaaa-0000-0000-0000-000000000001";     // 甲 R2/R3/R4
const U_YI  = "aaaaaaaa-0000-0000-0000-000000000002";     // 乙 R2/R3/R4
const U_BING = "aaaaaaaa-0000-0000-0000-000000000003";    // 丙 R4（無 R2/R3）
const U_OPS = "aaaaaaaa-0000-0000-0000-000000000004";     // 系管丁：R6（租戶層）
const U_TAX = "aaaaaaaa-0000-0000-0000-000000000005";     // 稅務擔當戊：R1（本案件）
const U_TR4 = "aaaaaaaa-0000-0000-0000-000000000006";     // 租戶層己：R4 但 engagement_id IS NULL
const U_TR3 = "aaaaaaaa-0000-0000-0000-000000000007";     // 租戶層庚：R3 但 engagement_id IS NULL
const T1 = "11111111-1111-1111-1111-111111111111";
// R2 代傳時必須指定真正的資料提供者（該案件的有效 R1）；R1 自己上傳則不需要
const PROVIDER_R1 = "aaaaaaaa-0000-0000-0000-000000000005";
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

// seed 為 B-06 畫面在 2026-03 留了一個 ACCEPTED 批次（case-001-tb.csv）與一個 RUNNING run。
// 因此「依期間查唯一批次」抓到的可能不是本測試上傳的那一批，而所有正常上傳的
// file_name 都是 tb.csv——唯一分得開的是**本測試自己算得出來的內容雜湊**。
const shaOf = (csvPath: string): string =>
  createHash("sha256").update(readFileSync(csvPath)).digest("hex");
const dbNow = (): string => sql("SELECT clock_timestamp()::text");
/** 取得本測試剛上傳的那一批。since 是上傳前記下的時間點——同一檔案重複上傳時，
 *  只靠雜湊會抓到較早那一批。取得後立刻回驗父鏈與雜湊，避免以錯誤對象通過。 */
const uploadedBatch = (pr: string, user: string, csvPath: string, since: string): string => {
  const sha = shaOf(csvPath);
  const id = sql(`SELECT import_batch_id FROM import_batch
                   WHERE declared_period_revision_id = '${pr}' AND uploaded_by = '${user}'
                     AND file_sha256 = '${sha}' AND created_at > '${since}'::timestamptz
                   ORDER BY created_at DESC LIMIT 1`);
  check(`前置：取得本測試上傳的批次（期間／上傳者／檔案雜湊皆相符）`,
    id !== "" && sql(`SELECT count(*) FROM import_batch WHERE import_batch_id = '${id}'
                       AND declared_period_revision_id = '${pr}' AND uploaded_by = '${user}'
                       AND file_sha256 = '${sha}'`) === "1", id.slice(0, 8));
  return id;
};

async function login(userId: string): Promise<string> {
  const r = await fetch(`${API}/login?u=${userId}&t=${T1}`, { redirect: "manual" });
  return (r.headers.get("set-cookie") ?? "").split(";")[0];
}
async function post(cookie: string, path: string, fields: Record<string, string>) {
  return fetch(`${API}${path}`, { method: "POST", redirect: "manual",
    headers: { cookie, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(fields).toString() });
}
const getStatus = async (cookie: string, path: string): Promise<number> =>
  (await fetch(`${API}${path}`, { headers: { cookie }, redirect: "manual" })).status;
const get = async (cookie: string, path: string): Promise<string> =>
  (await fetch(`${API}${path}`, { headers: { cookie } })).text();
async function upload(cookie: string, pr: string, csvPath: string): Promise<number> {
  return (await post(cookie, "/upload", { engagement: ENG_A, legal_entity: LE_A,
    period_revision: pr, provided_by: PROVIDER_R1, csv: readFileSync(csvPath, "utf8") })).status;
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
  const t0 = dbNow();
  await upload(jia, PR1, `${FIX}/jp_tb_2026-03.csv`);
  await upload(jia, PR2, `${FIX}/jp_tb_2026-04.csv`);
  await waitWorker();
  const B1 = uploadedBatch(PR1, U_JIA, `${FIX}/jp_tb_2026-03.csv`, t0);
  const B2 = uploadedBatch(PR2, U_JIA, `${FIX}/jp_tb_2026-04.csv`, t0);
  await post(jia, "/b04/accept", { batch: B1 });

  // 1 G-02 未通過 → 不建 run ＋ 留痕（機器代碼）
  check("G-02 未通過 → 不得建立 Run（409＋G02_UNMAPPED 留痕）",
    (await post(jia, "/b06/run", { batch: B1, request_key: K(1) })).status === 409
    && violations("G02_UNMAPPED") >= 1
    // 只計本批次的 run：seed 為 B-06 畫面留了一個屬於別的批次的 RUNNING run
    && sql(`SELECT count(*) FROM calculation_run WHERE import_batch_id='${B1}'`) === "0");

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
  // SLICE-M2-06 起再凍結兩份基礎組成（A、C）——「哪些層構成哪個基礎」是計算輸入，
  // 不凍結的話組成升版後重演會得到不同的基礎餘額且無任何錯誤訊息（INV-21／INV-29）。
  check("Manifest 凍結 21 筆輸入（SCOPE 1＋TB 1＋映射 15＋調整 1＋COA 1＋基礎組成 2）",
    sql(`SELECT count(*) FROM calculation_manifest_entry cme JOIN calculation_run r
         ON r.manifest_id = cme.manifest_id WHERE r.calculation_run_id='${RUN1}'`) === "21",
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

  // 7b §24.6 逐動作授權：建立／重演／清單／結果檢視皆為**案件層** R2／R3
  // 以 run 為入口者由 CalculationRun → ImportBatch → Engagement 反查歸屬，
  // 不採信請求附帶的 batch。
  const ops = await login(U_OPS);
  const tax = await login(U_TAX);
  const tr4 = await login(U_TR4);
  const tr3 = await login(U_TR3);
  const runsBefore = Number(sql("SELECT count(*) FROM calculation_run"));
  const jobsBefore = Number(sql("SELECT count(*) FROM background_job WHERE job_type='CALCULATION_RUN'"));
  const createdBefore = Number(sql(`SELECT count(*) FROM audit_event
                                     WHERE event_type='calculation_run.created'`));
  check("前置成立：戊持本案件 R1、丁持租戶層 R6、己持租戶層 R4（三者皆無案件層 R2／R3）",
    sql(`SELECT count(*) FROM role_assignment WHERE user_id IN ('${U_TAX}','${U_OPS}','${U_TR4}')
          AND role IN ('R2','R3') AND engagement_id='${ENG_A}'`) === "0");
  // 庚是「角色種類正確（R3 在白名單內）、但作用域是租戶層」的樣本——
  // 只有它能釘住作用域判定；R1／R6／R4 三者連白名單都不在。
  check("租戶層 R3（種類正確、範圍錯誤）建立／重演／檢視 run 皆 403",
    (await post(tr3, "/b06/run", { batch: B1, request_key: K(93) })).status === 403
    && (await post(tr3, "/b06/replay", { run: RUN1 })).status === 403
    && await getStatus(tr3, `/b06/run?id=${RUN1}`) === 403);
  check("建立 run：R1／R6／租戶層 R4 皆 403",
    (await post(tax, "/b06/run", { batch: B1, request_key: K(90) })).status === 403
    && (await post(ops, "/b06/run", { batch: B1, request_key: K(91) })).status === 403
    && (await post(tr4, "/b06/run", { batch: B1, request_key: K(92) })).status === 403);
  check("重演：三者皆 403（歸屬由 run 反查，不採信附帶 batch）",
    (await post(tax, "/b06/replay", { run: RUN1 })).status === 403
    && (await post(ops, "/b06/replay", { run: RUN1 })).status === 403
    && (await post(tr4, "/b06/replay", { run: RUN1 })).status === 403);
  check("清單與單次結果檢視：三者皆 403",
    await getStatus(tax, `/b06?batch=${B1}`) === 403
    && await getStatus(ops, `/b06/run?id=${RUN1}`) === 403
    && await getStatus(tr4, `/b06/run?id=${RUN1}`) === 403);
  check("越權未新增任何 calculation_run、背景工作或 calculation_run.created 事件",
    Number(sql("SELECT count(*) FROM calculation_run")) === runsBefore
    && Number(sql("SELECT count(*) FROM background_job WHERE job_type='CALCULATION_RUN'")) === jobsBefore
    && Number(sql(`SELECT count(*) FROM audit_event
                    WHERE event_type='calculation_run.created'`)) === createdBefore);
  check("拒絕的 CVA 分開記錄 engagement_roles 與 tenant_roles",
    sql(`SELECT (payload->>'engagement_roles')||'|'||(payload->>'tenant_roles')
           FROM audit_event WHERE event_type='b06.run.view.denied'
          ORDER BY audit_event_id DESC LIMIT 1`) === '[]|["R4"]');

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

  // 7c 自動保存草稿不得影響既有 run 的重演（INV-29：重演只讀 manifest 凍結內容）
  // manifest 只凍結**已批准**的調整；草稿再怎麼改都不該進入既有 run。
  await post(jia, "/b05/create", { batch: B1, title: "run 建立後才編輯的草稿" });
  const DRAFT = sql(`SELECT adjustment_id FROM adjustment ORDER BY created_at DESC LIMIT 1`);
  const draftSave = await post(jia, "/b05/save", { adj: DRAFT, mode: "auto",
    base_object_version: "1", title: "自動保存於 run 之後", legal_basis: "x",
    evidence_ref: "y", judgment_reason: "z", language_tag: "ja-JP",
    lines: "6602,500000,0\n1601,0,500000",
    edit_session_id: "22220000-0000-4000-8000-000000000001", client_save_sequence: "1" });
  check("run 建立後仍可自動保存草稿（草稿不受既有 run 影響）",
    draftSave.status === 200
    && sql(`SELECT title FROM adjustment WHERE adjustment_id='${DRAFT}'`) === "自動保存於 run 之後");
  await post(jia, "/b06/replay", { run: RUN1 });
  const REPLAY_AS = sql(`SELECT calculation_run_id FROM calculation_run
                          WHERE replay_of_run_id='${RUN1}' AND calculation_run_id <> '${REPLAY1}'
                          ORDER BY created_at DESC LIMIT 1`);
  check("既有 run 重演結果仍與原 run 逐位元一致（只讀凍結內容，未讀到新草稿）",
    await waitFor(() => runField(REPLAY_AS, "status") === "COMPLETED", 20000)
    && runField(REPLAY_AS, "result_content_hash") === runField(RUN1, "result_content_hash"),
    `replay=${runField(REPLAY_AS, "status")}`);
  check("新草稿未進入既有 run 的凍結清單",
    sql(`SELECT count(*) FROM calculation_manifest_entry e
          JOIN calculation_run r ON r.manifest_id = e.manifest_id
         WHERE r.calculation_run_id='${RUN1}' AND e.object_type='ADJUSTMENT'
           AND e.object_id='${DRAFT}'`) === "0");

  // 10 竄改凍結內容 → 重演外顯失敗（REPLAY_FAILED），原 run 不變
  sql(`ALTER TABLE calculation_manifest_entry DISABLE TRIGGER trg_cme_immutable`);
  sql(`UPDATE calculation_manifest_entry SET content_canonical = content_canonical || 'X'
       WHERE object_type='SOURCE_TB' AND manifest_id =
         (SELECT manifest_id FROM calculation_run WHERE calculation_run_id='${RUN1}')`);
  sql(`ALTER TABLE calculation_manifest_entry ENABLE TRIGGER trg_cme_immutable`);
  await post(jia, "/b06/replay", { run: RUN1 });
  // RUN1 現在有多筆重演（含 7c 的一致性驗證），以最新一筆識別本次竄改後的 replay
  const REPLAY2 = sql(`SELECT calculation_run_id FROM calculation_run
                       WHERE replay_of_run_id='${RUN1}' AND calculation_run_id <> '${REPLAY1}'
                       ORDER BY created_at DESC LIMIT 1`);
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

  // 11B SQL 端的結果雜湊鏡像必須與 worker 的生成公式一致（0045）
  // fn_calc_result_hash 是 worker canonical 結果雜湊的鏡像，凍結來源 run 時用它復驗。
  // 兩端各自實作，唯一的防分岔手段就是拿**真實 worker 產出的 run** 對一次。
  // 該函式驗 current_tenant()（0045 的跨租戶探測面收口），因此要帶上租戶脈絡。
  check("fn_calc_result_hash 對 worker 產出的 NO_FX run 重算結果一致（0045 鏡像未分岔）",
    sql(`SET app.tenant_id = '11111111-1111-1111-1111-111111111111';
         SELECT (fn_calc_result_hash('${RUN1}'::uuid) = result_content_hash)::text
           FROM calculation_run WHERE calculation_run_id = '${RUN1}'::uuid`) === "true");

  // 12 事件完整性
  check("建立／重演建立／完成／失敗事件皆存在",
    Number(sql(`SELECT count(DISTINCT event_type) FROM audit_event WHERE kind='DOMAIN_EVENT'
      AND event_type IN ('calculation_run.created','calculation_run.replay_created',
                         'calculation_run.completed','calculation_run.failed')`)) === 4);
} finally {
  worker?.kill(); api.kill();
  // 等子行程真正退出——殘留 worker 會搶先認領下一支測試的工作（跨測試競態）
  await Promise.all([api, worker].map((p) => p && p.exitCode === null && p.signalCode === null
    ? new Promise((res) => { const t = setTimeout(() => p.kill("SIGKILL"), 3000); p.once("exit", () => { clearTimeout(t); res(null); }); })
    : null));
}

const failed = results.filter(([, ok]) => !ok);
console.log(`\n通過 ${results.length - failed.length} ／ 失敗 ${failed.length}`);
process.exit(failed.length ? 1 : 0);
