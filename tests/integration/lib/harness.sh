#!/usr/bin/env bash
# DB 整合測試共用底座：連線、斷言、計數、fixture。
#
# 兩種執行模式，同一份 fixture：
#   * 單跑（`bash tests/integration/db/basis.test.sh`）——自己重建資料庫並補齊前置，
#     日常只跑受影響的領域。
#   * 聚合（`tests/integration/db.test.sh`）——重建一次，依原順序執行各領域；
#     此時前置多半已由前面的區段建立，fixture 偵測到就跳過。
#
# fixture 一律**幂等**：先查再建。這樣同一個檔案在兩種模式下行為一致，
# 不需要兩套種子——兩套種子遲早會分岔，而分岔的那天沒有人會發現。

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$ROOT/scripts/env.sh"
DB="${DB_TEST_NAME:-cbfc_test}"

PSQL_C() { psql_run -d "$DB" "$@"; }
# app_runtime 身分（RLS 生效的那一邊）。PSQL_MODE=local 分支沿用原 db.test.sh 的寫法，
# 但本機未安裝 psql，**這條路徑未經實測**——要啟用 local 模式前先驗證它的認證方式。
APP_C() {
  if [ "$PSQL_MODE" = "docker" ]; then
    docker exec -i "$DB_CONTAINER" psql -v ON_ERROR_STOP=1 -qtA -U app_runtime -d "$DB" "$@"
  else
    psql -v ON_ERROR_STOP=1 -qtA -h "$DB_HOST" -p "$DB_PORT" -U app_runtime -d "$DB" "$@"
  fi
}

# 聚合模式由 db.test.sh 設定；未設定＝單跑
DB_TEST_AGGREGATE="${DB_TEST_AGGREGATE:-0}"
pass=${pass:-0}; fail=${fail:-0}
ok() { pass=$((pass+1)); echo "  PASS  $1"; }
ng() { fail=$((fail+1)); echo "  FAIL  $1"; }
expect_ok() { if out=$(PSQL_C <<<"$2" 2>&1); then ok "$1"; else ng "$1 → $out"; fi }
expect_err() {
  if out=$(PSQL_C <<<"$2" 2>&1); then ng "$1（不該成功卻成功了）"
  elif echo "$out" | grep -q "$3"; then ok "$1"
  else ng "$1 → 失敗原因不符：$out"; fi
}
summary() {
  echo ""
  echo "通過 $pass ／ 失敗 $fail"
  [ "$fail" -eq 0 ]
}

# ── 共用識別碼（兩種模式都要有，因此無條件指定） ──────────────
TEN=11111111-1111-1111-1111-111111111111
TEN2=22222222-2222-2222-2222-222222222222
T1="SET app.tenant_id = '$TEN';"
T2="SET app.tenant_id = '$TEN2';"
JIA=aaaaaaaa-0000-0000-0000-000000000001
YI=aaaaaaaa-0000-0000-0000-000000000002
BING=aaaaaaaa-0000-0000-0000-000000000003
ENG=eeeeeeee-0000-0000-0000-000000000001
ENG99=eeeeeeee-0000-0000-0000-000000000099
UNIT=bbbbbbbb-0000-0000-0000-000000000001
GRP_UNIT=bbbbbbbb-0000-0000-0000-000000000002
CAL=ffffffff-0000-0000-0000-000000000001
PR=99999999-0000-0000-0000-000000000001
GRP_PR=99999999-0000-0000-0000-000000000002
B1=00000000-0000-0000-0000-0000000000b1
B2=00000000-0000-0000-0000-0000000000b2
ACC1=ac000000-0000-0000-0000-000000000001
ACC2=ac000000-0000-0000-0000-000000000002
ACC99=ac000000-0000-0000-0000-000000000099
ADJ=ad000000-0000-0000-0000-000000000001
BASIS_A=20000000-0000-0000-0000-000000000001
BASIS_B=20000000-0000-0000-0000-000000000002
BASIS_C=20000000-0000-0000-0000-000000000003
LAYER_LB=10000000-0000-0000-0000-000000000001
LAYER_GG=10000000-0000-0000-0000-000000000003
LAYER_CONSOL=10000000-0000-0000-0000-000000000005
LAYER_TA=10000000-0000-0000-0000-000000000006
COMP_A=21000000-0000-0000-0000-000000000001
COMP_C=21000000-0000-0000-0000-000000000003
POL_OK=30000000-0000-0000-0000-000000000001
POL_DRAFT=30000000-0000-0000-0000-000000000002
ADJ_BRIDGE_COLS="basis_from_id, basis_to_id, posting_layer_id"
ADJ_BRIDGE_VALS="'$BASIS_A','$BASIS_C','$LAYER_GG'"
EVID="legal_basis='企業会計基準第29号', evidence_ref='attach-001.pdf', judgment_reason='集團政策', language_tag='ja-JP'"

# 表存在且有列＝該 fixture 已建立
_has() { [ "$(PSQL_C <<<"SELECT count(*) FROM $1 ${2:-}" 2>/dev/null)" != "0" ]; }

# ── fixture ───────────────────────────────────────────────────
fx_reset() {
  [ "$DB_TEST_AGGREGATE" = "1" ] && return 0
  bash "$ROOT/packages/database/src/db-reset.sh" "$DB" >/dev/null 2>&1 \
    || { echo "重建失敗"; exit 1; }
}

fx_core() {
  _has tenant && return 0
  PSQL_C >/dev/null <<SQL || { ng "fx_core 建立失敗（fail closed）"; exit 1; }
INSERT INTO tenant (tenant_id, name) VALUES ('$TEN','T1 事務所'),('$TEN2','T2 事務所');
SET app.tenant_id = '$TEN';
INSERT INTO app_user (user_id, tenant_id, email, display_name) VALUES
  ('$JIA','$TEN','staff@t1.jp','職員甲'),
  ('$YI','$TEN','senior@t1.jp','資深乙'),
  ('$BING','$TEN','manager@t1.jp','經理丙');
INSERT INTO app_user (user_id, tenant_id, email, display_name, is_active) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000005','$TEN','left@t1.jp','離職戊',false);
INSERT INTO app_user (user_id, tenant_id, email, display_name) VALUES
  ('a2222222-0000-0000-0000-000000000009','$TEN2','staff@t2.jp','T2 職員');
INSERT INTO client_engagement (engagement_id, tenant_id, name) VALUES ('$ENG','$TEN','A 客戶案件');
INSERT INTO role_assignment (tenant_id, user_id, role, engagement_id) VALUES
  ('$TEN','$JIA','R2','$ENG'),('$TEN','$YI','R2','$ENG'),
  ('$TEN','aaaaaaaa-0000-0000-0000-000000000005','R2','$ENG'),
  -- 丙持有 R1（政策指定的稅務確認角色）；甲乙在本案件但無 R1，
  -- 「確認人存在且在本案件、只是角色不符」因此可被單獨驗證
  ('$TEN','$BING','R1','$ENG');
INSERT INTO legal_entity (legal_entity_id, tenant_id, engagement_id, name, authoritative_code, country_code)
VALUES ('cccccccc-0000-0000-0000-000000000001','$TEN','$ENG','A 株式会社','1234567890123','JP');
INSERT INTO reporting_unit (reporting_unit_id, tenant_id, engagement_id, legal_entity_id, unit_scope, name) VALUES
  ('$UNIT','$TEN','$ENG','cccccccc-0000-0000-0000-000000000001','LEGAL_ENTITY','A 社'),
  ('$GRP_UNIT','$TEN','$ENG',NULL,'CONSOLIDATION_GROUP','A 集團');
INSERT INTO fiscal_calendar (fiscal_calendar_id, tenant_id, engagement_id, name, year_start_month)
VALUES ('$CAL','$TEN','$ENG','日本4月起',4);
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id, fiscal_calendar_id, label, start_date, end_date) VALUES
  ('dddddddd-0000-0000-0000-000000000001','$TEN','$ENG','$UNIT','$CAL','2026-03','2026-03-01','2026-03-31'),
  ('dddddddd-0000-0000-0000-000000000002','$TEN','$ENG','$GRP_UNIT','$CAL','2026-03G','2026-03-01','2026-03-31');
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id) VALUES
  ('$PR','$TEN','dddddddd-0000-0000-0000-000000000001'),
  ('$GRP_PR','$TEN','dddddddd-0000-0000-0000-000000000002');
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id, declared_period_revision_id, uploaded_by, provided_by)
VALUES ('$B1','$TEN','$ENG','cccccccc-0000-0000-0000-000000000001','$PR','$JIA','$JIA');
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id, declared_period_revision_id, uploaded_by, provided_by, status)
VALUES ('$B2','$TEN','$ENG','cccccccc-0000-0000-0000-000000000001','$PR','$JIA','$JIA','UPLOADED');
-- SLICE-M2-06 多基礎：層是平台主檔（0023 已種），基礎是案件內口徑
INSERT INTO basis_source_policy_version (basis_source_policy_version_id, policy_series_id, version_no,
        tenant_id, engagement_id, source_kind, confirmation_role, description, status,
        approved_by, approved_at, approval_role) VALUES
  ('$POL_OK','30000000-0000-0000-0000-000000000101',1,'$TEN','$ENG','TAX_WORKPAPER','R1',
   '稅務計算底稿','APPROVED','$BING',now(),'R4'),
  ('$POL_DRAFT','30000000-0000-0000-0000-000000000102',1,'$TEN','$ENG','TAX_RETURN','R1',
   '未批准政策（供負面測試）','DRAFT',NULL,NULL,NULL);
INSERT INTO book_basis (basis_id, tenant_id, engagement_id, code, jurisdiction, framework,
        source_mode, basis_source_policy_version_id, permits_group_layer) VALUES
  ('$BASIS_A','$TEN','$ENG','A','JP','JP_GAAP','COMPOSED',NULL,false),
  ('$BASIS_B','$TEN','$ENG','B','JP','JP_TAX','DIRECT_AUTHORITATIVE_IMPORT','$POL_OK',false),
  ('$BASIS_C','$TEN','$ENG','C','CN','CN_CAS','COMPOSED',NULL,true);
INSERT INTO basis_composition_version (basis_composition_version_id, composition_series_id,
        version_no, tenant_id, engagement_id, basis_id, status) VALUES
  ('$COMP_A','21000000-0000-0000-0000-000000000101',1,'$TEN','$ENG','$BASIS_A','DRAFT'),
  ('$COMP_C','21000000-0000-0000-0000-000000000103',1,'$TEN','$ENG','$BASIS_C','DRAFT');
INSERT INTO constitutive_layer_item (basis_composition_version_id, layer_id, sign) VALUES
  ('$COMP_A','$LAYER_LB',1),('$COMP_C','$LAYER_LB',1),('$COMP_C','$LAYER_GG',1);
UPDATE basis_composition_version SET status='APPROVED', approved_by='$BING',
       approved_at=now(), approval_role='R4' WHERE status='DRAFT';
SQL
}

fx_accounts() {
  _has chart_of_accounts && return 0
  PSQL_C >/dev/null <<SQL || { ng "fx_accounts 建立失敗（fail closed）"; exit 1; }
INSERT INTO chart_of_accounts (coa_id, tenant_id, engagement_id, name) VALUES
  ('88888888-0000-0000-0000-000000000001','$TEN','$ENG','集團科目表');
INSERT INTO account (account_id, tenant_id, coa_id, code, name) VALUES
  ('$ACC1','$TEN','88888888-0000-0000-0000-000000000001','1002','银行存款'),
  ('$ACC2','$TEN','88888888-0000-0000-0000-000000000001','6602','管理费用');
INSERT INTO client_engagement (engagement_id, tenant_id, name) VALUES ('$ENG99','$TEN','另一案件');
INSERT INTO chart_of_accounts (coa_id, tenant_id, engagement_id, name) VALUES
  ('88888888-0000-0000-0000-000000000099','$TEN','$ENG99','另一案件科目表');
INSERT INTO account (account_id, tenant_id, coa_id, code, name) VALUES
  ('$ACC99','$TEN','88888888-0000-0000-0000-000000000099','1002','银行存款');
SQL
}

fx_tb_lines() {
  _has source_ledger_line && return 0
  PSQL_C >/dev/null <<SQL || { ng "fx_tb_lines 建立失敗（fail closed）"; exit 1; }
INSERT INTO source_dataset (source_dataset_id, tenant_id, import_batch_id, batch_version, granularity, content_sha256, row_count)
VALUES ('77777777-0000-0000-0000-000000000001','$TEN','$B2',1,'BALANCE','h',2);
INSERT INTO source_ledger_line (tenant_id, source_dataset_id, import_batch_id, source_row_id, account_code, debit, credit, content_sha256) VALUES
 ('$TEN','77777777-0000-0000-0000-000000000001','$B2','r1','1100',1000.00,0,'h1'),
 ('$TEN','77777777-0000-0000-0000-000000000001','$B2','r2','4000',0,1000.00,'h2');
SQL
}

# 已批准並物化的調整：其他領域（計算、調節）需要它，但不應重複驗證它的守衛。
# 這裡刻意**靜默建立**——斷言留在 adjustment 領域檔，避免同一條規則被計兩次。
fx_adjustment_approved() {
  _has adjustment "WHERE adjustment_id='$ADJ'" && return 0
  fx_accounts
  PSQL_C >/dev/null <<SQL || { ng "fx_adjustment_approved 建立失敗（fail closed）"; exit 1; }
$T1
INSERT INTO adjustment (adjustment_id, tenant_id, engagement_id, period_revision_id, title, prepared_by,
                        $ADJ_BRIDGE_COLS, legal_basis, evidence_ref, judgment_reason, language_tag)
VALUES ('$ADJ','$TEN','$ENG','$PR','GROUP_GAAP 調整','$JIA',
        $ADJ_BRIDGE_VALS,'企業会計基準第29号','attach-001.pdf','集團政策','ja-JP');
INSERT INTO adjustment_line (tenant_id, adjustment_id, line_no, target_account_id, debit, credit) VALUES
  ('$TEN','$ADJ',1,'$ACC1',1234.56,0),('$TEN','$ADJ',2,'$ACC2',0,1234.56);
UPDATE adjustment SET status='PENDING_REVIEW', business_version=2 WHERE adjustment_id='$ADJ';
UPDATE adjustment SET status='PENDING_APPROVAL', reviewed_by='$YI', reviewed_at=now(),
       business_version=3 WHERE adjustment_id='$ADJ';
UPDATE adjustment SET status='APPROVED', approved_by='$BING', approved_at=now(),
       business_version=4 WHERE adjustment_id='$ADJ';
INSERT INTO journal_entry (entry_id, tenant_id, engagement_id, period_revision_id, adjustment_id,
        business_version, entry_date, posting_layer_id)
VALUES ('be000000-0000-0000-0000-000000000001','$TEN','$ENG','$PR','$ADJ',4,'2026-03-31','$LAYER_GG');
INSERT INTO journal_line (tenant_id, entry_id, line_no, account_id, debit, credit) VALUES
  ('$TEN','be000000-0000-0000-0000-000000000001',1,'$ACC1',1234.56,0),
  ('$TEN','be000000-0000-0000-0000-000000000001',2,'$ACC2',0,1234.56);
SQL
}

# 0023 之前語意的 run（manifest 不含 BASIS_COMPOSITION）——分層版本界線的對照組
MANI=ee110000-0000-0000-0000-000000000001
MANI2=ee110000-0000-0000-0000-000000000002
RUNA=ee110000-0000-0000-0000-000000000011
RUNB=ee110000-0000-0000-0000-000000000012
fx_calc_runs() {
  _has calculation_run "WHERE calculation_run_id='$RUNA'" && return 0
  fx_accounts
  PSQL_C >/dev/null <<SQL || { ng "fx_calc_runs 建立失敗（fail closed）"; exit 1; }
$T1
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by) VALUES
  ('$MANI','$TEN','$ENG','$PR','NO_FX','sqlcanon-1','h0','$JIA'),
  ('$MANI2','$TEN','$ENG','$PR','NO_FX','sqlcanon-1','h0','$JIA');
INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, domain_version_kind,
        domain_version_value, content_canonical, content_hash, payload)
VALUES ('$TEN','$MANI','SCOPE','SCOPE','1','c','h','{}'::jsonb);
INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, request_key, request_content_hash, engine_version, created_by)
VALUES ('$RUNA','$TEN','$ENG','$PR','$B1','$MANI','PREVIEW',
        'ee110000-0000-0000-0000-0000000000a1','rc1','calc-engine-1','$JIA');
INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, replay_of_run_id, request_key, request_content_hash, engine_version, created_by)
VALUES ('$RUNB','$TEN','$ENG','$PR','$B1','$MANI','PREVIEW','$RUNA',
        'ee110000-0000-0000-0000-0000000000a2','REPLAY|$RUNA','calc-engine-1','$JIA');
INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit)
VALUES ('$TEN','$RUNA','SOURCE_TB','$ACC1','1002','银行存款',100.00,0);
SQL
}

# need fx_a fx_b …：宣告本領域的前置，順序即依賴順序
need() { for f in "$@"; do "$f"; done; }
