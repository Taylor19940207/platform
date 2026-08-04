#!/usr/bin/env bash
# 開發種子：T1 事務所、兩位使用者、兩個案件（甲只被指派 A 案件——驗 WKB-a）、
# A 案件下兩家法人（做 CONFLICT 測試）、2026-03 期間。冪等：先清後建。
set -euo pipefail
. "$(cd "$(dirname "$0")/../../../scripts" && pwd)/env.sh"
DB="${1:-$DB_NAME}"
psql_run -d "$DB" <<'SQL'
TRUNCATE tenant CASCADE;
INSERT INTO tenant (tenant_id, name) VALUES
  ('11111111-1111-1111-1111-111111111111','T1 國際會計事務所');
INSERT INTO app_user (user_id, tenant_id, email, display_name) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','staff@t1.jp','職員甲'),
  ('aaaaaaaa-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','senior@t1.jp','資深乙');
INSERT INTO client_engagement (engagement_id, tenant_id, name) VALUES
  ('eeeeeeee-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','A 商事株式会社'),
  ('eeeeeeee-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','B 工業株式会社');
-- 職員甲只被指派 A 案件（B-00 不得出現 B 案件——WKB-a）
INSERT INTO role_assignment (tenant_id, user_id, role, engagement_id) VALUES
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','R2','eeeeeeee-0000-0000-0000-000000000001'),
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000002','R2','eeeeeeee-0000-0000-0000-000000000001'),
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000002','R3','eeeeeeee-0000-0000-0000-000000000002');
INSERT INTO legal_entity (legal_entity_id, tenant_id, engagement_id, name, authoritative_code, country_code) VALUES
  ('cccccccc-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','A 商事株式会社','1234567890123','JP'),
  ('cccccccc-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','A 商事（上海）有限公司','9876543210987','CN');
INSERT INTO reporting_unit (reporting_unit_id, tenant_id, engagement_id, legal_entity_id, unit_scope, name) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001','LEGAL_ENTITY','A 商事');
INSERT INTO fiscal_calendar (fiscal_calendar_id, tenant_id, engagement_id, name, year_start_month) VALUES
  ('ffffffff-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','日本4月起',4);
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id, fiscal_calendar_id, label, start_date, end_date) VALUES
  ('dddddddd-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-000000000001','2026-03','2026-03-01','2026-03-31');
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id) VALUES
  ('99999999-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','dddddddd-0000-0000-0000-000000000001');
SQL
echo "種子完成（${DB}）"
