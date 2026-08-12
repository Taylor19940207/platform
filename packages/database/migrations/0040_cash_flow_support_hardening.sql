-- 0040 現金流支持資料：結構收口（SLICE-M3-04 走查後追加，不回改 0039）
--
-- 三個結構缺口：
--   1. `source_ledger_line_id` 實際是 **bigint**，0039 寫成 uuid，且兩個來源引用
--      **都沒有真正的外鍵**——「具體外鍵」因此只停留在契約文字。
--   2. 零活動缺 `reason` 欄位；`content_hash` 可空，不可變資料能在沒有內容證據
--      的情況下建立。
--   3. `calculation_run.import_batch_id` 是 NOT NULL，但一期的現金流支持資料
--      可能來自**多個**已接受批次；任選一個填入，run 的來源歸屬就會說謊。

-- ═══ 1　來源引用：正確型別與真正的外鍵 ═════════════════════════════
ALTER TABLE cash_flow_mapping_rule DROP CONSTRAINT cash_flow_mapping_rule_check;
ALTER TABLE cash_flow_mapping_rule
  DROP COLUMN source_ledger_line_id,
  DROP COLUMN source_document_id,
  ADD COLUMN source_ledger_line_id bigint REFERENCES source_ledger_line,
  ADD COLUMN source_document_id    uuid   REFERENCES source_document;
ALTER TABLE cash_flow_mapping_rule ADD CONSTRAINT cash_flow_mapping_rule_source_ck CHECK (
    (source_kind = 'ACCOUNT' AND account_id IS NOT NULL
       AND source_ledger_line_id IS NULL AND source_document_id IS NULL)
 OR (source_kind IN ('JOURNAL_LINE','SUBLEDGER_ITEM') AND source_ledger_line_id IS NOT NULL
       AND source_document_id IS NULL)
 OR (source_kind = 'DOCUMENT' AND source_document_id IS NOT NULL
       AND source_ledger_line_id IS NULL));

ALTER TABLE cash_flow_source_fact DROP CONSTRAINT cash_flow_source_fact_check1;
ALTER TABLE cash_flow_source_fact
  DROP COLUMN source_ledger_line_id,
  DROP COLUMN source_document_id,
  ADD COLUMN source_ledger_line_id bigint REFERENCES source_ledger_line,
  ADD COLUMN source_document_id    uuid   REFERENCES source_document;
-- source_kind 的必填引用矩陣。DOCUMENT **允許**同時帶 account_id 作為追溯輔助，
-- 但映射的權威引用仍是 document。
ALTER TABLE cash_flow_source_fact ADD CONSTRAINT cash_flow_source_fact_source_ck CHECK (
    (source_kind = 'ACCOUNT' AND account_id IS NOT NULL AND source_row_id IS NOT NULL
       AND source_ledger_line_id IS NULL AND source_document_id IS NULL)
 OR (source_kind IN ('JOURNAL_LINE','SUBLEDGER_ITEM') AND source_ledger_line_id IS NOT NULL
       AND source_document_id IS NULL)
 OR (source_kind = 'DOCUMENT' AND source_document_id IS NOT NULL
       AND source_ledger_line_id IS NULL));

-- 父鏈：引用的來源列／文件必須同租戶，且屬於本 fact 宣告的批次
CREATE FUNCTION fn_cf_source_fact_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_t uuid; v_b uuid; v_ds_batch uuid; v_ds_gran text; v_status import_batch_status;
BEGIN
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id, NEW.reporting_unit_id,
                                  NEW.account_id, NEW.period_revision_id);
  -- 封套：dataset 必須是**現金流支持資料集**，且父鏈一致
  SELECT import_batch_id INTO v_ds_batch FROM cash_flow_support_dataset
   WHERE source_dataset_id = NEW.source_dataset_id AND tenant_id = NEW.tenant_id
     AND engagement_id = NEW.engagement_id AND period_revision_id = NEW.period_revision_id
     AND reporting_unit_id = NEW.reporting_unit_id;
  IF v_ds_batch IS NULL THEN
    RAISE EXCEPTION 'CFS_DATASET_NOT_SUPPORT_PURPOSE: 引用的資料集不是現金流支持資料集，或父鏈不一致';
  END IF;
  IF v_ds_batch IS DISTINCT FROM NEW.import_batch_id THEN
    RAISE EXCEPTION 'CFS_FACT_BATCH_MISMATCH: fact 的批次與其資料集的批次不一致';
  END IF;
  -- actual_granularity 必須等於該資料集的 DataCoverage（不得逐列自填）
  SELECT granularity INTO v_ds_gran FROM data_coverage dc
    JOIN import_batch ib ON ib.import_batch_id = dc.import_batch_id
                        AND ib.batch_version = dc.batch_version
   WHERE dc.import_batch_id = NEW.import_batch_id
   ORDER BY fn_granularity_rank(dc.granularity) DESC LIMIT 1;
  IF v_ds_gran IS DISTINCT FROM NEW.actual_granularity THEN
    RAISE EXCEPTION 'CFS_GRANULARITY_MISDECLARED: fact 宣告 %，該資料集的 DataCoverage 為 %',
      NEW.actual_granularity, COALESCE(v_ds_gran, '（無）');
  END IF;
  -- source_kind 與實際粒度必須相容
  IF NOT fn_granularity_satisfies(NEW.actual_granularity,
                                  fn_source_kind_granularity(NEW.source_kind)) THEN
    RAISE EXCEPTION 'CFS_SOURCE_KIND_GRANULARITY: % 需要至少 % 粒度，實際為 %',
      NEW.source_kind, fn_source_kind_granularity(NEW.source_kind), NEW.actual_granularity;
  END IF;
  IF NEW.source_ledger_line_id IS NOT NULL THEN
    SELECT tenant_id, import_batch_id INTO v_t, v_b FROM source_ledger_line
     WHERE source_ledger_line_id = NEW.source_ledger_line_id;
    IF v_t IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION '歸屬違規：引用的來源列屬於其他租戶（INV-18）';
    END IF;
    IF v_b IS DISTINCT FROM NEW.import_batch_id THEN
      RAISE EXCEPTION 'CFS_FACT_SOURCE_BATCH_MISMATCH: 引用的來源列不屬本 fact 的批次';
    END IF;
  END IF;
  IF NEW.source_document_id IS NOT NULL THEN
    SELECT tenant_id, import_batch_id INTO v_t, v_b FROM source_document
     WHERE source_document_id = NEW.source_document_id;
    IF v_t IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION '歸屬違規：引用的來源文件屬於其他租戶（INV-18）';
    END IF;
    IF v_b IS DISTINCT FROM NEW.import_batch_id THEN
      RAISE EXCEPTION 'CFS_FACT_SOURCE_BATCH_MISMATCH: 引用的來源文件不屬本 fact 的批次';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cf_source_fact BEFORE INSERT ON cash_flow_source_fact
  FOR EACH ROW EXECUTE FUNCTION fn_cf_source_fact_guard();

-- fact 建立後不可變：更正走新批次與新 dataset（與 SourceLedgerLine 同一原則）
CREATE FUNCTION fn_cf_fact_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'CFS_FACT_IMMUTABLE: 現金流金額事實建立後不可 % ——更正請走新批次與新資料集', TG_OP;
END $$;
CREATE TRIGGER trg_cf_fact_immutable BEFORE UPDATE OR DELETE ON cash_flow_source_fact
  FOR EACH ROW EXECUTE FUNCTION fn_cf_fact_immutable();

-- ═══ 2　零活動的理由欄位；內容雜湊必填 ═════════════════════════════
ALTER TABLE cash_flow_class_period_coverage ADD COLUMN reason text;
ALTER TABLE cash_flow_class_period_coverage DROP CONSTRAINT cash_flow_class_period_coverage_check;
ALTER TABLE cash_flow_class_period_coverage ADD CONSTRAINT cf_coverage_zero_activity_ck CHECK (
  status <> 'ZERO_ACTIVITY_CONFIRMED' OR (
       confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL
   AND reviewed_by  IS NOT NULL AND reviewed_at  IS NOT NULL
   AND reason IS NOT NULL AND reason <> ''
   AND evidence_ref IS NOT NULL AND evidence_ref <> ''));

-- 不可變資料不得在沒有內容證據的情況下建立
ALTER TABLE cash_flow_support_dataset ALTER COLUMN content_hash SET NOT NULL;
ALTER TABLE cash_flow_source_fact     ALTER COLUMN content_hash SET NOT NULL;

-- ═══ 3　一個 run 可以有多個來源批次 ════════════════════════════════
-- 一期的現金流支持資料可能來自多個已接受批次。任選一個填進 import_batch_id，
-- run 的來源歸屬就會說謊；而「全部資料一定在一個檔案」不是可以預設的事。
CREATE TABLE calculation_run_source_batch (
  calculation_run_id uuid NOT NULL REFERENCES calculation_run ON DELETE CASCADE,
  import_batch_id    uuid NOT NULL REFERENCES import_batch,
  tenant_id          uuid NOT NULL REFERENCES tenant,
  PRIMARY KEY (calculation_run_id, import_batch_id)
);
ALTER TABLE calculation_run_source_batch ENABLE ROW LEVEL SECURITY;
ALTER TABLE calculation_run_source_batch FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON calculation_run_source_batch
  USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant());
GRANT SELECT ON calculation_run_source_batch TO app_runtime;

-- bridge 的每個批次都要 ACCEPTED，且與 run 同租戶／案件／期間
CREATE FUNCTION fn_run_source_batch_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r record; b record;
BEGIN
  SELECT tenant_id, engagement_id, period_revision_id INTO r
    FROM calculation_run WHERE calculation_run_id = NEW.calculation_run_id;
  IF r.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：來源批次橋接與 run 不同租戶（INV-18）';
  END IF;
  SELECT tenant_id, engagement_id, declared_period_revision_id, status INTO b
    FROM import_batch WHERE import_batch_id = NEW.import_batch_id;
  IF b.tenant_id IS DISTINCT FROM r.tenant_id OR b.engagement_id IS DISTINCT FROM r.engagement_id THEN
    RAISE EXCEPTION '§24.1A：來源批次不屬本案件';
  END IF;
  IF b.declared_period_revision_id IS DISTINCT FROM r.period_revision_id THEN
    RAISE EXCEPTION 'CFS_BATCH_PERIOD_MISMATCH: 來源批次的宣告期間與 run 不一致';
  END IF;
  IF b.status <> 'ACCEPTED' THEN
    RAISE EXCEPTION 'CFS_BATCH_NOT_ACCEPTED: 來源批次尚未接受（目前 %）——未接受的批次不得參與判定或輸出', b.status;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_run_source_batch BEFORE INSERT ON calculation_run_source_batch
  FOR EACH ROW EXECUTE FUNCTION fn_run_source_batch_guard();

-- calculation_run.import_batch_id 只對 CASH_FLOW_SUPPORT 放寬為可空。
-- **NO_FX／FX_TRANSLATION 的既有行為完全不變**。
ALTER TABLE calculation_run ALTER COLUMN import_batch_id DROP NOT NULL;

CREATE OR REPLACE FUNCTION fn_calculation_run_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_mani uuid; v_tenant uuid;
  m_tenant uuid; m_eng uuid; m_pr uuid; m_scope text;
  b_tenant uuid; b_eng uuid; b_pr uuid;
  p_eng uuid; p_tenant uuid; u_tenant uuid;
BEGIN
  IF NEW.status <> 'RUNNING' THEN
    RAISE EXCEPTION 'Run 建立時必須為 RUNNING（結果狀態由執行交易寫入）';
  END IF;
  IF NEW.result_content_hash IS NOT NULL OR NEW.failure_reason_code IS NOT NULL
     OR NEW.failure_reason IS NOT NULL OR NEW.completed_at IS NOT NULL
     OR NEW.failed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Run 建立時不得預填結果或終態欄位（終態欄位互斥）';
  END IF;
  SELECT tenant_id, engagement_id, period_revision_id, calculation_scope
    INTO m_tenant, m_eng, m_pr, m_scope
    FROM calculation_input_manifest WHERE manifest_id = NEW.manifest_id FOR UPDATE;
  IF m_tenant IS DISTINCT FROM NEW.tenant_id OR m_eng IS DISTINCT FROM NEW.engagement_id
     OR m_pr IS DISTINCT FROM NEW.period_revision_id THEN
    RAISE EXCEPTION '歸屬違規：Run 與 Manifest 的租戶／案件／期間不一致（§24.1A）';
  END IF;
  SELECT rp.engagement_id, pr.tenant_id INTO p_eng, p_tenant
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = NEW.period_revision_id;
  IF p_eng IS DISTINCT FROM NEW.engagement_id OR p_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：Run 的期間不屬於本案件（§24.1A）';
  END IF;

  -- **只對 CASH_FLOW_SUPPORT 開新分支**：單一批次欄位可空，來源以 bridge 凍結。
  -- NO_FX／FX_TRANSLATION 維持原本的單一批次要求，不得放寬。
  IF m_scope = 'CASH_FLOW_SUPPORT' THEN
    IF NEW.import_batch_id IS NOT NULL THEN
      RAISE EXCEPTION 'CFS_RUN_SINGLE_BATCH_NOT_ALLOWED: 現金流支持 run 的來源批次以 calculation_run_source_batch 凍結，不得填單一批次';
    END IF;
  ELSE
    IF NEW.import_batch_id IS NULL THEN
      RAISE EXCEPTION '歸屬違規：Run 必須指明來源批次（§24.1A）';
    END IF;
    SELECT tenant_id, engagement_id, declared_period_revision_id INTO b_tenant, b_eng, b_pr
      FROM import_batch WHERE import_batch_id = NEW.import_batch_id;
    IF b_tenant IS DISTINCT FROM NEW.tenant_id OR b_eng IS DISTINCT FROM NEW.engagement_id THEN
      RAISE EXCEPTION '歸屬違規：Run 與來源批次的租戶／案件不一致（§24.1A）';
    END IF;
    IF b_pr IS DISTINCT FROM NEW.period_revision_id THEN
      RAISE EXCEPTION '歸屬違規：Run 期間與批次宣告期間不一致（§24.1A）';
    END IF;
  END IF;

  SELECT tenant_id INTO u_tenant FROM app_user WHERE user_id = NEW.created_by;
  IF u_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：建立者不屬於本租戶（INV-18）';
  END IF;
  IF NEW.replay_of_run_id IS NOT NULL THEN
    SELECT manifest_id, tenant_id INTO v_mani, v_tenant
      FROM calculation_run WHERE calculation_run_id = NEW.replay_of_run_id;
    IF v_mani IS NULL THEN
      RAISE EXCEPTION 'replay 引用的原 run 不存在（%）', NEW.replay_of_run_id;
    END IF;
    IF v_mani <> NEW.manifest_id OR v_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'replay 必須引用同一份 Manifest 且同租戶';
    END IF;
  END IF;
  RETURN NEW;
END $$;
