// 里程碑 1 端到端驗收（手冊 §19）：
//   登入 → 選 客戶/法人/期間 → 上傳 TB → 保存原檔與雜湊 → 驗證平衡與歸屬 → B-00 顯示結果
// 直接驅動 api＋worker 子行程，最後以 SQL 驗證資料層結果。
import { spawn, execSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { raw } from "../../packages/database/src/psql.ts";

const API = "http://127.0.0.1:8091";
const U1 = "aaaaaaaa-0000-0000-0000-000000000001";   // 職員甲：只被指派 A 案件
const T1 = "11111111-1111-1111-1111-111111111111";
const ENG_A = "eeeeeeee-0000-0000-0000-000000000001";
const ENG_B = "eeeeeeee-0000-0000-0000-000000000002";  // 甲未被指派
const LE_A = "cccccccc-0000-0000-0000-000000000001";   // A 商事，代碼 1234567890123
const PR = "99999999-0000-0000-0000-000000000001";

const results: [string, boolean, string][] = [];
const check = (name: string, ok: boolean, detail = "") => {
  results.push([name, ok, detail]);
  console.log(`  ${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  " + detail : ""}`);
};
const sql = (q: string): string => raw(q, { db: "cbfc_dev" });

async function upload(cookie: string, eng: string, le: string, pr: string, csv: string): Promise<number> {
  const body = new URLSearchParams({ engagement: eng, legal_entity: le, period_revision: pr, csv });
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
