-- 0021 映射來源批次必須已被接受（SLICE-M2-04 關閉稽核）
--
-- 0020 的 fn_mapping_source_batch_guard 只驗「同租戶且同案件」，未要求來源批次已 ACCEPTED。
-- 因此 DRAFT／UPLOADED／VALIDATED／QUARANTINED／SUPERSEDED 的批次都能成為映射草稿的
-- 來源脈絡。真正的風險不是 engagement_id 漂移（0020 的 fn_import_batch_guard 已在
-- OLD.status <> 'DRAFT' 時凍結歸屬欄位），而是：
--
--   **未經接受的批次成為正式映射的來源脈絡**——例如被隔離（QUARANTINED）或尚未通過
--   驗證的批次，追溯鏈會指向一份從未被接受的資料。
--
-- 另需 FOR UPDATE：只做 SELECT 檢查會留下 TOCTOU 窗口——檢查通過後、INSERT 提交前，
-- 另一交易可把該批次由 ACCEPTED 轉為 SUPERSEDED，映射仍會建立成功。
-- 鎖住批次列可讓兩者無法交錯穿越。
--
-- 不追溯既有映射：UPDATE 分支只驗「來源脈絡不可變更」，不重驗 ACCEPTED——
-- 已合法建立的映射不因來源批次日後轉 SUPERSEDED 而被刪除或改寫（歷史事實不可回溯改寫）。

CREATE OR REPLACE FUNCTION fn_mapping_source_batch_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_status import_batch_status;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.source_import_batch_id IS DISTINCT FROM OLD.source_import_batch_id THEN
      RAISE EXCEPTION '映射草稿的來源批次脈絡不可變更';
    END IF;
    -- 刻意不重驗 ACCEPTED：既有映射不因來源批次日後轉 SUPERSEDED 而被追溯改寫
    RETURN NEW;
  END IF;

  IF NEW.source_import_batch_id IS NOT NULL THEN
    -- FOR UPDATE：鎖住來源批次列，消除「檢查通過後批次狀態才改變」的 TOCTOU
    SELECT b.status INTO v_status
      FROM import_batch b
     WHERE b.import_batch_id = NEW.source_import_batch_id
       AND b.tenant_id = NEW.tenant_id AND b.engagement_id = NEW.engagement_id
     FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '映射來源批次歸屬違規：必須同租戶且同案件（INV-18／§24.1A）';
    END IF;
    IF v_status <> 'ACCEPTED' THEN
      RAISE EXCEPTION 'SOURCE_BATCH_NOT_ACCEPTED：映射來源批次必須已接受（目前為 %）——未經接受的批次不得成為正式映射的來源脈絡',
        v_status;
    END IF;
  END IF;
  RETURN NEW;
END $$;
