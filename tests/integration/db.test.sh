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
PSQL_C <<'SQL' >/dev/null || { ng "種子資料建立失敗（fail closed）"; exit 1; }
INSERT INTO tenant (tenant_id, name) VALUES
  ('11111111-1111-1111-1111-111111111111','T1 事務所'),
  ('22222222-2222-2222-2222-222222222222','T2 事務所');
SET app.tenant_id = '11111111-1111-1111-1111-111111111111';
INSERT INTO app_user (user_id, tenant_id, email, display_name) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','staff@t1.jp','職員甲'),
  ('aaaaaaaa-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','senior@t1.jp','資深乙'),
  ('aaaaaaaa-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','manager@t1.jp','經理丙');
INSERT INTO app_user (user_id, tenant_id, email, display_name, is_active) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000005','11111111-1111-1111-1111-111111111111','left@t1.jp','離職戊',false);
INSERT INTO app_user (user_id, tenant_id, email, display_name) VALUES
  ('a2222222-0000-0000-0000-000000000009','22222222-2222-2222-2222-222222222222','staff@t2.jp','T2 職員');
INSERT INTO client_engagement (engagement_id, tenant_id, name) VALUES
  ('eeeeeeee-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','A 客戶案件');
INSERT INTO role_assignment (tenant_id, user_id, role, engagement_id) VALUES
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','R2','eeeeeeee-0000-0000-0000-000000000001'),
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000002','R2','eeeeeeee-0000-0000-0000-000000000001'),
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000005','R2','eeeeeeee-0000-0000-0000-000000000001');
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
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id, declared_period_revision_id, uploaded_by, provided_by, status) VALUES
  ('00000000-0000-0000-0000-0000000000b2','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','UPLOADED');
-- ── SLICE-M2-06 多基礎種子 ──
-- 丙持有 R1（政策指定的稅務確認角色）；甲乙在本案件但只有 R2——
-- 「確認人存在且在本案件、只是角色不符」因此可被單獨驗證。
INSERT INTO role_assignment (tenant_id, user_id, role, engagement_id) VALUES
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000003','R1','eeeeeeee-0000-0000-0000-000000000001');
-- 群組單位：INV-03（層 scope × 單位型別）需要一個 CONSOLIDATION_GROUP 才驗得到
INSERT INTO reporting_unit (reporting_unit_id, tenant_id, engagement_id, legal_entity_id, unit_scope, name) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',NULL,'CONSOLIDATION_GROUP','A 集團');
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id, fiscal_calendar_id, label, start_date, end_date) VALUES
  ('dddddddd-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000002','ffffffff-0000-0000-0000-000000000001','2026-03G','2026-03-01','2026-03-31');
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id) VALUES
  ('99999999-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','dddddddd-0000-0000-0000-000000000002');
INSERT INTO basis_source_policy_version (basis_source_policy_version_id, policy_series_id, version_no,
        tenant_id, engagement_id, source_kind, confirmation_role, description, status,
        approved_by, approved_at, approval_role) VALUES
  ('30000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000101',1,
   '11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
   'TAX_WORKPAPER','R1','稅務計算底稿','APPROVED','aaaaaaaa-0000-0000-0000-000000000003',now(),'R4'),
  ('30000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000102',1,
   '11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
   'TAX_RETURN','R1','未批准政策（供負面測試）','DRAFT',NULL,NULL,NULL);
INSERT INTO book_basis (basis_id, tenant_id, engagement_id, code, jurisdiction, framework,
        source_mode, basis_source_policy_version_id, permits_group_layer) VALUES
  ('20000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','A','JP','JP_GAAP','COMPOSED',NULL,false),
  ('20000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','B','JP','JP_TAX','DIRECT_AUTHORITATIVE_IMPORT','30000000-0000-0000-0000-000000000001',false),
  ('20000000-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','C','CN','CN_CAS','COMPOSED',NULL,true);
INSERT INTO basis_composition_version (basis_composition_version_id, composition_series_id,
        version_no, tenant_id, engagement_id, basis_id, status) VALUES
  ('21000000-0000-0000-0000-000000000001','21000000-0000-0000-0000-000000000101',1,'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','DRAFT'),
  ('21000000-0000-0000-0000-000000000003','21000000-0000-0000-0000-000000000103',1,'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000003','DRAFT');
INSERT INTO constitutive_layer_item (basis_composition_version_id, layer_id, sign) VALUES
  ('21000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',1),
  ('21000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001',1),
  ('21000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003',1);
UPDATE basis_composition_version SET status='APPROVED',
       approved_by='aaaaaaaa-0000-0000-0000-000000000003', approved_at=now(), approval_role='R4'
 WHERE status='DRAFT';
SQL
ok "種子資料建立（2 租戶、1 案件、1 批次、A/B/C 三基礎）"

B1=00000000-0000-0000-0000-0000000000b1
B2=00000000-0000-0000-0000-0000000000b2
T1="SET app.tenant_id = '11111111-1111-1111-1111-111111111111';"
T2="SET app.tenant_id = '22222222-2222-2222-2222-222222222222';"

# ── RLS（§24.9／INV-18） ────────────────────────────
n=$(APP_C <<<"$T1 SELECT count(*) FROM import_batch")
[ "$n" = "2" ] && ok "RLS：T1 看得到自己的批次（B1＋B2）" || ng "RLS：T1 應看到 2 筆，得到 $n"
n=$(APP_C <<<"$T2 SELECT count(*) FROM import_batch")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的批次" || ng "RLS：T2 應看到 0 筆，得到 $n"
if APP_C >/dev/null 2>&1 <<<"$T2 INSERT INTO import_batch (tenant_id, engagement_id, declared_legal_entity_id, declared_period_revision_id) VALUES ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001','99999999-0000-0000-0000-000000000001')"
then ng "RLS：T2 竟可寫入 T1 資料"; else ok "RLS：T2 無法寫入 T1 資料（WITH CHECK）"; fi
n=$(APP_C 2>/dev/null <<<"SELECT count(*) FROM import_batch")
[ "$n" = "0" ] && ok "RLS：未設定 tenant 時看不到任何資料" || ng "RLS：未設定 tenant 竟看到 $n 筆"

# ── 主狀態機（§25.5）＋ identity 遷移白名單（0019） ────────
expect_err "狀態機：DRAFT 不可直接跳 VALIDATED" \
  "UPDATE import_batch SET status='VALIDATED' WHERE import_batch_id='$B1'" "非法狀態遷移"
expect_ok  "狀態機：DRAFT → UPLOADED" \
  "UPDATE import_batch SET status='UPLOADED', file_name='tb.csv', file_sha256='abc' WHERE import_batch_id='$B1'"
expect_err "0019：identity 判定不得於 UPLOADED 階段寫入（僅 VALIDATING）" \
  "UPDATE import_batch SET identity_status='MATCHED' WHERE import_batch_id='$B1'" "VALIDATING 階段"
expect_ok  "狀態機：UPLOADED → VALIDATING" \
  "UPDATE import_batch SET status='VALIDATING' WHERE import_batch_id='$B1'"
expect_err "0020：判定未與 current 指標成對 → 拒絕（無 Assessment 的 MATCHED 不存在）" \
  "UPDATE import_batch SET identity_status='MATCHED' WHERE import_batch_id='$B1'" "成對"
AM1=a1110000-0000-0000-0000-000000000001
APU1=a1110000-0000-0000-0000-000000000002
PSQL_C <<SQL >/dev/null || { ng "B1 評估種子建立失敗（fail closed）"; exit 1; }
INSERT INTO source_identity_assessment (assessment_id, tenant_id, import_batch_id, batch_version, match_result, evidence_kind, detection_rule_version) VALUES
  ('$AM1','11111111-1111-1111-1111-111111111111','$B1',1,'MATCH','AUTHORITATIVE_ID','m1'),
  ('$APU1','11111111-1111-1111-1111-111111111111','$B1',1,'UNVERIFIABLE','NONE','m2');
SQL
expect_err "0020：判定與 assessment 結果不對應（MATCHED ↔ UNVERIFIABLE）" \
  "UPDATE import_batch SET identity_status='MATCHED', current_identity_assessment_id='$APU1' WHERE import_batch_id='$B1'" "不對應"
expect_ok  "判定於 VALIDATING 與 current 指標成對寫入（worker 唯一合法路徑）" \
  "UPDATE import_batch SET identity_status='MATCHED', current_identity_assessment_id='$AM1' WHERE import_batch_id='$B1';
   UPDATE import_batch SET status='VALIDATED' WHERE import_batch_id='$B1'"
expect_err "0020：判定後 current 指標不可改寫" \
  "UPDATE import_batch SET current_identity_assessment_id='$APU1' WHERE import_batch_id='$B1'" "成對寫入"
expect_err "0019：已判定不得改寫（MATCHED → CONFLICT 拒絕）" \
  "UPDATE import_batch SET identity_status='CONFLICT' WHERE import_batch_id='$B1'" "非法 identity"

# ── G-01／INV-28（CR-002） ──────────────────────────
expect_ok  "評估：權威識別符 CONFLICT 可寫入" \
  "INSERT INTO source_identity_assessment (tenant_id, import_batch_id, batch_version, match_result, evidence_kind, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$B1',1,'CONFLICT','AUTHORITATIVE_ID','r1')"
expect_err "證據分級：模糊名稱不得產生 CONFLICT" \
  "INSERT INTO source_identity_assessment (tenant_id, import_batch_id, batch_version, match_result, evidence_kind, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$B1',1,'CONFLICT','FUZZY_NAME','r1')" "violates check"
expect_err "INV-28：MATCHED 但雜湊未驗證仍不得 ACCEPTED" \
  "UPDATE import_batch SET status='ACCEPTED', hash_verified=false WHERE import_batch_id='$B1'" "G-01/INV-28"
expect_ok  "G-01：三條件齊備 → ACCEPTED 成功" \
  "UPDATE import_batch SET status='ACCEPTED', hash_verified=true WHERE import_batch_id='$B1'"
expect_err "INV-08：SUPERSEDED 必須指向替代批次" \
  "UPDATE import_batch SET status='SUPERSEDED' WHERE import_batch_id='$B1'" "INV-08"
# NOT_CHECKED／CONFLICT 阻擋——各用專用批次（identity 白名單下不可事後改寫）
BN=00000000-0000-0000-0000-0000000000b3
BC=00000000-0000-0000-0000-0000000000b4
PSQL_C >/dev/null <<SQL
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id, declared_period_revision_id, uploaded_by, provided_by, file_name, file_sha256, status) VALUES
  ('$BN','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','n.csv','hn','UPLOADED'),
  ('$BC','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','c.csv','hc','UPLOADED');
UPDATE import_batch SET status='VALIDATING' WHERE import_batch_id='$BN';
UPDATE import_batch SET status='VALIDATED'  WHERE import_batch_id='$BN';
UPDATE import_batch SET status='VALIDATING' WHERE import_batch_id='$BC';
SQL
expect_err "0020：current assessment 屬其他批次 → 拒絕" \
  "UPDATE import_batch SET identity_status='CONFLICT', current_identity_assessment_id='$AM1' WHERE import_batch_id='$BC'" "歸屬違規"
ACX=a1110000-0000-0000-0000-000000000003
PSQL_C <<SQL >/dev/null || { ng "BC 評估種子建立失敗（fail closed）"; exit 1; }
INSERT INTO source_identity_assessment (assessment_id, tenant_id, import_batch_id, batch_version, match_result, evidence_kind, detection_rule_version)
VALUES ('$ACX','11111111-1111-1111-1111-111111111111','$BC',1,'CONFLICT','AUTHORITATIVE_ID','c1');
UPDATE import_batch SET identity_status='CONFLICT', current_identity_assessment_id='$ACX' WHERE import_batch_id='$BC';
UPDATE import_batch SET status='VALIDATED'  WHERE import_batch_id='$BC';
SQL
expect_err "INV-28：identity_status=NOT_CHECKED 不得 ACCEPTED" \
  "UPDATE import_batch SET status='ACCEPTED', hash_verified=true WHERE import_batch_id='$BN'" "G-01/INV-28"
expect_err "INV-28：identity_status=CONFLICT 不得 ACCEPTED（硬性、無豁免）" \
  "UPDATE import_batch SET status='ACCEPTED', hash_verified=true WHERE import_batch_id='$BC'" "G-01/INV-28"

# ── SOD-07 ＋ 0019 Resolution 防繞過 ─────────────────
BU=00000000-0000-0000-0000-0000000000b5
BW=00000000-0000-0000-0000-0000000000b6
AU=aa110000-0000-0000-0000-000000000001
AU2=aa110000-0000-0000-0000-000000000002
AM=aa110000-0000-0000-0000-000000000003
AW=aa110000-0000-0000-0000-000000000004
expect_ok "0019 前置：UNVERIFIABLE 批次（worker 路徑：VALIDATING 寫入評估＋current 指標）" \
  "INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id, declared_period_revision_id, uploaded_by, provided_by, file_name, file_sha256, status) VALUES
    ('$BU','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','u.csv','hu','UPLOADED');
   UPDATE import_batch SET status='VALIDATING' WHERE import_batch_id='$BU';
   INSERT INTO source_identity_assessment (assessment_id, tenant_id, import_batch_id, batch_version, match_result, evidence_kind, detection_rule_version)
   VALUES ('$AU','11111111-1111-1111-1111-111111111111','$BU',1,'UNVERIFIABLE','NONE','r1');
   UPDATE import_batch SET identity_status='PENDING_CONFIRMATION', current_identity_assessment_id='$AU' WHERE import_batch_id='$BU';
   UPDATE import_batch SET status='VALIDATED' WHERE import_batch_id='$BU'"
expect_err "0019：無 Resolution 不得直接改寫為 MANUALLY_RESOLVED" \
  "UPDATE import_batch SET identity_status='MANUALLY_RESOLVED' WHERE import_batch_id='$BU'" "必須先有"
PSQL_C >/dev/null <<<"INSERT INTO source_identity_assessment (assessment_id, tenant_id, import_batch_id, batch_version, match_result, evidence_kind, detection_rule_version)
   VALUES ('$AU2','11111111-1111-1111-1111-111111111111','$BU',1,'UNVERIFIABLE','NONE','r2')"
expect_err "0019：非 current assessment 不可確認（重解析後舊評估不沿用）" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$AU2','$BU',1,'aaaaaaaa-0000-0000-0000-000000000002','R2','x','r2')" "current"
expect_err "0019：batch_version 三方不一致拒絕" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$AU','$BU',2,'aaaaaaaa-0000-0000-0000-000000000002','R2','x','r1')" "三方不一致"
PSQL_C >/dev/null <<<"INSERT INTO source_identity_assessment (assessment_id, tenant_id, import_batch_id, batch_version, match_result, evidence_kind, detection_rule_version)
   VALUES ('$AM','11111111-1111-1111-1111-111111111111','$BU',1,'MATCH','AUTHORITATIVE_ID','r3')"
expect_err "0019：非 UNVERIFIABLE 評估不可人工確認" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$AM','$BU',1,'aaaaaaaa-0000-0000-0000-000000000002','R2','x','r1')" "UNVERIFIABLE"
A1=$(PSQL_C <<<"SELECT assessment_id FROM source_identity_assessment WHERE import_batch_id='$B1' AND match_result='CONFLICT' LIMIT 1")
expect_err "0019：assessment 屬其他批次拒絕" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$A1','$BU',1,'aaaaaaaa-0000-0000-0000-000000000002','R2','x','r1')" "屬其他批次"
expect_err "SOD-07：上傳者不得確認自己上傳的批次（角色切換無效）" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$AU','$BU',1,'aaaaaaaa-0000-0000-0000-000000000001','R2','看起來沒問題','r1')" "SOD-07"
expect_err "0019：無該案件有效 R2 指派者不可確認（資料接受角色）" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$AU','$BU',1,'aaaaaaaa-0000-0000-0000-000000000003','R2','x','r1')" "R2 指派"
expect_err "0020：acting_role 偽造為 R4 → 拒絕（資料接受角色＝R2）" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$AU','$BU',1,'aaaaaaaa-0000-0000-0000-000000000002','R4','x','r1')" "acting_role"
expect_err "0020：理由全空白 → 拒絕（不可變紀錄必須有實質理由）" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$AU','$BU',1,'aaaaaaaa-0000-0000-0000-000000000002','R2','   ','r1')" "空"
expect_err "0020：規則版本與所選 assessment 不符 → 拒絕" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$AU','$BU',1,'aaaaaaaa-0000-0000-0000-000000000002','R2','x','FAKE-RULE')" "規則版本"
expect_err "0020：停用使用者不可確認（戊：仍有 R2 指派但 is_active=false）" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$AU','$BU',1,'aaaaaaaa-0000-0000-0000-000000000005','R2','x','r1')" "啟用"
expect_err "0020：他租戶使用者不可確認（resolved_by 屬 T2）" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$AU','$BU',1,'a2222222-0000-0000-0000-000000000009','R2','x','r1')" "啟用"
expect_ok  "SOD-07：另一個自然人（乙，R2）可以確認" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$AU','$BU',1,'aaaaaaaa-0000-0000-0000-000000000002','R2','已向客戶電話確認為 A 社','r1')"
expect_err "確認不可覆寫（同一評估只能有一筆）" \
  "INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$AU','$BU',1,'aaaaaaaa-0000-0000-0000-000000000002','R2','改個理由','r1')" "duplicate key"
expect_err "確認紀錄不可 UPDATE" \
  "UPDATE source_identity_resolution SET reason='改掉' WHERE assessment_id='$AU'" "不可變"
expect_ok  "0019：有 Resolution 後 PENDING_CONFIRMATION → MANUALLY_RESOLVED" \
  "UPDATE import_batch SET identity_status='MANUALLY_RESOLVED' WHERE import_batch_id='$BU'"
expect_ok  "G-01：MANUALLY_RESOLVED＋雜湊 → ACCEPTED（確認與接受分離）" \
  "UPDATE import_batch SET hash_verified=true WHERE import_batch_id='$BU';
   UPDATE import_batch SET status='ACCEPTED' WHERE import_batch_id='$BU'"
expect_err "0019：狀態白名單——VALIDATING 中的批次不可確認（需 VALIDATED）" \
  "INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id, declared_period_revision_id, uploaded_by, provided_by, file_name, file_sha256, status) VALUES
    ('$BW','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001','99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','w.csv','hw','UPLOADED');
   UPDATE import_batch SET status='VALIDATING' WHERE import_batch_id='$BW';
   INSERT INTO source_identity_assessment (assessment_id, tenant_id, import_batch_id, batch_version, match_result, evidence_kind, detection_rule_version)
   VALUES ('$AW','11111111-1111-1111-1111-111111111111','$BW',1,'UNVERIFIABLE','NONE','r1');
   UPDATE import_batch SET identity_status='PENDING_CONFIRMATION', current_identity_assessment_id='$AW' WHERE import_batch_id='$BW';
   INSERT INTO source_identity_resolution (tenant_id, assessment_id, import_batch_id, batch_version, resolved_by, acting_role, reason, detection_rule_version)
   VALUES ('11111111-1111-1111-1111-111111111111','$AW','$BW',1,'aaaaaaaa-0000-0000-0000-000000000002','R2','x','r1')" "不允許確認"

# ── 不可變性與借貸平衡 ─────────────────────────────
PSQL_C >/dev/null <<SQL
INSERT INTO source_dataset (source_dataset_id, tenant_id, import_batch_id, batch_version, granularity, content_sha256, row_count)
VALUES ('77777777-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','$B2',1,'BALANCE','h',2);
INSERT INTO source_ledger_line (tenant_id, source_dataset_id, import_batch_id, source_row_id, account_code, debit, credit, content_sha256) VALUES
 ('11111111-1111-1111-1111-111111111111','77777777-0000-0000-0000-000000000001','$B2','r1','1100',1000.00,0,'h1'),
 ('11111111-1111-1111-1111-111111111111','77777777-0000-0000-0000-000000000001','$B2','r2','4000',0,1000.00,'h2');
SQL
bal=$(PSQL_C <<<"SELECT fn_tb_balance('$B2')")
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
# 第三個自然人（丙）已於主種子建立——AC-WFL-001 需要三人互異

JIA=aaaaaaaa-0000-0000-0000-000000000001
YI=aaaaaaaa-0000-0000-0000-000000000002
BING=aaaaaaaa-0000-0000-0000-000000000003
ENG=eeeeeeee-0000-0000-0000-000000000001
PR=99999999-0000-0000-0000-000000000001
ACC1=ac000000-0000-0000-0000-000000000001
ACC2=ac000000-0000-0000-0000-000000000002
ADJ=ad000000-0000-0000-0000-000000000001
# SLICE-M2-06 多基礎：A→C 橋樑 ＋ GROUP_GAAP_ADJ 分層（種子建立，UUID 固定）
BASIS_A=20000000-0000-0000-0000-000000000001
BASIS_B=20000000-0000-0000-0000-000000000002
BASIS_C=20000000-0000-0000-0000-000000000003
LAYER_GG=10000000-0000-0000-0000-000000000003
LAYER_CONSOL=10000000-0000-0000-0000-000000000005
ADJ_BRIDGE_COLS="basis_from_id, basis_to_id, posting_layer_id"
ADJ_BRIDGE_VALS="'$BASIS_A','$BASIS_C','$LAYER_GG'"
EVID="legal_basis='企業会計基準第29号', evidence_ref='attach-001.pdf', judgment_reason='集團政策', language_tag='ja-JP'"

expect_ok "調整：建立草稿（prepared_by 甲）" \
  "$T1 INSERT INTO adjustment (adjustment_id, tenant_id, engagement_id, period_revision_id, title, prepared_by,
                              basis_from_id, basis_to_id, posting_layer_id)
   VALUES ('$ADJ','11111111-1111-1111-1111-111111111111','$ENG','$PR','GROUP_GAAP 調整','$JIA',
           '$BASIS_A','$BASIS_C','$LAYER_GG')"
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
  "$T1 INSERT INTO journal_entry (tenant_id, engagement_id, period_revision_id, adjustment_id, business_version, entry_date, posting_layer_id)
   VALUES ('11111111-1111-1111-1111-111111111111','$ENG','$PR','$ADJ',3,'2026-03-31','$LAYER_GG')" "只在 APPROVED 後物化"
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
  "$T1 INSERT INTO journal_entry (entry_id, tenant_id, engagement_id, period_revision_id, adjustment_id, business_version, entry_date, posting_layer_id)
   VALUES ('be000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','$ENG','$PR','$ADJ',4,'2026-03-31','$LAYER_GG');
   INSERT INTO journal_line (tenant_id, entry_id, line_no, account_id, debit, credit) VALUES
     ('11111111-1111-1111-1111-111111111111','be000000-0000-0000-0000-000000000001',1,'$ACC1',1234.56,0),
     ('11111111-1111-1111-1111-111111111111','be000000-0000-0000-0000-000000000001',2,'$ACC2',0,1234.56)"
expect_err "物化版本一致：business_version 不符 → 拒絕" \
  "$T1 INSERT INTO journal_entry (tenant_id, engagement_id, period_revision_id, adjustment_id, business_version, entry_date, posting_layer_id)
   VALUES ('11111111-1111-1111-1111-111111111111','$ENG','$PR','$ADJ',9,'2026-03-31','$LAYER_GG')" "須與調整當下版本"
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
                        basis_from_id, basis_to_id, posting_layer_id,
                        legal_basis, evidence_ref, judgment_reason, language_tag)
VALUES ('$ADJ2','11111111-1111-1111-1111-111111111111','$ENG','$PR','退回測試','$JIA',
        '$BASIS_A','$BASIS_C','$LAYER_GG',
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
                        basis_from_id, basis_to_id, posting_layer_id,
                        legal_basis, evidence_ref, judgment_reason, language_tag)
VALUES ('$ADJ3','11111111-1111-1111-1111-111111111111','$ENG','$PR','繞過測試','$JIA',
        '$BASIS_A','$BASIS_C','$LAYER_GG',
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
PSQL_C <<'SQL' >/dev/null || { ng "跨租戶測試種子建立失敗（fail closed）"; exit 1; }
SET app.tenant_id = '22222222-2222-2222-2222-222222222222';
INSERT INTO client_engagement (engagement_id, tenant_id, name) VALUES
  ('e2222222-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','T2 案件');
INSERT INTO app_user (user_id, tenant_id, email, display_name) VALUES
  ('a2222222-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','x@t2.jp','T2 使用者');
SQL
ok "跨租戶測試種子（T2 案件與使用者）"

expect_err "INV-18：tenant_id=T1 但案件屬 T2 → 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by, $ADJ_BRIDGE_COLS)
   VALUES ('11111111-1111-1111-1111-111111111111','e2222222-0000-0000-0000-000000000001','$PR','跨租戶','$JIA',$ADJ_BRIDGE_VALS)" \
  "案件（.*）不屬於本租戶"
expect_err "INV-18：編製人屬 T2 → 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by, $ADJ_BRIDGE_COLS)
   VALUES ('11111111-1111-1111-1111-111111111111','$ENG','$PR','跨租戶','a2222222-0000-0000-0000-000000000001',$ADJ_BRIDGE_VALS)" \
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
PSQL_C <<'SQL' >/dev/null || { ng "同租戶第二案件種子建立失敗（fail closed）"; exit 1; }
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
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by, $ADJ_BRIDGE_COLS)
   VALUES ('11111111-1111-1111-1111-111111111111','$ENG','$PR99','跨案件期間','$JIA',$ADJ_BRIDGE_VALS)" "與調整的案件"
expect_err "歸屬凍結：建立後不可改 engagement_id" \
  "$T1 UPDATE adjustment SET engagement_id='eeeeeeee-0000-0000-0000-000000000099'
   WHERE adjustment_id='$ADJ2'" "歸屬與分類欄位建立後不可變更"
expect_err "歸屬凍結：建立後不可改 period_revision_id" \
  "$T1 UPDATE adjustment SET period_revision_id='$PR99' WHERE adjustment_id='$ADJ2'" "不可變更"
expect_err "歸屬凍結：建立後不可改 basis_to／materiality" \
  "$T1 UPDATE adjustment SET basis_to_id='$BASIS_B', materiality='MAJOR', tenant_id='22222222-2222-2222-2222-222222222222'
   WHERE adjustment_id='$ADJ2'" "不可變更"
expect_err "§24.1A：正式分錄的案件與來源調整不一致 → 拒絕" \
  "$T1 INSERT INTO journal_entry (tenant_id, engagement_id, period_revision_id, adjustment_id, business_version, entry_date, posting_layer_id)
   VALUES ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000099','$PR','$ADJ',4,'2026-03-31','$LAYER_GG')" \
  "案件（.*）與來源調整的案件"
expect_err "§24.1A：正式分錄的期間與來源調整不一致 → 拒絕" \
  "$T1 INSERT INTO journal_entry (tenant_id, engagement_id, period_revision_id, adjustment_id, business_version, entry_date, posting_layer_id)
   VALUES ('11111111-1111-1111-1111-111111111111','$ENG','$PR99','$ADJ',4,'2026-03-31','$LAYER_GG')" \
  "期間（.*）與來源調整的期間"
expect_err "§24.1A：正式分錄的科目屬同租戶另一案件 → 拒絕" \
  "$T1 INSERT INTO journal_line (tenant_id, entry_id, line_no, account_id, debit, credit)
   VALUES ('11111111-1111-1111-1111-111111111111','be000000-0000-0000-0000-000000000001',9,'$ACC99',1,0)" \
  "與來源調整的案件"
ADJ4=ad000000-0000-0000-0000-000000000004
if ! PSQL_C <<SQL >/dev/null 2>&1
$T1
INSERT INTO adjustment (adjustment_id, tenant_id, engagement_id, period_revision_id, title, prepared_by,
                        $ADJ_BRIDGE_COLS, legal_basis, evidence_ref, judgment_reason, language_tag)
VALUES ('$ADJ4','11111111-1111-1111-1111-111111111111','$ENG','$PR','時間戳測試','$JIA',
        $ADJ_BRIDGE_VALS,'a','b','c','ja-JP');
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
# 快照只能寫入 RUNNING 的 run（0013 ②）——寫入須在 RUNA 完成之前
expect_ok "快照輸出建立（run 內 層×科目 唯一；run 仍 RUNNING）" \
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
expect_err "0013①：Manifest 已封存（有 Run 引用）不得追加 entry" \
  "$T1 INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, domain_version_kind,
        domain_version_value, content_canonical, content_hash, payload)
   VALUES ('11111111-1111-1111-1111-111111111111','$MANI','SCOPE','SCOPE','2','c2','h2','{}'::jsonb)" "封存"
expect_err "0013③：entry 與 Manifest 不同租戶 → 拒絕" \
  "$T1 INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, domain_version_kind,
        domain_version_value, content_canonical, content_hash, payload)
   VALUES ('22222222-2222-2222-2222-222222222222','$MANI2','SCOPE','SCOPE','1','c','h','{}'::jsonb)" "不同租戶"
expect_err "0013③：快照與 Run 不同租戶 → 拒絕" \
  "$T1 INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit)
   VALUES ('22222222-2222-2222-2222-222222222222','$RUNA','ADJUSTMENT','ac000000-0000-0000-0000-000000000002',
           '6602','管理费用',1,0)" "不同租戶"
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
expect_err "0013②：終態 Run 不得追加快照（result hash 固定後結果不可再變）" \
  "$T1 INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit)
   VALUES ('11111111-1111-1111-1111-111111111111','$RUNA','ADJUSTMENT','ac000000-0000-0000-0000-000000000002',
           '6602','管理费用',1,0)" "不得追加結果"
RUNC=ee110000-0000-0000-0000-000000000013
MANI3=ee110000-0000-0000-0000-000000000003
expect_ok "前置：RUNC（MANI2 的原始 run）與 MANI3" \
  "$T1 INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, request_key, request_content_hash, engine_version, created_by)
   VALUES ('$RUNC','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '99999999-0000-0000-0000-000000000001','$B1','$MANI2','PREVIEW',
           'ee110000-0000-0000-0000-0000000000a3','rc6','calc-engine-1','aaaaaaaa-0000-0000-0000-000000000001');
   INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
   VALUES ('$MANI3','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '99999999-0000-0000-0000-000000000001','NO_FX','sqlcanon-2','h3','aaaaaaaa-0000-0000-0000-000000000001')"
expect_err "0013 終態互斥：COMPLETED 不得帶失敗欄位" \
  "$T1 UPDATE calculation_run SET status='COMPLETED', result_content_hash='r',
       failure_reason_code='X', failure_reason='y' WHERE calculation_run_id='$RUNC'" "互斥"
expect_err "0013 終態互斥：FAILED 不得帶結果欄位" \
  "$T1 UPDATE calculation_run SET status='FAILED', failure_reason_code='NON_RETRYABLE_SYSTEM',
       failure_reason='x', result_content_hash='r' WHERE calculation_run_id='$RUNC'" "互斥"
expect_err "0013 建立時不得預填終態欄位" \
  "$T1 INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, request_key, request_content_hash, engine_version,
        created_by, completed_at)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '99999999-0000-0000-0000-000000000001','$B1','$MANI3','PREVIEW',
           gen_random_uuid(),'rc7','calc-engine-1','aaaaaaaa-0000-0000-0000-000000000001', now())" "預填"
expect_err "0013③：Run 與 Manifest 案件不一致 → 拒絕（§24.1A）" \
  "$T1 INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, request_key, request_content_hash, engine_version, created_by)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000099',
           '99999999-0000-0000-0000-000000000001','$B1','$MANI3','PREVIEW',
           gen_random_uuid(),'rc8','calc-engine-1','aaaaaaaa-0000-0000-0000-000000000001')" "歸屬違規"
n=$(PSQL_C <<<"SELECT count(*) FROM pg_constraint WHERE conname='calculation_run_tenant_request_key_uq'")
[ "$n" = "1" ] && ok "0013：request_key 唯一改為（tenant_id, request_key）" \
               || ng "request_key 約束未改名（$n）"
expect_ok "BackgroundJob 支援 CALCULATION_RUN 型別" \
  "$T1 INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version, rule_version, idempotency_key)
   VALUES ('11111111-1111-1111-1111-111111111111','CALCULATION_RUN','$RUNA',1,'calc-engine-1','ck1')"
expect_err "INV-18：計算工作主體屬其他租戶 → 拒絕" \
  "$T1 INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version, rule_version, idempotency_key)
   VALUES ('22222222-2222-2222-2222-222222222222','CALCULATION_RUN','$RUNA',1,'calc-engine-1','ck2')" "不屬於本租戶"
n=$(APP_C <<<"$T2 SELECT count(*) FROM calculation_run")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的計算執行" || ng "RLS：calculation_run 洩漏 $n 筆"

# ── 0014：並發競態與期間歸屬 ─────────────────────────
# E99 期間（PR99）已由前段 02A 區建立；此處只補 E1 的第二期間（2026-05）
PSQL_C >/dev/null <<'SQL'
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id, fiscal_calendar_id, label, start_date, end_date) VALUES
  ('dddddddd-0000-0000-0000-000000000052','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-000000000001','2026-05','2026-05-01','2026-05-31');
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id) VALUES
  ('99999999-0000-0000-0000-000000000052','11111111-1111-1111-1111-111111111111','dddddddd-0000-0000-0000-000000000052');
SQL
ok "0014 前置：E1 第二期間（2026-05；E99 期間沿用前段）"
PR99=99999999-0000-0000-0000-000000000099
PR52=99999999-0000-0000-0000-000000000052
MANI5=ee110000-0000-0000-0000-000000000005
expect_err "0014②：Manifest 掛他案件的期間（E1 × E99 期間）→ 拒絕" \
  "$T1 INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '$PR99','NO_FX','sqlcanon-2','h','aaaaaaaa-0000-0000-0000-000000000001')" "期間不屬於本案件"
expect_err "0014②：Run 期間 ≠ 批次宣告期間 → 拒絕（Manifest 與 Run 填同一錯誤期間也擋）" \
  "$T1 INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
   VALUES ('$MANI5','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '$PR52','NO_FX','sqlcanon-2','h5','aaaaaaaa-0000-0000-0000-000000000001');
   INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, request_key, request_content_hash, engine_version, created_by)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '$PR52','$B1','$MANI5','PREVIEW',
           gen_random_uuid(),'rc9','calc-engine-1','aaaaaaaa-0000-0000-0000-000000000001')" "批次宣告期間"
expect_err "0014 小項：RUNNING 不得帶 failure_reason（互斥補漏）" \
  "$T1 UPDATE calculation_run SET failure_reason='x' WHERE calculation_run_id='$RUNC'" "互斥"
expect_err "0014 白名單：未知 canonicalization 版本 fail closed" \
  "$T1 INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '99999999-0000-0000-0000-000000000001','NO_FX','sqlcanon-99','h','aaaaaaaa-0000-0000-0000-000000000001')" "check"
expect_err "0014 白名單：未知 hash 演算法 fail closed" \
  "$T1 INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, hash_algorithm, canonicalization_version, frozen_set_content_hash, created_by)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
           '99999999-0000-0000-0000-000000000001','NO_FX','md5','sqlcanon-2','h','aaaaaaaa-0000-0000-0000-000000000001')" "check"

# 競態 a：Run 建立交易持 Manifest 鎖期間，entry 追加必須阻塞後被拒（封存無 TOCTOU 窗）
MANI4=ee110000-0000-0000-0000-000000000004
RUND=ee110000-0000-0000-0000-000000000014
PSQL_C >/dev/null <<SQL
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
     calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
VALUES ('$MANI4','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
        '99999999-0000-0000-0000-000000000001','NO_FX','sqlcanon-2','h4','aaaaaaaa-0000-0000-0000-000000000001');
INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, domain_version_kind,
     domain_version_value, content_canonical, content_hash, payload)
VALUES ('11111111-1111-1111-1111-111111111111','$MANI4','SCOPE','SCOPE','1','c4','h4','{}'::jsonb);
SQL
( PSQL_C >/dev/null 2>&1 <<RACEA
BEGIN;
INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
     import_batch_id, manifest_id, run_type, request_key, request_content_hash, engine_version, created_by)
VALUES ('$RUND','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
        '99999999-0000-0000-0000-000000000001','$B1','$MANI4','PREVIEW',
        'ee110000-0000-0000-0000-0000000000a4','rcA','calc-engine-1','aaaaaaaa-0000-0000-0000-000000000001');
SELECT pg_sleep(2);
COMMIT;
RACEA
) &
RACEAPID=$!
sleep 1
if out=$(PSQL_C 2>&1 <<<"INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, domain_version_kind,
      domain_version_value, content_canonical, content_hash, payload)
    VALUES ('11111111-1111-1111-1111-111111111111','$MANI4','SCOPE','SCOPE','2','c5','h5','{}'::jsonb)"); then
  wait $RACEAPID; ng "0014① 競態a：Run 建立中 entry 竟可追加"
else
  wait $RACEAPID
  echo "$out" | grep -q "封存" && ok "0014① 競態a：entry 追加阻塞至 Run 建立提交後被拒（封存）" \
                              || ng "0014① 競態a：失敗原因不符：$out"
fi

# 競態 b：worker 終態提交持 Run 鎖期間，外部快照必須阻塞後被拒
( PSQL_C >/dev/null 2>&1 <<RACEB
BEGIN;
WITH runlock AS (SELECT status FROM calculation_run WHERE calculation_run_id='$RUND' FOR UPDATE)
SELECT count(*) FROM runlock;
SELECT pg_sleep(2);
UPDATE calculation_run SET status='COMPLETED', result_content_hash='rD' WHERE calculation_run_id='$RUND';
COMMIT;
RACEB
) &
RACEBPID=$!
sleep 1
if out=$(PSQL_C 2>&1 <<<"INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
      account_code, account_name, debit, credit)
    VALUES ('11111111-1111-1111-1111-111111111111','$RUND','SOURCE_TB','ac000000-0000-0000-0000-000000000001',
            '1002','银行存款',1,0)"); then
  wait $RACEBPID; ng "0014① 競態b：終態提交中快照竟可寫入"
else
  wait $RACEBPID
  echo "$out" | grep -q "不得追加結果" && ok "0014① 競態b：快照阻塞至終態提交後被拒（result hash 固定）" \
                                       || ng "0014① 競態b：失敗原因不符：$out"
fi

# ── SLICE-M2-02C：EvidencePackage（migrations/0015；契約 A～C） ──
PKG1=ee220000-0000-0000-0000-000000000001
PKG2=ee220000-0000-0000-0000-000000000002
CUT=$(PSQL_C <<<"INSERT INTO audit_event (tenant_id, kind, event_type, object_type, object_id)
  VALUES ('11111111-1111-1111-1111-111111111111','DOMAIN_EVENT','calculation_run.completed','calculation_run','$RUNA')
  RETURNING audit_event_id")
expect_ok "Package 建立（GENERATING；cutoff＝該 run 的 completed 事件）" \
  "$T1 INSERT INTO evidence_package (package_id, tenant_id, engagement_id, calculation_run_id,
        request_key, request_content_hash, audit_cutoff_event_id, render_version, created_by)
   VALUES ('$PKG1','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','$RUNA',
           'ee220000-0000-0000-0000-0000000000a1','pch1',$CUT,'html-1','aaaaaaaa-0000-0000-0000-000000000001')"
expect_err "契約 A：GENERATING 內容欄位必須全空" \
  "$T1 INSERT INTO evidence_package (package_id, tenant_id, engagement_id, calculation_run_id,
        request_key, request_content_hash, audit_cutoff_event_id, render_version, created_by, artifact_sha256)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','$RUNA',
           gen_random_uuid(),'x',$CUT,'html-1','aaaaaaaa-0000-0000-0000-000000000001','sha')" "全空"
expect_err "非 COMPLETED run 不可產包" \
  "$T1 INSERT INTO evidence_package (package_id, tenant_id, engagement_id, calculation_run_id,
        request_key, request_content_hash, audit_cutoff_event_id, render_version, created_by)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','$RUNC',
           gen_random_uuid(),'x',$CUT,'html-1','aaaaaaaa-0000-0000-0000-000000000001')" "RUN_NOT_COMPLETED"
expect_err "cutoff 必須是該 run 的 completed 事件" \
  "$T1 INSERT INTO evidence_package (package_id, tenant_id, engagement_id, calculation_run_id,
        request_key, request_content_hash, audit_cutoff_event_id, render_version, created_by)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','$RUNA',
           gen_random_uuid(),'x',1,'html-1','aaaaaaaa-0000-0000-0000-000000000001')" "completed 事件"
expect_err "重產必須引用同一 run 的既有 Package" \
  "$T1 INSERT INTO evidence_package (package_id, tenant_id, engagement_id, calculation_run_id,
        request_key, request_content_hash, audit_cutoff_event_id, render_version, created_by, regenerated_from_id)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','$RUND',
           gen_random_uuid(),'x',$CUT,'html-1','aaaaaaaa-0000-0000-0000-000000000001','$PKG1')" "同一 run"
expect_err "request_key 唯一於（tenant, key）" \
  "$T1 INSERT INTO evidence_package (package_id, tenant_id, engagement_id, calculation_run_id,
        request_key, request_content_hash, audit_cutoff_event_id, render_version, created_by)
   VALUES (gen_random_uuid(),'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','$RUNA',
           'ee220000-0000-0000-0000-0000000000a1','pch1',$CUT,'html-1','aaaaaaaa-0000-0000-0000-000000000001')" "duplicate key"
expect_ok "索引：GENERATING 期間可寫入（固定 10 節）" \
  "$T1 INSERT INTO evidence_package_index (tenant_id, package_id, section, item_count, content_hash)
   SELECT '11111111-1111-1111-1111-111111111111','$PKG1', s, 1, 'h-'||s
     FROM unnest(ARRAY['source','mapping','adjustment','calculation','rule_versions',
                       'process_level','control_exceptions','traceability','events','attachments']) AS s"
expect_err "契約 A：READY 必須齊備 artifact 與內容 hash" \
  "$T1 UPDATE evidence_package SET status='READY' WHERE package_id='$PKG1'" "齊備"
expect_err "0016④：READY 的 package_content_hash 必須等於索引 aggregate（DB 重算）" \
  "$T1 UPDATE evidence_package SET status='READY', package_content_hash='wrong', artifact_object_key='k',
       artifact_sha256='as', artifact_mime_type='text/html', artifact_byte_size=10 WHERE package_id='$PKG1'" "aggregate 不符"
AGG=$(PSQL_C <<<"SELECT encode(sha256(convert_to(string_agg(section||'|'||content_hash, E'\n' ORDER BY section COLLATE \"C\"),'UTF8')),'hex') FROM evidence_package_index WHERE package_id='$PKG1'")
expect_ok "GENERATING → READY（齊備＋aggregate 相符）" \
  "$T1 UPDATE evidence_package SET status='READY', package_content_hash='$AGG', artifact_object_key='k',
       artifact_sha256='as', artifact_mime_type='text/html', artifact_byte_size=10 WHERE package_id='$PKG1'"
expect_err "終態後索引封存" \
  "$T1 INSERT INTO evidence_package_index (tenant_id, package_id, section, item_count, content_hash)
   VALUES ('11111111-1111-1111-1111-111111111111','$PKG1','late',1,'h2')" "封存"
expect_err "終態不可修改（重產＝新 package）" \
  "$T1 UPDATE evidence_package SET package_content_hash='pc2' WHERE package_id='$PKG1'" "終態"
expect_err "索引不可修改" \
  "$T1 UPDATE evidence_package_index SET content_hash='x' WHERE package_id='$PKG1'" "不可變"
expect_err "FAILED 必須帶機器代碼與原因" \
  "$T1 INSERT INTO evidence_package (package_id, tenant_id, engagement_id, calculation_run_id,
        request_key, request_content_hash, audit_cutoff_event_id, render_version, created_by)
   VALUES ('$PKG2','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','$RUNA',
           'ee220000-0000-0000-0000-0000000000a2','pch2',$CUT,'html-1','aaaaaaaa-0000-0000-0000-000000000001');
   UPDATE evidence_package SET status='FAILED' WHERE package_id='$PKG2'" "機器代碼"
expect_err "0016④：READY 需要固定章節集合（缺節被拒）" \
  "$T1 UPDATE evidence_package SET status='READY', package_content_hash='x', artifact_object_key='k',
       artifact_sha256='as', artifact_mime_type='text/html', artifact_byte_size=10 WHERE package_id='$PKG2'" "固定章節集合"
expect_err "契約 A：FAILED 不得帶 artifact" \
  "$T1 UPDATE evidence_package SET status='FAILED', failure_reason_code='X', failure_reason='y',
       artifact_sha256='s' WHERE package_id='$PKG2'" "互斥"
expect_ok "GENERATING → FAILED（帶代碼與原因）" \
  "$T1 UPDATE evidence_package SET status='FAILED', failure_reason_code='UPSTREAM_VERIFY_FAILED',
       failure_reason='上游驗證失敗' WHERE package_id='$PKG2'"
expect_ok "BackgroundJob 支援 EVIDENCE_PACKAGE 型別" \
  "$T1 INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version, rule_version, idempotency_key)
   VALUES ('11111111-1111-1111-1111-111111111111','EVIDENCE_PACKAGE','$PKG1',1,'html-1','ek1')"
expect_err "INV-18：包工作主體屬其他租戶 → 拒絕" \
  "$T1 INSERT INTO background_job (tenant_id, job_type, subject_id, subject_version, rule_version, idempotency_key)
   VALUES ('22222222-2222-2222-2222-222222222222','EVIDENCE_PACKAGE','$PKG1',1,'html-1','ek2')" "不屬於本租戶"
# 契約 C：來源實體不可變前提
expect_ok "契約 C 前置：coverage 與 document 各一列（B2 未封存）" \
  "$T1 INSERT INTO data_coverage (tenant_id, import_batch_id, batch_version, account_scope, granularity, completeness_status)
   VALUES ('11111111-1111-1111-1111-111111111111','$B2',1,'prep','BALANCE','UNKNOWN');
   INSERT INTO source_document (tenant_id, import_batch_id, file_name, content_sha256, object_key, byte_size)
   VALUES ('11111111-1111-1111-1111-111111111111','$B2','tb.csv','h','k0',1)"
expect_err "契約 C：source_dataset 不可修改" \
  "$T1 UPDATE source_dataset SET row_count=99 WHERE import_batch_id='$B2'" "不可變"
expect_err "契約 C：data_coverage 不可修改" \
  "$T1 UPDATE data_coverage SET completeness_status='COMPLETE' WHERE import_batch_id='$B2'" "不可變"
expect_err "契約 C：source_document 不可修改" \
  "$T1 UPDATE source_document SET file_name='x' WHERE import_batch_id='$B2'" "不可變"
expect_err "契約 C：來源實體與批次不同租戶 → 拒絕" \
  "$T1 INSERT INTO source_dataset (tenant_id, import_batch_id, batch_version, granularity, content_sha256, row_count)
   VALUES ('22222222-2222-2222-2222-222222222222','$B2',9,'BALANCE','h',1)" "不同租戶"
expect_err "0018③：上傳後批次來源身分欄位凍結（file_sha256 不可改寫）" \
  "$T1 UPDATE import_batch SET file_sha256='tampered' WHERE import_batch_id='$B2'" "已凍結"
expect_err "0016①：來源集合封存——已驗證批次不得追加來源實體（同 run 同包內容才成立）" \
  "$T1 INSERT INTO source_document (tenant_id, import_batch_id, file_name, content_sha256, object_key, byte_size)
   VALUES ('11111111-1111-1111-1111-111111111111','$B1','late.pdf','h','k9',1)" "已封存"
n=$(APP_C <<<"$T2 SELECT count(*) FROM evidence_package")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的證據包" || ng "RLS：evidence_package 洩漏 $n 筆"

# 衍生資料的自然唯一性（冪等第二道防線）
expect_err "冪等：同批次同版本同粒度不得有第二個 source_dataset" \
  "$T1 INSERT INTO source_dataset (tenant_id, import_batch_id, batch_version, granularity, content_sha256, row_count)
   VALUES ('11111111-1111-1111-1111-111111111111','$B2',1,'BALANCE','h2',2)" "duplicate key"
expect_err "0017②：來源實體版本必須等於批次當前版本（Manifest 依 batch_version 定位）" \
  "$T1 INSERT INTO source_dataset (tenant_id, import_batch_id, batch_version, granularity, content_sha256, row_count)
   VALUES ('11111111-1111-1111-1111-111111111111','$B2',2,'BALANCE','h3',2)" "必須等於批次當前版本"
expect_ok "冪等：data_coverage 首筆" \
  "$T1 INSERT INTO data_coverage (tenant_id, import_batch_id, batch_version, granularity, completeness_status)
   VALUES ('11111111-1111-1111-1111-111111111111','$B2',1,'BALANCE','UNKNOWN')"
expect_err "冪等：data_coverage 同鍵不得重複" \
  "$T1 INSERT INTO data_coverage (tenant_id, import_batch_id, batch_version, granularity, completeness_status)
   VALUES ('11111111-1111-1111-1111-111111111111','$B2',1,'BALANCE','COMPLETE')" "duplicate key"
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

# ══ 0021：映射來源批次必須已接受 ══════════════════════════════
# 0020 只驗同租戶同案件；未經接受的批次（含 QUARANTINED）曾可成為正式映射的來源脈絡。
TEN=11111111-1111-1111-1111-111111111111
LE1=cccccccc-0000-0000-0000-000000000001
PRX=99999999-0000-0000-0000-000000000001
# 依 0019／0020 的合法路徑推進：assessment 必須先獨立寫入，identity 判定與 current
# 指標同一次 UPDATE 成對寫入，且只能在 VALIDATING 階段。種子失敗即 fail closed。
mkbatch() {   # $1=批次id $2=目標狀態 $3=assessment id
  PSQL_C <<SQL >/dev/null 2>&1 || { ng "0021 種子 $2 建立失敗（fail closed）"; return 1; }
$T1
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by, file_name, file_sha256, status)
VALUES ('$1','$TEN','$ENG','$LE1','$PRX','$JIA','$JIA','tb.csv','sha-$1','DRAFT');
SQL
  [ "$2" = "DRAFT" ] && return 0
  PSQL_C <<<"$T1 UPDATE import_batch SET status='UPLOADED' WHERE import_batch_id='$1'" >/dev/null 2>&1 \
    || { ng "0021 種子 $2：UPLOADED 失敗"; return 1; }
  [ "$2" = "UPLOADED" ] && return 0
  PSQL_C <<SQL >/dev/null 2>&1 || { ng "0021 種子 $2：VALIDATED 路徑失敗"; return 1; }
$T1
UPDATE import_batch SET status='VALIDATING' WHERE import_batch_id='$1';
INSERT INTO source_identity_assessment (assessment_id, tenant_id, import_batch_id, batch_version,
        match_result, evidence_kind, detection_rule_version)
VALUES ('$3','$TEN','$1',1,'MATCH','AUTHORITATIVE_ID','detect-r1');
UPDATE import_batch SET identity_status='MATCHED', current_identity_assessment_id='$3'
 WHERE import_batch_id='$1';
UPDATE import_batch SET hash_verified=true WHERE import_batch_id='$1';
UPDATE import_batch SET status='VALIDATED' WHERE import_batch_id='$1';
SQL
  [ "$2" = "VALIDATED" ] && return 0
  if [ "$2" = "QUARANTINED" ]; then
    PSQL_C <<<"$T1 UPDATE import_batch SET status='QUARANTINED', quarantine_reason='測試' WHERE import_batch_id='$1'" >/dev/null 2>&1
  else
    PSQL_C <<<"$T1 UPDATE import_batch SET status='ACCEPTED' WHERE import_batch_id='$1'" >/dev/null 2>&1
  fi
  st=$(APP_C <<<"$T1 SELECT status FROM import_batch WHERE import_batch_id='$1'")
  [ "$st" = "$2" ] || { ng "0021 種子批次 $1 期望 $2 得到 $st"; return 1; }
  return 0
}
BD=ba000000-0000-0000-0000-000000000301    # DRAFT
BU2=ba000000-0000-0000-0000-000000000401   # UPLOADED
BV=ba000000-0000-0000-0000-000000000501    # VALIDATED
BQ=ba000000-0000-0000-0000-000000000601    # QUARANTINED
BA=ba000000-0000-0000-0000-000000000701    # ACCEPTED
BS=ba000000-0000-0000-0000-000000000801    # ACCEPTED → 稍後轉 SUPERSEDED
AS1=a9000000-0000-0000-0000-000000000501
AS2=a9000000-0000-0000-0000-000000000601
AS3=a9000000-0000-0000-0000-000000000701
AS4=a9000000-0000-0000-0000-000000000801
mkbatch "$BD" DRAFT ""; mkbatch "$BU2" UPLOADED ""; mkbatch "$BV" VALIDATED "$AS1"
mkbatch "$BQ" QUARANTINED "$AS2"; mkbatch "$BA" ACCEPTED "$AS3"; mkbatch "$BS" ACCEPTED "$AS4"
seeded=$(APP_C <<<"$T1 SELECT string_agg(status::text, ',' ORDER BY import_batch_id)
  FROM import_batch WHERE import_batch_id IN ('$BD','$BU2','$BV','$BQ','$BA','$BS')")
[ "$seeded" = "DRAFT,UPLOADED,VALIDATED,QUARANTINED,ACCEPTED,ACCEPTED" ] \
  && ok "0021 種子：六個批次確實停在 DRAFT／UPLOADED／VALIDATED／QUARANTINED／ACCEPTED×2" \
  || ng "0021 種子狀態不符：$seeded"

mkmap() {   # $1=來源批次 $2=來源科目代碼
  echo "INSERT INTO mapping_rule (tenant_id, engagement_id, source_account_code,
          target_account_id, version_no, created_by, source_import_batch_id)
        VALUES ('$TEN','$ENG','$2','ac000000-0000-0000-0000-000000000001',1,'$JIA','$1')"
}
for pair in "$BD:DRAFT:901" "$BU2:UPLOADED:902" "$BV:VALIDATED:903" "$BQ:QUARANTINED:904"; do
  bid="${pair%%:*}"; rest="${pair#*:}"; st="${rest%%:*}"; code="${rest##*:}"
  expect_err "0021：來源批次為 $st → 拒絕建立映射" "$T1 $(mkmap "$bid" "$code")" "SOURCE_BATCH_NOT_ACCEPTED"
done
expect_ok "0021：來源批次為 ACCEPTED → 正常建立映射" "$T1 $(mkmap "$BA" 905)"

# 先 SUPERSEDED 再建立 → 必須拒絕
PSQL_C >/dev/null 2>&1 <<<"$T1 UPDATE import_batch SET status='SUPERSEDED', superseded_by_id='$BA' WHERE import_batch_id='$BS'"
expect_err "0021：來源批次已 SUPERSEDED → 拒絕建立映射" "$T1 $(mkmap "$BS" 906)" "SOURCE_BATCH_NOT_ACCEPTED"

# ── FOR UPDATE 競態：兩交易不得交錯穿越檢查 ──
# A：建立映射並鎖住來源批次列（持鎖 3 秒）；B：0.8 秒後嘗試把該批次轉 SUPERSEDED。
# 沒有 FOR UPDATE 時，B 會在 A 的檢查與提交之間穿過去。
BR=ba000000-0000-0000-0000-000000000901
mkbatch "$BR" ACCEPTED a9000000-0000-0000-0000-000000000901
( PSQL_C >/dev/null 2>&1 <<SQL
$T1
BEGIN;
$(mkmap "$BR" 907);
SELECT pg_sleep(3);
COMMIT;
SQL
) & APID=$!
sleep 0.8
start=$(date +%s)
PSQL_C >/dev/null 2>&1 <<<"$T1 UPDATE import_batch SET status='SUPERSEDED', superseded_by_id='$BA' WHERE import_batch_id='$BR'"
waited=$(( $(date +%s) - start ))
wait $APID
[ "$waited" -ge 1 ] && ok "0021 競態：B 的 SUPERSEDED 被 A 的列鎖擋住（等待 ${waited}s，未交錯穿越）" \
  || ng "0021 競態：B 未被阻塞（等待 ${waited}s）——FOR UPDATE 未生效"
n=$(APP_C <<<"$T1 SELECT count(*) FROM mapping_rule WHERE source_account_code='907'")
[ "$n" = "1" ] && ok "0021 競態：A 的映射已建立（檢查時來源仍為 ACCEPTED）" || ng "0021 競態：A 的映射未建立"
st=$(APP_C <<<"$T1 SELECT status FROM import_batch WHERE import_batch_id='$BR'")
[ "$st" = "SUPERSEDED" ] && ok "0021 競態：A 提交後 B 才生效（批次轉 SUPERSEDED）" || ng "0021 競態：批次狀態為 $st"
n=$(APP_C <<<"$T1 SELECT count(*) FROM mapping_rule WHERE source_account_code='907'")
[ "$n" = "1" ] && ok "0021：既有映射不因來源批次日後轉 SUPERSEDED 而被追溯刪除" || ng "既有映射被追溯刪除"
expect_ok "0021：既有映射仍可正常批准（不重驗來源狀態）" \
  "$T1 UPDATE mapping_rule SET approved_by='$YI', approved_at=now()
   WHERE source_account_code='907' AND source_import_batch_id='$BR'"
expect_err "0021：來源批次脈絡仍不可變更（改指向另一個批次亦拒絕）" \
  "$T1 UPDATE mapping_rule SET source_import_batch_id='$BR' WHERE source_account_code='905'" "不可變更"

# ══ SLICE-M2-05：期間生命週期（0022）══════════════════════════
# DB 是唯一裁決點。此區驗證的不只是規則，還有「所有繞道都被封住」。
# 註：owner 也無法直接改狀態；建立前置狀態必須明確 DISABLE TRIGGER（見下方 pforce）。
PU=bbbbbbbb-0000-0000-0000-000000000001
PCAL=ffffffff-0000-0000-0000-000000000001
PENG=eeeeeeee-0000-0000-0000-000000000001
# 註：reporting_period 有 no_overlap 排除約束（同單位同曆別不得日期重疊），
# 故每個測試期間必須用互不重疊的日期區間。
mkperiod() {  # $1=period_id $2=revision_id $3=is_initial $4=label $5=unit $6=start $7=end
  PSQL_C <<SQL >/dev/null 2>&1 || { ng "0022 種子 $4 建立失敗（fail closed）"; return 1; }
$T1
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id,
        fiscal_calendar_id, label, start_date, end_date, is_initial_period)
VALUES ('$1','$TEN','$PENG','$5','$PCAL','$4','$6','$7',$3);
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id)
VALUES ('$2','$TEN','$1');
SQL
}
pforce() {  # 建立前置狀態：owner 也得停用 trigger 才改得動（唯一裁決點的副作用）
  PSQL_C <<<"$T1 ALTER TABLE period_revision DISABLE TRIGGER trg_period_transition;
    UPDATE period_revision SET status='$2' WHERE period_revision_id='$1';
    ALTER TABLE period_revision ENABLE TRIGGER trg_period_transition;" >/dev/null 2>&1
}
att() { echo "$T1 SELECT fn_period_attempt_transition('$1','$2','$3','$4','$5')"; }

# 專用的「只有 R6」使用者：用來驗證冒充角色被擋（db.test.sh 的 fixture 沒有丁）
PSQL_C <<SQL >/dev/null 2>&1
$T1
INSERT INTO app_user (user_id, tenant_id, email, display_name)
VALUES ('a6220000-0000-0000-0000-000000000001','$TEN','ops-m205@t1.jp','M2-05 系管');
INSERT INTO role_assignment (tenant_id, user_id, role, engagement_id)
VALUES ('$TEN','a6220000-0000-0000-0000-000000000001','R6',NULL);
-- 本檔既有 fixture 只給了 R2；期間遷移需要 R3／R4。在此補指派，不改動既有 fixture
-- 以免影響前面各區的測試前提。
INSERT INTO role_assignment (tenant_id, user_id, role, engagement_id) VALUES
  ('$TEN','$YI','R4','$PENG'),
  ('$TEN','$YI','R3','$PENG'),
  ('$TEN','$BING','R3','$PENG');
SQL
R6USER=a6220000-0000-0000-0000-000000000001

PA=dd220000-0000-0000-0000-000000000001; RA=9d220000-0000-0000-0000-000000000001
mkperiod "$PA" "$RA" true "M2-05-初" "$PU" "2026-09-01" "2026-09-30"
ok "0022 種子：首期 ＋ 修訂（預設應為 SETUP）"
st=$(APP_C <<<"$T1 SELECT status FROM period_revision WHERE period_revision_id='$RA'")
[ "$st" = "SETUP" ] && ok "0022：新建修訂預設 SETUP（DEFAULT 已由 OPEN 改為 SETUP）" \
  || ng "0022：新建修訂預設為 $st（應為 SETUP）"

# ── 繞道 1：INSERT 跳過狀態機 ──
expect_err "0022 繞道：INSERT status='DELIVERED' → 拒絕" \
  "$T1 INSERT INTO period_revision (tenant_id, reporting_period_id, status)
   VALUES ('$TEN','$PA','DELIVERED')" "PERIOD_INSERT_MUST_BE_SETUP"
expect_err "0022 繞道：INSERT revision_no=99 → 拒絕" \
  "$T1 INSERT INTO period_revision (tenant_id, reporting_period_id, revision_no)
   VALUES ('$TEN','$PA',99)" "REVISION_CHAIN_NOT_IMPLEMENTED"
expect_err "0022 繞道：同期間第二條修訂 → 拒絕（重開尚未實作）" \
  "$T1 INSERT INTO period_revision (tenant_id, reporting_period_id, revision_no)
   VALUES ('$TEN','$PA',1)" "REVISION_CHAIN_NOT_IMPLEMENTED"
expect_err "0022 繞道：修訂與父期間不同租戶 → 拒絕" \
  "$T1 INSERT INTO period_revision (tenant_id, reporting_period_id, revision_no)
   VALUES ('22222222-2222-2222-2222-222222222222','$PA',1)" "INV-18"

# ── 繞道 2：身分欄位與期間屬性凍結 ──
expect_err "0022 繞道：遷移時同時改 revision_no → 拒絕" \
  "$T1 SELECT set_config('app.actor_id','$YI',true);
   SELECT set_config('app.acting_role','R4',true);
   UPDATE period_revision SET status='OPEN', revision_no=99 WHERE period_revision_id='$RA'" \
  "REVISION_IDENTITY_IMMUTABLE"
expect_err "0022：is_initial_period 建立後不可變更" \
  "$T1 UPDATE reporting_period SET is_initial_period=false WHERE reporting_period_id='$PA'" \
  "INITIAL_PERIOD_IMMUTABLE"
expect_err "0022：期間日期不可變更（end_date 決定映射生效版本）" \
  "$T1 UPDATE reporting_period SET end_date='2026-04-30' WHERE reporting_period_id='$PA'" \
  "PERIOD_DATES_IMMUTABLE"

# ── 繞道 3：actor／角色 ──
expect_err "0022 繞道：不帶 actor 直接 UPDATE → 拒絕" \
  "$T1 UPDATE period_revision SET status='OPEN' WHERE period_revision_id='$RA'" \
  "TRANSITION_ACTOR_REQUIRED"
expect_err "0022：發起人未持有該角色（只有 R6 者冒充 R4）" \
  "$(att "$RA" SETUP OPEN "$R6USER" R4)" "ACTOR_ROLE_NOT_HELD"
n=$(APP_C <<<"$T1 SELECT string_agg(privilege_type,',' ORDER BY privilege_type)
  FROM information_schema.role_table_grants WHERE grantee='app_runtime' AND table_name='period_revision'")
[ "$n" = "INSERT,SELECT" ] && ok "0022：app_runtime 對 period_revision 僅餘 INSERT,SELECT（UPDATE／DELETE 已撤回）" \
  || ng "0022：app_runtime 權限為 $n"

# ── 狀態機主路徑與 fail closed ──
expect_err "0022：跳關 SETUP → ADJ_APPROVED" "$(att "$RA" SETUP ADJ_APPROVED "$YI" R4)" "ILLEGAL_TRANSITION"
expect_err "0022：SETUP → OPEN 角色須 R4（R2 拒絕）" "$(att "$RA" SETUP OPEN "$YI" R2)" "ROLE_NOT_PERMITTED"
expect_err "0022：樂觀鎖——expected_from 不符" "$(att "$RA" OPEN IN_PREPARATION "$YI" R2)" "OPTIMISTIC_LOCK_CONFLICT"
expect_err "0022：同狀態請求不構成遷移" "$(att "$RA" SETUP SETUP "$YI" R4)" "NO_OP_TRANSITION"
expect_ok  "0022：首期 SETUP → OPEN（R4）" "$(att "$RA" SETUP OPEN "$YI" R4)"
expect_err "0022：OPEN → IN_PREPARATION 無完整 TB → 拒絕" \
  "$(att "$RA" OPEN IN_PREPARATION "$YI" R2)" "REQUIRED_DATA_INCOMPLETE"

PB=dd220000-0000-0000-0000-000000000002; RB=9d220000-0000-0000-0000-000000000002
PSQL_C <<SQL >/dev/null 2>&1
$T1
INSERT INTO reporting_unit (reporting_unit_id, tenant_id, engagement_id, unit_scope, name)
VALUES ('bb220000-0000-0000-0000-000000000002','$TEN','$PENG','LEGAL_ENTITY','M2-05 第二單位');
SQL
PSQL_C <<SQL >/dev/null 2>&1
$T1
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id,
        fiscal_calendar_id, label, start_date, end_date, is_initial_period)
VALUES ('$PB','$TEN','$PENG','bb220000-0000-0000-0000-000000000002','$PCAL','M2-05-非首','2026-10-01','2026-10-31',false);
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id) VALUES ('$RB','$TEN','$PB');
SQL
expect_err "0022：非首期 SETUP → OPEN fail closed" "$(att "$RB" SETUP OPEN "$YI" R4)" "G10_NOT_IMPLEMENTED"

# 首期唯一約束
expect_err "0022：同單位同曆別第二個首期 → unique 拒絕" \
  "$T1 INSERT INTO reporting_period (tenant_id, engagement_id, reporting_unit_id, fiscal_calendar_id,
        label, start_date, end_date, is_initial_period)
   VALUES ('$TEN','$PENG','$PU','$PCAL','再一個首期','2026-11-01','2026-11-30',true)" "duplicate key"

# 後段各守衛的專屬代碼（非 ILLEGAL_TRANSITION）
for pair in "ADJ_APPROVED:CALCULATING:G07_NOT_IMPLEMENTED" \
            "CALCULATING:RECONCILING:RECONCILE_NOT_IMPLEMENTED" \
            "RECONCILING:PENDING_PKG_APPR:G03_NOT_IMPLEMENTED" \
            "PENDING_PKG_APPR:LOCKED:G06_NOT_IMPLEMENTED" \
            "LOCKED:DELIVERED:G09_NOT_IMPLEMENTED"; do
  from="${pair%%:*}"; rest="${pair#*:}"; to="${rest%%:*}"; code="${rest##*:}"
  pforce "$RA" "$from"
  expect_err "0022 fail closed：$from → $to" "$(att "$RA" "$from" "$to" "$YI" R4)" "$code"
done
pforce "$RA" SETUP

# ── 繞道 4／5：AWAITING 不可直選、Evaluation 不可偽造 ──
pforce "$RA" IN_REVIEW
expect_err "0022：AWAITING_REVIEWER 不可由使用者直接指定" \
  "$(att "$RA" IN_REVIEW AWAITING_REVIEWER "$YI" R4)" "ILLEGAL_TRANSITION"
pforce "$RA" SETUP
n=$(APP_C <<<"$T1 INSERT INTO reviewer_eligibility_evaluation (tenant_id, period_revision_id,
  policy_version, evaluated_by, scope_object_count, fully_covered, resulting_status)
  VALUES ('$TEN','$RA','fake','$YI',0,true,'IN_REVIEW')" 2>&1 | grep -c "permission denied")
[ "$n" -ge 1 ] && ok "0022：app_runtime 不得直接寫入 Evaluation 快照" || ng "0022：Evaluation 可被偽造"
expect_err "0022：Evaluation 結論與落點不得矛盾" \
  "$T1 INSERT INTO reviewer_eligibility_evaluation (tenant_id, period_revision_id, policy_version,
        evaluated_by, scope_object_count, fully_covered, resulting_status)
   VALUES ('$TEN','$RA','x','$YI',1,false,'IN_REVIEW')" "violates check constraint"

n=$(APP_C <<<"$T2 SELECT count(*) FROM reviewer_eligibility_evaluation")
[ "$n" = "0" ] && ok "0022 RLS：T2 看不到 T1 的覆核評估" || ng "0022 RLS：評估洩漏 $n 筆"
# ══════════ SLICE-M2-06：多基礎與四類規則（migration 0023） ══════════
# 三條主軸的驗證：代碼不驅動約束、構成與調節分屬兩模型、守衛未實作即 fail closed。
TEN=11111111-1111-1111-1111-111111111111
BING=aaaaaaaa-0000-0000-0000-000000000003     # 持有 R1（政策指定的稅務確認角色）
POL_OK=30000000-0000-0000-0000-000000000001
POL_DRAFT=30000000-0000-0000-0000-000000000002
COMP_A=21000000-0000-0000-0000-000000000001
COMP_C=21000000-0000-0000-0000-000000000003
LAYER_LB=10000000-0000-0000-0000-000000000001
LAYER_TA=10000000-0000-0000-0000-000000000006  # TRANSLATION_ADJUSTMENT（rule_type IS NULL）
GRP_PR=99999999-0000-0000-0000-000000000002
ASOF=2026-03-31

# ── 1 主檔與可查性（AC-BAS-001 前半） ──
n=$(APP_C <<<"$T1 SELECT string_agg(code,',' ORDER BY code) FROM book_basis")
[ "$n" = "A,B,C" ] && ok "0023：A／B／C 三基礎可分別查詢（同一查詢路徑）" || ng "0023：基礎清單為 $n"
n=$(APP_C <<<"$T1 SELECT count(*) FROM posting_layer WHERE scope_type='GROUP'")
[ "$n" = "1" ] && ok "0023：六個分層已種，CONSOLIDATION 為唯一 GROUP scope" || ng "0023：GROUP 層數為 $n"
n=$(APP_C <<<"$T1 INSERT INTO posting_layer (layer_id, code, scope_type) VALUES (gen_random_uuid(),'X','ENTITY')" 2>&1 | grep -c "permission denied")
[ "$n" -ge 1 ] && ok "0023：posting_layer 為平台參照主檔，app_runtime 不得寫入" || ng "0023：分層主檔可被租戶寫入"
expect_err "0023：分層主檔不可變更（改 scope_type 會追溯翻案 INV-03）" \
  "UPDATE posting_layer SET scope_type='GROUP' WHERE code='LOCAL_BOOK'" "不可變"

# ── 2 代碼不得驅動約束（原始碼掃描） ──
# 種子與回填必然要點名代碼（要建的就是 A／C），那些行以 `-- seed-data` 標記；
# 掃描的是「約束與守衛是否以代碼判斷」——那才是新增第四基礎時會爆掉的東西。
if grep -rnE "^[^-]*[^-]code[[:space:]]*=[[:space:]]*'(A|B|C)'" \
     "$ROOT"/packages/database/migrations/*.sql | grep -v "seed-data" >/dev/null 2>&1
then ng "0023：migration 的約束／守衛出現以 code 值驅動的判斷"
else ok "0023：全部 migration 的約束與守衛內無 code='A'／'B'／'C' 判斷（一律由語意欄位驅動）"; fi
# 「指定稅務專業角色」由 BasisSourcePolicyVersion.confirmation_role 指定；
# 只要有人把 R1 寫死進判斷，換法域或換客戶就得改約束——那正是本刀要避免的。
# role_code 的 ENUM 宣告本身不是判斷，排除。
if grep -rn "'R1'" "$ROOT"/packages/database/migrations/*.sql "$ROOT"/apps/*/src/*.ts \
     "$ROOT"/packages/domain/src/*.ts | grep -v "CREATE TYPE role_code" >/dev/null 2>&1
then ng "0023：程式或 migration 內出現硬編 'R1' 的稅務確認判斷"
else ok "0023：全庫無硬編 'R1'（確認角色一律由政策版本指定）"; fi

# ── 3 INV-05／GB-02：權威匯入基礎不得有組成 ──
expect_err "INV-05：權威匯入基礎（B）建立組成版本 → 拒絕" \
  "$T1 INSERT INTO basis_composition_version (composition_series_id, version_no, tenant_id,
        engagement_id, basis_id, status)
   VALUES (gen_random_uuid(),1,'$TEN','$ENG','$BASIS_B','DRAFT')" "INV05_COMPOSITION_FORBIDDEN"
expect_err "GB-02：DIRECT_AUTHORITATIVE_IMPORT 缺來源政策 → 拒絕" \
  "$T1 INSERT INTO book_basis (tenant_id, engagement_id, code, source_mode)
   VALUES ('$TEN','$ENG','B2','DIRECT_AUTHORITATIVE_IMPORT')" "check constraint"
expect_err "無混合語意：COMPOSED 卻帶來源政策 → 拒絕" \
  "$T1 INSERT INTO book_basis (tenant_id, engagement_id, code, source_mode, basis_source_policy_version_id)
   VALUES ('$TEN','$ENG','C2','COMPOSED','$POL_OK')" "check constraint"
expect_err "來源政策未批准 → 不構成 GB-02 的依據" \
  "$T1 INSERT INTO book_basis (tenant_id, engagement_id, code, source_mode, basis_source_policy_version_id)
   VALUES ('$TEN','$ENG','B3','DIRECT_AUTHORITATIVE_IMPORT','$POL_DRAFT')" "BASIS_SOURCE_POLICY_NOT_APPROVED"
expect_err "基礎的政策欄位建立後不可變更（改動會追溯翻案 INV-05）" \
  "$T1 UPDATE book_basis SET source_mode='COMPOSED' WHERE basis_id='$BASIS_B'" "BOOK_BASIS_IMMUTABLE"
expect_err "已批准的來源政策不可原地改寫" \
  "$T1 UPDATE basis_source_policy_version SET confirmation_role='R4'
   WHERE basis_source_policy_version_id='$POL_OK'" "BASIS_SOURCE_POLICY_IMMUTABLE"

# ── 4 INV-04 入口：GROUP 層不得進入不允許群組層的基礎 ──
CMP_TMP=21000000-0000-0000-0000-0000000000f1
expect_ok "組成草稿建立（A 基礎第二版，供入口測試）" \
  "$T1 INSERT INTO basis_composition_version (basis_composition_version_id, composition_series_id,
        version_no, tenant_id, engagement_id, basis_id, status)
   VALUES ('$CMP_TMP','21000000-0000-0000-0000-000000000101',2,'$TEN','$ENG','$BASIS_A','DRAFT')"
n=$(APP_C <<<"$T1 SELECT permits_group_layer FROM book_basis WHERE basis_id='$BASIS_A'")
[ "$n" = "f" ] && ok "前置成立：A 基礎 permits_group_layer = false" || ng "前置不成立：A 的 permits_group_layer=$n"
expect_err "INV-04 入口：A 的組成納入 CONSOLIDATION（GROUP）層 → 拒絕" \
  "$T1 INSERT INTO constitutive_layer_item (basis_composition_version_id, layer_id, sign)
   VALUES ('$CMP_TMP','$LAYER_CONSOL',1)" "INV04_GROUP_LAYER_IN_LOCAL_BASIS"
expect_ok "同一組成納入 ENTITY 層則正常" \
  "$T1 INSERT INTO constitutive_layer_item (basis_composition_version_id, layer_id, sign)
   VALUES ('$CMP_TMP','$LAYER_LB',1)"
expect_ok "組成批准（帶 R4 角色快照）" \
  "$T1 UPDATE basis_composition_version SET status='APPROVED', approved_by='$BING',
       approved_at=now(), approval_role='R4' WHERE basis_composition_version_id='$CMP_TMP'"
expect_err "已批准的組成其構成項不可再增刪" \
  "$T1 INSERT INTO constitutive_layer_item (basis_composition_version_id, layer_id, sign)
   VALUES ('$CMP_TMP','$LAYER_GG',1)" "COMPOSITION_IMMUTABLE"
expect_err "已批准的組成版本不可原地改寫（改政策＝新 version_no）" \
  "$T1 UPDATE basis_composition_version SET effective_from='2020-01-01'
   WHERE basis_composition_version_id='$CMP_TMP'" "COMPOSITION_IMMUTABLE"

# ── 5 INV-03／INV-04：調整層級 ──
ADJG=ad000000-0000-0000-0000-0000000000a1
n=$(APP_C <<<"$T1 SELECT ru.unit_scope FROM period_revision pr
     JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
     JOIN reporting_unit ru ON ru.reporting_unit_id = rp.reporting_unit_id
    WHERE pr.period_revision_id='$GRP_PR'")
[ "$n" = "CONSOLIDATION_GROUP" ] && ok "前置成立：群組期間的報告單位為 CONSOLIDATION_GROUP" \
  || ng "前置不成立：群組期間的單位型別為 $n"
expect_err "INV-03：ENTITY 層的調整落在 CONSOLIDATION_GROUP 單位 → 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by,
        basis_from_id, basis_to_id, posting_layer_id)
   VALUES ('$TEN','$ENG','$GRP_PR','層錯配','$JIA','$BASIS_A','$BASIS_C','$LAYER_GG')" "INV03_SCOPE_MISMATCH"
expect_err "INV-03：GROUP 層的調整落在 LEGAL_ENTITY 單位 → 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by,
        basis_from_id, basis_to_id, posting_layer_id)
   VALUES ('$TEN','$ENG','$PR','層錯配','$JIA','$BASIS_A','$BASIS_C','$LAYER_CONSOL')" "INV03_SCOPE_MISMATCH"
expect_err "INV-04：群組層調整寫入不允許群組層的基礎（A）→ 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by,
        basis_from_id, basis_to_id, posting_layer_id)
   VALUES ('$TEN','$ENG','$GRP_PR','回寫法定帳','$JIA','$BASIS_C','$BASIS_A','$LAYER_CONSOL')" \
  "INV04_GROUP_ADJ_INTO_LOCAL_BASIS"
expect_ok "群組層調整寫入允許群組層的基礎（C）＋群組單位 → 通過" \
  "$T1 INSERT INTO adjustment (adjustment_id, tenant_id, engagement_id, period_revision_id, title,
        prepared_by, basis_from_id, basis_to_id, posting_layer_id)
   VALUES ('$ADJG','$TEN','$ENG','$GRP_PR','集團抵銷','$JIA','$BASIS_A','$BASIS_C','$LAYER_CONSOL')"
expect_err "橋樑必須跨兩個基礎（from = to）→ 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by,
        basis_from_id, basis_to_id, posting_layer_id)
   VALUES ('$TEN','$ENG','$PR','自我橋樑','$JIA','$BASIS_C','$BASIS_C','$LAYER_GG')" "ADJ_BASIS_BRIDGE_INVALID"

# ── 6 Rule／RuleVersion：三層歸屬、四類不可混記、SOD-H3 ──
RULE1=40000000-0000-0000-0000-000000000001
RV1=41000000-0000-0000-0000-000000000001
expect_err "rule 三層：PLATFORM 卻帶 tenant → 拒絕" \
  "$T1 INSERT INTO rule (scope_level, tenant_id, rule_type, code, name)
   VALUES ('PLATFORM','$TEN','GROUP_GAAP','P1','平台規則')" "check constraint"
expect_err "rule 三層：TENANT 卻帶 engagement → 拒絕" \
  "$T1 INSERT INTO rule (scope_level, tenant_id, engagement_id, rule_type, code, name)
   VALUES ('TENANT','$TEN','$ENG','GROUP_GAAP','T1','租戶規則')" "check constraint"
expect_err "rule 三層：CLIENT 缺 engagement → 拒絕" \
  "$T1 INSERT INTO rule (scope_level, tenant_id, rule_type, code, name)
   VALUES ('CLIENT','$TEN','GROUP_GAAP','C1','客戶規則')" "check constraint"
n=$(APP_C <<<"$T1 INSERT INTO rule (scope_level, rule_type, code, name)
   VALUES ('PLATFORM','GROUP_GAAP','P9','平台規則')" 2>&1 | grep -c "row-level security\|violates row-level")
[ "$n" -ge 1 ] && ok "0023：app_runtime 寫不出 PLATFORM 規則（RLS WITH CHECK，非應用層自律）" \
  || ng "0023：PLATFORM 規則可被租戶寫入"
n=$(APP_C <<<"$T1 SELECT count(*) FROM rule WHERE scope_level='PLATFORM'")
[ "$n" = "0" ] && ok "0023：本刀不種任何 PLATFORM 規則列（無合法平台發布身分）" || ng "0023：平台規則列數 $n"
expect_ok "rule 建立（CLIENT，GROUP_GAAP）" \
  "$T1 INSERT INTO rule (rule_id, scope_level, tenant_id, engagement_id, rule_type, code, name)
   VALUES ('$RULE1','CLIENT','$TEN','$ENG','GROUP_GAAP','R-GG-01','集團折舊政策差異')"
expect_err "四類不可混記①：規則類型與分層類型不一致 → 拒絕" \
  "$T1 INSERT INTO rule_version (rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by)
   VALUES ('$RULE1',9,'$TEN','10000000-0000-0000-0000-000000000002','BALANCE','$JIA')" \
  "RULE_TYPE_LAYER_MISMATCH"
expect_err "rule_type 未定的分層被引用 → 顯式拒絕（不得默默通過）" \
  "$T1 INSERT INTO rule_version (rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by)
   VALUES ('$RULE1',8,'$TEN','$LAYER_TA','BALANCE','$JIA')" "LAYER_RULE_TYPE_UNSET"
expect_err "AUTO_POST 尚未實作 → fail closed（GB-05）" \
  "$T1 INSERT INTO rule_version (rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by, automation_level)
   VALUES ('$RULE1',7,'$TEN','$LAYER_GG','BALANCE','$JIA','AUTO_POST')" "AUTO_POST_NOT_IMPLEMENTED"
expect_err "required_granularity 沿用既有四值：LINE 不存在 → 拒絕" \
  "$T1 INSERT INTO rule_version (rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by)
   VALUES ('$RULE1',6,'$TEN','$LAYER_GG','LINE','$JIA')" "check constraint"
expect_err "規則版本只能以 DRAFT 建立（不得 INSERT 直達 ACTIVE）" \
  "$T1 INSERT INTO rule_version (rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by, peer_reviewed_by, status)
   VALUES ('$RULE1',5,'$TEN','$LAYER_GG','BALANCE','$JIA','$YI','ACTIVE')" "RULE_VERSION_MUST_START_DRAFT"
expect_ok "規則版本建立為 DRAFT，且 peer_reviewed_by 可為空（草稿必須能存在）" \
  "$T1 INSERT INTO rule_version (rule_version_id, rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by)
   VALUES ('$RV1','$RULE1',1,'$TEN','$LAYER_GG','BALANCE','$JIA')"
expect_err "SOD-H3：未同行覆核不得生效" \
  "$T1 UPDATE rule_version SET status='ACTIVE' WHERE rule_version_id='$RV1'" "SODH3_PEER_REVIEW_REQUIRED"
expect_err "SOD-H3：草案人不得同行覆核自己" \
  "$T1 UPDATE rule_version SET peer_reviewed_by='$JIA', status='ACTIVE'
   WHERE rule_version_id='$RV1'" "SODH3_PEER_REVIEW_REQUIRED"
expect_ok "SOD-H3：另一自然人同行覆核後可生效" \
  "$T1 UPDATE rule_version SET peer_reviewed_by='$YI', status='ACTIVE' WHERE rule_version_id='$RV1'"
expect_err "SOD-H3 基準不可改寫：草案人不可變更" \
  "$T1 UPDATE rule_version SET drafted_by='$YI' WHERE rule_version_id='$RV1'" "RULE_VERSION_IMMUTABLE"
expect_err "SOD-H3 基準不可改寫：同行覆核人首次設定後不可換人" \
  "$T1 UPDATE rule_version SET peer_reviewed_by='$BING' WHERE rule_version_id='$RV1'" "RULE_VERSION_IMMUTABLE"

# 四類不可混記②：Adjustment 引用規則時比對「層」而非只比 rule_type
RV2=41000000-0000-0000-0000-000000000002
expect_ok "第二個規則版本（DEFERRED_TAX 類，掛 DEFERRED_TAX 層）" \
  "$T1 INSERT INTO rule (rule_id, scope_level, tenant_id, engagement_id, rule_type, code, name)
   VALUES ('40000000-0000-0000-0000-000000000002','CLIENT','$TEN','$ENG','DEFERRED_TAX','R-DT-01','稅效果');
   INSERT INTO rule_version (rule_version_id, rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by)
   VALUES ('$RV2','40000000-0000-0000-0000-000000000002',1,'$TEN',
           '10000000-0000-0000-0000-000000000004','BALANCE','$JIA');
   UPDATE rule_version SET peer_reviewed_by='$YI', status='ACTIVE' WHERE rule_version_id='$RV2'"
expect_err "四類不可混記②：調整的分層與所引用規則版本的分層不一致 → 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by,
        basis_from_id, basis_to_id, posting_layer_id, rule_version_id)
   VALUES ('$TEN','$ENG','$PR','混記','$JIA','$BASIS_A','$BASIS_C','$LAYER_GG','$RV2')" \
  "ADJ_LAYER_RULE_MISMATCH"
RV3=41000000-0000-0000-0000-000000000003
expect_ok "第三個規則版本維持 DRAFT（供「只能引用 ACTIVE」測試）" \
  "$T1 INSERT INTO rule_version (rule_version_id, rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by)
   VALUES ('$RV3','$RULE1',2,'$TEN','$LAYER_GG','BALANCE','$JIA')"
n=$(APP_C <<<"$T1 SELECT status||'/'||(SELECT code FROM posting_layer p WHERE p.layer_id = rv.posting_layer_id)
     FROM rule_version rv WHERE rule_version_id='$RV3'")
[ "$n" = "DRAFT/GROUP_GAAP_ADJ" ] && ok "前置成立：RV3 為 DRAFT 且分層與調整相同（唯一差異是未生效）" \
  || ng "前置不成立：RV3 為 $n"
expect_err "只能引用已生效的規則版本（分層相同也不例外）" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by,
        basis_from_id, basis_to_id, posting_layer_id, rule_version_id)
   VALUES ('$TEN','$ENG','$PR','引用草稿','$JIA','$BASIS_A','$BASIS_C','$LAYER_GG','$RV3')" \
  "RULE_VERSION_NOT_ACTIVE"

# ── 7 TaxBasisObservation：欄位契約、AMENDED、確認角色 ──
# 觀測引用既有的來源資料集（來源集合有冪等唯一鍵，不另建重複列）
SDS=$(APP_C <<<"$T1 SELECT source_dataset_id FROM source_dataset ORDER BY source_dataset_id LIMIT 1")
[ ${#SDS} -eq 36 ] && ok "前置成立：已有可引用的來源資料集" || ng "前置不成立：來源資料集為 '$SDS'"
expect_err "AMENDED 尚未實作 → fail closed（取代鏈留待更正申告刀）" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, account_id, amount, evidence_status, source_dataset_id, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','$ACC1',1,'AMENDED','$SDS','$BING')" \
  "AMENDED_NOT_IMPLEMENTED"
expect_err "觀測只適用於權威匯入基礎（掛到 A）→ 拒絕" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, account_id, amount, evidence_status, source_dataset_id, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_A','$ACC1',1,'FILED','$SDS','$BING')" \
  "TAX_OBS_BASIS_NOT_DIRECT"
expect_err "欄位契約：非 MISSING 缺金額／來源資料集 → 拒絕" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, account_id, evidence_status, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','$ACC1','FILED','$BING')" \
  "TAX_OBS_FIELD_CONTRACT"
expect_err "欄位契約：MISSING 缺原因／負責人／截止日 → 拒絕" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, evidence_status)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','MISSING')" \
  "TAX_OBS_FIELD_CONTRACT"
expect_err "欄位契約：MISSING 不得帶確認人（沒有數字就沒有人能確認它）" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, evidence_status, missing_reason, owner_id, due_date, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','MISSING','申告未完成','$JIA','2026-06-30','$BING')" \
  "TAX_OBS_FIELD_CONTRACT"
# 確認角色：先證明前置狀態成立，再驗拒絕理由（避免以錯誤理由通過）
n=$(APP_C <<<"$T1 SELECT confirmation_role FROM basis_source_policy_version WHERE basis_source_policy_version_id='$POL_OK'")
[ "$n" = "R1" ] && ok "前置成立：政策指定的確認角色為 R1" || ng "前置不成立：政策角色為 $n"
n=$(APP_C <<<"$T1 SELECT count(*) FROM role_assignment WHERE user_id='$JIA' AND engagement_id='$ENG' AND revoked_at IS NULL")
[ "$n" -ge 1 ] && ok "前置成立：甲確實存在且被指派於本案件（只是沒有 R1）" || ng "前置不成立：甲的指派數 $n"
expect_err "GB-02：確認人在本案件但角色不符（甲無 R1）→ 拒絕" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, account_id, amount, evidence_status, source_dataset_id, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','$ACC1',1000,'FILED','$SDS','$JIA')" \
  "TAX_CONFIRMER_ROLE_INVALID"
OBS1=51000000-0000-0000-0000-000000000001
expect_ok "持有 R1 的確認人（丙）→ 通過" \
  "$T1 INSERT INTO tax_basis_observation (observation_id, tenant_id, engagement_id, reporting_unit_id,
        as_of_date, book_basis_id, account_id, amount, evidence_status, source_dataset_id,
        confirmed_by, confirmed_role)
   VALUES ('$OBS1','$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','$ACC1',
           1000,'FILED','$SDS','$BING','R6')"
n=$(APP_C <<<"$T1 SELECT confirmed_role||'/'||(confirmed_at IS NOT NULL) FROM tax_basis_observation WHERE observation_id='$OBS1'")
[ "$n" = "R1/true" ] && ok "確認角色快照由 DB 寫入並覆寫呼叫端宣告（宣告 R6 → 實存 R1）" \
  || ng "確認角色未被 DB 覆寫：$n"
expect_err "唯一性：同一（基礎,單位,日期,科目）重複 → 拒絕" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, account_id, amount, evidence_status, source_dataset_id, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','$ACC1',1,'FILED','$SDS','$BING')" \
  "duplicate key"
expect_ok "整體缺漏（account_id 為 NULL）可登記一次" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, evidence_status, missing_reason, owner_id, due_date)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000002','$ASOF','$BASIS_B','MISSING','申告未完成','$JIA','2026-06-30')"
expect_err "NULLS NOT DISTINCT：同一日期第二筆整體缺漏 → 拒絕（NULL 不得被視為互異）" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, evidence_status, missing_reason, owner_id, due_date)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000002','$ASOF','$BASIS_B','MISSING','再登記一次','$JIA','2026-07-31')" \
  "duplicate key"
expect_err "確認人建立後不可變更" \
  "$T1 UPDATE tax_basis_observation SET confirmed_by='$YI' WHERE observation_id='$OBS1'" "TAX_OBS_IMMUTABLE"
n=$(APP_C <<<"$T1 UPDATE role_assignment SET revoked_at=now()
      WHERE user_id='$BING' AND role='R1'; SELECT confirmed_role FROM tax_basis_observation WHERE observation_id='$OBS1'")
[ "$n" = "R1" ] && ok "INV-11：角色指派撤銷後，既有觀測的角色快照不變" || ng "角色快照被追溯改變：$n"
expect_err "撤銷後：同一人不得再建立新觀測（有效未撤銷才算數）" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, account_id, amount, evidence_status, source_dataset_id, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','2026-03-30','$BASIS_B','$ACC1',1,'FILED','$SDS','$BING')" \
  "TAX_CONFIRMER_ROLE_INVALID"
PSQL_C <<<"$T1 UPDATE role_assignment SET revoked_at=NULL WHERE user_id='$BING' AND role='R1'" >/dev/null

# ── 8 分層快照與版本界線（manifest 是否凍結組成） ──
MANI06=ee110000-0000-0000-0000-0000000000c3
RUN06=ee110000-0000-0000-0000-0000000000c9
expect_ok "含組成的 Manifest ＋ Run（分層模型之後的 run）" \
  "$T1 INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
   VALUES ('$MANI06','$TEN','$ENG','$PR','NO_FX','sqlcanon-1','h3','$JIA');
   INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
        domain_version_kind, domain_version_value, content_canonical, content_hash, payload) VALUES
     ('$TEN','$MANI06','BASIS_COMPOSITION','$COMP_A','COMPOSITION_VERSION_NO','1','cA','hA',
      jsonb_build_object('basis_id','$BASIS_A')),
     ('$TEN','$MANI06','BASIS_COMPOSITION','$COMP_C','COMPOSITION_VERSION_NO','1','cC','hC',
      jsonb_build_object('basis_id','$BASIS_C'));
   INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, request_key, request_content_hash, engine_version, created_by)
   VALUES ('$RUN06','$TEN','$ENG','$PR','$B1','$MANI06','PREVIEW',
           'ee110000-0000-0000-0000-0000000000a9','rc9','calc-engine-1','$JIA')"
expect_err "版本界線：含組成的 run，快照未標分層 → 拒絕（不靠 worker 紀律）" \
  "$T1 INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit)
   VALUES ('$TEN','$RUN06','SOURCE_TB','$ACC1','1002','银行存款',1000,0)" "BSL_POSTING_LAYER_REQUIRED"
expect_err "版本界線：不含組成的歷史 run，快照不得標分層" \
  "$T1 INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, posting_layer_id,
        account_id, account_code, account_name, debit, credit)
   VALUES ('$TEN','$RUNB','ADJUSTMENT','$LAYER_GG','$ACC1','1002','银行存款',1,0)" "BSL_POSTING_LAYER_UNEXPECTED"
n=$(APP_C <<<"$T1 SELECT count(*) FROM balance_snapshot_line
      WHERE calculation_run_id='$RUNA' AND posting_layer_id IS NULL")
[ "$n" -ge 1 ] && ok "歷史 run 的快照未被回寫（posting_layer_id 維持 NULL）" || ng "歷史快照被回寫"
expect_ok "含組成的 run：帶分層的快照（A=1000；C=1000+200；ACC2 僅調整層 -200）" \
  "$T1 INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, posting_layer_id,
        account_id, account_code, account_name, debit, credit) VALUES
     ('$TEN','$RUN06','SOURCE_TB','$LAYER_LB','$ACC1','1002','银行存款',1000,0),
     ('$TEN','$RUN06','ADJUSTMENT','$LAYER_GG','$ACC1','1002','银行存款',200,0),
     ('$TEN','$RUN06','ADJUSTMENT','$LAYER_GG','$ACC2','6602','管理费用',0,200)"
n=$(APP_C <<<"$T1 SELECT amount::text FROM fn_basis_account_balance('$RUN06','$BASIS_C') WHERE account_id='$ACC1'")
[ "$n" = "1200.00" ] && ok "INV-01：C 基礎餘額＝LOCAL_BOOK＋GROUP_GAAP_ADJ（逐科目由組成加總）" \
  || ng "INV-01：C 的 1002 餘額為 ${n}（預期 1200）"
n=$(APP_C <<<"$T1 SELECT amount::text FROM fn_basis_account_balance('$RUN06','$BASIS_A') WHERE account_id='$ACC1'")
[ "$n" = "1000.00" ] && ok "INV-01：A 基礎餘額只含 LOCAL_BOOK" || ng "INV-01：A 的 1002 餘額為 ${n}（預期 1000）"
n=$(APP_C <<<"$T1 SELECT count(*) FROM fn_basis_account_balance('$RUNA','$BASIS_C')" 2>&1 | grep -c "RECON_RUN_PREDATES_BASIS_MODEL")
[ "$n" -ge 1 ] && ok "歷史 run 無組成凍結 → 基礎餘額 fail closed（不得把 SOURCE_TB 當成 LOCAL_BOOK）" \
  || ng "歷史 run 竟能算出基礎餘額"

# ── 9 調節模型：DRAFT 自由增修、FINALIZE 一次驗 INV-02、之後全凍結 ──
REC1=60000000-0000-0000-0000-000000000001
expect_err "調節只能以 DRAFT 建立" \
  "$T1 INSERT INTO basis_reconciliation (tenant_id, engagement_id, reporting_unit_id,
        period_revision_id, from_basis_id, to_basis_id, calculation_run_id, status)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$PR','$BASIS_A','$BASIS_C','$RUN06','FINALIZED')" \
  "RECON_INSERT_MUST_BE_DRAFT"
expect_ok "調節建立（A→C，綁定既有 run）" \
  "$T1 INSERT INTO basis_reconciliation (reconciliation_id, tenant_id, engagement_id, reporting_unit_id,
        period_revision_id, from_basis_id, to_basis_id, calculation_run_id)
   VALUES ('$REC1','$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$PR','$BASIS_A','$BASIS_C','$RUN06')"
expect_ok "DRAFT 期間可自由新增明細（不受即時平衡檢查——第一列必然不平）" \
  "$T1 INSERT INTO reconciliation_line (tenant_id, reconciliation_id, account_id, amount,
        source_adjustment_id, description)
   VALUES ('$TEN','$REC1','$ACC1',200,'$ADJ','集團折舊政策差異')"
expect_err "調節明細必須說得出來源（兩者皆空）→ 拒絕" \
  "$T1 INSERT INTO reconciliation_line (tenant_id, reconciliation_id, account_id, amount, description)
   VALUES ('$TEN','$REC1','$ACC2',-200,'無來源')" "check constraint"
expect_err "尾差自動結案尚未實作 → fail closed（單筆與累積容許值皆無從判定）" \
  "$T1 INSERT INTO reconciliation_difference (tenant_id, reconciliation_id, account_id, amount,
        reason_class, resolution_status)
   VALUES ('$TEN','$REC1','$ACC2',-200,'ROUNDING','RESOLVED_BY_POLICY')" "INV24_THRESHOLD_NOT_IMPLEMENTED"
n=$(APP_C <<<"$T1 SELECT count(*) FROM reconciliation_line WHERE reconciliation_id='$REC1'")
[ "$n" = "1" ] && ok "前置成立：ACC1 已有調節明細、ACC2 尚無任何去處" || ng "前置不成立：明細數 $n"
n=$(APP_C <<<"$T1 SELECT fn_reconciliation_finalize('$REC1','$JIA')" 2>&1 | grep -c "INV02_RECONCILIATION_IMBALANCE")
[ "$n" -ge 1 ] && ok "INV-02：ACC2 殘差無去處 → FINALIZE 整筆拒絕（尾差不得靜默吸收）" \
  || ng "INV-02：不平衡竟可定稿"
n=$(APP_C <<<"$T1 SELECT status FROM basis_reconciliation WHERE reconciliation_id='$REC1'")
[ "$n" = "DRAFT" ] && ok "FINALIZE 被拒後調節仍為 DRAFT（整筆交易回滾）" || ng "FINALIZE 失敗卻改了狀態：$n"
expect_ok "殘差登記為顯式差異（OPEN；不得靜默吸收）" \
  "$T1 INSERT INTO reconciliation_difference (tenant_id, reconciliation_id, account_id, amount,
        reason_class, owner_id, due_date)
   VALUES ('$TEN','$REC1','$ACC2',-200,'UNEXPLAINED','$JIA','2026-06-30')"
n=$(APP_C <<<"$T1 SELECT fn_reconciliation_finalize('$REC1','$JIA')" 2>&1 | grep -c "ERROR")
[ "$n" = "0" ] && ok "INV-02 成立 → FINALIZE 通過" || ng "FINALIZE 仍失敗"
n=$(APP_C <<<"$T1 SELECT status FROM basis_reconciliation WHERE reconciliation_id='$REC1'")
[ "$n" = "FINALIZED" ] && ok "定稿後狀態為 FINALIZED，且同交易寫入 DomainEvent" || ng "狀態為 $n"
n=$(APP_C <<<"$T1 SELECT count(*) FROM audit_event WHERE event_type='basis_reconciliation.finalized'
      AND object_id='$REC1'")
[ "$n" = "1" ] && ok "調節定稿事件已寫入稽核軌跡" || ng "定稿事件數 $n"
expect_err "定稿後明細不可再增加" \
  "$T1 INSERT INTO reconciliation_line (tenant_id, reconciliation_id, account_id, amount,
        source_adjustment_id, description)
   VALUES ('$TEN','$REC1','$ACC1',1,'$ADJ','事後追加')" "RECON_FINALIZED_IMMUTABLE"
expect_err "定稿後差異不可改（本刀不提供結案功能；未來以獨立 append-only 紀錄擴充）" \
  "$T1 UPDATE reconciliation_difference SET resolution_status='EXPLAINED' WHERE reconciliation_id='$REC1'" \
  "RECON_FINALIZED_IMMUTABLE"
n=$(APP_C <<<"$T1 UPDATE basis_reconciliation SET status='DRAFT' WHERE reconciliation_id='$REC1'" 2>&1 | grep -c "permission denied")
[ "$n" -ge 1 ] && ok "唯一入口：app_runtime 對 basis_reconciliation 無 UPDATE（不得繞過 finalize）" \
  || ng "調節狀態可被直接改寫"
n=$(APP_C <<<"$T1 SELECT count(*) FROM reconciliation_difference
      WHERE reconciliation_id='$REC1' AND resolution_status='OPEN'")
[ "$n" = "1" ] && ok "未解釋差異數以 resolution_status='OPEN' 查得（不看 reason_class）" || ng "OPEN 差異數 $n"

# ── 10 INV-05：涉權威匯入基礎的調節在 FINALIZE 時驗觀測涵蓋 ──
REC2=60000000-0000-0000-0000-000000000002
expect_ok "調節建立（A→B，端點含權威匯入基礎）" \
  "$T1 INSERT INTO basis_reconciliation (reconciliation_id, tenant_id, engagement_id, reporting_unit_id,
        period_revision_id, from_basis_id, to_basis_id, calculation_run_id)
   VALUES ('$REC2','$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$PR','$BASIS_A','$BASIS_B','$RUN06');
   INSERT INTO reconciliation_line (tenant_id, reconciliation_id, account_id, amount,
        source_rule_version_id, description)
   VALUES ('$TEN','$REC2','$ACC2',0,'$RV1','稅務差異（本科目無觀測）')"
n=$(APP_C <<<"$T1 SELECT count(*) FROM tax_basis_observation
      WHERE book_basis_id='$BASIS_B' AND account_id='$ACC2' AND as_of_date='$ASOF'")
[ "$n" = "0" ] && ok "前置成立：6602 於期末確實沒有稅務基礎觀測" || ng "前置不成立：觀測數 $n"
n=$(APP_C <<<"$T1 SELECT fn_reconciliation_finalize('$REC2','$JIA')" 2>&1 | grep -c "INV05_TAX_OBSERVATION_MISSING")
[ "$n" -ge 1 ] && ok "INV-05：缺已確認觀測的科目 → FINALIZE 拒絕（掛在具體操作上）" \
  || ng "INV-05：缺觀測竟可定稿"

# ── 11 INV-21：已被鎖定期間的凍結清單引用的組成不得變更 ──
n=$(APP_C <<<"$T1 SELECT status FROM period_revision WHERE period_revision_id='$PR'")
[ "$n" != "LOCKED" ] && ok "前置成立：本期尚未 LOCKED，組成仍可退役" || ng "前置不成立：期間已 $n"
expect_ok "未鎖定期間：組成可退役（APPROVED → RETIRED）" \
  "$T1 UPDATE basis_composition_version SET status='RETIRED' WHERE basis_composition_version_id='$CMP_TMP'"
PSQL_C <<<"UPDATE period_revision SET status='LOCKED' WHERE period_revision_id='$PR'" >/dev/null 2>&1 \
  || PSQL_C <<<"ALTER TABLE period_revision DISABLE TRIGGER trg_period_transition;
                UPDATE period_revision SET status='LOCKED' WHERE period_revision_id='$PR';
                ALTER TABLE period_revision ENABLE TRIGGER trg_period_transition;" >/dev/null
expect_err "INV-21：期間已 LOCKED，其凍結清單引用的組成不得再變更" \
  "$T1 UPDATE basis_composition_version SET status='RETIRED' WHERE basis_composition_version_id='$COMP_C'" \
  "INV21_LOCKED_COMPOSITION"
PSQL_C <<<"ALTER TABLE period_revision DISABLE TRIGGER trg_period_transition;
           UPDATE period_revision SET status='SETUP' WHERE period_revision_id='$PR';
           ALTER TABLE period_revision ENABLE TRIGGER trg_period_transition;" >/dev/null

# ── 12 AC-BAS-001：新增第四種基礎零 DDL ──
BEFORE=$(APP_C <<<"$T1 SELECT md5(string_agg(basis_id::text||code, ',' ORDER BY code)) FROM book_basis")
BASIS_D=20000000-0000-0000-0000-0000000000d1
CMP_D=21000000-0000-0000-0000-0000000000d1
expect_ok "新增第四基礎（D／IFRS）＋組成＋調整＋物化分錄——全部只用 INSERT" \
  "$T1 INSERT INTO book_basis (basis_id, tenant_id, engagement_id, code, jurisdiction, framework,
        source_mode, permits_group_layer)
   VALUES ('$BASIS_D','$TEN','$ENG','D','XX','IFRS','COMPOSED',false);
   INSERT INTO basis_composition_version (basis_composition_version_id, composition_series_id,
        version_no, tenant_id, engagement_id, basis_id, status)
   VALUES ('$CMP_D','21000000-0000-0000-0000-0000000001d1',1,'$TEN','$ENG','$BASIS_D','DRAFT');
   INSERT INTO constitutive_layer_item (basis_composition_version_id, layer_id, sign) VALUES
     ('$CMP_D','$LAYER_LB',1),('$CMP_D','$LAYER_GG',1);
   UPDATE basis_composition_version SET status='APPROVED', approved_by='$BING', approved_at=now(),
          approval_role='R4' WHERE basis_composition_version_id='$CMP_D';
   INSERT INTO adjustment (adjustment_id, tenant_id, engagement_id, period_revision_id, title,
        prepared_by, basis_from_id, basis_to_id, posting_layer_id)
   VALUES ('ad000000-0000-0000-0000-0000000000d1','$TEN','$ENG','$PR','IFRS 調整','$JIA',
           '$BASIS_A','$BASIS_D','$LAYER_GG')"
AFTER=$(APP_C <<<"$T1 SELECT md5(string_agg(basis_id::text||code, ',' ORDER BY code))
        FROM book_basis WHERE code <> 'D'")
[ "$BEFORE" = "$AFTER" ] && ok "AC-BAS-001：既有 A／B／C 未被修改（逐列雜湊比對）" || ng "既有基礎被改動"
n=$(APP_C <<<"$T1 SELECT count(*) FROM constitutive_layer_item WHERE basis_composition_version_id='$CMP_D'")
[ "$n" = "2" ] && ok "AC-BAS-001：第四基礎的組成成立，全程零 DDL" || ng "第四基礎組成項數 $n"

# ── 13 RLS（INV-18） ──
n=$(APP_C <<<"$T2 SELECT count(*) FROM book_basis")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的基礎" || ng "RLS：基礎洩漏 $n 筆"
n=$(APP_C <<<"$T2 SELECT count(*) FROM tax_basis_observation")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的稅務基礎觀測" || ng "RLS：觀測洩漏 $n 筆"
n=$(APP_C <<<"$T2 SELECT count(*) FROM basis_reconciliation")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的調節結果" || ng "RLS：調節洩漏 $n 筆"
n=$(APP_C <<<"$T2 SELECT count(*) FROM constitutive_layer_item")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的構成項（以父版本的租戶隔離）" || ng "RLS：構成項洩漏 $n 筆"
n=$(APP_C <<<"$T2 SELECT count(*) FROM rule")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的客戶規則" || ng "RLS：規則洩漏 $n 筆"


echo ""
echo "通過 $pass ／ 失敗 $fail"
[ $fail -eq 0 ]
