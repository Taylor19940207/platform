-- 0010 BackgroundJob：非同步工作可靠性（SLICE-M2-03）
-- 契約：docs/slices/SLICE-M2-03_背景工作可靠性.md
-- 可觀察性決定：docs/adr/ADR-M2-002.md
--
-- 設計書 §27.4 L1620：「非同步作業的共同要求：具冪等鍵、可重試、失敗有明確終態與
-- 人可讀原因、進度可查詢、不吞掉錯誤。任何非同步作業的失敗都不得讓業務物件停在中間狀態。」
--
-- 凍結的是 ImportBatch.status 七狀態，不是禁止非同步工作擁有自己的狀態：
--   ImportBatch.status    = 業務結果狀態
--   BackgroundJob.status  = 非同步執行進度
-- 基礎設施故障因此不會污染 ImportBatch，批次也不可能永久卡在 VALIDATING。

CREATE TYPE background_job_status AS ENUM
  ('QUEUED','RUNNING','RETRY_WAIT','COMPLETED','FAILED');

-- 錯誤四分類（處置完全不同，不得混為一談）：
--   BUSINESS_VALIDATION       業務裁決 → 立即 QUARANTINED，不重試
--   RETRYABLE_INFRASTRUCTURE  基礎設施故障 → 退避重試；ImportBatch 保持 UPLOADED
--   NON_RETRYABLE_SYSTEM      系統性錯誤 → job FAILED，人工處理
--   LEASE_LOST                租約已被接手 → 舊 worker 停手，不得改任何狀態
CREATE TYPE job_error_class AS ENUM
  ('BUSINESS_VALIDATION','RETRYABLE_INFRASTRUCTURE','NON_RETRYABLE_SYSTEM','LEASE_LOST');

CREATE TABLE background_job (
  job_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenant,
  job_type        text NOT NULL CHECK (job_type IN ('IMPORT_VALIDATION')),
  subject_id      uuid NOT NULL,               -- IMPORT_VALIDATION → import_batch_id
  subject_version int  NOT NULL,               -- import_batch.batch_version
  rule_version    text NOT NULL,               -- detection_rule_version
  -- 冪等鍵是結構化唯一約束（下方 UNIQUE）；idempotency_key 為其 canonical hash，
  -- 屬推導值，不得被獨立填寫或當成第二個真相來源。
  idempotency_key text NOT NULL,
  status          background_job_status NOT NULL DEFAULT 'QUEUED',
  -- claimed_by 只作診斷；claim_token 才是寫入權威。
  -- 只比對 claimed_by 不是真正的 fencing——worker ID 被重用時，
  -- 舊 worker 恢復後可能誤用新租約。每次認領產生新的 claim_token。
  claimed_by      text,
  claim_token     uuid,
  claimed_at      timestamptz,
  lease_expires_at timestamptz,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  attempt_count   int  NOT NULL DEFAULT 0,
  max_attempts    int  NOT NULL DEFAULT 5,     -- 首次執行 ＋ 4 次重試
  last_error_class   job_error_class,
  last_error_message text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  completed_at    timestamptz,
  failed_at       timestamptz,
  UNIQUE (job_type, subject_id, subject_version, rule_version)
);

CREATE INDEX background_job_claimable_idx
  ON background_job (status, next_attempt_at, lease_expires_at);

-- ── 狀態與租約紀律 ────────────────────────────────────────────
CREATE FUNCTION fn_background_job_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  legal boolean;
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

  IF OLD.status = NEW.status THEN
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

  -- 認領：必須帶新的 claim_token 與租約
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

CREATE TRIGGER trg_background_job_guard
  BEFORE UPDATE ON background_job
  FOR EACH ROW EXECUTE FUNCTION fn_background_job_guard();

-- 租戶歸屬（INV-18）：工作的主體必須屬於同一租戶
CREATE FUNCTION fn_background_job_tenant_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_tenant uuid;
BEGIN
  IF NEW.job_type = 'IMPORT_VALIDATION' THEN
    SELECT tenant_id INTO v_tenant FROM import_batch WHERE import_batch_id = NEW.subject_id;
    IF v_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'INV-18：工作主體（匯入批次 %）不屬於本租戶', NEW.subject_id;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_background_job_tenant
  BEFORE INSERT OR UPDATE ON background_job
  FOR EACH ROW EXECUTE FUNCTION fn_background_job_tenant_guard();

-- ── 衍生資料的自然唯一性（冪等的第二道防線） ──────────────────
-- 單一交易解決「不留半套資料」，冪等鍵解決「重送不產生第二份結果」——
-- 兩者不可互相取代。source_dataset 與 data_coverage 原本沒有 batch_version，先補。
ALTER TABLE source_dataset ADD COLUMN batch_version int;
ALTER TABLE data_coverage  ADD COLUMN batch_version int;

UPDATE source_dataset sd SET batch_version = ib.batch_version
  FROM import_batch ib WHERE ib.import_batch_id = sd.import_batch_id;
UPDATE data_coverage dc SET batch_version = ib.batch_version
  FROM import_batch ib WHERE ib.import_batch_id = dc.import_batch_id;

ALTER TABLE source_dataset ALTER COLUMN batch_version SET NOT NULL;
ALTER TABLE data_coverage  ALTER COLUMN batch_version SET NOT NULL;

ALTER TABLE source_dataset
  ADD CONSTRAINT source_dataset_idem_uq UNIQUE (import_batch_id, batch_version, granularity);
ALTER TABLE data_coverage
  ADD CONSTRAINT data_coverage_idem_uq
  UNIQUE (import_batch_id, batch_version, granularity, account_scope);
ALTER TABLE source_identity_assessment
  ADD CONSTRAINT sia_idem_uq
  UNIQUE (import_batch_id, batch_version, detection_rule_version);

-- ── RLS ───────────────────────────────────────────────────────
ALTER TABLE background_job ENABLE ROW LEVEL SECURITY;
ALTER TABLE background_job FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON background_job
  USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant());
GRANT SELECT, INSERT, UPDATE, DELETE ON background_job TO app_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_runtime;
