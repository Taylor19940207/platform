-- 0034 折算：Manifest 真正可重演（SLICE-M3-02 走查第三輪）
--
-- 0033 建立了 Manifest，但折算**仍回查現行表**（分類、政策規則、匯率觀測、
-- 權益批次、期初餘額），而 entry 的 payload 一律寫成 `{}`。因此它證明的是
-- 「同一批現行資料跑兩次結果相同」，不是 AC-FX-001 要求的
-- 「只拿既有 Manifest、即使現行主檔已變，仍能重算出原結果」。
-- 「改 Currency 後舊 run 不變」只證明**結果不可變**，不證明**可重算**。
--
-- 本檔做四件事：
--   1. 凍結完整計算內容（payload 保存實際使用到的每一個值）。
--   2. 折算改為**只讀凍結 payload**——原始 run 與 replay 走同一支物化函式。
--   3. 補上 source run 的完整驗證（SECURITY DEFINER 不能依賴 RLS）。
--   4. Hash 改用宣告的 SHA-256（0033 宣告 sha256 卻用 md5，是明確矛盾），
--      且涵蓋來源證據而不只是金額。
--
-- 另：FX Manifest 承接來源 Manifest 的 BASIS_COMPOSITION 條目。這樣 0023 的
-- 守衛自然要求所有新快照帶 posting_layer_id，CTA 空殼不必再讓文字欄與 FK
-- 形成兩個真相。

-- 來源 run 也要進凍結清單：折算的輸入不只是主檔，還包括「哪一份 TB」
ALTER TABLE calculation_manifest_entry DROP CONSTRAINT calculation_manifest_entry_object_type_check;
ALTER TABLE calculation_manifest_entry ADD CONSTRAINT calculation_manifest_entry_object_type_check
  CHECK (object_type IN (
    'SCOPE','SOURCE_TB','MAPPING_RULE','ADJUSTMENT','CHART_OF_ACCOUNTS','BASIS_COMPOSITION',
    'CURRENCY_DEFINITION','EXCHANGE_RATE_VERSION','TRANSLATION_POLICY_VERSION',
    'CURRENCY_ASSIGNMENT','EQUITY_TRANSLATION_LOT_SET_VERSION',
    'EQUITY_OPENING_TRANSLATED_BALANCE','ACCOUNT_TRANSLATION_CLASSIFICATION',
    'SOURCE_CALCULATION_RUN'));

CREATE FUNCTION fn_fx_sha(p_text text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to(COALESCE(p_text, ''), 'UTF8')), 'hex')
$$;

-- ═══ 物化：只讀 Manifest ═══════════════════════════════════════════
-- 原始 run 與 replay 共用這一支。它**不查**任何主檔——所有值來自 payload。
-- 這是「可重演」與「碰巧相同」的分界線。
CREATE FUNCTION fn_fx_materialize(p_run uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_tenant uuid; v_eng uuid; v_rev uuid; v_manifest uuid; v_unit uuid;
  v_minor int; v_report text; v_cta_acc uuid; v_policy uuid; v_rate_ver uuid;
  v_has_comp int; v_layer uuid;
  src jsonb; pol jsonb; rates jsonb; cls jsonb; l jsonb; rule jsonb;
  v_src_d numeric(20,2); v_src_c numeric(20,2);
  v_amt numeric(20,2); v_sum numeric(20,2);
  v_method text; v_rule uuid; v_cat text;
  v_obs uuid; v_rate numeric(18,8); lot jsonb; lots jsonb; opening jsonb;
  v_snap bigint; v_res uuid; v_line_no int;
  v_tot_d numeric(20,2) := 0; v_tot_c numeric(20,2) := 0; v_cta numeric(20,2);
  v_entry uuid; v_cta_line uuid; v_canon text;
BEGIN
  SELECT tenant_id, engagement_id, period_revision_id, manifest_id
    INTO v_tenant, v_eng, v_rev, v_manifest
    FROM calculation_run WHERE calculation_run_id = p_run;

  SELECT payload INTO src FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'SOURCE_CALCULATION_RUN';
  SELECT payload, object_id INTO pol, v_policy FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'TRANSLATION_POLICY_VERSION';
  SELECT payload, object_id INTO rates, v_rate_ver FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'EXCHANGE_RATE_VERSION';
  SELECT (payload->>'minor_unit')::int, payload->>'code' INTO v_minor, v_report
    FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'CURRENCY_DEFINITION'
     AND payload->>'role' = 'REPORTING';
  v_unit := (pol->>'reporting_unit_id')::uuid;
  v_cta_acc := (pol->>'cta_account_id')::uuid;

  SELECT count(*) INTO v_has_comp FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'BASIS_COMPOSITION';

  FOR l IN SELECT * FROM jsonb_array_elements(src->'lines')
  LOOP
    -- 分類與方法：來自凍結條目，不查 account 也不查 policy rule
    SELECT payload INTO cls FROM calculation_manifest_entry
     WHERE manifest_id = v_manifest AND object_type = 'ACCOUNT_TRANSLATION_CLASSIFICATION'
       AND object_id = (l->>'account_id')::uuid;
    v_cat := cls->>'category';
    SELECT x INTO rule FROM jsonb_array_elements(pol->'rules') x
     WHERE x->>'category' = v_cat;
    v_method := rule->>'method';
    v_rule := (rule->>'policy_rule_id')::uuid;

    INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
            account_code, account_name, debit, credit, posting_layer_id)
    VALUES (v_tenant, p_run, l->>'posting_layer', (l->>'account_id')::uuid,
            l->>'account_code', l->>'account_name',
            (l->>'debit')::numeric, (l->>'credit')::numeric,
            NULLIF(l->>'posting_layer_id','')::uuid)
    RETURNING snapshot_line_id INTO v_snap;

    -- 先軋差再折算：折算的對象是餘額
    IF (l->>'debit')::numeric >= (l->>'credit')::numeric THEN
      v_src_d := (l->>'debit')::numeric - (l->>'credit')::numeric; v_src_c := 0;
    ELSE
      v_src_d := 0; v_src_c := (l->>'credit')::numeric - (l->>'debit')::numeric;
    END IF;

    IF v_method IN ('CLOSING','AVERAGE') THEN
      SELECT (x->>'observation_id')::uuid, (x->>'rate')::numeric INTO v_obs, v_rate
        FROM jsonb_array_elements(rates->'observations') x
       WHERE x->>'rate_type' = v_method AND x->>'usage' = v_method;
      v_amt := round(v_src_d * v_rate, v_minor);
      v_sum := round(v_src_c * v_rate, v_minor);
    ELSIF v_method = 'HISTORICAL_BY_LOT' THEN
      SELECT payload INTO lots FROM calculation_manifest_entry
       WHERE manifest_id = v_manifest AND object_type = 'EQUITY_TRANSLATION_LOT_SET_VERSION'
         AND payload->>'account_id' = l->>'account_id';
      IF lots IS NULL THEN
        RAISE EXCEPTION 'FX_REPLAY_FROZEN_SET_INCOMPLETE: 凍結集合缺科目 % 的權益批次', l->>'account_code';
      END IF;
      SELECT COALESCE(sum(round((x->>'functional_amount')::numeric * (x->>'rate')::numeric, v_minor)), 0)
        INTO v_amt FROM jsonb_array_elements(lots->'lots') x;
      IF v_src_c > 0 THEN v_sum := v_amt; v_amt := 0; ELSE v_sum := 0; END IF;
    ELSIF v_method = 'OPENING_TRANSLATED_BALANCE' THEN
      SELECT payload INTO opening FROM calculation_manifest_entry
       WHERE manifest_id = v_manifest AND object_type = 'EQUITY_OPENING_TRANSLATED_BALANCE'
         AND payload->>'account_id' = l->>'account_id';
      IF opening IS NULL THEN
        RAISE EXCEPTION 'FX_REPLAY_FROZEN_SET_INCOMPLETE: 凍結集合缺科目 % 的期初已折算餘額', l->>'account_code';
      END IF;
      v_amt := (opening->>'debit')::numeric; v_sum := (opening->>'credit')::numeric;
    ELSE
      RAISE EXCEPTION 'FX_METHOD_UNRESOLVED: 凍結集合中的折算方法無法解析（%）', v_method;
    END IF;

    INSERT INTO translation_result (tenant_id, calculation_run_id, source_snapshot_line_id,
            amount_role, currency_code, source_debit, source_credit,
            result_debit, result_credit, translation_policy_rule_id)
    VALUES (v_tenant, p_run, v_snap, 'REPORTING', v_report, v_src_d, v_src_c,
            v_amt, v_sum, v_rule)
    RETURNING translation_result_id INTO v_res;

    IF v_method IN ('CLOSING','AVERAGE') THEN
      INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no,
              source_kind, exchange_rate_observation_id, source_debit, source_credit,
              result_debit, result_credit)
      VALUES (v_tenant, v_res, 1, 'RATE_TRANSLATION', v_obs, v_src_d, v_src_c, v_amt, v_sum);
    ELSIF v_method = 'HISTORICAL_BY_LOT' THEN
      FOR lot IN SELECT * FROM jsonb_array_elements(lots->'lots') ORDER BY 1
      LOOP
        INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no,
                source_kind, equity_lot_id, exchange_rate_observation_id,
                source_debit, source_credit, result_debit, result_credit)
        VALUES (v_tenant, v_res, (lot->>'line_no')::int, 'EQUITY_LOT',
                (lot->>'lot_id')::uuid, (lot->>'observation_id')::uuid,
                CASE WHEN v_src_d > 0 THEN (lot->>'functional_amount')::numeric ELSE 0 END,
                CASE WHEN v_src_c > 0 THEN (lot->>'functional_amount')::numeric ELSE 0 END,
                CASE WHEN v_src_d > 0 THEN round((lot->>'functional_amount')::numeric * (lot->>'rate')::numeric, v_minor) ELSE 0 END,
                CASE WHEN v_src_c > 0 THEN round((lot->>'functional_amount')::numeric * (lot->>'rate')::numeric, v_minor) ELSE 0 END);
      END LOOP;
    ELSE
      INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no,
              source_kind, opening_balance_id, source_debit, source_credit,
              result_debit, result_credit)
      VALUES (v_tenant, v_res, 1, 'OPENING_TRANSLATED_BALANCE',
              (opening->>'opening_id')::uuid, v_src_d, v_src_c, v_amt, v_sum);
    END IF;

    v_tot_d := v_tot_d + v_amt;
    v_tot_c := v_tot_c + v_sum;
  END LOOP;

  -- CTA：報告幣下已捨入的借貸合計差額
  v_cta := v_tot_c - v_tot_d;
  IF v_cta <> 0 THEN
    SELECT layer_id INTO v_layer FROM posting_layer WHERE code = 'TRANSLATION_ADJUSTMENT';
    INSERT INTO translation_adjustment_entry (tenant_id, engagement_id, reporting_unit_id,
            period_revision_id, calculation_run_id, posting_layer_id, rule_type,
            reporting_currency, translation_policy_version_id, exchange_rate_version_id)
    VALUES (v_tenant, v_eng, v_unit, v_rev, p_run, v_layer, 'GROUP_GAAP', v_report,
            v_policy, v_rate_ver)
    RETURNING translation_entry_id INTO v_entry;
    INSERT INTO translation_adjustment_line (tenant_id, translation_entry_id, line_no, account_id,
            debit, credit, memo)
    VALUES (v_tenant, v_entry, 1, v_cta_acc,
            CASE WHEN v_cta > 0 THEN v_cta ELSE 0 END,
            CASE WHEN v_cta < 0 THEN -v_cta ELSE 0 END,
            '外幣報表折算差額（報告幣借貸合計差額）')
    RETURNING translation_line_id INTO v_cta_line;

    -- 空殼快照：金額在 TranslationResult，分層由 posting_layer_id 承載
    -- （FX Manifest 承接了來源的 BASIS_COMPOSITION，因此可以正確標示）
    INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
            account_code, account_name, debit, credit, posting_layer_id)
    SELECT v_tenant, p_run, 'TRANSLATION_ADJUSTMENT', v_cta_acc,
           pol->>'cta_account_code', pol->>'cta_account_name', 0, 0,
           CASE WHEN v_has_comp > 0 THEN v_layer ELSE NULL END
    RETURNING snapshot_line_id INTO v_snap;
    INSERT INTO translation_result (tenant_id, calculation_run_id, source_snapshot_line_id,
            amount_role, currency_code, source_debit, source_credit, result_debit, result_credit)
    VALUES (v_tenant, p_run, v_snap, 'REPORTING', v_report, 0, 0,
            CASE WHEN v_cta > 0 THEN v_cta ELSE 0 END,
            CASE WHEN v_cta < 0 THEN -v_cta ELSE 0 END)
    RETURNING translation_result_id INTO v_res;
    INSERT INTO translation_result_component (tenant_id, translation_result_id, line_no,
            source_kind, translation_adjustment_line_id, source_debit, source_credit,
            result_debit, result_credit)
    VALUES (v_tenant, v_res, 1, 'CTA_RESIDUAL', v_cta_line, 0, 0,
            CASE WHEN v_cta > 0 THEN v_cta ELSE 0 END,
            CASE WHEN v_cta < 0 THEN -v_cta ELSE 0 END);
  END IF;

  -- 結果雜湊：涵蓋金額**與來源證據**。只 hash 科目與金額的話，
  -- 來源證據換了但金額剛好相同時雜湊不變——那正是重演該抓出來的事。
  SELECT fn_fx_sha(string_agg(part, '|' ORDER BY part)) INTO v_canon FROM (
    SELECT bsl.account_code || ':' || bsl.posting_layer || ':' ||
           tr.result_debit::text || '/' || tr.result_credit::text || ':' ||
           COALESCE(tr.translation_policy_rule_id::text, '-') || '#' ||
           COALESCE((SELECT string_agg(c.source_kind || '>' ||
                       COALESCE(c.exchange_rate_observation_id::text, '-') || '>' ||
                       COALESCE(c.equity_lot_id::text, '-') || '>' ||
                       COALESCE(c.opening_balance_id::text, '-') || '>' ||
                       c.result_debit::text || '/' || c.result_credit::text,
                     ',' ORDER BY c.line_no)
                     FROM translation_result_component c
                    WHERE c.translation_result_id = tr.translation_result_id), '') AS part
      FROM translation_result tr
      JOIN balance_snapshot_line bsl ON bsl.snapshot_line_id = tr.source_snapshot_line_id
     WHERE tr.calculation_run_id = p_run
    UNION ALL
    SELECT 'CTA:' || tl.account_id::text || ':' || tl.debit::text || '/' || tl.credit::text ||
           ':' || te.translation_policy_version_id::text || ':' || te.exchange_rate_version_id::text
      FROM translation_adjustment_line tl
      JOIN translation_adjustment_entry te ON te.translation_entry_id = tl.translation_entry_id
     WHERE te.calculation_run_id = p_run) q;
  RETURN v_canon;
END $$;

-- canonical 由 payload 決定：payload 才是重演的依據，canonical 只是它的文字投影。
CREATE FUNCTION fn_fx_freeze_entry2(
  p_entries jsonb, p_type text, p_object uuid, p_kind text, p_value text, p_payload jsonb
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT p_entries || jsonb_build_object(
    'object_type', p_type, 'object_id', p_object, 'kind', p_kind, 'value', p_value,
    'canonical', p_type || ':' || COALESCE(p_object::text, '-') || ':' || jsonb_pretty(p_payload),
    'hash', fn_fx_sha(p_type || ':' || COALESCE(p_object::text, '-') || ':' || jsonb_pretty(p_payload)),
    'payload', p_payload)
$$;

-- ═══ 原始 run：驗證 → 凍結完整內容 → 物化 ═══════════════════════════
CREATE OR REPLACE FUNCTION fn_fx_translation_run(
  p_tenant uuid, p_engagement uuid, p_period_revision uuid, p_reporting_unit uuid,
  p_source_run uuid, p_rate_version uuid, p_policy_version uuid,
  p_actor uuid, p_engine_version text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_manifest uuid; v_run uuid; v_batch uuid; v_src record;
  v_period_end date; v_period_start date;
  v_func text; v_report text; v_func_asg uuid; v_report_asg uuid;
  v_minor int; v_minor_f int;
  v_obs_close uuid; v_rate_close numeric(18,8);
  v_obs_avg uuid; v_rate_avg numeric(18,8);
  r record; v_rule uuid; v_method text; v_set uuid; v_open uuid;
  v_sum numeric(20,2); v_bal numeric(20,2); v_n int;
  v_entries jsonb := '[]'::jsonb; e jsonb; v_canon text; v_hash text;
  v_payload jsonb; v_cta_acc uuid;
BEGIN
  PERFORM fn_assert_engagement_role(p_actor, 'R2', p_tenant, p_engagement);

  SELECT rp.start_date, rp.end_date INTO v_period_start, v_period_end
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = p_period_revision;
  IF v_period_end IS NULL THEN
    RAISE EXCEPTION 'FX_PERIOD_NOT_FOUND: 期間修訂不存在';
  END IF;

  -- 0 來源 run 的完整驗證。SECURITY DEFINER 以 owner 身分執行，**不受 RLS 保護**，
  -- 因此每一項歸屬都要自己查——不能假設呼叫者只看得到自己的資料。
  SELECT cr.tenant_id, cr.engagement_id, cr.period_revision_id, cr.status,
         cr.result_content_hash, cr.import_batch_id, cr.manifest_id
    INTO v_src FROM calculation_run cr WHERE cr.calculation_run_id = p_source_run;
  IF v_src.tenant_id IS NULL THEN
    RAISE EXCEPTION 'FX_SOURCE_RUN_NOT_FOUND: 來源 run 不存在';
  END IF;
  IF v_src.tenant_id IS DISTINCT FROM p_tenant THEN
    RAISE EXCEPTION '歸屬違規：來源 run 屬於其他租戶（INV-18）';
  END IF;
  IF v_src.engagement_id IS DISTINCT FROM p_engagement
  OR v_src.period_revision_id IS DISTINCT FROM p_period_revision THEN
    RAISE EXCEPTION '§24.1A：來源 run 的案件或期間與本次折算不一致';
  END IF;
  IF v_src.status IS DISTINCT FROM 'COMPLETED' THEN
    RAISE EXCEPTION 'FX_SOURCE_RUN_NOT_COMPLETED: 來源 run 的狀態為 %（須為 COMPLETED）', v_src.status;
  END IF;
  IF v_src.result_content_hash IS NULL OR btrim(v_src.result_content_hash) = '' THEN
    RAISE EXCEPTION 'FX_SOURCE_RUN_NO_RESULT_HASH: 來源 run 沒有結果雜湊，無法作為折算的憑據';
  END IF;
  SELECT count(*) INTO v_n FROM import_batch ib
   WHERE ib.import_batch_id = v_src.import_batch_id AND ib.tenant_id = p_tenant
     AND ib.engagement_id = p_engagement AND ib.declared_period_revision_id = p_period_revision;
  IF v_n = 0 THEN
    RAISE EXCEPTION '§24.1A：來源 run 的批次不屬本案件本期';
  END IF;
  v_batch := v_src.import_batch_id;

  -- 1 幣別角色
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
  SELECT minor_unit INTO v_minor_f FROM currency WHERE currency_code = v_func;

  -- 2／3 匯率版本與政策必須已批准
  PERFORM 1 FROM exchange_rate_version
   WHERE rate_version_id = p_rate_version AND tenant_id = p_tenant
     AND engagement_id = p_engagement AND status = 'APPROVED';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'G07_RATE_VERSION_NOT_FROZEN: 匯率版本未指定、不屬本案件或尚未批准，整期折算不可用';
  END IF;
  SELECT cta_account_id INTO v_cta_acc FROM translation_policy_version
   WHERE policy_version_id = p_policy_version AND tenant_id = p_tenant
     AND engagement_id = p_engagement AND reporting_unit_id = p_reporting_unit
     AND approved_at IS NOT NULL;
  IF v_cta_acc IS NULL THEN
    RAISE EXCEPTION 'TRANSLATION_POLICY_NOT_APPROVED: 折算政策版本未指定、不屬本單位或尚未批准';
  END IF;

  -- 4 匯率
  SELECT observation_id, rate INTO v_obs_close, v_rate_close FROM exchange_rate_observation
   WHERE rate_version_id = p_rate_version AND from_currency = v_func AND to_currency = v_report
     AND rate_type = 'CLOSING' AND measurement_date = v_period_end;
  IF v_obs_close IS NULL THEN
    RAISE EXCEPTION 'FX_RATE_MISSING: 缺 % → % 的 CLOSING 匯率（計量日 %）', v_func, v_report, v_period_end;
  END IF;
  SELECT observation_id, rate INTO v_obs_avg, v_rate_avg FROM exchange_rate_observation
   WHERE rate_version_id = p_rate_version AND from_currency = v_func AND to_currency = v_report
     AND rate_type = 'AVERAGE' AND coverage_start <= v_period_start AND coverage_end >= v_period_end;
  IF v_obs_avg IS NULL THEN
    RAISE EXCEPTION 'FX_RATE_COVERAGE_MISMATCH: 缺涵蓋 % ～ % 的 AVERAGE 匯率', v_period_start, v_period_end;
  END IF;

  -- 5 凍結：來源快照（含層與 layer id）
  SELECT jsonb_build_object(
           'source_run_id', p_source_run,
           'source_result_hash', v_src.result_content_hash,
           'lines', COALESCE(jsonb_agg(jsonb_build_object(
             'account_id', bsl.account_id, 'account_code', bsl.account_code,
             'account_name', bsl.account_name, 'posting_layer', bsl.posting_layer,
             'posting_layer_id', bsl.posting_layer_id,
             'debit', bsl.debit::text, 'credit', bsl.credit::text)
             ORDER BY bsl.account_code, bsl.posting_layer), '[]'::jsonb))
    INTO v_payload
    FROM balance_snapshot_line bsl WHERE bsl.calculation_run_id = p_source_run;
  v_entries := fn_fx_freeze_entry2(v_entries, 'SOURCE_CALCULATION_RUN', p_source_run,
    'result_hash', v_src.result_content_hash, v_payload);

  -- 承接來源 Manifest 的組成版本：FX run 以已有多基礎 TB 為來源，
  -- 因此分層身分必須一路帶下來，CTA 空殼才不必用 NULL 繞過模型。
  FOR r IN SELECT object_id, domain_version_kind, domain_version_value, content_canonical, payload
             FROM calculation_manifest_entry
            WHERE manifest_id = v_src.manifest_id AND object_type = 'BASIS_COMPOSITION'
            ORDER BY object_id
  LOOP
    v_entries := fn_fx_freeze_entry2(v_entries, 'BASIS_COMPOSITION', r.object_id,
      r.domain_version_kind, r.domain_version_value, r.payload);
  END LOOP;

  v_entries := fn_fx_freeze_entry2(v_entries, 'CURRENCY_DEFINITION', NULL, 'minor_unit',
    v_minor_f::text, jsonb_build_object('role','FUNCTIONAL','code',v_func,'minor_unit',v_minor_f));
  v_entries := fn_fx_freeze_entry2(v_entries, 'CURRENCY_DEFINITION', NULL, 'minor_unit',
    v_minor::text, jsonb_build_object('role','REPORTING','code',v_report,'minor_unit',v_minor));

  SELECT jsonb_build_object('role','FUNCTIONAL','currency',currency_code,
           'effective_range', effective_range::text,
           'approved_by', approved_by, 'approved_at', approved_at)
    INTO v_payload FROM reporting_unit_currency_assignment WHERE assignment_id = v_func_asg;
  v_entries := fn_fx_freeze_entry2(v_entries, 'CURRENCY_ASSIGNMENT', v_func_asg, 'role',
    'FUNCTIONAL', v_payload);
  SELECT jsonb_build_object('role','REPORTING','currency',currency_code,
           'effective_range', effective_range::text,
           'approved_by', approved_by, 'approved_at', approved_at)
    INTO v_payload FROM reporting_unit_currency_assignment WHERE assignment_id = v_report_asg;
  v_entries := fn_fx_freeze_entry2(v_entries, 'CURRENCY_ASSIGNMENT', v_report_asg, 'role',
    'REPORTING', v_payload);

  -- 匯率：保存**實際使用**的觀測（usage 標明它被用在哪一段）
  v_payload := jsonb_build_object('observations', jsonb_build_array(
    (SELECT jsonb_build_object('observation_id', observation_id, 'usage', 'CLOSING',
       'rate_type', rate_type, 'rate', rate::text, 'from', from_currency, 'to', to_currency,
       'measurement_date', measurement_date)
       FROM exchange_rate_observation WHERE observation_id = v_obs_close),
    (SELECT jsonb_build_object('observation_id', observation_id, 'usage', 'AVERAGE',
       'rate_type', rate_type, 'rate', rate::text, 'from', from_currency, 'to', to_currency,
       'coverage_start', coverage_start, 'coverage_end', coverage_end)
       FROM exchange_rate_observation WHERE observation_id = v_obs_avg)));
  v_entries := fn_fx_freeze_entry2(v_entries, 'EXCHANGE_RATE_VERSION', p_rate_version,
    'version', '1', v_payload);

  SELECT jsonb_build_object(
           'reporting_unit_id', p_reporting_unit,
           'cta_account_id', v_cta_acc,
           'cta_account_code', (SELECT code FROM account WHERE account_id = v_cta_acc),
           'cta_account_name', (SELECT name FROM account WHERE account_id = v_cta_acc),
           'cta_coa_id', (SELECT cta_coa_id FROM translation_policy_version
                           WHERE policy_version_id = p_policy_version),
           'rules', COALESCE(jsonb_agg(jsonb_build_object(
             'policy_rule_id', policy_rule_id, 'category', translation_category, 'method', method)
             ORDER BY translation_category), '[]'::jsonb))
    INTO v_payload FROM translation_policy_rule WHERE policy_version_id = p_policy_version;
  v_entries := fn_fx_freeze_entry2(v_entries, 'TRANSLATION_POLICY_VERSION', p_policy_version,
    'version', '1', v_payload);

  -- 分類、權益批次、期初餘額
  FOR r IN SELECT DISTINCT a.account_id, a.code, a.translation_category
             FROM balance_snapshot_line bsl JOIN account a ON a.account_id = bsl.account_id
            WHERE bsl.calculation_run_id = p_source_run ORDER BY a.code
  LOOP
    IF r.translation_category IS NULL THEN
      RAISE EXCEPTION 'FX_METHOD_UNRESOLVED: 科目 % 沒有折算分類', r.code;
    END IF;
    SELECT policy_rule_id, method INTO v_rule, v_method FROM translation_policy_rule
     WHERE policy_version_id = p_policy_version AND translation_category = r.translation_category;
    IF v_rule IS NULL THEN
      RAISE EXCEPTION 'FX_METHOD_UNRESOLVED: 分類 %（科目 %）在本政策版本沒有對應規則', r.translation_category, r.code;
    END IF;
    v_entries := fn_fx_freeze_entry2(v_entries, 'ACCOUNT_TRANSLATION_CLASSIFICATION',
      r.account_id, 'category', r.translation_category,
      jsonb_build_object('account_id', r.account_id, 'account_code', r.code,
                         'category', r.translation_category, 'policy_rule_id', v_rule));

    IF v_method = 'HISTORICAL_BY_LOT' THEN
      SELECT count(*) INTO v_n FROM balance_snapshot_line
       WHERE calculation_run_id = p_source_run AND account_id = r.account_id;
      IF v_n > 1 THEN
        RAISE EXCEPTION 'FX_EQUITY_ACCOUNT_SPLIT_UNSUPPORTED: 權益科目 % 在本 run 有 % 列', r.code, v_n;
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
      SELECT COALESCE(sum(debit),0) - COALESCE(sum(credit),0) INTO v_bal
        FROM balance_snapshot_line WHERE calculation_run_id = p_source_run AND account_id = r.account_id;
      IF v_sum <> abs(v_bal) THEN
        RAISE EXCEPTION 'EQUITY_LOT_SUM_MISMATCH: 科目 % 的批次合計 % 與功能幣餘額 % 不符', r.code, v_sum, abs(v_bal);
      END IF;
      SELECT jsonb_build_object('set_version_id', v_set, 'account_id', r.account_id,
               'lots', COALESCE(jsonb_agg(jsonb_build_object(
                 'lot_id', lot.lot_id, 'line_no', lot.line_no,
                 'event_date', lot.event_date, 'functional_amount', lot.functional_amount::text,
                 'observation_id', lot.exchange_rate_observation_id, 'rate', o.rate::text)
                 ORDER BY lot.line_no), '[]'::jsonb))
        INTO v_payload
        FROM equity_translation_lot lot
        JOIN exchange_rate_observation o ON o.observation_id = lot.exchange_rate_observation_id
       WHERE lot.set_version_id = v_set;
      v_entries := fn_fx_freeze_entry2(v_entries, 'EQUITY_TRANSLATION_LOT_SET_VERSION',
        v_set, 'set_version', '1', v_payload);
    ELSIF v_method = 'OPENING_TRANSLATED_BALANCE' THEN
      SELECT count(*) INTO v_n FROM balance_snapshot_line
       WHERE calculation_run_id = p_source_run AND account_id = r.account_id;
      IF v_n > 1 THEN
        RAISE EXCEPTION 'FX_EQUITY_ACCOUNT_SPLIT_UNSUPPORTED: 保留盈餘科目 % 在本 run 有 % 列', r.code, v_n;
      END IF;
      SELECT jsonb_build_object('opening_id', opening_id, 'account_id', account_id,
               'debit', opening_debit::text, 'credit', opening_credit::text,
               'source_kind', source_kind, 'source_calculation_run_id', source_calculation_run_id,
               'evidence_ref', evidence_ref, 'approved_at', approved_at)
        INTO v_payload FROM equity_opening_translated_balance
       WHERE period_revision_id = p_period_revision AND account_id = r.account_id
         AND approved_at IS NOT NULL;
      IF v_payload IS NULL THEN
        RAISE EXCEPTION 'FX_OPENING_EQUITY_MISSING: 科目 % 缺已批准的期初已折算餘額', r.code;
      END IF;
      v_entries := fn_fx_freeze_entry2(v_entries, 'EQUITY_OPENING_TRANSLATED_BALANCE',
        (v_payload->>'opening_id')::uuid, 'opening', '1', v_payload);
    END IF;
  END LOOP;

  SELECT fn_fx_sha(string_agg(x->>'hash', '|'
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
            e->>'kind', e->>'value', e->>'canonical', e->>'hash', e->'payload');
  END LOOP;

  v_run := gen_random_uuid();
  INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
          import_batch_id, manifest_id, run_type, status, request_key, request_content_hash,
          engine_version, created_by)
  VALUES (v_run, p_tenant, p_engagement, p_period_revision, v_batch, v_manifest, 'PREVIEW',
          'RUNNING', gen_random_uuid(), v_canon, p_engine_version, p_actor);

  v_hash := fn_fx_materialize(v_run);
  UPDATE calculation_run SET status = 'COMPLETED', result_content_hash = v_hash,
         completed_at = now() WHERE calculation_run_id = v_run;
  RETURN v_run;
END $$;

-- ═══ Replay：引用同一份 Manifest ════════════════════════════════════
CREATE FUNCTION fn_fx_translation_replay(
  p_original_run uuid, p_actor uuid, p_engine_version text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE o record; v_run uuid; v_hash text;
BEGIN
  SELECT * INTO o FROM calculation_run WHERE calculation_run_id = p_original_run;
  IF o.calculation_run_id IS NULL THEN
    RAISE EXCEPTION 'FX_SOURCE_RUN_NOT_FOUND: 原 run 不存在';
  END IF;
  PERFORM fn_assert_engagement_role(p_actor, 'R2', o.tenant_id, o.engagement_id);
  IF o.status <> 'COMPLETED' THEN
    RAISE EXCEPTION 'REPLAY_TARGET_NOT_COMPLETED: 只有已完成的 run 可被重演（目前 %）', o.status;
  END IF;
  PERFORM 1 FROM calculation_input_manifest
   WHERE manifest_id = o.manifest_id AND calculation_scope = 'FX_TRANSLATION';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FX_REPLAY_SCOPE_MISMATCH: 只有 FX_TRANSLATION 的 run 可用本函式重演';
  END IF;

  -- **引用同一份 Manifest**：不接受新的匯率、政策、lot set 或 Currency。
  -- 物化函式只讀 payload，因此現行主檔即使已變也不影響結果。
  v_run := gen_random_uuid();
  INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
          import_batch_id, manifest_id, run_type, status, replay_of_run_id, request_key,
          request_content_hash, engine_version, created_by)
  VALUES (v_run, o.tenant_id, o.engagement_id, o.period_revision_id, o.import_batch_id,
          o.manifest_id, 'PREVIEW', 'RUNNING', p_original_run, gen_random_uuid(),
          o.request_content_hash, p_engine_version, p_actor);

  v_hash := fn_fx_materialize(v_run);
  IF v_hash IS DISTINCT FROM o.result_content_hash THEN
    -- 失敗屬 replay run，原 run 永不修改（02B 的語意）
    UPDATE calculation_run SET status = 'FAILED', failure_reason_code = 'REPLAY_FAILED',
           failure_reason = '重演結果與原 run 不一致：' || COALESCE(v_hash, '(null)') ||
                            ' ≠ ' || COALESCE(o.result_content_hash, '(null)'),
           failed_at = now()
     WHERE calculation_run_id = v_run;
    RETURN v_run;
  END IF;
  UPDATE calculation_run SET status = 'COMPLETED', result_content_hash = v_hash,
         completed_at = now() WHERE calculation_run_id = v_run;
  RETURN v_run;
END $$;

REVOKE ALL ON FUNCTION fn_fx_materialize(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_fx_freeze_entry2(jsonb, text, uuid, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_fx_sha(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_fx_sha(text) TO app_runtime;
REVOKE ALL ON FUNCTION fn_fx_translation_replay(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_fx_translation_replay(uuid, uuid, text) TO app_runtime;
