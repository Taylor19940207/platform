-- 0005 映射版本化（SLICE-M2-01；設計書 §26.8 MappingRule／MappingVersion 最小版）
-- 三項控制做成 DB 最後防線（應用層先判定並記錄 ControlViolationAttempt）：
--   1. 歸屬完整性（§24.1A）：目標科目必須屬於同一 Tenant×案件的科目表——
--      有權者也不得把映射指向別的客戶。
--   2. 版本不可覆寫：已批准版本不可 UPDATE／DELETE；變更＝插入新 version_no。
--   3. 批准職責分離（§24.6 權限矩陣；SOD-01 精神的實例級）：批准人 ≠ 建立者，
--      判定對象是自然人，角色切換無效。

ALTER TABLE mapping_rule ADD COLUMN created_by uuid REFERENCES app_user;
ALTER TABLE mapping_rule ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE mapping_rule
  ADD CONSTRAINT mapping_rule_version_uq UNIQUE (engagement_id, source_account_code, version_no);

CREATE FUNCTION fn_mapping_target_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_eng uuid; v_tenant uuid;
BEGIN
  SELECT c.engagement_id, c.tenant_id INTO v_eng, v_tenant
    FROM account a JOIN chart_of_accounts c ON c.coa_id = a.coa_id
   WHERE a.account_id = NEW.target_account_id;
  IF v_eng IS NULL OR v_eng <> NEW.engagement_id OR v_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規（§24.1A）：目標科目不屬於本案件的科目表（來源科目 %）',
      NEW.source_account_code;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_mapping_target
  BEFORE INSERT OR UPDATE ON mapping_rule
  FOR EACH ROW EXECUTE FUNCTION fn_mapping_target_guard();

CREATE FUNCTION fn_mapping_version_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.approved_at IS NOT NULL THEN
      RAISE EXCEPTION '映射版本不可覆寫：已批准版本 %（v%）不可刪除',
        OLD.source_account_code, OLD.version_no;
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION '映射版本不可覆寫：已批准版本 %（v%）不可修改，變更請建立新版本',
      OLD.source_account_code, OLD.version_no;
  END IF;
  IF NEW.approved_at IS NOT NULL THEN
    IF NEW.approved_by IS NULL THEN
      RAISE EXCEPTION '批准必須記錄批准人';
    END IF;
    IF NEW.approved_by = OLD.created_by THEN
      RAISE EXCEPTION 'SOD：映射建立者不得批准自己建立的版本（自然人判定，角色切換無效）';
    END IF;
    IF NEW.source_account_code <> OLD.source_account_code
       OR NEW.target_account_id <> OLD.target_account_id
       OR NEW.version_no <> OLD.version_no
       OR NEW.engagement_id <> OLD.engagement_id
       OR COALESCE(NEW.created_by::text, '') <> COALESCE(OLD.created_by::text, '') THEN
      RAISE EXCEPTION '批准時不得同時修改映射內容';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_mapping_version
  BEFORE UPDATE OR DELETE ON mapping_rule
  FOR EACH ROW EXECUTE FUNCTION fn_mapping_version_guard();
