#!/usr/bin/env bash
# 折算與 CTA（0030）——SLICE-M3-02 的 DB 層負面測試。
# 可單跑，也可由 tests/integration/db.test.sh 依序聚合執行。
#
# 本檔驗的不是「折算算得對不對」（那是端到端算例的事），而是
# **所有繞道都被封住**：缺率、缺分類、缺期初值、lots 合計不符、
# 自簽匯率、人手寫 CTA、明細與彙總不符。
if [ -z "${DB_TEST_HARNESS:-}" ]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
  DB_TEST_HARNESS=1; STANDALONE=1
  echo "══ 折算與 CTA（0030）（${DB}）══"
fi
need() { :; }
fx_reset; fx_core; fx_accounts

FXV=f0300000-0000-0000-0000-000000000001      # 匯率版本
FXV2=f0300000-0000-0000-0000-000000000002
OBS_CLOSE=f0310000-0000-0000-0000-000000000001
OBS_AVG=f0310000-0000-0000-0000-000000000002
OBS_HIST=f0310000-0000-0000-0000-000000000003
POLV=f0320000-0000-0000-0000-000000000001      # 折算政策版本
SETV=f0330000-0000-0000-0000-000000000001      # 權益批次集合版本
SERIES=f0330000-0000-0000-0000-000000000101
P1=dddddddd-0000-0000-0000-000000000001        # 2026-03（fx_core：${UNIT}）
CTA_ACC=ac000000-0000-0000-0000-000000000001   # 借用 fx_accounts 的科目當 CTA 落點

# ══ 1　Currency 平台參照主檔 ═══════════════════════════════════════
n=$(APP_C <<<"SELECT count(*) FROM currency WHERE currency_code='JPY' AND minor_unit=0")
[ "$n" = "1" ] && ok "0030：Currency 主檔可讀，JPY 的 minor_unit 為 0" \
  || ng "0030：Currency 主檔讀不到（${n}）"
n=$(APP_C <<<"UPDATE currency SET minor_unit=2 WHERE currency_code='JPY'" 2>&1 | grep -c "permission denied")
[ "$n" -ge 1 ] && ok "0030：app_runtime 不得修改 Currency（平台參照主檔）" \
  || ng "0030：app_runtime 改得動 Currency"
expect_err "0030：minor_unit 超出範圍 → 拒絕" \
  "INSERT INTO currency (currency_code, minor_unit) VALUES ('XXX',9)" "violates check constraint"

# ══ 2　顯式前期連結 ═══════════════════════════════════════════════
PB=d0300000-0000-0000-0000-000000000001; PC=d0300000-0000-0000-0000-000000000002
_has reporting_period "reporting_period_id = '$PB'" || PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO reporting_unit (reporting_unit_id, tenant_id, engagement_id, unit_scope, name)
VALUES ('b0300000-0000-0000-0000-000000000001','$TEN','$ENG','LEGAL_ENTITY','FX 第二單位');
INSERT INTO fiscal_calendar (fiscal_calendar_id, tenant_id, engagement_id, name, year_start_month)
VALUES ('f0340000-0000-0000-0000-000000000001','$TEN','$ENG','FX 別曆',1);
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id,
        fiscal_calendar_id, label, start_date, end_date) VALUES
  ('$PB','$TEN','$ENG','$UNIT','$CAL','FX-2028-05','2028-05-01','2028-05-31'),
  ('$PC','$TEN','$ENG','$UNIT','$CAL','FX-2028-06','2028-06-01','2028-06-30');
SQL
expect_ok  "0030：期間可明示前期連結" \
  "$T1 UPDATE reporting_period SET previous_reporting_period_id='$PB' WHERE reporting_period_id='$PC'"
expect_err "0030：前期連結建立後不可變更" \
  "$T1 UPDATE reporting_period SET previous_reporting_period_id='$P1' WHERE reporting_period_id='$PC'" \
  "PREVIOUS_PERIOD_IMMUTABLE"
expect_err "0030：兩個期間不得指向同一前期（延續鏈分岔）" \
  "$T1 INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id,
        fiscal_calendar_id, label, start_date, end_date, previous_reporting_period_id)
   VALUES ('d0300000-0000-0000-0000-0000000000fa','$TEN','$ENG','$UNIT','$CAL','FX-分岔',
           '2028-07-01','2028-07-31','$PB')" \
  "duplicate key"
expect_err "0030：前期不得指向自己" \
  "$T1 UPDATE reporting_period SET previous_reporting_period_id='$PB' WHERE reporting_period_id='$PB'" \
  "PREVIOUS_PERIOD_SELF_REFERENCE"
expect_err "0030：前期不得跨報告單位" \
  "$T1 INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id,
        fiscal_calendar_id, label, start_date, end_date, previous_reporting_period_id)
   VALUES ('d0300000-0000-0000-0000-0000000000fe','$TEN','$ENG','b0300000-0000-0000-0000-000000000001',
           '$CAL','FX-跨單位','2028-07-01','2028-07-31','$P1')" \
  "PREVIOUS_PERIOD_UNIT_MISMATCH"
expect_err "0030：前期不得跨曆別" \
  "$T1 INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id,
        fiscal_calendar_id, label, start_date, end_date, previous_reporting_period_id)
   VALUES ('d0300000-0000-0000-0000-0000000000fd','$TEN','$ENG','$UNIT',
           'f0340000-0000-0000-0000-000000000001','FX-跨曆','2028-08-01','2028-08-31','$P1')" \
  "PREVIOUS_PERIOD_CALENDAR_MISMATCH"
expect_err "0030：前期的期末必須早於本期期初" \
  "$T1 INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id,
        fiscal_calendar_id, label, start_date, end_date, previous_reporting_period_id)
   VALUES ('d0300000-0000-0000-0000-0000000000fc','$TEN','$ENG','$UNIT','$CAL','FX-倒序',
           '2028-01-01','2028-01-31','$PC')" \
  "PREVIOUS_PERIOD_NOT_EARLIER"
expect_err "0030：首期不得有前期" \
  "$T1 INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id,
        fiscal_calendar_id, label, start_date, end_date, is_initial_period, previous_reporting_period_id)
   VALUES ('d0300000-0000-0000-0000-0000000000fb','$TEN','$ENG','$UNIT','$CAL','FX-首期有前期',
           '2028-09-01','2028-09-30',true,'$PC')" \
  "reporting_period_initial_has_no_previous"

# ══ 3　幣別角色指派（INV-22 (a)）═══════════════════════════════════
expect_ok  "0030：建立 FUNCTIONAL=JPY 指派" \
  "$T1 INSERT INTO reporting_unit_currency_assignment (tenant_id, engagement_id, reporting_unit_id,
        currency_role, currency_code, effective_range, created_by)
   VALUES ('$TEN','$ENG','$UNIT','FUNCTIONAL','JPY','[2020-01-01,)','$JIA')"
expect_ok  "0030：同單位可另有 REPORTING=CNY 指派" \
  "$T1 INSERT INTO reporting_unit_currency_assignment (tenant_id, engagement_id, reporting_unit_id,
        currency_role, currency_code, effective_range, created_by)
   VALUES ('$TEN','$ENG','$UNIT','REPORTING','CNY','[2020-01-01,)','$JIA')"
expect_err "0030 INV-22(a)：同時點第二個 FUNCTIONAL → 拒絕" \
  "$T1 INSERT INTO reporting_unit_currency_assignment (tenant_id, engagement_id, reporting_unit_id,
        currency_role, currency_code, effective_range, created_by)
   VALUES ('$TEN','$ENG','$UNIT','FUNCTIONAL','USD','[2024-01-01,)','$JIA')" \
  "conflicting key value\|exclusion constraint"
expect_err "0030 INV-22(a)：REPORTING 同樣不得多值" \
  "$T1 INSERT INTO reporting_unit_currency_assignment (tenant_id, engagement_id, reporting_unit_id,
        currency_role, currency_code, effective_range, created_by)
   VALUES ('$TEN','$ENG','$UNIT','REPORTING','USD','[2024-01-01,)','$JIA')" \
  "conflicting key value\|exclusion constraint"
expect_ok  "0030：不重疊的後續期間可指派（功能幣會隨時間變更）" \
  "$T1 INSERT INTO reporting_unit_currency_assignment (tenant_id, engagement_id, reporting_unit_id,
        currency_role, currency_code, effective_range, created_by)
   VALUES ('$TEN','$ENG','$GRP_UNIT','FUNCTIONAL','CNY','[2020-01-01,2024-01-01)','$JIA')"
expect_err "0030：幣別指派的報告單位須屬本案件" \
  "$T1 INSERT INTO reporting_unit_currency_assignment (tenant_id, engagement_id, reporting_unit_id,
        currency_role, currency_code, effective_range, created_by)
   VALUES ('$TEN','$ENG99','$UNIT','FUNCTIONAL','JPY','[2030-01-01,)','$JIA')" \
  "§24.1A"

# ══ 4　匯率版本工作流與自然人 SoD ══════════════════════════════════
RSERIES=f0300000-0000-0000-0000-000000000101
# FX 專屬使用者：同時持有 R3 與 R4，用來驗「覆核人可接著批准」的兩人路徑。
# 不改動共用的甲乙丙——那會動到前面各套件的前提。
FXU=af300000-0000-0000-0000-000000000001
_has app_user "user_id = '$FXU'" || PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO app_user (user_id, tenant_id, email, display_name)
VALUES ('$FXU','$TEN','fx-reviewer@t1.jp','FX 覆核者');
INSERT INTO role_assignment (tenant_id, user_id, role, engagement_id) VALUES
  ('$TEN','$FXU','R2','$ENG'), ('$TEN','$FXU','R3','$ENG'), ('$TEN','$FXU','R4','$ENG');
SQL
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO exchange_rate_version (rate_version_id, tenant_id, engagement_id, label,
        series_id, version_no, created_by)
VALUES ('$FXV','$TEN','$ENG','2026-03 v1','$RSERIES',1,'$JIA');
INSERT INTO exchange_rate_observation (observation_id, tenant_id, rate_version_id, from_currency,
        to_currency, rate_type, rate, source, measurement_date)
VALUES ('$OBS_CLOSE','$TEN','$FXV','JPY','CNY','CLOSING',0.04812,'BOJ','2026-03-31');
INSERT INTO exchange_rate_observation (observation_id, tenant_id, rate_version_id, from_currency,
        to_currency, rate_type, rate, source, coverage_start, coverage_end)
VALUES ('$OBS_AVG','$TEN','$FXV','JPY','CNY','AVERAGE',0.04795,'BOJ','2026-03-01','2026-03-31');
INSERT INTO exchange_rate_observation (observation_id, tenant_id, rate_version_id, from_currency,
        to_currency, rate_type, rate, source, event_date)
VALUES ('$OBS_HIST','$TEN','$FXV','JPY','CNY','HISTORICAL',0.061,'契約','2018-06-15');
SQL
n=$(PSQL_C <<<"$T1 SELECT count(*) FROM exchange_rate_observation WHERE rate_version_id='$FXV'")
[ "$n" = "3" ] && ok "0030：DRAFT 匯率版本可自由增減觀測（3 筆）" || ng "0030：觀測建立失敗（${n}）"

# 0031：建立時不得自填操作者，也不得直接以非 DRAFT 建立
expect_err "0031：建立時自填 submitted_by → 拒絕（操作者由 DB 查證）" \
  "$T1 INSERT INTO exchange_rate_version (tenant_id, engagement_id, label, series_id, version_no,
        created_by, submitted_by, submitted_at)
   VALUES ('$TEN','$ENG','偽造','f0300000-0000-0000-0000-000000000199',1,'$JIA','$JIA',now())" \
  "RATE_VERSION_ACTOR_NOT_SELF_DECLARED"
expect_err "0031：不得直接以 APPROVED 建立" \
  "$T1 INSERT INTO exchange_rate_version (tenant_id, engagement_id, label, series_id, version_no,
        created_by, status)
   VALUES ('$TEN','$ENG','偽造2','f0300000-0000-0000-0000-000000000198',1,'$JIA','APPROVED')" \
  "RATE_VERSION_MUST_START_DRAFT"

# 0031：唯一鍵 NULLS NOT DISTINCT——同一版本不得有兩筆一模一樣的 CLOSING
expect_err "0031：同版本重複的 CLOSING 觀測 → 拒絕（NULL 必須視為相等）" \
  "$T1 INSERT INTO exchange_rate_observation (tenant_id, rate_version_id, from_currency,
        to_currency, rate_type, rate, source, measurement_date)
   VALUES ('$TEN','$FXV','JPY','CNY','CLOSING',0.99,'重複','2026-03-31')" "duplicate key"
expect_err "0031：同版本重複的 HISTORICAL 觀測 → 拒絕" \
  "$T1 INSERT INTO exchange_rate_observation (tenant_id, rate_version_id, from_currency,
        to_currency, rate_type, rate, source, event_date)
   VALUES ('$TEN','$FXV','JPY','CNY','HISTORICAL',0.99,'重複','2018-06-15')" "duplicate key"

expect_err "0030：CLOSING 不得帶 coverage 區間（期間語意不可混用）" \
  "$T1 INSERT INTO exchange_rate_observation (tenant_id, rate_version_id, from_currency, to_currency,
        rate_type, rate, source, measurement_date, coverage_start, coverage_end)
   VALUES ('$TEN','$FXV','JPY','CNY','CLOSING',0.048,'x','2026-03-31','2026-03-01','2026-03-31')" \
  "violates check constraint"
expect_err "0030：AVERAGE 必須有覆蓋區間" \
  "$T1 INSERT INTO exchange_rate_observation (tenant_id, rate_version_id, from_currency, to_currency,
        rate_type, rate, source, measurement_date)
   VALUES ('$TEN','$FXV','JPY','CNY','AVERAGE',0.048,'x','2026-03-31')" \
  "violates check constraint"
expect_err "0030：HISTORICAL 必須有事件日" \
  "$T1 INSERT INTO exchange_rate_observation (tenant_id, rate_version_id, from_currency, to_currency,
        rate_type, rate, source, measurement_date)
   VALUES ('$TEN','$FXV','JPY','CNY','HISTORICAL',0.048,'x','2026-03-31')" \
  "violates check constraint"
expect_err "0030：同一幣別不得互相報價" \
  "$T1 INSERT INTO exchange_rate_observation (tenant_id, rate_version_id, from_currency, to_currency,
        rate_type, rate, source, measurement_date)
   VALUES ('$TEN','$FXV','JPY','JPY','CLOSING',1,'x','2026-03-31')" \
  "violates check constraint"

# ── 0031：狀態遷移只能經函式，且操作者由 DB 查證 ──
fxt() { echo "$T1 SELECT fn_exchange_rate_transition('$1','$2','$3','$4','$5'"${6:+,'$6'}")"; }
expect_err "0031：直接 UPDATE 改狀態 → 拒絕（只能經遷移函式）" \
  "$T1 UPDATE exchange_rate_version SET status='SUBMITTED' WHERE rate_version_id='$FXV'" \
  "RATE_VERSION_TRANSITION_ONLY"
expect_err "0031：直接 UPDATE 改標籤 → 拒絕" \
  "$T1 UPDATE exchange_rate_version SET label='偷改' WHERE rate_version_id='$FXV'" \
  "RATE_VERSION_TRANSITION_ONLY"
expect_err "0031：不得跳關（DRAFT → APPROVED）" \
  "$(fxt "$FXV" DRAFT APPROVED "$BING" R4)" "RATE_VERSION_ILLEGAL_TRANSITION"
expect_err "0031：角色不符（提交需 R2，帶 R4）" \
  "$(fxt "$FXV" DRAFT SUBMITTED "$JIA" R4)" "ROLE_NOT_PERMITTED"
# 丙在 fx_core 只有 R1，是「案件內但無該角色」的樣本
expect_err "0031：發起人未於本案件持有 R2 → ACTOR_ROLE_NOT_HELD" \
  "$(fxt "$FXV" DRAFT SUBMITTED "$BING" R2)" "ACTOR_ROLE_NOT_HELD"
expect_err "0031：樂觀鎖——expected_from 不符" \
  "$(fxt "$FXV" SUBMITTED REVIEWED "$FXU" R3)" "OPTIMISTIC_LOCK_CONFLICT"
expect_ok  "0031：甲（R2）提交 → SUBMITTED" "$(fxt "$FXV" DRAFT SUBMITTED "$JIA" R2)"
sub=$(PSQL_C <<<"$T1 SELECT submitted_by FROM exchange_rate_version WHERE rate_version_id='$FXV'")
[ "$sub" = "$JIA" ] && ok "0031：提交人由函式依查證結果寫入（非呼叫者自填）" \
  || ng "0031：提交人為 ${sub}"
expect_err "0030：SUBMITTED 後觀測列凍結（不得新增）" \
  "$T1 INSERT INTO exchange_rate_observation (tenant_id, rate_version_id, from_currency, to_currency,
        rate_type, rate, source, measurement_date)
   VALUES ('$TEN','$FXV','JPY','CNY','CLOSING',0.05,'x','2026-02-28')" "RATE_OBSERVATIONS_FROZEN"
expect_err "0030：SUBMITTED 後觀測列凍結（不得修改）" \
  "$T1 UPDATE exchange_rate_observation SET rate=0.9 WHERE observation_id='$OBS_CLOSE'" \
  "RATE_OBSERVATIONS_FROZEN"
expect_err "0030：SUBMITTED 後觀測列凍結（不得刪除）" \
  "$T1 DELETE FROM exchange_rate_observation WHERE observation_id='$OBS_AVG'" \
  "RATE_OBSERVATIONS_FROZEN"
# 自然人層 SoD：提交人不得覆核自己提交的版本。
# 反例必須是「角色齊備、只差不是同一人」——用沒有 R3 的甲來測，
# 會被 ACTOR_ROLE_NOT_HELD 以另一個理由擋下，證不到 SoD 本身。
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO exchange_rate_version (rate_version_id, tenant_id, engagement_id, label,
        series_id, version_no, created_by)
VALUES ('$FXV2','$TEN','$ENG','SoD 樣本 v1','f0300000-0000-0000-0000-000000000102',1,'$FXU');
SQL
expect_ok  "0031 前置：FX 覆核者（持 R2／R3／R4）提交另一個版本" \
  "$(fxt "$FXV2" DRAFT SUBMITTED "$FXU" R2)"
expect_err "0030 SoD：同一人提交後不得自行覆核（角色齊備仍被擋）" \
  "$(fxt "$FXV2" SUBMITTED REVIEWED "$FXU" R3)" "FX_RATE_SELF_REVIEW_DENIED"
expect_ok  "0030 SoD：FX 覆核者獨立覆核 → REVIEWED" "$(fxt "$FXV" SUBMITTED REVIEWED "$FXU" R3)"
# 兩人事務所必須能運作：覆核人可以接著批准
expect_ok  "0030 SoD：覆核人可接著批准（兩人即可運作）" \
  "$(fxt "$FXV" REVIEWED APPROVED "$FXU" R4)"
expect_err "0031：已批准的版本不得刪除" \
  "$T1 DELETE FROM exchange_rate_version WHERE rate_version_id='$FXV'" "RATE_VERSION_DELETE_DENIED"
expect_err "0030：APPROVED 後不得新增觀測" \
  "$T1 INSERT INTO exchange_rate_observation (tenant_id, rate_version_id, from_currency, to_currency,
        rate_type, rate, source, measurement_date)
   VALUES ('$TEN','$FXV','JPY','CNY','CLOSING',0.05,'x','2026-02-28')" "RATE_OBSERVATIONS_FROZEN"
n=$(APP_C <<<"$T1 UPDATE exchange_rate_version SET label='x' WHERE rate_version_id='$FXV'" 2>&1 | grep -c "permission denied")
[ "$n" -ge 1 ] && ok "0031：app_runtime 對匯率版本無 UPDATE 權限" || ng "0031：app_runtime 改得動匯率版本"

# ══ 5　折算分類與政策版本 ═════════════════════════════════════════
expect_err "0030：translation_category 不接受自創值" \
  "$T1 UPDATE account SET translation_category='WHATEVER' WHERE account_id='$ACC1'" \
  "violates check constraint"
expect_ok  "0030：科目可標記折算分類" \
  "$T1 UPDATE account SET translation_category='ASSET' WHERE account_id='$ACC1'"

expect_ok  "0030：建立折算政策版本（含 CTA 落點）" \
  "$T1 INSERT INTO translation_policy_version (policy_version_id, tenant_id, engagement_id,
        reporting_unit_id, label, cta_account_id, cta_coa_id, created_by)
   VALUES ('$POLV','$TEN','$ENG','$UNIT','FX 政策 v1','$CTA_ACC',
           '88888888-0000-0000-0000-000000000001','$JIA')"
expect_err "0030：CTA 科目與所宣告的科目表不符 → 拒絕" \
  "$T1 INSERT INTO translation_policy_version (tenant_id, engagement_id, reporting_unit_id, label,
        cta_account_id, cta_coa_id, created_by)
   VALUES ('$TEN','$ENG','$UNIT','壞政策','$ACC99','88888888-0000-0000-0000-000000000001','$JIA')" \
  "CTA_ACCOUNT_SCOPE_INVALID"
expect_ok  "0030：政策版本可掛規則（方法是資料）" \
  "$T1 INSERT INTO translation_policy_rule (tenant_id, policy_version_id, translation_category, method)
   VALUES ('$TEN','$POLV','ASSET','CLOSING'),('$TEN','$POLV','LIABILITY','CLOSING'),
          ('$TEN','$POLV','INCOME','AVERAGE'),('$TEN','$POLV','EXPENSE','AVERAGE'),
          ('$TEN','$POLV','EQUITY_CONTRIBUTED','HISTORICAL_BY_LOT'),
          ('$TEN','$POLV','EQUITY_RETAINED','OPENING_TRANSLATED_BALANCE')"
expect_err "0030：同一政策版本內同一分類不得有兩條規則（重疊在資料層先擋一半）" \
  "$T1 INSERT INTO translation_policy_rule (tenant_id, policy_version_id, translation_category, method)
   VALUES ('$TEN','$POLV','ASSET','AVERAGE')" "duplicate key"
expect_ok  "0030：批准政策版本" \
  "$T1 UPDATE translation_policy_version SET approved_by='$BING', approved_at=now()
   WHERE policy_version_id='$POLV'"
expect_err "0030：已批准的政策版本不可變更" \
  "$T1 UPDATE translation_policy_version SET label='改名' WHERE policy_version_id='$POLV'" \
  "TRANSLATION_POLICY_IMMUTABLE"
expect_err "0030：已批准的政策版本不得增刪規則" \
  "$T1 INSERT INTO translation_policy_rule (tenant_id, policy_version_id, translation_category, method)
   VALUES ('$TEN','$POLV','EQUITY_OTHER','HISTORICAL_BY_LOT')" "TRANSLATION_POLICY_IMMUTABLE"

# ══ 6　權益折算批次集合 ═══════════════════════════════════════════
expect_ok  "0030：建立 lot set v1" \
  "$T1 INSERT INTO equity_translation_lot_set_version (set_version_id, tenant_id, engagement_id,
        reporting_unit_id, account_id, series_id, version_no, created_by)
   VALUES ('$SETV','$TEN','$ENG','$UNIT','$ACC2','$SERIES',1,'$JIA')"
expect_ok  "0030：lot 可引用 HISTORICAL 觀測" \
  "$T1 INSERT INTO equity_translation_lot (tenant_id, set_version_id, event_date, functional_amount,
        exchange_rate_observation_id, evidence_ref, line_no)
   VALUES ('$TEN','$SETV','2018-06-15',7000000,'$OBS_HIST','出資契約 #1',1)"
expect_err "0030：lot 不得引用 CLOSING 觀測（權益只能用歷史匯率）" \
  "$T1 INSERT INTO equity_translation_lot (tenant_id, set_version_id, event_date, functional_amount,
        exchange_rate_observation_id, evidence_ref, line_no)
   VALUES ('$TEN','$SETV','2026-03-31',1,'$OBS_CLOSE','x',9)" "EQUITY_LOT_RATE_TYPE_INVALID"
expect_err "0030：lot 的 event_date 必須與觀測相符" \
  "$T1 INSERT INTO equity_translation_lot (tenant_id, set_version_id, event_date, functional_amount,
        exchange_rate_observation_id, evidence_ref, line_no)
   VALUES ('$TEN','$SETV','2020-01-01',1,'$OBS_HIST','x',8)" "EQUITY_LOT_RATE_DATE_MISMATCH"
expect_ok  "0030：批准 lot set v1" \
  "$T1 UPDATE equity_translation_lot_set_version SET approved_by='$BING', approved_at=now()
   WHERE set_version_id='$SETV'"
expect_err "0030：已批准的 set 不可變更" \
  "$T1 UPDATE equity_translation_lot_set_version SET version_no=2 WHERE set_version_id='$SETV'" \
  "EQUITY_LOT_SET_IMMUTABLE"
expect_err "0030：已批准的 set 不得增減 lots" \
  "$T1 INSERT INTO equity_translation_lot (tenant_id, set_version_id, event_date, functional_amount,
        exchange_rate_observation_id, evidence_ref, line_no)
   VALUES ('$TEN','$SETV','2018-06-15',1,'$OBS_HIST','x',7)" "EQUITY_LOT_SET_IMMUTABLE"
# 版本方向：新版本向後指，舊版本一個位元都不動
SETV2=f0330000-0000-0000-0000-000000000002
pre=$(PSQL_C <<<"$T1 SELECT md5(t::text) FROM equity_translation_lot_set_version t WHERE set_version_id='$SETV'")
expect_ok  "0030：建立 v2 並向後指向 v1" \
  "$T1 INSERT INTO equity_translation_lot_set_version (set_version_id, tenant_id, engagement_id,
        reporting_unit_id, account_id, series_id, version_no, supersedes_set_version_id, created_by)
   VALUES ('$SETV2','$TEN','$ENG','$UNIT','$ACC2','$SERIES',2,'$SETV','$JIA')"
post=$(PSQL_C <<<"$T1 SELECT md5(t::text) FROM equity_translation_lot_set_version t WHERE set_version_id='$SETV'")
[ "${pre}" = "${post}" ] && ok "0030：建立 v2 後 v1 逐欄位未變（不使用向前的 superseded_by）" \
  || ng "0030：v1 被改動了"
expect_err "0030：取代對象必須屬同一版本序列" \
  "$T1 INSERT INTO equity_translation_lot_set_version (tenant_id, engagement_id, reporting_unit_id,
        account_id, series_id, version_no, supersedes_set_version_id, created_by)
   VALUES ('$TEN','$ENG','$UNIT','$ACC2','f0330000-0000-0000-0000-000000000199',2,'$SETV','$JIA')" \
  "EQUITY_LOT_SET_SERIES_MISMATCH"
expect_err "0030：v1 不得被兩個後版指向" \
  "$T1 INSERT INTO equity_translation_lot_set_version (tenant_id, engagement_id, reporting_unit_id,
        account_id, series_id, version_no, supersedes_set_version_id, created_by)
   VALUES ('$TEN','$ENG','$UNIT','$ACC2','$SERIES',3,'$SETV','$JIA')" \
  "duplicate key\|EQUITY_LOT_SET_VERSION_GAP"

# ══ 7　期初已折算權益餘額 ═════════════════════════════════════════
# 真正的 run 前置。用 INSERT…SELECT FROM calculation_run LIMIT 1 在空表上會插入
# 零列並「成功」——那是最典型的假綠。
RPB=99930000-0000-0000-0000-000000000001      # PB（FX-2026-05）的修訂
RPC=99930000-0000-0000-0000-000000000002      # PC（FX-2026-06）的修訂，前期＝PB
MF=99940000-0000-0000-0000-000000000001
MF2=99940000-0000-0000-0000-000000000002
MF3=99940000-0000-0000-0000-000000000003
RUN_OK=99950000-0000-0000-0000-000000000001   # PB 期、COMPLETED
RUN_RUNNING=99950000-0000-0000-0000-000000000002
RUN_OTHER=99950000-0000-0000-0000-000000000003 # 2026-03 期（不是 PC 的前期）
BPB=b0300000-0000-0000-0000-0000000000b5   # 宣告 PB 期的批次（FX 專屬 ID）
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id) VALUES
  ('$RPB','$TEN','$PB'), ('$RPC','$TEN','$PC');
-- run 的批次必須宣告同一期間（§24.1A）——B1 宣告的是 2026-03，PB 期要自己的批次
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by, status)
VALUES ('${BPB}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${RPB}','${JIA}','${JIA}','ACCEPTED');
-- 一份 manifest 只能有一個原始 run（calc_run_manifest_origin_uq），因此三個 run 三份
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by) VALUES
  ('$MF','$TEN','$ENG','$RPB','NO_FX','sqlcanon-2','fx-fixture-1','$JIA'),
  ('$MF2','$TEN','$ENG','$RPB','NO_FX','sqlcanon-2','fx-fixture-2','$JIA'),
  ('$MF3','$TEN','$ENG','$PR','NO_FX','sqlcanon-2','fx-fixture-3','$JIA');
-- Manifest 一旦被 run 引用就封存（INV-17），凍結條目必須先寫。
-- MF2 凍結本案件的匯率版本——component 的「同凍結版本」檢查靠它。
INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
        domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
VALUES ('$TEN','$MF2','EXCHANGE_RATE_VERSION','$FXV','version','1','fx','h-fx','{}'::jsonb);
-- run 一律建立為 RUNNING（0012：結果狀態只能由執行交易寫入），再推到 COMPLETED
INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, status, request_key, request_content_hash,
        engine_version, created_by) VALUES
  ('$RUN_OK','$TEN','$ENG','$RPB','$BPB','$MF','PREVIEW','RUNNING',gen_random_uuid(),'h1','1.0.0','$JIA'),
  ('$RUN_RUNNING','$TEN','$ENG','$RPB','$BPB','$MF2','PREVIEW','RUNNING',gen_random_uuid(),'h2','1.0.0','$JIA'),
  ('$RUN_OTHER','$TEN','$ENG','$PR','$B1','$MF3','PREVIEW','RUNNING',gen_random_uuid(),'h3','1.0.0','$JIA');
UPDATE calculation_run SET status='COMPLETED', result_content_hash='r'||left(md5(random()::text),8),
       completed_at=now() WHERE calculation_run_id IN ('$RUN_OK','$RUN_OTHER');
SQL
n=$(PSQL_C <<<"$T1 SELECT count(*) FROM calculation_run WHERE calculation_run_id IN ('$RUN_OK','$RUN_RUNNING','$RUN_OTHER')")
[ "$n" = "3" ] && ok "0030 前置：三個 run 已建立（負面測試不會落在空集合上）" \
  || ng "0030 前置：run 建立失敗（${n}）"

expect_ok  "0030：FIRST_CONVERSION 需要外部證據" \
  "$T1 INSERT INTO equity_opening_translated_balance (tenant_id, engagement_id, reporting_unit_id,
        period_revision_id, account_id, reporting_currency, opening_credit, source_kind,
        evidence_ref, created_by)
   VALUES ('$TEN','$ENG','$UNIT','$PR','$ACC2','CNY',100380.00,'FIRST_CONVERSION','期初橋接底稿','$JIA')"
expect_err "0030：FIRST_CONVERSION 缺證據 → 拒絕" \
  "$T1 INSERT INTO equity_opening_translated_balance (tenant_id, engagement_id, reporting_unit_id,
        period_revision_id, account_id, reporting_currency, opening_credit, source_kind, created_by)
   VALUES ('$TEN','$ENG','$GRP_UNIT','$GRP_PR','$ACC2','CNY',1,'FIRST_CONVERSION','$JIA')" \
  "violates check constraint"
expect_err "0030：FIRST_CONVERSION 不得同時指定來源 run" \
  "$T1 INSERT INTO equity_opening_translated_balance (tenant_id, engagement_id, reporting_unit_id,
        period_revision_id, account_id, reporting_currency, opening_credit, source_kind,
        evidence_ref, source_calculation_run_id, created_by)
   VALUES ('$TEN','$ENG','$GRP_UNIT','$GRP_PR','$ACC2','CNY',1,'FIRST_CONVERSION','x','$RUN_OK','$JIA')" \
  "violates check constraint"
expect_err "0030：PRIOR_RUN 缺來源 run → 拒絕" \
  "$T1 INSERT INTO equity_opening_translated_balance (tenant_id, engagement_id, reporting_unit_id,
        period_revision_id, account_id, reporting_currency, opening_credit, source_kind, created_by)
   VALUES ('$TEN','$ENG','$GRP_UNIT','$GRP_PR','$ACC2','CNY',1,'PRIOR_RUN','$JIA')" \
  "violates check constraint"

# PRIOR_RUN 的四項條件，逐條反證。前置：PB 的修訂尚未 LOCKED。
opening_prior() {  # $1=來源 run
  echo "$T1 INSERT INTO equity_opening_translated_balance (tenant_id, engagement_id, reporting_unit_id,
        period_revision_id, account_id, reporting_currency, opening_credit, source_kind,
        source_calculation_run_id, created_by)
   VALUES ('$TEN','$ENG','$UNIT','$RPC','$ACC2','CNY',1,'PRIOR_RUN','$1','$JIA')"
}
expect_err "0030 條件①：來源 run 非 COMPLETED → 拒絕" \
  "$(opening_prior "$RUN_RUNNING")" "FX_OPENING_EQUITY_NOT_CONTINUOUS"
expect_err "0030 條件②：來源 run 的期間修訂非 LOCKED → 拒絕" \
  "$(opening_prior "$RUN_OK")" "FX_OPENING_EQUITY_NOT_CONTINUOUS"
# 把 PB 的修訂推到 LOCKED（owner 也得停用 trigger——唯一裁決點的副作用）
PSQL_C >/dev/null 2>&1 <<SQL
$T1
ALTER TABLE period_revision DISABLE TRIGGER trg_period_transition;
UPDATE period_revision SET status='LOCKED' WHERE period_revision_id='$RPB';
ALTER TABLE period_revision ENABLE TRIGGER trg_period_transition;
SQL
st=$(PSQL_C <<<"$T1 SELECT status FROM period_revision WHERE period_revision_id='$RPB'")
[ "$st" = "LOCKED" ] && ok "0030 前置：PB 的修訂已 LOCKED（條件②不再是拒絕理由）" \
  || ng "0030 前置：PB 修訂為 ${st}"
expect_err "0030 條件③：來源 run 不屬本期的顯式前期 → 拒絕" \
  "$(opening_prior "$RUN_OTHER")" "FX_OPENING_EQUITY_NOT_CONTINUOUS"
expect_ok  "0030：四項條件皆成立 → 接受（正控制，證明前三條不是被別的理由擋住）" \
  "$(opening_prior "$RUN_OK")"
# 條件④（單位相同）在本模型下不可能單獨違反：§24.1A 已要求列的單位＝本期單位，
# 而前期連結又要求前期與本期同單位。保留該檢查是縱深防禦，不製造假的反例。

expect_err "0030：同一期間同一科目只能有一筆期初已折算餘額" \
  "$T1 INSERT INTO equity_opening_translated_balance (tenant_id, engagement_id, reporting_unit_id,
        period_revision_id, account_id, reporting_currency, opening_credit, source_kind,
        evidence_ref, created_by)
   VALUES ('$TEN','$ENG','$UNIT','$PR','$ACC2','CNY',1,'FIRST_CONVERSION','x','$JIA')" \
  "duplicate key"
expect_ok  "0030：批准期初餘額" \
  "$T1 UPDATE equity_opening_translated_balance SET approved_by='$BING', approved_at=now()
   WHERE period_revision_id='$PR' AND account_id='$ACC2'"
expect_err "0030：已批准的期初餘額不可變更" \
  "$T1 UPDATE equity_opening_translated_balance SET opening_credit=1
   WHERE period_revision_id='$PR' AND account_id='$ACC2'" "OPENING_BALANCE_IMMUTABLE"

# ══ 8　CTA：獨立實體、不可人手寫入 ════════════════════════════════
n=$(APP_C <<<"$T1 INSERT INTO translation_adjustment_entry (tenant_id, engagement_id, reporting_unit_id,
      period_revision_id, calculation_run_id, posting_layer_id, rule_type, reporting_currency,
      translation_policy_version_id, exchange_rate_version_id)
    SELECT '$TEN','$ENG','$UNIT','$PR', calculation_run_id, '$LAYER_TA','GROUP_GAAP','CNY',
           '$POLV','$FXV' FROM calculation_run LIMIT 1" 2>&1 | grep -c "permission denied")
[ "$n" -ge 1 ] && ok "0030：app_runtime 不得人手寫入 CTA（只能由折算函式產生）" \
  || ng "0030：app_runtime 寫得進 CTA"
n=$(APP_C <<<"$T1 SELECT count(*) FROM translation_result" 2>&1 | grep -c "permission denied")
[ "$n" = "0" ] && ok "0030：app_runtime 可讀折算結果（只是不可寫）" \
  || ng "0030：app_runtime 連讀都不行"

# ══ 9　既有結構的擴充 ═════════════════════════════════════════════
expect_ok  "0030：manifest 接受 FX_TRANSLATION 範圍" \
  "$T1 INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
   VALUES (gen_random_uuid(),'$TEN','$ENG','$PR','FX_TRANSLATION','sqlcanon-2','deadbeef','$JIA')"
expect_err "0030：manifest 仍不接受未知範圍" \
  "$T1 INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
   VALUES (gen_random_uuid(),'$TEN','$ENG','$PR','WHATEVER','sqlcanon-2','x','$JIA')" "violates check constraint"
for t in CURRENCY_DEFINITION EXCHANGE_RATE_VERSION TRANSLATION_POLICY_VERSION CURRENCY_ASSIGNMENT \
         EQUITY_TRANSLATION_LOT_SET_VERSION EQUITY_OPENING_TRANSLATED_BALANCE \
         ACCOUNT_TRANSLATION_CLASSIFICATION; do
  n=$(PSQL_C <<<"$T1 SELECT 1 FROM pg_constraint
      WHERE conname='calculation_manifest_entry_object_type_check'
        AND pg_get_constraintdef(oid) LIKE '%${t}%'")
  [ "$n" = "1" ] && ok "0030：manifest 可凍結 ${t}" || ng "0030：manifest 缺 ${t}"
done
n=$(PSQL_C <<<"$T1 SELECT 1 FROM pg_constraint WHERE conname='balance_snapshot_line_posting_layer_check'
    AND pg_get_constraintdef(oid) LIKE '%TRANSLATION_ADJUSTMENT%'")
[ "$n" = "1" ] && ok "0030：快照分層接受 TRANSLATION_ADJUSTMENT" || ng "0030：快照分層未擴充"

# ══ 11　父鏈一致性與折算產出的不可變性（0031）══════════════════════
# RLS 只證明「這一列的 tenant_id 是我的」。它擋不住「自己的 tenant_id ＋
# 別人的父物件」——Adjustment 與 Mapping 已經踩過同一個洞。
# 快照只能在 RUNNING 的 run 上追加（0012：終態後結果不可再變），
# 因此折算結果的 fixture 掛在 RUN_RUNNING 上，另建一個 RUNNING 的 run 作跨 run 反例。
ENTRY=f0350000-0000-0000-0000-000000000001
MF4=99940000-0000-0000-0000-000000000004
RUN_SNAP2=99950000-0000-0000-0000-000000000004
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
VALUES ('$MF4','$TEN','$ENG','$PR','NO_FX','sqlcanon-2','fx-fixture-4','$JIA');
INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
        domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
VALUES ('$TEN','$MF4','EXCHANGE_RATE_VERSION','$FXV','version','1','fx','h-fx4','{}'::jsonb);
INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, status, request_key, request_content_hash,
        engine_version, created_by)
VALUES ('$RUN_SNAP2','$TEN','$ENG','$PR','$B1','$MF4','PREVIEW','RUNNING',gen_random_uuid(),'h4','1.0.0','$JIA');
INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit)
VALUES ('$TEN','$RUN_RUNNING','SOURCE_TB','$ACC1','1001','库存现金',350000,0),
       ('$TEN','$RUN_SNAP2','SOURCE_TB','$ACC1','1001','库存现金',1,0);
SQL
SNAP_OK=$(PSQL_C <<<"$T1 SELECT snapshot_line_id FROM balance_snapshot_line
  WHERE calculation_run_id='$RUN_RUNNING' ORDER BY snapshot_line_id LIMIT 1")
SNAP_OTHER=$(PSQL_C <<<"$T1 SELECT snapshot_line_id FROM balance_snapshot_line
  WHERE calculation_run_id='$RUN_SNAP2' ORDER BY snapshot_line_id LIMIT 1")
[ -n "$SNAP_OK" ] && [ -n "$SNAP_OTHER" ] && ok "0031 前置：兩個 run 各有一列快照" \
  || ng "0031 前置：快照建立失敗"

entry_sql() {  # $1=run $2=期間修訂 $3=單位 $4=政策 $5=匯率版本 $6=案件
  echo "$T1 INSERT INTO translation_adjustment_entry (translation_entry_id, tenant_id, engagement_id,
        reporting_unit_id, period_revision_id, calculation_run_id, posting_layer_id, rule_type,
        reporting_currency, translation_policy_version_id, exchange_rate_version_id)
   VALUES (gen_random_uuid(),'$TEN','$6','$3','$2','$1','$LAYER_TA','GROUP_GAAP','CNY','$4','$5')"
}
expect_err "0031 父鏈：CTA 分錄的 run 不屬本案件 → 拒絕" \
  "$(entry_sql "$RUN_RUNNING" "$RPB" "$UNIT" "$POLV" "$FXV" "$ENG99")" "§24.1A"
expect_err "0031 父鏈：CTA 分錄的期間修訂與 run 不一致 → 拒絕" \
  "$(entry_sql "$RUN_RUNNING" "$PR" "$UNIT" "$POLV" "$FXV" "$ENG")" "CTA_PERIOD_MISMATCH"
expect_err "0031 父鏈：匯率版本尚未批准 → G07 fail closed" \
  "$(entry_sql "$RUN_RUNNING" "$RPB" "$UNIT" "$POLV" "$FXV2" "$ENG")" "G07_RATE_VERSION_NOT_FROZEN"
expect_ok  "0031 父鏈：全部一致 → 接受（正控制）" \
  "$T1 INSERT INTO translation_adjustment_entry (translation_entry_id, tenant_id, engagement_id,
        reporting_unit_id, period_revision_id, calculation_run_id, posting_layer_id, rule_type,
        reporting_currency, translation_policy_version_id, exchange_rate_version_id)
   VALUES ('$ENTRY','$TEN','$ENG','$UNIT','$RPB','$RUN_RUNNING','$LAYER_TA','GROUP_GAAP','CNY','$POLV','$FXV')"
expect_err "0031 父鏈：CTA 明細的科目不屬本案件科目表 → 拒絕" \
  "$T1 INSERT INTO translation_adjustment_line (tenant_id, translation_entry_id, line_no,
        account_id, debit) VALUES ('$TEN','$ENTRY',9,'$ACC99',1)" "§24.1A"
LINE=f0360000-0000-0000-0000-000000000001
expect_ok  "0031：CTA 明細（正控制）" \
  "$T1 INSERT INTO translation_adjustment_line (translation_line_id, tenant_id, translation_entry_id,
        line_no, account_id, debit) VALUES ('$LINE','$TEN','$ENTRY',1,'$CTA_ACC',97159.00)"

expect_err "0031 父鏈：折算結果的來源快照屬於另一個 run → 拒絕" \
  "$T1 INSERT INTO translation_result (tenant_id, calculation_run_id, source_snapshot_line_id,
        amount_role, currency_code, source_debit, result_debit)
   VALUES ('$TEN','$RUN_RUNNING','$SNAP_OTHER','REPORTING','CNY',1,1)" "TRANSLATION_RESULT_RUN_MISMATCH"

# 延遲合計：彙總先建、明細後插，中間狀態不得誤擋；合計不符須在 COMMIT 時被擋下
RES1=f0370000-0000-0000-0000-000000000001
expect_ok  "0031：同一交易內先建彙總、再插兩筆明細 → COMMIT 通過（中間狀態不誤擋）" \
  "$T1 BEGIN;
   INSERT INTO translation_result (translation_result_id, tenant_id, calculation_run_id,
     source_snapshot_line_id, amount_role, currency_code, source_debit, result_debit)
   VALUES ('$RES1','$TEN','$RUN_RUNNING','$SNAP_OK','REPORTING','CNY',350000,16842.00);
   INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no, source_kind,
     exchange_rate_observation_id, source_debit, result_debit)
   VALUES ('$TEN','$RES1',1,'RATE_TRANSLATION','$OBS_CLOSE',200000,9624.00),
          ('$TEN','$RES1',2,'RATE_TRANSLATION','$OBS_CLOSE',150000,7218.00);
   COMMIT;"
expect_err "0031：明細合計與彙總不符 → COMMIT 時擋下" \
  "$T1 BEGIN;
   INSERT INTO translation_result (translation_result_id, tenant_id, calculation_run_id,
     source_snapshot_line_id, amount_role, currency_code, source_debit, result_debit)
   VALUES ('f0370000-0000-0000-0000-000000000002','$TEN','$RUN_SNAP2','$SNAP_OTHER',
           'REPORTING','CNY',1,1);
   INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no, source_kind,
     exchange_rate_observation_id, source_debit, result_debit)
   VALUES ('$TEN','f0370000-0000-0000-0000-000000000002',1,'RATE_TRANSLATION','$OBS_CLOSE',1,999);
   COMMIT;" "TRANSLATION_COMPONENT_SUM_MISMATCH"

# 「同凍結版本」：同租戶同案件的**另一份**匯率版本一樣不能用——
# 只驗租戶不夠，run 凍結的是哪一版才是重點。
FXV3=f0300000-0000-0000-0000-000000000003
OBS_OTHER=f0310000-0000-0000-0000-000000000009
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO exchange_rate_version (rate_version_id, tenant_id, engagement_id, label,
        series_id, version_no, created_by)
VALUES ('$FXV3','$TEN','$ENG','未被凍結的版本','f0300000-0000-0000-0000-000000000103',1,'$JIA');
INSERT INTO exchange_rate_observation (observation_id, tenant_id, rate_version_id, from_currency,
        to_currency, rate_type, rate, source, measurement_date)
VALUES ('$OBS_OTHER','$TEN','$FXV3','JPY','CNY','CLOSING',0.09,'另一版','2026-03-31');
SQL
n=$(PSQL_C <<<"$T1 SELECT count(*) FROM exchange_rate_observation WHERE observation_id='$OBS_OTHER'")
[ "$n" = "1" ] && ok "0031 前置：另一份匯率版本的觀測已建立（同租戶同案件）" \
  || ng "0031 前置：另一版觀測建立失敗"
expect_err "0031：component 引用未被本 run 凍結的匯率版本 → 拒絕" \
  "$T1 INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no,
        source_kind, exchange_rate_observation_id, source_debit, result_debit)
   VALUES ('$TEN','$RES1',5,'RATE_TRANSLATION','$OBS_OTHER',1,1)" "TRANSLATION_SOURCE_NOT_FROZEN"

expect_err "0031：component 的 XOR——RATE_TRANSLATION 缺匯率觀測" \
  "$T1 INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no,
        source_kind, source_debit, result_debit)
   VALUES ('$TEN','$RES1',8,'RATE_TRANSLATION',1,1)" "violates check constraint"
expect_err "0031：component 的 XOR——CTA_RESIDUAL 不得帶匯率觀測" \
  "$T1 INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no,
        source_kind, exchange_rate_observation_id, translation_adjustment_line_id,
        source_debit, result_debit)
   VALUES ('$TEN','$RES1',7,'CTA_RESIDUAL','$OBS_CLOSE','$LINE',1,1)" "violates check constraint"
expect_err "0031：component 的 XOR——OPENING_TRANSLATED_BALANCE 必須指向期初餘額" \
  "$T1 INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no,
        source_kind, source_debit, result_debit)
   VALUES ('$TEN','$RES1',6,'OPENING_TRANSLATED_BALANCE',1,1)" "violates check constraint"

# 折算產出不可變：重算＝新的 run
expect_err "0031：折算結果不可 UPDATE" \
  "$T1 UPDATE translation_result SET result_debit=1 WHERE translation_result_id='$RES1'" \
  "FX_OUTPUT_IMMUTABLE"
expect_err "0031：折算明細不可 DELETE（不得改掛到別的彙總）" \
  "$T1 DELETE FROM translation_result_component WHERE translation_result_id='$RES1'" \
  "FX_OUTPUT_IMMUTABLE"
expect_err "0031：CTA 分錄不可 UPDATE" \
  "$T1 UPDATE translation_adjustment_entry SET rule_type='CONSOLIDATION' WHERE translation_entry_id='$ENTRY'" \
  "FX_OUTPUT_IMMUTABLE"

# 已批准的主檔物件不得刪除
expect_err "0031：已批准的折算政策不得刪除" \
  "$T1 DELETE FROM translation_policy_version WHERE policy_version_id='$POLV'" \
  "FX_APPROVED_DELETE_DENIED"
expect_err "0031：已批准的 lot set 不得刪除" \
  "$T1 DELETE FROM equity_translation_lot_set_version WHERE set_version_id='$SETV'" \
  "FX_APPROVED_DELETE_DENIED"
expect_err "0031：已批准的期初餘額不得刪除" \
  "$T1 DELETE FROM equity_opening_translated_balance WHERE period_revision_id='$PR'" \
  "FX_APPROVED_DELETE_DENIED"

# ══ 10　RLS ══════════════════════════════════════════════════════
for t in exchange_rate_version translation_policy_version equity_translation_lot_set_version \
         equity_opening_translated_balance reporting_unit_currency_assignment; do
  n=$(APP_C <<<"$T2 SELECT count(*) FROM $t")
  [ "$n" = "0" ] && ok "0030 RLS：T2 看不到 T1 的 ${t}" || ng "0030 RLS：${t} 洩漏 $n 筆"
done

[ "${STANDALONE:-0}" = "1" ] && summary
