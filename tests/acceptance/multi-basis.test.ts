// SLICE-M2-06 端到端驗收：多基礎與四類規則最小資料模型。
// 契約：docs/slices/SLICE-M2-06_多基礎與四類規則最小模型.md
//
// 這裡驗的是「接線是否真的成立」——單元與 DB 層已逐條驗過守衛本身：
//   A→C 橋樑與分層自 B-05 建立起貫穿到物化分錄；
//   Manifest 凍結基礎組成；快照帶分層；
//   INV-01（C = LOCAL_BOOK + GROUP_GAAP_ADJ）與 Case-001 的 12/12 結果一致；
//   新欄位不進 result_content_hash（重演逐位元忠實）；
//   沒有已批准組成時 fail closed，而不是靜默退化成「分層模型之前的 run」。
import { spawn, execSync, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { raw } from "../../packages/database/src/psql.ts";

const API = "http://127.0.0.1:8095";
const U_JIA = "aaaaaaaa-0000-0000-0000-000000000001";
const U_YI = "aaaaaaaa-0000-0000-0000-000000000002";
const U_BING = "aaaaaaaa-0000-0000-0000-000000000003";
const T1 = "11111111-1111-1111-1111-111111111111";
// R2 代傳時必須指定真正的資料提供者（該案件的有效 R1）；R1 自己上傳則不需要
const PROVIDER_R1 = "aaaaaaaa-0000-0000-0000-000000000005";
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
async function waitWorker(): Promise<void> {
  for (let i = 0; i < 20; i++) {
    if (sql("SELECT count(*) FROM import_batch WHERE status IN ('UPLOADED','VALIDATING')") === "0") return;
    await sleep(500);
  }
}
async function waitFor(pred: () => boolean, ms = 20000): Promise<boolean> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) { if (pred()) return true; await sleep(400); }
  return false;
}
const accountId = (code: string): string =>
  sql(`SELECT a.account_id FROM account a JOIN chart_of_accounts c ON c.coa_id = a.coa_id
       WHERE c.engagement_id = '${ENG_A}' AND a.code = '${code}'`);
const runField = (run: string, col: string): string =>
  sql(`SELECT COALESCE(${col}::text,'') FROM calculation_run WHERE calculation_run_id='${run}'`);
const K = (n: number) => `00000000-0000-4000-8000-0000000000${String(n).padStart(2, "0")}`;

execSync("bash packages/database/src/seed.sh cbfc_dev", { stdio: "ignore" });
execSync("rm -rf var/objects");
const api = spawn("node", ["apps/api/src/server.ts"],
  { env: { ...process.env, PORT: "8095" }, stdio: "ignore" });
const worker: ChildProcess =
  spawn("node", ["apps/worker/src/worker.ts"], { env: { ...process.env, POLL_MS: "400" }, stdio: "ignore" });

try {
  await sleep(1200);
  console.log("══ SLICE-M2-06 多基礎與四類規則驗收（Case-001） ══");
  const jia = await login(U_JIA);
  const yi = await login(U_YI);
  const bing = await login(U_BING);

  // ── 0 種子的多基礎設定 ──
  check("案件內 A／B／C 三基礎存在，且僅 B 為權威匯入",
    sql(`SELECT string_agg(code||':'||source_mode, ' ' ORDER BY code) FROM book_basis
         WHERE engagement_id='${ENG_A}'`)
    === "A:COMPOSED B:DIRECT_AUTHORITATIVE_IMPORT C:COMPOSED");
  check("B 基礎無組成版本（GB-02：平台不得自行推算），且有已批准的來源政策",
    sql(`SELECT count(*) FROM basis_composition_version c JOIN book_basis b ON b.basis_id=c.basis_id
         WHERE b.engagement_id='${ENG_A}' AND b.source_mode='DIRECT_AUTHORITATIVE_IMPORT'`) === "0"
    && sql(`SELECT p.status FROM book_basis b
            JOIN basis_source_policy_version p
              ON p.basis_source_policy_version_id = b.basis_source_policy_version_id
            WHERE b.engagement_id='${ENG_A}' AND b.code='B'`) === "APPROVED");
  check("LOCAL_TAX_ADJ 不出現在任何組成（A→B 是調節橋樑，不是構成關係）",
    sql(`SELECT count(*) FROM constitutive_layer_item i
         JOIN posting_layer p ON p.layer_id = i.layer_id WHERE p.code='LOCAL_TAX_ADJ'`) === "0");

  // ── 1 前置：TB → 映射 → 調整 → 批准 ──
  await post(jia, "/upload", { engagement: ENG_A, legal_entity: LE_A, period_revision: PR1, provided_by: PROVIDER_R1,
    csv: readFileSync(`${FIX}/jp_tb_2026-03.csv`, "utf8") });
  await waitWorker();
  const B1 = sql(`SELECT import_batch_id FROM import_batch WHERE declared_period_revision_id='${PR1}'`);
  await post(jia, "/b04/accept", { batch: B1 });
  const manual = readFileSync(`${FIX}/manual_mapping.csv`, "utf8").trim().split("\n").slice(1)
    .map((l) => l.split(","));
  for (const [srcCode, , tgtCode] of manual)
    await post(jia, "/b04/map", { batch: B1, source_code: srcCode, target: accountId(tgtCode) });
  for (const id of sql(`SELECT mapping_rule_id FROM mapping_rule WHERE approved_at IS NULL`).split("\n"))
    await post(yi, "/b04/approve", { batch: B1, rule: id });

  await post(jia, "/b05/create", { batch: B1, title: "集團折舊政策差異追加" });
  const ADJ = sql(`SELECT adjustment_id FROM adjustment ORDER BY created_at DESC LIMIT 1`);
  check("B-05 建立的調整帶 A→C 橋樑與 GROUP_GAAP_ADJ 分層（不再是 basis 字串欄）",
    sql(`SELECT bf.code||'→'||bt.code||'@'||pl.code FROM adjustment a
         JOIN book_basis bf ON bf.basis_id=a.basis_from_id
         JOIN book_basis bt ON bt.basis_id=a.basis_to_id
         JOIN posting_layer pl ON pl.layer_id=a.posting_layer_id
         WHERE a.adjustment_id='${ADJ}'`) === "A→C@GROUP_GAAP_ADJ");
  await post(jia, "/b05/save", { adj: ADJ, base_object_version: "1", title: "集團折舊政策差異追加",
    legal_basis: "母公司折舊政策 v3", evidence_ref: "附件 A-12", judgment_reason: "耐用年限差異",
    language_tag: "zh-Hant", lines: "6602,200000,0\n1601,0,200000" });
  await post(jia, "/b05/submit", { adj: ADJ });
  await post(yi, "/b05/review", { adj: ADJ });
  await post(bing, "/b05/approve", { adj: ADJ });
  check("物化分錄繼承調整的分層，且不帶 basis_id（事實只歸屬層）",
    sql(`SELECT pl.code FROM journal_entry je JOIN posting_layer pl ON pl.layer_id=je.posting_layer_id
         WHERE je.adjustment_id='${ADJ}'`) === "GROUP_GAAP_ADJ"
    && sql(`SELECT count(*) FROM information_schema.columns
            WHERE table_name='journal_entry' AND column_name='basis_id'`) === "0");
  check("adjustment.basis 硬約束欄位已退役",
    sql(`SELECT count(*) FROM information_schema.columns
         WHERE table_name='adjustment' AND column_name='basis'`) === "0");

  // ── 2 Manifest 凍結基礎組成 ──
  await post(jia, "/b06/run", { batch: B1, request_key: K(1) });
  const RUN1 = sql(`SELECT calculation_run_id FROM calculation_run WHERE import_batch_id='${B1}'`);
  check("Manifest 凍結 A 與 C 的組成版本（INV-21／INV-29 的牙齒）",
    sql(`SELECT string_agg(e.payload->>'basis_code', ',' ORDER BY e.payload->>'basis_code')
         FROM calculation_manifest_entry e JOIN calculation_run r ON r.manifest_id=e.manifest_id
         WHERE r.calculation_run_id='${RUN1}' AND e.object_type='BASIS_COMPOSITION'`) === "A,C");
  check("worker 完成計算",
    await waitFor(() => runField(RUN1, "status") === "COMPLETED"),
    `run=${runField(RUN1, "status")}`);

  // ── 3 快照帶分層；INV-01 逐科目 ──
  check("新 run 的快照全數帶分層（SOURCE_TB→LOCAL_BOOK、ADJUSTMENT→GROUP_GAAP_ADJ）",
    sql(`SELECT count(*) FROM balance_snapshot_line
         WHERE calculation_run_id='${RUN1}' AND posting_layer_id IS NULL`) === "0"
    && sql(`SELECT string_agg(DISTINCT b.posting_layer||'='||p.code, ' ' ORDER BY b.posting_layer||'='||p.code)
            FROM balance_snapshot_line b JOIN posting_layer p ON p.layer_id=b.posting_layer_id
            WHERE b.calculation_run_id='${RUN1}'`)
       === "ADJUSTMENT=GROUP_GAAP_ADJ SOURCE_TB=LOCAL_BOOK");

  const expected = readFileSync(`${FIX}/expected_adjusted_group_tb_2026-03.csv`, "utf8").trim()
    .split("\n").slice(1)
    .map((l) => { const [code, , d, c] = l.split(","); return `${code}|${(Number(d) - Number(c)).toFixed(2)}`; });
  // C 基礎餘額完全由「組成」定義：不是把快照全部加總，而是只加總 C 的構成層。
  const cBalance = sql(`SELECT a.code||'|'||f.amount::text
      FROM fn_basis_account_balance('${RUN1}',
             (SELECT basis_id FROM book_basis WHERE engagement_id='${ENG_A}' AND code='C')) f
      JOIN account a ON a.account_id = f.account_id ORDER BY a.code`).split("\n").filter(Boolean);
  const diffs = expected.filter((e) => !cBalance.includes(e))
    .concat(cBalance.filter((a) => !expected.includes(a)));
  check(`INV-01：C = LOCAL_BOOK + GROUP_GAAP_ADJ 與 Case-001 預期逐科目一致（${expected.length}/${expected.length}）`,
    diffs.length === 0 && cBalance.length === expected.length,
    diffs.length ? `差異：${diffs.join(" ")}` : "");
  check("INV-01：A 基礎只含 LOCAL_BOOK——調整層不進 A（6602 不含 +200,000）",
    sql(`SELECT f.amount::text FROM fn_basis_account_balance('${RUN1}',
           (SELECT basis_id FROM book_basis WHERE engagement_id='${ENG_A}' AND code='A')) f
         JOIN account a ON a.account_id=f.account_id WHERE a.code='6602'`)
    !== sql(`SELECT f.amount::text FROM fn_basis_account_balance('${RUN1}',
           (SELECT basis_id FROM book_basis WHERE engagement_id='${ENG_A}' AND code='C')) f
         JOIN account a ON a.account_id=f.account_id WHERE a.code='6602'`));

  // ── 4 新欄位不進結果雜湊：重演必須逐位元一致 ──
  const HASH1 = runField(RUN1, "result_content_hash");
  await post(jia, "/b06/replay", { run: RUN1 });
  const REPLAY = sql(`SELECT calculation_run_id FROM calculation_run WHERE replay_of_run_id='${RUN1}'`);
  check("重演結果雜湊與原 run 完全一致（posting_layer_id 未進 result hash）",
    await waitFor(() => runField(REPLAY, "status") === "COMPLETED")
    && runField(REPLAY, "result_content_hash") === HASH1,
    `replay=${runField(REPLAY, "status")}`);

  // ── 5 沒有已批准組成 → fail closed，不得靜默退化 ──
  sql(`ALTER TABLE basis_composition_version DISABLE TRIGGER trg_bcv_guard;
       UPDATE basis_composition_version SET status='RETIRED' WHERE engagement_id='${ENG_A}';
       ALTER TABLE basis_composition_version ENABLE TRIGGER trg_bcv_guard`);
  check("前置成立：本案件已無任何已批准的組成版本",
    sql(`SELECT count(*) FROM basis_composition_version
         WHERE engagement_id='${ENG_A}' AND status='APPROVED'`) === "0");
  const refused = await post(jia, "/b06/run", { batch: B1, request_key: K(2) });
  check("無已批准組成 → 409＋BASIS_COMPOSITION_NOT_APPROVED（不得產生看起來像歷史 run 的新 run）",
    refused.status === 409
    && Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'
                   AND payload->>'code'='BASIS_COMPOSITION_NOT_APPROVED'`)) >= 1);
  sql(`ALTER TABLE basis_composition_version DISABLE TRIGGER trg_bcv_guard;
       UPDATE basis_composition_version SET status='APPROVED' WHERE engagement_id='${ENG_A}';
       ALTER TABLE basis_composition_version ENABLE TRIGGER trg_bcv_guard`);

  // ── 6 B 基礎存在不解除 G-03 ──
  // 把期間直接置於 RECONCILING（繞過狀態機只為建立前置），否則樂觀鎖會先擋下，
  // 測試就會以「狀態不符」而不是「G-03 未實作」通過——那是假綠。
  sql(`ALTER TABLE period_revision DISABLE TRIGGER trg_period_transition;
       UPDATE period_revision SET status='RECONCILING' WHERE period_revision_id='${PR1}';
       ALTER TABLE period_revision ENABLE TRIGGER trg_period_transition`);
  check("前置成立：期間確實處於 RECONCILING，且本案件已有 B 基礎",
    sql(`SELECT status FROM period_revision WHERE period_revision_id='${PR1}'`) === "RECONCILING"
    && sql(`SELECT count(*) FROM book_basis
            WHERE engagement_id='${ENG_A}' AND source_mode='DIRECT_AUTHORITATIVE_IMPORT'`) === "1");
  let g03Msg = "";
  try {
    sql(`SET app.tenant_id = '${T1}';
         SELECT fn_period_attempt_transition('${PR1}','RECONCILING','PENDING_PKG_APPR',
           '${U_BING}','R4')`);
  } catch (e) { g03Msg = String(e); }
  check("B 基礎已存在，但 G-03 仍 fail closed（模型存在 ≠ 遞延稅結論可用）",
    g03Msg.includes("G03_NOT_IMPLEMENTED"), g03Msg.split("\n")[0].slice(0, 80));
  sql(`ALTER TABLE period_revision DISABLE TRIGGER trg_period_transition;
       UPDATE period_revision SET status='SETUP' WHERE period_revision_id='${PR1}';
       ALTER TABLE period_revision ENABLE TRIGGER trg_period_transition`);
} finally {
  worker.kill(); api.kill();
  await sleep(300);
}

const failed = results.filter(([, ok]) => !ok);
console.log(`\n共 ${results.length} 條，失敗 ${failed.length}`);
process.exit(failed.length ? 1 : 0);
