-- 0014 02B 收口：並發競態與期間歸屬（關閉審查兩項 P1＋兩小項）
-- ① 封存／終態守衛只讀父列不加鎖：外部 INSERT 可在「檢查時尚無 Run／仍 RUNNING、
--    提交時已有 Run／已終態」的間隙穿過。修法＝guard 一律 FOR UPDATE 鎖父列，
--    worker 計算交易一開始鎖 Run——競爭者阻塞至提交後重讀，看到終態即被拒。
-- ② §24.1A 期間歸屬：原本只比對「Run 與 Manifest 填同一 period_revision_id」，
--    未驗證期間屬於案件、也未驗證等於批次宣告期間；Manifest 自身歸屬也未驗。
-- 小項：RUNNING 互斥補 failure_reason；canonicalization／hash 演算法白名單 fail closed。

-- ── Manifest 建立歸屬（新增） ─────────────────────────────────
CREATE FUNCTION fn_manifest_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  e_tenant uuid; p_eng uuid; p_tenant uuid; u_tenant uuid;
BEGIN
  SELECT tenant_id INTO e_tenant FROM client_engagement WHERE engagement_id = NEW.engagement_id;
  IF e_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：Manifest 的案件不屬於本租戶（INV-18）';
  END IF;
  SELECT rp.engagement_id, pr.tenant_id INTO p_eng, p_tenant
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = NEW.period_revision_id;
  IF p_eng IS DISTINCT FROM NEW.engagement_id OR p_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：Manifest 的期間不屬於本案件（§24.1A）';
  END IF;
  SELECT tenant_id INTO u_tenant FROM app_user WHERE user_id = NEW.created_by;
  IF u_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：Manifest 建立者不屬於本租戶（INV-18）';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cim_insert
  BEFORE INSERT ON calculation_input_manifest
  FOR EACH ROW EXECUTE FUNCTION fn_manifest_insert_guard();

-- ── entry：鎖 Manifest 後再驗封存（消除 TOCTOU） ─────────────
CREATE OR REPLACE FUNCTION fn_manifest_entry_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_tenant
    FROM calculation_input_manifest WHERE manifest_id = NEW.manifest_id
    FOR UPDATE;   -- 與「Run 建立」在 Manifest 列上序列化
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'entry 引用的 Manifest 不存在（%）', NEW.manifest_id;
  END IF;
  IF v_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：entry 與 Manifest 不同租戶（INV-18）';
  END IF;
  IF EXISTS (SELECT 1 FROM calculation_run WHERE manifest_id = NEW.manifest_id) THEN
    RAISE EXCEPTION 'Manifest 已封存（已有 Run 引用），不得追加 entry（INV-17）';
  END IF;
  RETURN NEW;
END $$;

-- ── Run 建立：鎖 Manifest＋期間歸屬鏈完整驗證 ─────────────────
CREATE OR REPLACE FUNCTION fn_calculation_run_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_mani uuid; v_tenant uuid;
  m_tenant uuid; m_eng uuid; m_pr uuid;
  b_tenant uuid; b_eng uuid; b_pr uuid;
  p_eng uuid; p_tenant uuid;
  u_tenant uuid;
BEGIN
  IF NEW.status <> 'RUNNING' THEN
    RAISE EXCEPTION 'Run 建立時必須為 RUNNING（結果狀態由執行交易寫入）';
  END IF;
  IF NEW.result_content_hash IS NOT NULL OR NEW.failure_reason_code IS NOT NULL
     OR NEW.failure_reason IS NOT NULL OR NEW.completed_at IS NOT NULL
     OR NEW.failed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Run 建立時不得預填結果或終態欄位（終態欄位互斥）';
  END IF;
  -- 鎖 Manifest：與 entry 追加序列化，封存判定無競態窗
  SELECT tenant_id, engagement_id, period_revision_id INTO m_tenant, m_eng, m_pr
    FROM calculation_input_manifest WHERE manifest_id = NEW.manifest_id
    FOR UPDATE;
  IF m_tenant IS DISTINCT FROM NEW.tenant_id OR m_eng IS DISTINCT FROM NEW.engagement_id
     OR m_pr IS DISTINCT FROM NEW.period_revision_id THEN
    RAISE EXCEPTION '歸屬違規：Run 與 Manifest 的租戶／案件／期間不一致（§24.1A）';
  END IF;
  -- 期間本身必須屬於本案件（不只是「兩邊填同一值」）
  SELECT rp.engagement_id, pr.tenant_id INTO p_eng, p_tenant
    FROM period_revision pr
    JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
   WHERE pr.period_revision_id = NEW.period_revision_id;
  IF p_eng IS DISTINCT FROM NEW.engagement_id OR p_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：Run 的期間不屬於本案件（§24.1A）';
  END IF;
  SELECT tenant_id, engagement_id, declared_period_revision_id INTO b_tenant, b_eng, b_pr
    FROM import_batch WHERE import_batch_id = NEW.import_batch_id;
  IF b_tenant IS DISTINCT FROM NEW.tenant_id OR b_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '歸屬違規：Run 與來源批次的租戶／案件不一致（§24.1A）';
  END IF;
  IF b_pr IS DISTINCT FROM NEW.period_revision_id THEN
    RAISE EXCEPTION '歸屬違規：Run 期間與批次宣告期間不一致（§24.1A）';
  END IF;
  SELECT tenant_id INTO u_tenant FROM app_user WHERE user_id = NEW.created_by;
  IF u_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：建立者不屬於本租戶（INV-18）';
  END IF;
  IF NEW.replay_of_run_id IS NOT NULL THEN
    SELECT manifest_id, tenant_id INTO v_mani, v_tenant
      FROM calculation_run WHERE calculation_run_id = NEW.replay_of_run_id;
    IF v_mani IS NULL THEN
      RAISE EXCEPTION 'replay 引用的原 run 不存在（%）', NEW.replay_of_run_id;
    END IF;
    IF v_mani <> NEW.manifest_id OR v_tenant <> NEW.tenant_id THEN
      RAISE EXCEPTION 'replay 必須引用原 run 的同一份 Manifest（原 % ≠ 新 %）', v_mani, NEW.manifest_id;
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- ── 快照：鎖 Run 後再驗狀態（與 worker 終態提交序列化） ───────
CREATE OR REPLACE FUNCTION fn_snapshot_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_tenant uuid; v_status calculation_run_status;
BEGIN
  SELECT tenant_id, status INTO v_tenant, v_status
    FROM calculation_run WHERE calculation_run_id = NEW.calculation_run_id
    FOR UPDATE;   -- worker 交易一開始即持有此鎖；外部寫入阻塞至終態提交後被拒
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION '快照引用的 Run 不存在（%）', NEW.calculation_run_id;
  END IF;
  IF v_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：快照與 Run 不同租戶（INV-18）';
  END IF;
  IF v_status <> 'RUNNING' THEN
    RAISE EXCEPTION 'Run 已進入終態（%），不得追加結果——result_content_hash 固定後結果不可再變', v_status;
  END IF;
  RETURN NEW;
END $$;

-- ── 小項①：RUNNING 互斥補 failure_reason ────────────────────
CREATE OR REPLACE FUNCTION fn_calculation_run_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'CalculationRun 不可刪除（§25.3：任何輸入變動都產生新的 run）';
  END IF;
  IF NEW.manifest_id IS DISTINCT FROM OLD.manifest_id
  OR NEW.replay_of_run_id IS DISTINCT FROM OLD.replay_of_run_id
  OR NEW.request_key IS DISTINCT FROM OLD.request_key
  OR NEW.request_content_hash IS DISTINCT FROM OLD.request_content_hash
  OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
  OR NEW.engagement_id IS DISTINCT FROM OLD.engagement_id
  OR NEW.period_revision_id IS DISTINCT FROM OLD.period_revision_id
  OR NEW.import_batch_id IS DISTINCT FROM OLD.import_batch_id
  OR NEW.run_type IS DISTINCT FROM OLD.run_type
  OR NEW.engine_version IS DISTINCT FROM OLD.engine_version
  OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
    RAISE EXCEPTION 'CalculationRun 身分欄位建立後不可變更';
  END IF;
  IF OLD.status IN ('COMPLETED','FAILED','SUPERSEDED') THEN
    RAISE EXCEPTION 'CalculationRun 終態（%）不可修改——重演＝建立新 run', OLD.status;
  END IF;
  IF NEW.status = 'SUPERSEDED' THEN
    RAISE EXCEPTION 'SUPERSEDED 本刀不使用（§25.11 下游失效鏈，語意保留）';
  END IF;
  IF NEW.status NOT IN ('RUNNING','COMPLETED','FAILED') THEN
    RAISE EXCEPTION '非法 Run 狀態遷移 % → %', OLD.status, NEW.status;
  END IF;
  IF NEW.status = 'COMPLETED' THEN
    IF COALESCE(NEW.result_content_hash,'') = '' THEN
      RAISE EXCEPTION 'COMPLETED 必須帶 result_content_hash（INV-17）';
    END IF;
    IF NEW.failure_reason_code IS NOT NULL OR NEW.failure_reason IS NOT NULL
       OR NEW.failed_at IS NOT NULL THEN
      RAISE EXCEPTION '終態欄位互斥：COMPLETED 不得帶失敗欄位';
    END IF;
    NEW.completed_at := COALESCE(NEW.completed_at, now());
  END IF;
  IF NEW.status = 'FAILED' THEN
    IF COALESCE(NEW.failure_reason_code,'') = '' OR COALESCE(NEW.failure_reason,'') = '' THEN
      RAISE EXCEPTION 'FAILED 必須帶機器代碼與客戶可理解原因';
    END IF;
    IF NEW.result_content_hash IS NOT NULL OR NEW.completed_at IS NOT NULL THEN
      RAISE EXCEPTION '終態欄位互斥：FAILED 不得帶結果欄位';
    END IF;
    NEW.failed_at := COALESCE(NEW.failed_at, now());
  END IF;
  IF NEW.status = 'RUNNING' AND (NEW.result_content_hash IS NOT NULL
     OR NEW.failure_reason_code IS NOT NULL OR NEW.failure_reason IS NOT NULL
     OR NEW.completed_at IS NOT NULL OR NEW.failed_at IS NOT NULL) THEN
    RAISE EXCEPTION '終態欄位互斥：RUNNING 不得預填結果或終態欄位';
  END IF;
  RETURN NEW;
END $$;

-- ── 小項②：白名單 fail closed（寫入端；讀取端 worker 另有斷言） ──
ALTER TABLE calculation_input_manifest
  ADD CONSTRAINT cim_hash_algorithm_whitelist CHECK (hash_algorithm IN ('sha256'));
ALTER TABLE calculation_input_manifest
  ADD CONSTRAINT cim_canonicalization_whitelist
  CHECK (canonicalization_version IN ('sqlcanon-1','sqlcanon-2'));
