-- 0003 匯入流程（設計書 §25.5／§26.6、CR-002）
-- 主狀態機七狀態（v1.0 不變）× identity_status 正交軸（CR-002）。
-- G-01 接受判定式、INV-28、SOD-07 在資料庫層做成最後防線；
-- 應用層先判定並記錄 ControlViolationAttempt，DB 觸發器只負責「絕不放行」。

CREATE TYPE import_batch_status AS ENUM
  ('DRAFT','UPLOADED','VALIDATING','QUARANTINED','VALIDATED','ACCEPTED','SUPERSEDED');

CREATE TYPE identity_status AS ENUM
  ('NOT_CHECKED','MATCHED','PENDING_CONFIRMATION','MANUALLY_RESOLVED','CONFLICT');

-- 科目表與科目（§26.11 最小切片；多語欄位第二階段補）
CREATE TABLE chart_of_accounts (
  coa_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  engagement_id uuid NOT NULL REFERENCES client_engagement,
  name          text NOT NULL,
  version_no    int  NOT NULL DEFAULT 1
);

CREATE TABLE account (
  account_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant,
  coa_id      uuid NOT NULL REFERENCES chart_of_accounts,
  code        text NOT NULL,
  name        text NOT NULL,
  balance_behavior text NOT NULL DEFAULT 'STOCK' CHECK (balance_behavior IN ('STOCK','FLOW')),
  UNIQUE (coa_id, code)
);

-- 映射規則（§26.8 最小切片：一對一；條件式／一對多第二階段）
CREATE TABLE mapping_rule (
  mapping_rule_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenant,
  engagement_id   uuid NOT NULL REFERENCES client_engagement,
  source_account_code text NOT NULL,
  target_account_id   uuid NOT NULL REFERENCES account,
  version_no      int NOT NULL DEFAULT 1,
  approved_by     uuid REFERENCES app_user,
  approved_at     timestamptz,
  effective_from  date,
  effective_to    date
);

CREATE TABLE import_batch (
  import_batch_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenant,
  engagement_id   uuid NOT NULL REFERENCES client_engagement,
  -- 宣告目標（DeclaredTarget，CR-002 主題四）
  declared_legal_entity_id uuid NOT NULL REFERENCES legal_entity,
  declared_period_revision_id uuid NOT NULL REFERENCES period_revision,
  batch_version   int  NOT NULL DEFAULT 1,
  status          import_batch_status NOT NULL DEFAULT 'DRAFT',
  identity_status identity_status     NOT NULL DEFAULT 'NOT_CHECKED',
  -- provided_by 與 uploaded_by 分開（D-24-03）：KPI 歸屬用 provided_by
  provided_by     uuid REFERENCES app_user,
  uploaded_by     uuid REFERENCES app_user,
  file_name       text,
  file_sha256     text,
  hash_verified   boolean NOT NULL DEFAULT false,
  superseded_by_id uuid REFERENCES import_batch,   -- INV-08
  quarantine_reason text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ── 主狀態機遷移守衛（§25.5 的遷移表，DB 層強制） ────────────────
CREATE FUNCTION fn_import_batch_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  legal boolean;
BEGIN
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

  -- G-01 接受判定式（§25.13）＝ INV-28 的執行路徑：
  --   status == VALIDATED
  --   AND identity_status IN (MATCHED, MANUALLY_RESOLVED)
  --   AND 完整雜湊驗證通過
  IF NEW.status = 'ACCEPTED' THEN
    IF OLD.status <> 'VALIDATED'
       OR NEW.identity_status NOT IN ('MATCHED','MANUALLY_RESOLVED')
       OR NOT NEW.hash_verified THEN
      RAISE EXCEPTION 'G-01/INV-28：不滿足接受判定式（status=%→%, identity_status=%, hash_verified=%）',
        OLD.status, NEW.status, NEW.identity_status, NEW.hash_verified;
    END IF;
  END IF;

  -- INV-08：SUPERSEDED 必有替代批次
  IF NEW.status = 'SUPERSEDED' AND NEW.superseded_by_id IS NULL THEN
    RAISE EXCEPTION 'INV-08：SUPERSEDED 必須指向替代批次';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE TRIGGER trg_import_batch_guard
  BEFORE UPDATE ON import_batch
  FOR EACH ROW EXECUTE FUNCTION fn_import_batch_guard();

-- ── 身分評估與人工確認（CR-002；§26.6） ─────────────────────
-- SourceIdentityAssessment：不可變；重新解析／規則升版產生新列，與舊列並存。
CREATE TABLE source_identity_assessment (
  assessment_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenant,
  import_batch_id uuid NOT NULL REFERENCES import_batch,
  batch_version   int  NOT NULL,
  detected_identity jsonb NOT NULL DEFAULT '[]'::jsonb,   -- 一對多
  match_result    text NOT NULL CHECK (match_result IN ('MATCH','CONFLICT','UNVERIFIABLE')),
  evidence_kind   text NOT NULL CHECK (evidence_kind IN ('AUTHORITATIVE_ID','APPROVED_ALIAS','FUZZY_NAME','NONE')),
  detection_rule_version text NOT NULL,
  assessed_at     timestamptz NOT NULL DEFAULT now(),
  -- 證據強度分級：僅權威識別符可產生 CONFLICT
  CHECK (match_result <> 'CONFLICT' OR evidence_kind = 'AUTHORITATIVE_ID')
);
CREATE TRIGGER trg_sia_immutable
  BEFORE UPDATE OR DELETE ON source_identity_assessment
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

-- SourceIdentityResolution：不可覆寫；效力只及該 batch_version。
CREATE TABLE source_identity_resolution (
  resolution_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenant,
  assessment_id   uuid NOT NULL REFERENCES source_identity_assessment,
  import_batch_id uuid NOT NULL REFERENCES import_batch,
  batch_version   int  NOT NULL,
  resolved_by     uuid NOT NULL REFERENCES app_user,
  acting_role     role_code NOT NULL,
  reason          text NOT NULL,
  evidence_ref    text,
  detection_rule_version text NOT NULL,
  resolved_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (assessment_id)
);
CREATE TRIGGER trg_sir_immutable
  BEFORE UPDATE OR DELETE ON source_identity_resolution
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

-- SOD-07（實例級，後端強制）：上傳者不得確認自己上傳的批次。
-- 角色級禁令擋不住「上傳後切換角色再確認自己」——判定對象是自然人，不是角色。
CREATE FUNCTION fn_sod07_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_uploaded_by uuid;
BEGIN
  SELECT uploaded_by INTO v_uploaded_by
    FROM import_batch WHERE import_batch_id = NEW.import_batch_id;
  IF v_uploaded_by IS NOT NULL AND v_uploaded_by = NEW.resolved_by THEN
    RAISE EXCEPTION 'SOD-07：上傳者（%）不得確認自己上傳的批次，與當下角色無關', NEW.resolved_by;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_sod07
  BEFORE INSERT ON source_identity_resolution
  FOR EACH ROW EXECUTE FUNCTION fn_sod07_guard();

-- ── 來源資料（§26.6 分區 E 最小切片） ───────────────────────
CREATE TABLE source_dataset (
  source_dataset_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenant,
  import_batch_id uuid NOT NULL REFERENCES import_batch,
  granularity     text NOT NULL CHECK (granularity IN ('BALANCE','JOURNAL','SUBLEDGER','DOCUMENT')),
  content_sha256  text NOT NULL,
  row_count       int  NOT NULL DEFAULT 0
);

CREATE TABLE source_document (
  source_document_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenant,
  import_batch_id uuid NOT NULL REFERENCES import_batch,
  file_name       text NOT NULL,
  content_sha256  text NOT NULL,
  object_key      text NOT NULL,            -- ObjectStore 介面的鍵（ADR-03 抽象邊界）
  byte_size       bigint NOT NULL,
  uploaded_at     timestamptz NOT NULL DEFAULT now()
);

-- SourceLedgerLine：不可變（更正走新批次）。金額以 numeric 存，絕不用浮點。
CREATE TABLE source_ledger_line (
  source_ledger_line_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id         uuid NOT NULL REFERENCES tenant,
  source_dataset_id uuid NOT NULL REFERENCES source_dataset,
  import_batch_id   uuid NOT NULL REFERENCES import_batch,
  source_row_id     text NOT NULL,          -- 來源列 ID：追溯的起點
  account_code      text NOT NULL,
  account_name      text,
  debit             numeric(20,2) NOT NULL DEFAULT 0,
  credit            numeric(20,2) NOT NULL DEFAULT 0,
  currency_code     text NOT NULL DEFAULT 'JPY',
  content_sha256    text NOT NULL,
  CHECK (debit >= 0 AND credit >= 0)
);
CREATE TRIGGER trg_sll_immutable
  BEFORE UPDATE OR DELETE ON source_ledger_line
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

CREATE INDEX sll_batch_idx ON source_ledger_line (import_batch_id);

-- DataCoverage（CR-001：粒度與涵蓋範圍紀錄）
CREATE TABLE data_coverage (
  data_coverage_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  import_batch_id   uuid NOT NULL REFERENCES import_batch,
  account_scope     text NOT NULL DEFAULT '*',
  granularity       text NOT NULL CHECK (granularity IN ('BALANCE','JOURNAL','SUBLEDGER','DOCUMENT')),
  completeness_status text NOT NULL DEFAULT 'UNKNOWN'
    CHECK (completeness_status IN ('COMPLETE','PARTIAL','UNKNOWN'))
);

-- G-01 借貸平衡：以 numeric 精確加總；回傳差額（0 = 平衡）
CREATE FUNCTION fn_tb_balance(p_batch uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT COALESCE(SUM(debit) - SUM(credit), 0)
    FROM source_ledger_line WHERE import_batch_id = p_batch
$$;
