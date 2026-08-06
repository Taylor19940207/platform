// SLICE-M2-01 端到端驗收：ACCEPTED TB → 版本化映射 → 集團科目 TB 預覽。
// 以 Case-001 資料包驗證，並與現行 Excel 結果（expected_group_tb_2026-03.csv）逐科目比對。
// 核心價值驗證：第一次建立映射後，下一期（2026-04）自動複用，使用者只處理例外（新科目 631）。
import { spawn, execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { raw } from "../../packages/database/src/psql.ts";

const API = "http://127.0.0.1:8092";
const U_STAFF = "aaaaaaaa-0000-0000-0000-000000000001";   // 職員甲：R2（A 案件）
const U_SENIOR = "aaaaaaaa-0000-0000-0000-000000000002";  // 資深乙：R2＋R4（A 案件）
const T1 = "11111111-1111-1111-1111-111111111111";
const ENG_A = "eeeeeeee-0000-0000-0000-000000000001";
const LE_A = "cccccccc-0000-0000-0000-000000000001";
const PR1 = "99999999-0000-0000-0000-000000000001";       // 2026-03
const PR2 = "99999999-0000-0000-0000-000000000002";       // 2026-04
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
async function post(cookie: string, path: string, fields: Record<string, string>): Promise<number> {
  const r = await fetch(`${API}${path}`, { method: "POST", redirect: "manual",
    headers: { cookie, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(fields).toString() });
  return r.status;
}
async function upload(cookie: string, pr: string, csvPath: string): Promise<number> {
  return post(cookie, "/upload", { engagement: ENG_A, legal_entity: LE_A,
    period_revision: pr, csv: readFileSync(csvPath, "utf8") });
}
async function waitWorker(): Promise<void> {
  for (let i = 0; i < 20; i++) {
    if (sql("SELECT count(*) FROM import_batch WHERE status IN ('UPLOADED','VALIDATING')") === "0") return;
    await sleep(700);
  }
}
const accountId = (code: string): string =>
  sql(`SELECT a.account_id FROM account a JOIN chart_of_accounts c ON c.coa_id = a.coa_id
       WHERE c.engagement_id = '${ENG_A}' AND a.code = '${code}'`);
/** 集團 TB 聚合（目前生效映射 × 批次來源列），輸出 code|debit|credit 列。 */
const groupTb = (batch: string): string[] =>
  sql(`SELECT a.code || '|' || SUM(l.debit)::text || '|' || SUM(l.credit)::text
         FROM source_ledger_line l
         JOIN (SELECT DISTINCT ON (source_account_code) source_account_code, target_account_id
                 FROM mapping_rule WHERE engagement_id = '${ENG_A}' AND approved_at IS NOT NULL
                 ORDER BY source_account_code, version_no DESC) m
           ON m.source_account_code = l.account_code
         JOIN account a ON a.account_id = m.target_account_id
        WHERE l.import_batch_id = '${batch}'
        GROUP BY a.code ORDER BY a.code`).split("\n").filter(Boolean);

// ── 重置環境 ──
execSync("bash packages/database/src/seed.sh cbfc_dev", { stdio: "ignore" });
execSync("rm -rf var/objects");
const api = spawn("node", ["apps/api/src/server.ts"], { env: { ...process.env, PORT: "8092" }, stdio: "ignore" });
const worker = spawn("node", ["apps/worker/src/worker.ts"], { env: { ...process.env, POLL_MS: "700" }, stdio: "ignore" });

try {
  await sleep(1200);
  console.log("══ SLICE-M2-01 映射切片驗收（Case-001） ══");
  const staff = await login(U_STAFF);
  const senior = await login(U_SENIOR);

  // ── 第一期：2026-03 ──
  check("上傳 Case-001 2026-03 TB 回 302", await upload(staff, PR1, `${FIX}/jp_tb_2026-03.csv`) === 302);
  await waitWorker();
  const B1 = sql(`SELECT import_batch_id FROM import_batch WHERE declared_period_revision_id='${PR1}'`);
  check("批次通過驗證（VALIDATED／MATCHED）",
    sql(`SELECT status||'/'||identity_status FROM import_batch WHERE import_batch_id='${B1}'`) === "VALIDATED/MATCHED");
  check("接受批次 → ACCEPTED（G-01 接受判定式）", await post(staff, "/b04/accept", { batch: B1 }) === 302
    && sql(`SELECT status FROM import_batch WHERE import_batch_id='${B1}'`) === "ACCEPTED");
  check("重複接受被拒（409）", await post(staff, "/b04/accept", { batch: B1 }) === 409);

  // 未映射狀態與 G-02 阻擋
  let b04 = await (await fetch(`${API}/b04?batch=${B1}`, { headers: { cookie: staff } })).text();
  check("B-04 顯示 15 個未映射科目與覆蓋率 0.0%",
    b04.includes("未映射科目 <b>15</b>") && b04.includes("0.0%"));
  check("G-02：未映射時「映射完成確認」被拒（409）", await post(staff, "/b04/submit", { batch: B1 }) === 409);
  check("G-02 拒絕已寫入 ControlViolationAttempt",
    Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'
                AND payload->>'guard'='G-02'`)) >= 1);

  // 依現行人工映射表建立 15 條草稿（甲）
  const manual = readFileSync(`${FIX}/manual_mapping.csv`, "utf8").trim().split("\n").slice(1)
    .map((l) => l.split(","));
  for (const [srcCode, , tgtCode] of manual)
    await post(staff, "/b04/map", { batch: B1, source_code: srcCode, target: accountId(tgtCode) });
  check("依人工映射表建立 15 條草稿",
    sql(`SELECT count(*) FROM mapping_rule WHERE engagement_id='${ENG_A}' AND approved_at IS NULL`) === "15");

  // SOD：建立者不得批准自己；R4 才可批准
  const draftIds = sql(`SELECT mapping_rule_id FROM mapping_rule
    WHERE engagement_id='${ENG_A}' AND approved_at IS NULL ORDER BY source_account_code`).split("\n");
  check("SOD：建立者（甲）批准自己 → 403", await post(staff, "/b04/approve", { batch: B1, rule: draftIds[0] }) === 403);
  for (const id of draftIds) await post(senior, "/b04/approve", { batch: B1, rule: id });
  check("R4（乙）批准全部 15 條映射",
    sql(`SELECT count(*) FROM mapping_rule WHERE engagement_id='${ENG_A}' AND approved_at IS NOT NULL`) === "15");

  // 跨案件誤用：目標科目屬 B 案件 → 拒絕＋留痕（§24.1A）
  const bAccount = sql(`SELECT a.account_id FROM account a JOIN chart_of_accounts c ON c.coa_id=a.coa_id
    WHERE c.engagement_id='eeeeeeee-0000-0000-0000-000000000002'`);
  check("跨案件誤用：映射指向 B 案件科目 → 403＋違規留痕",
    await post(staff, "/b04/map", { batch: B1, source_code: "100", target: bAccount }) === 403
    && Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'
                   AND payload->>'guard'='歸屬/§24.1A'`)) >= 1);

  // 與現行 Excel 結果逐科目比對
  const expected = readFileSync(`${FIX}/expected_group_tb_2026-03.csv`, "utf8").trim().split("\n").slice(1)
    .map((l) => { const [code, , d, c] = l.split(","); return `${code}|${Number(d).toFixed(2)}|${Number(c).toFixed(2)}`; });
  const actual = groupTb(B1);
  const diffs = expected.filter((e) => !actual.includes(e)).concat(actual.filter((a) => !expected.includes(a)));
  check(`集團 TB 與 Excel 預期逐科目一致（${expected.length}/${expected.length}）`,
    diffs.length === 0 && actual.length === expected.length, diffs.length ? `差異：${diffs.join(" ")}` : "");

  // 預覽頁：PREVIEW 標示＋控制總額勾稽
  const pv = await (await fetch(`${API}/b04/preview?batch=${B1}`, { headers: { cookie: staff } })).text();
  check("預覽頁標示 PREVIEW 非正式輸出", pv.includes("PREVIEW") && pv.includes("不得作為入帳或交付依據"));
  check("控制總額勾稽一致（借貸各 58,800,000）",
    pv.includes("58,800,000") && pv.includes("一致") && !pv.includes("不一致"));
  check("多對一正確（1002 银行存款 9,650,000；6602 管理费用 14,400,000）",
    pv.includes("9,650,000") && pv.includes("14,400,000"));
  check("全數映射後 G-02 通過", await post(staff, "/b04/submit", { batch: B1 }) === 200);

  // ── 第二期：2026-04（核心價值：自動複用＋只處理例外） ──
  check("上傳 2026-04 TB 回 302", await upload(staff, PR2, `${FIX}/jp_tb_2026-04.csv`) === 302);
  await waitWorker();
  const B2 = sql(`SELECT import_batch_id FROM import_batch WHERE declared_period_revision_id='${PR2}'`);
  await post(staff, "/b04/accept", { batch: B2 });
  b04 = await (await fetch(`${API}/b04?batch=${B2}`, { headers: { cookie: staff } })).text();
  check("下一期自動複用：僅新科目 631 未映射，其餘既有映射直接套用",
    b04.includes("未映射科目 <b>1</b>") && b04.includes("631"));
  check("既有 15 條映射零新增即複用（映射總數仍為 15）",
    sql(`SELECT count(*) FROM mapping_rule WHERE engagement_id='${ENG_A}'`) === "15");
  check("G-02 只擋例外：631 未映射 → 409", await post(staff, "/b04/submit", { batch: B2 }) === 409);
  await post(staff, "/b04/map", { batch: B2, source_code: "631", target: accountId("6602") });
  const d631 = sql(`SELECT mapping_rule_id FROM mapping_rule WHERE source_account_code='631' AND approved_at IS NULL`);
  await post(senior, "/b04/approve", { batch: B2, rule: d631 });
  check("例外處理完成（631 → 6602 v1 批准）後 G-02 通過", await post(staff, "/b04/submit", { batch: B2 }) === 200);
  const g2 = groupTb(B2);
  check("2026-04 集團 TB 正確且借貸平衡（12,000,000）",
    g2.includes("1002|6000000.00|0.00") && g2.includes("6602|150000.00|0.00")
    && g2.includes("2202|0.00|2000000.00") && g2.length === 6);

  // DomainEvent 完整性
  check("映射建立／批准／接受／預覽皆有 DomainEvent",
    Number(sql(`SELECT count(DISTINCT event_type) FROM audit_event WHERE kind='DOMAIN_EVENT'
      AND event_type IN ('mapping_rule.drafted','mapping_rule.approved','import_batch.accepted','group_tb.preview_generated','mapping.review_ready')`)) === 5);

  // ── 邊界：映射版本按報告期間生效日解析（effective_from） ──
  // 為 600 建 v2 → 6602，effective_from=2026-04-01：
  // 2026-03 期（期末 03-31）仍解析到 v1（6401），2026-04 期（期末 04-30）改用 v2。
  await post(staff, "/b04/map", { batch: B2, source_code: "600", target: accountId("6602") });
  const d600 = sql(`SELECT mapping_rule_id FROM mapping_rule WHERE source_account_code='600' AND approved_at IS NULL`);
  sql(`UPDATE mapping_rule SET effective_from='2026-04-01' WHERE mapping_rule_id='${d600}'`);
  await post(senior, "/b04/approve", { batch: B2, rule: d600 });
  const pvMar = await (await fetch(`${API}/b04/preview?batch=${B1}`, { headers: { cookie: staff } })).text();
  const pvApr = await (await fetch(`${API}/b04/preview?batch=${B2}`, { headers: { cookie: staff } })).text();
  check("生效日解析：2026-03 期不受未來版本影響（600 仍在 6401：21,700,000）",
    pvMar.includes("6401") && pvMar.includes("21,700,000"));
  check("生效日解析：2026-04 期起用 v2（600 併入 6602：1,850,000；6401 消失）",
    !pvApr.includes("6401") && pvApr.includes("1,850,000"));

  // ── 事件原子化（BACKLOG 2026-08-04）：資料與事件不存在單邊 ──
  check("事件原子化：每列 mapping_rule 皆有 drafted 事件、每個已批准列皆有 approved 事件",
    sql(`SELECT count(*) FROM mapping_rule mr WHERE NOT EXISTS (
           SELECT 1 FROM audit_event e WHERE e.event_type='mapping_rule.drafted'
             AND e.object_id = mr.mapping_rule_id)`) === "0"
    && sql(`SELECT count(*) FROM mapping_rule mr WHERE mr.approved_at IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM audit_event e WHERE e.event_type='mapping_rule.approved'
             AND e.object_id = mr.mapping_rule_id)`) === "0");
  const someApproved = sql(`SELECT mapping_rule_id FROM mapping_rule
    WHERE approved_at IS NOT NULL ORDER BY created_at LIMIT 1`);
  check("重複批准 → 404/409，且 approved 事件不重複",
    [404, 409].includes(await post(senior, "/b04/approve", { batch: B1, rule: someApproved }))
    && sql(`SELECT count(*) FROM audit_event WHERE event_type='mapping_rule.approved'
            AND object_id='${someApproved}'`) === "1");
} finally {
  api.kill(); worker.kill();
  // 等子行程真正退出——殘留 worker 會搶先認領下一支測試的工作（跨測試競態）
  await Promise.all([api, worker].map((p) => p && p.exitCode === null && p.signalCode === null
    ? new Promise((res) => { const t = setTimeout(() => p.kill("SIGKILL"), 3000); p.once("exit", () => { clearTimeout(t); res(null); }); })
    : null));
}

const fails = results.filter(([, ok]) => !ok).length;
console.log(`\n通過 ${results.length - fails} ／ 失敗 ${fails}`);
process.exit(fails === 0 ? 0 : 1);
