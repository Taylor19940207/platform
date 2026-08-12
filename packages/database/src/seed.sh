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
  ('aaaaaaaa-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','senior@t1.jp','資深乙'),
  ('aaaaaaaa-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','manager@t1.jp','經理丙'),
  ('aaaaaaaa-0000-0000-0000-000000000004','11111111-1111-1111-1111-111111111111','ops@t1.jp','系管丁'),
  ('aaaaaaaa-0000-0000-0000-000000000005','11111111-1111-1111-1111-111111111111','tax@t1.jp','稅務擔當戊'),
  ('aaaaaaaa-0000-0000-0000-000000000006','11111111-1111-1111-1111-111111111111','tenant-r4@t1.jp','租戶層己'),
  ('aaaaaaaa-0000-0000-0000-000000000007','11111111-1111-1111-1111-111111111111','tenant-r3@t1.jp','租戶層庚'),
  ('aaaaaaaa-0000-0000-0000-000000000008','11111111-1111-1111-1111-111111111111','tenant-r2@t1.jp','租戶層辛');
INSERT INTO client_engagement (engagement_id, tenant_id, name) VALUES
  ('eeeeeeee-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','A 商事株式会社'),
  ('eeeeeeee-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','B 工業株式会社');
-- 職員甲只被指派 A 案件（B-00 不得出現 B 案件——WKB-a）
--
-- SLICE-M2-02A 的角色配置刻意讓「角色齊備」與「實例級控制」正面對撞：
-- 甲同時具備 R2／R3／R4，因此 SOD-01、AC-WFL-001 被擋下時，唯一可能的原因
-- 是自然人判定，而不是角色不足——角色級禁令擋不住同一人切換角色自我放行。
INSERT INTO role_assignment (tenant_id, user_id, role, engagement_id) VALUES
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','R2','eeeeeeee-0000-0000-0000-000000000001'),
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','R3','eeeeeeee-0000-0000-0000-000000000001'),
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000001','R4','eeeeeeee-0000-0000-0000-000000000001'),
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000002','R2','eeeeeeee-0000-0000-0000-000000000001'),
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000002','R3','eeeeeeee-0000-0000-0000-000000000001'),
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000002','R4','eeeeeeee-0000-0000-0000-000000000001'),
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000003','R4','eeeeeeee-0000-0000-0000-000000000001'),
  -- 系管丁：R6 為租戶層技術角色（engagement_id NULL）；診斷 API（/admin/jobs）唯一有權者
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000004','R6',NULL),
  -- 稅務擔當戊：R1（資料提供者／日本記帳・稅務擔當）。B 基礎觀測的「指定稅務專業角色」
  -- 由 BasisSourcePolicyVersion.confirmation_role 指定為 R1，只有戊持有——
  -- 甲乙丙都在本案件內但沒有 R1，因此「確認人存在且在本案件、只是角色不符」可被驗證。
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000005','R1','eeeeeeee-0000-0000-0000-000000000001'),
  -- 租戶層己：只有 engagement_id IS NULL 的 R4。角色種類在白名單內，但**沒有任何
  -- 案件授權**——用來證明白名單擋的是「種類」，作用域要另外擋（§26.3：R1～R5、R7
  -- 屬 EngagementAssignment，租戶層角色不得隱式取得客戶資料）。
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000006','R4',NULL),
  -- 租戶層庚：只有 engagement_id IS NULL 的 R3。R3 **在** B-06 白名單內，
  -- 因此他是「種類正確、範圍錯誤」的唯一樣本——用來釘住作用域判定本身。
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000007','R3',NULL),
  -- 租戶層辛：只有 engagement_id IS NULL 的 R2。R2 在 B-03／B-04 多數動作的白名單內，
  -- 因此它是「種類正確、範圍錯誤」的樣本——用來釘住作用域判定本身。
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000008','R2',NULL),
  ('11111111-1111-1111-1111-111111111111','aaaaaaaa-0000-0000-0000-000000000002','R3','eeeeeeee-0000-0000-0000-000000000002');
INSERT INTO legal_entity (legal_entity_id, tenant_id, engagement_id, name, authoritative_code, country_code) VALUES
  ('cccccccc-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','A 商事株式会社','1234567890123','JP'),
  ('cccccccc-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','A 商事（上海）有限公司','9876543210987','CN');
INSERT INTO reporting_unit (reporting_unit_id, tenant_id, engagement_id, legal_entity_id, unit_scope, name) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001','LEGAL_ENTITY','A 商事');
INSERT INTO fiscal_calendar (fiscal_calendar_id, tenant_id, engagement_id, name, year_start_month) VALUES
  ('ffffffff-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','日本4月起',4);
-- is_initial_period 只給 2026-03（本單位在此曆別下的第一期）。
-- 該欄建立後不可變更（0022），且同一 (reporting_unit_id, fiscal_calendar_id)
-- 只能有一個 true——2026-04 必須維持 false，不得全面設為首期。
INSERT INTO reporting_period (reporting_period_id, tenant_id, engagement_id, reporting_unit_id, fiscal_calendar_id, label, start_date, end_date, is_initial_period) VALUES
  ('dddddddd-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-000000000001','2026-03','2026-03-01','2026-03-31',true),
  ('dddddddd-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-000000000001','2026-04','2026-04-01','2026-04-30',false);
-- 顯式前期連結（0030）：2026-04 的前期是 2026-03。這是**人明示的事實**，
-- 不由日期推導——期初已折算權益餘額的延續鏈就靠它。
UPDATE reporting_period SET previous_reporting_period_id = 'dddddddd-0000-0000-0000-000000000001'
 WHERE reporting_period_id = 'dddddddd-0000-0000-0000-000000000002';
INSERT INTO period_revision (period_revision_id, tenant_id, reporting_period_id) VALUES
  ('99999999-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','dddddddd-0000-0000-0000-000000000001'),
  ('99999999-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','dddddddd-0000-0000-0000-000000000002');
-- 中國集團科目表（母公司提供；SLICE-M2-01／case-001）。B 案件另建一張表供「跨案件誤用」測試。
INSERT INTO chart_of_accounts (coa_id, tenant_id, engagement_id, name) VALUES
  ('88888888-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','中國集團科目表（CAS）'),
  ('88888888-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000002','B 工業集團科目表');
INSERT INTO account (tenant_id, coa_id, code, name) VALUES
  ('11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','1001','库存现金'),
  ('11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','1002','银行存款'),
  ('11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','1122','应收账款'),
  ('11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','1405','库存商品'),
  ('11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','1601','固定资产'),
  ('11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','2202','应付账款'),
  ('11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','2221','应交税费'),
  ('11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','4001','实收资本'),
  ('11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','4104','未分配利润'),
  ('11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','6001','主营业务收入'),
  ('11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','6401','主营业务成本'),
  ('11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000001','6602','管理费用'),
  ('11111111-1111-1111-1111-111111111111','88888888-0000-0000-0000-000000000002','1002','银行存款');

-- ── SLICE-M2-06 多基礎：層是平台參照主檔（0023 已種），基礎是案件內口徑（此處種） ──
-- B 的權威來源政策：confirmation_role = R1 由**政策**指定，不是寫死在約束裡。
INSERT INTO basis_source_policy_version (basis_source_policy_version_id, policy_series_id, version_no,
        tenant_id, engagement_id, source_kind, confirmation_role, description, status,
        approved_by, approved_at, approval_role) VALUES
  ('30000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000101',1,
   '11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
   'TAX_WORKPAPER','R1','日本稅務基礎：稅務計算底稿，經指定稅務專業角色確認（GB-02 補充：判準是可靠的稅務基礎與證據，不是申告書這一種檔案形式）',
   'APPROVED','aaaaaaaa-0000-0000-0000-000000000003',now(),'R4');

INSERT INTO book_basis (basis_id, tenant_id, engagement_id, code, jurisdiction, framework,
        source_mode, basis_source_policy_version_id, permits_group_layer) VALUES
  ('20000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','A','JP','JP_GAAP','COMPOSED',NULL,false),
  ('20000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','B','JP','JP_TAX','DIRECT_AUTHORITATIVE_IMPORT','30000000-0000-0000-0000-000000000001',false),
  ('20000000-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','C','CN','CN_CAS','COMPOSED',NULL,true),
  ('20000000-0000-0000-0000-000000000011','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000002','A','JP','JP_GAAP','COMPOSED',NULL,false),
  ('20000000-0000-0000-0000-000000000013','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000002','C','CN','CN_CAS','COMPOSED',NULL,true);

-- 組成：A = LOCAL_BOOK；C = LOCAL_BOOK + GROUP_GAAP_ADJ。B 無組成（權威匯入，INV-05）。
-- LOCAL_TAX_ADJ 不出現在任何組成是刻意的：A→B 是調節橋樑不是構成關係。
INSERT INTO basis_composition_version (basis_composition_version_id, composition_series_id,
        version_no, tenant_id, engagement_id, basis_id, status) VALUES
  ('21000000-0000-0000-0000-000000000001','21000000-0000-0000-0000-000000000101',1,'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','DRAFT'),
  ('21000000-0000-0000-0000-000000000003','21000000-0000-0000-0000-000000000103',1,'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000003','DRAFT'),
  ('21000000-0000-0000-0000-000000000011','21000000-0000-0000-0000-000000000111',1,'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000011','DRAFT'),
  ('21000000-0000-0000-0000-000000000013','21000000-0000-0000-0000-000000000113',1,'11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000013','DRAFT');
INSERT INTO constitutive_layer_item (basis_composition_version_id, layer_id, sign) VALUES
  ('21000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',1),
  ('21000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001',1),
  ('21000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003',1),
  ('21000000-0000-0000-0000-000000000011','10000000-0000-0000-0000-000000000001',1),
  ('21000000-0000-0000-0000-000000000013','10000000-0000-0000-0000-000000000001',1),
  ('21000000-0000-0000-0000-000000000013','10000000-0000-0000-0000-000000000003',1);
-- 批准帶角色快照（R4／經理丙）：批准後組成即凍結，改政策＝新 version_no
UPDATE basis_composition_version
   SET status='APPROVED', approved_by='aaaaaaaa-0000-0000-0000-000000000003',
       approved_at=now(), approval_role='R4'
 WHERE status='DRAFT';

-- ══ 折算（M3-02／M3-03）的開發前置：讓 B-06 折算頁可以實際操作 ══
-- 這一段只建立**輸入**（幣別、匯率、政策、權益批次、期初值、容許值與一份
-- NO_FX 來源 run）；折算本身仍由使用者在畫面上執行，才看得到守衛的作用。
INSERT INTO account (account_id, tenant_id, coa_id, code, name, translation_category)
VALUES ('a9990000-0000-0000-0000-000000003999','11111111-1111-1111-1111-111111111111',
        '88888888-0000-0000-0000-000000000001','3999','外币报表折算差额',NULL);
UPDATE account SET translation_category = CASE code
    WHEN '1001' THEN 'ASSET' WHEN '1002' THEN 'ASSET' WHEN '1122' THEN 'ASSET'
    WHEN '1405' THEN 'ASSET' WHEN '1601' THEN 'ASSET'
    WHEN '2202' THEN 'LIABILITY' WHEN '2221' THEN 'LIABILITY'
    WHEN '4001' THEN 'EQUITY_CONTRIBUTED' WHEN '4104' THEN 'EQUITY_RETAINED'
    WHEN '6001' THEN 'INCOME' WHEN '6401' THEN 'EXPENSE' WHEN '6602' THEN 'EXPENSE'
    ELSE translation_category END
 WHERE coa_id = '88888888-0000-0000-0000-000000000001';

INSERT INTO reporting_unit_currency_assignment (tenant_id, engagement_id, reporting_unit_id,
        currency_role, currency_code, effective_range, created_by, approved_by, approved_at) VALUES
  ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
   'bbbbbbbb-0000-0000-0000-000000000001','FUNCTIONAL','JPY','[2020-01-01,)',
   'aaaaaaaa-0000-0000-0000-000000000004','aaaaaaaa-0000-0000-0000-000000000003',now()),
  ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001',
   'bbbbbbbb-0000-0000-0000-000000000001','REPORTING','CNY','[2020-01-01,)',
   'aaaaaaaa-0000-0000-0000-000000000004','aaaaaaaa-0000-0000-0000-000000000003',now());

-- 匯率版本：R6 建立 → R2 提交 → R3 覆核 → R4 批准（乙覆核、丙批准，符合 SoD）
INSERT INTO exchange_rate_version (rate_version_id, tenant_id, engagement_id, label,
        series_id, version_no, created_by)
VALUES ('e9990000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',
        'eeeeeeee-0000-0000-0000-000000000001','2026-03 JPY→CNY v1',
        'e9990000-0000-0000-0000-000000000101',1,'aaaaaaaa-0000-0000-0000-000000000004');
INSERT INTO exchange_rate_observation (tenant_id, rate_version_id, from_currency, to_currency,
        rate_type, rate, source, measurement_date, coverage_start, coverage_end, event_date) VALUES
  ('11111111-1111-1111-1111-111111111111','e9990000-0000-0000-0000-000000000001','JPY','CNY',
   'CLOSING',0.048120,'BOJ','2026-03-31',NULL,NULL,NULL),
  ('11111111-1111-1111-1111-111111111111','e9990000-0000-0000-0000-000000000001','JPY','CNY',
   'AVERAGE',0.047950,'BOJ',NULL,'2026-03-01','2026-03-31',NULL),
  ('11111111-1111-1111-1111-111111111111','e9990000-0000-0000-0000-000000000001','JPY','CNY',
   'HISTORICAL',0.061000,'出資契約',NULL,NULL,NULL,'2018-06-15'),
  ('11111111-1111-1111-1111-111111111111','e9990000-0000-0000-0000-000000000001','JPY','CNY',
   'HISTORICAL',0.051000,'増資契約',NULL,NULL,NULL,'2022-09-01');
SET app.tenant_id = '11111111-1111-1111-1111-111111111111';
SELECT fn_exchange_rate_transition('e9990000-0000-0000-0000-000000000001','DRAFT','SUBMITTED',
  'aaaaaaaa-0000-0000-0000-000000000001','R2');
SELECT fn_exchange_rate_transition('e9990000-0000-0000-0000-000000000001','SUBMITTED','REVIEWED',
  'aaaaaaaa-0000-0000-0000-000000000002','R3');
SELECT fn_exchange_rate_transition('e9990000-0000-0000-0000-000000000001','REVIEWED','APPROVED',
  'aaaaaaaa-0000-0000-0000-000000000003','R4');

INSERT INTO translation_policy_version (policy_version_id, tenant_id, engagement_id,
        reporting_unit_id, label, cta_account_id, cta_coa_id, created_by)
VALUES ('e9991000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',
        'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
        '折算政策 v1（CAS 19）','a9990000-0000-0000-0000-000000003999',
        '88888888-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001');
INSERT INTO translation_policy_rule (tenant_id, policy_version_id, translation_category, method) VALUES
  ('11111111-1111-1111-1111-111111111111','e9991000-0000-0000-0000-000000000001','ASSET','CLOSING'),
  ('11111111-1111-1111-1111-111111111111','e9991000-0000-0000-0000-000000000001','LIABILITY','CLOSING'),
  ('11111111-1111-1111-1111-111111111111','e9991000-0000-0000-0000-000000000001','INCOME','AVERAGE'),
  ('11111111-1111-1111-1111-111111111111','e9991000-0000-0000-0000-000000000001','EXPENSE','AVERAGE'),
  ('11111111-1111-1111-1111-111111111111','e9991000-0000-0000-0000-000000000001',
   'EQUITY_CONTRIBUTED','HISTORICAL_BY_LOT'),
  ('11111111-1111-1111-1111-111111111111','e9991000-0000-0000-0000-000000000001',
   'EQUITY_RETAINED','OPENING_TRANSLATED_BALANCE');
SELECT fn_translation_policy_approve('e9991000-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000003');

INSERT INTO equity_translation_lot_set_version (set_version_id, tenant_id, engagement_id,
        reporting_unit_id, account_id, series_id, version_no, created_by)
SELECT 'e9992000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',
       'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
       account_id,'e9992000-0000-0000-0000-000000000101',1,'aaaaaaaa-0000-0000-0000-000000000001'
  FROM account WHERE coa_id='88888888-0000-0000-0000-000000000001' AND code='4001';
INSERT INTO equity_translation_lot (tenant_id, set_version_id, event_date, functional_amount,
        exchange_rate_observation_id, evidence_ref, line_no)
SELECT '11111111-1111-1111-1111-111111111111','e9992000-0000-0000-0000-000000000001',
       '2018-06-15',7000000, observation_id,'出資契約 #1',1
  FROM exchange_rate_observation
 WHERE rate_version_id='e9990000-0000-0000-0000-000000000001' AND event_date='2018-06-15';
INSERT INTO equity_translation_lot (tenant_id, set_version_id, event_date, functional_amount,
        exchange_rate_observation_id, evidence_ref, line_no)
SELECT '11111111-1111-1111-1111-111111111111','e9992000-0000-0000-0000-000000000001',
       '2022-09-01',3000000, observation_id,'増資契約 #2',2
  FROM exchange_rate_observation
 WHERE rate_version_id='e9990000-0000-0000-0000-000000000001' AND event_date='2022-09-01';
SELECT fn_equity_lot_set_approve('e9992000-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000003');

INSERT INTO equity_opening_translated_balance (opening_id, tenant_id, engagement_id,
        reporting_unit_id, period_revision_id, account_id, reporting_currency, opening_credit,
        source_kind, evidence_ref, created_by)
SELECT 'e9993000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',
       'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
       '99999999-0000-0000-0000-000000000001', account_id,'CNY',100380.00,
       'FIRST_CONVERSION','期初橋接底稿','aaaaaaaa-0000-0000-0000-000000000001'
  FROM account WHERE coa_id='88888888-0000-0000-0000-000000000001' AND code='4104';
SELECT fn_equity_opening_approve('e9993000-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000003');

INSERT INTO rounding_tolerance_version (tolerance_version_id, tenant_id, engagement_id,
        reporting_unit_id, source_currency, target_currency, single_limit, cumulative_limit,
        series_id, version_no, created_by)
VALUES ('e9994000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',
        'eeeeeeee-0000-0000-0000-000000000001','bbbbbbbb-0000-0000-0000-000000000001',
        'JPY','CNY',0.05,0.20,'e9994000-0000-0000-0000-000000000101',1,
        'aaaaaaaa-0000-0000-0000-000000000001');
SELECT fn_rounding_tolerance_approve('e9994000-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000003');

-- NO_FX 來源 run（Case-001 調整後集團 TB，借貸各 59,000,000 JPY）
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by, status, file_name)
VALUES ('00000000-0000-0000-0000-0000000000f1','11111111-1111-1111-1111-111111111111',
        'eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001',
        '99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000005','ACCEPTED','case-001-tb.csv');
INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
VALUES ('00000000-0000-0000-0000-0000000000f2','11111111-1111-1111-1111-111111111111',
        'eeeeeeee-0000-0000-0000-000000000001','99999999-0000-0000-0000-000000000001',
        'NO_FX','sqlcanon-2','seed-case001','aaaaaaaa-0000-0000-0000-000000000001');
INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, status, request_key, request_content_hash,
        engine_version, created_by)
VALUES ('00000000-0000-0000-0000-0000000000f3','11111111-1111-1111-1111-111111111111',
        'eeeeeeee-0000-0000-0000-000000000001','99999999-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-0000000000f1','00000000-0000-0000-0000-0000000000f2',
        'PREVIEW','RUNNING',gen_random_uuid(),'seed','1.0.0',
        'aaaaaaaa-0000-0000-0000-000000000001');
INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit)
SELECT '11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-0000000000f3',
       'SOURCE_TB', a.account_id, a.code, a.name, v.d, v.c
  FROM (VALUES ('1001',350000,0),('1002',9650000,0),('1122',5600000,0),('1405',2300000,0),
               ('1601',4800000,200000),('2202',0,3900000),('2221',0,800000),
               ('4001',0,10000000),('4104',0,2100000),('6001',0,42000000),
               ('6401',21700000,0),('6602',14600000,0)) AS v(code,d,c)
  JOIN account a ON a.code = v.code AND a.coa_id='88888888-0000-0000-0000-000000000001';
UPDATE calculation_run SET status='COMPLETED', result_content_hash='seed-case001-result',
       completed_at=now() WHERE calculation_run_id='00000000-0000-0000-0000-0000000000f3';
SQL
echo "種子完成（${DB}）"
