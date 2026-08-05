-- 0016 02C 收口（逐行審查四項 P1 之 ①④；②③ 屬 worker／domain 層）
-- ① 來源集合封存：來源列不可修改（0015 已收），但批次驗證完成後仍可「新增」
--    source_document／data_coverage／source_dataset——同 run 再產包會得到不同內容，
--    破壞「同 run＋cutoff＋render → 同 hash」。封存點＝批次離開
--    DRAFT／UPLOADED／VALIDATING（VALIDATING 為交易內狀態，worker 寫入不受影響）。
-- ④ 契約 A 守衛補漏欄位；READY 遷移於 DB 驗證固定章節集合並重算 aggregate hash——
--    直接 SQL 不可能建立「不完整但看似 READY」的包。

-- ── ① 來源集合封存（鎖批次列；0014 的並發紀律同式） ──
CREATE OR REPLACE FUNCTION fn_source_batch_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  b_tenant uuid; b_status import_batch_status;
BEGIN
  SELECT tenant_id, status INTO b_tenant, b_status
    FROM import_batch WHERE import_batch_id = NEW.import_batch_id
    FOR UPDATE;
  IF b_tenant IS NULL THEN
    RAISE EXCEPTION '引用的匯入批次不存在（%）', NEW.import_batch_id;
  END IF;
  IF b_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：來源實體與批次不同租戶（INV-18）';
  END IF;
  IF b_status NOT IN ('DRAFT','UPLOADED','VALIDATING') THEN
    RAISE EXCEPTION '來源集合已封存（批次 %）：驗證完成後不得追加來源實體——更正走新批次', b_status;
  END IF;
  RETURN NEW;
END $$;

-- ── ④ 契約 A 守衛補全＋READY 的索引／aggregate 驗證 ──
CREATE OR REPLACE FUNCTION fn_evidence_package_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_sections text[];
  v_expected text[] := ARRAY['adjustment','attachments','calculation','control_exceptions',
                             'events','mapping','process_level','rule_versions','source','traceability'];
  v_agg text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'EvidencePackage 不可刪除（原包永久保留，不入 SUPERSEDED 鏈）';
  END IF;
  IF NEW.calculation_run_id IS DISTINCT FROM OLD.calculation_run_id
  OR NEW.regenerated_from_id IS DISTINCT FROM OLD.regenerated_from_id
  OR NEW.request_key IS DISTINCT FROM OLD.request_key
  OR NEW.request_content_hash IS DISTINCT FROM OLD.request_content_hash
  OR NEW.audit_cutoff_event_id IS DISTINCT FROM OLD.audit_cutoff_event_id
  OR NEW.render_version IS DISTINCT FROM OLD.render_version
  OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
  OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
  OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
    RAISE EXCEPTION 'Package 身分欄位建立後不可變更';
  END IF;
  IF OLD.status IN ('READY','FAILED') THEN
    RAISE EXCEPTION 'Package 終態（%）不可修改——重產＝新 package（regenerated_from_id）', OLD.status;
  END IF;
  IF NEW.status = 'GENERATING' THEN
    IF NEW.package_content_hash IS NOT NULL OR NEW.artifact_object_key IS NOT NULL
       OR NEW.artifact_sha256 IS NOT NULL OR NEW.artifact_mime_type IS NOT NULL
       OR NEW.artifact_byte_size IS NOT NULL OR NEW.failure_reason_code IS NOT NULL
       OR NEW.failure_reason IS NOT NULL OR NEW.completed_at IS NOT NULL
       OR NEW.failed_at IS NOT NULL THEN
      RAISE EXCEPTION 'GENERATING 內容欄位必須全空（契約 A 互斥；重試期間維持 GENERATING）';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.status = 'READY' THEN
    IF COALESCE(NEW.package_content_hash,'') = '' OR COALESCE(NEW.artifact_object_key,'') = ''
       OR COALESCE(NEW.artifact_sha256,'') = '' OR COALESCE(NEW.artifact_mime_type,'') = ''
       OR NEW.artifact_byte_size IS NULL THEN
      RAISE EXCEPTION 'READY 必須齊備 artifact 與內容 hash（契約 A）';
    END IF;
    IF NEW.failure_reason_code IS NOT NULL OR NEW.failure_reason IS NOT NULL
       OR NEW.failed_at IS NOT NULL THEN
      RAISE EXCEPTION '終態欄位互斥：READY 不得帶失敗欄位';
    END IF;
    -- 固定章節集合：缺節或多節都不是合法的 READY 包
    SELECT array_agg(section ORDER BY section COLLATE "C") INTO v_sections
      FROM evidence_package_index WHERE package_id = NEW.package_id;
    IF v_sections IS DISTINCT FROM v_expected THEN
      RAISE EXCEPTION 'READY 需要固定章節集合（10 節）；實際＝%', COALESCE(v_sections,'{}');
    END IF;
    -- aggregate hash 於 DB 重算：package_content_hash 必須等於索引逐節 hash 的聚合
    SELECT encode(sha256(convert_to(
             string_agg(section || '|' || content_hash, E'\n' ORDER BY section COLLATE "C"),
           'UTF8')),'hex') INTO v_agg
      FROM evidence_package_index WHERE package_id = NEW.package_id;
    IF v_agg IS DISTINCT FROM NEW.package_content_hash THEN
      RAISE EXCEPTION 'package_content_hash 與索引 aggregate 不符（宣稱 % ≠ 重算 %）',
        NEW.package_content_hash, v_agg;
    END IF;
    NEW.completed_at := COALESCE(NEW.completed_at, now());
    RETURN NEW;
  END IF;
  IF NEW.status = 'FAILED' THEN
    IF COALESCE(NEW.failure_reason_code,'') = '' OR COALESCE(NEW.failure_reason,'') = '' THEN
      RAISE EXCEPTION 'FAILED 必須帶機器代碼與客戶可理解原因';
    END IF;
    IF NEW.package_content_hash IS NOT NULL OR NEW.artifact_object_key IS NOT NULL
       OR NEW.artifact_sha256 IS NOT NULL OR NEW.artifact_mime_type IS NOT NULL
       OR NEW.artifact_byte_size IS NOT NULL OR NEW.completed_at IS NOT NULL THEN
      RAISE EXCEPTION '終態欄位互斥：FAILED 不得帶 artifact（契約 A）';
    END IF;
    NEW.failed_at := COALESCE(NEW.failed_at, now());
    RETURN NEW;
  END IF;
  RAISE EXCEPTION '非法 Package 狀態遷移 % → %', OLD.status, NEW.status;
END $$;
