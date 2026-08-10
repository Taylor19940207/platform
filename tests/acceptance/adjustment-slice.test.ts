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
const U_OPS = "aaaaaaaa-0000-0000-0000-000000000004";    // 系管丁：R6（租戶層指派）
const U_TAX = "aaaaaaaa-0000-0000-0000-000000000005";    // 稅務擔當戊：R1（本案件）
const U_TR4 = "aaaaaaaa-0000-0000-0000-000000000006";    // 租戶層己：R4 但 engagement_id IS NULL
const T1 = "11111111-1111-1111-1111-111111111111";
// R2 代傳時必須指定真正的資料提供者（該案件的有效 R1）；R1 自己上傳則不需要
const PROVIDER_R1 = "aaaaaaaa-0000-0000-0000-000000000005";
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
async function getStatus(cookie: string, path: string): Promise<number> {
  return (await fetch(`${API}${path}`, { headers: { cookie }, redirect: "manual" })).status;
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
  await post(jia, "/upload", { engagement: ENG_A, legal_entity: LE_A, period_revision: PR1, provided_by: PROVIDER_R1,
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
  // SLICE-M2-06 起「基礎」不再是 adjustment 上的字串，而是 A→C 橋樑＋分層外鍵。
  // 驗語意等價：來源 A、目標 C、層 GROUP_GAAP_ADJ（其 rule_type 即 GROUP_GAAP）。
  check("MAJOR ＋ A→C 橋樑掛 GROUP_GAAP_ADJ 分層（本切片唯一場景）",
    adjField(ADJ, "materiality") === "MAJOR"
    && sql(`SELECT bf.code||'→'||bt.code||'@'||pl.code||'/'||COALESCE(pl.rule_type,'-')
              FROM adjustment a
              JOIN book_basis bf ON bf.basis_id = a.basis_from_id
              JOIN book_basis bt ON bt.basis_id = a.basis_to_id
              JOIN posting_layer pl ON pl.layer_id = a.posting_layer_id
             WHERE a.adjustment_id = '${ADJ}'`) === "A→C@GROUP_GAAP_ADJ/GROUP_GAAP");

  // ── 1b §24.6 權限矩陣：調整列的 R1／R6 為「–」（無權限） ──
  // 「持有任何角色」不等於「有這個物件的權限」。R6 是租戶層指派（engagement_id IS NULL），
  // 只判斷 roles.size 的話它必然通過——這正是本次修補封住的洞。
  const ops = await login(U_OPS);
  const tax = await login(U_TAX);
  const cvaBefore = violations("b05.view.denied");
  check("前置成立：戊確實在本案件持有 R1、丁確實持有租戶層 R6",
    sql(`SELECT count(*) FROM role_assignment WHERE user_id='${U_TAX}' AND role='R1'
          AND engagement_id='${ENG_A}' AND revoked_at IS NULL`) === "1"
    && sql(`SELECT count(*) FROM role_assignment WHERE user_id='${U_OPS}' AND role='R6'
          AND engagement_id IS NULL AND revoked_at IS NULL`) === "1");
  check("R1（資料提供者）直接 GET /b05 → 403（§24.6：調整列為 –）",
    await getStatus(tax, `/b05?adj=${ADJ}`) === 403);
  check("R6（系管）直接 GET /b05 → 403（租戶層指派不得取得客戶工作資料）",
    await getStatus(ops, `/b05?adj=${ADJ}`) === 403);
  check("兩次越權讀取都留下 CVA（含實際持有的角色清單）",
    violations("b05.view.denied") === cvaBefore + 2
    && sql(`SELECT payload->>'reason' FROM audit_event
             WHERE event_type='b05.view.denied' ORDER BY audit_event_id DESC LIMIT 1`)
       === "目前角色或授權範圍無權讀取此調整（§24.6）");
  // 作用域：角色**種類**在白名單內，不代表**範圍**涵蓋本案件。
  // §26.3：R1～R5、R7 屬 EngagementAssignment；租戶層角色不得隱式取得客戶資料。
  const tr4 = await login(U_TR4);
  check("前置成立：己持有 R4，但那是租戶層指派（engagement_id IS NULL），無任何案件授權",
    sql(`SELECT count(*) FROM role_assignment WHERE user_id='${U_TR4}' AND role='R4'
          AND engagement_id IS NULL AND revoked_at IS NULL`) === "1"
    && sql(`SELECT count(*) FROM role_assignment WHERE user_id='${U_TR4}'
          AND engagement_id IS NOT NULL`) === "0");
  check("租戶層 R4 直接 GET /b05 → 403（種類在白名單內，但作用域不涵蓋本案件）",
    await getStatus(tr4, `/b05?adj=${ADJ}`) === 403);
  check("CVA 分開記錄兩種範圍：案件層為空、租戶層有 R4",
    sql(`SELECT (payload->>'engagement_roles')||'|'||(payload->>'tenant_roles')
           FROM audit_event WHERE event_type='b05.view.denied'
          ORDER BY audit_event_id DESC LIMIT 1`) === '[]|["R4"]');

  check("R2／R3／R4 的合法讀取不受影響（甲 200、丙 200）",
    await getStatus(jia, `/b05?adj=${ADJ}`) === 200
    && await getStatus(bing, `/b05?adj=${ADJ}`) === 200);

  // ── 1c /b05/create 的逐動作授權（§24.6 調整列 C ＝ 僅 R2，且須案件層） ──
  const preCreate = Number(sql(`SELECT count(*) FROM adjustment`));
  check("租戶層 R4 建立調整 → 403（種類不符且作用域不涵蓋本案件）",
    await post(tr4, "/b05/create", { batch: B1, title: "越權建立" }) === 403);
  check("R1（本案件資料提供者）建立調整 → 403（調整列 C 只給 R2）",
    await post(tax, "/b05/create", { batch: B1, title: "越權建立" }) === 403);
  check("兩次越權建立都留 CVA，且未產生任何調整",
    sql(`SELECT payload->>'reason' FROM audit_event WHERE event_type='adjustment.create.denied'
          ORDER BY audit_event_id DESC LIMIT 1`) === "編製調整需本案件的 R2 角色（§24.6 調整列 C）"
    && Number(sql(`SELECT count(*) FROM adjustment`)) === preCreate);
  // 未接受的批次其來源事實尚非正式，不得成為調整的期間脈絡
  await post(jia, "/upload", { engagement: ENG_A, legal_entity: LE_A, period_revision: PR1, provided_by: PROVIDER_R1,
    csv: "#legal_entity_code=1234567890123\naccount_code,account_name,debit,credit\n1002,現金,50,0\n4000,売上,0,50\n" });
  await waitWorker();
  const B_DRAFT = sql(`SELECT import_batch_id FROM import_batch
                        WHERE status <> 'ACCEPTED' ORDER BY created_at DESC LIMIT 1`);
  check("前置成立：存在一個非 ACCEPTED 的批次",
    B_DRAFT.length === 36
    && sql(`SELECT status FROM import_batch WHERE import_batch_id='${B_DRAFT}'`) !== "ACCEPTED");
  check("以非 ACCEPTED 批次建立調整 → 409＋BATCH_NOT_ACCEPTED",
    await post(jia, "/b05/create", { batch: B_DRAFT, title: "未接受批次" }) === 409
    && Number(sql(`SELECT count(*) FROM adjustment`)) === preCreate);

  // ── 2 G-08：四項缺一不可 ──
  check("G-08：空白草稿送覆核 → 409", await post(jia, "/b05/submit", { adj: ADJ }) === 409);
  await post(jia, "/b05/save", { adj: ADJ, base_object_version: "1", title: "GROUP_GAAP 調整",
    legal_basis: EVIDENCE.legal_basis, evidence_ref: EVIDENCE.evidence_ref,
    judgment_reason: EVIDENCE.judgment_reason, language_tag: "",   // 語言標籤故意留空
    lines: "1002,1234.56,0\n6602,0,1234.56" });
  check("G-08：只補三項（缺語言標籤）送覆核仍 409",
    await post(jia, "/b05/submit", { adj: ADJ }) === 409);
  check("G-08 缺漏逐項列出於畫面", (await get(jia, `/b05?adj=${ADJ}`)).includes("語言標籤"));

  // ── 2b 自動保存：冪等、亂序、兩分頁、伺服器確認（NFR-UX-001／INT-002） ──
  const autosave = async (cookie: string, fields: Record<string, string>) => {
    const r = await fetch(`${API}/b05/save`, { method: "POST", redirect: "manual",
      headers: { cookie, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ ...fields, mode: "auto" }).toString() });
    return { status: r.status, body: await r.json() as Record<string, string> };
  };
  // 自動保存用**獨立的調整**：與主流程共用同一份草稿會讓後續的樂觀鎖與併發
  // 斷言依賴我這裡留下的版本與標題——那是測試互相污染，不是被測行為。
  await post(jia, "/b05/create", { batch: B1, title: "自動保存測試" });
  const ADJ_AS = sql(`SELECT adjustment_id FROM adjustment ORDER BY created_at DESC LIMIT 1`);
  const ES_A = "11110000-0000-4000-8000-00000000000a";   // 分頁 A 的編輯來源
  const ES_B = "11110000-0000-4000-8000-00000000000b";   // 分頁 B（同一人，不同分頁）
  const ovNow = () => Number(adjField(ADJ_AS, "object_version"));

  const ov0 = ovNow();
  const a1 = await autosave(jia, { adj: ADJ_AS, base_object_version: String(ov0),
    title: "自動保存 v1", ...EVIDENCE, lines: "1002,10,0\n6602,0,10",
    edit_session_id: ES_A, client_save_sequence: "1" });
  check("自動保存回傳伺服器確認的 object_version（不由前端自行宣告）",
    a1.status === 200 && a1.body.saved === true && Number(a1.body.object_version) === ov0 + 1);
  check("last_saved_at／last_saved_by／edit_session_id 由伺服器落地",
    adjField(ADJ_AS, "last_saved_at") !== "" && adjField(ADJ_AS, "last_saved_by") === U_JIA
    && adjField(ADJ_AS, "edit_session_id") === ES_A);

  // 重送同一序號：不是衝突，是冪等重放
  const a1r = await autosave(jia, { adj: ADJ_AS, base_object_version: String(ov0),
    title: "自動保存 v1", ...EVIDENCE, lines: "1002,10,0\n6602,0,10",
    edit_session_id: ES_A, client_save_sequence: "1" });
  check("同來源同序號重送 → 冪等重放（200，非假衝突），版本不再前進",
    a1r.status === 200 && a1r.body.kind === "IDEMPOTENT_REPLAY"
    && ovNow() === ov0 + 1);

  // 亂序：舊序號晚到，必須被忽略且不得覆蓋較新內容
  const stale = await autosave(jia, { adj: ADJ_AS, base_object_version: String(ov0),
    title: "亂序舊內容", ...EVIDENCE, lines: "1002,99,0\n6602,0,99",
    edit_session_id: ES_A, client_save_sequence: "0" });
  check("同來源舊序號晚到 → 忽略，且未覆蓋較新內容",
    stale.body.kind === "STALE_SEQUENCE" && adjField(ADJ_AS, "title") === "自動保存 v1"
    && ovNow() === ov0 + 1);

  // 兩個分頁：同一自然人、不同 edit_session_id，後到者不得靜默覆蓋
  const tabB = await autosave(jia, { adj: ADJ_AS, base_object_version: String(ov0),
    title: "分頁 B 的內容", ...EVIDENCE, lines: "1002,77,0\n6602,0,77",
    edit_session_id: ES_B, client_save_sequence: "1" });
  check("同一人的另一分頁以過期版本保存 → 409 版本衝突，內容未被覆蓋",
    tabB.status === 409 && tabB.body.kind === "VERSION_CONFLICT"
    && adjField(ADJ_AS, "title") === "自動保存 v1");
  check("已獲伺服器確認的草稿未遺失（分頁衝突後內容仍是確認過的那一版）",
    adjField(ADJ_AS, "edit_session_id") === ES_A && ovNow() === ov0 + 1);

  // 冪等鍵必須涵蓋內容：同序號帶不同內容時回報成功，等於宣稱存了實際沒存的東西
  const reuse = await autosave(jia, { adj: ADJ_AS, base_object_version: String(ov0),
    title: "序號重用的不同內容", ...EVIDENCE, lines: "1002,55,0\n6602,0,55",
    edit_session_id: ES_A, client_save_sequence: "1" });
  check("同序號**不同內容** → 409 IDEMPOTENCY_KEY_REUSED（不得宣稱已保存）",
    reuse.status === 409 && reuse.body.kind === "IDEMPOTENCY_KEY_REUSED"
    && adjField(ADJ_AS, "title") === "自動保存 v1");
  check("序號重用留下 CVA",
    Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'
                 AND payload->>'code'='IDEMPOTENCY_KEY_REUSED'`)) >= 1);

  // 保存中繼續編輯：新序號帶新內容必須真的落地（不得被舊回應標成已保存）
  const nextSeq = await autosave(jia, { adj: ADJ_AS, base_object_version: adjField(ADJ_AS, "object_version"),
    title: "保存中又改的內容", ...EVIDENCE, lines: "1002,66,0\n6602,0,66",
    edit_session_id: ES_A, client_save_sequence: "2" });
  check("同來源新序號新內容 → 正常保存，內容確實更新",
    nextSeq.status === 200 && nextSeq.body.saved === true
    && adjField(ADJ_AS, "title") === "保存中又改的內容");

  // Session 失效：背景保存必須回 401 而不是被 302 導到登入頁
  const noAuth = await fetch(`${API}/b05/save`, { method: "POST", redirect: "manual",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams({ adj: ADJ_AS, mode: "auto", base_object_version: "1",
      title: "x", edit_session_id: ES_A, client_save_sequence: "9" }).toString() });
  check("Session 失效時自動保存回 401 SESSION_EXPIRED（非 302 靜默吞掉）",
    noAuth.status === 401
    && (await noAuth.json() as Record<string, string>).kind === "SESSION_EXPIRED");
  check("失效請求未寫入任何內容", adjField(ADJ_AS, "title") === "保存中又改的內容");

  // 前端契約：五秒硬上限、編輯世代號、提交前等待保存、失效處理都在頁面腳本內
  const b05Html = await get(jia, `/b05?adj=${ADJ_AS}`);
  check("前端具備 5 秒硬上限、編輯世代號、ensureSaved 與 SESSION_EXPIRED 處理",
    b05Html.includes("5000") && b05Html.includes("savedGen")
    && b05Html.includes("ensureSaved") && b05Html.includes("SESSION_EXPIRED"));

  // Session 到期後回到原案件、期間與 Adjustment（INT-b）
  const noSession = await fetch(`${API}/b05?adj=${ADJ_AS}`, { redirect: "manual" });
  const resumeCookie = (noSession.headers.get("set-cookie") ?? "").split(";")[0];
  const relogin = await fetch(`${API}/login?u=${U_JIA}&t=${T1}`,
    { redirect: "manual", headers: { cookie: resumeCookie } });
  check("Session 到期 → 登入後導回原 Adjustment（非回首頁）",
    noSession.status === 302 && resumeCookie.startsWith("resume=")
    && relogin.headers.get("location") === `/b05?adj=${ADJ_AS}`);
  check("瀏覽器端不保存客戶財務內容（頁面無 localStorage／IndexedDB 使用）",
    !(await get(jia, `/b05?adj=${ADJ_AS}`)).match(/localStorage|indexedDB/i));

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
  // 違規嘗試永久留在 AuditEvent；但輸出資格必須反映目前狀態，不得殘留臨時降級
  check("合法覆核完成後不殘留 PREVIEW 降級（輸出資格反映目前狀態）",
    adjField(ADJ, "output_capability") === "" && adjField(ADJ, "control_reasons") === "[]");
  check("PREVIEW 降級雖已清除，G-04 違規嘗試仍永久留在稽核軌跡", guardLogged("G-04／SOD-01") >= 1);
  check("B-05 不再同時顯示 APPROVED 與「只能預覽」",
    !(await get(yi, `/b05?adj=${ADJ}`)).includes("只能預覽、不可正式交付"));

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

  // ── 12b 原子性：狀態遷移與里程碑快照同進同出 ──
  const snapCount = (a: string): number =>
    Number(sql(`SELECT count(*) FROM adjustment_version_snapshot WHERE adjustment_id='${a}'`));
  check("每次狀態遷移都恰好留下一個 business version 快照（無孤兒狀態）",
    snapCount(ADJ) === Number(adjField(ADJ, "business_version")) - 1);
  check("快照的 business_version 與調整狀態鏈一致（無跳號）",
    sql(`SELECT string_agg(business_version::text,',' ORDER BY business_version)
         FROM adjustment_version_snapshot WHERE adjustment_id='${ADJ}'`) === "2,3,4");
  // 快照唯一鍵衝突 → 整筆交易回滾：狀態與 business_version 都不得前進
  await post(jia, "/b05/create", { batch: B1, title: "原子性測試" });
  const ADJ3 = sql(`SELECT adjustment_id FROM adjustment ORDER BY created_at DESC LIMIT 1`);
  await post(jia, "/b05/save", { adj: ADJ3, base_object_version: "1", title: "原子性測試",
    ...EVIDENCE, lines: "1002,700.00,0\n6602,0,700.00" });
  sql(`INSERT INTO adjustment_version_snapshot (tenant_id, adjustment_id, business_version,
        milestone, actor_id, acting_role, content, content_sha256)
       VALUES ('${T1}','${ADJ3}',2,'SUBMITTED','${U_JIA}','R2','{}'::jsonb,'preoccupied')`);
  const beforeStatus = adjField(ADJ3, "status"), beforeBv = adjField(ADJ3, "business_version");
  check("快照插入失敗 → 狀態與 business_version 全部回滾",
    await post(jia, "/b05/submit", { adj: ADJ3 }) === 500
    && adjField(ADJ3, "status") === beforeStatus && beforeStatus === "DRAFTING"
    && adjField(ADJ3, "business_version") === beforeBv && beforeBv === "1");

  // ── 12c 草稿保存的原子性與明確拒絕 ──
  const ovBefore = adjField(ADJ3, "object_version");
  const linesBefore = sql(`SELECT string_agg(debit::text,',' ORDER BY line_no)
                           FROM adjustment_line WHERE adjustment_id='${ADJ3}'`);
  check("草稿第二列科目不存在 → 整筆拒絕 409（不再靜默略過後回報成功）",
    await post(jia, "/b05/save", { adj: ADJ3, base_object_version: ovBefore, title: "被改壞的標題",
      ...EVIDENCE, lines: "1002,111.00,0\n9999,0,111.00" }) === 409);
  check("拒絕後表頭、明細與 object_version 全部不變",
    adjField(ADJ3, "title") === "原子性測試" && adjField(ADJ3, "object_version") === ovBefore
    && sql(`SELECT string_agg(debit::text,',' ORDER BY line_no)
            FROM adjustment_line WHERE adjustment_id='${ADJ3}'`) === linesBefore);
  check("草稿第二列金額格式錯誤 → 整筆拒絕，明細不變",
    await post(jia, "/b05/save", { adj: ADJ3, base_object_version: ovBefore, title: "原子性測試",
      ...EVIDENCE, lines: "1002,111.00,0\n6602,abc,0" }) === 409
    && sql(`SELECT string_agg(debit::text,',' ORDER BY line_no)
            FROM adjustment_line WHERE adjustment_id='${ADJ3}'`) === linesBefore);

  // ── 12e 真併發：兩個保存請求以相同 base 同時送出，只能一個成功 ──
  // 事後比對版本號會誤判：若對方先把 5 改成 6，本請求 UPDATE 影響 0 列，
  // 但事後查到的版本同樣是 6（＝base+1）。必須驗證本次 UPDATE 真的影響一列。
  const ovRace = adjField(ADJ3, "object_version");
  const raceBody = (title: string, amount: string) => ({
    adj: ADJ3, base_object_version: ovRace, title, ...EVIDENCE,
    lines: `1002,${amount},0\n6602,0,${amount}`,
  });
  const [rA, rB] = await Promise.all([
    post(jia, "/b05/save", raceBody("競態 A", "301.00")),
    post(jia, "/b05/save", raceBody("競態 B", "302.00")),
  ]);
  const winners = [rA, rB].filter((c) => c === 302).length;
  check("真併發保存：兩個相同 base 的請求只有一個成功",
    winners === 1, `A=${rA} B=${rB}`);
  check("落敗的請求被明確拒絕（非靜默覆蓋）", [rA, rB].filter((c) => c === 409).length === 1);
  check("併發後 object_version 只前進一格",
    adjField(ADJ3, "object_version") === String(Number(ovRace) + 1));
  const raceTitle = adjField(ADJ3, "title");
  const raceLines = sql(`SELECT string_agg(debit::text,',' ORDER BY line_no)
                         FROM adjustment_line WHERE adjustment_id='${ADJ3}'`);
  check("勝方的表頭與明細一致，未被落敗方混入",
    (raceTitle === "競態 A" && raceLines.startsWith("301.00"))
    || (raceTitle === "競態 B" && raceLines.startsWith("302.00")), `${raceTitle} / ${raceLines}`);

  // ── 12f DomainEvent 與狀態遷移同一交易 ──
  // 以暫時性 trigger 注入事件插入失敗，驗證狀態、快照與事件全部回滾。
  sql(`CREATE OR REPLACE FUNCTION fn_test_fail_audit() RETURNS trigger LANGUAGE plpgsql AS $x$
       BEGIN
         IF NEW.event_type = 'adjustment.submitted' THEN
           RAISE EXCEPTION 'INJECTED_AUDIT_FAILURE';
         END IF;
         RETURN NEW;
       END $x$`);
  sql(`CREATE TRIGGER trg_test_fail_audit BEFORE INSERT ON audit_event
       FOR EACH ROW EXECUTE FUNCTION fn_test_fail_audit()`);
  // ADJ3 的 bv=2 快照已被 12b 預佔且不可刪除，故另建一筆乾淨的調整
  await post(jia, "/b05/create", { batch: B1, title: "事件回滾測試" });
  const ADJ4 = sql(`SELECT adjustment_id FROM adjustment ORDER BY created_at DESC LIMIT 1`);
  await post(jia, "/b05/save", { adj: ADJ4, base_object_version: "1", title: "事件回滾測試",
    ...EVIDENCE, lines: "1002,800.00,0\n6602,0,800.00" });
  const stBefore = adjField(ADJ4, "status"), bvBefore = adjField(ADJ4, "business_version");
  const snapBefore = snapCount(ADJ4);
  const injected = await post(jia, "/b05/submit", { adj: ADJ4 });
  sql(`DROP TRIGGER trg_test_fail_audit ON audit_event`);
  sql(`DROP FUNCTION fn_test_fail_audit()`);
  check("DomainEvent 插入失敗 → 狀態、business_version 與快照全部回滾",
    injected === 500 && adjField(ADJ4, "status") === stBefore && stBefore === "DRAFTING"
    && adjField(ADJ4, "business_version") === bvBefore && snapCount(ADJ4) === snapBefore);
  check("回滾後未留下孤兒事件", sql(`SELECT count(*) FROM audit_event WHERE kind='DOMAIN_EVENT'
         AND object_id='${ADJ4}' AND event_type='adjustment.submitted'`) === "0");
  check("回滾後仍可正常送覆核（狀態未被污染）",
    await post(jia, "/b05/submit", { adj: ADJ4 }) === 302
    && adjField(ADJ4, "status") === "PENDING_REVIEW");
  check("每個生命週期事件都有對應的 DomainEvent（同交易保證）",
    sql(`SELECT count(*) FROM audit_event WHERE kind='DOMAIN_EVENT'
         AND object_id='${ADJ4}' AND event_type='adjustment.submitted'`) === "1"
    && snapCount(ADJ4) === 1);

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
  // 等子行程真正退出——殘留 worker 會搶先認領下一支測試的工作（跨測試競態）
  await Promise.all([api, worker].map((p) => p && p.exitCode === null && p.signalCode === null
    ? new Promise((res) => { const t = setTimeout(() => p.kill("SIGKILL"), 3000); p.once("exit", () => { clearTimeout(t); res(null); }); })
    : null));
}

const failed = results.filter(([, ok]) => !ok);
console.log(`\n通過 ${results.length - failed.length} ／ 失敗 ${failed.length}`);
if (failed.length) process.exit(1);
