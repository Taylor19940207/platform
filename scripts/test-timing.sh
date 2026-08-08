#!/usr/bin/env bash
# 逐 suite 計時：先知道時間花在哪裡，再決定優化什麼。
#
# 刻意**序列**執行並在每個 suite 之間確認沒有殘留的 API／worker 行程——
# 併發或殘留會讓測量結果失真（殘留 worker 會搶同一批 UPLOADED，
# 使下一個 suite 的 waitFor 一路耗到 deadline，量出來的是干擾不是成本）。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ACCEPTANCE=(milestone1 mapping-slice adjustment-slice job-reliability calculation-run
            evidence-package workbench-identity period-lifecycle multi-basis)

reap() {
  pkill -f "node apps/api/src/server.ts" 2>/dev/null
  pkill -f "node apps/worker/src/worker.ts" 2>/dev/null
  sleep 0.5
}

row() { printf "%7s  %s\n" "$1" "$2"; }

echo "══ 測試耗時（PSQL_MODE=${PSQL_MODE:-docker}）══"
total=0

reap
s=$SECONDS; node --test 'tests/unit/*.test.ts' >/dev/null 2>&1; d=$((SECONDS-s))
row "${d}s" "unit"; total=$((total+d))

reap
s=$SECONDS; bash tests/integration/db.test.sh >/dev/null 2>&1; d=$((SECONDS-s))
row "${d}s" "db-integration"; total=$((total+d))

for f in "${ACCEPTANCE[@]}"; do
  reap
  s=$SECONDS; node "tests/acceptance/$f.test.ts" >/dev/null 2>&1; d=$((SECONDS-s))
  row "${d}s" "acceptance/$f"; total=$((total+d))
done

reap
echo "────────"
row "${total}s" "合計"
