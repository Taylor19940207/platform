-- 0012 PREVIEW CalculationRun 與輸入凍結（SLICE-M2-02B）
-- 契約：docs/slices/SLICE-M2-02B_PREVIEW_CalculationRun與輸入凍結.md
-- 基線：§25.3（run 不可修改）、§26.9（Manifest 不可變、三層版本）、INV-17／29、
--       §25.9（PREVIEW 無正式交付能力）、§27.4／27.5（非同步與決定性）。
--
-- 護欄（走查定稿）：
--   1. Manifest 與 Run 分離：一份 Manifest 由唯一的原始 Run 建立（partial unique），
--      replay Run 以 replay_of_run_id 引用同一份——無隱含一對一。
--   2. 終態語意：COMPLETED 需 result_content_hash；FAILED 需機器代碼＋人可讀原因；
--      終態列不可再修改。SUPERSEDED 本刀不使用（§25.11 語意保留）。
--   3. 不為 PREVIEW 偷建任何交付實體：run_type 僅 'PREVIEW'（CHECK）。

CREATE TYPE calculation_run_status AS ENUM ('RUNNING','COMPLETED','FAILED','SUPERSEDED');

-- ── Manifest：不可變。frozen_set_content_hash 只涵蓋計算輸入（entries），
--    不含 run_id／建立者／時間（稽核 metadata 另存於欄位，不入 hash）。
CREATE TABLE calculation_input_manifest (
  manifest_id        uuid PRIMARY KEY,
  tenant_id          uuid NOT NULL REFERENCES tenant,
  engagement_id      uuid NOT NULL REFERENCES client_engagement,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  calculation_scope  text NOT NULL CHECK (calculation_scope = 'NO_FX'),
  hash_algorithm     text NOT NULL DEFAULT 'sha256',
  canonicalization_version text NOT NULL,
  frozen_set_content_hash  text NOT NULL,
  created_by         uuid NOT NULL REFERENCES app_user,
  created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_cim_immutable
  BEFORE UPDATE OR DELETE ON calculation_input_manifest
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

-- entry：三種版本語意分開保存（§26.9）。不可變事實 concurrency_version 為 NULL，
-- 完整性依 content_hash。payload 為凍結內容本體（計算只讀這裡）。
CREATE TABLE calculation_manifest_entry (
  entry_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id          uuid NOT NULL REFERENCES tenant,
  manifest_id        uuid NOT NULL REFERENCES calculation_input_manifest,
  object_type        text NOT NULL CHECK (object_type IN
                       ('SCOPE','SOURCE_TB','MAPPING_RULE','ADJUSTMENT','CHART_OF_ACCOUNTS')),
  object_id          uuid,
  concurrency_version int,
  domain_version_kind  text NOT NULL,
  domain_version_value text NOT NULL,
  content_canonical  text NOT NULL,
  content_hash       text NOT NULL,
  payload            jsonb NOT NULL
);
CREATE TRIGGER trg_cme_immutable
  BEFORE UPDATE OR DELETE ON calculation_manifest_entry
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();
CREATE INDEX cme_manifest_idx ON calculation_manifest_entry (manifest_id);

-- ── CalculationRun（§25.3 四狀態不增不減；細粒度執行進度以 BackgroundJob 為權威） ──
CREATE TABLE calculation_run (
  calculation_run_id uuid PRIMARY KEY,
  tenant_id          uuid NOT NULL REFERENCES tenant,
  engagement_id      uuid NOT NULL REFERENCES client_engagement,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  import_batch_id    uuid NOT NULL REFERENCES import_batch,
  manifest_id        uuid NOT NULL REFERENCES calculation_input_manifest,
  run_type           text NOT NULL CHECK (run_type = 'PREVIEW'),
  status             calculation_run_status NOT NULL DEFAULT 'RUNNING',
  replay_of_run_id   uuid REFERENCES calculation_run,
  -- 冪等契約（建立端點層）：同 key 同內容→原 run；同 key 異內容→409（應用層比對）
  request_key        uuid NOT NULL UNIQUE,
  request_content_hash text NOT NULL,
  result_content_hash  text,          -- canonical 結果 hash（排除 run_id／時間戳）
  failure_reason_code  text,          -- 機器代碼（REPLAY_FAILED 等）
  failure_reason       text,          -- 客戶可理解原因
  engine_version     text NOT NULL,
  created_by         uuid NOT NULL REFERENCES app_user,
  created_at         timestamptz NOT NULL DEFAULT now(),
  completed_at       timestamptz,
  failed_at          timestamptz
);
-- 一份 Manifest 恰有一個原始建立 Run；replay 不受限
CREATE UNIQUE INDEX calc_run_manifest_origin_uq
  ON calculation_run (manifest_id) WHERE replay_of_run_id IS NULL;
CREATE INDEX calc_run_batch_idx ON calculation_run (import_batch_id, created_at);

CREATE FUNCTION fn_calculation_run_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_mani uuid; v_tenant uuid;
BEGIN
  IF NEW.status <> 'RUNNING' THEN
    RAISE EXCEPTION 'Run 建立時必須為 RUNNING（結果狀態由執行交易寫入）';
  END IF;
  IF NEW.replay_of_run_id IS NOT NULL THEN
    SELECT manifest_id, tenant_id INTO v_mani, v_tenant
      FROM calculation_run WHERE calculation_run_id = NEW.replay_of_run_id;
    IF v_mani IS NULL THEN
      RAISE EXCEPTION 'replay 引用的原 run 不存在（%）', NEW.replay_of_run_id;
    END IF;
    IF v_mani <> NEW.manifest_id OR v_tenant <> NEW.tenant_id THEN
      RAISE EXCEPTION 'replay 必須引用原 run 的同一份 Manifest（原 % ≠ 新 %）', v_mani, NEW.manifest_id;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_calc_run_insert
  BEFORE INSERT ON calculation_run
  FOR EACH ROW EXECUTE FUNCTION fn_calculation_run_insert_guard();

CREATE FUNCTION fn_calculation_run_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'CalculationRun 不可刪除（§25.3：任何輸入變動都產生新的 run）';
  END IF;
  -- 身分欄位建立後凍結
  IF NEW.manifest_id IS DISTINCT FROM OLD.manifest_id
  OR NEW.replay_of_run_id IS DISTINCT FROM OLD.replay_of_run_id
  OR NEW.request_key IS DISTINCT FROM OLD.request_key
  OR NEW.request_content_hash IS DISTINCT FROM OLD.request_content_hash
  OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
  OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
  OR NEW.period_revision_id IS DISTINCT FROM OLD.period_revision_id
  OR NEW.import_batch_id IS DISTINCT FROM OLD.import_batch_id
  OR NEW.run_type IS DISTINCT FROM OLD.run_type
  OR NEW.engine_version IS DISTINCT FROM OLD.engine_version
  OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
    RAISE EXCEPTION 'CalculationRun 身分欄位建立後不可變更';
  END IF;
  IF OLD.status IN ('COMPLETED','FAILED','SUPERSEDED') THEN
    RAISE EXCEPTION 'CalculationRun 終態（%）不可修改——重演＝建立新 run', OLD.status;
  END IF;
  IF NEW.status = 'SUPERSEDED' THEN
    RAISE EXCEPTION 'SUPERSEDED 本刀不使用（§25.11 下游失效鏈，語意保留）';
  END IF;
  IF NEW.status NOT IN ('RUNNING','COMPLETED','FAILED') THEN
    RAISE EXCEPTION '非法 Run 狀態遷移 % → %', OLD.status, NEW.status;
  END IF;
  IF NEW.status = 'COMPLETED' THEN
    IF COALESCE(NEW.result_content_hash,'') = '' THEN
      RAISE EXCEPTION 'COMPLETED 必須帶 result_content_hash（INV-17）';
    END IF;
    NEW.completed_at := COALESCE(NEW.completed_at, now());
  END IF;
  IF NEW.status = 'FAILED' THEN
    IF COALESCE(NEW.failure_reason_code,'') = '' OR COALESCE(NEW.failure_reason,'') = '' THEN
      RAISE EXCEPTION 'FAILED 必須帶機器代碼與客戶可理解原因';
    END IF;
    NEW.failed_at := COALESCE(NEW.failed_at, now());
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_calc_run_guard
  BEFORE UPDATE OR DELETE ON calculation_run
  FOR EACH ROW EXECUTE FUNCTION fn_calculation_run_guard();

-- ── 快照輸出（§26.6 BalanceSnapshotLine 最小切片；不可變；run 內（層×科目）唯一） ──
CREATE TABLE balance_snapshot_line (
  snapshot_line_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id          uuid NOT NULL REFERENCES tenant,
  calculation_run_id uuid NOT NULL REFERENCES calculation_run,
  posting_layer      text NOT NULL CHECK (posting_layer IN ('SOURCE_TB','ADJUSTMENT')),
  account_id         uuid NOT NULL,
  account_code       text NOT NULL,     -- 凍結快照（來自 manifest，不回查 account 表）
  account_name       text NOT NULL,
  debit              numeric(20,2) NOT NULL DEFAULT 0,
  credit             numeric(20,2) NOT NULL DEFAULT 0,
  UNIQUE (calculation_run_id, posting_layer, account_id)
);
CREATE TRIGGER trg_bsl_immutable
  BEFORE UPDATE OR DELETE ON balance_snapshot_line
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

-- ── BackgroundJob 擴充：CALCULATION_RUN 工作型別 ──
ALTER TABLE background_job DROP CONSTRAINT background_job_job_type_check;
ALTER TABLE background_job ADD CONSTRAINT background_job_job_type_check
  CHECK (job_type IN ('IMPORT_VALIDATION','CALCULATION_RUN'));

CREATE OR REPLACE FUNCTION fn_background_job_tenant_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_tenant uuid;
BEGIN
  IF NEW.job_type = 'IMPORT_VALIDATION' THEN
    SELECT tenant_id INTO v_tenant FROM import_batch WHERE import_batch_id = NEW.subject_id;
  ELSIF NEW.job_type = 'CALCULATION_RUN' THEN
    SELECT tenant_id INTO v_tenant FROM calculation_run WHERE calculation_run_id = NEW.subject_id;
  END IF;
  IF v_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：工作主體（% %）不屬於本租戶', NEW.job_type, NEW.subject_id;
  END IF;
  RETURN NEW;
END $$;

-- ── RLS ──
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'calculation_input_manifest','calculation_manifest_entry','calculation_run','balance_snapshot_line'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant())', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO app_runtime', t);
  END LOOP;
END $$;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_runtime;
