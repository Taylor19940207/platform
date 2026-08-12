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
FXOPS=af300000-0000-0000-0000-000000000002      # 租戶層 R6（§26.3：系管不逐案件指派）
_has app_user "user_id = '$FXU'" || PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO app_user (user_id, tenant_id, email, display_name) VALUES
  ('$FXU','$TEN','fx-reviewer@t1.jp','FX 覆核者'),
  ('$FXOPS','$TEN','fx-ops@t1.jp','FX 系管');
INSERT INTO role_assignment (tenant_id, user_id, role, engagement_id) VALUES
  ('$TEN','$FXU','R2','$ENG'), ('$TEN','$FXU','R3','$ENG'), ('$TEN','$FXU','R4','$ENG'),
  ('$TEN','$FXOPS','R6',NULL);
SQL
# T2 的案件與報告單位：跨租戶父物件的反例來源
ENG_T2=ef300000-0000-0000-0000-000000000001
UNIT_T2=bf300000-0000-0000-0000-000000000001
_has client_engagement "engagement_id = '$ENG_T2'" || PSQL_C >/dev/null 2>&1 <<SQL
$T2
INSERT INTO client_engagement (engagement_id, tenant_id, name) VALUES ('$ENG_T2','$TEN2','T2 客戶案件');
INSERT INTO reporting_unit (reporting_unit_id, tenant_id, engagement_id, unit_scope, name)
VALUES ('$UNIT_T2','$TEN2','$ENG_T2','LEGAL_ENTITY','T2 單位');
SQL
# 0032：匯率版本與觀測只能經 system-only 函式建立（要驗租戶層 R6）
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO exchange_rate_version (rate_version_id, tenant_id, engagement_id, label,
        series_id, version_no, created_by)
VALUES ('$FXV','$TEN','$ENG','2026-03 v1','$RSERIES',1,'$FXOPS');
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
expect_err "0032：非 R6 不得建立匯率版本" \
  "$T1 SELECT fn_exchange_rate_version_create('$TEN','$ENG','非 R6 建立',
       'f0300000-0000-0000-0000-000000000191',1,NULL,'$JIA')" "ACTOR_ROLE_NOT_HELD"
expect_ok  "0032：租戶層 R6 可經函式建立匯率版本" \
  "$T1 SELECT fn_exchange_rate_version_create('$TEN','$ENG','R6 建立',
       'f0300000-0000-0000-0000-000000000192',1,NULL,'$FXOPS')"
expect_err "0032：非 R6 不得新增匯率觀測" \
  "$T1 SELECT fn_exchange_rate_observation_add('$FXV','JPY','CNY','CLOSING',0.5,'x',
       '2026-02-27',NULL,NULL,NULL,'$JIA')" "ACTOR_ROLE_NOT_HELD"
expect_ok  "0032：R6 可經函式新增匯率觀測" \
  "$T1 SELECT fn_exchange_rate_observation_add('$FXV','JPY','CNY','CLOSING',0.5,'x',
       '2026-02-27',NULL,NULL,NULL,'$FXOPS')"
expect_err "0032：跨租戶案件 → 建立匯率版本被拒" \
  "$T1 SELECT fn_exchange_rate_version_create('$TEN','$ENG_T2','跨租戶',
       'f0300000-0000-0000-0000-000000000193',1,NULL,'$FXOPS')" "歸屬違規\|ACTOR_ROLE_NOT_HELD"
n=$(APP_C <<<"$T1 INSERT INTO exchange_rate_version (tenant_id, engagement_id, label, series_id,
      version_no, created_by) VALUES ('$TEN','$ENG','直插','f0300000-0000-0000-0000-000000000194',1,'$JIA')" 2>&1 | grep -c "permission denied")
[ "$n" -ge 1 ] && ok "0032：app_runtime 不得直接 INSERT 匯率版本" || ng "0032：app_runtime 直插得進匯率版本"
n=$(PSQL_C <<<"$T1 SELECT count(*) FROM exchange_rate_observation WHERE rate_version_id='$FXV'")
# 3 筆種子 ＋ 1 筆由上面的 R6 函式加入
[ "$n" = "4" ] && ok "0030：DRAFT 匯率版本可自由增減觀測（4 筆）" || ng "0030：觀測建立失敗（${n}）"

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

# ── 0032：主檔父鏈必須一路同租戶（RLS 只看列上的 tenant_id）──
expect_err "0032 父鏈：幣別指派引用其他租戶的案件 → 拒絕" \
  "$T1 INSERT INTO reporting_unit_currency_assignment (tenant_id, engagement_id, reporting_unit_id,
        currency_role, currency_code, effective_range, created_by)
   VALUES ('$TEN','$ENG_T2','$UNIT_T2','FUNCTIONAL','JPY','[2031-01-01,)','$JIA')" "歸屬違規"
expect_err "0032 父鏈：幣別指派引用同租戶但其他案件的單位 → 拒絕" \
  "$T1 INSERT INTO reporting_unit_currency_assignment (tenant_id, engagement_id, reporting_unit_id,
        currency_role, currency_code, effective_range, created_by)
   VALUES ('$TEN','$ENG99','$UNIT','FUNCTIONAL','JPY','[2032-01-01,)','$JIA')" "§24.1A"
n=$(APP_C <<<"$T1 INSERT INTO reporting_unit_currency_assignment (tenant_id, engagement_id,
      reporting_unit_id, currency_role, currency_code, effective_range, created_by,
      approved_by, approved_at)
    VALUES ('$TEN','$ENG','$GRP_UNIT','REPORTING','CNY','[2033-01-01,)','$JIA','$JIA',now())" 2>&1 | grep -c "permission denied")
[ "$n" -ge 1 ] && ok "0032：app_runtime 不得於 INSERT 時自填批准欄（欄位級權限）" \
  || ng "0032：app_runtime 自填得了批准欄"
# 正控制：不自填批准欄時，app_runtime 必須仍能建立草稿列。
# 沒有這一條，權限收得太緊（例如連父鏈查證函式都撤回）會被誤讀成控制生效。
out=$(APP_C <<<"$T1 INSERT INTO reporting_unit_currency_assignment (tenant_id, engagement_id,
      reporting_unit_id, currency_role, currency_code, effective_range, created_by)
    VALUES ('$TEN','$ENG','$GRP_UNIT','REPORTING','CNY','[2033-01-01,)','$JIA')" 2>&1)
[ -z "$out" ] && ok "0032：app_runtime 仍可建立未批准的幣別指派（正控制）" \
  || ng "0032：合法建立被擋 → ${out}"
expect_err "0032：非 R4 不得批准幣別指派" \
  "$T1 SELECT fn_currency_assignment_approve(
       (SELECT assignment_id FROM reporting_unit_currency_assignment
         WHERE reporting_unit_id='$UNIT' AND currency_role='FUNCTIONAL'),'$JIA')" "ACTOR_ROLE_NOT_HELD"
expect_ok  "0032：R4 可經函式批准幣別指派" \
  "$T1 SELECT fn_currency_assignment_approve(
       (SELECT assignment_id FROM reporting_unit_currency_assignment
         WHERE reporting_unit_id='$UNIT' AND currency_role='FUNCTIONAL'),'$FXU')"

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
expect_err "0030／0032：CTA 科目不屬本案件的科目表 → 拒絕" \
  "$T1 INSERT INTO translation_policy_version (tenant_id, engagement_id, reporting_unit_id, label,
        cta_account_id, cta_coa_id, created_by)
   VALUES ('$TEN','$ENG','$UNIT','壞政策','$ACC99','88888888-0000-0000-0000-000000000001','$JIA')" \
  "§24.1A"
expect_ok  "0030：政策版本可掛規則（方法是資料）" \
  "$T1 INSERT INTO translation_policy_rule (tenant_id, policy_version_id, translation_category, method)
   VALUES ('$TEN','$POLV','ASSET','CLOSING'),('$TEN','$POLV','LIABILITY','CLOSING'),
          ('$TEN','$POLV','INCOME','AVERAGE'),('$TEN','$POLV','EXPENSE','AVERAGE'),
          ('$TEN','$POLV','EQUITY_CONTRIBUTED','HISTORICAL_BY_LOT'),
          ('$TEN','$POLV','EQUITY_RETAINED','OPENING_TRANSLATED_BALANCE')"
expect_err "0030：同一政策版本內同一分類不得有兩條規則（重疊在資料層先擋一半）" \
  "$T1 INSERT INTO translation_policy_rule (tenant_id, policy_version_id, translation_category, method)
   VALUES ('$TEN','$POLV','ASSET','AVERAGE')" "duplicate key"
expect_err "0032：非 R4 不得批准折算政策" \
  "$T1 SELECT fn_translation_policy_approve('$POLV','$JIA')" "ACTOR_ROLE_NOT_HELD"
expect_ok  "0030／0032：R4 經函式批准政策版本" \
  "$T1 SELECT fn_translation_policy_approve('$POLV','$FXU')"
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
expect_ok  "0030／0032：R4 經函式批准 lot set v1" \
  "$T1 SELECT fn_equity_lot_set_approve('$SETV','$FXU')"
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
VALUES ('$TEN','$MF2','EXCHANGE_RATE_VERSION','$FXV','version','1','fx','h-fx','{}'::jsonb),
       ('$TEN','$MF2','TRANSLATION_POLICY_VERSION','$POLV','version','1','pol','h-pol','{}'::jsonb);
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
expect_ok  "0030／0032：R4 經函式批准期初餘額" \
  "$T1 SELECT fn_equity_opening_approve(
       (SELECT opening_id FROM equity_opening_translated_balance
         WHERE period_revision_id='$PR' AND account_id='$ACC2'),'$FXU')"
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
RULE_ASSET=$(PSQL_C <<<"$T1 SELECT policy_rule_id FROM translation_policy_rule
  WHERE policy_version_id='$POLV' AND translation_category='ASSET'")
[ -n "$RULE_ASSET" ] && ok "0032 前置：取得 ASSET 的政策規則（非 CTA 結果必須帶它）" \
  || ng "0032 前置：找不到 ASSET 政策規則"
MF4=99940000-0000-0000-0000-000000000004
RUN_SNAP2=99950000-0000-0000-0000-000000000004
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
VALUES ('$MF4','$TEN','$ENG','$PR','NO_FX','sqlcanon-2','fx-fixture-4','$JIA');
INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
        domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
VALUES ('$TEN','$MF4','EXCHANGE_RATE_VERSION','$FXV','version','1','fx','h-fx4','{}'::jsonb),
       ('$TEN','$MF4','TRANSLATION_POLICY_VERSION','$POLV','version','1','pol','h-pol4','{}'::jsonb);
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
        amount_role, currency_code, source_debit, result_debit, translation_policy_rule_id)
   VALUES ('$TEN','$RUN_RUNNING','$SNAP_OTHER','REPORTING','CNY',1,1,'$RULE_ASSET')" "TRANSLATION_RESULT_RUN_MISMATCH"

# 延遲合計：彙總先建、明細後插，中間狀態不得誤擋；合計不符須在 COMMIT 時被擋下
RES1=f0370000-0000-0000-0000-000000000001
expect_ok  "0031：同一交易內先建彙總、再插兩筆明細 → COMMIT 通過（中間狀態不誤擋）" \
  "$T1 BEGIN;
   INSERT INTO translation_result (translation_result_id, tenant_id, calculation_run_id,
     source_snapshot_line_id, amount_role, currency_code, source_debit, result_debit,
     translation_policy_rule_id)
   VALUES ('$RES1','$TEN','$RUN_RUNNING','$SNAP_OK','REPORTING','CNY',350000,16842.00,'$RULE_ASSET');
   INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no, source_kind,
     exchange_rate_observation_id, source_debit, result_debit)
   VALUES ('$TEN','$RES1',1,'RATE_TRANSLATION','$OBS_CLOSE',200000,9624.00),
          ('$TEN','$RES1',2,'RATE_TRANSLATION','$OBS_CLOSE',150000,7218.00);
   COMMIT;"
expect_err "0031：明細合計與彙總不符 → COMMIT 時擋下" \
  "$T1 BEGIN;
   INSERT INTO translation_result (translation_result_id, tenant_id, calculation_run_id,
     source_snapshot_line_id, amount_role, currency_code, source_debit, result_debit,
     translation_policy_rule_id)
   VALUES ('f0370000-0000-0000-0000-000000000002','$TEN','$RUN_SNAP2','$SNAP_OTHER',
           'REPORTING','CNY',1,1,'$RULE_ASSET');
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

# 0032 P2：折算結果必須答得出「憑哪條方法算的」
POLV2=f0320000-0000-0000-0000-000000000002
SNAP_CTA=
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO translation_policy_version (policy_version_id, tenant_id, engagement_id,
        reporting_unit_id, label, cta_account_id, cta_coa_id, created_by)
VALUES ('$POLV2','$TEN','$ENG','$UNIT','未被凍結的政策','$CTA_ACC',
        '88888888-0000-0000-0000-000000000001','$JIA');
INSERT INTO translation_policy_rule (tenant_id, policy_version_id, translation_category, method)
VALUES ('$TEN','$POLV2','ASSET','CLOSING');
INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit)
VALUES ('$TEN','$RUN_RUNNING','TRANSLATION_ADJUSTMENT','$CTA_ACC','1001','CTA',0,0);
SQL
SNAP_CTA=$(PSQL_C <<<"$T1 SELECT snapshot_line_id FROM balance_snapshot_line
  WHERE calculation_run_id='$RUN_RUNNING' AND posting_layer='TRANSLATION_ADJUSTMENT'")
RULE_OTHER=$(PSQL_C <<<"$T1 SELECT policy_rule_id FROM translation_policy_rule
  WHERE policy_version_id='$POLV2'")
expect_err "0032：非 CTA 的折算結果缺政策規則 → 拒絕" \
  "$T1 INSERT INTO translation_result (tenant_id, calculation_run_id, source_snapshot_line_id,
        amount_role, currency_code, source_debit, result_debit)
   VALUES ('$TEN','$RUN_RUNNING','$SNAP_OK','REPORTING','CNY',1,1)" "TRANSLATION_RULE_REQUIRED"
expect_err "0032：政策規則不屬本 run 凍結的政策版本 → 拒絕" \
  "$T1 INSERT INTO translation_result (tenant_id, calculation_run_id, source_snapshot_line_id,
        amount_role, currency_code, source_debit, result_debit, translation_policy_rule_id)
   VALUES ('$TEN','$RUN_RUNNING','$SNAP_OK','REPORTING','CNY',1,1,'$RULE_OTHER')" \
  "TRANSLATION_SOURCE_NOT_FROZEN"
expect_err "0032：CTA 的折算結果不得帶政策規則（來源是 CTA 殘差）" \
  "$T1 INSERT INTO translation_result (tenant_id, calculation_run_id, source_snapshot_line_id,
        amount_role, currency_code, source_debit, result_debit, translation_policy_rule_id)
   VALUES ('$TEN','$RUN_RUNNING','$SNAP_CTA','REPORTING','CNY',0,97159.00,'$RULE_ASSET')" \
  "TRANSLATION_CTA_RULE_UNEXPECTED"

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


# ══ 12　Case-001 折算算例（SLICE-M3-02 §七）══════════════════════════
# 契約的驗收常數：12/12 科目、CTA 97,159.00 借方、RE 勾稽 373,695.00。
CASE_COA=88888888-0000-0000-0000-000000000001
FXCASE=f0300000-0000-0000-0000-000000000011
FXCASE_S=f0300000-0000-0000-0000-000000000111
POLCASE=f0320000-0000-0000-0000-000000000011
SETCASE=f0330000-0000-0000-0000-000000000011
SRCMF=99940000-0000-0000-0000-000000000011
SRCRUN=99950000-0000-0000-0000-000000000011
A=(1001 1002 1122 1405 1601 2202 2221 4001 4104 6001 6401 6602)
acc() { echo "aca00000-0000-0000-0000-0000000$1"; }

PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO account (account_id, tenant_id, coa_id, code, name, translation_category) VALUES
  ('$(acc 01001)','$TEN','$CASE_COA','C1001','库存现金','ASSET'),
  ('$(acc 01002)','$TEN','$CASE_COA','C1002','银行存款','ASSET'),
  ('$(acc 01122)','$TEN','$CASE_COA','C1122','应收账款','ASSET'),
  ('$(acc 01405)','$TEN','$CASE_COA','C1405','库存商品','ASSET'),
  ('$(acc 01601)','$TEN','$CASE_COA','C1601','固定资产','ASSET'),
  ('$(acc 02202)','$TEN','$CASE_COA','C2202','应付账款','LIABILITY'),
  ('$(acc 02221)','$TEN','$CASE_COA','C2221','应交税费','LIABILITY'),
  ('$(acc 04001)','$TEN','$CASE_COA','C4001','实收资本','EQUITY_CONTRIBUTED'),
  ('$(acc 04104)','$TEN','$CASE_COA','C4104','未分配利润','EQUITY_RETAINED'),
  ('$(acc 06001)','$TEN','$CASE_COA','C6001','主营业务收入','INCOME'),
  ('$(acc 06401)','$TEN','$CASE_COA','C6401','主营业务成本','EXPENSE'),
  ('$(acc 06602)','$TEN','$CASE_COA','C6602','管理费用','EXPENSE'),
  ('$(acc 03999)','$TEN','$CASE_COA','C3999','外币报表折算差额',NULL);
-- 匯率版本（含兩筆歷史匯率）
INSERT INTO exchange_rate_version (rate_version_id, tenant_id, engagement_id, label,
        series_id, version_no, created_by)
VALUES ('$FXCASE','$TEN','$ENG','Case-001 2026-03','$FXCASE_S',1,'$FXOPS');
INSERT INTO exchange_rate_observation (tenant_id, rate_version_id, from_currency, to_currency,
        rate_type, rate, source, measurement_date, coverage_start, coverage_end, event_date) VALUES
  ('$TEN','$FXCASE','JPY','CNY','CLOSING',0.048120,'BOJ','2026-03-31',NULL,NULL,NULL),
  ('$TEN','$FXCASE','JPY','CNY','AVERAGE',0.047950,'BOJ',NULL,'2026-03-01','2026-03-31',NULL),
  ('$TEN','$FXCASE','JPY','CNY','HISTORICAL',0.061000,'出資契約',NULL,NULL,NULL,'2018-06-15'),
  ('$TEN','$FXCASE','JPY','CNY','HISTORICAL',0.051000,'増資契約',NULL,NULL,NULL,'2022-09-01');
-- 折算政策
INSERT INTO translation_policy_version (policy_version_id, tenant_id, engagement_id,
        reporting_unit_id, label, cta_account_id, cta_coa_id, created_by)
VALUES ('$POLCASE','$TEN','$ENG','$UNIT','Case-001 折算政策','$(acc 03999)','$CASE_COA','$JIA');
INSERT INTO translation_policy_rule (tenant_id, policy_version_id, translation_category, method) VALUES
  ('$TEN','$POLCASE','ASSET','CLOSING'), ('$TEN','$POLCASE','LIABILITY','CLOSING'),
  ('$TEN','$POLCASE','INCOME','AVERAGE'), ('$TEN','$POLCASE','EXPENSE','AVERAGE'),
  ('$TEN','$POLCASE','EQUITY_CONTRIBUTED','HISTORICAL_BY_LOT'),
  ('$TEN','$POLCASE','EQUITY_RETAINED','OPENING_TRANSLATED_BALANCE');
-- 權益折算批次（合計 10,000,000 ＝ 4001 的功能幣餘額）
INSERT INTO equity_translation_lot_set_version (set_version_id, tenant_id, engagement_id,
        reporting_unit_id, account_id, series_id, version_no, created_by)
VALUES ('$SETCASE','$TEN','$ENG','$UNIT','$(acc 04001)','f0330000-0000-0000-0000-000000000111',1,'$JIA');
INSERT INTO equity_translation_lot (tenant_id, set_version_id, event_date, functional_amount,
        exchange_rate_observation_id, evidence_ref, line_no)
SELECT '$TEN','$SETCASE','2018-06-15',7000000, observation_id,'出資契約 #1',1
  FROM exchange_rate_observation WHERE rate_version_id='$FXCASE' AND event_date='2018-06-15';
INSERT INTO equity_translation_lot (tenant_id, set_version_id, event_date, functional_amount,
        exchange_rate_observation_id, evidence_ref, line_no)
SELECT '$TEN','$SETCASE','2022-09-01',3000000, observation_id,'増資契約 #2',2
  FROM exchange_rate_observation WHERE rate_version_id='$FXCASE' AND event_date='2022-09-01';
-- 期初已折算保留盈餘（首次轉換，經批准的外部證據）
INSERT INTO equity_opening_translated_balance (tenant_id, engagement_id, reporting_unit_id,
        period_revision_id, account_id, reporting_currency, opening_credit, source_kind,
        evidence_ref, created_by)
VALUES ('$TEN','$ENG','$UNIT','$PR','$(acc 04104)','CNY',100380.00,'FIRST_CONVERSION','期初橋接底稿','$JIA');
-- 來源 NO_FX run（Case-001 調整後集團 TB，功能幣 JPY，借貸各 59,000,000）
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
VALUES ('$SRCMF','$TEN','$ENG','$PR','NO_FX','sqlcanon-2','case001-src','$JIA');
INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, status, request_key, request_content_hash,
        engine_version, created_by)
VALUES ('$SRCRUN','$TEN','$ENG','$PR','$B1','$SRCMF','PREVIEW','RUNNING',gen_random_uuid(),
        'case001','1.0.0','$JIA');
INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit) VALUES
  ('$TEN','$SRCRUN','SOURCE_TB','$(acc 01001)','C1001','库存现金',350000,0),
  ('$TEN','$SRCRUN','SOURCE_TB','$(acc 01002)','C1002','银行存款',9650000,0),
  ('$TEN','$SRCRUN','SOURCE_TB','$(acc 01122)','C1122','应收账款',5600000,0),
  ('$TEN','$SRCRUN','SOURCE_TB','$(acc 01405)','C1405','库存商品',2300000,0),
  ('$TEN','$SRCRUN','SOURCE_TB','$(acc 01601)','C1601','固定资产',4800000,200000),
  ('$TEN','$SRCRUN','SOURCE_TB','$(acc 02202)','C2202','应付账款',0,3900000),
  ('$TEN','$SRCRUN','SOURCE_TB','$(acc 02221)','C2221','应交税费',0,800000),
  ('$TEN','$SRCRUN','SOURCE_TB','$(acc 04001)','C4001','实收资本',0,10000000),
  ('$TEN','$SRCRUN','SOURCE_TB','$(acc 04104)','C4104','未分配利润',0,2100000),
  ('$TEN','$SRCRUN','SOURCE_TB','$(acc 06001)','C6001','主营业务收入',0,42000000),
  ('$TEN','$SRCRUN','SOURCE_TB','$(acc 06401)','C6401','主营业务成本',21700000,0),
  ('$TEN','$SRCRUN','SOURCE_TB','$(acc 06602)','C6602','管理费用',14600000,0);
UPDATE calculation_run SET status='COMPLETED', result_content_hash='case001-r', completed_at=now()
 WHERE calculation_run_id='$SRCRUN';
SQL
n=$(PSQL_C <<<"$T1 SELECT count(*) FROM balance_snapshot_line WHERE calculation_run_id='$SRCRUN'")
[ "$n" = "12" ] && ok "Case-001 前置：來源 NO_FX run 有 12 列（功能幣 JPY）" \
  || ng "Case-001 前置：來源列數為 ${n}"
d=$(PSQL_C <<<"$T1 SELECT sum(debit)||'/'||sum(credit) FROM balance_snapshot_line WHERE calculation_run_id='$SRCRUN'")
[ "$d" = "59000000.00/59000000.00" ] && ok "Case-001 前置：功能幣借貸各 59,000,000" \
  || ng "Case-001 前置：功能幣合計為 ${d}"

# 匯率版本走完工作流（R6 建立 → R2 提交 → R3 覆核 → R4 批准）
expect_ok "Case-001 前置：匯率版本 DRAFT → SUBMITTED" "$(fxt "$FXCASE" DRAFT SUBMITTED "$JIA" R2)"
expect_ok "Case-001 前置：SUBMITTED → REVIEWED" "$(fxt "$FXCASE" SUBMITTED REVIEWED "$FXU" R3)"
expect_ok "Case-001 前置：REVIEWED → APPROVED" "$(fxt "$FXCASE" REVIEWED APPROVED "$FXU" R4)"
expect_ok "Case-001 前置：批准折算政策、lot set、期初餘額、報告幣指派" \
  "$T1 SELECT fn_translation_policy_approve('$POLCASE','$FXU');
   SELECT fn_equity_lot_set_approve('$SETCASE','$FXU');
   SELECT fn_equity_opening_approve((SELECT opening_id FROM equity_opening_translated_balance
     WHERE period_revision_id='$PR' AND account_id='$(acc 04104)'),'$FXU');
   SELECT fn_currency_assignment_approve((SELECT assignment_id FROM reporting_unit_currency_assignment
     WHERE reporting_unit_id='$UNIT' AND currency_role='REPORTING'),'$FXU')"

# 0038：引擎前置檢查——實際輸入必須等於現行 InputSelection。
# 這是**預期的 fixture 變更**（M3-02 的斷言一字不改）。
sel_inputs() {  # $1=來源 run $2=匯率版本 $3=政策版本
  PSQL_C >/dev/null 2>&1 <<SQL
$T1
SELECT fn_period_fx_select_inputs('$PR','$1','$2','$3','$JIA');
SQL
}
sel_inputs "$SRCRUN" "$FXCASE" "$POLCASE"
FXRUN=$(PSQL_C <<<"$T1 SELECT fn_fx_translation_run('$TEN','$ENG','$PR','$UNIT','$SRCRUN','$FXCASE','$POLCASE','$JIA','fx-1.0.0')")
[ -n "$FXRUN" ] && ok "Case-001：折算 run 建立成功" || ng "Case-001：折算失敗"

# ── 逐科目比對（契約 §七 的表）──
fxamt() {  # $1=科目代碼 → "借/貸"（報告幣）
  PSQL_C <<<"$T1 SELECT tr.result_debit||'/'||tr.result_credit
    FROM translation_result tr
    JOIN balance_snapshot_line b ON b.snapshot_line_id = tr.source_snapshot_line_id
   WHERE tr.calculation_run_id='$FXRUN' AND b.account_code='$1'"
}
hit=0
for pair in "C1001:16842.00/0.00" "C1002:464358.00/0.00" "C1122:269472.00/0.00" \
            "C1405:110676.00/0.00" "C1601:221352.00/0.00" "C2202:0.00/187668.00" \
            "C2221:0.00/38496.00" "C4001:0.00/580000.00" "C4104:0.00/100380.00" \
            "C6001:0.00/2013900.00" "C6401:1040515.00/0.00" "C6602:700070.00/0.00"; do
  code="${pair%%:*}"; want="${pair#*:}"; got=$(fxamt "$code")
  if [ "$got" = "$want" ]; then hit=$((hit+1)); else ng "Case-001 ${code}：期望 ${want} 實得 ${got}"; fi
done
[ "$hit" = "12" ] && ok "Case-001：逐科目折算 12/12 相符（含權益逐筆與延續橋接）" \
  || ng "Case-001：僅 ${hit}/12 相符"

tot=$(PSQL_C <<<"$T1 SELECT sum(tr.result_debit)||'/'||sum(tr.result_credit)
  FROM translation_result tr
  JOIN balance_snapshot_line b ON b.snapshot_line_id = tr.source_snapshot_line_id
 WHERE tr.calculation_run_id='$FXRUN' AND b.posting_layer <> 'TRANSLATION_ADJUSTMENT'")
[ "$tot" = "2823285.00/2920444.00" ] && ok "Case-001：折算後借 2,823,285.00 ／ 貸 2,920,444.00" \
  || ng "Case-001：合計為 ${tot}"

cta=$(PSQL_C <<<"$T1 SELECT debit||'/'||credit FROM translation_adjustment_line l
  JOIN translation_adjustment_entry e ON e.translation_entry_id=l.translation_entry_id
 WHERE e.calculation_run_id='$FXRUN'")
[ "$cta" = "97159.00/0.00" ] && ok "Case-001：CTA ＝ 97,159.00 且在**借方**（功能幣貶值）" \
  || ng "Case-001：CTA 為 ${cta}"
n=$(PSQL_C <<<"$T1 SELECT rule_type FROM translation_adjustment_entry WHERE calculation_run_id='$FXRUN'")
[ "$n" = "GROUP_GAAP" ] && ok "Case-001：CTA 物化為 TRANSLATION_ADJUSTMENT／GROUP_GAAP 分錄" \
  || ng "Case-001：CTA rule_type 為 ${n}"
n=$(PSQL_C <<<"$T1 SELECT debit||'/'||credit FROM balance_snapshot_line
  WHERE calculation_run_id='$FXRUN' AND posting_layer='TRANSLATION_ADJUSTMENT'")
[ "$n" = "0.00/0.00" ] && ok "Case-001：CTA 的快照列是空殼（功能幣下沒有 CTA）" \
  || ng "Case-001：CTA 快照列為 ${n}"
n=$(PSQL_C <<<"$T1 SELECT sum(debit)||'/'||sum(credit) FROM balance_snapshot_line
  WHERE calculation_run_id='$FXRUN'")
[ "$n" = "59000000.00/59000000.00" ] && ok "Case-001：功能幣 TB 仍借貸各 59,000,000（未被 CNY 污染）" \
  || ng "Case-001：功能幣合計為 ${n}"
n=$(PSQL_C <<<"$T1 SELECT (sum(tr.result_debit)+97159.00)||'/'||sum(tr.result_credit)
  FROM translation_result tr
  JOIN balance_snapshot_line b ON b.snapshot_line_id = tr.source_snapshot_line_id
 WHERE tr.calculation_run_id='$FXRUN' AND b.posting_layer <> 'TRANSLATION_ADJUSTMENT'")
[ "$n" = "2920444.00/2920444.00" ] && ok "Case-001：加入 CTA 後報告幣借貸平衡" \
  || ng "Case-001：加 CTA 後為 ${n}"

# RE 勾稽：期末已折算保留盈餘 ＝ 期初 ＋ 本期已折算損益
re=$(PSQL_C <<<"$T1 SELECT (100380.00 + sum(CASE WHEN b.account_code IN ('C6001') THEN tr.result_credit
        ELSE -tr.result_debit END))::text
  FROM translation_result tr JOIN balance_snapshot_line b ON b.snapshot_line_id=tr.source_snapshot_line_id
 WHERE tr.calculation_run_id='$FXRUN' AND b.account_code IN ('C6001','C6401','C6602')")
[ "$re" = "373695.00" ] && ok "Case-001：RE 勾稽 100,380.00 ＋ 273,315.00 ＝ 373,695.00" \
  || ng "Case-001：RE 勾稽得 ${re}"

# 明細追溯：4001 有兩個 EQUITY_LOT component；4104 是延續橋接、不帶匯率
n=$(PSQL_C <<<"$T1 SELECT count(*) FROM translation_result_component c
  JOIN translation_result tr ON tr.translation_result_id=c.translation_result_id
  JOIN balance_snapshot_line b ON b.snapshot_line_id=tr.source_snapshot_line_id
 WHERE tr.calculation_run_id='$FXRUN' AND b.account_code='C4001' AND c.source_kind='EQUITY_LOT'")
[ "$n" = "2" ] && ok "Case-001：实收资本的彙總掛兩筆 EQUITY_LOT 明細（一筆科目對多筆歷史來源）" \
  || ng "Case-001：4001 的 lot 明細數為 ${n}"
n=$(PSQL_C <<<"$T1 SELECT c.source_kind||':'||COALESCE(c.exchange_rate_observation_id::text,'無匯率')
  FROM translation_result_component c
  JOIN translation_result tr ON tr.translation_result_id=c.translation_result_id
  JOIN balance_snapshot_line b ON b.snapshot_line_id=tr.source_snapshot_line_id
 WHERE tr.calculation_run_id='$FXRUN' AND b.account_code='C4104'")
[ "$n" = "OPENING_TRANSLATED_BALANCE:無匯率" ] && ok "Case-001：保留盈餘是延續橋接，不帶任何匯率觀測" \
  || ng "Case-001：4104 的明細為 ${n}"

# ══ 13　重演、版本切換與捨入 ════════════════════════════════════════
FXRUN2=$(PSQL_C <<<"$T1 SELECT fn_fx_translation_run('$TEN','$ENG','$PR','$UNIT','$SRCRUN','$FXCASE','$POLCASE','$JIA','fx-1.0.0')")
h1=$(PSQL_C <<<"$T1 SELECT result_content_hash FROM calculation_run WHERE calculation_run_id='$FXRUN'")
h2=$(PSQL_C <<<"$T1 SELECT result_content_hash FROM calculation_run WHERE calculation_run_id='$FXRUN2'")
[ -n "$h1" ] && [ "$h1" = "$h2" ] && ok "重演：同一組輸入重跑，result_content_hash 完全相同" \
  || ng "重演：雜湊不同（${h1} / ${h2}）"
f1=$(PSQL_C <<<"$T1 SELECT m.frozen_set_content_hash FROM calculation_run r
  JOIN calculation_input_manifest m ON m.manifest_id=r.manifest_id WHERE r.calculation_run_id='$FXRUN'")
f2=$(PSQL_C <<<"$T1 SELECT m.frozen_set_content_hash FROM calculation_run r
  JOIN calculation_input_manifest m ON m.manifest_id=r.manifest_id WHERE r.calculation_run_id='$FXRUN2'")
[ "$f1" = "$f2" ] && ok "重演：凍結集合雜湊亦相同" || ng "重演：凍結雜湊不同"

# 改動現行主檔不影響既有 run；新 run 才採新值
PSQL_C >/dev/null 2>&1 <<SQL
$T1
UPDATE currency SET minor_unit = 0 WHERE currency_code = 'CNY';
SQL
h3=$(PSQL_C <<<"$T1 SELECT result_content_hash FROM calculation_run WHERE calculation_run_id='$FXRUN'")
[ "$h3" = "$h1" ] && ok "凍結：改動現行 Currency 後，舊 run 的結果與雜湊不變" || ng "凍結：舊 run 被影響"
m1=$(PSQL_C <<<"$T1 SELECT e.payload->>'minor_unit' FROM calculation_run r
  JOIN calculation_manifest_entry e ON e.manifest_id=r.manifest_id
 WHERE r.calculation_run_id='$FXRUN' AND e.object_type='CURRENCY_DEFINITION'
   AND e.payload->>'code'='CNY'")
[ "$m1" = "2" ] && ok "凍結：舊 run 的 manifest 仍記著 CNY minor_unit = 2" || ng "凍結：manifest 值為 ${m1}"
FXRUN3=$(PSQL_C <<<"$T1 SELECT fn_fx_translation_run('$TEN','$ENG','$PR','$UNIT','$SRCRUN','$FXCASE','$POLCASE','$JIA','fx-1.0.0')")
n=$(PSQL_C <<<"$T1 SELECT tr.result_debit FROM translation_result tr
  JOIN balance_snapshot_line b ON b.snapshot_line_id=tr.source_snapshot_line_id
 WHERE tr.calculation_run_id='$FXRUN3' AND b.account_code='C1001'")
[ "$n" = "16842.00" ] && ok "凍結：新 run 採用改後的 minor_unit = 0（16,842 而非 16,842.00 的分位）" \
  || ng "凍結：新 run 的 1001 為 ${n}"
PSQL_C >/dev/null 2>&1 <<SQL
$T1
UPDATE currency SET minor_unit = 2 WHERE currency_code = 'CNY';
SQL

# 捨入：刻意不整除的匯率必須得到 ROUND_HALF_UP 的結果
FXROUND=f0300000-0000-0000-0000-000000000021
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO exchange_rate_version (rate_version_id, tenant_id, engagement_id, label,
        series_id, version_no, created_by)
VALUES ('$FXROUND','$TEN','$ENG','捨入判準','f0300000-0000-0000-0000-000000000121',1,'$FXOPS');
INSERT INTO exchange_rate_observation (tenant_id, rate_version_id, from_currency, to_currency,
        rate_type, rate, source, measurement_date, coverage_start, coverage_end, event_date) VALUES
  ('$TEN','$FXROUND','JPY','CNY','CLOSING',0.0481233,'x','2026-03-31',NULL,NULL,NULL),
  ('$TEN','$FXROUND','JPY','CNY','AVERAGE',0.047950,'x',NULL,'2026-03-01','2026-03-31',NULL),
  ('$TEN','$FXROUND','JPY','CNY','HISTORICAL',0.061000,'x',NULL,NULL,NULL,'2018-06-15'),
  ('$TEN','$FXROUND','JPY','CNY','HISTORICAL',0.051000,'x',NULL,NULL,NULL,'2022-09-01');
SQL
expect_ok "捨入前置：匯率版本走完工作流" \
  "$T1 SELECT fn_exchange_rate_transition('$FXROUND','DRAFT','SUBMITTED','$JIA','R2');
   SELECT fn_exchange_rate_transition('$FXROUND','SUBMITTED','REVIEWED','$FXU','R3');
   SELECT fn_exchange_rate_transition('$FXROUND','REVIEWED','APPROVED','$FXU','R4')"
# 換匯率版本時，權益 lots 的歷史觀測就不再屬於本 run 凍結的版本——
# 這是真規則（明細必須可追溯到凍結集合），因此換版本必須連 lot set 一起換。
sel_inputs "$SRCRUN" "$FXROUND" "$POLCASE"
expect_err "換匯率版本但 lot set 仍指向舊版觀測 → 拒絕（不是靜默沿用）" \
  "$T1 SELECT fn_fx_translation_run('$TEN','$ENG','$PR','$UNIT','$SRCRUN','$FXROUND','$POLCASE','$JIA','x')" \
  "TRANSLATION_SOURCE_NOT_FROZEN"
sel_inputs "$SRCRUN" "$FXCASE" "$POLCASE"
# 捨入判準改用不含權益科目的來源，隔離出「率 × 金額」這一件事
SRCMF2=99940000-0000-0000-0000-000000000012
SRCRUN2=99950000-0000-0000-0000-000000000012
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
VALUES ('$SRCMF2','$TEN','$ENG','$PR','NO_FX','sqlcanon-2','round-src','$JIA');
INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, status, request_key, request_content_hash,
        engine_version, created_by)
VALUES ('$SRCRUN2','$TEN','$ENG','$PR','$B1','$SRCMF2','PREVIEW','RUNNING',gen_random_uuid(),
        'round','1.0.0','$JIA');
INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit)
VALUES ('$TEN','$SRCRUN2','SOURCE_TB','$(acc 01001)','C1001','库存现金',350000,0);
UPDATE calculation_run SET status='COMPLETED', result_content_hash='round-r', completed_at=now()
 WHERE calculation_run_id='$SRCRUN2';
SQL
sel_inputs "$SRCRUN2" "$FXROUND" "$POLCASE"
FXRUN4=$(PSQL_C <<<"$T1 SELECT fn_fx_translation_run('$TEN','$ENG','$PR','$UNIT','$SRCRUN2','$FXROUND','$POLCASE','$JIA','fx-1.0.0')")
n=$(PSQL_C <<<"$T1 SELECT tr.result_debit FROM translation_result tr
  JOIN balance_snapshot_line b ON b.snapshot_line_id=tr.source_snapshot_line_id
 WHERE tr.calculation_run_id='$FXRUN4' AND b.account_code='C1001'")
[ "$n" = "16843.16" ] && ok "捨入：350,000 × 0.0481233 ＝ 16,843.155 → ROUND_HALF_UP 16,843.16" \
  || ng "捨入：得 ${n}（banker's rounding 會得 16843.15）"

# lots 合計必須等於功能幣餘額——差一塊錢就代表有一次出資沒被記錄，
# 其歷史匯率沒被使用，差額會被靜默吸收進 CTA。
SRCMF3=99940000-0000-0000-0000-000000000013
SRCRUN3=99950000-0000-0000-0000-000000000013
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
VALUES ('$SRCMF3','$TEN','$ENG','$PR','NO_FX','sqlcanon-2','lotmismatch-src','$JIA');
INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, status, request_key, request_content_hash,
        engine_version, created_by)
VALUES ('$SRCRUN3','$TEN','$ENG','$PR','$B1','$SRCMF3','PREVIEW','RUNNING',gen_random_uuid(),
        'lotmismatch','1.0.0','$JIA');
INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit)
VALUES ('$TEN','$SRCRUN3','SOURCE_TB','$(acc 04001)','C4001','实收资本',0,9999999);
UPDATE calculation_run SET status='COMPLETED', result_content_hash='lm-r', completed_at=now()
 WHERE calculation_run_id='$SRCRUN3';
SQL
sel_inputs "$SRCRUN3" "$FXCASE" "$POLCASE"
expect_err "lots 合計（10,000,000）不等於功能幣餘額（9,999,999）→ 整筆拒絕" \
  "$T1 SELECT fn_fx_translation_run('$TEN','$ENG','$PR','$UNIT','$SRCRUN3','$FXCASE','$POLCASE','$JIA','x')" \
  "EQUITY_LOT_SUM_MISMATCH"
sel_inputs "$SRCRUN" "$FXCASE" "$POLCASE"

# ══ 14　整筆拒絕，不留半套 run ══════════════════════════════════════
pre=$(PSQL_C <<<"$T1 SELECT count(*) FROM calculation_run")
sel_inputs "$SRCRUN" "$FXV2" "$POLCASE"
expect_err "缺已批准匯率版本 → 整期折算不可用（G-07）" \
  "$T1 SELECT fn_fx_translation_run('$TEN','$ENG','$PR','$UNIT','$SRCRUN','$FXV2','$POLCASE','$JIA','x')" \
  "G07_RATE_VERSION_NOT_FROZEN"
sel_inputs "$SRCRUN" "$FXCASE" "$POLCASE"
expect_err "非 R2 不得發起折算" \
  "$T1 SELECT fn_fx_translation_run('$TEN','$ENG','$PR','$UNIT','$SRCRUN','$FXCASE','$POLCASE','$FXOPS','x')" \
  "ACTOR_ROLE_NOT_HELD"
post=$(PSQL_C <<<"$T1 SELECT count(*) FROM calculation_run")
[ "$pre" = "$post" ] && ok "被拒的折算不留下任何 run（連預覽都不產生）" \
  || ng "被拒後 run 數由 ${pre} 變為 ${post}"


# ══ 15　真正的 replay：只憑舊 Manifest 重算（AC-FX-001）══════════════
# 「同一批現行資料跑兩次結果相同」不等於「可重演」。這一節把現行主檔改到
# 足以改變結果，再用**同一份 Manifest** 重算——結果必須與原 run 一致。
PSQL_C >/dev/null 2>&1 <<SQL
$T1
-- 改分類（資產→費用）、改 Currency 精度。兩者若被回查，結果一定不同。
UPDATE account SET translation_category='EXPENSE' WHERE code='C1001';
UPDATE currency SET minor_unit=0 WHERE currency_code='CNY';
SQL
chg=$(PSQL_C <<<"$T1 SELECT translation_category||'/'||(SELECT minor_unit FROM currency WHERE currency_code='CNY')
  FROM account WHERE code='C1001'")
[ "$chg" = "EXPENSE/0" ] && ok "replay 前置：現行主檔已改（C1001 → EXPENSE，CNY → 0 位）" \
  || ng "replay 前置：主檔為 ${chg}"
RP=$(PSQL_C <<<"$T1 SELECT fn_fx_translation_replay('$FXRUN','$JIA','fx-1.0.0')")
st=$(PSQL_C <<<"$T1 SELECT status||'/'||COALESCE(failure_reason_code,'-') FROM calculation_run WHERE calculation_run_id='$RP'")
[ "$st" = "COMPLETED/-" ] && ok "replay：只憑舊 Manifest 重算成功（現行主檔已變仍一致）" \
  || ng "replay：狀態為 ${st}"
h=$(PSQL_C <<<"$T1 SELECT result_content_hash FROM calculation_run WHERE calculation_run_id='$RP'")
[ "$h" = "$h1" ] && ok "replay：result_content_hash 與原 run 完全相同" || ng "replay：雜湊不同"
n=$(PSQL_C <<<"$T1 SELECT tr.result_debit FROM translation_result tr
  JOIN balance_snapshot_line b ON b.snapshot_line_id=tr.source_snapshot_line_id
 WHERE tr.calculation_run_id='$RP' AND b.account_code='C1001'")
[ "$n" = "16842.00" ] && ok "replay：C1001 仍以凍結的 ASSET／2 位得 16,842.00（未回查現行分類與精度）" \
  || ng "replay：C1001 為 ${n}"
# 精度的重演證明必須用**乘積不整除**的案例：整除時 0 位與 2 位得到同一個數，
# 回查現行精度也看不出差別。
RP2=$(PSQL_C <<<"$T1 SELECT fn_fx_translation_replay('$FXRUN4','$JIA','fx-1.0.0')")
n=$(PSQL_C <<<"$T1 SELECT tr.result_debit FROM translation_result tr
  JOIN balance_snapshot_line b ON b.snapshot_line_id=tr.source_snapshot_line_id
 WHERE tr.calculation_run_id='$RP2' AND b.account_code='C1001'")
[ "$n" = "16843.16" ] && ok "replay：CNY 已改 0 位，重演仍以凍結的 2 位得 16,843.16" \
  || ng "replay：不整除案例得 ${n}（回查現行精度會得 16843.00）"
st=$(PSQL_C <<<"$T1 SELECT status FROM calculation_run WHERE calculation_run_id='$RP2'")
[ "$st" = "COMPLETED" ] && ok "replay：不整除案例的重演亦與原 run 一致" || ng "replay：狀態 ${st}"

n=$(PSQL_C <<<"$T1 SELECT manifest_id::text=(SELECT manifest_id::text FROM calculation_run
  WHERE calculation_run_id='$FXRUN') FROM calculation_run WHERE calculation_run_id='$RP'")
[ "$n" = "t" ] && ok "replay：引用同一份 Manifest（不建立新的凍結集合）" || ng "replay：Manifest 不同"
n=$(PSQL_C <<<"$T1 SELECT replay_of_run_id FROM calculation_run WHERE calculation_run_id='$RP'")
[ "$n" = "$FXRUN" ] && ok "replay：replay_of_run_id 指向原 run" || ng "replay：replay_of_run_id 為 ${n}"
n=$(PSQL_C <<<"$T1 SELECT status||'/'||result_content_hash FROM calculation_run WHERE calculation_run_id='$FXRUN'")
[ "$n" = "COMPLETED/$h1" ] && ok "replay：原 run 完全未被修改" || ng "replay：原 run 變成 ${n}"
PSQL_C >/dev/null 2>&1 <<SQL
$T1
UPDATE account SET translation_category='ASSET' WHERE code='C1001';
UPDATE currency SET minor_unit=2 WHERE currency_code='CNY';
SQL

# 重演不一致必須以 REPLAY_FAILED 結束，不得宣稱成功
# 竄改原 run 的結果雜湊（run 為終態，owner 也得停用守衛才改得動——
# 這正是「結果不可變」該有的阻力）
PSQL_C >/dev/null 2>&1 <<SQL
$T1
ALTER TABLE calculation_run DISABLE TRIGGER USER;
UPDATE calculation_run SET result_content_hash='刻意不符' WHERE calculation_run_id='$FXRUN2';
ALTER TABLE calculation_run ENABLE TRIGGER USER;
SQL
h4=$(PSQL_C <<<"$T1 SELECT result_content_hash FROM calculation_run WHERE calculation_run_id='$FXRUN2'")
[ "$h4" = "刻意不符" ] && ok "replay 前置：原 run 的結果雜湊已被竄改" || ng "replay 前置：雜湊為 ${h4}"
RPF=$(PSQL_C <<<"$T1 SELECT fn_fx_translation_replay('$FXRUN2','$JIA','fx-1.0.0')")
st=$(PSQL_C <<<"$T1 SELECT status||'/'||COALESCE(failure_reason_code,'-') FROM calculation_run WHERE calculation_run_id='$RPF'")
[ "$st" = "FAILED/REPLAY_FAILED" ] && ok "replay：結果不一致 → REPLAY_FAILED，不宣稱成功" \
  || ng "replay：狀態為 ${st}"

# Hash 演算法必須與宣告一致
n=$(PSQL_C <<<"$T1 SELECT length(frozen_set_content_hash)||'/'||hash_algorithm
  FROM calculation_input_manifest m JOIN calculation_run r ON r.manifest_id=m.manifest_id
 WHERE r.calculation_run_id='$FXRUN'")
[ "$n" = "64/sha256" ] && ok "凍結雜湊為 SHA-256（64 hex），與 hash_algorithm 宣告一致" \
  || ng "凍結雜湊為 ${n}"
n=$(PSQL_C <<<"$T1 SELECT length(result_content_hash) FROM calculation_run WHERE calculation_run_id='$FXRUN'")
[ "$n" = "64" ] && ok "結果雜湊亦為 SHA-256" || ng "結果雜湊長度 ${n}"
n=$(PSQL_C <<<"$T1 SELECT count(*) FROM calculation_manifest_entry e
  JOIN calculation_run r ON r.manifest_id=e.manifest_id
 WHERE r.calculation_run_id='$FXRUN' AND e.payload='{}'::jsonb")
[ "$n" = "0" ] && ok "凍結條目沒有空 payload（每一類都保存了實際使用的值）" \
  || ng "仍有 ${n} 筆空 payload"
n=$(PSQL_C <<<"$T1 SELECT payload->>'source_result_hash' FROM calculation_manifest_entry e
  JOIN calculation_run r ON r.manifest_id=e.manifest_id
 WHERE r.calculation_run_id='$FXRUN' AND e.object_type='SOURCE_CALCULATION_RUN'")
[ "$n" = "case001-r" ] && ok "凍結：來源 run 與其結果雜湊也在凍結清單內" || ng "來源雜湊為 ${n}"

# source run 的完整驗證
# 0038 之後，來源 run 的合法性由**選定函式**先擋（第一道防線）；
# 引擎內的同名檢查保留為縱深防禦，正常路徑走不到。
expect_err "選定：來源 run 非 COMPLETED → 拒絕" \
  "$T1 SELECT fn_period_fx_select_inputs('$PR','$RUN_RUNNING','$FXCASE','$POLCASE','$JIA')" \
  "FX_INPUT_SOURCE_RUN_INVALID"
expect_err "選定：來源 run 屬別的期間 → 拒絕" \
  "$T1 SELECT fn_period_fx_select_inputs('$RPC','$SRCRUN','$FXCASE','$POLCASE','$JIA')" \
  "FX_INPUT_SOURCE_RUN_INVALID\|ACTOR_ROLE_NOT_HELD"
expect_err "引擎前置：傳入的輸入與現行選定不一致 → 不建立任何 run" \
  "$T1 SELECT fn_fx_translation_run('$TEN','$ENG','$PR','$UNIT','$SRCRUN2','$FXCASE','$POLCASE','$JIA','x')" \
  "FX_INPUT_NOT_SELECTED"


# ══ 16　Manifest 自身的完整性（0035）══════════════════════════════
# 一般操作有不可變 trigger 擋著；這裡防的是另一類：資料修復、migration，
# 或 owner 停用 trigger 後的內容漂移。重演的意義就是回答
# 「這份證據還是不是當初那一份」，所以用之前必須先驗它。
tamper() {  # $1=SQL（以 owner 身分、停用觸發器後執行）
  PSQL_C >/dev/null 2>&1 <<SQL
$T1
ALTER TABLE calculation_manifest_entry DISABLE TRIGGER USER;
ALTER TABLE calculation_input_manifest DISABLE TRIGGER USER;
$1
ALTER TABLE calculation_input_manifest ENABLE TRIGGER USER;
ALTER TABLE calculation_manifest_entry ENABLE TRIGGER USER;
SQL
}
MFX=$(PSQL_C <<<"$T1 SELECT manifest_id FROM calculation_run WHERE calculation_run_id='$FXRUN'")
integ() {  # 竄改 → replay → 應為 FAILED/REPLAY_MANIFEST_INTEGRITY_FAILED 且無產出
  local name="$1" sqlmod="$2" sqlback="$3"
  tamper "$sqlmod"
  local rid st lines
  rid=$(PSQL_C <<<"$T1 SELECT fn_fx_translation_replay('$FXRUN','$JIA','fx-1.0.0')")
  st=$(PSQL_C <<<"$T1 SELECT status||'/'||COALESCE(failure_reason_code,'-')
       FROM calculation_run WHERE calculation_run_id='$rid'")
  lines=$(PSQL_C <<<"$T1 SELECT count(*) FROM balance_snapshot_line WHERE calculation_run_id='$rid'")
  tamper "$sqlback"
  if [ "$st" = "FAILED/REPLAY_MANIFEST_INTEGRITY_FAILED" ]; then
    ok "0035：${name} → REPLAY_MANIFEST_INTEGRITY_FAILED"
  else ng "0035：${name} → 狀態為 ${st}"; fi
  [ "$lines" = "0" ] && ok "0035：${name} 的 replay 沒有留下任何快照（驗證在物化之前）" \
    || ng "0035：${name} 留下 ${lines} 列快照"
}
integ "竄改 payload（只改內容、雜湊照舊）" \
  "UPDATE calculation_manifest_entry SET payload = jsonb_set(payload,'{minor_unit}','9')
    WHERE manifest_id='$MFX' AND object_type='CURRENCY_DEFINITION' AND payload->>'code'='CNY';" \
  "UPDATE calculation_manifest_entry SET payload = jsonb_set(payload,'{minor_unit}','2')
    WHERE manifest_id='$MFX' AND object_type='CURRENCY_DEFINITION' AND payload->>'code'='CNY';"
integ "竄改 content_hash" \
  "UPDATE calculation_manifest_entry SET content_hash = repeat('0',64)
    WHERE manifest_id='$MFX' AND object_type='TRANSLATION_POLICY_VERSION';" \
  "UPDATE calculation_manifest_entry SET content_hash = fn_fx_sha(content_canonical)
    WHERE manifest_id='$MFX' AND object_type='TRANSLATION_POLICY_VERSION';"
integ "竄改 frozen_set_content_hash" \
  "UPDATE calculation_input_manifest SET frozen_set_content_hash = repeat('a',64)
    WHERE manifest_id='$MFX';" \
  "UPDATE calculation_input_manifest SET frozen_set_content_hash =
     (SELECT fn_fx_sha(string_agg(content_hash,'|'
        ORDER BY object_type, COALESCE(object_id::text,''), content_hash))
        FROM calculation_manifest_entry WHERE manifest_id='$MFX')
    WHERE manifest_id='$MFX';"
# 三層檢查互為縱深，因此每一層都要有「只有它抓得到」的竄改：
# 只改 canonical → payload 重算的雜湊仍等於 content_hash，集合雜湊也沒變。
integ "只竄改 content_canonical" \
  "UPDATE calculation_manifest_entry SET content_canonical = content_canonical || ' '
    WHERE manifest_id='$MFX' AND object_type='EXCHANGE_RATE_VERSION';" \
  "UPDATE calculation_manifest_entry SET content_canonical = rtrim(content_canonical)
    WHERE manifest_id='$MFX' AND object_type='EXCHANGE_RATE_VERSION';"
# payload 與 canonical 一起改（彼此自洽）→ 只有逐條雜湊重算抓得到
integ "payload 與 canonical 一致地被改寫" \
  "UPDATE calculation_manifest_entry
      SET payload = jsonb_set(payload,'{minor_unit}','9'),
          content_canonical = object_type||':'||COALESCE(object_id::text,'-')||':'||
                              jsonb_pretty(jsonb_set(payload,'{minor_unit}','9'))
    WHERE manifest_id='$MFX' AND object_type='CURRENCY_DEFINITION' AND payload->>'code'='CNY';" \
  "UPDATE calculation_manifest_entry
      SET payload = jsonb_set(payload,'{minor_unit}','2'),
          content_canonical = object_type||':'||COALESCE(object_id::text,'-')||':'||
                              jsonb_pretty(jsonb_set(payload,'{minor_unit}','2'))
    WHERE manifest_id='$MFX' AND object_type='CURRENCY_DEFINITION' AND payload->>'code'='CNY';"

integ "刪除一筆凍結條目（集合雜湊因此不符）" \
  "DELETE FROM calculation_manifest_entry WHERE manifest_id='$MFX'
     AND object_type='ACCOUNT_TRANSLATION_CLASSIFICATION'
     AND ctid = (SELECT ctid FROM calculation_manifest_entry WHERE manifest_id='$MFX'
                  AND object_type='ACCOUNT_TRANSLATION_CLASSIFICATION' LIMIT 1);" \
  "SELECT 1;"
# 刪除的條目無法還原（因此排在最後——它會讓後續案例都因集合雜湊不符而假綠），
# 正控制改用另一個未受影響的 run
RPOK=$(PSQL_C <<<"$T1 SELECT fn_fx_translation_replay('$FXRUN4','$JIA','fx-1.0.0')")
st=$(PSQL_C <<<"$T1 SELECT status FROM calculation_run WHERE calculation_run_id='$RPOK'")
[ "$st" = "COMPLETED" ] && ok "0035：未受竄改的 Manifest 仍可正常重演（正控制）" \
  || ng "0035：正控制的 replay 狀態為 ${st}"
n=$(APP_C <<<"$T1 SELECT fn_fx_verify_manifest((SELECT manifest_id FROM calculation_run
     WHERE calculation_run_id='$FXRUN4'))" 2>&1 | grep -c "ERROR")
[ "$n" = "0" ] && ok "0035：app_runtime 可自行驗證凍結集合（稽核用）" || ng "0035：app_runtime 無法驗證"


# ══ 17　折算調節核對與期間級判定（0036–0038）══════════════════════
TOLV=f0380000-0000-0000-0000-000000000001
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO rounding_tolerance_version (tolerance_version_id, tenant_id, engagement_id,
        reporting_unit_id, source_currency, target_currency, single_limit, cumulative_limit,
        series_id, version_no, created_by)
VALUES ('$TOLV','$TEN','$ENG','$UNIT','JPY','CNY',0.05,0.20,
        'f0380000-0000-0000-0000-000000000101',1,'$JIA');
SQL
n=$(APP_C <<<"$T1 INSERT INTO rounding_tolerance_version (tenant_id, engagement_id,
      reporting_unit_id, source_currency, target_currency, single_limit, cumulative_limit,
      series_id, version_no, created_by, approved_by, approved_at)
    VALUES ('$TEN','$ENG','$UNIT','JPY','CNY',9,9,'f0380000-0000-0000-0000-000000000199',1,
            '$JIA','$JIA',now())" 2>&1 | grep -c "permission denied")
[ "$n" -ge 1 ] && ok "0036：app_runtime 不得自填容許值的批准欄（欄位級權限）" \
  || ng "0036：容許值批准欄可自填"
expect_err "0036：非 R4 不得批准容許值版本" \
  "$T1 SELECT fn_rounding_tolerance_approve('$TOLV','$JIA')" "ACTOR_ROLE_NOT_HELD"
expect_ok  "0036：R4 批准容許值版本" "$T1 SELECT fn_rounding_tolerance_approve('$TOLV','$FXU')"
expect_err "0036：已批准的容許值版本不可變更" \
  "$T1 UPDATE rounding_tolerance_version SET single_limit=1 WHERE tolerance_version_id='$TOLV'" \
  "TOLERANCE_IMMUTABLE"

# 調節：Case-001 的正控制——所有類別零筆（內部核對不產生尾差）。
# §16 的不可逆竄改破壞了 FXRUN 的凍結集合，因此另建一個乾淨的 run。
sel_inputs "$SRCRUN" "$FXCASE" "$POLCASE"
FXRUN5=$(PSQL_C <<<"$T1 SELECT fn_fx_translation_run('$TEN','$ENG','$PR','$UNIT','$SRCRUN','$FXCASE','$POLCASE','$JIA','fx-1.0.0')")
[ -n "$FXRUN5" ] && ok "0037 前置：另建凍結集合完整的 Case-001 FX run" || ng "0037 前置：建立失敗"
RECON=$(PSQL_C <<<"$T1 SELECT fn_translation_reconcile('$FXRUN5','$TOLV','$JIA','recon-1.0.0')")
[ -n "$RECON" ] && ok "0037：調節建立成功（單一交易、直接 FINALIZED）" || ng "0037：調節建立失敗"
n=$(PSQL_C <<<"$T1 SELECT count(*) FROM translation_difference WHERE reconciliation_id='$RECON'")
[ "$n" = "0" ] && ok "Case-001 調節：所有類別零筆差異（正確結果，非「還沒測到」）" \
  || ng "Case-001 調節：出現 ${n} 筆差異"
n=$(PSQL_C <<<"$T1 SELECT status||'/'||single_limit_snapshot||'/'||cumulative_limit_snapshot
     FROM translation_reconciliation WHERE reconciliation_id='$RECON'")
[ "$n" = "FINALIZED/0.05/0.20" ] && ok "0037：容許值快照凍結在調節上（不在 FX Manifest）" \
  || ng "0037：調節快照為 ${n}"
n=$(PSQL_C <<<"$T1 SELECT (reconciliation_engine_version='recon-1.0.0')
     AND (canonicalization_version='sqlcanon-2') AND (length(reconciliation_input_hash)=64)
     FROM translation_reconciliation WHERE reconciliation_id='$RECON'")
[ "$n" = "t" ] && ok "0037：保存 engine／canonicalization 版本與 SHA-256 輸入雜湊" \
  || ng "0037：版本或雜湊不符"
expect_err "0037：同一 run 至多一份調節" \
  "$T1 SELECT fn_translation_reconcile('$FXRUN5','$TOLV','$JIA','recon-1.0.0')" "duplicate key"
expect_err "0036：調節不可 UPDATE" \
  "$T1 UPDATE translation_reconciliation SET status='FINALIZED' WHERE reconciliation_id='$RECON'" \
  "FX_OUTPUT_IMMUTABLE"
expect_err "0036：調節不可 DELETE" \
  "$T1 DELETE FROM translation_reconciliation WHERE reconciliation_id='$RECON'" "FX_OUTPUT_IMMUTABLE"

# tolerance 的幣別對與明確指定
TOLBAD=f0380000-0000-0000-0000-000000000002
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO rounding_tolerance_version (tolerance_version_id, tenant_id, engagement_id,
        reporting_unit_id, source_currency, target_currency, single_limit, cumulative_limit,
        series_id, version_no, created_by)
VALUES ('$TOLBAD','$TEN','$ENG','$UNIT','USD','JPY',1,1,
        'f0380000-0000-0000-0000-000000000102',1,'$JIA');
SQL
PSQL_C >/dev/null 2>&1 <<<"$T1 SELECT fn_rounding_tolerance_approve('$TOLBAD','$FXU')"
expect_err "0037：容許值的幣別對與本 run 的報告幣不符 → 拒絕" \
  "$T1 SELECT fn_translation_reconcile('$FXRUN3','$TOLBAD','$JIA','recon-1.0.0')" \
  "TOLERANCE_CURRENCY_PAIR_MISMATCH"
TOLDRAFT=f0380000-0000-0000-0000-000000000003
PSQL_C >/dev/null 2>&1 <<SQL
$T1
INSERT INTO rounding_tolerance_version (tolerance_version_id, tenant_id, engagement_id,
        reporting_unit_id, source_currency, target_currency, single_limit, cumulative_limit,
        series_id, version_no, created_by)
VALUES ('$TOLDRAFT','$TEN','$ENG','$UNIT','JPY','CNY',1,1,
        'f0380000-0000-0000-0000-000000000103',1,'$JIA');
SQL
expect_err "0037：未批准的容許值版本不得使用" \
  "$T1 SELECT fn_translation_reconcile('$FXRUN3','$TOLDRAFT','$JIA','recon-1.0.0')" \
  "TOLERANCE_NOT_APPROVED"

# ── INV-24：schema-level fixture ──
# **本樣本不由折算流程產生**，用於驗證 DB 約束與 INV-24 判定。
# 內部核對不產生尾差（引擎與 C2 同法同率），因此尾差只會來自日後的對外核對。
RECON2=$(PSQL_C <<<"$T1 SELECT fn_translation_reconcile('$FXRUN3','$TOLV','$JIA','recon-1.0.0')")
mkdiff() {  # $1=line_no $2=actual $3=comparison $4=unrounded $5=rounded
  echo "$T1 INSERT INTO translation_difference (tenant_id, reconciliation_id, check_id,
        comparison_context, actual_amount, comparison_amount, actual_difference, reason_class,
        rounding_basis, unrounded_amount, rounded_amount, currency_minor_unit, rounding_mode,
        expected_rounding_residual, detail, line_no)
   VALUES ('$TEN','$RECON2','C2','EXTERNAL_OUTPUT',$2,$3,$2-$3,'ROUNDING_DIFFERENCE',
           $4,$4,$5,2,'ROUND_HALF_UP',$5-$4,'schema-level fixture（不由折算流程產生）',$1)"
}
expect_err "0036：內部重算的差異不得標為 ROUNDING_DIFFERENCE" \
  "$T1 INSERT INTO translation_difference (tenant_id, reconciliation_id, check_id,
        comparison_context, actual_amount, comparison_amount, actual_difference, reason_class,
        rounding_basis, unrounded_amount, rounded_amount, currency_minor_unit, rounding_mode,
        expected_rounding_residual, detail, line_no)
   VALUES ('$TEN','$RECON2','C2','INTERNAL_RECALCULATION',1,0.99,0.01,'ROUNDING_DIFFERENCE',
           0.99,0.99,1.00,2,'ROUND_HALF_UP',0.01,'x',90)" "violates check constraint"
expect_err "0036：尾差缺算術推導 → 拒絕" \
  "$T1 INSERT INTO translation_difference (tenant_id, reconciliation_id, check_id,
        comparison_context, actual_amount, comparison_amount, actual_difference, reason_class,
        detail, line_no)
   VALUES ('$TEN','$RECON2','C2','EXTERNAL_OUTPUT',1,0.99,0.01,'ROUNDING_DIFFERENCE','x',91)" \
  "violates check constraint"
expect_err "0036：尾差的方向必須與捨入殘差一致（絕對值相等不夠）" \
  "$(mkdiff 92 0.99 1.00 1.00 1.01)" "violates check constraint"
expect_err "0036：非尾差不得被自動結案" \
  "$T1 INSERT INTO translation_difference (tenant_id, reconciliation_id, check_id,
        comparison_context, actual_amount, comparison_amount, actual_difference, reason_class,
        resolution_status, detail, line_no)
   VALUES ('$TEN','$RECON2','C2','EXTERNAL_OUTPUT',1,0,1,'MISSING_RATE',
           'RESOLVED_BY_POLICY','x',93)" "violates check constraint"


# C2 是獨立重算：竄改產出後，調節必須抓出來（否則「第二次驗算」名不副實）
sel_inputs "$SRCRUN" "$FXCASE" "$POLCASE"
FXRUN6=$(PSQL_C <<<"$T1 SELECT fn_fx_translation_run('$TEN','$ENG','$PR','$UNIT','$SRCRUN','$FXCASE','$POLCASE','$JIA','fx-1.0.0')")
PSQL_C >/dev/null 2>&1 <<SQL
$T1
ALTER TABLE translation_result DISABLE TRIGGER USER;
UPDATE translation_result tr SET result_debit = result_debit + 100
  FROM balance_snapshot_line b
 WHERE b.snapshot_line_id = tr.source_snapshot_line_id
   AND tr.calculation_run_id = '$FXRUN6' AND b.account_code = 'C1001';
ALTER TABLE translation_result ENABLE TRIGGER USER;
SQL
n=$(PSQL_C <<<"$T1 SELECT tr.result_debit FROM translation_result tr
  JOIN balance_snapshot_line b ON b.snapshot_line_id=tr.source_snapshot_line_id
 WHERE tr.calculation_run_id='$FXRUN6' AND b.account_code='C1001'")
[ "$n" = "16942.00" ] && ok "C2 前置：產出已被竄改（16,842.00 → 16,942.00）" \
  || ng "C2 前置：竄改後為 ${n}"
RECON3=$(PSQL_C <<<"$T1 SELECT fn_translation_reconcile('$FXRUN6','$TOLV','$JIA','recon-1.0.0')")
n=$(PSQL_C <<<"$T1 SELECT reason_class||':'||actual_difference FROM translation_difference
     WHERE reconciliation_id='$RECON3' AND check_id='C2'")
[ "$n" = "UNEXPLAINED:100.00" ] && ok "C2：獨立重算抓出被竄改的產出（UNEXPLAINED 100.00）" \
  || ng "C2：得 ${n}"
n=$(PSQL_C <<<"$T1 SELECT count(*) FROM translation_difference
     WHERE reconciliation_id='$RECON3' AND reason_class='ROUNDING_DIFFERENCE'")
[ "$n" = "0" ] && ok "C2：竄改造成的差異不得被歸為尾差" || ng "C2：出現 ${n} 筆尾差"

# ══ 18　兩支 readiness（0038）══════════════════════════════════════
inrdy() { PSQL_C <<<"$T1 SELECT COALESCE((SELECT code FROM fn_period_fx_input_readiness('$1')
          WHERE NOT ok ORDER BY seq LIMIT 1),'READY')"; }
n=$(inrdy "$PR")
[ "$n" = "READY" ] && ok "0038 輸入就緒：Case-001 的輸入齊備 → READY" || ng "0038 輸入就緒：${n}"
n=$(inrdy "$GRP_PR")
[ "$n" = "G07_INPUT_NOT_SELECTED" ] && ok "0038 輸入就緒：未選定輸入 → G07_INPUT_NOT_SELECTED" \
  || ng "0038 輸入就緒：未選定時得 ${n}"
# 兩支各司其職：尚未選定「結果」時，輸入就緒仍可通過
n=$(PSQL_C <<<"$T1 SELECT fn_period_fx_result_ready('$PR')")
[ "$n" = "POSTFX_RUN_NOT_SELECTED" ] && ok "0038 結果就緒：尚未選定結果 → POSTFX_RUN_NOT_SELECTED" \
  || ng "0038 結果就緒：${n}"
[ "$(inrdy "$PR")" = "READY" ] && ok "0038：輸入就緒不因「尚無結果」而失敗（不形成循環）" \
  || ng "0038：輸入就緒被結果條件污染"

expect_err "0038 選定結果：非 R4 不得選定" \
  "$T1 SELECT fn_period_fx_select_run('$PR','$FXRUN5','$RECON','$JIA')" "ACTOR_ROLE_NOT_HELD"
expect_err "0038 選定結果：replay run 不得作為現行結論" \
  "$T1 SELECT fn_period_fx_select_run('$PR','$RP','$RECON','$FXU')" \
  "FX_SELECTION_RUN_IS_REPLAY\|§24.1A"
expect_err "0038 選定結果：調節不屬選定的 run → 拒絕" \
  "$T1 SELECT fn_period_fx_select_run('$PR','$FXRUN3','$RECON','$FXU')" "FX_SELECTION_RECON_MISMATCH"
expect_ok  "0038 選定結果：R4 選定 run 與其調節" \
  "$T1 SELECT fn_period_fx_select_run('$PR','$FXRUN5','$RECON','$FXU')"
n=$(PSQL_C <<<"$T1 SELECT fn_period_fx_result_ready('$PR')")
[ "$n" = "POST_FX_RECONCILIATION_READY" ] && ok "0038 結果就緒：零差異 → POST_FX_RECONCILIATION_READY" \
  || ng "0038 結果就緒：${n}"

# 硬差異只要存在就失敗，狀態無關
DIFF=$(PSQL_C <<<"$T1 INSERT INTO translation_difference (tenant_id, reconciliation_id, check_id,
        comparison_context, actual_amount, comparison_amount, actual_difference, reason_class,
        detail, line_no)
   VALUES ('$TEN','$RECON','C2','INTERNAL_RECALCULATION',1,0,1,'MISSING_RATE','注入的硬差異',80)
   RETURNING difference_id")
n=$(PSQL_C <<<"$T1 SELECT fn_period_fx_result_ready('$PR')")
[ "$n" = "POSTFX_HARD_DIFFERENCE_PRESENT" ] && ok "0038：硬差異存在 → 結果就緒失敗" \
  || ng "0038：硬差異存在卻得 ${n}"
expect_ok  "0038：R4 可將硬差異標為 ACCEPTED_EXCEPTION（調查紀錄）" \
  "$T1 SELECT fn_translation_difference_resolve('$DIFF','$FXU','ACCEPTED_EXCEPTION','已調查：缺率')"
n=$(PSQL_C <<<"$T1 SELECT fn_period_fx_result_ready('$PR')")
[ "$n" = "POSTFX_HARD_DIFFERENCE_PRESENT" ] && ok "0038：標成 ACCEPTED_EXCEPTION **仍**不通過（G-07 是硬守衛）" \
  || ng "0038：人工狀態讓硬錯誤放行 → ${n}"
expect_err "0038：已是終態的差異不得再改" \
  "$T1 SELECT fn_translation_difference_resolve('$DIFF','$FXU','EXPLAINED','再改一次')" \
  "FX_DIFFERENCE_ALREADY_RESOLVED"
expect_err "0036：差異不得經一般 UPDATE 修改" \
  "$T1 UPDATE translation_difference SET resolution_status='RESOLVED' WHERE difference_id='$DIFF'" \
  "FX_OUTPUT_IMMUTABLE"

# selection 版本鏈：不得分叉
SEL1=$(PSQL_C <<<"$T1 SELECT run_selection_id FROM period_fx_run_selection
       WHERE period_revision_id='$PR' ORDER BY version_no DESC LIMIT 1")
expect_err "0036：selection 不可修改（換選擇請發新版本）" \
  "$T1 UPDATE period_fx_run_selection SET selected_by='$JIA' WHERE run_selection_id='$SEL1'" \
  "FX_SELECTION_IMMUTABLE"
# v1 已被 v2 指向後，再造一個 v3 也指向 v1 → 唯一索引擋下（不得分叉）
expect_ok  "0036 前置：R4 改選（發 v2，向後指向 v1）" \
  "$T1 SELECT fn_period_fx_select_run('$PR','$FXRUN5','$RECON','$FXU')"
SELV1=$(PSQL_C <<<"$T1 SELECT run_selection_id FROM period_fx_run_selection
        WHERE period_revision_id='$PR' AND version_no=1")
expect_err "0036：同一舊版不得被兩個新版指向（不得分叉）" \
  "$T1 INSERT INTO period_fx_run_selection (tenant_id, engagement_id, period_revision_id,
        reporting_unit_id, selected_run_id, selected_reconciliation_id, selection_series_id,
        version_no, supersedes_selection_id, selected_by)
   SELECT tenant_id, engagement_id, period_revision_id, reporting_unit_id, selected_run_id,
          selected_reconciliation_id, selection_series_id, 3, '$SELV1', selected_by
     FROM period_fx_run_selection WHERE run_selection_id='$SELV1'" \
  "duplicate key"

# 跨租戶：唯讀函式也不得洩漏
n=$(APP_C <<<"$T2 SELECT fn_period_fx_result_ready('$PR')" 2>&1 | grep -c "CROSS_TENANT_DENIED")
[ "$n" -ge 1 ] && ok "0038：唯讀判定函式驗 current_tenant()，不因 UUID 可猜而洩漏" \
  || ng "0038：跨租戶可讀取判定結論"

[ "${STANDALONE:-0}" = "1" ] && summary
