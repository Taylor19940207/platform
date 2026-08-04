-- 0007 Adjustment 完整生命週期（SLICE-M2-02A）
-- 契約：docs/slices/SLICE-M2-02A_調整生命週期.md；退回版本語意見 docs/adr/ADR-M2-001.md
--
-- 三個守衛掛在三個不同的狀態遷移，不得合併成單一「建立者不得批准」判斷：
--   DRAFTING         → PENDING_REVIEW   G-08 四項證據齊備（§25.13）
--   PENDING_REVIEW   → PENDING_APPROVAL G-04／SOD-01：prepared_by ≠ reviewed_by（無豁免）
--   PENDING_APPROVAL → APPROVED         G-05／SOD-02：reviewed_by ≠ approved_by
--                                       AC-WFL-001 ：prepared_by ≠ approved_by（手冊 §849）
--
-- AC-WFL-001 推導不出來：SOD-01 ∧ SOD-02 同時成立時仍允許「甲編製→乙覆核→甲批准」。
-- 依 GOVERNANCE 權威順序（手冊 v1.2 > 設計書 v1.1）獨立落實，不併入 SOD-02。
--
-- 0006 的教訓沿用：SOD 比較的左值一律 NOT NULL ＋ 不可變更——
-- NULL 會使比較永遠不成立（NULL = x → NULL）等於可繞過；改寫比較基準是同一個洞的第二條路。

CREATE TYPE adjustment_status AS ENUM
  ('DRAFTING','PENDING_REVIEW','PENDING_APPROVAL','APPROVED');

-- RETURNED 不是持久狀態：§25.12 的 `RETURNED → DRAFTING` 是同一次遷移的表達。
-- 退回本身以 adjustment_version_snapshot.milestone='RETURNED' 永久保存（ADR-M2-001）。
CREATE TYPE adjustment_milestone AS ENUM
  ('SUBMITTED','RETURNED','REVIEWED','APPROVED');

CREATE TABLE adjustment (
  adjustment_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  engagement_id     uuid NOT NULL REFERENCES client_engagement,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  basis             text NOT NULL DEFAULT 'GROUP_GAAP' CHECK (basis IN ('GROUP_GAAP')),
  -- 本切片只接受 MAJOR：不實作重要性分類引擎，因此全部走完整三段式（SOD-03 降級未實作）
  materiality       text NOT NULL DEFAULT 'MAJOR' CHECK (materiality IN ('MAJOR')),
  status            adjustment_status NOT NULL DEFAULT 'DRAFTING',
  title             text NOT NULL,
  -- G-08 四項必要證據（§25.13 L930）：缺一不可
  legal_basis       text,          -- 法源／政策依據
  evidence_ref      text,          -- 附件／支持文件
  judgment_reason   text,          -- 判斷理由
  language_tag      text,          -- 語言標籤
  -- 自然人（實例級 SoD 的判定對象；角色切換無效）
  prepared_by       uuid NOT NULL REFERENCES app_user,
  reviewed_by       uuid REFERENCES app_user,
  approved_by       uuid REFERENCES app_user,
  prepared_at       timestamptz NOT NULL DEFAULT now(),
  reviewed_at       timestamptz,
  approved_at       timestamptz,
  -- §26.9 三層版本語意：object_version 併發控制（不可稽核）；business_version 里程碑鏈
  object_version    int NOT NULL DEFAULT 1,
  business_version  int NOT NULL DEFAULT 1,
  -- 控制判定（§25.9）。02A 不寫 delivery_quality——該欄屬 DeliveryRecord，本切片不存在該物件。
  output_capability text CHECK (output_capability IN ('NONE','PREVIEW','OFFICIAL')),
  control_reasons   jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX adjustment_eng_idx ON adjustment (engagement_id, period_revision_id);

CREATE TABLE adjustment_line (
  adjustment_line_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenant,
  adjustment_id   uuid NOT NULL REFERENCES adjustment ON DELETE CASCADE,
  line_no         int  NOT NULL,
  target_account_id uuid NOT NULL REFERENCES account,
  debit           numeric(20,2) NOT NULL DEFAULT 0,
  credit          numeric(20,2) NOT NULL DEFAULT 0,
  memo            text,
  CHECK (debit >= 0 AND credit >= 0),
  CHECK (NOT (debit > 0 AND credit > 0)),
  UNIQUE (adjustment_id, line_no)
);

-- business version 里程碑快照：不可變。退回、提交、覆核、批准各留一節點（ADR-M2-001）。
CREATE TABLE adjustment_version_snapshot (
  snapshot_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenant,
  adjustment_id    uuid NOT NULL REFERENCES adjustment ON DELETE CASCADE,
  business_version int  NOT NULL,
  milestone        adjustment_milestone NOT NULL,
  actor_id         uuid NOT NULL REFERENCES app_user,
  acting_role      role_code NOT NULL,
  reason_category  text,          -- 退回必填（§25.12「退回理由分類」）
  reason_note      text,
  content          jsonb NOT NULL,   -- 當時的表頭與明細內容
  content_sha256   text NOT NULL,
  occurred_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (adjustment_id, business_version)
);
CREATE TRIGGER trg_avs_immutable
  BEFORE UPDATE OR DELETE ON adjustment_version_snapshot
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

-- ── 正式事實：只在 APPROVED 後物化（§26 L1078） ──────────────
CREATE TABLE journal_entry (
  entry_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenant,
  engagement_id   uuid NOT NULL REFERENCES client_engagement,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  adjustment_id   uuid NOT NULL REFERENCES adjustment,
  business_version int NOT NULL,
  entry_date      date NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (adjustment_id, business_version)
);
CREATE TRIGGER trg_je_immutable
  BEFORE UPDATE OR DELETE ON journal_entry
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

CREATE TABLE journal_line (
  journal_line_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id       uuid NOT NULL REFERENCES tenant,
  entry_id        uuid NOT NULL REFERENCES journal_entry,
  line_no         int  NOT NULL,
  account_id      uuid NOT NULL REFERENCES account,
  debit           numeric(20,2) NOT NULL DEFAULT 0,
  credit          numeric(20,2) NOT NULL DEFAULT 0,
  CHECK (debit >= 0 AND credit >= 0)
);
CREATE TRIGGER trg_jl_immutable
  BEFORE UPDATE OR DELETE ON journal_line
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

CREATE INDEX journal_line_entry_idx ON journal_line (entry_id);

-- ── 借貸平衡與歸屬（供守衛與應用層共用） ─────────────────────
CREATE FUNCTION fn_adjustment_imbalance(p_adj uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT COALESCE(SUM(debit) - SUM(credit), 0) FROM adjustment_line WHERE adjustment_id = p_adj
$$;

-- ── 主守衛：狀態遷移 × G-08 × SOD-01 × SOD-02 × AC-WFL-001 ──
CREATE FUNCTION fn_adjustment_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  legal boolean;
  n_lines int;
BEGIN
  -- prepared_by 是兩個 SoD 比較的基準，不得被改寫（0006 的同一個洞）
  IF NEW.prepared_by IS DISTINCT FROM OLD.prepared_by THEN
    RAISE EXCEPTION '編製人（prepared_by）不可變更——SoD 比較的基準不得被改寫';
  END IF;

  -- 已批准調整不可改寫；變更＝新增 business version（切片驗收 12）
  IF OLD.status = 'APPROVED' THEN
    RAISE EXCEPTION '已批准調整（%）不可修改，變更請建立新的 business version', OLD.adjustment_id;
  END IF;

  IF OLD.status = NEW.status THEN
    NEW.updated_at := now();
    RETURN NEW;                              -- 草稿編輯：由應用層遞增 object_version
  END IF;

  legal := CASE OLD.status
    WHEN 'DRAFTING'         THEN NEW.status = 'PENDING_REVIEW'
    WHEN 'PENDING_REVIEW'   THEN NEW.status IN ('PENDING_APPROVAL','DRAFTING')
    WHEN 'PENDING_APPROVAL' THEN NEW.status IN ('APPROVED','DRAFTING')
    ELSE false
  END;
  IF NOT legal THEN
    RAISE EXCEPTION '非法狀態遷移 % → %（Adjustment %）——不得跳關',
      OLD.status, NEW.status, OLD.adjustment_id;
  END IF;

  -- G-08（§25.13）：四項必要證據缺一不可，掛 DRAFTING → PENDING_REVIEW 與 → APPROVED
  IF NEW.status IN ('PENDING_REVIEW','APPROVED') THEN
    IF COALESCE(NEW.legal_basis, '')     = '' OR COALESCE(NEW.evidence_ref, '')  = ''
    OR COALESCE(NEW.judgment_reason, '') = '' OR COALESCE(NEW.language_tag, '')  = '' THEN
      RAISE EXCEPTION 'G-08：必要證據未齊（法源／政策、附件、判斷理由、語言標籤缺一不可）';
    END IF;
  END IF;

  -- 送覆核前必須是一筆成立的分錄：至少兩列且借貸平衡
  IF NEW.status = 'PENDING_REVIEW' THEN
    SELECT count(*) INTO n_lines FROM adjustment_line WHERE adjustment_id = NEW.adjustment_id;
    IF n_lines < 2 THEN
      RAISE EXCEPTION '調整分錄至少需兩列';
    END IF;
    IF fn_adjustment_imbalance(NEW.adjustment_id) <> 0 THEN
      RAISE EXCEPTION '借貸不平衡（差額 %），不得送覆核',
        fn_adjustment_imbalance(NEW.adjustment_id);
    END IF;
  END IF;

  -- G-04／SOD-01：編製人不得覆核自己編製的調整。無豁免。
  IF NEW.status = 'PENDING_APPROVAL' THEN
    IF NEW.reviewed_by IS NULL THEN
      RAISE EXCEPTION 'G-04／SOD-01：覆核必須記錄覆核人';
    END IF;
    IF NEW.reviewed_by = NEW.prepared_by THEN
      RAISE EXCEPTION 'G-04／SOD-01：編製人（%）不得覆核自己編製的調整（自然人判定，角色切換無效）',
        NEW.prepared_by;
    END IF;
  END IF;

  IF NEW.status = 'APPROVED' THEN
    IF NEW.approved_by IS NULL THEN
      RAISE EXCEPTION '批准必須記錄批准人';
    END IF;
    IF NEW.reviewed_by IS NULL THEN
      RAISE EXCEPTION '批准前必須完成覆核';
    END IF;
    -- G-05／SOD-02：重大調整覆核人不得兼批准人
    IF NEW.approved_by = NEW.reviewed_by THEN
      RAISE EXCEPTION 'G-05／SOD-02：重大調整的覆核人（%）不得兼任批准人', NEW.reviewed_by;
    END IF;
    -- AC-WFL-001（手冊 §849）：編製人不得批准自己的重大調整。
    -- 與 SOD-02 是兩條獨立控制——甲編製→乙覆核→甲批准同時滿足 SOD-01 與 SOD-02。
    IF NEW.approved_by = NEW.prepared_by THEN
      RAISE EXCEPTION 'AC-WFL-001：編製人（%）不得批准自己編製的重大調整，與當下角色無關',
        NEW.prepared_by;
    END IF;
  END IF;

  -- 退回：從 PENDING_APPROVAL 退回時既有覆核失效（§25.12 L911）
  IF NEW.status = 'DRAFTING' AND OLD.status = 'PENDING_APPROVAL' THEN
    IF NEW.reviewed_by IS NOT NULL OR NEW.reviewed_at IS NOT NULL THEN
      RAISE EXCEPTION '從 PENDING_APPROVAL 退回時既有覆核必須失效（reviewed_by／reviewed_at 須清空）';
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE TRIGGER trg_adjustment_guard
  BEFORE UPDATE ON adjustment
  FOR EACH ROW EXECUTE FUNCTION fn_adjustment_guard();

-- 已批准調整不可刪除
CREATE FUNCTION fn_adjustment_no_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'APPROVED' THEN
    RAISE EXCEPTION '已批准調整（%）不可刪除', OLD.adjustment_id;
  END IF;
  RETURN OLD;
END $$;

CREATE TRIGGER trg_adjustment_no_delete
  BEFORE DELETE ON adjustment
  FOR EACH ROW EXECUTE FUNCTION fn_adjustment_no_delete();

-- ── 明細：離開 DRAFTING 後即凍結；目標科目須屬同一案件（§24.1A） ──
CREATE FUNCTION fn_adjustment_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_status adjustment_status; v_eng uuid; v_tenant uuid;
  v_acc_eng uuid; v_acc_tenant uuid; v_adj uuid;
BEGIN
  v_adj := CASE TG_OP WHEN 'DELETE' THEN OLD.adjustment_id ELSE NEW.adjustment_id END;
  SELECT status, engagement_id, tenant_id INTO v_status, v_eng, v_tenant
    FROM adjustment WHERE adjustment_id = v_adj;
  IF v_status IS DISTINCT FROM 'DRAFTING' THEN
    RAISE EXCEPTION '調整已離開草稿階段（%），明細不可再變更', v_status;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;

  SELECT c.engagement_id, c.tenant_id INTO v_acc_eng, v_acc_tenant
    FROM account a JOIN chart_of_accounts c ON c.coa_id = a.coa_id
   WHERE a.account_id = NEW.target_account_id;
  IF v_acc_eng IS NULL OR v_acc_eng <> v_eng OR v_acc_tenant <> v_tenant THEN
    RAISE EXCEPTION '歸屬違規（§24.1A）：調整明細的集團科目不屬於本案件的科目表';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_adjustment_line_guard
  BEFORE INSERT OR UPDATE OR DELETE ON adjustment_line
  FOR EACH ROW EXECUTE FUNCTION fn_adjustment_line_guard();

-- ── 物化守衛：JournalEntry 只在 Adjustment 已 APPROVED 時才允許寫入 ──
-- 「批准前 JournalLine 為零」在 DB 層是硬條件，不倚賴應用層自律。
CREATE FUNCTION fn_journal_entry_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_status adjustment_status; v_bv int;
BEGIN
  SELECT status, business_version INTO v_status, v_bv
    FROM adjustment WHERE adjustment_id = NEW.adjustment_id;
  IF v_status IS DISTINCT FROM 'APPROVED' THEN
    RAISE EXCEPTION '正式事實只在 APPROVED 後物化：調整 % 目前為 %',
      NEW.adjustment_id, COALESCE(v_status::text, '不存在');
  END IF;
  IF NEW.business_version <> v_bv THEN
    RAISE EXCEPTION '物化的 business_version（%）須與調整當下版本（%）一致',
      NEW.business_version, v_bv;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_journal_entry_guard
  BEFORE INSERT ON journal_entry
  FOR EACH ROW EXECUTE FUNCTION fn_journal_entry_guard();

-- ── RLS（§24.9／INV-18）：新表一律納入租戶隔離 ──────────────
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'adjustment','adjustment_line','adjustment_version_snapshot',
    'journal_entry','journal_line'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant())', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO app_runtime', t);
  END LOOP;
END $$;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_runtime;
