#!/usr/bin/env bash
# 映射版本化與來源批次脈絡（0005／0006／0021）
# 可單跑（自行重建 DB 並補齊前置），也可由 tests/integration/db.test.sh 依序聚合執行。
if [ -z "${DB_TEST_HARNESS:-}" ]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
  DB_TEST_HARNESS=1; STANDALONE=1
  echo "══ 映射版本化與來源批次脈絡（0005／0006／0021）（${DB}）══"
fi
need fx_reset fx_core fx_accounts

# ── 映射版本化（SLICE-M2-01；migrations/0005） ───────
# 前置由 fx_accounts 建立。此處**只斷言它確實存在**，不重複 INSERT——
# 重複插入必然 duplicate key，而錯誤被吞掉之後下一行照樣記 PASS：
# 那正是「以錯誤理由通過」的假綠。
seeded=$(APP_C <<<"$T1 SELECT count(*) FROM account WHERE account_id IN ('$ACC1','$ACC2','$ACC99')")
[ "$seeded" = "3" ] && ok "前置成立：兩案件各一份科目表（1002／6602 ＋ 另一案件 1002）" \
  || ng "前置不成立：fx_accounts 的三個科目只找到 $seeded 個"

MR1=ab000000-0000-0000-0000-000000000001
expect_ok "映射：建立草稿 v1" \
  "INSERT INTO mapping_rule (mapping_rule_id, tenant_id, engagement_id, source_account_code, target_account_id, version_no, created_by)
   VALUES ('$MR1','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','111','ac000000-0000-0000-0000-000000000001',1,'aaaaaaaa-0000-0000-0000-000000000001')"
expect_err "映射歸屬：目標科目屬其他案件 → 拒絕（§24.1A）" \
  "INSERT INTO mapping_rule (tenant_id, engagement_id, source_account_code, target_account_id, version_no, created_by)
   VALUES ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','112','ac000000-0000-0000-0000-000000000099',1,'aaaaaaaa-0000-0000-0000-000000000001')" "歸屬違規"
expect_err "映射 SOD：建立者不得批准自己（自然人判定）" \
  "UPDATE mapping_rule SET approved_by='aaaaaaaa-0000-0000-0000-000000000001', approved_at=now() WHERE mapping_rule_id='$MR1'" "SOD"
expect_ok "映射批准：另一自然人可批准" \
  "UPDATE mapping_rule SET approved_by='aaaaaaaa-0000-0000-0000-000000000002', approved_at=now() WHERE mapping_rule_id='$MR1'"
expect_err "映射版本不可覆寫：已批准列不可修改" \
  "UPDATE mapping_rule SET target_account_id='ac000000-0000-0000-0000-000000000002' WHERE mapping_rule_id='$MR1'" "不可覆寫"
expect_err "映射版本不可覆寫：已批准列不可刪除" \
  "DELETE FROM mapping_rule WHERE mapping_rule_id='$MR1'" "不可覆寫"
expect_ok "映射改版＝插入新版本列（v2）" \
  "INSERT INTO mapping_rule (tenant_id, engagement_id, source_account_code, target_account_id, version_no, created_by)
   VALUES ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','111','ac000000-0000-0000-0000-000000000002',2,'aaaaaaaa-0000-0000-0000-000000000001')"
expect_err "同（案件, 來源科目, 版本）唯一" \
  "INSERT INTO mapping_rule (tenant_id, engagement_id, source_account_code, target_account_id, version_no, created_by)
   VALUES ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','111','ac000000-0000-0000-0000-000000000001',2,'aaaaaaaa-0000-0000-0000-000000000001')" "duplicate key"
n=$(APP_C <<<"$T2 SELECT count(*) FROM mapping_rule")
[ "$n" = "0" ] && ok "RLS：T2 看不到 T1 的映射" || ng "RLS：mapping_rule 洩漏 $n 筆"
expect_err "硬化：created_by 必填（NULL 會使 SOD 比較永遠不成立）" \
  "INSERT INTO mapping_rule (tenant_id, engagement_id, source_account_code, target_account_id, version_no)
   VALUES ('11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','130','ac000000-0000-0000-0000-000000000001',1)" "null value"
expect_err "硬化：created_by 不可變更（草稿改建立者再自批＝同一個洞）" \
  "INSERT INTO mapping_rule (mapping_rule_id, tenant_id, engagement_id, source_account_code, target_account_id, version_no, created_by)
   VALUES ('ab000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','eeeeeeee-0000-0000-0000-000000000001','140','ac000000-0000-0000-0000-000000000001',1,'aaaaaaaa-0000-0000-0000-000000000001');
   UPDATE mapping_rule SET created_by='aaaaaaaa-0000-0000-0000-000000000002' WHERE mapping_rule_id='ab000000-0000-0000-0000-000000000002'" "不可變更"

# ══ 0021：映射來源批次必須已接受 ══════════════════════════════
# 0020 只驗同租戶同案件；未經接受的批次（含 QUARANTINED）曾可成為正式映射的來源脈絡。
TEN=11111111-1111-1111-1111-111111111111
LE1=cccccccc-0000-0000-0000-000000000001
PRX=99999999-0000-0000-0000-000000000001
# 依 0019／0020 的合法路徑推進：assessment 必須先獨立寫入，identity 判定與 current
# 指標同一次 UPDATE 成對寫入，且只能在 VALIDATING 階段。種子失敗即 fail closed。
mkbatch() {   # $1=批次id $2=目標狀態 $3=assessment id
  PSQL_C <<SQL >/dev/null 2>&1 || { ng "0021 種子 $2 建立失敗（fail closed）"; return 1; }
$T1
INSERT INTO import_batch (import_batch_id, tenant_id, engagement_id, declared_legal_entity_id,
        declared_period_revision_id, uploaded_by, provided_by, file_name, file_sha256, status)
VALUES ('$1','$TEN','$ENG','$LE1','$PRX','$JIA','$JIA','tb.csv','sha-$1','DRAFT');
SQL
  [ "$2" = "DRAFT" ] && return 0
  PSQL_C <<<"$T1 UPDATE import_batch SET status='UPLOADED' WHERE import_batch_id='$1'" >/dev/null 2>&1 \
    || { ng "0021 種子 $2：UPLOADED 失敗"; return 1; }
  [ "$2" = "UPLOADED" ] && return 0
  PSQL_C <<SQL >/dev/null 2>&1 || { ng "0021 種子 $2：VALIDATED 路徑失敗"; return 1; }
$T1
UPDATE import_batch SET status='VALIDATING' WHERE import_batch_id='$1';
INSERT INTO source_identity_assessment (assessment_id, tenant_id, import_batch_id, batch_version,
        match_result, evidence_kind, detection_rule_version)
VALUES ('$3','$TEN','$1',1,'MATCH','AUTHORITATIVE_ID','detect-r1');
UPDATE import_batch SET identity_status='MATCHED', current_identity_assessment_id='$3'
 WHERE import_batch_id='$1';
UPDATE import_batch SET hash_verified=true WHERE import_batch_id='$1';
UPDATE import_batch SET status='VALIDATED' WHERE import_batch_id='$1';
SQL
  [ "$2" = "VALIDATED" ] && return 0
  if [ "$2" = "QUARANTINED" ]; then
    PSQL_C <<<"$T1 UPDATE import_batch SET status='QUARANTINED', quarantine_reason='測試' WHERE import_batch_id='$1'" >/dev/null 2>&1
  else
    PSQL_C <<<"$T1 UPDATE import_batch SET status='ACCEPTED' WHERE import_batch_id='$1'" >/dev/null 2>&1
  fi
  st=$(APP_C <<<"$T1 SELECT status FROM import_batch WHERE import_batch_id='$1'")
  [ "$st" = "$2" ] || { ng "0021 種子批次 $1 期望 $2 得到 $st"; return 1; }
  return 0
}
BD=ba000000-0000-0000-0000-000000000301    # DRAFT
BU2=ba000000-0000-0000-0000-000000000401   # UPLOADED
BV=ba000000-0000-0000-0000-000000000501    # VALIDATED
BQ=ba000000-0000-0000-0000-000000000601    # QUARANTINED
BA=ba000000-0000-0000-0000-000000000701    # ACCEPTED
BS=ba000000-0000-0000-0000-000000000801    # ACCEPTED → 稍後轉 SUPERSEDED
AS1=a9000000-0000-0000-0000-000000000501
AS2=a9000000-0000-0000-0000-000000000601
AS3=a9000000-0000-0000-0000-000000000701
AS4=a9000000-0000-0000-0000-000000000801
mkbatch "$BD" DRAFT ""; mkbatch "$BU2" UPLOADED ""; mkbatch "$BV" VALIDATED "$AS1"
mkbatch "$BQ" QUARANTINED "$AS2"; mkbatch "$BA" ACCEPTED "$AS3"; mkbatch "$BS" ACCEPTED "$AS4"
seeded=$(APP_C <<<"$T1 SELECT string_agg(status::text, ',' ORDER BY import_batch_id)
  FROM import_batch WHERE import_batch_id IN ('$BD','$BU2','$BV','$BQ','$BA','$BS')")
[ "$seeded" = "DRAFT,UPLOADED,VALIDATED,QUARANTINED,ACCEPTED,ACCEPTED" ] \
  && ok "0021 種子：六個批次確實停在 DRAFT／UPLOADED／VALIDATED／QUARANTINED／ACCEPTED×2" \
  || ng "0021 種子狀態不符：$seeded"

mkmap() {   # $1=來源批次 $2=來源科目代碼
  echo "INSERT INTO mapping_rule (tenant_id, engagement_id, source_account_code,
          target_account_id, version_no, created_by, source_import_batch_id)
        VALUES ('$TEN','$ENG','$2','ac000000-0000-0000-0000-000000000001',1,'$JIA','$1')"
}
for pair in "$BD:DRAFT:901" "$BU2:UPLOADED:902" "$BV:VALIDATED:903" "$BQ:QUARANTINED:904"; do
  bid="${pair%%:*}"; rest="${pair#*:}"; st="${rest%%:*}"; code="${rest##*:}"
  expect_err "0021：來源批次為 $st → 拒絕建立映射" "$T1 $(mkmap "$bid" "$code")" "SOURCE_BATCH_NOT_ACCEPTED"
done
expect_ok "0021：來源批次為 ACCEPTED → 正常建立映射" "$T1 $(mkmap "$BA" 905)"

# 先 SUPERSEDED 再建立 → 必須拒絕
PSQL_C >/dev/null 2>&1 <<<"$T1 UPDATE import_batch SET status='SUPERSEDED', superseded_by_id='$BA' WHERE import_batch_id='$BS'"
expect_err "0021：來源批次已 SUPERSEDED → 拒絕建立映射" "$T1 $(mkmap "$BS" 906)" "SOURCE_BATCH_NOT_ACCEPTED"

# ── FOR UPDATE 競態：兩交易不得交錯穿越檢查 ──
# A：建立映射並鎖住來源批次列（持鎖 3 秒）；B：0.8 秒後嘗試把該批次轉 SUPERSEDED。
# 沒有 FOR UPDATE 時，B 會在 A 的檢查與提交之間穿過去。
BR=ba000000-0000-0000-0000-000000000901
mkbatch "$BR" ACCEPTED a9000000-0000-0000-0000-000000000901
( PSQL_C >/dev/null 2>&1 <<SQL
$T1
BEGIN;
$(mkmap "$BR" 907);
SELECT pg_sleep(3);
COMMIT;
SQL
) & APID=$!
sleep 0.8
start=$(date +%s)
PSQL_C >/dev/null 2>&1 <<<"$T1 UPDATE import_batch SET status='SUPERSEDED', superseded_by_id='$BA' WHERE import_batch_id='$BR'"
waited=$(( $(date +%s) - start ))
wait $APID
[ "$waited" -ge 1 ] && ok "0021 競態：B 的 SUPERSEDED 被 A 的列鎖擋住（等待 ${waited}s，未交錯穿越）" \
  || ng "0021 競態：B 未被阻塞（等待 ${waited}s）——FOR UPDATE 未生效"
n=$(APP_C <<<"$T1 SELECT count(*) FROM mapping_rule WHERE source_account_code='907'")
[ "$n" = "1" ] && ok "0021 競態：A 的映射已建立（檢查時來源仍為 ACCEPTED）" || ng "0021 競態：A 的映射未建立"
st=$(APP_C <<<"$T1 SELECT status FROM import_batch WHERE import_batch_id='$BR'")
[ "$st" = "SUPERSEDED" ] && ok "0021 競態：A 提交後 B 才生效（批次轉 SUPERSEDED）" || ng "0021 競態：批次狀態為 $st"
n=$(APP_C <<<"$T1 SELECT count(*) FROM mapping_rule WHERE source_account_code='907'")
[ "$n" = "1" ] && ok "0021：既有映射不因來源批次日後轉 SUPERSEDED 而被追溯刪除" || ng "既有映射被追溯刪除"
expect_ok "0021：既有映射仍可正常批准（不重驗來源狀態）" \
  "$T1 UPDATE mapping_rule SET approved_by='$YI', approved_at=now()
   WHERE source_account_code='907' AND source_import_batch_id='$BR'"
expect_err "0021：來源批次脈絡仍不可變更（改指向另一個批次亦拒絕）" \
  "$T1 UPDATE mapping_rule SET source_import_batch_id='$BR' WHERE source_account_code='905'" "不可變更"

[ "${STANDALONE:-0}" = "1" ] && summary
