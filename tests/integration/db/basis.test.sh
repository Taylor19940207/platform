#!/usr/bin/env bash
# 多基礎與四類規則（0023）
# 可單跑（自行重建 DB 並補齊前置），也可由 tests/integration/db.test.sh 依序聚合執行。
if [ -z "${DB_TEST_HARNESS:-}" ]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
  DB_TEST_HARNESS=1; STANDALONE=1
  echo "══ 多基礎與四類規則（0023）（${DB}）══"
fi
need fx_reset fx_core fx_accounts fx_tb_lines fx_adjustment_approved fx_calc_runs

# ══════════ SLICE-M2-06：多基礎與四類規則（migration 0023） ══════════
# 三條主軸的驗證：代碼不驅動約束、構成與調節分屬兩模型、守衛未實作即 fail closed。
TEN=11111111-1111-1111-1111-111111111111
BING=aaaaaaaa-0000-0000-0000-000000000003     # 持有 R1（政策指定的稅務確認角色）
POL_OK=30000000-0000-0000-0000-000000000001
POL_DRAFT=30000000-0000-0000-0000-000000000002
COMP_A=21000000-0000-0000-0000-000000000001
COMP_C=21000000-0000-0000-0000-000000000003
LAYER_LB=10000000-0000-0000-0000-000000000001
LAYER_TA=10000000-0000-0000-0000-000000000006  # TRANSLATION_ADJUSTMENT（rule_type IS NULL）
GRP_PR=99999999-0000-0000-0000-000000000002
ASOF=2026-03-31

# ── 1 主檔與可查性（AC-BAS-001 前半） ──
n=$(APP_C <<<"$T1 SELECT string_agg(code,',' ORDER BY code) FROM book_basis")
[ "$n" = "A,B,C" ] && ok "0023：A／B／C 三基礎可分別查詢（同一查詢路徑）" || ng "0023：基礎清單為 $n"
n=$(APP_C <<<"$T1 SELECT count(*) FROM posting_layer WHERE scope_type='GROUP'")
[ "$n" = "1" ] && ok "0023：六個分層已種，CONSOLIDATION 為唯一 GROUP scope" || ng "0023：GROUP 層數為 $n"
n=$(APP_C <<<"$T1 INSERT INTO posting_layer (layer_id, code, scope_type) VALUES (gen_random_uuid(),'X','ENTITY')" 2>&1 | grep -c "permission denied")
[ "$n" -ge 1 ] && ok "0023：posting_layer 為平台參照主檔，app_runtime 不得寫入" || ng "0023：分層主檔可被租戶寫入"
expect_err "0023：分層主檔不可變更（改 scope_type 會追溯翻案 INV-03）" \
  "UPDATE posting_layer SET scope_type='GROUP' WHERE code='LOCAL_BOOK'" "不可變"

# ── 2 代碼不得驅動約束（原始碼掃描） ──
# 種子與回填必然要點名代碼（要建的就是 A／C），那些行以 `-- seed-data` 標記；
# 掃描的是「約束與守衛是否以代碼判斷」——那才是新增第四基礎時會爆掉的東西。
if grep -rnE "^[^-]*[^-]code[[:space:]]*=[[:space:]]*'(A|B|C)'" \
     "$ROOT"/packages/database/migrations/*.sql | grep -v "seed-data" >/dev/null 2>&1
then ng "0023：migration 的約束／守衛出現以 code 值驅動的判斷"
else ok "0023：全部 migration 的約束與守衛內無 code='A'／'B'／'C' 判斷（一律由語意欄位驅動）"; fi
# 「指定稅務專業角色」由 BasisSourcePolicyVersion.confirmation_role 指定；
# 只要有人把 R1 寫死進判斷，換法域或換客戶就得改約束——那正是本刀要避免的。
# role_code 的 ENUM 宣告本身不是判斷，排除。
if grep -rn "'R1'" "$ROOT"/packages/database/migrations/*.sql "$ROOT"/apps/*/src/*.ts \
     "$ROOT"/packages/domain/src/*.ts | grep -v "CREATE TYPE role_code" >/dev/null 2>&1
then ng "0023：程式或 migration 內出現硬編 'R1' 的稅務確認判斷"
else ok "0023：全庫無硬編 'R1'（確認角色一律由政策版本指定）"; fi

# ── 3 INV-05／GB-02：權威匯入基礎不得有組成 ──
expect_err "INV-05：權威匯入基礎（B）建立組成版本 → 拒絕" \
  "$T1 INSERT INTO basis_composition_version (composition_series_id, version_no, tenant_id,
        engagement_id, basis_id, status)
   VALUES (gen_random_uuid(),1,'$TEN','$ENG','$BASIS_B','DRAFT')" "INV05_COMPOSITION_FORBIDDEN"
expect_err "GB-02：DIRECT_AUTHORITATIVE_IMPORT 缺來源政策 → 拒絕" \
  "$T1 INSERT INTO book_basis (tenant_id, engagement_id, code, source_mode)
   VALUES ('$TEN','$ENG','B2','DIRECT_AUTHORITATIVE_IMPORT')" "check constraint"
expect_err "無混合語意：COMPOSED 卻帶來源政策 → 拒絕" \
  "$T1 INSERT INTO book_basis (tenant_id, engagement_id, code, source_mode, basis_source_policy_version_id)
   VALUES ('$TEN','$ENG','C2','COMPOSED','$POL_OK')" "check constraint"
expect_err "來源政策未批准 → 不構成 GB-02 的依據" \
  "$T1 INSERT INTO book_basis (tenant_id, engagement_id, code, source_mode, basis_source_policy_version_id)
   VALUES ('$TEN','$ENG','B3','DIRECT_AUTHORITATIVE_IMPORT','$POL_DRAFT')" "BASIS_SOURCE_POLICY_NOT_APPROVED"
expect_err "基礎的政策欄位建立後不可變更（改動會追溯翻案 INV-05）" \
  "$T1 UPDATE book_basis SET source_mode='COMPOSED' WHERE basis_id='$BASIS_B'" "BOOK_BASIS_IMMUTABLE"
expect_err "已批准的來源政策不可原地改寫" \
  "$T1 UPDATE basis_source_policy_version SET confirmation_role='R4'
   WHERE basis_source_policy_version_id='$POL_OK'" "BASIS_SOURCE_POLICY_IMMUTABLE"

# ── 4 INV-04 入口：GROUP 層不得進入不允許群組層的基礎 ──
CMP_TMP=21000000-0000-0000-0000-0000000000f1
expect_ok "組成草稿建立（A 基礎第二版，供入口測試）" \
  "$T1 INSERT INTO basis_composition_version (basis_composition_version_id, composition_series_id,
        version_no, tenant_id, engagement_id, basis_id, status)
   VALUES ('$CMP_TMP','21000000-0000-0000-0000-000000000101',2,'$TEN','$ENG','$BASIS_A','DRAFT')"
n=$(APP_C <<<"$T1 SELECT permits_group_layer FROM book_basis WHERE basis_id='$BASIS_A'")
[ "$n" = "f" ] && ok "前置成立：A 基礎 permits_group_layer = false" || ng "前置不成立：A 的 permits_group_layer=$n"
expect_err "INV-04 入口：A 的組成納入 CONSOLIDATION（GROUP）層 → 拒絕" \
  "$T1 INSERT INTO constitutive_layer_item (basis_composition_version_id, layer_id, sign)
   VALUES ('$CMP_TMP','$LAYER_CONSOL',1)" "INV04_GROUP_LAYER_IN_LOCAL_BASIS"
expect_ok "同一組成納入 ENTITY 層則正常" \
  "$T1 INSERT INTO constitutive_layer_item (basis_composition_version_id, layer_id, sign)
   VALUES ('$CMP_TMP','$LAYER_LB',1)"
expect_ok "組成批准（帶 R4 角色快照）" \
  "$T1 UPDATE basis_composition_version SET status='APPROVED', approved_by='$BING',
       approved_at=now(), approval_role='R4' WHERE basis_composition_version_id='$CMP_TMP'"
expect_err "已批准的組成其構成項不可再增刪" \
  "$T1 INSERT INTO constitutive_layer_item (basis_composition_version_id, layer_id, sign)
   VALUES ('$CMP_TMP','$LAYER_GG',1)" "COMPOSITION_IMMUTABLE"
expect_err "已批准的組成版本不可原地改寫（改政策＝新 version_no）" \
  "$T1 UPDATE basis_composition_version SET effective_from='2020-01-01'
   WHERE basis_composition_version_id='$CMP_TMP'" "COMPOSITION_IMMUTABLE"

# ── 5 INV-03／INV-04：調整層級 ──
ADJG=ad000000-0000-0000-0000-0000000000a1
n=$(APP_C <<<"$T1 SELECT ru.unit_scope FROM period_revision pr
     JOIN reporting_period rp ON rp.reporting_period_id = pr.reporting_period_id
     JOIN reporting_unit ru ON ru.reporting_unit_id = rp.reporting_unit_id
    WHERE pr.period_revision_id='$GRP_PR'")
[ "$n" = "CONSOLIDATION_GROUP" ] && ok "前置成立：群組期間的報告單位為 CONSOLIDATION_GROUP" \
  || ng "前置不成立：群組期間的單位型別為 $n"
expect_err "INV-03：ENTITY 層的調整落在 CONSOLIDATION_GROUP 單位 → 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by,
        basis_from_id, basis_to_id, posting_layer_id)
   VALUES ('$TEN','$ENG','$GRP_PR','層錯配','$JIA','$BASIS_A','$BASIS_C','$LAYER_GG')" "INV03_SCOPE_MISMATCH"
expect_err "INV-03：GROUP 層的調整落在 LEGAL_ENTITY 單位 → 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by,
        basis_from_id, basis_to_id, posting_layer_id)
   VALUES ('$TEN','$ENG','$PR','層錯配','$JIA','$BASIS_A','$BASIS_C','$LAYER_CONSOL')" "INV03_SCOPE_MISMATCH"
expect_err "INV-04：群組層調整寫入不允許群組層的基礎（A）→ 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by,
        basis_from_id, basis_to_id, posting_layer_id)
   VALUES ('$TEN','$ENG','$GRP_PR','回寫法定帳','$JIA','$BASIS_C','$BASIS_A','$LAYER_CONSOL')" \
  "INV04_GROUP_ADJ_INTO_LOCAL_BASIS"
expect_ok "群組層調整寫入允許群組層的基礎（C）＋群組單位 → 通過" \
  "$T1 INSERT INTO adjustment (adjustment_id, tenant_id, engagement_id, period_revision_id, title,
        prepared_by, basis_from_id, basis_to_id, posting_layer_id)
   VALUES ('$ADJG','$TEN','$ENG','$GRP_PR','集團抵銷','$JIA','$BASIS_A','$BASIS_C','$LAYER_CONSOL')"
expect_err "橋樑必須跨兩個基礎（from = to）→ 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by,
        basis_from_id, basis_to_id, posting_layer_id)
   VALUES ('$TEN','$ENG','$PR','自我橋樑','$JIA','$BASIS_C','$BASIS_C','$LAYER_GG')" "ADJ_BASIS_BRIDGE_INVALID"

# ── 6 Rule／RuleVersion：三層歸屬、四類不可混記、SOD-H3 ──
RULE1=40000000-0000-0000-0000-000000000001
RV1=41000000-0000-0000-0000-000000000001
expect_err "rule 三層：PLATFORM 卻帶 tenant → 拒絕" \
  "$T1 INSERT INTO rule (scope_level, tenant_id, rule_type, code, name)
   VALUES ('PLATFORM','$TEN','GROUP_GAAP','P1','平台規則')" "check constraint"
expect_err "rule 三層：TENANT 卻帶 engagement → 拒絕" \
  "$T1 INSERT INTO rule (scope_level, tenant_id, engagement_id, rule_type, code, name)
   VALUES ('TENANT','$TEN','$ENG','GROUP_GAAP','T1','租戶規則')" "check constraint"
expect_err "rule 三層：CLIENT 缺 engagement → 拒絕" \
  "$T1 INSERT INTO rule (scope_level, tenant_id, rule_type, code, name)
   VALUES ('CLIENT','$TEN','GROUP_GAAP','C1','客戶規則')" "check constraint"
n=$(APP_C <<<"$T1 INSERT INTO rule (scope_level, rule_type, code, name)
   VALUES ('PLATFORM','GROUP_GAAP','P9','平台規則')" 2>&1 | grep -c "row-level security\|violates row-level")
[ "$n" -ge 1 ] && ok "0023：app_runtime 寫不出 PLATFORM 規則（RLS WITH CHECK，非應用層自律）" \
  || ng "0023：PLATFORM 規則可被租戶寫入"
n=$(APP_C <<<"$T1 SELECT count(*) FROM rule WHERE scope_level='PLATFORM'")
[ "$n" = "0" ] && ok "0023：本刀不種任何 PLATFORM 規則列（無合法平台發布身分）" || ng "0023：平台規則列數 $n"
expect_ok "rule 建立（CLIENT，GROUP_GAAP）" \
  "$T1 INSERT INTO rule (rule_id, scope_level, tenant_id, engagement_id, rule_type, code, name)
   VALUES ('$RULE1','CLIENT','$TEN','$ENG','GROUP_GAAP','R-GG-01','集團折舊政策差異')"
expect_err "四類不可混記①：規則類型與分層類型不一致 → 拒絕" \
  "$T1 INSERT INTO rule_version (rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by)
   VALUES ('$RULE1',9,'$TEN','10000000-0000-0000-0000-000000000002','BALANCE','$JIA')" \
  "RULE_TYPE_LAYER_MISMATCH"
expect_err "rule_type 未定的分層被引用 → 顯式拒絕（不得默默通過）" \
  "$T1 INSERT INTO rule_version (rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by)
   VALUES ('$RULE1',8,'$TEN','$LAYER_TA','BALANCE','$JIA')" "LAYER_RULE_TYPE_UNSET"
expect_err "AUTO_POST 尚未實作 → fail closed（GB-05）" \
  "$T1 INSERT INTO rule_version (rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by, automation_level)
   VALUES ('$RULE1',7,'$TEN','$LAYER_GG','BALANCE','$JIA','AUTO_POST')" "AUTO_POST_NOT_IMPLEMENTED"
expect_err "required_granularity 沿用既有四值：LINE 不存在 → 拒絕" \
  "$T1 INSERT INTO rule_version (rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by)
   VALUES ('$RULE1',6,'$TEN','$LAYER_GG','LINE','$JIA')" "check constraint"
expect_err "規則版本只能以 DRAFT 建立（不得 INSERT 直達 ACTIVE）" \
  "$T1 INSERT INTO rule_version (rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by, peer_reviewed_by, status)
   VALUES ('$RULE1',5,'$TEN','$LAYER_GG','BALANCE','$JIA','$YI','ACTIVE')" "RULE_VERSION_MUST_START_DRAFT"
expect_ok "規則版本建立為 DRAFT，且 peer_reviewed_by 可為空（草稿必須能存在）" \
  "$T1 INSERT INTO rule_version (rule_version_id, rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by)
   VALUES ('$RV1','$RULE1',1,'$TEN','$LAYER_GG','BALANCE','$JIA')"
expect_err "SOD-H3：未同行覆核不得生效" \
  "$T1 UPDATE rule_version SET status='ACTIVE' WHERE rule_version_id='$RV1'" "SODH3_PEER_REVIEW_REQUIRED"
expect_err "SOD-H3：草案人不得同行覆核自己" \
  "$T1 UPDATE rule_version SET peer_reviewed_by='$JIA', status='ACTIVE'
   WHERE rule_version_id='$RV1'" "SODH3_PEER_REVIEW_REQUIRED"
expect_ok "SOD-H3：另一自然人同行覆核後可生效" \
  "$T1 UPDATE rule_version SET peer_reviewed_by='$YI', status='ACTIVE' WHERE rule_version_id='$RV1'"
expect_err "SOD-H3 基準不可改寫：草案人不可變更" \
  "$T1 UPDATE rule_version SET drafted_by='$YI' WHERE rule_version_id='$RV1'" "RULE_VERSION_IMMUTABLE"
expect_err "SOD-H3 基準不可改寫：同行覆核人首次設定後不可換人" \
  "$T1 UPDATE rule_version SET peer_reviewed_by='$BING' WHERE rule_version_id='$RV1'" "RULE_VERSION_IMMUTABLE"

# 四類不可混記②：Adjustment 引用規則時比對「層」而非只比 rule_type
RV2=41000000-0000-0000-0000-000000000002
expect_ok "第二個規則版本（DEFERRED_TAX 類，掛 DEFERRED_TAX 層）" \
  "$T1 INSERT INTO rule (rule_id, scope_level, tenant_id, engagement_id, rule_type, code, name)
   VALUES ('40000000-0000-0000-0000-000000000002','CLIENT','$TEN','$ENG','DEFERRED_TAX','R-DT-01','稅效果');
   INSERT INTO rule_version (rule_version_id, rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by)
   VALUES ('$RV2','40000000-0000-0000-0000-000000000002',1,'$TEN',
           '10000000-0000-0000-0000-000000000004','BALANCE','$JIA');
   UPDATE rule_version SET peer_reviewed_by='$YI', status='ACTIVE' WHERE rule_version_id='$RV2'"
expect_err "四類不可混記②：調整的分層與所引用規則版本的分層不一致 → 拒絕" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by,
        basis_from_id, basis_to_id, posting_layer_id, rule_version_id)
   VALUES ('$TEN','$ENG','$PR','混記','$JIA','$BASIS_A','$BASIS_C','$LAYER_GG','$RV2')" \
  "ADJ_LAYER_RULE_MISMATCH"
RV3=41000000-0000-0000-0000-000000000003
expect_ok "第三個規則版本維持 DRAFT（供「只能引用 ACTIVE」測試）" \
  "$T1 INSERT INTO rule_version (rule_version_id, rule_id, version_no, tenant_id, posting_layer_id,
        required_granularity, drafted_by)
   VALUES ('$RV3','$RULE1',2,'$TEN','$LAYER_GG','BALANCE','$JIA')"
n=$(APP_C <<<"$T1 SELECT status||'/'||(SELECT code FROM posting_layer p WHERE p.layer_id = rv.posting_layer_id)
     FROM rule_version rv WHERE rule_version_id='$RV3'")
[ "$n" = "DRAFT/GROUP_GAAP_ADJ" ] && ok "前置成立：RV3 為 DRAFT 且分層與調整相同（唯一差異是未生效）" \
  || ng "前置不成立：RV3 為 $n"
expect_err "只能引用已生效的規則版本（分層相同也不例外）" \
  "$T1 INSERT INTO adjustment (tenant_id, engagement_id, period_revision_id, title, prepared_by,
        basis_from_id, basis_to_id, posting_layer_id, rule_version_id)
   VALUES ('$TEN','$ENG','$PR','引用草稿','$JIA','$BASIS_A','$BASIS_C','$LAYER_GG','$RV3')" \
  "RULE_VERSION_NOT_ACTIVE"

# ── 7 TaxBasisObservation：欄位契約、AMENDED、確認角色 ──
# 觀測引用既有的來源資料集（來源集合有冪等唯一鍵，不另建重複列）
SDS=$(APP_C <<<"$T1 SELECT source_dataset_id FROM source_dataset ORDER BY source_dataset_id LIMIT 1")
[ ${#SDS} -eq 36 ] && ok "前置成立：已有可引用的來源資料集" || ng "前置不成立：來源資料集為 '$SDS'"
expect_err "AMENDED 尚未實作 → fail closed（取代鏈留待更正申告刀）" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, account_id, amount, evidence_status, source_dataset_id, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','$ACC1',1,'AMENDED','$SDS','$BING')" \
  "AMENDED_NOT_IMPLEMENTED"
expect_err "觀測只適用於權威匯入基礎（掛到 A）→ 拒絕" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, account_id, amount, evidence_status, source_dataset_id, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_A','$ACC1',1,'FILED','$SDS','$BING')" \
  "TAX_OBS_BASIS_NOT_DIRECT"
expect_err "欄位契約：非 MISSING 缺金額／來源資料集 → 拒絕" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, account_id, evidence_status, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','$ACC1','FILED','$BING')" \
  "TAX_OBS_FIELD_CONTRACT"
expect_err "欄位契約：MISSING 缺原因／負責人／截止日 → 拒絕" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, evidence_status)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','MISSING')" \
  "TAX_OBS_FIELD_CONTRACT"
expect_err "欄位契約：MISSING 不得帶確認人（沒有數字就沒有人能確認它）" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, evidence_status, missing_reason, owner_id, due_date, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','MISSING','申告未完成','$JIA','2026-06-30','$BING')" \
  "TAX_OBS_FIELD_CONTRACT"
# 確認角色：先證明前置狀態成立，再驗拒絕理由（避免以錯誤理由通過）
n=$(APP_C <<<"$T1 SELECT confirmation_role FROM basis_source_policy_version WHERE basis_source_policy_version_id='$POL_OK'")
[ "$n" = "R1" ] && ok "前置成立：政策指定的確認角色為 R1" || ng "前置不成立：政策角色為 $n"
n=$(APP_C <<<"$T1 SELECT count(*) FROM role_assignment WHERE user_id='$JIA' AND engagement_id='$ENG' AND revoked_at IS NULL")
[ "$n" -ge 1 ] && ok "前置成立：甲確實存在且被指派於本案件（只是沒有 R1）" || ng "前置不成立：甲的指派數 $n"
expect_err "GB-02：確認人在本案件但角色不符（甲無 R1）→ 拒絕" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, account_id, amount, evidence_status, source_dataset_id, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','$ACC1',1000,'FILED','$SDS','$JIA')" \
  "TAX_CONFIRMER_ROLE_INVALID"
OBS1=51000000-0000-0000-0000-000000000001
expect_ok "持有 R1 的確認人（丙）→ 通過" \
  "$T1 INSERT INTO tax_basis_observation (observation_id, tenant_id, engagement_id, reporting_unit_id,
        as_of_date, book_basis_id, account_id, amount, evidence_status, source_dataset_id,
        confirmed_by, confirmed_role)
   VALUES ('$OBS1','$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','$ACC1',
           1000,'FILED','$SDS','$BING','R6')"
n=$(APP_C <<<"$T1 SELECT confirmed_role||'/'||(confirmed_at IS NOT NULL) FROM tax_basis_observation WHERE observation_id='$OBS1'")
[ "$n" = "R1/true" ] && ok "確認角色快照由 DB 寫入並覆寫呼叫端宣告（宣告 R6 → 實存 R1）" \
  || ng "確認角色未被 DB 覆寫：$n"
expect_err "唯一性：同一（基礎,單位,日期,科目）重複 → 拒絕" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, account_id, amount, evidence_status, source_dataset_id, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$ASOF','$BASIS_B','$ACC1',1,'FILED','$SDS','$BING')" \
  "duplicate key"
expect_ok "整體缺漏（account_id 為 NULL）可登記一次" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, evidence_status, missing_reason, owner_id, due_date)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000002','$ASOF','$BASIS_B','MISSING','申告未完成','$JIA','2026-06-30')"
expect_err "NULLS NOT DISTINCT：同一日期第二筆整體缺漏 → 拒絕（NULL 不得被視為互異）" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, evidence_status, missing_reason, owner_id, due_date)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000002','$ASOF','$BASIS_B','MISSING','再登記一次','$JIA','2026-07-31')" \
  "duplicate key"
expect_err "確認人建立後不可變更" \
  "$T1 UPDATE tax_basis_observation SET confirmed_by='$YI' WHERE observation_id='$OBS1'" "TAX_OBS_IMMUTABLE"
n=$(APP_C <<<"$T1 UPDATE role_assignment SET revoked_at=now()
      WHERE user_id='$BING' AND role='R1'; SELECT confirmed_role FROM tax_basis_observation WHERE observation_id='$OBS1'")
[ "$n" = "R1" ] && ok "INV-11：角色指派撤銷後，既有觀測的角色快照不變" || ng "角色快照被追溯改變：$n"
expect_err "撤銷後：同一人不得再建立新觀測（有效未撤銷才算數）" \
  "$T1 INSERT INTO tax_basis_observation (tenant_id, engagement_id, reporting_unit_id, as_of_date,
        book_basis_id, account_id, amount, evidence_status, source_dataset_id, confirmed_by)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','2026-03-30','$BASIS_B','$ACC1',1,'FILED','$SDS','$BING')" \
  "TAX_CONFIRMER_ROLE_INVALID"
PSQL_C <<<"$T1 UPDATE role_assignment SET revoked_at=NULL WHERE user_id='$BING' AND role='R1'" >/dev/null

# ── 8 分層快照與版本界線（manifest 是否凍結組成） ──
MANI06=ee110000-0000-0000-0000-0000000000c3
RUN06=ee110000-0000-0000-0000-0000000000c9
expect_ok "含組成的 Manifest ＋ Run（分層模型之後的 run）" \
  "$T1 INSERT INTO calculation_input_manifest (manifest_id, tenant_id, engagement_id, period_revision_id,
        calculation_scope, canonicalization_version, frozen_set_content_hash, created_by)
   VALUES ('$MANI06','$TEN','$ENG','$PR','NO_FX','sqlcanon-1','h3','$JIA');
   INSERT INTO calculation_manifest_entry (tenant_id, manifest_id, object_type, object_id,
        domain_version_kind, domain_version_value, content_canonical, content_hash, payload) VALUES
     ('$TEN','$MANI06','BASIS_COMPOSITION','$COMP_A','COMPOSITION_VERSION_NO','1','cA','hA',
      jsonb_build_object('basis_id','$BASIS_A')),
     ('$TEN','$MANI06','BASIS_COMPOSITION','$COMP_C','COMPOSITION_VERSION_NO','1','cC','hC',
      jsonb_build_object('basis_id','$BASIS_C'));
   INSERT INTO calculation_run (calculation_run_id, tenant_id, engagement_id, period_revision_id,
        import_batch_id, manifest_id, run_type, request_key, request_content_hash, engine_version, created_by)
   VALUES ('$RUN06','$TEN','$ENG','$PR','$B1','$MANI06','PREVIEW',
           'ee110000-0000-0000-0000-0000000000a9','rc9','calc-engine-1','$JIA')"
expect_err "版本界線：含組成的 run，快照未標分層 → 拒絕（不靠 worker 紀律）" \
  "$T1 INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, account_id,
        account_code, account_name, debit, credit)
   VALUES ('$TEN','$RUN06','SOURCE_TB','$ACC1','1002','银行存款',1000,0)" "BSL_POSTING_LAYER_REQUIRED"
expect_err "版本界線：不含組成的歷史 run，快照不得標分層" \
  "$T1 INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, posting_layer_id,
        account_id, account_code, account_name, debit, credit)
   VALUES ('$TEN','$RUNB','ADJUSTMENT','$LAYER_GG','$ACC1','1002','银行存款',1,0)" "BSL_POSTING_LAYER_UNEXPECTED"
n=$(APP_C <<<"$T1 SELECT count(*) FROM balance_snapshot_line
      WHERE calculation_run_id='$RUNA' AND posting_layer_id IS NULL")
[ "$n" -ge 1 ] && ok "歷史 run 的快照未被回寫（posting_layer_id 維持 NULL）" || ng "歷史快照被回寫"
expect_ok "含組成的 run：帶分層的快照（A=1000；C=1000+200；ACC2 僅調整層 -200）" \
  "$T1 INSERT INTO balance_snapshot_line (tenant_id, calculation_run_id, posting_layer, posting_layer_id,
        account_id, account_code, account_name, debit, credit) VALUES
     ('$TEN','$RUN06','SOURCE_TB','$LAYER_LB','$ACC1','1002','银行存款',1000,0),
     ('$TEN','$RUN06','ADJUSTMENT','$LAYER_GG','$ACC1','1002','银行存款',200,0),
     ('$TEN','$RUN06','ADJUSTMENT','$LAYER_GG','$ACC2','6602','管理费用',0,200)"
n=$(APP_C <<<"$T1 SELECT amount::text FROM fn_basis_account_balance('$RUN06','$BASIS_C') WHERE account_id='$ACC1'")
[ "$n" = "1200.00" ] && ok "INV-01：C 基礎餘額＝LOCAL_BOOK＋GROUP_GAAP_ADJ（逐科目由組成加總）" \
  || ng "INV-01：C 的 1002 餘額為 ${n}（預期 1200）"
n=$(APP_C <<<"$T1 SELECT amount::text FROM fn_basis_account_balance('$RUN06','$BASIS_A') WHERE account_id='$ACC1'")
[ "$n" = "1000.00" ] && ok "INV-01：A 基礎餘額只含 LOCAL_BOOK" || ng "INV-01：A 的 1002 餘額為 ${n}（預期 1000）"
n=$(APP_C <<<"$T1 SELECT count(*) FROM fn_basis_account_balance('$RUNA','$BASIS_C')" 2>&1 | grep -c "RECON_RUN_PREDATES_BASIS_MODEL")
[ "$n" -ge 1 ] && ok "歷史 run 無組成凍結 → 基礎餘額 fail closed（不得把 SOURCE_TB 當成 LOCAL_BOOK）" \
  || ng "歷史 run 竟能算出基礎餘額"

# ── 9 調節模型：DRAFT 自由增修、FINALIZE 一次驗 INV-02、之後全凍結 ──
REC1=60000000-0000-0000-0000-000000000001
expect_err "調節只能以 DRAFT 建立" \
  "$T1 INSERT INTO basis_reconciliation (tenant_id, engagement_id, reporting_unit_id,
        period_revision_id, from_basis_id, to_basis_id, calculation_run_id, status)
   VALUES ('$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$PR','$BASIS_A','$BASIS_C','$RUN06','FINALIZED')" \
  "RECON_INSERT_MUST_BE_DRAFT"
expect_ok "調節建立（A→C，綁定既有 run）" \
  "$T1 INSERT INTO basis_reconciliation (reconciliation_id, tenant_id, engagement_id, reporting_unit_id,
        period_revision_id, from_basis_id, to_basis_id, calculation_run_id)
   VALUES ('$REC1','$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$PR','$BASIS_A','$BASIS_C','$RUN06')"
expect_ok "DRAFT 期間可自由新增明細（不受即時平衡檢查——第一列必然不平）" \
  "$T1 INSERT INTO reconciliation_line (tenant_id, reconciliation_id, account_id, amount,
        source_adjustment_id, description)
   VALUES ('$TEN','$REC1','$ACC1',200,'$ADJ','集團折舊政策差異')"
expect_err "調節明細必須說得出來源（兩者皆空）→ 拒絕" \
  "$T1 INSERT INTO reconciliation_line (tenant_id, reconciliation_id, account_id, amount, description)
   VALUES ('$TEN','$REC1','$ACC2',-200,'無來源')" "check constraint"
expect_err "尾差自動結案尚未實作 → fail closed（單筆與累積容許值皆無從判定）" \
  "$T1 INSERT INTO reconciliation_difference (tenant_id, reconciliation_id, account_id, amount,
        reason_class, resolution_status)
   VALUES ('$TEN','$REC1','$ACC2',-200,'ROUNDING','RESOLVED_BY_POLICY')" "INV24_THRESHOLD_NOT_IMPLEMENTED"
n=$(APP_C <<<"$T1 SELECT count(*) FROM reconciliation_line WHERE reconciliation_id='$REC1'")
[ "$n" = "1" ] && ok "前置成立：ACC1 已有調節明細、ACC2 尚無任何去處" || ng "前置不成立：明細數 $n"
n=$(APP_C <<<"$T1 SELECT fn_reconciliation_finalize('$REC1','$JIA')" 2>&1 | grep -c "INV02_RECONCILIATION_IMBALANCE")
[ "$n" -ge 1 ] && ok "INV-02：ACC2 殘差無去處 → FINALIZE 整筆拒絕（尾差不得靜默吸收）" \
  || ng "INV-02：不平衡竟可定稿"
n=$(APP_C <<<"$T1 SELECT status FROM basis_reconciliation WHERE reconciliation_id='$REC1'")
[ "$n" = "DRAFT" ] && ok "FINALIZE 被拒後調節仍為 DRAFT（整筆交易回滾）" || ng "FINALIZE 失敗卻改了狀態：$n"
expect_ok "殘差登記為顯式差異（OPEN；不得靜默吸收）" \
  "$T1 INSERT INTO reconciliation_difference (tenant_id, reconciliation_id, account_id, amount,
        reason_class, owner_id, due_date)
   VALUES ('$TEN','$REC1','$ACC2',-200,'UNEXPLAINED','$JIA','2026-06-30')"
n=$(APP_C <<<"$T1 SELECT fn_reconciliation_finalize('$REC1','$JIA')" 2>&1 | grep -c "ERROR")
[ "$n" = "0" ] && ok "INV-02 成立 → FINALIZE 通過" || ng "FINALIZE 仍失敗"
n=$(APP_C <<<"$T1 SELECT status FROM basis_reconciliation WHERE reconciliation_id='$REC1'")
[ "$n" = "FINALIZED" ] && ok "定稿後狀態為 FINALIZED，且同交易寫入 DomainEvent" || ng "狀態為 $n"
n=$(APP_C <<<"$T1 SELECT count(*) FROM audit_event WHERE event_type='basis_reconciliation.finalized'
      AND object_id='$REC1'")
[ "$n" = "1" ] && ok "調節定稿事件已寫入稽核軌跡" || ng "定稿事件數 $n"
expect_err "定稿後明細不可再增加" \
  "$T1 INSERT INTO reconciliation_line (tenant_id, reconciliation_id, account_id, amount,
        source_adjustment_id, description)
   VALUES ('$TEN','$REC1','$ACC1',1,'$ADJ','事後追加')" "RECON_FINALIZED_IMMUTABLE"
expect_err "定稿後差異不可改（本刀不提供結案功能；未來以獨立 append-only 紀錄擴充）" \
  "$T1 UPDATE reconciliation_difference SET resolution_status='EXPLAINED' WHERE reconciliation_id='$REC1'" \
  "RECON_FINALIZED_IMMUTABLE"
n=$(APP_C <<<"$T1 UPDATE basis_reconciliation SET status='DRAFT' WHERE reconciliation_id='$REC1'" 2>&1 | grep -c "permission denied")
[ "$n" -ge 1 ] && ok "唯一入口：app_runtime 對 basis_reconciliation 無 UPDATE（不得繞過 finalize）" \
  || ng "調節狀態可被直接改寫"
n=$(APP_C <<<"$T1 SELECT count(*) FROM reconciliation_difference
      WHERE reconciliation_id='$REC1' AND resolution_status='OPEN'")
[ "$n" = "1" ] && ok "未解釋差異數以 resolution_status='OPEN' 查得（不看 reason_class）" || ng "OPEN 差異數 $n"

# ── 10 INV-05：涉權威匯入基礎的調節在 FINALIZE 時驗觀測涵蓋 ──
REC2=60000000-0000-0000-0000-000000000002
expect_ok "調節建立（A→B，端點含權威匯入基礎）" \
  "$T1 INSERT INTO basis_reconciliation (reconciliation_id, tenant_id, engagement_id, reporting_unit_id,
        period_revision_id, from_basis_id, to_basis_id, calculation_run_id)
   VALUES ('$REC2','$TEN','$ENG','bbbbbbbb-0000-0000-0000-000000000001','$PR','$BASIS_A','$BASIS_B','$RUN06');
   INSERT INTO reconciliation_line (tenant_id, reconciliation_id, account_id, amount,
        source_rule_version_id, description)
   VALUES ('$TEN','$REC2','$ACC2',0,'$RV1','稅務差異（本科目無觀測）')"
n=$(APP_C <<<"$T1 SELECT count(*) FROM tax_basis_observation
      WHERE book_basis_id='$BASIS_B' AND account_id='$ACC2' AND as_of_date='$ASOF'")
[ "$n" = "0" ] && ok "前置成立：6602 於期末確實沒有稅務基礎觀測" || ng "前置不成立：觀測數 $n"
n=$(APP_C <<<"$T1 SELECT fn_reconciliation_finalize('$REC2','$JIA')" 2>&1 | grep -c "INV05_TAX_OBSERVATION_MISSING")
[ "$n" -ge 1 ] && ok "INV-05：缺已確認觀測的科目 → FINALIZE 拒絕（掛在具體操作上）" \
  || ng "INV-05：缺觀測竟可定稿"

# ── 11 INV-21：已被鎖定期間的凍結清單引用的組成不得變更 ──
n=$(APP_C <<<"$T1 SELECT status FROM period_revision WHERE period_revision_id='$PR'")
[ "$n" != "LOCKED" ] && ok "前置成立：本期尚未 LOCKED，組成仍可退役" || ng "前置不成立：期間已 $n"
expect_ok "未鎖定期間：組成可退役（APPROVED → RETIRED）" \
  "$T1 UPDATE basis_composition_version SET status='RETIRED' WHERE basis_composition_version_id='$CMP_TMP'"
PSQL_C <<<"UPDATE period_revision SET status='LOCKED' WHERE period_revision_id='$PR'" >/dev/null 2>&1 \
  || PSQL_C <<<"ALTER TABLE period_revision DISABLE TRIGGER trg_period_transition;
                UPDATE period_revision SET status='LOCKED' WHERE period_revision_id='$PR';
                ALTER TABLE period_revision ENABLE TRIGGER trg_period_transition;" >/dev/null
expect_err "INV-21：期間已 LOCKED，其凍結清單引用的組成不得再變更" \
  "$T1 UPDATE basis_composition_version SET status='RETIRED' WHERE basis_composition_version_id='$COMP_C'" \
  "INV21_LOCKED_COMPOSITION"
PSQL_C <<<"ALTER TABLE period_revision DISABLE TRIGGER trg_period_transition;
           UPDATE period_revision SET status='SETUP' WHERE period_revision_id='$PR';
           ALTER TABLE period_revision ENABLE TRIGGER trg_period_transition;" >/dev/null

# ── 12 AC-BAS-001：新增第四種基礎零 DDL ──
BEFORE=$(APP_C <<<"$T1 SELECT md5(string_agg(basis_id::text||code, ',' ORDER BY code)) FROM book_basis")
BASIS_D=20000000-0000-0000-0000-0000000000d1
CMP_D=21000000-0000-0000-0000-0000000000d1
expect_ok "新增第四基礎（D／IFRS）＋組成＋調整＋物化分錄——全部只用 INSERT" \
  "$T1 INSERT INTO book_basis (basis_id, tenant_id, engagement_id, code, jurisdiction, framework,
        source_mode, permits_group_layer)
   VALUES ('$BASIS_D','$TEN','$ENG','D','XX','IFRS','COMPOSED',false);
   INSERT INTO basis_composition_version (basis_composition_version_id, composition_series_id,
        version_no, tenant_id, engagement_id, basis_id, status)
   VALUES ('$CMP_D','21000000-0000-0000-0000-0000000001d1',1,'$TEN','$ENG','$BASIS_D','DRAFT');
   INSERT INTO constitutive_layer_item (basis_composition_version_id, layer_id, sign) VALUES
     ('$CMP_D','$LAYER_LB',1),('$CMP_D','$LAYER_GG',1);
   UPDATE basis_composition_version SET status='APPROVED', approved_by='$BING', approved_at=now(),
          approval_role='R4' WHERE basis_composition_version_id='$CMP_D';
   INSERT INTO adjustment (adjustment_id, tenant_id, engagement_id, period_revision_id, title,
        prepared_by, basis_from_id, basis_to_id, posting_layer_id)
   VALUES ('ad000000-0000-0000-0000-0000000000d1','$TEN','$ENG','$PR','IFRS 調整','$JIA',
           '$BASIS_A','$BASIS_D','$LAYER_GG')"
AFTER=$(APP_C <<<"$T1 SELECT md5(string_agg(basis_id::text||code, ',' ORDER BY code))
        FROM book_basis WHERE code <> 'D'")
[ "$BEFORE" = "$AFTER" ] && ok "AC-BAS-001：既有 A／B／C 未被修改（逐列雜湊比對）" || ng "既有基礎被改動"
n=$(APP_C <<<"$T1 SELECT count(*) FROM constitutive_layer_item WHERE basis_composition_version_id='$CMP_D'")
[ "$n" = "2" ] && ok "AC-BAS-001：第四基礎的組成成立，全程零 DDL" || ng "第四基礎組成項數 $n"

# ── 13 RLS（INV-18） ──
n=$(APP_C <<<"$T2 SELECT count(*) FROM book_basis")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的基礎" || ng "RLS：基礎洩漏 $n 筆"
n=$(APP_C <<<"$T2 SELECT count(*) FROM tax_basis_observation")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的稅務基礎觀測" || ng "RLS：觀測洩漏 $n 筆"
n=$(APP_C <<<"$T2 SELECT count(*) FROM basis_reconciliation")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的調節結果" || ng "RLS：調節洩漏 $n 筆"
n=$(APP_C <<<"$T2 SELECT count(*) FROM constitutive_layer_item")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的構成項（以父版本的租戶隔離）" || ng "RLS：構成項洩漏 $n 筆"
n=$(APP_C <<<"$T2 SELECT count(*) FROM rule")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的客戶規則" || ng "RLS：規則洩漏 $n 筆"

[ "${STANDALONE:-0}" = "1" ] && summary
