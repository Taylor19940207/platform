-- 0022 ReportingPeriod 期間生命週期（SLICE-M2-05）
-- 契約：docs/slices/SLICE-M2-05_期間生命週期.md
--
-- 現況缺陷：
--   1. period_revision.status 的 CHECK 只有 SETUP／OPEN／LOCKED／REOPENED——
--      §25.8 的 13 狀態被簡化後寫死在 DB 裡。
--   2. status DEFAULT 'OPEN'：新建 revision 直接跳過 SETUP，
--      繞開 SETUP → OPEN 的 R4 與 G-10 控制。
--   3. 無任何遷移守衛，狀態可任意跳關。
--
-- 本檔把 §27 M7 的 attemptTransition 做成 **DB 唯一裁決點**：所有守衛只寫一份，
-- 應用層不得也不需要再判一次（02A 缺口 2 的教訓）。
--
-- 「唯一裁決點」不只是把規則寫進 trigger，還必須封掉所有繞道：
--   * INSERT 也要守（否則直接 INSERT status='DELIVERED' 就跳過整套狀態機）
--   * 身分欄位無條件凍結（否則遷移時順手改 revision_no／tenant_id）
--   * 發起人與角色必須由 DB 自行驗證（不能相信呼叫者傳什麼就是什麼）
--   * 直接寫入權限收回，只留受控函式（否則 app_runtime 自行 set_config 即可繞過）

-- ── 一、狀態集合擴為 §25.8 全 13 值 ──────────────────────────
ALTER TABLE period_revision DROP CONSTRAINT IF EXISTS period_revision_status_check;
ALTER TABLE period_revision ADD CONSTRAINT period_revision_status_check
  CHECK (status IN (
    'SETUP','OPEN','IN_PREPARATION','IN_REVIEW','AWAITING_REVIEWER','ADJ_APPROVED',
    'CALCULATING','RECONCILING','PENDING_PKG_APPR','LOCKED','DELIVERED',
    'REOPENED','PREVIEW_ONLY'));

-- 新建 revision 必須從 SETUP 開始；既有資料保持原狀（不追溯改寫歷史）
ALTER TABLE period_revision ALTER COLUMN status SET DEFAULT 'SETUP';

-- ── 二、首期以顯式欄位保存，不得推導、建立後不可改 ──────────
ALTER TABLE reporting_period ADD COLUMN is_initial_period boolean NOT NULL DEFAULT false;

-- 已知偏差：基線 §26 L1120 的 CalendarUsage(purpose=GROUP_REPORTING) 現行 schema
-- 不存在，故只能落在 (reporting_unit_id, fiscal_calendar_id)。
CREATE UNIQUE INDEX reporting_period_initial_uq
  ON reporting_period (reporting_unit_id, fiscal_calendar_id)
  WHERE is_initial_period;

CREATE FUNCTION fn_reporting_period_freeze() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.is_initial_period IS DISTINCT FROM OLD.is_initial_period THEN
    RAISE EXCEPTION 'INITIAL_PERIOD_IMMUTABLE: 首期旗標建立後不可變更（改動會追溯翻案 G-10 的判定）';
  END IF;
  IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
  OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
  OR NEW.reporting_unit_id IS DISTINCT FROM OLD.reporting_unit_id
  OR NEW.fiscal_calendar_id IS DISTINCT FROM OLD.fiscal_calendar_id THEN
    RAISE EXCEPTION 'PERIOD_ATTRIBUTION_IMMUTABLE: 期間歸屬欄位建立後不可變更';
  END IF;
  -- 期間日期與種類同樣凍結：end_date 是映射生效日的判定基準（M2-01），
  -- 進入覆核後改期間日期會追溯改變「當時採用哪一版映射」。
  IF NEW.start_date IS DISTINCT FROM OLD.start_date
  OR NEW.end_date IS DISTINCT FROM OLD.end_date
  OR NEW.period_kind IS DISTINCT FROM OLD.period_kind THEN
    RAISE EXCEPTION 'PERIOD_DATES_IMMUTABLE: 期間日期與種類建立後不可變更（end_date 決定映射生效版本）';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_reporting_period_freeze BEFORE UPDATE ON reporting_period
  FOR EACH ROW EXECUTE FUNCTION fn_reporting_period_freeze();

-- ── 三、ReviewerEligibilityEvaluation（§26.10 最小版，不可變＋不可偽造） ──
CREATE TABLE reviewer_eligibility_evaluation (
  evaluation_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenant,
  period_revision_id uuid NOT NULL REFERENCES period_revision,
  policy_version     text NOT NULL,
  evaluated_at       timestamptz NOT NULL DEFAULT now(),
  evaluated_by       uuid NOT NULL REFERENCES app_user,
  scope_object_count int  NOT NULL,
  fully_covered      boolean NOT NULL,
  resulting_status   text NOT NULL,
  -- 結果一致性：結論與落點不得互相矛盾
  CHECK ((fully_covered AND resulting_status = 'IN_REVIEW')
      OR (NOT fully_covered AND resulting_status = 'AWAITING_REVIEWER'))
);
CREATE TRIGGER trg_ree_immutable BEFORE UPDATE OR DELETE ON reviewer_eligibility_evaluation
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

-- 候選人評估：複製當時的角色指派快照值，而非只指向可變現況
CREATE TABLE reviewer_candidate_evaluation (
  candidate_eval_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenant,
  evaluation_id      uuid NOT NULL REFERENCES reviewer_eligibility_evaluation ON DELETE CASCADE,
  adjustment_id      uuid NOT NULL REFERENCES adjustment,
  candidate_user_id  uuid NOT NULL REFERENCES app_user,
  -- 快照值：指派本身日後被撤銷或改動，也不改變當時的評估事實
  role_assignment_id uuid REFERENCES role_assignment,
  snapshot_role      role_code NOT NULL,
  snapshot_engagement_id uuid,          -- NULL＝租戶層指派
  snapshot_granted_at    timestamptz NOT NULL,
  snapshot_user_active   boolean NOT NULL,
  eligible           boolean NOT NULL,
  exclusion_reason   text,
  CHECK (eligible OR exclusion_reason IS NOT NULL)
);
CREATE TRIGGER trg_rce_immutable BEFORE UPDATE OR DELETE ON reviewer_candidate_evaluation
  FOR EACH ROW EXECUTE FUNCTION fn_forbid_mutation();

CREATE INDEX ree_revision_idx ON reviewer_eligibility_evaluation (period_revision_id, evaluated_at DESC);

-- 父物件歸屬：候選列的調整必須屬於同一評估的期間與租戶
CREATE FUNCTION fn_rce_attribution_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_rev uuid; v_ten uuid; v_adj_rev uuid; v_adj_ten uuid;
BEGIN
  SELECT period_revision_id, tenant_id INTO v_rev, v_ten
    FROM reviewer_eligibility_evaluation WHERE evaluation_id = NEW.evaluation_id;
  SELECT period_revision_id, tenant_id INTO v_adj_rev, v_adj_ten
    FROM adjustment WHERE adjustment_id = NEW.adjustment_id;
  IF v_ten IS DISTINCT FROM NEW.tenant_id OR v_adj_ten IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：候選評估引用了不屬於本租戶的父物件或調整';
  END IF;
  IF v_adj_rev IS DISTINCT FROM v_rev THEN
    RAISE EXCEPTION '§24.1A：候選評估的調整（%）不屬於本次評估的期間', NEW.adjustment_id;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_rce_attribution BEFORE INSERT ON reviewer_candidate_evaluation
  FOR EACH ROW EXECUTE FUNCTION fn_rce_attribution_guard();

-- ── 四、覆核覆蓋評估（SECURITY DEFINER：只有本函式能寫入快照表） ──
-- 待覆核物件＝仍需要覆核動作的調整（DRAFTING／PENDING_REVIEW）。
-- 零調整期間＝空集合＝視為完整覆蓋，不得卡進 AWAITING_REVIEWER。
CREATE FUNCTION fn_period_evaluate_reviewers(p_revision uuid, p_actor uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE
  v_tenant uuid; v_eng uuid; v_eval uuid; v_scope int; v_covered boolean;
BEGIN
  SELECT pr.tenant_id, rp.engagement_id INTO v_tenant, v_eng
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = p_revision;
  -- 本函式以擁有者身分執行（superuser → 繞過 RLS），必須自行比對租戶
  IF v_tenant IS DISTINCT FROM current_tenant() THEN
    RAISE EXCEPTION 'CROSS_TENANT_DENIED: 期間不屬於目前租戶';
  END IF;

  SELECT count(*) INTO v_scope FROM adjustment a
   WHERE a.period_revision_id = p_revision AND a.status IN ('DRAFTING','PENDING_REVIEW');

  SELECT NOT EXISTS (
    SELECT 1 FROM adjustment a
     WHERE a.period_revision_id = p_revision AND a.status IN ('DRAFTING','PENDING_REVIEW')
       AND NOT EXISTS (
         SELECT 1 FROM role_assignment ra JOIN app_user u ON u.user_id = ra.user_id
          WHERE ra.role = 'R3' AND ra.revoked_at IS NULL AND u.is_active
            AND ra.tenant_id = v_tenant
            AND (ra.engagement_id IS NULL OR ra.engagement_id = v_eng)
            AND ra.user_id <> a.prepared_by))
  INTO v_covered;

  INSERT INTO reviewer_eligibility_evaluation (tenant_id, period_revision_id, policy_version,
          evaluated_by, scope_object_count, fully_covered, resulting_status)
  VALUES (v_tenant, p_revision, 'reviewer-policy-v1', p_actor, v_scope, v_covered,
          CASE WHEN v_covered THEN 'IN_REVIEW' ELSE 'AWAITING_REVIEWER' END)
  RETURNING evaluation_id INTO v_eval;

  INSERT INTO reviewer_candidate_evaluation (tenant_id, evaluation_id, adjustment_id,
          candidate_user_id, role_assignment_id, snapshot_role, snapshot_engagement_id,
          snapshot_granted_at, snapshot_user_active, eligible, exclusion_reason)
  SELECT v_tenant, v_eval, a.adjustment_id, ra.user_id, ra.role_assignment_id,
         ra.role, ra.engagement_id, ra.granted_at, u.is_active,
         (ra.user_id <> a.prepared_by),
         CASE WHEN ra.user_id = a.prepared_by
              THEN 'SOD-01：編製人不得覆核自己編製的調整' END
    FROM adjustment a
    JOIN role_assignment ra ON ra.role = 'R3' AND ra.revoked_at IS NULL
     AND ra.tenant_id = v_tenant AND (ra.engagement_id IS NULL OR ra.engagement_id = v_eng)
    JOIN app_user u ON u.user_id = ra.user_id AND u.is_active
   WHERE a.period_revision_id = p_revision AND a.status IN ('DRAFTING','PENDING_REVIEW');

  RETURN v_covered;
END $$;

-- ── 五、INSERT 守衛：新建 revision 只能是 SETUP ──────────────
CREATE FUNCTION fn_period_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_parent_tenant uuid; v_existing int;
BEGIN
  IF NEW.status <> 'SETUP' THEN
    RAISE EXCEPTION 'PERIOD_INSERT_MUST_BE_SETUP: 新建期間修訂只能是 SETUP（目前為 %）——不得以 INSERT 跳過狀態機', NEW.status;
  END IF;
  IF NEW.locked_at IS NOT NULL THEN
    RAISE EXCEPTION 'PERIOD_INSERT_MUST_BE_SETUP: 新建期間修訂不得帶 locked_at';
  END IF;

  SELECT tenant_id INTO v_parent_tenant FROM reporting_period
   WHERE reporting_period_id = NEW.reporting_period_id;
  IF v_parent_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'INV-18：期間修訂與父期間不同租戶';
  END IF;

  -- 本刀尚未實作重開：每個 ReportingPeriod 只能有一條 revision_no = 1 的修訂。
  -- 未來實作 REOPENED 時，由專用重開函式替換這條限制（見切片「後續驗收」）。
  IF NEW.revision_no <> 1 THEN
    RAISE EXCEPTION 'REVISION_CHAIN_NOT_IMPLEMENTED: 重開流程尚未實作，新建修訂的 revision_no 必須為 1（目前為 %）', NEW.revision_no;
  END IF;
  SELECT count(*) INTO v_existing FROM period_revision
   WHERE reporting_period_id = NEW.reporting_period_id;
  IF v_existing > 0 THEN
    RAISE EXCEPTION 'REVISION_CHAIN_NOT_IMPLEMENTED: 該報告期間已有修訂，重開流程尚未實作，不得逕行新增第二條';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_period_insert BEFORE INSERT ON period_revision
  FOR EACH ROW EXECUTE FUNCTION fn_period_insert_guard();

-- ── 六、唯一裁決點：期間狀態遷移守衛 ────────────────────────
CREATE FUNCTION fn_period_transition_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_actor uuid; v_role text; legal boolean;
  v_end date; v_initial boolean; v_eng uuid; v_tenant uuid;
  v_n int; v_covered boolean; v_has_role int;
BEGIN
  -- 身分欄位無條件凍結（不論狀態是否變動）
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

  -- 發起人必須真的持有該角色：同租戶、啟用中、且有未撤銷的 RoleAssignment。
  -- 不相信呼叫者傳進來的 p_role。
  SELECT count(*) INTO v_has_role
    FROM role_assignment ra JOIN app_user u ON u.user_id = ra.user_id
   WHERE ra.user_id = v_actor AND ra.role = v_role::role_code
     AND ra.revoked_at IS NULL AND u.is_active
     AND ra.tenant_id = v_tenant AND u.tenant_id = v_tenant
     AND (ra.engagement_id IS NULL OR ra.engagement_id = v_eng);
  IF v_has_role = 0 THEN
    RAISE EXCEPTION 'ACTOR_ROLE_NOT_HELD: 發起人未於本案件持有有效的 % 角色指派', v_role;
  END IF;

  -- 合法遷移表。AWAITING_REVIEWER 不在任何目標中——它只能由覆蓋評估改寫落點產生。
  legal := CASE OLD.status
    WHEN 'SETUP'             THEN NEW.status = 'OPEN'
    WHEN 'OPEN'              THEN NEW.status = 'IN_PREPARATION'
    WHEN 'IN_PREPARATION'    THEN NEW.status = 'IN_REVIEW'
    WHEN 'IN_REVIEW'         THEN NEW.status = 'ADJ_APPROVED'
    WHEN 'AWAITING_REVIEWER' THEN NEW.status = 'IN_REVIEW'
    WHEN 'ADJ_APPROVED'      THEN NEW.status = 'CALCULATING'
    WHEN 'CALCULATING'       THEN NEW.status = 'RECONCILING'
    WHEN 'RECONCILING'       THEN NEW.status = 'PENDING_PKG_APPR'
    WHEN 'PENDING_PKG_APPR'  THEN NEW.status = 'LOCKED'
    WHEN 'LOCKED'            THEN NEW.status = 'DELIVERED'
    ELSE false
  END;
  IF NOT legal THEN
    RAISE EXCEPTION 'ILLEGAL_TRANSITION: 非法期間狀態遷移 % → %（不得跳關）', OLD.status, NEW.status;
  END IF;

  -- 角色矩陣（§24.6）
  IF (OLD.status = 'SETUP' AND v_role <> 'R4')
  OR (OLD.status = 'OPEN' AND v_role <> 'R2')
  OR (OLD.status = 'IN_PREPARATION' AND v_role <> 'R2')
  OR (OLD.status = 'AWAITING_REVIEWER' AND v_role <> 'R2')
  OR (OLD.status = 'IN_REVIEW' AND v_role <> 'R4') THEN
    RAISE EXCEPTION 'ROLE_NOT_PERMITTED: 角色 % 不得發起 % → %', v_role, OLD.status, NEW.status;
  END IF;

  -- 後段各守衛尚未實作：各自回自己的穩定代碼，不得回 ILLEGAL_TRANSITION
  IF NEW.status = 'CALCULATING' THEN
    RAISE EXCEPTION 'G07_NOT_IMPLEMENTED: 匯率版本凍結守衛尚未實作，ADJ_APPROVED → CALCULATING 在本版不可用';
  END IF;
  IF NEW.status = 'RECONCILING' THEN
    RAISE EXCEPTION 'RECONCILE_NOT_IMPLEMENTED: 折算差額與調節核對尚未實作，CALCULATING → RECONCILING 在本版不可用';
  END IF;
  IF NEW.status = 'PENDING_PKG_APPR' THEN
    RAISE EXCEPTION 'G03_NOT_IMPLEMENTED: B 基礎（遞延稅）守衛尚未實作，RECONCILING → PENDING_PKG_APPR 在本版不可用';
  END IF;
  IF NEW.status = 'LOCKED' THEN
    RAISE EXCEPTION 'G06_NOT_IMPLEMENTED: 期間參與者去重計數守衛尚未實作，PENDING_PKG_APPR → LOCKED 在本版不可用';
  END IF;
  IF NEW.status = 'DELIVERED' THEN
    RAISE EXCEPTION 'G09_NOT_IMPLEMENTED: 控制總額守衛與 ExportJob 尚未實作，LOCKED → DELIVERED 在本版不可用';
  END IF;

  -- SETUP → OPEN：非首期須通過 G-10（尚未實作）
  IF OLD.status = 'SETUP' AND NOT v_initial THEN
    RAISE EXCEPTION 'G10_NOT_IMPLEMENTED: 前期銜接守衛尚未實作，非首期的 SETUP → OPEN 在本版不可用';
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

  -- 請求 IN_REVIEW（含由 AWAITING_REVIEWER 重新發起）：由 DB 評估覆蓋決定實際落點
  IF NEW.status = 'IN_REVIEW' THEN
    v_covered := fn_period_evaluate_reviewers(NEW.period_revision_id, v_actor);
    NEW.status := CASE WHEN v_covered THEN 'IN_REVIEW' ELSE 'AWAITING_REVIEWER' END;
    -- AWAITING_REVIEWER 進出不改變 revision_no（§25.8 L818）
  END IF;

  -- IN_REVIEW → ADJ_APPROVED：全期調整皆 APPROVED 且逐筆 SoD 復驗
  IF OLD.status = 'IN_REVIEW' AND NEW.status = 'ADJ_APPROVED' THEN
    SELECT count(*) INTO v_n FROM adjustment a
     WHERE a.period_revision_id = NEW.period_revision_id AND a.status <> 'APPROVED';
    IF v_n > 0 THEN
      RAISE EXCEPTION 'ADJ_NOT_ALL_APPROVED: 本期尚有 % 筆調整未批准', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM adjustment a
     WHERE a.period_revision_id = NEW.period_revision_id
       AND (a.reviewed_by IS NULL OR a.approved_by IS NULL
         OR a.reviewed_by = a.prepared_by      -- G-04／SOD-01
         OR a.approved_by = a.reviewed_by      -- G-05／SOD-02
         OR a.approved_by = a.prepared_by);    -- AC-WFL-001
    IF v_n > 0 THEN
      RAISE EXCEPTION 'PERIOD_SOD_VIOLATION: 本期有 % 筆調整不滿足逐筆職責分離復驗', v_n;
    END IF;
  END IF;

  RETURN NEW;
END $$;

CREATE TRIGGER trg_period_transition
  BEFORE UPDATE ON period_revision
  FOR EACH ROW EXECUTE FUNCTION fn_period_transition_guard();

-- ── 七、attemptTransition：應用層唯一入口（含同交易 DomainEvent） ──
-- 回傳「實際落點」——請求 IN_REVIEW 時可能因覆蓋不足而落在 AWAITING_REVIEWER。
CREATE FUNCTION fn_period_attempt_transition(
  p_revision uuid, p_expected_from text, p_to text, p_actor uuid, p_role text
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public AS $$
DECLARE v_from text; v_final text; v_tenant uuid;
BEGIN
  -- FOR UPDATE：兩個併發請求不得各自讀到同一個舊狀態後接力連跳
  SELECT status, tenant_id INTO v_from, v_tenant
    FROM period_revision WHERE period_revision_id = p_revision FOR UPDATE;
  IF v_from IS NULL THEN
    RAISE EXCEPTION 'PERIOD_NOT_FOUND: 期間修訂不存在';
  END IF;

  -- 本函式以擁有者身分執行（superuser → 繞過 RLS）。少了這道比對，
  -- 只要知道別的租戶的 revision UUID 與其一位有效 R4，即可跨租戶遷移。
  IF v_tenant IS DISTINCT FROM current_tenant() THEN
    RAISE EXCEPTION 'CROSS_TENANT_DENIED: 期間不屬於目前租戶';
  END IF;

  -- 樂觀鎖：呼叫者看到的狀態必須仍是目前狀態，否則舊畫面的請求可能
  -- 在別人先完成一步後，剛好變成「下一步合法遷移」。
  IF v_from IS DISTINCT FROM p_expected_from THEN
    RAISE EXCEPTION 'OPTIMISTIC_LOCK_CONFLICT: 期間狀態已由他人變更（你看到 %，目前為 %）',
      p_expected_from, v_from;
  END IF;

  -- 同狀態請求不是遷移：trigger 會直接放行，若照寫事件就會產生假的 period.transitioned
  IF p_to = v_from THEN
    RAISE EXCEPTION 'NO_OP_TRANSITION: 目標狀態與目前狀態相同（%），不構成遷移', v_from;
  END IF;

  PERFORM set_config('app.actor_id', p_actor::text, true);
  PERFORM set_config('app.acting_role', p_role, true);
  UPDATE period_revision SET status = p_to WHERE period_revision_id = p_revision;
  SELECT status INTO v_final FROM period_revision WHERE period_revision_id = p_revision;

  -- 遷移與 DomainEvent 同一交易：事件寫入失敗即整批回滾。
  -- requested 與 landed 分開記：請求 IN_REVIEW 卻落在 AWAITING_REVIEWER 時，
  -- 稽核軌跡必須看得出「他請求什麼、系統判給什麼」。
  INSERT INTO audit_event (tenant_id, kind, event_type, actor_id, acting_role,
          object_type, object_id, payload)
  VALUES (v_tenant, 'DOMAIN_EVENT', 'period.transitioned', p_actor, p_role::role_code,
          'period_revision', p_revision,
          jsonb_build_object('from', v_from, 'requested', p_to, 'landed', v_final));
  RETURN v_final;
END $$;

-- ── 八、收回直接寫入權；只留受控函式 ───────────────────────
-- 少了這步，app_runtime 仍可自行 set_config 後直接 UPDATE，繞過唯一入口。
REVOKE UPDATE ON period_revision FROM app_runtime;
-- DELETE 同屬繞道：尚無子資料的 SETUP／OPEN revision 可被直接刪除，完全不經狀態機，
-- 且既有 DomainEvent 會留下指向已消失物件的孤立引用。期間修訂只能新增與遷移，不可刪除。
REVOKE DELETE ON period_revision FROM app_runtime;
REVOKE INSERT, UPDATE, DELETE ON reviewer_eligibility_evaluation FROM app_runtime;
REVOKE INSERT, UPDATE, DELETE ON reviewer_candidate_evaluation FROM app_runtime;

-- ── 九、RLS ─────────────────────────────────────────────────
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['reviewer_eligibility_evaluation','reviewer_candidate_evaluation'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant())', t);
    EXECUTE format('GRANT SELECT ON %I TO app_runtime', t);
  END LOOP;
END $$;

-- 函式預設會授權給 PUBLIC——SECURITY DEFINER 下等於人人可執行，必須先收回。
REVOKE ALL ON FUNCTION fn_period_attempt_transition(uuid, text, text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_period_evaluate_reviewers(uuid, uuid) FROM PUBLIC;

-- 只授權唯一入口。helper 僅由 trigger 在 attempt 的 definer 脈絡下呼叫，
-- 不授權給 app_runtime——否則可繞過遷移直接產生評估快照。
GRANT EXECUTE ON FUNCTION fn_period_attempt_transition(uuid, text, text, uuid, text) TO app_runtime;
