#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

const rootDir = new URL("..", import.meta.url).pathname;
const mobileDir = join(rootDir, "apps", "mobile");

function run(command, args, options = {}) {
  return execFileSync(command, args, {
    cwd: options.cwd ?? rootDir,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function runOptional(command, args, options = {}) {
  try {
    return { ok: true, stdout: run(command, args, options), stderr: "" };
  } catch (error) {
    return {
      ok: false,
      stdout: error.stdout?.toString() ?? "",
      stderr: error.stderr?.toString() ?? error.message,
    };
  }
}

function parseXctraceDevices(text) {
  const devices = [];
  let section = "";
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.startsWith("== ") && line.endsWith(" ==")) {
      section = line.slice(3, -3);
      continue;
    }
    if (!line || section === "Simulators") {
      continue;
    }
    const match = line.match(/^(.*?)(?: \(([^()]+)\))? \(([^()]+)\)$/);
    if (!match) {
      continue;
    }
    devices.push({
      name: match[1],
      version: match[2] ?? "",
      id: match[3],
      section,
    });
  }
  return devices;
}

if (!existsSync(mobileDir)) {
  console.error(`Missing mobile app directory: ${mobileDir}`);
  process.exit(2);
}

console.log("iOS physical device readiness");
console.log(`  root: ${rootDir}`);

const flutterResult = runOptional("flutter", ["devices", "--machine"], {
  cwd: mobileDir,
});
if (!flutterResult.ok) {
  console.error("flutter devices --machine failed:");
  console.error(flutterResult.stderr.trim());
  process.exit(2);
}

const flutterDevices = JSON.parse(flutterResult.stdout);
const physicalIos = flutterDevices.filter(
  (device) => device.targetPlatform === "ios" && !device.emulator,
);
const simulators = flutterDevices.filter(
  (device) => device.targetPlatform === "ios" && device.emulator,
);

if (physicalIos.length > 0) {
  console.log("  status: ready");
  for (const device of physicalIos) {
    console.log(`  iPhone: ${device.name} (${device.id})`);
  }
  process.exit(0);
}

const xctraceResult = runOptional("xcrun", ["xctrace", "list", "devices"]);
const xctraceDevices = xctraceResult.ok
  ? parseXctraceDevices(xctraceResult.stdout)
  : [];
const offlineDevices = xctraceDevices.filter(
  (device) => device.section === "Devices Offline",
);
const visibleDevices = xctraceDevices.filter(
  (device) => device.section === "Devices" && device.version,
);

if (visibleDevices.length > 0) {
  console.log("  xcode-visible:");
  for (const device of visibleDevices) {
    console.log(`    ${device.name} (${device.id})`);
  }
}
if (offlineDevices.length > 0) {
  console.log("  xcode-offline:");
  for (const device of offlineDevices) {
    console.log(
      `    ${device.name}${device.version ? ` ${device.version}` : ""} (${device.id})`,
    );
  }
}
if (simulators.length > 0) {
  console.log("  simulator-ready:");
  for (const device of simulators) {
    console.log(`    ${device.name} (${device.id})`);
  }
}

console.log("");
console.log("  status: physical iPhone is not ready for Flutter deployment");
console.log("  next:");
console.log("    1. 解锁 iPhone，并在弹窗中信任这台 Mac。");
console.log("    2. 确认 iPhone 已开启 Developer Mode。");
console.log("    3. 优先使用 USB 线连接；如果走无线，确保手机和 Mac 在同一局域网。");
console.log("    4. 重新运行 npm run verify:ios:device-readiness。");

process.exit(offlineDevices.length > 0 ? 78 : 79);
