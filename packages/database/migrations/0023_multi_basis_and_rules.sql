-- 0023 多基礎與四類規則最小資料模型（SLICE-M2-06）
-- 契約：docs/slices/SLICE-M2-06_多基礎與四類規則最小模型.md
--
-- 現況缺陷：
--   1. adjustment.basis CHECK ('GROUP_GAAP') 把四類規則硬編成一類——
--      AC-BAS-001「新增基礎不需重建核心實體」不成立。
--   2. 無 BookBasis／PostingLayer／Rule／RuleVersion 實體。
--   3. 無構成與調節模型 → INV-01／INV-02 無對應物，差異只能靜默吸收。
--   4. 無 TaxBasisObservation／BasisSourcePolicyVersion → GB-02 靠「沒有 B」成立。
--
-- 本檔的三條主軸：
--   * **代碼不驅動約束**：全檔不得出現 code = 'A'／'B'／'C' 之類的判斷。
--     約束一律由 source_mode／scope_type／rule_type／permits_group_layer 驅動，
--     日後新增第四種基礎才會是純 INSERT（AC-BAS-001）。
--   * **構成與調節分屬不同模型**（§26.1 L1074）：BasisComposition 用於「計算」，
--     BasisReconciliation 用於「解釋」，兩者數學性質相反、不共用實體。
--   * **守衛未實作 ≠ 守衛通過**（沿用 0022）：AMENDED、尾差自動結案一律 fail closed，
--     回穩定機器前綴，訊息明寫「尚未實作」。

-- ══ 一、PostingLayer：平台級參照主檔（無租戶；app_runtime 唯讀） ══════
--
-- 層是平台語彙，不是客戶口徑：LOCAL_BOOK／CONSOLIDATION 的語意不因客戶而異，
-- 且 scope_type 與 rule_type 的對應是 §26.5 的結構事實，不是可配置政策。
CREATE TABLE posting_layer (
  layer_id   uuid PRIMARY KEY,
  code       text NOT NULL UNIQUE,
  scope_type text NOT NULL CHECK (scope_type IN ('ENTITY','GROUP')),
  -- NULL 是有意義的值：TRANSLATION_ADJUSTMENT 的 rule_type 是逐筆分錄的歸屬
  -- （GROUP_GAAP 或 CONSOLIDATION，§26.5 L1223），不是層的固定屬性。
  -- 單一 CHECK 欄位放不下「或」，種一個值等於替折算刀預先做決定。
  rule_type  text CHECK (rule_type IN ('LOCAL_TAX','GROUP_GAAP','DEFERRED_TAX','CONSOLIDATION'))
);
-- 參照主檔改一次，所有歷史判定的依據就變了——scope_type 改動會追溯翻案 INV-03。
CREATE TRIGGER trg_posting_layer_immutable BEFORE UPDATE OR DELETE ON posting_layer
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

INSERT INTO posting_layer (layer_id, code, scope_type, rule_type) VALUES
  ('10000000-0000-0000-0000-000000000001','LOCAL_BOOK',            'ENTITY', NULL),
  ('10000000-0000-0000-0000-000000000002','LOCAL_TAX_ADJ',         'ENTITY','LOCAL_TAX'),
  ('10000000-0000-0000-0000-000000000003','GROUP_GAAP_ADJ',        'ENTITY','GROUP_GAAP'),
  ('10000000-0000-0000-0000-000000000004','DEFERRED_TAX',          'ENTITY','DEFERRED_TAX'),
  ('10000000-0000-0000-0000-000000000005','CONSOLIDATION',         'GROUP', 'CONSOLIDATION'),
  ('10000000-0000-0000-0000-000000000006','TRANSLATION_ADJUSTMENT','ENTITY', NULL);

GRANT SELECT ON posting_layer TO app_runtime;

-- ══ 二、BasisSourcePolicyVersion：權威來源政策（B 的「憑什麼可信」） ══
--
-- 少了這張表，book_basis.basis_source_policy_version_id 只是一個 uuid 字串，
-- INV-05 的「必須有權威來源政策」會退化成「必須填一個 UUID」。
CREATE TABLE basis_source_policy_version (
  basis_source_policy_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  policy_series_id uuid NOT NULL,
  version_no       int  NOT NULL,
  tenant_id        uuid NOT NULL REFERENCES tenant,
  engagement_id    uuid NOT NULL REFERENCES client_engagement,
  source_kind      text NOT NULL CHECK (source_kind IN
                     ('TAX_RETURN','TAX_WORKPAPER','REGULATORY_FILING','OTHER_AUTHORITATIVE')),
  -- 「指定稅務專業角色」的權威定義。由政策版本承載而非硬編 R1——
  -- 日後客戶或法域不同時換政策版本即可，不改任何約束（GB-02）。
  confirmation_role role_code NOT NULL,
  description      text NOT NULL,
  effective_from   date,
  effective_to     date,
  status           text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED','RETIRED')),
  approved_by      uuid REFERENCES app_user,
  approved_at      timestamptz,
  approval_role    role_code,
  UNIQUE (policy_series_id, version_no),
  CHECK (status <> 'APPROVED'
      OR (approved_by IS NOT NULL AND approved_at IS NOT NULL AND approval_role IS NOT NULL))
);

CREATE FUNCTION fn_basis_source_policy_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_eng_tenant uuid; v_appr_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_eng_tenant FROM client_engagement WHERE engagement_id = NEW.engagement_id;
  IF v_eng_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：來源政策的案件（%）不屬於本租戶', NEW.engagement_id;
  END IF;
  IF NEW.approved_by IS NOT NULL THEN
    SELECT tenant_id INTO v_appr_tenant FROM app_user WHERE user_id = NEW.approved_by;
    IF v_appr_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'INV-18：來源政策的批准人（%）不屬於本租戶', NEW.approved_by;
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF OLD.status = 'APPROVED' AND NEW.status = 'APPROVED' THEN
      -- 已批准的政策原地改寫＝歷史的 B 基礎憑據被追溯換掉
      IF NEW.source_kind IS DISTINCT FROM OLD.source_kind
      OR NEW.confirmation_role IS DISTINCT FROM OLD.confirmation_role
      OR NEW.description IS DISTINCT FROM OLD.description
      OR NEW.effective_from IS DISTINCT FROM OLD.effective_from
      OR NEW.effective_to IS DISTINCT FROM OLD.effective_to
      OR NEW.approved_by IS DISTINCT FROM OLD.approved_by
      OR NEW.approval_role IS DISTINCT FROM OLD.approval_role THEN
        RAISE EXCEPTION 'BASIS_SOURCE_POLICY_IMMUTABLE: 已批准的來源政策不可變更——改政策請建立新 version_no';
      END IF;
    END IF;
    IF OLD.status = 'RETIRED' THEN
      RAISE EXCEPTION 'BASIS_SOURCE_POLICY_IMMUTABLE: 已退役的來源政策不可再變更';
    END IF;
    IF NEW.policy_series_id IS DISTINCT FROM OLD.policy_series_id
    OR NEW.version_no IS DISTINCT FROM OLD.version_no
    OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
    OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id THEN
      RAISE EXCEPTION 'BASIS_SOURCE_POLICY_IMMUTABLE: 政策版本的身分欄位不可變更';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_bspv_guard BEFORE INSERT OR UPDATE ON basis_source_policy_version
  FOR EACH ROW EXECUTE FUNCTION fn_basis_source_policy_guard();

-- ══ 三、BookBasis：案件範圍的可擴充主檔 ═══════════════════════════
--
-- A／B／C 是**客戶案件內的口徑**：framework、集團政策、來源政策都可能因客戶而異。
-- 因此帶 tenant_id ＋ engagement_id 並受 RLS；新增基礎仍然只是一次 INSERT。
CREATE TABLE book_basis (
  basis_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant,
  engagement_id uuid NOT NULL REFERENCES client_engagement,
  code          text NOT NULL,
  jurisdiction  text,
  framework     text,
  source_mode   text NOT NULL CHECK (source_mode IN ('COMPOSED','DIRECT_AUTHORITATIVE_IMPORT')),
  basis_source_policy_version_id uuid REFERENCES basis_source_policy_version,
  -- INV-04 的**獨立政策判定**。刻意不用「該基礎的 composition 是否含 GROUP 層」反查：
  -- 那是循環論證——GROUP 層被誤加進 A 之後，反查反而會說 A「允許 GROUP」，
  -- 守衛替錯誤配置背書。顯式欄位才擋得住錯誤配置。
  permits_group_layer boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (engagement_id, code),
  -- 雙向：DIRECT 必須有政策；COMPOSED 必須沒有（不存在「既組成又直接匯入」的混合語意）
  CHECK ((source_mode = 'DIRECT_AUTHORITATIVE_IMPORT') = (basis_source_policy_version_id IS NOT NULL))
);

CREATE FUNCTION fn_book_basis_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_eng_tenant uuid; v_p_tenant uuid; v_p_eng uuid; v_p_status text;
BEGIN
  SELECT tenant_id INTO v_eng_tenant FROM client_engagement WHERE engagement_id = NEW.engagement_id;
  IF v_eng_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：基礎的案件（%）不屬於本租戶', NEW.engagement_id;
  END IF;

  IF NEW.basis_source_policy_version_id IS NOT NULL THEN
    SELECT tenant_id, engagement_id, status INTO v_p_tenant, v_p_eng, v_p_status
      FROM basis_source_policy_version
     WHERE basis_source_policy_version_id = NEW.basis_source_policy_version_id;
    IF v_p_tenant IS DISTINCT FROM NEW.tenant_id OR v_p_eng IS DISTINCT FROM NEW.engagement_id THEN
      RAISE EXCEPTION '§24.1A：來源政策（%）不屬於本基礎的案件', NEW.basis_source_policy_version_id;
    END IF;
    IF v_p_status <> 'APPROVED' THEN
      RAISE EXCEPTION 'BASIS_SOURCE_POLICY_NOT_APPROVED: 權威來源政策尚未批准（目前 %）——未批准的政策不構成 GB-02 的依據', v_p_status;
    END IF;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- source_mode 與 permits_group_layer 改動會追溯翻案 INV-05 與 INV-04 的既有判定
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
    OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
    OR NEW.code IS DISTINCT FROM OLD.code
    OR NEW.source_mode IS DISTINCT FROM OLD.source_mode
    OR NEW.permits_group_layer IS DISTINCT FROM OLD.permits_group_layer
    OR NEW.basis_source_policy_version_id IS DISTINCT FROM OLD.basis_source_policy_version_id THEN
      RAISE EXCEPTION 'BOOK_BASIS_IMMUTABLE: 基礎的身分與政策欄位建立後不可變更（改動會追溯翻案 INV-04／INV-05 的既有判定）';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_book_basis_guard BEFORE INSERT OR UPDATE ON book_basis
  FOR EACH ROW EXECUTE FUNCTION fn_book_basis_guard();

CREATE FUNCTION fn_book_basis_no_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'BOOK_BASIS_IMMUTABLE: 基礎不可刪除——既有事實與快照仍引用它';
END $$;
CREATE TRIGGER trg_book_basis_no_delete BEFORE DELETE ON book_basis
  FOR EACH ROW EXECUTE FUNCTION fn_book_basis_no_delete();

-- ══ 四、構成模型：BasisCompositionVersion ＋ ConstitutiveLayerItem ══
--
-- 主鍵形狀：basis_composition_version_id 是版本列自己的代理鍵（子表與 manifest 引用它）；
-- (composition_series_id, version_no) 是政策序列的自然唯一鍵。缺一都會出現
-- 「子表引用一個不存在的單一 ID」。
CREATE TABLE basis_composition_version (
  basis_composition_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  composition_series_id uuid NOT NULL,
  version_no       int  NOT NULL,
  tenant_id        uuid NOT NULL REFERENCES tenant,
  engagement_id    uuid NOT NULL REFERENCES client_engagement,
  basis_id         uuid NOT NULL REFERENCES book_basis,
  effective_from   date,
  effective_to     date,
  status           text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED','RETIRED')),
  approved_by      uuid REFERENCES app_user,
  approved_at      timestamptz,
  approval_role    role_code,          -- R4 批准角色快照（INV-11：不得由現行指派推導）
  UNIQUE (composition_series_id, version_no),
  CHECK (status <> 'APPROVED'
      OR (approved_by IS NOT NULL AND approved_at IS NOT NULL AND approval_role IS NOT NULL))
);
CREATE INDEX bcv_basis_idx ON basis_composition_version (basis_id, status);

-- 僅此實體參與基礎餘額加總（§26.5 L1157）。任何「這一層要不要算進去」的問題，
-- 答案只在這張表。
CREATE TABLE constitutive_layer_item (
  basis_composition_version_id uuid NOT NULL REFERENCES basis_composition_version,
  layer_id          uuid NOT NULL REFERENCES posting_layer,
  sign              smallint NOT NULL CHECK (sign IN (1, -1)),
  include_condition jsonb,
  PRIMARY KEY (basis_composition_version_id, layer_id)
);

CREATE FUNCTION fn_basis_composition_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_mode text; v_b_tenant uuid; v_b_eng uuid; v_locked int;
BEGIN
  SELECT source_mode, tenant_id, engagement_id INTO v_mode, v_b_tenant, v_b_eng
    FROM book_basis WHERE basis_id = NEW.basis_id;
  IF v_b_tenant IS DISTINCT FROM NEW.tenant_id OR v_b_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：組成版本的基礎（%）不屬於本案件', NEW.basis_id;
  END IF;
  -- INV-05／GB-02：權威匯入的基礎不得存在任何 BasisComposition——平台無從「推算」它
  IF v_mode = 'DIRECT_AUTHORITATIVE_IMPORT' THEN
    RAISE EXCEPTION 'INV05_COMPOSITION_FORBIDDEN: 權威匯入基礎不得建立組成版本（GB-02：平台不得自行推算該基礎）';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.composition_series_id IS DISTINCT FROM OLD.composition_series_id
    OR NEW.version_no IS DISTINCT FROM OLD.version_no
    OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
    OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
    OR NEW.basis_id IS DISTINCT FROM OLD.basis_id THEN
      RAISE EXCEPTION 'COMPOSITION_IMMUTABLE: 組成版本的身分欄位不可變更';
    END IF;
    -- 已批准即凍結（只允許 APPROVED → RETIRED 的狀態變更本身）
    IF OLD.status = 'APPROVED' AND NEW.status = 'APPROVED' THEN
      IF NEW.effective_from IS DISTINCT FROM OLD.effective_from
      OR NEW.effective_to IS DISTINCT FROM OLD.effective_to
      OR NEW.approved_by IS DISTINCT FROM OLD.approved_by
      OR NEW.approval_role IS DISTINCT FROM OLD.approval_role THEN
        RAISE EXCEPTION 'COMPOSITION_IMMUTABLE: 已批准的組成版本不可變更——改政策請建立新 version_no';
      END IF;
    END IF;
    -- INV-21：已被任一 LOCKED 期間的 manifest 引用者，連狀態都不得再動。
    -- 追溯變更必須先走重開／重編決策並重新批准。
    SELECT count(*) INTO v_locked
      FROM calculation_manifest_entry e
      JOIN calculation_input_manifest m ON m.manifest_id = e.manifest_id
      JOIN period_revision pr ON pr.period_revision_id = m.period_revision_id
     WHERE e.object_type = 'BASIS_COMPOSITION'
       AND e.object_id = OLD.basis_composition_version_id
       AND pr.status IN ('LOCKED','DELIVERED');
    IF v_locked > 0 THEN
      RAISE EXCEPTION 'INV21_LOCKED_COMPOSITION: 此組成版本已被已鎖定期間的凍結清單引用，不得變更（追溯變更須先走重開／重編）';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_bcv_guard BEFORE INSERT OR UPDATE ON basis_composition_version
  FOR EACH ROW EXECUTE FUNCTION fn_basis_composition_guard();

CREATE FUNCTION fn_constitutive_item_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_status text; v_basis uuid; v_permits boolean; v_scope text; v_ver uuid;
BEGIN
  v_ver := CASE WHEN TG_OP = 'DELETE' THEN OLD.basis_composition_version_id
                ELSE NEW.basis_composition_version_id END;
  SELECT c.status, c.basis_id, b.permits_group_layer
    INTO v_status, v_basis, v_permits
    FROM basis_composition_version c JOIN book_basis b ON b.basis_id = c.basis_id
   WHERE c.basis_composition_version_id = v_ver;
  IF v_status <> 'DRAFT' THEN
    RAISE EXCEPTION 'COMPOSITION_IMMUTABLE: 組成版本已離開草稿（%），構成項不可再增刪改', v_status;
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  SELECT scope_type INTO v_scope FROM posting_layer WHERE layer_id = NEW.layer_id;
  -- INV-04 的入口版：把誤配置堵在構成模型，而不是等它在分錄端發作
  IF v_scope = 'GROUP' AND NOT v_permits THEN
    RAISE EXCEPTION 'INV04_GROUP_LAYER_IN_LOCAL_BASIS: 本基礎不允許群組層（permits_group_layer = false），不得納入 GROUP scope 的分層';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cli_guard BEFORE INSERT OR UPDATE OR DELETE ON constitutive_layer_item
  FOR EACH ROW EXECUTE FUNCTION fn_constitutive_item_guard();

-- ══ 五、Rule／RuleVersion：四類規則落表（不做引擎） ═══════════════
CREATE TABLE rule (
  rule_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope_level   text NOT NULL CHECK (scope_level IN ('PLATFORM','TENANT','CLIENT')),
  tenant_id     uuid REFERENCES tenant,
  engagement_id uuid REFERENCES client_engagement,
  rule_type     text NOT NULL CHECK (rule_type IN
                  ('LOCAL_TAX','GROUP_GAAP','DEFERRED_TAX','CONSOLIDATION')),
  jurisdiction  text,
  framework     text,
  code          text NOT NULL,
  name          text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  -- 三層歸屬：兩個控制面不得混用（§26.3）——平台規則不屬於任何 Tenant
  CHECK ((scope_level = 'PLATFORM' AND tenant_id IS NULL     AND engagement_id IS NULL)
      OR (scope_level = 'TENANT'   AND tenant_id IS NOT NULL AND engagement_id IS NULL)
      OR (scope_level = 'CLIENT'   AND tenant_id IS NOT NULL AND engagement_id IS NOT NULL))
);

CREATE TABLE rule_version (
  rule_version_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id          uuid NOT NULL REFERENCES rule,
  version_no       int  NOT NULL,
  tenant_id        uuid REFERENCES tenant,     -- 鏡射父規則，供 RLS 咬合
  posting_layer_id uuid NOT NULL REFERENCES posting_layer,
  effective_from   date,
  effective_to     date,
  supersedes_version_id uuid REFERENCES rule_version,
  legal_reference  text,
  trigger_condition jsonb,                     -- 保存，本刀不執行
  journal_template  jsonb,                     -- 保存，本刀不執行
  automation_level text NOT NULL DEFAULT 'SUGGEST_ONLY'
                     CHECK (automation_level IN ('SUGGEST_ONLY','AUTO_POST')),
  -- 沿用 data_coverage.granularity 的既有四值（0003）：INV-23 是兩者的比較，
  -- 值域不同就比不了，也會產生兩套詞彙。不另造 LINE。
  required_granularity text NOT NULL CHECK (required_granularity IN
                         ('BALANCE','JOURNAL','SUBLEDGER','DOCUMENT')),
  drafted_by       uuid NOT NULL REFERENCES app_user,
  peer_reviewed_by uuid REFERENCES app_user,   -- DRAFT 可空：否則草稿無法存在
  status           text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (rule_id, version_no)
);
CREATE INDEX rule_version_rule_idx ON rule_version (rule_id, status);

CREATE FUNCTION fn_rule_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_eng_tenant uuid;
BEGIN
  IF NEW.engagement_id IS NOT NULL THEN
    SELECT tenant_id INTO v_eng_tenant FROM client_engagement WHERE engagement_id = NEW.engagement_id;
    -- 外鍵表達不了「engagement 必須屬於這個 tenant」的跨欄條件
    IF v_eng_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'INV-18：規則的案件（%）不屬於本租戶', NEW.engagement_id;
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.scope_level IS DISTINCT FROM OLD.scope_level
    OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
    OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
    OR NEW.rule_type IS DISTINCT FROM OLD.rule_type THEN
      RAISE EXCEPTION 'RULE_IDENTITY_IMMUTABLE: 規則的歸屬與類型建立後不可變更（改 rule_type 會使既有版本的層一致性追溯失效）';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_rule_guard BEFORE INSERT OR UPDATE ON rule
  FOR EACH ROW EXECUTE FUNCTION fn_rule_guard();

CREATE FUNCTION fn_rule_version_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_rule_type text; v_rule_tenant uuid; v_layer_type text; v_drafter_tenant uuid;
BEGIN
  SELECT rule_type, tenant_id INTO v_rule_type, v_rule_tenant FROM rule WHERE rule_id = NEW.rule_id;
  IF NEW.tenant_id IS DISTINCT FROM v_rule_tenant THEN
    RAISE EXCEPTION 'INV-18：規則版本的 tenant_id 必須鏡射父規則（父為 %，本列為 %）', v_rule_tenant, NEW.tenant_id;
  END IF;

  SELECT rule_type INTO v_layer_type FROM posting_layer WHERE layer_id = NEW.posting_layer_id;
  -- rule_type IS NULL 的層（TRANSLATION_ADJUSTMENT）**顯式拒絕**，不是默默通過。
  -- 依賴 NULL = x → NULL 的沉默正是 0006／0007 點名的繞過型態。
  IF v_layer_type IS NULL THEN
    RAISE EXCEPTION 'LAYER_RULE_TYPE_UNSET: 此分層的 rule_type 尚未確定（逐筆歸屬隨折算刀），不得被規則版本引用';
  END IF;
  IF v_layer_type IS DISTINCT FROM v_rule_type THEN
    RAISE EXCEPTION 'RULE_TYPE_LAYER_MISMATCH: 規則類型（%）與分層的類型（%）不一致——四類規則不可混記', v_rule_type, v_layer_type;
  END IF;

  IF NEW.automation_level = 'AUTO_POST' THEN
    RAISE EXCEPTION 'AUTO_POST_NOT_IMPLEMENTED: 自動過帳尚未實作（GB-05：任何自動結果初始狀態一律為建議）';
  END IF;

  IF NEW.tenant_id IS NOT NULL THEN
    SELECT tenant_id INTO v_drafter_tenant FROM app_user WHERE user_id = NEW.drafted_by;
    IF v_drafter_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'INV-18：規則草案人（%）不屬於本租戶', NEW.drafted_by;
    END IF;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.rule_id IS DISTINCT FROM OLD.rule_id
    OR NEW.version_no IS DISTINCT FROM OLD.version_no
    OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
    OR NEW.posting_layer_id IS DISTINCT FROM OLD.posting_layer_id THEN
      RAISE EXCEPTION 'RULE_VERSION_IMMUTABLE: 規則版本的身分與分層建立後不可變更';
    END IF;
    -- drafted_by 是 SOD-H3 比較的基準；改寫比較基準與跳過檢查是同一個洞
    IF NEW.drafted_by IS DISTINCT FROM OLD.drafted_by THEN
      RAISE EXCEPTION 'RULE_VERSION_IMMUTABLE: 草案人不可變更——SOD-H3 比較的基準不得被改寫';
    END IF;
    -- 同行覆核人首次設定後不可再改（可從 NULL 設為某人，不可換人、不可清空）
    IF OLD.peer_reviewed_by IS NOT NULL AND NEW.peer_reviewed_by IS DISTINCT FROM OLD.peer_reviewed_by THEN
      RAISE EXCEPTION 'RULE_VERSION_IMMUTABLE: 同行覆核人首次設定後不可變更';
    END IF;
    IF OLD.status = 'RETIRED' AND NEW.status <> 'RETIRED' THEN
      RAISE EXCEPTION 'RULE_VERSION_IMMUTABLE: 已退役的規則版本不可復活';
    END IF;
    IF OLD.status = 'ACTIVE' AND NEW.status = 'DRAFT' THEN
      RAISE EXCEPTION 'RULE_VERSION_IMMUTABLE: 已生效的規則版本不可退回草稿（退役請改為 RETIRED）';
    END IF;
    -- SOD-H3 的檢查點：不是建立當下，而是進入 ACTIVE 的那一刻
    IF NEW.status = 'ACTIVE' AND OLD.status <> 'ACTIVE' THEN
      IF NEW.peer_reviewed_by IS NULL THEN
        RAISE EXCEPTION 'SODH3_PEER_REVIEW_REQUIRED: 規則版本生效前必須完成同行覆核';
      END IF;
      IF NEW.peer_reviewed_by = NEW.drafted_by THEN
        RAISE EXCEPTION 'SODH3_PEER_REVIEW_REQUIRED: 草案人（%）不得同行覆核自己的規則版本', NEW.drafted_by;
      END IF;
    END IF;
  ELSE
    IF NEW.status <> 'DRAFT' THEN
      RAISE EXCEPTION 'RULE_VERSION_MUST_START_DRAFT: 新建規則版本只能是 DRAFT——不得以 INSERT 跳過同行覆核';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_rule_version_guard BEFORE INSERT OR UPDATE ON rule_version
  FOR EACH ROW EXECUTE FUNCTION fn_rule_version_guard();

-- ══ 六、TaxBasisObservation：B 的唯一權威來源 ═══════════════════════
CREATE TABLE tax_basis_observation (
  observation_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  engagement_id     uuid NOT NULL REFERENCES client_engagement,
  reporting_unit_id uuid NOT NULL REFERENCES reporting_unit,
  as_of_date        date NOT NULL,
  book_basis_id     uuid NOT NULL REFERENCES book_basis,
  account_id        uuid REFERENCES account,      -- MISSING 時可空＝整體缺漏
  amount            numeric(20,2),
  evidence_status   text NOT NULL CHECK (evidence_status IN
                      ('PROVISIONAL','FILED','AMENDED','MISSING')),
  source_dataset_id uuid REFERENCES source_dataset,
  confirmed_by      uuid REFERENCES app_user,
  confirmed_role    role_code,                    -- **由 DB 寫入**，不接受呼叫端宣告
  confirmed_at      timestamptz,
  missing_reason    text,
  owner_id          uuid REFERENCES app_user,
  due_date          date,
  created_at        timestamptz NOT NULL DEFAULT now()
);
-- 唯一性約束全部列；NULL account_id 視為相同值。少了 NULLS NOT DISTINCT，
-- PostgreSQL 視 NULL 互不相等，同一基礎同一日期可插入無限多列整體缺漏的 MISSING。
CREATE UNIQUE INDEX tax_basis_observation_uq
  ON tax_basis_observation (book_basis_id, reporting_unit_id, as_of_date, account_id)
  NULLS NOT DISTINCT;

CREATE FUNCTION fn_tax_observation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_mode text; v_b_tenant uuid; v_b_eng uuid; v_policy uuid;
  v_role role_code; v_unit_eng uuid; v_has_role int;
BEGIN
  -- AMENDED 需要取代鏈（原子函式、延遲外鍵、權限封鎖、競態、ImpactAssessment），
  -- 本刀不做。守衛未實作 ≠ 守衛通過：明確 fail closed，不以原地 UPDATE 假裝支援。
  IF NEW.evidence_status = 'AMENDED' THEN
    RAISE EXCEPTION 'AMENDED_NOT_IMPLEMENTED: 更正申告的取代鏈尚未實作，AMENDED 在本版不可寫入（歷史期間版本不得覆寫）';
  END IF;

  -- 不可變性先於一切內容檢查：否則「改寫確認人」會先撞上角色檢查而以錯誤理由被拒，
  -- 讓「身分欄位凍結」這條規則其實從未被驗證過。
  IF TG_OP = 'UPDATE' THEN
    IF NEW.book_basis_id IS DISTINCT FROM OLD.book_basis_id
    OR NEW.reporting_unit_id IS DISTINCT FROM OLD.reporting_unit_id
    OR NEW.as_of_date IS DISTINCT FROM OLD.as_of_date
    OR NEW.account_id IS DISTINCT FROM OLD.account_id THEN
      RAISE EXCEPTION 'TAX_OBS_IMMUTABLE: 觀測的身分欄位（基礎／單位／日期／科目）不可變更';
    END IF;
    IF OLD.confirmed_by IS NOT NULL AND NEW.confirmed_by IS DISTINCT FROM OLD.confirmed_by THEN
      RAISE EXCEPTION 'TAX_OBS_IMMUTABLE: 確認人建立後不可變更';
    END IF;
  END IF;

  SELECT source_mode, tenant_id, engagement_id, basis_source_policy_version_id
    INTO v_mode, v_b_tenant, v_b_eng, v_policy
    FROM book_basis WHERE basis_id = NEW.book_basis_id;
  IF v_mode IS DISTINCT FROM 'DIRECT_AUTHORITATIVE_IMPORT' THEN
    RAISE EXCEPTION 'TAX_OBS_BASIS_NOT_DIRECT: 稅務基礎觀測只適用於權威匯入基礎（本基礎為 %）', COALESCE(v_mode,'不存在');
  END IF;
  IF v_b_tenant IS DISTINCT FROM NEW.tenant_id OR v_b_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：觀測的基礎（%）不屬於本案件', NEW.book_basis_id;
  END IF;
  SELECT engagement_id INTO v_unit_eng FROM reporting_unit WHERE reporting_unit_id = NEW.reporting_unit_id;
  IF v_unit_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：觀測的報告單位（%）不屬於本案件', NEW.reporting_unit_id;
  END IF;

  -- ── 欄位契約依 evidence_status 分流 ──
  IF NEW.evidence_status = 'MISSING' THEN
    -- MISSING 是「已登記的缺漏」：必須有原因、負責人與截止日（§24.4 GB-02 補充）
    IF COALESCE(NEW.missing_reason,'') = '' OR NEW.owner_id IS NULL OR NEW.due_date IS NULL THEN
      RAISE EXCEPTION 'TAX_OBS_FIELD_CONTRACT: MISSING 必須登記缺漏原因、負責人與截止日';
    END IF;
    -- 沒有數字就沒有人能確認它
    IF NEW.confirmed_by IS NOT NULL OR NEW.confirmed_role IS NOT NULL OR NEW.confirmed_at IS NOT NULL THEN
      RAISE EXCEPTION 'TAX_OBS_FIELD_CONTRACT: MISSING 不得帶確認人或確認時間';
    END IF;
    IF NEW.amount IS NOT NULL OR NEW.source_dataset_id IS NOT NULL THEN
      RAISE EXCEPTION 'TAX_OBS_FIELD_CONTRACT: MISSING 不得帶金額或來源資料集';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.account_id IS NULL OR NEW.amount IS NULL OR NEW.source_dataset_id IS NULL THEN
    RAISE EXCEPTION 'TAX_OBS_FIELD_CONTRACT: 非 MISSING 的觀測必須有科目、金額與來源資料集';
  END IF;
  IF NEW.missing_reason IS NOT NULL OR NEW.owner_id IS NOT NULL OR NEW.due_date IS NOT NULL THEN
    RAISE EXCEPTION 'TAX_OBS_FIELD_CONTRACT: 非 MISSING 的觀測不得帶缺漏欄位';
  END IF;
  IF NEW.confirmed_by IS NULL THEN
    RAISE EXCEPTION 'TAX_OBS_FIELD_CONTRACT: 非 MISSING 的觀測必須記錄確認人（INV-05）';
  END IF;

  -- ── 確認角色：confirmed_by 非空**不等於**「經指定稅務專業角色確認」 ──
  -- 只驗非空的話，任何使用者 UUID 都能填進去，GB-02 就只是一個外鍵而已。
  SELECT confirmation_role INTO v_role
    FROM basis_source_policy_version WHERE basis_source_policy_version_id = v_policy;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'BASIS_SOURCE_POLICY_REQUIRED: 本基礎沒有可解析的權威來源政策，無從判定指定稅務專業角色';
  END IF;
  SELECT count(*) INTO v_has_role
    FROM role_assignment ra JOIN app_user u ON u.user_id = ra.user_id
   WHERE ra.user_id = NEW.confirmed_by AND ra.role = v_role
     AND ra.revoked_at IS NULL AND u.is_active
     AND ra.tenant_id = NEW.tenant_id AND u.tenant_id = NEW.tenant_id
     AND (ra.engagement_id IS NULL OR ra.engagement_id = NEW.engagement_id);
  IF v_has_role = 0 THEN
    RAISE EXCEPTION 'TAX_CONFIRMER_ROLE_INVALID: 確認人未於本案件持有有效未撤銷的 % 角色指派（政策指定角色）', v_role;
  END IF;

  -- 角色快照由 DB 寫入並**無條件覆寫**呼叫端的宣告：
  -- 只驗角色不寫快照，角色日後撤銷時歷史無從還原（INV-11）；
  -- 只寫快照不驗角色，等於讓呼叫端自己蓋章。兩者必須成對。
  NEW.confirmed_role := v_role;
  NEW.confirmed_at   := COALESCE(NEW.confirmed_at, now());
  RETURN NEW;
END $$;
CREATE TRIGGER trg_tax_obs_guard BEFORE INSERT OR UPDATE ON tax_basis_observation
  FOR EACH ROW EXECUTE FUNCTION fn_tax_observation_guard();

-- ══ 七、基礎餘額：唯一的加總定義 ═══════════════════════════════════
--
-- COMPOSED 一側**必須讀該 run 的 manifest 所凍結的組成版本**，不是「目前生效的組成」——
-- 否則同一筆調節在組成 v2 落地後重驗會得到不同結論（INV-21／INV-29）。
CREATE FUNCTION fn_basis_account_balance(p_run uuid, p_basis uuid)
RETURNS TABLE (account_id uuid, amount numeric) LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_mode text; v_comp uuid; v_unit uuid; v_asof date; v_rev uuid;
BEGIN
  SELECT source_mode INTO v_mode FROM book_basis WHERE basis_id = p_basis;
  IF v_mode IS NULL THEN
    RAISE EXCEPTION 'BASIS_NOT_FOUND: 基礎（%）不存在', p_basis;
  END IF;

  SELECT cr.period_revision_id INTO v_rev FROM calculation_run cr
   WHERE cr.calculation_run_id = p_run;
  SELECT rp.reporting_unit_id, rp.end_date INTO v_unit, v_asof
    FROM period_revision pr JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = v_rev;

  IF v_mode = 'DIRECT_AUTHORITATIVE_IMPORT' THEN
    RETURN QUERY
      SELECT o.account_id, SUM(o.amount)
        FROM tax_basis_observation o
       WHERE o.book_basis_id = p_basis AND o.reporting_unit_id = v_unit
         AND o.as_of_date = v_asof AND o.evidence_status <> 'MISSING'
       GROUP BY o.account_id;
    RETURN;
  END IF;

  SELECT e.object_id INTO v_comp
    FROM calculation_manifest_entry e
    JOIN calculation_run cr ON cr.manifest_id = e.manifest_id
   WHERE cr.calculation_run_id = p_run AND e.object_type = 'BASIS_COMPOSITION'
     AND (e.payload->>'basis_id')::uuid = p_basis;
  IF v_comp IS NULL THEN
    -- 0023 之前的 run：凍結清單沒有組成版本，快照列的 posting_layer_id 也是 NULL。
    -- 不得靜默把 SOURCE_TB 當成 LOCAL_BOOK——那是替歷史 run 追加一個它沒凍結的假設。
    RAISE EXCEPTION 'RECON_RUN_PREDATES_BASIS_MODEL: 此計算執行的凍結清單未含本基礎的組成版本，無法據以計算基礎餘額';
  END IF;

  RETURN QUERY
    SELECT b.account_id, SUM(i.sign * (b.debit - b.credit))
      FROM balance_snapshot_line b
      JOIN constitutive_layer_item i ON i.layer_id = b.posting_layer_id
     WHERE b.calculation_run_id = p_run
       AND i.basis_composition_version_id = v_comp
     GROUP BY b.account_id;
END $$;

-- ══ 八、調節模型：BasisReconciliation（DRAFT → FINALIZED） ═══════════
CREATE TABLE basis_reconciliation (
  reconciliation_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenant,
  engagement_id      uuid NOT NULL REFERENCES client_engagement,
  reporting_unit_id  uuid NOT NULL REFERENCES reporting_unit,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  from_basis_id      uuid NOT NULL REFERENCES book_basis,
  to_basis_id        uuid NOT NULL REFERENCES book_basis,
  calculation_run_id uuid NOT NULL REFERENCES calculation_run,
  status             text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','FINALIZED')),
  finalized_by       uuid REFERENCES app_user,
  finalized_at       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (from_basis_id <> to_basis_id),
  UNIQUE (calculation_run_id, reporting_unit_id, from_basis_id, to_basis_id)
);

CREATE TABLE reconciliation_line (
  line_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant,
  reconciliation_id uuid NOT NULL REFERENCES basis_reconciliation,
  account_id        uuid NOT NULL REFERENCES account,
  amount            numeric(20,2) NOT NULL,
  source_adjustment_id   uuid REFERENCES adjustment,
  source_rule_version_id uuid REFERENCES rule_version,
  description       text NOT NULL,
  -- 調節列必須說得出「是誰造成的」；兩者恰有一個非空
  CHECK ((source_adjustment_id IS NULL) <> (source_rule_version_id IS NULL)),
  CHECK (description <> '')
);
CREATE INDEX recon_line_idx ON reconciliation_line (reconciliation_id, account_id);

CREATE TABLE reconciliation_difference (
  diff_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenant,
  reconciliation_id  uuid NOT NULL REFERENCES basis_reconciliation,
  account_id         uuid NOT NULL REFERENCES account,
  dimensions         jsonb NOT NULL DEFAULT '{}'::jsonb,
  amount             numeric(20,2) NOT NULL,
  -- 狀態在欄位裡，不在實體名稱裡（§26.5 L1165）：
  -- 「還有多少未解釋差異」一律查 resolution_status = 'OPEN'，不看 reason_class。
  reason_class       text NOT NULL CHECK (reason_class IN
                       ('UNEXPLAINED','ROUNDING','TIMING','MAPPING','SOURCE_DATA','POLICY','OTHER')),
  resolution_status  text NOT NULL DEFAULT 'OPEN' CHECK (resolution_status IN
                       ('OPEN','EXPLAINED','RESOLVED','RESOLVED_BY_POLICY','ACCEPTED_EXCEPTION')),
  owner_id           uuid REFERENCES app_user,
  due_date           date,
  threshold_policy_version_id uuid,
  resolution_ref     text
);
CREATE INDEX recon_diff_idx ON reconciliation_difference (reconciliation_id, resolution_status);

CREATE FUNCTION fn_reconciliation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_f_eng uuid; v_t_eng uuid; v_run_eng uuid; v_run_rev uuid; v_run_tenant uuid;
  v_pr_eng uuid; v_pr_unit uuid;
BEGIN
  IF TG_OP = 'INSERT' AND NEW.status <> 'DRAFT' THEN
    RAISE EXCEPTION 'RECON_INSERT_MUST_BE_DRAFT: 新建調節只能是 DRAFT——不得以 INSERT 跳過 FINALIZE 的 INV-02 驗證';
  END IF;

  SELECT engagement_id INTO v_f_eng FROM book_basis WHERE basis_id = NEW.from_basis_id;
  SELECT engagement_id INTO v_t_eng FROM book_basis WHERE basis_id = NEW.to_basis_id;
  IF v_f_eng IS DISTINCT FROM NEW.engagement_id OR v_t_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：調節端點的基礎不屬於本案件';
  END IF;

  SELECT engagement_id, period_revision_id, tenant_id INTO v_run_eng, v_run_rev, v_run_tenant
    FROM calculation_run WHERE calculation_run_id = NEW.calculation_run_id;
  IF v_run_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：計算執行（%）不屬於本租戶', NEW.calculation_run_id;
  END IF;
  IF v_run_eng IS DISTINCT FROM NEW.engagement_id OR v_run_rev IS DISTINCT FROM NEW.period_revision_id THEN
    RAISE EXCEPTION '§24.1A：計算執行（%）不屬於本調節的案件或期間', NEW.calculation_run_id;
  END IF;

  SELECT rp.engagement_id, rp.reporting_unit_id INTO v_pr_eng, v_pr_unit
    FROM period_revision pr JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = NEW.period_revision_id;
  IF v_pr_eng IS DISTINCT FROM NEW.engagement_id OR v_pr_unit IS DISTINCT FROM NEW.reporting_unit_id THEN
    RAISE EXCEPTION '§24.1A：期間（%）不屬於本調節的案件或報告單位', NEW.period_revision_id;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.status = 'FINALIZED' THEN
      RAISE EXCEPTION 'RECON_FINALIZED_IMMUTABLE: 已定稿的調節結果不可變更（重算＝建立新的調節與新的 run）';
    END IF;
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
    OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
    OR NEW.reporting_unit_id IS DISTINCT FROM OLD.reporting_unit_id
    OR NEW.period_revision_id IS DISTINCT FROM OLD.period_revision_id
    OR NEW.from_basis_id IS DISTINCT FROM OLD.from_basis_id
    OR NEW.to_basis_id IS DISTINCT FROM OLD.to_basis_id
    OR NEW.calculation_run_id IS DISTINCT FROM OLD.calculation_run_id THEN
      RAISE EXCEPTION 'RECON_IDENTITY_IMMUTABLE: 調節的身分欄位不可變更';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_recon_guard BEFORE INSERT OR UPDATE ON basis_reconciliation
  FOR EACH ROW EXECUTE FUNCTION fn_reconciliation_guard();

-- 子物件：只在 DRAFT 期間可動。FOR SHARE 與 finalize 的 FOR UPDATE 互斥——
-- 少了它，FINALIZE 驗完平衡、尚未提交的空隙間插入的新列會使 FINALIZED 結果不平（0021 的形狀）。
-- SECURITY DEFINER：PostgreSQL 的 SELECT … FOR SHARE 需要 UPDATE 權限，
-- 而 basis_reconciliation 的 UPDATE 已對 app_runtime 收回（唯一入口）。
-- 以擁有者身分取鎖，並在函式內自行比對租戶。
CREATE FUNCTION fn_recon_child_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE
  v_recon uuid; v_status text; v_tenant uuid; v_acc_tenant uuid; v_acc uuid;
BEGIN
  v_recon := CASE WHEN TG_OP = 'DELETE' THEN OLD.reconciliation_id ELSE NEW.reconciliation_id END;
  SELECT status, tenant_id INTO v_status, v_tenant
    FROM basis_reconciliation WHERE reconciliation_id = v_recon FOR SHARE;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'RECON_NOT_FOUND: 調節不存在（%）', v_recon;
  END IF;
  IF v_status <> 'DRAFT' THEN
    RAISE EXCEPTION 'RECON_FINALIZED_IMMUTABLE: 調節已定稿，明細與差異不可再增刪改';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  IF v_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：子列的 tenant_id 與父調節不符';
  END IF;
  v_acc := NEW.account_id;
  SELECT tenant_id INTO v_acc_tenant FROM account WHERE account_id = v_acc;
  IF v_acc_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：科目（%）不屬於本租戶', v_acc;
  END IF;

  IF TG_TABLE_NAME = 'reconciliation_difference' THEN
    -- INV-24：自動結案須**同時**滿足單筆與同期間×同幣別×同折算 run 的累積容許值。
    -- MaterialityThreshold 本刀不存在 → 兩個容許值都無法判定 → fail closed。
    -- 守衛未實作 ≠ 守衛通過。
    IF NEW.resolution_status = 'RESOLVED_BY_POLICY' THEN
      RAISE EXCEPTION 'INV24_THRESHOLD_NOT_IMPLEMENTED: 重要性門檻尚未實作，尾差自動結案在本版不可用（單筆與累積容許值皆無從判定）';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_recon_line_guard BEFORE INSERT OR UPDATE OR DELETE ON reconciliation_line
  FOR EACH ROW EXECUTE FUNCTION fn_recon_child_guard();
CREATE TRIGGER trg_recon_diff_guard BEFORE INSERT OR UPDATE OR DELETE ON reconciliation_difference
  FOR EACH ROW EXECUTE FUNCTION fn_recon_child_guard();

-- FINALIZE：INV-02 的**完成點**。逐列即時平衡做不到（第一列插入必然不平），
-- 因此平衡在此一次驗證，通過後整組凍結。
CREATE FUNCTION fn_reconciliation_finalize(p_reconciliation uuid, p_actor uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE
  r record; v_bad record; v_missing text; v_asof date;
BEGIN
  -- FOR UPDATE：與子列守衛的 FOR SHARE 互斥，消除「驗完平衡後才插入新列」的競態
  SELECT * INTO r FROM basis_reconciliation
   WHERE reconciliation_id = p_reconciliation FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RECON_NOT_FOUND: 調節不存在';
  END IF;
  -- 本函式以擁有者身分執行（繞過 RLS），必須自行比對租戶
  IF r.tenant_id IS DISTINCT FROM current_tenant() THEN
    RAISE EXCEPTION 'CROSS_TENANT_DENIED: 調節不屬於目前租戶';
  END IF;
  IF r.status <> 'DRAFT' THEN
    RAISE EXCEPTION 'RECON_FINALIZED_IMMUTABLE: 調節已定稿，不可重複定稿';
  END IF;

  SELECT rp.end_date INTO v_asof
    FROM period_revision pr JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = r.period_revision_id;

  -- INV-05：涉權威匯入基礎者，涵蓋範圍內每個科目都必須有非 MISSING 且經角色確認的觀測。
  -- 「某個時點值不存在一列」DB 沒有觸發時機可以拒絕，因此檢查掛在這個具體操作上。
  SELECT string_agg(DISTINCT a.code, '、' ORDER BY a.code) INTO v_missing
    FROM (
      SELECT l.account_id FROM reconciliation_line l WHERE l.reconciliation_id = p_reconciliation
      UNION
      SELECT d.account_id FROM reconciliation_difference d WHERE d.reconciliation_id = p_reconciliation
    ) x
    JOIN account a ON a.account_id = x.account_id
   WHERE EXISTS (SELECT 1 FROM book_basis b
                  WHERE b.basis_id IN (r.from_basis_id, r.to_basis_id)
                    AND b.source_mode = 'DIRECT_AUTHORITATIVE_IMPORT')
     AND NOT EXISTS (
       SELECT 1 FROM tax_basis_observation o
        JOIN book_basis b2 ON b2.basis_id = o.book_basis_id
                          AND b2.source_mode = 'DIRECT_AUTHORITATIVE_IMPORT'
        WHERE o.book_basis_id IN (r.from_basis_id, r.to_basis_id)
          AND o.reporting_unit_id = r.reporting_unit_id
          AND o.as_of_date = v_asof
          AND o.account_id = x.account_id
          AND o.evidence_status <> 'MISSING'
          AND o.confirmed_by IS NOT NULL);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'INV05_TAX_OBSERVATION_MISSING: 下列科目於 % 缺少已確認的稅務基礎觀測：%', v_asof, v_missing;
  END IF;

  -- INV-02（逐科目）：to − from = sum(Line) + sum(Difference)。殘差必須有去處。
  SELECT * INTO v_bad FROM (
    SELECT COALESCE(t.account_id, f.account_id, l.account_id, d.account_id) AS acc,
           COALESCE(t.amount,0) - COALESCE(f.amount,0)
             - COALESCE(l.amount,0) - COALESCE(d.amount,0) AS residual
      FROM fn_basis_account_balance(r.calculation_run_id, r.to_basis_id) t
      FULL JOIN fn_basis_account_balance(r.calculation_run_id, r.from_basis_id) f
             ON f.account_id = t.account_id
      FULL JOIN (SELECT account_id, SUM(amount) amount FROM reconciliation_line
                  WHERE reconciliation_id = p_reconciliation GROUP BY account_id) l
             ON l.account_id = COALESCE(t.account_id, f.account_id)
      FULL JOIN (SELECT account_id, SUM(amount) amount FROM reconciliation_difference
                  WHERE reconciliation_id = p_reconciliation GROUP BY account_id) d
             ON d.account_id = COALESCE(t.account_id, f.account_id, l.account_id)
  ) z WHERE residual <> 0 LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'INV02_RECONCILIATION_IMBALANCE: 科目 % 的調節殘差為 %，必須落入調節明細或差異（尾差不得靜默吸收）',
      v_bad.acc, v_bad.residual;
  END IF;

  UPDATE basis_reconciliation
     SET status = 'FINALIZED', finalized_by = p_actor, finalized_at = now()
   WHERE reconciliation_id = p_reconciliation;

  INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, object_type, object_id, payload)
  VALUES (r.tenant_id, 'DOMAIN_EVENT', 'basis_reconciliation.finalized', p_actor,
          'basis_reconciliation', p_reconciliation,
          jsonb_build_object('from_basis', r.from_basis_id, 'to_basis', r.to_basis_id,
                             'calculation_run', r.calculation_run_id));
END $$;

-- ══ 九、既有實體接線 ═══════════════════════════════════════════════

-- 9-1 manifest 增加 BASIS_COMPOSITION 凍結型別（INV-21／INV-29 的牙齒）
ALTER TABLE calculation_manifest_entry DROP CONSTRAINT calculation_manifest_entry_object_type_check;
ALTER TABLE calculation_manifest_entry ADD CONSTRAINT calculation_manifest_entry_object_type_check
  CHECK (object_type IN
    ('SCOPE','SOURCE_TB','MAPPING_RULE','ADJUSTMENT','CHART_OF_ACCOUNTS','BASIS_COMPOSITION'));

-- 9-2 BalanceSnapshotLine：新增分層外鍵。既有列不回寫。
ALTER TABLE balance_snapshot_line ADD COLUMN posting_layer_id uuid REFERENCES posting_layer;

-- 版本界線由 DB 判定，不靠 worker 紀律：manifest 是否凍結了組成版本，
-- 同時決定「這是分層模型之後的 run」與「因此快照必須帶層」。
CREATE FUNCTION fn_bsl_layer_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_has_comp int;
BEGIN
  SELECT count(*) INTO v_has_comp
    FROM calculation_manifest_entry e
    JOIN calculation_run cr ON cr.manifest_id = e.manifest_id
   WHERE cr.calculation_run_id = NEW.calculation_run_id AND e.object_type = 'BASIS_COMPOSITION';
  IF v_has_comp > 0 AND NEW.posting_layer_id IS NULL THEN
    RAISE EXCEPTION 'BSL_POSTING_LAYER_REQUIRED: 本 run 的凍結清單含組成版本，快照列必須標示 posting_layer_id';
  END IF;
  IF v_has_comp = 0 AND NEW.posting_layer_id IS NOT NULL THEN
    RAISE EXCEPTION 'BSL_POSTING_LAYER_UNEXPECTED: 本 run 的凍結清單不含組成版本（早於分層模型），快照列不得標示 posting_layer_id';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_bsl_layer BEFORE INSERT ON balance_snapshot_line
  FOR EACH ROW EXECUTE FUNCTION fn_bsl_layer_guard();

-- 9-3 JournalEntry：只帶分層，**不帶 basis_id**。
-- 在構成模型下，一筆事實屬於某個 PostingLayer；「哪些基礎包含它」由
-- ConstitutiveLayerItem 回答。若在分錄上釘死 basis_id，日後新增的基礎只要在其
-- composition 納入同一層，同一筆事實就會同時經 composition 被算進去、又帶著寫死的
-- basis_id——兩個彼此競爭的加總鍵，而且錯的那一個查得到。
ALTER TABLE journal_entry ADD COLUMN posting_layer_id uuid REFERENCES posting_layer;

-- 9-4 Adjustment：basis 硬約束欄位退役，改為 §26.8 形狀
ALTER TABLE adjustment ADD COLUMN basis_from_id    uuid REFERENCES book_basis;
ALTER TABLE adjustment ADD COLUMN basis_to_id      uuid REFERENCES book_basis;
ALTER TABLE adjustment ADD COLUMN posting_layer_id uuid REFERENCES posting_layer;
ALTER TABLE adjustment ADD COLUMN rule_version_id  uuid REFERENCES rule_version;

-- 既有案件補建 A／C 兩個基礎與其組成版本（全新資料庫無案件，本段為空操作；
-- 開發種子另行建立含 B 的完整組合）。組成版本以 DRAFT 建立後再批准——
-- APPROVED 需要批准人快照，而遷移沒有合法的批准身分可用，因此**不種 APPROVED**：
-- 沒有真正的 R4 批准就不假裝有（與平台規則零列同一原則）。
DO $$
DECLARE e record; v_a uuid; v_c uuid; v_ca uuid; v_cc uuid;
BEGIN
  FOR e IN SELECT engagement_id, tenant_id FROM client_engagement LOOP
    INSERT INTO book_basis (tenant_id, engagement_id, code, jurisdiction, framework,
                            source_mode, permits_group_layer)
    VALUES (e.tenant_id, e.engagement_id, 'A', 'JP', 'JP_GAAP', 'COMPOSED', false)
    ON CONFLICT (engagement_id, code) DO NOTHING;
    INSERT INTO book_basis (tenant_id, engagement_id, code, jurisdiction, framework,
                            source_mode, permits_group_layer)
    VALUES (e.tenant_id, e.engagement_id, 'C', 'CN', 'CN_CAS', 'COMPOSED', true)
    ON CONFLICT (engagement_id, code) DO NOTHING;

    SELECT basis_id INTO v_a FROM book_basis
      WHERE engagement_id = e.engagement_id AND code = 'A';   -- seed-data（非約束）
    SELECT basis_id INTO v_c FROM book_basis
      WHERE engagement_id = e.engagement_id AND code = 'C';   -- seed-data（非約束）

    INSERT INTO basis_composition_version (composition_series_id, version_no, tenant_id,
            engagement_id, basis_id, status)
    VALUES (gen_random_uuid(), 1, e.tenant_id, e.engagement_id, v_a, 'DRAFT')
    RETURNING basis_composition_version_id INTO v_ca;
    INSERT INTO constitutive_layer_item (basis_composition_version_id, layer_id, sign)
    VALUES (v_ca, '10000000-0000-0000-0000-000000000001', 1);

    INSERT INTO basis_composition_version (composition_series_id, version_no, tenant_id,
            engagement_id, basis_id, status)
    VALUES (gen_random_uuid(), 1, e.tenant_id, e.engagement_id, v_c, 'DRAFT')
    RETURNING basis_composition_version_id INTO v_cc;
    INSERT INTO constitutive_layer_item (basis_composition_version_id, layer_id, sign) VALUES
      (v_cc, '10000000-0000-0000-0000-000000000001', 1),
      (v_cc, '10000000-0000-0000-0000-000000000003', 1);
  END LOOP;
END $$;

-- 既有調整回填為 A→C ＋ GROUP_GAAP_ADJ（basis 舊值只有 'GROUP_GAAP' 一種，語意等價）
UPDATE adjustment a
   SET basis_from_id = (SELECT basis_id FROM book_basis
                         WHERE engagement_id = a.engagement_id AND code = 'A'),  -- seed-data（非約束）
       basis_to_id   = (SELECT basis_id FROM book_basis
                         WHERE engagement_id = a.engagement_id AND code = 'C'),  -- seed-data（非約束）
       posting_layer_id = '10000000-0000-0000-0000-000000000003'
 WHERE basis_from_id IS NULL;

ALTER TABLE adjustment ALTER COLUMN basis_from_id    SET NOT NULL;
ALTER TABLE adjustment ALTER COLUMN basis_to_id      SET NOT NULL;
ALTER TABLE adjustment ALTER COLUMN posting_layer_id SET NOT NULL;

-- 守衛先換再 DROP：plpgsql 於執行時解析欄位，先 DROP 會讓下一次 UPDATE 直接爆掉。
-- 除凍結清單中的 basis → 三個新欄位之外，其餘與 0009 完全相同。
CREATE OR REPLACE FUNCTION fn_adjustment_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  legal boolean;
  n_lines int;
  changed boolean;
BEGIN
  changed := (OLD.status IS DISTINCT FROM NEW.status);

  -- prepared_by 是兩個 SoD 比較的基準，不得被改寫（0006 的同一個洞）
  IF NEW.prepared_by IS DISTINCT FROM OLD.prepared_by THEN
    RAISE EXCEPTION '編製人（prepared_by）不可變更——SoD 比較的基準不得被改寫';
  END IF;

  -- 歸屬與分類欄位建立後即凍結：調整不得在生命週期中換租戶、換案件、換期間、
  -- 換基礎、換分層或換重要性等級。少了這條，DRAFTING 的調整可被改到同租戶另一案件，
  -- 而既有明細仍指向舊案件的科目；換分層則會追溯改變 INV-03／INV-04 的判定。
  IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
  OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
  OR NEW.period_revision_id IS DISTINCT FROM OLD.period_revision_id
  OR NEW.basis_from_id IS DISTINCT FROM OLD.basis_from_id
  OR NEW.basis_to_id IS DISTINCT FROM OLD.basis_to_id
  OR NEW.posting_layer_id IS DISTINCT FROM OLD.posting_layer_id
  OR NEW.materiality IS DISTINCT FROM OLD.materiality THEN
    RAISE EXCEPTION '歸屬與分類欄位建立後不可變更（tenant／engagement／period_revision／basis_from／basis_to／posting_layer／materiality）';
  END IF;

  IF OLD.status = 'APPROVED' THEN
    RAISE EXCEPTION '已批准調整（%）不可修改，變更請建立新的 business version', OLD.adjustment_id;
  END IF;

  -- ── 控制關鍵欄位的變動紀律（同狀態與遷移皆適用） ──
  IF NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by
     OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at THEN
    IF changed AND NEW.status = 'PENDING_APPROVAL' AND OLD.reviewed_by IS NULL THEN
      NULL;                                       -- 首次覆核
    ELSIF changed AND NEW.status = 'DRAFTING' AND OLD.status = 'PENDING_APPROVAL'
          AND NEW.reviewed_by IS NULL THEN
      NULL;                                       -- 退回使覆核失效
    ELSE
      RAISE EXCEPTION '覆核人只能在進入 PENDING_APPROVAL 時記錄、在退回時清空——不得改寫（SOD-01 的比較基準）';
    END IF;
  END IF;

  IF NEW.approved_by IS DISTINCT FROM OLD.approved_by
     OR NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
    IF NOT (changed AND NEW.status = 'APPROVED' AND OLD.approved_by IS NULL) THEN
      RAISE EXCEPTION '批准人只能在進入 APPROVED 時記錄——不得改寫';
    END IF;
  END IF;

  IF NEW.business_version IS DISTINCT FROM OLD.business_version AND NOT changed THEN
    RAISE EXCEPTION 'business_version 只能隨狀態遷移變動（同狀態改寫屬繞過守衛）';
  END IF;

  IF NOT changed THEN
    IF OLD.status <> 'DRAFTING' THEN
      IF NEW.title IS DISTINCT FROM OLD.title
      OR NEW.legal_basis IS DISTINCT FROM OLD.legal_basis
      OR NEW.evidence_ref IS DISTINCT FROM OLD.evidence_ref
      OR NEW.judgment_reason IS DISTINCT FROM OLD.judgment_reason
      OR NEW.language_tag IS DISTINCT FROM OLD.language_tag
      OR NEW.object_version IS DISTINCT FROM OLD.object_version THEN
        RAISE EXCEPTION '調整已離開草稿階段（%），表頭內容不可再變更', OLD.status;
      END IF;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
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

  IF NEW.status IN ('PENDING_REVIEW','APPROVED') THEN
    IF COALESCE(NEW.legal_basis, '')     = '' OR COALESCE(NEW.evidence_ref, '')  = ''
    OR COALESCE(NEW.judgment_reason, '') = '' OR COALESCE(NEW.language_tag, '')  = '' THEN
      RAISE EXCEPTION 'G-08：必要證據未齊（法源／政策、附件、判斷理由、語言標籤缺一不可）';
    END IF;
  END IF;

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

  -- G-04／SOD-01；覆核人與覆核時間同為必填（直接下 SQL 也不得留空）
  IF NEW.status = 'PENDING_APPROVAL' THEN
    IF NEW.reviewed_by IS NULL THEN
      RAISE EXCEPTION 'G-04／SOD-01：覆核必須記錄覆核人';
    END IF;
    IF NEW.reviewed_at IS NULL THEN
      RAISE EXCEPTION '覆核必須記錄覆核時間（AC-WFL-001：退回、重開、修改均須有理由與時間）';
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
    IF NEW.approved_at IS NULL THEN
      RAISE EXCEPTION '批准必須記錄批准時間';
    END IF;
    IF NEW.reviewed_by IS NULL THEN
      RAISE EXCEPTION '批准前必須完成覆核';
    END IF;
    IF NEW.approved_by = NEW.reviewed_by THEN
      RAISE EXCEPTION 'G-05／SOD-02：重大調整的覆核人（%）不得兼任批准人', NEW.reviewed_by;
    END IF;
    IF NEW.approved_by = NEW.prepared_by THEN
      RAISE EXCEPTION 'AC-WFL-001：編製人（%）不得批准自己編製的重大調整，與當下角色無關',
        NEW.prepared_by;
    END IF;
  END IF;

  IF NEW.status = 'DRAFTING' AND OLD.status = 'PENDING_APPROVAL' THEN
    IF NEW.reviewed_by IS NOT NULL OR NEW.reviewed_at IS NOT NULL THEN
      RAISE EXCEPTION '從 PENDING_APPROVAL 退回時既有覆核必須失效（reviewed_by／reviewed_at 須清空）';
    END IF;
  END IF;

  IF NEW.business_version <> OLD.business_version + 1 THEN
    RAISE EXCEPTION '狀態遷移 % → % 必須將 business_version 由 % 前進為 %',
      OLD.status, NEW.status, OLD.business_version, OLD.business_version + 1;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;

ALTER TABLE adjustment DROP COLUMN basis;

-- 9-5 INV-03／INV-04：兩個獨立的守衛，掛在調整建立時
CREATE FUNCTION fn_adjustment_basis_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_f_eng uuid; v_t_eng uuid; v_scope text; v_unit_scope text; v_permits boolean;
  v_rv_layer uuid; v_rv_status text; v_rv_tenant uuid;
BEGIN
  SELECT engagement_id INTO v_f_eng FROM book_basis WHERE basis_id = NEW.basis_from_id;
  SELECT engagement_id, permits_group_layer INTO v_t_eng, v_permits
    FROM book_basis WHERE basis_id = NEW.basis_to_id;
  IF v_f_eng IS DISTINCT FROM NEW.engagement_id OR v_t_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：調整的基礎不屬於本案件';
  END IF;
  IF NEW.basis_from_id = NEW.basis_to_id THEN
    RAISE EXCEPTION 'ADJ_BASIS_BRIDGE_INVALID: 調整的來源與目標基礎不得相同（橋樑必須跨兩個基礎）';
  END IF;

  SELECT scope_type INTO v_scope FROM posting_layer WHERE layer_id = NEW.posting_layer_id;
  SELECT ru.unit_scope INTO v_unit_scope
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
    JOIN reporting_unit ru ON ru.reporting_unit_id = rp.reporting_unit_id
   WHERE pr.period_revision_id = NEW.period_revision_id;

  -- INV-03：層的 scope 與報告單位的型別必須相符
  IF (v_scope = 'ENTITY' AND v_unit_scope <> 'LEGAL_ENTITY')
  OR (v_scope = 'GROUP'  AND v_unit_scope <> 'CONSOLIDATION_GROUP') THEN
    RAISE EXCEPTION 'INV03_SCOPE_MISMATCH: % scope 的分層不得寫入 % 型別的報告單位', v_scope, v_unit_scope;
  END IF;

  -- INV-04：群組層的調整不得寫入不允許群組層的基礎（日本法定帳不得出現抵銷分錄）
  IF v_scope = 'GROUP' AND NOT v_permits THEN
    RAISE EXCEPTION 'INV04_GROUP_ADJ_INTO_LOCAL_BASIS: 群組層調整不得寫入不允許群組層的基礎';
  END IF;

  IF NEW.rule_version_id IS NOT NULL THEN
    SELECT posting_layer_id, status, tenant_id INTO v_rv_layer, v_rv_status, v_rv_tenant
      FROM rule_version WHERE rule_version_id = NEW.rule_version_id;
    IF v_rv_tenant IS NOT NULL AND v_rv_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'INV-18：規則版本（%）不屬於本租戶', NEW.rule_version_id;
    END IF;
    IF v_rv_status <> 'ACTIVE' THEN
      RAISE EXCEPTION 'RULE_VERSION_NOT_ACTIVE: 只能引用已生效的規則版本（目前 %）', v_rv_status;
    END IF;
    -- 比「rule_type 相同」更嚴：後者仍允許同類型不同層的錯配
    IF v_rv_layer IS DISTINCT FROM NEW.posting_layer_id THEN
      RAISE EXCEPTION 'ADJ_LAYER_RULE_MISMATCH: 調整的分層與所引用規則版本的分層不一致';
    END IF;
  END IF;
  RETURN NEW;
END $$;
-- 觸發器名稱刻意排在 trg_adjustment_tenant 之後（PostgreSQL 依名稱順序觸發）：
-- 租戶／案件歸屬要先被判定，否則跨案件的插入會先撞上「基礎不屬於本案件」，
-- 讓 INV-18 的負面測試**以錯誤的理由通過**。
CREATE TRIGGER trg_adjustment_wiring BEFORE INSERT ON adjustment
  FOR EACH ROW EXECUTE FUNCTION fn_adjustment_basis_guard();

-- 9-6 JournalEntry 的分層由 Adjustment 物化時帶入，且必須一致、不可變
CREATE FUNCTION fn_journal_entry_layer_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_layer uuid;
BEGIN
  SELECT posting_layer_id INTO v_layer FROM adjustment WHERE adjustment_id = NEW.adjustment_id;
  IF NEW.posting_layer_id IS NULL THEN
    RAISE EXCEPTION 'JE_POSTING_LAYER_REQUIRED: 物化分錄必須標示分層（INV-03／INV-04 的判定依據）';
  END IF;
  IF NEW.posting_layer_id IS DISTINCT FROM v_layer THEN
    RAISE EXCEPTION 'JE_LAYER_MISMATCH: 物化分錄的分層必須等於調整的分層——不得於物化時改寫';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_je_layer BEFORE INSERT ON journal_entry
  FOR EACH ROW EXECUTE FUNCTION fn_journal_entry_layer_guard();

-- ══ 十、權限與 RLS ═════════════════════════════════════════════════

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'basis_source_policy_version','book_basis','basis_composition_version',
    'tax_basis_observation','basis_reconciliation','reconciliation_line',
    'reconciliation_difference'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant())', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO app_runtime', t);
  END LOOP;
END $$;
-- 調節只能經 finalize 函式定稿：少了這步，app_runtime 可直接 UPDATE status='FINALIZED'
-- 繞過 INV-02 與 INV-05（0022 唯一入口模式）。必須在上面的 GRANT 迴圈**之後**收回。
REVOKE UPDATE ON basis_reconciliation FROM app_runtime;

-- constitutive_layer_item 無 tenant_id：以父版本的租戶隔離，經 EXISTS 掛 RLS
ALTER TABLE constitutive_layer_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE constitutive_layer_item FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON constitutive_layer_item
  USING (EXISTS (SELECT 1 FROM basis_composition_version c
                  WHERE c.basis_composition_version_id = constitutive_layer_item.basis_composition_version_id
                    AND c.tenant_id = current_tenant()))
  WITH CHECK (EXISTS (SELECT 1 FROM basis_composition_version c
                  WHERE c.basis_composition_version_id = constitutive_layer_item.basis_composition_version_id
                    AND c.tenant_id = current_tenant()));
GRANT SELECT, INSERT, UPDATE, DELETE ON constitutive_layer_item TO app_runtime;

-- rule／rule_version：PLATFORM 列全租戶可讀；WITH CHECK 要求 tenant_id = current_tenant()，
-- 因此 app_runtime **寫不出** PLATFORM 列（tenant_id 為 NULL 必然不等於當前租戶）。
-- 這正是「平台規則唯讀」的機制——不靠應用層自律。
ALTER TABLE rule ENABLE ROW LEVEL SECURITY;
ALTER TABLE rule FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON rule
  USING (scope_level = 'PLATFORM' OR tenant_id = current_tenant())
  WITH CHECK (tenant_id = current_tenant());
GRANT SELECT, INSERT, UPDATE, DELETE ON rule TO app_runtime;

ALTER TABLE rule_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE rule_version FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON rule_version
  USING (tenant_id IS NULL OR tenant_id = current_tenant())
  WITH CHECK (tenant_id = current_tenant());
GRANT SELECT, INSERT, UPDATE, DELETE ON rule_version TO app_runtime;

REVOKE ALL ON FUNCTION fn_reconciliation_finalize(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_reconciliation_finalize(uuid, uuid) TO app_runtime;
GRANT EXECUTE ON FUNCTION fn_basis_account_balance(uuid, uuid) TO app_runtime;
