-- 0025 草稿自動保存的併發欄位（NFR-UX-001／NFR-INT-002；§26.9 三層版本語意）
--
-- §26.9 把版本語意分成三層，本檔補齊第一層「併發控制版本」缺少的欄位：
--   object_version        每次自動儲存遞增（已存在，0007）
--   edit_session_id       識別編輯來源——**同一自然人的不同分頁取得不同值**
--   client_save_sequence  冪等鍵：重試與亂序到達時去重，避免重送造成假衝突
--   last_saved_at/by      最後一次**伺服器確認**保存的時間與人
--   stale_marked_at       長期未動草稿的過期標記（清理候選，**非刪除**）
--
-- 為什麼 edit_session_id 不能用 user_id 代替：同一個人開兩個分頁編輯同一份草稿，
-- 兩邊的 base_object_version 都是舊值。只比對使用者的話兩邊都「是自己」，
-- 後送出的會靜默覆蓋先送出的——NFR-INT-002 的 INT-a2 就是這條。
--
-- 為什麼 client_save_sequence 不能省：自動保存會重送（網路抖動、瀏覽器重試）。
-- 沒有冪等鍵時，重送的第二次會因為 object_version 已被第一次遞增而被判為
-- 「版本衝突」——使用者看到的是自己跟自己衝突，那是假衝突。

ALTER TABLE adjustment ADD COLUMN edit_session_id      uuid;
ALTER TABLE adjustment ADD COLUMN client_save_sequence int;
ALTER TABLE adjustment ADD COLUMN last_saved_at        timestamptz;
ALTER TABLE adjustment ADD COLUMN last_saved_by        uuid REFERENCES app_user;
ALTER TABLE adjustment ADD COLUMN stale_marked_at      timestamptz;

-- 這五欄只在 DRAFTING 階段有意義：離開草稿後的內容由 business_version 與
-- 不可變快照負責，併發控制欄位不得再被改寫（否則可製造「已送覆核卻仍在自動保存」
-- 的矛盾資料）。
CREATE FUNCTION fn_adjustment_autosave_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.edit_session_id      IS DISTINCT FROM OLD.edit_session_id
   OR NEW.client_save_sequence IS DISTINCT FROM OLD.client_save_sequence
   OR NEW.last_saved_at        IS DISTINCT FROM OLD.last_saved_at
   OR NEW.last_saved_by        IS DISTINCT FROM OLD.last_saved_by)
   AND OLD.status <> 'DRAFTING' THEN
    RAISE EXCEPTION 'AUTOSAVE_FIELDS_DRAFT_ONLY: 併發控制欄位只在 DRAFTING 階段可變更（目前 %）', OLD.status;
  END IF;
  -- last_saved_by 必須是實際保存者，且與 edit_session_id 成對出現——
  -- 只寫其中一個會讓「誰在哪個分頁存的」永遠答不出來。
  IF (NEW.last_saved_by IS NOT NULL) <> (NEW.edit_session_id IS NOT NULL) THEN
    RAISE EXCEPTION 'AUTOSAVE_FIELDS_PAIRED: last_saved_by 與 edit_session_id 必須成對寫入';
  END IF;
  RETURN NEW;
END $$;

-- 名稱排在既有 adjustment 守衛之後：讓狀態機與 SoD 先行判定，
-- 避免既有負面測試以「自動保存欄位」這個新理由通過。
CREATE TRIGGER trg_adjustment_zautosave BEFORE UPDATE ON adjustment
  FOR EACH ROW EXECUTE FUNCTION fn_adjustment_autosave_guard();

-- 同一編輯來源的序號不得倒退：亂序到達的舊請求必須被忽略，不得覆蓋新內容。
-- 這條寫在 DB 而不只在應用層，因為它是「不得遺失已確認保存」的最後防線。
CREATE FUNCTION fn_adjustment_save_sequence_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.edit_session_id IS NOT NULL
     AND NEW.edit_session_id IS NOT DISTINCT FROM OLD.edit_session_id
     AND OLD.client_save_sequence IS NOT NULL
     AND NEW.client_save_sequence < OLD.client_save_sequence THEN
    RAISE EXCEPTION 'SAVE_SEQUENCE_REGRESSION: 同一編輯來源的保存序號不得倒退（已接受 %，本次 %）',
      OLD.client_save_sequence, NEW.client_save_sequence;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_adjustment_zsaveseq BEFORE UPDATE ON adjustment
  FOR EACH ROW EXECUTE FUNCTION fn_adjustment_save_sequence_guard();
