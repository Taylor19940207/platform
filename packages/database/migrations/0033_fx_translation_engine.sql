-- 0033 折算引擎（SLICE-M3-02 計算主線）
--
-- 一支函式、一個交易：凍結 → 建立 run → 折算 → 物化 → 完成。
-- 任何一步失敗即整筆回滾，**不留下半套 run**（G-07 的 output_capability = NONE
-- 要求連預覽都不產生）。
--
-- 三條不可退讓：
--   1. **只讀 Manifest**：折算一律用凍結值，不回查現行主檔。否則「凍結」只是裝飾。
--   2. **全程 numeric**：金額與匯率都不進浮點；逐行 ROUND_HALF_UP，
--      合計＝已捨入值的加總。
--   3. **沒有靜默回退**：缺率、缺分類、lots 不平、期初延續不成立一律 fail closed。

-- Manifest 是 append-only（0012）：`frozen_set_content_hash` 必須在**建立之前**
-- 算好，因此凍結條目先收集成 jsonb，算完雜湊再一次寫入。
CREATE FUNCTION fn_fx_freeze_entry(
  p_entries jsonb, p_type text, p_object uuid, p_kind text, p_value text, p_canonical text
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT p_entries || jsonb_build_object(
    'object_type', p_type, 'object_id', p_object, 'kind', p_kind,
    'value', p_value, 'canonical', p_canonical, 'hash', md5(p_canonical))
$$;

-- ── 主函式 ──────────────────────────────────────────────────────────
CREATE FUNCTION fn_fx_translation_run(
  p_tenant uuid, p_engagement uuid, p_period_revision uuid, p_reporting_unit uuid,
  p_source_run uuid, p_rate_version uuid, p_policy_version uuid,
  p_actor uuid, p_engine_version text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_manifest uuid; v_run uuid; v_batch uuid;
  v_period_end date; v_period_start date;
  v_func text; v_report text; v_func_asg uuid; v_report_asg uuid;
  v_minor int; v_rate_close numeric(18,8); v_obs_close uuid;
  v_rate_avg numeric(18,8); v_obs_avg uuid;
  r record; c record; l record;
  v_cat text; v_method text; v_rule uuid;
  v_snap bigint; v_res uuid; v_amt numeric(20,2); v_sum numeric(20,2);
  v_set uuid; v_open uuid; v_open_d numeric(20,2); v_open_c numeric(20,2);
  v_tot_d numeric(20,2) := 0; v_tot_c numeric(20,2) := 0; v_cta numeric(20,2);
  v_entry uuid; v_line uuid; v_cta_acc uuid; v_canon text; v_n int;
  v_entries jsonb := '[]'::jsonb; e jsonb; v_rate numeric(18,8); v_obs uuid;
  v_src_d numeric(20,2); v_src_c numeric(20,2);
BEGIN
  -- 0 發起人：B-06 的計算執行屬 R2（§24.6／§28）
  PERFORM fn_assert_engagement_role(p_actor, 'R2', p_tenant, p_engagement);

  SELECT rp.start_date, rp.end_date INTO v_period_start, v_period_end
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = p_period_revision;
  IF v_period_end IS NULL THEN
    RAISE EXCEPTION 'FX_PERIOD_NOT_FOUND: 期間修訂不存在';
  END IF;

  -- 1 幣別角色：兩個都要，且都必須已批准並涵蓋期末
  SELECT assignment_id, currency_code INTO v_func_asg, v_func
    FROM reporting_unit_currency_assignment
   WHERE reporting_unit_id = p_reporting_unit AND currency_role = 'FUNCTIONAL'
     AND approved_at IS NOT NULL AND effective_range @> v_period_end;
  SELECT assignment_id, currency_code INTO v_report_asg, v_report
    FROM reporting_unit_currency_assignment
   WHERE reporting_unit_id = p_reporting_unit AND currency_role = 'REPORTING'
     AND approved_at IS NOT NULL AND effective_range @> v_period_end;
  IF v_func IS NULL OR v_report IS NULL THEN
    RAISE EXCEPTION 'FX_CURRENCY_ASSIGNMENT_MISSING: 本期缺少已批准的功能幣或報告幣指派（功能幣 %、報告幣 %）', v_func, v_report;
  END IF;
  IF v_func = v_report THEN
    RAISE EXCEPTION 'FX_NO_TRANSLATION_NEEDED: 功能幣與報告幣相同，不需折算';
  END IF;
  SELECT minor_unit INTO v_minor FROM currency WHERE currency_code = v_report;

  -- 2 匯率版本：必須已批准（G-07 的 output_capability = NONE）
  PERFORM 1 FROM exchange_rate_version
   WHERE rate_version_id = p_rate_version AND tenant_id = p_tenant
     AND engagement_id = p_engagement AND status = 'APPROVED';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'G07_RATE_VERSION_NOT_FROZEN: 匯率版本未指定、不屬本案件或尚未批准，整期折算不可用';
  END IF;

  -- 3 折算政策：必須已批准
  PERFORM 1 FROM translation_policy_version
   WHERE policy_version_id = p_policy_version AND tenant_id = p_tenant
     AND engagement_id = p_engagement AND reporting_unit_id = p_reporting_unit
     AND approved_at IS NOT NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TRANSLATION_POLICY_NOT_APPROVED: 折算政策版本未指定、不屬本單位或尚未批准';
  END IF;
  SELECT cta_account_id INTO v_cta_acc FROM translation_policy_version
   WHERE policy_version_id = p_policy_version;

  -- 4 期末與期中匯率：只接受直接幣別對，不倒數不交叉
  SELECT observation_id, rate INTO v_obs_close, v_rate_close
    FROM exchange_rate_observation
   WHERE rate_version_id = p_rate_version AND from_currency = v_func
     AND to_currency = v_report AND rate_type = 'CLOSING'
     AND measurement_date = v_period_end;
  IF v_obs_close IS NULL THEN
    RAISE EXCEPTION 'FX_RATE_MISSING: 缺 % → % 的 CLOSING 匯率（計量日 %）', v_func, v_report, v_period_end;
  END IF;
  SELECT observation_id, rate INTO v_obs_avg, v_rate_avg
    FROM exchange_rate_observation
   WHERE rate_version_id = p_rate_version AND from_currency = v_func
     AND to_currency = v_report AND rate_type = 'AVERAGE'
     AND coverage_start <= v_period_start AND coverage_end >= v_period_end;
  IF v_obs_avg IS NULL THEN
    RAISE EXCEPTION 'FX_RATE_COVERAGE_MISMATCH: 缺涵蓋 % ～ % 的 AVERAGE 匯率', v_period_start, v_period_end;
  END IF;

  -- 5 來源 run 的每個科目都必須有分類，且恰好命中一條政策規則
  FOR r IN SELECT DISTINCT a.account_id, a.code, a.translation_category
             FROM balance_snapshot_line bsl
             JOIN account a ON a.account_id = bsl.account_id
            WHERE bsl.calculation_run_id = p_source_run
            ORDER BY a.code
  LOOP
    IF r.translation_category IS NULL THEN
      RAISE EXCEPTION 'FX_METHOD_UNRESOLVED: 科目 % 沒有折算分類', r.code;
    END IF;
    SELECT count(*) INTO v_n FROM translation_policy_rule
     WHERE policy_version_id = p_policy_version AND translation_category = r.translation_category;
    IF v_n = 0 THEN
      RAISE EXCEPTION 'FX_METHOD_UNRESOLVED: 分類 %（科目 %）在本政策版本沒有對應規則', r.translation_category, r.code;
    END IF;
  END LOOP;

  -- 6 凍結集合：先收集、算雜湊，再建立 manifest（append-only，不能事後回填）

  v_entries := fn_fx_freeze_entry(v_entries, 'CURRENCY_DEFINITION', NULL, 'minor_unit',
    (SELECT minor_unit::text FROM currency WHERE currency_code = v_func),
    'currency=' || v_func || ';minor_unit=' || (SELECT minor_unit::text FROM currency WHERE currency_code = v_func));
  v_entries := fn_fx_freeze_entry(v_entries, 'CURRENCY_DEFINITION', NULL, 'minor_unit',
    v_minor::text, 'currency=' || v_report || ';minor_unit=' || v_minor::text);
  v_entries := fn_fx_freeze_entry(v_entries, 'CURRENCY_ASSIGNMENT', v_func_asg, 'role',
    'FUNCTIONAL', 'role=FUNCTIONAL;currency=' || v_func);
  v_entries := fn_fx_freeze_entry(v_entries, 'CURRENCY_ASSIGNMENT', v_report_asg, 'role',
    'REPORTING', 'role=REPORTING;currency=' || v_report);
  SELECT string_agg(from_currency || '>' || to_currency || ':' || rate_type || ':' ||
                    COALESCE(measurement_date::text, coverage_start::text || '~' || coverage_end::text,
                             event_date::text) || '=' || rate::text, '|' ORDER BY observation_id)
    INTO v_canon FROM exchange_rate_observation WHERE rate_version_id = p_rate_version;
  v_entries := fn_fx_freeze_entry(v_entries, 'EXCHANGE_RATE_VERSION', p_rate_version,
    'version', '1', COALESCE(v_canon, ''));
  SELECT string_agg(translation_category || '=' || method, '|' ORDER BY translation_category)
    INTO v_canon FROM translation_policy_rule WHERE policy_version_id = p_policy_version;
  v_entries := fn_fx_freeze_entry(v_entries, 'TRANSLATION_POLICY_VERSION', p_policy_version,
    'version', '1', COALESCE(v_canon, '') || ';cta=' || v_cta_acc::text);

  -- 科目分類獨立凍結：不得併進既有的 CHART_OF_ACCOUNTS 條目
  FOR r IN SELECT DISTINCT a.account_id, a.code, a.translation_category
             FROM balance_snapshot_line bsl
             JOIN account a ON a.account_id = bsl.account_id
            WHERE bsl.calculation_run_id = p_source_run
            ORDER BY a.code
  LOOP
    SELECT policy_rule_id INTO v_rule FROM translation_policy_rule
     WHERE policy_version_id = p_policy_version AND translation_category = r.translation_category;
    v_entries := fn_fx_freeze_entry(v_entries, 'ACCOUNT_TRANSLATION_CLASSIFICATION',
      r.account_id, 'category', r.translation_category,
      'account=' || r.code || ';category=' || r.translation_category || ';rule=' || v_rule::text);

    -- 權益：lot set 與期初餘額也在此凍結，並先驗合計
    IF r.translation_category IN ('EQUITY_CONTRIBUTED','EQUITY_DISTRIBUTION','EQUITY_OTHER') THEN
      SELECT count(*) INTO v_n FROM balance_snapshot_line
       WHERE calculation_run_id = p_source_run AND account_id = r.account_id;
      IF v_n > 1 THEN
        RAISE EXCEPTION 'FX_EQUITY_ACCOUNT_SPLIT_UNSUPPORTED: 權益科目 % 在本 run 有 % 列，逐筆歷史折算無法判定該把哪一列拆給哪一筆出資', r.code, v_n;
      END IF;
      SELECT sv.set_version_id INTO v_set FROM equity_translation_lot_set_version sv
       WHERE sv.account_id = r.account_id AND sv.reporting_unit_id = p_reporting_unit
         AND sv.approved_at IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM equity_translation_lot_set_version n
                          WHERE n.supersedes_set_version_id = sv.set_version_id)
       ORDER BY sv.version_no DESC LIMIT 1;
      IF v_set IS NULL THEN
        RAISE EXCEPTION 'EQUITY_LOT_SET_MISSING: 權益科目 % 沒有已批准的折算批次集合', r.code;
      END IF;
      SELECT COALESCE(sum(functional_amount),0) INTO v_sum
        FROM equity_translation_lot WHERE set_version_id = v_set;
      SELECT COALESCE(sum(debit),0) - COALESCE(sum(credit),0) INTO v_amt
        FROM balance_snapshot_line
       WHERE calculation_run_id = p_source_run AND account_id = r.account_id;
      IF v_sum <> abs(v_amt) THEN
        RAISE EXCEPTION 'EQUITY_LOT_SUM_MISMATCH: 科目 % 的批次合計 % 與功能幣餘額 % 不符', r.code, v_sum, abs(v_amt);
      END IF;
      SELECT string_agg(event_date::text || '=' || functional_amount::text, '|' ORDER BY line_no)
        INTO v_canon FROM equity_translation_lot WHERE set_version_id = v_set;
      v_entries := fn_fx_freeze_entry(v_entries, 'EQUITY_TRANSLATION_LOT_SET_VERSION',
        v_set, 'set_version', '1', COALESCE(v_canon, ''));
    ELSIF r.translation_category = 'EQUITY_RETAINED' THEN
      SELECT count(*) INTO v_n FROM balance_snapshot_line
       WHERE calculation_run_id = p_source_run AND account_id = r.account_id;
      IF v_n > 1 THEN
        RAISE EXCEPTION 'FX_EQUITY_ACCOUNT_SPLIT_UNSUPPORTED: 保留盈餘科目 % 在本 run 有 % 列', r.code, v_n;
      END IF;
      SELECT opening_id, opening_debit, opening_credit INTO v_open, v_open_d, v_open_c
        FROM equity_opening_translated_balance
       WHERE period_revision_id = p_period_revision AND account_id = r.account_id
         AND approved_at IS NOT NULL;
      IF v_open IS NULL THEN
        RAISE EXCEPTION 'FX_OPENING_EQUITY_MISSING: 科目 % 缺已批准的期初已折算餘額（保留盈餘不得以餘額乘匯率求得）', r.code;
      END IF;
      v_entries := fn_fx_freeze_entry(v_entries, 'EQUITY_OPENING_TRANSLATED_BALANCE',
        v_open, 'opening', '1', 'debit=' || v_open_d::text || ';credit=' || v_open_c::text);
    END IF;
  END LOOP;

  -- 精度改讀**凍結值**：從此刻起權威來源是凍結集合，不是現行主檔。
  SELECT (x->>'value')::int INTO v_minor
    FROM jsonb_array_elements(v_entries) x
   WHERE x->>'object_type' = 'CURRENCY_DEFINITION'
     AND x->>'canonical' LIKE 'currency=' || v_report || '%';

  SELECT md5(string_agg(x->>'hash', '|'
             ORDER BY x->>'object_type', COALESCE(x->>'object_id', ''), x->>'hash'))
    INTO v_canon FROM jsonb_array_elements(v_entries) x;
  v_manifest := gen_random_uuid();
  INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
          calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
  VALUES (v_manifest, p_tenant, p_engagement, p_period_revision, 'FX_TRANSLATION', 'sqlcanon-2',
          v_canon, p_actor);
  FOR e IN SELECT * FROM jsonb_array_elements(v_entries) LOOP
    INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
            domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
    VALUES (p_tenant, v_manifest, e->>'object_type', (e->>'object_id')::uuid,
            e->>'kind', e->>'value', e->>'canonical', e->>'hash', '{}'::jsonb);
  END LOOP;

  -- 7 建立 run
  SELECT import_batch_id INTO v_batch FROM calculation_run WHERE calculation_run_id = p_source_run;
  v_run := gen_random_uuid();
  INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
          import_batch_id, manifest_id, run_type, status, request_key, request_content_hash,
          engine_version, created_by)
  VALUES (v_run, p_tenant, p_engagement, p_period_revision, v_batch, v_manifest, 'PREVIEW',
          'RUNNING', gen_random_uuid(), v_canon, p_engine_version, p_actor);

  -- 8 折算：逐行、逐 component ROUND_HALF_UP，全程 numeric
  FOR l IN SELECT bsl.snapshot_line_id, bsl.posting_layer, bsl.account_id, bsl.account_code,
                  bsl.account_name, bsl.debit, bsl.credit, bsl.posting_layer_id,
                  a.translation_category
             FROM balance_snapshot_line bsl
             JOIN account a ON a.account_id = bsl.account_id
            WHERE bsl.calculation_run_id = p_source_run
            ORDER BY bsl.account_code, bsl.posting_layer
  LOOP
    INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
            account_code, account_name, debit, credit, posting_layer_id)
    VALUES (p_tenant, v_run, l.posting_layer, l.account_id, l.account_code, l.account_name,
            l.debit, l.credit, l.posting_layer_id)
    RETURNING snapshot_line_id INTO v_snap;

    SELECT policy_rule_id, method INTO v_rule, v_method FROM translation_policy_rule
     WHERE policy_version_id = p_policy_version AND translation_category = l.translation_category;

    -- 先軋差再折算：折算的對象是**餘額**，不是借貸兩個方向各自的發生額。
    -- 同一列同時有借有貸時分開折算再相加，結果相同但會產生雙邊的結果列，
    -- 而「一個餘額有兩個方向」在報表上沒有意義。
    IF l.debit >= l.credit THEN
      v_src_d := l.debit - l.credit; v_src_c := 0;
    ELSE
      v_src_d := 0; v_src_c := l.credit - l.debit;
    END IF;

    -- 彙總必須先算好：折算產出建立後不可 UPDATE（0031），
    -- 而彙總＝**已捨入明細**的加總，不得由未捨入值另算一次。
    IF v_method = 'CLOSING' THEN
      v_rate := v_rate_close; v_obs := v_obs_close;
    ELSIF v_method = 'AVERAGE' THEN
      v_rate := v_rate_avg; v_obs := v_obs_avg;
    END IF;
    IF v_method IN ('CLOSING','AVERAGE') THEN
      v_amt := round(v_src_d * v_rate, v_minor);
      v_sum := round(v_src_c * v_rate, v_minor);
    ELSIF v_method = 'HISTORICAL_BY_LOT' THEN
      SELECT sv.set_version_id INTO v_set FROM equity_translation_lot_set_version sv
       WHERE sv.account_id = l.account_id AND sv.reporting_unit_id = p_reporting_unit
         AND sv.approved_at IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM equity_translation_lot_set_version n
                          WHERE n.supersedes_set_version_id = sv.set_version_id)
       ORDER BY sv.version_no DESC LIMIT 1;
      SELECT COALESCE(sum(round(lot.functional_amount * o.rate, v_minor)), 0) INTO v_amt
        FROM equity_translation_lot lot
        JOIN exchange_rate_observation o ON o.observation_id = lot.exchange_rate_observation_id
       WHERE lot.set_version_id = v_set;
      IF v_src_c > 0 THEN v_sum := v_amt; v_amt := 0; ELSE v_sum := 0; END IF;
    ELSIF v_method = 'OPENING_TRANSLATED_BALANCE' THEN
      SELECT opening_id, opening_debit, opening_credit INTO v_open, v_open_d, v_open_c
        FROM equity_opening_translated_balance
       WHERE period_revision_id = p_period_revision AND account_id = l.account_id
         AND approved_at IS NOT NULL;
      v_amt := v_open_d; v_sum := v_open_c;
    ELSE
      RAISE EXCEPTION 'FX_METHOD_UNRESOLVED: 未知的折算方法 %', v_method;
    END IF;

    INSERT INTO translation_result (tenant_id, calculation_run_id, source_snapshot_line_id,
            amount_role, currency_code, source_debit, source_credit,
            result_debit, result_credit, translation_policy_rule_id)
    VALUES (p_tenant, v_run, v_snap, 'REPORTING', v_report, v_src_d, v_src_c,
            v_amt, v_sum, v_rule)
    RETURNING translation_result_id INTO v_res;

    IF v_method IN ('CLOSING','AVERAGE') THEN
      INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no,
              source_kind, exchange_rate_observation_id, source_debit, source_credit,
              result_debit, result_credit)
      VALUES (p_tenant, v_res, 1, 'RATE_TRANSLATION', v_obs, v_src_d, v_src_c, v_amt, v_sum);
    ELSIF v_method = 'HISTORICAL_BY_LOT' THEN
      FOR c IN SELECT lot.lot_id, lot.line_no, lot.functional_amount,
                      lot.exchange_rate_observation_id, o.rate
                 FROM equity_translation_lot lot
                 JOIN exchange_rate_observation o
                   ON o.observation_id = lot.exchange_rate_observation_id
                WHERE lot.set_version_id = v_set ORDER BY lot.line_no
      LOOP
        INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no,
                source_kind, equity_lot_id, exchange_rate_observation_id,
                source_debit, source_credit, result_debit, result_credit)
        VALUES (p_tenant, v_res, c.line_no, 'EQUITY_LOT', c.lot_id, c.exchange_rate_observation_id,
                CASE WHEN v_src_d > 0 THEN c.functional_amount ELSE 0 END,
                CASE WHEN v_src_c > 0 THEN c.functional_amount ELSE 0 END,
                CASE WHEN v_src_d > 0 THEN round(c.functional_amount * c.rate, v_minor) ELSE 0 END,
                CASE WHEN v_src_c > 0 THEN round(c.functional_amount * c.rate, v_minor) ELSE 0 END);
      END LOOP;
    ELSE
      INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no,
              source_kind, opening_balance_id, source_debit, source_credit,
              result_debit, result_credit)
      VALUES (p_tenant, v_res, 1, 'OPENING_TRANSLATED_BALANCE', v_open, v_src_d, v_src_c,
              v_open_d, v_open_c);
    END IF;

    v_tot_d := v_tot_d + v_amt;
    v_tot_c := v_tot_c + v_sum;
  END LOOP;

  -- 9 CTA：報告幣下已捨入的借貸合計差額。**不得**以功能幣合計與報告幣合計相減。
  v_cta := v_tot_c - v_tot_d;
  IF v_cta <> 0 THEN
    INSERT INTO translation_adjustment_entry (tenant_id, engagement_id, reporting_unit_id,
            period_revision_id, calculation_run_id, posting_layer_id, rule_type,
            reporting_currency, translation_policy_version_id, exchange_rate_version_id)
    VALUES (p_tenant, p_engagement, p_reporting_unit, p_period_revision, v_run,
            (SELECT layer_id FROM posting_layer WHERE code = 'TRANSLATION_ADJUSTMENT'),
            'GROUP_GAAP', v_report, p_policy_version, p_rate_version)
    RETURNING translation_entry_id INTO v_entry;
    INSERT INTO translation_adjustment_line (tenant_id, translation_entry_id, line_no, account_id,
            debit, credit, memo)
    VALUES (p_tenant, v_entry, 1, v_cta_acc,
            CASE WHEN v_cta > 0 THEN v_cta ELSE 0 END,
            CASE WHEN v_cta < 0 THEN -v_cta ELSE 0 END,
            '外幣報表折算差額（報告幣借貸合計差額）')
    RETURNING translation_line_id INTO v_line;

    -- CTA 的快照列是空殼：功能幣下沒有 CTA，金額只在 TranslationResult
    INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
            account_code, account_name, debit, credit, posting_layer_id)
    -- posting_layer_id 留 NULL：0023 的守衛要求「標示分層」的快照列必須有
    -- BASIS_COMPOSITION 凍結條目，而 FX run 凍結的是折算政策而非組成版本。
    -- 分層身分由 posting_layer 文字欄承載；CTA 分錄本身仍帶 posting_layer_id。
    SELECT p_tenant, v_run, 'TRANSLATION_ADJUSTMENT', v_cta_acc, a.code, a.name, 0, 0, NULL
      FROM account a WHERE a.account_id = v_cta_acc
    RETURNING snapshot_line_id INTO v_snap;
    INSERT INTO translation_result (tenant_id, calculation_run_id, source_snapshot_line_id,
            amount_role, currency_code, source_debit, source_credit, result_debit, result_credit)
    VALUES (p_tenant, v_run, v_snap, 'REPORTING', v_report, 0, 0,
            CASE WHEN v_cta > 0 THEN v_cta ELSE 0 END,
            CASE WHEN v_cta < 0 THEN -v_cta ELSE 0 END)
    RETURNING translation_result_id INTO v_res;
    INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no,
            source_kind, translation_adjustment_line_id, source_debit, source_credit,
            result_debit, result_credit)
    VALUES (p_tenant, v_res, 1, 'CTA_RESIDUAL', v_line, 0, 0,
            CASE WHEN v_cta > 0 THEN v_cta ELSE 0 END,
            CASE WHEN v_cta < 0 THEN -v_cta ELSE 0 END);
  END IF;

  -- 10 完成：result hash 排除 run_id 與時間戳（0012 已凍結的規則）
  SELECT md5(string_agg(
           bsl.account_code || ':' || bsl.posting_layer || ':' ||
           tr.result_debit::text || '/' || tr.result_credit::text,
           '|' ORDER BY bsl.account_code, bsl.posting_layer))
    INTO v_canon
    FROM translation_result tr
    JOIN balance_snapshot_line bsl ON bsl.snapshot_line_id = tr.source_snapshot_line_id
   WHERE tr.calculation_run_id = v_run;
  UPDATE calculation_run SET status = 'COMPLETED', result_content_hash = v_canon,
         completed_at = now()
   WHERE calculation_run_id = v_run;
  RETURN v_run;
END $$;

REVOKE ALL ON FUNCTION fn_fx_translation_run(uuid, uuid, uuid, uuid, uuid, uuid, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_fx_translation_run(uuid, uuid, uuid, uuid, uuid, uuid, uuid, uuid, text) TO app_runtime;
REVOKE ALL ON FUNCTION fn_fx_freeze_entry(jsonb, text, uuid, text, text, text) FROM PUBLIC;
