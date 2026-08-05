-- 0015 預覽證據包（SLICE-M2-02C）
-- 契約：docs/slices/SLICE-M2-02C_預覽證據包.md（含實作契約 A～D）
--   A. 三態：GENERATING（內容全空）→ READY（齊備才可下載）／FAILED（帶代碼不帶 artifact）
--      不可變語意＝身分欄位不可變、受控終態遷移、終態不可變。
--   C. 來源實體不可變前提補齊：SourceDataset／DataCoverage／SourceDocument
--      補 UPDATE/DELETE 禁止與 tenant×ImportBatch 歸屬守衛（宣稱與現況對齊）。

CREATE TYPE evidence_package_status AS ENUM ('GENERATING','READY','FAILED');

CREATE TABLE evidence_package (
  package_id          uuid PRIMARY KEY,
  tenant_id           uuid NOT NULL REFERENCES tenant,
  engagement_id       uuid NOT NULL REFERENCES client_engagement,
  calculation_run_id  uuid NOT NULL REFERENCES calculation_run,
  regenerated_from_id uuid REFERENCES evidence_package,   -- 明示重產關係；原包永久保留
  status              evidence_package_status NOT NULL DEFAULT 'GENERATING',
  request_key         uuid NOT NULL,
  request_content_hash text NOT NULL,
  -- 時間軸截止點：該 run 的 calculation_run.completed 事件；包自身事件不入自身 hash
  audit_cutoff_event_id bigint NOT NULL,
  render_version      text NOT NULL,
  -- READY 齊備欄位（GENERATING 期間全空——互斥守衛）
  package_content_hash text,
  artifact_object_key  text,
  artifact_sha256      text,
  artifact_mime_type   text,
  artifact_byte_size   bigint,
  -- FAILED
  failure_reason_code  text,
  failure_reason       text,
  created_by          uuid NOT NULL REFERENCES app_user,
  created_at          timestamptz NOT NULL DEFAULT now(),
  completed_at        timestamptz,
  failed_at           timestamptz,
  UNIQUE (tenant_id, request_key)
);
CREATE INDEX evidence_package_run_idx ON evidence_package (calculation_run_id, created_at);

CREATE TABLE evidence_package_index (
  index_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id   uuid NOT NULL REFERENCES tenant,
  package_id  uuid NOT NULL REFERENCES evidence_package,
  section     text NOT NULL,
  item_count  int  NOT NULL,
  content_hash text NOT NULL,
  UNIQUE (package_id, section)
);
CREATE TRIGGER trg_epi_immutable
  BEFORE UPDATE OR DELETE ON evidence_package_index
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

CREATE FUNCTION fn_evidence_package_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  r_tenant uuid; r_eng uuid; r_status calculation_run_status;
  g_run uuid; g_tenant uuid; u_tenant uuid; n int;
BEGIN
  IF NEW.status <> 'GENERATING' THEN
    RAISE EXCEPTION 'Package 建立時必須為 GENERATING（權威內容與終態由 worker 寫入）';
  END IF;
  IF NEW.package_content_hash IS NOT NULL OR NEW.artifact_object_key IS NOT NULL
     OR NEW.artifact_sha256 IS NOT NULL OR NEW.artifact_mime_type IS NOT NULL
     OR NEW.artifact_byte_size IS NOT NULL OR NEW.failure_reason_code IS NOT NULL
     OR NEW.failure_reason IS NOT NULL OR NEW.completed_at IS NOT NULL
     OR NEW.failed_at IS NOT NULL THEN
    RAISE EXCEPTION 'GENERATING 內容欄位必須全空（契約 A 互斥）';
  END IF;
  SELECT tenant_id, engagement_id, status INTO r_tenant, r_eng, r_status
    FROM calculation_run WHERE calculation_run_id = NEW.calculation_run_id;
  IF r_tenant IS NULL THEN
    RAISE EXCEPTION 'Package 引用的 Run 不存在（%）', NEW.calculation_run_id;
  END IF;
  IF r_tenant IS DISTINCT FROM NEW.tenant_id OR r_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '歸屬違規：Package 與 Run 的租戶／案件不一致（§24.1A）';
  END IF;
  IF r_status <> 'COMPLETED' THEN
    RAISE EXCEPTION 'RUN_NOT_COMPLETED：只有 COMPLETED 的 PREVIEW run 可產包（目前 %）', r_status;
  END IF;
  SELECT tenant_id INTO u_tenant FROM app_user WHERE user_id = NEW.created_by;
  IF u_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：建立者不屬於本租戶（INV-18）';
  END IF;
  IF NEW.regenerated_from_id IS NOT NULL THEN
    SELECT calculation_run_id, tenant_id INTO g_run, g_tenant
      FROM evidence_package WHERE package_id = NEW.regenerated_from_id;
    IF g_run IS NULL OR g_run <> NEW.calculation_run_id OR g_tenant <> NEW.tenant_id THEN
      RAISE EXCEPTION '重產必須引用同一 run 的既有 Package（原包永久保留）';
    END IF;
  END IF;
  -- 契約 D-4（建立端先驗）：cutoff 事件必須恰為該 run 的 completed 事件
  SELECT count(*) INTO n FROM audit_event
   WHERE audit_event_id = NEW.audit_cutoff_event_id
     AND event_type = 'calculation_run.completed'
     AND object_id = NEW.calculation_run_id
     AND tenant_id = NEW.tenant_id;
  IF n <> 1 THEN
    RAISE EXCEPTION 'audit_cutoff_event_id 必須是該 run 的 calculation_run.completed 事件';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_ep_insert
  BEFORE INSERT ON evidence_package
  FOR EACH ROW EXECUTE FUNCTION fn_evidence_package_insert_guard();

CREATE FUNCTION fn_evidence_package_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'EvidencePackage 不可刪除（原包永久保留，不入 SUPERSEDED 鏈）';
  END IF;
  IF NEW.calculation_run_id IS DISTINCT FROM OLD.calculation_run_id
  OR NEW.regenerated_from_id IS DISTINCT FROM OLD.regenerated_from_id
  OR NEW.request_key IS DISTINCT FROM OLD.request_key
  OR NEW.request_content_hash IS DISTINCT FROM OLD.request_content_hash
  OR NEW.audit_cutoff_event_id IS DISTINCT FROM OLD.audit_cutoff_event_id
  OR NEW.render_version IS DISTINCT FROM OLD.render_version
  OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
  OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
  OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
    RAISE EXCEPTION 'Package 身分欄位建立後不可變更';
  END IF;
  IF OLD.status IN ('READY','FAILED') THEN
    RAISE EXCEPTION 'Package 終態（%）不可修改——重產＝新 package（regenerated_from_id）', OLD.status;
  END IF;
  IF NEW.status = 'GENERATING' THEN
    IF NEW.package_content_hash IS NOT NULL OR NEW.artifact_object_key IS NOT NULL
       OR NEW.artifact_sha256 IS NOT NULL OR NEW.failure_reason_code IS NOT NULL
       OR NEW.failure_reason IS NOT NULL THEN
      RAISE EXCEPTION 'GENERATING 內容欄位必須全空（契約 A 互斥；重試期間維持 GENERATING）';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.status = 'READY' THEN
    IF COALESCE(NEW.package_content_hash,'') = '' OR COALESCE(NEW.artifact_object_key,'') = ''
       OR COALESCE(NEW.artifact_sha256,'') = '' OR COALESCE(NEW.artifact_mime_type,'') = ''
       OR NEW.artifact_byte_size IS NULL THEN
      RAISE EXCEPTION 'READY 必須齊備 artifact 與內容 hash（契約 A）';
    END IF;
    IF NEW.failure_reason_code IS NOT NULL OR NEW.failure_reason IS NOT NULL
       OR NEW.failed_at IS NOT NULL THEN
      RAISE EXCEPTION '終態欄位互斥：READY 不得帶失敗欄位';
    END IF;
    NEW.completed_at := COALESCE(NEW.completed_at, now());
    RETURN NEW;
  END IF;
  IF NEW.status = 'FAILED' THEN
    IF COALESCE(NEW.failure_reason_code,'') = '' OR COALESCE(NEW.failure_reason,'') = '' THEN
      RAISE EXCEPTION 'FAILED 必須帶機器代碼與客戶可理解原因';
    END IF;
    IF NEW.package_content_hash IS NOT NULL OR NEW.artifact_object_key IS NOT NULL
       OR NEW.artifact_sha256 IS NOT NULL THEN
      RAISE EXCEPTION '終態欄位互斥：FAILED 不得帶 artifact（契約 A）';
    END IF;
    NEW.failed_at := COALESCE(NEW.failed_at, now());
    RETURN NEW;
  END IF;
  RAISE EXCEPTION '非法 Package 狀態遷移 % → %', OLD.status, NEW.status;
END $$;
CREATE TRIGGER trg_ep_guard
  BEFORE UPDATE OR DELETE ON evidence_package
  FOR EACH ROW EXECUTE FUNCTION fn_evidence_package_guard();

-- 索引：只能寫入 GENERATING 的 Package（鎖父列；終態後索引封存）
CREATE FUNCTION fn_epi_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_tenant uuid; v_status evidence_package_status;
BEGIN
  SELECT tenant_id, status INTO v_tenant, v_status
    FROM evidence_package WHERE package_id = NEW.package_id
    FOR UPDATE;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION '索引引用的 Package 不存在（%）', NEW.package_id;
  END IF;
  IF v_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：索引與 Package 不同租戶（INV-18）';
  END IF;
  IF v_status <> 'GENERATING' THEN
    RAISE EXCEPTION 'Package 已終態（%），索引已封存不得追加', v_status;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_epi_insert
  BEFORE INSERT ON evidence_package_index
  FOR EACH ROW EXECUTE FUNCTION fn_epi_insert_guard();

-- ── BackgroundJob 擴充 ──
ALTER TABLE background_job DROP CONSTRAINT background_job_job_type_check;
ALTER TABLE background_job ADD CONSTRAINT background_job_job_type_check
  CHECK (job_type IN ('IMPORT_VALIDATION','CALCULATION_RUN','EVIDENCE_PACKAGE'));

CREATE OR REPLACE FUNCTION fn_background_job_tenant_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_tenant uuid;
BEGIN
  IF NEW.job_type = 'IMPORT_VALIDATION' THEN
    SELECT tenant_id INTO v_tenant FROM import_batch WHERE import_batch_id = NEW.subject_id;
  ELSIF NEW.job_type = 'CALCULATION_RUN' THEN
    SELECT tenant_id INTO v_tenant FROM calculation_run WHERE calculation_run_id = NEW.subject_id;
  ELSIF NEW.job_type = 'EVIDENCE_PACKAGE' THEN
    SELECT tenant_id INTO v_tenant FROM evidence_package WHERE package_id = NEW.subject_id;
  END IF;
  IF v_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：工作主體（% %）不屬於本租戶', NEW.job_type, NEW.subject_id;
  END IF;
  RETURN NEW;
END $$;

-- ── 契約 C：來源實體不可變前提補齊 ──
CREATE TRIGGER trg_sds_immutable
  BEFORE UPDATE OR DELETE ON source_dataset
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();
CREATE TRIGGER trg_dcov_immutable
  BEFORE UPDATE OR DELETE ON data_coverage
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();
CREATE TRIGGER trg_sdoc_immutable
  BEFORE UPDATE OR DELETE ON source_document
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

CREATE FUNCTION fn_source_batch_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  b_tenant uuid;
BEGIN
  SELECT tenant_id INTO b_tenant FROM import_batch WHERE import_batch_id = NEW.import_batch_id;
  IF b_tenant IS NULL THEN
    RAISE EXCEPTION '引用的匯入批次不存在（%）', NEW.import_batch_id;
  END IF;
  IF b_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：來源實體與批次不同租戶（INV-18）';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_sds_batch BEFORE INSERT ON source_dataset
  FOR EACH ROW EXECUTE FUNCTION fn_source_batch_guard();
CREATE TRIGGER trg_dcov_batch BEFORE INSERT ON data_coverage
  FOR EACH ROW EXECUTE FUNCTION fn_source_batch_guard();
CREATE TRIGGER trg_sdoc_batch BEFORE INSERT ON source_document
  FOR EACH ROW EXECUTE FUNCTION fn_source_batch_guard();

-- ── RLS ──
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['evidence_package','evidence_package_index'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant())', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO app_runtime', t);
  END LOOP;
END $$;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_runtime;
