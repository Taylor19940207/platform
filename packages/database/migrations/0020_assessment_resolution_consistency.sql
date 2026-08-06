-- 0020 判定／Resolution 一致性收口（SLICE-M2-04 複核 P1）
-- 複核實證的三個洞：
--   1. VALIDATING 階段可直接 SQL 寫 MATCHED 而不建 Assessment（ACCEPTED|MATCHED|assessment=NULL）；
--   2. Resolution 的 acting_role／reason／detection_rule_version／resolved_by 歸因欄位可偽造；
--   3. 映射草稿沒有保存來源工作脈絡，B-00 一鍵回位連結為空。

-- ── A) ImportBatch：判定與 current 指標成對＋結果對應＋ACCEPTED 復驗 ──
CREATE OR REPLACE FUNCTION fn_import_batch_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  a record;
  legal boolean;
BEGIN
  IF OLD.status <> 'DRAFT' AND (
       NEW.file_sha256 IS DISTINCT FROM OLD.file_sha256
    OR NEW.file_name IS DISTINCT FROM OLD.file_name
    OR NEW.batch_version IS DISTINCT FROM OLD.batch_version
    OR NEW.declared_legal_entity_id IS DISTINCT FROM OLD.declared_legal_entity_id
    OR NEW.declared_period_revision_id IS DISTINCT FROM OLD.declared_period_revision_id
    OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
    OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
    OR NEW.uploaded_by IS DISTINCT FROM OLD.uploaded_by
    OR NEW.provided_by IS DISTINCT FROM OLD.provided_by) THEN
    RAISE EXCEPTION '批次來源身分欄位已凍結（上傳後不可改寫；更正走新批次）';
  END IF;

  -- 0020：current 指標只能與「NOT_CHECKED → 判定」同一次 UPDATE 成對寫入（VALIDATING）。
  -- 判定完成後指標即凍結——重評估屬 D-25-07 影響評估，未實作前一律拒絕。
  IF NEW.current_identity_assessment_id IS DISTINCT FROM OLD.current_identity_assessment_id THEN
    IF OLD.status <> 'VALIDATING' OR OLD.identity_status <> 'NOT_CHECKED'
       OR NEW.identity_status IS NOT DISTINCT FROM OLD.identity_status THEN
      RAISE EXCEPTION 'current_identity_assessment_id 只能於 VALIDATING 階段與身分判定成對寫入（判定後不可改寫）';
    END IF;
  END IF;

  IF NEW.identity_status IS DISTINCT FROM OLD.identity_status THEN
    IF OLD.identity_status = 'NOT_CHECKED'
       AND NEW.identity_status IN ('MATCHED','PENDING_CONFIRMATION','CONFLICT') THEN
      IF OLD.status <> 'VALIDATING' THEN
        RAISE EXCEPTION 'identity 判定只能於 VALIDATING 階段寫入（worker 唯一合法路徑）';
      END IF;
      -- 0020：判定必須與 current assessment 成對——沒有可稽核評估的判定不存在
      IF NEW.current_identity_assessment_id IS NULL
         OR NEW.current_identity_assessment_id IS NOT DISTINCT FROM OLD.current_identity_assessment_id THEN
        RAISE EXCEPTION '身分判定必須與 current assessment 指標同一次 UPDATE 成對寫入（0020）';
      END IF;
      SELECT tenant_id, import_batch_id, batch_version, match_result INTO a
        FROM source_identity_assessment
       WHERE assessment_id = NEW.current_identity_assessment_id;
      IF a.tenant_id IS NULL THEN
        RAISE EXCEPTION 'current assessment 不存在（%）', NEW.current_identity_assessment_id;
      END IF;
      IF a.tenant_id IS DISTINCT FROM NEW.tenant_id
         OR a.import_batch_id IS DISTINCT FROM NEW.import_batch_id
         OR a.batch_version IS DISTINCT FROM NEW.batch_version THEN
        RAISE EXCEPTION 'current assessment 歸屬違規：必須同租戶、同批次、同版本（INV-18）';
      END IF;
      IF NOT ((NEW.identity_status = 'MATCHED' AND a.match_result = 'MATCH')
           OR (NEW.identity_status = 'PENDING_CONFIRMATION' AND a.match_result = 'UNVERIFIABLE')
           OR (NEW.identity_status = 'CONFLICT' AND a.match_result = 'CONFLICT')) THEN
        RAISE EXCEPTION '身分判定與 assessment 結果不對應（% ↔ %）', NEW.identity_status, a.match_result;
      END IF;
    ELSIF OLD.identity_status = 'PENDING_CONFIRMATION'
       AND NEW.identity_status = 'MANUALLY_RESOLVED' THEN
      IF OLD.status <> 'VALIDATED' THEN
        RAISE EXCEPTION '人工確認只允許於 VALIDATED 批次';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM source_identity_resolution r
                      WHERE r.import_batch_id = OLD.import_batch_id
                        AND r.batch_version = OLD.batch_version
                        AND r.assessment_id = OLD.current_identity_assessment_id) THEN
        RAISE EXCEPTION 'MANUALLY_RESOLVED 必須先有對應 current assessment 的 Resolution（不可直接改寫）';
      END IF;
    ELSE
      RAISE EXCEPTION '非法 identity_status 遷移 % → %（已判定不得改寫；重評估屬 D-25-07 影響評估，未實作）',
        OLD.identity_status, NEW.identity_status;
    END IF;
  END IF;

  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;
  legal := CASE OLD.status
    WHEN 'DRAFT'       THEN NEW.status = 'UPLOADED'
    WHEN 'UPLOADED'    THEN NEW.status = 'VALIDATING'
    WHEN 'VALIDATING'  THEN NEW.status IN ('QUARANTINED','VALIDATED')
    WHEN 'VALIDATED'   THEN NEW.status IN ('ACCEPTED','QUARANTINED')
    WHEN 'ACCEPTED'    THEN NEW.status = 'SUPERSEDED'
    ELSE false
  END;
  IF NOT legal THEN
    RAISE EXCEPTION '非法狀態遷移 % → %（ImportBatch %）',
      OLD.status, NEW.status, OLD.import_batch_id;
  END IF;

  IF NEW.status = 'ACCEPTED' THEN
    IF OLD.status <> 'VALIDATED'
       OR NEW.identity_status NOT IN ('MATCHED','MANUALLY_RESOLVED')
       OR NOT NEW.hash_verified THEN
      RAISE EXCEPTION 'G-01/INV-28：不滿足接受判定式（status=%→%, identity_status=%, hash_verified=%）',
        OLD.status, NEW.status, NEW.identity_status, NEW.hash_verified;
    END IF;
    -- 0020 復驗（縱深防禦）：接受瞬間 current assessment 必須存在且與 identity_status 對應
    SELECT tenant_id, import_batch_id, batch_version, match_result INTO a
      FROM source_identity_assessment
     WHERE assessment_id = NEW.current_identity_assessment_id;
    IF NEW.current_identity_assessment_id IS NULL OR a.tenant_id IS NULL
       OR a.tenant_id IS DISTINCT FROM NEW.tenant_id
       OR a.import_batch_id IS DISTINCT FROM NEW.import_batch_id
       OR a.batch_version IS DISTINCT FROM NEW.batch_version
       OR NOT ((NEW.identity_status = 'MATCHED' AND a.match_result = 'MATCH')
            OR (NEW.identity_status = 'MANUALLY_RESOLVED' AND a.match_result = 'UNVERIFIABLE')) THEN
      RAISE EXCEPTION 'G-01 復驗失敗：ACCEPTED 必須存在對應的 current assessment（0020）';
    END IF;
  END IF;

  IF NEW.status = 'SUPERSEDED' AND NEW.superseded_by_id IS NULL THEN
    RAISE EXCEPTION 'INV-08：SUPERSEDED 必須指向替代批次';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- ── B) Resolution：歸因欄位不可偽造 ──
CREATE OR REPLACE FUNCTION fn_sod07_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  b record; a record; v_ra uuid; v_user record;
BEGIN
  SELECT tenant_id, engagement_id, status, identity_status, batch_version,
         uploaded_by, current_identity_assessment_id
    INTO b FROM import_batch WHERE import_batch_id = NEW.import_batch_id
    FOR UPDATE;
  IF b.tenant_id IS NULL THEN
    RAISE EXCEPTION '引用的匯入批次不存在（%）', NEW.import_batch_id;
  END IF;
  SELECT tenant_id, import_batch_id, batch_version, match_result, detection_rule_version
    INTO a FROM source_identity_assessment WHERE assessment_id = NEW.assessment_id;
  IF a.tenant_id IS NULL THEN
    RAISE EXCEPTION '引用的 assessment 不存在（%）', NEW.assessment_id;
  END IF;
  IF a.tenant_id IS DISTINCT FROM NEW.tenant_id
     OR b.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：Resolution／assessment／批次不同租戶（INV-18）';
  END IF;
  IF a.import_batch_id IS DISTINCT FROM NEW.import_batch_id THEN
    RAISE EXCEPTION '歸屬違規：assessment 屬其他批次';
  END IF;
  IF NEW.batch_version IS DISTINCT FROM a.batch_version
     OR NEW.batch_version IS DISTINCT FROM b.batch_version THEN
    RAISE EXCEPTION 'batch_version 三方不一致或非批次目前版本（Resolution=%、assessment=%、批次=%）',
      NEW.batch_version, a.batch_version, b.batch_version;
  END IF;
  IF a.match_result <> 'UNVERIFIABLE' THEN
    RAISE EXCEPTION '只有 UNVERIFIABLE 評估可人工確認（此筆為 %）', a.match_result;
  END IF;
  IF b.current_identity_assessment_id IS DISTINCT FROM NEW.assessment_id THEN
    RAISE EXCEPTION '只能確認 current assessment——重新解析後的舊評估不可沿用（CTX-e）';
  END IF;
  IF b.status <> 'VALIDATED' OR b.identity_status <> 'PENDING_CONFIRMATION' THEN
    RAISE EXCEPTION '批次狀態不允許確認（需 VALIDATED＋PENDING_CONFIRMATION；目前 %／%）',
      b.status, b.identity_status;
  END IF;
  IF b.uploaded_by IS NOT NULL AND b.uploaded_by = NEW.resolved_by THEN
    RAISE EXCEPTION 'SOD-07：上傳者（%）不得確認自己上傳的批次，與當下角色無關', NEW.resolved_by;
  END IF;
  -- 0020：歸因欄位不可偽造——acting_role、理由、規則版本、確認者本人
  IF NEW.acting_role IS DISTINCT FROM 'R2' THEN
    RAISE EXCEPTION 'Resolution 的 acting_role 必須為 R2（資料接受角色；此筆 %）', NEW.acting_role;
  END IF;
  IF btrim(coalesce(NEW.reason, '')) = '' THEN
    RAISE EXCEPTION '確認理由去空白後不得為空（不可變紀錄必須有實質理由）';
  END IF;
  IF NEW.detection_rule_version IS DISTINCT FROM a.detection_rule_version THEN
    RAISE EXCEPTION 'Resolution 的規則版本必須等於所選 assessment 的規則版本（% ≠ %）',
      NEW.detection_rule_version, a.detection_rule_version;
  END IF;
  -- 確認者必須是同租戶且啟用中的使用者；鎖列避免與停用交錯
  SELECT user_id, is_active INTO v_user FROM app_user
   WHERE user_id = NEW.resolved_by AND tenant_id = b.tenant_id
   FOR UPDATE;
  IF v_user.user_id IS NULL OR NOT v_user.is_active THEN
    RAISE EXCEPTION 'resolved_by 必須是同租戶且啟用中的使用者（%）', NEW.resolved_by;
  END IF;
  SELECT role_assignment_id INTO v_ra FROM role_assignment
   WHERE user_id = NEW.resolved_by AND tenant_id = b.tenant_id
     AND engagement_id = b.engagement_id AND role = 'R2' AND revoked_at IS NULL
   LIMIT 1 FOR UPDATE;
  IF v_ra IS NULL THEN
    RAISE EXCEPTION 'resolved_by 必須對該案件具有效 R2 指派（資料接受角色）';
  END IF;
  RETURN NEW;
END $$;

-- ── C) 映射草稿：保存不可變的來源工作脈絡（B-00 一鍵回位） ──
ALTER TABLE mapping_rule ADD COLUMN source_import_batch_id uuid REFERENCES import_batch;

CREATE FUNCTION fn_mapping_source_batch_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.source_import_batch_id IS DISTINCT FROM OLD.source_import_batch_id THEN
      RAISE EXCEPTION '映射草稿的來源批次脈絡不可變更';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.source_import_batch_id IS NOT NULL THEN
    PERFORM 1 FROM import_batch b
     WHERE b.import_batch_id = NEW.source_import_batch_id
       AND b.tenant_id = NEW.tenant_id AND b.engagement_id = NEW.engagement_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION '映射來源批次歸屬違規：必須同租戶且同案件（INV-18／§24.1A）';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_mapping_source_batch
  BEFORE INSERT OR UPDATE ON mapping_rule
  FOR EACH ROW EXECUTE FUNCTION fn_mapping_source_batch_guard();
