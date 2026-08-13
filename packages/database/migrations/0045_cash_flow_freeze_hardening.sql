-- 0045 現金流凍結的收口（SLICE-M3-04 2b 第二刀 A 的 hardening）
--
-- 0044 走查抓出三件必須在同一刀內收口的事：
--
-- 1. **結構驗證函式有跨租戶探測面**：`fn_cf_manifest_assert_contract` 是
--    SECURITY DEFINER 卻授權給 app_runtime，且不驗 `current_tenant()`——
--    等於一支可以拿任意已知 UUID 繞過 RLS 探測他人 Manifest 是否存在、
--    結構是否完整的工具。它只是內部 helper，撤回授權並補租戶查證。
-- 2. **來源 run 沒有真的證明「凍結實際輸出」**：FX 的 payload 少了
--    `translation_policy_rule_id`、component 的來源證據與 CTA 的政策／匯率版本，
--    因此**無法由 payload 重算來源 run 的 result hash**；而且凍結當下沒有重算並
--    比對來源 run 自己的 `result_content_hash`——終態輸出若被資料修復破壞，
--    0044 會把「損壞的行 ＋ 舊雜湊」一起封存，之後永遠對不出來。
-- 3. **0044 檔頭關於「改選競態」的記載是錯的**：`fn_cf_select_source`（0042）
--    本來就 `FOR UPDATE OF pr`，與凍結鎖的是同一列，兩者在期間列上序列化。
--    該邊界不存在，檔頭已更正，並改以雙 session 測試證明。
--
-- ## 本檔交付
--
-- | # | 收口 |
-- |---|---|
-- | 1 | `fn_cf_manifest_assert_contract` 撤回 app_runtime 的 EXECUTE ＋ 加 `current_tenant()` 查證 |
-- | 2 | `fn_calc_result_hash(run)`：依 scope 重算來源 run 的結果雜湊 |
-- | 3 | `fn_cf_freeze_source_run_entry(run, role)`：凍結完整輸出證據 ＋ **凍結當下復驗 result hash** |
-- | 4 | 凍結入口改用該 helper（其餘邏輯不動） |
--
-- ## `fn_calc_result_hash` 的兩條公式都是**既有生成端的鏡像**
--
-- * `FX_TRANSLATION`：逐字取自 `fn_fx_materialize`（0034）——涵蓋金額**與來源證據**
--   （命中規則、component 的觀測／批次／期初引用、CTA 的政策與匯率版本）。
-- * 其餘（`NO_FX`）：逐字取自 worker 的 canonical 結果雜湊
--   （`apps/worker/src/worker.ts` 的 `_res`）：排序後的（層｜科目｜借｜貸）。
--
-- 兩者是**鏡像而非唯一實作**，這是本檔唯一接受的重複——因為生成端一個在 SQL、
-- 一個在 TypeScript worker 裡，沒有共用的位置。防分岔的方式是把它釘死在測試上：
-- 引擎產生的折算 run 與 worker 產生的 NO_FX run 都必須滿足
-- `fn_calc_result_hash(run) = run.result_content_hash`。任一端改了公式，該斷言就轉紅。

-- ═══ 1　結構驗證 helper 私有化 ═════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_cf_manifest_assert_contract(p_manifest uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_scope text; v_kind text; v_t text; v_n int; v_opening int; v_runs int; v_tenant uuid;
BEGIN
  -- SECURITY DEFINER 不受 RLS 保護：租戶必須自己查，否則本函式就是一支
  -- 「拿已知 UUID 探測他人物件」的工具（不同錯誤訊息就是資訊）。
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

-- ═══ 2　來源 run 的結果雜湊：依 scope 重算 ═════════════════════════
CREATE FUNCTION fn_calc_result_hash(p_run uuid) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_scope text; v_hash text;
BEGIN
  SELECT m.calculation_scope INTO v_scope
    FROM calculation_run r JOIN calculation_input_manifest m ON m.manifest_id = r.manifest_id
   WHERE r.calculation_run_id = p_run;
  IF v_scope IS NULL THEN
    RETURN NULL;
  END IF;
  IF v_scope = 'FX_TRANSLATION' THEN
    -- fn_fx_materialize（0034）的鏡像：涵蓋金額與來源證據
    SELECT fn_fx_sha(string_agg(part, '|' ORDER BY part)) INTO v_hash FROM (
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
  ELSE
    -- worker 的 canonical 結果雜湊鏡像：排序後的（層｜科目｜借｜貸）
    SELECT encode(sha256(convert_to(COALESCE(string_agg(
             posting_layer || '|' || account_code || '|' || debit::text || '|' || credit::text,
             E'\n' ORDER BY posting_layer, account_code), ''), 'UTF8')), 'hex')
      INTO v_hash FROM balance_snapshot_line WHERE calculation_run_id = p_run;
  END IF;
  RETURN v_hash;
END $$;
REVOKE ALL ON FUNCTION fn_calc_result_hash(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_calc_result_hash(uuid) TO app_runtime;

-- ═══ 3　來源 run 的凍結條目：完整證據 ＋ 凍結當下復驗 ═══════════════
-- 「凍結實際輸出」要成立必須兩件事同時做到：payload 足以重算來源 run 的
-- result hash；而且**凍結的那一刻**重算過一次並與記載的雜湊相符。
-- 少了後者，被資料修復破壞的輸出會連同舊雜湊一起被封存，日後永遠對不出來。
CREATE FUNCTION fn_cf_freeze_source_run_entry(p_run uuid, p_role text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE cr record; m record; v_recomputed text; v_payload jsonb;
BEGIN
  SELECT * INTO cr FROM calculation_run WHERE calculation_run_id = p_run;
  IF cr.calculation_run_id IS NULL THEN
    RAISE EXCEPTION 'CFS_SOURCE_RUN_NOT_FOUND: 來源 run 不存在（%）', p_run;
  END IF;
  SELECT * INTO m FROM calculation_input_manifest WHERE manifest_id = cr.manifest_id;
  IF cr.result_content_hash IS NULL OR btrim(cr.result_content_hash) = '' THEN
    RAISE EXCEPTION 'CFS_SOURCE_RUN_NO_RESULT_HASH: 來源 run 沒有結果雜湊，不能作為凍結輸入';
  END IF;
  v_recomputed := fn_calc_result_hash(p_run);
  IF v_recomputed IS DISTINCT FROM cr.result_content_hash THEN
    RAISE EXCEPTION 'CFS_SOURCE_RUN_RESULT_HASH_MISMATCH: 來源 run % 的輸出與其結果雜湊不符（重算 %／記載 %）——不得把損壞的輸出連同舊雜湊一起封存',
      p_run, COALESCE(v_recomputed, '(null)'), cr.result_content_hash;
  END IF;

  v_payload := jsonb_build_object(
    'calculation_run_id', cr.calculation_run_id, 'role', p_role,
    'calculation_scope', m.calculation_scope, 'manifest_id', cr.manifest_id,
    'engine_version', cr.engine_version, 'status', cr.status,
    'result_content_hash', cr.result_content_hash,
    'result_hash_verified_at_freeze', true,
    'output_kind', m.calculation_scope,
    'lines', CASE WHEN m.calculation_scope = 'FX_TRANSLATION' THEN
      (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'translation_result_id', tr.translation_result_id,
            'source_snapshot_line_id', tr.source_snapshot_line_id,
            'source_account_id', bsl.account_id, 'source_account_code', bsl.account_code,
            'source_account_name', bsl.account_name,
            'source_posting_layer', bsl.posting_layer,
            'source_debit_functional', bsl.debit, 'source_credit_functional', bsl.credit,
            'amount_role', tr.amount_role, 'currency_code', tr.currency_code,
            'source_debit', tr.source_debit, 'source_credit', tr.source_credit,
            'result_debit', tr.result_debit, 'result_credit', tr.result_credit,
            -- result hash 涵蓋命中的規則與逐筆 component，凍結就必須帶上它們，
            -- 否則由 payload 重算不出來源 run 的結果雜湊。
            'translation_policy_rule_id', tr.translation_policy_rule_id,
            'components', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                  'component_id', c.component_id, 'line_no', c.line_no,
                  'source_kind', c.source_kind,
                  'exchange_rate_observation_id', c.exchange_rate_observation_id,
                  'equity_lot_id', c.equity_lot_id,
                  'opening_balance_id', c.opening_balance_id,
                  'translation_adjustment_line_id', c.translation_adjustment_line_id,
                  'source_debit', c.source_debit, 'source_credit', c.source_credit,
                  'result_debit', c.result_debit, 'result_credit', c.result_credit)
                ORDER BY c.line_no), '[]'::jsonb)
              FROM translation_result_component c
             WHERE c.translation_result_id = tr.translation_result_id))
          ORDER BY tr.source_snapshot_line_id, tr.amount_role), '[]'::jsonb)
         FROM translation_result tr
         JOIN balance_snapshot_line bsl ON bsl.snapshot_line_id = tr.source_snapshot_line_id
        WHERE tr.calculation_run_id = p_run)
      ELSE
      (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'snapshot_line_id', b.snapshot_line_id, 'posting_layer', b.posting_layer,
            'posting_layer_id', b.posting_layer_id,
            'account_id', b.account_id, 'account_code', b.account_code,
            'account_name', b.account_name, 'debit', b.debit, 'credit', b.credit)
          ORDER BY b.snapshot_line_id), '[]'::jsonb)
         FROM balance_snapshot_line b WHERE b.calculation_run_id = p_run)
      END,
    -- CTA 殘差的政策與匯率版本證據：result hash 的第二個 UNION 分支就是它
    'cta_lines', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'translation_line_id', tl.translation_line_id, 'line_no', tl.line_no,
          'account_id', tl.account_id, 'debit', tl.debit, 'credit', tl.credit,
          'translation_entry_id', te.translation_entry_id,
          'translation_policy_version_id', te.translation_policy_version_id,
          'exchange_rate_version_id', te.exchange_rate_version_id,
          'posting_layer_id', te.posting_layer_id, 'rule_type', te.rule_type,
          'reporting_currency', te.reporting_currency)
        ORDER BY tl.translation_line_id), '[]'::jsonb)
       FROM translation_adjustment_line tl
       JOIN translation_adjustment_entry te ON te.translation_entry_id = tl.translation_entry_id
      WHERE te.calculation_run_id = p_run));

  RETURN fn_fx_freeze_entry2('[]'::jsonb, 'SOURCE_CALCULATION_RUN', p_run,
           'result_hash', cr.result_content_hash, v_payload)->0;
END $$;
REVOKE ALL ON FUNCTION fn_cf_freeze_source_run_entry(uuid, text) FROM PUBLIC;

-- ═══ 4　凍結入口改用該 helper（其餘邏輯不動） ═══════════════════════
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
  -- INSERT，不 UPDATE 舊列，`FOR UPDATE` 攔不到——那屬於檔頭記錄的「改選競態」
  -- 同一類邊界，由後續刀的期間級就緒判定把關。
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
      'period_revision_id', p_period_revision,
      'reporting_unit_id', p_reporting_unit,
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

-- ═══ 5　權限 ═══════════════════════════════════════════════════════
REVOKE ALL ON FUNCTION fn_cash_flow_support_freeze_and_run(uuid, uuid, uuid, uuid, uuid[], uuid, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_cash_flow_support_freeze_and_run(uuid, uuid, uuid, uuid, uuid[], uuid, text)
  TO app_runtime;
