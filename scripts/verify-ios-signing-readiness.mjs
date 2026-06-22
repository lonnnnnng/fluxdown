#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";

const rootDir = new URL("..", import.meta.url).pathname;
const mobileDir = resolve(rootDir, "apps/mobile");
const profileDirs = [
  join(homedir(), "Library/MobileDevice/Provisioning Profiles"),
  resolve(mobileDir, "ios/signing"),
];
const requiredEnv = [
  "IOS_CERTIFICATE_BASE64",
  "IOS_CERTIFICATE_PASSWORD",
  "IOS_PROVISIONING_PROFILE_BASE64",
  "IOS_KEYCHAIN_PASSWORD",
  "APPLE_TEAM_ID",
];
const bundleId = "dev.fluxdown.mobile";

// 作者: long
// 签名检查只判断自动化构建是否具备输入，不解码证书内容，避免在普通验证日志里暴露敏感材料。
function runOptional(command, args, options = {}) {
  try {
    return {
      ok: true,
      stdout: execFileSync(command, args, {
        cwd: options.cwd ?? rootDir,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      }),
      stderr: "",
    };
  } catch (error) {
    return {
      ok: false,
      stdout: error.stdout?.toString() ?? "",
      stderr: error.stderr?.toString() ?? error.message,
    };
  }
}

function codeSigningIdentities() {
  const result = runOptional("security", ["find-identity", "-v", "-p", "codesigning"]);
  if (!result.ok) {
    return { ok: false, identities: [], error: result.stderr.trim() };
  }
  const identities = [];
  for (const line of result.stdout.split(/\r?\n/)) {
    const match = line.match(/^\s*\d+\)\s+[0-9A-F]+\s+"([^"]+)"/);
    if (match) {
      identities.push(match[1]);
    }
  }
  return { ok: true, identities, error: "" };
}

function provisioningProfiles() {
  const files = [];
  for (const dir of profileDirs) {
    if (!existsSync(dir)) {
      continue;
    }
    for (const entry of readdirSync(dir)) {
      if (entry.endsWith(".mobileprovision")) {
        files.push(resolve(dir, entry));
      }
    }
  }
  return files.map(readProvisioningProfile).filter(Boolean);
}

function readProvisioningProfile(path) {
  const cms = runOptional("security", ["cms", "-D", "-i", path]);
  if (!cms.ok) {
    return null;
  }
  const tempDir = mkdtempSync(join(tmpdir(), "fluxdown-ios-profile-"));
  const plist = join(tempDir, "profile.plist");
  try {
    writeFileSync(plist, cms.stdout);
    const read = (key) => {
      const result = runOptional("/usr/libexec/PlistBuddy", ["-c", `Print ${key}`, plist]);
      return result.ok ? result.stdout.trim() : "";
    };
    const appIdentifier = read("Entitlements:application-identifier");
    return {
      path,
      name: read("Name"),
      uuid: read("UUID"),
      teamIdentifier: read("TeamIdentifier:0"),
      appIdentifier,
      expirationDate: read("ExpirationDate"),
      matchesBundle:
        appIdentifier === `${process.env.APPLE_TEAM_ID ?? ""}.${bundleId}` ||
        appIdentifier.endsWith(`.${bundleId}`),
    };
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

console.log("iOS signing readiness");
console.log(`  root: ${rootDir}`);

const missingEnv = requiredEnv.filter((name) => !process.env[name]);
if (missingEnv.length === 0) {
  console.log("  env: ready for npm run mobile:ios:ipa:signed");
} else {
  console.log("  env-missing:");
  for (const name of missingEnv) {
    console.log(`    ${name}`);
  }
}

const identityResult = codeSigningIdentities();
if (identityResult.ok && identityResult.identities.length > 0) {
  console.log("  codesigning-identities:");
  for (const identity of identityResult.identities) {
    console.log(`    ${identity}`);
  }
} else if (identityResult.ok) {
  console.log("  codesigning-identities: none");
} else {
  console.log(`  codesigning-identities: unreadable (${identityResult.error})`);
}

const profiles = provisioningProfiles();
const matchingProfiles = profiles.filter((profile) => profile.matchesBundle);
if (matchingProfiles.length > 0) {
  console.log(`  matching-profiles for ${bundleId}:`);
  for (const profile of matchingProfiles) {
    console.log(`    ${profile.name || profile.uuid} (${profile.teamIdentifier || "unknown team"})`);
  }
} else {
  console.log(`  matching-profiles for ${bundleId}: none`);
}

if (missingEnv.length === 0) {
  console.log("");
  console.log("  status: signed IPA automation inputs are present");
  process.exit(0);
}

console.log("");
console.log("  status: signed IPA automation is not ready");
console.log("  next:");
console.log("    1. 准备 iOS distribution/development p12 和匹配 dev.fluxdown.mobile 的 provisioning profile。");
console.log("    2. 设置 IOS_CERTIFICATE_BASE64、IOS_CERTIFICATE_PASSWORD、IOS_PROVISIONING_PROFILE_BASE64、IOS_KEYCHAIN_PASSWORD、APPLE_TEAM_ID。");
console.log("    3. 重新运行 npm run verify:ios:signing-readiness。");

process.exit(78);
