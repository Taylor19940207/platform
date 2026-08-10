// SLICE-M3-01 端到端驗收：B-02 期間工作台。
// 契約：docs/slices/SLICE-M3-01_期間工作台.md
//
// 本刀最重要的一條：畫面上的「下一步」必須來自 DB 的 fn_period_transition_spec，
// 不得在 TypeScript 再寫一份遷移表。因此下列測試**逐狀態釘住可見集合**——
// 若有人把「下一步」改成列出全部狀態，第 2、3 節必轉紅（驗收 7）。
//
// 授權：完整 B-02 為案件層 R2／R3／R4。租戶層庚（R3）／辛（R2）／己（R4）是
// 「角色種類正確、作用域錯誤」的樣本——它們釘住的是作用域判定本身，
// 不是白名單（§26.3：R1～R5、R7 屬 EngagementAssignment）。
import { spawn, execSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { raw } from "../../packages/database/src/psql.ts";

const API = "http://127.0.0.1:8098";
const T1 = "11111111-1111-1111-1111-111111111111";
const U_JIA = "aaaaaaaa-0000-0000-0000-000000000001";   // 案件層 R2＋R3＋R4
const U_BING = "aaaaaaaa-0000-0000-0000-000000000003";  // 案件層 R4（只有 R4）
const U_DING = "aaaaaaaa-0000-0000-0000-000000000004";  // 租戶層 R6
const U_WU = "aaaaaaaa-0000-0000-0000-000000000005";    // 案件層 R1（作用域正確、種類不符）
const U_JI = "aaaaaaaa-0000-0000-0000-000000000006";    // 租戶層 R4
const U_GENG = "aaaaaaaa-0000-0000-0000-000000000007";  // 租戶層 R3
const U_XIN = "aaaaaaaa-0000-0000-0000-000000000008";   // 租戶層 R2
const PR1 = "99999999-0000-0000-0000-000000000001";     // 2026-03（首期）
const PR2 = "99999999-0000-0000-0000-000000000002";     // 2026-04（非首期）
const ALL_STATES = ["SETUP", "OPEN", "IN_PREPARATION", "IN_REVIEW", "AWAITING_REVIEWER",
  "ADJ_APPROVED", "CALCULATING", "RECONCILING", "PENDING_PKG_APPR", "LOCKED",
  "DELIVERED", "REOPENED", "PREVIEW_ONLY"];

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
async function b02(cookie: string, revision: string): Promise<{ status: number; body: string }> {
  const r = await fetch(`${API}/b02?revision=${revision}`, { headers: { cookie }, redirect: "manual" });
  return { status: r.status, body: await r.text() };
}
/** 只取「下一步」區塊——本期物件區也會出現狀態字樣，不能整頁比對。 */
const nextSteps = (body: string): string =>
  body.slice(body.indexOf("<h2>下一步</h2>"), body.indexOf("<h2>本期物件</h2>"));
/** 「下一步」中出現的目標狀態集合。 */
const listed = (body: string): string[] =>
  ALL_STATES.filter((st) => new RegExp(`<td><b>${st}</b>`).test(nextSteps(body)));

// 前置狀態：唯一裁決點的副作用——owner 也得停用 trigger 才改得動。
// 只用於「建立測試前置」，不用於驗證遷移本身（那是 period-lifecycle 套件的事）。
const force = (rev: string, status: string): void =>
  void sql(`ALTER TABLE period_revision DISABLE TRIGGER trg_period_transition;
            UPDATE period_revision SET status='${status}' WHERE period_revision_id='${rev}';
            ALTER TABLE period_revision ENABLE TRIGGER trg_period_transition;`);
const cvaCount = (): number =>
  Number(sql(`SELECT count(*) FROM audit_event WHERE kind='CONTROL_VIOLATION_ATTEMPT'`));

execSync("bash packages/database/src/seed.sh cbfc_dev", { stdio: "ignore" });
const api = spawn("node", ["apps/api/src/server.ts"],
  { env: { ...process.env, PORT: "8098" }, stdio: "ignore" });

try {
  await sleep(1200);
  console.log("══ SLICE-M3-01 B-02 期間工作台驗收 ══");
  const jia = await login(U_JIA);

  // ── 1 期間狀態與四欄脈絡（驗收 1）──
  force(PR1, "SETUP");
  const p1 = await b02(jia, PR1);
  check("案件層 R2／R3／R4 可讀取期間工作台", p1.status === 200, `${p1.status}`);
  check("顯示四欄脈絡（客戶／單位／曆別／期間）",
    ["A 商事株式会社", "A 商事", "日本4月起", "2026-03"].every((x) => p1.body.includes(x)));
  check("顯示目前狀態 SETUP 與修訂號", p1.body.includes("SETUP") && p1.body.includes("修訂 1"));
  check("首期旗標：2026-03 標為首期", p1.body.includes("<b>首期</b>"));
  const p2 = await b02(jia, PR2);
  check("首期旗標：2026-04 標為非首期",
    p2.status === 200 && p2.body.includes("非首期") && !p2.body.includes("<b>首期</b>"));
  check("不存在的期間 → 404", (await b02(jia, "99999999-0000-0000-0000-0000000000ff")).status === 404);

  // ── 2 只列出目前狀態的合法遷移（驗收 2；反證釘子見驗收 7）──
  check("SETUP 的下一步只有 OPEN 一個",
    JSON.stringify(listed(p1.body)) === '["OPEN"]', listed(p1.body).join(","));
  force(PR1, "OPEN");
  const pOpen = await b02(jia, PR1);
  check("OPEN 的下一步只有 IN_PREPARATION",
    JSON.stringify(listed(pOpen.body)) === '["IN_PREPARATION"]', listed(pOpen.body).join(","));
  force(PR1, "IN_REVIEW");
  const pReview = await b02(jia, PR1);
  check("IN_REVIEW 的下一步只有 ADJ_APPROVED",
    JSON.stringify(listed(pReview.body)) === '["ADJ_APPROVED"]', listed(pReview.body).join(","));
  force(PR1, "DELIVERED");
  const pDeliv = await b02(jia, PR1);
  check("DELIVERED 沒有後續遷移（不是列出全部狀態）",
    listed(pDeliv.body).length === 0 && pDeliv.body.includes("沒有後續遷移"));
  {
    // 逐狀態掃描：AWAITING_REVIEWER、REOPENED、PREVIEW_ONLY 不得出現在任何「下一步」
    const everListed = new Set<string>();
    for (const from of ["SETUP", "OPEN", "IN_PREPARATION", "IN_REVIEW", "AWAITING_REVIEWER",
                        "ADJ_APPROVED", "CALCULATING", "RECONCILING", "PENDING_PKG_APPR", "LOCKED"]) {
      force(PR1, from);
      for (const to of listed((await b02(jia, PR1)).body)) everListed.add(to);
    }
    check("全狀態掃描：AWAITING_REVIEWER／REOPENED／PREVIEW_ONLY 從不出現在下一步",
      !["AWAITING_REVIEWER", "REOPENED", "PREVIEW_ONLY"].some((x) => everListed.has(x)),
      [...everListed].join(","));
  }
  {
    // 最強的釘子：逐狀態把畫面所列與 DB 規格函式**完全比對**。
    // 多列一個（例如列出全部 13 狀態）或少列一個，都會轉紅。
    const mismatched: string[] = [];
    for (const from of ALL_STATES) {
      force(PR1, from);
      const page = listed((await b02(jia, PR1)).body).sort().join(",");
      const spec = sql(`SELECT string_agg(requested_to, ',' ORDER BY requested_to)
                          FROM fn_period_transition_spec('${from}')`);
      if (page !== spec) mismatched.push(`${from}：畫面[${page}] ≠ DB[${spec}]`);
    }
    check("逐 13 狀態：畫面所列的下一步與 DB 規格函式完全一致",
      mismatched.length === 0, mismatched.join("；"));
  }

  // ── 3 角色不符者看不到按鈕，但 DB 仍是唯一裁決點（驗收 3）──
  force(PR1, "OPEN");           // OPEN → IN_PREPARATION 需 R2；丙只有 R4
  const bing = await login(U_BING);
  const pBing = await b02(bing, PR1);
  check("案件層 R4（無 R2）可讀取，但下一步無按鈕",
    pBing.status === 200 && !nextSteps(pBing.body).includes("<button>"), `${pBing.status}`);
  check("並明示所需角色（可行動的原因，不是靜默隱藏）",
    nextSteps(pBing.body).includes("需 R2 角色"));
  check("持有 R2 者才渲染按鈕",
    nextSteps((await b02(jia, PR1)).body).includes("<button>前往 IN_PREPARATION</button>"));
  const cvaBefore = cvaCount();
  const bypass = await fetch(`${API}/period/transition`, { method: "POST", redirect: "manual",
    headers: { cookie: bing, "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ revision: PR1, expected_from: "OPEN",
      to: "IN_PREPARATION", acting_role: "R4" }).toString() });
  check("繞過畫面直接 POST：DB 仍以 ROLE_NOT_PERMITTED 擋下（403）",
    bypass.status === 403 && bypass.headers.get("x-error-code") === "ROLE_NOT_PERMITTED",
    `${bypass.status}/${bypass.headers.get("x-error-code")}`);
  check("且留下 CVA", cvaCount() > cvaBefore);
  check("期間狀態未被改變",
    sql(`SELECT status FROM period_revision WHERE period_revision_id='${PR1}'`) === "OPEN");

  // ── 3B 作用域反證：角色種類正確、作用域錯誤者直接 POST（0029）──
  // 第 3 節的樣本是「案件層 R4 用錯角色」，那只證明角色矩陣，不證明作用域。
  // 0022 原本寫成 (ra.engagement_id IS NULL OR ra.engagement_id = v_eng)，
  // 租戶層指派因此對所有案件有效——畫面擋得住，DB 擋不住。
  const post = async (cookie: string, revision: string, from: string, to: string, role: string) => {
    const r = await fetch(`${API}/period/transition`, { method: "POST", redirect: "manual",
      headers: { cookie, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ revision, expected_from: from, to, acting_role: role }).toString() });
    return { status: r.status, code: r.headers.get("x-error-code"),
             landed: r.headers.get("x-period-status") };
  };
  const pstatus = (): string =>
    sql(`SELECT status FROM period_revision WHERE period_revision_id='${PR1}'`);

  force(PR1, "SETUP");
  {
    const before = cvaCount();
    const r = await post(await login(U_JI), PR1, "SETUP", "OPEN", "R4");
    check("租戶層 R4 直接 POST 首期 SETUP → OPEN：403 ACTOR_ROLE_NOT_HELD",
      r.status === 403 && r.code === "ACTOR_ROLE_NOT_HELD", `${r.status}/${r.code}`);
    check("租戶層 R4 被拒後期間狀態不變（仍 SETUP）", pstatus() === "SETUP");
    check("租戶層 R4 的嘗試留下 CVA", cvaCount() > before);
  }

  // 第二條要證明拒絕**來自作用域**，不是來自 G-01 缺完整 TB——
  // 因此先建立完整 TB 前置，並在 POST 之前斷言它成立。
  const BATCH = "b0290000-0000-0000-0000-000000000001";
  // 覆蓋度必須在批次 ACCEPTED **之前**寫入——已接受的批次來源集合已封存。
  sql(`INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id,
         declared_legal_entity_id, declared_period_revision_id, batch_version,
         status, identity_status, file_name)
       VALUES ('${BATCH}','${T1}','eeeeeeee-0000-0000-0000-000000000001',
               'cccccccc-0000-0000-0000-000000000001','${PR1}',1,
               'VALIDATING','MATCHED','0029-前置.csv');
       INSERT INTO data_coverage (tenant_id, import_batch_id, batch_version,
         granularity, completeness_status)
       VALUES ('${T1}','${BATCH}',1,'BALANCE','COMPLETE');
       ALTER TABLE import_batch DISABLE TRIGGER USER;
       UPDATE import_batch SET status='ACCEPTED' WHERE import_batch_id='${BATCH}';
       ALTER TABLE import_batch ENABLE TRIGGER USER`);
  const tbReady = (): string => sql(
    `SELECT count(*) FROM import_batch ib
       JOIN data_coverage dc ON dc.import_batch_id = ib.import_batch_id
        AND dc.batch_version = ib.batch_version
      WHERE ib.declared_period_revision_id = '${PR1}' AND ib.status = 'ACCEPTED'
        AND dc.granularity = 'BALANCE' AND dc.completeness_status = 'COMPLETE'`);
  check("前置成立：本期已有「已接受且聲明完整」的 BALANCE 批次（G-01 不會成為拒絕理由）",
    tbReady() === "1", tbReady());
  force(PR1, "OPEN");
  check("且畫面不再顯示該未達成條件（讀模型與守衛同一份事實）",
    !nextSteps((await b02(jia, PR1)).body).includes("尚無「已接受且聲明完整」"));
  {
    const before = cvaCount();
    const r = await post(await login(U_XIN), PR1, "OPEN", "IN_PREPARATION", "R2");
    check("租戶層 R2 直接 POST OPEN → IN_PREPARATION：403 ACTOR_ROLE_NOT_HELD",
      r.status === 403 && r.code === "ACTOR_ROLE_NOT_HELD", `${r.status}/${r.code}`);
    check("拒絕理由不是 G-01（否則就是被錯誤理由擋住的假綠）",
      r.code !== "REQUIRED_DATA_INCOMPLETE");
    check("租戶層 R2 被拒後期間狀態不變（仍 OPEN）", pstatus() === "OPEN");
    check("租戶層 R2 的嘗試留下 CVA", cvaCount() > before);
  }
  // 正控制：同一條遷移由**案件層** R2 發起必須成功——否則「前置成立」只是嘴上說。
  const okR2 = await post(jia, PR1, "OPEN", "IN_PREPARATION", "R2");
  check("正控制：案件層 R2 在同一前置下真的走得過去",
    okR2.status === 200 && okR2.landed === "IN_PREPARATION", `${okR2.status}/${okR2.code}`);
  // 拆除前置：data_coverage 為 append-only，import_batch 身分凍結——
  // 兩者都得明確停用觸發器才移得掉，這正是「不可變事實」該有的阻力。
  sql(`ALTER TABLE data_coverage DISABLE TRIGGER USER;
       ALTER TABLE import_batch DISABLE TRIGGER USER;
       DELETE FROM data_coverage WHERE import_batch_id='${BATCH}';
       DELETE FROM import_batch WHERE import_batch_id='${BATCH}';
       ALTER TABLE import_batch ENABLE TRIGGER USER;
       ALTER TABLE data_coverage ENABLE TRIGGER USER`);
  check("前置已清除，後續各節的前提回復（本期無完整 TB）", tbReady() === "0");

  // ── 4 尚未實作的遷移不得被畫成可點（驗收 4）──
  force(PR1, "ADJ_APPROVED");
  const pAdj = await b02(jia, PR1);
  const rowCalc = nextSteps(pAdj.body).split("<tr>").find((r) => r.includes("CALCULATING")) ?? "";
  check("ADJ_APPROVED → CALCULATING 標示「守衛尚未實作」",
    rowCalc.includes("守衛尚未實作") && rowCalc.includes("匯率版本凍結守衛尚未實作"));
  check("該列沒有按鈕（甲持有 R2／R3／R4 仍不得點）", !rowCalc.includes("<button>"));
  check("尚未實作的列不謊稱「需某角色」（守衛未實作＝角色也未決定）",
    !rowCalc.includes("需 R") && rowCalc.includes("<td>—</td>"));
  force(PR1, "LOCKED");
  const rowDeliv = nextSteps((await b02(jia, PR1)).body).split("<tr>")
    .find((r) => r.includes("DELIVERED")) ?? "";
  check("LOCKED → DELIVERED 同樣標示尚未實作且不可點",
    rowDeliv.includes("守衛尚未實作") && !rowDeliv.includes("<button>"));
  // CONDITIONAL（G-10）：條件成立才畫成不可用。條件不成立時照樣渲染按鈕——
  // 對首期謊稱「本版不可用」，與把未實作畫成可點一樣是錯的，只是方向相反。
  force(PR2, "SETUP");
  const rowCond = nextSteps((await b02(jia, PR2)).body).split("<tr>")
    .find((r) => r.includes("OPEN")) ?? "";
  check("非首期 SETUP → OPEN：條件成立 → 不可用＋G-10 理由，且無按鈕",
    rowCond.includes("守衛尚未實作") && rowCond.includes("前期銜接守衛尚未實作")
      && !rowCond.includes("<button>"));
  force(PR1, "SETUP");
  const rowInit = nextSteps((await b02(jia, PR1)).body).split("<tr>")
    .find((r) => r.includes("OPEN")) ?? "";
  check("首期 SETUP → OPEN：條件不成立 → 渲染按鈕，且不謊稱本版不可用",
    rowInit.includes("<button>前往 OPEN</button>") && !rowInit.includes("守衛尚未實作")
      && !rowInit.includes("前期銜接"));
  // 畫面與 DB 的實際結論必須一致（否則畫面就是在自說自話）
  const doTrans = async (rev: string, to: string, role: string) =>
    (await fetch(`${API}/period/transition`, { method: "POST", redirect: "manual",
      headers: { cookie: jia, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ revision: rev, expected_from: "SETUP", to,
        acting_role: role }).toString() })).headers;
  check("DB 實際結論一致：非首期 → G10_NOT_IMPLEMENTED",
    (await doTrans(PR2, "OPEN", "R4")).get("x-error-code") === "G10_NOT_IMPLEMENTED");
  check("DB 實際結論一致：首期 → 真的走得過去",
    (await doTrans(PR1, "OPEN", "R4")).get("x-period-status") === "OPEN");

  // ── 5 未達成條件顯示可行動的原因（驗收 5）──
  force(PR1, "OPEN");
  check("OPEN：顯示「尚無已接受且聲明完整的 BALANCE 批次」",
    nextSteps((await b02(jia, PR1)).body).includes("尚無「已接受且聲明完整」的 BALANCE 批次"));
  const ADJ = "a0310000-0000-0000-0000-000000000001";
  // 基礎必須屬於本案件（0023 §24.1A）——取 A 基礎，不硬編 code
  // 調整是**跨兩個基礎的橋樑**，來源與目標不得相同（0023）
  const [basisFrom, basisTo] = sql(`SELECT basis_id FROM book_basis
                       WHERE engagement_id='eeeeeeee-0000-0000-0000-000000000001'
                       ORDER BY code LIMIT 2`).split("\n");
  sql(`INSERT INTO adjustment (adjustment_id, tenant_id, engagement_id, period_revision_id,
         basis_from_id, basis_to_id, posting_layer_id, title, prepared_by, status)
       VALUES ('${ADJ}','${T1}','eeeeeeee-0000-0000-0000-000000000001','${PR1}',
               '${basisFrom}','${basisTo}',
               (SELECT layer_id FROM posting_layer WHERE scope_type='ENTITY'
                  AND rule_type='GROUP_GAAP'),
               'B-02 未達成條件樣本','${U_JIA}','DRAFTING')
       ON CONFLICT (adjustment_id) DO NOTHING`);
  force(PR1, "IN_REVIEW");
  const pWhy = nextSteps((await b02(jia, PR1)).body);
  check("IN_REVIEW：顯示未批准調整筆數，而不是只說「被擋」",
    /尚有 1 筆調整未批准/.test(pWhy), pWhy.includes("未批准") ? "" : "無此訊息");
  check("該原因與 DB 聚合守衛查同一份事實（實際遷移同樣被擋）",
    (await fetch(`${API}/period/transition`, { method: "POST", redirect: "manual",
      headers: { cookie: jia, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ revision: PR1, expected_from: "IN_REVIEW",
        to: "ADJ_APPROVED", acting_role: "R4" }).toString() }))
      .headers.get("x-error-code") === "ADJ_NOT_ALL_APPROVED");
  sql(`DELETE FROM adjustment WHERE adjustment_id='${ADJ}'`);

  // ── 6 R1、租戶層角色與未指派者：整頁 403（驗收 6）──
  force(PR1, "OPEN");
  for (const [who, uid, why] of [
    ["案件層 R1（戊）", U_WU, "作用域正確、種類不在白名單"],
    ["租戶層 R2（辛）", U_XIN, "種類正確、作用域錯誤"],
    ["租戶層 R3（庚）", U_GENG, "種類正確、作用域錯誤"],
    ["租戶層 R4（己）", U_JI, "種類正確、作用域錯誤"],
    ["租戶層 R6（丁）", U_DING, "技術角色，非案件成員"],
  ] as const) {
    const c = await login(uid);
    const before = cvaCount();
    const r = await b02(c, PR1);
    check(`${who}：整頁 403（${why}）`, r.status === 403, `${r.status}`);
    check(`${who}：不洩漏客戶名稱、狀態或計數`,
      !r.body.includes("A 商事株式会社") && !r.body.includes("2026-03") &&
      !/<b>OPEN<\/b>/.test(r.body));
    check(`${who}：留下 CVA`, cvaCount() > before);
  }
  check("CVA 物件記在 period_revision 上（不是使用者或案件）",
    sql(`SELECT object_type||':'||object_id FROM audit_event
          WHERE kind='CONTROL_VIOLATION_ATTEMPT' AND event_type='b02.view.denied'
          ORDER BY occurred_at DESC LIMIT 1`) === `period_revision:${PR1}`);
  check("CVA 同時記下持有的案件層與租戶層角色（供調查）",
    sql(`SELECT (payload->>'tenant_roles') FROM audit_event
          WHERE kind='CONTROL_VIOLATION_ATTEMPT' AND event_type='b02.view.denied'
          ORDER BY occurred_at DESC LIMIT 1`).includes("R6"));

  // ── 7 B-00 的 B-02 入口：可見範圍與 B-02 授權同一組角色 ──
  const home = async (c: string): Promise<string> =>
    await (await fetch(`${API}/`, { headers: { cookie: c }, redirect: "manual" })).text();
  const hJia = await home(jia);
  check("B-00 提供 B-02 入口（本刀的缺口就是入口缺席）",
    hJia.includes(`/b02?revision=${PR1}`) && hJia.includes("<h2>期間</h2>"));
  const hWu = await home(await login(U_WU));
  check("案件層 R1 的 B-00 不出現期間區塊，也沒有 B-02 連結",
    !hWu.includes("/b02?revision=") && !hWu.includes("<h2>期間</h2>"));
  check("R1 的 B-00 仍保有自己的上傳入口（未被連坐移除）", hWu.includes("上傳"));
  const hGeng = await home(await login(U_GENG));
  check("租戶層 R3 的 B-00 不出現任何期間（作用域錯誤）",
    !hGeng.includes("/b02?revision="));

  force(PR1, "SETUP");
} finally {
  api.kill();
  await sleep(300);
}

const failed = results.filter(([, ok]) => !ok);
console.log(`\n通過 ${results.length - failed.length} ／ 失敗 ${failed.length}`);
if (failed.length) process.exit(1);
