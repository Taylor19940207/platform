-- 0037 折算調節的計算與判定（SLICE-M3-03 下半）
--
-- C2 的實作界線（契約寫死，否則不是第二次驗算）：
--   不得呼叫 fn_fx_materialize／fn_fx_materialize_verified；
--   不得讀 translation_result 當期望值；不得讀任何現行主檔。
--   只讀**已驗證**的 Manifest payload，並以**獨立公式**逐列輸出期望值。
--   共用計算主體會讓引擎缺陷同時出現在兩邊而互相抵銷——那時調節永遠通過。

-- ═══ 1　C2 的獨立重算：逐列期望值 ═══════════════════════════════════
CREATE FUNCTION fn_fx_expected_lines(p_run uuid)
RETURNS TABLE (account_id uuid, account_code text, posting_layer text,
               expected_debit numeric(20,2), expected_credit numeric(20,2))
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_manifest uuid; v_minor int; src jsonb; pol jsonb; rates jsonb;
  cls jsonb; rule jsonb; lots jsonb; opening jsonb; l jsonb;
  v_d numeric(20,2); v_c numeric(20,2); v_rate numeric(18,8); v_method text; v_cat text;
BEGIN
  SELECT manifest_id INTO v_manifest FROM calculation_run WHERE calculation_run_id = p_run;
  SELECT payload INTO src FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'SOURCE_CALCULATION_RUN';
  SELECT payload INTO pol FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'TRANSLATION_POLICY_VERSION';
  SELECT payload INTO rates FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'EXCHANGE_RATE_VERSION';
  SELECT (payload->>'minor_unit')::int INTO v_minor FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'CURRENCY_DEFINITION'
     AND payload->>'role' = 'REPORTING';

  FOR l IN SELECT * FROM jsonb_array_elements(src->'lines')
  LOOP
    SELECT payload INTO cls FROM calculation_manifest_entry
     WHERE manifest_id = v_manifest AND object_type = 'ACCOUNT_TRANSLATION_CLASSIFICATION'
       AND object_id = (l->>'account_id')::uuid;
    v_cat := cls->>'category';
    SELECT x INTO rule FROM jsonb_array_elements(pol->'rules') x WHERE x->>'category' = v_cat;
    v_method := rule->>'method';

    -- 獨立實作的軋差與折算公式（與引擎同語意、不同程式碼路徑）
    IF (l->>'debit')::numeric >= (l->>'credit')::numeric THEN
      v_d := (l->>'debit')::numeric - (l->>'credit')::numeric; v_c := 0;
    ELSE
      v_d := 0; v_c := (l->>'credit')::numeric - (l->>'debit')::numeric;
    END IF;

    IF v_method IN ('CLOSING','AVERAGE') THEN
      SELECT (x->>'rate')::numeric INTO v_rate
        FROM jsonb_array_elements(rates->'observations') x WHERE x->>'usage' = v_method;
      IF v_rate IS NULL THEN
        RETURN QUERY SELECT (l->>'account_id')::uuid, l->>'account_code', l->>'posting_layer',
                            NULL::numeric(20,2), NULL::numeric(20,2);
        CONTINUE;
      END IF;
      account_id := (l->>'account_id')::uuid; account_code := l->>'account_code';
      posting_layer := l->>'posting_layer';
      expected_debit := round(v_d * v_rate, v_minor);
      expected_credit := round(v_c * v_rate, v_minor);
    ELSIF v_method = 'HISTORICAL_BY_LOT' THEN
      SELECT payload INTO lots FROM calculation_manifest_entry
       WHERE manifest_id = v_manifest AND object_type = 'EQUITY_TRANSLATION_LOT_SET_VERSION'
         AND payload->>'account_id' = l->>'account_id';
      SELECT COALESCE(sum(round((x->>'functional_amount')::numeric * (x->>'rate')::numeric, v_minor)), 0)
        INTO v_rate FROM jsonb_array_elements(lots->'lots') x;
      account_id := (l->>'account_id')::uuid; account_code := l->>'account_code';
      posting_layer := l->>'posting_layer';
      expected_debit := CASE WHEN v_d > 0 THEN v_rate ELSE 0 END;
      expected_credit := CASE WHEN v_c > 0 THEN v_rate ELSE 0 END;
    ELSIF v_method = 'OPENING_TRANSLATED_BALANCE' THEN
      SELECT payload INTO opening FROM calculation_manifest_entry
       WHERE manifest_id = v_manifest AND object_type = 'EQUITY_OPENING_TRANSLATED_BALANCE'
         AND payload->>'account_id' = l->>'account_id';
      account_id := (l->>'account_id')::uuid; account_code := l->>'account_code';
      posting_layer := l->>'posting_layer';
      expected_debit := (opening->>'debit')::numeric;
      expected_credit := (opening->>'credit')::numeric;
    ELSE
      account_id := (l->>'account_id')::uuid; account_code := l->>'account_code';
      posting_layer := l->>'posting_layer';
      expected_debit := NULL; expected_credit := NULL;   -- 方法未解析
    END IF;
    RETURN NEXT;
  END LOOP;
END $$;

-- ═══ 2　調節：唯一建立入口，單一交易 ═══════════════════════════════
CREATE FUNCTION fn_translation_reconcile(
  p_run uuid, p_tolerance_version uuid, p_actor uuid, p_engine_version text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  r record; v_recon uuid; v_manifest uuid; src jsonb; pol jsonb;
  v_tol record; v_unit uuid; v_n int := 0;
  e record; a record; v_exp_d numeric(20,2); v_exp_c numeric(20,2);
  v_tot_d numeric(20,2) := 0; v_tot_c numeric(20,2) := 0;
  v_cta numeric(20,2); v_cta_expected numeric(20,2);
  v_hash text; v_scope jsonb; v_minor int; v_report text;
BEGIN
  SELECT cr.*, m.calculation_scope, m.frozen_set_content_hash
    INTO r FROM calculation_run cr
    JOIN calculation_input_manifest m ON m.manifest_id = cr.manifest_id
   WHERE cr.calculation_run_id = p_run FOR UPDATE;
  IF r.calculation_run_id IS NULL THEN
    RAISE EXCEPTION 'FX_SOURCE_RUN_NOT_FOUND: run 不存在';
  END IF;
  IF r.tenant_id IS DISTINCT FROM current_tenant() THEN
    RAISE EXCEPTION 'CROSS_TENANT_DENIED: run 不屬於目前租戶';
  END IF;
  PERFORM fn_assert_engagement_role(p_actor, 'R2', r.tenant_id, r.engagement_id);
  -- 凍結集合本身先驗過，C2 才有意義
  PERFORM fn_fx_verify_manifest(r.manifest_id);
  v_manifest := r.manifest_id;

  SELECT payload INTO pol FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'TRANSLATION_POLICY_VERSION';
  v_unit := (pol->>'reporting_unit_id')::uuid;
  SELECT payload INTO src FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'SOURCE_CALCULATION_RUN';
  SELECT (payload->>'minor_unit')::int, payload->>'code' INTO v_minor, v_report
    FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'CURRENCY_DEFINITION'
     AND payload->>'role' = 'REPORTING';

  SELECT * INTO v_tol FROM rounding_tolerance_version
   WHERE tolerance_version_id = p_tolerance_version;
  IF v_tol.tolerance_version_id IS NULL THEN
    RAISE EXCEPTION 'FX_OBJECT_NOT_FOUND: 容許值版本不存在';
  END IF;
  IF v_tol.target_currency <> v_report THEN
    RAISE EXCEPTION 'TOLERANCE_CURRENCY_PAIR_MISMATCH: 容許值版本的目標幣別為 %，本 run 的報告幣為 %',
      v_tol.target_currency, v_report;
  END IF;
  v_scope := jsonb_build_object('reporting_unit_id', v_tol.reporting_unit_id,
    'source_currency', v_tol.source_currency, 'target_currency', v_tol.target_currency);
  v_hash := fn_fx_sha(r.frozen_set_content_hash || '|' || COALESCE(r.result_content_hash,'') ||
    '|' || p_tolerance_version::text || '|' || v_tol.single_limit::text || '|' ||
    v_tol.cumulative_limit::text || '|' || v_scope::text || '|' || p_engine_version ||
    '|sqlcanon-2');

  INSERT INTO translation_reconciliation (tenant_id, engagement_id, reporting_unit_id,
          period_revision_id, calculation_run_id, tolerance_version_id, tolerance_content_hash,
          single_limit_snapshot, cumulative_limit_snapshot, scope_snapshot,
          reconciliation_engine_version, canonicalization_version, reconciliation_input_hash,
          finalized_by)
  VALUES (r.tenant_id, r.engagement_id, v_unit, r.period_revision_id, p_run,
          p_tolerance_version, fn_fx_sha(v_scope::text || v_tol.single_limit::text ||
          v_tol.cumulative_limit::text), v_tol.single_limit, v_tol.cumulative_limit, v_scope,
          p_engine_version, 'sqlcanon-2', v_hash, p_actor)
  RETURNING reconciliation_id INTO v_recon;

  -- ── C1：功能幣快照 vs 凍結來源 ──
  FOR a IN
    -- run 的過濾必須在**子查詢**裡：放進 FULL JOIN 的 ON 子句會讓其他 run
    -- 的快照全部被保留下來，然後每一列都變成「來源不符」。
    SELECT COALESCE(b.account_code, x->>'account_code') AS code,
           COALESCE(b.posting_layer, x->>'posting_layer') AS layer,
           COALESCE(b.debit, 0) AS bd, COALESCE(b.credit, 0) AS bc,
           COALESCE((x->>'debit')::numeric, 0) AS sd,
           COALESCE((x->>'credit')::numeric, 0) AS sc, b.account_id
      FROM jsonb_array_elements(src->'lines') x
      FULL JOIN (SELECT * FROM balance_snapshot_line
                  WHERE calculation_run_id = p_run
                    AND posting_layer <> 'TRANSLATION_ADJUSTMENT') b
        ON b.account_code = x->>'account_code' AND b.posting_layer = x->>'posting_layer'
  LOOP
    IF a.bd <> a.sd OR a.bc <> a.sc THEN
      v_n := v_n + 1;
      INSERT INTO translation_difference (tenant_id, reconciliation_id, check_id, account_id,
              account_code, posting_layer, comparison_context, actual_amount, comparison_amount,
              actual_difference, reason_class, detail, line_no)
      VALUES (r.tenant_id, v_recon, 'C1', a.account_id, a.code, a.layer,
              'INTERNAL_RECALCULATION', a.bd - a.bc, a.sd - a.sc, (a.bd - a.bc) - (a.sd - a.sc),
              'SOURCE_MISMATCH', '功能幣快照與凍結來源不一致', v_n);
    END IF;
  END LOOP;

  -- ── C2：報告幣結果 vs 獨立重算 ──
  FOR e IN SELECT * FROM fn_fx_expected_lines(p_run)
  LOOP
    SELECT tr.result_debit, tr.result_credit INTO v_exp_d, v_exp_c
      FROM translation_result tr
      JOIN balance_snapshot_line b ON b.snapshot_line_id = tr.source_snapshot_line_id
     WHERE tr.calculation_run_id = p_run AND b.account_code = e.account_code
       AND b.posting_layer = e.posting_layer;
    IF e.expected_debit IS NULL THEN
      v_n := v_n + 1;
      INSERT INTO translation_difference (tenant_id, reconciliation_id, check_id, account_id,
              account_code, posting_layer, comparison_context, actual_amount, comparison_amount,
              actual_difference, reason_class, detail, line_no)
      VALUES (r.tenant_id, v_recon, 'C2', e.account_id, e.account_code, e.posting_layer,
              'INTERNAL_RECALCULATION', COALESCE(v_exp_d,0) - COALESCE(v_exp_c,0), 0,
              COALESCE(v_exp_d,0) - COALESCE(v_exp_c,0), 'METHOD_UNRESOLVED',
              '凍結集合中的方法或匯率無法解析', v_n);
    ELSIF COALESCE(v_exp_d,0) <> e.expected_debit OR COALESCE(v_exp_c,0) <> e.expected_credit THEN
      v_n := v_n + 1;
      INSERT INTO translation_difference (tenant_id, reconciliation_id, check_id, account_id,
              account_code, posting_layer, comparison_context, actual_amount, comparison_amount,
              actual_difference, reason_class, detail, line_no)
      VALUES (r.tenant_id, v_recon, 'C2', e.account_id, e.account_code, e.posting_layer,
              'INTERNAL_RECALCULATION',
              COALESCE(v_exp_d,0) - COALESCE(v_exp_c,0),
              e.expected_debit - e.expected_credit,
              (COALESCE(v_exp_d,0) - COALESCE(v_exp_c,0)) - (e.expected_debit - e.expected_credit),
              'UNEXPLAINED', '報告幣結果與獨立重算不一致', v_n);
    END IF;
    v_tot_d := v_tot_d + COALESCE(e.expected_debit, 0);
    v_tot_c := v_tot_c + COALESCE(e.expected_credit, 0);
  END LOOP;

  -- ── C3：CTA vs 報告幣合計差額 ──
  v_cta_expected := v_tot_c - v_tot_d;
  SELECT COALESCE(sum(tl.debit) - sum(tl.credit), 0) INTO v_cta
    FROM translation_adjustment_line tl
    JOIN translation_adjustment_entry te ON te.translation_entry_id = tl.translation_entry_id
   WHERE te.calculation_run_id = p_run;
  IF v_cta <> v_cta_expected THEN
    v_n := v_n + 1;
    INSERT INTO translation_difference (tenant_id, reconciliation_id, check_id,
            comparison_context, actual_amount, comparison_amount, actual_difference,
            reason_class, detail, line_no)
    VALUES (r.tenant_id, v_recon, 'C3', 'INTERNAL_RECALCULATION', v_cta, v_cta_expected,
            v_cta - v_cta_expected, 'CTA_MISMATCH', 'CTA 與報告幣借貸合計差額不符', v_n);
  END IF;

  -- ── C4：含 CTA 後的報告幣平衡 ──
  IF (v_tot_d + GREATEST(v_cta, 0)) <> (v_tot_c + GREATEST(-v_cta, 0)) THEN
    v_n := v_n + 1;
    INSERT INTO translation_difference (tenant_id, reconciliation_id, check_id,
            comparison_context, actual_amount, comparison_amount, actual_difference,
            reason_class, detail, line_no)
    VALUES (r.tenant_id, v_recon, 'C4', 'INTERNAL_RECALCULATION',
            v_tot_d + GREATEST(v_cta, 0), v_tot_c + GREATEST(-v_cta, 0),
            (v_tot_d + GREATEST(v_cta, 0)) - (v_tot_c + GREATEST(-v_cta, 0)),
            'CTA_MISMATCH', '加入 CTA 後報告幣仍不平衡', v_n);
  END IF;

  -- INV-24：兩層同時滿足才自動結案（本刀的內部核對不產生尾差，
  -- 因此這段在生產流程下必然是空集合；它為對外核對而存在）
  PERFORM fn_translation_apply_tolerance(v_recon);
  RETURN v_recon;
END $$;

-- INV-24：單筆與累積**同時**滿足；一律絕對值加總，禁止淨額互抵；
-- 任一不滿足則**全部**尾差維持 OPEN。
CREATE FUNCTION fn_translation_apply_tolerance(p_recon uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_single numeric(20,2); v_cum numeric(20,2); v_sum numeric(20,2);
        v_max numeric(20,2); v_tol uuid;
BEGIN
  SELECT single_limit_snapshot, cumulative_limit_snapshot, tolerance_version_id
    INTO v_single, v_cum, v_tol FROM translation_reconciliation WHERE reconciliation_id = p_recon;
  SELECT COALESCE(sum(abs(actual_difference)), 0), COALESCE(max(abs(actual_difference)), 0)
    INTO v_sum, v_max FROM translation_difference
   WHERE reconciliation_id = p_recon AND reason_class = 'ROUNDING_DIFFERENCE';
  IF v_max = 0 THEN RETURN; END IF;
  IF v_max > v_single OR v_sum > v_cum THEN
    RETURN;   -- 任一超限：全部維持 OPEN
  END IF;
  UPDATE translation_difference
     SET resolution_status = 'RESOLVED_BY_POLICY',
         threshold_policy_version_id = v_tol,
         cumulative_at_resolution = v_sum
   WHERE reconciliation_id = p_recon AND reason_class = 'ROUNDING_DIFFERENCE';
END $$;

-- 人工處理：只允許 OPEN → EXPLAINED／ACCEPTED_EXCEPTION
CREATE FUNCTION fn_translation_difference_resolve(
  p_difference uuid, p_actor uuid, p_status text, p_ref text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_tenant uuid; v_eng uuid;
BEGIN
  SELECT d.tenant_id, rc.engagement_id INTO v_tenant, v_eng
    FROM translation_difference d
    JOIN translation_reconciliation rc ON rc.reconciliation_id = d.reconciliation_id
   WHERE d.difference_id = p_difference FOR UPDATE;
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'FX_OBJECT_NOT_FOUND: 差異不存在'; END IF;
  IF v_tenant IS DISTINCT FROM current_tenant() THEN
    RAISE EXCEPTION 'CROSS_TENANT_DENIED: 差異不屬於目前租戶';
  END IF;
  IF p_status = 'ACCEPTED_EXCEPTION' THEN
    PERFORM fn_assert_engagement_role(p_actor, 'R4', v_tenant, v_eng);
  ELSE
    PERFORM fn_assert_engagement_role(p_actor, 'R3', v_tenant, v_eng);
  END IF;
  IF p_ref IS NULL OR btrim(p_ref) = '' THEN
    RAISE EXCEPTION 'FX_DIFFERENCE_REASON_REQUIRED: 人工處理必須留下調查結論';
  END IF;
  PERFORM set_config('app.fx_recon_resolve', '1', true);
  UPDATE translation_difference
     SET resolution_status = p_status, resolved_by = p_actor, resolved_at = now(),
         resolution_ref = p_ref
   WHERE difference_id = p_difference;
  PERFORM set_config('app.fx_recon_resolve', '', true);
END $$;

-- ═══ 3　兩個選定函式（TOCTOU：先鎖 period_revision）═════════════════
CREATE FUNCTION fn_period_fx_select_inputs(
  p_period_revision uuid, p_source_run uuid, p_rate_version uuid, p_policy_version uuid,
  p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_tenant uuid; v_eng uuid; v_unit uuid; v_cur uuid; v_series uuid; v_no int; v_id uuid;
BEGIN
  -- 鎖住期間：判定「現行 selection」與寫入新版本之間不得被併發插隊
  SELECT pr.tenant_id, rp.engagement_id, rp.reporting_unit_id INTO v_tenant, v_eng, v_unit
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = p_period_revision FOR UPDATE OF pr;
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'FX_PERIOD_NOT_FOUND: 期間修訂不存在'; END IF;
  IF v_tenant IS DISTINCT FROM current_tenant() THEN
    RAISE EXCEPTION 'CROSS_TENANT_DENIED: 期間修訂不屬於目前租戶';
  END IF;
  -- 選輸入是作業（R2）；選結論才是批准（R4）
  PERFORM fn_assert_engagement_role(p_actor, 'R2', v_tenant, v_eng);

  PERFORM 1 FROM calculation_run WHERE calculation_run_id = p_source_run
     AND tenant_id = v_tenant AND engagement_id = v_eng
     AND period_revision_id = p_period_revision AND status = 'COMPLETED';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FX_INPUT_SOURCE_RUN_INVALID: 來源 run 不存在、不屬本期本案件或尚未完成';
  END IF;
  PERFORM 1 FROM exchange_rate_version WHERE rate_version_id = p_rate_version
     AND tenant_id = v_tenant AND engagement_id = v_eng;
  IF NOT FOUND THEN
    RAISE EXCEPTION '§24.1A：匯率版本不屬本案件';
  END IF;
  PERFORM 1 FROM translation_policy_version WHERE policy_version_id = p_policy_version
     AND tenant_id = v_tenant AND engagement_id = v_eng AND reporting_unit_id = v_unit;
  IF NOT FOUND THEN
    RAISE EXCEPTION '§24.1A：折算政策不屬本案件本單位';
  END IF;

  v_cur := fn_current_fx_input_selection(p_period_revision);
  IF v_cur IS NULL THEN
    v_series := gen_random_uuid(); v_no := 1;
  ELSE
    SELECT selection_series_id, version_no + 1 INTO v_series, v_no
      FROM period_fx_input_selection WHERE input_selection_id = v_cur;
  END IF;
  INSERT INTO period_fx_input_selection (tenant_id, engagement_id, period_revision_id,
          reporting_unit_id, source_run_id, exchange_rate_version_id,
          translation_policy_version_id, selection_series_id, version_no,
          supersedes_selection_id, selected_by)
  VALUES (v_tenant, v_eng, p_period_revision, v_unit, p_source_run, p_rate_version,
          p_policy_version, v_series, v_no, v_cur, p_actor)
  RETURNING input_selection_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION fn_period_fx_select_run(
  p_period_revision uuid, p_run uuid, p_reconciliation uuid, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_tenant uuid; v_eng uuid; v_unit uuid; v_cur uuid; v_series uuid; v_no int; v_id uuid;
  v_run record; v_rc record;
BEGIN
  SELECT pr.tenant_id, rp.engagement_id, rp.reporting_unit_id INTO v_tenant, v_eng, v_unit
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = p_period_revision FOR UPDATE OF pr;
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'FX_PERIOD_NOT_FOUND: 期間修訂不存在'; END IF;
  IF v_tenant IS DISTINCT FROM current_tenant() THEN
    RAISE EXCEPTION 'CROSS_TENANT_DENIED: 期間修訂不屬於目前租戶';
  END IF;
  -- 選結論是批准行為
  PERFORM fn_assert_engagement_role(p_actor, 'R4', v_tenant, v_eng);

  SELECT * INTO v_run FROM calculation_run WHERE calculation_run_id = p_run;
  IF v_run.calculation_run_id IS NULL
  OR v_run.tenant_id IS DISTINCT FROM v_tenant
  OR v_run.engagement_id IS DISTINCT FROM v_eng
  OR v_run.period_revision_id IS DISTINCT FROM p_period_revision THEN
    RAISE EXCEPTION '§24.1A：選定的 run 不屬本案件本期';
  END IF;
  IF v_run.status <> 'COMPLETED' THEN
    RAISE EXCEPTION 'FX_SELECTION_RUN_NOT_COMPLETED: 只有已完成的 run 可被選定（目前 %）', v_run.status;
  END IF;
  IF v_run.replay_of_run_id IS NOT NULL THEN
    RAISE EXCEPTION 'FX_SELECTION_RUN_IS_REPLAY: replay 是驗證行為，不得作為現行結論';
  END IF;
  SELECT * INTO v_rc FROM translation_reconciliation WHERE reconciliation_id = p_reconciliation;
  IF v_rc.reconciliation_id IS NULL OR v_rc.calculation_run_id IS DISTINCT FROM p_run THEN
    RAISE EXCEPTION 'FX_SELECTION_RECON_MISMATCH: 選定的調節不屬於選定的 run';
  END IF;
  IF v_rc.tenant_id IS DISTINCT FROM v_tenant OR v_rc.engagement_id IS DISTINCT FROM v_eng
  OR v_rc.reporting_unit_id IS DISTINCT FROM v_unit THEN
    RAISE EXCEPTION '§24.1A：選定的調節不屬本案件本單位';
  END IF;

  v_cur := fn_current_fx_run_selection(p_period_revision);
  IF v_cur IS NULL THEN
    v_series := gen_random_uuid(); v_no := 1;
  ELSE
    SELECT selection_series_id, version_no + 1 INTO v_series, v_no
      FROM period_fx_run_selection WHERE run_selection_id = v_cur;
  END IF;
  INSERT INTO period_fx_run_selection (tenant_id, engagement_id, period_revision_id,
          reporting_unit_id, selected_run_id, selected_reconciliation_id,
          selection_series_id, version_no, supersedes_selection_id, selected_by)
  VALUES (v_tenant, v_eng, p_period_revision, v_unit, p_run, p_reconciliation,
          v_series, v_no, v_cur, p_actor)
  RETURNING run_selection_id INTO v_id;
  RETURN v_id;
END $$;

-- ═══ 4　引擎前置檢查：實際輸入必須等於現行 InputSelection ═══════════
-- 否則「G-07 通過的輸入」與「實際拿去算的輸入」可能不是同一組。
-- 簽章與計算行為不變（M3-02 的斷言一字不改）；只是多一道前置。
CREATE FUNCTION fn_fx_assert_input_selected(
  p_period_revision uuid, p_source_run uuid, p_rate_version uuid, p_policy_version uuid
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE s record;
BEGIN
  -- TOCTOU：與選定函式鎖同一筆期間
  PERFORM 1 FROM period_revision WHERE period_revision_id = p_period_revision FOR UPDATE;
  SELECT * INTO s FROM period_fx_input_selection
   WHERE input_selection_id = fn_current_fx_input_selection(p_period_revision);
  IF s.input_selection_id IS NULL THEN
    RAISE EXCEPTION 'FX_INPUT_NOT_SELECTED: 本期尚未選定折算輸入（來源 run／匯率版本／政策版本）';
  END IF;
  IF s.source_run_id IS DISTINCT FROM p_source_run
  OR s.exchange_rate_version_id IS DISTINCT FROM p_rate_version
  OR s.translation_policy_version_id IS DISTINCT FROM p_policy_version THEN
    RAISE EXCEPTION 'FX_INPUT_NOT_SELECTED: 傳入的輸入與現行選定不一致（選定＝%／%／%）',
      s.source_run_id, s.exchange_rate_version_id, s.translation_policy_version_id;
  END IF;
END $$;

-- ═══ 5　權限 ═══════════════════════════════════════════════════════
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'fn_rounding_tolerance_approve(uuid, uuid)',
    'fn_translation_reconcile(uuid, uuid, uuid, text)',
    'fn_translation_difference_resolve(uuid, uuid, text, text)',
    'fn_period_fx_select_inputs(uuid, uuid, uuid, uuid, uuid)',
    'fn_period_fx_select_run(uuid, uuid, uuid, uuid)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO app_runtime', f);
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION fn_fx_expected_lines(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_translation_apply_tolerance(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_fx_assert_input_selected(uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_current_fx_input_selection(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_current_fx_run_selection(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_current_fx_input_selection(uuid) TO app_runtime;
GRANT EXECUTE ON FUNCTION fn_current_fx_run_selection(uuid) TO app_runtime;
