-- 0042 現金流支持資料：角色工作流函式與父鏈（SLICE-M3-04 第二段 2a）
--
-- 0039～0041 交付了模型與結構守衛，但**十一張表沒有任何父鏈查證**：
-- 政策、分類集合、映射、例外都可以宣告 T1 的 tenant_id 卻引用 T2 的
-- engagement／reporting_unit——RLS 只看列上的 tenant_id，普通外鍵不管父物件屬誰
-- （0032 §2 的同一個洞）。同時 0039 只授予 app_runtime `SELECT`，
-- 因此**建立與批准都還沒有入口**。
--
-- 本檔補這兩件事，範圍嚴格限於「角色工作流」：
--   1. 十一張表的父鏈與版本鏈守衛（trigger，最後防線）；
--   2. 七組角色工作流函式（SECURITY DEFINER，唯一寫入入口）；
--   3. `CashFlowZeroActivityAttestation`：零活動的 R2 → R3 兩段流程；
--   4. 映射的覆核、SoD、生效區間重疊與**靜態**粒度相容；
--   5. Coverage 的「有效結論」父鏈。
--
-- **本檔不做**：CalculationRun 的現金流 scope、Manifest、CashFlowSupportLine、
-- K1～K4、replay、完整度判定，以及依賴**實際 DataCoverage** 的粒度判定——
-- 後者是 run 級判定，屬 2b。
--
-- 三條在本檔沿用而非重新發明的原則：
--   * **權限是邊界，函式是流程**（0032）：批准欄不靠 GUC 保護，靠 app_runtime
--     連 INSERT 通道都沒有。
--   * **角色一律案件層逐動作**（§26.3／0029）：`fn_assert_engagement_role`
--     嚴格相等，租戶層指派不得隱式取得本案件權限。
--   * **守衛未實作即 fail closed**（0023）：`DATA_PRESENT` 的系統衍生入口屬 2b，
--     在它落地前任何寫入一律拒絕。

-- ═══ 0　共用：租戶脈絡 ＋ 案件層角色 ═══════════════════════════════
-- 每支工作流函式的第一件事。分開寫是為了讓拒絕理由分得出
-- 「租戶不對」與「角色不足」——稽核軌跡才答得出缺的是哪一個。
CREATE FUNCTION fn_cf_assert_actor(
  p_actor uuid, p_role text, p_tenant uuid, p_engagement uuid
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_tenant IS DISTINCT FROM current_tenant() THEN
    RAISE EXCEPTION 'CROSS_TENANT_DENIED: 物件不屬於目前租戶';
  END IF;
  PERFORM fn_assert_engagement_role(p_actor, p_role, p_tenant, p_engagement);
END $$;

-- 版本鏈：同一 series、緊接前一版、同租戶。分叉由 0039 的部分唯一索引擋。
CREATE FUNCTION fn_cf_assert_chain(
  p_kind text, p_tenant uuid, p_series uuid, p_version_no int,
  p_prev_tenant uuid, p_prev_series uuid, p_prev_version_no int
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_prev_series IS NULL THEN
    RAISE EXCEPTION 'CFS_CHAIN_PREDECESSOR_NOT_FOUND: % 取代的版本不存在', p_kind;
  END IF;
  IF p_prev_tenant IS DISTINCT FROM p_tenant THEN
    RAISE EXCEPTION '歸屬違規：% 取代的版本屬於其他租戶（INV-18）', p_kind;
  END IF;
  IF p_prev_series IS DISTINCT FROM p_series THEN
    RAISE EXCEPTION 'CFS_CHAIN_SERIES_MISMATCH: % 取代的對象必須屬同一版本序列', p_kind;
  END IF;
  IF p_prev_version_no <> p_version_no - 1 THEN
    RAISE EXCEPTION 'CFS_CHAIN_VERSION_GAP: % 的新版本必須緊接前一版（v% → v%）',
      p_kind, p_prev_version_no, p_version_no;
  END IF;
END $$;

-- ═══ 1　分類集合：父鏈、版本鏈、批准後不可變 ═══════════════════════
CREATE FUNCTION fn_cf_class_set_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p record;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.approved_at IS NOT NULL THEN
      RAISE EXCEPTION 'CFS_CLASS_SET_IMMUTABLE: 已批准的分類集合不可刪除';
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_CLASS_SET_IMMUTABLE: 已批准的分類集合不可變更（改分類須發新集合版本）';
  END IF;
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id);
  IF TG_OP = 'INSERT' AND NEW.supersedes_set_version_id IS NOT NULL THEN
    SELECT tenant_id, series_id, version_no INTO p FROM cash_flow_class_set_version
     WHERE class_set_version_id = NEW.supersedes_set_version_id;
    PERFORM fn_cf_assert_chain('分類集合', NEW.tenant_id, NEW.series_id, NEW.version_no,
                               p.tenant_id, p.series_id, p.version_no);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cf_class_set BEFORE INSERT OR UPDATE OR DELETE
  ON cash_flow_class_set_version FOR EACH ROW EXECUTE FUNCTION fn_cf_class_set_guard();

-- 分類與現金科目範圍：集合是批准單位，批准後不得增刪改任何成員。
-- 單獨新增一個分類到已批准集合，等於在不發新版本的情況下改變口徑。
CREATE FUNCTION fn_cf_class_member_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s record; v_row record;
BEGIN
  v_row := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  SELECT tenant_id, engagement_id, approved_at INTO s FROM cash_flow_class_set_version
   WHERE class_set_version_id = v_row.class_set_version_id;
  IF s.tenant_id IS NULL THEN
    -- 集合本身已被刪除＝ ON DELETE CASCADE 正在收尾（未批准的集合才刪得掉）
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'CFS_CLASS_SET_NOT_FOUND: 分類集合不存在';
  END IF;
  IF s.tenant_id IS DISTINCT FROM v_row.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：成員與分類集合不同租戶（INV-18）';
  END IF;
  IF s.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_CLASS_SET_IMMUTABLE: 已批准的分類集合不可 % 成員（更正請發新集合版本）', TG_OP;
  END IF;
  IF TG_OP <> 'DELETE' AND TG_TABLE_NAME = 'cash_flow_cash_account_membership' THEN
    PERFORM fn_assert_parent_tenant(NEW.tenant_id, s.engagement_id, NULL, NEW.account_id);
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cf_class BEFORE INSERT OR UPDATE OR DELETE
  ON cash_flow_class FOR EACH ROW EXECUTE FUNCTION fn_cf_class_member_guard();
CREATE TRIGGER trg_cf_cash_membership BEFORE INSERT OR UPDATE OR DELETE
  ON cash_flow_cash_account_membership FOR EACH ROW EXECUTE FUNCTION fn_cf_class_member_guard();

-- ═══ 2　政策版本：父鏈、版本鏈、批准後不可變 ═══════════════════════
CREATE FUNCTION fn_cf_policy_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p record; s record;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.approved_at IS NOT NULL THEN
      RAISE EXCEPTION 'CFS_POLICY_IMMUTABLE: 已批准的政策版本不可刪除';
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_POLICY_IMMUTABLE: 已批准的政策版本不可變更（改方法或粒度須發新版本）';
  END IF;
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id, NEW.reporting_unit_id);
  SELECT tenant_id, engagement_id INTO s FROM cash_flow_class_set_version
   WHERE class_set_version_id = NEW.class_set_version_id;
  IF s.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：引用的分類集合屬於其他租戶（INV-18）';
  END IF;
  IF s.engagement_id IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：引用的分類集合不屬本案件';
  END IF;
  IF TG_OP = 'INSERT' AND NEW.supersedes_policy_version_id IS NOT NULL THEN
    SELECT tenant_id, series_id, version_no INTO p FROM cash_flow_policy_version
     WHERE policy_version_id = NEW.supersedes_policy_version_id;
    PERFORM fn_cf_assert_chain('政策版本', NEW.tenant_id, NEW.series_id, NEW.version_no,
                               p.tenant_id, p.series_id, p.version_no);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cf_policy BEFORE INSERT OR UPDATE OR DELETE
  ON cash_flow_policy_version FOR EACH ROW EXECUTE FUNCTION fn_cf_policy_guard();

-- ═══ 3　映射版本：R2 建立 → R3 覆核 → R4 批准 ═══════════════════════
ALTER TABLE cash_flow_mapping_version
  ADD COLUMN reviewed_by uuid REFERENCES app_user,
  ADD COLUMN reviewed_at timestamptz;
ALTER TABLE cash_flow_mapping_version
  ADD CONSTRAINT cf_mapping_reviewed_pair_ck CHECK ((reviewed_by IS NULL) = (reviewed_at IS NULL)),
  -- 未覆核就批准＝覆核這一段從來沒發生過
  ADD CONSTRAINT cf_mapping_approve_after_review_ck
    CHECK (approved_at IS NULL OR reviewed_at IS NOT NULL);

CREATE FUNCTION fn_cf_mapping_version_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p record; pol record;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.approved_at IS NOT NULL THEN
      RAISE EXCEPTION 'CFS_MAPPING_IMMUTABLE: 已批准的映射版本不可刪除';
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF OLD.approved_at IS NOT NULL THEN
      RAISE EXCEPTION 'CFS_MAPPING_IMMUTABLE: 已批准的映射版本不可變更（改規則須發新版本）';
    END IF;
    -- 沿用 0005 的既有 Mapping SoD：自然人判定，角色切換無效。
    -- 不另造新的互斥規則（覆核人是否可兼批准，沿用既有實例級政策）。
    IF NEW.approved_by IS NOT NULL AND NEW.approved_by = OLD.created_by THEN
      RAISE EXCEPTION 'SOD：映射建立者不得批准自己建立的版本（自然人判定，角色切換無效）';
    END IF;
  END IF;
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id);
  SELECT tenant_id, engagement_id INTO pol FROM cash_flow_policy_version
   WHERE policy_version_id = NEW.policy_version_id;
  IF pol.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：引用的政策版本屬於其他租戶（INV-18）';
  END IF;
  IF pol.engagement_id IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：引用的政策版本不屬本案件';
  END IF;
  IF TG_OP = 'INSERT' AND NEW.supersedes_mapping_version_id IS NOT NULL THEN
    SELECT tenant_id, series_id, version_no INTO p FROM cash_flow_mapping_version
     WHERE mapping_version_id = NEW.supersedes_mapping_version_id;
    PERFORM fn_cf_assert_chain('映射版本', NEW.tenant_id, NEW.series_id, NEW.version_no,
                               p.tenant_id, p.series_id, p.version_no);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cf_mapping_version BEFORE INSERT OR UPDATE OR DELETE
  ON cash_flow_mapping_version FOR EACH ROW EXECUTE FUNCTION fn_cf_mapping_version_guard();

-- 規則：分類必須屬政策綁定的集合；**靜態**粒度相容；同來源生效區間不得重疊。
CREATE FUNCTION fn_cf_mapping_rule_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v record; pol record; cls record; v_t uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    SELECT reviewed_at, approved_at INTO v FROM cash_flow_mapping_version
     WHERE mapping_version_id = OLD.mapping_version_id;
    IF v.reviewed_at IS NULL THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'CFS_MAPPING_LOCKED: 已覆核或已批准的映射版本不可刪除規則';
  END IF;
  SELECT tenant_id, engagement_id, policy_version_id, reviewed_at, approved_at INTO v
    FROM cash_flow_mapping_version WHERE mapping_version_id = NEW.mapping_version_id;
  IF v.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：映射規則與其版本不同租戶（INV-18）';
  END IF;
  -- 覆核後才改內容，等於覆核的不是被批准的那一份
  IF v.reviewed_at IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_MAPPING_LOCKED: 映射版本已覆核（或已批准），不得再增修規則';
  END IF;

  SELECT tenant_id, engagement_id, class_set_version_id, required_granularity INTO pol
    FROM cash_flow_policy_version WHERE policy_version_id = v.policy_version_id;
  SELECT tenant_id, class_set_version_id INTO cls
    FROM cash_flow_class WHERE cash_flow_class_id = NEW.cash_flow_class_id;
  IF cls.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：引用的現金流分類屬於其他租戶（INV-18）';
  END IF;
  IF cls.class_set_version_id IS DISTINCT FROM pol.class_set_version_id THEN
    RAISE EXCEPTION 'CFS_MAPPING_CLASS_NOT_IN_SET: 分類不屬政策所綁定的分類集合';
  END IF;

  -- **靜態**粒度相容（唯一實作 fn_granularity_satisfies）：
  -- 規則的 source_kind 對應粒度必須滿足政策的最低粒度。
  -- 「實際 DataCoverage 是否足夠」是 run 級完整度判定，屬 2b。
  IF NOT fn_granularity_satisfies(fn_source_kind_granularity(NEW.source_kind),
                                  pol.required_granularity) THEN
    RAISE EXCEPTION 'CFS_MAPPING_GRANULARITY_INSUFFICIENT: 規則的 %（粒度 %）不滿足政策要求的最低粒度 %',
      NEW.source_kind, fn_source_kind_granularity(NEW.source_kind), pol.required_granularity;
  END IF;

  IF NEW.account_id IS NOT NULL THEN
    PERFORM fn_assert_parent_tenant(NEW.tenant_id, v.engagement_id, NULL, NEW.account_id);
  END IF;
  IF NEW.source_ledger_line_id IS NOT NULL THEN
    SELECT tenant_id INTO v_t FROM source_ledger_line
     WHERE source_ledger_line_id = NEW.source_ledger_line_id;
    IF v_t IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION '歸屬違規：引用的來源列屬於其他租戶（INV-18）';
    END IF;
  END IF;
  IF NEW.source_document_id IS NOT NULL THEN
    SELECT tenant_id INTO v_t FROM source_document
     WHERE source_document_id = NEW.source_document_id;
    IF v_t IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION '歸屬違規：引用的來源文件屬於其他租戶（INV-18）';
    END IF;
  END IF;
  IF NEW.effective_from IS NOT NULL AND NEW.effective_to IS NOT NULL
     AND NEW.effective_to < NEW.effective_from THEN
    RAISE EXCEPTION 'CFS_MAPPING_EFFECTIVE_RANGE_INVALID: 生效迄日早於起日';
  END IF;
  -- 一對一：同一來源在同一生效期間內至多一條規則（NULL 邊界＝無限）
  IF EXISTS (
    SELECT 1 FROM cash_flow_mapping_rule r
     WHERE r.mapping_version_id = NEW.mapping_version_id
       AND r.mapping_rule_id IS DISTINCT FROM NEW.mapping_rule_id
       AND r.source_kind = NEW.source_kind
       AND r.account_id IS NOT DISTINCT FROM NEW.account_id
       AND r.source_ledger_line_id IS NOT DISTINCT FROM NEW.source_ledger_line_id
       AND r.source_document_id IS NOT DISTINCT FROM NEW.source_document_id
       AND daterange(r.effective_from, r.effective_to, '[]')
        && daterange(NEW.effective_from, NEW.effective_to, '[]')) THEN
    RAISE EXCEPTION 'CFS_MAPPING_AMBIGUOUS: 同一來源在同一生效期間內已有規則（不做條件式映射）';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cf_mapping_rule BEFORE INSERT OR UPDATE OR DELETE
  ON cash_flow_mapping_rule FOR EACH ROW EXECUTE FUNCTION fn_cf_mapping_rule_guard();

-- ═══ 4　粒度例外：父鏈、逐分類、批准後不可變 ═══════════════════════
CREATE FUNCTION fn_cf_coverage_exception_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE pol record; cls record; v_unit uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.approved_at IS NOT NULL THEN
      RAISE EXCEPTION 'CFS_EXCEPTION_IMMUTABLE: 已批准的粒度例外不可刪除';
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_EXCEPTION_IMMUTABLE: 已批准的粒度例外不可變更';
  END IF;
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id, NEW.reporting_unit_id,
                                  NULL, NEW.period_revision_id);
  SELECT rp.reporting_unit_id INTO v_unit FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = NEW.period_revision_id;
  IF v_unit IS DISTINCT FROM NEW.reporting_unit_id THEN
    RAISE EXCEPTION '§24.1A：粒度例外的報告單位與期間不一致';
  END IF;
  SELECT tenant_id, engagement_id, reporting_unit_id, class_set_version_id INTO pol
    FROM cash_flow_policy_version WHERE policy_version_id = NEW.policy_version_id;
  IF pol.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：引用的政策版本屬於其他租戶（INV-18）';
  END IF;
  IF pol.engagement_id IS DISTINCT FROM NEW.engagement_id
  OR pol.reporting_unit_id IS DISTINCT FROM NEW.reporting_unit_id THEN
    RAISE EXCEPTION '§24.1A：粒度例外的政策不屬本案件本單位';
  END IF;
  SELECT tenant_id, class_set_version_id INTO cls
    FROM cash_flow_class WHERE cash_flow_class_id = NEW.cash_flow_class_id;
  IF cls.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：引用的現金流分類屬於其他租戶（INV-18）';
  END IF;
  IF cls.class_set_version_id IS DISTINCT FROM pol.class_set_version_id THEN
    RAISE EXCEPTION 'CFS_EXCEPTION_CLASS_NOT_IN_SET: 例外的分類不屬政策所綁定的分類集合';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cf_coverage_exception BEFORE INSERT OR UPDATE OR DELETE
  ON cash_flow_coverage_exception FOR EACH ROW EXECUTE FUNCTION fn_cf_coverage_exception_guard();

-- ═══ 5　零活動的工作流物件 ═════════════════════════════════════════
-- **不動 CashFlowClassPeriodCoverage 的三值語意**：該表只保存已生效的覆蓋結論。
-- R2 確認與 R3 覆核之間需要一個可指、可鎖、可覆核的物件，因此另立見證表。
CREATE TABLE cash_flow_zero_activity_attestation (
  attestation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  engagement_id uuid NOT NULL REFERENCES client_engagement,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  policy_version_id uuid NOT NULL REFERENCES cash_flow_policy_version,
  cash_flow_class_id uuid NOT NULL REFERENCES cash_flow_class,
  reason        text NOT NULL CHECK (reason <> ''),
  evidence_ref  text NOT NULL CHECK (evidence_ref <> ''),
  confirmed_by  uuid NOT NULL REFERENCES app_user,
  confirmed_at  timestamptz NOT NULL DEFAULT now(),
  reviewed_by   uuid REFERENCES app_user,
  reviewed_at   timestamptz,
  status        text NOT NULL DEFAULT 'PENDING_REVIEW'
                  CHECK (status IN ('PENDING_REVIEW','REVIEWED')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK ((reviewed_by IS NULL) = (reviewed_at IS NULL)),
  CHECK ((status = 'REVIEWED') = (reviewed_by IS NOT NULL)),
  UNIQUE (period_revision_id, cash_flow_class_id, policy_version_id)
);
ALTER TABLE cash_flow_zero_activity_attestation ENABLE ROW LEVEL SECURITY;
ALTER TABLE cash_flow_zero_activity_attestation FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON cash_flow_zero_activity_attestation
  USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant());
GRANT SELECT ON cash_flow_zero_activity_attestation TO app_runtime;

-- 見證與覆蓋結論共用同一組父鏈判準——兩者指的是同一件事，
-- 判準分岔時「見證通過但結論被擋下」會變成無法解釋的狀態。
CREATE FUNCTION fn_cf_period_class_parents(
  p_tenant uuid, p_period_revision uuid, p_reporting_unit uuid,
  p_policy uuid, p_class uuid
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE pol record; cls record; v_unit uuid;
BEGIN
  SELECT tenant_id, engagement_id, reporting_unit_id, class_set_version_id INTO pol
    FROM cash_flow_policy_version WHERE policy_version_id = p_policy;
  IF pol.tenant_id IS NULL THEN
    RAISE EXCEPTION 'CFS_POLICY_NOT_FOUND: 政策版本不存在';
  END IF;
  IF pol.tenant_id IS DISTINCT FROM p_tenant THEN
    RAISE EXCEPTION '歸屬違規：引用的政策版本屬於其他租戶（INV-18）';
  END IF;
  PERFORM fn_assert_parent_tenant(p_tenant, pol.engagement_id, p_reporting_unit,
                                  NULL, p_period_revision);
  IF pol.reporting_unit_id IS DISTINCT FROM p_reporting_unit THEN
    RAISE EXCEPTION '§24.1A：政策版本的報告單位與本列不一致';
  END IF;
  SELECT rp.reporting_unit_id INTO v_unit FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = p_period_revision;
  IF v_unit IS DISTINCT FROM p_reporting_unit THEN
    RAISE EXCEPTION '§24.1A：期間的報告單位與本列不一致';
  END IF;
  SELECT tenant_id, class_set_version_id INTO cls
    FROM cash_flow_class WHERE cash_flow_class_id = p_class;
  IF cls.tenant_id IS DISTINCT FROM p_tenant THEN
    RAISE EXCEPTION '歸屬違規：引用的現金流分類屬於其他租戶（INV-18）';
  END IF;
  IF cls.class_set_version_id IS DISTINCT FROM pol.class_set_version_id THEN
    RAISE EXCEPTION 'CFS_CLASS_NOT_IN_SET: 分類不屬政策所綁定的分類集合';
  END IF;
END $$;

CREATE FUNCTION fn_cf_zero_activity_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'REVIEWED' THEN
      RAISE EXCEPTION 'CFS_ZERO_ACTIVITY_IMMUTABLE: 已覆核的零活動見證不可刪除';
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'REVIEWED' THEN
    RAISE EXCEPTION 'CFS_ZERO_ACTIVITY_IMMUTABLE: 已覆核的零活動見證不可變更';
  END IF;
  PERFORM fn_cf_period_class_parents(NEW.tenant_id, NEW.period_revision_id,
                                     NEW.reporting_unit_id, NEW.policy_version_id,
                                     NEW.cash_flow_class_id);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cf_zero_activity BEFORE INSERT OR UPDATE OR DELETE
  ON cash_flow_zero_activity_attestation FOR EACH ROW EXECUTE FUNCTION fn_cf_zero_activity_guard();

-- ═══ 6　覆蓋結論的父鏈 ═════════════════════════════════════════════
CREATE FUNCTION fn_cf_class_period_coverage_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e record;
BEGIN
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  PERFORM fn_cf_period_class_parents(NEW.tenant_id, NEW.period_revision_id,
                                     NEW.reporting_unit_id, NEW.policy_version_id,
                                     NEW.cash_flow_class_id);
  -- DATA_PRESENT 只能由系統依 CashFlowSourceFact 衍生（契約 §五）。
  -- 那個衍生入口屬 2b；在它落地前一律 fail closed——寫成「暫時允許人工宣告」，
  -- 等於讓完整度判定可以用手填的方式通過。
  IF NEW.status = 'DATA_PRESENT' THEN
    RAISE EXCEPTION 'CFS_DATA_PRESENT_NOT_IMPLEMENTED: DATA_PRESENT 只能由系統依已映射的來源事實衍生，該入口尚未實作';
  END IF;

  -- 「必須帶 exception_id」是 0039 的 CHECK 的事；這裡驗的是**它指向什麼**。
  -- 兩者混做會讓缺 id 的列以「例外不存在」被擋下，拒絕理由就答錯了。
  IF NEW.status = 'COVERAGE_EXCEPTION' AND NEW.coverage_exception_id IS NOT NULL THEN
    SELECT tenant_id, period_revision_id, reporting_unit_id, policy_version_id,
           cash_flow_class_id, approved_at INTO e
      FROM cash_flow_coverage_exception WHERE exception_id = NEW.coverage_exception_id;
    IF e.tenant_id IS NULL THEN
      RAISE EXCEPTION 'CFS_EXCEPTION_NOT_FOUND: 引用的粒度例外不存在';
    END IF;
    IF e.tenant_id IS DISTINCT FROM NEW.tenant_id
    OR e.period_revision_id IS DISTINCT FROM NEW.period_revision_id
    OR e.reporting_unit_id IS DISTINCT FROM NEW.reporting_unit_id
    OR e.policy_version_id IS DISTINCT FROM NEW.policy_version_id
    OR e.cash_flow_class_id IS DISTINCT FROM NEW.cash_flow_class_id THEN
      RAISE EXCEPTION 'CFS_EXCEPTION_SCOPE_MISMATCH: 引用的粒度例外不屬同一期、同單位、同政策、同分類';
    END IF;
    IF e.approved_at IS NULL THEN
      RAISE EXCEPTION 'CFS_EXCEPTION_NOT_APPROVED: 引用的粒度例外尚未經 R4 批准';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cf_class_period_coverage BEFORE INSERT OR UPDATE OR DELETE
  ON cash_flow_class_period_coverage
  FOR EACH ROW EXECUTE FUNCTION fn_cf_class_period_coverage_guard();

-- ═══ 7　首期期初證據集合 ═══════════════════════════════════════════
CREATE FUNCTION fn_cf_opening_set_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p record; v_unit uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.approved_at IS NOT NULL THEN
      RAISE EXCEPTION 'CFS_OPENING_SET_IMMUTABLE: 已批准的期初證據集合不可刪除';
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_OPENING_SET_IMMUTABLE: 已批准的期初證據集合不可變更（更正須發新版本）';
  END IF;
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id, NEW.reporting_unit_id,
                                  NULL, NEW.period_revision_id);
  SELECT rp.reporting_unit_id INTO v_unit FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = NEW.period_revision_id;
  IF v_unit IS DISTINCT FROM NEW.reporting_unit_id THEN
    RAISE EXCEPTION '§24.1A：期初證據集合的報告單位與期間不一致';
  END IF;
  IF TG_OP = 'INSERT' AND NEW.supersedes_set_version_id IS NOT NULL THEN
    SELECT tenant_id, series_id, version_no INTO p FROM cash_flow_opening_balance_set_version
     WHERE opening_set_version_id = NEW.supersedes_set_version_id;
    PERFORM fn_cf_assert_chain('期初證據集合', NEW.tenant_id, NEW.series_id, NEW.version_no,
                               p.tenant_id, p.series_id, p.version_no);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cf_opening_set BEFORE INSERT OR UPDATE OR DELETE
  ON cash_flow_opening_balance_set_version
  FOR EACH ROW EXECUTE FUNCTION fn_cf_opening_set_guard();

CREATE FUNCTION fn_cf_opening_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s record; v_row record;
BEGIN
  v_row := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  SELECT tenant_id, engagement_id, approved_at INTO s
    FROM cash_flow_opening_balance_set_version
   WHERE opening_set_version_id = v_row.opening_set_version_id;
  IF s.tenant_id IS NULL THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'CFS_OPENING_SET_NOT_FOUND: 期初證據集合不存在';
  END IF;
  IF s.tenant_id IS DISTINCT FROM v_row.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：期初明細與其集合不同租戶（INV-18）';
  END IF;
  IF s.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_OPENING_SET_IMMUTABLE: 已批准的期初證據集合不可 % 明細', TG_OP;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, s.engagement_id, NULL, NEW.account_id);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cf_opening_line BEFORE INSERT OR UPDATE OR DELETE
  ON cash_flow_opening_balance_line
  FOR EACH ROW EXECUTE FUNCTION fn_cf_opening_line_guard();

-- ═══ 8　來源選定：FX 對齊、顯式前期、首期證據 ══════════════════════
-- 現行版本＝同一 series 中未被任何後版指向者（由取代鏈判斷，不按時間）
CREATE FUNCTION fn_current_cf_source_selection(p_period_revision uuid)
RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT s.cf_selection_id FROM period_cash_flow_source_selection s
   WHERE s.period_revision_id = p_period_revision
     AND NOT EXISTS (SELECT 1 FROM period_cash_flow_source_selection n
                      WHERE n.supersedes_selection_id = s.cf_selection_id)
   ORDER BY s.version_no DESC LIMIT 1
$$;

CREATE FUNCTION fn_cf_source_selection_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  run record; p record; v_unit uuid; v_prev uuid;
  v_fx_run uuid; v_prior_rev uuid; v_prior_run uuid; os record;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'CFS_SELECTION_IMMUTABLE: 選定建立後不可 % ——換選擇請發新版本', TG_OP;
  END IF;
  PERFORM fn_assert_parent_tenant(NEW.tenant_id, NEW.engagement_id, NEW.reporting_unit_id,
                                  NULL, NEW.period_revision_id);
  SELECT rp.reporting_unit_id, rp.previous_reporting_period_id INTO v_unit, v_prev
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = NEW.period_revision_id;
  IF v_unit IS DISTINCT FROM NEW.reporting_unit_id THEN
    RAISE EXCEPTION '§24.1A：來源選定的報告單位與期間不一致';
  END IF;

  -- ── 本期來源 run ──
  SELECT cr.tenant_id, cr.engagement_id, cr.period_revision_id, cr.status,
         cr.replay_of_run_id, m.calculation_scope
    INTO run FROM calculation_run cr
    JOIN calculation_input_manifest m ON m.manifest_id = cr.manifest_id
   WHERE cr.calculation_run_id = NEW.current_run_id;
  IF run.tenant_id IS NULL THEN
    RAISE EXCEPTION 'CFS_SOURCE_RUN_NOT_FOUND: 本期來源 run 不存在';
  END IF;
  IF run.tenant_id IS DISTINCT FROM NEW.tenant_id
  OR run.engagement_id IS DISTINCT FROM NEW.engagement_id
  OR run.period_revision_id IS DISTINCT FROM NEW.period_revision_id THEN
    RAISE EXCEPTION '§24.1A：本期來源 run 不屬本案件本期';
  END IF;
  IF run.status <> 'COMPLETED' THEN
    RAISE EXCEPTION 'CFS_SOURCE_RUN_NOT_COMPLETED: 只有已完成的 run 可作為來源（目前 %）', run.status;
  END IF;
  IF run.replay_of_run_id IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_SOURCE_RUN_IS_REPLAY: replay 是驗證行為，不得作為現行來源';
  END IF;
  IF run.calculation_scope = 'CASH_FLOW_SUPPORT' THEN
    RAISE EXCEPTION 'CFS_SOURCE_RUN_SCOPE_INVALID: 來源 run 是餘額或折算 run，不是現金流支持 run 自己';
  END IF;
  -- FX 情境：兩個選定不得各說各話
  IF run.calculation_scope = 'FX_TRANSLATION' THEN
    SELECT selected_run_id INTO v_fx_run FROM period_fx_run_selection
     WHERE run_selection_id = fn_current_fx_run_selection(NEW.period_revision_id);
    IF v_fx_run IS NULL THEN
      RAISE EXCEPTION 'CFS_FX_RUN_NOT_SELECTED: 本期尚未選定折算結果（PeriodFxRunSelection），折算 run 不得逕行作為現金流來源';
    END IF;
    IF v_fx_run IS DISTINCT FROM NEW.current_run_id THEN
      RAISE EXCEPTION 'CFS_FX_SELECTION_MISMATCH: 本期來源 run 與現行 PeriodFxRunSelection 不一致（選定＝%）', v_fx_run;
    END IF;
  END IF;

  -- ── 期初來源：首期只能用證據，非首期只能用前期已選定結果 ──
  IF v_prev IS NULL THEN
    IF NEW.opening_source_kind <> 'FIRST_PERIOD_EVIDENCE' THEN
      RAISE EXCEPTION 'CFS_OPENING_SOURCE_INVALID: 首期沒有前期已選定結果，期初只能用已批准的期初證據';
    END IF;
  ELSE
    IF NEW.opening_source_kind <> 'PRIOR_SELECTED_RUN' THEN
      RAISE EXCEPTION 'CFS_OPENING_SOURCE_INVALID: 非首期不得使用首期期初證據';
    END IF;
  END IF;

  IF NEW.opening_source_kind = 'FIRST_PERIOD_EVIDENCE' THEN
    SELECT tenant_id, engagement_id, reporting_unit_id, period_revision_id, approved_at
      INTO os FROM cash_flow_opening_balance_set_version
     WHERE opening_set_version_id = NEW.opening_balance_set_version_id;
    IF os.tenant_id IS DISTINCT FROM NEW.tenant_id
    OR os.engagement_id IS DISTINCT FROM NEW.engagement_id
    OR os.reporting_unit_id IS DISTINCT FROM NEW.reporting_unit_id
    OR os.period_revision_id IS DISTINCT FROM NEW.period_revision_id THEN
      RAISE EXCEPTION '§24.1A：期初證據集合不屬本案件本單位本期';
    END IF;
    IF os.approved_at IS NULL THEN
      RAISE EXCEPTION 'CFS_OPENING_EVIDENCE_NOT_APPROVED: 未批准的期初證據集合不得使用';
    END IF;
  ELSE
    -- 顯式前期的**已選定結果**——不是「前期最新的 COMPLETED run」。
    -- 順序固定且兩者都是顯式選定：現金流自己的選定優先；前期尚未做現金流選定時，
    -- 才接受前期的 PeriodFxRunSelection。任何情況下都不按時間找最新。
    SELECT pr.period_revision_id INTO v_prior_rev
      FROM period_revision pr
     WHERE pr.reporting_period_id = v_prev
       AND fn_current_cf_source_selection(pr.period_revision_id) IS NOT NULL
     LIMIT 1;
    IF v_prior_rev IS NOT NULL THEN
      SELECT s.current_run_id INTO v_prior_run FROM period_cash_flow_source_selection s
       WHERE s.cf_selection_id = fn_current_cf_source_selection(v_prior_rev);
    ELSE
      SELECT s.selected_run_id INTO v_prior_run
        FROM period_revision pr
        JOIN period_fx_run_selection s
          ON s.run_selection_id = fn_current_fx_run_selection(pr.period_revision_id)
       WHERE pr.reporting_period_id = v_prev
       LIMIT 1;
    END IF;
    IF v_prior_run IS NULL THEN
      RAISE EXCEPTION 'CFS_PRIOR_RUN_NOT_SELECTED: 顯式前期尚無已選定結果（現金流選定或折算結果選定）';
    END IF;
    IF v_prior_run IS DISTINCT FROM NEW.prior_run_id THEN
      RAISE EXCEPTION 'CFS_PRIOR_RUN_NOT_SELECTED: 期初 run 不是顯式前期的已選定結果（已選定＝%）',
        v_prior_run;
    END IF;
  END IF;

  IF NEW.supersedes_selection_id IS NOT NULL THEN
    SELECT tenant_id, selection_series_id AS series_id, version_no, period_revision_id INTO p
      FROM period_cash_flow_source_selection WHERE cf_selection_id = NEW.supersedes_selection_id;
    PERFORM fn_cf_assert_chain('來源選定', NEW.tenant_id, NEW.selection_series_id,
                               NEW.version_no, p.tenant_id, p.series_id, p.version_no);
    IF p.period_revision_id IS DISTINCT FROM NEW.period_revision_id THEN
      RAISE EXCEPTION 'CFS_SELECTION_PERIOD_MISMATCH: 取代的選定屬於其他期間';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cf_source_selection BEFORE INSERT OR UPDATE OR DELETE
  ON period_cash_flow_source_selection
  FOR EACH ROW EXECUTE FUNCTION fn_cf_source_selection_guard();

-- ═══ 9　角色工作流函式 ═════════════════════════════════════════════
-- 全部 SECURITY DEFINER ＋ 固定 search_path（不固定時呼叫者可用自己的 schema
-- 影子化被引用的物件），並在 §10 撤回 PUBLIC 後明示授權。
-- app_runtime 對這十二張表只有 SELECT——**這些函式是唯一的寫入入口**。

-- ── 9.1 分類集合（R4；契約 §三：分類是母公司口徑的一部分）──
CREATE FUNCTION fn_cf_class_set_create(
  p_tenant uuid, p_engagement uuid, p_label text,
  p_series uuid, p_version_no int, p_supersedes uuid, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM fn_cf_assert_actor(p_actor, 'R4', p_tenant, p_engagement);
  INSERT INTO cash_flow_class_set_version (tenant_id, engagement_id, label, series_id,
          version_no, supersedes_set_version_id, created_by)
  VALUES (p_tenant, p_engagement, p_label, p_series, p_version_no, p_supersedes, p_actor)
  RETURNING class_set_version_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION fn_cf_class_add(
  p_set uuid, p_code text, p_name text, p_kind text, p_activity text,
  p_direction text, p_is_required boolean, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s record; v_id uuid;
BEGIN
  SELECT tenant_id, engagement_id INTO s FROM cash_flow_class_set_version
   WHERE class_set_version_id = p_set FOR UPDATE;
  IF s.tenant_id IS NULL THEN RAISE EXCEPTION 'CFS_CLASS_SET_NOT_FOUND: 分類集合不存在'; END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R4', s.tenant_id, s.engagement_id);
  INSERT INTO cash_flow_class (tenant_id, class_set_version_id, code, name, kind, activity,
          direction, is_required)
  VALUES (s.tenant_id, p_set, p_code, p_name, p_kind, p_activity, p_direction,
          COALESCE(p_is_required, false))
  RETURNING cash_flow_class_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION fn_cf_cash_account_add(
  p_set uuid, p_account uuid, p_cash_role text, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s record; v_id uuid;
BEGIN
  SELECT tenant_id, engagement_id INTO s FROM cash_flow_class_set_version
   WHERE class_set_version_id = p_set FOR UPDATE;
  IF s.tenant_id IS NULL THEN RAISE EXCEPTION 'CFS_CLASS_SET_NOT_FOUND: 分類集合不存在'; END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R4', s.tenant_id, s.engagement_id);
  INSERT INTO cash_flow_cash_account_membership (tenant_id, class_set_version_id, account_id, cash_role)
  VALUES (s.tenant_id, p_set, p_account, p_cash_role)
  RETURNING membership_id INTO v_id;
  RETURN v_id;
END $$;

-- 批准時的兩項最低要求（契約 §三）：否則等於批准了一個空集合。
CREATE FUNCTION fn_cf_class_set_approve(p_set uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s record; v_fx int; v_cash int;
BEGIN
  SELECT tenant_id, engagement_id, approved_at INTO s FROM cash_flow_class_set_version
   WHERE class_set_version_id = p_set FOR UPDATE;
  IF s.tenant_id IS NULL THEN RAISE EXCEPTION 'CFS_CLASS_SET_NOT_FOUND: 分類集合不存在'; END IF;
  IF s.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_ALREADY_APPROVED: 已批准，不得重複批准';
  END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R4', s.tenant_id, s.engagement_id);
  SELECT count(*) INTO v_fx FROM cash_flow_class
   WHERE class_set_version_id = p_set AND kind = 'FX_EFFECT_ON_CASH';
  IF v_fx <> 1 THEN
    RAISE EXCEPTION 'CFS_CLASS_SET_FX_EFFECT_REQUIRED: 分類集合必須恰有一個 FX_EFFECT_ON_CASH 控制項（目前 % 個）——它是 K2 的檢查項，不是第四種活動', v_fx;
  END IF;
  SELECT count(*) INTO v_cash FROM cash_flow_cash_account_membership
   WHERE class_set_version_id = p_set;
  IF v_cash = 0 THEN
    RAISE EXCEPTION 'CFS_CLASS_SET_NO_CASH_ACCOUNT: 沒有現金科目範圍的分類集合不得批准（K1／K2 沒有計算對象）';
  END IF;
  UPDATE cash_flow_class_set_version SET approved_by = p_actor, approved_at = now()
   WHERE class_set_version_id = p_set;
END $$;

-- ── 9.2 政策版本（R4；§24.6：R4 決定輸出與現金流粒度）──
CREATE FUNCTION fn_cf_policy_create(
  p_tenant uuid, p_engagement uuid, p_unit uuid, p_method text,
  p_required_granularity text, p_class_set uuid, p_evidence_version text,
  p_series uuid, p_version_no int, p_supersedes uuid, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM fn_cf_assert_actor(p_actor, 'R4', p_tenant, p_engagement);
  INSERT INTO cash_flow_policy_version (tenant_id, engagement_id, reporting_unit_id, method,
          required_granularity, class_set_version_id, evidence_version, series_id, version_no,
          supersedes_policy_version_id, created_by)
  VALUES (p_tenant, p_engagement, p_unit, p_method, p_required_granularity, p_class_set,
          p_evidence_version, p_series, p_version_no, p_supersedes, p_actor)
  RETURNING policy_version_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION fn_cf_policy_approve(p_policy uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE p record; v_set_approved timestamptz;
BEGIN
  SELECT tenant_id, engagement_id, class_set_version_id, approved_at INTO p
    FROM cash_flow_policy_version WHERE policy_version_id = p_policy FOR UPDATE;
  IF p.tenant_id IS NULL THEN RAISE EXCEPTION 'CFS_POLICY_NOT_FOUND: 政策版本不存在'; END IF;
  IF p.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_ALREADY_APPROVED: 已批准，不得重複批准';
  END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R4', p.tenant_id, p.engagement_id);
  SELECT approved_at INTO v_set_approved FROM cash_flow_class_set_version
   WHERE class_set_version_id = p.class_set_version_id;
  IF v_set_approved IS NULL THEN
    RAISE EXCEPTION 'CFS_CLASS_SET_NOT_APPROVED: 政策引用的分類集合尚未批准——必要性只由集合的 is_required 定義';
  END IF;
  UPDATE cash_flow_policy_version SET approved_by = p_actor, approved_at = now()
   WHERE policy_version_id = p_policy;
END $$;

-- ── 9.3 映射：R2 建立 → R3 覆核 → R4 批准（比照 MappingRule）──
CREATE FUNCTION fn_cf_mapping_create(
  p_tenant uuid, p_engagement uuid, p_policy uuid,
  p_series uuid, p_version_no int, p_supersedes uuid, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM fn_cf_assert_actor(p_actor, 'R2', p_tenant, p_engagement);
  INSERT INTO cash_flow_mapping_version (tenant_id, engagement_id, policy_version_id,
          series_id, version_no, supersedes_mapping_version_id, created_by)
  VALUES (p_tenant, p_engagement, p_policy, p_series, p_version_no, p_supersedes, p_actor)
  RETURNING mapping_version_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION fn_cf_mapping_rule_add(
  p_version uuid, p_source_kind text, p_account uuid, p_ledger_line bigint,
  p_document uuid, p_class uuid, p_from date, p_to date, p_evidence text, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v record; v_id uuid;
BEGIN
  -- 鎖住版本：重疊判定與寫入之間不得被併發插隊（CFS_MAPPING_AMBIGUOUS 的 TOCTOU）
  SELECT tenant_id, engagement_id INTO v FROM cash_flow_mapping_version
   WHERE mapping_version_id = p_version FOR UPDATE;
  IF v.tenant_id IS NULL THEN RAISE EXCEPTION 'CFS_MAPPING_NOT_FOUND: 映射版本不存在'; END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R2', v.tenant_id, v.engagement_id);
  INSERT INTO cash_flow_mapping_rule (tenant_id, mapping_version_id, source_kind, account_id,
          source_ledger_line_id, source_document_id, cash_flow_class_id, effective_from,
          effective_to, evidence_ref)
  VALUES (v.tenant_id, p_version, p_source_kind, p_account, p_ledger_line, p_document,
          p_class, p_from, p_to, p_evidence)
  RETURNING mapping_rule_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION fn_cf_mapping_review(p_version uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v record; v_rules int;
BEGIN
  SELECT tenant_id, engagement_id, reviewed_at, approved_at INTO v
    FROM cash_flow_mapping_version WHERE mapping_version_id = p_version FOR UPDATE;
  IF v.tenant_id IS NULL THEN RAISE EXCEPTION 'CFS_MAPPING_NOT_FOUND: 映射版本不存在'; END IF;
  IF v.reviewed_at IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_MAPPING_ALREADY_REVIEWED: 已覆核，不得重複覆核';
  END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R3', v.tenant_id, v.engagement_id);
  SELECT count(*) INTO v_rules FROM cash_flow_mapping_rule WHERE mapping_version_id = p_version;
  IF v_rules = 0 THEN
    RAISE EXCEPTION 'CFS_MAPPING_EMPTY: 沒有任何規則的映射版本不得覆核';
  END IF;
  UPDATE cash_flow_mapping_version SET reviewed_by = p_actor, reviewed_at = now()
   WHERE mapping_version_id = p_version;
END $$;

CREATE FUNCTION fn_cf_mapping_approve(p_version uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v record; v_pol_approved timestamptz;
BEGIN
  SELECT tenant_id, engagement_id, policy_version_id, reviewed_at, approved_at, created_by INTO v
    FROM cash_flow_mapping_version WHERE mapping_version_id = p_version FOR UPDATE;
  IF v.tenant_id IS NULL THEN RAISE EXCEPTION 'CFS_MAPPING_NOT_FOUND: 映射版本不存在'; END IF;
  IF v.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_ALREADY_APPROVED: 已批准，不得重複批准';
  END IF;
  IF v.reviewed_at IS NULL THEN
    RAISE EXCEPTION 'CFS_MAPPING_NOT_REVIEWED: 映射版本尚未經 R3 覆核，不得批准';
  END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R4', v.tenant_id, v.engagement_id);
  SELECT approved_at INTO v_pol_approved FROM cash_flow_policy_version
   WHERE policy_version_id = v.policy_version_id;
  IF v_pol_approved IS NULL THEN
    RAISE EXCEPTION 'CFS_POLICY_NOT_APPROVED: 映射所綁定的政策版本尚未批准';
  END IF;
  UPDATE cash_flow_mapping_version SET approved_by = p_actor, approved_at = now()
   WHERE mapping_version_id = p_version;
END $$;

-- ── 9.4 粒度例外：R2 申請、R4 批准（逐分類，不得整期一次豁免）──
CREATE FUNCTION fn_cf_coverage_exception_create(
  p_period uuid, p_unit uuid, p_policy uuid, p_class uuid,
  p_actual_granularity text, p_reason text, p_evidence text, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE pol record; v_id uuid;
BEGIN
  SELECT tenant_id, engagement_id INTO pol FROM cash_flow_policy_version
   WHERE policy_version_id = p_policy;
  IF pol.tenant_id IS NULL THEN RAISE EXCEPTION 'CFS_POLICY_NOT_FOUND: 政策版本不存在'; END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R2', pol.tenant_id, pol.engagement_id);
  INSERT INTO cash_flow_coverage_exception (tenant_id, engagement_id, period_revision_id,
          reporting_unit_id, policy_version_id, cash_flow_class_id, actual_granularity,
          reason, evidence_ref, created_by)
  VALUES (pol.tenant_id, pol.engagement_id, p_period, p_unit, p_policy, p_class,
          p_actual_granularity, p_reason, p_evidence, p_actor)
  RETURNING exception_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION fn_cf_coverage_exception_approve(p_exception uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE e record;
BEGIN
  SELECT tenant_id, engagement_id, approved_at INTO e FROM cash_flow_coverage_exception
   WHERE exception_id = p_exception FOR UPDATE;
  IF e.tenant_id IS NULL THEN RAISE EXCEPTION 'CFS_EXCEPTION_NOT_FOUND: 粒度例外不存在'; END IF;
  IF e.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_ALREADY_APPROVED: 已批准，不得重複批准';
  END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R4', e.tenant_id, e.engagement_id);
  UPDATE cash_flow_coverage_exception SET approved_by = p_actor, approved_at = now()
   WHERE exception_id = p_exception;
END $$;

-- 已批准的例外落成該期該分類的覆蓋結論。輸出時每一列都要帶得出這個 exception_id，
-- 支持資料本身才看得出哪一段是在粒度不足下產生的。
CREATE FUNCTION fn_cf_coverage_exception_record(p_exception uuid, p_actor uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE e record; v_id uuid;
BEGIN
  SELECT * INTO e FROM cash_flow_coverage_exception WHERE exception_id = p_exception FOR UPDATE;
  IF e.exception_id IS NULL THEN RAISE EXCEPTION 'CFS_EXCEPTION_NOT_FOUND: 粒度例外不存在'; END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R2', e.tenant_id, e.engagement_id);
  IF e.approved_at IS NULL THEN
    RAISE EXCEPTION 'CFS_EXCEPTION_NOT_APPROVED: 未經 R4 批准的粒度例外不得成為覆蓋結論';
  END IF;
  INSERT INTO cash_flow_class_period_coverage (tenant_id, period_revision_id, reporting_unit_id,
          policy_version_id, cash_flow_class_id, status, coverage_exception_id)
  VALUES (e.tenant_id, e.period_revision_id, e.reporting_unit_id, e.policy_version_id,
          e.cash_flow_class_id, 'COVERAGE_EXCEPTION', p_exception)
  RETURNING coverage_id INTO v_id;
  RETURN v_id;
END $$;

-- ── 9.5 首期期初證據集合（R4）──
CREATE FUNCTION fn_cf_opening_set_create(
  p_tenant uuid, p_engagement uuid, p_unit uuid, p_period uuid,
  p_series uuid, p_version_no int, p_supersedes uuid, p_evidence text, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM fn_cf_assert_actor(p_actor, 'R4', p_tenant, p_engagement);
  INSERT INTO cash_flow_opening_balance_set_version (tenant_id, engagement_id, reporting_unit_id,
          period_revision_id, series_id, version_no, supersedes_set_version_id,
          evidence_ref, created_by)
  VALUES (p_tenant, p_engagement, p_unit, p_period, p_series, p_version_no, p_supersedes,
          p_evidence, p_actor)
  RETURNING opening_set_version_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION fn_cf_opening_line_add(
  p_set uuid, p_account uuid, p_functional_amount numeric, p_functional_currency text,
  p_reporting_amount numeric, p_reporting_currency text, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s record; v_id uuid;
BEGIN
  SELECT tenant_id, engagement_id INTO s FROM cash_flow_opening_balance_set_version
   WHERE opening_set_version_id = p_set FOR UPDATE;
  IF s.tenant_id IS NULL THEN RAISE EXCEPTION 'CFS_OPENING_SET_NOT_FOUND: 期初證據集合不存在'; END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R4', s.tenant_id, s.engagement_id);
  INSERT INTO cash_flow_opening_balance_line (tenant_id, opening_set_version_id, account_id,
          functional_amount, functional_currency, reporting_amount, reporting_currency)
  VALUES (s.tenant_id, p_set, p_account, p_functional_amount, p_functional_currency,
          p_reporting_amount, p_reporting_currency)
  RETURNING opening_line_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION fn_cf_opening_set_approve(p_set uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE s record; v_lines int;
BEGIN
  SELECT tenant_id, engagement_id, approved_at INTO s
    FROM cash_flow_opening_balance_set_version WHERE opening_set_version_id = p_set FOR UPDATE;
  IF s.tenant_id IS NULL THEN RAISE EXCEPTION 'CFS_OPENING_SET_NOT_FOUND: 期初證據集合不存在'; END IF;
  IF s.approved_at IS NOT NULL THEN
    RAISE EXCEPTION 'CFS_ALREADY_APPROVED: 已批准，不得重複批准';
  END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R4', s.tenant_id, s.engagement_id);
  SELECT count(*) INTO v_lines FROM cash_flow_opening_balance_line
   WHERE opening_set_version_id = p_set;
  IF v_lines = 0 THEN
    RAISE EXCEPTION 'CFS_OPENING_SET_EMPTY: 空的期初證據集合不得批准（單列的版本鏈證明不了沒有漏掉現金科目）';
  END IF;
  UPDATE cash_flow_opening_balance_set_version SET approved_by = p_actor, approved_at = now()
   WHERE opening_set_version_id = p_set;
END $$;

-- ── 9.6 來源選定（R4；取代鏈，不得分叉）──
CREATE FUNCTION fn_cf_select_source(
  p_period_revision uuid, p_current_run uuid, p_opening_source_kind text,
  p_prior_run uuid, p_opening_set uuid, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_tenant uuid; v_eng uuid; v_unit uuid; v_cur uuid; v_series uuid; v_no int; v_id uuid;
BEGIN
  -- 鎖住期間：判定「現行 selection」與寫入新版本之間不得被併發插隊（比照 0037）
  SELECT pr.tenant_id, rp.engagement_id, rp.reporting_unit_id INTO v_tenant, v_eng, v_unit
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = p_period_revision FOR UPDATE OF pr;
  IF v_tenant IS NULL THEN RAISE EXCEPTION 'CFS_PERIOD_NOT_FOUND: 期間修訂不存在'; END IF;
  -- 選定本期的權威來源是批准行為（§24.6：R4 決定輸出）
  PERFORM fn_cf_assert_actor(p_actor, 'R4', v_tenant, v_eng);

  v_cur := fn_current_cf_source_selection(p_period_revision);
  IF v_cur IS NULL THEN
    v_series := gen_random_uuid(); v_no := 1;
  ELSE
    SELECT selection_series_id, version_no + 1 INTO v_series, v_no
      FROM period_cash_flow_source_selection WHERE cf_selection_id = v_cur;
  END IF;
  INSERT INTO period_cash_flow_source_selection (tenant_id, engagement_id, period_revision_id,
          reporting_unit_id, current_run_id, opening_source_kind, prior_run_id,
          opening_balance_set_version_id, selection_series_id, version_no,
          supersedes_selection_id, selected_by)
  VALUES (v_tenant, v_eng, p_period_revision, v_unit, p_current_run, p_opening_source_kind,
          p_prior_run, p_opening_set, v_series, v_no, v_cur, p_actor)
  RETURNING cf_selection_id INTO v_id;
  RETURN v_id;
END $$;

-- ── 9.7 零活動：R2 確認 → R3 覆核（同一交易產生正式覆蓋結論）──
CREATE FUNCTION fn_cf_zero_activity_confirm(
  p_period uuid, p_unit uuid, p_policy uuid, p_class uuid,
  p_reason text, p_evidence text, p_actor uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE pol record; v_id uuid;
BEGIN
  SELECT tenant_id, engagement_id, approved_at INTO pol FROM cash_flow_policy_version
   WHERE policy_version_id = p_policy;
  IF pol.tenant_id IS NULL THEN RAISE EXCEPTION 'CFS_POLICY_NOT_FOUND: 政策版本不存在'; END IF;
  IF pol.approved_at IS NULL THEN
    RAISE EXCEPTION 'CFS_POLICY_NOT_APPROVED: 未批准的政策版本不得作為零活動確認的依據';
  END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R2', pol.tenant_id, pol.engagement_id);
  INSERT INTO cash_flow_zero_activity_attestation (tenant_id, engagement_id, period_revision_id,
          reporting_unit_id, policy_version_id, cash_flow_class_id, reason, evidence_ref,
          confirmed_by)
  VALUES (pol.tenant_id, pol.engagement_id, p_period, p_unit, p_policy, p_class,
          p_reason, p_evidence, p_actor)
  RETURNING attestation_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION fn_cf_zero_activity_review(p_attestation uuid, p_actor uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE a record; v_id uuid;
BEGIN
  SELECT * INTO a FROM cash_flow_zero_activity_attestation
   WHERE attestation_id = p_attestation FOR UPDATE;
  IF a.attestation_id IS NULL THEN
    RAISE EXCEPTION 'CFS_ZERO_ACTIVITY_NOT_FOUND: 零活動見證不存在';
  END IF;
  IF a.status = 'REVIEWED' THEN
    RAISE EXCEPTION 'CFS_ZERO_ACTIVITY_ALREADY_REVIEWED: 已覆核，不得重複覆核';
  END IF;
  PERFORM fn_cf_assert_actor(p_actor, 'R3', a.tenant_id, a.engagement_id);
  UPDATE cash_flow_zero_activity_attestation
     SET status = 'REVIEWED', reviewed_by = p_actor, reviewed_at = now()
   WHERE attestation_id = p_attestation;
  -- 同一交易寫入正式結論：確認人來自見證（R2），覆核人是本次的 R3。
  -- 兩者分開保存，稽核軌跡才答得出「誰確認、誰覆核」。
  INSERT INTO cash_flow_class_period_coverage (tenant_id, period_revision_id, reporting_unit_id,
          policy_version_id, cash_flow_class_id, status, confirmed_by, confirmed_at,
          reviewed_by, reviewed_at, reason, evidence_ref)
  VALUES (a.tenant_id, a.period_revision_id, a.reporting_unit_id, a.policy_version_id,
          a.cash_flow_class_id, 'ZERO_ACTIVITY_CONFIRMED', a.confirmed_by, a.confirmed_at,
          p_actor, now(), a.reason, a.evidence_ref)
  RETURNING coverage_id INTO v_id;
  RETURN v_id;
END $$;

-- ═══ 10　權限 ══════════════════════════════════════════════════════
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'fn_cf_class_set_create(uuid, uuid, text, uuid, integer, uuid, uuid)',
    'fn_cf_class_add(uuid, text, text, text, text, text, boolean, uuid)',
    'fn_cf_cash_account_add(uuid, uuid, text, uuid)',
    'fn_cf_class_set_approve(uuid, uuid)',
    'fn_cf_policy_create(uuid, uuid, uuid, text, text, uuid, text, uuid, integer, uuid, uuid)',
    'fn_cf_policy_approve(uuid, uuid)',
    'fn_cf_mapping_create(uuid, uuid, uuid, uuid, integer, uuid, uuid)',
    'fn_cf_mapping_rule_add(uuid, text, uuid, bigint, uuid, uuid, date, date, text, uuid)',
    'fn_cf_mapping_review(uuid, uuid)',
    'fn_cf_mapping_approve(uuid, uuid)',
    'fn_cf_coverage_exception_create(uuid, uuid, uuid, uuid, text, text, text, uuid)',
    'fn_cf_coverage_exception_approve(uuid, uuid)',
    'fn_cf_coverage_exception_record(uuid, uuid)',
    'fn_cf_opening_set_create(uuid, uuid, uuid, uuid, uuid, integer, uuid, text, uuid)',
    'fn_cf_opening_line_add(uuid, uuid, numeric, text, numeric, text, uuid)',
    'fn_cf_opening_set_approve(uuid, uuid)',
    'fn_cf_select_source(uuid, uuid, text, uuid, uuid, uuid)',
    'fn_cf_zero_activity_confirm(uuid, uuid, uuid, uuid, text, text, uuid)',
    'fn_cf_zero_activity_review(uuid, uuid)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO app_runtime', f);
  END LOOP;
END $$;

-- 角色與版本鏈查證只由上述 SECURITY DEFINER 函式呼叫（以 owner 身分執行），對外不開放
REVOKE ALL ON FUNCTION fn_cf_assert_actor(uuid, text, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_cf_assert_chain(text, uuid, uuid, integer, uuid, uuid, integer) FROM PUBLIC;
-- 父鏈查證由 **SECURITY INVOKER 的 trigger** 呼叫，執行身分就是寫入者（0032 §4 的同一個理由）
REVOKE ALL ON FUNCTION fn_cf_period_class_parents(uuid, uuid, uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_cf_period_class_parents(uuid, uuid, uuid, uuid, uuid) TO app_runtime;
-- 現行選定的讀取：B-06 與 2b 的判定都要用
REVOKE ALL ON FUNCTION fn_current_cf_source_selection(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_current_cf_source_selection(uuid) TO app_runtime;
