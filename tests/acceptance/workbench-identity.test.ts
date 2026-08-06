// SLICE-M2-04 端到端驗收：B-00 五佇列（角色×指派過濾＋三人分離＋R6 負面）
// ＋ B-03 UNVERIFIABLE 人工確認（明確選定 current assessment → 不可變 Resolution → G-01 接受）。
// 契約：docs/slices/SLICE-M2-04_B00待辦與身分確認.md
import { spawn, execSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { raw } from "../../packages/database/src/psql.ts";

const API = "http://127.0.0.1:8099";
const U_JIA = "aaaaaaaa-0000-0000-0000-000000000001";    // 職員甲：R2＋R3＋R4（上傳者）
const U_YI = "aaaaaaaa-0000-0000-0000-000000000002";     // 資深乙：R2＋R3＋R4
const U_BING = "aaaaaaaa-0000-0000-0000-000000000003";   // 經理丙：僅 R4
const U_DING = "aaaaaaaa-0000-0000-0000-000000000004";   // 系管丁：R6（租戶層，engagement NULL）
const T1 = "11111111-1111-1111-1111-111111111111";
const ENG_A = "eeeeeeee-0000-0000-0000-000000000001";
const LE_A = "cccccccc-0000-0000-0000-000000000001";
const PR1 = "99999999-0000-0000-0000-000000000001";

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
async function get(cookie: string, path: string): Promise<string> {
  const r = await fetch(`${API}${path}`, { headers: { cookie } });
  return r.text();
}
async function getStatus(cookie: string, path: string): Promise<number> {
  const r = await fetch(`${API}${path}`, { headers: { cookie }, redirect: "manual" });
  return r.status;
}
async function waitWorker(): Promise<void> {
  for (let i = 0; i < 25; i++) {
    if (sql("SELECT count(*) FROM import_batch WHERE status IN ('UPLOADED','VALIDATING')") === "0") return;
    await sleep(700);
  }
}
// B-00 佇列區塊抽出：qSec 產出 <h3>標題（N）</h3> 後接表格或「無」
const section = (html: string, title: string): string => {
  const i = html.indexOf(`<h3>${title}（`);
  if (i < 0) return "";
  const j = html.indexOf("<h3>", i + 4);
  return html.slice(i, j < 0 ? undefined : j);
};
const cva = (eventType: string, code?: string): number =>
  Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'
              AND event_type='${eventType}'${code ? ` AND payload->>'code'='${code}'` : ""}`));

// ── 重置環境 ──
execSync("bash packages/database/src/seed.sh cbfc_dev", { stdio: "ignore" });
execSync("rm -rf var/objects");
const api = spawn("node", ["apps/api/src/server.ts"], { env: { ...process.env, PORT: "8099" }, stdio: "ignore" });
const worker = spawn("node", ["apps/worker/src/worker.ts"], { env: { ...process.env, POLL_MS: "700" }, stdio: "ignore" });

const EVIDENCE = {
  legal_basis: "企業会計基準第29号 収益認識",
  evidence_ref: "attach-001.pdf",
  judgment_reason: "集團會計政策要求以 CAS 認列",
  language_tag: "ja-JP",
};
const OK_CSV = "#legal_entity_code=1234567890123\naccount_code,account_name,debit,credit\n1002,現金,1000,0\n4000,売上,0,1000\n";
const NOID_CSV = "account_code,account_name,debit,credit\n1002,現金,300,0\n4000,売上,0,300\n";
const WRONG_CSV = "#legal_entity_code=9876543210987\naccount_code,account_name,debit,credit\n1002,現金,500,0\n4000,売上,0,500\n";

try {
  await sleep(1200);
  console.log("══ SLICE-M2-04 B-00 佇列與身分確認驗收 ══");
  const jia = await login(U_JIA);
  const yi = await login(U_YI);
  const bing = await login(U_BING);
  const ding = await login(U_DING);

  // ── 前置：MATCHED 批次 → 接受 → 調整草稿送覆核；另一批 no-id → PENDING_CONFIRMATION ──
  await post(jia, "/upload", { engagement: ENG_A, legal_entity: LE_A, period_revision: PR1, csv: OK_CSV });
  await post(jia, "/upload", { engagement: ENG_A, legal_entity: LE_A, period_revision: PR1, csv: NOID_CSV });
  await post(jia, "/upload", { engagement: ENG_A, legal_entity: LE_A, period_revision: PR1, csv: WRONG_CSV });
  await waitWorker();
  const B1 = sql(`SELECT import_batch_id FROM import_batch WHERE identity_status='MATCHED' LIMIT 1`);
  const BU = sql(`SELECT import_batch_id FROM import_batch WHERE identity_status='PENDING_CONFIRMATION' LIMIT 1`);
  const BC = sql(`SELECT import_batch_id FROM import_batch WHERE identity_status='CONFLICT' LIMIT 1`);
  check("前置：MATCHED／PENDING_CONFIRMATION／CONFLICT 三批次就緒", !!B1 && !!BU && !!BC);
  check("worker：Assessment 與 current 指標同交易寫入（指標＝該批次唯一評估）",
    sql(`SELECT (ib.current_identity_assessment_id = a.assessment_id)::text
         FROM import_batch ib JOIN source_identity_assessment a ON a.import_batch_id = ib.import_batch_id
         WHERE ib.import_batch_id='${BU}'`) === "true");
  await post(jia, "/b04/accept", { batch: B1 });
  await post(jia, "/b05/create", { batch: B1, title: "GROUP_GAAP 調整" });
  const ADJ = sql(`SELECT adjustment_id FROM adjustment ORDER BY created_at DESC LIMIT 1`);
  await post(jia, "/b05/save", { adj: ADJ, base_object_version: "1", title: "GROUP_GAAP 調整",
    ...EVIDENCE, lines: "1002,1234.56,0\n6602,0,1234.56" });
  check("前置：甲編製調整並送覆核（PENDING_REVIEW）",
    await post(jia, "/b05/submit", { adj: ADJ }) === 302
    && sql(`SELECT status FROM adjustment WHERE adjustment_id='${ADJ}'`) === "PENDING_REVIEW");

  // ── 佇列 1：待身分確認（R2；CONFLICT／QUARANTINED 不入列） ──
  let homeYi = await get(yi, "/");
  let sec = section(homeYi, "待身分確認");
  check("待身分確認：乙（R2）見 no-id 批次", sec.includes(BU.slice(0, 8)));
  check("待身分確認：CONFLICT（已隔離）不入佇列", !sec.includes(BC.slice(0, 8)));
  check("待身分確認：一鍵直達確認頁連結", sec.includes(`/b03/identity?batch=${BU}`));
  check("四欄脈絡：客戶×法人×期間出現在佇列列上",
    sec.includes("A 商事株式会社") && sec.includes("2026-03"));

  // ── 佇列 2／3：三人分離（SOD-01＋AC-WFL-001＋SOD-02） ──
  let homeJia = await get(jia, "/");
  check("待覆核：乙（R3）見甲編製的調整", section(homeYi, "待覆核").includes("GROUP_GAAP 調整"));
  check("待覆核：甲（編製人）不見自己的調整（SOD-01）",
    !section(homeJia, "待覆核").includes("GROUP_GAAP 調整"));
  check("等待他人：自己送出的項目不入任何可處理佇列",
    !section(homeJia, "未完成草稿").includes("GROUP_GAAP 調整"));
  check("乙覆核 → PENDING_APPROVAL", await post(yi, "/b05/review", { adj: ADJ }) === 302);
  homeJia = await get(jia, "/"); homeYi = await get(yi, "/");
  const homeBing = await get(bing, "/");
  check("待批准：只有丙（R4，非編製非覆核）見", section(homeBing, "待批准").includes("GROUP_GAAP 調整"));
  check("待批准：甲（編製人，具 R4）不見（AC-WFL-001）",
    !section(homeJia, "待批准").includes("GROUP_GAAP 調整"));
  check("待批准：乙（覆核人，具 R4）不見（SOD-02）",
    !section(homeYi, "待批准").includes("GROUP_GAAP 調整"));

  // ── 佇列 4／5：退回與未完成草稿 ──
  check("丙退回（附理由分類）", await post(bing, "/b05/return",
    { adj: ADJ, reason_category: "MISSING_EVIDENCE", reason_note: "附件不足" }) === 302);
  homeJia = await get(jia, "/"); homeYi = await get(yi, "/");
  sec = section(homeJia, "被退回／待補證據");
  check("被退回：甲見自己被退回的調整＋理由分類",
    sec.includes("GROUP_GAAP 調整") && sec.includes("MISSING_EVIDENCE"));
  check("被退回：乙不見（非本人編製）", !section(homeYi, "被退回／待補證據").includes("GROUP_GAAP"));
  check("未完成草稿：甲見退回後的 DRAFTING 調整",
    section(homeJia, "未完成草稿").includes("GROUP_GAAP 調整"));
  check("空佇列顯示「無」而非隱藏", section(homeBing, "被退回／待補證據").includes("無"));

  // ── R6 負面（WKB-a：租戶層角色不得取得客戶工作存取權） ──
  const homeDing = await get(ding, "/");
  check("R6 丁：B-00 不出現任何客戶名稱", !homeDing.includes("A 商事") && !homeDing.includes("B 工業"));
  check("R6 丁：五佇列全空（無明細、無計數洩漏）",
    ["待身分確認", "待覆核", "待批准", "被退回／待補證據", "未完成草稿"]
      .every((t) => homeDing.includes(`<h3>${t}（0）</h3>`)));
  const cvaView0 = cva("identity.view.denied");
  check("R6 丁：直開確認頁 → 403", await getStatus(ding, `/b03/identity?batch=${BU}`) === 403);
  check("R6 丁：確認頁拒絕寫入 CVA", cva("identity.view.denied") === cvaView0 + 1);

  // ── B-03 確認頁內容（決策 4） ──
  const AID = sql(`SELECT current_identity_assessment_id FROM import_batch WHERE import_batch_id='${BU}'`);
  const pageYi = await get(yi, `/b03/identity?batch=${BU}`);
  check("確認頁：宣告目標含法人權威代碼與檔案雜湊",
    pageYi.includes("1234567890123") && pageYi.includes("宣告目標"));
  check("確認頁：評估列含證據強度、判定、規則版本與 current 標記",
    pageYi.includes("✓ current") && pageYi.includes("UNVERIFIABLE"));
  check("確認頁：表單以 current assessment 明確選定", pageYi.includes(`value="${AID}"`));

  // ── 確認提交的控制邊界（決策 7／10） ──
  const cvaRole0 = cva("identity.confirm.denied", "ROLE_REQUIRED");
  const cvaSod0 = cva("identity.confirm.denied", "SOD_07");
  const cvaAll0 = Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'`));
  check("理由空白 → 409（REASON_REQUIRED）", await post(yi, "/b03/identity/confirm",
    { batch: BU, assessment_id: AID, reason: "  " }) === 409);
  check("理由空白：一般欄位錯誤不寫 CVA（§25.18）",
    Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'`)) === cvaAll0);
  check("非 R2（丙，僅 R4）提交 → 403", await post(bing, "/b03/identity/confirm",
    { batch: BU, assessment_id: AID, reason: "我覺得可以" }) === 403);
  check("非 R2 拒絕寫 CVA（ROLE_REQUIRED）", cva("identity.confirm.denied", "ROLE_REQUIRED") === cvaRole0 + 1);
  check("上傳者甲提交 → 403（SOD-07，角色切換無效）", await post(jia, "/b03/identity/confirm",
    { batch: BU, assessment_id: AID, reason: "是我上傳的沒錯" }) === 403);
  check("SOD-07 拒絕寫 CVA", cva("identity.confirm.denied", "SOD_07") === cvaSod0 + 1);

  // 同批次兩筆評估並存：只有明確選定且＝current 的可提交（CTX-e／決策 5）
  sql(`SET app.tenant_id='${T1}';
       INSERT INTO source_identity_assessment (tenant_id, import_batch_id, batch_version,
              match_result, evidence_kind, detection_rule_version)
       VALUES ('${T1}','${BU}',1,'UNVERIFIABLE','NONE','r9')`);
  const AID2 = sql(`SELECT assessment_id FROM source_identity_assessment
                    WHERE import_batch_id='${BU}' AND detection_rule_version='r9'`);
  const cvaCur0 = cva("identity.confirm.rejected", "NOT_CURRENT_ASSESSMENT");
  check("選定非 current 評估 → 409", await post(yi, "/b03/identity/confirm",
    { batch: BU, assessment_id: AID2, reason: "選錯一筆" }) === 409);
  check("非 current 拒絕寫 CVA（NOT_CURRENT_ASSESSMENT）",
    cva("identity.confirm.rejected", "NOT_CURRENT_ASSESSMENT") === cvaCur0 + 1);
  const pageTwo = await get(yi, `/b03/identity?batch=${BU}`);
  check("兩筆評估全部顯示（歷史不隱藏）",
    pageTwo.includes("✓ current") && pageTwo.includes("（歷史）"));

  // ── 合法確認：單一交易（Resolution＋MANUALLY_RESOLVED＋DomainEvent） ──
  check("乙（R2、非上傳者）確認成功 → 302", await post(yi, "/b03/identity/confirm",
    { batch: BU, assessment_id: AID, reason: "已向客戶電話確認為 A 商事株式会社", evidence_ref: "tel-memo-001" }) === 302);
  check("identity_status → MANUALLY_RESOLVED",
    sql(`SELECT identity_status FROM import_batch WHERE import_batch_id='${BU}'`) === "MANUALLY_RESOLVED");
  check("Resolution 保存：選定評估、確認者乙、理由、證據、該筆規則版本",
    sql(`SELECT count(*) FROM source_identity_resolution
         WHERE import_batch_id='${BU}' AND assessment_id='${AID}'
           AND resolved_by='${U_YI}' AND evidence_ref='tel-memo-001'
           AND detection_rule_version=(SELECT detection_rule_version
                FROM source_identity_assessment WHERE assessment_id='${AID}')`) === "1");
  check("DomainEvent：import_batch.identity_resolved（payload 含 assessment 與規則版本）",
    sql(`SELECT count(*) FROM audit_event WHERE kind='DOMAIN_EVENT'
         AND event_type='import_batch.identity_resolved' AND object_id='${BU}'
         AND payload->>'assessment_id'='${AID}'
         AND payload ? 'detection_rule_version' AND payload ? 'alias_table_version'`) === "1");
  check("確認不自動接受（CTX-g）：批次仍為 VALIDATED",
    sql(`SELECT status FROM import_batch WHERE import_batch_id='${BU}'`) === "VALIDATED");
  const cvaState0 = cva("identity.confirm.rejected", "STATE_NOT_CONFIRMABLE");
  check("已確認後再提交 → 409（狀態白名單）", await post(yi, "/b03/identity/confirm",
    { batch: BU, assessment_id: AID, reason: "再確認一次" }) === 409);
  check("狀態拒絕寫 CVA（STATE_NOT_CONFIRMABLE）",
    cva("identity.confirm.rejected", "STATE_NOT_CONFIRMABLE") === cvaState0 + 1);
  homeYi = await get(yi, "/");
  check("確認後離開待身分確認佇列", !section(homeYi, "待身分確認").includes(BU.slice(0, 8)));
  check("接受（G-01：MANUALLY_RESOLVED＋雜湊）→ ACCEPTED",
    await post(jia, "/b04/accept", { batch: BU }) === 302
    && sql(`SELECT status FROM import_batch WHERE import_batch_id='${BU}'`) === "ACCEPTED");

  // ── CTX-e：效力只及該批次（版本）——新上傳需重新確認，原紀錄並存 ──
  await post(jia, "/upload", { engagement: ENG_A, legal_entity: LE_A, period_revision: PR1, csv: NOID_CSV });
  await waitWorker();
  const BU2 = sql(`SELECT import_batch_id FROM import_batch
                   WHERE identity_status='PENDING_CONFIRMATION' AND import_batch_id<>'${BU}' LIMIT 1`);
  check("CTX-e：重新上傳的同內容批次仍需重新確認（不沿用舊 Resolution）",
    !!BU2 && sql(`SELECT count(*) FROM source_identity_resolution WHERE import_batch_id='${BU2}'`) === "0");
  check("原確認紀錄並存於已接受批次",
    sql(`SELECT count(*) FROM source_identity_resolution WHERE import_batch_id='${BU}'`) === "1");

  // ── 映射草稿：不可變來源批次脈絡＋可用的一鍵回位（0020 source_import_batch_id） ──
  const ACCT = sql(`SELECT a.account_id FROM account a
                    JOIN chart_of_accounts c ON c.coa_id = a.coa_id
                    WHERE c.engagement_id='${ENG_A}' LIMIT 1`);
  check("甲建立映射草稿（B-04，來源批次 B1）", await post(jia, "/b04/map",
    { batch: B1, source_code: "9999", target: ACCT }) === 302);
  check("映射草稿保存來源批次脈絡",
    sql(`SELECT source_import_batch_id FROM mapping_rule WHERE source_account_code='9999'`) === B1);
  homeJia = await get(jia, "/");
  sec = section(homeJia, "未完成草稿");
  check("映射草稿列：四欄脈絡為真實法人與期間（非破折號）",
    sec.includes("9999") && sec.includes("A 商事株式会社") && sec.includes("2026-03"));
  check("映射草稿列：一鍵回位連結指向來源批次的 B-04", sec.includes(`/b04?batch=${B1}`));
  check("一鍵回位連結實際可用（200）", await getStatus(jia, `/b04?batch=${B1}`) === 200);
  check("來源批次脈絡不可變更（DB 守衛）", (() => {
    try {
      sql(`SET app.tenant_id='${T1}';
           UPDATE mapping_rule SET source_import_batch_id='${BU}' WHERE source_account_code='9999'`);
      return false;
    } catch { return true; }
  })());

  // ── 佇列 1 收緊：待身分確認只收 VALIDATED（VALIDATING 中不入列） ──
  const BV = "00000000-0000-0000-0000-0000000000e1";
  sql(`SET app.tenant_id='${T1}';
       INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
              declared_period_revision_id, uploaded_by, provided_by, file_name, file_sha256, status)
       VALUES ('${BV}','${T1}','${ENG_A}','${LE_A}','${PR1}','${U_JIA}','${U_JIA}','v.csv','hv','UPLOADED');
       UPDATE import_batch SET status='VALIDATING' WHERE import_batch_id='${BV}';
       INSERT INTO source_identity_assessment (assessment_id, tenant_id, import_batch_id, batch_version,
              match_result, evidence_kind, detection_rule_version)
       VALUES ('aa990000-0000-0000-0000-000000000001','${T1}','${BV}',1,'UNVERIFIABLE','NONE','rv');
       UPDATE import_batch SET identity_status='PENDING_CONFIRMATION',
              current_identity_assessment_id='aa990000-0000-0000-0000-000000000001'
        WHERE import_batch_id='${BV}'`);
  homeJia = await get(jia, "/");
  check("待身分確認只收 VALIDATED：VALIDATING 中的 PENDING_CONFIRMATION 不入列",
    !section(homeJia, "待身分確認").includes(BV.slice(0, 8)));

  // ── WKB-b：撤銷指派即時生效——佇列消失、既有連結被拒 ──
  sql(`SET app.tenant_id='${T1}';
       UPDATE role_assignment SET revoked_at=now()
       WHERE user_id='${U_YI}' AND engagement_id='${ENG_A}'`);
  homeYi = await get(yi, "/");
  check("撤銷後：乙的 B-00 不再出現 A 商事名稱與項目", !homeYi.includes("A 商事"));
  check("撤銷後：既有確認頁連結被拒（403）", await getStatus(yi, `/b03/identity?batch=${BU2}`) === 403);
} finally {
  api.kill(); worker.kill();
  // 等子行程真正退出——殘留 worker 會搶先認領下一支測試的工作（跨測試競態）
  await Promise.all([api, worker].map((p) => p && p.exitCode === null && p.signalCode === null
    ? new Promise((res) => { const t = setTimeout(() => p.kill("SIGKILL"), 3000); p.once("exit", () => { clearTimeout(t); res(null); }); })
    : null));
}

const failed = results.filter(([, ok]) => !ok).length;
console.log(`\n共 ${results.length} 條，失敗 ${failed}`);
process.exit(failed ? 1 : 0);
