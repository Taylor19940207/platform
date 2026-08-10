#!/usr/bin/env bash
# Adjustment 生命週期與 SoD（0007／0008／0009）
# 可單跑（自行重建 DB 並補齊前置），也可由 tests/integration/db.test.sh 依序聚合執行。
if [ -z "${DB_TEST_HARNESS:-}" ]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
  DB_TEST_HARNESS=1; STANDALONE=1
  echo "══ Adjustment 生命週期與 SoD（0007／0008／0009）（${DB}）══"
fi
need fx_reset fx_core fx_accounts

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

[ "${STANDALONE:-0}" = "1" ] && summary

# ── 自動保存併發欄位（0025／0026／0027） ──
expect_err "0027：三欄不得只寫一部分（無來源卻有序號）" \
  "$T1 UPDATE adjustment SET client_save_sequence = 9 WHERE adjustment_id='$ADJ2'" \
  "adjustment_autosave_all_or_none"
# 這個方向由 0026 的觸發器先擋下（觸發器早於 CHECK 執行）——記錄實際擋下的那一層，
# 不假裝是 CHECK 攔的。反向（無來源卻有序號）觸發器管不到，才由上一條的 CHECK 兜底。
expect_err "0026：有來源卻缺內容雜湊 → 拒絕（觸發器層）" \
  "$T1 UPDATE adjustment SET edit_session_id='11110000-0000-4000-8000-00000000000a',
       client_save_sequence=1, last_saved_at=now(), last_saved_by='$JIA'
   WHERE adjustment_id='$ADJ2'" "AUTOSAVE_FIELDS_PAIRED"
expect_ok "三欄成組寫入（DRAFTING 階段）→ 通過" \
  "$T1 UPDATE adjustment SET edit_session_id='11110000-0000-4000-8000-00000000000a',
       client_save_sequence=1, last_save_content_hash='h1', last_saved_at=now(), last_saved_by='$JIA'
   WHERE adjustment_id='$ADJ2'"
expect_err "0025：同一來源的序號不得倒退（亂序舊請求不得覆蓋新內容）" \
  "$T1 UPDATE adjustment SET client_save_sequence=0, last_save_content_hash='h0'
   WHERE adjustment_id='$ADJ2'" "SAVE_SEQUENCE_REGRESSION"
# 離開草稿後併發控制欄位即凍結。用 ADJ4（PENDING_REVIEW）而非 ADJ（APPROVED）：
# 已批准的列會先被「已批准調整不可修改」擋下，那樣就驗不到本條守衛。
n=$(APP_C <<<"$T1 SELECT status FROM adjustment WHERE adjustment_id='$ADJ4'")
[ "$n" != "DRAFTING" ] && [ "$n" != "APPROVED" ] \
  && ok "前置成立：ADJ4 已離開 DRAFTING（${n}）但尚未批准" \
  || ng "前置不成立：ADJ4 狀態為 $n"
expect_err "0025：離開 DRAFTING 後併發控制欄位不可再變更" \
  "$T1 UPDATE adjustment SET edit_session_id='11110000-0000-4000-8000-00000000000b',
       client_save_sequence=5, last_save_content_hash='h5', last_saved_at=now(), last_saved_by='$JIA'
   WHERE adjustment_id='$ADJ4'" "AUTOSAVE_FIELDS_DRAFT_ONLY"

