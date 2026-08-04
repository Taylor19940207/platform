-- 0004 租戶隔離：Row-Level Security（§24.9、D-24-01、INV-18）
-- 應用連線一律以 app_runtime 角色執行，並在交易開頭 set_config('app.tenant_id', ...)。
-- 注意 §24.1A：RLS 防的是「不該看到的人看到」；歸屬完整性（放錯客戶）由
-- EngagementContext 伺服器端驗證與 identity_status 處理，兩者不可互相替代。

CREATE FUNCTION current_tenant() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
$$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'app_user','client_engagement','legal_entity','reporting_unit','role_assignment',
    'fiscal_calendar','reporting_period','period_revision',
    'chart_of_accounts','account','mapping_rule',
    'import_batch','source_identity_assessment','source_identity_resolution',
    'source_dataset','source_document','source_ledger_line','data_coverage',
    'audit_event'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (tenant_id = current_tenant()) WITH CHECK (tenant_id = current_tenant())', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO app_runtime', t);
  END LOOP;
END $$;

-- tenant 表本身：只能看到自己
ALTER TABLE tenant ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_self ON tenant USING (tenant_id = current_tenant());
GRANT SELECT ON tenant TO app_runtime;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_runtime;
