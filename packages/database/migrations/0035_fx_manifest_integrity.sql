-- 0035 折算：使用 Manifest 前先驗 Manifest 自身（SLICE-M3-02 關閉前最後一項）
--
-- 0034 讓折算只讀凍結 payload，但**沒有驗證那份 payload 本身是否還是原來的**。
-- 一般操作有不可變 trigger 擋著；契約要防的是另一類：資料修復、migration、
-- 或 owner 停用 trigger 後的內容漂移。那時 replay 會拿被竄改的 payload 計算，
-- 若結果碰巧相同，甚至會宣稱重演成功——而重演的全部意義就是回答
-- 「這份證據還是不是當初那一份」。
--
-- 驗證與生成必須共用同一套 canonical 規則，否則兩邊日後會分岔；
-- 因此原始 run 也在 materialize 之前呼叫同一支函式。

CREATE FUNCTION fn_fx_verify_manifest(p_manifest uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  m record; e record; v_canon text; v_hash text; v_set text; v_n int;
BEGIN
  SELECT * INTO m FROM calculation_input_manifest WHERE manifest_id = p_manifest;
  IF m.manifest_id IS NULL THEN
    RAISE EXCEPTION 'REPLAY_MANIFEST_INTEGRITY_FAILED: 凍結集合不存在（%）', p_manifest;
  END IF;
  IF m.hash_algorithm <> 'sha256' THEN
    RAISE EXCEPTION 'REPLAY_MANIFEST_INTEGRITY_FAILED: 雜湊演算法為 %，本引擎只支援 sha256', m.hash_algorithm;
  END IF;
  IF m.canonicalization_version <> 'sqlcanon-2' THEN
    RAISE EXCEPTION 'REPLAY_MANIFEST_INTEGRITY_FAILED: canonical 版本 % 非本引擎支援的版本', m.canonicalization_version;
  END IF;

  SELECT count(*) INTO v_n FROM calculation_manifest_entry WHERE manifest_id = p_manifest;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'REPLAY_MANIFEST_INTEGRITY_FAILED: 凍結集合沒有任何條目';
  END IF;

  -- 逐條由 (object_type, object_id, payload) 重算 canonical 與雜湊。
  -- 三者任一被單獨改過都會露餡：改 payload 則 canonical 與 hash 對不上，
  -- 改 canonical 或 hash 則與 payload 重算的結果對不上。
  FOR e IN SELECT * FROM calculation_manifest_entry WHERE manifest_id = p_manifest
  LOOP
    v_canon := e.object_type || ':' || COALESCE(e.object_id::text, '-') || ':' ||
               jsonb_pretty(e.payload);
    IF v_canon IS DISTINCT FROM e.content_canonical THEN
      RAISE EXCEPTION 'REPLAY_MANIFEST_INTEGRITY_FAILED: 條目 %（%）的 canonical 與 payload 不符',
        e.object_type, COALESCE(e.object_id::text, '-');
    END IF;
    IF fn_fx_sha(v_canon) IS DISTINCT FROM e.content_hash THEN
      RAISE EXCEPTION 'REPLAY_MANIFEST_INTEGRITY_FAILED: 條目 %（%）的內容雜湊不符',
        e.object_type, COALESCE(e.object_id::text, '-');
    END IF;
  END LOOP;

  -- 整份凍結集合的雜湊，排序規則與生成端相同
  SELECT fn_fx_sha(string_agg(content_hash, '|'
           ORDER BY object_type, COALESCE(object_id::text, ''), content_hash))
    INTO v_set FROM calculation_manifest_entry WHERE manifest_id = p_manifest;
  IF v_set IS DISTINCT FROM m.frozen_set_content_hash THEN
    RAISE EXCEPTION 'REPLAY_MANIFEST_INTEGRITY_FAILED: 凍結集合雜湊不符（重算 % ≠ 記載 %）',
      v_set, m.frozen_set_content_hash;
  END IF;
END $$;

-- 物化前先驗：生成端與驗證端共用同一支，canonical 規則不會分岔。
-- 原本的物化邏輯原封不動改名，外層只多做一次驗證。
ALTER FUNCTION fn_fx_materialize(uuid) RENAME TO fn_fx_materialize_verified;

CREATE FUNCTION fn_fx_materialize(p_run uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  PERFORM fn_fx_verify_manifest((SELECT manifest_id FROM calculation_run
                                  WHERE calculation_run_id = p_run));
  RETURN fn_fx_materialize_verified(p_run);
END $$;

-- Replay：完整性失敗必須讓 replay run 進 FAILED，且**在物化之前**——
-- 不建立任何 SnapshotLine／TranslationResult／Component／CTA，原 run 不變。
CREATE OR REPLACE FUNCTION fn_fx_translation_replay(
  p_original_run uuid, p_actor uuid, p_engine_version text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE o record; v_run uuid; v_hash text; v_err text;
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

  v_run := gen_random_uuid();
  INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
          import_batch_id, manifest_id, run_type, status, replay_of_run_id, request_key,
          request_content_hash, engine_version, created_by)
  VALUES (v_run, o.tenant_id, o.engagement_id, o.period_revision_id, o.import_batch_id,
          o.manifest_id, 'PREVIEW', 'RUNNING', p_original_run, gen_random_uuid(),
          o.request_content_hash, p_engine_version, p_actor);

  -- 先驗凍結集合本身。失敗時**還沒有任何產出**，因此 FAILED 的 replay run
  -- 是乾淨的：只有狀態與原因，沒有半套快照。
  BEGIN
    PERFORM fn_fx_verify_manifest(o.manifest_id);
  EXCEPTION WHEN raise_exception THEN
    v_err := SQLERRM;
    IF v_err NOT LIKE 'REPLAY_MANIFEST_INTEGRITY_FAILED%' THEN RAISE; END IF;
    UPDATE calculation_run SET status = 'FAILED',
           failure_reason_code = 'REPLAY_MANIFEST_INTEGRITY_FAILED',
           failure_reason = v_err, failed_at = now()
     WHERE calculation_run_id = v_run;
    RETURN v_run;
  END;

  v_hash := fn_fx_materialize_verified(v_run);
  IF v_hash IS DISTINCT FROM o.result_content_hash THEN
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

REVOKE ALL ON FUNCTION fn_fx_verify_manifest(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_fx_verify_manifest(uuid) TO app_runtime;
REVOKE ALL ON FUNCTION fn_fx_materialize(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_fx_materialize_verified(uuid) FROM PUBLIC;
