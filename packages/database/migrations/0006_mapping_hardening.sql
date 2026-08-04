-- 0006 映射硬化（SLICE-M2-01 覆核回饋）
-- created_by 是 SOD 比較（approved_by = created_by → 拒絕）的左值。
--   1. NULL 會使比較永遠不成立（NULL = x → NULL），等於可繞過 → NOT NULL。
--   2. 草稿階段改寫 created_by 再自批是同一個洞的第二條路 → created_by 不可變更。

ALTER TABLE mapping_rule ALTER COLUMN created_by SET NOT NULL;

CREATE FUNCTION fn_mapping_created_by_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
    RAISE EXCEPTION '映射建立者（created_by）不可變更——SOD 比較的基準不得被改寫';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_mapping_created_by
  BEFORE UPDATE ON mapping_rule
  FOR EACH ROW EXECUTE FUNCTION fn_mapping_created_by_immutable();
