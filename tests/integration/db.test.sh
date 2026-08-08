#!/usr/bin/env bash
# DB 層整合測試（聚合入口）：從零重建 → 依序驗證各領域守衛。
# 每條測試對應設計書的一個識別碼；「應失敗」的測試以 psql 回傳非零為 PASS。
#
# 常改的四個領域已抽成可單跑的檔案（tests/integration/db/），日常請用
#   pnpm test:db:mapping / :adjustment / :period / :basis
# 只跑受影響的一段；本檔負責完整一輪，切片收口與 push 前跑。
set -uo pipefail
DB_TEST_AGGREGATE=1
. "$(cd "$(dirname "$0")/lib" && pwd)/harness.sh"
DB_TEST_HARNESS=1
DOMAIN="$(cd "$(dirname "$0")/db" && pwd)"

echo "══ DB 整合測試（${DB}）══"
bash "$ROOT/packages/database/src/db-reset.sh" "$DB" >/dev/null 2>&1 || { echo "重建失敗"; exit 1; }
ok "migration 可從零重建資料庫"
fx_core
ok "種子資料建立（2 租戶、1 案件、1 批次、A/B/C 三基礎）"

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


. "$DOMAIN/mapping.test.sh"
. "$DOMAIN/adjustment.test.sh"

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


. "$DOMAIN/period.test.sh"
. "$DOMAIN/basis.test.sh"

echo ""
echo "通過 $pass ／ 失敗 $fail"
[ $fail -eq 0 ]
