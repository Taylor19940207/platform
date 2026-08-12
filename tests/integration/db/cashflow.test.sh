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
  (gen_random_uuid(),'${TEN}','${CFSET}','FXE','匯率變動對現金的影響','FX_EFFECT_ON_CASH',
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
expect_err "0040：COVERAGE_EXCEPTION 必須帶 exception_id" \
  "${T1} INSERT INTO cash_flow_class_period_coverage (tenant_id, period_revision_id,
        reporting_unit_id, policy_version_id, cash_flow_class_id, status)
   VALUES ('${TEN}','${GRP_PR}','${GRP_UNIT}','${CFPOL}','${CFCLS}','COVERAGE_EXCEPTION')" \
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

[ "${STANDALONE:-0}" = "1" ] && summary
