#!/usr/bin/env bash
# 期間生命週期（0022）
# 可單跑（自行重建 DB 並補齊前置），也可由 tests/integration/db.test.sh 依序聚合執行。
if [ -z "${DB_TEST_HARNESS:-}" ]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
  DB_TEST_HARNESS=1; STANDALONE=1
  echo "══ 期間生命週期（0022）（${DB}）══"
fi
need fx_reset fx_core fx_accounts

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
  || ng "0022：新建修訂預設為 ${st}（應為 SETUP）"

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

[ "${STANDALONE:-0}" = "1" ] && summary
