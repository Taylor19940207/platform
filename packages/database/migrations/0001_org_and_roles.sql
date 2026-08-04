-- 0001 組織與角色（設計書 §24.5／§24.9、§26.3 分區 A）
-- Tenant 是契約與最高資料隔離邊界；四層結構 Tenant → ClientEngagement → ReportingUnit(LegalEntity) → ReportingPeriod。
-- 註：INV-18 禁止跨 Tenant 外鍵；所有事實實體帶 tenant_id 冗餘欄位供 RLS 與隔離檢查。

CREATE TYPE role_code AS ENUM ('R1','R2','R3','R4','R5','R6','R7','R8','R9');

CREATE TABLE tenant (
  tenant_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app_user (
  user_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant,
  email       text NOT NULL,
  display_name text NOT NULL,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, email)
);

CREATE TABLE client_engagement (
  engagement_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  name          text NOT NULL,
  status        text NOT NULL DEFAULT 'ACTIVE',
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE legal_entity (
  legal_entity_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenant,
  engagement_id   uuid NOT NULL REFERENCES client_engagement,
  name            text NOT NULL,
  -- 權威識別符：主題四證據強度分級的第一級（法人番号等）。身分比對只有這一級可產生 CONFLICT。
  authoritative_code text,
  country_code    text NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX legal_entity_auth_code_uq
  ON legal_entity (tenant_id, authoritative_code) WHERE authoritative_code IS NOT NULL;

CREATE TABLE reporting_unit (
  reporting_unit_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  engagement_id     uuid NOT NULL REFERENCES client_engagement,
  legal_entity_id   uuid REFERENCES legal_entity,
  unit_scope        text NOT NULL CHECK (unit_scope IN ('LEGAL_ENTITY','CONSOLIDATION_GROUP')),
  name              text NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- 角色指派：engagement_id 為 NULL＝租戶層級指派；非 NULL＝案件層級。
-- B-00「只顯示有權且被指派的工作」（WKB-a）由此表過濾。
CREATE TABLE role_assignment (
  role_assignment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  user_id       uuid NOT NULL REFERENCES app_user,
  role          role_code NOT NULL,
  engagement_id uuid REFERENCES client_engagement,
  granted_at    timestamptz NOT NULL DEFAULT now(),
  revoked_at    timestamptz
);

-- 稽核事件（§25.18：DomainEvent 與 ControlViolationAttempt 分開存放於同表、以 kind 區分；
-- 一般驗證錯誤不得寫入——那走應用日誌）。
CREATE TABLE audit_event (
  audit_event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id      uuid NOT NULL,
  kind           text NOT NULL CHECK (kind IN ('DOMAIN_EVENT','CONTROL_VIOLATION_ATTEMPT','CONTROL_PRECHECK')),
  event_type     text NOT NULL,
  actor_id       uuid,
  acting_role    role_code,           -- 當時角色，非現行角色（INV-11 精神）
  object_type    text,
  object_id      uuid,
  payload        jsonb NOT NULL DEFAULT '{}'::jsonb,
  correlation_id uuid,
  occurred_at    timestamptz NOT NULL DEFAULT now()
);

-- 稽核軌跡 append-only：資料庫層擋住改寫（最後防線；應用層不應嘗試）。
CREATE FUNCTION fn_forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% 為 append-only／不可變，禁止 %', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'raise_exception';
END $$;

CREATE TRIGGER trg_audit_event_immutable
  BEFORE UPDATE OR DELETE ON audit_event
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

-- 應用執行角色：受 RLS 約束（不可 BYPASSRLS）。0004 啟用政策。
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_runtime') THEN
    CREATE ROLE app_runtime LOGIN;
  END IF;
END $$;
