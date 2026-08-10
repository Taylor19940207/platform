-- 0029 期間遷移的角色**作用域**：租戶層指派不得發起期間遷移
--
-- 缺陷（0022 起存在，0028 原樣搬運未察覺）：角色驗證寫成
--     AND (ra.engagement_id IS NULL OR ra.engagement_id = v_eng)
-- 那個 `IS NULL` 分支把**租戶層指派**當成對所有案件有效。於是租戶層 R4
-- 可以直接 POST 推動任何案件的期間——畫面擋得住，DB 擋不住，而 DB 才是
-- 唯一裁決點。B-02 的整頁 403 只是讓這個洞不容易被點到，不是封住它。
--
-- §26.3：R1～R5、R7 屬 EngagementAssignment。期間遷移用的是 R2／R4，
-- 兩者都在該清單內，因此「未指定案件的指派」對期間遷移**沒有**任何意義。
-- 唯一合法解讀是嚴格相等：
--     AND ra.engagement_id = v_eng
-- 這不是收緊政策，是修正一個把「限案件」讀成「不限案件」的實作錯誤。
-- R6／R8-Tenant／R9 等真正的租戶層角色本來就不在遷移角色矩陣裡，不受影響。
--
-- 判定順序、錯誤代碼與訊息一律不動：仍是 ACTOR_ROLE_NOT_HELD。
-- 0028 不改寫；本檔只 CREATE OR REPLACE 守衛函式。

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

  -- 作用域嚴格相等：期間遷移的角色全屬 EngagementAssignment（§26.3），
  -- 未指定案件的指派不得取得本案件的發起權。
  SELECT count(*) INTO v_has_role
    FROM role_assignment ra JOIN app_user u ON u.user_id = ra.user_id
   WHERE ra.user_id = v_actor AND ra.role = v_role::role_code
     AND ra.revoked_at IS NULL AND u.is_active
     AND ra.tenant_id = v_tenant AND u.tenant_id = v_tenant
     AND ra.engagement_id = v_eng;
  IF v_has_role = 0 THEN
    RAISE EXCEPTION 'ACTOR_ROLE_NOT_HELD: 發起人未於本案件持有有效的 % 角色指派', v_role;
  END IF;

  SELECT * INTO spec FROM fn_period_transition_spec(OLD.status) s
   WHERE s.requested_to = NEW.status;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ILLEGAL_TRANSITION: 非法期間狀態遷移 % → %（不得跳關）', OLD.status, NEW.status;
  END IF;

  IF spec.required_role IS NOT NULL AND v_role::role_code <> spec.required_role THEN
    RAISE EXCEPTION 'ROLE_NOT_PERMITTED: 角色 % 不得發起 % → %', v_role, OLD.status, NEW.status;
  END IF;

  IF spec.availability = 'NOT_IMPLEMENTED' THEN
    RAISE EXCEPTION '%: %', spec.unavailable_code, spec.unavailable_reason;
  END IF;

  IF spec.availability = 'CONDITIONAL' AND OLD.status = 'SETUP' AND NOT v_initial THEN
    RAISE EXCEPTION '%: %', spec.unavailable_code, spec.unavailable_reason;
  END IF;

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

-- PostgreSQL 預設把新函式的 EXECUTE 授予 PUBLIC。0028 只寫了 GRANT，
-- 因此「只有 app_runtime 可執行」在實況上並不成立。該函式只回常數，
-- 不構成資料外洩，但權限敘述必須與實況一致——否則下一份唯讀函式
-- 就會沿用同一個錯誤模板。
REVOKE ALL ON FUNCTION fn_period_transition_spec(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_period_transition_spec(text) TO app_runtime;
