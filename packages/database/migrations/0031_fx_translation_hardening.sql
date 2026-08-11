-- 0031 折算硬化：權限、父鏈、唯一性、不可變性（SLICE-M3-02 走查後追加）
--
-- 0030 的資料模型方向正確，但四類防線只做到「欄位存在」的程度：
--   1. 匯率工作流相信呼叫者自己填的 submitted_by／reviewed_by／approved_by，
--      DB 從未驗證那個人是否真的持有該案件的角色——而版本上連 engagement_id
--      都沒有，根本不知道要查哪個案件。
--   2. RLS 只驗「自己填的 tenant_id」，父鏈一致性缺席：同租戶跨案件的錯配
--      全部放行（Adjustment 與 Mapping 已經踩過同一個洞）。
--   3. 觀測的唯一鍵含多個可空日期欄，PostgreSQL 預設 NULL 互不相等，
--      同一版本可以插入無限多筆一模一樣的 CLOSING（TaxBasisObservation 同題）。
--   4. component 的來源只是一個可空 text，追溯無法被 DB 保證；
--      延遲合計 trigger 沒有 DELETE 分支，也沒檢查 OLD。
--
-- 本檔只補防線，不改 0030 的模型形狀。

-- ═══ 1　匯率版本：案件歸屬、版本序列、遷移只能經函式 ═══════════════
ALTER TABLE exchange_rate_version
  ADD COLUMN engagement_id uuid REFERENCES client_engagement,
  ADD COLUMN series_id uuid,
  ADD COLUMN version_no int,
  ADD COLUMN supersedes_rate_version_id uuid REFERENCES exchange_rate_version;

-- 空表才設 NOT NULL；本欄無從回填——匯率版本屬哪個案件不是可推導的事實
DO $$
BEGIN
  IF (SELECT count(*) FROM exchange_rate_version) = 0 THEN
    ALTER TABLE exchange_rate_version
      ALTER COLUMN engagement_id SET NOT NULL,
      ALTER COLUMN series_id SET NOT NULL,
      ALTER COLUMN version_no SET NOT NULL;
  ELSE
    RAISE EXCEPTION 'FX0031_BACKFILL_REQUIRED: exchange_rate_version 已有資料，engagement_id 無從推導，須人工回填後再套用本 migration';
  END IF;
END $$;

ALTER TABLE exchange_rate_version
  ADD CONSTRAINT exchange_rate_version_series_uq UNIQUE (series_id, version_no),
  ADD CONSTRAINT exchange_rate_version_version_no_ck CHECK (version_no >= 1),
  ADD CONSTRAINT exchange_rate_version_supersedes_ck
    CHECK ((version_no = 1) = (supersedes_rate_version_id IS NULL));
CREATE UNIQUE INDEX exchange_rate_version_supersedes_uq
  ON exchange_rate_version (supersedes_rate_version_id)
  WHERE supersedes_rate_version_id IS NOT NULL;

-- 遷移只能經 fn_exchange_rate_transition：trigger 要求交易內已設 app.fx_actor，
-- 而唯一會設它的就是那個函式。與 0022 期間狀態機同一個模式——
-- 「誰做的」必須由 DB 自己查證，不是呼叫者自填的 UUID。
CREATE OR REPLACE FUNCTION fn_exchange_rate_version_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE legal boolean;
BEGIN
  IF NULLIF(current_setting('app.fx_actor', true), '') IS NULL THEN
    RAISE EXCEPTION 'RATE_VERSION_TRANSITION_ONLY: 匯率版本只能經 fn_exchange_rate_transition 變更（發起人與角色須由 DB 查證）';
  END IF;
  IF NEW.status = OLD.status THEN
    IF OLD.status <> 'DRAFT' THEN
      RAISE EXCEPTION 'RATE_VERSION_FROZEN: 匯率版本於 % 狀態不可修改（改率須發新版本）', OLD.status;
    END IF;
    RETURN NEW;
  END IF;
  -- 身分欄位不可變（與 0022 的 REVISION_IDENTITY_IMMUTABLE 同性質）
  IF NEW.rate_version_id IS DISTINCT FROM OLD.rate_version_id
  OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
  OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
  OR NEW.series_id IS DISTINCT FROM OLD.series_id
  OR NEW.version_no IS DISTINCT FROM OLD.version_no THEN
    RAISE EXCEPTION 'RATE_VERSION_IDENTITY_IMMUTABLE: 匯率版本的身分欄位不可變更';
  END IF;
  legal := (OLD.status, NEW.status) IN (
    ('DRAFT','SUBMITTED'), ('SUBMITTED','REVIEWED'), ('REVIEWED','APPROVED'),
    ('SUBMITTED','DRAFT'), ('REVIEWED','DRAFT'));
  IF NOT legal THEN
    RAISE EXCEPTION 'RATE_VERSION_ILLEGAL_TRANSITION: 匯率版本不得由 % 遷移至 %', OLD.status, NEW.status;
  END IF;
  IF NEW.status = 'REVIEWED' AND NEW.reviewed_by = NEW.submitted_by THEN
    RAISE EXCEPTION 'FX_RATE_SELF_REVIEW_DENIED: 提交人不得覆核自己提交的匯率版本（最低限度的獨立覆核）';
  END IF;
  IF OLD.reviewed_at IS NOT NULL AND NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
     AND NEW.status <> 'DRAFT' THEN
    RAISE EXCEPTION 'RATE_VERSION_REVIEW_IMMUTABLE: 覆核事實不可覆寫';
  END IF;
  RETURN NEW;
END $$;

-- 已批准的版本不得刪除；DELETE 不經 UPDATE trigger，必須另設
CREATE FUNCTION fn_exchange_rate_version_delete_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status <> 'DRAFT' THEN
    RAISE EXCEPTION 'RATE_VERSION_DELETE_DENIED: 已提交或已批准的匯率版本不得刪除（run 可能已凍結它）';
  END IF;
  IF NULLIF(current_setting('app.fx_actor', true), '') IS NULL THEN
    RAISE EXCEPTION 'RATE_VERSION_TRANSITION_ONLY: 匯率版本只能經 fn_exchange_rate_transition 變更';
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER trg_exchange_rate_version_delete
  BEFORE DELETE ON exchange_rate_version
  FOR EACH ROW EXECUTE FUNCTION fn_exchange_rate_version_delete_guard();

-- 版本序列：新版本向後指（與 lot set 同一形狀）
CREATE FUNCTION fn_exchange_rate_version_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_series uuid; v_no int; v_tenant uuid;
BEGIN
  IF NEW.status <> 'DRAFT' THEN
    RAISE EXCEPTION 'RATE_VERSION_MUST_START_DRAFT: 匯率版本必須以 DRAFT 建立（狀態由遷移函式推進）';
  END IF;
  IF NEW.submitted_by IS NOT NULL OR NEW.reviewed_by IS NOT NULL OR NEW.approved_by IS NOT NULL THEN
    RAISE EXCEPTION 'RATE_VERSION_ACTOR_NOT_SELF_DECLARED: 提交／覆核／批准人不得於建立時自填（由遷移函式依 DB 查證後寫入）';
  END IF;
  IF NEW.supersedes_rate_version_id IS NOT NULL THEN
    SELECT series_id, version_no, tenant_id INTO v_series, v_no, v_tenant
      FROM exchange_rate_version WHERE rate_version_id = NEW.supersedes_rate_version_id;
    IF v_series IS DISTINCT FROM NEW.series_id THEN
      RAISE EXCEPTION 'RATE_VERSION_SERIES_MISMATCH: 取代的對象必須屬同一版本序列';
    END IF;
    IF v_no <> NEW.version_no - 1 THEN
      RAISE EXCEPTION 'RATE_VERSION_GAP: 新版本必須緊接前一版（v% → v%）', v_no, NEW.version_no;
    END IF;
    IF v_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION '歸屬違規：取代的匯率版本不同租戶（INV-18）';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_exchange_rate_version_insert
  BEFORE INSERT ON exchange_rate_version
  FOR EACH ROW EXECUTE FUNCTION fn_exchange_rate_version_insert_guard();

-- 遷移函式：DB 查證發起人在**該案件**持有該角色，再依角色矩陣裁決。
-- 角色矩陣（§24.6 匯率版本列）：R2 提交、R3 覆核、R4 批准；退回由 R3／R4。
CREATE FUNCTION fn_exchange_rate_transition(
  p_version uuid, p_expected_from text, p_to text,
  p_actor uuid, p_acting_role text, p_reason text DEFAULT NULL
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v record; v_has int; v_required text;
BEGIN
  SELECT * INTO v FROM exchange_rate_version WHERE rate_version_id = p_version FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RATE_VERSION_NOT_FOUND: 匯率版本不存在';
  END IF;
  IF v.status <> p_expected_from THEN
    RAISE EXCEPTION 'OPTIMISTIC_LOCK_CONFLICT: 匯率版本狀態已由他人變更（你看到 %，目前為 %）', p_expected_from, v.status;
  END IF;
  v_required := CASE
    WHEN p_expected_from = 'DRAFT'     AND p_to = 'SUBMITTED' THEN 'R2'
    WHEN p_expected_from = 'SUBMITTED' AND p_to = 'REVIEWED'  THEN 'R3'
    WHEN p_expected_from = 'REVIEWED'  AND p_to = 'APPROVED'  THEN 'R4'
    WHEN p_to = 'DRAFT' AND p_expected_from = 'SUBMITTED'     THEN 'R3'
    WHEN p_to = 'DRAFT' AND p_expected_from = 'REVIEWED'      THEN 'R4'
    ELSE NULL END;
  IF v_required IS NULL THEN
    RAISE EXCEPTION 'RATE_VERSION_ILLEGAL_TRANSITION: 匯率版本不得由 % 遷移至 %', p_expected_from, p_to;
  END IF;
  IF p_acting_role IS DISTINCT FROM v_required THEN
    RAISE EXCEPTION 'ROLE_NOT_PERMITTED: 角色 % 不得發起 % → %（須 %）', p_acting_role, p_expected_from, p_to, v_required;
  END IF;
  -- 作用域嚴格相等：§26.3 的 R1～R5、R7 屬 EngagementAssignment，
  -- 未指定案件的租戶層指派不得取得本案件的匯率權（與 0029 同一條）
  SELECT count(*) INTO v_has
    FROM role_assignment ra JOIN app_user u ON u.user_id = ra.user_id
   WHERE ra.user_id = p_actor AND ra.role = p_acting_role::role_code
     AND ra.revoked_at IS NULL AND u.is_active
     AND ra.tenant_id = v.tenant_id AND u.tenant_id = v.tenant_id
     AND ra.engagement_id = v.engagement_id;
  IF v_has = 0 THEN
    RAISE EXCEPTION 'ACTOR_ROLE_NOT_HELD: 發起人未於本案件持有有效的 % 角色指派', p_acting_role;
  END IF;
  IF p_to = 'DRAFT' AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
    RAISE EXCEPTION 'RATE_VERSION_RETURN_REASON_REQUIRED: 退回必須填理由';
  END IF;

  PERFORM set_config('app.fx_actor', p_actor::text, true);
  UPDATE exchange_rate_version SET
    status = p_to,
    submitted_by = CASE WHEN p_to = 'SUBMITTED' THEN p_actor ELSE submitted_by END,
    submitted_at = CASE WHEN p_to = 'SUBMITTED' THEN now() ELSE submitted_at END,
    reviewed_by  = CASE WHEN p_to = 'REVIEWED'  THEN p_actor ELSE reviewed_by END,
    reviewed_at  = CASE WHEN p_to = 'REVIEWED'  THEN now() ELSE reviewed_at END,
    approved_by  = CASE WHEN p_to = 'APPROVED'  THEN p_actor ELSE approved_by END,
    approved_at  = CASE WHEN p_to = 'APPROVED'  THEN now() ELSE approved_at END,
    return_reason = CASE WHEN p_to = 'DRAFT' THEN p_reason ELSE return_reason END
  WHERE rate_version_id = p_version;
  RETURN p_to;
END $$;

-- 觀測列的增刪改一律經版本狀態把關（0030 已有），另補：不得跨案件引用
CREATE OR REPLACE FUNCTION fn_exchange_rate_observation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_status text; v_tenant uuid; v_ver uuid;
BEGIN
  v_ver := COALESCE(NEW.rate_version_id, OLD.rate_version_id);
  SELECT status, tenant_id INTO v_status, v_tenant
    FROM exchange_rate_version WHERE rate_version_id = v_ver;
  IF v_status <> 'DRAFT' THEN
    RAISE EXCEPTION 'RATE_OBSERVATIONS_FROZEN: 匯率版本已 %，觀測列不得增刪改（改率須發新版本）', v_status;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  IF v_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：觀測與匯率版本不同租戶（INV-18）';
  END IF;
  RETURN NEW;
END $$;

-- ═══ 2　觀測唯一鍵：NULL 必須被視為相等 ═════════════════════════════
-- 0030 的 UNIQUE 含四個可空日期欄。PostgreSQL 預設 NULL 互不相等，
-- 因此同一版本可以插入無限多筆一模一樣的 CLOSING——凍結的「唯一匯率」
-- 其實不唯一（TaxBasisObservation 踩過同一個洞）。
-- 約束名由 PostgreSQL 自動截斷，不同版本的截斷點可能不同——按名稱硬編會脆。
-- 改為查出該表唯一的 UNIQUE 約束再 DROP。
DO $$
DECLARE v_name text;
BEGIN
  SELECT conname INTO v_name FROM pg_constraint
   WHERE conrelid = 'exchange_rate_observation'::regclass AND contype = 'u';
  EXECUTE format('ALTER TABLE exchange_rate_observation DROP CONSTRAINT %I', v_name);
END $$;
ALTER TABLE exchange_rate_observation
  ADD CONSTRAINT exchange_rate_observation_uq UNIQUE NULLS NOT DISTINCT
    (rate_version_id, from_currency, to_currency, rate_type,
     measurement_date, coverage_start, coverage_end, event_date);

-- ═══ 3　已批准物件禁止刪除 ═════════════════════════════════════════
CREATE FUNCTION fn_fx_approved_delete_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'FX_APPROVED_DELETE_DENIED: 已批准的 % 不得刪除（run 可能已凍結它）', TG_TABLE_NAME;
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER trg_currency_assignment_delete BEFORE DELETE ON reporting_unit_currency_assignment
  FOR EACH ROW EXECUTE FUNCTION fn_fx_approved_delete_guard();
CREATE TRIGGER trg_translation_policy_delete BEFORE DELETE ON translation_policy_version
  FOR EACH ROW EXECUTE FUNCTION fn_fx_approved_delete_guard();
CREATE TRIGGER trg_equity_lot_set_delete BEFORE DELETE ON equity_translation_lot_set_version
  FOR EACH ROW EXECUTE FUNCTION fn_fx_approved_delete_guard();
CREATE TRIGGER trg_equity_opening_delete BEFORE DELETE ON equity_opening_translated_balance
  FOR EACH ROW EXECUTE FUNCTION fn_fx_approved_delete_guard();

-- ═══ 4　父鏈一致性 ═════════════════════════════════════════════════
-- RLS 只證明「這一列的 tenant_id 是我的」。它擋不住「自己的 tenant_id ＋
-- 別人的父物件」——同租戶跨案件的錯配全部放行。Adjustment 與 Mapping
-- 已經踩過同一個洞，這裡逐條補上。

-- 4-1 權益批次：set、觀測、案件三者必須一致
CREATE OR REPLACE FUNCTION fn_equity_lot_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_approved timestamptz; v_rate_type text; v_event date;
        v_set_tenant uuid; v_set_eng uuid; v_obs_tenant uuid; v_obs_eng uuid;
BEGIN
  SELECT approved_at, tenant_id, engagement_id INTO v_approved, v_set_tenant, v_set_eng
    FROM equity_translation_lot_set_version
   WHERE set_version_id = COALESCE(NEW.set_version_id, OLD.set_version_id);
  IF v_approved IS NOT NULL THEN
    RAISE EXCEPTION 'EQUITY_LOT_SET_IMMUTABLE: 已批准的集合不得增刪改 lots';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  IF v_set_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：lot 與其集合不同租戶（INV-18）';
  END IF;
  SELECT o.rate_type, o.event_date, o.tenant_id, ver.engagement_id
    INTO v_rate_type, v_event, v_obs_tenant, v_obs_eng
    FROM exchange_rate_observation o
    JOIN exchange_rate_version ver ON ver.rate_version_id = o.rate_version_id
   WHERE o.observation_id = NEW.exchange_rate_observation_id;
  IF v_obs_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：lot 引用了其他租戶的匯率觀測（INV-18）';
  END IF;
  IF v_obs_eng IS DISTINCT FROM v_set_eng THEN
    RAISE EXCEPTION '§24.1A：lot 引用的匯率版本不屬本案件';
  END IF;
  IF v_rate_type <> 'HISTORICAL' THEN
    RAISE EXCEPTION 'EQUITY_LOT_RATE_TYPE_INVALID: 權益批次只能引用 HISTORICAL 觀測（引用到 %）', v_rate_type;
  END IF;
  IF v_event IS DISTINCT FROM NEW.event_date THEN
    RAISE EXCEPTION 'EQUITY_LOT_RATE_DATE_MISMATCH: 觀測的 event_date（%）與批次的 event_date（%）不符', v_event, NEW.event_date;
  END IF;
  RETURN NEW;
END $$;

-- 4-2 CTA 分錄：run、期間、單位、政策、匯率版本必須同屬一個案件
CREATE OR REPLACE FUNCTION fn_translation_entry_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_code text; v_scope text; v_unit_scope text; v_unit_eng uuid;
  v_run_tenant uuid; v_run_eng uuid; v_run_rev uuid;
  v_pol_tenant uuid; v_pol_eng uuid; v_pol_unit uuid; v_pol_approved timestamptz;
  v_rate_tenant uuid; v_rate_eng uuid; v_rate_status text;
BEGIN
  SELECT code, scope_type INTO v_code, v_scope FROM posting_layer
   WHERE layer_id = NEW.posting_layer_id;
  IF v_code <> 'TRANSLATION_ADJUSTMENT' THEN
    RAISE EXCEPTION 'CTA_LAYER_INVALID: 折算調整只能記入 TRANSLATION_ADJUSTMENT 分層（收到 %）', v_code;
  END IF;
  SELECT unit_scope, engagement_id INTO v_unit_scope, v_unit_eng
    FROM reporting_unit WHERE reporting_unit_id = NEW.reporting_unit_id;
  IF v_unit_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：CTA 分錄的報告單位不屬本案件';
  END IF;
  IF (v_scope = 'ENTITY' AND v_unit_scope <> 'LEGAL_ENTITY')
  OR (v_scope = 'GROUP'  AND v_unit_scope <> 'CONSOLIDATION_GROUP') THEN
    RAISE EXCEPTION 'INV03_SCOPE_MISMATCH: % scope 的分層不得寫入 % 型別的報告單位', v_scope, v_unit_scope;
  END IF;

  SELECT tenant_id, engagement_id, period_revision_id
    INTO v_run_tenant, v_run_eng, v_run_rev
    FROM calculation_run WHERE calculation_run_id = NEW.calculation_run_id;
  IF v_run_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：CTA 分錄與 run 不同租戶（INV-18）';
  END IF;
  IF v_run_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：CTA 分錄的 run 不屬本案件';
  END IF;
  IF v_run_rev IS DISTINCT FROM NEW.period_revision_id THEN
    RAISE EXCEPTION 'CTA_PERIOD_MISMATCH: CTA 分錄的期間修訂與 run 不一致';
  END IF;

  SELECT tenant_id, engagement_id, reporting_unit_id, approved_at
    INTO v_pol_tenant, v_pol_eng, v_pol_unit, v_pol_approved
    FROM translation_policy_version WHERE policy_version_id = NEW.translation_policy_version_id;
  IF v_pol_tenant IS DISTINCT FROM NEW.tenant_id OR v_pol_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：CTA 分錄引用的折算政策不屬本案件';
  END IF;
  IF v_pol_unit IS DISTINCT FROM NEW.reporting_unit_id THEN
    RAISE EXCEPTION 'CTA_POLICY_UNIT_MISMATCH: 折算政策的適用單位與 CTA 分錄不一致';
  END IF;
  IF v_pol_approved IS NULL THEN
    RAISE EXCEPTION 'TRANSLATION_POLICY_NOT_APPROVED: 未批准的折算政策不得被使用';
  END IF;

  SELECT tenant_id, engagement_id, status INTO v_rate_tenant, v_rate_eng, v_rate_status
    FROM exchange_rate_version WHERE rate_version_id = NEW.exchange_rate_version_id;
  IF v_rate_tenant IS DISTINCT FROM NEW.tenant_id OR v_rate_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：CTA 分錄引用的匯率版本不屬本案件';
  END IF;
  IF v_rate_status <> 'APPROVED' THEN
    RAISE EXCEPTION 'G07_RATE_VERSION_NOT_FROZEN: 匯率版本尚未批准（狀態 %），不得產生折算結果', v_rate_status;
  END IF;
  RETURN NEW;
END $$;

-- 4-3 CTA 明細：父分錄與科目歸屬
CREATE FUNCTION fn_translation_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_tenant uuid; v_eng uuid; v_acc_eng uuid;
BEGIN
  SELECT tenant_id, engagement_id INTO v_tenant, v_eng
    FROM translation_adjustment_entry WHERE translation_entry_id = NEW.translation_entry_id;
  IF v_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：CTA 明細與其分錄不同租戶（INV-18）';
  END IF;
  SELECT coa.engagement_id INTO v_acc_eng
    FROM account a JOIN chart_of_accounts coa ON coa.coa_id = a.coa_id
   WHERE a.account_id = NEW.account_id;
  IF v_acc_eng IS DISTINCT FROM v_eng THEN
    RAISE EXCEPTION '§24.1A：CTA 明細的科目不屬本案件的科目表';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_translation_line BEFORE INSERT ON translation_adjustment_line
  FOR EACH ROW EXECUTE FUNCTION fn_translation_line_guard();

-- 4-4 折算結果：run 與來源快照必須同屬一個 run
CREATE FUNCTION fn_translation_result_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_run_tenant uuid; v_line_run uuid; v_line_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_run_tenant FROM calculation_run
   WHERE calculation_run_id = NEW.calculation_run_id;
  IF v_run_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：折算結果與 run 不同租戶（INV-18）';
  END IF;
  SELECT calculation_run_id, tenant_id INTO v_line_run, v_line_tenant
    FROM balance_snapshot_line WHERE snapshot_line_id = NEW.source_snapshot_line_id;
  IF v_line_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：折算結果與來源快照不同租戶（INV-18）';
  END IF;
  IF v_line_run IS DISTINCT FROM NEW.calculation_run_id THEN
    RAISE EXCEPTION 'TRANSLATION_RESULT_RUN_MISMATCH: 折算結果的來源快照屬於另一個 run（% ≠ %）', v_line_run, NEW.calculation_run_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_translation_result BEFORE INSERT ON translation_result
  FOR EACH ROW EXECUTE FUNCTION fn_translation_result_guard();

-- ═══ 5　component 的來源改為具體外鍵 ═══════════════════════════════
-- 可空的 text 追溯不了任何東西：DB 無從知道那串字是否指向真實物件。
ALTER TABLE translation_result_component
  DROP COLUMN source_ref,
  ADD COLUMN opening_balance_id uuid REFERENCES equity_opening_translated_balance,
  ADD COLUMN translation_adjustment_line_id uuid REFERENCES translation_adjustment_line;

ALTER TABLE translation_result_component
  ADD CONSTRAINT translation_component_source_xor CHECK (
    (source_kind = 'RATE_TRANSLATION'
       AND exchange_rate_observation_id IS NOT NULL AND equity_lot_id IS NULL
       AND opening_balance_id IS NULL AND translation_adjustment_line_id IS NULL)
 OR (source_kind = 'EQUITY_LOT'
       AND exchange_rate_observation_id IS NOT NULL AND equity_lot_id IS NOT NULL
       AND opening_balance_id IS NULL AND translation_adjustment_line_id IS NULL)
 OR (source_kind = 'OPENING_TRANSLATED_BALANCE'
       AND opening_balance_id IS NOT NULL AND exchange_rate_observation_id IS NULL
       AND equity_lot_id IS NULL AND translation_adjustment_line_id IS NULL)
 OR (source_kind = 'CTA_RESIDUAL'
       AND translation_adjustment_line_id IS NOT NULL AND exchange_rate_observation_id IS NULL
       AND equity_lot_id IS NULL AND opening_balance_id IS NULL));

-- component 引用的來源必須與**父結果所屬 run 凍結的版本**一致。
-- 只驗同租戶不夠：同租戶同案件的另一份匯率版本一樣不能用。
CREATE FUNCTION fn_translation_component_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_res_tenant uuid; v_run uuid; v_manifest uuid; v_rev uuid;
  v_obs_ver uuid; v_lot_set uuid; v_lot_obs uuid; v_open_rev uuid; v_line_run uuid;
BEGIN
  SELECT r.tenant_id, r.calculation_run_id INTO v_res_tenant, v_run
    FROM translation_result r WHERE r.translation_result_id = NEW.translation_result_id;
  IF v_res_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：計算明細與其彙總不同租戶（INV-18）';
  END IF;
  SELECT manifest_id, period_revision_id INTO v_manifest, v_rev
    FROM calculation_run WHERE calculation_run_id = v_run;

  IF NEW.exchange_rate_observation_id IS NOT NULL THEN
    SELECT rate_version_id INTO v_obs_ver FROM exchange_rate_observation
     WHERE observation_id = NEW.exchange_rate_observation_id;
    IF NOT EXISTS (SELECT 1 FROM calculation_manifest_entry
                    WHERE manifest_id = v_manifest
                      AND object_type = 'EXCHANGE_RATE_VERSION'
                      AND object_id = v_obs_ver) THEN
      RAISE EXCEPTION 'TRANSLATION_SOURCE_NOT_FROZEN: 明細引用的匯率觀測不屬本 run 凍結的匯率版本';
    END IF;
  END IF;

  IF NEW.equity_lot_id IS NOT NULL THEN
    SELECT set_version_id, exchange_rate_observation_id INTO v_lot_set, v_lot_obs
      FROM equity_translation_lot WHERE lot_id = NEW.equity_lot_id;
    IF NOT EXISTS (SELECT 1 FROM calculation_manifest_entry
                    WHERE manifest_id = v_manifest
                      AND object_type = 'EQUITY_TRANSLATION_LOT_SET_VERSION'
                      AND object_id = v_lot_set) THEN
      RAISE EXCEPTION 'TRANSLATION_SOURCE_NOT_FROZEN: 明細引用的權益批次不屬本 run 凍結的集合版本';
    END IF;
    IF v_lot_obs IS DISTINCT FROM NEW.exchange_rate_observation_id THEN
      RAISE EXCEPTION 'TRANSLATION_LOT_RATE_MISMATCH: 明細所記的匯率觀測與該 lot 自身的觀測不符';
    END IF;
  END IF;

  IF NEW.opening_balance_id IS NOT NULL THEN
    SELECT period_revision_id INTO v_open_rev FROM equity_opening_translated_balance
     WHERE opening_id = NEW.opening_balance_id;
    IF v_open_rev IS DISTINCT FROM v_rev THEN
      RAISE EXCEPTION 'TRANSLATION_OPENING_PERIOD_MISMATCH: 明細引用的期初已折算餘額不屬本期';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM calculation_manifest_entry
                    WHERE manifest_id = v_manifest
                      AND object_type = 'EQUITY_OPENING_TRANSLATED_BALANCE'
                      AND object_id = NEW.opening_balance_id) THEN
      RAISE EXCEPTION 'TRANSLATION_SOURCE_NOT_FROZEN: 明細引用的期初已折算餘額未被本 run 凍結';
    END IF;
  END IF;

  IF NEW.translation_adjustment_line_id IS NOT NULL THEN
    SELECT e.calculation_run_id INTO v_line_run
      FROM translation_adjustment_line l
      JOIN translation_adjustment_entry e ON e.translation_entry_id = l.translation_entry_id
     WHERE l.translation_line_id = NEW.translation_adjustment_line_id;
    IF v_line_run IS DISTINCT FROM v_run THEN
      RAISE EXCEPTION 'TRANSLATION_CTA_RUN_MISMATCH: 明細引用的 CTA 明細屬於另一個 run';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_translation_component BEFORE INSERT ON translation_result_component
  FOR EACH ROW EXECUTE FUNCTION fn_translation_component_guard();

-- ═══ 6　折算產出一經建立即不可變 ═══════════════════════════════════
-- 0030 的延遲合計 trigger 沒有 DELETE 分支，也只看 NEW——把 component 從
-- 結果 A 改掛到結果 B，A 那邊的合計就永遠不會再被檢查。
-- 與其把 trigger 補成支援重新掛接，不如**不允許重新掛接**：
-- 折算產出只由折算函式在同一交易 INSERT，之後一律不可 UPDATE／DELETE。
-- 重算＝新的 run（0012 已凍結的語意）。
CREATE FUNCTION fn_fx_output_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'FX_OUTPUT_IMMUTABLE: 折算產出（%）建立後不可 % ——重算請建立新的 CalculationRun',
    TG_TABLE_NAME, TG_OP;
END $$;
CREATE TRIGGER trg_translation_result_immutable
  BEFORE UPDATE OR DELETE ON translation_result
  FOR EACH ROW EXECUTE FUNCTION fn_fx_output_immutable();
CREATE TRIGGER trg_translation_component_immutable
  BEFORE UPDATE OR DELETE ON translation_result_component
  FOR EACH ROW EXECUTE FUNCTION fn_fx_output_immutable();
CREATE TRIGGER trg_translation_entry_immutable
  BEFORE UPDATE OR DELETE ON translation_adjustment_entry
  FOR EACH ROW EXECUTE FUNCTION fn_fx_output_immutable();
CREATE TRIGGER trg_translation_line_immutable
  BEFORE UPDATE OR DELETE ON translation_adjustment_line
  FOR EACH ROW EXECUTE FUNCTION fn_fx_output_immutable();

-- 因此延遲合計 trigger 只需驗新增，且不再需要那個殘留的 COALESCE 筆誤
CREATE OR REPLACE FUNCTION fn_translation_result_sum_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r record; c record;
BEGIN
  SELECT * INTO r FROM translation_result
   WHERE translation_result_id = NEW.translation_result_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT COALESCE(sum(source_debit),0) sd, COALESCE(sum(source_credit),0) sc,
         COALESCE(sum(result_debit),0) rd, COALESCE(sum(result_credit),0) rc,
         count(*) n
    INTO c FROM translation_result_component
   WHERE translation_result_id = r.translation_result_id;
  IF c.n = 0 THEN
    RAISE EXCEPTION 'TRANSLATION_RESULT_NO_COMPONENT: 折算結果必須至少有一筆計算明細（否則「彙總怎麼來的」無法回答）';
  END IF;
  IF c.sd <> r.source_debit OR c.sc <> r.source_credit
  OR c.rd <> r.result_debit OR c.rc <> r.result_credit THEN
    RAISE EXCEPTION 'TRANSLATION_COMPONENT_SUM_MISMATCH: 明細合計（來源 %/%、結果 %/%）與彙總（%/%、%/%）不符——差額就是無法追溯的金額',
      c.sd, c.sc, c.rd, c.rc, r.source_debit, r.source_credit, r.result_debit, r.result_credit;
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER trg_translation_result_sum ON translation_result_component;
CREATE CONSTRAINT TRIGGER trg_translation_result_sum
  AFTER INSERT ON translation_result_component
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION fn_translation_result_sum_guard();

-- ═══ 7　權限收口 ═══════════════════════════════════════════════════
-- 匯率版本與觀測：app_runtime 只能讀與（在 DRAFT 時）建立資料；
-- 狀態遷移一律走函式，刪除一律禁止。
REVOKE UPDATE, DELETE ON exchange_rate_version FROM app_runtime;
REVOKE DELETE ON exchange_rate_observation FROM app_runtime;
GRANT EXECUTE ON FUNCTION fn_exchange_rate_transition(uuid, text, text, uuid, text, text) TO app_runtime;

-- 已批准的主檔物件不得刪除（觸發器擋語意，權限擋通道）
REVOKE DELETE ON reporting_unit_currency_assignment FROM app_runtime;
REVOKE DELETE ON translation_policy_version FROM app_runtime;
REVOKE DELETE ON equity_translation_lot_set_version FROM app_runtime;
REVOKE DELETE ON equity_opening_translated_balance FROM app_runtime;
