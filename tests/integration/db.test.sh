#!/usr/bin/env bash
# DB 層整合測試：從零重建 → 逐條驗證守衛。
# 每條測試對應設計書的一個識別碼；「應失敗」的測試以 psql 回傳非零為 PASS。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/env.sh"
DB=cbfc_test
PSQL_C() { psql_run -d "$DB" "$@"; }
APP_C() {
  if [ "$PSQL_MODE" = "docker" ]; then
    docker exec -i "$DB_CONTAINER" psql -v ON_ERROR_STOP=1 -qtA -U app_runtime -d "$DB" "$@"
  else
    psql -v ON_ERROR_STOP=1 -qtA -h "$DB_HOST" -p "$DB_PORT" -U app_runtime -d "$DB" "$@"
  fi
}

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
ng()  { fail=$((fail+1)); echo "  FAIL  $1"; }
# expect_ok "名稱" "SQL"（成功才 PASS）
expect_ok() { if out=$(PSQL_C <<<"$2" 2>&1); then ok "$1"; else ng "$1 → $out"; fi }
# expect_err "名稱" "SQL" "訊息關鍵字"（失敗且訊息含關鍵字才 PASS）
expect_err() {
  if out=$(PSQL_C <<<"$2" 2>&1); then ng "$1（不該成功卻成功了）"
  elif echo "$out" | grep -q "$3"; then ok "$1"
  else ng "$1 → 失敗原因不符：$out"; fi
}

echo "══ DB 整合測試（${DB}）══"
bash "$ROOT/packages/database/src/db-reset.sh" $DB >/dev/null 2>&1 || { echo "重建失敗"; exit 1; }
ok "migration 可從零重建資料庫"

# ── 種子 ─────────────────────────────────────────────
PSQL_C <<'SQL' >/dev/null
INSERT INTO tenant (tenant_id, name) VALUES
  ('11111111-1111-1111-1111-111111111111','T1 事務所'),
  ('22222222-2222-2222-2222-222222222222','T2 事務所');
SET app.tenant_id = '11111111-1111-1111-1111-111111111111';
INSERT INTO app_user (user_id, tenant_id, email, display_name) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','staff@t1.jp','職員甲'),
  ('aaaaaaaa-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','senior@t1.jp','資深乙');
INSERT INTO client_engagement (engagement_id, tenant_id, name) VALUES
  ('eeeeeeee-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','A 客戶案件');
INSERT INTO legal_entity (legal_entity_id, tenant_id, engagement_id, name, authoritative_code, country_code) VALUES
  ('cccccccc-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','A 株式会社','1234567890123','JP');
INSERT INTO reporting_unit (reporting_unit_id, tenant_id, engagement_id, legal_entity_id, unit_scope, name) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001','LEGAL_ENTITY','A 社');
INSERT INTO fiscal_calendar (fiscal_calendar_id, tenant_id, engagement_id, name, year_start_month) VALUES
  ('ffffffff-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','日本4月起',4);
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id, fiscal_calendar_id, label, start_date, end_date) VALUES
  ('dddddddd-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-000000000001','2026-03','2026-03-01','2026-03-31');
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id) VALUES
  ('99999999-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','dddddddd-0000-0000-0000-000000000001');
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id, declared_period_revision_id, uploaded_by, provided_by) VALUES
  ('00000000-0000-0000-0000-0000000000b1','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001');
SQL
ok "種子資料建立（2 租戶、1 案件、1 批次）"

B1=00000000-0000-0000-0000-0000000000b1
T1="SET app.tenant_id = '11111111-1111-1111-1111-111111111111';"
T2="SET app.tenant_id = '22222222-2222-2222-2222-222222222222';"

# ── RLS（§24.9／INV-18） ────────────────────────────
n=$(APP_C <<<"$T1 SELECT count(*) FROM import_batch")
[ "$n" = "1" ] && ok "RLS：T1 看得到自己的批次" || ng "RLS：T1 應看到 1 筆，得到 $n"
n=$(APP_C <<<"$T2 SELECT count(*) FROM import_batch")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的批次" || ng "RLS：T2 應看到 0 筆，得到 $n"
if APP_C >/dev/null 2>&1 <<<"$T2 INSERT INTO import_batch (tenant_id, engagement_id, declared_legal_entity_id, declared_period_revision_id) VALUES ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001','99999999-0000-0000-0000-000000000001')"
then ng "RLS：T2 竟可寫入 T1 資料"; else ok "RLS：T2 無法寫入 T1 資料（WITH CHECK）"; fi
n=$(APP_C 2>/dev/null <<<"SELECT count(*) FROM import_batch")
[ "$n" = "0" ] && ok "RLS：未設定 tenant 時看不到任何資料" || ng "RLS：未設定 tenant 竟看到 $n 筆"

# ── 主狀態機（§25.5） ───────────────────────────────
expect_err "狀態機：DRAFT 不可直接跳 VALIDATED" \
  "UPDATE import_batch SET status='VALIDATED' WHERE import_batch_id='$B1'" "非法狀態遷移"
expect_ok  "狀態機：DRAFT → UPLOADED" \
  "UPDATE import_batch SET status='UPLOADED', file_name='tb.csv', file_sha256='abc' WHERE import_batch_id='$B1'"
expect_ok  "狀態機：UPLOADED → VALIDATING → VALIDATED" \
  "UPDATE import_batch SET status='VALIDATING' WHERE import_batch_id='$B1';
   UPDATE import_batch SET status='VALIDATED' WHERE import_batch_id='$B1'"

# ── G-01／INV-28（CR-002） ──────────────────────────
expect_err "INV-28：identity_status=NOT_CHECKED 不得 ACCEPTED" \
  "UPDATE import_batch SET status='ACCEPTED', hash_verified=true WHERE import_batch_id='$B1'" "G-01/INV-28"
expect_ok  "評估：權威識別符 CONFLICT 可寫入" \
  "INSERT INTO source_identity_assessment (tenant_id, import_batch_id, batch_version, match_result, evidence_kind, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$B1',1,'CONFLICT','AUTHORITATIVE_ID','r1')"
expect_err "證據分級：模糊名稱不得產生 CONFLICT" \
  "INSERT INTO source_identity_assessment (tenant_id, import_batch_id, batch_version, match_result, evidence_kind, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$B1',1,'CONFLICT','FUZZY_NAME','r1')" "violates check"
PSQL_C >/dev/null <<<"UPDATE import_batch SET identity_status='CONFLICT' WHERE import_batch_id='$B1'"
expect_err "INV-28：identity_status=CONFLICT 不得 ACCEPTED（硬性、無豁免）" \
  "UPDATE import_batch SET status='ACCEPTED', hash_verified=true WHERE import_batch_id='$B1'" "G-01/INV-28"
PSQL_C >/dev/null <<<"UPDATE import_batch SET identity_status='MATCHED' WHERE import_batch_id='$B1'"
expect_err "INV-28：MATCHED 但雜湊未驗證仍不得 ACCEPTED" \
  "UPDATE import_batch SET status='ACCEPTED', hash_verified=false WHERE import_batch_id='$B1'" "G-01/INV-28"
expect_ok  "G-01：三條件齊備 → ACCEPTED 成功" \
  "UPDATE import_batch SET status='ACCEPTED', hash_verified=true WHERE import_batch_id='$B1'"
expect_err "INV-08：SUPERSEDED 必須指向替代批次" \
  "UPDATE import_batch SET status='SUPERSEDED' WHERE import_batch_id='$B1'" "INV-08"

# ── SOD-07（CR-002，實例級） ─────────────────────────
A1=$(PSQL_C <<<"SELECT assessment_id FROM source_identity_assessment WHERE import_batch_id='$B1' LIMIT 1")
expect_err "SOD-07：上傳者不得確認自己上傳的批次（角色切換無效）" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$A1','$B1',1,'aaaaaaaa-0000-0000-0000-000000000001','R2','看起來沒問題','r1')" "SOD-07"
expect_ok  "SOD-07：另一個自然人可以確認" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$A1','$B1',1,'aaaaaaaa-0000-0000-0000-000000000002','R2','已向客戶電話確認為 A 社','r1')"
expect_err "確認不可覆寫（同一評估只能有一筆）" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$A1','$B1',1,'aaaaaaaa-0000-0000-0000-000000000002','R2','改個理由','r1')" "duplicate key"
expect_err "確認紀錄不可 UPDATE" \
  "UPDATE source_identity_resolution SET reason='改掉' WHERE assessment_id='$A1'" "不可變"

# ── 不可變性與借貸平衡 ─────────────────────────────
PSQL_C >/dev/null <<SQL
INSERT INTO source_dataset (source_dataset_id, tenant_id, import_batch_id, batch_version, granularity, content_sha256, row_count)
VALUES ('77777777-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','$B1',1,'BALANCE','h',2);
INSERT INTO source_ledger_line (tenant_id, source_dataset_id, import_batch_id, source_row_id, account_code, debit, credit, content_sha256) VALUES
 ('11111111-1111-1111-1111-111111111111','77777777-0000-0000-0000-000000000001','$B1','r1','1100',1000.00,0,'h1'),
 ('11111111-1111-1111-1111-111111111111','77777777-0000-0000-0000-000000000001','$B1','r2','4000',0,1000.00,'h2');
SQL
bal=$(PSQL_C <<<"SELECT fn_tb_balance('$B1')")
[ "$bal" = "0.00" ] && ok "G-01：借貸平衡函式（差額 0.00）" || ng "借貸平衡：期望 0.00 得到 $bal"
expect_err "SourceLedgerLine 不可變（更正走新批次）" \
  "UPDATE source_ledger_line SET debit=999 WHERE source_row_id='r1'" "不可變"
expect_err "稽核軌跡 append-only" \
  "INSERT INTO audit_event (tenant_id, kind, event_type) VALUES ('11111111-1111-1111-1111-111111111111','DOMAIN_EVENT','test');
   DELETE FROM audit_event" "append-only"

# ── 映射版本化（SLICE-M2-01；migrations/0005） ───────
PSQL_C >/dev/null <<'SQL'
INSERT INTO chart_of_accounts (coa_id, tenant_id, engagement_id, name) VALUES
  ('88888888-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','集團科目表');
INSERT INTO account (account_id, tenant_id, coa_id, code, name) VALUES
  ('ac000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','1002','银行存款'),
  ('ac000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','6602','管理费用');
INSERT INTO client_engagement (engagement_id, tenant_id, name) VALUES
  ('eeeeeeee-0000-0000-0000-000000000099','11111111-1111-1111-1111-111111111111','另一案件');
INSERT INTO chart_of_accounts (coa_id, tenant_id, engagement_id, name) VALUES
  ('88888888-0000-0000-0000-000000000099','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000099','另一案件科目表');
INSERT INTO account (account_id, tenant_id, coa_id, code, name) VALUES
  ('ac000000-0000-0000-0000-000000000099','11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000099','1002','银行存款');
SQL
ok "映射測試種子（兩案件各一份科目表）"

MR1=ab000000-0000-0000-0000-000000000001
expect_ok "映射：建立草稿 v1" \
  "INSERT INTO mapping_rule (mapping_rule_id, tenant_id, engagement_id, source_account_code, target_account_id, version_no, created_by)
   VALUES ('$MR1','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','111','ac000000-0000-0000-0000-000000000001',1,'aaaaaaaa-0000-0000-0000-000000000001')"
expect_err "映射歸屬：目標科目屬其他案件 → 拒絕（§24.1A）" \
  "INSERT INTO mapping_rule (tenant_id, engagement_id, source_account_code, target_account_id, version_no, created_by)
   VALUES ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','112','ac000000-0000-0000-0000-000000000099',1,'aaaaaaaa-0000-0000-0000-000000000001')" "歸屬違規"
expect_err "映射 SOD：建立者不得批准自己（自然人判定）" \
  "UPDATE mapping_rule SET approved_by='aaaaaaaa-0000-0000-0000-000000000001', approved_at=now() WHERE mapping_rule_id='$MR1'" "SOD"
expect_ok "映射批准：另一自然人可批准" \
  "UPDATE mapping_rule SET approved_by='aaaaaaaa-0000-0000-0000-000000000002', approved_at=now() WHERE mapping_rule_id='$MR1'"
expect_err "映射版本不可覆寫：已批准列不可修改" \
  "UPDATE mapping_rule SET target_account_id='ac000000-0000-0000-0000-000000000002' WHERE mapping_rule_id='$MR1'" "不可覆寫"
expect_err "映射版本不可覆寫：已批准列不可刪除" \
  "DELETE FROM mapping_rule WHERE mapping_rule_id='$MR1'" "不可覆寫"
expect_ok "映射改版＝插入新版本列（v2）" \
  "INSERT INTO mapping_rule (tenant_id, engagement_id, source_account_code, target_account_id, version_no, created_by)
   VALUES ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','111','ac000000-0000-0000-0000-000000000002',2,'aaaaaaaa-0000-0000-0000-000000000001')"
expect_err "同（案件, 來源科目, 版本）唯一" \
  "INSERT INTO mapping_rule (tenant_id, engagement_id, source_account_code, target_account_id, version_no, created_by)
   VALUES ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','111','ac000000-0000-0000-0000-000000000001',2,'aaaaaaaa-0000-0000-0000-000000000001')" "duplicate key"
n=$(APP_C <<<"$T2 SELECT count(*) FROM mapping_rule")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的映射" || ng "RLS：mapping_rule 洩漏 $n 筆"
expect_err "硬化：created_by 必填（NULL 會使 SOD 比較永遠不成立）" \
  "INSERT INTO mapping_rule (tenant_id, engagement_id, source_account_code, target_account_id, version_no)
   VALUES ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','130','ac000000-0000-0000-0000-000000000001',1)" "null value"
expect_err "硬化：created_by 不可變更（草稿改建立者再自批＝同一個洞）" \
  "INSERT INTO mapping_rule (mapping_rule_id, tenant_id, engagement_id, source_account_code, target_account_id, version_no, created_by)
   VALUES ('ab000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','140','ac000000-0000-0000-0000-000000000001',1,'aaaaaaaa-0000-0000-0000-000000000001');
   UPDATE mapping_rule SET created_by='aaaaaaaa-0000-0000-0000-000000000002' WHERE mapping_rule_id='ab000000-0000-0000-0000-000000000002'" "不可變更"

# ══ SLICE-M2-02A：Adjustment 生命週期（migration 0007）══════════
# 三個守衛掛在三個不同遷移；此層驗證 DB 為最後防線——繞過應用層直接寫 SQL 同樣被擋。
PSQL_C <<'SQL' >/dev/null
SET app.tenant_id = '11111111-1111-1111-1111-111111111111';
INSERT INTO app_user (user_id, tenant_id, email, display_name) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','manager@t1.jp','經理丙');
SQL
ok "調整測試種子（第三個自然人：AC-WFL-001 需要三人互異）"

JIA=aaaaaaaa-0000-0000-0000-000000000001
YI=aaaaaaaa-0000-0000-0000-000000000002
BING=aaaaaaaa-0000-0000-0000-000000000003
ENG=eeeeeeee-0000-0000-0000-000000000001
PR=99999999-0000-0000-0000-000000000001
ACC1=ac000000-0000-0000-0000-000000000001
ACC2=ac000000-0000-0000-0000-000000000002
ADJ=ad000000-0000-0000-0000-000000000001
EVID="legal_basis='企業会計基準第29号', evidence_ref='attach-001.pdf', judgment_reason='集團政策', language_tag='ja-JP'"

expect_ok "調整：建立草稿（prepared_by 甲）" \
  "$T1 INSERT INTO adjustment (adjustment_id, tenant_id, engagement_id, period_revision_id, title, prepared_by)
   VALUES ('$ADJ','11111111-1111-1111-1111-111111111111','$ENG','$PR','GROUP_GAAP 調整','$JIA')"
expect_err "調整明細歸屬：集團科目屬其他案件 → 拒絕（§24.1A）" \
  "$T1 INSERT INTO adjustment_line (tenant_id, adjustment_id, line_no, target_account_id, debit, credit)
   VALUES ('11111111-1111-1111-1111-111111111111','$ADJ',1,'ac000000-0000-0000-0000-000000000099',100,0)" "歸屬違規"
expect_ok "調整明細：兩列借貸平衡" \
  "$T1 INSERT INTO adjustment_line (tenant_id, adjustment_id, line_no, target_account_id, debit, credit) VALUES
     ('11111111-1111-1111-1111-111111111111','$ADJ',1,'$ACC1',1234.56,0),
     ('11111111-1111-1111-1111-111111111111','$ADJ',2,'$ACC2',0,1234.56)"

expect_err "不得跳關：DRAFTING → APPROVED" \
  "$T1 UPDATE adjustment SET status='APPROVED' WHERE adjustment_id='$ADJ'" "非法狀態遷移"
expect_err "不得跳關：DRAFTING → PENDING_APPROVAL" \
  "$T1 UPDATE adjustment SET status='PENDING_APPROVAL' WHERE adjustment_id='$ADJ'" "非法狀態遷移"
expect_err "G-08：必要證據未齊 → 不得送覆核" \
  "$T1 UPDATE adjustment SET status='PENDING_REVIEW' WHERE adjustment_id='$ADJ'" "G-08"
expect_err "G-08：只補三項仍不得送覆核（語言標籤缺）" \
  "$T1 UPDATE adjustment SET legal_basis='x', evidence_ref='y', judgment_reason='z',
       status='PENDING_REVIEW' WHERE adjustment_id='$ADJ'" "G-08"
expect_ok "G-08：四項齊備 → 可送覆核" \
  "$T1 UPDATE adjustment SET $EVID, status='PENDING_REVIEW', business_version=2
   WHERE adjustment_id='$ADJ'"

expect_err "明細凍結：離開 DRAFTING 後不可再變更" \
  "$T1 UPDATE adjustment_line SET debit=999 WHERE adjustment_id='$ADJ' AND line_no=1" "不可再變更"
expect_err "G-04／SOD-01：編製人（甲）不得覆核自己" \
  "$T1 UPDATE adjustment SET status='PENDING_APPROVAL', reviewed_by='$JIA', reviewed_at=now()
   WHERE adjustment_id='$ADJ'" "SOD-01"
expect_err "G-04／SOD-01：覆核人未記錄不得進 PENDING_APPROVAL" \
  "$T1 UPDATE adjustment SET status='PENDING_APPROVAL' WHERE adjustment_id='$ADJ'" "SOD-01"
expect_ok "覆核：另一自然人（乙）通過" \
  "$T1 UPDATE adjustment SET status='PENDING_APPROVAL', reviewed_by='$YI', reviewed_at=now(),
       business_version=3 WHERE adjustment_id='$ADJ'"

expect_err "物化守衛：批准前不得寫入 JournalEntry" \
  "$T1 INSERT INTO journal_entry (tenant_id, engagement_id, period_revision_id, adjustment_id, business_version, entry_date)
   VALUES ('11111111-1111-1111-1111-111111111111','$ENG','$PR','$ADJ',3,'2026-03-31')" "只在 APPROVED 後物化"
expect_err "G-05／SOD-02：覆核人（乙）不得兼批准人" \
  "$T1 UPDATE adjustment SET status='APPROVED', approved_by='$YI', approved_at=now()
   WHERE adjustment_id='$ADJ'" "SOD-02"
# 甲編製→乙覆核→甲批准：SOD-01 與 SOD-02 都成立，唯有 AC-WFL-001 能擋下
expect_err "AC-WFL-001：編製人（甲）不得批准自己——SOD-01／02 皆成立仍須被擋" \
  "$T1 UPDATE adjustment SET status='APPROVED', approved_by='$JIA', approved_at=now()
   WHERE adjustment_id='$ADJ'" "AC-WFL-001"
expect_err "SoD 基準不可改寫：prepared_by 不可變更" \
  "$T1 UPDATE adjustment SET prepared_by='$BING' WHERE adjustment_id='$ADJ'" "不可變更"

expect_ok "批准：第三個自然人（丙）通過" \
  "$T1 UPDATE adjustment SET status='APPROVED', approved_by='$BING', approved_at=now(),
       business_version=4 WHERE adjustment_id='$ADJ'"
expect_ok "物化：APPROVED 後可寫入 JournalEntry／JournalLine" \
  "$T1 INSERT INTO journal_entry (entry_id, tenant_id, engagement_id, period_revision_id, adjustment_id, business_version, entry_date)
   VALUES ('be000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','$ENG','$PR','$ADJ',4,'2026-03-31');
   INSERT INTO journal_line (tenant_id, entry_id, line_no, account_id, debit, credit) VALUES
     ('11111111-1111-1111-1111-111111111111','be000000-0000-0000-0000-000000000001',1,'$ACC1',1234.56,0),
     ('11111111-1111-1111-1111-111111111111','be000000-0000-0000-0000-000000000001',2,'$ACC2',0,1234.56)"
expect_err "物化版本一致：business_version 不符 → 拒絕" \
  "$T1 INSERT INTO journal_entry (tenant_id, engagement_id, period_revision_id, adjustment_id, business_version, entry_date)
   VALUES ('11111111-1111-1111-1111-111111111111','$ENG','$PR','$ADJ',9,'2026-03-31')" "須與調整當下版本"
expect_err "已批准調整不可修改" \
  "$T1 UPDATE adjustment SET title='改標題' WHERE adjustment_id='$ADJ'" "不可修改"
expect_err "已批准調整不可刪除" \
  "$T1 DELETE FROM adjustment WHERE adjustment_id='$ADJ'" "不可刪除"
expect_err "JournalLine 不可變（正式事實）" \
  "$T1 UPDATE journal_line SET debit=1 WHERE entry_id='be000000-0000-0000-0000-000000000001'" "不可變"

n=$(APP_C <<<"$T1 SELECT count(*) FROM journal_line jl JOIN journal_entry je ON je.entry_id=jl.entry_id
  WHERE je.adjustment_id='$ADJ'")
[ "$n" = "2" ] && ok "物化結果：2 列正式分錄" || ng "物化列數不符：$n"

# 退回路徑：另一筆調整走 PENDING_APPROVAL → DRAFTING
ADJ2=ad000000-0000-0000-0000-000000000002
if ! PSQL_C <<SQL >/dev/null 2>&1
$T1
INSERT INTO adjustment (adjustment_id, tenant_id, engagement_id, period_revision_id, title, prepared_by,
                        legal_basis, evidence_ref, judgment_reason, language_tag)
VALUES ('$ADJ2','11111111-1111-1111-1111-111111111111','$ENG','$PR','退回測試','$JIA',
        '企業会計基準第29号','attach-002.pdf','集團政策','ja-JP');
INSERT INTO adjustment_line (tenant_id, adjustment_id, line_no, target_account_id, debit, credit) VALUES
  ('11111111-1111-1111-1111-111111111111','$ADJ2',1,'$ACC1',500,0),
  ('11111111-1111-1111-1111-111111111111','$ADJ2',2,'$ACC2',0,500);
UPDATE adjustment SET status='PENDING_REVIEW', business_version=2 WHERE adjustment_id='$ADJ2';
UPDATE adjustment SET status='PENDING_APPROVAL', reviewed_by='$YI', reviewed_at=now(), business_version=3
 WHERE adjustment_id='$ADJ2';
SQL
then ng "退回測試種子建立失敗"; else ok "退回測試種子（ADJ2 已達 PENDING_APPROVAL）"; fi

expect_err "退回：從 PENDING_APPROVAL 退回未清空覆核 → 拒絕（覆核須失效）" \
  "$T1 UPDATE adjustment SET status='DRAFTING', business_version=4 WHERE adjustment_id='$ADJ2'" "覆核必須失效"
expect_ok "退回：清空 reviewed_by／reviewed_at 後可退回草稿" \
  "$T1 UPDATE adjustment SET status='DRAFTING', reviewed_by=NULL, reviewed_at=NULL, business_version=4
   WHERE adjustment_id='$ADJ2'"
expect_ok "退回里程碑：business_version 遞增並留不可變快照（ADR-M2-001）" \
  "$T1 INSERT INTO adjustment_version_snapshot (tenant_id, adjustment_id, business_version, milestone,
        actor_id, acting_role, reason_category, reason_note, content, content_sha256)
   VALUES ('11111111-1111-1111-1111-111111111111','$ADJ2',4,'RETURNED','$YI','R4','CALCULATION_ERROR',
           '金額有誤','{}'::jsonb,'deadbeef')"
expect_err "退回快照不可變" \
  "$T1 UPDATE adjustment_version_snapshot SET reason_note='改' WHERE adjustment_id='$ADJ2'" "不可變"
n=$(APP_C <<<"$T1 SELECT adjustment_id FROM adjustment WHERE adjustment_id='$ADJ2'" | wc -l | tr -d ' ')
[ "$n" = "1" ] && ok "退回不建立新調整：adjustment_id 不變（ADR-M2-001）" || ng "退回後調整筆數異常：$n"

# ══ 0008 硬化：同狀態繞過與跨租戶錯配 ══════════════════════════
# 缺口 2 實測重現：0008 之前，同狀態 UPDATE 可把 reviewed_by 改成編製人本人，
# SOD-01 在 DB 層被完全繞過；併發的第二次覆核也會覆蓋第一位覆核人。
ADJ3=ad000000-0000-0000-0000-000000000003
if ! PSQL_C <<SQL >/dev/null 2>&1
$T1
INSERT INTO adjustment (adjustment_id, tenant_id, engagement_id, period_revision_id, title, prepared_by,
                        legal_basis, evidence_ref, judgment_reason, language_tag)
VALUES ('$ADJ3','11111111-1111-1111-1111-111111111111','$ENG','$PR','繞過測試','$JIA',
        '法源','附件','理由','ja-JP');
INSERT INTO adjustment_line (tenant_id, adjustment_id, line_no, target_account_id, debit, credit) VALUES
  ('11111111-1111-1111-1111-111111111111','$ADJ3',1,'$ACC1',700,0),
  ('11111111-1111-1111-1111-111111111111','$ADJ3',2,'$ACC2',0,700);
UPDATE adjustment SET status='PENDING_REVIEW', business_version=2 WHERE adjustment_id='$ADJ3';
UPDATE adjustment SET status='PENDING_APPROVAL', reviewed_by='$YI', reviewed_at=now(), business_version=3
 WHERE adjustment_id='$ADJ3';
SQL
then ng "繞過測試種子建立失敗"; else ok "繞過測試種子（ADJ3 已達 PENDING_APPROVAL，覆核人乙）"; fi

expect_err "繞過封鎖：同狀態改寫 reviewed_by → 拒絕（SOD-01 的比較基準）" \
  "$T1 UPDATE adjustment SET reviewed_by='$JIA' WHERE adjustment_id='$ADJ3'" "不得改寫"
expect_err "繞過封鎖：同狀態改寫 business_version → 拒絕" \
  "$T1 UPDATE adjustment SET business_version=99 WHERE adjustment_id='$ADJ3'" "只能隨狀態遷移變動"
expect_err "繞過封鎖：同狀態改寫已送出的表頭 → 拒絕" \
  "$T1 UPDATE adjustment SET title='竄改' WHERE adjustment_id='$ADJ3'" "不可再變更"
# 併發：兩個覆核請求都讀到 PENDING_REVIEW，第一個先提交。第二個到達時列已是
# PENDING_APPROVAL，該遷移變成同狀態改寫 reviewed_by —— 被覆核人不可改寫規則擋下。
expect_err "併發覆核：第二次覆核不得覆蓋第一位覆核人" \
  "$T1 UPDATE adjustment SET status='PENDING_APPROVAL', reviewed_by='$BING', reviewed_at=now(),
       business_version=4 WHERE adjustment_id='$ADJ3'" "不得改寫"
expect_err "里程碑紀律：狀態遷移未遞增 business_version → 拒絕" \
  "$T1 UPDATE adjustment SET status='DRAFTING', reviewed_by=NULL, reviewed_at=NULL
   WHERE adjustment_id='$ADJ3'" "必須將 business_version"
expect_err "里程碑紀律：business_version 跳號 → 拒絕" \
  "$T1 UPDATE adjustment SET status='DRAFTING', reviewed_by=NULL, reviewed_at=NULL, business_version=9
   WHERE adjustment_id='$ADJ3'" "前進為"
expect_err "批准人不可改寫：已批准列以外不得設定 approved_by" \
  "$T1 UPDATE adjustment SET approved_by='$BING' WHERE adjustment_id='$ADJ3'" "只能在進入 APPROVED"
n=$(APP_C <<<"$T1 SELECT reviewed_by FROM adjustment WHERE adjustment_id='$ADJ3'")
[ "$n" = "$YI" ] && ok "繞過嘗試後覆核人仍為乙（未被竄改）" || ng "覆核人已被竄改為 $n"

# 缺口 5 實測重現：tenant_id 自填為 T1、engagement_id 指向 T2 的案件。
# RLS 只比對列自己的 tenant_id，一般 FK 不保證父物件同租戶（INV-18）。
PSQL_C <<'SQL' >/dev/null 2>&1
SET app.tenant_id = '22222222-2222-2222-2222-222222222222';
INSERT INTO client_engagement (engagement_id, tenant_id, name) VALUES
  ('e2222222-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','T2 案件');
INSERT INTO app_user (user_id, tenant_id, email, display_name) VALUES
  ('a2222222-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','x@t2.jp','T2 使用者');
SQL
ok "跨租戶測試種子（T2 案件與使用者）"

expect_err "INV-18：tenant_id=T1 但案件屬 T2 → 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by)
   VALUES ('11111111-1111-1111-1111-111111111111','e2222222-0000-0000-0000-000000000001','$PR','跨租戶','$JIA')" \
  "案件（.*）不屬於本租戶"
expect_err "INV-18：編製人屬 T2 → 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by)
   VALUES ('11111111-1111-1111-1111-111111111111','$ENG','$PR','跨租戶','a2222222-0000-0000-0000-000000000001')" \
  "編製人（.*）不屬於本租戶"
# 以 ADJ2（退回後為 DRAFTING）測明細層：ADJ3 已離開草稿，會先被明細凍結守衛擋下
expect_err "INV-18：調整明細的 tenant_id 與父調整不符 → 拒絕" \
  "$T1 INSERT INTO adjustment_line (tenant_id, adjustment_id, line_no, target_account_id, debit, credit)
   VALUES ('22222222-2222-2222-2222-222222222222','$ADJ2',3,'$ACC1',1,0)" "不屬於本租戶"
expect_err "INV-18：快照 actor 屬其他租戶 → 拒絕" \
  "$T1 INSERT INTO adjustment_version_snapshot (tenant_id, adjustment_id, business_version, milestone,
        actor_id, acting_role, content, content_sha256)
   VALUES ('11111111-1111-1111-1111-111111111111','$ADJ3',9,'SUBMITTED',
           'a2222222-0000-0000-0000-000000000001','R2','{}'::jsonb,'x')" "不屬於本租戶"

# ══ 0009 同租戶跨案件錯配（同租戶 ≠ 同案件）══════════════════
# 0008 的守衛只確認「都是 T1」。同一租戶底下的另一個案件仍可被錯配引用。
PSQL_C <<'SQL' >/dev/null 2>&1
SET app.tenant_id = '11111111-1111-1111-1111-111111111111';
INSERT INTO reporting_unit (reporting_unit_id, tenant_id, engagement_id, unit_scope, name) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000099','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000099','LEGAL_ENTITY','另一案件單位');
INSERT INTO fiscal_calendar (fiscal_calendar_id, tenant_id, engagement_id, name, year_start_month) VALUES
  ('ffffffff-0000-0000-0000-000000000099','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000099','另一案件曆',4);
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id, fiscal_calendar_id, label, start_date, end_date) VALUES
  ('dddddddd-0000-0000-0000-000000000099','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000099','bbbbbbbb-0000-0000-0000-000000000099','ffffffff-0000-0000-0000-000000000099','2026-03','2026-03-01','2026-03-31');
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id) VALUES
  ('99999999-0000-0000-0000-000000000099','11111111-1111-1111-1111-111111111111','dddddddd-0000-0000-0000-000000000099');
SQL
ok "同租戶第二案件種子（期間與科目表皆屬 eeee...0099）"

PR99=99999999-0000-0000-0000-000000000099
ACC99=ac000000-0000-0000-0000-000000000099

expect_err "§24.1A：期間屬同租戶的另一案件 → 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by)
   VALUES ('11111111-1111-1111-1111-111111111111','$ENG','$PR99','跨案件期間','$JIA')" "與調整的案件"
expect_err "歸屬凍結：建立後不可改 engagement_id" \
  "$T1 UPDATE adjustment SET engagement_id='eeeeeeee-0000-0000-0000-000000000099'
   WHERE adjustment_id='$ADJ2'" "歸屬與分類欄位建立後不可變更"
expect_err "歸屬凍結：建立後不可改 period_revision_id" \
  "$T1 UPDATE adjustment SET period_revision_id='$PR99' WHERE adjustment_id='$ADJ2'" "不可變更"
expect_err "歸屬凍結：建立後不可改 basis／materiality" \
  "$T1 UPDATE adjustment SET basis='GROUP_GAAP', materiality='MAJOR', tenant_id='22222222-2222-2222-2222-222222222222'
   WHERE adjustment_id='$ADJ2'" "不可變更"
expect_err "§24.1A：正式分錄的案件與來源調整不一致 → 拒絕" \
  "$T1 INSERT INTO journal_entry (tenant_id, engagement_id, period_revision_id, adjustment_id, business_version, entry_date)
   VALUES ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000099','$PR','$ADJ',4,'2026-03-31')" \
  "案件（.*）與來源調整的案件"
expect_err "§24.1A：正式分錄的期間與來源調整不一致 → 拒絕" \
  "$T1 INSERT INTO journal_entry (tenant_id, engagement_id, period_revision_id, adjustment_id, business_version, entry_date)
   VALUES ('11111111-1111-1111-1111-111111111111','$ENG','$PR99','$ADJ',4,'2026-03-31')" \
  "期間（.*）與來源調整的期間"
expect_err "§24.1A：正式分錄的科目屬同租戶另一案件 → 拒絕" \
  "$T1 INSERT INTO journal_line (tenant_id, entry_id, line_no, account_id, debit, credit)
   VALUES ('11111111-1111-1111-1111-111111111111','be000000-0000-0000-0000-000000000001',9,'$ACC99',1,0)" \
  "與來源調整的案件"
ADJ4=ad000000-0000-0000-0000-000000000004
if ! PSQL_C <<SQL >/dev/null 2>&1
$T1
INSERT INTO adjustment (adjustment_id, tenant_id, engagement_id, period_revision_id, title, prepared_by,
                        legal_basis, evidence_ref, judgment_reason, language_tag)
VALUES ('$ADJ4','11111111-1111-1111-1111-111111111111','$ENG','$PR','時間戳測試','$JIA','a','b','c','ja-JP');
INSERT INTO adjustment_line (tenant_id, adjustment_id, line_no, target_account_id, debit, credit) VALUES
  ('11111111-1111-1111-1111-111111111111','$ADJ4',1,'$ACC1',900,0),
  ('11111111-1111-1111-1111-111111111111','$ADJ4',2,'$ACC2',0,900);
UPDATE adjustment SET status='PENDING_REVIEW', business_version=2 WHERE adjustment_id='$ADJ4';
SQL
then ng "時間戳測試種子建立失敗"; else ok "時間戳測試種子（ADJ4 已達 PENDING_REVIEW）"; fi

# 直接下 SQL 進入覆核／批准時，時間戳不得留空（AC-WFL-001 要求理由與時間）
expect_err "時間戳必填：進入 PENDING_APPROVAL 時 reviewed_at 不得為 NULL" \
  "$T1 UPDATE adjustment SET status='PENDING_APPROVAL', reviewed_by='$YI', reviewed_at=NULL,
       business_version=3 WHERE adjustment_id='$ADJ4'" "覆核時間"
expect_ok "時間戳齊備 → 可進入 PENDING_APPROVAL" \
  "$T1 UPDATE adjustment SET status='PENDING_APPROVAL', reviewed_by='$YI', reviewed_at=now(),
       business_version=3 WHERE adjustment_id='$ADJ4'"
expect_err "時間戳必填：進入 APPROVED 時 approved_at 不得為 NULL" \
  "$T1 UPDATE adjustment SET status='APPROVED', approved_by='$BING', approved_at=NULL,
       business_version=4 WHERE adjustment_id='$ADJ4'" "批准時間"

n=$(APP_C <<<"$T2 SELECT count(*) FROM adjustment")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的調整" || ng "RLS：adjustment 洩漏 $n 筆"
n=$(APP_C <<<"$T2 SELECT count(*) FROM journal_line")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的正式分錄" || ng "RLS：journal_line 洩漏 $n 筆"

# ══ SLICE-M2-03：BackgroundJob 租約、fencing 與冪等 ══════════════
JOB=cc000000-0000-0000-0000-000000000001
TOK1=cc000000-0000-0000-0000-0000000000a1
TOK2=cc000000-0000-0000-0000-0000000000a2

expect_ok "工作：上傳時建立（QUEUED，next_attempt_at 立即）" \
  "$T1 INSERT INTO background_job (job_id, tenant_id, job_type, subject_id, subject_version,
        rule_version, idempotency_key)
   VALUES ('$JOB','11111111-1111-1111-1111-111111111111','IMPORT_VALIDATION','$B1',1,'detect-r1','k1')"
expect_err "冪等鍵：同一 (job_type, subject, version, rule) 不得建立第二個工作" \
  "$T1 INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version, rule_version, idempotency_key)
   VALUES ('11111111-1111-1111-1111-111111111111','IMPORT_VALIDATION','$B1',1,'detect-r1','k2')" "duplicate key"
expect_ok "冪等鍵：規則版本不同即為不同工作" \
  "$T1 INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version, rule_version, idempotency_key)
   VALUES ('11111111-1111-1111-1111-111111111111','IMPORT_VALIDATION','$B1',1,'detect-r2','k3')"
expect_err "INV-18：工作主體屬其他租戶 → 拒絕" \
  "$T1 INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version, rule_version, idempotency_key)
   VALUES ('22222222-2222-2222-2222-222222222222','IMPORT_VALIDATION','$B1',1,'detect-r9','k9')" "不屬於本租戶"

expect_err "認領必須產生新的 claim_token（fencing token）" \
  "$T1 UPDATE background_job SET status='RUNNING', claimed_by='w1', claimed_at=now(),
       lease_expires_at=now()+interval '60 seconds', attempt_count=1 WHERE job_id='$JOB'" "claim_token"
expect_err "認領必須遞增 attempt_count" \
  "$T1 UPDATE background_job SET status='RUNNING', claim_token='$TOK1', claimed_by='w1', claimed_at=now(),
       lease_expires_at=now()+interval '60 seconds' WHERE job_id='$JOB'" "attempt_count"
expect_ok "認領：RUNNING ＋ 新 token ＋ 租約 ＋ attempt_count=1" \
  "$T1 UPDATE background_job SET status='RUNNING', claim_token='$TOK1', claimed_by='w1', claimed_at=now(),
       lease_expires_at=now()+interval '60 seconds', attempt_count=1 WHERE job_id='$JOB'"

# fencing：舊 token 的寫回必須落空，即使 claimed_by 相同（worker ID 會被重用）
n=$(APP_C <<<"$T1 UPDATE background_job SET status='COMPLETED'
  WHERE job_id='$JOB' AND claim_token='$TOK2' RETURNING 1" | wc -l | tr -d ' ')
[ "$n" = "0" ] && ok "fencing：持舊／錯誤 claim_token 的寫回落空" || ng "fencing 失效：影響 $n 列"
n=$(APP_C <<<"$T1 UPDATE background_job SET lease_expires_at=now()+interval '60 seconds'
  WHERE job_id='$JOB' AND claim_token='$TOK2' AND lease_expires_at>now() RETURNING 1" | wc -l | tr -d ' ')
[ "$n" = "0" ] && ok "心跳：持舊 token 無法延長租約" || ng "心跳 fencing 失效"
n=$(APP_C <<<"$T1 UPDATE background_job SET lease_expires_at=now()+interval '120 seconds'
  WHERE job_id='$JOB' AND claim_token='$TOK1' AND lease_expires_at>now() RETURNING 1" | wc -l | tr -d ' ')
[ "$n" = "1" ] && ok "心跳：持有者可延長租約" || ng "心跳失敗"

expect_err "冪等鍵欄位建立後不可變更" \
  "$T1 UPDATE background_job SET rule_version='detect-r9' WHERE job_id='$JOB'" "不可變更"
expect_err "失敗終態必須有分類與人可讀原因（§27.4 不吞掉錯誤）" \
  "$T1 UPDATE background_job SET status='FAILED' WHERE job_id='$JOB'" "人可讀原因"
expect_err "RETRY_WAIT 必須設定未來的 next_attempt_at" \
  "$T1 UPDATE background_job SET status='RETRY_WAIT', last_error_class='RETRYABLE_INFRASTRUCTURE',
       next_attempt_at=now()-interval '1 hour' WHERE job_id='$JOB'" "next_attempt_at"
expect_ok "RETRY_WAIT：記錄分類與退避時間" \
  "$T1 UPDATE background_job SET status='RETRY_WAIT', last_error_class='RETRYABLE_INFRASTRUCTURE',
       last_error_message='connection reset', next_attempt_at=now()+interval '5 seconds' WHERE job_id='$JOB'"
n=$(APP_C <<<"$T1 SELECT COALESCE(claim_token::text,'released') FROM background_job WHERE job_id='$JOB'")
[ "$n" = "released" ] && ok "離開 RUNNING 即釋放租約（不留殘存 token）" || ng "租約未釋放：$n"

expect_err "終態不可復活：FAILED 之後不得再 RUNNING" \
  "$T1 UPDATE background_job SET status='RUNNING', claim_token='$TOK2', claimed_at=now(),
       lease_expires_at=now()+interval '60 seconds', attempt_count=2 WHERE job_id='$JOB';
   UPDATE background_job SET status='FAILED', last_error_class='NON_RETRYABLE_SYSTEM',
       last_error_message='x' WHERE job_id='$JOB';
   UPDATE background_job SET status='RUNNING', claim_token='cc000000-0000-0000-0000-0000000000a3',
       claimed_at=now(), lease_expires_at=now()+interval '60 seconds', attempt_count=3 WHERE job_id='$JOB'" \
  "非法工作狀態遷移"

# ── 關閉修正 ①②③（2026-08-05；SLICE-M2-03 逐行審查回饋） ────────
J2=cc000000-0000-0000-0000-000000000002
TOKA=cc000000-0000-0000-0000-0000000000b1
TOKB=cc000000-0000-0000-0000-0000000000b2
TOKC=cc000000-0000-0000-0000-0000000000b3
expect_ok "關閉③ 前置：建立並認領第二個工作（attempt 1）" \
  "$T1 INSERT INTO background_job (job_id, tenant_id, job_type, subject_id, subject_version, rule_version, idempotency_key)
   VALUES ('$J2','11111111-1111-1111-1111-111111111111','IMPORT_VALIDATION','$B1',3,'detect-r1','k4');
   UPDATE background_job SET status='RUNNING', claim_token='$TOKA', claimed_by='w1', claimed_at=now(),
       lease_expires_at=now()+interval '60 seconds', attempt_count=1 WHERE job_id='$J2'"
expect_err "關閉③：活租約不可被搶（RUNNING→RUNNING 未到期換 token）" \
  "$T1 UPDATE background_job SET status='RUNNING', claim_token='$TOKB', claimed_by='w2', claimed_at=now(),
       lease_expires_at=now()+interval '60 seconds', attempt_count=2 WHERE job_id='$J2'" "不得重領"
expect_ok "前置：使租約到期（同 token 欄位更新＝心跳路徑，合法）" \
  "$T1 UPDATE background_job SET lease_expires_at=now()-interval '1 second' WHERE job_id='$J2'"
expect_err "關閉③：到期重領仍須遞增 attempt_count（同狀態不再是後門）" \
  "$T1 UPDATE background_job SET status='RUNNING', claim_token='$TOKB', claimed_by='w2', claimed_at=now(),
       lease_expires_at=now()+interval '60 seconds' WHERE job_id='$J2'" "attempt_count"
expect_ok "關閉③：到期重領（新 token＋attempt_count 遞增）成功" \
  "$T1 UPDATE background_job SET status='RUNNING', claim_token='$TOKB', claimed_by='w2', claimed_at=now(),
       lease_expires_at=now()+interval '60 seconds', attempt_count=2 WHERE job_id='$J2'"
expect_ok "前置：再次使租約到期" \
  "$T1 UPDATE background_job SET lease_expires_at=now()-interval '1 second' WHERE job_id='$J2'"
n=$(APP_C <<<"$T1 UPDATE background_job SET status='RETRY_WAIT', last_error_class='RETRYABLE_INFRASTRUCTURE',
      last_error_message='conn reset', next_attempt_at=now()+interval '5 seconds'
    WHERE job_id='$J2' AND claim_token='$TOKB' AND lease_expires_at>now() RETURNING 1" | wc -l | tr -d ' ')
[ "$n" = "0" ] && ok "關閉①：租約到期後失敗寫回落空（0 列，不改任何狀態）" || ng "關閉①失效：影響 $n 列"
expect_err "關閉②：交易內 fencing 斷言——租約到期即 LEASE_LOST" \
  "$T1 WITH fence AS (SELECT job_id FROM background_job
        WHERE job_id='$J2' AND claim_token='$TOKB' AND lease_expires_at>now() FOR UPDATE)
   SELECT fn_assert(EXISTS (SELECT 1 FROM fence), 'LEASE_LOST')" "LEASE_LOST"
expect_ok "前置：到期重領（attempt 3，租約有效）" \
  "$T1 UPDATE background_job SET status='RUNNING', claim_token='$TOKC', claimed_by='w3', claimed_at=now(),
       lease_expires_at=now()+interval '60 seconds', attempt_count=3 WHERE job_id='$J2'"
# 交易 A 持 fence 列鎖 2 秒；期間競爭者以 FOR UPDATE SKIP LOCKED 探測必須拿不到列
( PSQL_C >/dev/null 2>&1 <<LOCKSQL
$T1
BEGIN;
WITH fence AS (SELECT job_id FROM background_job
  WHERE job_id='$J2' AND claim_token='$TOKC' AND lease_expires_at>now() FOR UPDATE)
SELECT fn_assert(EXISTS (SELECT 1 FROM fence), 'LEASE_LOST');
SELECT pg_sleep(2);
COMMIT;
LOCKSQL
) &
LOCKER=$!
sleep 1
n=$(APP_C <<<"$T1 SELECT count(*) FROM (
      SELECT job_id FROM background_job WHERE job_id='$J2' FOR UPDATE SKIP LOCKED) x")
wait $LOCKER
[ "$n" = "0" ] && ok "關閉②：fence 列鎖持有至 COMMIT——SKIP LOCKED 競爭者拿不到列" \
               || ng "關閉②失效：鎖未生效（競爭者取得 $n 列）"

# ── SLICE-M2-02B：CalculationRun／Manifest／快照（migrations/0012） ──
MANI=ee110000-0000-0000-0000-000000000001
MANI2=ee110000-0000-0000-0000-000000000002
RUNA=ee110000-0000-0000-0000-000000000011
RUNB=ee110000-0000-0000-0000-000000000012
expect_ok "Manifest 建立（NO_FX、演算法與標準化版本必填）" \
  "$T1 INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
   VALUES ('$MANI','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '99999999-0000-0000-0000-000000000001','NO_FX','sqlcanon-1','h0','aaaaaaaa-0000-0000-0000-000000000001');
   INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
   VALUES ('$MANI2','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '99999999-0000-0000-0000-000000000001','NO_FX','sqlcanon-1','h0','aaaaaaaa-0000-0000-0000-000000000001');
   INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, domain_version_kind,
        domain_version_value, content_canonical, content_hash, payload)
   VALUES ('11111111-1111-1111-1111-111111111111','$MANI','SCOPE','SCOPE','1','c','h','{}'::jsonb)"
expect_err "Manifest 不可修改（INV-17：凍結即不可變）" \
  "$T1 UPDATE calculation_input_manifest SET frozen_set_content_hash='x' WHERE manifest_id='$MANI'" "不可變"
expect_err "Manifest entry 不可修改" \
  "$T1 UPDATE calculation_manifest_entry SET content_hash='x' WHERE manifest_id='$MANI'" "不可變"
expect_ok "原始 Run 建立（RUNNING）" \
  "$T1 INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, request_key, request_content_hash, engine_version, created_by)
   VALUES ('$RUNA','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '99999999-0000-0000-0000-000000000001','$B1','$MANI','PREVIEW',
           'ee110000-0000-0000-0000-0000000000a1','rc1','calc-engine-1','aaaaaaaa-0000-0000-0000-000000000001')"
expect_err "同一 Manifest 不得有第二個原始 Run（partial unique）" \
  "$T1 INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, request_key, request_content_hash, engine_version, created_by)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '99999999-0000-0000-0000-000000000001','$B1','$MANI','PREVIEW',
           gen_random_uuid(),'rc2','calc-engine-1','aaaaaaaa-0000-0000-0000-000000000001')" "duplicate key"
expect_err "run_type 僅 PREVIEW——不為 PREVIEW 偷建正式資格（護欄 4）" \
  "$T1 INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, request_key, request_content_hash, engine_version, created_by)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '99999999-0000-0000-0000-000000000001','$B1','$MANI2','OFFICIAL',
           gen_random_uuid(),'rc3','calc-engine-1','aaaaaaaa-0000-0000-0000-000000000001')" "check"
expect_err "Run 建立時必須為 RUNNING" \
  "$T1 INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, status, request_key, request_content_hash, engine_version, created_by)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '99999999-0000-0000-0000-000000000001','$B1','$MANI2','PREVIEW','COMPLETED',
           gen_random_uuid(),'rc4','calc-engine-1','aaaaaaaa-0000-0000-0000-000000000001')" "必須為 RUNNING"
expect_err "replay 必須引用原 run 的同一份 Manifest" \
  "$T1 INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, replay_of_run_id, request_key, request_content_hash, engine_version, created_by)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '99999999-0000-0000-0000-000000000001','$B1','$MANI2','PREVIEW','$RUNA',
           gen_random_uuid(),'rc5','calc-engine-1','aaaaaaaa-0000-0000-0000-000000000001')" "同一份 Manifest"
expect_ok "replay Run 建立（同 Manifest、引用原 run；無隱含一對一）" \
  "$T1 INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, replay_of_run_id, request_key, request_content_hash, engine_version, created_by)
   VALUES ('$RUNB','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '99999999-0000-0000-0000-000000000001','$B1','$MANI','PREVIEW','$RUNA',
           'ee110000-0000-0000-0000-0000000000a2','REPLAY|$RUNA','calc-engine-1','aaaaaaaa-0000-0000-0000-000000000001')"
expect_err "RUNNING → SUPERSEDED 被拒（本刀不使用，§25.11 語意保留）" \
  "$T1 UPDATE calculation_run SET status='SUPERSEDED' WHERE calculation_run_id='$RUNA'" "不使用"
expect_err "COMPLETED 必須帶 result_content_hash（INV-17）" \
  "$T1 UPDATE calculation_run SET status='COMPLETED' WHERE calculation_run_id='$RUNA'" "result_content_hash"
expect_ok "RUNNING → COMPLETED（帶結果 hash）" \
  "$T1 UPDATE calculation_run SET status='COMPLETED', result_content_hash='r1' WHERE calculation_run_id='$RUNA'"
expect_err "終態不可修改——重演＝建立新 run" \
  "$T1 UPDATE calculation_run SET result_content_hash='r2' WHERE calculation_run_id='$RUNA'" "終態"
expect_err "FAILED 必須帶機器代碼與客戶可理解原因" \
  "$T1 UPDATE calculation_run SET status='FAILED' WHERE calculation_run_id='$RUNB'" "機器代碼"
expect_ok "FAILED（帶 REPLAY_FAILED 代碼與原因）——失敗狀態屬 replay run，原 run 不變" \
  "$T1 UPDATE calculation_run SET status='FAILED', failure_reason_code='REPLAY_FAILED',
       failure_reason='凍結內容雜湊不符' WHERE calculation_run_id='$RUNB'"
expect_ok "快照輸出建立（run 內 層×科目 唯一）" \
  "$T1 INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit)
   VALUES ('11111111-1111-1111-1111-111111111111','$RUNA','SOURCE_TB','ac000000-0000-0000-0000-000000000001',
           '1002','银行存款',100.00,0)"
expect_err "快照重複（run×層×科目）→ 拒絕（重領不產生重複產物）" \
  "$T1 INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit)
   VALUES ('11111111-1111-1111-1111-111111111111','$RUNA','SOURCE_TB','ac000000-0000-0000-0000-000000000001',
           '1002','银行存款',200.00,0)" "duplicate key"
expect_err "快照不可修改" \
  "$T1 UPDATE balance_snapshot_line SET debit=999 WHERE calculation_run_id='$RUNA'" "不可變"
expect_ok "BackgroundJob 支援 CALCULATION_RUN 型別" \
  "$T1 INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version, rule_version, idempotency_key)
   VALUES ('11111111-1111-1111-1111-111111111111','CALCULATION_RUN','$RUNA',1,'calc-engine-1','ck1')"
expect_err "INV-18：計算工作主體屬其他租戶 → 拒絕" \
  "$T1 INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version, rule_version, idempotency_key)
   VALUES ('22222222-2222-2222-2222-222222222222','CALCULATION_RUN','$RUNA',1,'calc-engine-1','ck2')" "不屬於本租戶"
n=$(APP_C <<<"$T2 SELECT count(*) FROM calculation_run")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的計算執行" || ng "RLS：calculation_run 洩漏 $n 筆"

# 衍生資料的自然唯一性（冪等第二道防線）
expect_err "冪等：同批次同版本同粒度不得有第二個 source_dataset" \
  "$T1 INSERT INTO source_dataset (tenant_id, import_batch_id, batch_version, granularity, content_sha256, row_count)
   VALUES ('11111111-1111-1111-1111-111111111111','$B1',1,'BALANCE','h2',2)" "duplicate key"
expect_ok "冪等：不同 batch_version 視為不同資料集" \
  "$T1 INSERT INTO source_dataset (tenant_id, import_batch_id, batch_version, granularity, content_sha256, row_count)
   VALUES ('11111111-1111-1111-1111-111111111111','$B1',2,'BALANCE','h3',2)"
expect_ok "冪等：data_coverage 首筆" \
  "$T1 INSERT INTO data_coverage (tenant_id, import_batch_id, batch_version, granularity, completeness_status)
   VALUES ('11111111-1111-1111-1111-111111111111','$B1',1,'BALANCE','UNKNOWN')"
expect_err "冪等：data_coverage 同鍵不得重複" \
  "$T1 INSERT INTO data_coverage (tenant_id, import_batch_id, batch_version, granularity, completeness_status)
   VALUES ('11111111-1111-1111-1111-111111111111','$B1',1,'BALANCE','COMPLETE')" "duplicate key"
expect_ok "冪等：source_identity_assessment 首筆（batch_version=1, detect-r1）" \
  "$T1 INSERT INTO source_identity_assessment (tenant_id, import_batch_id, batch_version,
        detected_identity, match_result, evidence_kind, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$B1',1,'[]'::jsonb,'UNVERIFIABLE','NONE','detect-r1')"
expect_err "冪等：source_identity_assessment 同鍵不得重複" \
  "$T1 INSERT INTO source_identity_assessment (tenant_id, import_batch_id, batch_version,
        detected_identity, match_result, evidence_kind, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$B1',1,'[]'::jsonb,'UNVERIFIABLE','NONE','detect-r1')" "duplicate key"

n=$(APP_C <<<"$T2 SELECT count(*) FROM background_job")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的背景工作" || ng "RLS：background_job 洩漏 $n 筆"

echo ""
echo "通過 $pass ／ 失敗 $fail"
[ $fail -eq 0 ]
