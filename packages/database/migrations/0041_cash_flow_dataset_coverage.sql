-- 0041 用途封套必須指向**該 dataset 自己的** DataCoverage（SLICE-M3-04 收口）
--
-- 0040 的 fact guard 以「整個批次最細的 DataCoverage」取粒度：
--     WHERE dc.import_batch_id = … ORDER BY fn_granularity_rank(...) DESC LIMIT 1
-- 同一批次若同時有 BALANCE 與 DOCUMENT 的 dataset，BALANCE 的 fact 就能**冒用**
-- DOCUMENT 粒度——封套與真實 dataset 因此分離。
-- 改為封套直接引用 DataCoverage，fact 的粒度等於封套所指的那一筆。

ALTER TABLE cash_flow_support_dataset
  ADD COLUMN data_coverage_id uuid REFERENCES data_coverage;
DO $$
BEGIN
  IF (SELECT count(*) FROM cash_flow_support_dataset) = 0 THEN
    ALTER TABLE cash_flow_support_dataset ALTER COLUMN data_coverage_id SET NOT NULL;
  ELSE
    RAISE EXCEPTION 'CF0041_BACKFILL_REQUIRED: 封套已有資料，data_coverage_id 無從推導';
  END IF;
END $$;

CREATE FUNCTION fn_cf_support_dataset_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  ds record; dc record; b record;
BEGIN
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id, NEW.reporting_unit_id,
                                  NULL, NEW.period_revision_id);
  SELECT tenant_id, import_batch_id, granularity, batch_version INTO ds
    FROM source_dataset WHERE source_dataset_id = NEW.source_dataset_id;
  IF ds.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：來源資料集屬於其他租戶（INV-18）';
  END IF;
  IF ds.import_batch_id IS DISTINCT FROM NEW.import_batch_id THEN
    RAISE EXCEPTION 'CFS_DATASET_BATCH_MISMATCH: 封套宣告的批次與底層資料集的批次不同';
  END IF;
  SELECT tenant_id, import_batch_id, granularity, batch_version INTO dc
    FROM data_coverage WHERE data_coverage_id = NEW.data_coverage_id;
  IF dc.tenant_id IS DISTINCT FROM NEW.tenant_id
  OR dc.import_batch_id IS DISTINCT FROM NEW.import_batch_id THEN
    RAISE EXCEPTION 'CFS_COVERAGE_BATCH_MISMATCH: 覆蓋度紀錄不屬本封套的批次';
  END IF;
  IF dc.batch_version IS DISTINCT FROM ds.batch_version THEN
    RAISE EXCEPTION 'CFS_COVERAGE_VERSION_MISMATCH: 覆蓋度與資料集的批次版本不一致';
  END IF;
  -- **這一條就是 0040 的洞**：粒度必須是該 dataset 自己的，不是整批最細的
  IF dc.granularity IS DISTINCT FROM ds.granularity THEN
    RAISE EXCEPTION 'CFS_COVERAGE_GRANULARITY_MISMATCH: 覆蓋度粒度 % 與資料集粒度 % 不一致',
      dc.granularity, ds.granularity;
  END IF;
  SELECT tenant_id, engagement_id, declared_period_revision_id INTO b
    FROM import_batch WHERE import_batch_id = NEW.import_batch_id;
  IF b.tenant_id IS DISTINCT FROM NEW.tenant_id OR b.engagement_id IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：批次不屬本案件';
  END IF;
  IF b.declared_period_revision_id IS DISTINCT FROM NEW.period_revision_id THEN
    RAISE EXCEPTION 'CFS_DATASET_PERIOD_MISMATCH: 批次的宣告期間與封套不一致';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cf_support_dataset BEFORE INSERT ON cash_flow_support_dataset
  FOR EACH ROW EXECUTE FUNCTION fn_cf_support_dataset_guard();

-- 封套建立後不可變：更正走新 dataset
CREATE FUNCTION fn_cf_support_dataset_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'CFS_DATASET_IMMUTABLE: 現金流支持資料集建立後不可 % ——更正請走新的資料集', TG_OP;
END $$;
CREATE TRIGGER trg_cf_support_dataset_immutable
  BEFORE UPDATE OR DELETE ON cash_flow_support_dataset
  FOR EACH ROW EXECUTE FUNCTION fn_cf_support_dataset_immutable();

-- fact 的粒度改為**直接等於封套所指的 DataCoverage**，不再對整批 ORDER BY … LIMIT 1
CREATE OR REPLACE FUNCTION fn_cf_source_fact_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_t uuid; v_b uuid; v_ds_batch uuid; v_ds_gran text;
BEGIN
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id, NEW.reporting_unit_id,
                                  NEW.account_id, NEW.period_revision_id);
  SELECT sd.import_batch_id, dc.granularity INTO v_ds_batch, v_ds_gran
    FROM cash_flow_support_dataset sd
    JOIN data_coverage dc ON dc.data_coverage_id = sd.data_coverage_id
   WHERE sd.source_dataset_id = NEW.source_dataset_id AND sd.tenant_id = NEW.tenant_id
     AND sd.engagement_id = NEW.engagement_id AND sd.period_revision_id = NEW.period_revision_id
     AND sd.reporting_unit_id = NEW.reporting_unit_id;
  IF v_ds_batch IS NULL THEN
    RAISE EXCEPTION 'CFS_DATASET_NOT_SUPPORT_PURPOSE: 引用的資料集不是現金流支持資料集，或父鏈不一致';
  END IF;
  IF v_ds_batch IS DISTINCT FROM NEW.import_batch_id THEN
    RAISE EXCEPTION 'CFS_FACT_BATCH_MISMATCH: fact 的批次與其資料集的批次不一致';
  END IF;
  IF v_ds_gran IS DISTINCT FROM NEW.actual_granularity THEN
    RAISE EXCEPTION 'CFS_GRANULARITY_MISDECLARED: fact 宣告 %，該資料集的 DataCoverage 為 %',
      NEW.actual_granularity, v_ds_gran;
  END IF;
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
