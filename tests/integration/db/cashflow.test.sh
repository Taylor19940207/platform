#!/usr/bin/env bash
# 現金流支持資料的結構守衛（0039／0040）——SLICE-M3-04 第一段。
# 本檔只驗**結構**：型別與外鍵、零活動的必填、內容雜湊、多批次橋接。
# 函式層（批准、產生、完整度、控制總額）屬第二段。
if [ -z "${DB_TEST_HARNESS:-}" ]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
  DB_TEST_HARNESS=1; STANDALONE=1
  echo "══ 現金流支持資料（0039／0040）（${DB}）══"
fi
fx_reset; fx_core; fx_accounts

CFSET=c0400000-0000-0000-0000-000000000001
CFCLS=c0410000-0000-0000-0000-000000000001
CFCLS_FXE=c0410000-0000-0000-0000-000000000002
CFPOL=c0420000-0000-0000-0000-000000000001
CFDS=c0430000-0000-0000-0000-000000000001
CFMF=c0440000-0000-0000-0000-000000000001
CFRUN=c0450000-0000-0000-0000-000000000001
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
INSERT INTO cash_flow_class_set_version (class_set_version_id, tenant_id, engagement_id, label,
        series_id, version_no, created_by)
VALUES ('${CFSET}','${TEN}','${ENG}','CF 分類 v1','c0400000-0000-0000-0000-000000000101',1,'${JIA}');
INSERT INTO cash_flow_class (cash_flow_class_id, tenant_id, class_set_version_id, code, name,
        kind, activity, direction, is_required) VALUES
  ('${CFCLS}','${TEN}','${CFSET}','OP-01','銷售收現','ACTIVITY','OPERATING','INFLOW',true),
  ('${CFCLS_FXE}','${TEN}','${CFSET}','FXE','匯率變動對現金的影響','FX_EFFECT_ON_CASH',
   NULL,'EITHER',true);
INSERT INTO cash_flow_cash_account_membership (tenant_id, class_set_version_id, account_id, cash_role)
VALUES ('${TEN}','${CFSET}','${ACC1}','CASH');
INSERT INTO cash_flow_policy_version (policy_version_id, tenant_id, engagement_id,
        reporting_unit_id, method, required_granularity, class_set_version_id, evidence_version,
        series_id, version_no, created_by)
VALUES ('${CFPOL}','${TEN}','${ENG}','${UNIT}','DIRECT','BALANCE','${CFSET}','母公司確認函 v1',
        'c0420000-0000-0000-0000-000000000101',1,'${JIA}');
SQL
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM cash_flow_class WHERE class_set_version_id='${CFSET}'")
[ "$n" = "2" ] && ok "0039：分類集合可含 ACTIVITY 與 FX_EFFECT_ON_CASH 兩種 kind" \
  || ng "0039：分類數為 ${n}"

# ── kind 與 activity 的對應 ──
expect_err "0039：ACTIVITY 必須有 activity" \
  "${T1} INSERT INTO cash_flow_class (tenant_id, class_set_version_id, code, name, kind, direction)
   VALUES ('${TEN}','${CFSET}','BAD1','缺 activity','ACTIVITY','INFLOW')" "violates check constraint"
expect_err "0039：FX_EFFECT_ON_CASH 不得帶 activity（它不是第四種活動）" \
  "${T1} INSERT INTO cash_flow_class (tenant_id, class_set_version_id, code, name, kind, activity, direction)
   VALUES ('${TEN}','${CFSET}','BAD2','錯誤控制項','FX_EFFECT_ON_CASH','OPERATING','INFLOW')" \
  "violates check constraint"
expect_err "0039：政策的粒度不接受 ACCOUNT（那是 source_kind）" \
  "${T1} INSERT INTO cash_flow_policy_version (tenant_id, engagement_id, reporting_unit_id,
        method, required_granularity, class_set_version_id, evidence_version, series_id,
        version_no, created_by)
   VALUES ('${TEN}','${ENG}','${UNIT}','DIRECT','ACCOUNT','${CFSET}','x',
           'c0420000-0000-0000-0000-000000000199',1,'${JIA}')" "violates check constraint"
expect_err "0039：政策的 evidence_version 不得為空" \
  "${T1} INSERT INTO cash_flow_policy_version (tenant_id, engagement_id, reporting_unit_id,
        method, required_granularity, class_set_version_id, evidence_version, series_id,
        version_no, created_by)
   VALUES ('${TEN}','${ENG}','${UNIT}','DIRECT','BALANCE','${CFSET}','',
           'c0420000-0000-0000-0000-000000000198',1,'${JIA}')" "violates check constraint"

# ── 粒度相容：單一實作 ──
for t in "BALANCE:BALANCE:t" "JOURNAL:BALANCE:t" "BALANCE:JOURNAL:f" "DOCUMENT:SUBLEDGER:t"; do
  a="${t%%:*}"; rest="${t#*:}"; r="${rest%%:*}"; want="${rest##*:}"
  got=$(PSQL_C <<<"${T1} SELECT fn_granularity_satisfies('$a','$r')")
  [ "$got" = "$want" ] && ok "0039 粒度：實際 $a 對要求 $r → ${want}（更細不是錯）" \
    || ng "0039 粒度：$a/$r 得 ${got}"
done
got=$(PSQL_C <<<"${T1} SELECT fn_source_kind_granularity('ACCOUNT')")
[ "$got" = "BALANCE" ] && ok "0039：source_kind ACCOUNT 對應粒度 BALANCE" || ng "0039：得 ${got}"

# ── 0040：來源引用的型別與外鍵 ──
n=$(PSQL_C <<<"${T1} SELECT data_type FROM information_schema.columns
     WHERE table_name='cash_flow_source_fact' AND column_name='source_ledger_line_id'")
[ "$n" = "bigint" ] && ok "0040：fact 的 source_ledger_line_id 型別為 bigint" || ng "0040：型別為 ${n}"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM pg_constraint
     WHERE conrelid='cash_flow_source_fact'::regclass AND contype='f'
       AND confrelid IN ('source_ledger_line'::regclass,'source_document'::regclass)")
[ "$n" = "2" ] && ok "0040：兩個來源引用都有真正的外鍵" || ng "0040：外鍵數為 ${n}"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM pg_constraint
     WHERE conrelid='cash_flow_mapping_rule'::regclass AND contype='f'
       AND confrelid IN ('source_ledger_line'::regclass,'source_document'::regclass)")
[ "$n" = "2" ] && ok "0040：映射規則的兩個來源引用也有外鍵" || ng "0040：外鍵數為 ${n}"

# ── 0040：用途封套與 fact 的父鏈 ──
# 真正的支持資料集＋已接受批次（否則 fact 的測試會被封套守衛先擋住）
CFB=c0460000-0000-0000-0000-000000000001
CFSD=c0470000-0000-0000-0000-000000000001
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by, status, file_name)
VALUES ('${CFB}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR}','${JIA}',
        '${JIA}','VALIDATING','cash-flow-support.csv');   -- 已接受的批次來源集合已封存
INSERT INTO data_coverage (data_coverage_id, tenant_id, import_batch_id, batch_version,
        granularity, completeness_status) VALUES
  ('c0480000-0000-0000-0000-000000000001','${TEN}','${CFB}',1,'BALANCE','COMPLETE'),
  -- 同一批次另有更細的 DOCUMENT 覆蓋度——0040 的洞就是讓 BALANCE 的 fact 冒用它
  ('c0480000-0000-0000-0000-000000000002','${TEN}','${CFB}',1,'DOCUMENT','COMPLETE');
INSERT INTO source_dataset (source_dataset_id, tenant_id, import_batch_id, granularity,
        content_sha256, row_count, batch_version)
VALUES ('${CFSD}','${TEN}','${CFB}','BALANCE','sha-cf',1,1);
INSERT INTO cash_flow_support_dataset (source_dataset_id, tenant_id, engagement_id,
        period_revision_id, reporting_unit_id, import_batch_id, content_hash, data_coverage_id)
VALUES ('${CFSD}','${TEN}','${ENG}','${PR}','${UNIT}','${CFB}','ds-hash',
        'c0480000-0000-0000-0000-000000000001');
ALTER TABLE import_batch DISABLE TRIGGER USER;
UPDATE import_batch SET status='ACCEPTED' WHERE import_batch_id='${CFB}';
ALTER TABLE import_batch ENABLE TRIGGER USER;
SQL
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM cash_flow_support_dataset WHERE source_dataset_id='${CFSD}'")
[ "${n}" = "1" ] && ok "0040 前置：現金流支持資料集已建立（批次已 ACCEPTED）" \
  || ng "0040 前置：支持資料集建立失敗"

expect_err "0040：fact 不得引用非現金流支持資料集" \
  "${T1} INSERT INTO cash_flow_source_fact (tenant_id, engagement_id, period_revision_id,
        reporting_unit_id, source_dataset_id, import_batch_id, actual_granularity, source_kind,
        account_id, source_row_id, signed_amount_functional, functional_currency, content_hash)
   VALUES ('${TEN}','${ENG}','${PR}','${UNIT}','${CFDS}','${B1}','BALANCE','ACCOUNT','${ACC1}',
           'r1',100,'JPY','h')" "violates foreign key\|CFS_DATASET_NOT_SUPPORT_PURPOSE"
expect_err "0039：fact 的 content_hash 不得為空" \
  "${T1} INSERT INTO cash_flow_source_fact (tenant_id, engagement_id, period_revision_id,
        reporting_unit_id, source_dataset_id, import_batch_id, actual_granularity, source_kind,
        account_id, source_row_id, signed_amount_functional, functional_currency)
   VALUES ('${TEN}','${ENG}','${PR}','${UNIT}','${CFSD}','${CFB}','BALANCE','ACCOUNT','${ACC1}',
           'r1',100,'JPY')" "not-null"
# 用**存在的**來源列，否則會先撞上「來源列屬於其他租戶」（查不到 → NULL）
SLL=$(PSQL_C <<<"${T1} SELECT source_ledger_line_id FROM source_ledger_line LIMIT 1")
expect_err "0040：ACCOUNT 的 fact 不得帶來源列引用（矩陣）" \
  "${T1} INSERT INTO cash_flow_source_fact (tenant_id, engagement_id, period_revision_id,
        reporting_unit_id, source_dataset_id, import_batch_id, actual_granularity, source_kind,
        account_id, source_row_id, source_ledger_line_id, signed_amount_functional,
        functional_currency, content_hash)
   VALUES ('${TEN}','${ENG}','${PR}','${UNIT}','${CFSD}','${CFB}','BALANCE','ACCOUNT','${ACC1}',
           'r1',COALESCE(NULLIF('${SLL}','')::bigint, 1),100,'JPY','h')" \
  "violates check constraint\|來源列"
expect_ok  "0040：合格的 fact（封套、批次、粒度、矩陣皆相符）→ 接受" \
  "${T1} INSERT INTO cash_flow_source_fact (tenant_id, engagement_id, period_revision_id,
        reporting_unit_id, source_dataset_id, import_batch_id, actual_granularity, source_kind,
        account_id, source_row_id, signed_amount_functional, functional_currency, content_hash)
   VALUES ('${TEN}','${ENG}','${PR}','${UNIT}','${CFSD}','${CFB}','BALANCE','ACCOUNT','${ACC1}',
           'r1',-350000,'JPY','f1')"
expect_err "0040：fact 建立後不可 UPDATE（更正走新批次與新資料集）" \
  "${T1} UPDATE cash_flow_source_fact SET signed_amount_functional=1 WHERE content_hash='f1'" \
  "CFS_FACT_IMMUTABLE"
expect_err "0040：fact 宣告的粒度與該資料集的 DataCoverage 不符 → 拒絕" \
  "${T1} INSERT INTO cash_flow_source_fact (tenant_id, engagement_id, period_revision_id,
        reporting_unit_id, source_dataset_id, import_batch_id, actual_granularity, source_kind,
        account_id, source_row_id, signed_amount_functional, functional_currency, content_hash)
   VALUES ('${TEN}','${ENG}','${PR}','${UNIT}','${CFSD}','${CFB}','JOURNAL','ACCOUNT','${ACC1}',
           'r2',100,'JPY','f2')" "CFS_GRANULARITY_MISDECLARED"

# ── 0040：零活動的四組資料必填 ──
expect_err "0040：零活動缺 reason → 拒絕" \
  "${T1} INSERT INTO cash_flow_class_period_coverage (tenant_id, period_revision_id,
        reporting_unit_id, policy_version_id, cash_flow_class_id, status, confirmed_by,
        confirmed_at, reviewed_by, reviewed_at, evidence_ref)
   VALUES ('${TEN}','${PR}','${UNIT}','${CFPOL}','${CFCLS}','ZERO_ACTIVITY_CONFIRMED',
           '${JIA}',now(),'${YI}',now(),'底稿')" "violates check constraint"
expect_err "0040：零活動缺 R3 覆核 → 拒絕" \
  "${T1} INSERT INTO cash_flow_class_period_coverage (tenant_id, period_revision_id,
        reporting_unit_id, policy_version_id, cash_flow_class_id, status, confirmed_by,
        confirmed_at, reason, evidence_ref)
   VALUES ('${TEN}','${PR}','${UNIT}','${CFPOL}','${CFCLS}','ZERO_ACTIVITY_CONFIRMED',
           '${JIA}',now(),'本期無此類活動','底稿')" "violates check constraint"
expect_ok  "0040：零活動四組資料齊備 → 接受" \
  "${T1} INSERT INTO cash_flow_class_period_coverage (tenant_id, period_revision_id,
        reporting_unit_id, policy_version_id, cash_flow_class_id, status, confirmed_by,
        confirmed_at, reviewed_by, reviewed_at, reason, evidence_ref)
   VALUES ('${TEN}','${PR}','${UNIT}','${CFPOL}','${CFCLS}','ZERO_ACTIVITY_CONFIRMED',
           '${JIA}',now(),'${YI}',now(),'本期無此類活動','底稿 #1')"
# 父鏈正確的一列（PR＋UNIT＋CFPOL＋CFCLS_FXE）——原本的 GRP_PR＋GRP_UNIT
# 搭配 UNIT 政策本身就是無效父鏈，0042 的 DB 防線會先以別的理由擋下，
# 那條測試就會「以錯誤理由通過」。
expect_err "0040：COVERAGE_EXCEPTION 必須帶 exception_id" \
  "${T1} INSERT INTO cash_flow_class_period_coverage (tenant_id, period_revision_id,
        reporting_unit_id, policy_version_id, cash_flow_class_id, status)
   VALUES ('${TEN}','${PR}','${UNIT}','${CFPOL}','${CFCLS_FXE}','COVERAGE_EXCEPTION')" \
  "violates check constraint"

# ── 0040：多批次橋接 ──
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
VALUES ('${CFMF}','${TEN}','${ENG}','${PR}','CASH_FLOW_SUPPORT','sqlcanon-2','cf','${JIA}');
SQL
expect_err "0040：現金流 run 不得填單一 import_batch_id（來源以橋接凍結）" \
  "${T1} INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id,
        period_revision_id, import_batch_id, manifest_id, run_type, status, request_key,
        request_content_hash, engine_version, created_by)
   VALUES ('${CFRUN}','${TEN}','${ENG}','${PR}','${B1}','${CFMF}','PREVIEW','RUNNING',
           gen_random_uuid(),'h','1.0.0','${JIA}')" "CFS_RUN_SINGLE_BATCH_NOT_ALLOWED"
expect_ok  "0040：現金流 run 的 import_batch_id 可為 NULL" \
  "${T1} INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id,
        period_revision_id, manifest_id, run_type, status, request_key, request_content_hash,
        engine_version, created_by)
   VALUES ('${CFRUN}','${TEN}','${ENG}','${PR}','${CFMF}','PREVIEW','RUNNING',
           gen_random_uuid(),'h','1.0.0','${JIA}')"
expect_err "0040：未 ACCEPTED 的批次不得進入橋接" \
  "${T1} INSERT INTO calculation_run_source_batch (calculation_run_id, import_batch_id, tenant_id)
   VALUES ('${CFRUN}','${B2}','${TEN}')" "CFS_BATCH_NOT_ACCEPTED"
expect_ok  "0040：已接受的批次可進入橋接" \
  "${T1} INSERT INTO calculation_run_source_batch (calculation_run_id, import_batch_id, tenant_id)
   VALUES ('${CFRUN}','${CFB}','${TEN}')"
expect_err "0040：同一 run 同一批次不得重複橋接" \
  "${T1} INSERT INTO calculation_run_source_batch (calculation_run_id, import_batch_id, tenant_id)
   VALUES ('${CFRUN}','${CFB}','${TEN}')" "duplicate key"

# ── NO_FX／FX 的既有行為不得被放寬 ──
# 用**明確建立**的 manifest，不用 SELECT … LIMIT 1——空集合會插入零列而「成功」
NOFXMF=c0440000-0000-0000-0000-000000000002
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
VALUES ('${NOFXMF}','${TEN}','${ENG}','${PR}','NO_FX','sqlcanon-2','nofx','${JIA}');
SQL
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM calculation_input_manifest WHERE manifest_id='${NOFXMF}'")
[ "${n}" = "1" ] && ok "0040 前置：NO_FX manifest 已建立" || ng "0040 前置：manifest 建立失敗"
expect_err "0040：NO_FX run 仍必須指明來源批次（既有行為不變）" \
  "${T1} INSERT INTO calculation_run (tenant_id, engagement_id, period_revision_id, manifest_id,
        run_type, status, request_key, request_content_hash, engine_version, created_by)
   VALUES ('${TEN}','${ENG}','${PR}','${NOFXMF}','PREVIEW','RUNNING',gen_random_uuid(),'h','1.0.0','${JIA}')" \
  "Run 必須指明來源批次"


# ══ 0041：封套必須指向**該 dataset 自己的** DataCoverage ══════════
CFSD2=c0470000-0000-0000-0000-000000000002
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by, status, file_name)
VALUES ('c0460000-0000-0000-0000-000000000002','${TEN}','${ENG}',
        'cccccccc-0000-0000-0000-000000000001','${PR}','${JIA}','${JIA}','VALIDATING','other.csv');
INSERT INTO source_dataset (source_dataset_id, tenant_id, import_batch_id, granularity,
        content_sha256, row_count, batch_version)
VALUES ('${CFSD2}','${TEN}','c0460000-0000-0000-0000-000000000002','BALANCE','sha-2',1,1);
SQL
# 隔離用第二個批次：同一批次不得有兩個同粒度 dataset（唯一鍵），
# 因此「BALANCE dataset 冒用 DOCUMENT 覆蓋度」要在自己的批次內構造。
CFB3=c0460000-0000-0000-0000-000000000003
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by, status, file_name)
VALUES ('${CFB3}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR}','${JIA}',
        '${JIA}','VALIDATING','mix.csv');
INSERT INTO data_coverage (data_coverage_id, tenant_id, import_batch_id, batch_version,
        granularity, completeness_status) VALUES
  ('c0480000-0000-0000-0000-000000000011','${TEN}','${CFB3}',1,'BALANCE','COMPLETE'),
  ('c0480000-0000-0000-0000-000000000012','${TEN}','${CFB3}',1,'DOCUMENT','COMPLETE');
INSERT INTO source_dataset (source_dataset_id, tenant_id, import_batch_id, granularity,
        content_sha256, row_count, batch_version)
VALUES ('c0470000-0000-0000-0000-000000000003','${TEN}','${CFB3}','BALANCE','sha-mix',1,1);
SQL
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM source_dataset WHERE source_dataset_id='c0470000-0000-0000-0000-000000000003'")
[ "${n}" = "1" ] && ok "0041 前置：同批次同時有 BALANCE 與 DOCUMENT 覆蓋度" \
  || ng "0041 前置：混合批次建立失敗"
expect_err "0041：同批次的 BALANCE dataset 不得冒用 DOCUMENT 覆蓋度" \
  "${T1} INSERT INTO cash_flow_support_dataset (source_dataset_id, tenant_id, engagement_id,
        period_revision_id, reporting_unit_id, import_batch_id, content_hash, data_coverage_id)
   VALUES ('c0470000-0000-0000-0000-000000000003','${TEN}','${ENG}','${PR}','${UNIT}','${CFB3}','h',
           'c0480000-0000-0000-0000-000000000012')" "CFS_COVERAGE_GRANULARITY_MISMATCH"
expect_err "0041：封套宣告的批次與底層資料集的批次不同 → 拒絕" \
  "${T1} INSERT INTO cash_flow_support_dataset (source_dataset_id, tenant_id, engagement_id,
        period_revision_id, reporting_unit_id, import_batch_id, content_hash, data_coverage_id)
   VALUES ('${CFSD2}','${TEN}','${ENG}','${PR}','${UNIT}','${CFB}','h',
           'c0480000-0000-0000-0000-000000000001')" "CFS_DATASET_BATCH_MISMATCH"
expect_err "0041：封套建立後不可 UPDATE" \
  "${T1} UPDATE cash_flow_support_dataset SET content_hash='x' WHERE source_dataset_id='${CFSD}'" \
  "CFS_DATASET_IMMUTABLE"
n=$(PSQL_C <<<"${T1} SELECT actual_granularity FROM cash_flow_source_fact WHERE content_hash='f1'")
[ "${n}" = "BALANCE" ] && ok "0041：fact 的粒度取自封套所指的覆蓋度（不是整批最細的）" \
  || ng "0041：fact 粒度為 ${n}"



# ══════════════════════════════════════════════════════════════════
# 0042：角色工作流函式與父鏈（SLICE-M3-04 第二段 2a）
#
# 紀律：每條負面測試**先斷言前置狀態成立**（角色確實持有、物件確實存在、
# 父鏈確實正確），否則會被更前面的守衛以別的理由擋下而假綠。
# ══════════════════════════════════════════════════════════════════
fx_tb_lines

# ── 角色前置：作用域正確與作用域錯誤各一組 ──
CFR4=af420000-0000-0000-0000-000000000001      # 案件層 R4
CFR3=af420000-0000-0000-0000-000000000002      # 案件層 R3
CFT4=af420000-0000-0000-0000-000000000004      # **租戶層** R4（作用域錯誤的反例）
CFDUAL=af420000-0000-0000-0000-000000000005    # 案件層 R2＋R3＋R4（SoD 反例）
_has app_user "user_id = '${CFR4}'" || PSQL_C >/dev/null 2>&1 <<SQL
${T1}
INSERT INTO app_user (user_id, tenant_id, email, display_name) VALUES
  ('${CFR4}','${TEN}','cf-partner@t1.jp','現金流合夥人'),
  ('${CFR3}','${TEN}','cf-senior@t1.jp','現金流覆核者'),
  ('${CFT4}','${TEN}','cf-tenant-r4@t1.jp','租戶層 R4'),
  ('${CFDUAL}','${TEN}','cf-dual@t1.jp','兼任者');
INSERT INTO role_assignment (tenant_id, user_id, role, engagement_id) VALUES
  ('${TEN}','${CFR4}','R4','${ENG}'),
  ('${TEN}','${CFR3}','R3','${ENG}'),
  ('${TEN}','${CFT4}','R4',NULL),
  ('${TEN}','${CFDUAL}','R2','${ENG}'),('${TEN}','${CFDUAL}','R3','${ENG}'),
  ('${TEN}','${CFDUAL}','R4','${ENG}');
SQL
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM role_assignment
     WHERE user_id='${CFR4}' AND role='R4' AND engagement_id='${ENG}' AND revoked_at IS NULL")
[ "${n}" = "1" ] && ok "0042 前置：CFR4 持有**案件層** R4" || ng "0042 前置：CFR4 角色數 ${n}"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM role_assignment
     WHERE user_id='${CFT4}' AND role='R4' AND engagement_id IS NULL AND revoked_at IS NULL")
m=$(PSQL_C <<<"${T1} SELECT count(*) FROM role_assignment
     WHERE user_id='${CFT4}' AND engagement_id='${ENG}'")
[ "${n}" = "1" ] && [ "${m}" = "0" ] \
  && ok "0042 前置：CFT4 持有租戶層 R4、且本案件無任何指派（角色種類正確、作用域錯誤）" \
  || ng "0042 前置：CFT4 租戶層 ${n}／案件層 ${m}"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM role_assignment
     WHERE user_id='${JIA}' AND role='R2' AND engagement_id='${ENG}' AND revoked_at IS NULL")
[ "${n}" = "1" ] && ok "0042 前置：甲持有案件層 R2（非 R4 的反例是角色種類不符，不是沒有指派）" \
  || ng "0042 前置：甲 R2 數 ${n}"

# ══ 1　分類集合：R4、集合為批准單位、批准時的兩項最低要求 ══════════
SERA=c0420000-0000-0000-0000-000000000301
SETA=$(PSQL_C <<<"${T1} SELECT fn_cf_class_set_create('${TEN}','${ENG}','CF 分類集合 A','${SERA}',1,NULL,'${CFR4}')" 2>/dev/null)
[ -n "${SETA}" ] && ok "0042：R4 可經函式建立分類集合" || ng "0042：分類集合建立失敗"
expect_err "0042：非 R4（甲，案件層 R2）不得建立分類集合" \
  "${T1} SELECT fn_cf_class_set_create('${TEN}','${ENG}','x','c0420000-0000-0000-0000-000000000399',1,NULL,'${JIA}')" \
  "ACTOR_ROLE_NOT_HELD"
expect_err "0042：租戶層 R4 不得建立分類集合（§26.3 作用域嚴格相等）" \
  "${T1} SELECT fn_cf_class_set_create('${TEN}','${ENG}','x','c0420000-0000-0000-0000-000000000398',1,NULL,'${CFT4}')" \
  "ACTOR_ROLE_NOT_HELD"
expect_err "0042：跨租戶脈絡不得建立分類集合" \
  "${T2} SELECT fn_cf_class_set_create('${TEN}','${ENG}','x','c0420000-0000-0000-0000-000000000397',1,NULL,'${CFR4}')" \
  "CROSS_TENANT_DENIED"

expect_err "0042：空集合不得批准（沒有 FX_EFFECT_ON_CASH 控制項）" \
  "${T1} SELECT fn_cf_class_set_approve('${SETA}','${CFR4}')" "CFS_CLASS_SET_FX_EFFECT_REQUIRED"
CLSA=$(PSQL_C <<<"${T1} SELECT fn_cf_class_add('${SETA}','OP-01','銷售收現','ACTIVITY','OPERATING','INFLOW',true,'${CFR4}')" 2>/dev/null)
[ -n "${CLSA}" ] && ok "0042：R4 可加入 ACTIVITY 分類" || ng "0042：分類建立失敗"
expect_err "0042：只有活動分類仍不得批准（K2 沒有檢查項）" \
  "${T1} SELECT fn_cf_class_set_approve('${SETA}','${CFR4}')" "CFS_CLASS_SET_FX_EFFECT_REQUIRED"
CLSF=$(PSQL_C <<<"${T1} SELECT fn_cf_class_add('${SETA}','FXE','匯率變動對現金的影響','FX_EFFECT_ON_CASH',NULL,'EITHER',true,'${CFR4}')" 2>/dev/null)
[ -n "${CLSF}" ] && ok "0042：R4 可加入 FX_EFFECT_ON_CASH 控制項" || ng "0042：控制項建立失敗"
expect_err "0042：沒有現金科目範圍的分類集合不得批准（K1／K2 沒有計算對象）" \
  "${T1} SELECT fn_cf_class_set_approve('${SETA}','${CFR4}')" "CFS_CLASS_SET_NO_CASH_ACCOUNT"
expect_err "0042：現金科目必須屬本案件的科目表" \
  "${T1} SELECT fn_cf_cash_account_add('${SETA}','${ACC99}','CASH','${CFR4}')" "§24.1A"
expect_ok  "0042：R4 加入本案件科目為現金範圍" \
  "${T1} SELECT fn_cf_cash_account_add('${SETA}','${ACC1}','CASH','${CFR4}')"
CLSF2=$(PSQL_C <<<"${T1} SELECT fn_cf_class_add('${SETA}','FXE2','第二個控制項','FX_EFFECT_ON_CASH',NULL,'EITHER',false,'${CFR4}')" 2>/dev/null)
[ -n "${CLSF2}" ] && ok "0042 前置：集合內已有兩個 FX_EFFECT_ON_CASH" || ng "0042 前置：第二個控制項建立失敗"
expect_err "0042：超過一個 FX_EFFECT_ON_CASH → 批准被拒" \
  "${T1} SELECT fn_cf_class_set_approve('${SETA}','${CFR4}')" "CFS_CLASS_SET_FX_EFFECT_REQUIRED"
expect_ok  "0042：未批准的集合可移除多餘控制項" \
  "${T1} DELETE FROM cash_flow_class WHERE cash_flow_class_id='${CLSF2}'"
expect_ok  "0042：恰一個控制項＋至少一筆現金科目 → R4 批准通過" \
  "${T1} SELECT fn_cf_class_set_approve('${SETA}','${CFR4}')"
expect_err "0042：已批准集合不得重複批准" \
  "${T1} SELECT fn_cf_class_set_approve('${SETA}','${CFR4}')" "CFS_ALREADY_APPROVED"
expect_err "0042：已批准集合不得單獨新增分類（集合是批准單位）" \
  "${T1} SELECT fn_cf_class_add('${SETA}','OP-02','事後追加','ACTIVITY','OPERATING','INFLOW',true,'${CFR4}')" \
  "CFS_CLASS_SET_IMMUTABLE"
expect_err "0042：已批准集合不得單獨新增現金科目" \
  "${T1} SELECT fn_cf_cash_account_add('${SETA}','${ACC2}','CASH_EQUIVALENT','${CFR4}')" \
  "CFS_CLASS_SET_IMMUTABLE"
expect_err "0042：已批准集合不可變更（改口徑須發新集合版本）" \
  "${T1} UPDATE cash_flow_class_set_version SET label='改名' WHERE class_set_version_id='${SETA}'" \
  "CFS_CLASS_SET_IMMUTABLE"

# ── 版本鏈：同 series、緊接前一版、不得分叉 ──
expect_err "0042：新版本不得跳號（v1 → v3）" \
  "${T1} SELECT fn_cf_class_set_create('${TEN}','${ENG}','A v3','${SERA}',3,'${SETA}','${CFR4}')" \
  "CFS_CHAIN_VERSION_GAP"
expect_err "0042：取代的對象必須屬同一版本序列" \
  "${T1} SELECT fn_cf_class_set_create('${TEN}','${ENG}','別的序列','c0420000-0000-0000-0000-000000000302',2,'${SETA}','${CFR4}')" \
  "CFS_CHAIN_SERIES_MISMATCH"
SETA2=$(PSQL_C <<<"${T1} SELECT fn_cf_class_set_create('${TEN}','${ENG}','A v2','${SERA}',2,'${SETA}','${CFR4}')" 2>/dev/null)
[ -n "${SETA2}" ] && ok "0042：v2 緊接 v1 且同 series → 接受" || ng "0042：v2 建立失敗"
expect_err "0042：同一舊版不得分叉出兩個現行版本" \
  "${T1} SELECT fn_cf_class_set_create('${TEN}','${ENG}','A v2 分叉','${SERA}',2,'${SETA}','${CFR4}')" \
  "duplicate key"

# ══ 2　政策版本：R4、引用已批准集合、批准後不可變 ══════════════════
SERP=c0420000-0000-0000-0000-000000000311
expect_err "0042：非 R4 不得建立政策版本（方法與粒度是母公司的決定）" \
  "${T1} SELECT fn_cf_policy_create('${TEN}','${ENG}','${UNIT}','DIRECT','BALANCE','${SETA}','確認函 v1','${SERP}',1,NULL,'${JIA}')" \
  "ACTOR_ROLE_NOT_HELD"
POLA=$(PSQL_C <<<"${T1} SELECT fn_cf_policy_create('${TEN}','${ENG}','${UNIT}','DIRECT','BALANCE','${SETA}','母公司確認函 v1','${SERP}',1,NULL,'${CFR4}')" 2>/dev/null)
[ -n "${POLA}" ] && ok "0042：R4 可經函式建立政策版本" || ng "0042：政策建立失敗"
expect_err "0042：政策的分類集合必須屬本案件（父鏈最後防線）" \
  "${T1} INSERT INTO cash_flow_policy_version (tenant_id, engagement_id, reporting_unit_id,
        method, required_granularity, class_set_version_id, evidence_version, series_id,
        version_no, created_by)
   VALUES ('${TEN}','${ENG99}','${UNIT}','DIRECT','BALANCE','${SETA}','x',
           'c0420000-0000-0000-0000-000000000391',1,'${CFR4}')" "§24.1A"
# 未批准集合的政策：批准時必須被擋（SETA2 是尚未批准的 v2）
POLB=$(PSQL_C <<<"${T1} SELECT fn_cf_policy_create('${TEN}','${ENG}','${UNIT}','INDIRECT','BALANCE','${SETA2}','確認函 v2','c0420000-0000-0000-0000-000000000312',1,NULL,'${CFR4}')" 2>/dev/null)
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM cash_flow_class_set_version
     WHERE class_set_version_id='${SETA2}' AND approved_at IS NULL")
[ -n "${POLB}" ] && [ "${n}" = "1" ] \
  && ok "0042 前置：政策 B 已建立且其分類集合尚未批准" || ng "0042 前置：政策 B／集合狀態不符"
expect_err "0042：政策引用的分類集合未批准 → 不得批准政策" \
  "${T1} SELECT fn_cf_policy_approve('${POLB}','${CFR4}')" "CFS_CLASS_SET_NOT_APPROVED"
expect_err "0042：非 R4 不得批准政策版本" \
  "${T1} SELECT fn_cf_policy_approve('${POLA}','${CFR3}')" "ACTOR_ROLE_NOT_HELD"
expect_ok  "0042：R4 批准政策版本" "${T1} SELECT fn_cf_policy_approve('${POLA}','${CFR4}')"
expect_err "0042：已批准政策不得重複批准" \
  "${T1} SELECT fn_cf_policy_approve('${POLA}','${CFR4}')" "CFS_ALREADY_APPROVED"
expect_err "0042：已批准政策不可變更（改方法或粒度須發新版本）" \
  "${T1} UPDATE cash_flow_policy_version SET method='INDIRECT' WHERE policy_version_id='${POLA}'" \
  "CFS_POLICY_IMMUTABLE"

# ══ 3　映射：R2 建立 → R3 覆核 → R4 批准 ═══════════════════════════
SERM=c0420000-0000-0000-0000-000000000321
expect_err "0042：非 R2 不得建立映射版本" \
  "${T1} SELECT fn_cf_mapping_create('${TEN}','${ENG}','${POLA}','${SERM}',1,NULL,'${CFR4}')" \
  "ACTOR_ROLE_NOT_HELD"
MAPA=$(PSQL_C <<<"${T1} SELECT fn_cf_mapping_create('${TEN}','${ENG}','${POLA}','${SERM}',1,NULL,'${JIA}')" 2>/dev/null)
[ -n "${MAPA}" ] && ok "0042：R2 可經函式建立映射版本" || ng "0042：映射版本建立失敗"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM cash_flow_class
     WHERE cash_flow_class_id='${CFCLS}' AND class_set_version_id='${CFSET}'")
[ "${n}" = "1" ] && ok "0042 前置：CFCLS 屬另一個分類集合（不是政策 A 綁定的那一份）" \
  || ng "0042 前置：CFCLS 歸屬不符"
expect_err "0042：映射規則的分類必須屬政策所綁定的集合" \
  "${T1} SELECT fn_cf_mapping_rule_add('${MAPA}','ACCOUNT','${ACC1}',NULL,NULL,'${CFCLS}',NULL,NULL,'e','${JIA}')" \
  "CFS_MAPPING_CLASS_NOT_IN_SET"
expect_ok  "0042：R2 加入 ACCOUNT 規則（2026-01-01～2026-06-30）" \
  "${T1} SELECT fn_cf_mapping_rule_add('${MAPA}','ACCOUNT','${ACC1}',NULL,NULL,'${CLSA}','2026-01-01','2026-06-30','e1','${JIA}')"
expect_err "0042：同一來源同一生效期間重疊 → CFS_MAPPING_AMBIGUOUS" \
  "${T1} SELECT fn_cf_mapping_rule_add('${MAPA}','ACCOUNT','${ACC1}',NULL,NULL,'${CLSA}','2026-06-01','2026-12-31','e2','${JIA}')" \
  "CFS_MAPPING_AMBIGUOUS"
expect_ok  "0042：相鄰不重疊的生效期間 → 接受" \
  "${T1} SELECT fn_cf_mapping_rule_add('${MAPA}','ACCOUNT','${ACC1}',NULL,NULL,'${CLSA}','2026-07-01','2026-12-31','e3','${JIA}')"
expect_err "0042：無界規則與既有規則重疊 → CFS_MAPPING_AMBIGUOUS" \
  "${T1} SELECT fn_cf_mapping_rule_add('${MAPA}','ACCOUNT','${ACC1}',NULL,NULL,'${CLSA}',NULL,NULL,'e4','${JIA}')" \
  "CFS_MAPPING_AMBIGUOUS"
SLL2=$(PSQL_C <<<"${T1} SELECT source_ledger_line_id FROM source_ledger_line ORDER BY source_ledger_line_id LIMIT 1")
[ -n "${SLL2}" ] && ok "0042 前置：本租戶存在來源列（JOURNAL_LINE 規則的引用對象）" \
  || ng "0042 前置：找不到來源列"
expect_ok  "0042 靜態粒度：政策只要 BALANCE 而規則到 JOURNAL_LINE → 接受（更細不是錯）" \
  "${T1} SELECT fn_cf_mapping_rule_add('${MAPA}','JOURNAL_LINE',NULL,${SLL2},NULL,'${CLSA}',NULL,NULL,'e5','${JIA}')"

# 政策要求 JOURNAL 時，只有 ACCOUNT 層映射不算完整（靜態判定，唯一實作）
SERPJ=c0420000-0000-0000-0000-000000000313
POLJ=$(PSQL_C <<<"${T1} SELECT fn_cf_policy_create('${TEN}','${ENG}','${UNIT}','DIRECT','JOURNAL','${SETA}','確認函 J','${SERPJ}',1,NULL,'${CFR4}')" 2>/dev/null)
MAPJ=$(PSQL_C <<<"${T1} SELECT fn_cf_mapping_create('${TEN}','${ENG}','${POLJ}','c0420000-0000-0000-0000-000000000322',1,NULL,'${JIA}')" 2>/dev/null)
n=$(PSQL_C <<<"${T1} SELECT required_granularity FROM cash_flow_policy_version WHERE policy_version_id='${POLJ}'")
[ "${n}" = "JOURNAL" ] && ok "0042 前置：政策 J 要求 JOURNAL 粒度" || ng "0042 前置：政策 J 粒度為 ${n}"
expect_err "0042 靜態粒度：政策要 JOURNAL 而規則只到 ACCOUNT → 拒絕" \
  "${T1} SELECT fn_cf_mapping_rule_add('${MAPJ}','ACCOUNT','${ACC1}',NULL,NULL,'${CLSA}',NULL,NULL,'ej','${JIA}')" \
  "CFS_MAPPING_GRANULARITY_INSUFFICIENT"

expect_err "0042：非 R3 不得覆核映射版本" \
  "${T1} SELECT fn_cf_mapping_review('${MAPA}','${JIA}')" "ACTOR_ROLE_NOT_HELD"
expect_err "0042：未經 R3 覆核不得批准映射版本" \
  "${T1} SELECT fn_cf_mapping_approve('${MAPA}','${CFR4}')" "CFS_MAPPING_NOT_REVIEWED"
expect_err "0042：沒有任何規則的映射版本不得覆核" \
  "${T1} SELECT fn_cf_mapping_review('${MAPJ}','${CFR3}')" "CFS_MAPPING_EMPTY"
expect_ok  "0042：R3 覆核映射版本" "${T1} SELECT fn_cf_mapping_review('${MAPA}','${CFR3}')"
expect_err "0042：已覆核不得重複覆核" \
  "${T1} SELECT fn_cf_mapping_review('${MAPA}','${CFR3}')" "CFS_MAPPING_ALREADY_REVIEWED"
expect_err "0042：覆核後不得再增修規則（否則覆核的不是被批准的那一份）" \
  "${T1} SELECT fn_cf_mapping_rule_add('${MAPA}','ACCOUNT','${ACC2}',NULL,NULL,'${CLSA}',NULL,NULL,'e6','${JIA}')" \
  "CFS_MAPPING_LOCKED"

# SoD：建立者不得批准自己建立的版本（自然人判定）
MAPD=$(PSQL_C <<<"${T1} SELECT fn_cf_mapping_create('${TEN}','${ENG}','${POLA}','c0420000-0000-0000-0000-000000000323',1,NULL,'${CFDUAL}')" 2>/dev/null)
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
SELECT fn_cf_mapping_rule_add('${MAPD}','ACCOUNT','${ACC2}',NULL,NULL,'${CLSA}',NULL,NULL,'d1','${CFDUAL}');
SELECT fn_cf_mapping_review('${MAPD}','${CFR3}');
SQL
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM role_assignment WHERE user_id='${CFDUAL}'
     AND role='R4' AND engagement_id='${ENG}' AND revoked_at IS NULL")
m=$(PSQL_C <<<"${T1} SELECT count(*) FROM cash_flow_mapping_version
     WHERE mapping_version_id='${MAPD}' AND reviewed_at IS NOT NULL AND created_by='${CFDUAL}'")
[ "${n}" = "1" ] && [ "${m}" = "1" ] \
  && ok "0042 前置：兼任者持有案件層 R4，且該版本由他建立、已完成 R3 覆核" \
  || ng "0042 前置：兼任者 R4=${n}／版本狀態=${m}"
expect_err "0042 SoD：映射建立者不得批准自己建立的版本（角色齊備，只差不是同一人）" \
  "${T1} SELECT fn_cf_mapping_approve('${MAPD}','${CFDUAL}')" "SOD"
expect_ok  "0042：R4（非建立者）批准映射版本" \
  "${T1} SELECT fn_cf_mapping_approve('${MAPA}','${CFR4}')"
expect_err "0042：已批准的映射版本不得重複批准" \
  "${T1} SELECT fn_cf_mapping_approve('${MAPA}','${CFR4}')" "CFS_ALREADY_APPROVED"
expect_err "0042：已批准的映射版本不可變更" \
  "${T1} UPDATE cash_flow_mapping_version SET content_hash='x' WHERE mapping_version_id='${MAPA}'" \
  "CFS_MAPPING_IMMUTABLE"

# ══ 4　粒度例外：R2 申請、R4 批准、逐分類 ══════════════════════════
EXCA=$(PSQL_C <<<"${T1} SELECT fn_cf_coverage_exception_create('${PR}','${UNIT}','${POLA}','${CLSA}','BALANCE','拿不到分錄層資料','底稿 E1','${JIA}')" 2>/dev/null)
[ -n "${EXCA}" ] && ok "0042：R2 可申請逐分類的粒度例外" || ng "0042：例外申請失敗"
expect_err "0042：例外的分類必須屬政策所綁定的集合" \
  "${T1} SELECT fn_cf_coverage_exception_create('${PR}','${UNIT}','${POLA}','${CFCLS}','BALANCE','r','e','${JIA}')" \
  "CFS_EXCEPTION_CLASS_NOT_IN_SET"
expect_err "0042：未批准的粒度例外不得成為覆蓋結論" \
  "${T1} SELECT fn_cf_coverage_exception_record('${EXCA}','${JIA}')" "CFS_EXCEPTION_NOT_APPROVED"
expect_err "0042：非 R4 不得批准粒度例外" \
  "${T1} SELECT fn_cf_coverage_exception_approve('${EXCA}','${JIA}')" "ACTOR_ROLE_NOT_HELD"
expect_ok  "0042：R4 批准粒度例外" "${T1} SELECT fn_cf_coverage_exception_approve('${EXCA}','${CFR4}')"
expect_err "0042：已批准的粒度例外不可變更" \
  "${T1} UPDATE cash_flow_coverage_exception SET reason='改' WHERE exception_id='${EXCA}'" \
  "CFS_EXCEPTION_IMMUTABLE"
expect_ok  "0042：已批准的例外可落成該期該分類的覆蓋結論" \
  "${T1} SELECT fn_cf_coverage_exception_record('${EXCA}','${JIA}')"

# ══ 5　覆蓋結論的父鏈 ══════════════════════════════════════════════
expect_err "0042：DATA_PRESENT 不得人工宣告（只能由系統依已映射的來源事實衍生）" \
  "${T1} INSERT INTO cash_flow_class_period_coverage (tenant_id, period_revision_id,
        reporting_unit_id, policy_version_id, cash_flow_class_id, status)
   VALUES ('${TEN}','${PR}','${UNIT}','${POLA}','${CLSF}','DATA_PRESENT')" \
  "CFS_DATA_PRESENT_NOT_IMPLEMENTED"
expect_err "0042：覆蓋結論的分類必須屬政策所綁定的集合" \
  "${T1} INSERT INTO cash_flow_class_period_coverage (tenant_id, period_revision_id,
        reporting_unit_id, policy_version_id, cash_flow_class_id, status, coverage_exception_id)
   VALUES ('${TEN}','${PR}','${UNIT}','${POLA}','${CFCLS}','COVERAGE_EXCEPTION','${EXCA}')" \
  "CFS_CLASS_NOT_IN_SET"
expect_err "0042：覆蓋結論的報告單位必須與政策一致" \
  "${T1} INSERT INTO cash_flow_class_period_coverage (tenant_id, period_revision_id,
        reporting_unit_id, policy_version_id, cash_flow_class_id, status, coverage_exception_id)
   VALUES ('${TEN}','${GRP_PR}','${GRP_UNIT}','${POLA}','${CLSF}','COVERAGE_EXCEPTION','${EXCA}')" \
  "§24.1A"
expect_err "0042：覆蓋結論引用的例外必須是同期同分類" \
  "${T1} INSERT INTO cash_flow_class_period_coverage (tenant_id, period_revision_id,
        reporting_unit_id, policy_version_id, cash_flow_class_id, status, coverage_exception_id)
   VALUES ('${TEN}','${PR}','${UNIT}','${POLA}','${CLSF}','COVERAGE_EXCEPTION','${EXCA}')" \
  "CFS_EXCEPTION_SCOPE_MISMATCH"

# ══ 6　零活動：R2 確認 → R3 覆核（Coverage 仍只有三種完成語意）══════
expect_err "0042：非 R2 不得確認零活動" \
  "${T1} SELECT fn_cf_zero_activity_confirm('${PR}','${UNIT}','${POLA}','${CLSF}','同幣別本期為零','底稿 Z1','${CFR4}')" \
  "ACTOR_ROLE_NOT_HELD"
expect_err "0042：未批准的政策版本不得作為零活動確認的依據" \
  "${T1} SELECT fn_cf_zero_activity_confirm('${PR}','${UNIT}','${POLB}','${CLSA}','x','e','${JIA}')" \
  "CFS_POLICY_NOT_APPROVED"
ATT=$(PSQL_C <<<"${T1} SELECT fn_cf_zero_activity_confirm('${PR}','${UNIT}','${POLA}','${CLSF}','同幣別本期為零','底稿 Z1','${JIA}')" 2>/dev/null)
n=$(PSQL_C <<<"${T1} SELECT status FROM cash_flow_zero_activity_attestation WHERE attestation_id='${ATT}'")
[ "${n}" = "PENDING_REVIEW" ] && ok "0042：R2 確認產生 PENDING_REVIEW 的零活動見證" \
  || ng "0042：見證狀態為 ${n}"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM cash_flow_class_period_coverage
     WHERE period_revision_id='${PR}' AND cash_flow_class_id='${CLSF}' AND policy_version_id='${POLA}'")
[ "${n}" = "0" ] && ok "0042：只有 R2 確認時**尚未**產生覆蓋結論（雙人流程未完成）" \
  || ng "0042：覆蓋結論提前出現 ${n} 筆"
expect_err "0042：非 R3 不得覆核零活動見證" \
  "${T1} SELECT fn_cf_zero_activity_review('${ATT}','${JIA}')" "ACTOR_ROLE_NOT_HELD"
expect_ok  "0042：R3 覆核零活動見證" "${T1} SELECT fn_cf_zero_activity_review('${ATT}','${CFR3}')"
n=$(PSQL_C <<<"${T1} SELECT status FROM cash_flow_class_period_coverage
     WHERE period_revision_id='${PR}' AND cash_flow_class_id='${CLSF}' AND policy_version_id='${POLA}'")
[ "${n}" = "ZERO_ACTIVITY_CONFIRMED" ] \
  && ok "0042：R3 覆核於同一交易產生 ZERO_ACTIVITY_CONFIRMED 的覆蓋結論" \
  || ng "0042：覆蓋結論狀態為 ${n}"
n=$(PSQL_C <<<"${T1} SELECT confirmed_by='${JIA}' AND reviewed_by='${CFR3}'
     FROM cash_flow_class_period_coverage WHERE period_revision_id='${PR}'
       AND cash_flow_class_id='${CLSF}' AND policy_version_id='${POLA}'")
[ "${n}" = "t" ] && ok "0042：確認人（R2）與覆核人（R3）分開保存於覆蓋結論" \
  || ng "0042：確認人／覆核人不符（${n}）"
expect_err "0042：已覆核的零活動見證不得重複覆核" \
  "${T1} SELECT fn_cf_zero_activity_review('${ATT}','${CFR3}')" "CFS_ZERO_ACTIVITY_ALREADY_REVIEWED"
expect_err "0042：已覆核的零活動見證不可變更" \
  "${T1} UPDATE cash_flow_zero_activity_attestation SET reason='改' WHERE attestation_id='${ATT}'" \
  "CFS_ZERO_ACTIVITY_IMMUTABLE"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM pg_constraint
     WHERE conrelid='cash_flow_class_period_coverage'::regclass AND contype='c'
       AND pg_get_constraintdef(oid) LIKE '%ZERO_ACTIVITY_PENDING%'")
[ "${n}" = "0" ] && ok "0042：Coverage 仍只有三種完成語意（未新增中間狀態）" \
  || ng "0042：Coverage 出現中間狀態 ${n} 條"

# ══ 7　首期期初證據集合 ════════════════════════════════════════════
SERO=c0420000-0000-0000-0000-000000000331
expect_err "0042：非 R4 不得建立期初證據集合" \
  "${T1} SELECT fn_cf_opening_set_create('${TEN}','${ENG}','${UNIT}','${PR}','${SERO}',1,NULL,'期初證據','${JIA}')" \
  "ACTOR_ROLE_NOT_HELD"
OPS=$(PSQL_C <<<"${T1} SELECT fn_cf_opening_set_create('${TEN}','${ENG}','${UNIT}','${PR}','${SERO}',1,NULL,'母公司期初證據 v1','${CFR4}')" 2>/dev/null)
[ -n "${OPS}" ] && ok "0042：R4 可建立期初證據集合" || ng "0042：期初集合建立失敗"
expect_err "0042：空的期初證據集合不得批准（證明不了沒有漏掉現金科目）" \
  "${T1} SELECT fn_cf_opening_set_approve('${OPS}','${CFR4}')" "CFS_OPENING_SET_EMPTY"
expect_err "0042：期初明細的科目必須屬本案件" \
  "${T1} SELECT fn_cf_opening_line_add('${OPS}','${ACC99}',100,'JPY',NULL,NULL,'${CFR4}')" "§24.1A"
expect_ok  "0042：R4 加入期初明細" \
  "${T1} SELECT fn_cf_opening_line_add('${OPS}','${ACC1}',5000000,'JPY',NULL,NULL,'${CFR4}')"
expect_ok  "0042：R4 批准期初證據集合" "${T1} SELECT fn_cf_opening_set_approve('${OPS}','${CFR4}')"
expect_err "0042：已批准的期初證據集合不得再加明細" \
  "${T1} SELECT fn_cf_opening_line_add('${OPS}','${ACC2}',1,'JPY',NULL,NULL,'${CFR4}')" \
  "CFS_OPENING_SET_IMMUTABLE"

# ══ 8　來源選定：FX 對齊、顯式前期、首期證據 ═══════════════════════
# 本期的 NO_FX 來源 run（已完成）、一個仍在執行的 run、一個未經選定的折算 run
RUN_OK=c0450000-0000-0000-0000-000000000101
RUN_RUNNING=c0450000-0000-0000-0000-000000000102
RUN_FX=c0450000-0000-0000-0000-000000000103
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by) VALUES
  ('c0440000-0000-0000-0000-000000000101','${TEN}','${ENG}','${PR}','NO_FX','sqlcanon-2','k1','${JIA}'),
  ('c0440000-0000-0000-0000-000000000102','${TEN}','${ENG}','${PR}','NO_FX','sqlcanon-2','k2','${JIA}'),
  ('c0440000-0000-0000-0000-000000000103','${TEN}','${ENG}','${PR}','FX_TRANSLATION','sqlcanon-2','k3','${JIA}');
INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, status, request_key, request_content_hash,
        engine_version, created_by) VALUES
  ('${RUN_OK}','${TEN}','${ENG}','${PR}','${B1}','c0440000-0000-0000-0000-000000000101','PREVIEW',
   'RUNNING',gen_random_uuid(),'h1','1.0.0','${JIA}'),
  ('${RUN_RUNNING}','${TEN}','${ENG}','${PR}','${B1}','c0440000-0000-0000-0000-000000000102','PREVIEW',
   'RUNNING',gen_random_uuid(),'h2','1.0.0','${JIA}'),
  ('${RUN_FX}','${TEN}','${ENG}','${PR}','${B1}','c0440000-0000-0000-0000-000000000103','PREVIEW',
   'RUNNING',gen_random_uuid(),'h3','1.0.0','${JIA}');
-- 本期來源 run 的實際輸出。0044 凍結的是**行資料**，run 是裸的話那條斷言只是空證；
-- 必須在轉 COMPLETED 之前寫入（0013 的 trg_bsl_run_state 禁止對終態 run 追加結果）。
INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit) VALUES
  ('${TEN}','${RUN_OK}','SOURCE_TB','${ACC1}','1002','银行存款',1000.00,0),
  ('${TEN}','${RUN_OK}','SOURCE_TB','${ACC2}','6602','管理费用',0,1000.00);
-- 結果雜湊用 fn_calc_result_hash 實算：0045 起凍結會在當下復驗，
-- 填假雜湊等於讓那道控制永遠測不到。
UPDATE calculation_run SET status='COMPLETED',
       result_content_hash = fn_calc_result_hash(calculation_run_id)
 WHERE calculation_run_id = '${RUN_OK}';
UPDATE calculation_run SET status='COMPLETED', result_content_hash='r1'
 WHERE calculation_run_id = '${RUN_FX}';
SQL
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM calculation_run
     WHERE calculation_run_id IN ('${RUN_OK}','${RUN_FX}') AND status='COMPLETED'")
[ "${n}" = "2" ] && ok "0042 前置：本期已有兩個 COMPLETED run（NO_FX 與 FX_TRANSLATION）" \
  || ng "0042 前置：COMPLETED run 數為 ${n}"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM reporting_period rp JOIN period_revision pr
       ON pr.reporting_period_id = rp.reporting_period_id
     WHERE pr.period_revision_id='${PR}' AND rp.previous_reporting_period_id IS NULL")
[ "${n}" = "1" ] && ok "0042 前置：本期是首期（沒有顯式前期）" || ng "0042 前置：首期判定為 ${n}"

expect_err "0042：非 R4 不得選定本期的權威來源" \
  "${T1} SELECT fn_cf_select_source('${PR}','${RUN_OK}','FIRST_PERIOD_EVIDENCE',NULL,'${OPS}','${JIA}')" \
  "ACTOR_ROLE_NOT_HELD"
expect_err "0042：首期不得使用 PRIOR_SELECTED_RUN" \
  "${T1} SELECT fn_cf_select_source('${PR}','${RUN_OK}','PRIOR_SELECTED_RUN','${RUN_OK}',NULL,'${CFR4}')" \
  "CFS_OPENING_SOURCE_INVALID"
expect_err "0042：尚未完成的 run 不得作為本期來源" \
  "${T1} SELECT fn_cf_select_source('${PR}','${RUN_RUNNING}','FIRST_PERIOD_EVIDENCE',NULL,'${OPS}','${CFR4}')" \
  "CFS_SOURCE_RUN_NOT_COMPLETED"
# 本期的折算結果選定狀態依執行模式而異（聚合時 fx 套件已選定，單跑時為空）。
# 兩種狀態都必須擋下同一件事——先斷言實際狀態，再驗對應的拒絕理由，
# 否則就是「以錯誤理由通過」。
FXSEL=$(PSQL_C <<<"${T1} SELECT COALESCE(fn_current_fx_run_selection('${PR}')::text,'')")
if [ -z "${FXSEL}" ]; then
  ok "0042 前置：本期尚未選定折算結果（驗未選定分支）"; FXEXP="CFS_FX_RUN_NOT_SELECTED"
else
  n=$(PSQL_C <<<"${T1} SELECT selected_run_id<>'${RUN_FX}' FROM period_fx_run_selection
       WHERE run_selection_id='${FXSEL}'")
  [ "${n}" = "t" ] && ok "0042 前置：本期已選定的折算結果不是本測試的 run（驗不一致分支）" \
    || ng "0042 前置：折算結果選定狀態不符（${n}）"
  FXEXP="CFS_FX_SELECTION_MISMATCH"
fi
expect_err "0042：折算 run 必須與現行 PeriodFxRunSelection 一致（兩個選定不得各說各話）" \
  "${T1} SELECT fn_cf_select_source('${PR}','${RUN_FX}','FIRST_PERIOD_EVIDENCE',NULL,'${OPS}','${CFR4}')" \
  "${FXEXP}"
OPS2=$(PSQL_C <<<"${T1} SELECT fn_cf_opening_set_create('${TEN}','${ENG}','${UNIT}','${PR}','c0420000-0000-0000-0000-000000000332',1,NULL,'未批准的期初證據','${CFR4}')" 2>/dev/null)
expect_err "0042：未批准的期初證據集合不得使用" \
  "${T1} SELECT fn_cf_select_source('${PR}','${RUN_OK}','FIRST_PERIOD_EVIDENCE',NULL,'${OPS2}','${CFR4}')" \
  "CFS_OPENING_EVIDENCE_NOT_APPROVED"
SEL1=$(PSQL_C <<<"${T1} SELECT fn_cf_select_source('${PR}','${RUN_OK}','FIRST_PERIOD_EVIDENCE',NULL,'${OPS}','${CFR4}')" 2>/dev/null)
[ -n "${SEL1}" ] && ok "0042：R4 以首期期初證據選定本期權威來源" || ng "0042：來源選定失敗"
expect_err "0042：選定建立後不可 UPDATE（換選擇請發新版本）" \
  "${T1} UPDATE period_cash_flow_source_selection SET current_run_id='${RUN_FX}' WHERE cf_selection_id='${SEL1}'" \
  "CFS_SELECTION_IMMUTABLE"
SEL2=$(PSQL_C <<<"${T1} SELECT fn_cf_select_source('${PR}','${RUN_OK}','FIRST_PERIOD_EVIDENCE',NULL,'${OPS}','${CFR4}')" 2>/dev/null)
n=$(PSQL_C <<<"${T1} SELECT version_no FROM period_cash_flow_source_selection WHERE cf_selection_id='${SEL2}'")
m=$(PSQL_C <<<"${T1} SELECT supersedes_selection_id='${SEL1}' FROM period_cash_flow_source_selection WHERE cf_selection_id='${SEL2}'")
[ "${n}" = "2" ] && [ "${m}" = "t" ] && ok "0042：改選發 v2 並向後指向 v1（取代鏈，不按時間）" \
  || ng "0042：v2 版本號 ${n}／取代指向 ${m}"
n=$(PSQL_C <<<"${T1} SELECT fn_current_cf_source_selection('${PR}')='${SEL2}'")
[ "${n}" = "t" ] && ok "0042：現行選定由取代鏈判斷（未被任何後版指向者）" || ng "0042：現行選定不是 v2"

# ── 非首期：顯式前期的已選定結果 ──
RP2=dddddddd-0000-0000-0000-000000000011
PR2=99999999-0000-0000-0000-000000000011
B_P2=00000000-0000-0000-0000-0000000000c2
RUN_P2=c0450000-0000-0000-0000-000000000111
RUN_P2FX=c0450000-0000-0000-0000-000000000112
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id,
        fiscal_calendar_id, label, start_date, end_date, previous_reporting_period_id)
VALUES ('${RP2}','${TEN}','${ENG}','${UNIT}','${CAL}','2026-04','2026-04-01','2026-04-30',
        'dddddddd-0000-0000-0000-000000000001');
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id)
VALUES ('${PR2}','${TEN}','${RP2}');
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by)
VALUES ('${B_P2}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR2}','${JIA}','${JIA}');
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by) VALUES
  ('c0440000-0000-0000-0000-000000000111','${TEN}','${ENG}','${PR2}','NO_FX','sqlcanon-2','k4','${JIA}'),
  ('c0440000-0000-0000-0000-000000000112','${TEN}','${ENG}','${PR2}','FX_TRANSLATION','sqlcanon-2','k5','${JIA}');
INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, status, request_key, request_content_hash,
        engine_version, created_by) VALUES
  ('${RUN_P2}','${TEN}','${ENG}','${PR2}','${B_P2}','c0440000-0000-0000-0000-000000000111',
   'PREVIEW','RUNNING',gen_random_uuid(),'h4','1.0.0','${JIA}'),
  ('${RUN_P2FX}','${TEN}','${ENG}','${PR2}','${B_P2}','c0440000-0000-0000-0000-000000000112',
   'PREVIEW','RUNNING',gen_random_uuid(),'h5','1.0.0','${JIA}');
-- 前期來源 run 必須有實際輸出：0044 凍結的是行資料，空的 run 會讓「逐筆相等」變成空證
INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit) VALUES
  ('${TEN}','${RUN_P2}','SOURCE_TB','${ACC1}','1002','银行存款',2000.00,0),
  ('${TEN}','${RUN_P2}','SOURCE_TB','${ACC2}','6602','管理费用',0,2000.00);
UPDATE calculation_run SET status='COMPLETED',
       result_content_hash = fn_calc_result_hash(calculation_run_id)
 WHERE calculation_run_id = '${RUN_P2}';
UPDATE calculation_run SET status='COMPLETED', result_content_hash='r2'
 WHERE calculation_run_id = '${RUN_P2FX}';
SQL
n=$(PSQL_C <<<"${T1} SELECT previous_reporting_period_id='dddddddd-0000-0000-0000-000000000001'
     FROM reporting_period WHERE reporting_period_id='${RP2}'")
[ "${n}" = "t" ] && ok "0042 前置：第二期有顯式前期連結" || ng "0042 前置：前期連結為 ${n}"
expect_err "0042：非首期不得使用首期期初證據" \
  "${T1} SELECT fn_cf_select_source('${PR2}','${RUN_P2}','FIRST_PERIOD_EVIDENCE',NULL,'${OPS}','${CFR4}')" \
  "CFS_OPENING_SOURCE_INVALID"
expect_err "0042：期初 run 必須是顯式前期的**已選定**結果（不是前期最新的 COMPLETED run）" \
  "${T1} SELECT fn_cf_select_source('${PR2}','${RUN_P2}','PRIOR_SELECTED_RUN','${RUN_FX}',NULL,'${CFR4}')" \
  "CFS_PRIOR_RUN_NOT_SELECTED"
# 第二期由本檔自建，兩種模式下都不會有折算結果選定——未選定分支因此是確定的
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM period_fx_run_selection WHERE period_revision_id='${PR2}'")
[ "${n}" = "0" ] && ok "0042 前置：第二期尚未選定折算結果" || ng "0042 前置：第二期已有 ${n} 筆折算選定"
expect_err "0042：折算 run 未經 PeriodFxRunSelection 選定 → 不得逕行作為現金流來源" \
  "${T1} SELECT fn_cf_select_source('${PR2}','${RUN_P2FX}','PRIOR_SELECTED_RUN','${RUN_OK}',NULL,'${CFR4}')" \
  "CFS_FX_RUN_NOT_SELECTED"
expect_ok  "0042：期初 run 等於前期已選定結果 → 接受" \
  "${T1} SELECT fn_cf_select_source('${PR2}','${RUN_P2}','PRIOR_SELECTED_RUN','${RUN_OK}',NULL,'${CFR4}')"

# ══ 9　權限模板：函式是唯一寫入入口 ════════════════════════════════
n=$(PSQL_C <<<"SELECT count(*) FROM information_schema.role_table_grants
     WHERE grantee='app_runtime' AND privilege_type IN ('INSERT','UPDATE','DELETE')
       AND table_name LIKE 'cash_flow%'")
[ "${n}" = "0" ] && ok "0042：app_runtime 對現金流各表只有 SELECT（建立與批准只能經函式）" \
  || ng "0042：app_runtime 仍有 ${n} 項寫入授權"
n=$(PSQL_C <<<"SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
     WHERE ns.nspname='public' AND p.proname LIKE 'fn_cf%' AND p.prosecdef
       AND NOT ('search_path=pg_catalog, public' = ANY(COALESCE(p.proconfig,ARRAY['']::text[])))")
[ "${n}" = "0" ] && ok "0042：所有 SECURITY DEFINER 函式都固定 search_path" \
  || ng "0042：${n} 支函式未固定 search_path"
n=$(PSQL_C <<<"SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
     WHERE ns.nspname='public' AND p.proname LIKE 'fn_cf%' AND p.prosecdef
       AND has_function_privilege('public', p.oid, 'EXECUTE')")
[ "${n}" = "0" ] && ok "0042：SECURITY DEFINER 函式一律撤回 PUBLIC" \
  || ng "0042：${n} 支函式仍對 PUBLIC 開放"


# ══ 10　0043：CASH_FLOW_SUPPORT run 的建立入口 ═════════════════════
# 0040 讓現金流 run 的 import_batch_id 可空、來源改由橋接凍結，但沒有入口：
# app_runtime 對 calculation_run 有 INSERT（NO_FX 要用），對橋接只有 SELECT，
# 因此建得出「scope 是現金流、卻零筆來源」的 run。本節驗證入口收斂與來源凍結。
MF43N=c0440000-0000-0000-0000-000000000201    # app_runtime 直插用
MF43P=c0440000-0000-0000-0000-000000000202    # 正控制
MF43C=c0440000-0000-0000-0000-000000000203    # 併發
MF43FX=c0440000-0000-0000-0000-000000000205   # FX_TRANSLATION 既有行為
B43A=c0460000-0000-0000-0000-000000000201     # ACCEPTED
B43B=c0460000-0000-0000-0000-000000000202     # ACCEPTED
B43DR=c0460000-0000-0000-0000-000000000203    # DRAFT
B43VA=c0460000-0000-0000-0000-000000000204    # VALIDATED
B43QU=c0460000-0000-0000-0000-000000000205    # QUARANTINED
B43SU=c0460000-0000-0000-0000-000000000206    # SUPERSEDED
B43P2=c0460000-0000-0000-0000-000000000207    # ACCEPTED 但屬 PR2（跨期間）
B43E9=c0460000-0000-0000-0000-000000000208    # ACCEPTED 但屬 ENG99（同租戶跨案件）
B43T2=c0460000-0000-0000-0000-000000000209    # ACCEPTED 但屬 TEN2（跨租戶）
B43CC=c0460000-0000-0000-0000-000000000210    # 併發用（ACCEPTED → 併發轉 SUPERSEDED）
B43NX=c0460000-0000-0000-0000-000000000299    # 不存在的批次 ID
T2R2=af420000-0000-0000-0000-000000000006     # **租戶層** R2（角色種類正確、作用域錯誤）

_has import_batch "import_batch_id = '${B43A}'" || PSQL_C >/dev/null <<SQL || { ng "0043 fixture 建立失敗（fail closed）"; exit 1; }
${T1}
-- 同案件同期間的各狀態批次。INSERT 不經狀態機 trigger（它只掛 UPDATE），
-- 因此可直接落在目標狀態；每條負面測試都會先斷言狀態確實如宣告。
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by, status) VALUES
  ('${B43A}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR}','${JIA}','${JIA}','ACCEPTED'),
  ('${B43B}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR}','${JIA}','${JIA}','ACCEPTED'),
  ('${B43DR}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR}','${JIA}','${JIA}','DRAFT'),
  ('${B43VA}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR}','${JIA}','${JIA}','VALIDATED'),
  ('${B43QU}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR}','${JIA}','${JIA}','QUARANTINED'),
  ('${B43CC}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR}','${JIA}','${JIA}','ACCEPTED'),
  ('${B43P2}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR2}','${JIA}','${JIA}','ACCEPTED');
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by, status, superseded_by_id)
VALUES ('${B43SU}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR}','${JIA}',
        '${JIA}','SUPERSEDED','${B43A}');
-- 同租戶、**另一案件**的完整期間鏈（0024 要求批次的法人與期間都屬同一案件）。
-- 用 …098 系列自建，不沿用 adjustment.test.sh 的 …099 鏈：那組在聚合模式下已存在
-- （撞主鍵會讓整段 fixture 中止），且它的 reporting_unit 沒有 legal_entity_id，
-- 掛批次會先撞 0024 的歸屬守衛，變成「以錯誤理由拒絕」。
INSERT INTO legal_entity (legal_entity_id, tenant_id, engagement_id, name, authoritative_code, country_code)
VALUES ('cccccccc-0000-0000-0000-000000000098','${TEN}','${ENG99}','另一案件法人','9999999999998','JP');
INSERT INTO reporting_unit (reporting_unit_id, tenant_id, engagement_id, legal_entity_id, unit_scope, name)
VALUES ('bbbbbbbb-0000-0000-0000-000000000098','${TEN}','${ENG99}',
        'cccccccc-0000-0000-0000-000000000098','LEGAL_ENTITY','另一案件法人單位');
INSERT INTO fiscal_calendar (fiscal_calendar_id, tenant_id, engagement_id, name, year_start_month)
VALUES ('ffffffff-0000-0000-0000-000000000098','${TEN}','${ENG99}','另一案件曆（現金流）',4);
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id,
        fiscal_calendar_id, label, start_date, end_date)
VALUES ('dddddddd-0000-0000-0000-000000000098','${TEN}','${ENG99}',
        'bbbbbbbb-0000-0000-0000-000000000098','ffffffff-0000-0000-0000-000000000098',
        '2026-03','2026-03-01','2026-03-31');
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id)
VALUES ('99999999-0000-0000-0000-000000000098','${TEN}','dddddddd-0000-0000-0000-000000000098');
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by, status)
VALUES ('${B43E9}','${TEN}','${ENG99}','cccccccc-0000-0000-0000-000000000098',
        '99999999-0000-0000-0000-000000000098','${JIA}','${JIA}','ACCEPTED');
-- 租戶層 R2：角色種類正確、作用域錯誤（§26.3 嚴格相等的反例）
INSERT INTO app_user (user_id, tenant_id, email, display_name)
VALUES ('${T2R2}','${TEN}','cf-tenant-r2@t1.jp','租戶層 R2');
INSERT INTO role_assignment (tenant_id, user_id, role, engagement_id)
VALUES ('${TEN}','${T2R2}','R2',NULL);
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by) VALUES
  ('${MF43N}','${TEN}','${ENG}','${PR}','CASH_FLOW_SUPPORT','sqlcanon-2','cfs-neg','${JIA}'),
  ('${MF43P}','${TEN}','${ENG}','${PR}','CASH_FLOW_SUPPORT','sqlcanon-2','cfs-pos','${JIA}'),
  ('${MF43C}','${TEN}','${ENG}','${PR}','CASH_FLOW_SUPPORT','sqlcanon-2','cfs-race','${JIA}'),
  ('${MF43FX}','${TEN}','${ENG}','${PR}','FX_TRANSLATION','sqlcanon-2','cfs-fx','${JIA}');
${T2}
-- **另一租戶**的完整鏈：跨租戶批次必須是真的存在，否則「拒絕」證明不了什麼
INSERT INTO client_engagement (engagement_id, tenant_id, name)
VALUES ('eeeeeeee-0000-0000-0000-000000000022','${TEN2}','T2 案件');
INSERT INTO legal_entity (legal_entity_id, tenant_id, engagement_id, name, authoritative_code, country_code)
VALUES ('cccccccc-0000-0000-0000-000000000022','${TEN2}','eeeeeeee-0000-0000-0000-000000000022',
        'T2 法人','2222222222222','JP');
INSERT INTO reporting_unit (reporting_unit_id, tenant_id, engagement_id, legal_entity_id, unit_scope, name)
VALUES ('bbbbbbbb-0000-0000-0000-000000000022','${TEN2}','eeeeeeee-0000-0000-0000-000000000022',
        'cccccccc-0000-0000-0000-000000000022','LEGAL_ENTITY','T2 單位');
INSERT INTO fiscal_calendar (fiscal_calendar_id, tenant_id, engagement_id, name, year_start_month)
VALUES ('ffffffff-0000-0000-0000-000000000022','${TEN2}','eeeeeeee-0000-0000-0000-000000000022','T2 曆',4);
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id,
        fiscal_calendar_id, label, start_date, end_date)
VALUES ('dddddddd-0000-0000-0000-000000000022','${TEN2}','eeeeeeee-0000-0000-0000-000000000022',
        'bbbbbbbb-0000-0000-0000-000000000022','ffffffff-0000-0000-0000-000000000022',
        '2026-03','2026-03-01','2026-03-31');
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id)
VALUES ('99999999-0000-0000-0000-000000000022','${TEN2}','dddddddd-0000-0000-0000-000000000022');
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by, status)
VALUES ('${B43T2}','${TEN2}','eeeeeeee-0000-0000-0000-000000000022',
        'cccccccc-0000-0000-0000-000000000022','99999999-0000-0000-0000-000000000022',
        'a2222222-0000-0000-0000-000000000009','a2222222-0000-0000-0000-000000000009','ACCEPTED');
SQL

# 每條負面測試各用一份**新的** Manifest，並逐條回驗「沒有留下半套 run」。
# 共用一份的話，控制一旦被拿掉，第一條會佔用它、後面全部以 MANIFEST_ALREADY_USED
# 連鎖失敗——反證時就分不出是哪一項控制在守。
mfn() {
  PSQL_C <<<"${T1} INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id,
        period_revision_id, calculation_scope, canonicalization_version, frozen_set_content_hash,
        created_by)
   VALUES (gen_random_uuid(),'${TEN}','${ENG}','${PR}','CASH_FLOW_SUPPORT','sqlcanon-2',
           'cfs-neg','${JIA}') RETURNING manifest_id"
}
no_run() {  # $1=manifest $2=情境
  local r b
  r=$(PSQL_C <<<"${T1} SELECT count(*) FROM calculation_run WHERE manifest_id='$1'")
  b=$(PSQL_C <<<"${T1} SELECT count(*) FROM calculation_run_source_batch sb
       JOIN calculation_run r ON r.calculation_run_id = sb.calculation_run_id
       WHERE r.manifest_id='$1'")
  [ "${r}" = "0" ] && [ "${b}" = "0" ] && ok "0043：$2 之後沒有留下半套 run（run 0 筆／橋接 0 筆）" \
    || ng "0043：$2 之後留下 run ${r} 筆／橋接 ${b} 筆"
}

# ── 前置：每條負面測試要擋的東西都必須先確認確實處於目標狀態 ──
st=$(PSQL_C <<<"${T1} SELECT string_agg(status::text,',' ORDER BY import_batch_id)
     FROM import_batch WHERE import_batch_id IN
       ('${B43A}','${B43B}','${B43DR}','${B43VA}','${B43QU}','${B43SU}')")
[ "${st}" = "ACCEPTED,ACCEPTED,DRAFT,VALIDATED,QUARANTINED,SUPERSEDED" ] \
  && ok "0043 前置：六筆批次分別處於 ACCEPTED×2／DRAFT／VALIDATED／QUARANTINED／SUPERSEDED" \
  || ng "0043 前置：批次狀態為 ${st}"
st=$(PSQL_C <<<"${T1} SELECT status||'/'||(declared_period_revision_id='${PR2}')::text
     FROM import_batch WHERE import_batch_id='${B43P2}'")
[ "${st}" = "ACCEPTED/true" ] && ok "0043 前置：跨期間批次本身是 ACCEPTED（擋它的只能是期間）" \
  || ng "0043 前置：跨期間批次為 ${st}"
st=$(PSQL_C <<<"${T1} SELECT status||'/'||(engagement_id='${ENG99}')::text
     FROM import_batch WHERE import_batch_id='${B43E9}'")
[ "${st}" = "ACCEPTED/true" ] && ok "0043 前置：跨案件批次本身是 ACCEPTED 且同租戶（擋它的只能是案件）" \
  || ng "0043 前置：跨案件批次為 ${st}"
st=$(PSQL_C <<<"${T2} SELECT status||'/'||(tenant_id='${TEN2}')::text
     FROM import_batch WHERE import_batch_id='${B43T2}'")
[ "${st}" = "ACCEPTED/true" ] && ok "0043 前置：跨租戶批次確實存在且為 ACCEPTED（在 T2 脈絡下查得到）" \
  || ng "0043 前置：跨租戶批次為 ${st}"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM calculation_run WHERE manifest_id='${MF43P}'")
[ "${n}" = "0" ] && ok "0043 前置：正控制的 Manifest 尚無任何 run" || ng "0043 前置：已有 ${n} 筆 run"

# ── system-only：權限是邊界（不是 GUC 標記） ──
# 先證明 app_runtime **確實有** calculation_run 的 INSERT 授權——否則下一條測試
# 擋下來的可能只是缺授權，而不是本刀的守衛。
n=$(PSQL_C <<<"SELECT count(*) FROM information_schema.role_table_grants
     WHERE grantee='app_runtime' AND table_name='calculation_run' AND privilege_type='INSERT'")
[ "${n}" = "1" ] && ok "0043 前置：app_runtime 對 calculation_run 確有 INSERT 授權（NO_FX 需要，不能收回）" \
  || ng "0043 前置：app_runtime 的 calculation_run INSERT 授權數為 ${n}"
n=$(APP_C <<<"${T1} INSERT INTO calculation_run (tenant_id, engagement_id, period_revision_id,
      manifest_id, run_type, status, request_key, request_content_hash, engine_version, created_by)
    VALUES ('${TEN}','${ENG}','${PR}','${MF43N}','PREVIEW','RUNNING',gen_random_uuid(),'h','1.0.0','${JIA}')" 2>&1 \
    | grep -c "CFS_RUN_SYSTEM_ONLY")
[ "${n}" -ge 1 ] && ok "0043：app_runtime 直插現金流 run 被拒（system-only，只能經函式）" \
  || ng "0043：app_runtime 直插未被 CFS_RUN_SYSTEM_ONLY 擋下"
n=$(PSQL_C <<<"SELECT count(*) FROM information_schema.role_table_grants
     WHERE grantee='app_runtime' AND table_name='calculation_run_source_batch'
       AND privilege_type IN ('INSERT','UPDATE','DELETE')")
[ "${n}" = "0" ] && ok "0043：app_runtime 對來源橋接無任何寫入授權（橋接只能由函式凍結）" \
  || ng "0043：app_runtime 對橋接仍有 ${n} 項寫入授權"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM calculation_run WHERE manifest_id='${MF43N}'")
[ "${n}" = "0" ] && ok "0043：被拒的直插沒有留下半套 run" || ng "0043：留下 ${n} 筆 run"

# ── 入口本身的參數契約 ──
expect_err "0043：NO_FX 的 Manifest 不得走現金流入口" \
  "${T1} SELECT fn_cash_flow_support_run_create('${NOFXMF}',ARRAY['${B43A}']::uuid[],'${JIA}','1.0.0')" \
  "CFS_RUN_SCOPE_MISMATCH"
expect_err "0043：Manifest 不存在 → 拒絕" \
  "${T1} SELECT fn_cash_flow_support_run_create('c0440000-0000-0000-0000-000000000999',
     ARRAY['${B43A}']::uuid[],'${JIA}','1.0.0')" "CFS_RUN_MANIFEST_NOT_FOUND"
MF=$(mfn)
expect_err "0043：缺引擎版本 → 拒絕（重演要比對它）" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43A}']::uuid[],'${JIA}','')" \
  "CFS_RUN_ENGINE_VERSION_REQUIRED"
no_run "${MF}" "缺引擎版本"

# ── 來源清單：至少一筆、不重複 ──
MF=$(mfn)
expect_err "0043：空來源清單 → 拒絕（空集合等於來源歸屬未宣告）" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY[]::uuid[],'${JIA}','1.0.0')" \
  "CFS_RUN_SOURCE_BATCH_REQUIRED"
no_run "${MF}" "空來源清單"
MF=$(mfn)
expect_err "0043：來源清單為 NULL → 拒絕" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',NULL,'${JIA}','1.0.0')" \
  "CFS_RUN_SOURCE_BATCH_REQUIRED"
MF=$(mfn)
expect_err "0043：來源清單含空值 → 拒絕" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43A}',NULL]::uuid[],'${JIA}','1.0.0')" \
  "CFS_RUN_SOURCE_BATCH_REQUIRED"
MF=$(mfn)
expect_err "0043：同一批次重複列入 → 拒絕（重複＝同一份資料被算兩次）" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43A}','${B43A}']::uuid[],'${JIA}','1.0.0')" \
  "CFS_RUN_SOURCE_BATCH_DUPLICATE"
no_run "${MF}" "重複來源批次"

# ── 每一筆來源批次都必須是同租戶、同案件、同期間且 ACCEPTED ──
MF=$(mfn)
expect_err "0043：DRAFT 批次不得成為來源" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43DR}']::uuid[],'${JIA}','1.0.0')" \
  "CFS_BATCH_NOT_ACCEPTED"
no_run "${MF}" "DRAFT 批次不得成為來源"
MF=$(mfn)
expect_err "0043：VALIDATED 批次不得成為來源（通過驗證不等於已接受）" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43VA}']::uuid[],'${JIA}','1.0.0')" \
  "CFS_BATCH_NOT_ACCEPTED"
no_run "${MF}" "VALIDATED 批次不得成為來源"
MF=$(mfn)
expect_err "0043：QUARANTINED 批次不得成為來源" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43QU}']::uuid[],'${JIA}','1.0.0')" \
  "CFS_BATCH_NOT_ACCEPTED"
no_run "${MF}" "QUARANTINED 批次不得成為來源"
MF=$(mfn)
expect_err "0043：SUPERSEDED 批次不得成為來源（曾經接受過也不行）" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43SU}']::uuid[],'${JIA}','1.0.0')" \
  "CFS_BATCH_NOT_ACCEPTED"
no_run "${MF}" "SUPERSEDED 批次不得成為來源"
MF=$(mfn)
expect_err "0043：跨期間的已接受批次不得成為來源" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43P2}']::uuid[],'${JIA}','1.0.0')" \
  "CFS_BATCH_PERIOD_MISMATCH"
no_run "${MF}" "跨期間的已接受批次不得成為來源"
MF=$(mfn)
expect_err "0043：同租戶但屬另一案件的已接受批次不得成為來源" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43E9}']::uuid[],'${JIA}','1.0.0')" \
  "§24.1A"
no_run "${MF}" "同租戶但屬另一案件的已接受批次不得成為來源"
MF=$(mfn)
expect_err "0043：另一租戶的已接受批次不得成為來源（鎖的範圍就限本租戶）" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43T2}']::uuid[],'${JIA}','1.0.0')" \
  "CFS_RUN_SOURCE_BATCH_NOT_FOUND"
no_run "${MF}" "另一租戶的已接受批次不得成為來源"
MF=$(mfn)
expect_err "0043：不存在的批次 → 拒絕" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43NX}']::uuid[],'${JIA}','1.0.0')" \
  "CFS_RUN_SOURCE_BATCH_NOT_FOUND"
no_run "${MF}" "不存在的批次"

# ── 多批次：只要一筆不合法，整次建立全部回滾 ──
MF=$(mfn)
expect_err "0043：多批次中一筆未接受 → 整次拒絕" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',
     ARRAY['${B43A}','${B43QU}','${B43B}']::uuid[],'${JIA}','1.0.0')" "CFS_BATCH_NOT_ACCEPTED"
no_run "${MF}" "多批次中一筆未接受（合法的那兩筆橋接也不得留下）"

# ── 角色：案件層 R2，作用域嚴格相等 ──
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM role_assignment
     WHERE user_id='${CFR4}' AND role='R2' AND revoked_at IS NULL")
[ "${n}" = "0" ] && ok "0043 前置：CFR4 在本案件不持有 R2（反例是角色種類不符）" \
  || ng "0043 前置：CFR4 仍持有 ${n} 筆 R2"
MF=$(mfn)
expect_err "0043：非 R2（案件層 R4）不得建立現金流支持 run" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43A}']::uuid[],'${CFR4}','1.0.0')" \
  "ACTOR_ROLE_NOT_HELD"
no_run "${MF}" "非 R2 發起"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM role_assignment
     WHERE user_id='${T2R2}' AND role='R2' AND engagement_id IS NULL AND revoked_at IS NULL")
m=$(PSQL_C <<<"${T1} SELECT count(*) FROM role_assignment
     WHERE user_id='${T2R2}' AND engagement_id='${ENG}' AND revoked_at IS NULL")
[ "${n}" = "1" ] && [ "${m}" = "0" ] \
  && ok "0043 前置：T2R2 持有租戶層 R2、本案件無任何指派（角色種類正確、作用域錯誤）" \
  || ng "0043 前置：T2R2 租戶層 ${n} 筆／案件層 ${m} 筆"
MF=$(mfn)
expect_err "0043：租戶層 R2 不得建立現金流支持 run（§26.3 作用域嚴格相等）" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43A}']::uuid[],'${T2R2}','1.0.0')" \
  "ACTOR_ROLE_NOT_HELD"
no_run "${MF}" "租戶層 R2 發起"
MF=$(mfn)
expect_err "0043：在別的租戶脈絡下不得建立本租戶的 run" \
  "${T2} SELECT fn_cash_flow_support_run_create('${MF}',ARRAY['${B43A}']::uuid[],'${JIA}','1.0.0')" \
  "CROSS_TENANT_DENIED"
no_run "${MF}" "跨租戶脈絡發起"

# ── 正控制：多筆合法批次，經 app_runtime 走**凍結入口** ──
# 0044 起 0043 的入口降為內部 helper（app_runtime 已無 EXECUTE），因此正控制改走
# 唯一對外入口 fn_cash_flow_support_freeze_and_run——它凍結完整 Manifest 之後才
# 呼叫本 helper。0043 檔頭明文留下的「零條目 Manifest」過渡邊界於此關閉。
# 用 APP_C 才同時證明：GRANT EXECUTE 生效、且 system-only 守衛不擋函式路徑。
RUN43=$(APP_C <<<"${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR}','${UNIT}',
        '${POLA}','${MAPA}',ARRAY['${B43A}','${B43B}','${CFB}']::uuid[],'${JIA}','1.0.0')" 2>/dev/null)
[ -n "${RUN43}" ] && ok "0043／0044：R2 經凍結入口以多筆已接受批次建立現金流支持 run" \
  || ng "0043／0044：正控制建立失敗"
st=$(PSQL_C <<<"${T1} SELECT status||'/'||(import_batch_id IS NULL)::text||'/'||
     (result_content_hash IS NULL)::text||'/'||(completed_at IS NULL)::text||'/'||
     (failed_at IS NULL)::text||'/'||(replay_of_run_id IS NULL)::text
     FROM calculation_run WHERE calculation_run_id='${RUN43}'")
[ "${st}" = "RUNNING/true/true/true/true/true" ] \
  && ok "0043：run 建立即 RUNNING、單一批次欄位為 NULL、結果與終態欄位皆未預填" \
  || ng "0043：run 狀態為 ${st}"
st=$(PSQL_C <<<"${T1} SELECT string_agg(import_batch_id::text,',' ORDER BY import_batch_id)
     FROM calculation_run_source_batch WHERE calculation_run_id='${RUN43}'")
[ "${st}" = "${CFB},${B43A},${B43B}" ] \
  && ok "0043：來源橋接恰好是那三筆批次（同一交易內凍結）" \
  || ng "0043：橋接為 ${st}"
st=$(PSQL_C <<<"${T1} SELECT (r.created_by='${JIA}')::text||'/'||
     (r.request_content_hash = m.frozen_set_content_hash)::text||'/'||r.engine_version
     FROM calculation_run r JOIN calculation_input_manifest m ON m.manifest_id=r.manifest_id
     WHERE r.calculation_run_id='${RUN43}'")
[ "${st}" = "true/true/1.0.0" ] \
  && ok "0043：建立者、請求雜湊（＝Manifest 凍結雜湊）與引擎版本都如實記錄" \
  || ng "0043：run 欄位為 ${st}"
MANI43=$(PSQL_C <<<"${T1} SELECT manifest_id FROM calculation_run WHERE calculation_run_id='${RUN43}'")
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM cash_flow_support_line WHERE calculation_run_id='${RUN43}'")
m=$(PSQL_C <<<"${T1} SELECT count(*) FROM calculation_manifest_entry WHERE manifest_id='${MANI43}'")
[ "${n}" = "0" ] && [ "${m}" -ge 5 ] \
  && ok "0043／0044：Manifest 已完整凍結（${m} 筆條目），但仍不產生支持資料列（屬後續刀）" \
  || ng "0043／0044：支持資料列 ${n} 筆／Manifest 條目 ${m} 筆"
expect_err "0043：同一份 Manifest 不得再建第二個原始 run" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MANI43}',ARRAY['${B43A}']::uuid[],'${JIA}','1.0.0')" \
  "CFS_RUN_MANIFEST_ALREADY_USED"

# ── 既有的單批次契約不得因本刀改變 ──
expect_err "0043：FX_TRANSLATION run 不帶 import_batch_id 仍被既有守衛拒絕" \
  "${T1} INSERT INTO calculation_run (tenant_id, engagement_id, period_revision_id, manifest_id,
        run_type, status, request_key, request_content_hash, engine_version, created_by)
   VALUES ('${TEN}','${ENG}','${PR}','${MF43FX}','PREVIEW','RUNNING',gen_random_uuid(),'h','1.0.0','${JIA}')" \
  "Run 必須指明來源批次"

# ── 權限：0042 的掃描用 LIKE 'fn_cf%'，而 LIKE 的 `_` 是**單字元萬用字元**，
# 等於要求第五個字元是 f——fn_cash_flow_support_run_create 被靜默排除。
# 不改既有那三條（斷言不得修改），改用正規表示式另立一組涵蓋兩種命名。
n=$(PSQL_C <<<"SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
     WHERE ns.nspname='public' AND p.proname ~ '^fn_(cf|cash_flow)_' AND p.prosecdef
       AND NOT ('search_path=pg_catalog, public' = ANY(COALESCE(p.proconfig,ARRAY['']::text[])))")
[ "${n}" = "0" ] && ok "0043：現金流全部 SECURITY DEFINER 函式都固定 search_path（含 fn_cash_flow_*）" \
  || ng "0043：${n} 支函式未固定 search_path"
n=$(PSQL_C <<<"SELECT count(*) FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
     WHERE ns.nspname='public' AND p.proname ~ '^fn_(cf|cash_flow)_' AND p.prosecdef
       AND has_function_privilege('public', p.oid, 'EXECUTE')")
[ "${n}" = "0" ] && ok "0043：現金流全部 SECURITY DEFINER 函式一律撤回 PUBLIC（含 fn_cash_flow_*）" \
  || ng "0043：${n} 支函式仍對 PUBLIC 開放"
# 0044 起本函式是**內部 helper**：app_runtime 的 EXECUTE 已撤回，
# 唯一對外入口是 fn_cash_flow_support_freeze_and_run（見第 11 節）。
n=$(PSQL_C <<<"SELECT prosecdef::text||'/'||has_function_privilege('public',oid,'EXECUTE')::text||'/'||
     has_function_privilege('app_runtime',oid,'EXECUTE')::text
     FROM pg_proc WHERE proname='fn_cash_flow_support_run_create'")
[ "${n}" = "true/false/false" ] \
  && ok "0044：0043 的建立入口降為內部 helper（SECURITY DEFINER、PUBLIC 與 app_runtime 皆無 EXECUTE）" \
  || ng "0044：helper 的權限為 ${n}"
n=$(PSQL_C <<<"SELECT prosecdef::text FROM pg_proc WHERE proname='fn_calculation_run_insert_guard'")
[ "${n}" = "false" ] \
  && ok "0043：run 的 INSERT trigger 維持 SECURITY INVOKER（改成 DEFINER 會讓 system-only 檢查對誰都通過）" \
  || ng "0043：trigger 的 prosecdef 為 ${n}"

# ── 併發：批次狀態變更不得穿過建立交易 ──
# B 先持有未提交的 ACCEPTED → SUPERSEDED；A 呼叫函式時會卡在 FOR UPDATE，
# 等 B 提交後讀到的是 SUPERSEDED，因此必須失敗。沒有列鎖時 A 會讀到舊值而成功。
st=$(PSQL_C <<<"${T1} SELECT status FROM import_batch WHERE import_batch_id='${B43CC}'")
[ "${st}" = "ACCEPTED" ] && ok "0043 併發前置：競態批次在 B 動手前確實是 ACCEPTED" \
  || ng "0043 併發前置：狀態為 ${st}"
( PSQL_C >/dev/null 2>&1 <<SQL
${T1}
BEGIN;
UPDATE import_batch SET status='SUPERSEDED', superseded_by_id='${B43A}'
 WHERE import_batch_id='${B43CC}';
SELECT pg_sleep(3);
COMMIT;
SQL
) & BPID=$!
sleep 0.8
start=$(date +%s)
out=$(PSQL_C <<<"${T1} SELECT fn_cash_flow_support_run_create('${MF43C}',
      ARRAY['${B43CC}']::uuid[],'${JIA}','1.0.0')" 2>&1)
waited=$(( $(date +%s) - start ))
wait ${BPID}
[ "${waited}" -ge 1 ] && ok "0043 競態：A 的建立被 B 的列鎖擋住（等待 ${waited}s，未讀到過期狀態）" \
  || ng "0043 競態：A 未被阻塞（等待 ${waited}s）——FOR UPDATE 未生效"
echo "${out}" | grep -q "CFS_BATCH_NOT_ACCEPTED" \
  && ok "0043 競態：B 提交後 A 讀到 SUPERSEDED 並失敗（狀態變更未穿過建立交易）" \
  || ng "0043 競態：A 未以 CFS_BATCH_NOT_ACCEPTED 失敗 → ${out}"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM calculation_run WHERE manifest_id='${MF43C}'")
[ "${n}" = "0" ] && ok "0043 競態：失敗的建立沒有留下 run" || ng "0043 競態：留下 ${n} 筆 run"

# ══ 11　0044：CFS Manifest 的 system-only 凍結入口 ═════════════════
# 0043 收斂了 run 的建立，輸入卻還沒被凍結：manifest 與 entry 對 app_runtime 一直
# 可寫（NO_FX 需要），因此現金流的 run 可以掛在一份任人捏造、甚至空白的 Manifest 上。
# 本節驗證：直插被擋、結構契約成立、竄改露餡、半套不留、以及兩種來源輸出形狀都被凍結。

# 三者的增量：凍結失敗時不得留下任何一半
freeze_snapshot() {
  PSQL_C <<<"${T1} SELECT
    (SELECT count(*) FROM calculation_input_manifest WHERE calculation_scope='CASH_FLOW_SUPPORT')||'/'||
    (SELECT count(*) FROM calculation_manifest_entry e
       JOIN calculation_input_manifest m ON m.manifest_id=e.manifest_id
      WHERE m.calculation_scope='CASH_FLOW_SUPPORT')||'/'||
    (SELECT count(*) FROM calculation_run r
       JOIN calculation_input_manifest m ON m.manifest_id=r.manifest_id
      WHERE m.calculation_scope='CASH_FLOW_SUPPORT')"
}
no_freeze() {  # $1=先前快照 $2=情境
  local now; now=$(freeze_snapshot)
  [ "${now}" = "$1" ] && ok "0044：$2 之後 Manifest／條目／run 三者增量皆為 0" \
    || ng "0044：$2 之後三者由 $1 變為 ${now}"
}

# ── 前置：先證明 app_runtime **確實有**兩張表的 INSERT 授權 ──
# 否則下面兩條擋下來的可能只是缺授權，而不是本刀的守衛。
n=$(PSQL_C <<<"SELECT count(*) FROM information_schema.role_table_grants
     WHERE grantee='app_runtime' AND privilege_type='INSERT'
       AND table_name IN ('calculation_input_manifest','calculation_manifest_entry')")
[ "${n}" = "2" ] && ok "0044 前置：app_runtime 對 Manifest 與條目確有 INSERT 授權（NO_FX 需要，不能收回）" \
  || ng "0044 前置：INSERT 授權數為 ${n}"

n=$(APP_C <<<"${T1} INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id,
      period_revision_id, calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
    VALUES (gen_random_uuid(),'${TEN}','${ENG}','${PR}','CASH_FLOW_SUPPORT','sqlcanon-2','x','${JIA}')" 2>&1 \
    | grep -c "CFS_MANIFEST_SYSTEM_ONLY")
[ "${n}" -ge 1 ] && ok "0044：app_runtime 直插現金流 Manifest 被拒（system-only）" \
  || ng "0044：app_runtime 直插 Manifest 未被擋下"
n=$(APP_C <<<"${T1} INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type,
      object_id, domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
    VALUES ('${TEN}','${MANI43}','CASH_FLOW_SOURCE_FACT',gen_random_uuid(),'k','v','c','h','{}'::jsonb)" 2>&1 \
    | grep -c "CFS_MANIFEST_SYSTEM_ONLY")
[ "${n}" -ge 1 ] && ok "0044：app_runtime 直插現金流凍結條目被拒（system-only）" \
  || ng "0044：app_runtime 直插條目未被擋下"

# NO_FX 路徑必須完全不受影響——守衛是 scope-specific，不是整表封鎖
NOFXMF2=c0440000-0000-0000-0000-000000000301
expect_ok "0044：NO_FX 的 Manifest 仍可由 app_runtime 直接建立（既有路徑不動）" \
  "${T1} INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id,
        period_revision_id, calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
   VALUES ('${NOFXMF2}','${TEN}','${ENG}','${PR}','NO_FX','sqlcanon-2','nofx2','${JIA}')"
n=$(APP_C <<<"${T1} INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type,
      object_id, domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
    VALUES ('${TEN}','${NOFXMF2}','SOURCE_TB',NULL,'k','v','c','h','{}'::jsonb)" 2>&1 | grep -c "ERROR")
[ "${n}" = "0" ] && ok "0044：NO_FX 的凍結條目仍可由 app_runtime 直接建立（既有路徑不動）" \
  || ng "0044：NO_FX 條目寫入被誤擋"

# fail closed：條目所屬集合查不到（跨租戶被 RLS 擋掉）時不得當成「不是現金流」放行
MFT2=c0440000-0000-0000-0000-000000000303
_has calculation_input_manifest "manifest_id = '${MFT2}'" || PSQL_C >/dev/null <<SQL
${T2}
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
VALUES ('${MFT2}','${TEN2}','eeeeeeee-0000-0000-0000-000000000022',
        '99999999-0000-0000-0000-000000000022','NO_FX','sqlcanon-2','t2','a2222222-0000-0000-0000-000000000009');
SQL
n=$(PSQL_C <<<"${T2} SELECT count(*) FROM calculation_input_manifest WHERE manifest_id='${MFT2}'")
[ "${n}" = "1" ] && ok "0044 前置：另一租戶確實有一份 NO_FX 集合（本租戶看不到它）" \
  || ng "0044 前置：T2 集合建立失敗（${n}）"
n=$(APP_C <<<"${T1} INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type,
      object_id, domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
    VALUES ('${TEN}','${MFT2}','SOURCE_TB',NULL,'k','v','c','h','{}'::jsonb)" 2>&1 \
    | grep -c "CFS_MANIFEST_SYSTEM_ONLY")
[ "${n}" -ge 1 ] && ok "0044：條目所屬集合不可見時 fail closed（不得當成非現金流放行）" \
  || ng "0044：不可見集合的條目寫入未被擋下"

n=$(APP_C <<<"${T1} SELECT fn_cash_flow_support_run_create('${MANI43}',
      ARRAY['${B43A}']::uuid[],'${JIA}','1.0.0')" 2>&1 | grep -c "permission denied")
[ "${n}" -ge 1 ] && ok "0044：app_runtime 已不能呼叫 0043 的 helper（唯一對外入口是凍結函式）" \
  || ng "0044：app_runtime 仍可呼叫舊 helper"

n=$(PSQL_C <<<"SELECT string_agg(prosecdef::text,',' ORDER BY proname) FROM pg_proc
     WHERE proname IN ('fn_cfs_manifest_insert_guard','fn_cfs_manifest_entry_insert_guard')")
[ "${n}" = "false,false" ] \
  && ok "0044：兩支 Manifest 守衛都維持 SECURITY INVOKER（DEFINER 會讓身分檢查對誰都通過）" \
  || ng "0044：守衛的 prosecdef 為 ${n}"

# ── 結構契約：fn_manifest_verify 之上的薄薄一層 ──
expect_ok "0044：完整凍結的 Manifest 通過結構契約查證" \
  "${T1} SELECT fn_cf_manifest_assert_contract('${MANI43}')"
expect_err "0044：零條目的 Manifest 無法通過（完整性先於結構）" \
  "${T1} SELECT fn_cf_manifest_assert_contract('${MF43N}')" "REPLAY_MANIFEST_INTEGRITY_FAILED"
SNAP=$(freeze_snapshot)
expect_err "0044：空 Manifest 的 run 對任何呼叫者都不成立（helper 尾端查證）" \
  "${T1} SELECT fn_cash_flow_support_run_create('${MF43N}',ARRAY['${B43A}']::uuid[],'${JIA}','1.0.0')" \
  "REPLAY_MANIFEST_INTEGRITY_FAILED"
no_freeze "${SNAP}" "空 Manifest 建 run 被拒"

# 缺項：雜湊完全自洽、卻少了必要條目的一份集合
MFPART=c0440000-0000-0000-0000-000000000302
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
WITH e AS (SELECT fn_fx_freeze_entry2('[]'::jsonb,'SCOPE',NULL,'scope','1',
             '{"calculation_scope":"CASH_FLOW_SUPPORT"}'::jsonb)->0 AS x)
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
SELECT '${MFPART}','${TEN}','${ENG}','${PR}','CASH_FLOW_SUPPORT','sqlcanon-2',
       fn_fx_sha(x->>'hash'),'${JIA}' FROM e;
WITH e AS (SELECT fn_fx_freeze_entry2('[]'::jsonb,'SCOPE',NULL,'scope','1',
             '{"calculation_scope":"CASH_FLOW_SUPPORT"}'::jsonb)->0 AS x)
INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
        domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
SELECT '${TEN}','${MFPART}',x->>'object_type',NULL,x->>'kind',x->>'value',
       x->>'canonical',x->>'hash',x->'payload' FROM e;
SQL
expect_ok "0044 前置：缺項樣本的雜湊自洽（完整性驗證會通過，擋它的只能是結構契約）" \
  "${T1} SELECT fn_manifest_verify('${MFPART}')"
expect_err "0044：只有 SCOPE 的集合缺必要條目 → 結構契約不成立" \
  "${T1} SELECT fn_cf_manifest_assert_contract('${MFPART}')" "CFS_MANIFEST_SINGLETON_VIOLATION"

# ── 唯一性與 object_id ──
expect_err "0044：同一集合內 singleton 條目不得重複" \
  "${T1} INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
        domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
   VALUES ('${TEN}','${MFPART}','SCOPE',NULL,'k','v','c','h','{}'::jsonb)" "duplicate key"
# 重複測試必須挑**尚未被 run 引用**的集合：已封存的集合會先撞 INV-17，
# 那條測試就會以「Manifest 已封存」這個別的理由通過。
FACT1=$(PSQL_C <<<"${T1} SELECT object_id FROM calculation_manifest_entry
        WHERE manifest_id='${MANI43}' AND object_type='CASH_FLOW_SOURCE_FACT' LIMIT 1")
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM calculation_run WHERE manifest_id='${MFPART}'")
[ "${n}" = "0" ] && ok "0044 前置：缺項樣本尚未被任何 run 引用（不會先撞 INV-17 封存）" \
  || ng "0044 前置：缺項樣本已被 ${n} 個 run 引用"
expect_ok "0044 前置：多值條目可寫入未封存的集合" \
  "${T1} INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
        domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
   VALUES ('${TEN}','${MFPART}','CASH_FLOW_SOURCE_FACT','${FACT1}','k','v','c','h','{}'::jsonb)"
expect_err "0044：同一事實不得在同一集合內凍結兩次" \
  "${T1} INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
        domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
   VALUES ('${TEN}','${MFPART}','CASH_FLOW_SOURCE_FACT','${FACT1}','k','v','c','h','{}'::jsonb)" \
  "duplicate key"
expect_err "0044：多值型別的條目不得沒有 object_id（NULL 唯一性會留下重複通道）" \
  "${T1} INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
        domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
   VALUES ('${TEN}','${MFPART}','CASH_FLOW_SOURCE_FACT',NULL,'k','v','c','h','{}'::jsonb)" \
  "cme_multi_object_id_ck"

# ── 竄改：不可變 trigger 擋不住資料修復與 owner 操作，驗證要自己抓得到 ──
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
ALTER TABLE calculation_manifest_entry DISABLE TRIGGER USER;
UPDATE calculation_manifest_entry SET payload = payload || '{"tampered":true}'::jsonb
 WHERE manifest_id='${MANI43}' AND object_type='CASH_FLOW_POLICY_VERSION';
ALTER TABLE calculation_manifest_entry ENABLE TRIGGER USER;
SQL
expect_err "0044：條目 payload 被竄改 → 結構契約查證失敗" \
  "${T1} SELECT fn_cf_manifest_assert_contract('${MANI43}')" "REPLAY_MANIFEST_INTEGRITY_FAILED"
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
ALTER TABLE calculation_manifest_entry DISABLE TRIGGER USER;
UPDATE calculation_manifest_entry SET payload = payload - 'tampered'
 WHERE manifest_id='${MANI43}' AND object_type='CASH_FLOW_POLICY_VERSION';
ALTER TABLE calculation_manifest_entry ENABLE TRIGGER USER;
SQL
expect_ok "0044：還原竄改後恢復通過（證明上一條抓到的就是那次竄改）" \
  "${T1} SELECT fn_cf_manifest_assert_contract('${MANI43}')"
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
ALTER TABLE calculation_input_manifest DISABLE TRIGGER USER;
UPDATE calculation_input_manifest SET frozen_set_content_hash = 'deadbeef'
 WHERE manifest_id='${MANI43}';
ALTER TABLE calculation_input_manifest ENABLE TRIGGER USER;
SQL
expect_err "0044：集合雜湊被竄改 → 結構契約查證失敗" \
  "${T1} SELECT fn_cf_manifest_assert_contract('${MANI43}')" "REPLAY_MANIFEST_INTEGRITY_FAILED"
SETHASH=$(PSQL_C <<<"${T1} SELECT fn_fx_sha(string_agg(content_hash,'|'
          ORDER BY object_type, COALESCE(object_id::text,''), content_hash))
          FROM calculation_manifest_entry WHERE manifest_id='${MANI43}'")
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
ALTER TABLE calculation_input_manifest DISABLE TRIGGER USER;
UPDATE calculation_input_manifest SET frozen_set_content_hash = '${SETHASH}'
 WHERE manifest_id='${MANI43}';
ALTER TABLE calculation_input_manifest ENABLE TRIGGER USER;
SQL
expect_ok "0044：以生成端同一套排序重算的集合雜湊可還原（生成與驗證未分岔）" \
  "${T1} SELECT fn_cf_manifest_assert_contract('${MANI43}')"

# ── 正控制 A 的內容：凍結的是不是真的那些東西 ──
n=$(PSQL_C <<<"${T1} SELECT string_agg(object_type,',' ORDER BY object_type)
     FROM calculation_manifest_entry WHERE manifest_id='${MANI43}'")
[ "${n}" = "CASH_FLOW_CLASS_SET_VERSION,CASH_FLOW_COVERAGE_EXCEPTION,CASH_FLOW_MAPPING_VERSION,CASH_FLOW_OPENING_BALANCE_SET_VERSION,CASH_FLOW_POLICY_VERSION,CASH_FLOW_SOURCE_FACT,CASH_FLOW_SOURCE_SELECTION,SCOPE,SOURCE_CALCULATION_RUN" ] \
  && ok "0044：條目清單齊備（SCOPE／選定／政策／分類集合／映射／期初證據／例外／事實／來源 run）" \
  || ng "0044：條目清單為 ${n}"
n=$(PSQL_C <<<"${T1} SELECT (payload->>'cf_selection_id' = fn_current_cf_source_selection('${PR}')::text)::text
     FROM calculation_manifest_entry WHERE manifest_id='${MANI43}' AND object_type='CASH_FLOW_SOURCE_SELECTION'")
[ "${n}" = "true" ] && ok "0044：凍結的是**現行**選定（取代鏈判定，不是第一版也不是按時間）" \
  || ng "0044：凍結的選定與現行選定不符（${n}）"
n=$(PSQL_C <<<"${T1} SELECT (payload->>'opening_source_kind')||'/'||
     (SELECT count(*) FROM calculation_manifest_entry WHERE manifest_id='${MANI43}'
        AND object_type='CASH_FLOW_OPENING_BALANCE_SET_VERSION')||'/'||
     (SELECT count(*) FROM calculation_manifest_entry WHERE manifest_id='${MANI43}'
        AND object_type='SOURCE_CALCULATION_RUN')
     FROM calculation_manifest_entry WHERE manifest_id='${MANI43}' AND object_type='CASH_FLOW_SOURCE_SELECTION'")
[ "${n}" = "FIRST_PERIOD_EVIDENCE/1/1" ] \
  && ok "0044：首期期初證據情境下——期初證據恰 1 筆、來源 run 恰 1 筆" \
  || ng "0044：期初／來源 run 筆數為 ${n}"
# SCOPE 承載來源封套：facts 可以是零筆，封套不能跟著消失
n=$(PSQL_C <<<"${T1} SELECT (payload->'datasets'->0 ? 'data_coverage_id')::text||'/'||
     (payload->'datasets'->0 ? 'coverage_granularity')::text||'/'||
     (payload->'datasets'->0 ? 'completeness_status')::text||'/'||
     (payload->'datasets'->0 ? 'account_scope')::text||'/'||
     jsonb_array_length(payload->'source_batches')::text
     FROM calculation_manifest_entry WHERE manifest_id='${MANI43}' AND object_type='SCOPE'")
[ "${n}" = "true/true/true/true/3" ] \
  && ok "0044：SCOPE 凍結了來源封套（三筆批次＋資料集的 data_coverage_id／粒度／完整度／範圍）" \
  || ng "0044：SCOPE 封套為 ${n}"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM calculation_manifest_entry
     WHERE manifest_id='${MANI43}' AND object_type='CASH_FLOW_SOURCE_FACT'
       AND NOT (payload ? 'data_coverage_id')")
[ "${n}" = "0" ] && ok "0044：每筆事實都帶著綁定的 data_coverage_id（不只 actual_granularity）" \
  || ng "0044：${n} 筆事實沒有 data_coverage_id"
# 來源 run 凍結的是**實際行資料**，不是只有身分與雜湊
n=$(PSQL_C <<<"${T1} SELECT (payload->>'output_kind')||'/'||jsonb_array_length(payload->'lines')::text
     FROM calculation_manifest_entry WHERE manifest_id='${MANI43}' AND object_type='SOURCE_CALCULATION_RUN'")
m=$(PSQL_C <<<"${T1} SELECT count(*) FROM balance_snapshot_line WHERE calculation_run_id='${RUN_OK}'")
[ "${n}" = "NO_FX/${m}" ] && ok "0044：NO_FX 來源 run 凍結了全部 ${m} 筆 balance_snapshot_line" \
  || ng "0044：來源 run 的凍結行資料為 ${n}（實際 ${m} 筆）"
n=$(PSQL_C <<<"${T1} SELECT string_agg(l->>'account_code',',' ORDER BY (l->>'snapshot_line_id')::bigint)
     FROM calculation_manifest_entry e, jsonb_array_elements(e.payload->'lines') l
     WHERE e.manifest_id='${MANI43}' AND e.object_type='SOURCE_CALCULATION_RUN'")
m=$(PSQL_C <<<"${T1} SELECT string_agg(account_code,',' ORDER BY snapshot_line_id)
     FROM balance_snapshot_line WHERE calculation_run_id='${RUN_OK}'")
[ -n "${n}" ] && [ "${n}" = "${m}" ] && ok "0044：凍結的行資料逐筆等於來源 run 的實際輸出（${n}）" \
  || ng "0044：凍結行資料 ${n} ≠ 實際 ${m}"

# ── 凍結入口的參數契約：每一條之後都回驗三者增量為 0 ──
SNAP=$(freeze_snapshot)
expect_err "0044：期間不存在 → 拒絕" \
  "${T1} SELECT fn_cash_flow_support_freeze_and_run('99999999-0000-0000-0000-000000000777','${UNIT}',
     '${POLA}','${MAPA}',ARRAY['${B43A}']::uuid[],'${JIA}','1.0.0')" "CFS_FREEZE_PERIOD_NOT_FOUND"
expect_err "0044：報告單位與期間不符 → 拒絕" \
  "${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR}','${GRP_UNIT}',
     '${POLA}','${MAPA}',ARRAY['${B43A}']::uuid[],'${JIA}','1.0.0')" "CFS_FREEZE_UNIT_MISMATCH"
expect_err "0044：非 R2 不得凍結" \
  "${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR}','${UNIT}',
     '${POLA}','${MAPA}',ARRAY['${B43A}']::uuid[],'${CFR4}','1.0.0')" "ACTOR_ROLE_NOT_HELD"
expect_err "0044：在別的租戶脈絡下不得凍結本租戶的輸入" \
  "${T2} SELECT fn_cash_flow_support_freeze_and_run('${PR}','${UNIT}',
     '${POLA}','${MAPA}',ARRAY['${B43A}']::uuid[],'${JIA}','1.0.0')" "CROSS_TENANT_DENIED"
expect_err "0044：未批准的政策版本不得成為凍結輸入" \
  "${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR}','${UNIT}',
     '${POLB}','${MAPA}',ARRAY['${B43A}']::uuid[],'${JIA}','1.0.0')" "CFS_POLICY_NOT_APPROVED"
expect_err "0044：映射版本綁定的政策不是本次凍結的政策 → 拒絕" \
  "${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR}','${UNIT}',
     '${POLA}','${MAPJ}',ARRAY['${B43A}']::uuid[],'${JIA}','1.0.0')" \
  "CFS_FREEZE_MAPPING_POLICY_MISMATCH"
expect_err "0044：未批准的映射版本不得成為凍結輸入" \
  "${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR}','${UNIT}',
     '${POLA}','${MAPD}',ARRAY['${B43A}']::uuid[],'${JIA}','1.0.0')" "CFS_MAPPING_NOT_APPROVED"
expect_err "0044：缺引擎版本 → 拒絕" \
  "${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR}','${UNIT}',
     '${POLA}','${MAPA}',ARRAY['${B43A}']::uuid[],'${JIA}','')" "CFS_RUN_ENGINE_VERSION_REQUIRED"
expect_err "0044：空來源批次清單 → 拒絕" \
  "${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR}','${UNIT}',
     '${POLA}','${MAPA}',ARRAY[]::uuid[],'${JIA}','1.0.0')" "CFS_RUN_SOURCE_BATCH_REQUIRED"
expect_err "0044：未接受的批次不得成為凍結來源" \
  "${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR}','${UNIT}',
     '${POLA}','${MAPA}',ARRAY['${B43QU}']::uuid[],'${JIA}','1.0.0')" "CFS_BATCH_NOT_ACCEPTED"
no_freeze "${SNAP}" "以上十條參數契約全部被拒"

# ── 正控制 B：前期已選定結果（兩筆來源 run、零事實、無期初證據） ──
# 本期來源刻意用 NO_FX run：現金流的來源若是折算 run，選定會要求同期的
# PeriodFxRunSelection，而那需要容許值版本＋折算調節＋折算政策鏈＋匯率版本——
# 等於在現金流 fixture 裡重建整條 M3-02／M3-03 的鏈。**FX 原始輸出形狀
# （translation_result）的斷言因此留給下一刀**（見 0044 檔頭的已知邊界）。
RP3=dddddddd-0000-0000-0000-000000000031
PR3=99999999-0000-0000-0000-000000000031
B_P3=c0460000-0000-0000-0000-000000000031
MF_P3=c0440000-0000-0000-0000-000000000131
RUN_P3=c0450000-0000-0000-0000-000000000131
_has period_revision "period_revision_id = '${PR3}'" || PSQL_C >/dev/null <<SQL || { ng "0044 fixture（PR3 鏈）建立失敗（fail closed）"; exit 1; }
${T1}
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id,
        fiscal_calendar_id, label, start_date, end_date, previous_reporting_period_id)
-- 日期區間避開其他領域檔已用的月份：reporting_period 對
-- (reporting_unit_id, fiscal_calendar_id, daterange) 有排除約束，聚合模式下會相撞。
VALUES ('${RP3}','${TEN}','${ENG}','${UNIT}','${CAL}','2030-05','2030-05-01','2030-05-31','${RP2}');
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id)
VALUES ('${PR3}','${TEN}','${RP3}');
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by, status, file_name)
VALUES ('${B_P3}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR3}','${JIA}',
        '${JIA}','VALIDATING','cf-p3.csv');
INSERT INTO data_coverage (data_coverage_id, tenant_id, import_batch_id, batch_version,
        granularity, completeness_status)
VALUES ('c0480000-0000-0000-0000-000000000031','${TEN}','${B_P3}',1,'BALANCE','COMPLETE');
INSERT INTO source_dataset (source_dataset_id, tenant_id, import_batch_id, granularity,
        content_sha256, row_count, batch_version)
VALUES ('c0470000-0000-0000-0000-000000000031','${TEN}','${B_P3}','BALANCE','sha-p3',1,1);
INSERT INTO cash_flow_support_dataset (source_dataset_id, tenant_id, engagement_id,
        period_revision_id, reporting_unit_id, import_batch_id, content_hash, data_coverage_id)
VALUES ('c0470000-0000-0000-0000-000000000031','${TEN}','${ENG}','${PR3}','${UNIT}','${B_P3}',
        'ds-p3','c0480000-0000-0000-0000-000000000031');
ALTER TABLE import_batch DISABLE TRIGGER USER;
UPDATE import_batch SET status='ACCEPTED' WHERE import_batch_id='${B_P3}';
ALTER TABLE import_batch ENABLE TRIGGER USER;
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
VALUES ('${MF_P3}','${TEN}','${ENG}','${PR3}','NO_FX','sqlcanon-2','nofx-p3','${JIA}');
INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, status, request_key, request_content_hash,
        engine_version, created_by)
VALUES ('${RUN_P3}','${TEN}','${ENG}','${PR3}','${B_P3}','${MF_P3}','PREVIEW','RUNNING',
        gen_random_uuid(),'nofx-p3','1.0.0','${JIA}');
INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit) VALUES
  ('${TEN}','${RUN_P3}','SOURCE_TB','${ACC1}','1002','银行存款',3000.00,0),
  ('${TEN}','${RUN_P3}','SOURCE_TB','${ACC2}','6602','管理费用',0,3000.00);
UPDATE calculation_run SET status='COMPLETED', result_content_hash='r-p3', completed_at=now()
 WHERE calculation_run_id='${RUN_P3}';
SQL
# ── 第三期的本期來源是**引擎真正產生的折算 run** ──
# 不手工拼 translation_result：它的 result hash 涵蓋規則、component 與 CTA 證據，
# 手工拼出來的東西無法用來證明「凍結的 payload 足以重算來源 result hash」。
CFR6=af420000-0000-0000-0000-000000000007
FXV3=c0490000-0000-0000-0000-000000000041
POLV3=c0490000-0000-0000-0000-000000000042
CTA3=ac000000-0000-0000-0000-000000000041
_has app_user "user_id = '${CFR6}'" || PSQL_C >/dev/null <<SQL || { ng "0044 fixture（R6／科目）建立失敗（fail closed）"; exit 1; }
${T1}
INSERT INTO app_user (user_id, tenant_id, email, display_name)
VALUES ('${CFR6}','${TEN}','cf-r6@t1.jp','租戶層 R6');
INSERT INTO role_assignment (tenant_id, user_id, role, engagement_id)
VALUES ('${TEN}','${CFR6}','R6',NULL);
INSERT INTO account (account_id, tenant_id, coa_id, code, name, translation_category)
VALUES ('${CTA3}','${TEN}','88888888-0000-0000-0000-000000000001','3999','外幣報表折算差額','EQUITY_RETAINED');
UPDATE account SET translation_category='ASSET'  WHERE account_id='${ACC1}';
UPDATE account SET translation_category='EXPENSE' WHERE account_id='${ACC2}';
SQL
# 幣別指派：聚合模式下 fx 套件已建好同範圍的指派，這裡只在缺的時候補
_has reporting_unit_currency_assignment "reporting_unit_id='${UNIT}' AND currency_role='FUNCTIONAL' AND approved_at IS NOT NULL" \
  || PSQL_C >/dev/null <<SQL || { ng "0044 fixture（功能幣指派）建立失敗（fail closed）"; exit 1; }
${T1}
INSERT INTO reporting_unit_currency_assignment (tenant_id, engagement_id, reporting_unit_id,
        currency_role, currency_code, effective_range, created_by)
VALUES ('${TEN}','${ENG}','${UNIT}','FUNCTIONAL','JPY','[2020-01-01,)','${JIA}');
SELECT fn_currency_assignment_approve((SELECT assignment_id FROM reporting_unit_currency_assignment
  WHERE reporting_unit_id='${UNIT}' AND currency_role='FUNCTIONAL'),'${CFR4}');
SQL
_has reporting_unit_currency_assignment "reporting_unit_id='${UNIT}' AND currency_role='REPORTING' AND approved_at IS NOT NULL" \
  || PSQL_C >/dev/null <<SQL || { ng "0044 fixture（報告幣指派）建立失敗（fail closed）"; exit 1; }
${T1}
INSERT INTO reporting_unit_currency_assignment (tenant_id, engagement_id, reporting_unit_id,
        currency_role, currency_code, effective_range, created_by)
VALUES ('${TEN}','${ENG}','${UNIT}','REPORTING','CNY','[2020-01-01,)','${JIA}');
SELECT fn_currency_assignment_approve((SELECT assignment_id FROM reporting_unit_currency_assignment
  WHERE reporting_unit_id='${UNIT}' AND currency_role='REPORTING'),'${CFR4}');
SQL
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM reporting_unit_currency_assignment
     WHERE reporting_unit_id='${UNIT}' AND approved_at IS NOT NULL
       AND effective_range @> DATE '2030-05-31'")
[ "${n}" = "2" ] && ok "0044 前置：本單位有已批准的功能幣與報告幣指派（涵蓋第三期期末）" \
  || ng "0044 前置：涵蓋期末的已批准指派為 ${n} 筆"
_has exchange_rate_version "rate_version_id = '${FXV3}'" || PSQL_C >/dev/null <<SQL || { ng "0044 fixture（匯率版本）建立失敗（fail closed）"; exit 1; }
${T1}
INSERT INTO exchange_rate_version (rate_version_id, tenant_id, engagement_id, label,
        series_id, version_no, created_by)
VALUES ('${FXV3}','${TEN}','${ENG}','現金流第三期匯率','c0490000-0000-0000-0000-000000000141',1,'${CFR6}');
SELECT fn_exchange_rate_observation_add('${FXV3}','JPY','CNY','CLOSING',0.05,'央行',
       DATE '2030-05-31',NULL,NULL,NULL,'${CFR6}');
SELECT fn_exchange_rate_observation_add('${FXV3}','JPY','CNY','AVERAGE',0.048,'央行',
       NULL,DATE '2030-05-01',DATE '2030-05-31',NULL,'${CFR6}');
INSERT INTO translation_policy_version (policy_version_id, tenant_id, engagement_id,
        reporting_unit_id, label, cta_account_id, cta_coa_id, created_by)
VALUES ('${POLV3}','${TEN}','${ENG}','${UNIT}','現金流第三期折算政策','${CTA3}',
        '88888888-0000-0000-0000-000000000001','${JIA}');
INSERT INTO translation_policy_rule (tenant_id, policy_version_id, translation_category, method) VALUES
  ('${TEN}','${POLV3}','ASSET','CLOSING'),('${TEN}','${POLV3}','EXPENSE','AVERAGE');
SQL
expect_ok "0044 前置：匯率版本走完 R2 → R3 → R4 並批准折算政策" \
  "${T1} SELECT fn_exchange_rate_transition('${FXV3}','DRAFT','SUBMITTED','${JIA}','R2');
   SELECT fn_exchange_rate_transition('${FXV3}','SUBMITTED','REVIEWED','${CFR3}','R3');
   SELECT fn_exchange_rate_transition('${FXV3}','REVIEWED','APPROVED','${CFR4}','R4');
   SELECT fn_translation_policy_approve('${POLV3}','${CFR4}')"
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
SELECT fn_period_fx_select_inputs('${PR3}','${RUN_P3}','${FXV3}','${POLV3}','${JIA}');
SQL
FXRUN3=$(PSQL_C <<<"${T1} SELECT fn_fx_translation_run('${TEN}','${ENG}','${PR3}','${UNIT}',
         '${RUN_P3}','${FXV3}','${POLV3}','${JIA}','fx-1.0.0')" 2>/dev/null)
[ -n "${FXRUN3}" ] && ok "0044 前置：引擎產生第三期的折算 run（真實 translation_result 與 component）" \
  || ng "0044 前置：折算 run 建立失敗"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM translation_result WHERE calculation_run_id='${FXRUN3}'")
m=$(PSQL_C <<<"${T1} SELECT count(*) FROM translation_result_component c
     JOIN translation_result r ON r.translation_result_id=c.translation_result_id
     WHERE r.calculation_run_id='${FXRUN3}'")
[ "${n}" -ge 2 ] && [ "${m}" -ge 2 ] \
  && ok "0044 前置：折算 run 有 ${n} 筆 translation_result 與 ${m} 筆 component（非空證）" \
  || ng "0044 前置：折算輸出為 ${n}／${m}"
# 折算結果選定：現金流的來源若是折算 run，兩個選定不得各說各話
TOLV=c0490000-0000-0000-0000-000000000031
RECON=c04a0000-0000-0000-0000-000000000031
_has rounding_tolerance_version "tolerance_version_id = '${TOLV}'" || PSQL_C >/dev/null <<SQL || { ng "0044 fixture（容許值）建立失敗（fail closed）"; exit 1; }
${T1}
INSERT INTO rounding_tolerance_version (tolerance_version_id, tenant_id, engagement_id,
        reporting_unit_id, source_currency, target_currency, single_limit, cumulative_limit,
        series_id, version_no, created_by)
VALUES ('${TOLV}','${TEN}','${ENG}','${UNIT}','JPY','CNY',1.00,10.00,
        'c0490000-0000-0000-0000-000000000131',1,'${CFR4}');
SQL
expect_ok "0044 前置：R4 批准容許值版本" "${T1} SELECT fn_rounding_tolerance_approve('${TOLV}','${CFR4}')"
_has translation_reconciliation "reconciliation_id = '${RECON}'" || PSQL_C >/dev/null <<SQL || { ng "0044 fixture（折算調節）建立失敗（fail closed）"; exit 1; }
${T1}
INSERT INTO translation_reconciliation (reconciliation_id, tenant_id, engagement_id,
        reporting_unit_id, period_revision_id, calculation_run_id, tolerance_version_id,
        tolerance_content_hash, single_limit_snapshot, cumulative_limit_snapshot,
        scope_snapshot, reconciliation_engine_version, canonicalization_version,
        reconciliation_input_hash, finalized_by)
VALUES ('${RECON}','${TEN}','${ENG}','${UNIT}','${PR3}','${FXRUN3}','${TOLV}',
        'tol-h',1.00,10.00,'{"pair":"JPY->CNY"}'::jsonb,'1.0.0','sqlcanon-2','recon-h','${CFR4}');
SQL
expect_ok "0044 前置：R4 選定第三期的折算結果" \
  "${T1} SELECT fn_period_fx_select_run('${PR3}','${FXRUN3}','${RECON}','${CFR4}')"
PRIOR3=$(PSQL_C <<<"${T1} SELECT current_run_id FROM period_cash_flow_source_selection
         WHERE cf_selection_id = fn_current_cf_source_selection('${PR2}')")
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM balance_snapshot_line WHERE calculation_run_id='${PRIOR3}'")
[ "${n}" -ge 2 ] && ok "0044 前置：前期已選定 run 有 ${n} 筆實際輸出（前期比較不是空證）" \
  || ng "0044 前置：前期 run 只有 ${n} 筆輸出"
expect_ok "0044 前置：R4 以折算結果與前期已選定 run 選定第三期的權威來源" \
  "${T1} SELECT fn_cf_select_source('${PR3}','${FXRUN3}','PRIOR_SELECTED_RUN','${PRIOR3}',NULL,'${CFR4}')"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM cash_flow_source_fact WHERE period_revision_id='${PR3}'")
[ "${n}" = "0" ] && ok "0044 前置：第三期沒有任何金額事實（零活動是合法的，驗零事實分支）" \
  || ng "0044 前置：第三期已有 ${n} 筆事實"

RUN44=$(APP_C <<<"${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR3}','${UNIT}',
        '${POLA}','${MAPA}',ARRAY['${B_P3}']::uuid[],'${JIA}','1.0.0')" 2>/dev/null)
[ -n "${RUN44}" ] && ok "0044：零事實的期間仍可完成凍結與建立 run（零活動合法）" \
  || ng "0044：第三期凍結失敗"
MANI44=$(PSQL_C <<<"${T1} SELECT manifest_id FROM calculation_run WHERE calculation_run_id='${RUN44}'")
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM calculation_manifest_entry
     WHERE manifest_id='${MANI44}' AND object_type='CASH_FLOW_SOURCE_FACT'")
m=$(PSQL_C <<<"${T1} SELECT count(*) FROM calculation_manifest_entry
     WHERE manifest_id='${MANI44}' AND object_type='SCOPE'
       AND jsonb_array_length(payload->'datasets') = 1")
[ "${n}" = "0" ] && [ "${m}" = "1" ] \
  && ok "0044：零事實時 SCOPE 的來源封套仍在（封套不隨事實消失，粒度判定才有依據）" \
  || ng "0044：事實 ${n} 筆／封套資料集 ${m}"
n=$(PSQL_C <<<"${T1} SELECT string_agg(payload->>'role'||':'||(payload->>'output_kind'),',' ORDER BY payload->>'role')
     FROM calculation_manifest_entry WHERE manifest_id='${MANI44}' AND object_type='SOURCE_CALCULATION_RUN'")
[ "${n}" = "CURRENT:FX_TRANSLATION,PRIOR:NO_FX" ] \
  && ok "0044：前期已選定結果情境下凍結兩筆來源 run，且各自標明原始輸出形狀" \
  || ng "0044：來源 run 為 ${n}"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM calculation_manifest_entry
     WHERE manifest_id='${MANI44}' AND object_type='CASH_FLOW_OPENING_BALANCE_SET_VERSION'")
[ "${n}" = "0" ] && ok "0044：非首期不凍結期初證據集合（條件式條目）" || ng "0044：期初證據 ${n} 筆"
n=$(PSQL_C <<<"${T1} SELECT jsonb_array_length(payload->'lines')
     FROM calculation_manifest_entry WHERE manifest_id='${MANI44}'
       AND object_type='SOURCE_CALCULATION_RUN' AND payload->>'role'='PRIOR'")
m=$(PSQL_C <<<"${T1} SELECT count(*) FROM balance_snapshot_line WHERE calculation_run_id='${PRIOR3}'")
[ "${n}" = "${m}" ] && ok "0044：前期來源 run 的行資料也逐筆凍結（${m} 筆）" \
  || ng "0044：前期 run 凍結 ${n} 筆／實際 ${m} 筆"
expect_ok "0044：第三期的凍結集合通過結構契約查證" \
  "${T1} SELECT fn_cf_manifest_assert_contract('${MANI44}')"

# ── 併發：凍結途中批次狀態變更不得穿過 ──
# 用**已有現行選定**的 PR3：沒有選定的期間會在鎖批次之前就失敗，
# 那樣測到的是「沒有選定」，不是列鎖——以錯誤理由通過。
B44C=c0460000-0000-0000-0000-000000000032
B44D=c0460000-0000-0000-0000-000000000033
_has import_batch "import_batch_id = '${B44C}'" || PSQL_C >/dev/null <<SQL || { ng "0044 fixture（競態批次）建立失敗（fail closed）"; exit 1; }
${T1}
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by, status) VALUES
  ('${B44C}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR3}','${JIA}','${JIA}','ACCEPTED'),
  ('${B44D}','${TEN}','${ENG}','cccccccc-0000-0000-0000-000000000001','${PR3}','${JIA}','${JIA}','ACCEPTED');
SQL
st=$(PSQL_C <<<"${T1} SELECT status FROM import_batch WHERE import_batch_id='${B44C}'")
[ "${st}" = "ACCEPTED" ] && ok "0044 競態前置：批次在 B 動手前確實是 ACCEPTED" || ng "0044 競態前置：${st}"
n=$(PSQL_C <<<"${T1} SELECT (fn_current_cf_source_selection('${PR3}') IS NOT NULL)::text")
[ "${n}" = "true" ] && ok "0044 競態前置：該期間有現行選定（凍結因此走得到鎖批次那一步）" \
  || ng "0044 競態前置：該期間沒有現行選定，測到的會是別的理由"
SNAP=$(freeze_snapshot)
( PSQL_C >/dev/null 2>&1 <<SQL
${T1}
BEGIN;
UPDATE import_batch SET status='SUPERSEDED', superseded_by_id='${B43A}'
 WHERE import_batch_id='${B44C}';
SELECT pg_sleep(3);
COMMIT;
SQL
) & BPID=$!
sleep 0.8
start=$(date +%s)
out=$(PSQL_C <<<"${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR3}','${UNIT}',
      '${POLA}','${MAPA}',ARRAY['${B44C}']::uuid[],'${JIA}','1.0.0')" 2>&1)
waited=$(( $(date +%s) - start ))
wait ${BPID}
[ "${waited}" -ge 1 ] && ok "0044 競態：凍結被 B 的列鎖擋住（等待 ${waited}s，未讀到過期狀態）" \
  || ng "0044 競態：未被阻塞（等待 ${waited}s）"
echo "${out}" | grep -q "CFS_BATCH_NOT_ACCEPTED" \
  && ok "0044 競態：B 提交後凍結讀到 SUPERSEDED 並失敗（狀態變更未穿過凍結交易）" \
  || ng "0044 競態：未以 CFS_BATCH_NOT_ACCEPTED 失敗 → ${out}"
no_freeze "${SNAP}" "競態下的凍結失敗"

# 同一期間的兩次凍結必須互相序列化，否則兩份凍結會各自看到不同 snapshot。
# 批次集合刻意**互不相交**：共用批次的話，擋住第二次的會是 helper 的批次列鎖。
# **本條不宣稱是期間列鎖擋的**——實測反證：把 `FOR UPDATE OF pr` 拿掉仍然全綠，
# 因為兩次凍結還共用政策／映射／選定那幾列的 FOR UPDATE。期間鎖是刻意保留的
# 順序保證（先鎖期間再解析現行選定），但目前沒有測試能單獨證明它。
( PSQL_C >/dev/null 2>&1 <<SQL
${T1}
BEGIN;
SELECT fn_cash_flow_support_freeze_and_run('${PR3}','${UNIT}','${POLA}','${MAPA}',
       ARRAY['${B_P3}']::uuid[],'${JIA}','1.0.0');
SELECT pg_sleep(3);
COMMIT;
SQL
) & APID=$!
sleep 0.8
start=$(date +%s)
PSQL_C >/dev/null 2>&1 <<<"${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR3}','${UNIT}',
  '${POLA}','${MAPA}',ARRAY['${B44D}']::uuid[],'${JIA}','1.0.0')"
waited=$(( $(date +%s) - start ))
wait ${APID}
[ "${waited}" -ge 1 ] \
  && ok "0044 競態：同一期間的兩次凍結互相序列化（等待 ${waited}s，批次集合不相交仍序列化）" \
  || ng "0044 競態：第二次凍結未被序列化（等待 ${waited}s）"

# ══ 12　0045：私有化、結果雜湊復驗、來源輸出證據完整 ═════════════════
# ── P1-1：結構驗證 helper 不得成為跨租戶探測工具 ──
n=$(PSQL_C <<<"SELECT has_function_privilege('app_runtime',
     'fn_cf_manifest_assert_contract(uuid)','EXECUTE')::text")
[ "${n}" = "false" ] && ok "0045：結構驗證 helper 已撤回 app_runtime 的 EXECUTE（僅內部使用）" \
  || ng "0045：app_runtime 仍可執行結構驗證 helper"
n=$(APP_C <<<"${T1} SELECT fn_cf_manifest_assert_contract('${MANI43}')" 2>&1 | grep -c "permission denied")
[ "${n}" -ge 1 ] && ok "0045：app_runtime 直接呼叫結構驗證 helper 被權限擋下" \
  || ng "0045：app_runtime 仍呼叫得動結構驗證 helper"
expect_err "0045：在別的租戶脈絡下不得以已知 UUID 探測本租戶的凍結集合" \
  "${T2} SELECT fn_cf_manifest_assert_contract('${MANI43}')" "CROSS_TENANT_DENIED"

# ── P1-2：凍結當下復驗來源 run 的結果雜湊 ──
n=$(PSQL_C <<<"${T1} SELECT (fn_calc_result_hash('${FXRUN3}') = result_content_hash)::text
     FROM calculation_run WHERE calculation_run_id='${FXRUN3}'")
[ "${n}" = "true" ] \
  && ok "0045：FX 重算公式與引擎（fn_fx_materialize）一致——引擎產生的 run 對得上" \
  || ng "0045：FX 重算與引擎不一致（${n}）"
n=$(PSQL_C <<<"${T1} SELECT (fn_calc_result_hash('${PRIOR3}') = result_content_hash)::text
     FROM calculation_run WHERE calculation_run_id='${PRIOR3}'")
[ "${n}" = "true" ] && ok "0045：NO_FX 重算公式與該 run 記載的結果雜湊一致" \
  || ng "0045：NO_FX 重算不一致（${n}）"

SNAP=$(freeze_snapshot)
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
ALTER TABLE balance_snapshot_line DISABLE TRIGGER USER;
UPDATE balance_snapshot_line SET debit = debit + 1
 WHERE calculation_run_id='${PRIOR3}' AND account_code='1002';
ALTER TABLE balance_snapshot_line ENABLE TRIGGER USER;
SQL
n=$(PSQL_C <<<"${T1} SELECT (fn_calc_result_hash('${PRIOR3}') <> result_content_hash)::text
     FROM calculation_run WHERE calculation_run_id='${PRIOR3}'")
[ "${n}" = "true" ] && ok "0045 前置：前期來源 run 的輸出已被竄改（重算雜湊與記載不符）" \
  || ng "0045 前置：竄改未生效（${n}）"
expect_err "0045：來源 run 的輸出被破壞 → 拒絕凍結（不得把損壞行＋舊雜湊一起封存）" \
  "${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR3}','${UNIT}','${POLA}','${MAPA}',
     ARRAY['${B_P3}']::uuid[],'${JIA}','1.0.0')" "CFS_SOURCE_RUN_RESULT_HASH_MISMATCH"
no_freeze "${SNAP}" "來源輸出損壞而拒絕凍結"
PSQL_C >/dev/null 2>&1 <<SQL
${T1}
ALTER TABLE balance_snapshot_line DISABLE TRIGGER USER;
UPDATE balance_snapshot_line SET debit = debit - 1
 WHERE calculation_run_id='${PRIOR3}' AND account_code='1002';
ALTER TABLE balance_snapshot_line ENABLE TRIGGER USER;
SQL
RUN45=$(PSQL_C <<<"${T1} SELECT fn_cash_flow_support_freeze_and_run('${PR3}','${UNIT}',
        '${POLA}','${MAPA}',ARRAY['${B_P3}']::uuid[],'${JIA}','1.0.0')" 2>/dev/null)
[ -n "${RUN45}" ] && ok "0045：還原竄改後凍結恢復成立（證明上一條擋的就是那次破壞）" \
  || ng "0045：還原後仍無法凍結"
MANI45=$(PSQL_C <<<"${T1} SELECT manifest_id FROM calculation_run WHERE calculation_run_id='${RUN45}'")

# ── P1-2：FX payload 必須足以**由凍結內容重算**來源 run 的結果雜湊 ──
n=$(PSQL_C <<<"${T1} SELECT (payload->'lines'->0 ? 'translation_policy_rule_id')::text||'/'||
     (payload->'lines'->0 ? 'components')::text||'/'||
     (jsonb_array_length(payload->'lines'->0->'components') > 0)::text||'/'||
     (payload ? 'cta_lines')::text
     FROM calculation_manifest_entry WHERE manifest_id='${MANI45}'
       AND object_type='SOURCE_CALCULATION_RUN' AND payload->>'role'='CURRENT'")
[ "${n}" = "true/true/true/true" ] \
  && ok "0045：FX 來源凍結了命中規則、逐筆 component 與 CTA 證據" \
  || ng "0045：FX payload 證據為 ${n}"
RECALC=$(PSQL_C <<<"${T1}
  WITH e AS (SELECT payload AS p FROM calculation_manifest_entry
              WHERE manifest_id='${MANI45}' AND object_type='SOURCE_CALCULATION_RUN'
                AND payload->>'role'='CURRENT'),
  parts AS (
    SELECT (l->>'source_account_code')||':'||(l->>'source_posting_layer')||':'||
           (l->>'result_debit')||'/'||(l->>'result_credit')||':'||
           COALESCE(l->>'translation_policy_rule_id','-')||'#'||
           COALESCE((SELECT string_agg((c->>'source_kind')||'>'||
                       COALESCE(c->>'exchange_rate_observation_id','-')||'>'||
                       COALESCE(c->>'equity_lot_id','-')||'>'||
                       COALESCE(c->>'opening_balance_id','-')||'>'||
                       (c->>'result_debit')||'/'||(c->>'result_credit'), ','
                     ORDER BY (c->>'line_no')::int)
                     FROM jsonb_array_elements(l->'components') c), '') AS part
      FROM e, jsonb_array_elements(e.p->'lines') l
    UNION ALL
    SELECT 'CTA:'||(t->>'account_id')||':'||(t->>'debit')||'/'||(t->>'credit')||':'||
           (t->>'translation_policy_version_id')||':'||(t->>'exchange_rate_version_id')
      FROM e, jsonb_array_elements(e.p->'cta_lines') t)
  SELECT fn_fx_sha(string_agg(part,'|' ORDER BY part)) FROM parts")
STORED=$(PSQL_C <<<"${T1} SELECT payload->>'result_content_hash' FROM calculation_manifest_entry
         WHERE manifest_id='${MANI45}' AND object_type='SOURCE_CALCULATION_RUN'
           AND payload->>'role'='CURRENT'")
[ -n "${RECALC}" ] && [ "${RECALC}" = "${STORED}" ] \
  && ok "0045：**只用凍結 payload** 就能重算出來源 FX run 的結果雜湊（重演不必回查結果表）" \
  || ng "0045：由 payload 重算得 ${RECALC}，凍結記載為 ${STORED}"

# ── P1-3：NO_FX 的「逐筆相等」必須是全欄位，且兩邊都非空 ──
for role in CURRENT PRIOR; do
  RID=$(PSQL_C <<<"${T1} SELECT payload->>'calculation_run_id' FROM calculation_manifest_entry
        WHERE manifest_id='${MANI45}' AND object_type='SOURCE_CALCULATION_RUN'
          AND payload->>'role'='${role}' AND payload->>'output_kind'='NO_FX'")
  [ -z "${RID}" ] && continue
  froz=$(PSQL_C <<<"${T1} SELECT string_agg((l->>'posting_layer')||'|'||(l->>'account_id')||'|'||
         (l->>'account_code')||'|'||(l->>'account_name')||'|'||(l->>'debit')||'|'||(l->>'credit'),
         E'\n' ORDER BY (l->>'snapshot_line_id')::bigint)
         FROM calculation_manifest_entry e, jsonb_array_elements(e.payload->'lines') l
         WHERE e.manifest_id='${MANI45}' AND e.object_type='SOURCE_CALCULATION_RUN'
           AND e.payload->>'role'='${role}'")
  live=$(PSQL_C <<<"${T1} SELECT string_agg(posting_layer||'|'||account_id||'|'||account_code||'|'||
         account_name||'|'||debit::text||'|'||credit::text, E'\n' ORDER BY snapshot_line_id)
         FROM balance_snapshot_line WHERE calculation_run_id='${RID}'")
  cnt=$(PSQL_C <<<"${T1} SELECT count(*) FROM balance_snapshot_line WHERE calculation_run_id='${RID}'")
  [ "${cnt}" -ge 2 ] && [ -n "${froz}" ] && [ "${froz}" = "${live}" ] \
    && ok "0045：${role} 的 NO_FX 來源逐筆全欄位相等（層／科目／代碼／名稱／借／貸，${cnt} 筆非空）" \
    || ng "0045：${role} 的凍結行資料與實際不符（${cnt} 筆）"
done

# ── P1-4：凍結與改選在期間列上序列化（0042 已 FOR UPDATE OF pr） ──
( PSQL_C >/dev/null 2>&1 <<SQL
${T1}
BEGIN;
SELECT fn_cash_flow_support_freeze_and_run('${PR3}','${UNIT}','${POLA}','${MAPA}',
       ARRAY['${B_P3}']::uuid[],'${JIA}','1.0.0');
SELECT pg_sleep(3);
COMMIT;
SQL
) & APID=$!
sleep 0.8
start=$(date +%s)
PSQL_C >/dev/null 2>&1 <<<"${T1} SELECT fn_cf_select_source('${PR3}','${FXRUN3}','PRIOR_SELECTED_RUN','${PRIOR3}',NULL,'${CFR4}')"
waited=$(( $(date +%s) - start ))
wait ${APID}
[ "${waited}" -ge 1 ] \
  && ok "0045：改選被凍結交易的期間列鎖擋住（等待 ${waited}s——凍結途中不可能有新版選定提交）" \
  || ng "0045：改選未被序列化（等待 ${waited}s）"
n=$(PSQL_C <<<"${T1} SELECT count(*) FROM period_cash_flow_source_selection WHERE period_revision_id='${PR3}'")
[ "${n}" -ge 2 ] && ok "0045：改選在凍結提交後才生效（第三期已有 ${n} 版選定）" \
  || ng "0045：改選未生效（${n} 版）"

[ "${STANDALONE:-0}" = "1" ] && summary
