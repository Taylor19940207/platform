// pnpm dev：同時啟動 API 與 Worker（前端骨架由 API 供頁；Next.js 到位後在此加入）。
import { spawn } from "node:child_process";
const procs = [
  ["api",    ["apps/api/src/server.ts"]],
  ["worker", ["apps/worker/src/worker.ts"]],
].map(([name, args]) => {
  const p = spawn("node", args, { stdio: ["ignore", "pipe", "pipe"] });
  p.stdout.on("data", (d) => process.stdout.write(`[${name}] ${d}`));
  p.stderr.on("data", (d) => process.stderr.write(`[${name}] ${d}`));
  p.on("exit", (c) => { console.log(`[${name}] exited (${c})`); procs.forEach((q) => q.kill()); process.exit(c ?? 1); });
  return p;
});
// SIGINT 與 SIGTERM 都要收拾子行程——只攔 SIGINT 時，`kill <dev.mjs>` 會遺留
// 殭屍 worker 繼續搶批次（且可能是舊程式碼），污染測試與開發資料。
for (const sig of ["SIGINT", "SIGTERM"])
  process.on(sig, () => { procs.forEach((p) => p.kill()); process.exit(0); });
console.log("dev 啟動：http://localhost:" + (process.env.PORT ?? 8080));
