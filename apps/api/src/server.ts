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
import { allAssignedRolesOf } from "./modules/engagements/access.ts";
import { loadBatch, type BatchCtx } from "./modules/imports/access.ts";
import { b04CtxBar } from "./modules/imports/views.ts";

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

    const b04Guard = (batchId: string, action: string):
        { ok: true; b: BatchCtx; roles: Set<string> } | { ok: false; res: void } => {
      const b = loadBatch(s, batchId);
      if (!b) return { ok: false, res: send(404, page("404", "", "<h2>批次不存在</h2>")) };
      const roles = allAssignedRolesOf(s, b.engagement_id);
      if (roles.size === 0) {
        audit(s.tenantId, "CONTROL_VIOLATION_ATTEMPT", `${action}.denied`, s.userId,
          "import_batch", batchId, { reason: "未被指派此案件", action });
        return { ok: false, res: send(403, page("拒絕", "<b>⛔ 未被指派</b>",
          `<h2>⛔ 未被指派此案件</h2><p>此次嘗試已寫入稽核軌跡。</p><p><a href="/">回 B-00</a></p>`)) };
      }
      return { ok: true, b, roles };
    };

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
