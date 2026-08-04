-- 0009 Adjustment 歸屬與必填硬化（SLICE-M2-02A 第二輪覆核回饋）
-- 0008 的跨租戶守衛只確認「都是同一個 Tenant」，但沒有確認「屬於同一個案件」。
-- 同租戶跨案件的錯配仍可成立：
--   * adjustment.period_revision_id 可指向同租戶另一個 Engagement 的期間；
--   * DRAFTING 的調整可被改到同租戶另一案件，原有明細仍指向舊案件科目；
--   * journal_entry 可填同租戶另一案件／期間；
--   * journal_line 可引用同租戶另一案件的科目。
-- 另外建立後的歸屬欄位未凍結，且直接下 SQL 進入覆核／批准時 reviewed_at／approved_at 可為 NULL。

-- ── 一、主守衛：歸屬欄位凍結 ＋ 時間戳必填 ──────────────────
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
  -- 換基礎或換重要性等級。少了這條，DRAFTING 的調整可被改到同租戶另一案件，
  -- 而既有明細仍指向舊案件的科目。
  IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
  OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
  OR NEW.period_revision_id IS DISTINCT FROM OLD.period_revision_id
  OR NEW.basis IS DISTINCT FROM OLD.basis
  OR NEW.materiality IS DISTINCT FROM OLD.materiality THEN
    RAISE EXCEPTION '歸屬與分類欄位建立後不可變更（tenant／engagement／period_revision／basis／materiality）';
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

-- ── 二、建立時的案件一致性（同租戶不等於同案件） ──────────────
CREATE OR REPLACE FUNCTION fn_adjustment_tenant_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_eng uuid; v_pr uuid; v_prep uuid; v_pr_eng uuid;
BEGIN
  SELECT tenant_id INTO v_eng FROM client_engagement WHERE engagement_id = NEW.engagement_id;
  SELECT tenant_id INTO v_prep FROM app_user WHERE user_id = NEW.prepared_by;
  SELECT pr.tenant_id, rp.engagement_id INTO v_pr, v_pr_eng
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = NEW.period_revision_id;
  IF v_eng IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：調整的案件（%）不屬於本租戶', NEW.engagement_id;
  END IF;
  IF v_pr IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：調整的報告期間（%）不屬於本租戶', NEW.period_revision_id;
  END IF;
  IF v_prep IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：編製人（%）不屬於本租戶', NEW.prepared_by;
  END IF;
  -- 同租戶不等於同案件（§24.1A 歸屬完整性）
  IF v_pr_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '§24.1A：報告期間（%）屬於案件 %，與調整的案件 % 不一致',
      NEW.period_revision_id, v_pr_eng, NEW.engagement_id;
  END IF;
  RETURN NEW;
END $$;

-- ── 三、子物件：不只同租戶，還要同案件／同期間 ────────────────
CREATE OR REPLACE FUNCTION fn_child_tenant_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_parent uuid; v_extra uuid;
  v_adj_eng uuid; v_adj_pr uuid; v_acc_eng uuid;
BEGIN
  IF TG_TABLE_NAME = 'adjustment_line' THEN
    SELECT tenant_id INTO v_parent FROM adjustment WHERE adjustment_id = NEW.adjustment_id;
    SELECT tenant_id INTO v_extra FROM account WHERE account_id = NEW.target_account_id;

  ELSIF TG_TABLE_NAME = 'adjustment_version_snapshot' THEN
    SELECT tenant_id INTO v_parent FROM adjustment WHERE adjustment_id = NEW.adjustment_id;
    SELECT tenant_id INTO v_extra FROM app_user WHERE user_id = NEW.actor_id;

  ELSIF TG_TABLE_NAME = 'journal_entry' THEN
    SELECT tenant_id, engagement_id, period_revision_id INTO v_parent, v_adj_eng, v_adj_pr
      FROM adjustment WHERE adjustment_id = NEW.adjustment_id;
    SELECT tenant_id INTO v_extra FROM client_engagement WHERE engagement_id = NEW.engagement_id;
    -- 正式分錄的案件與期間必須與來源調整完全一致，不得填同租戶的其他案件／期間
    IF NEW.engagement_id IS DISTINCT FROM v_adj_eng THEN
      RAISE EXCEPTION '§24.1A：正式分錄的案件（%）與來源調整的案件（%）不一致',
        NEW.engagement_id, v_adj_eng;
    END IF;
    IF NEW.period_revision_id IS DISTINCT FROM v_adj_pr THEN
      RAISE EXCEPTION '§24.1A：正式分錄的期間（%）與來源調整的期間（%）不一致',
        NEW.period_revision_id, v_adj_pr;
    END IF;

  ELSE  -- journal_line
    SELECT tenant_id INTO v_parent FROM journal_entry WHERE entry_id = NEW.entry_id;
    SELECT tenant_id INTO v_extra FROM account WHERE account_id = NEW.account_id;
    -- 科目必須屬於來源調整所屬案件的科目表
    SELECT adj.engagement_id INTO v_adj_eng
      FROM journal_entry je JOIN adjustment adj ON adj.adjustment_id = je.adjustment_id
     WHERE je.entry_id = NEW.entry_id;
    SELECT c.engagement_id INTO v_acc_eng
      FROM account a JOIN chart_of_accounts c ON c.coa_id = a.coa_id
     WHERE a.account_id = NEW.account_id;
    IF v_acc_eng IS DISTINCT FROM v_adj_eng THEN
      RAISE EXCEPTION '§24.1A：正式分錄的科目屬案件 %，與來源調整的案件 % 不一致',
        v_acc_eng, v_adj_eng;
    END IF;
  END IF;

  IF v_parent IS DISTINCT FROM NEW.tenant_id OR v_extra IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：% 引用了不屬於本租戶的父物件或科目', TG_TABLE_NAME;
  END IF;
  RETURN NEW;
END $$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_runtime;
