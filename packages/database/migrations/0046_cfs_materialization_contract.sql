-- 0046 CFS 物化契約升版 ＋ 私有解析器（SLICE-M3-04 2b 第三刀 3A）
--
-- 第三刀是**非同步計算閉環**：凍結 Run＋Job → 只讀 Manifest 解析候選列 →
-- DATA_PRESENT／粒度／完整度／K1～K4 → 原子寫入支持列＋雜湊＋Run/Job 終態 →
-- replay 走同一路徑。閉環不能拆開交付（不可變輸出一旦寫出就撤不回），
-- 但可以分段提交。**本檔是 3A：只升版凍結契約與解析，不寫正式支持列、
-- 不設定 result hash、不宣告 Run 完成。**
--
-- ## 3A 交付
--
-- | # | 內容 |
-- |---|---|
-- | 1 | `SCOPE` 補凍結：`materialization_contract_version`、期間起訖日、功能幣／報告幣（含指派 ID） |
-- | 2 | `fn_cf_parse_support_candidates(run)`：**只讀凍結 payload** 解析候選列 |
-- | 3 | 未映射／多重映射的穩定代碼；未知契約版本 fail closed |
--
-- ## 為什麼期間終了日與幣別必須進 SCOPE
--
-- 映射規則有生效區間，判定「這條規則在本期是否生效」需要期間終了日；
-- 支持列的幣別則來自本期已批准的幣別指派。兩者若在物化時回查主檔，
-- 凍結就名存實亡——期間或指派日後被改，同一份 Manifest 會解析出不同結果。
-- **缺欄位的舊 CFS Manifest 一律 fail closed，不得回查補值。**
--
-- ## 解析的三條規矩（本檔只做解析，不做判定）
--
-- 1. **恰好命中一條**：ACCOUNT 比 `account_id`、JOURNAL_LINE／SUBLEDGER_ITEM 比
--    `source_ledger_line_id`、DOCUMENT 比 `source_document_id`，且規則的生效區間
--    必須涵蓋凍結的期間終了日。0 條 → `CFS_UNMAPPED_SOURCE`；
--    多於 1 條 → `CFS_MAPPING_AMBIGUOUS`。
-- 2. **沒有預設分類**：未命中就是未命中，不得落入「其他」——那會讓 P0 的
--    「只收集不重建」邊界失效（契約驗收 6）。
-- 3. **命中的分類必須在凍結的分類集合內**：規則指向集合外的分類即 fail closed；
--    否則支持列會帶著一個 Manifest 裡不存在的分類。
--
-- 金額與幣別**原樣承接**：解析器不做任何運算、不淨額化、不換算。

-- ═══ 1　凍結入口：SCOPE 升版 ═══════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_cash_flow_support_freeze_and_run(
  p_period_revision uuid, p_reporting_unit uuid,
  p_policy_version uuid, p_mapping_version uuid,
  p_source_batches uuid[], p_actor uuid, p_engine_version text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_tenant uuid; v_eng uuid; v_unit uuid;
  pol record; sel record; v_class_set uuid; v_manifest uuid; v_run uuid;
  v_entries jsonb; v_set_hash text; e jsonb;
  v_kind text; v_n int;
  v_period_start date; v_period_end date; v_func text; v_report text;
  v_func_asg uuid; v_report_asg uuid; v_cur_scope text;
BEGIN
  -- 引擎版本的檢查同樣只留在 helper（單一實作）。

  -- ── 4.1 鎖期間：兩個併發凍結因此互相序列化 ──
  SELECT pr.tenant_id, rp.engagement_id, rp.reporting_unit_id INTO v_tenant, v_eng, v_unit
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = p_period_revision FOR UPDATE OF pr;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'CFS_FREEZE_PERIOD_NOT_FOUND: 期間修訂不存在（%）', p_period_revision;
  END IF;
  IF v_unit IS DISTINCT FROM p_reporting_unit THEN
    RAISE EXCEPTION 'CFS_FREEZE_UNIT_MISMATCH: 期間屬報告單位 %，與參數 % 不一致', v_unit, p_reporting_unit;
  END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R2', v_tenant, v_eng);

  -- ── 4.2 鎖版本列 ──
  -- 這些鎖真正做到的是「同一期間的兩次凍結互相序列化」（不相交批次的競態測試
  -- 就是被它們擋下的）。**它們擋不住取代鏈被接上**：新版本是帶 supersedes 的
  -- INSERT，不 UPDATE 舊列，`FOR UPDATE` 攔不到。**這不是缺口**：政策與映射版本
  -- 由參數顯式帶入，後續版本被建立也不會改變本次凍結的輸入；而「凍結途中改選」
  -- 由期間列鎖擋住（`fn_cf_select_source` 同樣 `FOR UPDATE OF pr`，已有雙 session 測試）。
  SELECT p.policy_version_id, p.tenant_id, p.engagement_id, p.reporting_unit_id,
         p.class_set_version_id, p.approved_at
    INTO pol FROM cash_flow_policy_version p
   WHERE p.policy_version_id = p_policy_version AND p.tenant_id = v_tenant FOR UPDATE;
  IF pol.policy_version_id IS NULL THEN
    RAISE EXCEPTION 'CFS_FREEZE_POLICY_NOT_FOUND: 政策版本不存在或不屬本租戶';
  END IF;
  IF pol.engagement_id IS DISTINCT FROM v_eng OR pol.reporting_unit_id IS DISTINCT FROM p_reporting_unit THEN
    RAISE EXCEPTION '§24.1A：政策版本不屬本案件本單位';
  END IF;
  IF pol.approved_at IS NULL THEN
    RAISE EXCEPTION 'CFS_POLICY_NOT_APPROVED: 未批准的政策版本不得作為凍結輸入';
  END IF;
  v_class_set := pol.class_set_version_id;

  PERFORM 1 FROM cash_flow_class_set_version WHERE class_set_version_id = v_class_set FOR UPDATE;
  SELECT count(*) INTO v_n FROM cash_flow_class_set_version
   WHERE class_set_version_id = v_class_set AND tenant_id = v_tenant AND approved_at IS NOT NULL;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'CFS_CLASS_SET_NOT_APPROVED: 政策引用的分類集合尚未批准或不屬本租戶';
  END IF;

  SELECT count(*) INTO v_n FROM cash_flow_mapping_version
   WHERE mapping_version_id = p_mapping_version AND tenant_id = v_tenant;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'CFS_FREEZE_MAPPING_NOT_FOUND: 映射版本不存在或不屬本租戶';
  END IF;
  PERFORM 1 FROM cash_flow_mapping_version WHERE mapping_version_id = p_mapping_version FOR UPDATE;
  SELECT count(*) INTO v_n FROM cash_flow_mapping_version
   WHERE mapping_version_id = p_mapping_version AND policy_version_id = p_policy_version;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'CFS_FREEZE_MAPPING_POLICY_MISMATCH: 映射版本綁定的政策不是本次凍結的政策';
  END IF;
  SELECT count(*) INTO v_n FROM cash_flow_mapping_version
   WHERE mapping_version_id = p_mapping_version AND approved_at IS NOT NULL;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'CFS_MAPPING_NOT_APPROVED: 未批准的映射版本不得作為凍結輸入';
  END IF;

  -- ── 4.3 現行選定（取代鏈，不按時間找最新） ──
  SELECT s.* INTO sel FROM period_cash_flow_source_selection s
   WHERE s.cf_selection_id = fn_current_cf_source_selection(p_period_revision) FOR UPDATE;
  IF sel.cf_selection_id IS NULL THEN
    RAISE EXCEPTION 'CFS_SELECTION_NOT_FOUND: 本期尚未選定權威來源（PeriodCashFlowSourceSelection）';
  END IF;
  IF sel.tenant_id IS DISTINCT FROM v_tenant OR sel.reporting_unit_id IS DISTINCT FROM p_reporting_unit THEN
    RAISE EXCEPTION '§24.1A：現行來源選定不屬本租戶本單位';
  END IF;
  IF sel.opening_source_kind = 'FIRST_PERIOD_EVIDENCE' THEN
    PERFORM 1 FROM cash_flow_opening_balance_set_version
     WHERE opening_set_version_id = sel.opening_balance_set_version_id FOR UPDATE;
    SELECT count(*) INTO v_n FROM cash_flow_opening_balance_set_version
     WHERE opening_set_version_id = sel.opening_balance_set_version_id
       AND tenant_id = v_tenant AND approved_at IS NOT NULL;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'CFS_OPENING_EVIDENCE_NOT_APPROVED: 未批准的期初證據集合不得使用';
    END IF;
  END IF;

  -- ── 4.3B 期間終了日與幣別：凍結它們，解析時就不必回查主檔 ──
  SELECT rp.start_date, rp.end_date INTO v_period_start, v_period_end
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = p_period_revision;
  SELECT assignment_id, currency_code INTO v_func_asg, v_func
    FROM reporting_unit_currency_assignment
   WHERE reporting_unit_id = p_reporting_unit AND currency_role = 'FUNCTIONAL'
     AND approved_at IS NOT NULL AND effective_range @> v_period_end;
  IF v_func IS NULL THEN
    RAISE EXCEPTION 'CFS_FREEZE_FUNCTIONAL_CURRENCY_MISSING: 本期缺少已批准的功能幣指派（期末 %）', v_period_end;
  END IF;
  SELECT assignment_id, currency_code INTO v_report_asg, v_report
    FROM reporting_unit_currency_assignment
   WHERE reporting_unit_id = p_reporting_unit AND currency_role = 'REPORTING'
     AND approved_at IS NOT NULL AND effective_range @> v_period_end;
  -- 報告幣只在本期來源是折算 run 時是必要的（K4：報告幣欄位僅在引用 FX run 時填寫）
  SELECT m.calculation_scope INTO v_cur_scope FROM calculation_run cr
    JOIN calculation_input_manifest m ON m.manifest_id = cr.manifest_id
   WHERE cr.calculation_run_id = sel.current_run_id;
  IF v_cur_scope = 'FX_TRANSLATION' AND v_report IS NULL THEN
    RAISE EXCEPTION 'CFS_FREEZE_REPORTING_CURRENCY_MISSING: 本期來源是折算 run，卻缺少已批准的報告幣指派';
  END IF;

  -- ── 4.4 來源批次的檢查與列鎖**不在這裡**：0043 的 helper 已是那份實作。
  -- 實測反證過——把這裡的檢查與 FOR UPDATE 拿掉，競態測試不會轉紅，因為擋住它的
  -- 一直是 helper 的鎖。同一個檢查留兩份，遲早有一份先鬆掉；本函式只負責凍結，
  -- 批次合法性與 TOCTOU 由 helper 在同一交易內把關（任何一項不成立即整份回滾）。

  -- ── 4.5 單一 statement 物化整份凍結輸入 ──
  -- 條目元素的 canonical 與雜湊一律經 `fn_fx_freeze_entry2`（0034 的唯一實作），
  -- 本檔不另寫一份公式；所有內嵌陣列都以穩定 ID／line_no 明確排序，
  -- 不依資料庫自然順序。
  SELECT jsonb_agg(x.e ORDER BY x.e->>'object_type', COALESCE(x.e->>'object_id', ''))
    INTO v_entries
  FROM (
    -- SCOPE：來源封套。facts 可以是零筆，封套不能跟著消失。
    SELECT fn_fx_freeze_entry2('[]'::jsonb, 'SCOPE', NULL, 'scope', '1', jsonb_build_object(
      'calculation_scope', 'CASH_FLOW_SUPPORT',
      -- 物化契約版本：解析器只認得自己這一版；舊集合缺欄位一律 fail closed，
      -- **不得回查期間或 Run 主檔補值**（補值等於把凍結變成重算）。
      'materialization_contract_version', 'cfs-mat-1',
      'period_revision_id', p_period_revision,
      'period_start_date', v_period_start,
      'period_end_date', v_period_end,
      'reporting_unit_id', p_reporting_unit,
      'functional_currency', v_func, 'functional_assignment_id', v_func_asg,
      'reporting_currency', v_report, 'reporting_assignment_id', v_report_asg,
      'source_batches', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'import_batch_id', ib.import_batch_id, 'batch_version', ib.batch_version,
            'file_sha256', ib.file_sha256, 'status', ib.status::text)
          ORDER BY ib.import_batch_id), '[]'::jsonb)
        FROM import_batch ib WHERE ib.import_batch_id = ANY(p_source_batches)),
      'datasets', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'source_dataset_id', d.source_dataset_id, 'import_batch_id', d.import_batch_id,
            'dataset_content_hash', d.content_hash, 'dataset_granularity', sd.granularity,
            'dataset_content_sha256', sd.content_sha256, 'row_count', sd.row_count,
            'dataset_batch_version', sd.batch_version,
            'data_coverage_id', d.data_coverage_id, 'coverage_granularity', dc.granularity,
            'coverage_batch_version', dc.batch_version,
            'account_scope', dc.account_scope, 'completeness_status', dc.completeness_status)
          ORDER BY d.source_dataset_id), '[]'::jsonb)
        FROM cash_flow_support_dataset d
        JOIN source_dataset sd ON sd.source_dataset_id = d.source_dataset_id
        JOIN data_coverage dc ON dc.data_coverage_id = d.data_coverage_id
       WHERE d.import_batch_id = ANY(p_source_batches)
         AND d.period_revision_id = p_period_revision AND d.reporting_unit_id = p_reporting_unit),
      -- 零活動的 R2 確認 → R3 覆核已成為正式結論；不凍結的話 replay 仍要回查現行 Coverage
      'coverage_inputs', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'coverage_id', c.coverage_id, 'cash_flow_class_id', c.cash_flow_class_id,
            'status', c.status, 'confirmed_by', c.confirmed_by, 'confirmed_at', c.confirmed_at,
            'reviewed_by', c.reviewed_by, 'reviewed_at', c.reviewed_at,
            'evidence_ref', c.evidence_ref, 'coverage_exception_id', c.coverage_exception_id)
          ORDER BY c.coverage_id), '[]'::jsonb)
        FROM cash_flow_class_period_coverage c
       WHERE c.period_revision_id = p_period_revision AND c.reporting_unit_id = p_reporting_unit
         AND c.policy_version_id = p_policy_version)
    ))->0 AS e

    UNION ALL
    SELECT fn_fx_freeze_entry2('[]'::jsonb, 'CASH_FLOW_SOURCE_SELECTION', s.cf_selection_id,
      'version_no', s.version_no::text, jsonb_build_object(
      'cf_selection_id', s.cf_selection_id, 'period_revision_id', s.period_revision_id,
      'reporting_unit_id', s.reporting_unit_id, 'current_run_id', s.current_run_id,
      'opening_source_kind', s.opening_source_kind, 'prior_run_id', s.prior_run_id,
      'opening_balance_set_version_id', s.opening_balance_set_version_id,
      'selection_series_id', s.selection_series_id, 'version_no', s.version_no,
      'selected_by', s.selected_by, 'selected_at', s.selected_at))->0
      FROM period_cash_flow_source_selection s WHERE s.cf_selection_id = sel.cf_selection_id

    UNION ALL
    SELECT fn_fx_freeze_entry2('[]'::jsonb, 'CASH_FLOW_POLICY_VERSION', p.policy_version_id,
      'version_no', p.version_no::text, jsonb_build_object(
      'policy_version_id', p.policy_version_id, 'reporting_unit_id', p.reporting_unit_id,
      'method', p.method, 'required_granularity', p.required_granularity,
      'class_set_version_id', p.class_set_version_id, 'evidence_version', p.evidence_version,
      'series_id', p.series_id, 'version_no', p.version_no,
      'approved_by', p.approved_by, 'approved_at', p.approved_at))->0
      FROM cash_flow_policy_version p WHERE p.policy_version_id = p_policy_version

    UNION ALL
    SELECT fn_fx_freeze_entry2('[]'::jsonb, 'CASH_FLOW_CLASS_SET_VERSION', v.class_set_version_id,
      'version_no', v.version_no::text, jsonb_build_object(
      'class_set_version_id', v.class_set_version_id, 'label', v.label,
      'series_id', v.series_id, 'version_no', v.version_no,
      'approved_by', v.approved_by, 'approved_at', v.approved_at,
      'classes', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'cash_flow_class_id', c.cash_flow_class_id, 'code', c.code, 'name', c.name,
            'kind', c.kind, 'activity', c.activity, 'direction', c.direction,
            'is_required', c.is_required) ORDER BY c.cash_flow_class_id), '[]'::jsonb)
        FROM cash_flow_class c WHERE c.class_set_version_id = v.class_set_version_id),
      'cash_accounts', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'membership_id', m.membership_id, 'account_id', m.account_id,
            'cash_role', m.cash_role) ORDER BY m.account_id), '[]'::jsonb)
        FROM cash_flow_cash_account_membership m
       WHERE m.class_set_version_id = v.class_set_version_id)))->0
      FROM cash_flow_class_set_version v WHERE v.class_set_version_id = v_class_set

    UNION ALL
    SELECT fn_fx_freeze_entry2('[]'::jsonb, 'CASH_FLOW_MAPPING_VERSION', mv.mapping_version_id,
      'version_no', mv.version_no::text, jsonb_build_object(
      'mapping_version_id', mv.mapping_version_id, 'policy_version_id', mv.policy_version_id,
      'series_id', mv.series_id, 'version_no', mv.version_no,
      'approved_by', mv.approved_by, 'approved_at', mv.approved_at,
      'rules', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'mapping_rule_id', r.mapping_rule_id, 'source_kind', r.source_kind,
            'account_id', r.account_id, 'source_ledger_line_id', r.source_ledger_line_id,
            'source_document_id', r.source_document_id,
            'cash_flow_class_id', r.cash_flow_class_id,
            'effective_from', r.effective_from, 'effective_to', r.effective_to,
            'evidence_ref', r.evidence_ref) ORDER BY r.mapping_rule_id), '[]'::jsonb)
        FROM cash_flow_mapping_rule r WHERE r.mapping_version_id = mv.mapping_version_id)))->0
      FROM cash_flow_mapping_version mv WHERE mv.mapping_version_id = p_mapping_version

    UNION ALL
    SELECT fn_fx_freeze_entry2('[]'::jsonb, 'CASH_FLOW_OPENING_BALANCE_SET_VERSION',
      o.opening_set_version_id, 'version_no', o.version_no::text, jsonb_build_object(
      'opening_set_version_id', o.opening_set_version_id, 'evidence_ref', o.evidence_ref,
      'series_id', o.series_id, 'version_no', o.version_no,
      'approved_by', o.approved_by, 'approved_at', o.approved_at,
      'lines', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'opening_line_id', l.opening_line_id, 'account_id', l.account_id,
            'functional_amount', l.functional_amount, 'functional_currency', l.functional_currency,
            'reporting_amount', l.reporting_amount, 'reporting_currency', l.reporting_currency)
          ORDER BY l.opening_line_id), '[]'::jsonb)
        FROM cash_flow_opening_balance_line l
       WHERE l.opening_set_version_id = o.opening_set_version_id)))->0
      FROM cash_flow_opening_balance_set_version o
     WHERE o.opening_set_version_id = sel.opening_balance_set_version_id

    UNION ALL
    SELECT fn_fx_freeze_entry2('[]'::jsonb, 'CASH_FLOW_COVERAGE_EXCEPTION', x.exception_id,
      'approved', '1', jsonb_build_object(
      'exception_id', x.exception_id, 'cash_flow_class_id', x.cash_flow_class_id,
      'actual_granularity', x.actual_granularity, 'reason', x.reason,
      'evidence_ref', x.evidence_ref, 'approved_by', x.approved_by,
      'approved_at', x.approved_at))->0
      FROM cash_flow_coverage_exception x
     WHERE x.period_revision_id = p_period_revision AND x.reporting_unit_id = p_reporting_unit
       AND x.policy_version_id = p_policy_version AND x.approved_at IS NOT NULL

    UNION ALL
    SELECT fn_fx_freeze_entry2('[]'::jsonb, 'CASH_FLOW_SOURCE_FACT', f.source_fact_id,
      'content_hash', f.content_hash, jsonb_build_object(
      'source_fact_id', f.source_fact_id, 'source_dataset_id', f.source_dataset_id,
      'import_batch_id', f.import_batch_id, 'data_coverage_id', d.data_coverage_id,
      'actual_granularity', f.actual_granularity, 'source_kind', f.source_kind,
      'account_id', f.account_id, 'source_ledger_line_id', f.source_ledger_line_id,
      'source_document_id', f.source_document_id, 'source_row_id', f.source_row_id,
      'signed_amount_functional', f.signed_amount_functional,
      'functional_currency', f.functional_currency,
      'signed_amount_reporting', f.signed_amount_reporting,
      'reporting_currency', f.reporting_currency,
      'evidence_ref', f.evidence_ref, 'content_hash', f.content_hash))->0
      FROM cash_flow_source_fact f
      JOIN cash_flow_support_dataset d ON d.source_dataset_id = f.source_dataset_id
     WHERE f.period_revision_id = p_period_revision AND f.reporting_unit_id = p_reporting_unit
       AND f.import_batch_id = ANY(p_source_batches)

    UNION ALL
    -- 來源 run：交給 fn_cf_freeze_source_run_entry——它同時做**凍結當下的
    -- result hash 復驗**，並凍結足以重算該雜湊的全部證據（規則、component、CTA）。
    SELECT fn_cf_freeze_source_run_entry(src.run_id, src.role)
      FROM (VALUES (sel.current_run_id, 'CURRENT'), (sel.prior_run_id, 'PRIOR')) AS src(run_id, role)
     WHERE src.run_id IS NOT NULL
  ) x;

  -- ── 4.6 只驗物化後的集合（此後不再讀 live 表） ──
  IF v_entries IS NULL THEN
    RAISE EXCEPTION 'CFS_FREEZE_SET_EMPTY: 凍結集合為空——輸入解析失敗';
  END IF;
  SELECT count(*) INTO v_n FROM jsonb_array_elements(v_entries) t
   WHERE t->>'object_type' = 'CASH_FLOW_SOURCE_FACT'
     AND NOT (t->'payload' ? 'data_coverage_id');
  IF v_n > 0 THEN
    RAISE EXCEPTION 'CFS_FREEZE_FACT_COVERAGE_MISSING: % 筆事實沒有綁定的 DataCoverage', v_n;
  END IF;

  -- ── 4.7 寫入：集合雜湊的排序逐字沿用 0034，生成端與驗證端不得分岔 ──
  SELECT fn_fx_sha(string_agg(t->>'hash', '|'
           ORDER BY t->>'object_type', COALESCE(t->>'object_id', ''), t->>'hash'))
    INTO v_set_hash FROM jsonb_array_elements(v_entries) t;

  v_manifest := gen_random_uuid();
  INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id,
          period_revision_id, calculation_scope, canonicalization_version,
          frozen_set_content_hash, created_by)
  VALUES (v_manifest, v_tenant, v_eng, p_period_revision, 'CASH_FLOW_SUPPORT', 'sqlcanon-2',
          v_set_hash, p_actor);
  FOR e IN SELECT * FROM jsonb_array_elements(v_entries) LOOP
    INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
            domain_version_kind, domain_version_value, content_canonical, content_hash, payload)
    VALUES (v_tenant, v_manifest, e->>'object_type', (e->>'object_id')::uuid,
            e->>'kind', COALESCE(e->>'value', ''), e->>'canonical', e->>'hash', e->'payload');
  END LOOP;

  -- ── 4.8 run 與橋接：沿用 0043 的入口，不重寫一份 ──
  -- 它在尾端呼叫 fn_cf_manifest_assert_contract，因此結構契約在同一交易內查證；
  -- 任何一項不成立，整份凍結與 run 一起回滾。
  v_run := fn_cash_flow_support_run_create(v_manifest, p_source_batches, p_actor, p_engine_version);
  RETURN v_run;
END $$;

-- ═══ 2　結構契約：新版必要欄位 ═════════════════════════════════════
-- `fn_manifest_verify` 驗的是「還是不是原來那一份」；缺了新版欄位的集合雜湊
-- 完全自洽，卻解析不出東西。契約版本因此要在結構層就擋下來。
CREATE OR REPLACE FUNCTION fn_cf_manifest_assert_contract(p_manifest uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_scope text; v_kind text; v_t text; v_n int; v_opening int; v_runs int; v_tenant uuid;
        v_scope_payload jsonb;
BEGIN
  SELECT tenant_id, calculation_scope INTO v_tenant, v_scope
    FROM calculation_input_manifest WHERE manifest_id = p_manifest;
  IF v_tenant IS DISTINCT FROM current_tenant() THEN
    RAISE EXCEPTION 'CROSS_TENANT_DENIED: 凍結集合不屬於目前租戶';
  END IF;

  PERFORM fn_manifest_verify(p_manifest);

  IF v_scope IS DISTINCT FROM 'CASH_FLOW_SUPPORT' THEN
    RAISE EXCEPTION 'CFS_MANIFEST_SCOPE_MISMATCH: 凍結集合的 scope 為 %，不是現金流支持',
      COALESCE(v_scope, '（不存在）');
  END IF;

  -- 物化契約版本先驗：版本決定其餘欄位怎麼解讀，它不對的話後面的結構判定
  -- 都是在用新版的期待去看一份舊集合。舊集合在此 fail closed。
  -- 物化契約：版本與新版必要欄位缺一不可（舊集合在此 fail closed）
  SELECT payload INTO v_scope_payload FROM calculation_manifest_entry
   WHERE manifest_id = p_manifest AND object_type = 'SCOPE';
  IF v_scope_payload->>'materialization_contract_version' IS DISTINCT FROM 'cfs-mat-1' THEN
    RAISE EXCEPTION 'CFS_MANIFEST_CONTRACT_VERSION_UNSUPPORTED: SCOPE 的物化契約版本為 %，本引擎只支援 cfs-mat-1',
      COALESCE(v_scope_payload->>'materialization_contract_version', '（缺）');
  END IF;
  IF v_scope_payload->>'period_end_date' IS NULL OR v_scope_payload->>'functional_currency' IS NULL THEN
    RAISE EXCEPTION 'CFS_MANIFEST_SCOPE_INCOMPLETE: SCOPE 缺期間終了日或功能幣——不得回查主檔補值';
  END IF;

  FOREACH v_t IN ARRAY ARRAY['SCOPE','CASH_FLOW_SOURCE_SELECTION','CASH_FLOW_POLICY_VERSION',
                             'CASH_FLOW_CLASS_SET_VERSION','CASH_FLOW_MAPPING_VERSION'] LOOP
    SELECT count(*) INTO v_n FROM calculation_manifest_entry
     WHERE manifest_id = p_manifest AND object_type = v_t;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'CFS_MANIFEST_SINGLETON_VIOLATION: % 應恰一筆，實得 %', v_t, v_n;
    END IF;
  END LOOP;

  SELECT payload->>'opening_source_kind' INTO v_kind FROM calculation_manifest_entry
   WHERE manifest_id = p_manifest AND object_type = 'CASH_FLOW_SOURCE_SELECTION';
  SELECT count(*) INTO v_opening FROM calculation_manifest_entry
   WHERE manifest_id = p_manifest AND object_type = 'CASH_FLOW_OPENING_BALANCE_SET_VERSION';
  IF (v_kind = 'FIRST_PERIOD_EVIDENCE') <> (v_opening = 1) THEN
    RAISE EXCEPTION 'CFS_MANIFEST_OPENING_EVIDENCE_MISMATCH: 期初來源為 % 卻凍結了 % 筆期初證據集合',
      v_kind, v_opening;
  END IF;

  SELECT count(*) INTO v_runs FROM calculation_manifest_entry
   WHERE manifest_id = p_manifest AND object_type = 'SOURCE_CALCULATION_RUN';
  IF v_runs <> (CASE WHEN v_kind = 'PRIOR_SELECTED_RUN' THEN 2 ELSE 1 END) THEN
    RAISE EXCEPTION 'CFS_MANIFEST_SOURCE_RUN_VIOLATION: 期初來源為 % 時應凍結 % 筆來源 run，實得 %',
      v_kind, (CASE WHEN v_kind = 'PRIOR_SELECTED_RUN' THEN 2 ELSE 1 END), v_runs;
  END IF;

  SELECT count(*) INTO v_n FROM calculation_manifest_entry
   WHERE manifest_id = p_manifest AND object_id IS NULL AND object_type <> 'SCOPE';
  IF v_n > 0 THEN
    RAISE EXCEPTION 'CFS_MANIFEST_OBJECT_ID_REQUIRED: % 筆條目沒有 object_id（只有 SCOPE 允許）', v_n;
  END IF;
END $$;
REVOKE ALL ON FUNCTION fn_cf_manifest_assert_contract(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION fn_cf_manifest_assert_contract(uuid) FROM app_runtime;

-- ═══ 3　私有解析器：只讀凍結 payload ═══════════════════════════════
-- 本函式**不查** cash_flow_source_fact、映射／分類主檔或現行 coverage：
-- 那正是「重演」與「重算」的分界線。它只回傳候選列，不寫入任何東西——
-- DATA_PRESENT、粒度、完整度與 K1～K4 屬 3B，支持列落地屬 3C。
CREATE FUNCTION fn_cf_parse_support_candidates(p_run uuid)
RETURNS TABLE (
  source_fact_id uuid, source_kind text, mapping_rule_id uuid, cash_flow_class_id uuid,
  class_code text, class_kind text, activity text, is_required boolean,
  signed_amount_functional numeric, functional_currency text,
  signed_amount_reporting numeric, reporting_currency text,
  actual_granularity text, data_coverage_id uuid, fact_content_hash text
) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_tenant uuid; v_manifest uuid; v_scope text; v_sc jsonb; v_period_end date;
  v_func text; v_report text; v_rules jsonb; v_classes jsonb;
  f record; v_matched jsonb; v_rule jsonb; v_class jsonb; v_n int;
BEGIN
  SELECT r.tenant_id, r.manifest_id, m.calculation_scope
    INTO v_tenant, v_manifest, v_scope
    FROM calculation_run r JOIN calculation_input_manifest m ON m.manifest_id = r.manifest_id
   WHERE r.calculation_run_id = p_run;
  IF v_tenant IS DISTINCT FROM current_tenant() THEN
    RAISE EXCEPTION 'CROSS_TENANT_DENIED: Run 不屬於目前租戶';
  END IF;
  IF v_scope IS DISTINCT FROM 'CASH_FLOW_SUPPORT' THEN
    RAISE EXCEPTION 'CFS_PARSE_SCOPE_MISMATCH: 只有現金流支持 run 可解析候選列（scope＝%）',
      COALESCE(v_scope, '（不存在）');
  END IF;

  SELECT payload INTO v_sc FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'SCOPE';
  IF v_sc->>'materialization_contract_version' IS DISTINCT FROM 'cfs-mat-1' THEN
    RAISE EXCEPTION 'CFS_MANIFEST_CONTRACT_VERSION_UNSUPPORTED: SCOPE 的物化契約版本為 %，本引擎只支援 cfs-mat-1',
      COALESCE(v_sc->>'materialization_contract_version', '（缺）');
  END IF;
  v_period_end := (v_sc->>'period_end_date')::date;
  v_func := v_sc->>'functional_currency';
  v_report := v_sc->>'reporting_currency';
  IF v_period_end IS NULL OR v_func IS NULL THEN
    RAISE EXCEPTION 'CFS_MANIFEST_SCOPE_INCOMPLETE: SCOPE 缺期間終了日或功能幣——不得回查主檔補值';
  END IF;

  SELECT payload->'rules' INTO v_rules FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'CASH_FLOW_MAPPING_VERSION';
  SELECT payload->'classes' INTO v_classes FROM calculation_manifest_entry
   WHERE manifest_id = v_manifest AND object_type = 'CASH_FLOW_CLASS_SET_VERSION';

  FOR f IN SELECT e.payload AS p FROM calculation_manifest_entry e
            WHERE e.manifest_id = v_manifest AND e.object_type = 'CASH_FLOW_SOURCE_FACT'
            ORDER BY e.object_id
  LOOP
    -- 命中判定：source_kind 決定比對哪一個引用；生效區間必須涵蓋凍結的期間終了日。
    -- 命中條件只寫一次——寫兩份遲早有一份先鬆掉。
    SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO v_matched
      FROM jsonb_array_elements(COALESCE(v_rules, '[]'::jsonb)) x
     WHERE x->>'source_kind' = f.p->>'source_kind'
       AND ((x->>'source_kind') = 'ACCOUNT'
              AND x->>'account_id' IS NOT DISTINCT FROM f.p->>'account_id'
         OR (x->>'source_kind') IN ('JOURNAL_LINE','SUBLEDGER_ITEM')
              AND x->>'source_ledger_line_id' IS NOT DISTINCT FROM f.p->>'source_ledger_line_id'
         OR (x->>'source_kind') = 'DOCUMENT'
              AND x->>'source_document_id' IS NOT DISTINCT FROM f.p->>'source_document_id')
       AND (x->>'effective_from' IS NULL OR (x->>'effective_from')::date <= v_period_end)
       AND (x->>'effective_to'   IS NULL OR (x->>'effective_to')::date   >= v_period_end);
    v_n := jsonb_array_length(v_matched);
    IF v_n = 0 THEN
      RAISE EXCEPTION 'CFS_UNMAPPED_SOURCE: 事實 % 未命中任何凍結映射規則——未映射就是未映射，不得歸入預設分類',
        f.p->>'source_fact_id';
    END IF;
    IF v_n > 1 THEN
      RAISE EXCEPTION 'CFS_MAPPING_AMBIGUOUS: 事實 % 在凍結映射中命中 % 條規則',
        f.p->>'source_fact_id', v_n;
    END IF;
    v_rule := v_matched->0;

    SELECT c INTO v_class FROM jsonb_array_elements(COALESCE(v_classes, '[]'::jsonb)) c
     WHERE c->>'cash_flow_class_id' = v_rule->>'cash_flow_class_id'
     LIMIT 1;
    IF v_class IS NULL THEN
      RAISE EXCEPTION 'CFS_PARSE_CLASS_NOT_IN_SET: 命中的分類不在凍結的分類集合內（事實 %）',
        f.p->>'source_fact_id';
    END IF;

    source_fact_id  := (f.p->>'source_fact_id')::uuid;
    source_kind     := f.p->>'source_kind';
    mapping_rule_id := (v_rule->>'mapping_rule_id')::uuid;
    cash_flow_class_id := (v_class->>'cash_flow_class_id')::uuid;
    class_code  := v_class->>'code';
    class_kind  := v_class->>'kind';
    activity    := v_class->>'activity';
    is_required := (v_class->>'is_required')::boolean;
    -- 金額與幣別原樣承接：解析器不做任何運算、不淨額化、不換算
    signed_amount_functional := (f.p->>'signed_amount_functional')::numeric;
    functional_currency      := f.p->>'functional_currency';
    signed_amount_reporting  := (f.p->>'signed_amount_reporting')::numeric;
    reporting_currency       := f.p->>'reporting_currency';
    actual_granularity := f.p->>'actual_granularity';
    data_coverage_id   := (f.p->>'data_coverage_id')::uuid;
    fact_content_hash  := f.p->>'content_hash';
    RETURN NEXT;
  END LOOP;
  RETURN;
END $$;
REVOKE ALL ON FUNCTION fn_cf_parse_support_candidates(uuid) FROM PUBLIC;

-- ═══ 4　權限 ═══════════════════════════════════════════════════════
REVOKE ALL ON FUNCTION fn_cash_flow_support_freeze_and_run(uuid, uuid, uuid, uuid, uuid[], uuid, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_cash_flow_support_freeze_and_run(uuid, uuid, uuid, uuid, uuid[], uuid, text)
  TO app_runtime;
