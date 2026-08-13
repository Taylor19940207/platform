-- 0044 現金流支持資料：Manifest 的 system-only 凍結入口（SLICE-M3-04 2b 第二刀 A）
--
-- 0043 把 run 的建立收斂成單一入口，但**輸入還沒有被凍結**：`calculation_input_manifest`
-- 與 `calculation_manifest_entry` 對 app_runtime 一直是可寫的（NO_FX 需要），所以
-- 現金流的 run 可以掛在一份內容任人捏造、甚至完全空白的 Manifest 上。
-- 沒有凍結，「重演」只能回查現行主檔——那不是重演，是重算。
--
-- ## 契約（本刀的完成範圍）
--
-- | 項目 | 決定 |
-- |---|---|
-- | 對外入口 | `fn_cash_flow_support_freeze_and_run(...)`，案件層 **R2**，唯一外部路徑 |
-- | 0043 的 `fn_cash_flow_support_run_create` | 降為**內部 helper**：撤回 app_runtime 的 EXECUTE |
-- | 直插封閉 | manifest／entry 的 INSERT trigger **只對 `CASH_FLOW_SUPPORT`** 要求執行身分為 owner；NO_FX／FX 路徑不動 |
-- | 版本輸入 | 政策與映射版本**由參數顯式帶入**——不得以「最新已批准」推導（驗收 1 的反證） |
-- | 權威來源選定 | 由既有 `fn_current_cf_source_selection()` 取現行選定（取代鏈，本就是顯式選定物件） |
-- | canonical／雜湊 | 逐字沿用 0034 的 `fn_fx_freeze_entry2` 與集合雜湊排序；驗證沿用 `fn_manifest_verify` |
-- | 結構契約 | 新增薄函式 `fn_cf_manifest_assert_contract()`：先呼叫 `fn_manifest_verify`，再驗 CFS 的結構 |
-- | 空 Manifest 的 run | helper 在寫入後、回傳前呼叫 `fn_cf_manifest_assert_contract`，**任何呼叫者**都不可能建立空 Manifest 的 run |
--
-- ## 凍結條目清單
--
-- | object_type | 筆數 | object_id |
-- |---|---|---|
-- | `SCOPE` | 恰 1 | NULL（來源封套：批次、資料集、覆蓋度、逐期覆蓋結論） |
-- | `CASH_FLOW_SOURCE_SELECTION` | 恰 1 | cf_selection_id |
-- | `CASH_FLOW_POLICY_VERSION` | 恰 1 | policy_version_id |
-- | `CASH_FLOW_CLASS_SET_VERSION` | 恰 1 | class_set_version_id（含分類與現金科目 membership 陣列） |
-- | `CASH_FLOW_MAPPING_VERSION` | 恰 1 | mapping_version_id（含規則陣列） |
-- | `CASH_FLOW_OPENING_BALANCE_SET_VERSION` | 0 或 1 | 恰 1 ⟺ 選定為 `FIRST_PERIOD_EVIDENCE` |
-- | `CASH_FLOW_COVERAGE_EXCEPTION` | 0..n | exception_id |
-- | `CASH_FLOW_SOURCE_FACT` | 0..n | source_fact_id（**零活動合法，facts 可為零筆**） |
-- | `SOURCE_CALCULATION_RUN` | 1 或 2 | run_id（`PRIOR_SELECTED_RUN` 時另含前期選定 run） |
--
-- **`SCOPE` 承載來源封套而不是把它塞進 fact**：facts 可以是零筆，若封套只存在於
-- fact 的 payload，零活動期間整個來源封套就會消失，後續也無法「以那一筆
-- `data_coverage_id` 判定實際粒度」。同理，零活動的 R2→R3 正式結論放在
-- `SCOPE.coverage_inputs`，否則 replay 仍得回查現行 Coverage。
--
-- **來源 run 凍結實際行資料，不只身分＋雜湊**：只凍雜湊的話，後續仍得查來源 run
-- 的結果表，資料若損壞只能失敗而無法重演——那不符合「replay 只讀凍結 payload」。
-- 以 `output_kind` 區分原始輸出形狀（`NO_FX` 為 `balance_snapshot_line`；
-- `FX_TRANSLATION` 為 `translation_result` 加其來源 snapshot 身分），
-- **本刀不換算、不選現金科目、不計算控制總額**。
--
-- ## 本檔明確不做
--
-- * `CashFlowSupportLine`、`DATA_PRESENT` 衍生、粒度判定、K1～K4、結果雜湊與 replay。
--   結果雜湊與 replay 已改排到支持資料列那一刀：在有真實輸出之前，replay 只會是
--   拿 Manifest 集合雜湊冒充 result hash。
-- * 畫面與期間遷移解鎖。
-- * **不回改 0039～0042**。0043 只加一行（helper 尾端的結構契約查證）與一次 REVOKE。
--
-- ## 兩個已知邊界
--
-- 1. **改選競態**：`fn_cf_select_source`（0042，不得回改）不鎖 `period_revision`，
--    因此凍結進行中仍可能有新版選定提交。凍結誠實記錄**凍結時刻的現行選定**；
--    「凍結後又改選」由期間級就緒判定把關（後續刀）。不跨函式補鎖。
-- 2. **期間列鎖目前沒有測試能單獨證明它**：任何兩次同期間的凍結都會共用政策／
--    映射／選定那幾列的 `FOR UPDATE`，序列化實際上是它們做到的（實測反證——拿掉
--    `FOR UPDATE OF pr` 仍全綠）。保留它是為了「先鎖期間、再解析現行選定」這個
--    順序保證；不要因為它看起來多餘就拿掉，也不要宣稱測試證明過它。
-- 3. **FX 來源 run 的原始輸出形狀（`translation_result`）尚未被測試走過**：
--    現金流的來源 run 若是折算 run，選定會要求同期的 `PeriodFxRunSelection`，
--    而那需要容許值版本＋折算調節＋折算政策鏈＋匯率版本——等於在現金流 fixture
--    裡重建整條 M3-02／M3-03 的鏈。NO_FX 分支已逐筆驗過（凍結行資料等於實際輸出）。
--    **下一刀（支持資料列與 K1～K4）本來就需要一個 FX 期間，該條斷言在那裡補。**
-- 4. `SCOPE` 與 `SOURCE_CALCULATION_RUN` 是與 NO_FX／FX **共用**的 object_type。
--    本檔的部分唯一索引與 object_id 檢查因此也會約束既有 manifest——實查兩者
--    本來就滿足（各恰一筆、`SOURCE_CALCULATION_RUN` 的 object_id 恆非空），
--    但這是動到既有最後防線的變更，落地後必須立刻跑 fx 與端到端計算套件。

-- ═══ 1　system-only：CFS 的 Manifest 與條目只能由函式寫入 ══════════
-- 與 0043 同一個理由：app_runtime 對這兩張表的 INSERT 不能收回（NO_FX 要用），
-- 所以用**執行身分**當邊界。兩支都必須維持 **SECURITY INVOKER**——改成 DEFINER
-- 之後 `current_user` 會變成 owner，檢查對誰都通過。
CREATE FUNCTION fn_cfs_manifest_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_owner name;
BEGIN
  IF NEW.calculation_scope = 'CASH_FLOW_SUPPORT' THEN
    SELECT pg_catalog.pg_get_userbyid(c.relowner) INTO v_owner
      FROM pg_catalog.pg_class c WHERE c.oid = TG_RELID;
    IF current_user <> v_owner THEN
      RAISE EXCEPTION 'CFS_MANIFEST_SYSTEM_ONLY: 現金流的凍結集合只能由 fn_cash_flow_support_freeze_and_run 建立';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cim_cfs_system_only BEFORE INSERT ON calculation_input_manifest
  FOR EACH ROW EXECUTE FUNCTION fn_cfs_manifest_insert_guard();

CREATE FUNCTION fn_cfs_manifest_entry_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_owner name; v_scope text;
BEGIN
  SELECT calculation_scope INTO v_scope
    FROM calculation_input_manifest WHERE manifest_id = NEW.manifest_id;
  -- 查不到＝跨租戶而 RLS 擋掉（本函式是 INVOKER，執行身分就是寫入者）。
  -- 不能因此當作「不是現金流」放行——那正好是繞過本守衛的方式。
  IF v_scope IS NULL THEN
    RAISE EXCEPTION 'CFS_MANIFEST_SYSTEM_ONLY: 條目所屬的凍結集合不存在或不可見（fail closed）';
  END IF;
  IF v_scope = 'CASH_FLOW_SUPPORT' THEN
    SELECT pg_catalog.pg_get_userbyid(c.relowner) INTO v_owner
      FROM pg_catalog.pg_class c WHERE c.oid = TG_RELID;
    IF current_user <> v_owner THEN
      RAISE EXCEPTION 'CFS_MANIFEST_SYSTEM_ONLY: 現金流的凍結條目只能由 fn_cash_flow_support_freeze_and_run 建立';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cme_cfs_system_only BEFORE INSERT ON calculation_manifest_entry
  FOR EACH ROW EXECUTE FUNCTION fn_cfs_manifest_entry_insert_guard();

-- ═══ 2　條目的唯一性（結構層最後防線） ═════════════════════════════
-- singleton：一份凍結集合內每種至多一筆。
CREATE UNIQUE INDEX cme_cf_singleton_uq ON calculation_manifest_entry (manifest_id, object_type)
  WHERE object_type IN ('SCOPE','CASH_FLOW_SOURCE_SELECTION','CASH_FLOW_POLICY_VERSION',
                        'CASH_FLOW_CLASS_SET_VERSION','CASH_FLOW_MAPPING_VERSION',
                        'CASH_FLOW_OPENING_BALANCE_SET_VERSION');
-- 多值：同一物件不得凍結兩次。
CREATE UNIQUE INDEX cme_cf_multi_uq
  ON calculation_manifest_entry (manifest_id, object_type, object_id)
  WHERE object_type IN ('CASH_FLOW_COVERAGE_EXCEPTION','CASH_FLOW_SOURCE_FACT',
                        'SOURCE_CALCULATION_RUN');
-- PostgreSQL 的唯一索引把每個 NULL 視為互異，object_id 可空就等於留下重複通道。
ALTER TABLE calculation_manifest_entry ADD CONSTRAINT cme_multi_object_id_ck CHECK (
  object_type NOT IN ('CASH_FLOW_COVERAGE_EXCEPTION','CASH_FLOW_SOURCE_FACT',
                      'SOURCE_CALCULATION_RUN')
  OR object_id IS NOT NULL);

-- ═══ 3　結構契約：薄薄一層，不重寫 canonical 或 hash ═══════════════
-- `fn_manifest_verify` 驗的是「這份集合還是不是原來那一份」；它不知道現金流
-- 需要哪些條目。缺一份政策或一份選定的集合，雜湊完全自洽——卻不能拿來計算。
CREATE FUNCTION fn_cf_manifest_assert_contract(p_manifest uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_scope text; v_kind text; v_t text; v_n int; v_opening int; v_runs int;
BEGIN
  -- 完整性先於結構：內容若已被竄改，結構對不對都沒有意義
  PERFORM fn_manifest_verify(p_manifest);

  SELECT calculation_scope INTO v_scope
    FROM calculation_input_manifest WHERE manifest_id = p_manifest;
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

  -- 來源 run：本期一筆；期初來自前期已選定結果時另有一筆
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

-- ═══ 4　凍結並建立 run：唯一對外入口 ═══════════════════════════════
-- 順序是本函式的全部重點：
--   鎖（期間 → 版本列 → 批次）→ **單一 statement 物化整份輸入** → 只驗物化後的
--   集合 → 寫入 → 結構契約查證。
-- PL/pgSQL 在預設隔離等級下每個 statement 各有 snapshot，「同一個函式」證明不了
-- 「同一份輸入」；先鎖再以**一個** statement 建成 `v_entries`，之後所有判定都只讀
-- 這個變數，凍結內容才真的是同一時刻的事實。
CREATE FUNCTION fn_cash_flow_support_freeze_and_run(
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
    -- 來源 run：凍結**實際行資料**。只凍身分＋雜湊的話，後續仍得查來源結果表，
    -- 資料若損壞只能失敗而無法重演。以 output_kind 區分原始輸出形狀，本刀不換算。
    SELECT fn_fx_freeze_entry2('[]'::jsonb, 'SOURCE_CALCULATION_RUN', cr.calculation_run_id,
      'result_hash', cr.result_content_hash, jsonb_build_object(
      'calculation_run_id', cr.calculation_run_id, 'role', src.role,
      'calculation_scope', m.calculation_scope, 'manifest_id', cr.manifest_id,
      'engine_version', cr.engine_version, 'status', cr.status,
      'result_content_hash', cr.result_content_hash,
      'output_kind', m.calculation_scope,
      'lines', CASE WHEN m.calculation_scope = 'FX_TRANSLATION' THEN
        (SELECT COALESCE(jsonb_agg(jsonb_build_object(
              'translation_result_id', tr.translation_result_id,
              'source_snapshot_line_id', tr.source_snapshot_line_id,
              'source_account_id', bsl.account_id, 'source_account_code', bsl.account_code,
              'source_posting_layer', bsl.posting_layer,
              'amount_role', tr.amount_role, 'currency_code', tr.currency_code,
              'source_debit', tr.source_debit, 'source_credit', tr.source_credit,
              'result_debit', tr.result_debit, 'result_credit', tr.result_credit)
            ORDER BY tr.source_snapshot_line_id, tr.amount_role), '[]'::jsonb)
           FROM translation_result tr
           JOIN balance_snapshot_line bsl ON bsl.snapshot_line_id = tr.source_snapshot_line_id
          WHERE tr.calculation_run_id = cr.calculation_run_id)
        ELSE
        (SELECT COALESCE(jsonb_agg(jsonb_build_object(
              'snapshot_line_id', b.snapshot_line_id, 'posting_layer', b.posting_layer,
              'account_id', b.account_id, 'account_code', b.account_code,
              'account_name', b.account_name, 'debit', b.debit, 'credit', b.credit)
            ORDER BY b.snapshot_line_id), '[]'::jsonb)
           FROM balance_snapshot_line b WHERE b.calculation_run_id = cr.calculation_run_id)
        END))->0
      FROM (VALUES (sel.current_run_id, 'CURRENT'), (sel.prior_run_id, 'PRIOR')) AS src(run_id, role)
      JOIN calculation_run cr ON cr.calculation_run_id = src.run_id
      JOIN calculation_input_manifest m ON m.manifest_id = cr.manifest_id
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

-- ═══ 5　0043 的入口降為內部 helper ═════════════════════════════════
-- 唯一的改動是**尾端**加一次結構契約查證：放在 run 與橋接寫入之後，
-- 既有的批次／角色／重複判定順序完全不動（放在前面會讓那些負面測試
-- 以「Manifest 不完整」這個新理由被擋下，變成以錯誤理由通過）。
CREATE OR REPLACE FUNCTION fn_cash_flow_support_run_create(
  p_manifest uuid, p_source_batches uuid[], p_actor uuid, p_engine_version text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  m record; v_run uuid; v_batch uuid; v_locked int := 0; v_distinct int;
BEGIN
  IF p_engine_version IS NULL OR p_engine_version = '' THEN
    RAISE EXCEPTION 'CFS_RUN_ENGINE_VERSION_REQUIRED: 建立 run 必須指明引擎版本（重演要比對它）';
  END IF;

  SELECT manifest_id, tenant_id, engagement_id, period_revision_id, calculation_scope,
         frozen_set_content_hash
    INTO m FROM calculation_input_manifest WHERE manifest_id = p_manifest FOR UPDATE;
  IF m.manifest_id IS NULL THEN
    RAISE EXCEPTION 'CFS_RUN_MANIFEST_NOT_FOUND: Manifest 不存在（%）', p_manifest;
  END IF;
  IF m.calculation_scope <> 'CASH_FLOW_SUPPORT' THEN
    RAISE EXCEPTION 'CFS_RUN_SCOPE_MISMATCH: 本入口只建立 CASH_FLOW_SUPPORT run（該 Manifest 為 %）',
      m.calculation_scope;
  END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R2', m.tenant_id, m.engagement_id);

  IF EXISTS (SELECT 1 FROM calculation_run
              WHERE manifest_id = p_manifest AND replay_of_run_id IS NULL) THEN
    RAISE EXCEPTION 'CFS_RUN_MANIFEST_ALREADY_USED: 這份 Manifest 已有原始 run';
  END IF;

  IF p_source_batches IS NULL OR cardinality(p_source_batches) = 0 THEN
    RAISE EXCEPTION 'CFS_RUN_SOURCE_BATCH_REQUIRED: 現金流支持 run 必須至少凍結一筆來源批次（空集合等於來源歸屬未宣告）';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_source_batches) b WHERE b IS NULL) THEN
    RAISE EXCEPTION 'CFS_RUN_SOURCE_BATCH_REQUIRED: 來源批次清單含空值';
  END IF;
  SELECT count(DISTINCT b) INTO v_distinct FROM unnest(p_source_batches) b;
  IF v_distinct <> cardinality(p_source_batches) THEN
    RAISE EXCEPTION 'CFS_RUN_SOURCE_BATCH_DUPLICATE: 同一批次不得重複列入來源（重複＝同一份資料被算兩次）';
  END IF;

  FOR v_batch IN
    SELECT ib.import_batch_id FROM import_batch ib
     WHERE ib.import_batch_id = ANY(p_source_batches) AND ib.tenant_id = m.tenant_id
     ORDER BY ib.import_batch_id FOR UPDATE
  LOOP
    v_locked := v_locked + 1;
  END LOOP;
  IF v_locked <> v_distinct THEN
    RAISE EXCEPTION 'CFS_RUN_SOURCE_BATCH_NOT_FOUND: 來源批次不存在或不屬本租戶（鎖到 %／需要 %）',
      v_locked, v_distinct;
  END IF;

  v_run := gen_random_uuid();
  INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
          import_batch_id, manifest_id, run_type, status, request_key, request_content_hash,
          engine_version, created_by)
  VALUES (v_run, m.tenant_id, m.engagement_id, m.period_revision_id,
          NULL, p_manifest, 'PREVIEW', 'RUNNING', gen_random_uuid(),
          m.frozen_set_content_hash, p_engine_version, p_actor);

  FOREACH v_batch IN ARRAY p_source_batches LOOP
    INSERT INTO calculation_run_source_batch (calculation_run_id, import_batch_id, tenant_id)
    VALUES (v_run, v_batch, m.tenant_id);
  END LOOP;

  -- 完整性與結構契約：空 Manifest 的 run 因此對**任何呼叫者**都不可能成立
  PERFORM fn_cf_manifest_assert_contract(p_manifest);
  RETURN v_run;
END $$;

-- ═══ 6　權限 ═══════════════════════════════════════════════════════
REVOKE ALL ON FUNCTION fn_cash_flow_support_freeze_and_run(uuid, uuid, uuid, uuid, uuid[], uuid, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_cash_flow_support_freeze_and_run(uuid, uuid, uuid, uuid, uuid[], uuid, text)
  TO app_runtime;
REVOKE ALL ON FUNCTION fn_cf_manifest_assert_contract(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_cf_manifest_assert_contract(uuid) TO app_runtime;
-- 0043 的入口自本檔起是**內部 helper**：外部只能經凍結入口。
-- 0043 對 app_runtime 有明示 GRANT，只撤 PUBLIC 不會生效，必須逐一撤回。
REVOKE ALL ON FUNCTION fn_cash_flow_support_run_create(uuid, uuid[], uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION fn_cash_flow_support_run_create(uuid, uuid[], uuid, text) FROM app_runtime;
-- trigger 守衛由寫入者自己的身分執行（SECURITY INVOKER），對外不開放
REVOKE ALL ON FUNCTION fn_cfs_manifest_insert_guard() FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_cfs_manifest_entry_insert_guard() FROM PUBLIC;
