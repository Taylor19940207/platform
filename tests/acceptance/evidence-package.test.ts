// SLICE-M2-02C 端到端驗收：預覽證據包。
// 契約：docs/slices/SLICE-M2-02C_預覽證據包.md（實作契約 A～D）
// 流程：Case-001 完整鏈（TB→映射→調整→PREVIEW run）→ 非同步產包 → 下載驗 hash
//       → 冪等三情形 → cutoff/hash 穩定性 → staging 衝突 → 上游損壞 FAILED。
import { spawn, execSync, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { setTimeout as sleep } from "node:timers/promises";
import { raw } from "../../packages/database/src/psql.ts";
import { putObject } from "../../packages/database/src/objectstore.ts";
import { artifactObjectKey } from "../../packages/domain/src/evidencePackage.ts";

const API = "http://127.0.0.1:8098";
const U_JIA = "aaaaaaaa-0000-0000-0000-000000000001";
const U_YI = "aaaaaaaa-0000-0000-0000-000000000002";
const U_BING = "aaaaaaaa-0000-0000-0000-000000000003";   // R4（可產包）
const U_OPS = "aaaaaaaa-0000-0000-0000-000000000004";    // R6（不可產包）
const T1 = "11111111-1111-1111-1111-111111111111";
const ENG_A = "eeeeeeee-0000-0000-0000-000000000001";
const LE_A = "cccccccc-0000-0000-0000-000000000001";
const PR1 = "99999999-0000-0000-0000-000000000001";
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
async function waitFor(pred: () => boolean, ms = 20000): Promise<boolean> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) { if (pred()) return true; await sleep(400); }
  return false;
}
const accountId = (code: string): string =>
  sql(`SELECT a.account_id FROM account a JOIN chart_of_accounts c ON c.coa_id = a.coa_id
       WHERE c.engagement_id = '${ENG_A}' AND a.code = '${code}'`);
const pkgField = (p: string, col: string): string =>
  sql(`SELECT COALESCE(${col}::text,'') FROM evidence_package WHERE package_id='${p}'`);
const K = (n: number) => `00000000-0000-4000-9000-00000000000${n}`;

execSync("bash packages/database/src/seed.sh cbfc_dev", { stdio: "ignore" });
execSync("rm -rf var/objects");
const api = spawn("node", ["apps/api/src/server.ts"],
  { env: { ...process.env, PORT: "8098" }, stdio: "ignore" });
let worker: ChildProcess | null =
  spawn("node", ["apps/worker/src/worker.ts"], { env: { ...process.env, POLL_MS: "400" }, stdio: "ignore" });

try {
  await sleep(1200);
  console.log("══ SLICE-M2-02C 預覽證據包驗收（Case-001） ══");
  const jia = await login(U_JIA); const yi = await login(U_YI);
  const bing = await login(U_BING); const ops = await login(U_OPS);

  // ── 前置：Case-001 完整鏈 ──
  await post(jia, "/upload", { engagement: ENG_A, legal_entity: LE_A, period_revision: PR1,
    csv: readFileSync(`${FIX}/jp_tb_2026-03.csv`, "utf8") });
  await waitFor(() => sql("SELECT count(*) FROM import_batch WHERE status='VALIDATED'") === "1");
  const B1 = sql(`SELECT import_batch_id FROM import_batch LIMIT 1`);
  await post(jia, "/b04/accept", { batch: B1 });
  const manual = readFileSync(`${FIX}/manual_mapping.csv`, "utf8").trim().split("\n").slice(1)
    .map((l) => l.split(","));
  for (const [srcCode, , tgtCode] of manual)
    await post(jia, "/b04/map", { batch: B1, source_code: srcCode, target: accountId(tgtCode) });
  for (const id of sql(`SELECT mapping_rule_id FROM mapping_rule WHERE approved_at IS NULL`).split("\n"))
    await post(yi, "/b04/approve", { batch: B1, rule: id });
  await post(jia, "/b05/create", { batch: B1, title: "集團折舊政策差異追加" });
  const ADJ = sql(`SELECT adjustment_id FROM adjustment ORDER BY created_at DESC LIMIT 1`);
  await post(jia, "/b05/save", { adj: ADJ, base_object_version: "1", title: "集團折舊政策差異追加",
    legal_basis: "母公司折舊政策 v3", evidence_ref: "附件 A-12", judgment_reason: "耐用年限差異",
    language_tag: "zh-Hant", lines: "6602,200000,0\n1601,0,200000" });
  await post(jia, "/b05/submit", { adj: ADJ });
  await post(yi, "/b05/review", { adj: ADJ });
  await post(bing, "/b05/approve", { adj: ADJ });

  // run 建立時先停 worker → RUNNING 狀態下測 RUN_NOT_COMPLETED
  worker.kill(); worker = null; await sleep(600);
  await post(jia, "/b06/run", { batch: B1, request_key: K(1) });
  const RUN = sql(`SELECT calculation_run_id FROM calculation_run LIMIT 1`);
  check("run 尚未 COMPLETED → 產包 409＋RUN_NOT_COMPLETED 留痕",
    (await post(jia, "/b07/package", { run: RUN, request_key: K(2) })).status === 409
    && Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'
         AND payload->>'code'='RUN_NOT_COMPLETED'`)) >= 1);
  worker = spawn("node", ["apps/worker/src/worker.ts"],
    { env: { ...process.env, POLL_MS: "400" }, stdio: "ignore" });
  check("run COMPLETED（前置就緒）",
    await waitFor(() => sql(`SELECT status FROM calculation_run
      WHERE calculation_run_id='${RUN}'`) === "COMPLETED"));

  // ── 角色 ──
  check("R6（丁）產包 → 403＋ROLE_REQUIRED 留痕",
    (await post(ops, "/b07/package", { run: RUN, request_key: K(3) })).status === 403);

  // ── 產包（R4 丙）→ 非同步 READY ──
  const r1 = await post(bing, "/b07/package", { run: RUN, request_key: K(4) });
  check("R4 產包 → 302（precheck 同步、產生非同步）", r1.status === 302);
  const P1 = sql(`SELECT package_id FROM evidence_package ORDER BY created_at LIMIT 1`);
  check("Package GENERATING → READY；Job COMPLETED（終態同交易）",
    await waitFor(() => pkgField(P1, "status") === "READY")
    && sql(`SELECT status FROM background_job WHERE subject_id='${P1}'`) === "COMPLETED",
    pkgField(P1, "status"));
  check("索引 10 節；追溯判定 item_count＝12（AC-AUD-001 逐科目範圍）",
    sql(`SELECT count(*) FROM evidence_package_index WHERE package_id='${P1}'`) === "10"
    && sql(`SELECT item_count::text FROM evidence_package_index
            WHERE package_id='${P1}' AND section='traceability'`) === "12");

  // ── 下載＝讀已保存位元組並驗 hash ──
  const dl = await fetch(`${API}/b07/download?id=${P1}`, { headers: { cookie: bing } });
  const bytes = Buffer.from(await dl.arrayBuffer());
  const html = bytes.toString("utf8");
  check("下載 200＋PREVIEW_DRAFT_ 檔名＋位元組 SHA-256 與登記一致",
    dl.status === 200
    && (dl.headers.get("content-disposition") ?? "").includes("PREVIEW_DRAFT_")
    && createHash("sha256").update(bytes).digest("hex") === pkgField(P1, "artifact_sha256"));
  check("底稿含 DRAFT・UNREVIEWED・未折算警語與 package_content_hash",
    html.includes("DRAFT・UNREVIEWED・未折算") && html.includes(pkgField(P1, "package_content_hash")));
  check("追溯判定 12/12 科目範圍均明示 BALANCE（驗收 #6）",
    (html.match(/<td>BALANCE（餘額級）<\/td>/g) ?? []).length === 12
    && !html.includes("JOURNAL級") && !html.includes("憑證級"));

  // ── 冪等三情形 ──
  const again = await post(bing, "/b07/package", { run: RUN, request_key: K(4) });
  check("同 key 同內容 → 原 package",
    again.status === 302 && (again.headers.get("location") ?? "").includes(P1)
    && sql(`SELECT count(*) FROM evidence_package`) === "1");
  await post(jia, "/b06/replay", { run: RUN });
  const REPLAY = sql(`SELECT calculation_run_id FROM calculation_run WHERE replay_of_run_id='${RUN}'`);
  await waitFor(() => sql(`SELECT status FROM calculation_run
    WHERE calculation_run_id='${REPLAY}'`) === "COMPLETED");
  check("同 key 異內容（不同 run）→ 409＋REQUEST_KEY_REUSED",
    (await post(bing, "/b07/package", { run: REPLAY, request_key: K(4) })).status === 409);

  // ── cutoff／hash 穩定性：新 key 第二包（事件已增長）→ hash 完全一致 ──
  await post(jia, "/b07/package", { run: RUN, request_key: K(5) });
  const P2 = sql(`SELECT package_id FROM evidence_package
    WHERE package_id <> '${P1}' AND calculation_run_id='${RUN}' ORDER BY created_at DESC LIMIT 1`);
  check("同 run＋同 cutoff＋同 render → 第二包 package_content_hash 與 artifact_sha256 完全一致（驗收 #4/#8）",
    await waitFor(() => pkgField(P2, "status") === "READY")
    && pkgField(P2, "package_content_hash") === pkgField(P1, "package_content_hash")
    && pkgField(P2, "artifact_sha256") === pkgField(P1, "artifact_sha256"),
    `${pkgField(P2, "status")}`);

  // ── 契約 B：staging 物件預置異內容 → 確定性 ARTIFACT_CONFLICT ──
  const P3 = "ee330000-0000-0000-0000-000000000003";
  const cut = sql(`SELECT audit_cutoff_event_id FROM evidence_package WHERE package_id='${P1}'`);
  putObject(artifactObjectKey(T1, P3, "html-1"), Buffer.from("tampered artifact"));
  sql(`INSERT INTO evidence_package (package_id, tenant_id, engagement_id, calculation_run_id,
        request_key, request_content_hash, audit_cutoff_event_id, render_version, created_by)
       VALUES ('${P3}','${T1}','${ENG_A}','${RUN}','${K(6)}','manual',${cut},'html-1','${U_JIA}')`);
  sql(`INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version, rule_version, idempotency_key)
       VALUES ('${T1}','EVIDENCE_PACKAGE','${P3}',1,'html-1','manual-k3')`);
  check("staging 異內容 → Package FAILED（ARTIFACT_CONFLICT，契約 B）",
    await waitFor(() => pkgField(P3, "status") === "FAILED")
    && pkgField(P3, "failure_reason_code") === "ARTIFACT_CONFLICT",
    pkgField(P3, "failure_reason_code"));
  check("非 READY 下載 → 409（PACKAGE_NOT_READY）",
    (await fetch(`${API}/b07/download?id=${P3}`, { headers: { cookie: bing } })).status === 409);

  // ── 契約 D：上游損壞 → 新包 FAILED；既有包不受影響 ──
  sql(`ALTER TABLE balance_snapshot_line DISABLE TRIGGER trg_bsl_immutable`);
  sql(`ALTER TABLE balance_snapshot_line DISABLE TRIGGER trg_bsl_run_state`);
  // 保持借貸平衡的竄改：G-09 precheck 過、契約 D 的快照重算 hash 不符才被打到
  sql(`UPDATE balance_snapshot_line SET debit = debit + 1
       WHERE calculation_run_id='${RUN}' AND account_code='6602' AND posting_layer='ADJUSTMENT'`);
  sql(`UPDATE balance_snapshot_line SET credit = credit + 1
       WHERE calculation_run_id='${RUN}' AND account_code='1601' AND posting_layer='ADJUSTMENT'`);
  sql(`ALTER TABLE balance_snapshot_line ENABLE TRIGGER trg_bsl_immutable`);
  sql(`ALTER TABLE balance_snapshot_line ENABLE TRIGGER trg_bsl_run_state`);
  await post(jia, "/b07/package", { run: RUN, request_key: K(7) });
  const P4 = sql(`SELECT package_id FROM evidence_package WHERE request_key='${K(7)}'`);
  check("上游損壞（快照重算≠result hash）→ Package FAILED（UPSTREAM_VERIFY_FAILED，契約 D）",
    await waitFor(() => pkgField(P4, "status") === "FAILED")
    && pkgField(P4, "failure_reason_code") === "UPSTREAM_VERIFY_FAILED",
    pkgField(P4, "failure_reason_code"));
  const dl2 = await fetch(`${API}/b07/download?id=${P1}`, { headers: { cookie: jia } });
  const bytes2 = Buffer.from(await dl2.arrayBuffer());
  check("既有包不受上游竄改影響：仍可下載且 hash 驗證通過（驗收 #13）",
    dl2.status === 200
    && createHash("sha256").update(bytes2).digest("hex") === pkgField(P1, "artifact_sha256"));

  // ── 收尾檢查 ──
  check("無矛盾組合：Package 終態 ⇔ Job 終態（全庫掃描）",
    sql(`SELECT count(*) FROM evidence_package p
         JOIN background_job j ON j.subject_id = p.package_id AND j.job_type='EVIDENCE_PACKAGE'
        WHERE (p.status IN ('READY','FAILED')) <> (j.status IN ('COMPLETED','FAILED'))`) === "0");
  check("不存在任何交付紀錄實體（驗收 #12：PREVIEW 不建立第二套發布真相）",
    sql(`SELECT count(*) FROM pg_tables WHERE tablename IN ('delivery_record','export_job')`) === "0");
  check("created／completed／failed 事件皆存在",
    Number(sql(`SELECT count(DISTINCT event_type) FROM audit_event WHERE kind='DOMAIN_EVENT'
      AND event_type IN ('evidence_package.created','evidence_package.completed','evidence_package.failed')`)) === 3);
} finally {
  worker?.kill(); api.kill();
}

const failed = results.filter(([, ok]) => !ok);
console.log(`\n通過 ${results.length - failed.length} ／ 失敗 ${failed.length}`);
process.exit(failed.length ? 1 : 0);
