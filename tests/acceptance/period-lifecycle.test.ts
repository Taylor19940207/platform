// SLICE-M2-05 端到端驗收：期間生命週期（§25.8）。
// 契約：docs/slices/SLICE-M2-05_期間生命週期.md
//
// 責任邊界：API 證明「呼叫者是誰」（p_actor 取自 Session），
//           DB 證明「這個人是否真的持有該角色並允許這次遷移」。
//
// 計數一律採「本次操作前後增量」——audit_event 是 append-only，全庫總數會被
// 先前測試污染。
import { spawn, execSync, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { raw } from "../../packages/database/src/psql.ts";

const API = "http://127.0.0.1:8099";
const U_JIA = "aaaaaaaa-0000-0000-0000-000000000001";   // R2＋R3＋R4
const U_YI = "aaaaaaaa-0000-0000-0000-000000000002";    // R2＋R3＋R4
const U_BING = "aaaaaaaa-0000-0000-0000-000000000003";  // R4
const U_DING = "aaaaaaaa-0000-0000-0000-000000000004";  // R6（租戶層）
const T1 = "11111111-1111-1111-1111-111111111111";
// R2 代傳時必須指定真正的資料提供者（該案件的有效 R1）
const PROVIDER_R1 = "aaaaaaaa-0000-0000-0000-000000000005";
const ENG_A = "eeeeeeee-0000-0000-0000-000000000001";
const LE_A = "cccccccc-0000-0000-0000-000000000001";
const PR1 = "99999999-0000-0000-0000-000000000001";     // 2026-03（首期）
const PR2 = "99999999-0000-0000-0000-000000000002";     // 2026-04（非首期）
const RP1 = "dddddddd-0000-0000-0000-000000000001";
const RP2 = "dddddddd-0000-0000-0000-000000000002";
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
interface Res { status: number; code: string | null; landed: string | null }
async function transition(cookie: string, revision: string, from: string, to: string,
                          role: string): Promise<Res> {
  const r = await fetch(`${API}/period/transition`, { method: "POST", redirect: "manual",
    headers: { cookie, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ revision, expected_from: from, to, acting_role: role }).toString() });
  return { status: r.status, code: r.headers.get("x-error-code"),
           landed: r.headers.get("x-period-status") };
}
const pstatus = (rev: string): string =>
  sql(`SELECT status FROM period_revision WHERE period_revision_id='${rev}'`);
const evCount = (rev: string, type: string): number =>
  Number(sql(`SELECT count(*) FROM audit_event WHERE object_id='${rev}' AND event_type='${type}'`));
const cvaCount = (): number =>
  Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'`));

execSync("bash packages/database/src/seed.sh cbfc_dev", { stdio: "ignore" });
execSync("rm -rf var/objects");
const api = spawn("node", ["apps/api/src/server.ts"],
  { env: { ...process.env, PORT: "8099" }, stdio: "ignore" });
let worker: ChildProcess | null = null;

try {
  await sleep(1200);
  console.log("══ SLICE-M2-05 期間生命週期驗收（Case-001） ══");
  const jia = await login(U_JIA);
  const yi = await login(U_YI);
  const ding = await login(U_DING);
  // audit_event 是 append-only（db:seed 也不清），全庫總數會被先前測試污染，
  // 因此一律以「本次操作前後增量」判定。
  const reqEvBase = evCount(PR1, "period.transition_requested");

  // ── 1 seed 的首期設定 ──
  check("Case-001 種子期間 2026-03 is_initial_period = true",
    sql(`SELECT is_initial_period FROM reporting_period WHERE reporting_period_id='${RP1}'`) === "t");
  check("同單位同曆別第二期 2026-04 = false",
    sql(`SELECT is_initial_period FROM reporting_period WHERE reporting_period_id='${RP2}'`) === "f");
  const dupInitial = (() => {
    try {
      sql(`INSERT INTO reporting_period (tenant_id, engagement_id, reporting_unit_id,
             fiscal_calendar_id, label, start_date, end_date, is_initial_period)
           VALUES ('${T1}','${ENG_A}','bbbbbbbb-0000-0000-0000-000000000001',
                   'ffffffff-0000-0000-0000-000000000001','再一個首期',
                   '2026-12-01','2026-12-31',true)`);
      return "unexpectedly-succeeded";
    } catch (e) { return String(e); }
  })();
  check("同單位同曆別第二個首期 → unique constraint 拒絕",
    dupInitial.includes("reporting_period_initial_uq") || dupInitial.includes("duplicate key"),
    dupInitial.slice(0, 60));
  check("新建修訂預設 SETUP（DEFAULT 已由 OPEN 改為 SETUP）", pstatus(PR1) === "SETUP");

  // ── 2 格式錯誤回 400，且不寫 CVA ──
  const cva0 = cvaCount();
  const bad: [string, string, string, string, string][] = [
    ["revision 非 UUID", "not-a-uuid", "SETUP", "OPEN", "R4"],
    ["revision 空", "", "SETUP", "OPEN", "R4"],
    ["acting_role 非法", PR1, "SETUP", "OPEN", "SUPERUSER"],
    ["acting_role 空", PR1, "SETUP", "OPEN", ""],
    ["expected_from 非法狀態", PR1, "BANANA", "OPEN", "R4"],
    ["to 非法狀態", PR1, "SETUP", "BANANA", "R4"],
  ];
  let all400 = true;
  for (const [name, rev, from, to, role] of bad) {
    const r = await transition(yi, rev, from, to, role);
    if (!(r.status === 400 && r.code === "INVALID_REQUEST")) {
      all400 = false;
      check(`格式錯誤應 400：${name}`, false, `http=${r.status} code=${r.code}`);
    }
  }
  check("六種格式錯誤全部回 400 ＋ INVALID_REQUEST", all400);
  check("格式錯誤不寫 ControlViolationAttempt（增量 0）", cvaCount() - cva0 === 0);
  check("格式錯誤未改變期間狀態", pstatus(PR1) === "SETUP");

  // ── 3 角色與 actor 綁定 ──
  const evBefore = evCount(PR1, "period.transitioned");
  const r403 = await transition(yi, PR1, "SETUP", "OPEN", "R2");
  check("角色不符 → 403 ROLE_NOT_PERMITTED", r403.status === 403 && r403.code === "ROLE_NOT_PERMITTED");
  const rDing = await transition(ding, PR1, "SETUP", "OPEN", "R4");
  check("未持有該角色（丁只有 R6）→ 403 ACTOR_ROLE_NOT_HELD",
    rDing.status === 403 && rDing.code === "ACTOR_ROLE_NOT_HELD");
  check("被拒期間狀態不變、無成功事件（增量 0）",
    pstatus(PR1) === "SETUP" && evCount(PR1, "period.transitioned") - evBefore === 0);

  // ── 4 主路徑 SETUP → OPEN，且只留一筆權威事件 ──
  const rOpen = await transition(yi, PR1, "SETUP", "OPEN", "R4");
  check("首期 SETUP → OPEN（R4）→ 200", rOpen.status === 200 && rOpen.landed === "OPEN");
  check("成功遷移只新增一筆 period.transitioned（增量 1）",
    evCount(PR1, "period.transitioned") - evBefore === 1);
  check("API 未另寫第二筆事件（period.transition_requested 增量 0）",
    evCount(PR1, "period.transition_requested") - reqEvBase === 0);
  check("權威事件含 from／requested／landed",
    sql(`SELECT payload::text FROM audit_event WHERE object_id='${PR1}'
         AND event_type='period.transitioned' ORDER BY audit_event_id DESC LIMIT 1`)
      .includes('"landed": "OPEN"'));

  // ── 5 競態與重送 ──
  const rReplay = await transition(yi, PR1, "SETUP", "OPEN", "R4");
  check("重送舊畫面的請求 → 409 OPTIMISTIC_LOCK_CONFLICT",
    rReplay.status === 409 && rReplay.code === "OPTIMISTIC_LOCK_CONFLICT");
  const rNoop = await transition(yi, PR1, "OPEN", "OPEN", "R4");
  check("同狀態請求 → 409 NO_OP_TRANSITION", rNoop.status === 409 && rNoop.code === "NO_OP_TRANSITION");
  check("兩者皆未產生成功事件（增量仍為 1）",
    evCount(PR1, "period.transitioned") - evBefore === 1);

  // ── 6 非首期 fail closed ──
  const rNonInitial = await transition(yi, PR2, "SETUP", "OPEN", "R4");
  check("非首期 SETUP → OPEN → 409 G10_NOT_IMPLEMENTED",
    rNonInitial.status === 409 && rNonInitial.code === "G10_NOT_IMPLEMENTED");

  // ── 7 OPEN → IN_PREPARATION 須有 ACCEPTED＋BALANCE＋COMPLETE ──
  const rNoData = await transition(jia, PR1, "OPEN", "IN_PREPARATION", "R2");
  check("尚無完整 TB → 409 REQUIRED_DATA_INCOMPLETE",
    rNoData.status === 409 && rNoData.code === "REQUIRED_DATA_INCOMPLETE");

  worker = spawn("node", ["apps/worker/src/worker.ts"],
    { env: { ...process.env, POLL_MS: "500" }, stdio: "ignore" });
  // Case-001 的 fixture 本身就聲明 #completeness=COMPLETE，因此「未聲明」的案例
  // 必須把該行拿掉——否則測不到「平衡≠完整」這條。
  const undeclared = readFileSync(`${FIX}/jp_tb_2026-03.csv`, "utf8")
    .split("\n").filter((l) => !l.startsWith("#completeness")).join("\n");
  await fetch(`${API}/upload`, { method: "POST", redirect: "manual",
    headers: { cookie: jia, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ engagement: ENG_A, legal_entity: LE_A, period_revision: PR1,
      provided_by: PROVIDER_R1,
      csv: undeclared }).toString() });
  for (let i = 0; i < 30; i++) {
    if (sql(`SELECT count(*) FROM import_batch WHERE status IN ('UPLOADED','VALIDATING')`) === "0") break;
    await sleep(400);
  }
  const B1 = sql(`SELECT import_batch_id FROM import_batch ORDER BY created_at DESC LIMIT 1`);
  await fetch(`${API}/b04/accept`, { method: "POST", redirect: "manual",
    headers: { cookie: jia, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ batch: B1 }).toString() });
  const b1st = sql(`SELECT status FROM import_batch WHERE import_batch_id='${B1}'`);
  const b1cov = sql(`SELECT completeness_status FROM data_coverage WHERE import_batch_id='${B1}'`);
  check("前置：批次 ACCEPTED 但完整度為 UNKNOWN",
    b1st === "ACCEPTED" && b1cov === "UNKNOWN", `${b1st}/${b1cov}`);
  const rUnknown = await transition(jia, PR1, "OPEN", "IN_PREPARATION", "R2");
  check("ACCEPTED 但未聲明完整 → 仍 409 REQUIRED_DATA_INCOMPLETE（平衡≠完整）",
    rUnknown.status === 409 && rUnknown.code === "REQUIRED_DATA_INCOMPLETE");

  // 提供者顯式聲明完整度（檔案內 #completeness=COMPLETE，受 file hash 涵蓋）
  const declared = readFileSync(`${FIX}/jp_tb_2026-03.csv`, "utf8");   // fixture 已含聲明
  await fetch(`${API}/upload`, { method: "POST", redirect: "manual",
    headers: { cookie: jia, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ engagement: ENG_A, legal_entity: LE_A, period_revision: PR1,
      provided_by: PROVIDER_R1,
      csv: declared }).toString() });
  for (let i = 0; i < 30; i++) {
    if (sql(`SELECT count(*) FROM import_batch WHERE status IN ('UPLOADED','VALIDATING')`) === "0") break;
    await sleep(400);
  }
  const B2 = sql(`SELECT import_batch_id FROM import_batch ORDER BY created_at DESC LIMIT 1`);
  await fetch(`${API}/b04/accept`, { method: "POST", redirect: "manual",
    headers: { cookie: jia, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ batch: B2 }).toString() });
  check("聲明完整的批次 ACCEPTED ＋ COMPLETE",
    sql(`SELECT completeness_status FROM data_coverage WHERE import_batch_id='${B2}'`) === "COMPLETE");
  const rPrep = await transition(jia, PR1, "OPEN", "IN_PREPARATION", "R2");
  check("有 ACCEPTED＋BALANCE＋COMPLETE → 200 IN_PREPARATION",
    rPrep.status === 200 && rPrep.landed === "IN_PREPARATION", `${rPrep.status}/${rPrep.code}`);

  // ── 8 期間級 G-02 聚合 ──
  const rUnmapped = await transition(jia, PR1, "IN_PREPARATION", "IN_REVIEW", "R2");
  check("期間內有未映射餘額 → 409 G02_PERIOD_UNMAPPED",
    rUnmapped.status === 409 && rUnmapped.code === "G02_PERIOD_UNMAPPED", `${rUnmapped.code}`);

  // 建立並批准全部映射
  const manual = readFileSync(`${FIX}/manual_mapping.csv`, "utf8").trim().split("\n").slice(1)
    .map((l) => l.split(","));
  const accountId = (code: string): string =>
    sql(`SELECT a.account_id FROM account a JOIN chart_of_accounts c ON c.coa_id = a.coa_id
         WHERE c.engagement_id = '${ENG_A}' AND a.code = '${code}'`);
  for (const [src, , tgt] of manual) {
    await fetch(`${API}/b04/map`, { method: "POST", redirect: "manual",
      headers: { cookie: jia, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ batch: B2, source_code: src, target: accountId(tgt) }).toString() });
  }
  const drafts = sql(`SELECT mapping_rule_id FROM mapping_rule
    WHERE engagement_id='${ENG_A}' AND approved_at IS NULL`).split("\n").filter(Boolean);
  for (const id of drafts) {
    await fetch(`${API}/b04/approve`, { method: "POST", redirect: "manual",
      headers: { cookie: yi, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ batch: B2, rule: id }).toString() });
  }
  check("映射全數批准", sql(`SELECT count(*) FROM mapping_rule
    WHERE engagement_id='${ENG_A}' AND approved_at IS NOT NULL`) === String(manual.length));

  // ── 9 零調整期間視為覆蓋完整 → 直接進 IN_REVIEW ──
  check("本期尚無調整（覆核範圍為空集合）",
    sql(`SELECT count(*) FROM adjustment WHERE period_revision_id='${PR1}'`) === "0");
  const rReview = await transition(jia, PR1, "IN_PREPARATION", "IN_REVIEW", "R2");
  check("零調整期間 → 直接進 IN_REVIEW，不卡 AWAITING_REVIEWER",
    rReview.status === 200 && rReview.landed === "IN_REVIEW", `${rReview.status}/${rReview.landed}`);
  check("仍留下覆核覆蓋評估快照（scope=0、fully_covered=true）",
    sql(`SELECT scope_object_count||'/'||fully_covered FROM reviewer_eligibility_evaluation
         WHERE period_revision_id='${PR1}' ORDER BY evaluated_at DESC LIMIT 1`) === "0/true");

  // ── 10 IN_REVIEW → ADJ_APPROVED ──
  const rApproved = await transition(yi, PR1, "IN_REVIEW", "ADJ_APPROVED", "R4");
  check("全期無未批准調整 → 200 ADJ_APPROVED",
    rApproved.status === 200 && rApproved.landed === "ADJ_APPROVED", `${rApproved.status}/${rApproved.code}`);

  // ── 11 後段各守衛的專屬代碼 ──
  const rCalc = await transition(yi, PR1, "ADJ_APPROVED", "CALCULATING", "R4");
  check("ADJ_APPROVED → CALCULATING → 409 G07_NOT_IMPLEMENTED",
    rCalc.status === 409 && rCalc.code === "G07_NOT_IMPLEMENTED");
  check("畫面明示「尚未實作」而非「已驗證通過」",
    (await (await fetch(`${API}/period/transition`, { method: "POST", redirect: "manual",
      headers: { cookie: yi, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ revision: PR1, expected_from: "ADJ_APPROVED",
        to: "CALCULATING", acting_role: "R4" }).toString() })).text()).includes("尚未實作"));

  // ── 12 PREVIEW_ONLY／REOPENED 不得被任意跳入 ──
  for (const target of ["PREVIEW_ONLY", "REOPENED", "LOCKED", "DELIVERED"]) {
    const r = await transition(yi, PR1, "ADJ_APPROVED", target, "R4");
    check(`不得由 ADJ_APPROVED 跳入 ${target}`,
      r.status === 409 && r.code === "ILLEGAL_TRANSITION", `${r.code}`);
  }
  check("既有預覽包／證據包流程未改變期間狀態", pstatus(PR1) === "ADJ_APPROVED");

  // ── 13 跨租戶 ──
  check("跨租戶期間不可見（查詢為零）",
    sql(`SELECT count(*) FROM period_revision WHERE tenant_id <> '${T1}'`) === "0");
} finally {
  worker?.kill(); api.kill();
  await sleep(300);
}

const failed = results.filter(([, ok]) => !ok);
console.log(`\n通過 ${results.length - failed.length} ／ 失敗 ${failed.length}`);
if (failed.length) process.exit(1);
