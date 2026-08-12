-- 0039 現金流支持資料：模型與守衛（SLICE-M3-04 第一段）
--
-- 邊界（契約第五版）：P0 只收集與映射，**不重建**。因此本檔沒有任何可以放
-- 推算結果的欄位——金額只從 CashFlowSourceFact 原樣帶出。

-- ═══ 0　通用凍結集合驗證：fn_manifest_verify ═══════════════════════
-- 該驗證與 FX 無關（它驗的是 manifest 自己）。新增通用入口；
-- fn_fx_verify_manifest **保留為相容 wrapper**，M3-02／M3-03 的行為與斷言不動。
ALTER FUNCTION fn_fx_verify_manifest(uuid) RENAME TO fn_manifest_verify;
CREATE FUNCTION fn_fx_verify_manifest(p_manifest uuid) RETURNS void
LANGUAGE sql AS $$ SELECT fn_manifest_verify(p_manifest) $$;
REVOKE ALL ON FUNCTION fn_fx_verify_manifest(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_fx_verify_manifest(uuid) TO app_runtime;
REVOKE ALL ON FUNCTION fn_manifest_verify(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_manifest_verify(uuid) TO app_runtime;

-- ═══ 1　粒度相容：單一實作 ═════════════════════════════════════════
-- 不得在各處各寫一份排序；更細不是錯，只有更粗才是。
CREATE FUNCTION fn_granularity_rank(p text) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p WHEN 'BALANCE' THEN 1 WHEN 'JOURNAL' THEN 2
                WHEN 'SUBLEDGER' THEN 3 WHEN 'DOCUMENT' THEN 4 END
$$;
CREATE FUNCTION fn_granularity_satisfies(p_actual text, p_required text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT fn_granularity_rank(p_actual) >= fn_granularity_rank(p_required)
$$;
CREATE FUNCTION fn_source_kind_granularity(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p WHEN 'ACCOUNT' THEN 'BALANCE' WHEN 'JOURNAL_LINE' THEN 'JOURNAL'
                WHEN 'SUBLEDGER_ITEM' THEN 'SUBLEDGER' WHEN 'DOCUMENT' THEN 'DOCUMENT' END
$$;

-- ═══ 2　分類集合（含現金科目範圍）═══════════════════════════════════
CREATE TABLE cash_flow_class_set_version (
  class_set_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  engagement_id uuid NOT NULL REFERENCES client_engagement,
  label         text NOT NULL,
  series_id     uuid NOT NULL,
  version_no    int  NOT NULL CHECK (version_no >= 1),
  supersedes_set_version_id uuid REFERENCES cash_flow_class_set_version,
  approved_by   uuid REFERENCES app_user,
  approved_at   timestamptz,
  created_by    uuid NOT NULL REFERENCES app_user,
  created_at    timestamptz NOT NULL DEFAULT now(),
  content_hash  text,
  CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
  CHECK ((version_no = 1) = (supersedes_set_version_id IS NULL)),
  UNIQUE (series_id, version_no)
);
CREATE UNIQUE INDEX cf_class_set_supersedes_uq
  ON cash_flow_class_set_version (supersedes_set_version_id)
  WHERE supersedes_set_version_id IS NOT NULL;

CREATE TABLE cash_flow_class (
  cash_flow_class_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  class_set_version_id uuid NOT NULL REFERENCES cash_flow_class_set_version ON DELETE CASCADE,
  code          text NOT NULL,
  name          text NOT NULL,
  -- FX_EFFECT_ON_CASH 是控制項，不是第四種活動
  kind          text NOT NULL CHECK (kind IN ('ACTIVITY','FX_EFFECT_ON_CASH')),
  activity      text CHECK (activity IN ('OPERATING','INVESTING','FINANCING')),
  direction     text NOT NULL CHECK (direction IN ('INFLOW','OUTFLOW','EITHER')),
  is_required   boolean NOT NULL DEFAULT false,
  CHECK ((kind = 'ACTIVITY') = (activity IS NOT NULL)),
  UNIQUE (class_set_version_id, code)
);

-- 現金及約當現金的範圍隨集合批准：不同母公司對同一科目可能有不同認定，
-- Account 屬性表達不了「這是誰的口徑」。
CREATE TABLE cash_flow_cash_account_membership (
  membership_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  class_set_version_id uuid NOT NULL REFERENCES cash_flow_class_set_version ON DELETE CASCADE,
  account_id    uuid NOT NULL REFERENCES account,
  cash_role     text NOT NULL CHECK (cash_role IN ('CASH','CASH_EQUIVALENT')),
  UNIQUE (class_set_version_id, account_id)
);

-- ═══ 3　政策版本 ═══════════════════════════════════════════════════
CREATE TABLE cash_flow_policy_version (
  policy_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  engagement_id uuid NOT NULL REFERENCES client_engagement,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  method        text NOT NULL CHECK (method IN ('DIRECT','INDIRECT')),
  -- 沿用 DataCoverage 的既有四值（ACCOUNT 是 source_kind，不是粒度）
  required_granularity text NOT NULL
    CHECK (required_granularity IN ('BALANCE','JOURNAL','SUBLEDGER','DOCUMENT')),
  -- 必要性只由集合的 is_required 定義，不在此另存一份
  class_set_version_id uuid NOT NULL REFERENCES cash_flow_class_set_version,
  evidence_version text NOT NULL CHECK (evidence_version <> ''),
  series_id     uuid NOT NULL,
  version_no    int  NOT NULL CHECK (version_no >= 1),
  supersedes_policy_version_id uuid REFERENCES cash_flow_policy_version,
  approved_by   uuid REFERENCES app_user,
  approved_at   timestamptz,
  created_by    uuid NOT NULL REFERENCES app_user,
  created_at    timestamptz NOT NULL DEFAULT now(),
  content_hash  text,
  CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
  CHECK ((version_no = 1) = (supersedes_policy_version_id IS NULL)),
  UNIQUE (series_id, version_no)
);
CREATE UNIQUE INDEX cf_policy_supersedes_uq
  ON cash_flow_policy_version (supersedes_policy_version_id)
  WHERE supersedes_policy_version_id IS NOT NULL;

-- ═══ 4　映射版本與規則 ═════════════════════════════════════════════
CREATE TABLE cash_flow_mapping_version (
  mapping_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  engagement_id uuid NOT NULL REFERENCES client_engagement,
  policy_version_id uuid NOT NULL REFERENCES cash_flow_policy_version,
  series_id     uuid NOT NULL,
  version_no    int  NOT NULL CHECK (version_no >= 1),
  supersedes_mapping_version_id uuid REFERENCES cash_flow_mapping_version,
  approved_by   uuid REFERENCES app_user,
  approved_at   timestamptz,
  created_by    uuid NOT NULL REFERENCES app_user,
  created_at    timestamptz NOT NULL DEFAULT now(),
  content_hash  text,
  CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
  CHECK ((version_no = 1) = (supersedes_mapping_version_id IS NULL)),
  UNIQUE (series_id, version_no)
);
CREATE UNIQUE INDEX cf_mapping_supersedes_uq
  ON cash_flow_mapping_version (supersedes_mapping_version_id)
  WHERE supersedes_mapping_version_id IS NOT NULL;

CREATE TABLE cash_flow_mapping_rule (
  mapping_rule_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  mapping_version_id uuid NOT NULL REFERENCES cash_flow_mapping_version ON DELETE CASCADE,
  source_kind   text NOT NULL CHECK (source_kind IN
                  ('ACCOUNT','JOURNAL_LINE','SUBLEDGER_ITEM','DOCUMENT')),
  -- 具體外鍵，不是可空 text（0031 的教訓）
  account_id            uuid REFERENCES account,
  source_ledger_line_id uuid,
  source_document_id    uuid,
  cash_flow_class_id uuid NOT NULL REFERENCES cash_flow_class,
  effective_from date,
  effective_to   date,
  evidence_ref   text,
  CHECK (
    (source_kind = 'ACCOUNT' AND account_id IS NOT NULL
       AND source_ledger_line_id IS NULL AND source_document_id IS NULL)
 OR (source_kind IN ('JOURNAL_LINE','SUBLEDGER_ITEM') AND source_ledger_line_id IS NOT NULL
       AND source_document_id IS NULL)
 OR (source_kind = 'DOCUMENT' AND source_document_id IS NOT NULL
       AND source_ledger_line_id IS NULL))
);

-- ═══ 5　用途封套與金額事實 ═════════════════════════════════════════
-- **表的存在本身就代表 dataset_purpose = CASH_FLOW_SUPPORT**——不設列舉欄位，
-- 也就沒有「值被改掉」的可能。沒有這層封套，「不得從 TB 推算」只是註解。
CREATE TABLE cash_flow_support_dataset (
  source_dataset_id uuid PRIMARY KEY REFERENCES source_dataset,
  tenant_id     uuid NOT NULL REFERENCES tenant,
  engagement_id uuid NOT NULL REFERENCES client_engagement,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  import_batch_id uuid NOT NULL REFERENCES import_batch,
  content_hash  text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE cash_flow_source_fact (
  source_fact_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  engagement_id uuid NOT NULL REFERENCES client_engagement,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  source_dataset_id uuid NOT NULL REFERENCES cash_flow_support_dataset,
  import_batch_id uuid NOT NULL REFERENCES import_batch,
  actual_granularity text NOT NULL
    CHECK (actual_granularity IN ('BALANCE','JOURNAL','SUBLEDGER','DOCUMENT')),
  source_kind   text NOT NULL CHECK (source_kind IN
                  ('ACCOUNT','JOURNAL_LINE','SUBLEDGER_ITEM','DOCUMENT')),
  account_id    uuid REFERENCES account,
  source_ledger_line_id uuid,
  source_document_id    uuid,
  source_row_id text,
  -- 帶正負號而非借貸兩欄：現金流的方向是流入／流出，借貸表示會在
  -- 「同一分類同時有流入與流出」時失去可加性。
  signed_amount_functional numeric(20,2) NOT NULL,
  functional_currency text NOT NULL REFERENCES currency,
  signed_amount_reporting numeric(20,2),
  reporting_currency  text REFERENCES currency,
  evidence_ref  text,
  content_hash  text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK ((signed_amount_reporting IS NULL) = (reporting_currency IS NULL)),
  -- source_kind 的必填引用矩陣。DOCUMENT **允許**同時帶 account_id 作為
  -- 追溯輔助，但映射的權威引用仍是 document。
  CHECK (
    (source_kind = 'ACCOUNT' AND account_id IS NOT NULL AND source_row_id IS NOT NULL
       AND source_ledger_line_id IS NULL AND source_document_id IS NULL)
 OR (source_kind IN ('JOURNAL_LINE','SUBLEDGER_ITEM') AND source_ledger_line_id IS NOT NULL
       AND source_document_id IS NULL)
 OR (source_kind = 'DOCUMENT' AND source_document_id IS NOT NULL
       AND source_ledger_line_id IS NULL))
);
CREATE INDEX cf_fact_idx ON cash_flow_source_fact (period_revision_id, reporting_unit_id);

-- ═══ 6　粒度例外與逐期覆蓋 ═════════════════════════════════════════
CREATE TABLE cash_flow_coverage_exception (
  exception_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  engagement_id uuid NOT NULL REFERENCES client_engagement,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  policy_version_id uuid NOT NULL REFERENCES cash_flow_policy_version,
  -- 逐分類申請：不得「整期粒度不足一次豁免」——那等於取消判定
  cash_flow_class_id uuid NOT NULL REFERENCES cash_flow_class,
  actual_granularity text NOT NULL
    CHECK (actual_granularity IN ('BALANCE','JOURNAL','SUBLEDGER','DOCUMENT')),
  reason        text NOT NULL CHECK (reason <> ''),
  evidence_ref  text NOT NULL CHECK (evidence_ref <> ''),
  approved_by   uuid REFERENCES app_user,
  approved_at   timestamptz,
  created_by    uuid NOT NULL REFERENCES app_user,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
  UNIQUE (period_revision_id, cash_flow_class_id, policy_version_id)
);

CREATE TABLE cash_flow_class_period_coverage (
  coverage_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  policy_version_id uuid NOT NULL REFERENCES cash_flow_policy_version,
  cash_flow_class_id uuid NOT NULL REFERENCES cash_flow_class,
  status        text NOT NULL CHECK (status IN
                  ('DATA_PRESENT','ZERO_ACTIVITY_CONFIRMED','COVERAGE_EXCEPTION')),
  confirmed_by  uuid REFERENCES app_user,
  confirmed_at  timestamptz,
  reviewed_by   uuid REFERENCES app_user,
  reviewed_at   timestamptz,
  evidence_ref  text,
  coverage_exception_id uuid REFERENCES cash_flow_coverage_exception,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (period_revision_id, cash_flow_class_id, policy_version_id),
  -- 零活動需 R2 確認 ＋ R3 覆核 ＋ 理由與證據齊備，三者同時成立才算完整
  CHECK (status <> 'ZERO_ACTIVITY_CONFIRMED' OR (
           confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL
       AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL
       AND evidence_ref IS NOT NULL AND evidence_ref <> '')),
  CHECK (status <> 'COVERAGE_EXCEPTION' OR coverage_exception_id IS NOT NULL)
);

-- ═══ 7　來源選定與首期期初證據 ═════════════════════════════════════
CREATE TABLE cash_flow_opening_balance_set_version (
  opening_set_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  engagement_id uuid NOT NULL REFERENCES client_engagement,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  series_id     uuid NOT NULL,
  version_no    int  NOT NULL CHECK (version_no >= 1),
  supersedes_set_version_id uuid REFERENCES cash_flow_opening_balance_set_version,
  evidence_ref  text NOT NULL CHECK (evidence_ref <> ''),
  approved_by   uuid REFERENCES app_user,
  approved_at   timestamptz,
  created_by    uuid NOT NULL REFERENCES app_user,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
  CHECK ((version_no = 1) = (supersedes_set_version_id IS NULL)),
  UNIQUE (series_id, version_no)
);
CREATE UNIQUE INDEX cf_opening_supersedes_uq
  ON cash_flow_opening_balance_set_version (supersedes_set_version_id)
  WHERE supersedes_set_version_id IS NOT NULL;

CREATE TABLE cash_flow_opening_balance_line (
  opening_line_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  opening_set_version_id uuid NOT NULL
    REFERENCES cash_flow_opening_balance_set_version ON DELETE CASCADE,
  account_id    uuid NOT NULL REFERENCES account,
  functional_amount numeric(20,2) NOT NULL,
  functional_currency text NOT NULL REFERENCES currency,
  reporting_amount numeric(20,2),
  reporting_currency text REFERENCES currency,
  CHECK ((reporting_amount IS NULL) = (reporting_currency IS NULL)),
  UNIQUE (opening_set_version_id, account_id)
);

CREATE TABLE period_cash_flow_source_selection (
  cf_selection_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  engagement_id uuid NOT NULL REFERENCES client_engagement,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  current_run_id uuid NOT NULL REFERENCES calculation_run,
  opening_source_kind text NOT NULL
    CHECK (opening_source_kind IN ('PRIOR_SELECTED_RUN','FIRST_PERIOD_EVIDENCE')),
  prior_run_id  uuid REFERENCES calculation_run,
  opening_balance_set_version_id uuid REFERENCES cash_flow_opening_balance_set_version,
  selection_series_id uuid NOT NULL,
  version_no    int  NOT NULL CHECK (version_no >= 1),
  supersedes_selection_id uuid REFERENCES period_cash_flow_source_selection,
  selected_by   uuid NOT NULL REFERENCES app_user,
  selected_at   timestamptz NOT NULL DEFAULT now(),
  CHECK ((version_no = 1) = (supersedes_selection_id IS NULL)),
  -- 兩個來源欄位恰有一個非空
  CHECK (
    (opening_source_kind = 'PRIOR_SELECTED_RUN' AND prior_run_id IS NOT NULL
       AND opening_balance_set_version_id IS NULL)
 OR (opening_source_kind = 'FIRST_PERIOD_EVIDENCE' AND opening_balance_set_version_id IS NOT NULL
       AND prior_run_id IS NULL)),
  UNIQUE (selection_series_id, version_no)
);
CREATE UNIQUE INDEX cf_source_selection_supersedes_uq
  ON period_cash_flow_source_selection (supersedes_selection_id)
  WHERE supersedes_selection_id IS NOT NULL;

-- ═══ 8　支持資料列：只保存、分類與輸出，不做金額運算 ═══════════════
-- **沒有任何可以放推算結果的欄位**——這一條讓「收集」與「重建」在資料層
-- 就分得開。金額一律自 CashFlowSourceFact 原樣帶出。
CREATE TABLE cash_flow_support_line (
  support_line_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  calculation_run_id uuid NOT NULL REFERENCES calculation_run,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  cash_flow_class_id uuid NOT NULL REFERENCES cash_flow_class,
  kind          text NOT NULL CHECK (kind IN ('ACTIVITY','FX_EFFECT_ON_CASH')),
  activity      text CHECK (activity IN ('OPERATING','INVESTING','FINANCING')),
  source_fact_id uuid NOT NULL REFERENCES cash_flow_source_fact,
  mapping_rule_id uuid NOT NULL REFERENCES cash_flow_mapping_rule,
  signed_amount_functional numeric(20,2) NOT NULL,
  signed_amount_reporting numeric(20,2),
  coverage_exception_id uuid REFERENCES cash_flow_coverage_exception,
  line_no       int NOT NULL,
  CHECK ((kind = 'ACTIVITY') = (activity IS NOT NULL)),
  UNIQUE (calculation_run_id, line_no)
);

-- ═══ 9　calculation_scope 擴充與 manifest 條目 ══════════════════════
ALTER TABLE calculation_input_manifest DROP CONSTRAINT calculation_input_manifest_calculation_scope_check;
ALTER TABLE calculation_input_manifest ADD CONSTRAINT calculation_input_manifest_calculation_scope_check
  CHECK (calculation_scope IN ('NO_FX','FX_TRANSLATION','CASH_FLOW_SUPPORT'));
ALTER TABLE calculation_manifest_entry DROP CONSTRAINT calculation_manifest_entry_object_type_check;
ALTER TABLE calculation_manifest_entry ADD CONSTRAINT calculation_manifest_entry_object_type_check
  CHECK (object_type IN (
    'SCOPE','SOURCE_TB','MAPPING_RULE','ADJUSTMENT','CHART_OF_ACCOUNTS','BASIS_COMPOSITION',
    'CURRENCY_DEFINITION','EXCHANGE_RATE_VERSION','TRANSLATION_POLICY_VERSION',
    'CURRENCY_ASSIGNMENT','EQUITY_TRANSLATION_LOT_SET_VERSION',
    'EQUITY_OPENING_TRANSLATED_BALANCE','ACCOUNT_TRANSLATION_CLASSIFICATION',
    'SOURCE_CALCULATION_RUN',
    'CASH_FLOW_POLICY_VERSION','CASH_FLOW_CLASS_SET_VERSION','CASH_FLOW_MAPPING_VERSION',
    'CASH_FLOW_COVERAGE_EXCEPTION','CASH_FLOW_SOURCE_FACT',
    'CASH_FLOW_OPENING_BALANCE_SET_VERSION','CASH_FLOW_SOURCE_SELECTION'));

-- ═══ 10　RLS 與權限 ════════════════════════════════════════════════
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'cash_flow_class_set_version','cash_flow_class','cash_flow_cash_account_membership',
    'cash_flow_policy_version','cash_flow_mapping_version','cash_flow_mapping_rule',
    'cash_flow_support_dataset','cash_flow_source_fact','cash_flow_coverage_exception',
    'cash_flow_class_period_coverage','cash_flow_opening_balance_set_version',
    'cash_flow_opening_balance_line','period_cash_flow_source_selection',
    'cash_flow_support_line']
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant())', t);
    EXECUTE format('GRANT SELECT ON %I TO app_runtime', t);
  END LOOP;
END $$;
