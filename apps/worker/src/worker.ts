// 匯入驗證工作器（§27.4 非同步邊界；§25.5 第一條流程）。
//   認領 UPLOADED → VALIDATING → 解析 TB ＋ 三項檢查 → VALIDATED / QUARANTINED
//   檢查：①雜湊完整性 ②借貸平衡（G-01） ③檔案歸屬比對 → identity_status（CR-002）
// 佇列：Postgres FOR UPDATE SKIP LOCKED（沙箱替代，見 ADR-LOCAL-001）。
// 註：worker 以受信後端身分跨租戶處理（dev 角色）；真機應改專用角色並逐租戶 set_config。
import { createHash } from "node:crypto";
import { query, exec } from "../../../packages/database/src/psql.ts";
import { getObject } from "../../../packages/database/src/objectstore.ts";
import { classifyIdentity, identityStatusOf, type EvidenceKind }
  from "../../../packages/domain/src/importBatch.ts";
import { cents, fmtCents } from "../../../packages/domain/src/mapping.ts";
import { config } from "../../../packages/config/src/index.ts";

const INTERVAL = config.pollMs;
const RULE_VERSION = "detect-r1";   // 識別規則版本：寫入每筆評估（CR-002 B-3）

interface Claimed {
  import_batch_id: string; tenant_id: string; file_sha256: string;
  declared_legal_entity_id: string; object_key: string; declared_code: string | null;
}

function audit(tenantId: string, eventType: string, objectId: string, payload: object): void {
  exec(`INSERT INTO audit_event (tenant_id, kind, event_type, object_type, object_id, payload)
        VALUES (:'t'::uuid, 'DOMAIN_EVENT', :'e', 'import_batch', :'oi'::uuid, :'pl'::jsonb)`,
    { t: tenantId, e: eventType, oi: objectId, pl: JSON.stringify(payload) }, { asRuntime: false });
}

/** TB 解析：#key=value 中繼資料列 ＋ CSV（account_code,account_name,debit,credit） */
function parseTb(text: string): { meta: Record<string, string>;
    lines: { code: string; name: string; debit: string; credit: string }[]; errors: string[] } {
  const meta: Record<string, string> = {};
  const lines: { code: string; name: string; debit: string; credit: string }[] = [];
  const errors: string[] = [];
  let headerSeen = false;
  for (const [i, rawLine] of text.split("\n").entries()) {
    const line = rawLine.trim();
    if (!line) continue;
    if (line.startsWith("#")) {
      const eq = line.indexOf("=");
      if (eq > 1) meta[line.slice(1, eq).trim()] = line.slice(eq + 1).trim();
      continue;
    }
    if (!headerSeen) { headerSeen = true; continue; }   // 表頭列
    const cols = line.split(",");
    if (cols.length < 4) { errors.push(`第 ${i + 1} 列欄位不足`); continue; }
    const [code, name, debit, credit] = cols.map((c) => c.trim());
    if (!/^-?\d+(\.\d{1,2})?$/.test(debit) || !/^-?\d+(\.\d{1,2})?$/.test(credit)) {
      errors.push(`第 ${i + 1} 列金額格式錯誤`); continue;
    }
    lines.push({ code, name, debit, credit });
  }
  return { meta, lines, errors };
}

function claim(): Claimed | null {
  const rows = query<Claimed>(
    `UPDATE import_batch ib SET status = 'VALIDATING'
      WHERE ib.import_batch_id = (
        SELECT import_batch_id FROM import_batch
         WHERE status = 'UPLOADED'
         ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED)
      RETURNING ib.import_batch_id, ib.tenant_id, ib.file_sha256, ib.declared_legal_entity_id,
        (SELECT object_key FROM source_document sd WHERE sd.import_batch_id = ib.import_batch_id LIMIT 1) AS object_key,
        (SELECT authoritative_code FROM legal_entity le
          WHERE le.legal_entity_id = ib.declared_legal_entity_id) AS declared_code`,
    {}, { asRuntime: false });
  return rows[0] ?? null;
}

function quarantine(b: Claimed, reason: string): void {
  exec(`UPDATE import_batch SET status='QUARANTINED', quarantine_reason=:'r'
         WHERE import_batch_id=:'id'::uuid`,
    { r: reason, id: b.import_batch_id }, { asRuntime: false });
  audit(b.tenant_id, "import_batch.quarantined", b.import_batch_id, { reason });
}

function processBatch(b: Claimed): void {
  // ① 雜湊完整性：重算物件內容雜湊，須與上傳時宣告一致
  const data = getObject(b.object_key);
  const sha = createHash("sha256").update(data).digest("hex");
  if (sha !== b.file_sha256) return quarantine(b, `雜湊不符：物件內容與上傳宣告不一致`);
  exec(`UPDATE import_batch SET hash_verified=true WHERE import_batch_id=:'id'::uuid`,
    { id: b.import_batch_id }, { asRuntime: false });

  // ② 解析＋借貸平衡（G-01）
  const { meta, lines, errors } = parseTb(data.toString("utf8"));
  if (errors.length) return quarantine(b, `解析失敗：${errors.slice(0, 3).join("；")}`);
  if (lines.length === 0) return quarantine(b, "檔案沒有資料列");
  let debit = 0n, credit = 0n;   // 以「分」為單位的整數運算——金額絕不用浮點（cents 為純字串解析）
  for (const l of lines) { debit += cents(l.debit); credit += cents(l.credit); }
  const diff = debit - credit;

  // 寫入來源事實（不可變）
  const dsId = query<{ id: string }>(
    `INSERT INTO source_dataset (tenant_id, import_batch_id, granularity, content_sha256, row_count)
     VALUES (:'t'::uuid, :'b'::uuid, 'BALANCE', :'sha', ${lines.length})
     RETURNING source_dataset_id AS id`,
    { t: b.tenant_id, b: b.import_batch_id, sha }, { asRuntime: false })[0].id;
  for (const l of lines) {
    const lineSha = createHash("sha256").update(`${l.code}|${l.debit}|${l.credit}`).digest("hex");
    exec(`INSERT INTO source_ledger_line (tenant_id, source_dataset_id, import_batch_id,
            source_row_id, account_code, account_name, debit, credit, content_sha256)
          VALUES (:'t'::uuid, :'ds'::uuid, :'b'::uuid, :'rid', :'code', :'name', :'d'::numeric, :'c'::numeric, :'ls')`,
      { t: b.tenant_id, ds: dsId, b: b.import_batch_id, rid: l.code, code: l.code,
        name: l.name, d: l.debit, c: l.credit, ls: lineSha }, { asRuntime: false });
  }
  exec(`INSERT INTO data_coverage (tenant_id, import_batch_id, granularity, completeness_status)
        VALUES (:'t'::uuid, :'b'::uuid, 'BALANCE', 'UNKNOWN')`,
    { t: b.tenant_id, b: b.import_batch_id }, { asRuntime: false });

  // ③ 檔案歸屬比對（CR-002 主題四；證據分級：僅權威識別符可產生 CONFLICT）
  const detectedCode = meta["legal_entity_code"] ?? null;
  const evidence: EvidenceKind = detectedCode ? "AUTHORITATIVE_ID" : "NONE";
  const result = classifyIdentity(b.declared_code, detectedCode, evidence);
  const idStatus = identityStatusOf(result);
  exec(`INSERT INTO source_identity_assessment (tenant_id, import_batch_id, batch_version,
          detected_identity, match_result, evidence_kind, detection_rule_version)
        VALUES (:'t'::uuid, :'b'::uuid, 1, :'di'::jsonb, :'mr',
                :'ek', :'rv')`,
    { t: b.tenant_id, b: b.import_batch_id,
      di: JSON.stringify(detectedCode ? [{ kind: "legal_entity_code", value: detectedCode }] : []),
      mr: result === "MATCH" ? "MATCH" : result, ek: evidence, rv: RULE_VERSION },
    { asRuntime: false });
  exec(`UPDATE import_batch SET identity_status=:'s'::identity_status WHERE import_batch_id=:'id'::uuid`,
    { s: idStatus, id: b.import_batch_id }, { asRuntime: false });
  audit(b.tenant_id, "import_batch.identity_assessed", b.import_batch_id,
    { declared: b.declared_code, detected: detectedCode, evidence, result });

  // 判定去向：CONFLICT → 隔離（不可接受，INV-28）；借貸不平 → 隔離；其餘 → VALIDATED
  if (result === "CONFLICT")
    return quarantine(b, `身分不一致：宣告法人代碼 ${b.declared_code}，檔案內為 ${detectedCode}（CONFLICT，無人工豁免）`);
  if (diff !== 0n)
    return quarantine(b, `借貸不平衡：差額 ${fmtCents(diff)}（G-01）`);
  exec(`UPDATE import_batch SET status='VALIDATED' WHERE import_batch_id=:'id'::uuid`,
    { id: b.import_batch_id }, { asRuntime: false });
  audit(b.tenant_id, "import_batch.validated", b.import_batch_id,
    { rows: lines.length, identity: idStatus });
}

function tick(): void {
  try {
    for (let i = 0; i < 10; i++) {
      const b = claim();
      if (!b) break;
      console.log(`[worker] 驗證批次 ${b.import_batch_id.slice(0, 8)}…`);
      try { processBatch(b); }
      catch (e) { quarantine(b, `處理失敗：${String(e).slice(0, 200)}`); }
    }
  } catch (e) { console.error("[worker]", String(e)); }
}

console.log(`worker polling every ${INTERVAL}ms`);
setInterval(tick, INTERVAL);
tick();
