-- 0002 曆法與期間（設計書 §26.4 分區 B——期間子模型的最小切片）
-- 完整模型含 PeriodCompositionVersion／TaxYearAllocation 等，屬第二階段；
-- 第一條 TB 匯入流程只需要「批次歸屬到哪個期間修訂」。

CREATE TABLE fiscal_calendar (
  fiscal_calendar_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  engagement_id uuid NOT NULL REFERENCES client_engagement,
  name          text NOT NULL,          -- 例：日本 4 月起、中國曆年
  year_start_month int NOT NULL CHECK (year_start_month BETWEEN 1 AND 12),
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE reporting_period (
  reporting_period_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  engagement_id     uuid NOT NULL REFERENCES client_engagement,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  fiscal_calendar_id uuid NOT NULL REFERENCES fiscal_calendar,
  period_kind       text NOT NULL DEFAULT 'REGULAR' CHECK (period_kind IN ('REGULAR','OPENING','ADJUSTMENT')),
  label             text NOT NULL,      -- 例：2026-03
  start_date        date NOT NULL,
  end_date          date NOT NULL,
  CHECK (start_date <= end_date)
);
-- INV-15 的最小版：同單位同曆法的 REGULAR 期間不得重疊。
CREATE EXTENSION IF NOT EXISTS btree_gist;
ALTER TABLE reporting_period ADD CONSTRAINT reporting_period_no_overlap
  EXCLUDE USING gist (
    reporting_unit_id WITH =,
    fiscal_calendar_id WITH =,
    daterange(start_date, end_date, '[]') WITH &&
  ) WHERE (period_kind = 'REGULAR');

-- 期間修訂：INV-10——已 LOCKED 的修訂不可變，追溯變更產生新 revision。
CREATE TABLE period_revision (
  period_revision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES tenant,
  reporting_period_id uuid NOT NULL REFERENCES reporting_period,
  revision_no         int NOT NULL DEFAULT 1,
  status              text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('SETUP','OPEN','LOCKED','REOPENED')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  locked_at           timestamptz,
  UNIQUE (reporting_period_id, revision_no)
);
