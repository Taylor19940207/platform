-- 0019 身分確認防繞過（SLICE-M2-04；契約：docs/slices/SLICE-M2-04_B00待辦與身分確認.md 決策 9）
-- 現有 trg_sod07 只驗 uploaded_by ≠ resolved_by——歸屬、版本、current 指標、角色與
-- 狀態皆可被直接 SQL 繞過；0018 的同狀態提前返回也讓 identity_status 可被直接改寫。

-- ── current assessment 指標：「仍有效的 assessment」的權威判定（INV-28 精神） ──
ALTER TABLE import_batch
  ADD COLUMN current_identity_assessment_id uuid REFERENCES source_identity_assessment;

-- ── Resolution INSERT 守衛（取代舊 fn_sod07_guard 內容；觸發器名不變） ──
CREATE OR REPLACE FUNCTION fn_sod07_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  b record; a record; v_ra uuid;
BEGIN
  -- 鎖批次列：資格檢查到提交之間，批次狀態變更不得交錯（並發要求）
  SELECT tenant_id, engagement_id, status, identity_status, batch_version,
         uploaded_by, current_identity_assessment_id
    INTO b FROM import_batch WHERE import_batch_id = NEW.import_batch_id
    FOR UPDATE;
  IF b.tenant_id IS NULL THEN
    RAISE EXCEPTION '引用的匯入批次不存在（%）', NEW.import_batch_id;
  END IF;
  SELECT tenant_id, import_batch_id, batch_version, match_result
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
  -- 允許確認狀態＝正向白名單
  IF b.status <> 'VALIDATED' OR b.identity_status <> 'PENDING_CONFIRMATION' THEN
    RAISE EXCEPTION '批次狀態不允許確認（需 VALIDATED＋PENDING_CONFIRMATION；目前 %／%）',
      b.status, b.identity_status;
  END IF;
  -- SOD-07：判定對象是自然人，角色切換無效
  IF b.uploaded_by IS NOT NULL AND b.uploaded_by = NEW.resolved_by THEN
    RAISE EXCEPTION 'SOD-07：上傳者（%）不得確認自己上傳的批次，與當下角色無關', NEW.resolved_by;
  END IF;
  -- 資料接受角色（本刀＝R2）＋鎖住當下使用的指派列：撤銷不得與提交交錯
  SELECT role_assignment_id INTO v_ra FROM role_assignment
   WHERE user_id = NEW.resolved_by AND tenant_id = b.tenant_id
     AND engagement_id = b.engagement_id AND role = 'R2' AND revoked_at IS NULL
   LIMIT 1 FOR UPDATE;
  IF v_ra IS NULL THEN
    RAISE EXCEPTION 'resolved_by 必須對該案件具有效 R2 指派（資料接受角色）';
  END IF;
  RETURN NEW;
END $$;

-- ── ImportBatch：identity 遷移白名單＋current 指標階段限制 ──
CREATE OR REPLACE FUNCTION fn_import_batch_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
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

  -- current 指標只能於 VALIDATING 階段更新（worker 與 Assessment 同交易寫入）
  IF NEW.current_identity_assessment_id IS DISTINCT FROM OLD.current_identity_assessment_id
     AND OLD.status <> 'VALIDATING' THEN
    RAISE EXCEPTION 'current_identity_assessment_id 只能於 VALIDATING 階段更新';
  END IF;

  -- identity 遷移白名單（0019）：關掉同狀態提前返回留下的直接改寫後門
  IF NEW.identity_status IS DISTINCT FROM OLD.identity_status THEN
    IF OLD.identity_status = 'NOT_CHECKED'
       AND NEW.identity_status IN ('MATCHED','PENDING_CONFIRMATION','CONFLICT') THEN
      IF OLD.status <> 'VALIDATING' THEN
        RAISE EXCEPTION 'identity 判定只能於 VALIDATING 階段寫入（worker 唯一合法路徑）';
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
  END IF;

  IF NEW.status = 'SUPERSEDED' AND NEW.superseded_by_id IS NULL THEN
    RAISE EXCEPTION 'INV-08：SUPERSEDED 必須指向替代批次';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;
