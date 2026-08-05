-- 0017 02C final hardening（P1-② DB 側）
-- SourceDataset／DataCoverage 的 batch_version 必須等於批次當前版本——
-- 否則「由 Manifest 的 batch ID＋batch_version 定位」可撈到不同版本的 coverage 混入包。
-- （source_document 無 batch_version 欄，僅維持租戶與封存檢查。）

CREATE OR REPLACE FUNCTION fn_source_batch_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  b_tenant uuid; b_status import_batch_status; b_version int; v_version text;
BEGIN
  SELECT tenant_id, status, batch_version INTO b_tenant, b_status, b_version
    FROM import_batch WHERE import_batch_id = NEW.import_batch_id
    FOR UPDATE;
  IF b_tenant IS NULL THEN
    RAISE EXCEPTION '引用的匯入批次不存在（%）', NEW.import_batch_id;
  END IF;
  IF b_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：來源實體與批次不同租戶（INV-18）';
  END IF;
  IF b_status NOT IN ('DRAFT','UPLOADED','VALIDATING') THEN
    RAISE EXCEPTION '來源集合已封存（批次 %）：驗證完成後不得追加來源實體——更正走新批次', b_status;
  END IF;
  v_version := to_jsonb(NEW)->>'batch_version';   -- source_document 無此欄 → NULL，略過
  IF v_version IS NOT NULL AND v_version::int IS DISTINCT FROM b_version THEN
    RAISE EXCEPTION '來源實體版本（%）必須等於批次當前版本（%）——Manifest 依 batch_version 定位',
      v_version, b_version;
  END IF;
  RETURN NEW;
END $$;
