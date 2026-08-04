-- 0011 BackgroundJob 守衛硬化（SLICE-M2-03 關閉修正 ③）
-- 原版 fn_background_job_guard 在 OLD.status = NEW.status 時一律提前返回，
-- 使「RUNNING→RUNNING 到期重領」完全繞過認領檢查（新 claim_token、
-- attempt_count 遞增）——DB 在最關鍵的一條路徑上不是最後防線。
-- 修正：同狀態提前返回僅適用於「非重領」的欄位更新（心跳等）；
-- RUNNING→RUNNING 換 token ＝ 重領，必須走完整認領檢查，且舊租約必須已到期
-- （活租約不可被搶——否則兩個 worker 可同時自認持有）。

CREATE OR REPLACE FUNCTION fn_background_job_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  legal boolean;
  is_reclaim boolean;
BEGIN
  -- 冪等鍵的四個欄位建立後凍結：改寫等於偽造另一個工作的身分
  IF NEW.job_type IS DISTINCT FROM OLD.job_type
  OR NEW.subject_id IS DISTINCT FROM OLD.subject_id
  OR NEW.subject_version IS DISTINCT FROM OLD.subject_version
  OR NEW.rule_version IS DISTINCT FROM OLD.rule_version
  OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
  OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
    RAISE EXCEPTION '冪等鍵欄位建立後不可變更（job_type／subject_id／subject_version／rule_version／idempotency_key／tenant_id）';
  END IF;

  -- 重領＝RUNNING→RUNNING 且 claim_token 變動（含被清空）。不得走同狀態捷徑。
  is_reclaim := OLD.status = 'RUNNING' AND NEW.status = 'RUNNING'
                AND NEW.claim_token IS DISTINCT FROM OLD.claim_token;

  IF OLD.status = NEW.status AND NOT is_reclaim THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  legal := CASE OLD.status
    WHEN 'QUEUED'     THEN NEW.status = 'RUNNING'
    WHEN 'RUNNING'    THEN NEW.status IN ('COMPLETED','FAILED','RETRY_WAIT','RUNNING')
    WHEN 'RETRY_WAIT' THEN NEW.status = 'RUNNING'
    ELSE false                                   -- COMPLETED／FAILED 為終態
  END;
  IF NOT legal THEN
    RAISE EXCEPTION '非法工作狀態遷移 % → %（job %）', OLD.status, NEW.status, OLD.job_id;
  END IF;

  -- 認領（含到期重領）：必須帶新的 claim_token 與租約
  IF NEW.status = 'RUNNING' THEN
    IF NEW.claim_token IS NULL OR NEW.claim_token IS NOT DISTINCT FROM OLD.claim_token THEN
      RAISE EXCEPTION '認領必須產生新的 claim_token（fencing token；claimed_by 僅供診斷）';
    END IF;
    IF NEW.lease_expires_at IS NULL OR NEW.claimed_at IS NULL THEN
      RAISE EXCEPTION '認領必須記錄 claimed_at 與 lease_expires_at';
    END IF;
    IF NEW.attempt_count <> OLD.attempt_count + 1 THEN
      RAISE EXCEPTION '每次認領必須遞增 attempt_count（% → %）', OLD.attempt_count, NEW.attempt_count;
    END IF;
    -- 重領只允許發生在舊租約到期之後
    IF is_reclaim AND COALESCE(OLD.lease_expires_at > now(), false) THEN
      RAISE EXCEPTION '租約尚未到期（至 %），不得重領——活租約不可被搶', OLD.lease_expires_at;
    END IF;
  END IF;

  -- 失敗終態必須有人可讀原因（§27.4：不吞掉錯誤）
  IF NEW.status = 'FAILED' THEN
    IF NEW.last_error_class IS NULL OR COALESCE(NEW.last_error_message,'') = '' THEN
      RAISE EXCEPTION '工作失敗必須記錄錯誤分類與人可讀原因';
    END IF;
    NEW.failed_at := COALESCE(NEW.failed_at, now());
  END IF;

  IF NEW.status = 'RETRY_WAIT' THEN
    IF NEW.next_attempt_at IS NULL OR NEW.next_attempt_at <= OLD.updated_at THEN
      RAISE EXCEPTION 'RETRY_WAIT 必須設定未來的 next_attempt_at（退避時間須可保存可查詢）';
    END IF;
    IF NEW.last_error_class IS NULL THEN
      RAISE EXCEPTION 'RETRY_WAIT 必須記錄錯誤分類';
    END IF;
  END IF;

  IF NEW.status = 'COMPLETED' THEN
    NEW.completed_at := COALESCE(NEW.completed_at, now());
  END IF;

  -- 離開 RUNNING 即釋放租約，避免殘留的 token 讓舊 worker 誤以為仍持有
  IF OLD.status = 'RUNNING' AND NEW.status <> 'RUNNING' THEN
    NEW.claim_token := NULL;
    NEW.lease_expires_at := NULL;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;
