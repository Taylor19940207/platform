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
INSERT INTO source_dataset (source_dataset_id, tenant_id, import_batch_id, granularity, content_sha256, row_count)
VALUES ('77777777-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','$B1','BALANCE','h',2);
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

n=$(APP_C <<<"$T2 SELECT count(*) FROM adjustment")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的調整" || ng "RLS：adjustment 洩漏 $n 筆"
n=$(APP_C <<<"$T2 SELECT count(*) FROM journal_line")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的正式分錄" || ng "RLS：journal_line 洩漏 $n 筆"

echo ""
echo "通過 $pass ／ 失敗 $fail"
[ $fail -eq 0 ]
