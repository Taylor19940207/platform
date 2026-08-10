-- 0024 ImportBatch 四層歸屬守衛（上傳模組拆層時補上的既有缺口）
--
-- 現況缺陷：import_batch 的 declared_legal_entity_id 與 declared_period_revision_id
-- 各自有外鍵，但**兩者之間沒有任何一致性約束**。同一案件有多個法人時
-- （Case-001 就有兩個），可以把 A 法人的 TB 掛到 B 法人的期間——
-- 租戶對、案件對、法人對、期間也對，唯獨「這個期間是誰的」錯了。
--
-- 應用層（modules/uploads/guard.ts）已先擋一次。這裡是最後防線：
-- 應用程式改錯、繞過 UI、或直接下 SQL 都必須被擋下。
-- 少了它，「歸屬完整性」就只是應用層的一個 if。

CREATE FUNCTION fn_import_batch_attribution_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_le_eng uuid; v_rp_eng uuid; v_ru_eng uuid; v_ru_scope text; v_ru_le uuid;
BEGIN
  SELECT engagement_id INTO v_le_eng FROM legal_entity
   WHERE legal_entity_id = NEW.declared_legal_entity_id;
  SELECT rp.engagement_id, ru.engagement_id, ru.unit_scope, ru.legal_entity_id
    INTO v_rp_eng, v_ru_eng, v_ru_scope, v_ru_le
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
    JOIN reporting_unit ru ON ru.reporting_unit_id = rp.reporting_unit_id
   WHERE pr.period_revision_id = NEW.declared_period_revision_id;

  IF v_le_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION 'BATCH_ATTRIBUTION_MISMATCH: 宣告法人（%）不屬於本批次的案件',
      NEW.declared_legal_entity_id;
  END IF;
  IF v_rp_eng IS DISTINCT FROM NEW.engagement_id
  OR v_ru_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION 'BATCH_ATTRIBUTION_MISMATCH: 宣告期間（%）不屬於本批次的案件',
      NEW.declared_period_revision_id;
  END IF;
  -- 這兩條才是本 migration 的重點：期間的報告單位必須就是所宣告的那個法人。
  IF v_ru_scope IS DISTINCT FROM 'LEGAL_ENTITY' THEN
    RAISE EXCEPTION 'BATCH_ATTRIBUTION_MISMATCH: 宣告期間的報告單位型別為 %，來源 TB 只能掛在法人單位上',
      COALESCE(v_ru_scope, '不存在');
  END IF;
  IF v_ru_le IS DISTINCT FROM NEW.declared_legal_entity_id THEN
    RAISE EXCEPTION 'BATCH_ATTRIBUTION_MISMATCH: 宣告期間屬於法人 %，與宣告法人 % 不一致（同案件跨法人錯配）',
      v_ru_le, NEW.declared_legal_entity_id;
  END IF;
  RETURN NEW;
END $$;

-- 歸屬欄位建立後即凍結（0009 對 adjustment 的同一原則）：批次不得在生命週期中
-- 換法人或換期間，否則既有 SourceLedgerLine 會靜默改變歸屬。
CREATE FUNCTION fn_import_batch_attribution_freeze() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
  OR NEW.declared_legal_entity_id IS DISTINCT FROM OLD.declared_legal_entity_id
  OR NEW.declared_period_revision_id IS DISTINCT FROM OLD.declared_period_revision_id THEN
    RAISE EXCEPTION 'BATCH_ATTRIBUTION_IMMUTABLE: 批次的案件／法人／期間建立後不可變更（既有來源事實會靜默改變歸屬）';
  END IF;
  RETURN NEW;
END $$;

-- 名稱排在既有 import_batch 觸發器之後，讓原有的狀態機與身分守衛先行判定，
-- 避免既有負面測試以「歸屬錯配」這個新理由通過（PostgreSQL 依名稱順序觸發）。
CREATE TRIGGER trg_import_batch_zattribution BEFORE INSERT ON import_batch
  FOR EACH ROW EXECUTE FUNCTION fn_import_batch_attribution_guard();
CREATE TRIGGER trg_import_batch_zfreeze BEFORE UPDATE ON import_batch
  FOR EACH ROW EXECUTE FUNCTION fn_import_batch_attribution_freeze();
