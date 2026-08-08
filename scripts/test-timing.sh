#!/usr/bin/env bash
# 逐 suite 計時：先知道時間花在哪裡，再決定優化什麼。
#
# 計時器**不得成為新的假綠來源**，因此：
#   * 每支都檢查 exit code，失敗印 FAIL 並保留該支輸出；任一失敗整體非零退出。
#   * 不做全域 pkill。開始前偵測到 dev 的 API／Worker 就拒絕執行（那是使用者的行程，
#     殺掉它既粗暴又會讓「測試前要停 dev」這條規則失去意義）。
#   * 每支結束後若有殘留行程，**該支判定失敗**——殘留是被測試的缺陷，
#     不是計時器該替它掃乾淨的髒東西。先記下 PID 再清理，避免污染下一支。
#     （2026-08-08 第一次量測得到 job-reliability 954s，就是上一支殘留的 worker
#      搶走 UPLOADED 批次所致；單跑只要 17s。這種事必須看得見。）
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ACCEPTANCE=(milestone1 mapping-slice adjustment-slice job-reliability calculation-run
            evidence-package workbench-identity period-lifecycle multi-basis)

OUT_DIR="$(mktemp -d)"
APP_PATTERN='node apps/(api|worker)/src/(server|worker)\.ts'

app_pids() { pgrep -f "$APP_PATTERN" 2>/dev/null | sort -n | tr '\n' ' ' | sed 's/ $//'; }

cleanup() { local p; p="$(app_pids)"; [ -n "$p" ] && kill $p 2>/dev/null; return 0; }
trap 'echo ""; echo "中斷——清理本次測試程序：$(app_pids)"; cleanup; exit 130' INT TERM

failed=0
row() { printf "%-4s %6s  %s\n" "$1" "$2" "$3"; }

# ── 開始前：dev 必須是停的 ──
pre="$(app_pids)"
if [ -n "$pre" ]; then
  echo "⛔ 偵測到正在執行的 API／Worker（PID: ${pre}）"
  echo "   端到端測試會自己 spawn API（8091～8099）與 worker，8080 的 dev worker"
  echo "   會搶同一批 UPLOADED 批次造成偽失敗。請先停掉 pnpm dev 再跑。"
  echo "   （本腳本刻意不替你殺掉——那是你的行程。）"
  exit 2
fi

# run <名稱> <指令…>
run() {
  local name="$1"; shift
  local log="$OUT_DIR/${name//\//_}.log"
  local s=$SECONDS rc=0
  "$@" >"$log" 2>&1 || rc=$?
  local d=$((SECONDS-s))

  local leaked; leaked="$(app_pids)"
  if [ -n "$leaked" ]; then
    row FAIL "${d}s" "$name  ← 殘留行程未被回收：PID $leaked"
    cleanup
    failed=1
    return
  fi
  if [ "$rc" -ne 0 ]; then
    row FAIL "${d}s" "$name  ← 退出碼 $rc"
    echo "──────── $name 輸出（末 30 行） ────────"
    tail -30 "$log" | sed 's/^/    /'
    echo "──────── 完整輸出：$log ────────"
    failed=1
    return
  fi
  row PASS "${d}s" "$name"
  TOTAL=$((TOTAL+d))
}

echo "══ 測試耗時（PSQL_MODE=${PSQL_MODE:-docker}）══"
TOTAL=0

run unit           node --test 'tests/unit/*.test.ts'
run db-integration bash tests/integration/db.test.sh
for f in "${ACCEPTANCE[@]}"; do
  run "acceptance/$f" node "tests/acceptance/$f.test.ts"
done

echo "────────"
row "" "${TOTAL}s" "合計（僅計成功的 suite）"
if [ "$failed" -ne 0 ]; then
  echo ""
  echo "⛔ 有 suite 失敗或洩漏行程——耗時數字在這種狀態下不具參考價值。"
  exit 1
fi
rm -rf "$OUT_DIR"
