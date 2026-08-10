// 里程碑 1 端到端驗收（手冊 §19）：
//   登入 → 選 客戶/法人/期間 → 上傳 TB → 保存原檔與雜湊 → 驗證平衡與歸屬 → B-00 顯示結果
// 直接驅動 api＋worker 子行程，最後以 SQL 驗證資料層結果。
import { spawn, execSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { raw } from "../../packages/database/src/psql.ts";

const API = "http://127.0.0.1:8091";
const U1 = "aaaaaaaa-0000-0000-0000-000000000001";   // 職員甲：只被指派 A 案件
const T1 = "11111111-1111-1111-1111-111111111111";
// R2 代傳時必須指定真正的資料提供者（該案件的有效 R1）；R1 自己上傳則不需要
const PROVIDER_R1 = "aaaaaaaa-0000-0000-0000-000000000005";
const ENG_A = "eeeeeeee-0000-0000-0000-000000000001";
const ENG_B = "eeeeeeee-0000-0000-0000-000000000002";  // 甲未被指派
const LE_A = "cccccccc-0000-0000-0000-000000000001";   // A 商事，代碼 1234567890123
const LE_A2 = "cccccccc-0000-0000-0000-000000000002";  // A 商事（上海）——同案件的第二法人
const U_YI = "aaaaaaaa-0000-0000-0000-000000000002";   // 資深乙：案件層 R2
const U_BING = "aaaaaaaa-0000-0000-0000-000000000003"; // 經理丙：案件層 R4（不得上傳）
const U_OPS = "aaaaaaaa-0000-0000-0000-000000000004";  // 系管丁：租戶層 R6
const U_TAX = "aaaaaaaa-0000-0000-0000-000000000005";  // 稅務擔當戊：案件層 R1（可上傳）
const U_TR2 = "aaaaaaaa-0000-0000-0000-000000000008";  // 租戶層辛：R2 但 engagement_id IS NULL
const PR = "99999999-0000-0000-0000-000000000001";

const results: [string, boolean, string][] = [];
const check = (name: string, ok: boolean, detail = "") => {
  results.push([name, ok, detail]);
  console.log(`  ${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  " + detail : ""}`);
};
const sql = (q: string): string => raw(q, { db: "cbfc_dev" });

async function upload(cookie: string, eng: string, le: string, pr: string, csv: string): Promise<number> {
  const body = new URLSearchParams({ engagement: eng, legal_entity: le, period_revision: pr, csv, provided_by: PROVIDER_R1 });
  const r = await fetch(`${API}/upload`, { method: "POST", redirect: "manual",
    headers: { cookie, "content-type": "application/x-www-form-urlencoded" }, body: body.toString() });
  return r.status;
}

// ── 重置環境 ──
execSync("bash packages/database/src/seed.sh cbfc_dev", { stdio: "ignore" });
execSync("rm -rf var/objects");
const api = spawn("node", ["apps/api/src/server.ts"], { env: { ...process.env, PORT: "8091" }, stdio: "ignore" });
const worker = spawn("node", ["apps/worker/src/worker.ts"], { env: { ...process.env, POLL_MS: "700" }, stdio: "ignore" });

try {
  await sleep(1200);
  console.log("══ 里程碑 1 端到端驗收 ══");

  // 1 登入
  const login = await fetch(`${API}/login?u=${U1}&t=${T1}`, { redirect: "manual" });
  const cookie = (login.headers.get("set-cookie") ?? "").split(";")[0];
  check("登入取得 session cookie", cookie.startsWith("s="));

  // 2 B-00 只顯示被指派的案件（WKB-a）
  let home = await (await fetch(`${API}/`, { headers: { cookie } })).text();
  check("B-00：顯示被指派的 A 商事", home.includes("A 商事株式会社"));
  check("B-00：不顯示未被指派的 B 工業（名稱不得出現）", !home.includes("B 工業"));

  // 3 正常上傳：平衡＋正確法人代碼 → VALIDATED / MATCHED
  const okCsv = "#legal_entity_code=1234567890123\naccount_code,account_name,debit,credit\n1100,現金,1000,0\n4000,売上,0,1000";
  check("上傳（正常）回 302", await upload(cookie, ENG_A, LE_A, PR, okCsv) === 302);

  // 4 借貸不平 → QUARANTINED
  const unbal = "#legal_entity_code=1234567890123\naccount_code,account_name,debit,credit\n1100,現金,1000,0\n4000,売上,0,900";
  check("上傳（不平衡）回 302", await upload(cookie, ENG_A, LE_A, PR, unbal) === 302);

  // 5 錯誤法人代碼 → CONFLICT ＋ QUARANTINED
  const wrong = "#legal_entity_code=9876543210987\naccount_code,account_name,debit,credit\n1100,現金,500,0\n4000,売上,0,500";
  check("上傳（歸屬錯誤）回 302", await upload(cookie, ENG_A, LE_A, PR, wrong) === 302);

  // 6 無識別資訊 → PENDING_CONFIRMATION（仍可 VALIDATED，但不可接受）
  const noid = "account_code,account_name,debit,credit\n1100,現金,300,0\n4000,売上,0,300";
  check("上傳（無識別資訊）回 302", await upload(cookie, ENG_A, LE_A, PR, noid) === 302);

  // 7 繞過 UI：對未指派案件上傳 → 403 ＋ 違規紀錄（CTX-a）
  const st = await upload(cookie, ENG_B, LE_A, PR, okCsv);
  check("繞過 UI 對未指派案件上傳 → 403", st === 403);

  // ── 7b §24.6 ImportBatch 列：建立為 R1／R2，且必須是**案件層**指派 ──
  const login2 = async (u: string) => (await fetch(`${API}/login?u=${u}&t=${T1}`,
    { redirect: "manual" })).headers.get("set-cookie")?.split(";")[0] ?? "";
  const cYi = await login2(U_YI), cBing = await login2(U_BING);
  const cOps = await login2(U_OPS), cTax = await login2(U_TAX), cTr2 = await login2(U_TR2);
  const okCsv2 = "#legal_entity_code=1234567890123\naccount_code,account_name,debit,credit\n1100,現金,10,0\n4000,売上,0,10";
  const before = () => ({
    batches: Number(sql("SELECT count(*) FROM import_batch")),
    docs: Number(sql("SELECT count(*) FROM source_document")),
    jobs: Number(sql("SELECT count(*) FROM background_job")),
    events: Number(sql(`SELECT count(*) FROM audit_event WHERE event_type='import_batch.uploaded'`)),
  });
  const b0 = before();
  check("案件層 R1（戊）與 R2（乙）皆可上傳",
    await upload(cTax, ENG_A, LE_A, PR, okCsv2) === 302
    && await upload(cYi, ENG_A, LE_A, PR, okCsv2) === 302);
  const b1 = before();
  check("R3／R4／R6／租戶層 R2 皆 403（丙 R4、丁 R6、辛租戶層 R2）",
    await upload(cBing, ENG_A, LE_A, PR, okCsv2) === 403
    && await upload(cOps, ENG_A, LE_A, PR, okCsv2) === 403
    && await upload(cTr2, ENG_A, LE_A, PR, okCsv2) === 403);
  check("越權未寫入任何 Batch／Document／Job／DomainEvent",
    JSON.stringify(before()) === JSON.stringify(b1));

  // 同案件跨法人錯配：PR 的 ReportingUnit 是 LE_A，卻宣告 LE_A2
  check("前置成立：LE_A2 與 LE_A 同案件，且 PR 的報告單位指向 LE_A",
    sql(`SELECT count(*) FROM legal_entity WHERE legal_entity_id='${LE_A2}'
          AND engagement_id='${ENG_A}'`) === "1"
    && sql(`SELECT ru.legal_entity_id FROM period_revision pr
              JOIN reporting_period rp ON rp.reporting_period_id=pr.reporting_period_id
              JOIN reporting_unit ru ON ru.reporting_unit_id=rp.reporting_unit_id
             WHERE pr.period_revision_id='${PR}'`) === LE_A);
  const b2 = before();
  check("API：同案件 A 法人＋B 法人期間 → 403",
    await upload(cYi, ENG_A, LE_A2, PR, okCsv2) === 403);
  check("錯配未寫入任何 Batch／Document／Job／DomainEvent",
    JSON.stringify(before()) === JSON.stringify(b2));
  // DB 為最後防線：繞過應用層直接 INSERT 同樣被擋
  let dbBlocked = "";
  try {
    sql(`SET app.tenant_id='${T1}';
         INSERT INTO import_batch (tenant_id, engagement_id, declared_legal_entity_id,
                 declared_period_revision_id, uploaded_by, provided_by)
         VALUES ('${T1}','${ENG_A}','${LE_A2}','${PR}','${U_YI}','${U_YI}')`);
  } catch (e) { dbBlocked = String(e); }
  check("DB：直接 INSERT 跨法人錯配 → BATCH_ATTRIBUTION_MISMATCH",
    dbBlocked.includes("BATCH_ATTRIBUTION_MISMATCH"), dbBlocked.split("\n")[0].slice(0, 70));

  // 等 worker 消化
  for (let i = 0; i < 20; i++) {
    if (sql("SELECT count(*) FROM import_batch WHERE status IN ('UPLOADED','VALIDATING')") === "0") break;
    await sleep(700);
  }

  // ── 資料層驗證 ──
  check("正常批次 → VALIDATED ＋ MATCHED",
    sql(`SELECT status||'/'||identity_status FROM import_batch WHERE file_sha256 IS NOT NULL
         AND import_batch_id IN (SELECT import_batch_id FROM source_identity_assessment WHERE match_result='MATCH')
         AND quarantine_reason IS NULL LIMIT 1`) === "VALIDATED/MATCHED");
  check("不平衡批次 → QUARANTINED（理由含 G-01）",
    sql("SELECT count(*) FROM import_batch WHERE status='QUARANTINED' AND quarantine_reason LIKE '%G-01%'") === "1");
  check("歸屬錯誤批次 → identity_status=CONFLICT ＋ QUARANTINED",
    sql("SELECT count(*) FROM import_batch WHERE status='QUARANTINED' AND identity_status='CONFLICT'") === "1");
  check("無識別資訊批次 → PENDING_CONFIRMATION ＋ VALIDATED",
    sql("SELECT count(*) FROM import_batch WHERE status='VALIDATED' AND identity_status='PENDING_CONFIRMATION'") === "1");
  check("CONFLICT 批次無法接受（DB 層雙防線）",
    (() => { try {
      raw("UPDATE import_batch SET status='ACCEPTED' WHERE identity_status='CONFLICT'", { db: "cbfc_dev" });
      return false;   // 不該成功
    } catch (e) {
      // 兩層都算正確阻擋：已隔離者先被狀態機擋（非法狀態遷移）；
      // 若仍在 VALIDATED 則由接受判定式擋（G-01/INV-28）
      const msg = String(e);
      return msg.includes("G-01/INV-28") || msg.includes("非法狀態遷移");
    } })());
  check("原檔雜湊已保存且經 worker 重算驗證",
    Number(sql("SELECT count(*) FROM import_batch WHERE hash_verified AND file_sha256 IS NOT NULL")) >= 3);
  check("來源列已物化為不可變事實（SourceLedgerLine）",
    Number(sql("SELECT count(*) FROM source_ledger_line")) >= 6);
  check("違規嘗試已寫入稽核軌跡（CONTROL_VIOLATION_ATTEMPT）",
    Number(sql("SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'")) >= 1);
  check("上傳與驗證的 DomainEvent 已記錄",
    Number(sql("SELECT count(*) FROM audit_event WHERE kind='DOMAIN_EVENT'")) >= 6);

  // 8 B-00 顯示處理結果（四欄脈絡＋狀態徽章）
  home = await (await fetch(`${API}/`, { headers: { cookie } })).text();
  check("B-00 顯示 VALIDATED 徽章", home.includes("st-VALIDATED"));
  check("B-00 顯示 QUARANTINED 與 CONFLICT", home.includes("QUARANTINED") && home.includes("CONFLICT"));
  check("B-00 每列含 客戶/法人/期間/狀態 表頭",
    home.includes("<th>客戶</th><th>法人</th><th>期間</th><th>狀態</th>"));
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
