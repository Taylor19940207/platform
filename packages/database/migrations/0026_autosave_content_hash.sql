-- 0026 自動保存的冪等鍵必須涵蓋內容（autosave correctness 收口）
--
-- 0025 的冪等判定只看 (edit_session_id, client_save_sequence)。漏洞：
-- 同一序號帶**不同內容**重送時，系統回報「已保存」，但資料庫裡是上一份內容。
-- 使用者看到綠燈、實際內容沒進去——這比明白失敗更糟，因為沒有人會去重試。
--
-- 修法：冪等鍵＝(來源, 序號, **內容雜湊**)。
--   同序號同雜湊 → 真的是重試，回報成功
--   同序號異雜湊 → IDEMPOTENCY_KEY_REUSED（409），序號被重用於不同內容
-- 與 CalculationRun 的 request_key／request_content_hash 是同一個契約（0012）。

ALTER TABLE adjustment ADD COLUMN last_save_content_hash text;

-- 三個併發控制欄位必須成組寫入：只寫其中一部分，冪等判定就會拿舊雜湊比對新序號。
CREATE OR REPLACE FUNCTION fn_adjustment_autosave_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.edit_session_id        IS DISTINCT FROM OLD.edit_session_id
   OR NEW.client_save_sequence   IS DISTINCT FROM OLD.client_save_sequence
   OR NEW.last_save_content_hash IS DISTINCT FROM OLD.last_save_content_hash
   OR NEW.last_saved_at          IS DISTINCT FROM OLD.last_saved_at
   OR NEW.last_saved_by          IS DISTINCT FROM OLD.last_saved_by)
   AND OLD.status <> 'DRAFTING' THEN
    RAISE EXCEPTION 'AUTOSAVE_FIELDS_DRAFT_ONLY: 併發控制欄位只在 DRAFTING 階段可變更（目前 %）', OLD.status;
  END IF;
  IF (NEW.last_saved_by IS NOT NULL) <> (NEW.edit_session_id IS NOT NULL) THEN
    RAISE EXCEPTION 'AUTOSAVE_FIELDS_PAIRED: last_saved_by 與 edit_session_id 必須成對寫入';
  END IF;
  IF (NEW.edit_session_id IS NOT NULL)
     AND (NEW.client_save_sequence IS NULL OR NEW.last_save_content_hash IS NULL) THEN
    RAISE EXCEPTION 'AUTOSAVE_FIELDS_PAIRED: 冪等鍵三欄（來源／序號／內容雜湊）必須成組寫入';
  END IF;
  RETURN NEW;
END $$;
