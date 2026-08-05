-- 0013 02B hardening（逐行審查四缺口＋兩項次要邊界）
-- ① Manifest 真正封存：Run 建立後不得再 INSERT entry；content_hash 改涵蓋
--    canonical＋payload（canonicalization v2）——單獨竄改 payload 亦可偵測。
-- ② 終態 Run 不得追加快照：balance_snapshot_line 只允許插入 RUNNING 的 run。
-- ③ 歸屬守衛（0008 同一模式）：entry↔manifest、run↔manifest／batch／created_by、
--    snapshot↔run 必須同租戶／同案件——RLS 只看列自身 tenant_id，防不了跨父項錯配。
-- ④（API 層）建立交易改 REPEATABLE READ——本檔不涉，見 server.ts。
-- 次要：request_key 唯一改 (tenant_id, request_key)；終態欄位互斥。

-- ── ① Manifest 封存＋entry 歸屬 ──────────────────────────────
CREATE FUNCTION fn_manifest_entry_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_tenant
    FROM calculation_input_manifest WHERE manifest_id = NEW.manifest_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'entry 引用的 Manifest 不存在（%）', NEW.manifest_id;
  END IF;
  IF v_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION '歸屬違規：entry 與 Manifest 不同租戶（INV-18）';
  END IF;
  -- 封存：一旦有任何 Run 引用此 Manifest，凍結集合即不得再擴充。
  -- 建立交易內 entries 先於 run 寫入，因此正常建立不受影響。
  IF EXISTS (SELECT 1 FROM calculation_run WHERE manifest_id = NEW.manifest_id) THEN
    RAISE EXCEPTION 'Manifest 已封存（已有 Run 引用），不得追加 entry（INV-17）';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_cme_sealed
  BEFORE INSERT ON calculation_manifest_entry
  FOR EACH ROW EXECUTE FUNCTION fn_manifest_entry_guard();

-- ── ② 快照只能寫入 RUNNING 的 run ＋ ③ snapshot 歸屬 ─────────
CREATE FUNCTION fn_snapshot_line_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_tenant uuid; v_status calculation_run_status;
BEGIN
  SELECT tenant_id, status INTO v_tenant, v_status
    FROM calculation_run WHERE calculation_run_id = NEW.calculation_run_id;
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
CREATE TRIGGER trg_bsl_run_state
  BEFORE INSERT ON balance_snapshot_line
  FOR EACH ROW EXECUTE FUNCTION fn_snapshot_line_guard();

-- ── ③ Run 歸屬＋次要②（建立時不得預填終態欄位） ──────────────
CREATE OR REPLACE FUNCTION fn_calculation_run_insert_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_mani uuid; v_tenant uuid;
  m_tenant uuid; m_eng uuid; m_pr uuid;
  b_tenant uuid; b_eng uuid;
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
  SELECT tenant_id, engagement_id, period_revision_id INTO m_tenant, m_eng, m_pr
    FROM calculation_input_manifest WHERE manifest_id = NEW.manifest_id;
  IF m_tenant IS DISTINCT FROM NEW.tenant_id OR m_eng IS DISTINCT FROM NEW.engagement_id
     OR m_pr IS DISTINCT FROM NEW.period_revision_id THEN
    RAISE EXCEPTION '歸屬違規：Run 與 Manifest 的租戶／案件／期間不一致（§24.1A）';
  END IF;
  SELECT tenant_id, engagement_id INTO b_tenant, b_eng
    FROM import_batch WHERE import_batch_id = NEW.import_batch_id;
  IF b_tenant IS DISTINCT FROM NEW.tenant_id OR b_eng IS DISTINCT FROM NEW.engagement_id THEN
    RAISE EXCEPTION '歸屬違規：Run 與來源批次的租戶／案件不一致（§24.1A）';
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

-- ── 次要②：終態欄位互斥（UPDATE 路徑） ──────────────────────
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
     OR NEW.failure_reason_code IS NOT NULL OR NEW.completed_at IS NOT NULL
     OR NEW.failed_at IS NOT NULL) THEN
    RAISE EXCEPTION '終態欄位互斥：RUNNING 不得預填結果或終態欄位';
  END IF;
  RETURN NEW;
END $$;

-- ── 次要①：request_key 唯一於租戶內（跨租戶 UUID 碰撞不應互相阻擋） ──
ALTER TABLE calculation_run DROP CONSTRAINT calculation_run_request_key_key;
ALTER TABLE calculation_run
  ADD CONSTRAINT calculation_run_tenant_request_key_uq UNIQUE (tenant_id, request_key);
