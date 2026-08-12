-- 0032 折算主檔的工作流與父鏈收口（SLICE-M3-02 走查第二輪）
--
-- 0031 封住了 CTA／Result／Component／lot 的父鏈與匯率版本的**狀態遷移**，
-- 但三個入口仍可實際繞過：
--
--   1. `app.fx_actor` 是自訂 GUC，**任何連線都能自己 set_config**。
--      0031 的註解把它寫成「只有函式會設它」——那不成立。真正擋住直接 UPDATE 的
--      是權限撤回，GUC 只是交易內的標記。本檔把該事實寫清楚，並補上
--      SECURITY DEFINER 函式該有的 search_path 固定與 PUBLIC 撤回。
--   2. **建立與批准仍可自填 actor**：app_runtime 能直接 INSERT 一列
--      `approved_at = now()` 的政策或 lot set，run 看到 approved_at 非空就信任它。
--      批准欄一旦可以自填，G-07 與重演證據就同時失效。
--   3. **主檔父鏈只比 engagement，沒比 tenant**：T1 可以填自己的 tenant_id
--      卻引用 T2 的 engagement／reporting_unit。RLS 只看列上的 tenant_id，
--      普通外鍵不管父物件屬誰。
--
-- 防線分工（本檔的核心決定）：
--   **權限是邊界，函式是流程，GUC 只是標記。**
--   批准欄以**欄位級權限**擋住（app_runtime 對 approved_by／approved_at
--   連 INSERT 與 UPDATE 的通道都沒有），不依賴任何可偽造的 session 變數。

-- ═══ 1　共用：案件層角色查證 ═══════════════════════════════════════
-- 作用域嚴格相等（§26.3／0029）：未指定案件的租戶層指派不得取得本案件的權限。
CREATE FUNCTION fn_assert_engagement_role(
  p_actor uuid, p_role text, p_tenant uuid, p_engagement uuid
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_has int;
BEGIN
  SELECT count(*) INTO v_has
    FROM role_assignment ra JOIN app_user u ON u.user_id = ra.user_id
   WHERE ra.user_id = p_actor AND ra.role = p_role::role_code
     AND ra.revoked_at IS NULL AND u.is_active
     AND ra.tenant_id = p_tenant AND u.tenant_id = p_tenant
     AND ra.engagement_id = p_engagement;
  IF v_has = 0 THEN
    RAISE EXCEPTION 'ACTOR_ROLE_NOT_HELD: 發起人未於本案件持有有效的 % 角色指派', p_role;
  END IF;
END $$;

-- R6 屬 TenantMembership（§26.3），**沒有**案件層指派——把它當案件層角色查，
-- 等於要求系管逐案件被指派，那是違反基線的。租戶層角色用這一支。
CREATE FUNCTION fn_assert_tenant_role(p_actor uuid, p_role text, p_tenant uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_has int;
BEGIN
  SELECT count(*) INTO v_has
    FROM role_assignment ra JOIN app_user u ON u.user_id = ra.user_id
   WHERE ra.user_id = p_actor AND ra.role = p_role::role_code
     AND ra.revoked_at IS NULL AND u.is_active
     AND ra.tenant_id = p_tenant AND u.tenant_id = p_tenant
     AND ra.engagement_id IS NULL;
  IF v_has = 0 THEN
    RAISE EXCEPTION 'ACTOR_ROLE_NOT_HELD: 發起人未持有有效的租戶層 % 角色指派', p_role;
  END IF;
END $$;

-- ═══ 2　主檔父鏈：tenant 必須一路一致 ═══════════════════════════════
-- 只比 engagement 不夠：跨租戶的 engagement 一樣能被引用。
CREATE FUNCTION fn_assert_parent_tenant(
  p_tenant uuid, p_engagement uuid, p_reporting_unit uuid DEFAULT NULL,
  p_account uuid DEFAULT NULL, p_period_revision uuid DEFAULT NULL
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_t uuid; v_e uuid;
BEGIN
  SELECT tenant_id INTO v_t FROM client_engagement WHERE engagement_id = p_engagement;
  IF v_t IS DISTINCT FROM p_tenant THEN
    RAISE EXCEPTION '歸屬違規：引用的案件屬於其他租戶（INV-18）';
  END IF;
  IF p_reporting_unit IS NOT NULL THEN
    SELECT tenant_id, engagement_id INTO v_t, v_e FROM reporting_unit
     WHERE reporting_unit_id = p_reporting_unit;
    IF v_t IS DISTINCT FROM p_tenant THEN
      RAISE EXCEPTION '歸屬違規：引用的報告單位屬於其他租戶（INV-18）';
    END IF;
    IF v_e IS DISTINCT FROM p_engagement THEN
      RAISE EXCEPTION '§24.1A：引用的報告單位不屬本案件';
    END IF;
  END IF;
  IF p_account IS NOT NULL THEN
    SELECT coa.tenant_id, coa.engagement_id INTO v_t, v_e
      FROM account a JOIN chart_of_accounts coa ON coa.coa_id = a.coa_id
     WHERE a.account_id = p_account;
    IF v_t IS DISTINCT FROM p_tenant THEN
      RAISE EXCEPTION '歸屬違規：引用的科目屬於其他租戶（INV-18）';
    END IF;
    IF v_e IS DISTINCT FROM p_engagement THEN
      RAISE EXCEPTION '§24.1A：引用的科目不屬本案件的科目表';
    END IF;
  END IF;
  IF p_period_revision IS NOT NULL THEN
    SELECT pr.tenant_id, rp.engagement_id INTO v_t, v_e
      FROM period_revision pr
      JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
     WHERE pr.period_revision_id = p_period_revision;
    IF v_t IS DISTINCT FROM p_tenant THEN
      RAISE EXCEPTION '歸屬違規：引用的期間修訂屬於其他租戶（INV-18）';
    END IF;
    IF v_e IS DISTINCT FROM p_engagement THEN
      RAISE EXCEPTION '§24.1A：引用的期間修訂不屬本案件';
    END IF;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION fn_currency_assignment_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id, NEW.reporting_unit_id);
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'CURRENCY_ASSIGNMENT_IMMUTABLE: 已批准的幣別指派不可變更（改期間或幣別須發新指派）';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION fn_translation_policy_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_coa uuid; v_owner uuid;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'TRANSLATION_POLICY_IMMUTABLE: 已批准的折算政策版本不可變更';
  END IF;
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id, NEW.reporting_unit_id,
                                  NEW.cta_account_id);
  SELECT coa_id INTO v_coa FROM account WHERE account_id = NEW.cta_account_id;
  IF v_coa IS DISTINCT FROM NEW.cta_coa_id THEN
    RAISE EXCEPTION 'CTA_ACCOUNT_SCOPE_INVALID: CTA 科目不屬於所宣告的科目表';
  END IF;
  SELECT engagement_id INTO v_owner FROM chart_of_accounts WHERE coa_id = NEW.cta_coa_id;
  IF v_owner IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION 'CTA_ACCOUNT_SCOPE_INVALID: CTA 科目表必須是本案件的集團科目表';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION fn_equity_lot_set_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_prev_series uuid; v_prev_no int;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'EQUITY_LOT_SET_IMMUTABLE: 已批准的權益折算批次集合不可變更（增減出資須發新 set version）';
  END IF;
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id, NEW.reporting_unit_id,
                                  NEW.account_id);
  IF NEW.supersedes_set_version_id IS NOT NULL THEN
    SELECT series_id, version_no INTO v_prev_series, v_prev_no
      FROM equity_translation_lot_set_version
     WHERE set_version_id = NEW.supersedes_set_version_id;
    IF v_prev_series IS DISTINCT FROM NEW.series_id THEN
      RAISE EXCEPTION 'EQUITY_LOT_SET_SERIES_MISMATCH: 取代的對象必須屬同一版本序列';
    END IF;
    IF v_prev_no <> NEW.version_no - 1 THEN
      RAISE EXCEPTION 'EQUITY_LOT_SET_VERSION_GAP: 新版本必須緊接前一版（v% → v%）', v_prev_no, NEW.version_no;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION fn_equity_opening_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_run_status text; v_run_rev uuid; v_run_period uuid; v_run_unit uuid;
  v_rev_status text; v_this_unit uuid; v_prev uuid;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'OPENING_BALANCE_IMMUTABLE: 已批准的期初已折算餘額不可變更';
  END IF;
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id, NEW.reporting_unit_id,
                                  NEW.account_id, NEW.period_revision_id);
  SELECT rp.reporting_unit_id, rp.previous_reporting_period_id
    INTO v_this_unit, v_prev
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = NEW.period_revision_id;
  IF v_this_unit IS DISTINCT FROM NEW.reporting_unit_id THEN
    RAISE EXCEPTION '§24.1A：期初已折算餘額的報告單位與期間不一致';
  END IF;
  IF NEW.source_kind = 'FIRST_CONVERSION' OR NEW.source_calculation_run_id IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT cr.status, cr.period_revision_id INTO v_run_status, v_run_rev
    FROM calculation_run cr WHERE cr.calculation_run_id = NEW.source_calculation_run_id;
  IF v_run_status IS DISTINCT FROM 'COMPLETED' THEN
    RAISE EXCEPTION 'FX_OPENING_EQUITY_NOT_CONTINUOUS: 來源 run 的狀態為 %（須為 COMPLETED）', v_run_status;
  END IF;
  SELECT pr.status, rp.reporting_period_id, rp.reporting_unit_id
    INTO v_rev_status, v_run_period, v_run_unit
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = v_run_rev;
  IF v_rev_status IS DISTINCT FROM 'LOCKED' THEN
    RAISE EXCEPTION 'FX_OPENING_EQUITY_NOT_CONTINUOUS: 來源 run 所屬期間修訂的狀態為 %（須為 LOCKED）', v_rev_status;
  END IF;
  IF v_prev IS NULL OR v_run_period IS DISTINCT FROM v_prev THEN
    RAISE EXCEPTION 'FX_OPENING_EQUITY_NOT_CONTINUOUS: 來源 run 不屬本期的顯式前期（前期連結為 %）', v_prev;
  END IF;
  IF v_run_unit IS DISTINCT FROM NEW.reporting_unit_id THEN
    RAISE EXCEPTION 'FX_OPENING_EQUITY_NOT_CONTINUOUS: 來源 run 的報告單位與本期不同';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION fn_exchange_rate_version_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_series uuid; v_no int; v_tenant uuid;
BEGIN
  IF NEW.status <> 'DRAFT' THEN
    RAISE EXCEPTION 'RATE_VERSION_MUST_START_DRAFT: 匯率版本必須以 DRAFT 建立（狀態由遷移函式推進）';
  END IF;
  IF NEW.submitted_by IS NOT NULL OR NEW.reviewed_by IS NOT NULL OR NEW.approved_by IS NOT NULL THEN
    RAISE EXCEPTION 'RATE_VERSION_ACTOR_NOT_SELF_DECLARED: 提交／覆核／批准人不得於建立時自填（由遷移函式依 DB 查證後寫入）';
  END IF;
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id);
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

-- ═══ 3　建立與批准的 system-only 函式 ═══════════════════════════════
-- 全部 SECURITY DEFINER ＋ 固定 search_path。SECURITY DEFINER 不固定
-- search_path 時，呼叫者可用自己的 schema 影子化被引用的物件。
CREATE FUNCTION fn_exchange_rate_version_create(
  p_tenant uuid, p_engagement uuid, p_label text,
  p_series uuid, p_version_no int, p_supersedes uuid, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_id uuid;
BEGIN
  -- §24.6：匯率版本由 R6 建立與維護。R6 是租戶層技術角色（§26.3），
  -- 不逐案件指派——但仍必須驗證那個案件屬於同一租戶（父鏈由 trigger 補）。
  PERFORM fn_assert_tenant_role(p_actor, 'R6', p_tenant);
  INSERT INTO exchange_rate_version (tenant_id, engagement_id, label, series_id, version_no,
          supersedes_rate_version_id, created_by)
  VALUES (p_tenant, p_engagement, p_label, p_series, p_version_no, p_supersedes, p_actor)
  RETURNING rate_version_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION fn_exchange_rate_observation_add(
  p_version uuid, p_from text, p_to text, p_rate_type text, p_rate numeric, p_source text,
  p_measurement date, p_coverage_start date, p_coverage_end date, p_event date, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_tenant uuid; v_eng uuid; v_id uuid;
BEGIN
  SELECT tenant_id, engagement_id INTO v_tenant, v_eng
    FROM exchange_rate_version WHERE rate_version_id = p_version;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'RATE_VERSION_NOT_FOUND: 匯率版本不存在';
  END IF;
  PERFORM fn_assert_tenant_role(p_actor, 'R6', v_tenant);
  INSERT INTO exchange_rate_observation (tenant_id, rate_version_id, from_currency, to_currency,
          rate_type, rate, source, measurement_date, coverage_start, coverage_end, event_date)
  VALUES (v_tenant, p_version, p_from, p_to, p_rate_type, p_rate, p_source,
          p_measurement, p_coverage_start, p_coverage_end, p_event)
  RETURNING observation_id INTO v_id;
  RETURN v_id;
END $$;

-- 四個批准函式。批准欄不得在 INSERT 時自填——app_runtime 對那兩欄
-- 連寫入通道都沒有（見 §4 的欄位級權限）。
CREATE FUNCTION fn_currency_assignment_approve(p_assignment uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_tenant uuid; v_eng uuid; v_approved timestamptz;
BEGIN
  SELECT tenant_id, engagement_id, approved_at INTO v_tenant, v_eng, v_approved
    FROM reporting_unit_currency_assignment WHERE assignment_id = p_assignment FOR UPDATE;
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'FX_OBJECT_NOT_FOUND: 幣別指派不存在'; END IF;
  IF v_approved IS NOT NULL THEN RAISE EXCEPTION 'FX_ALREADY_APPROVED: 已批准，不得重複批准'; END IF;
  PERFORM fn_assert_engagement_role(p_actor, 'R4', v_tenant, v_eng);
  UPDATE reporting_unit_currency_assignment SET approved_by = p_actor, approved_at = now()
   WHERE assignment_id = p_assignment;
END $$;

CREATE FUNCTION fn_translation_policy_approve(p_policy uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_tenant uuid; v_eng uuid; v_approved timestamptz; v_rules int;
BEGIN
  SELECT tenant_id, engagement_id, approved_at INTO v_tenant, v_eng, v_approved
    FROM translation_policy_version WHERE policy_version_id = p_policy FOR UPDATE;
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'FX_OBJECT_NOT_FOUND: 折算政策版本不存在'; END IF;
  IF v_approved IS NOT NULL THEN RAISE EXCEPTION 'FX_ALREADY_APPROVED: 已批准，不得重複批准'; END IF;
  PERFORM fn_assert_engagement_role(p_actor, 'R4', v_tenant, v_eng);
  SELECT count(*) INTO v_rules FROM translation_policy_rule WHERE policy_version_id = p_policy;
  IF v_rules = 0 THEN
    RAISE EXCEPTION 'TRANSLATION_POLICY_EMPTY: 沒有任何規則的折算政策不得批准';
  END IF;
  UPDATE translation_policy_version SET approved_by = p_actor, approved_at = now()
   WHERE policy_version_id = p_policy;
END $$;

CREATE FUNCTION fn_equity_lot_set_approve(p_set uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_tenant uuid; v_eng uuid; v_approved timestamptz; v_lots int;
BEGIN
  SELECT tenant_id, engagement_id, approved_at INTO v_tenant, v_eng, v_approved
    FROM equity_translation_lot_set_version WHERE set_version_id = p_set FOR UPDATE;
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'FX_OBJECT_NOT_FOUND: 權益批次集合不存在'; END IF;
  IF v_approved IS NOT NULL THEN RAISE EXCEPTION 'FX_ALREADY_APPROVED: 已批准，不得重複批准'; END IF;
  PERFORM fn_assert_engagement_role(p_actor, 'R4', v_tenant, v_eng);
  SELECT count(*) INTO v_lots FROM equity_translation_lot WHERE set_version_id = p_set;
  IF v_lots = 0 THEN
    RAISE EXCEPTION 'EQUITY_LOT_SET_EMPTY: 空的權益批次集合不得批准（合計必等於餘額的檢查會變成無條件通過）';
  END IF;
  UPDATE equity_translation_lot_set_version SET approved_by = p_actor, approved_at = now()
   WHERE set_version_id = p_set;
END $$;

CREATE FUNCTION fn_equity_opening_approve(p_opening uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_tenant uuid; v_eng uuid; v_approved timestamptz;
BEGIN
  SELECT tenant_id, engagement_id, approved_at INTO v_tenant, v_eng, v_approved
    FROM equity_opening_translated_balance WHERE opening_id = p_opening FOR UPDATE;
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'FX_OBJECT_NOT_FOUND: 期初已折算餘額不存在'; END IF;
  IF v_approved IS NOT NULL THEN RAISE EXCEPTION 'FX_ALREADY_APPROVED: 已批准，不得重複批准'; END IF;
  PERFORM fn_assert_engagement_role(p_actor, 'R4', v_tenant, v_eng);
  UPDATE equity_opening_translated_balance SET approved_by = p_actor, approved_at = now()
   WHERE opening_id = p_opening;
END $$;

-- 0031 的遷移函式補上固定 search_path
CREATE OR REPLACE FUNCTION fn_exchange_rate_transition(
  p_version uuid, p_expected_from text, p_to text,
  p_actor uuid, p_acting_role text, p_reason text DEFAULT NULL
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v record; v_required text;
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
  PERFORM fn_assert_engagement_role(p_actor, p_acting_role, v.tenant_id, v.engagement_id);
  IF p_to = 'DRAFT' AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
    RAISE EXCEPTION 'RATE_VERSION_RETURN_REASON_REQUIRED: 退回必須填理由';
  END IF;
  -- 交易內標記，供 trigger 辨識「這次寫入來自流程函式」。
  -- **這不是安全邊界**：自訂 GUC 任何連線都能自己 set_config。
  -- 真正擋住直接寫入的是下方的權限撤回。
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

-- ═══ 4　權限：批准欄以欄位級授權擋住 ═══════════════════════════════
-- 這是真防線。GUC 可偽造，欄位級權限不能。
REVOKE INSERT, UPDATE ON reporting_unit_currency_assignment FROM app_runtime;
GRANT INSERT (assignment_id, tenant_id, engagement_id, reporting_unit_id, currency_role,
              currency_code, effective_range, created_by, created_at, content_hash),
      UPDATE (content_hash)
  ON reporting_unit_currency_assignment TO app_runtime;

REVOKE INSERT, UPDATE ON translation_policy_version FROM app_runtime;
GRANT INSERT (policy_version_id, tenant_id, engagement_id, reporting_unit_id, label,
              cta_account_id, cta_coa_id, created_by, created_at, content_hash),
      UPDATE (label, content_hash)
  ON translation_policy_version TO app_runtime;

REVOKE INSERT, UPDATE ON equity_translation_lot_set_version FROM app_runtime;
GRANT INSERT (set_version_id, tenant_id, engagement_id, reporting_unit_id, account_id,
              series_id, version_no, supersedes_set_version_id, created_by, created_at, content_hash),
      UPDATE (content_hash)
  ON equity_translation_lot_set_version TO app_runtime;

REVOKE INSERT, UPDATE ON equity_opening_translated_balance FROM app_runtime;
GRANT INSERT (opening_id, tenant_id, engagement_id, reporting_unit_id, period_revision_id,
              account_id, reporting_currency, opening_debit, opening_credit, source_kind,
              source_calculation_run_id, evidence_ref, created_by, created_at, content_hash),
      UPDATE (content_hash)
  ON equity_opening_translated_balance TO app_runtime;

-- 匯率版本與觀測：建立也必須經函式（要驗 R6）
REVOKE INSERT ON exchange_rate_version FROM app_runtime;
REVOKE INSERT, UPDATE ON exchange_rate_observation FROM app_runtime;

-- SECURITY DEFINER 函式一律撤回 PUBLIC，再明示授權
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'fn_exchange_rate_transition(uuid, text, text, uuid, text, text)',
    'fn_exchange_rate_version_create(uuid, uuid, text, uuid, integer, uuid, uuid)',
    'fn_exchange_rate_observation_add(uuid, text, text, text, numeric, text, date, date, date, date, uuid)',
    'fn_currency_assignment_approve(uuid, uuid)',
    'fn_translation_policy_approve(uuid, uuid)',
    'fn_equity_lot_set_approve(uuid, uuid)',
    'fn_equity_opening_approve(uuid, uuid)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO app_runtime', f);
  END LOOP;
END $$;
-- 角色查證只由 SECURITY DEFINER 函式呼叫（以 owner 身分執行），對外不開放
REVOKE ALL ON FUNCTION fn_assert_engagement_role(uuid, text, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_assert_tenant_role(uuid, text, uuid) FROM PUBLIC;
-- 父鏈查證不同：它由**SECURITY INVOKER 的 trigger** 呼叫，執行身分就是寫入者。
-- 一併撤回會讓 app_runtime 連合法的 INSERT 都做不了，而錯誤訊息會是
-- 「permission denied for function」——看起來像權限設定壞了，不像控制生效。
REVOKE ALL ON FUNCTION fn_assert_parent_tenant(uuid, uuid, uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_assert_parent_tenant(uuid, uuid, uuid, uuid, uuid) TO app_runtime;
-- ═══ 5　P2：非 CTA 的折算結果必須帶得出方法 ═════════════════════════
-- 沒有 policy rule 的普通科目＝有折算結果卻無法回答「憑哪條方法算的」。
-- CTA 結果例外：它的來源是 CTA_RESIDUAL 與折算調整列，不經政策規則。
CREATE OR REPLACE FUNCTION fn_translation_result_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_run_tenant uuid; v_line_run uuid; v_line_tenant uuid; v_layer text;
  v_manifest uuid; v_rule_policy uuid;
BEGIN
  SELECT tenant_id, manifest_id INTO v_run_tenant, v_manifest FROM calculation_run
   WHERE calculation_run_id = NEW.calculation_run_id;
  IF v_run_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：折算結果與 run 不同租戶（INV-18）';
  END IF;
  SELECT calculation_run_id, tenant_id, posting_layer INTO v_line_run, v_line_tenant, v_layer
    FROM balance_snapshot_line WHERE snapshot_line_id = NEW.source_snapshot_line_id;
  IF v_line_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：折算結果與來源快照不同租戶（INV-18）';
  END IF;
  IF v_line_run IS DISTINCT FROM NEW.calculation_run_id THEN
    RAISE EXCEPTION 'TRANSLATION_RESULT_RUN_MISMATCH: 折算結果的來源快照屬於另一個 run（% ≠ %）', v_line_run, NEW.calculation_run_id;
  END IF;

  IF v_layer = 'TRANSLATION_ADJUSTMENT' THEN
    IF NEW.translation_policy_rule_id IS NOT NULL THEN
      RAISE EXCEPTION 'TRANSLATION_CTA_RULE_UNEXPECTED: CTA 的折算結果不經政策規則（來源是 CTA 殘差）';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.translation_policy_rule_id IS NULL THEN
    RAISE EXCEPTION 'TRANSLATION_RULE_REQUIRED: 非 CTA 的折算結果必須記錄命中的政策規則（否則答不出憑哪條方法折算）';
  END IF;
  SELECT policy_version_id INTO v_rule_policy FROM translation_policy_rule
   WHERE policy_rule_id = NEW.translation_policy_rule_id;
  IF NOT EXISTS (SELECT 1 FROM calculation_manifest_entry
                  WHERE manifest_id = v_manifest
                    AND object_type = 'TRANSLATION_POLICY_VERSION'
                    AND object_id = v_rule_policy) THEN
    RAISE EXCEPTION 'TRANSLATION_SOURCE_NOT_FROZEN: 折算結果引用的政策規則不屬本 run 凍結的政策版本';
  END IF;
  RETURN NEW;
END $$;
