-- 0030 折算與外幣報表折算差額（SLICE-M3-02，契約 APPROVED_FOR_IMPLEMENTATION）
--
-- 三條不可退讓的實作原則（與 0023 同源）：
--   1. 方法是資料不是程式碼分支——折算方法由 translation_policy_rule 驅動，
--      不得由科目代碼或表名推斷。
--   2. 沒有靜默回退——缺率、缺分類、缺期初值、lots 合計不符一律 fail closed，
--      不得回退到期末率、不得取倒數、不得把差額併入 CTA。
--   3. 凍結的東西一律從 manifest 讀——重演時回查目前主檔，等於沒有凍結。
--
-- 本檔只建資料模型與守衛，**不含折算函式**（下一步）。

-- ═══ 1　Currency：平台參照主檔 ═══════════════════════════════════════
-- 與 posting_layer 同性質：不屬任何租戶、不做 RLS、app_runtime 唯讀。
-- 「JPY 0 位、CNY 2 位」必須是資料，不得寫死在程式裡。
CREATE TABLE currency (
  currency_code text PRIMARY KEY CHECK (currency_code ~ '^[A-Z]{3}$'),
  minor_unit    int  NOT NULL CHECK (minor_unit BETWEEN 0 AND 4),
  active        boolean NOT NULL DEFAULT true
);
INSERT INTO currency (currency_code, minor_unit) VALUES
  ('JPY', 0), ('CNY', 2), ('USD', 2), ('EUR', 2);
GRANT SELECT ON currency TO app_runtime;

-- ═══ 2　顯式前期連結 ════════════════════════════════════════════════
-- 「前期」不得用 end_date 減一期或 revision 編號推導：期間可跳號、可有非標準
-- 長度，推導出來的前期在跨年度或補期時會指錯，而期初已折算餘額正是靠它延續。
ALTER TABLE reporting_period
  ADD COLUMN previous_reporting_period_id uuid REFERENCES reporting_period;

-- 一個期間至多被一個後期指向——否則兩期共用同一前期，延續鏈分岔
CREATE UNIQUE INDEX reporting_period_previous_unique
  ON reporting_period (previous_reporting_period_id)
  WHERE previous_reporting_period_id IS NOT NULL;

ALTER TABLE reporting_period ADD CONSTRAINT reporting_period_previous_not_self
  CHECK (previous_reporting_period_id IS DISTINCT FROM reporting_period_id);

-- 首期不得有前期。**反向不強制**：非首期可以暫時沒有連結——期間有可能在其前期
-- 建立之前就先開好，強制雙向只會逼人現場捏一個連結出來，那正是本欄要消滅的東西。
-- 連結缺席時 FX run 以 FX_OPENING_EQUITY_NOT_CONTINUOUS 拒絕（fail closed），
-- 不會靜默改用日期推導的「前期」。
ALTER TABLE reporting_period ADD CONSTRAINT reporting_period_initial_has_no_previous
  CHECK (NOT (is_initial_period AND previous_reporting_period_id IS NOT NULL));

CREATE FUNCTION fn_reporting_period_previous_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_unit uuid; v_cal uuid; v_end date;
BEGIN
  -- 可以從 NULL 補上一次；補上之後不得再改或清除
  IF TG_OP = 'UPDATE'
     AND OLD.previous_reporting_period_id IS NOT NULL
     AND NEW.previous_reporting_period_id IS DISTINCT FROM OLD.previous_reporting_period_id THEN
    RAISE EXCEPTION 'PREVIOUS_PERIOD_IMMUTABLE: 前期連結建立後不可變更（延續鏈是身分事實，改它等於改寫歷史的解釋）';
  END IF;
  IF NEW.previous_reporting_period_id IS NULL THEN
    RETURN NEW;
  END IF;
  -- 自指要有自己的代碼：查表會查不到「尚未存在的自己」，落到單位不符的訊息上，
  -- 讀起來像另一回事
  IF NEW.previous_reporting_period_id = NEW.reporting_period_id THEN
    RAISE EXCEPTION 'PREVIOUS_PERIOD_SELF_REFERENCE: 期間不得以自己為前期';
  END IF;
  SELECT reporting_unit_id, fiscal_calendar_id, end_date INTO v_unit, v_cal, v_end
    FROM reporting_period WHERE reporting_period_id = NEW.previous_reporting_period_id;
  IF v_unit IS DISTINCT FROM NEW.reporting_unit_id THEN
    RAISE EXCEPTION 'PREVIOUS_PERIOD_UNIT_MISMATCH: 前期必須屬同一報告單位';
  END IF;
  IF v_cal IS DISTINCT FROM NEW.fiscal_calendar_id THEN
    RAISE EXCEPTION 'PREVIOUS_PERIOD_CALENDAR_MISMATCH: 前期必須屬同一曆別';
  END IF;
  -- 時序：前期必須真的在前面。這不是「用日期推導前期」，而是驗證人工指定的連結不矛盾。
  IF v_end >= NEW.start_date THEN
    RAISE EXCEPTION 'PREVIOUS_PERIOD_NOT_EARLIER: 前期的期末（%）必須早於本期期初（%）', v_end, NEW.start_date;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_reporting_period_previous
  BEFORE INSERT OR UPDATE ON reporting_period
  FOR EACH ROW EXECUTE FUNCTION fn_reporting_period_previous_guard();

-- ═══ 3　幣別角色指派（INV-22／D-26-06）══════════════════════════════
CREATE TABLE reporting_unit_currency_assignment (
  assignment_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  engagement_id     uuid NOT NULL REFERENCES client_engagement,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  currency_role     text NOT NULL CHECK (currency_role IN ('FUNCTIONAL','REPORTING')),
  currency_code     text NOT NULL REFERENCES currency,
  -- 有效期間：功能幣會隨時間變更（D-26-06），因此是期間化的指派而非單一欄位
  effective_range   daterange NOT NULL,
  -- 批准是必要的：沒有它，「功能幣是誰決定的」在稽核上沒有答案
  approved_by       uuid REFERENCES app_user,
  approved_at       timestamptz,
  created_by        uuid NOT NULL REFERENCES app_user,
  created_at        timestamptz NOT NULL DEFAULT now(),
  content_hash      text,
  CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
  -- INV-22 (a)：同一單位同一時點，每個角色至多一個有效指派。
  -- REPORTING 現在就不允許多值——多值卻沒有選擇規則，等於把「用哪個報告幣」
  -- 留給實作當下猜。日後要第二報告幣時新增 SECONDARY_REPORTING。
  EXCLUDE USING gist (reporting_unit_id WITH =, currency_role WITH =, effective_range WITH &&)
);

CREATE FUNCTION fn_currency_assignment_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_eng uuid;
BEGIN
  SELECT engagement_id INTO v_eng FROM reporting_unit
   WHERE reporting_unit_id = NEW.reporting_unit_id;
  IF v_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：幣別指派的報告單位不屬本案件';
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'CURRENCY_ASSIGNMENT_IMMUTABLE: 已批准的幣別指派不可變更（改期間或幣別須發新指派）';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_currency_assignment
  BEFORE INSERT OR UPDATE ON reporting_unit_currency_assignment
  FOR EACH ROW EXECUTE FUNCTION fn_currency_assignment_guard();

-- ═══ 4　匯率：版本（工作流）＋觀測（資料）═══════════════════════════
CREATE TABLE exchange_rate_version (
  rate_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenant,
  label           text NOT NULL,
  status          text NOT NULL DEFAULT 'DRAFT'
                  CHECK (status IN ('DRAFT','SUBMITTED','REVIEWED','APPROVED')),
  created_by      uuid NOT NULL REFERENCES app_user,
  submitted_by    uuid REFERENCES app_user,
  submitted_at    timestamptz,
  reviewed_by     uuid REFERENCES app_user,
  reviewed_at     timestamptz,
  approved_by     uuid REFERENCES app_user,
  approved_at     timestamptz,
  return_reason   text,
  content_hash    text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((submitted_by IS NULL) = (submitted_at IS NULL)),
  CHECK ((reviewed_by  IS NULL) = (reviewed_at  IS NULL)),
  CHECK ((approved_by  IS NULL) = (approved_at  IS NULL)),
  UNIQUE (tenant_id, label)
);

CREATE TABLE exchange_rate_observation (
  observation_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenant,
  rate_version_id  uuid NOT NULL REFERENCES exchange_rate_version ON DELETE CASCADE,
  from_currency    text NOT NULL REFERENCES currency,
  to_currency      text NOT NULL REFERENCES currency,
  rate_type        text NOT NULL CHECK (rate_type IN ('CLOSING','AVERAGE','HISTORICAL')),
  -- 報價方向唯一：target_amount = source_amount × rate（from → to）
  rate             numeric(18,8) NOT NULL CHECK (rate > 0),
  source           text NOT NULL,
  -- 各 rate_type 的期間語意不同，不能共用一個模糊的 rate_date
  measurement_date date,          -- CLOSING
  coverage_start   date,          -- AVERAGE
  coverage_end     date,          -- AVERAGE
  event_date       date,          -- HISTORICAL
  CHECK (from_currency <> to_currency),
  CHECK (
    (rate_type = 'CLOSING'    AND measurement_date IS NOT NULL
       AND coverage_start IS NULL AND coverage_end IS NULL AND event_date IS NULL)
 OR (rate_type = 'AVERAGE'    AND coverage_start IS NOT NULL AND coverage_end IS NOT NULL
       AND coverage_start <= coverage_end
       AND measurement_date IS NULL AND event_date IS NULL)
 OR (rate_type = 'HISTORICAL' AND event_date IS NOT NULL
       AND measurement_date IS NULL AND coverage_start IS NULL AND coverage_end IS NULL)
  ),
  UNIQUE (rate_version_id, from_currency, to_currency, rate_type,
          measurement_date, coverage_start, coverage_end, event_date)
);

-- 工作流：DRAFT → SUBMITTED → REVIEWED → APPROVED，退回可回 DRAFT。
-- 自然人層 SoD（本切片的嚴格子集，見 BACKLOG 2026-08-11）：
--   submitted_by ≠ reviewed_by  強制——避免一人從提交、覆核一路自簽
--   reviewed_by  = approved_by  允許——兩人事務所必須能運作
CREATE FUNCTION fn_exchange_rate_version_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE legal boolean;
BEGIN
  IF NEW.status = OLD.status THEN
    -- 同狀態的內容修改：只有 DRAFT 可改
    IF OLD.status <> 'DRAFT' THEN
      RAISE EXCEPTION 'RATE_VERSION_FROZEN: 匯率版本於 % 狀態不可修改（改率須發新版本）', OLD.status;
    END IF;
    RETURN NEW;
  END IF;
  legal := (OLD.status, NEW.status) IN (
    ('DRAFT','SUBMITTED'), ('SUBMITTED','REVIEWED'), ('REVIEWED','APPROVED'),
    ('SUBMITTED','DRAFT'), ('REVIEWED','DRAFT'));
  IF NOT legal THEN
    RAISE EXCEPTION 'RATE_VERSION_ILLEGAL_TRANSITION: 匯率版本不得由 % 遷移至 %', OLD.status, NEW.status;
  END IF;
  IF NEW.status = 'SUBMITTED' AND NEW.submitted_by IS NULL THEN
    RAISE EXCEPTION 'RATE_VERSION_SUBMITTER_REQUIRED: 提交必須記錄提交人';
  END IF;
  IF NEW.status = 'REVIEWED' THEN
    IF NEW.reviewed_by IS NULL THEN
      RAISE EXCEPTION 'RATE_VERSION_REVIEWER_REQUIRED: 覆核必須記錄覆核人';
    END IF;
    IF NEW.reviewed_by = NEW.submitted_by THEN
      RAISE EXCEPTION 'FX_RATE_SELF_REVIEW_DENIED: 提交人不得覆核自己提交的匯率版本（最低限度的獨立覆核）';
    END IF;
  END IF;
  IF NEW.status = 'APPROVED' AND NEW.approved_by IS NULL THEN
    RAISE EXCEPTION 'RATE_VERSION_APPROVER_REQUIRED: 批准必須記錄批准人';
  END IF;
  -- 覆核事實不可覆寫：一旦寫入，退回也不得抹除（退回只改狀態，理由另記）
  IF OLD.reviewed_at IS NOT NULL AND NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at THEN
    RAISE EXCEPTION 'RATE_VERSION_REVIEW_IMMUTABLE: 覆核事實不可覆寫';
  END IF;
  IF NEW.status = 'DRAFT' AND NEW.return_reason IS NULL THEN
    RAISE EXCEPTION 'RATE_VERSION_RETURN_REASON_REQUIRED: 退回必須填理由';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_exchange_rate_version
  BEFORE UPDATE ON exchange_rate_version
  FOR EACH ROW EXECUTE FUNCTION fn_exchange_rate_version_guard();

-- 觀測列於 SUBMITTED 起凍結；APPROVED 後整版不可變（含不得新增觀測）
CREATE FUNCTION fn_exchange_rate_observation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_status text; v_tenant uuid; v_ver uuid;
BEGIN
  v_ver := COALESCE(NEW.rate_version_id, OLD.rate_version_id);
  SELECT status, tenant_id INTO v_status, v_tenant
    FROM exchange_rate_version WHERE rate_version_id = v_ver;
  IF v_status <> 'DRAFT' THEN
    RAISE EXCEPTION 'RATE_OBSERVATIONS_FROZEN: 匯率版本已 %，觀測列不得增刪改（改率須發新版本）', v_status;
  END IF;
  IF TG_OP <> 'DELETE' AND v_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：觀測與匯率版本不同租戶（INV-18）';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_exchange_rate_observation
  BEFORE INSERT OR UPDATE OR DELETE ON exchange_rate_observation
  FOR EACH ROW EXECUTE FUNCTION fn_exchange_rate_observation_guard();

-- ═══ 5　科目的折算分類 ══════════════════════════════════════════════
-- 現有 balance_behavior = STOCK/FLOW 不足以選方法；即使補 ASSET/LIABILITY/EQUITY
-- 也分不出實收資本、保留盈餘、股利分配與其他權益變動，而這四者處理完全不同。
ALTER TABLE account ADD COLUMN translation_category text
  CHECK (translation_category IN
    ('ASSET','LIABILITY','INCOME','EXPENSE',
     'EQUITY_CONTRIBUTED','EQUITY_RETAINED','EQUITY_DISTRIBUTION','EQUITY_OTHER'));

-- ═══ 6　折算政策版本＋規則＋CTA 落點 ════════════════════════════════
CREATE TABLE translation_policy_version (
  policy_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  engagement_id     uuid NOT NULL REFERENCES client_engagement,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  label             text NOT NULL,
  -- CTA 落點必須被凍結：只知道金額不知道科目，CTA 就出不了報表
  cta_account_id    uuid NOT NULL REFERENCES account,
  cta_coa_id        uuid NOT NULL REFERENCES chart_of_accounts,
  approved_by       uuid REFERENCES app_user,
  approved_at       timestamptz,
  created_by        uuid NOT NULL REFERENCES app_user,
  created_at        timestamptz NOT NULL DEFAULT now(),
  content_hash      text,
  CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
  UNIQUE (engagement_id, reporting_unit_id, label)
);

CREATE TABLE translation_policy_rule (
  policy_rule_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES tenant,
  policy_version_id   uuid NOT NULL REFERENCES translation_policy_version ON DELETE CASCADE,
  translation_category text NOT NULL CHECK (translation_category IN
    ('ASSET','LIABILITY','INCOME','EXPENSE',
     'EQUITY_CONTRIBUTED','EQUITY_RETAINED','EQUITY_DISTRIBUTION','EQUITY_OTHER')),
  -- 方法是資料，不是程式碼分支
  method text NOT NULL CHECK (method IN
    ('CLOSING','AVERAGE','HISTORICAL_BY_LOT','OPENING_TRANSLATED_BALANCE')),
  -- 同一政策版本內，每個分類至多一條規則——重疊在資料層就先擋掉一半
  UNIQUE (policy_version_id, translation_category)
);

CREATE FUNCTION fn_translation_policy_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_coa uuid; v_owner uuid; v_eng uuid;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'TRANSLATION_POLICY_IMMUTABLE: 已批准的折算政策版本不可變更';
  END IF;
  SELECT engagement_id INTO v_eng FROM reporting_unit
   WHERE reporting_unit_id = NEW.reporting_unit_id;
  IF v_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：折算政策的報告單位不屬本案件';
  END IF;
  SELECT coa_id INTO v_coa FROM account WHERE account_id = NEW.cta_account_id;
  IF v_coa IS DISTINCT FROM NEW.cta_coa_id THEN
    RAISE EXCEPTION 'CTA_ACCOUNT_SCOPE_INVALID: CTA 科目不屬於所宣告的科目表';
  END IF;
  -- 實作的 chart_of_accounts 以 engagement_id 表示歸屬（設計書 §26.11 的
  -- owner_scope／owner_id 尚未落地，見 BACKLOG 的 ChartOfAccountsVersion 條目）
  SELECT engagement_id INTO v_owner FROM chart_of_accounts WHERE coa_id = NEW.cta_coa_id;
  IF v_owner IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION 'CTA_ACCOUNT_SCOPE_INVALID: CTA 科目表必須是本案件的集團科目表';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_translation_policy
  BEFORE INSERT OR UPDATE ON translation_policy_version
  FOR EACH ROW EXECUTE FUNCTION fn_translation_policy_guard();

CREATE FUNCTION fn_translation_policy_rule_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_approved timestamptz;
BEGIN
  SELECT approved_at INTO v_approved FROM translation_policy_version
   WHERE policy_version_id = COALESCE(NEW.policy_version_id, OLD.policy_version_id);
  IF v_approved IS NOT NULL THEN
    RAISE EXCEPTION 'TRANSLATION_POLICY_IMMUTABLE: 已批准的政策版本不得增刪改規則';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_translation_policy_rule
  BEFORE INSERT OR UPDATE OR DELETE ON translation_policy_rule
  FOR EACH ROW EXECUTE FUNCTION fn_translation_policy_rule_guard();

-- ═══ 7　權益折算批次：以「集合版本」為批准與凍結單位 ═════════════════
-- 單筆 lot 的版本鏈證明不了「沒有漏掉第三筆出資」——漏掉的那筆根本不存在，
-- 沒有任何版本鏈會指向它。因此批准與凍結的單位是整個 set。
CREATE TABLE equity_translation_lot_set_version (
  set_version_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  engagement_id     uuid NOT NULL REFERENCES client_engagement,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  account_id        uuid NOT NULL REFERENCES account,
  -- 版本方向：新版本向後指向舊版本。用向前的 superseded_by 就得寫進已批准的
  -- 舊列，與「APPROVED 後不可變」直接矛盾。
  series_id         uuid NOT NULL,
  version_no        int  NOT NULL CHECK (version_no >= 1),
  supersedes_set_version_id uuid REFERENCES equity_translation_lot_set_version,
  approved_by       uuid REFERENCES app_user,
  approved_at       timestamptz,
  created_by        uuid NOT NULL REFERENCES app_user,
  created_at        timestamptz NOT NULL DEFAULT now(),
  content_hash      text,
  CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
  CHECK ((version_no = 1) = (supersedes_set_version_id IS NULL)),
  UNIQUE (series_id, version_no)
);
-- 同一 series 的每一版至多被一個後版指向
CREATE UNIQUE INDEX equity_lot_set_supersedes_unique
  ON equity_translation_lot_set_version (supersedes_set_version_id)
  WHERE supersedes_set_version_id IS NOT NULL;

CREATE TABLE equity_translation_lot (
  lot_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenant,
  set_version_id  uuid NOT NULL REFERENCES equity_translation_lot_set_version ON DELETE CASCADE,
  event_date      date NOT NULL,
  functional_amount numeric(20,2) NOT NULL CHECK (functional_amount <> 0),
  exchange_rate_observation_id uuid NOT NULL REFERENCES exchange_rate_observation,
  evidence_ref    text NOT NULL,
  line_no         int NOT NULL,
  UNIQUE (set_version_id, line_no)
);

CREATE FUNCTION fn_equity_lot_set_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_prev_series uuid; v_prev_no int; v_eng uuid;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'EQUITY_LOT_SET_IMMUTABLE: 已批准的權益折算批次集合不可變更（增減出資須發新 set version）';
  END IF;
  SELECT engagement_id INTO v_eng FROM reporting_unit
   WHERE reporting_unit_id = NEW.reporting_unit_id;
  IF v_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：權益折算批次的報告單位不屬本案件';
  END IF;
  IF NEW.supersedes_set_version_id IS NOT NULL THEN
    SELECT series_id, version_no INTO v_prev_series, v_prev_no
      FROM equity_translation_lot_set_version
     WHERE set_version_id = NEW.supersedes_set_version_id;
    IF v_prev_series IS DISTINCT FROM NEW.series_id THEN
      RAISE EXCEPTION 'EQUITY_LOT_SET_SERIES_MISMATCH: 取代的對象必須屬同一版本序列';
    END IF;
    IF v_prev_no <> NEW.version_no - 1 THEN
      RAISE EXCEPTION 'EQUITY_LOT_SET_VERSION_GAP: 新版本必須緊接前一版（v% → v%）', v_prev_no, NEW.version_no;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_equity_lot_set
  BEFORE INSERT OR UPDATE ON equity_translation_lot_set_version
  FOR EACH ROW EXECUTE FUNCTION fn_equity_lot_set_guard();

CREATE FUNCTION fn_equity_lot_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_approved timestamptz; v_rate_type text; v_event date;
BEGIN
  SELECT approved_at INTO v_approved FROM equity_translation_lot_set_version
   WHERE set_version_id = COALESCE(NEW.set_version_id, OLD.set_version_id);
  IF v_approved IS NOT NULL THEN
    RAISE EXCEPTION 'EQUITY_LOT_SET_IMMUTABLE: 已批准的集合不得增刪改 lots';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  SELECT rate_type, event_date INTO v_rate_type, v_event
    FROM exchange_rate_observation WHERE observation_id = NEW.exchange_rate_observation_id;
  IF v_rate_type <> 'HISTORICAL' THEN
    RAISE EXCEPTION 'EQUITY_LOT_RATE_TYPE_INVALID: 權益批次只能引用 HISTORICAL 觀測（引用到 %）', v_rate_type;
  END IF;
  IF v_event IS DISTINCT FROM NEW.event_date THEN
    RAISE EXCEPTION 'EQUITY_LOT_RATE_DATE_MISMATCH: 觀測的 event_date（%）與批次的 event_date（%）不符', v_event, NEW.event_date;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_equity_lot
  BEFORE INSERT OR UPDATE OR DELETE ON equity_translation_lot
  FOR EACH ROW EXECUTE FUNCTION fn_equity_lot_guard();

-- ═══ 8　期初已折算權益餘額（延續橋接的輸入）═════════════════════════
CREATE TABLE equity_opening_translated_balance (
  opening_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  engagement_id     uuid NOT NULL REFERENCES client_engagement,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  account_id        uuid NOT NULL REFERENCES account,
  reporting_currency text NOT NULL REFERENCES currency,
  opening_debit     numeric(20,2) NOT NULL DEFAULT 0 CHECK (opening_debit >= 0),
  opening_credit    numeric(20,2) NOT NULL DEFAULT 0 CHECK (opening_credit >= 0),
  -- 後續期間必須引用前期已鎖定的 run；只有首次導入能用經批准的外部證據。
  -- 否則每期都可以人工填一個數，形式上批准、實際上沒有延續。
  source_kind       text NOT NULL CHECK (source_kind IN ('PRIOR_RUN','FIRST_CONVERSION')),
  source_calculation_run_id uuid REFERENCES calculation_run,
  evidence_ref      text,
  approved_by       uuid REFERENCES app_user,
  approved_at       timestamptz,
  created_by        uuid NOT NULL REFERENCES app_user,
  created_at        timestamptz NOT NULL DEFAULT now(),
  content_hash      text,
  CHECK (NOT (opening_debit > 0 AND opening_credit > 0)),
  CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
  CHECK (
    (source_kind = 'PRIOR_RUN' AND source_calculation_run_id IS NOT NULL AND evidence_ref IS NULL)
 OR (source_kind = 'FIRST_CONVERSION' AND evidence_ref IS NOT NULL
       AND source_calculation_run_id IS NULL)
  ),
  UNIQUE (period_revision_id, account_id)
);

-- PRIOR_RUN 的四項條件：run 為 COMPLETED（CalculationRun 沒有 LOCKED 狀態，
-- 鎖定屬期間）／其 PeriodRevision 為 LOCKED／屬本期的**顯式前期**／單位與科目相同。
CREATE FUNCTION fn_equity_opening_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_run_status text; v_run_rev uuid; v_run_period uuid; v_run_unit uuid;
  v_rev_status text; v_this_period uuid; v_this_unit uuid; v_prev uuid;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'OPENING_BALANCE_IMMUTABLE: 已批准的期初已折算餘額不可變更';
  END IF;
  SELECT rp.reporting_period_id, rp.reporting_unit_id, rp.previous_reporting_period_id
    INTO v_this_period, v_this_unit, v_prev
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = NEW.period_revision_id;
  IF v_this_unit IS DISTINCT FROM NEW.reporting_unit_id THEN
    RAISE EXCEPTION '§24.1A：期初已折算餘額的報告單位與期間不一致';
  END IF;

  -- 形狀（哪個欄位必填）由 CHECK 約束裁決；本觸發器只驗參照語意。
  -- 在這裡搶先報 NOT_CONTINUOUS，會讓「欄位沒填」看起來像「延續斷了」。
  IF NEW.source_kind = 'FIRST_CONVERSION' OR NEW.source_calculation_run_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT cr.status, cr.period_revision_id INTO v_run_status, v_run_rev
    FROM calculation_run cr WHERE cr.calculation_run_id = NEW.source_calculation_run_id;
  IF v_run_status IS DISTINCT FROM 'COMPLETED' THEN
    RAISE EXCEPTION 'FX_OPENING_EQUITY_NOT_CONTINUOUS: 來源 run 的狀態為 %（須為 COMPLETED）', v_run_status;
  END IF;
  SELECT pr.status, rp.reporting_period_id, rp.reporting_unit_id
    INTO v_rev_status, v_run_period, v_run_unit
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = v_run_rev;
  IF v_rev_status IS DISTINCT FROM 'LOCKED' THEN
    RAISE EXCEPTION 'FX_OPENING_EQUITY_NOT_CONTINUOUS: 來源 run 所屬期間修訂的狀態為 %（須為 LOCKED）', v_rev_status;
  END IF;
  IF v_prev IS NULL OR v_run_period IS DISTINCT FROM v_prev THEN
    RAISE EXCEPTION 'FX_OPENING_EQUITY_NOT_CONTINUOUS: 來源 run 不屬本期的顯式前期（前期連結為 %）', v_prev;
  END IF;
  IF v_run_unit IS DISTINCT FROM NEW.reporting_unit_id THEN
    RAISE EXCEPTION 'FX_OPENING_EQUITY_NOT_CONTINUOUS: 來源 run 的報告單位與本期不同';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_equity_opening
  BEFORE INSERT OR UPDATE ON equity_opening_translated_balance
  FOR EACH ROW EXECUTE FUNCTION fn_equity_opening_guard();

-- ═══ 9　CTA：獨立的報告層調整，不冒充一般分錄 ═══════════════════════
-- JournalEntry 的語意是借貸平衡；CTA 是單邊的報告層調整。只記借方的普通分錄
-- 本身不平，硬補貸方對應列又等於憑空造出不存在的科目餘額。
CREATE TABLE translation_adjustment_entry (
  translation_entry_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  engagement_id     uuid NOT NULL REFERENCES client_engagement,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  calculation_run_id uuid NOT NULL REFERENCES calculation_run,
  posting_layer_id  uuid NOT NULL REFERENCES posting_layer,
  -- rule_type 落在分錄上，不落在層上：同一 TRANSLATION_ADJUSTMENT 層同時承載
  -- 實體層 CTA（GROUP_GAAP）與合併層 CTA（CONSOLIDATION）。塞回層上就得拆成
  -- 兩個層，那是代碼驅動約束的變形。
  rule_type         text NOT NULL CHECK (rule_type IN ('GROUP_GAAP','CONSOLIDATION')),
  reporting_currency text NOT NULL REFERENCES currency,
  translation_policy_version_id uuid NOT NULL REFERENCES translation_policy_version,
  exchange_rate_version_id uuid NOT NULL REFERENCES exchange_rate_version,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (calculation_run_id, reporting_unit_id, rule_type)
);

CREATE TABLE translation_adjustment_line (
  translation_line_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  translation_entry_id uuid NOT NULL REFERENCES translation_adjustment_entry ON DELETE CASCADE,
  line_no           int NOT NULL,
  account_id        uuid NOT NULL REFERENCES account,
  -- 報告幣金額
  debit             numeric(20,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
  credit            numeric(20,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  memo              text,
  CHECK (NOT (debit > 0 AND credit > 0)),
  UNIQUE (translation_entry_id, line_no)
);

-- 分層必須是 TRANSLATION_ADJUSTMENT，且該層的 scope 與報告單位型別相符
CREATE FUNCTION fn_translation_entry_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_code text; v_scope text; v_unit_scope text;
BEGIN
  SELECT code, scope_type INTO v_code, v_scope FROM posting_layer
   WHERE layer_id = NEW.posting_layer_id;
  IF v_code <> 'TRANSLATION_ADJUSTMENT' THEN
    RAISE EXCEPTION 'CTA_LAYER_INVALID: 折算調整只能記入 TRANSLATION_ADJUSTMENT 分層（收到 %）', v_code;
  END IF;
  SELECT unit_scope INTO v_unit_scope FROM reporting_unit
   WHERE reporting_unit_id = NEW.reporting_unit_id;
  IF (v_scope = 'ENTITY' AND v_unit_scope <> 'LEGAL_ENTITY')
  OR (v_scope = 'GROUP'  AND v_unit_scope <> 'CONSOLIDATION_GROUP') THEN
    RAISE EXCEPTION 'INV03_SCOPE_MISMATCH: % scope 的分層不得寫入 % 型別的報告單位', v_scope, v_unit_scope;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_translation_entry
  BEFORE INSERT OR UPDATE ON translation_adjustment_entry
  FOR EACH ROW EXECUTE FUNCTION fn_translation_entry_guard();

-- ═══ 10　折算結果：彙總（INV-19）＋計算明細 ═════════════════════════
-- 一個科目可能有多筆歷史來源（實收資本的多次出資），但 INV-19 要求每個
-- (snapshot_line, amount_role) 只有一筆結果。兩者只能靠兩層並存。
CREATE TABLE translation_result (
  translation_result_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  calculation_run_id uuid NOT NULL REFERENCES calculation_run,
  source_snapshot_line_id bigint NOT NULL REFERENCES balance_snapshot_line ON DELETE CASCADE,
  amount_role       text NOT NULL CHECK (amount_role IN ('REPORTING')),
  currency_code     text NOT NULL REFERENCES currency,
  source_debit      numeric(20,2) NOT NULL DEFAULT 0 CHECK (source_debit >= 0),
  source_credit     numeric(20,2) NOT NULL DEFAULT 0 CHECK (source_credit >= 0),
  result_debit      numeric(20,2) NOT NULL DEFAULT 0 CHECK (result_debit >= 0),
  result_credit     numeric(20,2) NOT NULL DEFAULT 0 CHECK (result_credit >= 0),
  translation_policy_rule_id uuid REFERENCES translation_policy_rule,
  CHECK (NOT (source_debit > 0 AND source_credit > 0)),
  CHECK (NOT (result_debit > 0 AND result_credit > 0)),
  -- INV-19：同一 SnapshotLine 下每個 amount_role 至多一筆
  UNIQUE (source_snapshot_line_id, amount_role)
);

CREATE TABLE translation_result_component (
  component_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  translation_result_id uuid NOT NULL REFERENCES translation_result ON DELETE CASCADE,
  line_no           int NOT NULL,
  source_kind       text NOT NULL CHECK (source_kind IN
    ('RATE_TRANSLATION','EQUITY_LOT','OPENING_TRANSLATED_BALANCE','CTA_RESIDUAL')),
  source_ref        text,
  equity_lot_id     uuid REFERENCES equity_translation_lot,
  exchange_rate_observation_id uuid REFERENCES exchange_rate_observation,
  source_debit      numeric(20,2) NOT NULL DEFAULT 0 CHECK (source_debit >= 0),
  source_credit     numeric(20,2) NOT NULL DEFAULT 0 CHECK (source_credit >= 0),
  result_debit      numeric(20,2) NOT NULL DEFAULT 0 CHECK (result_debit >= 0),
  result_credit     numeric(20,2) NOT NULL DEFAULT 0 CHECK (result_credit >= 0),
  -- 匯率觀測的有無由 source_kind 決定，不是可選欄位：
  -- 延續橋接與 CTA 殘差沒有匯率，帶上一個就是在謊稱它們是按率折算的
  CHECK (
    (source_kind IN ('RATE_TRANSLATION','EQUITY_LOT') AND exchange_rate_observation_id IS NOT NULL)
 OR (source_kind IN ('OPENING_TRANSLATED_BALANCE','CTA_RESIDUAL') AND exchange_rate_observation_id IS NULL)
  ),
  CHECK ((source_kind = 'EQUITY_LOT') = (equity_lot_id IS NOT NULL)),
  UNIQUE (translation_result_id, line_no)
);

-- 彙總＝明細合計。彙總先建立、component 後插入，普通 row trigger 在第一筆
-- component 時必然不平，因此必須 DEFERRABLE INITIALLY DEFERRED，在交易結束前檢查。
-- 不得依賴應用層「記得最後再檢查一次」——忘記檢查與檢查失敗看起來一模一樣，
-- 而前者會留下無法追溯的金額。
CREATE FUNCTION fn_translation_result_sum_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r record; c record;
BEGIN
  SELECT * INTO r FROM translation_result
   WHERE translation_result_id = COALESCE(NEW.translation_result_id, NEW.translation_result_id);
  IF NOT FOUND THEN RETURN NULL; END IF;      -- 彙總已被刪除（CASCADE）
  SELECT COALESCE(sum(source_debit),0) sd, COALESCE(sum(source_credit),0) sc,
         COALESCE(sum(result_debit),0) rd, COALESCE(sum(result_credit),0) rc,
         count(*) n
    INTO c FROM translation_result_component
   WHERE translation_result_id = r.translation_result_id;
  IF c.n = 0 THEN
    RAISE EXCEPTION 'TRANSLATION_RESULT_NO_COMPONENT: 折算結果必須至少有一筆計算明細（否則「彙總怎麼來的」無法回答）';
  END IF;
  IF c.sd <> r.source_debit OR c.sc <> r.source_credit
  OR c.rd <> r.result_debit OR c.rc <> r.result_credit THEN
    RAISE EXCEPTION 'TRANSLATION_COMPONENT_SUM_MISMATCH: 明細合計（來源 %/%、結果 %/%）與彙總（%/%、%/%）不符——差額就是無法追溯的金額',
      c.sd, c.sc, c.rd, c.rc, r.source_debit, r.source_credit, r.result_debit, r.result_credit;
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_translation_result_sum
  AFTER INSERT OR UPDATE ON translation_result_component
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION fn_translation_result_sum_guard();

-- 彙總本身也要被檢查：只建彙總不建明細同樣不可接受
CREATE FUNCTION fn_translation_result_has_component() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c record; r record;
BEGIN
  SELECT * INTO r FROM translation_result WHERE translation_result_id = NEW.translation_result_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT COALESCE(sum(source_debit),0) sd, COALESCE(sum(source_credit),0) sc,
         COALESCE(sum(result_debit),0) rd, COALESCE(sum(result_credit),0) rc,
         count(*) n
    INTO c FROM translation_result_component
   WHERE translation_result_id = r.translation_result_id;
  IF c.n = 0 THEN
    RAISE EXCEPTION 'TRANSLATION_RESULT_NO_COMPONENT: 折算結果必須至少有一筆計算明細';
  END IF;
  IF c.sd <> r.source_debit OR c.sc <> r.source_credit
  OR c.rd <> r.result_debit OR c.rc <> r.result_credit THEN
    RAISE EXCEPTION 'TRANSLATION_COMPONENT_SUM_MISMATCH: 明細合計與彙總不符';
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_translation_result_complete
  AFTER INSERT OR UPDATE ON translation_result
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION fn_translation_result_has_component();

-- ═══ 11　既有結構的擴充 ════════════════════════════════════════════
-- calculation_scope 在 manifest 上，不在 calculation_run
ALTER TABLE calculation_input_manifest DROP CONSTRAINT calculation_input_manifest_calculation_scope_check;
ALTER TABLE calculation_input_manifest ADD CONSTRAINT calculation_input_manifest_calculation_scope_check
  CHECK (calculation_scope IN ('NO_FX','FX_TRANSLATION'));

-- manifest 新條目。account_translation_classification 是**獨立條目**，
-- 不得擴充既有 CHART_OF_ACCOUNTS 條目的 canonical 內容——那會改變既有 NO_FX
-- manifest 的 hash，使里程碑 2 的既有 run 全部無法重演。
ALTER TABLE calculation_manifest_entry DROP CONSTRAINT calculation_manifest_entry_object_type_check;
ALTER TABLE calculation_manifest_entry ADD CONSTRAINT calculation_manifest_entry_object_type_check
  CHECK (object_type IN (
    'SCOPE','SOURCE_TB','MAPPING_RULE','ADJUSTMENT','CHART_OF_ACCOUNTS','BASIS_COMPOSITION',
    'CURRENCY_DEFINITION','EXCHANGE_RATE_VERSION','TRANSLATION_POLICY_VERSION',
    'CURRENCY_ASSIGNMENT','EQUITY_TRANSLATION_LOT_SET_VERSION',
    'EQUITY_OPENING_TRANSLATED_BALANCE','ACCOUNT_TRANSLATION_CLASSIFICATION'));

-- CTA 的 SnapshotLine 是空殼（debit/credit 皆 0），只提供科目與層的落點；
-- 真正的報告幣金額在 TranslationResult。SnapshotLine 的 debit/credit 是功能幣
-- 且沒有 currency 欄，把 CNY 寫進去會在同一表混入兩種幣別。
ALTER TABLE balance_snapshot_line DROP CONSTRAINT balance_snapshot_line_posting_layer_check;
ALTER TABLE balance_snapshot_line ADD CONSTRAINT balance_snapshot_line_posting_layer_check
  CHECK (posting_layer IN ('SOURCE_TB','ADJUSTMENT','TRANSLATION_ADJUSTMENT'));

-- ═══ 12　RLS 與權限 ════════════════════════════════════════════════
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'reporting_unit_currency_assignment','exchange_rate_version','exchange_rate_observation',
    'translation_policy_version','translation_policy_rule',
    'equity_translation_lot_set_version','equity_translation_lot',
    'equity_opening_translated_balance',
    'translation_adjustment_entry','translation_adjustment_line',
    'translation_result','translation_result_component']
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant())', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO app_runtime', t);
  END LOOP;
END $$;

-- 折算結果與 CTA 只能由折算函式在同一交易內產生。
-- 人手寫得出來的 CTA 不是算出來的 CTA。
REVOKE INSERT, UPDATE, DELETE ON translation_adjustment_entry FROM app_runtime;
REVOKE INSERT, UPDATE, DELETE ON translation_adjustment_line FROM app_runtime;
REVOKE INSERT, UPDATE, DELETE ON translation_result FROM app_runtime;
REVOKE INSERT, UPDATE, DELETE ON translation_result_component FROM app_runtime;
