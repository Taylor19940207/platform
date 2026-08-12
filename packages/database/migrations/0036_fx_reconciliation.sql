-- 0036 折算調節核對與期間級判定（SLICE-M3-03，契約第四版）
--
-- 三條實作防線（走查指定）：
--   1. **TOCTOU**：InputSelection 的建立與 `fn_fx_translation_run` 都先鎖同一筆
--      `period_revision` FOR UPDATE 再判定現行 selection，否則「檢查後被併發換版」。
--   2. **`comparison_context`**：差異列明示比較基準；內部重算不得使用
--      `ROUNDING_DIFFERENCE`——引擎與 C2 同法同率，內部差異只會是零或硬差異。
--   3. **安全模板**：所有 system-only／readiness 函式固定 search_path、撤回 PUBLIC、
--      明示授權、驗 `current_tenant()` 與完整父鏈。唯讀函式也不得因 UUID 可猜
--      而洩漏跨租戶結論。

-- ═══ 1　RoundingToleranceVersion（幣別對 scope）═══════════════════════
-- D-26-05 的完整 scope 鏈含尚未實作的 OutputProfile，本刀不假裝它存在；
-- 但幣別必須是**幣別對**——JPY→CNY 與 USD→CNY 的最小單位關係、匯率量級
-- 與尾差分布都不同，共用一個容許值沒有意義。
CREATE TABLE rounding_tolerance_version (
  tolerance_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  engagement_id     uuid NOT NULL REFERENCES client_engagement,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  source_currency   text NOT NULL REFERENCES currency,
  target_currency   text NOT NULL REFERENCES currency,
  single_limit      numeric(20,2) NOT NULL CHECK (single_limit >= 0),
  cumulative_limit  numeric(20,2) NOT NULL CHECK (cumulative_limit >= 0),
  series_id         uuid NOT NULL,
  version_no        int  NOT NULL CHECK (version_no >= 1),
  supersedes_tolerance_version_id uuid REFERENCES rounding_tolerance_version,
  approved_by       uuid REFERENCES app_user,
  approved_at       timestamptz,
  created_by        uuid NOT NULL REFERENCES app_user,
  created_at        timestamptz NOT NULL DEFAULT now(),
  content_hash      text,
  CHECK (source_currency <> target_currency),
  CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
  CHECK ((version_no = 1) = (supersedes_tolerance_version_id IS NULL)),
  UNIQUE (series_id, version_no)
);
CREATE UNIQUE INDEX rounding_tolerance_supersedes_uq
  ON rounding_tolerance_version (supersedes_tolerance_version_id)
  WHERE supersedes_tolerance_version_id IS NOT NULL;

CREATE FUNCTION fn_rounding_tolerance_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_series uuid; v_no int;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'TOLERANCE_IMMUTABLE: 已批准的容許值版本不可變更（改門檻須發新版本）';
  END IF;
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id, NEW.reporting_unit_id);
  IF NEW.supersedes_tolerance_version_id IS NOT NULL THEN
    SELECT series_id, version_no INTO v_series, v_no FROM rounding_tolerance_version
     WHERE tolerance_version_id = NEW.supersedes_tolerance_version_id;
    IF v_series IS DISTINCT FROM NEW.series_id THEN
      RAISE EXCEPTION 'TOLERANCE_SERIES_MISMATCH: 取代的對象必須屬同一版本序列';
    END IF;
    IF v_no <> NEW.version_no - 1 THEN
      RAISE EXCEPTION 'TOLERANCE_VERSION_GAP: 新版本必須緊接前一版（v% → v%）', v_no, NEW.version_no;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_rounding_tolerance BEFORE INSERT OR UPDATE ON rounding_tolerance_version
  FOR EACH ROW EXECUTE FUNCTION fn_rounding_tolerance_guard();

CREATE FUNCTION fn_rounding_tolerance_approve(p_version uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_tenant uuid; v_eng uuid; v_approved timestamptz;
BEGIN
  SELECT tenant_id, engagement_id, approved_at INTO v_tenant, v_eng, v_approved
    FROM rounding_tolerance_version WHERE tolerance_version_id = p_version FOR UPDATE;
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'FX_OBJECT_NOT_FOUND: 容許值版本不存在'; END IF;
  IF v_tenant IS DISTINCT FROM current_tenant() THEN
    RAISE EXCEPTION 'CROSS_TENANT_DENIED: 容許值版本不屬於目前租戶';
  END IF;
  IF v_approved IS NOT NULL THEN RAISE EXCEPTION 'FX_ALREADY_APPROVED: 已批准，不得重複批准'; END IF;
  PERFORM fn_assert_engagement_role(p_actor, 'R4', v_tenant, v_eng);
  UPDATE rounding_tolerance_version SET approved_by = p_actor, approved_at = now()
   WHERE tolerance_version_id = p_version;
END $$;

-- ═══ 2　折算調節與差異 ══════════════════════════════════════════════
-- 沒有 DRAFT：header、差異列、tolerance 快照與 FINALIZED 在同一交易完成。
-- 半成品加上「之後再結案」的流程，等於把不可變性交還給呼叫者。
CREATE TABLE translation_reconciliation (
  reconciliation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  engagement_id     uuid NOT NULL REFERENCES client_engagement,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  calculation_run_id uuid NOT NULL REFERENCES calculation_run,
  status            text NOT NULL DEFAULT 'FINALIZED' CHECK (status = 'FINALIZED'),
  -- tolerance 凍結在調節身上：FX run 完成時 Manifest 已封存，調節是後續工作
  tolerance_version_id   uuid NOT NULL REFERENCES rounding_tolerance_version,
  tolerance_content_hash text NOT NULL,
  single_limit_snapshot     numeric(20,2) NOT NULL,
  cumulative_limit_snapshot numeric(20,2) NOT NULL,
  scope_snapshot    jsonb NOT NULL,
  -- C2 演算法升版後，兩次結論不同才解釋得了
  reconciliation_engine_version text NOT NULL,
  canonicalization_version      text NOT NULL,
  reconciliation_input_hash     text NOT NULL,
  finalized_by      uuid NOT NULL REFERENCES app_user,
  finalized_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (calculation_run_id)
);

CREATE TABLE translation_difference (
  difference_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  reconciliation_id uuid NOT NULL REFERENCES translation_reconciliation ON DELETE CASCADE,
  check_id          text NOT NULL CHECK (check_id IN ('C1','C2','C3','C4')),
  account_id        uuid REFERENCES account,
  account_code      text,
  posting_layer     text,
  -- 比較基準：內部重算 vs 對外輸出核對。兩者的 comparison_amount 語意不同，
  -- 因此適用的 reason_class 也不同。
  comparison_context text NOT NULL CHECK (comparison_context IN
                       ('INTERNAL_RECALCULATION','EXTERNAL_OUTPUT')),
  actual_amount     numeric(20,2) NOT NULL,
  comparison_amount numeric(20,2) NOT NULL,
  actual_difference numeric(20,2) NOT NULL,
  reason_class      text NOT NULL CHECK (reason_class IN
                      ('ROUNDING_DIFFERENCE','MISSING_RATE','METHOD_UNRESOLVED',
                       'SOURCE_MISMATCH','CTA_MISMATCH','UNEXPLAINED')),
  resolution_status text NOT NULL DEFAULT 'OPEN' CHECK (resolution_status IN
                      ('OPEN','EXPLAINED','RESOLVED','RESOLVED_BY_POLICY','ACCEPTED_EXCEPTION')),
  -- 尾差的算術推導（日後對外核對的舉證基礎）
  rounding_basis            numeric(30,10),
  unrounded_amount          numeric(30,10),
  rounded_amount            numeric(20,2),
  currency_minor_unit       int,
  rounding_mode             text CHECK (rounding_mode IS NULL OR rounding_mode = 'ROUND_HALF_UP'),
  expected_rounding_residual numeric(30,10),
  threshold_policy_version_id uuid REFERENCES rounding_tolerance_version,
  cumulative_at_resolution  numeric(20,2),
  detail            text NOT NULL,
  resolved_by       uuid REFERENCES app_user,
  resolved_at       timestamptz,
  resolution_ref    text,
  line_no           int NOT NULL,
  UNIQUE (reconciliation_id, line_no),
  -- 差額的定義（方向明確）
  CHECK (actual_difference = actual_amount - comparison_amount),
  -- 內部重算**不得**產生尾差：引擎與 C2 同法同率，差異只會是零或硬差異
  CHECK (NOT (comparison_context = 'INTERNAL_RECALCULATION'
              AND reason_class = 'ROUNDING_DIFFERENCE')),
  -- 尾差必須帶完整推導，且差額等於捨入殘差（含正負號）
  CHECK (reason_class <> 'ROUNDING_DIFFERENCE' OR (
           rounding_basis IS NOT NULL AND unrounded_amount IS NOT NULL
       AND rounded_amount IS NOT NULL AND currency_minor_unit IS NOT NULL
       AND rounding_mode = 'ROUND_HALF_UP' AND expected_rounding_residual IS NOT NULL
       AND expected_rounding_residual = rounded_amount - unrounded_amount
       AND actual_difference = expected_rounding_residual)),
  -- 只有尾差可被政策自動結案
  CHECK (resolution_status <> 'RESOLVED_BY_POLICY' OR
         (reason_class = 'ROUNDING_DIFFERENCE' AND threshold_policy_version_id IS NOT NULL))
);
CREATE INDEX translation_difference_idx
  ON translation_difference (reconciliation_id, reason_class, resolution_status);

-- 父鏈：調節的 run、期間、單位、tolerance 必須同租戶同案件
CREATE FUNCTION fn_translation_reconciliation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_run_tenant uuid; v_run_eng uuid; v_run_rev uuid; v_run_status text; v_scope text;
  v_tol_tenant uuid; v_tol_eng uuid; v_tol_unit uuid; v_tol_approved timestamptz;
BEGIN
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id, NEW.reporting_unit_id,
                                  NULL, NEW.period_revision_id);
  SELECT cr.tenant_id, cr.engagement_id, cr.period_revision_id, cr.status, m.calculation_scope
    INTO v_run_tenant, v_run_eng, v_run_rev, v_run_status, v_scope
    FROM calculation_run cr
    JOIN calculation_input_manifest m ON m.manifest_id = cr.manifest_id
   WHERE cr.calculation_run_id = NEW.calculation_run_id;
  IF v_run_tenant IS DISTINCT FROM NEW.tenant_id OR v_run_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：調節的 run 不屬本案件';
  END IF;
  IF v_run_rev IS DISTINCT FROM NEW.period_revision_id THEN
    RAISE EXCEPTION 'RECON_PERIOD_MISMATCH: 調節的期間修訂與 run 不一致';
  END IF;
  IF v_scope <> 'FX_TRANSLATION' THEN
    RAISE EXCEPTION 'RECON_SCOPE_MISMATCH: 只有 FX_TRANSLATION 的 run 可做折算調節';
  END IF;
  IF v_run_status <> 'COMPLETED' THEN
    RAISE EXCEPTION 'RECON_RUN_NOT_COMPLETED: 只有已完成的 run 可做調節（目前 %）', v_run_status;
  END IF;
  SELECT tenant_id, engagement_id, reporting_unit_id, approved_at
    INTO v_tol_tenant, v_tol_eng, v_tol_unit, v_tol_approved
    FROM rounding_tolerance_version WHERE tolerance_version_id = NEW.tolerance_version_id;
  IF v_tol_tenant IS DISTINCT FROM NEW.tenant_id OR v_tol_eng IS DISTINCT FROM NEW.engagement_id
  OR v_tol_unit IS DISTINCT FROM NEW.reporting_unit_id THEN
    RAISE EXCEPTION '§24.1A：容許值版本不屬本案件本單位';
  END IF;
  IF v_tol_approved IS NULL THEN
    RAISE EXCEPTION 'TOLERANCE_NOT_APPROVED: 未批准的容許值版本不得使用';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_translation_reconciliation BEFORE INSERT ON translation_reconciliation
  FOR EACH ROW EXECUTE FUNCTION fn_translation_reconciliation_guard();

CREATE FUNCTION fn_translation_difference_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_tenant FROM translation_reconciliation
   WHERE reconciliation_id = NEW.reconciliation_id;
  IF v_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：差異列與其調節不同租戶（INV-18）';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_translation_difference BEFORE INSERT ON translation_difference
  FOR EACH ROW EXECUTE FUNCTION fn_translation_difference_guard();

-- 不可變：調節與差異是 run 的產出。唯一例外是 resolution_status 由 OPEN
-- 走向人工終態，且只能經 system-only 函式（見下）。
CREATE FUNCTION fn_translation_recon_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'FX_OUTPUT_IMMUTABLE: 折算調節產出不可刪除——重新核對請建立新的 run 與調節';
  END IF;
  IF TG_TABLE_NAME = 'translation_reconciliation' THEN
    RAISE EXCEPTION 'FX_OUTPUT_IMMUTABLE: 折算調節建立後不可修改';
  END IF;
  -- translation_difference：只允許 OPEN → EXPLAINED／ACCEPTED_EXCEPTION，
  -- 且只能改狀態與處理欄位
  IF NULLIF(current_setting('app.fx_recon_resolve', true), '') IS NULL THEN
    RAISE EXCEPTION 'FX_OUTPUT_IMMUTABLE: 差異列只能經 fn_translation_difference_resolve 處理';
  END IF;
  IF OLD.resolution_status <> 'OPEN' THEN
    RAISE EXCEPTION 'FX_DIFFERENCE_ALREADY_RESOLVED: 已是終態的差異不得再改（目前 %）', OLD.resolution_status;
  END IF;
  IF NEW.resolution_status NOT IN ('EXPLAINED','ACCEPTED_EXCEPTION') THEN
    RAISE EXCEPTION 'FX_DIFFERENCE_STATUS_INVALID: 人工處理只能標為 EXPLAINED 或 ACCEPTED_EXCEPTION';
  END IF;
  IF NEW.reason_class IS DISTINCT FROM OLD.reason_class
  OR NEW.actual_amount IS DISTINCT FROM OLD.actual_amount
  OR NEW.comparison_amount IS DISTINCT FROM OLD.comparison_amount
  OR NEW.actual_difference IS DISTINCT FROM OLD.actual_difference
  OR NEW.comparison_context IS DISTINCT FROM OLD.comparison_context THEN
    RAISE EXCEPTION 'FX_OUTPUT_IMMUTABLE: 差異的事實欄位不可修改，只能記錄處理結論';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_translation_reconciliation_immutable
  BEFORE UPDATE OR DELETE ON translation_reconciliation
  FOR EACH ROW EXECUTE FUNCTION fn_translation_recon_immutable();
CREATE TRIGGER trg_translation_difference_immutable
  BEFORE UPDATE OR DELETE ON translation_difference
  FOR EACH ROW EXECUTE FUNCTION fn_translation_recon_immutable();

-- ═══ 3　期間級的兩個選定物件 ════════════════════════════════════════
CREATE TABLE period_fx_input_selection (
  input_selection_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  engagement_id     uuid NOT NULL REFERENCES client_engagement,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  source_run_id     uuid NOT NULL REFERENCES calculation_run,
  exchange_rate_version_id uuid NOT NULL REFERENCES exchange_rate_version,
  translation_policy_version_id uuid NOT NULL REFERENCES translation_policy_version,
  selection_series_id uuid NOT NULL,
  version_no        int  NOT NULL CHECK (version_no >= 1),
  supersedes_selection_id uuid REFERENCES period_fx_input_selection,
  selected_by       uuid NOT NULL REFERENCES app_user,
  selected_at       timestamptz NOT NULL DEFAULT now(),
  CHECK ((version_no = 1) = (supersedes_selection_id IS NULL)),
  UNIQUE (selection_series_id, version_no)
);
-- 不得從同一舊版分叉出兩個現行版本
CREATE UNIQUE INDEX period_fx_input_selection_supersedes_uq
  ON period_fx_input_selection (supersedes_selection_id)
  WHERE supersedes_selection_id IS NOT NULL;

CREATE TABLE period_fx_run_selection (
  run_selection_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  engagement_id     uuid NOT NULL REFERENCES client_engagement,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  selected_run_id   uuid NOT NULL REFERENCES calculation_run,
  selected_reconciliation_id uuid NOT NULL REFERENCES translation_reconciliation,
  selection_series_id uuid NOT NULL,
  version_no        int  NOT NULL CHECK (version_no >= 1),
  supersedes_selection_id uuid REFERENCES period_fx_run_selection,
  selected_by       uuid NOT NULL REFERENCES app_user,
  selected_at       timestamptz NOT NULL DEFAULT now(),
  CHECK ((version_no = 1) = (supersedes_selection_id IS NULL)),
  UNIQUE (selection_series_id, version_no)
);
CREATE UNIQUE INDEX period_fx_run_selection_supersedes_uq
  ON period_fx_run_selection (supersedes_selection_id)
  WHERE supersedes_selection_id IS NOT NULL;

-- 兩個 selection 都不可變：換選擇＝發新版本
CREATE FUNCTION fn_fx_selection_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'FX_SELECTION_IMMUTABLE: 選定建立後不可 % ——換選擇請發新版本', TG_OP;
END $$;
CREATE TRIGGER trg_period_fx_input_selection_immutable
  BEFORE UPDATE OR DELETE ON period_fx_input_selection
  FOR EACH ROW EXECUTE FUNCTION fn_fx_selection_immutable();
CREATE TRIGGER trg_period_fx_run_selection_immutable
  BEFORE UPDATE OR DELETE ON period_fx_run_selection
  FOR EACH ROW EXECUTE FUNCTION fn_fx_selection_immutable();

-- 現行版本＝同一 series 中未被任何後版指向者（由取代鏈判斷，不按時間）
CREATE FUNCTION fn_current_fx_input_selection(p_period_revision uuid)
RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT s.input_selection_id FROM period_fx_input_selection s
   WHERE s.period_revision_id = p_period_revision
     AND NOT EXISTS (SELECT 1 FROM period_fx_input_selection n
                      WHERE n.supersedes_selection_id = s.input_selection_id)
   ORDER BY s.version_no DESC LIMIT 1
$$;
CREATE FUNCTION fn_current_fx_run_selection(p_period_revision uuid)
RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT s.run_selection_id FROM period_fx_run_selection s
   WHERE s.period_revision_id = p_period_revision
     AND NOT EXISTS (SELECT 1 FROM period_fx_run_selection n
                      WHERE n.supersedes_selection_id = s.run_selection_id)
   ORDER BY s.version_no DESC LIMIT 1
$$;

-- ═══ 4　RLS 與基本權限 ══════════════════════════════════════════════
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['rounding_tolerance_version','translation_reconciliation',
    'translation_difference','period_fx_input_selection','period_fx_run_selection']
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant())', t);
    EXECUTE format('GRANT SELECT ON %I TO app_runtime', t);
  END LOOP;
END $$;

-- 容許值版本可由 app_runtime 建立草稿，但批准欄以欄位級權限擋住（比照 0032）
GRANT INSERT (tolerance_version_id, tenant_id, engagement_id, reporting_unit_id,
              source_currency, target_currency, single_limit, cumulative_limit,
              series_id, version_no, supersedes_tolerance_version_id, created_by,
              created_at, content_hash),
      UPDATE (content_hash)
  ON rounding_tolerance_version TO app_runtime;
-- 調節、差異與兩個 selection 一律只能經 system-only 函式建立
