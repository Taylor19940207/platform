// API（§27 模組化單體宿主）。里程碑 1 垂直切片：
//   登入 → 選 客戶/法人/期間（EngagementContext）→ 上傳 TB → B-00 顯示結果。
// 畫面為走查骨架（真機換 Next.js）；控制邏輯（脈絡伺服器端驗證、雜湊、審計）是正式的。
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createHash, randomUUID } from "node:crypto";
import { query, exec } from "../../../packages/database/src/psql.ts";
import { putObject } from "../../../packages/database/src/objectstore.ts";
import { sign, verify, type Session } from "../../../packages/auth/src/session.ts";
import { config } from "../../../packages/config/src/index.ts";
import { acceptancePredicate, type ImportBatchStatus, type IdentityStatus }
  from "../../../packages/domain/src/importBatch.ts";
import { applyMappings, coverage, g02Check, totalsOf, cents, fmtCents,
  type TbAccountLine, type CurrentMapping } from "../../../packages/domain/src/mapping.ts";
import { ENGINE_VERSION, CANONICALIZATION_VERSION, RUN_REASON, reasonCodeOf }
  from "../../../packages/domain/src/calculationRun.ts";
import { RENDER_VERSION, PKG_REASON, type PkgReasonCode }
  from "../../../packages/domain/src/evidencePackage.ts";
import { getObject } from "../../../packages/database/src/objectstore.ts";
import { idempotencyKey, isStalled } from "../../../packages/domain/src/backgroundJob.ts";
import { authenticatedContext, readBody, sessionOf } from "./http/context.ts";
import { dispatch } from "./http/dispatch.ts";
import { esc, page, responder } from "./http/respond.ts";
import { audit, auditSql } from "./modules/audit.ts";
import { rolesOf } from "./modules/adjustments/access.ts";
import * as adjSvc from "./modules/adjustments/service.ts";

// 識別規則版本：與 worker 一致，構成 job 冪等鍵的一部分
const DETECTION_RULE_VERSION = "detect-r1";

const PORT = config.port;
// ── EngagementContext 伺服器端驗證（§24.1A：不得信任前端下拉選單） ──
function validateContext(s: Session, engagementId: string, legalEntityId: string,
                         periodRevisionId: string): { ok: boolean; reason?: string } {
  const rows = query<{ n: string }>(
    `SELECT count(*) AS n FROM legal_entity le
       JOIN period_revision pr ON pr.period_revision_id = :'pr'::uuid
       JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
      WHERE le.legal_entity_id = :'le'::uuid
        AND le.engagement_id = :'e'::uuid
        AND rp.engagement_id = :'e'::uuid`,
    { pr: periodRevisionId, le: legalEntityId, e: engagementId }, { tenantId: s.tenantId });
  if (Number(rows[0]?.n) !== 1) return { ok: false, reason: "物件與 Engagement 不一致" };
  const assigned = query<{ n: string }>(
    `SELECT count(*) AS n FROM role_assignment
      WHERE user_id = :'u'::uuid AND revoked_at IS NULL
        AND (engagement_id IS NULL OR engagement_id = :'e'::uuid)`,
    { u: s.userId, e: engagementId }, { tenantId: s.tenantId });
  if (Number(assigned[0]?.n) === 0) return { ok: false, reason: "未被指派此案件" };
  return { ok: true };
}

/** 使用者在該案件的角色集合（含租戶層指派）。 */
interface BatchCtx {
  import_batch_id: string; engagement_id: string; status: ImportBatchStatus;
  identity_status: IdentityStatus; hash_verified: boolean;
  client: string; entity: string; period: string; period_end: string;
  declared_period_revision_id: string;
}
function loadBatch(s: Session, batchId: string): BatchCtx | null {
  const rows = query<BatchCtx>(
    `SELECT ib.import_batch_id, ib.engagement_id, ib.status, ib.identity_status, ib.hash_verified,
            ib.declared_period_revision_id,
            ce.name AS client, le.name AS entity, rp.label AS period, rp.end_date AS period_end
       FROM import_batch ib
       JOIN client_engagement ce ON ce.engagement_id = ib.engagement_id
       JOIN legal_entity le ON le.legal_entity_id = ib.declared_legal_entity_id
       JOIN period_revision pr ON pr.period_revision_id = ib.declared_period_revision_id
       JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
      WHERE ib.import_batch_id = :'b'::uuid`,
    { b: batchId }, { tenantId: s.tenantId });
  return rows[0] ?? null;
}

/**
 * 目前生效映射：每來源科目取「該報告期間生效」的最高已批准版本。
 * 生效以期間終了日判定（TB 為期末餘額）；NULL 生效日＝不限。
 * 版本凍結（CalculationInputManifest）屬下一刀 CalculationRun。
 */
function currentMappings(s: Session, engagementId: string, periodEnd: string): CurrentMapping[] {
  return query<{ source_account_code: string; target_account_id: string;
                 target_code: string; target_name: string; version_no: number }>(
    `SELECT DISTINCT ON (mr.source_account_code)
            mr.source_account_code, mr.target_account_id, mr.version_no,
            a.code AS target_code, a.name AS target_name
       FROM mapping_rule mr JOIN account a ON a.account_id = mr.target_account_id
      WHERE mr.engagement_id = :'e'::uuid AND mr.approved_at IS NOT NULL
        AND (mr.effective_from IS NULL OR mr.effective_from <= :'pe'::date)
        AND (mr.effective_to   IS NULL OR mr.effective_to   >= :'pe'::date)
      ORDER BY mr.source_account_code, mr.version_no DESC`,
    { e: engagementId, pe: periodEnd }, { tenantId: s.tenantId })
    .map((r) => ({ sourceAccountCode: r.source_account_code, targetAccountId: r.target_account_id,
                   targetCode: r.target_code, targetName: r.target_name, versionNo: Number(r.version_no) }));
}

/** 批次的 TB 科目彙總列。 */
function tbLines(s: Session, batchId: string): TbAccountLine[] {
  return query<{ account_code: string; account_name: string; debit: string; credit: string }>(
    `SELECT account_code, MAX(account_name) AS account_name,
            SUM(debit) AS debit, SUM(credit) AS credit
       FROM source_ledger_line WHERE import_batch_id = :'b'::uuid
      GROUP BY account_code ORDER BY account_code`,
    { b: batchId }, { tenantId: s.tenantId })
    .map((r) => ({ accountCode: r.account_code, accountName: r.account_name ?? "",
                   debitCents: cents(r.debit), creditCents: cents(r.credit) }));
}

function b04CtxBar(b: BatchCtx, screen: string): string {
  return `<span>畫面 <b>${esc(screen)}</b></span><span>客戶 <b>${esc(b.client)}</b></span>` +
    `<span>法人 <b>${esc(b.entity)}</b></span><span>期間 <b>${esc(b.period)}</b></span>` +
    `<span>批次 <b>${b.import_batch_id.slice(0, 8)}</b>（${b.status}）</span>`;
}

const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
  const url = new URL(req.url ?? "/", "http://x");
  const send = responder(res);
  try {
    if (url.pathname === "/health") {
      const [row] = query<{ ok: number }>("SELECT 1 AS ok", {}, { asRuntime: false });
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify({ ok: true, db: row?.ok === 1 }));
    }

    // ── 登入（開發用：列出種子使用者；真機換 SSO） ──
    if (url.pathname === "/" && !sessionOf(req)) {
      const users = query<{ user_id: string; email: string; display_name: string; tenant_id: string }>(
        "SELECT user_id, email, display_name, tenant_id FROM app_user WHERE is_active", {}, { asRuntime: false });
      return send(200, page("登入", "<b>未登入</b>",
        `<h2>登入（開發模式）</h2><p class="note">走查骨架：點選身分即登入。真機環境換 SSO／IdP。</p>` +
        users.map((u) => `<p><a href="/login?u=${u.user_id}&t=${u.tenant_id}">${esc(u.display_name)}（${esc(u.email)}）</a></p>`).join("")));
    }
    if (url.pathname === "/login") {
      const s: Session = { userId: url.searchParams.get("u") ?? "", tenantId: url.searchParams.get("t") ?? "" };
      return send(302, "", { "set-cookie": `s=${sign(s)}; HttpOnly; Path=/`, location: "/" });
    }

    const s = sessionOf(req);
    if (!s) return send(302, "", { location: "/" });

    // 已拆出模組的路由先問 dispatcher；未命中才落回下方原有的 if 鏈。
    // 一個模組一次地搬，回歸差異才分得清是哪個模組造成的。
    if (await dispatch(authenticatedContext(req, url, s), send)) return;

    // ── 診斷：背景工作狀態（SLICE-M2-03 第 16 條；管理用途，本刀只做 API 不做畫面） ──
    if (url.pathname === "/admin/jobs" && req.method === "GET") {
      // 診斷屬技術維運資料（§24.6 權限矩陣：技術維運＝R6 系統管理員）。
      // 只驗登入等於把租約、認領者與失敗原因暴露給租戶內任何使用者。
      const isR6 = query<{ n: string }>(
        `SELECT count(*) AS n FROM role_assignment
          WHERE user_id = :'u'::uuid AND role = 'R6' AND revoked_at IS NULL`,
        { u: s.userId }, { tenantId: s.tenantId });
      if (Number(isR6[0]?.n) === 0) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "admin.jobs.denied", s.userId,
          "admin_api", s.userId, { reason: "診斷 API 需 R6 系統管理員角色" });
        res.writeHead(403, { "content-type": "application/json; charset=utf-8" });
        return res.end(JSON.stringify({ error: "診斷 API 需 R6 系統管理員角色" }));
      }
      const jobs = query<Record<string, string>>(
        `SELECT job_id, job_type, subject_id, subject_version, status,
                claimed_by, claimed_at, lease_expires_at, next_attempt_at,
                attempt_count, max_attempts, last_error_class, last_error_message,
                created_at, updated_at, completed_at, failed_at
           FROM background_job ORDER BY created_at DESC LIMIT 200`,
        {}, { tenantId: s.tenantId });
      res.writeHead(200, { "content-type": "application/json; charset=utf-8" });
      // 卡住＝RUNNING 但租約已過期。這是本刀之前唯一無法回答的問題。
      return res.end(JSON.stringify({
        jobs: jobs.map((j) => ({
          ...j,
          stalled: isStalled(j.status as "RUNNING", j.lease_expires_at ?? null),
        })),
        stalled_count: jobs.filter((j) =>
          isStalled(j.status as "RUNNING", j.lease_expires_at ?? null)).length,
      }, null, 2));
    }

    // ── B-00 個人工作台（M2-04）──
    // 佇列依「所需業務角色 × 該案件有效指派」過濾（engagement_id 明確匹配、未撤銷）；
    // 租戶層角色（R6 等，engagement_id IS NULL）不取得任何客戶工作存取權（WKB-a）。
    if (url.pathname === "/") {
      const engFor = (roles: string[]) => query<{ engagement_id: string; name: string }>(
        `SELECT DISTINCT ce.engagement_id, ce.name FROM client_engagement ce
           JOIN role_assignment ra ON ra.engagement_id = ce.engagement_id
          WHERE ra.user_id = :'u'::uuid AND ra.revoked_at IS NULL
            AND ra.role IN (${roles.map((r) => `'${r}'`).join(",")})
          ORDER BY ce.name`,
        { u: s.userId }, { tenantId: s.tenantId });
      const bizEng = engFor(["R1", "R2", "R3", "R4", "R5", "R7"]);
      const inList = (rows: { engagement_id: string }[]) =>
        rows.length ? rows.map((r) => `'${r.engagement_id}'`).join(",")
                    : "'00000000-0000-0000-0000-000000000000'";
      const r2In = inList(engFor(["R2"]));
      const r3In = inList(engFor(["R3"]));
      const r4In = inList(engFor(["R4"]));
      const bizIn = inList(bizEng);
      const bizIds = new Set(bizEng.map((e2) => e2.engagement_id));

      // 佇列 1：待身分確認（R2；PENDING_CONFIRMATION 且非 QUARANTINED／SUPERSEDED）
      const qIdentity = query<Record<string, string>>(
        `SELECT ib.import_batch_id, ib.batch_version, ce.name AS client, le.name AS entity,
                rp.label AS period, ib.status
           FROM import_batch ib
           JOIN client_engagement ce ON ce.engagement_id = ib.engagement_id
           JOIN legal_entity le ON le.legal_entity_id = ib.declared_legal_entity_id
           JOIN period_revision pr ON pr.period_revision_id = ib.declared_period_revision_id
           JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
          WHERE ib.identity_status = 'PENDING_CONFIRMATION'
            AND ib.status = 'VALIDATED'
            AND ib.engagement_id IN (${r2In})
          ORDER BY ib.created_at DESC`, {}, { tenantId: s.tenantId });
      const adjQ = (where: string, engIn: string) => query<Record<string, string>>(
        `SELECT a.adjustment_id, a.title, a.status, ce.name AS client, ru.name AS entity,
                rp.label AS period, last.reason_category
           FROM adjustment a
           JOIN client_engagement ce ON ce.engagement_id = a.engagement_id
           JOIN period_revision pr ON pr.period_revision_id = a.period_revision_id
           JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
           JOIN reporting_unit ru ON ru.reporting_unit_id = rp.reporting_unit_id
           LEFT JOIN LATERAL (SELECT milestone, reason_category
                  FROM adjustment_version_snapshot v WHERE v.adjustment_id = a.adjustment_id
                 ORDER BY v.business_version DESC, v.occurred_at DESC LIMIT 1) last ON true
          WHERE ${where} AND a.engagement_id IN (${engIn})
          ORDER BY a.updated_at DESC`, {}, { tenantId: s.tenantId });
      // 佇列 2：待覆核（R3；SOD-01：不含自己編製）
      const qReview = adjQ(`a.status = 'PENDING_REVIEW' AND a.prepared_by <> :'u2'::uuid`
        .replace(":'u2'", `'${s.userId}'`), r3In);
      // 佇列 3：待批准（R4；AC-WFL-001 ≠編製人 ∧ SOD-02 ≠覆核人——完整三人分離）
      const qApprove = adjQ(
        `a.status = 'PENDING_APPROVAL' AND a.prepared_by <> '${s.userId}' AND a.reviewed_by <> '${s.userId}'`,
        r4In);
      // 佇列 4：被退回／待補證據（自己編製、DRAFTING、最新里程碑 RETURNED）
      const qReturned = adjQ(
        `a.status = 'DRAFTING' AND a.prepared_by = '${s.userId}' AND last.milestone = 'RETURNED'`,
        bizIn);
      // 佇列 5：未完成草稿（自己的 DRAFTING 調整＋未批准映射草稿）
      const qDraftAdj = adjQ(`a.status = 'DRAFTING' AND a.prepared_by = '${s.userId}'`, bizIn);
      // 映射草稿的四欄脈絡與一鍵回位來自不可變的來源批次（0020 source_import_batch_id）
      const qDraftMap = query<Record<string, string>>(
        `SELECT mr.mapping_rule_id, mr.source_account_code, mr.source_import_batch_id,
                ce.name AS client, COALESCE(le.name, '—') AS entity, COALESCE(rp.label, '—') AS period
           FROM mapping_rule mr
           JOIN client_engagement ce ON ce.engagement_id = mr.engagement_id
           LEFT JOIN import_batch ib ON ib.import_batch_id = mr.source_import_batch_id
           LEFT JOIN legal_entity le ON le.legal_entity_id = ib.declared_legal_entity_id
           LEFT JOIN period_revision pr ON pr.period_revision_id = ib.declared_period_revision_id
           LEFT JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
          WHERE mr.created_by = :'u'::uuid AND mr.approved_at IS NULL
            AND mr.engagement_id IN (${bizIn})
          ORDER BY mr.created_at DESC`, { u: s.userId }, { tenantId: s.tenantId });

      const batches = bizEng.length ? query<Record<string, string>>(
        `SELECT ib.import_batch_id, ib.created_at, ce.name AS client, le.name AS entity,
                rp.label AS period, ib.status, ib.identity_status, ib.file_name, ib.quarantine_reason
           FROM import_batch ib
           JOIN client_engagement ce ON ce.engagement_id = ib.engagement_id
           JOIN legal_entity le ON le.legal_entity_id = ib.declared_legal_entity_id
           JOIN period_revision pr ON pr.period_revision_id = ib.declared_period_revision_id
           JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
          WHERE ib.engagement_id IN (${bizIn})
          ORDER BY ib.created_at DESC LIMIT 50`, {}, { tenantId: s.tenantId }) : [];
      const les = query<Record<string, string>>(
        `SELECT legal_entity_id, name, engagement_id FROM legal_entity`, {}, { tenantId: s.tenantId })
        .filter((r) => bizIds.has(r.engagement_id));
      const prs = query<Record<string, string>>(
        `SELECT pr.period_revision_id, rp.label, rp.engagement_id FROM period_revision pr
           JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id`,
        {}, { tenantId: s.tenantId }).filter((r) => bizIds.has(r.engagement_id));

      const four = (r: Record<string, string>) =>
        `<td>${esc(r.client)}</td><td>${esc(r.entity)}</td><td>${esc(r.period)}</td>`;
      const qSec = (title: string, rows: string[], count: number) =>
        `<h3>${esc(title)}（${count}）</h3>` + (count
          ? `<table><tr><th>客戶</th><th>法人</th><th>期間</th><th>狀態</th><th>項目</th><th></th></tr>${rows.join("")}</table>`
          : `<p class="note">無</p>`);
      return send(200, page("B-00 個人工作台",
        `<span>畫面 <b>B-00 個人工作台</b></span><span>使用者 <b>${esc(s.userId.slice(-4))}</b></span>`,
        `<h2>等我處理的事項</h2>
         ${qSec("待身分確認", qIdentity.map((r) => `<tr>${four(r)}
            <td><span class="badge st-PENDING_CONFIRMATION">待確認</span></td>
            <td>批次 ${r.import_batch_id.slice(0, 8)}（v${r.batch_version}）</td>
            <td><a href="/b03/identity?batch=${r.import_batch_id}">開啟確認頁</a></td></tr>`), qIdentity.length)}
         ${qSec("待覆核", qReview.map((r) => `<tr>${four(r)}
            <td><span class="badge st-UPLOADED">待覆核</span></td><td>${esc(r.title)}</td>
            <td><a href="/b05?adj=${r.adjustment_id}">開啟 B-05</a></td></tr>`), qReview.length)}
         ${qSec("待批准", qApprove.map((r) => `<tr>${four(r)}
            <td><span class="badge st-UPLOADED">待批准</span></td><td>${esc(r.title)}</td>
            <td><a href="/b05?adj=${r.adjustment_id}">開啟 B-05</a></td></tr>`), qApprove.length)}
         ${qSec("被退回／待補證據", qReturned.map((r) => `<tr>${four(r)}
            <td><span class="badge st-QUARANTINED">被退回</span></td>
            <td>${esc(r.title)}（${esc(r.reason_category ?? "")}）</td>
            <td><a href="/b05?adj=${r.adjustment_id}">開啟 B-05</a></td></tr>`), qReturned.length)}
         ${qSec("未完成草稿", [
            ...qDraftAdj.map((r) => `<tr>${four(r)}
              <td><span class="badge st-UPLOADED">草稿</span></td><td>${esc(r.title)}</td>
              <td><a href="/b05?adj=${r.adjustment_id}">開啟 B-05</a></td></tr>`),
            ...qDraftMap.map((r) => `<tr>${four(r)}
              <td><span class="badge st-UPLOADED">映射草稿</span></td><td>${esc(r.source_account_code)}</td>
              <td>${r.source_import_batch_id
                ? `<a href="/b04?batch=${r.source_import_batch_id}">開啟 B-04</a>`
                : `<span class="note">—（無來源批次脈絡）</span>`}</td></tr>`),
          ], qDraftAdj.length + qDraftMap.length)}
         <h2>上傳試算表（TB）</h2>
         <form class="up" method="post" action="/upload">
           客戶 <select name="engagement">${bizEng.map((r) => `<option value="${r.engagement_id}">${esc(r.name)}</option>`).join("")}</select>
           法人 <select name="legal_entity">${les.map((r) => `<option value="${r.legal_entity_id}">${esc(r.name)}</option>`).join("")}</select>
           期間 <select name="period_revision">${prs.map((r) => `<option value="${r.period_revision_id}">${esc(r.label)}</option>`).join("")}</select><br>
           <textarea name="csv" rows="6" cols="80"
placeholder="#legal_entity_code=1234567890123
account_code,account_name,debit,credit
1100,現金,1000,0
4000,売上,0,1000"></textarea><br>
           <button>上傳</button>
           <span class="note">上傳後由背景工作驗證：借貸平衡（G-01）＋檔案歸屬比對（identity_status）</span>
         </form>
         <h2>批次狀態</h2>
         <table><tr><th>客戶</th><th>法人</th><th>期間</th><th>狀態</th><th>身分比對</th><th>檔案</th><th>說明</th><th>動作</th></tr>
         ${batches.map((b) => `<tr><td>${esc(b.client)}</td><td>${esc(b.entity)}</td><td>${esc(b.period)}</td>
           <td><span class="badge st-${b.status}">${b.status}</span></td>
           <td><span class="badge st-${b.identity_status}">${b.identity_status}</span></td>
           <td>${esc(b.file_name)}</td><td class="note">${esc(b.quarantine_reason ?? "")}</td>
           <td>${b.status === "VALIDATED" && b.identity_status === "MATCHED"
             ? `<form method="post" action="/b04/accept" style="margin:0"><input type="hidden" name="batch" value="${b.import_batch_id}"><button>接受</button></form>`
             : b.status === "VALIDATED" && b.identity_status === "MANUALLY_RESOLVED"
             ? `<form method="post" action="/b04/accept" style="margin:0"><input type="hidden" name="batch" value="${b.import_batch_id}"><button>接受</button></form>`
             : b.status === "VALIDATED" && b.identity_status === "PENDING_CONFIRMATION"
             ? `<a href="/b03/identity?batch=${b.import_batch_id}">身分確認</a>`
             : b.status === "ACCEPTED" ? `<a href="/b04?batch=${b.import_batch_id}">B-04 映射</a>` : ""}</td></tr>`).join("")}
         </table><p class="note">此頁只顯示您具業務角色且被指派之案件；未指派案件的名稱與數量不會出現（WKB-a）。</p>`));
    }


    // ── 上傳（POST /upload；走查骨架用 urlencoded 表單。分段續傳 A7/A8 屬下一里程碑） ──
    if (url.pathname === "/upload" && req.method === "POST") {
      const raw = (await readBody(req)).toString("utf8");
      const fields = Object.fromEntries(new URLSearchParams(raw));
      const engagement = fields["engagement"] ?? "";
      const legal_entity = fields["legal_entity"] ?? "";
      const period_revision = fields["period_revision"] ?? "";
      const csv = (fields["csv"] ?? "").replace(/\r\n/g, "\n");

      // 伺服器端脈絡驗證：繞過 UI 直接呼叫也會被擋，並記錄違規嘗試（CTX-a）
      const v = validateContext(s, engagement, legal_entity, period_revision);
      if (!v.ok) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "context.mismatch", s.userId,
          "import_batch", randomUUID(), { reason: v.reason, engagement, legal_entity, period_revision });
        return send(403, page("拒絕", "<b>⛔ 歸屬驗證失敗</b>",
          `<h2>⛔ ${esc(v.reason)}</h2><p>此次嘗試已寫入稽核軌跡。</p><p><a href="/">回 B-00</a></p>`));
      }

      const data = Buffer.from(csv, "utf8");
      const sha = createHash("sha256").update(data).digest("hex");
      const batchId = randomUUID();
      const key = `${s.tenantId}/${batchId}/tb.csv`;
      putObject(key, data);
      // 上傳為單一交易：ImportBatch、SourceDocument、BackgroundJob 與 uploaded 事件同進同出。
      //
      // job 若改在「認領時」才建立，會留下這條路徑：批次已 UPLOADED → 程式崩潰
      // → job 從未建立 → 永遠沒人處理。那與原本的卡住問題等價，只是換了位置。
      //
      // 原檔紀錄先落地，最後才轉 UPLOADED——§25.5「UPLOADED＝檔案已落地」。
      const ev = auditSql(s.tenantId, "DOMAIN_EVENT", "import_batch.uploaded", s.userId,
        "import_batch", batchId, { sha256: sha, bytes: data.length });
      exec(`BEGIN;
            INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id,
                    declared_legal_entity_id, declared_period_revision_id,
                    uploaded_by, provided_by, file_name, file_sha256, status)
            VALUES ('${batchId}'::uuid, :'t'::uuid, :'e'::uuid, :'le'::uuid, :'pr'::uuid,
                    :'u'::uuid, :'u'::uuid, 'tb.csv', :'sha', 'DRAFT');
            INSERT INTO source_document (tenant_id, import_batch_id, file_name,
                    content_sha256, object_key, byte_size)
            VALUES (:'t'::uuid, '${batchId}'::uuid, 'tb.csv', :'sha', :'k', ${data.length});
            UPDATE import_batch SET status='UPLOADED' WHERE import_batch_id = '${batchId}'::uuid;
            INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version,
                    rule_version, idempotency_key, max_attempts)
            SELECT :'t'::uuid, 'IMPORT_VALIDATION', '${batchId}'::uuid, ib.batch_version,
                   :'rv', :'ik', ${config.jobMaxAttempts}
              FROM import_batch ib WHERE ib.import_batch_id = '${batchId}'::uuid;
            ${ev.sql}
            COMMIT;`,
        { t: s.tenantId, e: engagement, le: legal_entity, pr: period_revision,
          u: s.userId, sha, k: key, rv: DETECTION_RULE_VERSION,
          ik: idempotencyKey("IMPORT_VALIDATION", batchId, 1, DETECTION_RULE_VERSION),
          ...ev.params }, { tenantId: s.tenantId });
      return send(302, "", { location: "/" });
    }

    // ═══════════ SLICE-M2-01：B-04 科目映射 ═══════════
    // 共通入口檢查：批次存在＋使用者被指派該案件（歸屬完整性 §24.1A）
    const b04Guard = (batchId: string, action: string):
        { ok: true; b: BatchCtx; roles: Set<string> } | { ok: false; res: void } => {
      const b = loadBatch(s, batchId);
      if (!b) return { ok: false, res: send(404, page("404", "", "<h2>批次不存在</h2>")) };
      const roles = rolesOf(s, b.engagement_id);
      if (roles.size === 0) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", `${action}.denied`, s.userId,
          "import_batch", batchId, { reason: "未被指派此案件", action });
        return { ok: false, res: send(403, page("拒絕", "<b>⛔ 未被指派</b>",
          `<h2>⛔ 未被指派此案件</h2><p>此次嘗試已寫入稽核軌跡。</p><p><a href="/">回 B-00</a></p>`)) };
      }
      return { ok: true, b, roles };
    };

    // ── 接受批次（VALIDATED → ACCEPTED；G-01 接受判定式，DB 觸發器為最後防線） ──
    if (url.pathname === "/b04/accept" && req.method === "POST") {
      const fields = Object.fromEntries(new URLSearchParams((await readBody(req)).toString("utf8")));
      const g = b04Guard(fields["batch"] ?? "", "batch.accept");
      if (!g.ok) return;
      if (!g.roles.has("R2")) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "batch.accept.denied", s.userId,
          "import_batch", g.b.import_batch_id, { reason: "接受需 R2 角色" });
        return send(403, page("拒絕", b04CtxBar(g.b, "B-04"), "<h2>⛔ 接受需 R2 角色</h2>"));
      }
      const pred = acceptancePredicate({ status: g.b.status,
        identityStatus: g.b.identity_status, hashVerified: g.b.hash_verified });
      if (!pred.ok) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "batch.accept.rejected", s.userId,
          "import_batch", g.b.import_batch_id, { guard: pred.guard, reasons: pred.reasons });
        return send(409, page("拒絕", b04CtxBar(g.b, "B-04"),
          `<h2>⛔ ${pred.guard}：不滿足接受判定式</h2><ul>${pred.reasons.map((r) => `<li>${esc(r)}</li>`).join("")}</ul><p><a href="/">回 B-00</a></p>`));
      }
      // 狀態與事件同交易（與 SLICE-M2-03 的其餘 import_batch 事件一致）
      const evAcc = auditSql(s.tenantId, "DOMAIN_EVENT", "import_batch.accepted", s.userId,
        "import_batch", g.b.import_batch_id, {});
      exec(`BEGIN;
            UPDATE import_batch SET status='ACCEPTED' WHERE import_batch_id = :'b'::uuid;
            ${evAcc.sql}
            COMMIT;`,
        { b: g.b.import_batch_id, ...evAcc.params }, { tenantId: s.tenantId });
      return send(302, "", { location: `/b04?batch=${g.b.import_batch_id}` });
    }

    // ── B-04 映射工作畫面 ──
    if (url.pathname === "/b04" && req.method === "GET") {
      const g = b04Guard(url.searchParams.get("batch") ?? "", "b04.view");
      if (!g.ok) return;
      const lines = tbLines(s, g.b.import_batch_id);
      const maps = currentMappings(s, g.b.engagement_id, g.b.period_end);
      const { rows, unmapped } = applyMappings(lines, maps);
      const cov = coverage(lines, maps);
      const bySource = new Map(maps.map((m) => [m.sourceAccountCode, m]));
      const drafts = query<Record<string, string>>(
        `SELECT mr.mapping_rule_id, mr.source_account_code, mr.version_no, mr.created_by,
                a.code AS target_code, a.name AS target_name
           FROM mapping_rule mr JOIN account a ON a.account_id = mr.target_account_id
          WHERE mr.engagement_id = :'e'::uuid AND mr.approved_at IS NULL
          ORDER BY mr.source_account_code, mr.version_no`,
        { e: g.b.engagement_id }, { tenantId: s.tenantId });
      const accounts = query<Record<string, string>>(
        `SELECT a.account_id, a.code, a.name FROM account a
           JOIN chart_of_accounts c ON c.coa_id = a.coa_id
          WHERE c.engagement_id = :'e'::uuid ORDER BY a.code`,
        { e: g.b.engagement_id }, { tenantId: s.tenantId });
      const draftBySource = new Map(drafts.map((d) => [d.source_account_code, d]));
      const fmt = (c: bigint) => c === 0n ? "" : fmtCents(c);
      return send(200, page("B-04 科目與維度映射", b04CtxBar(g.b, "B-04 科目與維度映射"),
        `<h2>映射狀態</h2>
         <p>覆蓋率（按金額）<b>${(cov.ratio * 100).toFixed(1)}%</b>｜
            未映射科目 <b>${cov.unmappedAccounts.length}</b> 個｜
            未映射影響金額（借＋貸）<b>${fmtCents(cov.unmappedCents)}</b></p>
         <table><tr><th>來源科目</th><th>名稱</th><th>借方</th><th>貸方</th><th>映射狀態</th><th>集團科目</th><th>版本</th></tr>
         ${lines.map((l) => {
           const m = bySource.get(l.accountCode);
           const d = draftBySource.get(l.accountCode);
           const st = m ? `<span class="badge st-MATCHED">已映射</span>${d ? ` <span class="badge st-PENDING_CONFIRMATION">草稿待批（衝突檢視）</span>` : ""}`
                        : d ? `<span class="badge st-PENDING_CONFIRMATION">草稿待批</span>`
                            : `<span class="badge st-QUARANTINED">未映射</span>`;
           return `<tr><td>${esc(l.accountCode)}</td><td>${esc(l.accountName)}</td>
             <td style="text-align:right">${fmt(l.debitCents)}</td><td style="text-align:right">${fmt(l.creditCents)}</td>
             <td>${st}</td><td>${m ? esc(`${m.targetCode} ${m.targetName}`) : d ? `<span class="note">${esc(`${d.target_code} ${d.target_name}`)}（草稿）</span>` : "—"}</td>
             <td>${m ? `v${m.versionNo}` : ""}</td></tr>`;
         }).join("")}
         </table>
         <h2>建立映射（草稿 → 需另一自然人批准）</h2>
         <form class="up" method="post" action="/b04/map">
           <input type="hidden" name="batch" value="${g.b.import_batch_id}">
           來源科目 <select name="source_code">${lines.filter((l) => !bySource.has(l.accountCode))
             .map((l) => `<option value="${esc(l.accountCode)}">${esc(l.accountCode)} ${esc(l.accountName)}</option>`).join("")}
             ${lines.filter((l) => bySource.has(l.accountCode))
             .map((l) => `<option value="${esc(l.accountCode)}">${esc(l.accountCode)} ${esc(l.accountName)}（改版）</option>`).join("")}</select>
           → 集團科目 <select name="target">${accounts.map((a) =>
             `<option value="${a.account_id}">${esc(a.code)} ${esc(a.name)}</option>`).join("")}</select>
           <button>建立草稿</button>
         </form>
         ${drafts.length ? `<h2>待批准草稿</h2>
         <table><tr><th>來源科目</th><th>集團科目</th><th>版本</th><th></th></tr>
         ${drafts.map((d) => `<tr><td>${esc(d.source_account_code)}</td>
           <td>${esc(`${d.target_code} ${d.target_name}`)}</td><td>v${d.version_no}</td>
           <td><form method="post" action="/b04/approve" style="margin:0">
             <input type="hidden" name="batch" value="${g.b.import_batch_id}">
             <input type="hidden" name="rule" value="${d.mapping_rule_id}">
             <button>批准（R4）</button></form></td></tr>`).join("")}
         </table><p class="note">建立者不得批准自己的草稿（實例級 SOD；DB 觸發器為最後防線）。</p>` : ""}
         <p><a href="/b04/preview?batch=${g.b.import_batch_id}">→ 產生集團科目 TB 預覽</a>
            　<a href="/b06?batch=${g.b.import_batch_id}">→ B-06 計算執行（PREVIEW Run）</a>
            <form method="post" action="/b04/submit" style="display:inline;margin:0">
              <input type="hidden" name="batch" value="${g.b.import_batch_id}">
              <button>映射完成確認（G-02）</button></form>　<a href="/">回 B-00</a></p>
         <h2>調整（B-05）</h2>
         <form class="up" method="post" action="/b05/create">
           <input type="hidden" name="batch" value="${g.b.import_batch_id}">
           標題 <input name="title" size="40" value="GROUP_GAAP 調整">
           <button>建立調整草稿（R2）</button>
           <span class="note">本切片只收 MAJOR 重大調整，走完整三段式 R2→R3→R4</span>
         </form>
         ${(() => {
           const adjs = query<Record<string, string>>(
             `SELECT adjustment_id, title, status, business_version FROM adjustment
               WHERE engagement_id = :'e'::uuid ORDER BY created_at DESC LIMIT 20`,
             { e: g.b.engagement_id }, { tenantId: s.tenantId });
           return adjs.length ? `<table><tr><th>調整</th><th>狀態</th><th>bv</th><th></th></tr>
             ${adjs.map((a) => `<tr><td>${esc(a.title)}</td>
               <td><span class="badge st-${a.status === "APPROVED" ? "ACCEPTED" : "UPLOADED"}">${a.status}</span></td>
               <td>${esc(a.business_version)}</td>
               <td><a href="/b05?adj=${a.adjustment_id}">開啟 B-05</a></td></tr>`).join("")}</table>` : "";
         })()}`));
    }

    // ── 建立映射草稿 ──
    if (url.pathname === "/b04/map" && req.method === "POST") {
      const fields = Object.fromEntries(new URLSearchParams((await readBody(req)).toString("utf8")));
      const g = b04Guard(fields["batch"] ?? "", "mapping.create");
      if (!g.ok) return;
      if (!g.roles.has("R2") && !g.roles.has("R7")) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "mapping.create.denied", s.userId,
          "import_batch", g.b.import_batch_id, { reason: "建立映射需 R2 或 R7" });
        return send(403, page("拒絕", b04CtxBar(g.b, "B-04"), "<h2>⛔ 建立映射需 R2 或 R7 角色</h2>"));
      }
      const sourceCode = fields["source_code"] ?? "";
      const target = fields["target"] ?? "";
      // 來源批次必須已接受（0021）：未經接受的批次不得成為正式映射的來源脈絡。
      // 應用層先判定並回穩定機器代碼；DB 觸發器（含 FOR UPDATE）仍是最後防線，
      // 不信任應用層——少了這層，繞過 UI 直接呼叫會得到 DB 例外與 HTTP 500。
      if (g.b.status !== "ACCEPTED") {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "mapping.create.rejected", s.userId,
          "import_batch", g.b.import_batch_id,
          { guard: "SOURCE_BATCH_NOT_ACCEPTED", reason: "映射來源批次尚未接受",
            batch_status: g.b.status, source_code: sourceCode });
        return send(409, page("拒絕", b04CtxBar(g.b, "B-04"),
          `<h2>⛔ SOURCE_BATCH_NOT_ACCEPTED：來源批次尚未接受</h2>
           <p>目前狀態 <b>${esc(g.b.status)}</b>；映射的來源脈絡必須是已接受（ACCEPTED）的批次。</p>
           <p class="note">此次嘗試已寫入稽核軌跡。</p>`),
          { "x-error-code": "SOURCE_BATCH_NOT_ACCEPTED" });
      }
      // 歸屬完整性（§24.1A）：目標科目必須屬於本案件的科目表；DB 觸發器為最後防線
      const okTarget = query<{ n: string }>(
        `SELECT count(*) AS n FROM account a JOIN chart_of_accounts c ON c.coa_id = a.coa_id
          WHERE a.account_id = :'a'::uuid AND c.engagement_id = :'e'::uuid`,
        { a: target, e: g.b.engagement_id }, { tenantId: s.tenantId });
      if (Number(okTarget[0]?.n) !== 1) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "mapping.create.rejected", s.userId,
          "import_batch", g.b.import_batch_id,
          { guard: "歸屬/§24.1A", reason: "目標科目不屬於本案件", source_code: sourceCode, target });
        return send(403, page("拒絕", b04CtxBar(g.b, "B-04"),
          `<h2>⛔ 歸屬違規：目標科目不屬於本案件的科目表</h2><p>此次嘗試已寫入稽核軌跡。</p>`));
      }
      // 狀態異動與 DomainEvent 同一 statement（事件原子化）：事件寫入失敗＝整句回滾，
      // 不存在「映射已生效而事件不存在」（BACKLOG 2026-08-04 條目）
      const ruleId = randomUUID();
      exec(`WITH ins AS (
              INSERT INTO mapping_rule (mapping_rule_id, tenant_id, engagement_id,
                     source_account_code, target_account_id, version_no, created_by,
                     source_import_batch_id)
              VALUES (:'m'::uuid, :'t'::uuid, :'e'::uuid, :'sc', :'a'::uuid,
                      (SELECT COALESCE(MAX(version_no), 0) + 1 FROM mapping_rule
                        WHERE engagement_id = :'e'::uuid AND source_account_code = :'sc'),
                      :'u'::uuid, :'b'::uuid)
              RETURNING mapping_rule_id, version_no)
            INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
            SELECT :'t'::uuid, 'DOMAIN_EVENT', 'mapping_rule.drafted', :'u'::uuid,
                   'mapping_rule', ins.mapping_rule_id,
                   jsonb_build_object('source_code', :'sc', 'target', :'a', 'version', ins.version_no)
              FROM ins`,
        { m: ruleId, t: s.tenantId, e: g.b.engagement_id, sc: sourceCode, a: target, u: s.userId,
          b: g.b.import_batch_id },
        { tenantId: s.tenantId });
      return send(302, "", { location: `/b04?batch=${g.b.import_batch_id}` });
    }

    // ── 批准映射（R4；批准人 ≠ 建立者） ──
    if (url.pathname === "/b04/approve" && req.method === "POST") {
      const fields = Object.fromEntries(new URLSearchParams((await readBody(req)).toString("utf8")));
      const g = b04Guard(fields["batch"] ?? "", "mapping.approve");
      if (!g.ok) return;
      const ruleId = fields["rule"] ?? "";
      if (!g.roles.has("R4")) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "mapping.approve.denied", s.userId,
          "mapping_rule", ruleId, { reason: "批准需 R4 角色（§24.6 權限矩陣）" });
        return send(403, page("拒絕", b04CtxBar(g.b, "B-04"), "<h2>⛔ 批准映射需 R4 角色</h2>"));
      }
      const rule = query<{ created_by: string }>(
        `SELECT created_by FROM mapping_rule
          WHERE mapping_rule_id = :'m'::uuid AND engagement_id = :'e'::uuid AND approved_at IS NULL`,
        { m: ruleId, e: g.b.engagement_id }, { tenantId: s.tenantId })[0];
      if (!rule) return send(404, page("404", b04CtxBar(g.b, "B-04"), "<h2>草稿不存在或已批准</h2>"));
      if (rule.created_by === s.userId) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "mapping.approve.rejected", s.userId,
          "mapping_rule", ruleId, { guard: "SOD", reason: "建立者不得批准自己建立的映射版本" });
        return send(403, page("拒絕", b04CtxBar(g.b, "B-04"),
          "<h2>⛔ SOD：建立者不得批准自己建立的映射版本</h2><p>此次嘗試已寫入稽核軌跡。</p>"));
      }
      // 批准與事件同一 statement；併發下 UPDATE 落空（已被批准）→ fn_assert 整句回滾
      try {
        exec(`WITH upd AS (
                UPDATE mapping_rule SET approved_by = :'u'::uuid, approved_at = now()
                 WHERE mapping_rule_id = :'m'::uuid AND approved_at IS NULL
                 RETURNING mapping_rule_id),
              ev AS (
                INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
                SELECT :'t'::uuid, 'DOMAIN_EVENT', 'mapping_rule.approved', :'u'::uuid,
                       'mapping_rule', upd.mapping_rule_id, '{}'::jsonb
                  FROM upd)
              SELECT fn_assert(EXISTS (SELECT 1 FROM upd), 'ALREADY_APPROVED')`,
          { u: s.userId, m: ruleId, t: s.tenantId }, { tenantId: s.tenantId });
      } catch (e) {
        if (String(e).includes("ALREADY_APPROVED"))
          return send(409, page("拒絕", b04CtxBar(g.b, "B-04"),
            "<h2>⛔ 草稿已被批准或不存在（併發）</h2>"));
        throw e;
      }
      return send(302, "", { location: `/b04?batch=${g.b.import_batch_id}` });
    }

    // ── 集團科目 TB 預覽（非正式輸出；§25.9 output_capability=PREVIEW） ──
    if (url.pathname === "/b04/preview" && req.method === "GET") {
      const g = b04Guard(url.searchParams.get("batch") ?? "", "b04.preview");
      if (!g.ok) return;
      if (g.b.status !== "ACCEPTED")
        return send(409, page("拒絕", b04CtxBar(g.b, "B-04 預覽"),
          `<h2>⛔ 批次尚未 ACCEPTED，不產生預覽</h2><p><a href="/">回 B-00</a></p>`));
      const lines = tbLines(s, g.b.import_batch_id);
      const maps = currentMappings(s, g.b.engagement_id, g.b.period_end);
      const { rows, unmapped } = applyMappings(lines, maps);
      const cov = coverage(lines, maps);
      const g02 = g02Check(cov);
      const src = totalsOf(lines);
      const grp = totalsOf(rows);
      const un = totalsOf(unmapped);
      const tied = grp.debitCents + un.debitCents === src.debitCents
                && grp.creditCents + un.creditCents === src.creditCents;
      audit(s.tenantId, "DOMAIN_EVENT", "group_tb.preview_generated", s.userId,
        "import_batch", g.b.import_batch_id,
        { mapped_rows: rows.length, unmapped: cov.unmappedAccounts.length, g02_ok: g02.ok });
      const fmt = (c: bigint) => c === 0n ? "" : fmtCents(c);
      return send(200, page("集團科目 TB（預覽）", b04CtxBar(g.b, "B-04 集團 TB 預覽"),
        `<div style="background:#fff3e0;border:1px solid #d9a05b;border-radius:6px;padding:10px 14px;font-weight:600">
           PREVIEW（預覽）——非正式輸出、未經覆核批准，不得作為入帳或交付依據
         </div>
         <p>G-02 ${g02.ok ? `<span class="badge st-MATCHED">通過</span>`
                          : `<span class="badge st-QUARANTINED">阻擋</span> ${(g02 as { reasons: string[] }).reasons.map(esc).join("；")}`}</p>
         <h2>集團科目 TB</h2>
         <table><tr><th>集團科目</th><th>名稱</th><th>借方</th><th>貸方</th><th>來源科目</th></tr>
         ${rows.map((r) => `<tr><td>${esc(r.targetCode)}</td><td>${esc(r.targetName)}</td>
           <td style="text-align:right">${fmt(r.debitCents)}</td><td style="text-align:right">${fmt(r.creditCents)}</td>
           <td class="note">${r.sourceCodes.map(esc).join("、")}</td></tr>`).join("")}
         ${unmapped.length ? `<tr><td colspan="2"><b>未映射（不得靜默吸收）</b></td><td></td><td></td><td></td></tr>` +
           unmapped.map((l) => `<tr><td>—</td><td>${esc(l.accountCode)} ${esc(l.accountName)}</td>
             <td style="text-align:right">${fmt(l.debitCents)}</td><td style="text-align:right">${fmt(l.creditCents)}</td>
             <td><span class="badge st-QUARANTINED">未映射</span></td></tr>`).join("") : ""}
         </table>
         <h2>控制總額勾稽</h2>
         <table><tr><th></th><th>借方</th><th>貸方</th></tr>
         <tr><td>來源 TB</td><td style="text-align:right">${fmtCents(src.debitCents)}</td><td style="text-align:right">${fmtCents(src.creditCents)}</td></tr>
         <tr><td>集團 TB（含未映射）</td><td style="text-align:right">${fmtCents(grp.debitCents + un.debitCents)}</td><td style="text-align:right">${fmtCents(grp.creditCents + un.creditCents)}</td></tr>
         <tr><td>勾稽</td><td colspan="2">${tied ? `<span class="badge st-MATCHED">一致</span>` : `<span class="badge st-QUARANTINED">不一致</span>`}</td></tr>
         </table>
         <p><a href="/b04?batch=${g.b.import_batch_id}">← 回 B-04</a></p>`));
    }

    // ── 映射完成確認（G-02 守衛；繞過 UI 直接呼叫亦被擋並留痕） ──
    if (url.pathname === "/b04/submit" && req.method === "POST") {
      const fields = Object.fromEntries(new URLSearchParams((await readBody(req)).toString("utf8")));
      const g = b04Guard(fields["batch"] ?? "", "mapping.submit");
      if (!g.ok) return;
      if (g.b.status !== "ACCEPTED")
        return send(409, page("拒絕", b04CtxBar(g.b, "B-04"), "<h2>⛔ 批次尚未 ACCEPTED</h2>"));
      const cov = coverage(tbLines(s, g.b.import_batch_id), currentMappings(s, g.b.engagement_id, g.b.period_end));
      const g02 = g02Check(cov);
      if (!g02.ok) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "mapping.submit.rejected", s.userId,
          "import_batch", g.b.import_batch_id,
          { guard: "G-02", reasons: g02.reasons, unmapped_cents: String(cov.unmappedCents) });
        return send(409, page("G-02 阻擋", b04CtxBar(g.b, "B-04"),
          `<h2>⛔ G-02：重要來源餘額尚未全數映射</h2>
           <ul>${g02.reasons.map((r) => `<li>${esc(r)}</li>`).join("")}</ul>
           <p class="note">映射例外批准機制屬後續切片；本切片任何未映射餘額即阻擋。</p>
           <p><a href="/b04?batch=${g.b.import_batch_id}">回 B-04 處理未映射科目</a></p>`));
      }
      audit(s.tenantId, "DOMAIN_EVENT", "mapping.review_ready", s.userId,
        "import_batch", g.b.import_batch_id, { coverage_ratio: cov.ratio });
      return send(200, page("G-02 通過", b04CtxBar(g.b, "B-04"),
        `<h2>✓ G-02 通過：映射完成，可進入覆核</h2>
         <p class="note">期間狀態機（IN_PREPARATION → IN_REVIEW）屬後續切片；本次僅記錄 DomainEvent。</p>
         <p><a href="/b04/preview?batch=${g.b.import_batch_id}">查看集團 TB 預覽</a>　<a href="/">回 B-00</a></p>`));
    }

    // ═══════════ SLICE-M2-02A：B-05 調整編製・覆核・批准 ═══════════
    // 契約：docs/slices/SLICE-M2-02A_調整生命週期.md
    // 三個守衛掛在三個不同的狀態遷移；DB 觸發器（0007）為最後防線。

    // ── 建立調整草稿（R2） ──
    if (url.pathname === "/b05/create" && req.method === "POST") {
      const f = Object.fromEntries(new URLSearchParams((await readBody(req)).toString("utf8")));
      const g = b04Guard(f["batch"] ?? "", "adjustment.create");
      if (!g.ok) return;
      if (!g.roles.has("R2")) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "adjustment.create.denied", s.userId,
          "import_batch", g.b.import_batch_id, { reason: "編製調整需 R2 角色" });
        return send(403, page("拒絕", b04CtxBar(g.b, "B-04"), "<h2>⛔ 編製調整需 R2 角色</h2>"));
      }
      const pr = query<{ period_revision_id: string }>(
        `SELECT declared_period_revision_id AS period_revision_id FROM import_batch
          WHERE import_batch_id = :'b'::uuid`,
        { b: g.b.import_batch_id }, { tenantId: s.tenantId })[0];
      const created = adjSvc.createDraft(
        { userId: s.userId, tenantId: s.tenantId, roles: g.roles },
        { engagementId: g.b.engagement_id, periodRevisionId: pr.period_revision_id,
          title: f["title"] || "未命名調整" });
      if (!created.ok) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "adjustment.create.rejected", s.userId,
          "import_batch", g.b.import_batch_id, { code: "BASIS_NOT_CONFIGURED" });
        return send(409, page("拒絕", b04CtxBar(g.b, "B-04"),
          "<h2>⛔ BASIS_NOT_CONFIGURED</h2><p>本案件尚未建立 A／C 基礎，無法建立跨基礎調整。</p>"),
          { "x-error-code": "BASIS_NOT_CONFIGURED" });
      }
      return send(302, "", { location: `/b05?adj=${created.adjustmentId}` });
    }

    // ═══════════ SLICE-M2-04：B-03 身分確認（UNVERIFIABLE 人工確認） ═══════════
    // 明確案件指派的業務角色（不含租戶層 NULL 指派——R6 不得取得客戶工作存取權）
    const explicitRolesOf = (engagementId: string): Set<string> =>
      new Set(query<{ role: string }>(
        `SELECT role FROM role_assignment
          WHERE user_id = :'u'::uuid AND revoked_at IS NULL AND engagement_id = :'e'::uuid`,
        { u: s.userId, e: engagementId }, { tenantId: s.tenantId }).map((r) => r.role));
    const loadBatchFull = (batchId: string) => query<Record<string, string>>(
      `SELECT ib.import_batch_id, ib.engagement_id, ib.status, ib.identity_status,
              ib.batch_version, ib.uploaded_by, ib.current_identity_assessment_id,
              ib.file_sha256, ce.name AS client, le.name AS entity,
              le.authoritative_code, rp.label AS period
         FROM import_batch ib
         JOIN client_engagement ce ON ce.engagement_id = ib.engagement_id
         JOIN legal_entity le ON le.legal_entity_id = ib.declared_legal_entity_id
         JOIN period_revision pr ON pr.period_revision_id = ib.declared_period_revision_id
         JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
        WHERE ib.import_batch_id = :'b'::uuid`,
      { b: batchId }, { tenantId: s.tenantId })[0];

    if (url.pathname === "/b03/identity" && req.method === "GET") {
      const b = loadBatchFull(url.searchParams.get("batch") ?? "");
      if (!b) return send(404, page("404", "", "<h2>批次不存在</h2>"));
      const roles = explicitRolesOf(b.engagement_id);
      if (!roles.has("R2") && !roles.has("R3") && !roles.has("R4")) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "identity.view.denied", s.userId,
          "import_batch", b.import_batch_id, { reason: "無該案件業務角色指派" });
        return send(403, page("拒絕", "<b>⛔</b>", "<h2>⛔ 未被指派此案件</h2><p>此次嘗試已寫入稽核軌跡。</p>"));
      }
      const assessments = query<Record<string, string>>(
        `SELECT assessment_id, evidence_kind, match_result, detected_identity::text AS detected,
                detection_rule_version, assessed_at::text AS assessed_at
           FROM source_identity_assessment WHERE import_batch_id = :'b'::uuid
          ORDER BY assessed_at, assessment_id`,
        { b: b.import_batch_id }, { tenantId: s.tenantId });
      const ctx = `<span>畫面 <b>B-03 身分確認</b></span><span>客戶 <b>${esc(b.client)}</b></span>
        <span>法人 <b>${esc(b.entity)}</b></span><span>期間 <b>${esc(b.period)}</b></span>
        <span>批次 <b>${b.import_batch_id.slice(0, 8)}（v${b.batch_version}）</b></span>`;
      const confirmable = b.status === "VALIDATED" && b.identity_status === "PENDING_CONFIRMATION";
      return send(200, page("B-03 身分確認", ctx,
        `<h2>宣告目標</h2>
         <table><tr><th>客戶</th><th>法人</th><th>法人權威代碼</th><th>期間</th><th>批次版本</th><th>檔案 SHA-256</th></tr>
         <tr><td>${esc(b.client)}</td><td>${esc(b.entity)}</td><td>${esc(b.authoritative_code ?? "—")}</td>
         <td>${esc(b.period)}</td><td>v${esc(b.batch_version)}</td><td class="note">${esc(b.file_sha256 ?? "")}</td></tr></table>
         <h2>偵測證據（全部評估，含歷史）</h2>
         <table><tr><th>current</th><th>證據強度</th><th>偵測值</th><th>判定</th><th>規則版本</th><th>別名表版本</th><th>評估時間</th></tr>
         ${assessments.map((a) => `<tr>
           <td>${a.assessment_id === b.current_identity_assessment_id ? "✓ current" : "（歷史）"}</td>
           <td>${esc(a.evidence_kind)}</td><td class="note">${esc(a.detected)}</td>
           <td><span class="badge st-${a.match_result === "MATCH" ? "MATCHED" : a.match_result === "CONFLICT" ? "CONFLICT" : "PENDING_CONFIRMATION"}">${a.match_result}</span></td>
           <td>${esc(a.detection_rule_version)}</td><td>—（本刀無別名表）</td>
           <td class="note">${esc(a.assessed_at.slice(0, 19))}</td></tr>`).join("")}
         </table>
         ${b.identity_status === "CONFLICT"
           ? `<p>⛔ <b>CONFLICT 不提供人工豁免</b>（§25.5）。出路只有三條：修正宣告目標、
              重新上傳正確檔案、或以新版識別規則重新偵測。</p>`
           : b.identity_status === "MANUALLY_RESOLVED"
           ? `<p>✅ 已人工確認（MANUALLY_RESOLVED）。可回 <a href="/">B-00</a> 執行接受（G-01 判定式）。</p>`
           : confirmable ? `
         <h2>人工確認（資料接受角色 R2；上傳者不得確認自己——SOD-07）</h2>
         <form class="up" method="post" action="/b03/identity/confirm">
           <input type="hidden" name="batch" value="${b.import_batch_id}">
           <input type="hidden" name="assessment_id" value="${b.current_identity_assessment_id}">
           確認理由（必填）<br><textarea name="reason" rows="3" cols="70"
             placeholder="例：已向客戶電話確認為 A 商事株式会社之試算表"></textarea><br>
           證據參照（選填）<input name="evidence_ref" size="40"><br>
           <button>確認歸屬（寫入不可變紀錄）</button>
           <span class="note">確認不會自動接受——接受仍須另行執行並通過 G-01 三條件（CTX-g）</span>
         </form>` : `<p class="note">批次目前為 ${esc(b.status)}／${esc(b.identity_status)}，不在可確認狀態。</p>`}
         <p><a href="/">回 B-00</a></p>`));
    }

    if (url.pathname === "/b03/identity/confirm" && req.method === "POST") {
      const f = Object.fromEntries(new URLSearchParams((await readBody(req)).toString("utf8")));
      const b = loadBatchFull(f["batch"] ?? "");
      if (!b) return send(404, page("404", "", "<h2>批次不存在</h2>"));
      const roles = explicitRolesOf(b.engagement_id);
      if (!roles.has("R2")) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "identity.confirm.denied", s.userId,
          "import_batch", b.import_batch_id, { code: "ROLE_REQUIRED", reason: "確認需該案件的有效 R2 指派（資料接受角色）" });
        return send(403, page("拒絕", "<b>⛔</b>", "<h2>⛔ 確認需該案件的有效 R2 指派</h2>"));
      }
      if (b.uploaded_by === s.userId) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "identity.confirm.denied", s.userId,
          "import_batch", b.import_batch_id,
          { code: "SOD_07", reason: "上傳者不得確認自己上傳的批次（角色切換無效）" });
        return send(403, page("拒絕", "<b>⛔</b>",
          "<h2>⛔ SOD-07：上傳者不得確認自己上傳的批次</h2><p>與當下角色無關。此次嘗試已寫入稽核軌跡。</p>"));
      }
      // 一般欄位驗證錯誤：409＋機器代碼，不寫 CVA（§25.18）
      if (!(f["reason"] ?? "").trim())
        return send(409, page("欄位錯誤", "<b>⛔</b>",
          "<h2>REASON_REQUIRED</h2><p>確認理由為必填。</p>"));
      if (b.status !== "VALIDATED" || b.identity_status !== "PENDING_CONFIRMATION") {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "identity.confirm.rejected", s.userId,
          "import_batch", b.import_batch_id,
          { code: "STATE_NOT_CONFIRMABLE", status: b.status, identity_status: b.identity_status });
        return send(409, page("拒絕", "<b>⛔</b>",
          `<h2>⛔ STATE_NOT_CONFIRMABLE</h2><p>需 VALIDATED＋PENDING_CONFIRMATION（目前 ${esc(b.status)}／${esc(b.identity_status)}）。</p>`));
      }
      if ((f["assessment_id"] ?? "") !== b.current_identity_assessment_id) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "identity.confirm.rejected", s.userId,
          "import_batch", b.import_batch_id,
          { code: "NOT_CURRENT_ASSESSMENT", selected: f["assessment_id"] ?? "" });
        return send(409, page("拒絕", "<b>⛔</b>",
          "<h2>⛔ NOT_CURRENT_ASSESSMENT</h2><p>只能確認 current assessment——重新解析後的舊評估不可沿用（CTX-e）。</p>"));
      }
      const ev = (f["evidence_ref"] ?? "").trim();
      // 單一交易：Resolution＋MANUALLY_RESOLVED＋DomainEvent 同生共死（DB 守衛為最後防線）
      exec(`BEGIN;
        INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id,
               batch_version, resolved_by, acting_role, reason, evidence_ref, detection_rule_version)
        VALUES (:'t'::uuid, :'aid'::uuid, :'b'::uuid, ${Number(b.batch_version)}, :'u'::uuid, 'R2',
               :'rs', ${ev ? ":'ev'" : "NULL"},
               (SELECT detection_rule_version FROM source_identity_assessment WHERE assessment_id = :'aid'::uuid));
        UPDATE import_batch SET identity_status = 'MANUALLY_RESOLVED'
         WHERE import_batch_id = :'b'::uuid;
        INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
        VALUES (:'t'::uuid, 'DOMAIN_EVENT', 'import_batch.identity_resolved', :'u'::uuid,
               'import_batch', :'b'::uuid,
               jsonb_build_object('assessment_id', :'aid', 'reason', :'rs',
                 'evidence_ref', ${ev ? ":'ev'" : "NULL"},
                 'detection_rule_version',
                 (SELECT detection_rule_version FROM source_identity_assessment WHERE assessment_id = :'aid'::uuid),
                 'alias_table_version', NULL));
        COMMIT;`,
        { t: s.tenantId, aid: b.current_identity_assessment_id, b: b.import_batch_id,
          u: s.userId, rs: f["reason"].trim(), ...(ev ? { ev } : {}) },
        { tenantId: s.tenantId });
      return send(302, "", { location: `/b03/identity?batch=${b.import_batch_id}` });
    }

    // ═══════════ SLICE-M2-02B：B-06 PREVIEW CalculationRun ═══════════
    const b06Refuse = (b: BatchCtx | null, action: string, code: keyof typeof RUN_REASON,
                       detail = ""): void => {
      audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", action, s.userId,
        "calculation_run", b?.import_batch_id ?? s.userId,
        { code, reason: RUN_REASON[code], detail });
      send(code === "ROLE_REQUIRED" ? 403 : 409,
        page("拒絕", b ? b04CtxBar(b, "B-06") : "<b>⛔</b>",
          `<h2>⛔ ${esc(code)}</h2><p>${esc(RUN_REASON[code])}</p>` +
          (detail ? `<p class="note">${esc(detail)}</p>` : "") +
          `<p>此次嘗試已寫入稽核軌跡。</p><p><a href="/">回 B-00</a></p>`));
    };

    // ── 建立 PREVIEW Run（R2／R3；同一交易：解析＋G-02＋Manifest＋Run＋Job＋事件） ──
    if (url.pathname === "/b06/run" && req.method === "POST") {
      const f = Object.fromEntries(new URLSearchParams((await readBody(req)).toString("utf8")));
      const g = b04Guard(f["batch"] ?? "", "calculation.create");
      if (!g.ok) return;
      if (!g.roles.has("R2") && !g.roles.has("R3"))
        return b06Refuse(g.b, "calculation.create.denied", "ROLE_REQUIRED");
      if (g.b.status !== "ACCEPTED")
        return b06Refuse(g.b, "calculation.create.rejected", "BATCH_NOT_ACCEPTED",
          `批次目前為 ${g.b.status}`);
      const requestKey = f["request_key"] ?? "";
      if (!/^[0-9a-f-]{36}$/.test(requestKey))
        return send(400, page("錯誤", b04CtxBar(g.b, "B-06"), "<h2>request_key 缺漏或格式錯誤</h2>"));
      // 冪等契約：同 key 同內容 → 原 run；同 key 異內容 → 409
      const rch = createHash("sha256")
        .update(`B06RUN|${g.b.engagement_id}|${g.b.declared_period_revision_id}|${g.b.import_batch_id}`)
        .digest("hex");
      const existing = query<{ calculation_run_id: string; request_content_hash: string }>(
        `SELECT calculation_run_id, request_content_hash FROM calculation_run
          WHERE request_key = :'rk'::uuid`, { rk: requestKey }, { tenantId: s.tenantId });
      if (existing[0]) {
        if (existing[0].request_content_hash === rch)
          return send(302, "", { location: `/b06/run?id=${existing[0].calculation_run_id}` });
        return b06Refuse(g.b, "calculation.create.rejected", "REQUEST_KEY_REUSED");
      }
      const runId = randomUUID();
      const maniId = randomUUID();
      const ik = idempotencyKey("CALCULATION_RUN", runId, 1, ENGINE_VERSION);
      try {
        // REPEATABLE READ：READ COMMITTED 是逐 statement 換 snapshot——TEMP 表只保證
        // G-02 與 Manifest 用同一映射集合，TB／調整／CoA 仍可能來自不同時間點。
        exec(`BEGIN ISOLATION LEVEL REPEATABLE READ;
          SELECT fn_assert((SELECT status FROM import_batch
            WHERE import_batch_id = :'b'::uuid AND engagement_id = :'e'::uuid) = 'ACCEPTED',
            'BATCH_NOT_ACCEPTED');

          -- 同一交易 snapshot：解析集合 → 對同一份集合驗 G-02 → 寫入 Manifest（護欄 2）
          CREATE TEMP TABLE _tb ON COMMIT DROP AS
            SELECT account_code, MAX(COALESCE(account_name,'')) AS account_name,
                   SUM(debit) AS debit, SUM(credit) AS credit
              FROM source_ledger_line WHERE import_batch_id = :'b'::uuid
             GROUP BY account_code;
          CREATE TEMP TABLE _map ON COMMIT DROP AS
            SELECT DISTINCT ON (mr.source_account_code)
                   mr.mapping_rule_id, mr.source_account_code, mr.version_no,
                   mr.effective_from, mr.effective_to,
                   mr.target_account_id, a.code AS target_code, a.name AS target_name,
                   mr.created_by, cu.display_name AS created_by_name,
                   mr.approved_by, au.display_name AS approved_by_name, mr.approved_at
              FROM mapping_rule mr JOIN account a ON a.account_id = mr.target_account_id
              JOIN app_user cu ON cu.user_id = mr.created_by
              JOIN app_user au ON au.user_id = mr.approved_by
             WHERE mr.engagement_id = :'e'::uuid AND mr.approved_at IS NOT NULL
               AND (mr.effective_from IS NULL OR mr.effective_from <= :'pe'::date)
               AND (mr.effective_to   IS NULL OR mr.effective_to   >= :'pe'::date)
             ORDER BY mr.source_account_code, mr.version_no DESC;
          SELECT fn_assert(NOT EXISTS (
            SELECT 1 FROM _tb t LEFT JOIN _map m ON m.source_account_code = t.account_code
             WHERE m.source_account_code IS NULL),
            'G02_UNMAPPED:'||COALESCE((SELECT string_agg(t.account_code,'、' ORDER BY t.account_code)
              FROM _tb t LEFT JOIN _map m ON m.source_account_code = t.account_code
             WHERE m.source_account_code IS NULL),''));

          CREATE TEMP TABLE _adj ON COMMIT DROP AS
            SELECT je.adjustment_id, je.business_version, adj.title,
                   adj.prepared_by, pu.display_name AS prepared_by_name, adj.prepared_at,
                   adj.reviewed_by, ru.display_name AS reviewed_by_name, adj.reviewed_at,
                   adj.approved_by, qu.display_name AS approved_by_name, adj.approved_at,
                   jsonb_agg(jsonb_build_object('line_no', jl.line_no, 'account_id', jl.account_id,
                     'code', a.code, 'name', a.name,
                     'debit', jl.debit::text, 'credit', jl.credit::text) ORDER BY jl.line_no) AS lines,
                   string_agg(jl.line_no||':'||a.code||':'||jl.debit::text||':'||jl.credit::text,
                     ';' ORDER BY jl.line_no) AS canon_lines
              FROM journal_entry je
              JOIN journal_line jl ON jl.entry_id = je.entry_id
              JOIN account a ON a.account_id = jl.account_id
              JOIN adjustment adj ON adj.adjustment_id = je.adjustment_id
              JOIN app_user pu ON pu.user_id = adj.prepared_by
              JOIN app_user ru ON ru.user_id = adj.reviewed_by
              JOIN app_user qu ON qu.user_id = adj.approved_by
             WHERE je.engagement_id = :'e'::uuid AND je.period_revision_id = :'pr'::uuid
             GROUP BY je.adjustment_id, je.business_version, adj.title,
                      adj.prepared_by, pu.display_name, adj.prepared_at,
                      adj.reviewed_by, ru.display_name, adj.reviewed_at,
                      adj.approved_by, qu.display_name, adj.approved_at;

          CREATE TEMP TABLE _entries (
            object_type text, object_id uuid, concurrency_version int,
            domain_version_kind text, domain_version_value text,
            content_canonical text, payload jsonb) ON COMMIT DROP;
          INSERT INTO _entries SELECT 'SCOPE', NULL, NULL, 'SCOPE', '1',
            'SCOPE|NO_FX|engine=' || :'ev' || '|engagement=' || :'e' || '|period_revision=' || :'pr'
              || '|batch=' || :'b',
            jsonb_build_object('calculation_scope','NO_FX','engine_version', :'ev');
          INSERT INTO _entries SELECT 'SOURCE_TB', :'b'::uuid, NULL, 'BATCH_VERSION',
            (SELECT batch_version::text FROM import_batch WHERE import_batch_id = :'b'::uuid),
            'SOURCE_TB|' || :'b' || '|v' ||
              (SELECT batch_version FROM import_batch WHERE import_batch_id = :'b'::uuid) ||
              '|sha=' || (SELECT COALESCE(file_sha256,'') FROM import_batch WHERE import_batch_id = :'b'::uuid) ||
              '|' || (SELECT COALESCE(string_agg(account_code||':'||debit::text||':'||credit::text,
                        ';' ORDER BY account_code),'') FROM _tb),
            jsonb_build_object(
              'batch_id', :'b',
              'batch_version', (SELECT batch_version FROM import_batch WHERE import_batch_id = :'b'::uuid),
              'file_sha256', (SELECT COALESCE(file_sha256,'') FROM import_batch WHERE import_batch_id = :'b'::uuid),
              'lines', (SELECT COALESCE(jsonb_agg(jsonb_build_object('code',account_code,'name',account_name,
                'debit',debit::text,'credit',credit::text) ORDER BY account_code),'[]'::jsonb) FROM _tb));
          INSERT INTO _entries
            SELECT 'MAPPING_RULE', m.mapping_rule_id, NULL, 'MAPPING_VERSION_NO', m.version_no::text,
              'MAPPING|'||m.source_account_code||'|v'||m.version_no||'|'||
                COALESCE(m.effective_from::text,'-')||'|'||COALESCE(m.effective_to::text,'-')||'|'||
                m.target_code||'|'||m.target_name||'|'||m.target_account_id,
              jsonb_build_object('source_code',m.source_account_code,'version_no',m.version_no,
                'effective_from',m.effective_from,'effective_to',m.effective_to,
                'target_account_id',m.target_account_id,'target_code',m.target_code,
                'target_name',m.target_name,
                'created_by',m.created_by,'created_by_name',m.created_by_name,
                'approved_by',m.approved_by,'approved_by_name',m.approved_by_name,
                'approved_at',m.approved_at)
            FROM _map m;
          INSERT INTO _entries
            SELECT 'ADJUSTMENT', a.adjustment_id, NULL, 'BUSINESS_VERSION', a.business_version::text,
              'ADJUSTMENT|'||a.adjustment_id||'|bv'||a.business_version||'|'||a.canon_lines,
              jsonb_build_object('adjustment_id',a.adjustment_id,'business_version',a.business_version,
                'title',a.title,'lines',a.lines,
                'prepared_by',a.prepared_by,'prepared_by_name',a.prepared_by_name,'prepared_at',a.prepared_at,
                'reviewed_by',a.reviewed_by,'reviewed_by_name',a.reviewed_by_name,'reviewed_at',a.reviewed_at,
                'approved_by',a.approved_by,'approved_by_name',a.approved_by_name,'approved_at',a.approved_at)
            FROM _adj a;
          INSERT INTO _entries
            SELECT 'CHART_OF_ACCOUNTS', c.coa_id, NULL, 'COA_VERSION', c.version_no::text,
              'COA|'||c.coa_id||'|v'||c.version_no,
              jsonb_build_object('coa_id',c.coa_id,'version_no',c.version_no,'name',c.name)
            FROM chart_of_accounts c WHERE c.engagement_id = :'e'::uuid;

          -- 基礎組成（SLICE-M2-06）：凍結本案件全部已批准的組成版本。
          -- 「哪些層構成哪個基礎」是計算輸入的一部分——不凍結的話，組成 v2 落地後
          -- 重演同一個 run 會得到不同的基礎餘額，而且不會有任何錯誤訊息（INV-21／INV-29）。
          INSERT INTO _entries
            SELECT 'BASIS_COMPOSITION', c.basis_composition_version_id, NULL,
              'COMPOSITION_VERSION_NO', c.version_no::text,
              'BASIS_COMPOSITION|'||b.code||'|'||c.basis_composition_version_id||'|v'||c.version_no||'|'||
                COALESCE((SELECT string_agg(pl.code||':'||i.sign, ';' ORDER BY pl.code)
                            FROM constitutive_layer_item i
                            JOIN posting_layer pl ON pl.layer_id = i.layer_id
                           WHERE i.basis_composition_version_id = c.basis_composition_version_id),''),
              jsonb_build_object('basis_id', c.basis_id, 'basis_code', b.code,
                'source_mode', b.source_mode, 'version_no', c.version_no,
                'items', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                             'layer_code', pl.code, 'layer_id', i.layer_id, 'sign', i.sign)
                           ORDER BY pl.code),'[]'::jsonb)
                            FROM constitutive_layer_item i
                            JOIN posting_layer pl ON pl.layer_id = i.layer_id
                           WHERE i.basis_composition_version_id = c.basis_composition_version_id))
            FROM basis_composition_version c JOIN book_basis b ON b.basis_id = c.basis_id
           WHERE c.engagement_id = :'e'::uuid AND c.status = 'APPROVED';
          -- 沒有已批准的組成就沒有分層語意可凍結。若放行，這個 run 會與 0023 之前的
          -- 歷史 run 長得一模一樣（無組成 entry、快照無分層），等於靜默降級。
          SELECT fn_assert((SELECT count(*) FROM _entries WHERE object_type = 'BASIS_COMPOSITION') > 0,
            'BASIS_COMPOSITION_NOT_APPROVED:本案件沒有已批准的基礎組成版本');

          -- frozen hash 只涵蓋計算輸入（entries）；run_id／建立者／時間不入 hash。
          -- v2：entry hash 涵蓋 canonical＋payload（計算實際讀 payload，兩者都要蓋到）
          INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id,
            period_revision_id, calculation_scope, hash_algorithm, canonicalization_version,
            frozen_set_content_hash, created_by)
          SELECT :'mani'::uuid, :'t'::uuid, :'e'::uuid, :'pr'::uuid, 'NO_FX', 'sha256', :'cv',
            encode(sha256(convert_to((SELECT string_agg(
              encode(sha256(convert_to(content_canonical || E'\n' || payload::text,'UTF8')),'hex'),
              E'\n' ORDER BY content_canonical) FROM _entries),'UTF8')),'hex'),
            :'u'::uuid;
          INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
            concurrency_version, domain_version_kind, domain_version_value,
            content_canonical, content_hash, payload)
          SELECT :'t'::uuid, :'mani'::uuid, object_type, object_id, concurrency_version,
            domain_version_kind, domain_version_value, content_canonical,
            encode(sha256(convert_to(content_canonical || E'\n' || payload::text,'UTF8')),'hex'),
            payload
          FROM _entries;

          INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id,
            period_revision_id, import_batch_id, manifest_id, run_type, status,
            request_key, request_content_hash, engine_version, created_by)
          VALUES (:'run'::uuid, :'t'::uuid, :'e'::uuid, :'pr'::uuid, :'b'::uuid, :'mani'::uuid,
            'PREVIEW', 'RUNNING', :'rk'::uuid, :'rch', :'ev', :'u'::uuid);
          INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version,
            rule_version, idempotency_key, max_attempts)
          VALUES (:'t'::uuid, 'CALCULATION_RUN', :'run'::uuid, 1, :'ev', :'ik', ${config.jobMaxAttempts});
          INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
          VALUES (:'t'::uuid, 'DOMAIN_EVENT', 'calculation_run.created', :'u'::uuid,
            'calculation_run', :'run'::uuid,
            jsonb_build_object('manifest_id', :'mani', 'batch', :'b', 'scope', 'NO_FX'));
          COMMIT;`,
          { b: g.b.import_batch_id, e: g.b.engagement_id, pr: g.b.declared_period_revision_id,
            pe: g.b.period_end, t: s.tenantId, u: s.userId, run: runId, mani: maniId,
            rk: requestKey, rch, ik, ev: ENGINE_VERSION, cv: CANONICALIZATION_VERSION },
          { tenantId: s.tenantId });
      } catch (e) {
        const msg = String(e);
        const code = reasonCodeOf(msg);
        if (code === "G02_UNMAPPED" || code === "BATCH_NOT_ACCEPTED"
            || code === "BASIS_COMPOSITION_NOT_APPROVED")
          return b06Refuse(g.b, "calculation.create.rejected", code,
            msg.split(`${code}:`)[1]?.split("\n")[0] ?? "");
        if (msg.includes("calculation_run_tenant_request_key_uq")) {   // 併發同 key：回查
          const again = query<{ calculation_run_id: string; request_content_hash: string }>(
            `SELECT calculation_run_id, request_content_hash FROM calculation_run
              WHERE request_key = :'rk'::uuid`, { rk: requestKey }, { tenantId: s.tenantId });
          if (again[0]?.request_content_hash === rch)
            return send(302, "", { location: `/b06/run?id=${again[0].calculation_run_id}` });
          return b06Refuse(g.b, "calculation.create.rejected", "REQUEST_KEY_REUSED");
        }
        throw e;
      }
      return send(302, "", { location: `/b06/run?id=${runId}` });
    }

    // ── 重演：新 run 引用同一份 Manifest（原 run 永不修改） ──
    if (url.pathname === "/b06/replay" && req.method === "POST") {
      const f = Object.fromEntries(new URLSearchParams((await readBody(req)).toString("utf8")));
      const orig = query<{ calculation_run_id: string; import_batch_id: string; status: string;
                           engagement_id: string }>(
        `SELECT calculation_run_id, import_batch_id, status, engagement_id
           FROM calculation_run WHERE calculation_run_id = :'r'::uuid`,
        { r: f["run"] ?? "" }, { tenantId: s.tenantId })[0];
      if (!orig) return send(404, page("404", "", "<h2>Run 不存在</h2>"));
      const g = b04Guard(orig.import_batch_id, "calculation.replay");
      if (!g.ok) return;
      if (!g.roles.has("R2") && !g.roles.has("R3"))
        return b06Refuse(g.b, "calculation.replay.denied", "ROLE_REQUIRED");
      if (orig.status !== "COMPLETED")
        return b06Refuse(g.b, "calculation.replay.rejected", "REPLAY_TARGET_NOT_COMPLETED",
          `原 run 狀態為 ${orig.status}`);
      const runId = randomUUID();
      const ik = idempotencyKey("CALCULATION_RUN", runId, 1, ENGINE_VERSION);
      exec(`BEGIN;
        INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id,
          period_revision_id, import_batch_id, manifest_id, run_type, status, replay_of_run_id,
          request_key, request_content_hash, engine_version, created_by)
        SELECT :'run'::uuid, tenant_id, engagement_id, period_revision_id, import_batch_id,
          manifest_id, 'PREVIEW', 'RUNNING', :'orig'::uuid,
          :'rk'::uuid, 'REPLAY|' || :'orig', engine_version, :'u'::uuid
        FROM calculation_run WHERE calculation_run_id = :'orig'::uuid;
        INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version,
          rule_version, idempotency_key, max_attempts)
        VALUES (:'t'::uuid, 'CALCULATION_RUN', :'run'::uuid, 1, :'ev', :'ik', ${config.jobMaxAttempts});
        INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
        VALUES (:'t'::uuid, 'DOMAIN_EVENT', 'calculation_run.replay_created', :'u'::uuid,
          'calculation_run', :'run'::uuid, jsonb_build_object('replay_of', :'orig'));
        COMMIT;`,
        { run: runId, orig: orig.calculation_run_id, rk: randomUUID(), u: s.userId,
          t: s.tenantId, ev: ENGINE_VERSION, ik }, { tenantId: s.tenantId });
      return send(302, "", { location: `/b06/run?id=${runId}` });
    }

    // ── B-06 執行清單 ──
    if (url.pathname === "/b06" && req.method === "GET") {
      const g = b04Guard(url.searchParams.get("batch") ?? "", "b06.view");
      if (!g.ok) return;
      const runs = query<Record<string, string>>(
        `SELECT r.calculation_run_id, r.status, r.replay_of_run_id, r.result_content_hash,
                r.failure_reason_code, r.created_at,
                j.status AS job_status, j.attempt_count
           FROM calculation_run r
           LEFT JOIN background_job j ON j.subject_id = r.calculation_run_id
                AND j.job_type = 'CALCULATION_RUN'
          WHERE r.import_batch_id = :'b'::uuid ORDER BY r.created_at DESC LIMIT 50`,
        { b: g.b.import_batch_id }, { tenantId: s.tenantId });
      return send(200, page("B-06 計算執行", b04CtxBar(g.b, "B-06 計算執行、折算與調節"),
        `<h2>PREVIEW CalculationRun</h2>
         <p class="note">本刀輸出為「科目映射＋已批准調整、<b>未折算（NO_FX）</b>」預覽；折算屬 MVP 3。</p>
         <form class="up" method="post" action="/b06/run">
           <input type="hidden" name="batch" value="${g.b.import_batch_id}">
           <input type="hidden" name="request_key" value="${randomUUID()}">
           <button>建立 PREVIEW 計算執行（R2／R3）</button>
           <span class="note">同一請求重送不會產生第二個 run；再次點按此頁重新產生的 key 才建立新 run</span>
         </form>
         <table><tr><th>Run</th><th>種類</th><th>Run 狀態</th><th>執行進度（Job）</th><th>結果 hash</th><th>建立</th><th></th></tr>
         ${runs.map((r) => `<tr><td>${r.calculation_run_id.slice(0, 8)}</td>
           <td>${r.replay_of_run_id ? `重演 ← ${r.replay_of_run_id.slice(0, 8)}` : "原始"}</td>
           <td><span class="badge st-${r.status === "COMPLETED" ? "ACCEPTED" : r.status === "FAILED" ? "QUARANTINED" : "UPLOADED"}">${r.status}</span>${r.failure_reason_code ? ` <span class="note">${esc(r.failure_reason_code)}</span>` : ""}</td>
           <td>${esc(r.job_status ?? "")}（${esc(r.attempt_count ?? "0")}）</td>
           <td class="note">${(r.result_content_hash ?? "").slice(0, 12)}</td>
           <td class="note">${esc(String(r.created_at).slice(0, 19))}</td>
           <td><a href="/b06/run?id=${r.calculation_run_id}">開啟</a></td></tr>`).join("")}
         </table>
         <p><a href="/b04?batch=${g.b.import_batch_id}">← 回 B-04</a>　<a href="/">回 B-00</a></p>`));
    }

    // ── Run 詳情：PREVIEW 快照、控制總額、Manifest 摘要、重演 ──
    if (url.pathname === "/b06/run" && req.method === "GET") {
      const run = query<Record<string, string>>(
        `SELECT r.*, j.status AS job_status, j.attempt_count, j.last_error_class,
                m.frozen_set_content_hash, m.canonicalization_version, m.calculation_scope
           FROM calculation_run r
           JOIN calculation_input_manifest m ON m.manifest_id = r.manifest_id
           LEFT JOIN background_job j ON j.subject_id = r.calculation_run_id
                AND j.job_type = 'CALCULATION_RUN'
          WHERE r.calculation_run_id = :'r'::uuid`,
        { r: url.searchParams.get("id") ?? "" }, { tenantId: s.tenantId })[0];
      if (!run) return send(404, page("404", "", "<h2>Run 不存在</h2>"));
      const g = b04Guard(run.import_batch_id, "b06.run.view");
      if (!g.ok) return;
      const entries = query<{ object_type: string; n: string }>(
        `SELECT object_type, count(*) AS n FROM calculation_manifest_entry
          WHERE manifest_id = :'m'::uuid GROUP BY object_type ORDER BY object_type`,
        { m: run.manifest_id }, { tenantId: s.tenantId });
      const lines = query<Record<string, string>>(
        `SELECT posting_layer, account_code, account_name, debit, credit
           FROM balance_snapshot_line WHERE calculation_run_id = :'r'::uuid
          ORDER BY account_code, posting_layer`,
        { r: run.calculation_run_id }, { tenantId: s.tenantId });
      const fmt = (v: string) => v && v !== "0.00" ? fmtCents(cents(v)) : "";
      const tot = (col: "debit" | "credit") =>
        lines.reduce((a, l) => a + cents(l[col]), 0n);
      return send(200, page("B-06 PREVIEW 執行結果", b04CtxBar(g.b, "B-06 計算執行結果"),
        `<div style="background:#fff3e0;border:1px solid #d9a05b;border-radius:6px;padding:10px 14px;font-weight:600">
           PREVIEW（預覽）——非正式輸出、<u>未折算（calculation_scope=NO_FX）</u>，
           不建立交付紀錄，不得作為入帳或交付依據
         </div>
         <p>Run <b>${run.calculation_run_id.slice(0, 8)}</b>
            ${run.replay_of_run_id ? `（重演 ← ${run.replay_of_run_id.slice(0, 8)}）` : "（原始）"}｜
            狀態 <span class="badge st-${run.status === "COMPLETED" ? "ACCEPTED" : run.status === "FAILED" ? "QUARANTINED" : "UPLOADED"}">${run.status}</span>｜
            Job ${esc(run.job_status ?? "—")}（第 ${esc(run.attempt_count ?? "0")} 次）</p>
         ${run.status === "FAILED" ? `<p>⛔ <b>${esc(run.failure_reason_code)}</b>：${esc(run.failure_reason)}</p>` : ""}
         ${run.status === "COMPLETED" ? `
         <h2>調整後集團 TB（未折算）</h2>
         <table><tr><th>層</th><th>集團科目</th><th>名稱</th><th>借方</th><th>貸方</th></tr>
         ${lines.map((l) => `<tr><td class="note">${l.posting_layer === "SOURCE_TB" ? "來源 TB" : "調整"}</td>
           <td>${esc(l.account_code)}</td><td>${esc(l.account_name)}</td>
           <td style="text-align:right">${fmt(l.debit)}</td><td style="text-align:right">${fmt(l.credit)}</td></tr>`).join("")}
         <tr><th colspan="3">控制總額（G-09 已於結果交易內勾稽）</th>
           <th style="text-align:right">${fmtCents(tot("debit"))}</th>
           <th style="text-align:right">${fmtCents(tot("credit"))}</th></tr>
         </table>
         <p class="note">result_content_hash＝<code>${esc(run.result_content_hash)}</code>（canonical 結果，排除 run_id 與時間戳）</p>
         <form method="post" action="/b06/replay" style="margin:8px 0">
           <input type="hidden" name="run" value="${run.calculation_run_id}">
           <button>依 Manifest 重演（建立 replay run）</button>
         </form>
         <p><a href="/b07?run=${run.calculation_run_id}">→ B-07 產生預覽證據包</a></p>` : ""}
         <h2>Manifest（凍結輸入）</h2>
         <p class="note">frozen_set_content_hash＝<code>${esc(run.frozen_set_content_hash)}</code>｜
            canonicalization＝${esc(run.canonicalization_version)}｜scope＝${esc(run.calculation_scope)}</p>
         <table><tr><th>輸入類型</th><th>筆數</th></tr>
         ${entries.map((e2) => `<tr><td>${esc(e2.object_type)}</td><td>${esc(e2.n)}</td></tr>`).join("")}
         </table>
         <p><a href="/b06?batch=${run.import_batch_id}">← 回 B-06 清單</a></p>`));
    }

    // ═══════════ SLICE-M2-02C：B-07 預覽證據包 ═══════════
    const b07Refuse = (b: BatchCtx | null, action: string, code: PkgReasonCode, detail = ""): void => {
      audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", action, s.userId,
        "evidence_package", b?.import_batch_id ?? s.userId,
        { code, reason: PKG_REASON[code], detail });
      send(code === "ROLE_REQUIRED" ? 403 : 409,
        page("拒絕", b ? b04CtxBar(b, "B-07") : "<b>⛔</b>",
          `<h2>⛔ ${esc(code)}</h2><p>${esc(PKG_REASON[code])}</p>` +
          (detail ? `<p class="note">${esc(detail)}</p>` : "") +
          `<p>此次嘗試已寫入稽核軌跡。</p><p><a href="/">回 B-00</a></p>`));
    };
    const loadRunForPkg = (runId: string) => query<Record<string, string>>(
      `SELECT calculation_run_id, import_batch_id, engagement_id, status, run_type
         FROM calculation_run WHERE calculation_run_id = :'r'::uuid`,
      { r: runId }, { tenantId: s.tenantId })[0];

    // ── 產包（precheck 同步 → Package(GENERATING)＋Job＋事件同交易；產生非同步） ──
    if (url.pathname === "/b07/package" && req.method === "POST") {
      const f = Object.fromEntries(new URLSearchParams((await readBody(req)).toString("utf8")));
      const run = loadRunForPkg(f["run"] ?? "");
      if (!run) return send(404, page("404", "", "<h2>Run 不存在</h2>"));
      const g = b04Guard(run.import_batch_id, "evidence.create");
      if (!g.ok) return;
      if (!g.roles.has("R2") && !g.roles.has("R3") && !g.roles.has("R4"))
        return b07Refuse(g.b, "evidence.create.denied", "ROLE_REQUIRED");
      if (run.status !== "COMPLETED")
        return b07Refuse(g.b, "evidence.create.rejected", "RUN_NOT_COMPLETED",
          `run 目前為 ${run.status}`);
      // G-09 復驗（precheck；worker 終態交易另有契約 D 全套）
      const tot = query<{ ok: boolean }>(
        `SELECT COALESCE(SUM(debit),0) = COALESCE(SUM(credit),0) AS ok
           FROM balance_snapshot_line WHERE calculation_run_id = :'r'::uuid`,
        { r: run.calculation_run_id }, { tenantId: s.tenantId })[0];
      if (!tot?.ok)
        return b07Refuse(g.b, "evidence.create.rejected", "CONTROL_TOTAL_MISMATCH");
      const cutoff = query<{ id: string }>(
        `SELECT audit_event_id::text AS id FROM audit_event
          WHERE event_type='calculation_run.completed' AND object_id = :'r'::uuid
          ORDER BY audit_event_id LIMIT 1`,
        { r: run.calculation_run_id }, { tenantId: s.tenantId })[0];
      if (!cutoff)
        return b07Refuse(g.b, "evidence.create.rejected", "CUTOFF_EVENT_MISSING");
      const requestKey = f["request_key"] ?? "";
      if (!/^[0-9a-f-]{36}$/.test(requestKey))
        return send(400, page("錯誤", b04CtxBar(g.b, "B-07"), "<h2>request_key 缺漏或格式錯誤</h2>"));
      const rch = createHash("sha256")
        .update(`B07PKG|${run.calculation_run_id}|${RENDER_VERSION}`).digest("hex");
      const existing = query<{ package_id: string; request_content_hash: string }>(
        `SELECT package_id, request_content_hash FROM evidence_package
          WHERE request_key = :'rk'::uuid`, { rk: requestKey }, { tenantId: s.tenantId });
      if (existing[0]) {
        if (existing[0].request_content_hash === rch)
          return send(302, "", { location: `/b07/package?id=${existing[0].package_id}` });
        return b07Refuse(g.b, "evidence.create.rejected", "REQUEST_KEY_REUSED");
      }
      const pkgId = randomUUID();
      const ik = idempotencyKey("EVIDENCE_PACKAGE", pkgId, 1, RENDER_VERSION);
      try {
        exec(`BEGIN;
          INSERT INTO evidence_package (package_id, tenant_id, engagement_id, calculation_run_id,
            request_key, request_content_hash, audit_cutoff_event_id, render_version, created_by)
          VALUES (:'p'::uuid, :'t'::uuid, :'e'::uuid, :'r'::uuid,
            :'rk'::uuid, :'rch', :'cut'::bigint, :'rv', :'u'::uuid);
          INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version,
            rule_version, idempotency_key, max_attempts)
          VALUES (:'t'::uuid, 'EVIDENCE_PACKAGE', :'p'::uuid, 1, :'rv', :'ik', ${config.jobMaxAttempts});
          INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
          VALUES (:'t'::uuid, 'DOMAIN_EVENT', 'evidence_package.created', :'u'::uuid,
            'evidence_package', :'p'::uuid,
            jsonb_build_object('run', :'r', 'cutoff', (:'cut')::bigint, 'render', :'rv'));
          COMMIT;`,
          { p: pkgId, t: s.tenantId, e: run.engagement_id, r: run.calculation_run_id,
            rk: requestKey, rch, rv: RENDER_VERSION, u: s.userId, ik, cut: cutoff.id },
          { tenantId: s.tenantId });
      } catch (e) {
        const msg = String(e);
        if (msg.includes("evidence_package_tenant_id_request_key_key")) {
          const again = query<{ package_id: string; request_content_hash: string }>(
            `SELECT package_id, request_content_hash FROM evidence_package
              WHERE request_key = :'rk'::uuid`, { rk: requestKey }, { tenantId: s.tenantId });
          if (again[0]?.request_content_hash === rch)
            return send(302, "", { location: `/b07/package?id=${again[0].package_id}` });
          return b07Refuse(g.b, "evidence.create.rejected", "REQUEST_KEY_REUSED");
        }
        throw e;
      }
      return send(302, "", { location: `/b07/package?id=${pkgId}` });
    }

    // ── B-07 清單 ──
    if (url.pathname === "/b07" && req.method === "GET") {
      const run = loadRunForPkg(url.searchParams.get("run") ?? "");
      if (!run) return send(404, page("404", "", "<h2>Run 不存在</h2>"));
      const g = b04Guard(run.import_batch_id, "b07.view");
      if (!g.ok) return;
      const pkgs = query<Record<string, string>>(
        `SELECT p.package_id, p.status, p.failure_reason_code, p.created_at,
                p.package_content_hash, j.status AS job_status, j.attempt_count
           FROM evidence_package p
           LEFT JOIN background_job j ON j.subject_id = p.package_id AND j.job_type='EVIDENCE_PACKAGE'
          WHERE p.calculation_run_id = :'r'::uuid ORDER BY p.created_at DESC LIMIT 20`,
        { r: run.calculation_run_id }, { tenantId: s.tenantId });
      return send(200, page("B-07 證據包", b04CtxBar(g.b, "B-07 交付、預覽與證據包"),
        `<h2>預覽證據包（run ${run.calculation_run_id.slice(0, 8)}）</h2>
         <p class="note">預覽級底稿：DRAFT・UNREVIEWED・未折算——不建立交付紀錄。</p>
         <form class="up" method="post" action="/b07/package">
           <input type="hidden" name="run" value="${run.calculation_run_id}">
           <input type="hidden" name="request_key" value="${randomUUID()}">
           <button>產生預覽證據包（R2／R3／R4）</button>
         </form>
         <table><tr><th>Package</th><th>狀態</th><th>Job</th><th>package hash</th><th>建立</th><th></th></tr>
         ${pkgs.map((p) => `<tr><td>${p.package_id.slice(0, 8)}</td>
           <td><span class="badge st-${p.status === "READY" ? "ACCEPTED" : p.status === "FAILED" ? "QUARANTINED" : "UPLOADED"}">${p.status}</span>${p.failure_reason_code ? ` <span class="note">${esc(p.failure_reason_code)}</span>` : ""}</td>
           <td>${esc(p.job_status ?? "")}（${esc(p.attempt_count ?? "0")}）</td>
           <td class="note">${(p.package_content_hash ?? "").slice(0, 12)}</td>
           <td class="note">${esc(String(p.created_at).slice(0, 19))}</td>
           <td><a href="/b07/package?id=${p.package_id}">開啟</a></td></tr>`).join("")}
         </table>
         <p><a href="/b06/run?id=${run.calculation_run_id}">← 回 B-06 執行結果</a></p>`));
    }

    // ── Package 狀態頁 ──
    if (url.pathname === "/b07/package" && req.method === "GET") {
      const p = query<Record<string, string>>(
        `SELECT p.*, r.import_batch_id, j.status AS job_status, j.attempt_count
           FROM evidence_package p
           JOIN calculation_run r ON r.calculation_run_id = p.calculation_run_id
           LEFT JOIN background_job j ON j.subject_id = p.package_id AND j.job_type='EVIDENCE_PACKAGE'
          WHERE p.package_id = :'p'::uuid`,
        { p: url.searchParams.get("id") ?? "" }, { tenantId: s.tenantId })[0];
      if (!p) return send(404, page("404", "", "<h2>Package 不存在</h2>"));
      const g = b04Guard(p.import_batch_id, "b07.package.view");
      if (!g.ok) return;
      const idx = query<Record<string, string>>(
        `SELECT section, item_count, content_hash FROM evidence_package_index
          WHERE package_id = :'p'::uuid ORDER BY section`,
        { p: p.package_id }, { tenantId: s.tenantId });
      return send(200, page("B-07 證據包狀態", b04CtxBar(g.b, "B-07 證據包"),
        `<div style="background:#fff3e0;border:1px solid #d9a05b;border-radius:6px;padding:10px 14px;font-weight:600">
           PREVIEW 證據包——DRAFT・UNREVIEWED・未折算（NO_FX），不得作為入帳或交付依據
         </div>
         <p>Package <b>${p.package_id.slice(0, 8)}</b>｜狀態
            <span class="badge st-${p.status === "READY" ? "ACCEPTED" : p.status === "FAILED" ? "QUARANTINED" : "UPLOADED"}">${p.status}</span>｜
            Job ${esc(p.job_status ?? "—")}（第 ${esc(p.attempt_count ?? "0")} 次）</p>
         ${p.status === "FAILED" ? `<p>⛔ <b>${esc(p.failure_reason_code)}</b>：${esc(p.failure_reason)}</p>` : ""}
         ${p.status === "READY" ? `
         <p>package_content_hash＝<code>${esc(p.package_content_hash)}</code><br>
            artifact＝<code>${esc(p.artifact_object_key)}</code>（${esc(p.artifact_byte_size)} bytes，
            SHA-256 <code>${esc(p.artifact_sha256)}</code>，render ${esc(p.render_version)}）</p>
         <p><a href="/b07/download?id=${p.package_id}"><b>下載底稿（PREVIEW_DRAFT）</b></a>
            <span class="note">下載＝讀已保存位元組並驗 hash，不重新渲染</span></p>
         <h2>內容索引</h2>
         <table><tr><th>節</th><th>筆數</th><th>content hash</th></tr>
         ${idx.map((i) => `<tr><td>${esc(i.section)}</td><td>${esc(i.item_count)}</td><td class="note">${esc(i.content_hash)}</td></tr>`).join("")}
         </table>` : ""}
         <p><a href="/b07?run=${p.calculation_run_id}">← 回 B-07 清單</a></p>`));
    }

    // ── 下載：只讀已保存位元組並驗 hash（READY 限定） ──
    if (url.pathname === "/b07/download" && req.method === "GET") {
      const p = query<Record<string, string>>(
        `SELECT p.*, r.import_batch_id FROM evidence_package p
           JOIN calculation_run r ON r.calculation_run_id = p.calculation_run_id
          WHERE p.package_id = :'p'::uuid`,
        { p: url.searchParams.get("id") ?? "" }, { tenantId: s.tenantId })[0];
      if (!p) return send(404, page("404", "", "<h2>Package 不存在</h2>"));
      const g = b04Guard(p.import_batch_id, "b07.download");
      if (!g.ok) return;
      if (!g.roles.has("R2") && !g.roles.has("R3") && !g.roles.has("R4"))
        return b07Refuse(g.b, "evidence.download.denied", "ROLE_REQUIRED");
      if (p.status !== "READY")
        return b07Refuse(g.b, "evidence.download.rejected", "PACKAGE_NOT_READY",
          `目前為 ${p.status}`);
      const bytes = getObject(p.artifact_object_key);
      const sha = createHash("sha256").update(bytes).digest("hex");
      if (sha !== p.artifact_sha256) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", "evidence.download.integrity", s.userId,
          "evidence_package", p.package_id,
          { code: "ARTIFACT_HASH_MISMATCH", expected: p.artifact_sha256, actual: sha });
        return send(500, page("完整性失敗", b04CtxBar(g.b, "B-07"),
          `<h2>⛔ ARTIFACT_HASH_MISMATCH</h2><p>${esc(PKG_REASON.ARTIFACT_HASH_MISMATCH)}</p>`));
      }
      res.writeHead(200, {
        "content-type": p.artifact_mime_type,
        "content-length": String(bytes.length),
        "content-disposition":
          `attachment; filename="PREVIEW_DRAFT_evidence_${p.calculation_run_id.slice(0, 8)}_${p.package_id.slice(0, 8)}.html"`,
      });
      return res.end(bytes);
    }

    send(404, page("404", "", "<h2>找不到頁面</h2>"));
  } catch (e) {
    send(500, page("錯誤", "", `<h2>伺服器錯誤</h2><pre>${esc(String(e))}</pre>`));
  }
});

server.listen(PORT, "127.0.0.1", () =>
  console.log(`api listening on http://127.0.0.1:${PORT}`));
