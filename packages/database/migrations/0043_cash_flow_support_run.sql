-- 0043 現金流支持資料：CASH_FLOW_SUPPORT run 的建立入口（SLICE-M3-04 第二段 2b 第一刀）
--
-- 0040 讓 `calculation_run.import_batch_id` 對 CASH_FLOW_SUPPORT 可空、並新增
-- `calculation_run_source_batch` 橋接，但**沒有任何入口**：app_runtime 對橋接只有
-- SELECT，對 `calculation_run` 卻有 INSERT（NO_FX 需要）。結果是應用層可以建立一個
-- 「scope 是現金流、卻一筆來源批次都沒有」的 run——那正是 0040 要防的「來源歸屬說謊」，
-- 只是換成用空集合說謊。
--
-- 本檔只做一件事：**把現金流支持 run 的建立收斂成單一 system-only 入口**，
-- 並在同一交易內凍結來源批次。
--
-- ## 契約（本刀的完成範圍）
--
-- | 項目 | 決定 |
-- |---|---|
-- | 入口 | `fn_cash_flow_support_run_create(manifest, batches[], actor, engine_version)` |
-- | 角色 | 案件層 **R2**——比照 `fn_fx_translation_run`（0034）：發起計算是編製者的動作 |
-- | Manifest | **既有的** CASH_FLOW_SUPPORT manifest 由參數帶入；本檔不凍結、不產生條目 |
-- | 單一批次欄位 | `import_batch_id` 必須為 NULL（0040 已擋，本檔不重複實作） |
-- | 來源批次 | 至少一筆、不得重複、不得含空值；每筆的 ACCEPTED／期間／案件由 **0040 的 trigger** 判定 |
-- | 鎖 | 依 `import_batch_id` 遞增順序 `FOR UPDATE`；併發下狀態變更不得穿過建立交易 |
-- | 狀態 | 建立即 `RUNNING`；不寫結果、不寫完整度結論 |
--
-- ## 本檔明確不做
--
-- * Manifest 凍結、條目、`fn_manifest_verify` 與結果雜湊——2b 第二項。
-- * `CashFlowSupportLine`、`DATA_PRESENT` 衍生、粒度判定、K1～K4、replay——2b 後續。
-- * 畫面與期間遷移解鎖。
-- * **不回改 0039～0042**：0040 的橋接 trigger 是每筆批次檢查的唯一實作，
--   本檔只負責「至少一筆」「不重複」「先鎖再寫」。
--
-- ## 兩個已知且刻意保留的邊界（2b 後續關閉，不在本刀範圍）
--
-- 1. **CASH_FLOW_SUPPORT manifest 仍可由 app_runtime 直接 INSERT**（0012 的既有授權）。
--    凍結與驗證是 2b 第二項的內容；在它落地前，manifest 的內容還不是權威的。
--    本檔只保證：run 一旦建立，來源批次就與它同生共死。
-- 2. **「至少一筆橋接」在函式層強制，不做 DEFERRABLE 約束 trigger。**
--    理由是實測的：0040 有一條既有斷言單獨建立無橋接的 run，加約束會讓它在 commit 轉紅，
--    而既有斷言不得修改。真正的防線改由**權限邊界**擔任——app_runtime 完全不能插入
--    CASH_FLOW_SUPPORT run（見 §1），owner 直插屬於既有的邊界外（M3-02：不可變 trigger
--    擋不住 owner 操作）。「無橋接的 run 不得寫出結果」留給 2b 的結果寫入路徑。

-- ═══ 1　system-only：現金流支持 run 只能經函式建立 ═════════════════
-- app_runtime 對 `calculation_run` 的 INSERT 不能收回（NO_FX 要用），因此用
-- **執行身分**當邊界：SECURITY DEFINER 函式以 owner 身分寫入，直連的 app_runtime 不是
-- owner。GUC 標記在這裡沒有用——任何連線都能 `set_config`（M3-02 §權限是邊界）。
--
-- 本函式維持 **SECURITY INVOKER**：改成 DEFINER 的話 `current_user` 會變成 owner，
-- 這個檢查對誰都會通過，等於沒寫。
CREATE OR REPLACE FUNCTION fn_calculation_run_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_mani uuid; v_tenant uuid;
  m_tenant uuid; m_eng uuid; m_pr uuid; m_scope text;
  b_tenant uuid; b_eng uuid; b_pr uuid;
  p_eng uuid; p_tenant uuid; u_tenant uuid;
  v_owner name;
BEGIN
  IF NEW.status <> 'RUNNING' THEN
    RAISE EXCEPTION 'Run 建立時必須為 RUNNING（結果狀態由執行交易寫入）';
  END IF;
  IF NEW.result_content_hash IS NOT NULL OR NEW.failure_reason_code IS NOT NULL
     OR NEW.failure_reason IS NOT NULL OR NEW.completed_at IS NOT NULL
     OR NEW.failed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Run 建立時不得預填結果或終態欄位（終態欄位互斥）';
  END IF;
  SELECT tenant_id, engagement_id, period_revision_id, calculation_scope
    INTO m_tenant, m_eng, m_pr, m_scope
    FROM calculation_input_manifest WHERE manifest_id = NEW.manifest_id FOR UPDATE;
  IF m_tenant IS DISTINCT FROM NEW.tenant_id OR m_eng IS DISTINCT FROM NEW.engagement_id
     OR m_pr IS DISTINCT FROM NEW.period_revision_id THEN
    RAISE EXCEPTION '歸屬違規：Run 與 Manifest 的租戶／案件／期間不一致（§24.1A）';
  END IF;
  SELECT rp.engagement_id, pr.tenant_id INTO p_eng, p_tenant
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = NEW.period_revision_id;
  IF p_eng IS DISTINCT FROM NEW.engagement_id OR p_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：Run 的期間不屬於本案件（§24.1A）';
  END IF;

  -- **只對 CASH_FLOW_SUPPORT 開新分支**：單一批次欄位可空，來源以 bridge 凍結。
  -- NO_FX／FX_TRANSLATION 維持原本的單一批次要求，不得放寬。
  IF m_scope = 'CASH_FLOW_SUPPORT' THEN
    SELECT pg_catalog.pg_get_userbyid(c.relowner) INTO v_owner
      FROM pg_catalog.pg_class c WHERE c.oid = TG_RELID;
    IF current_user <> v_owner THEN
      RAISE EXCEPTION 'CFS_RUN_SYSTEM_ONLY: 現金流支持 run 只能經 fn_cash_flow_support_run_create 建立（來源批次必須在同一交易內凍結）';
    END IF;
    IF NEW.import_batch_id IS NOT NULL THEN
      RAISE EXCEPTION 'CFS_RUN_SINGLE_BATCH_NOT_ALLOWED: 現金流支持 run 的來源批次以 calculation_run_source_batch 凍結，不得填單一批次';
    END IF;
  ELSE
    IF NEW.import_batch_id IS NULL THEN
      RAISE EXCEPTION '歸屬違規：Run 必須指明來源批次（§24.1A）';
    END IF;
    SELECT tenant_id, engagement_id, declared_period_revision_id INTO b_tenant, b_eng, b_pr
      FROM import_batch WHERE import_batch_id = NEW.import_batch_id;
    IF b_tenant IS DISTINCT FROM NEW.tenant_id OR b_eng IS DISTINCT FROM NEW.engagement_id THEN
      RAISE EXCEPTION '歸屬違規：Run 與來源批次的租戶／案件不一致（§24.1A）';
    END IF;
    IF b_pr IS DISTINCT FROM NEW.period_revision_id THEN
      RAISE EXCEPTION '歸屬違規：Run 期間與批次宣告期間不一致（§24.1A）';
    END IF;
  END IF;

  SELECT tenant_id INTO u_tenant FROM app_user WHERE user_id = NEW.created_by;
  IF u_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：建立者不屬於本租戶（INV-18）';
  END IF;
  IF NEW.replay_of_run_id IS NOT NULL THEN
    SELECT manifest_id, tenant_id INTO v_mani, v_tenant
      FROM calculation_run WHERE calculation_run_id = NEW.replay_of_run_id;
    IF v_mani IS NULL THEN
      RAISE EXCEPTION 'replay 引用的原 run 不存在（%）', NEW.replay_of_run_id;
    END IF;
    IF v_mani <> NEW.manifest_id OR v_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'replay 必須引用同一份 Manifest 且同租戶';
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ═══ 2　建立入口 ═══════════════════════════════════════════════════
-- 順序是有意的：先確定 Manifest 與角色（誰、對哪個案件），再確定來源清單本身合法
-- （非空、不重複），最後**鎖住批次列**才寫入。鎖在寫入之前、且在同一交易內，
-- 「檢查時 ACCEPTED、提交時已 SUPERSEDED」因此不可能發生（0021 的同一手法）。
--
-- 每一筆批次的 ACCEPTED／期間／案件由 0040 的 trigger 判定，本函式不重寫一份：
-- 同一個檢查有兩份實作，遲早會有一份先鬆掉。
CREATE FUNCTION fn_cash_flow_support_run_create(
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
  -- 租戶脈絡 ＋ 案件層 R2（作用域嚴格相等；租戶層 R2 不得隱式取得本案件權限）
  PERFORM fn_cf_assert_actor(p_actor, 'R2', m.tenant_id, m.engagement_id);

  -- 一份 Manifest 恰有一個原始 run（calc_run_manifest_origin_uq 是最後防線，
  -- 這裡先給穩定代碼；replay 屬 2b 後續，不由本入口建立）
  IF EXISTS (SELECT 1 FROM calculation_run
              WHERE manifest_id = p_manifest AND replay_of_run_id IS NULL) THEN
    RAISE EXCEPTION 'CFS_RUN_MANIFEST_ALREADY_USED: 這份 Manifest 已有原始 run';
  END IF;

  -- ── 來源清單本身 ──
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

  -- ── 鎖住父列 ──
  -- 固定遞增順序：兩個併發建立若共用批次，鎖的取得順序一致，不會互鎖。
  -- 這裡的 tenant 條件是**鎖的範圍**，不是父鏈判定：SECURITY DEFINER 以 owner 執行，
  -- owner 是 superuser 時 RLS 不生效，跨租戶批次會被查得到（0034 的同一個教訓）。
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

  -- ── 寫入：run 與橋接同一交易，任何一筆批次不合法就整次回滾 ──
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

  RETURN v_run;
END $$;

-- ═══ 3　權限 ═══════════════════════════════════════════════════════
REVOKE ALL ON FUNCTION fn_cash_flow_support_run_create(uuid, uuid[], uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_cash_flow_support_run_create(uuid, uuid[], uuid, text) TO app_runtime;
