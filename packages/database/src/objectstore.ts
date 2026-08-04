// ObjectStore：ADR-03 的抽象邊界。沙箱以檔案系統實作；真機換 S3/MinIO，介面不變。
// 物件不可覆寫（put 相同 key 直接拒絕）——對應「原始檔不可覆寫」（REQ-ING-002）。
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { dirname, join, isAbsolute } from "node:path";
import { config, REPO_ROOT } from "../../config/src/index.ts";

const ROOT = isAbsolute(config.objectStoreDir)
  ? config.objectStoreDir
  : join(REPO_ROOT, config.objectStoreDir);

export function putObject(key: string, data: Buffer): void {
  const p = join(ROOT, key);
  if (existsSync(p)) throw new Error(`物件已存在，不可覆寫：${key}`);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, data, { flag: "wx" });
}
export function getObject(key: string): Buffer { return readFileSync(join(ROOT, key)); }
