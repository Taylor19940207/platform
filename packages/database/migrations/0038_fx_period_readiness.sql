-- 0038 期間級判定：輸入就緒（現行 G-07）與結果就緒（SLICE-M3-03 收尾）
--
-- 為什麼是兩支：基線的 G-07 掛在 ADJ_APPROVED → CALCULATING，只能回答
-- 「**開始計算**所需的輸入是否齊備」。若把「run COMPLETED → 調節 FINALIZED →
-- R4 選定」也塞進 G-07，就會形成循環：還沒進 CALCULATING，卻要先完成計算
-- 與調節才准進去。
--
-- 結果就緒**暫不自行命名為 G-13**——新增正式 Guard ID 須走 CR（BACKLOG 已記）。
-- 本檔用穩定代碼 POST_FX_RECONCILIATION_READY 與 POSTFX_* 前綴。
--
-- 兩支皆唯讀，且**驗 current_tenant()**：唯讀函式也不得因 UUID 可猜而洩漏
-- 跨租戶結論。

-- ═══ 1　輸入就緒（現行 G-07）═══════════════════════════════════════
CREATE FUNCTION fn_period_fx_input_readiness(p_period_revision uuid)
RETURNS TABLE (seq int, condition text, ok boolean, code text, detail text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_tenant uuid; v_eng uuid; v_unit uuid; v_start date; v_end date;
  s record; v_func text; v_report text; v_n int; v_missing text;
BEGIN
  SELECT pr.tenant_id, rp.engagement_id, rp.reporting_unit_id, rp.start_date, rp.end_date
    INTO v_tenant, v_eng, v_unit, v_start, v_end
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = p_period_revision;
  IF v_tenant IS NULL OR v_tenant IS DISTINCT FROM current_tenant() THEN
    RAISE EXCEPTION 'CROSS_TENANT_DENIED: 期間修訂不存在或不屬於目前租戶';
  END IF;

  SELECT * INTO s FROM period_fx_input_selection
   WHERE input_selection_id = fn_current_fx_input_selection(p_period_revision);
  seq := 0; condition := '已選定折算輸入'; ok := s.input_selection_id IS NOT NULL;
  code := CASE WHEN ok THEN NULL ELSE 'G07_INPUT_NOT_SELECTED' END;
  detail := CASE WHEN ok THEN '' ELSE '本期尚未由 R2 選定來源 run／匯率版本／政策版本' END;
  RETURN NEXT;
  IF NOT ok THEN RETURN; END IF;   -- 後續各項都以選定為前提

  SELECT currency_code INTO v_func FROM reporting_unit_currency_assignment
   WHERE reporting_unit_id = v_unit AND currency_role = 'FUNCTIONAL'
     AND approved_at IS NOT NULL AND effective_range @> v_end;
  SELECT currency_code INTO v_report FROM reporting_unit_currency_assignment
   WHERE reporting_unit_id = v_unit AND currency_role = 'REPORTING'
     AND approved_at IS NOT NULL AND effective_range @> v_end;
  seq := 1; condition := '功能幣與報告幣指派已批准且涵蓋期末';
  ok := v_func IS NOT NULL AND v_report IS NOT NULL AND v_func <> v_report;
  code := CASE WHEN ok THEN NULL ELSE 'G07_CURRENCY_ASSIGNMENT_MISSING' END;
  detail := CASE WHEN ok THEN v_func || ' → ' || v_report
                 ELSE '功能幣 ' || COALESCE(v_func,'（無）') || '／報告幣 ' || COALESCE(v_report,'（無）') END;
  RETURN NEXT;

  SELECT count(*) INTO v_n FROM exchange_rate_version
   WHERE rate_version_id = s.exchange_rate_version_id AND tenant_id = v_tenant
     AND engagement_id = v_eng AND status = 'APPROVED';
  seq := 2; condition := '選定的匯率版本已批准'; ok := v_n = 1;
  code := CASE WHEN ok THEN NULL ELSE 'G07_RATE_VERSION_NOT_FROZEN' END;
  detail := CASE WHEN ok THEN '' ELSE '匯率版本不存在、不屬本案件或尚未批准' END;
  RETURN NEXT;

  v_missing := '';
  IF v_func IS NOT NULL AND v_report IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM exchange_rate_observation
                    WHERE rate_version_id = s.exchange_rate_version_id
                      AND from_currency = v_func AND to_currency = v_report
                      AND rate_type = 'CLOSING' AND measurement_date = v_end) THEN
      v_missing := v_missing || 'CLOSING@' || v_end::text || ' ';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM exchange_rate_observation
                    WHERE rate_version_id = s.exchange_rate_version_id
                      AND from_currency = v_func AND to_currency = v_report
                      AND rate_type = 'AVERAGE'
                      AND coverage_start <= v_start AND coverage_end >= v_end) THEN
      v_missing := v_missing || 'AVERAGE covering ' || v_start::text || '~' || v_end::text || ' ';
    END IF;
    -- 每筆權益事件都要有對應的 HISTORICAL 觀測
    SELECT count(*) INTO v_n FROM equity_translation_lot_set_version sv
      JOIN equity_translation_lot lot ON lot.set_version_id = sv.set_version_id
      JOIN exchange_rate_observation o ON o.observation_id = lot.exchange_rate_observation_id
     WHERE sv.reporting_unit_id = v_unit AND sv.approved_at IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM equity_translation_lot_set_version n
                        WHERE n.supersedes_set_version_id = sv.set_version_id)
       AND o.rate_version_id <> s.exchange_rate_version_id;
    IF v_n > 0 THEN
      v_missing := v_missing || v_n::text || ' 筆權益批次的 HISTORICAL 觀測不屬選定的匯率版本 ';
    END IF;
  END IF;
  seq := 3; condition := '所需 rate／date／coverage 完整'; ok := btrim(v_missing) = '';
  code := CASE WHEN ok THEN NULL ELSE 'G07_RATE_INCOMPLETE' END;
  detail := btrim(v_missing);
  RETURN NEXT;

  SELECT count(*) INTO v_n FROM translation_policy_version p
    JOIN account a ON a.account_id = p.cta_account_id
    JOIN chart_of_accounts coa ON coa.coa_id = a.coa_id
   WHERE p.policy_version_id = s.translation_policy_version_id
     AND p.tenant_id = v_tenant AND p.engagement_id = v_eng
     AND p.reporting_unit_id = v_unit AND p.approved_at IS NOT NULL
     AND coa.engagement_id = v_eng;
  seq := 4; condition := '選定的折算政策已批准且 CTA 科目屬本案件'; ok := v_n = 1;
  code := CASE WHEN ok THEN NULL ELSE 'G07_POLICY_NOT_APPROVED' END;
  detail := CASE WHEN ok THEN '' ELSE '政策未批准、不屬本單位，或 CTA 科目不屬本案件科目表' END;
  RETURN NEXT;

  SELECT count(*) INTO v_n FROM calculation_run
   WHERE calculation_run_id = s.source_run_id AND status = 'COMPLETED'
     AND tenant_id = v_tenant AND period_revision_id = p_period_revision;
  seq := 5; condition := '選定的來源 run 已完成'; ok := v_n = 1;
  code := CASE WHEN ok THEN NULL ELSE 'G07_SOURCE_RUN_NOT_READY' END;
  detail := CASE WHEN ok THEN '' ELSE '來源 run 不存在、不屬本期或尚未完成' END;
  RETURN NEXT;
END $$;

-- ═══ 2　結果就緒（折算與調節是否完成）═══════════════════════════════
CREATE FUNCTION fn_period_fx_result_readiness(p_period_revision uuid)
RETURNS TABLE (seq int, condition text, ok boolean, code text, detail text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_tenant uuid; sel record; run record; rc record; v_n int; v_err text;
  v_sum numeric(20,2); v_max numeric(20,2);
BEGIN
  SELECT pr.tenant_id INTO v_tenant FROM period_revision pr
   WHERE pr.period_revision_id = p_period_revision;
  IF v_tenant IS NULL OR v_tenant IS DISTINCT FROM current_tenant() THEN
    RAISE EXCEPTION 'CROSS_TENANT_DENIED: 期間修訂不存在或不屬於目前租戶';
  END IF;

  SELECT * INTO sel FROM period_fx_run_selection
   WHERE run_selection_id = fn_current_fx_run_selection(p_period_revision);
  seq := 1; condition := '已選定折算結果'; ok := sel.run_selection_id IS NOT NULL;
  code := CASE WHEN ok THEN NULL ELSE 'POSTFX_RUN_NOT_SELECTED' END;
  detail := CASE WHEN ok THEN '' ELSE '本期尚未由 R4 選定現行的 FX run 與調節' END;
  RETURN NEXT;
  IF NOT ok THEN RETURN; END IF;

  SELECT * INTO run FROM calculation_run WHERE calculation_run_id = sel.selected_run_id;

  v_err := NULL;
  BEGIN
    PERFORM fn_fx_verify_manifest(run.manifest_id);
  EXCEPTION WHEN raise_exception THEN v_err := SQLERRM;
  END;
  seq := 2; condition := '選定 run 的凍結集合完整'; ok := v_err IS NULL;
  code := CASE WHEN ok THEN NULL ELSE 'POSTFX_MANIFEST_INTEGRITY_FAILED' END;
  detail := COALESCE(v_err, '');
  RETURN NEXT;

  SELECT count(DISTINCT object_type) INTO v_n FROM calculation_manifest_entry
   WHERE manifest_id = run.manifest_id
     AND object_type IN ('EXCHANGE_RATE_VERSION','CURRENCY_ASSIGNMENT','TRANSLATION_POLICY_VERSION');
  seq := 3; condition := '匯率、幣別指派與政策均已凍結'; ok := v_n = 3;
  code := CASE WHEN ok THEN NULL ELSE 'POSTFX_INPUT_NOT_FROZEN' END;
  detail := CASE WHEN ok THEN '' ELSE '凍結集合缺少必要條目' END;
  RETURN NEXT;

  seq := 4; condition := '選定 run 已完成且非 replay';
  ok := run.status = 'COMPLETED' AND run.replay_of_run_id IS NULL;
  code := CASE WHEN ok THEN NULL ELSE 'POSTFX_RUN_NOT_COMPLETED' END;
  detail := CASE WHEN ok THEN '' ELSE 'run 狀態 ' || run.status ||
                 CASE WHEN run.replay_of_run_id IS NOT NULL THEN '（且為 replay）' ELSE '' END END;
  RETURN NEXT;

  SELECT * INTO rc FROM translation_reconciliation
   WHERE reconciliation_id = sel.selected_reconciliation_id;
  seq := 5; condition := '選定調節已完成且屬該 run';
  ok := rc.reconciliation_id IS NOT NULL AND rc.status = 'FINALIZED'
        AND rc.calculation_run_id = sel.selected_run_id;
  code := CASE WHEN ok THEN NULL ELSE 'POSTFX_RECONCILIATION_NOT_FINALIZED' END;
  detail := CASE WHEN ok THEN '' ELSE '調節不存在、未完成或不屬選定的 run' END;
  RETURN NEXT;
  IF NOT ok THEN RETURN; END IF;

  -- 條件 6：硬差異只要**存在**就失敗，狀態無關。
  -- 只擋 OPEN 的話，把 MISSING_RATE 標成 ACCEPTED_EXCEPTION 就能讓
  -- 「有一段金額根本沒有匯率可折算」的期間變成 ready——G-07 是硬守衛。
  SELECT count(*) INTO v_n FROM translation_difference
   WHERE reconciliation_id = rc.reconciliation_id AND reason_class <> 'ROUNDING_DIFFERENCE';
  seq := 6; condition := '不存在任何非尾差的差異（無論處理狀態）'; ok := v_n = 0;
  code := CASE WHEN ok THEN NULL ELSE 'POSTFX_HARD_DIFFERENCE_PRESENT' END;
  detail := CASE WHEN ok THEN '' ELSE v_n::text || ' 筆非尾差差異存在；修復路徑是重建正確的 FX run 並重新選定' END;
  RETURN NEXT;

  SELECT COALESCE(sum(abs(actual_difference)),0), COALESCE(max(abs(actual_difference)),0)
    INTO v_sum, v_max FROM translation_difference
   WHERE reconciliation_id = rc.reconciliation_id AND reason_class = 'ROUNDING_DIFFERENCE';
  SELECT count(*) INTO v_n FROM translation_difference
   WHERE reconciliation_id = rc.reconciliation_id AND reason_class = 'ROUNDING_DIFFERENCE'
     AND resolution_status <> 'RESOLVED_BY_POLICY';
  seq := 7; condition := '尾差皆依 INV-24 結案（單筆與累積同時滿足）';
  ok := v_n = 0 AND v_max <= rc.single_limit_snapshot AND v_sum <= rc.cumulative_limit_snapshot;
  code := CASE WHEN ok THEN NULL ELSE 'POSTFX_TOLERANCE_VIOLATION' END;
  detail := CASE WHEN ok THEN '' ELSE '單筆最大 ' || v_max::text || '／限 ' ||
                 rc.single_limit_snapshot::text || '；累積 ' || v_sum::text || '／限 ' ||
                 rc.cumulative_limit_snapshot::text END;
  RETURN NEXT;
END $$;

-- 整體結論：全部成立才回 POST_FX_RECONCILIATION_READY
CREATE FUNCTION fn_period_fx_result_ready(p_period_revision uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT COALESCE(
    (SELECT code FROM fn_period_fx_result_readiness(p_period_revision)
      WHERE NOT ok ORDER BY seq LIMIT 1),
    'POST_FX_RECONCILIATION_READY')
$$;

-- ═══ 3　引擎前置：實際輸入必須等於現行 InputSelection ═══════════════
-- 原本的 fn_fx_translation_run 原封不動改名為 _core，外層只多一道前置檢查。
-- 這樣「計算行為不變」是結構上的事實，不是承諾。
ALTER FUNCTION fn_fx_translation_run(uuid, uuid, uuid, uuid, uuid, uuid, uuid, uuid, text)
  RENAME TO fn_fx_translation_run_core;

CREATE FUNCTION fn_fx_translation_run(
  p_tenant uuid, p_engagement uuid, p_period_revision uuid, p_reporting_unit uuid,
  p_source_run uuid, p_rate_version uuid, p_policy_version uuid,
  p_actor uuid, p_engine_version text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_run uuid;
BEGIN
  -- 0038：先鎖期間再比對選定（TOCTOU），確保「G-07 通過的輸入」與
  -- 「實際拿去算的輸入」是同一組。計算行為完全不變。
  PERFORM fn_fx_assert_input_selected(p_period_revision, p_source_run,
                                      p_rate_version, p_policy_version);
  v_run := fn_fx_translation_run_core(p_tenant, p_engagement, p_period_revision,
             p_reporting_unit, p_source_run, p_rate_version, p_policy_version,
             p_actor, p_engine_version);
  RETURN v_run;
END $$;

REVOKE ALL ON FUNCTION fn_period_fx_input_readiness(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_period_fx_result_readiness(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_period_fx_result_ready(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_period_fx_input_readiness(uuid) TO app_runtime;
GRANT EXECUTE ON FUNCTION fn_period_fx_result_readiness(uuid) TO app_runtime;
GRANT EXECUTE ON FUNCTION fn_period_fx_result_ready(uuid) TO app_runtime;
