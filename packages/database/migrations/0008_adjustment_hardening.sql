-- 0008 Adjustment 硬化（SLICE-M2-02A 覆核回饋）
-- 0007 的守衛只在「狀態有變」時檢查，留下兩個實測可繞過的洞：
--
--   1. 同狀態 UPDATE 直接返回 → 進入 PENDING_APPROVAL 後仍可改寫 reviewed_by。
--      實測：UPDATE adjustment SET reviewed_by = <編製人> 成功，SOD-01 在 DB 層被完全繞過；
--      併發的第二次覆核也會覆蓋第一位覆核人。
--   2. tenant_id 是自填欄位，RLS 只比對它；engagement_id／period_revision_id 的
--      FK 不保證同租戶。實測：以 T1 身分寫入指向 T2 案件的調整成功（違反 INV-18）。
--
-- 修法：把「控制關鍵欄位只能在對應的狀態遷移中變動」併進主守衛（而非另掛 trigger——
-- 同事件的多個 BEFORE trigger 依名稱排序執行，順序一旦錯開，錯誤訊息會指向錯的守衛），
-- 並為 02A 新增的五張表補上跨租戶歸屬守衛。

-- 交易內斷言：psql 不會在 dollar-quoted 區塊內插值，因此無法用 DO $$ ... $$ 搭配 :'參數'。
-- 以函式形式提供，讓應用層能在單一交易裡「條件不成立就整批回滾」。
CREATE FUNCTION fn_assert(p_cond boolean, p_msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE(p_cond, false) THEN
    RAISE EXCEPTION '%', p_msg;
  END IF;
END $$;

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

  -- 已批准調整不可改寫；變更＝新增 business version
  IF OLD.status = 'APPROVED' THEN
    RAISE EXCEPTION '已批准調整（%）不可修改，變更請建立新的 business version', OLD.adjustment_id;
  END IF;

  -- ── 控制關鍵欄位的變動紀律（同狀態與遷移皆適用；0007 的漏洞在此封死） ──
  -- reviewed_by／reviewed_at：只在「進入 PENDING_APPROVAL」時首次設定，
  -- 只在「PENDING_APPROVAL 退回 DRAFTING」時清空。其餘任何變動都是繞過。
  -- 這同時擋住併發的第二次覆核覆蓋第一位覆核人。
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

  -- approved_by／approved_at：只在「進入 APPROVED」時首次設定。
  IF NEW.approved_by IS DISTINCT FROM OLD.approved_by
     OR NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
    IF NOT (changed AND NEW.status = 'APPROVED' AND OLD.approved_by IS NULL) THEN
      RAISE EXCEPTION '批准人只能在進入 APPROVED 時記錄——不得改寫';
    END IF;
  END IF;

  -- business_version 不得在同狀態下被改寫（里程碑鏈只能隨遷移前進）
  IF NEW.business_version IS DISTINCT FROM OLD.business_version AND NOT changed THEN
    RAISE EXCEPTION 'business_version 只能隨狀態遷移變動（同狀態改寫屬繞過守衛）';
  END IF;

  IF NOT changed THEN
    -- 已離開草稿階段：表頭凍結（明細由 trg_adjustment_line_guard 凍結）。
    -- 唯一例外是控制判定欄位——G-04 拒絕時需在同狀態下記錄「只能預覽」。
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

  -- G-08（§25.13）：四項必要證據缺一不可
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

  -- 每次合法遷移都是業務里程碑：business_version 必須前進一格（ADR-M2-001）
  IF NEW.business_version <> OLD.business_version + 1 THEN
    RAISE EXCEPTION '狀態遷移 % → % 必須將 business_version 由 % 前進為 %',
      OLD.status, NEW.status, OLD.business_version, OLD.business_version + 1;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- ── 跨租戶歸屬守衛（INV-18：不得跨 Tenant 引用） ──────────────
-- RLS 比對的是列自己的 tenant_id；父物件屬於哪個租戶，一般 FK 不管。
-- 沒有這層，「tenant_id 填自己、engagement_id 指別人」就能寫入成功。
CREATE FUNCTION fn_adjustment_tenant_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_eng uuid; v_pr uuid; v_prep uuid;
BEGIN
  SELECT tenant_id INTO v_eng FROM client_engagement WHERE engagement_id = NEW.engagement_id;
  SELECT tenant_id INTO v_pr FROM period_revision WHERE period_revision_id = NEW.period_revision_id;
  SELECT tenant_id INTO v_prep FROM app_user WHERE user_id = NEW.prepared_by;
  IF v_eng IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：調整的案件（%）不屬於本租戶', NEW.engagement_id;
  END IF;
  IF v_pr IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：調整的報告期間（%）不屬於本租戶', NEW.period_revision_id;
  END IF;
  IF v_prep IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：編製人（%）不屬於本租戶', NEW.prepared_by;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_adjustment_tenant
  BEFORE INSERT OR UPDATE ON adjustment
  FOR EACH ROW EXECUTE FUNCTION fn_adjustment_tenant_guard();

CREATE FUNCTION fn_child_tenant_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_parent uuid; v_extra uuid;
BEGIN
  IF TG_TABLE_NAME = 'adjustment_line' THEN
    SELECT tenant_id INTO v_parent FROM adjustment WHERE adjustment_id = NEW.adjustment_id;
    SELECT tenant_id INTO v_extra FROM account WHERE account_id = NEW.target_account_id;
  ELSIF TG_TABLE_NAME = 'adjustment_version_snapshot' THEN
    SELECT tenant_id INTO v_parent FROM adjustment WHERE adjustment_id = NEW.adjustment_id;
    SELECT tenant_id INTO v_extra FROM app_user WHERE user_id = NEW.actor_id;
  ELSIF TG_TABLE_NAME = 'journal_entry' THEN
    SELECT tenant_id INTO v_parent FROM adjustment WHERE adjustment_id = NEW.adjustment_id;
    SELECT tenant_id INTO v_extra FROM client_engagement WHERE engagement_id = NEW.engagement_id;
  ELSE  -- journal_line
    SELECT tenant_id INTO v_parent FROM journal_entry WHERE entry_id = NEW.entry_id;
    SELECT tenant_id INTO v_extra FROM account WHERE account_id = NEW.account_id;
  END IF;
  IF v_parent IS DISTINCT FROM NEW.tenant_id OR v_extra IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：% 引用了不屬於本租戶的父物件或科目', TG_TABLE_NAME;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_adjustment_line_tenant BEFORE INSERT OR UPDATE ON adjustment_line
  FOR EACH ROW EXECUTE FUNCTION fn_child_tenant_guard();
CREATE TRIGGER trg_avs_tenant BEFORE INSERT ON adjustment_version_snapshot
  FOR EACH ROW EXECUTE FUNCTION fn_child_tenant_guard();
CREATE TRIGGER trg_journal_entry_tenant BEFORE INSERT ON journal_entry
  FOR EACH ROW EXECUTE FUNCTION fn_child_tenant_guard();
CREATE TRIGGER trg_journal_line_tenant BEFORE INSERT ON journal_line
  FOR EACH ROW EXECUTE FUNCTION fn_child_tenant_guard();

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_runtime;
