// 環境設定單一入口：載入 repo 根目錄的 .env.local（不覆蓋既有環境變數），
// 供 TS 端所有模組使用。程式內不得寫死路徑、主機或使用者。
import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

export const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "../../..");

const envFile = join(REPO_ROOT, ".env.local");
if (existsSync(envFile)) {
  for (const line of readFileSync(envFile, "utf8").split("\n")) {
    const m = /^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
    if (m && !(m[1] in process.env)) process.env[m[1]] = m[2];
  }
}

const env = (k: string, d: string) => process.env[k] ?? d;

export const config = {
  psqlMode: env("PSQL_MODE", "docker") as "docker" | "local",
  dbContainer: env("DB_CONTAINER", "cbfc-db"),
  dbHost: env("DB_HOST", "127.0.0.1"),
  dbPort: env("DB_PORT", "5433"),
  dbUser: env("DB_USER", "dev"),
  dbPassword: env("DB_PASSWORD", "dev"),
  dbName: env("DB_NAME", "cbfc_dev"),
  port: Number(env("PORT", "8080")),
  pollMs: Number(env("POLL_MS", "1500")),
  objectStoreDir: env("OBJECT_STORE_DIR", "var/objects"),
  sessionSecret: env("SESSION_SECRET", ""),
  saveWindowSeconds: 5,   // 窗口參數 W（NFR-UX-001；可經批准放寬至 10）
};
