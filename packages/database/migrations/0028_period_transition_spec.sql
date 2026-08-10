-- 0028 期間遷移規格：把 0022 內嵌的規則抽成**唯一可查詢來源**（SLICE-M3-01）
--
-- 0022 把合法遷移表與角色矩陣寫在 trigger 的 CASE／IF 裡。那對 DB 沒有問題——
-- 它本來就是唯一裁決點——但畫面無從得知「這一期現在能做什麼」。
-- B-02 若自行推導，就會出現第二份遷移表，而兩份規則遲早分岔。
--
-- 因此把規格抽成唯讀函式：trigger 呼叫它，B-02 也讀它。
-- **這不是新增控制，是換存放形式**：合法遷移、角色、fail closed 代碼與訊息
-- 一字不改，既有期間測試（DB 29＋端到端 37）即為回歸判準。
--
-- availability 三值：
--   AVAILABLE        結構上允許（是否真的能走，仍由 trigger 的聚合守衛判定）
--
-- required_role 對 NOT_IMPLEMENTED 的列一律 **NULL**：守衛都還沒實作，
-- 「誰可以發起」當然也還沒決定。填一個角色等於憑空發明規則，而且會讓
-- 角色檢查搶在 fail closed 之前觸發——0022 對那些遷移本來就沒有角色檢查。
--   NOT_IMPLEMENTED  守衛尚未實作，一律 fail closed
--   CONDITIONAL      結構上允許，但在指定條件下 fail closed（目前只有 G-10 非首期）
-- 畫面據此渲染；**能不能真的遷移永遠由 POST 時的 DB 重新判定**。

CREATE FUNCTION fn_period_transition_spec(p_from text)
RETURNS TABLE (
  requested_to       text,
  required_role      role_code,
  availability       text,
  unavailable_code   text,
  unavailable_reason text
) LANGUAGE sql IMMUTABLE AS $$
  SELECT s.requested_to, s.required_role::role_code, s.availability,
         s.unavailable_code, s.unavailable_reason
    FROM (VALUES
    -- from,               to,                  role,  availability,      code,                        reason
    ('SETUP',             'OPEN',              'R4'::text, 'CONDITIONAL',     'G10_NOT_IMPLEMENTED',
     '前期銜接守衛尚未實作，非首期的 SETUP → OPEN 在本版不可用'),
    ('OPEN',              'IN_PREPARATION',    'R2', 'AVAILABLE',        NULL, NULL),
    ('IN_PREPARATION',    'IN_REVIEW',         'R2', 'AVAILABLE',        NULL, NULL),
    ('AWAITING_REVIEWER', 'IN_REVIEW',         'R2', 'AVAILABLE',        NULL, NULL),
    ('IN_REVIEW',         'ADJ_APPROVED',      'R4', 'AVAILABLE',        NULL, NULL),
    ('ADJ_APPROVED',      'CALCULATING',       NULL, 'NOT_IMPLEMENTED', 'G07_NOT_IMPLEMENTED',
     '匯率版本凍結守衛尚未實作，ADJ_APPROVED → CALCULATING 在本版不可用'),
    ('CALCULATING',       'RECONCILING',       NULL, 'NOT_IMPLEMENTED', 'RECONCILE_NOT_IMPLEMENTED',
     '折算差額與調節核對尚未實作，CALCULATING → RECONCILING 在本版不可用'),
    ('RECONCILING',       'PENDING_PKG_APPR',  NULL, 'NOT_IMPLEMENTED', 'G03_NOT_IMPLEMENTED',
     'B 基礎（遞延稅）守衛尚未實作，RECONCILING → PENDING_PKG_APPR 在本版不可用'),
    ('PENDING_PKG_APPR',  'LOCKED',            NULL, 'NOT_IMPLEMENTED', 'G06_NOT_IMPLEMENTED',
     '期間參與者去重計數守衛尚未實作，PENDING_PKG_APPR → LOCKED 在本版不可用'),
    ('LOCKED',            'DELIVERED',         NULL, 'NOT_IMPLEMENTED', 'G09_NOT_IMPLEMENTED',
     '控制總額守衛與 ExportJob 尚未實作，LOCKED → DELIVERED 在本版不可用')
  ) AS s(from_status, requested_to, required_role, availability, unavailable_code, unavailable_reason)
  WHERE s.from_status = p_from
$$;

-- trigger 改為讀規格。判定順序與訊息與 0022 完全相同：
--   合法遷移 → 角色矩陣 → fail closed → 各段聚合守衛
CREATE OR REPLACE FUNCTION fn_period_transition_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_actor uuid; v_role text; spec record;
  v_end date; v_initial boolean; v_eng uuid; v_tenant uuid;
  v_n int; v_covered boolean; v_has_role int;
BEGIN
  IF NEW.revision_no IS DISTINCT FROM OLD.revision_no
  OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
  OR NEW.reporting_period_id IS DISTINCT FROM OLD.reporting_period_id
  OR NEW.period_revision_id IS DISTINCT FROM OLD.period_revision_id THEN
    RAISE EXCEPTION 'REVISION_IDENTITY_IMMUTABLE: 期間修訂的身分欄位不可變更（重開須建立新列，不得原地改寫）';
  END IF;

  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  v_actor := NULLIF(current_setting('app.actor_id', true), '')::uuid;
  v_role  := NULLIF(current_setting('app.acting_role', true), '');
  IF v_actor IS NULL OR v_role IS NULL THEN
    RAISE EXCEPTION 'TRANSITION_ACTOR_REQUIRED: 期間狀態只能經 fn_period_attempt_transition 遷移（須帶發起人與角色）';
  END IF;

  SELECT rp.end_date, rp.is_initial_period, rp.engagement_id, pr.tenant_id
    INTO v_end, v_initial, v_eng, v_tenant
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = NEW.period_revision_id;

  SELECT count(*) INTO v_has_role
    FROM role_assignment ra JOIN app_user u ON u.user_id = ra.user_id
   WHERE ra.user_id = v_actor AND ra.role = v_role::role_code
     AND ra.revoked_at IS NULL AND u.is_active
     AND ra.tenant_id = v_tenant AND u.tenant_id = v_tenant
     AND (ra.engagement_id IS NULL OR ra.engagement_id = v_eng);
  IF v_has_role = 0 THEN
    RAISE EXCEPTION 'ACTOR_ROLE_NOT_HELD: 發起人未於本案件持有有效的 % 角色指派', v_role;
  END IF;

  -- 合法遷移表：規格裡沒有這一列＝不合法。AWAITING_REVIEWER 不是任何列的目標——
  -- 它只能由覆蓋評估改寫落點產生。
  SELECT * INTO spec FROM fn_period_transition_spec(OLD.status) s
   WHERE s.requested_to = NEW.status;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ILLEGAL_TRANSITION: 非法期間狀態遷移 % → %（不得跳關）', OLD.status, NEW.status;
  END IF;

  -- required_role 為 NULL＝該遷移的守衛尚未實作，角色也尚未決定：跳過角色檢查，
  -- 讓 fail closed 成為拒絕理由（與 0022 相同）
  IF spec.required_role IS NOT NULL AND v_role::role_code <> spec.required_role THEN
    RAISE EXCEPTION 'ROLE_NOT_PERMITTED: 角色 % 不得發起 % → %', v_role, OLD.status, NEW.status;
  END IF;

  IF spec.availability = 'NOT_IMPLEMENTED' THEN
    RAISE EXCEPTION '%: %', spec.unavailable_code, spec.unavailable_reason;
  END IF;

  -- CONDITIONAL：結構上允許，但在指定條件下 fail closed（目前只有 G-10 非首期）
  IF spec.availability = 'CONDITIONAL' AND OLD.status = 'SETUP' AND NOT v_initial THEN
    RAISE EXCEPTION '%: %', spec.unavailable_code, spec.unavailable_reason;
  END IF;

  -- OPEN → IN_PREPARATION：至少一份 ACCEPTED ＋ BALANCE ＋ COMPLETE 的批次
  IF OLD.status = 'OPEN' THEN
    SELECT count(*) INTO v_n
      FROM import_batch ib
      JOIN data_coverage dc ON dc.import_batch_id = ib.import_batch_id
       AND dc.batch_version = ib.batch_version
     WHERE ib.declared_period_revision_id = NEW.period_revision_id
       AND ib.status = 'ACCEPTED' AND dc.granularity = 'BALANCE'
       AND dc.completeness_status = 'COMPLETE';
    IF v_n = 0 THEN
      RAISE EXCEPTION 'REQUIRED_DATA_INCOMPLETE: 本期尚無「已接受且聲明完整」的 BALANCE 批次（MVP 只要求完整 TB）';
    END IF;
  END IF;

  -- IN_PREPARATION → IN_REVIEW：期間級 G-02 聚合
  IF OLD.status = 'IN_PREPARATION' THEN
    SELECT count(*) INTO v_n
      FROM import_batch ib
      JOIN source_ledger_line sll ON sll.import_batch_id = ib.import_batch_id
     WHERE ib.declared_period_revision_id = NEW.period_revision_id
       AND ib.status = 'ACCEPTED'
       AND NOT EXISTS (
         SELECT 1 FROM mapping_rule mr
          WHERE mr.engagement_id = ib.engagement_id
            AND mr.source_account_code = sll.account_code
            AND mr.approved_at IS NOT NULL
            AND (mr.effective_from IS NULL OR mr.effective_from <= v_end)
            AND (mr.effective_to   IS NULL OR mr.effective_to   >= v_end));
    IF v_n > 0 THEN
      RAISE EXCEPTION 'G02_PERIOD_UNMAPPED: 本期尚有 % 列來源餘額未映射，不得進入覆核', v_n;
    END IF;
  END IF;

  IF NEW.status = 'IN_REVIEW' THEN
    v_covered := fn_period_evaluate_reviewers(NEW.period_revision_id, v_actor);
    NEW.status := CASE WHEN v_covered THEN 'IN_REVIEW' ELSE 'AWAITING_REVIEWER' END;
  END IF;

  IF OLD.status = 'IN_REVIEW' AND NEW.status = 'ADJ_APPROVED' THEN
    SELECT count(*) INTO v_n FROM adjustment a
     WHERE a.period_revision_id = NEW.period_revision_id AND a.status <> 'APPROVED';
    IF v_n > 0 THEN
      RAISE EXCEPTION 'ADJ_NOT_ALL_APPROVED: 本期尚有 % 筆調整未批准', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM adjustment a
     WHERE a.period_revision_id = NEW.period_revision_id
       AND (a.reviewed_by IS NULL OR a.approved_by IS NULL
         OR a.reviewed_by = a.prepared_by
         OR a.approved_by = a.reviewed_by
         OR a.approved_by = a.prepared_by);
    IF v_n > 0 THEN
      RAISE EXCEPTION 'PERIOD_SOD_VIOLATION: 本期有 % 筆調整不滿足逐筆職責分離復驗', v_n;
    END IF;
  END IF;

  RETURN NEW;
END $$;

-- app_runtime 只能執行；函式的擁有者不是它，因此改不動定義。
GRANT EXECUTE ON FUNCTION fn_period_transition_spec(text) TO app_runtime;
