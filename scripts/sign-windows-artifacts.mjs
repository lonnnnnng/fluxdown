#!/usr/bin/env node
// 作者: long
// Windows 产物签名入口（CI 专用）：读取 WINDOWS_PFX_BASE64 / WINDOWS_PFX_PASSWORD，
// 对传入的文件或 glob 列表逐个用 signtool 签名（SHA-256 + RFC3161 时间戳）。
// secrets 未配置时打印跳过原因并正常退出——签名缺失不能阻断打包，只降低分发体验。
// 首次启用签名前需要在仓库 Settings → Secrets 添加：
//   WINDOWS_PFX_BASE64    代码签名证书 .pfx 的 base64（certutil -encode cert.pfx cert.b64 的内容体）
//   WINDOWS_PFX_PASSWORD  该 .pfx 的导出密码

import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const pfxBase64 = process.env.WINDOWS_PFX_BASE64 ?? "";
const pfxPassword = process.env.WINDOWS_PFX_PASSWORD ?? "";
const targets = process.argv.slice(2);

if (process.platform !== "win32") {
  console.error("sign-windows-artifacts: only runs on Windows runners.");
  process.exit(1);
}

if (!pfxBase64) {
  console.log(
    "sign-windows-artifacts: WINDOWS_PFX_BASE64 is not set; skipping code signing."
  );
  process.exit(0);
}

if (targets.length === 0) {
  console.error("sign-windows-artifacts: no target files given.");
  process.exit(1);
}

function expandGlob(pattern) {
  // 作者: long
  // 只支持 "**/*.exe|msi" 这类简单模式：按最后一段通配展开目录匹配，
  // 避免 CI 里额外引入 glob 依赖。
  const absolute = resolve(root, pattern);
  if (!pattern.includes("*")) {
    return existsSync(absolute) ? [absolute] : [];
  }
  const directory = dirname(absolute);
  const suffix = absolute.slice(directory.length + 1);
  const regex = new RegExp(
    `^${suffix.replace(/[.]/g, "\\.").replace(/\*/g, ".*")}$`,
    "i",
  );
  if (!existsSync(directory)) return [];
  return readdirSync(directory)
    .filter((name) => regex.test(name))
    .map((name) => join(directory, name));
}

const files = [...new Set(targets.flatMap(expandGlob))];
if (files.length === 0) {
  console.error(
    `sign-windows-artifacts: no files matched: ${targets.join(", ")}`
  );
  process.exit(1);
}

const kitsRoot = "C:/Program Files (x86)/Windows Kits/10/bin";
if (!existsSync(kitsRoot)) {
  console.error("sign-windows-artifacts: Windows Kits signtool not found.");
  process.exit(1);
}
const signtool = readdirSync(kitsRoot)
  .filter((name) => /^\d+\.\d+\.\d+\.\d+$/.test(name))
  .sort()
  .map((version) => join(kitsRoot, version, "x64", "signtool.exe"))
  .filter((path) => existsSync(path))
  .pop();
if (!signtool) {
  console.error("sign-windows-artifacts: signtool.exe not found in Windows Kits.");
  process.exit(1);
}

const pfxPath = join(process.env.RUNNER_TEMP ?? root, "fluxdown-signing.pfx");
writeFileSync(pfxPath, Buffer.from(pfxBase64, "base64"));

const timestampUrl =
  process.env.WINDOWS_TIMESTAMP_URL ?? "http://timestamp.digicert.com";

let failures = 0;
try {
  for (const file of files) {
    console.log(`signing ${file}`);
    try {
      execFileSync(
        signtool,
        [
          "sign",
          "/f",
          pfxPath,
          "/p",
          pfxPassword,
          "/fd",
          "sha256",
          "/tr",
          timestampUrl,
          "/td",
          "sha256",
          file,
        ],
        { stdio: "inherit" }
      );
    } catch (error) {
      failures += 1;
      console.error(`sign failed for ${file}: ${error.message}`);
    }
  }
} finally {
  rmSync(pfxPath, { force: true });
}

if (failures > 0) {
  console.error(`sign-windows-artifacts: ${failures} file(s) failed to sign.`);
  process.exit(1);
}
console.log(`sign-windows-artifacts: signed ${files.length} file(s).`);
