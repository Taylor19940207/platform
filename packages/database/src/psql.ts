// DB 轉接層（開發用；正式驅動見 docs/adr/ADR-LOCAL-001）。
// 傳輸由 PSQL_MODE 決定：
//   docker（預設）＝ docker exec 進 compose 的 db 容器，免裝本機 psql
//   local          ＝ 本機 psql 二進位（DB_HOST／DB_PORT／DB_PASSWORD）
// 參數經 psql -v 變數傳遞並以 :'name' 引用（psql 負責安全引號）；
// SQL 一律走 stdin（-c 不做變數插值，且 docker 模式下檔案不在容器內）。
import { spawnSync } from "node:child_process";
import { config } from "../../config/src/index.ts";

export interface DbOptions { db?: string; tenantId?: string; asRuntime?: boolean }

function run(sqlText: string, params: Record<string, string>, opts: DbOptions):
    { status: number | null; stdout: string; stderr: string } {
  const user = opts.asRuntime === false ? config.dbUser : "app_runtime";
  const db = opts.db ?? config.dbName;
  const psqlArgs = ["-v", "ON_ERROR_STOP=1", "-qtA", "--no-psqlrc", "-U", user, "-d", db];
  for (const [k, v] of Object.entries(params)) psqlArgs.push("-v", `${k}=${v}`);
  if (config.psqlMode === "docker") {
    const r = spawnSync("docker", ["exec", "-i", config.dbContainer, "psql", ...psqlArgs],
      { encoding: "utf8", input: sqlText });
    return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
  }
  const r = spawnSync("psql", ["-h", config.dbHost, "-p", config.dbPort, ...psqlArgs],
    { encoding: "utf8", input: sqlText,
      env: { ...process.env, PGPASSWORD: config.dbPassword } });
  return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

function preamble(opts: DbOptions): string {
  return opts.tenantId
    ? `SET app.tenant_id = '${opts.tenantId.replace(/[^0-9a-f-]/g, "")}'; `
    : "";
}

export function query<T = Record<string, unknown>>(
  sql: string, params: Record<string, string> = {}, opts: DbOptions = {}
): T[] {
  // DML＋RETURNING 須以 CTE 包裝（不能放進 FROM 子查詢）
  const isDml = /^\s*(insert|update|delete)/i.test(sql);
  const wrapped = isDml
    ? `${preamble(opts)}WITH t AS (${sql}) SELECT COALESCE(json_agg(t), '[]'::json) FROM t;`
    : `${preamble(opts)}SELECT COALESCE(json_agg(t), '[]'::json) FROM (${sql}) t;`;
  const r = run(wrapped, params, opts);
  if (r.status !== 0) throw new Error(`psql: ${r.stderr.trim()}`);
  return JSON.parse(r.stdout.trim() || "[]") as T[];
}

export function exec(sql: string, params: Record<string, string> = {}, opts: DbOptions = {}): void {
  const r = run(preamble(opts) + sql, params, opts);
  if (r.status !== 0) throw new Error(`psql: ${r.stderr.trim()}`);
}

/** 測試輔助：回傳原始 -qtA 輸出（trim）。失敗擲回含 stderr 的錯誤。 */
export function raw(sql: string, opts: DbOptions = {}): string {
  const r = run(preamble(opts) + sql, {}, { asRuntime: false, ...opts });
  if (r.status !== 0) throw new Error(`psql: ${r.stderr.trim()}`);
  return r.stdout.trim();
}
