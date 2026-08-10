-- 0027 自動保存三欄的「全空或全非空」約束（0026 的反向缺口）
--
-- 0026 只檢查「有 edit_session_id 時 sequence 與 hash 必填」，反向仍允許
-- session 為空但 sequence／hash 有值。那種列的冪等判定會拿不到來源，
-- 於是「同序號」的比對永遠不成立——重送會被當成新內容，序號形同虛設。
--
-- 用 CHECK 而不是只靠 trigger：它對 INSERT、UPDATE、直接 SQL 一律成立，
-- 且不依賴觸發器順序。
ALTER TABLE adjustment ADD CONSTRAINT adjustment_autosave_all_or_none CHECK (
  (edit_session_id IS NULL AND client_save_sequence IS NULL
    AND last_save_content_hash IS NULL AND last_saved_at IS NULL AND last_saved_by IS NULL)
  OR
  (edit_session_id IS NOT NULL AND client_save_sequence IS NOT NULL
    AND last_save_content_hash IS NOT NULL AND last_saved_at IS NOT NULL
    AND last_saved_by IS NOT NULL)
);
