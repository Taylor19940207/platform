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
process.on("SIGINT", () => { procs.forEach((p) => p.kill()); process.exit(0); });
console.log("dev 啟動：http://localhost:" + (process.env.PORT ?? 8080));
