#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
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
// 签名检查只输出就绪状态和错误原因，不打印证书、profile 或 keychain 密码等敏感材料。
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

function parseCodeSigningIdentities(text) {
  const identities = [];
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\s*\d+\)\s+[0-9A-F]+\s+"([^"]+)"/);
    if (match) {
      identities.push(match[1]);
    }
  }
  return identities;
}

function decodeBase64Env(name) {
  const raw = process.env[name] ?? "";
  const normalized = raw.replace(/\s+/g, "");
  if (!normalized) {
    return { ok: false, error: "empty value", bytes: null };
  }
  if (/[^A-Za-z0-9+/=]/.test(normalized) || normalized.length % 4 === 1) {
    return { ok: false, error: "not standard base64 text", bytes: null };
  }
  const bytes = Buffer.from(normalized, "base64");
  const canonical = normalized.replace(/=+$/, "");
  const encoded = bytes.toString("base64").replace(/=+$/, "");
  if (bytes.length === 0 || encoded !== canonical) {
    return { ok: false, error: "base64 decode check failed", bytes: null };
  }
  return { ok: true, error: "", bytes };
}

function codeSigningIdentities() {
  const result = runOptional("security", ["find-identity", "-v", "-p", "codesigning"]);
  if (!result.ok) {
    return { ok: false, identities: [], error: result.stderr.trim() };
  }
  return { ok: true, identities: parseCodeSigningIdentities(result.stdout), error: "" };
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

function validateEnvProvisioningProfile(tempDir) {
  const decoded = decodeBase64Env("IOS_PROVISIONING_PROFILE_BASE64");
  if (!decoded.ok) {
    return [`IOS_PROVISIONING_PROFILE_BASE64: ${decoded.error}`];
  }

  const profilePath = join(tempDir, "env-profile.mobileprovision");
  writeFileSync(profilePath, decoded.bytes);
  const profile = readProvisioningProfile(profilePath);
  if (!profile) {
    return ["IOS_PROVISIONING_PROFILE_BASE64: unable to decode mobileprovision CMS payload"];
  }

  const errors = [];
  if (!profile.matchesBundle) {
    errors.push(
      `IOS_PROVISIONING_PROFILE_BASE64: application identifier does not match ${bundleId}`,
    );
  }
  if (!profile.teamIdentifier) {
    errors.push("IOS_PROVISIONING_PROFILE_BASE64: missing TeamIdentifier");
  } else if (profile.teamIdentifier !== process.env.APPLE_TEAM_ID) {
    errors.push(
      `IOS_PROVISIONING_PROFILE_BASE64: team ${profile.teamIdentifier} does not match APPLE_TEAM_ID`,
    );
  }
  if (profile.expirationDate) {
    const expiresAt = Date.parse(profile.expirationDate);
    if (!Number.isNaN(expiresAt) && expiresAt <= Date.now()) {
      errors.push("IOS_PROVISIONING_PROFILE_BASE64: provisioning profile is expired");
    }
  }
  return errors;
}

function validateEnvCertificate(tempDir) {
  const decoded = decodeBase64Env("IOS_CERTIFICATE_BASE64");
  if (!decoded.ok) {
    return [`IOS_CERTIFICATE_BASE64: ${decoded.error}`];
  }

  const certPath = join(tempDir, "env-signing.p12");
  const keychainPath = join(tempDir, "readiness.keychain-db");
  writeFileSync(certPath, decoded.bytes);

  const keychainPassword = process.env.IOS_KEYCHAIN_PASSWORD ?? "";
  const certificatePassword = process.env.IOS_CERTIFICATE_PASSWORD ?? "";
  const errors = [];

  // 作者: long
  // 签名预检用临时 keychain 验证 p12 密码和代码签名 identity，避免把错误推迟到耗时的 flutter build ipa 阶段。
  const created = runOptional("security", ["create-keychain", "-p", keychainPassword, keychainPath]);
  if (!created.ok) {
    return [`IOS_CERTIFICATE_BASE64: unable to create temporary keychain (${created.stderr.trim()})`];
  }
  try {
    const unlocked = runOptional("security", [
      "unlock-keychain",
      "-p",
      keychainPassword,
      keychainPath,
    ]);
    if (!unlocked.ok) {
      errors.push("IOS_KEYCHAIN_PASSWORD: unable to unlock temporary keychain");
    }

    const imported = runOptional("security", [
      "import",
      certPath,
      "-P",
      certificatePassword,
      "-A",
      "-t",
      "cert",
      "-f",
      "pkcs12",
      "-k",
      keychainPath,
    ]);
    if (!imported.ok) {
      errors.push("IOS_CERTIFICATE_BASE64: p12 import failed; check certificate password");
    } else {
      const identities = runOptional("security", [
        "find-identity",
        "-v",
        "-p",
        "codesigning",
        keychainPath,
      ]);
      const parsed = identities.ok ? parseCodeSigningIdentities(identities.stdout) : [];
      if (parsed.length === 0) {
        errors.push("IOS_CERTIFICATE_BASE64: no codesigning identity found in p12");
      }
    }
  } finally {
    runOptional("security", ["delete-keychain", keychainPath]);
  }

  return errors;
}

console.log("iOS signing readiness");
console.log(`  root: ${rootDir}`);

const missingEnv = requiredEnv.filter((name) => !process.env[name]);
let envValidationErrors = [];
if (missingEnv.length === 0) {
  const tempDir = mkdtempSync(join(tmpdir(), "fluxdown-ios-signing-readiness-"));
  try {
    envValidationErrors = [
      ...validateEnvProvisioningProfile(tempDir),
      ...validateEnvCertificate(tempDir),
    ];
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }

  if (envValidationErrors.length === 0) {
    console.log("  env: ready for npm run mobile:ios:ipa:signed");
  } else {
    console.log("  env-invalid:");
    for (const error of envValidationErrors) {
      console.log(`    ${error}`);
    }
  }
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

if (missingEnv.length === 0 && envValidationErrors.length === 0) {
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
