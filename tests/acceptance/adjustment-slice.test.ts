// SLICE-M2-02A 端到端驗收：Adjustment 編製 → 覆核 → 批准 → 物化 JournalEntry／Line。
// 契約：docs/slices/SLICE-M2-02A_調整生命週期.md；退回版本語意：docs/adr/ADR-M2-001.md
//
// 角色配置刻意讓「角色齊備」與「實例級控制」正面對撞：甲同時具備 R2／R3／R4，
// 因此 SOD-01 與 AC-WFL-001 被擋下時，唯一可能的原因是自然人判定而非角色不足。
import { spawn, execSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { raw } from "../../packages/database/src/psql.ts";

const API = "http://127.0.0.1:8093";
const U_JIA = "aaaaaaaa-0000-0000-0000-000000000001";    // 職員甲：R2＋R3＋R4
const U_YI = "aaaaaaaa-0000-0000-0000-000000000002";     // 資深乙：R2＋R3＋R4
const U_BING = "aaaaaaaa-0000-0000-0000-000000000003";   // 經理丙：R4
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
async function waitWorker(): Promise<void> {
  for (let i = 0; i < 20; i++) {
    if (sql("SELECT count(*) FROM import_batch WHERE status IN ('UPLOADED','VALIDATING')") === "0") return;
    await sleep(700);
  }
}
const adjField = (adj: string, col: string): string =>
  sql(`SELECT COALESCE(${col}::text,'') FROM adjustment WHERE adjustment_id='${adj}'`);
const journalCount = (adj: string): string =>
  sql(`SELECT count(*) FROM journal_line jl JOIN journal_entry je ON je.entry_id=jl.entry_id
       WHERE je.adjustment_id='${adj}'`);
const violations = (eventType: string): number =>
  Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'
              AND event_type='${eventType}'`));
const guardLogged = (guard: string): number =>
  Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'
              AND payload->>'guard'='${guard}'`));

// ── 重置環境 ──
execSync("bash packages/database/src/seed.sh cbfc_dev", { stdio: "ignore" });
execSync("rm -rf var/objects");
const api = spawn("node", ["apps/api/src/server.ts"], { env: { ...process.env, PORT: "8093" }, stdio: "ignore" });
const worker = spawn("node", ["apps/worker/src/worker.ts"], { env: { ...process.env, POLL_MS: "700" }, stdio: "ignore" });

const EVIDENCE = {
  legal_basis: "企業会計基準第29号 収益認識",
  evidence_ref: "attach-001.pdf",
  judgment_reason: "集團會計政策要求以 CAS 認列",
  language_tag: "ja-JP",
};

try {
  await sleep(1200);
  console.log("══ SLICE-M2-02A 調整生命週期驗收（Case-001） ══");
  const jia = await login(U_JIA);
  const yi = await login(U_YI);
  const bing = await login(U_BING);

  // ── 前置：一份 ACCEPTED 批次，提供 engagement × period 脈絡 ──
  await post(jia, "/upload", { engagement: ENG_A, legal_entity: LE_A, period_revision: PR1,
    csv: "#legal_entity_code=1234567890123\naccount_code,account_name,debit,credit\n1002,現金,1000,0\n4000,売上,0,1000\n" });
  await waitWorker();
  const B1 = sql(`SELECT import_batch_id FROM import_batch ORDER BY created_at DESC LIMIT 1`);
  await post(jia, "/b04/accept", { batch: B1 });
  check("前置：批次 ACCEPTED", sql(`SELECT status FROM import_batch WHERE import_batch_id='${B1}'`) === "ACCEPTED");

  // ── 1 建立草稿 ──
  check("建立調整草稿（R2 甲）→ 302", await post(jia, "/b05/create", { batch: B1, title: "GROUP_GAAP 調整" }) === 302);
  const ADJ = sql(`SELECT adjustment_id FROM adjustment ORDER BY created_at DESC LIMIT 1`);
  check("草稿初始狀態 DRAFTING、bv=1、ov=1",
    adjField(ADJ, "status") === "DRAFTING" && adjField(ADJ, "business_version") === "1"
    && adjField(ADJ, "object_version") === "1");
  check("MAJOR ＋ GROUP_GAAP（本切片唯一場景）",
    adjField(ADJ, "materiality") === "MAJOR" && adjField(ADJ, "basis") === "GROUP_GAAP");

  // ── 2 G-08：四項缺一不可 ──
  check("G-08：空白草稿送覆核 → 409", await post(jia, "/b05/submit", { adj: ADJ }) === 409);
  await post(jia, "/b05/save", { adj: ADJ, base_object_version: "1", title: "GROUP_GAAP 調整",
    legal_basis: EVIDENCE.legal_basis, evidence_ref: EVIDENCE.evidence_ref,
    judgment_reason: EVIDENCE.judgment_reason, language_tag: "",   // 語言標籤故意留空
    lines: "1002,1234.56,0\n6602,0,1234.56" });
  check("G-08：只補三項（缺語言標籤）送覆核仍 409",
    await post(jia, "/b05/submit", { adj: ADJ }) === 409);
  check("G-08 缺漏逐項列出於畫面", (await get(jia, `/b05?adj=${ADJ}`)).includes("語言標籤"));

  // ── 3 草稿保存與樂觀鎖 ──
  const ovAfterSave = adjField(ADJ, "object_version");
  check("儲存草稿只遞增 object_version，不動 business_version",
    ovAfterSave === "2" && adjField(ADJ, "business_version") === "1");
  check("併發：以過期的 base_object_version 儲存 → 409，不靜默覆蓋",
    await post(jia, "/b05/save", { adj: ADJ, base_object_version: "1", title: "被覆蓋的標題",
      ...EVIDENCE, lines: "1002,1,0\n6602,0,1" }) === 409);
  check("併發衝突後內容未被覆蓋",
    adjField(ADJ, "title") === "GROUP_GAAP 調整"
    && sql(`SELECT count(*) FROM adjustment_line WHERE adjustment_id='${ADJ}' AND debit=1234.56`) === "1");

  // ── 4 借貸不平衡不得送覆核 ──
  await post(jia, "/b05/save", { adj: ADJ, base_object_version: ovAfterSave,
    title: "GROUP_GAAP 調整", ...EVIDENCE, lines: "1002,1234.56,0\n6602,0,1000.00" });
  check("借貸不平衡 → 送覆核 409", await post(jia, "/b05/submit", { adj: ADJ }) === 409);

  // ── 5 齊備且平衡 → 送覆核 ──
  await post(jia, "/b05/save", { adj: ADJ, base_object_version: adjField(ADJ, "object_version"),
    title: "GROUP_GAAP 調整", ...EVIDENCE, lines: "1002,1234.56,0\n6602,0,1234.56" });

  // ── 6 關閉瀏覽器再登入（新 session），草稿仍在伺服器且內容一致 ──
  const jia2 = await login(U_JIA);
  const reopened = await get(jia2, `/b05?adj=${ADJ}`);
  check("關閉瀏覽器再登入：DRAFTING 草稿仍存在且內容一致",
    adjField(ADJ, "status") === "DRAFTING"
    && reopened.includes("企業会計基準第29号") && reopened.includes("1234.56"));

  check("G-08 齊備＋借貸平衡 → 送覆核 302", await post(jia, "/b05/submit", { adj: ADJ }) === 302);
  check("狀態 PENDING_REVIEW、business_version 遞增為 2",
    adjField(ADJ, "status") === "PENDING_REVIEW" && adjField(ADJ, "business_version") === "2");

  // 覆核人必須看得到要覆核的證據——離開草稿階段後不得隱藏
  const asReviewer = await get(yi, `/b05?adj=${ADJ}`);
  check("覆核人（R3）在 PENDING_REVIEW 仍看得到四項證據內容",
    asReviewer.includes("企業会計基準第29号") && asReviewer.includes("attach-001.pdf")
    && asReviewer.includes("集團會計政策要求以 CAS 認列") && asReviewer.includes("ja-JP"));

  // ── 7 G-04／SOD-01：甲具備 R3 仍不得覆核自己 ──
  check("SOD-01：編製人（甲）自我覆核 → 409，儘管甲具備 R3",
    await post(jia, "/b05/review", { adj: ADJ }) === 409);
  check("SOD-01 拒絕已留痕（ControlViolationAttempt）", guardLogged("G-04／SOD-01") >= 1);
  check("G-04 失敗 → 記錄 output_capability=PREVIEW（02A 不產生預覽檔）",
    adjField(ADJ, "output_capability") === "PREVIEW"
    && adjField(ADJ, "control_reasons").includes("G-04"));
  check("控制判定不含 delivery_quality 欄位（屬 DeliveryRecord，02A 不存在）",
    sql(`SELECT count(*) FROM information_schema.columns
         WHERE table_name='adjustment' AND column_name IN ('delivery_quality','official_eligible')`) === "0");

  // ── 8 乙覆核 ──
  check("覆核：另一自然人（乙 R3）通過 → 302", await post(yi, "/b05/review", { adj: ADJ }) === 302);
  check("狀態 PENDING_APPROVAL、reviewed_by=乙、bv=3",
    adjField(ADJ, "status") === "PENDING_APPROVAL" && adjField(ADJ, "reviewed_by") === U_YI
    && adjField(ADJ, "business_version") === "3");

  // ── 9 批准前不得有正式事實 ──
  check("批准前 JournalLine 為零", journalCount(ADJ) === "0");

  // ── 10 G-05／SOD-02 與 AC-WFL-001 是兩條獨立控制 ──
  check("SOD-02：覆核人（乙）兼批准 → 409，儘管乙具備 R4",
    await post(yi, "/b05/approve", { adj: ADJ }) === 409);
  check("SOD-02 拒絕已留痕", guardLogged("G-05／SOD-02") >= 1);
  // 甲編製 → 乙覆核 → 甲批准：SOD-01（甲≠乙）與 SOD-02（乙≠甲）都成立
  check("AC-WFL-001：編製人（甲）批准自己 → 409，儘管甲具備 R4 且 SOD-01／02 皆成立",
    await post(jia, "/b05/approve", { adj: ADJ }) === 409);
  check("AC-WFL-001 拒絕已留痕（獨立 guard，未冒充 SOD-02）", guardLogged("AC-WFL-001") >= 1);
  check("三次拒絕後仍未物化任何正式事實", journalCount(ADJ) === "0"
    && adjField(ADJ, "status") === "PENDING_APPROVAL");

  // ── 11 丙批准並同交易物化 ──
  check("批准：第三個自然人（丙 R4）→ 302", await post(bing, "/b05/approve", { adj: ADJ }) === 302);
  check("狀態 APPROVED、approved_by=丙、bv=4",
    adjField(ADJ, "status") === "APPROVED" && adjField(ADJ, "approved_by") === U_BING
    && adjField(ADJ, "business_version") === "4");
  check("批准後才物化：JournalLine 2 列", journalCount(ADJ) === "2");
  check("物化金額精確（1234.56，未經浮點）",
    sql(`SELECT SUM(debit)::text FROM journal_line jl JOIN journal_entry je ON je.entry_id=jl.entry_id
         WHERE je.adjustment_id='${ADJ}'`) === "1234.56");
  check("物化分錄借貸平衡",
    sql(`SELECT (SUM(debit)-SUM(credit))::text FROM journal_line jl
         JOIN journal_entry je ON je.entry_id=jl.entry_id WHERE je.adjustment_id='${ADJ}'`) === "0.00");
  check("已批准調整不可再編輯 → 409",
    await post(jia, "/b05/save", { adj: ADJ, base_object_version: adjField(ADJ, "object_version"),
      title: "改標題", ...EVIDENCE, lines: "1002,1,0\n6602,0,1" }) === 409);

  // ── 12 退回：兩個節點、覆核失效、不建立新調整 ──
  await post(jia, "/b05/create", { batch: B1, title: "退回測試調整" });
  const ADJ2 = sql(`SELECT adjustment_id FROM adjustment ORDER BY created_at DESC LIMIT 1`);
  await post(jia, "/b05/save", { adj: ADJ2, base_object_version: "1", title: "退回測試調整",
    ...EVIDENCE, lines: "1002,500.00,0\n6602,0,500.00" });
  await post(jia, "/b05/submit", { adj: ADJ2 });
  check("退回節點一：PENDING_REVIEW → DRAFTING（R3 乙）",
    await post(yi, "/b05/return", { adj: ADJ2, reason_category: "MISSING_EVIDENCE",
      reason_note: "附件不足" }) === 302 && adjField(ADJ2, "status") === "DRAFTING");
  check("退回必填理由：缺說明 → 409",
    await post(yi, "/b05/return", { adj: ADJ2, reason_category: "OTHER", reason_note: "" }) === 409);
  await post(jia, "/b05/submit", { adj: ADJ2 });
  await post(yi, "/b05/review", { adj: ADJ2 });
  const bvBeforeReturn = Number(adjField(ADJ2, "business_version"));
  check("退回節點二：PENDING_APPROVAL → DRAFTING（R4 丙）",
    await post(bing, "/b05/return", { adj: ADJ2, reason_category: "CALCULATION_ERROR",
      reason_note: "金額有誤" }) === 302 && adjField(ADJ2, "status") === "DRAFTING");
  check("從 PENDING_APPROVAL 退回：既有覆核失效（reviewed_by 清空）",
    adjField(ADJ2, "reviewed_by") === "");
  check("退回是業務里程碑：business_version 遞增（ADR-M2-001）",
    Number(adjField(ADJ2, "business_version")) === bvBeforeReturn + 1);
  check("退回不建立新調整、不建立替代版本：adjustment_id 不變",
    sql(`SELECT count(*) FROM adjustment WHERE title='退回測試調整'`) === "1");
  check("退回理由分類與說明可查（不可變快照）",
    sql(`SELECT count(*) FROM adjustment_version_snapshot WHERE adjustment_id='${ADJ2}'
         AND milestone='RETURNED' AND reason_category IN ('MISSING_EVIDENCE','CALCULATION_ERROR')`) === "2");
  check("退回次數可查（KPI 用）",
    sql(`SELECT count(*) FROM audit_event WHERE event_type='adjustment.returned'
         AND object_id='${ADJ2}'`) === "2");
  check("覆核失效後未重新覆核不得再進 PENDING_APPROVAL",
    await post(bing, "/b05/approve", { adj: ADJ2 }) === 409
    && adjField(ADJ2, "status") === "DRAFTING");

  // ── 13 稽核軌跡完整 ──
  const events = sql(`SELECT DISTINCT event_type FROM audit_event WHERE kind='DOMAIN_EVENT'
                      AND object_type='adjustment' ORDER BY event_type`).split("\n").filter(Boolean);
  check("DomainEvent 涵蓋編製／保存／送覆核／覆核／退回／批准／物化",
    ["adjustment.drafted", "adjustment.draft_saved", "adjustment.submitted", "adjustment.reviewed",
     "adjustment.returned", "adjustment.approved", "journal.materialized"]
      .every((e) => events.includes(e)), events.join("、"));
  check("繞過 UI 的直接 API 呼叫全部留痕（本測試所有拒絕皆為直接 API）",
    violations("adjustment.review.rejected") >= 1 && violations("adjustment.approve.rejected") >= 2);

  // ── 14 跨案件／跨租戶 ──
  check("跨租戶不可見：以 T1 之外的租戶查詢調整為零",
    sql(`SELECT count(*) FROM adjustment WHERE tenant_id <> '${T1}'`) === "0");
} finally {
  api.kill(); worker.kill();
}

const failed = results.filter(([, ok]) => !ok);
console.log(`\n通過 ${results.length - failed.length} ／ 失敗 ${failed.length}`);
if (failed.length) process.exit(1);
