-- 0018 02C final hardening 第三輪（P1-③ DB 側）
-- fn_import_batch_guard 的同狀態提前返回讓 ACCEPTED 批次的 file_sha256／batch_version
-- 等來源身分欄位仍可被直接 SQL 改寫——同一 Run 重產即漂移。
-- 修正：批次離開 DRAFT 後，來源身分欄位凍結（superseded_by_id 與處理欄位不在此列）。

CREATE OR REPLACE FUNCTION fn_import_batch_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  legal boolean;
BEGIN
  -- 來源身分凍結（0018）：上傳後不得改寫「這是哪份檔案、屬於誰、第幾版」
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

  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;
  legal := CASE OLD.status
    WHEN 'DRAFT'       THEN NEW.status = 'UPLOADED'
    WHEN 'UPLOADED'    THEN NEW.status = 'VALIDATING'
    WHEN 'VALIDATING'  THEN NEW.status IN ('QUARANTINED','VALIDATED')
    WHEN 'VALIDATED'   THEN NEW.status IN ('ACCEPTED','QUARANTINED')
    WHEN 'ACCEPTED'    THEN NEW.status = 'SUPERSEDED'
    ELSE false                                   -- QUARANTINED／SUPERSEDED 為終態
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
