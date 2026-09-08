import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, join, resolve } from "node:path";
import { promisify } from "node:util";

const binary = resolve(process.argv[2] ?? `target/release/fluxdown${process.platform === "win32" ? ".exe" : ""}`);
const reportPath = resolve(process.argv[3] ?? "dist/release-cli-smoke/report.json");
const version = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version;
mkdirSync(dirname(reportPath), { recursive: true });
// long: 所有命令显式指定隔离队列与输出目录，回验发行程序时不能触碰用户现有下载。
const workDir = mkdtempSync(join(dirname(reportPath), "cli-smoke-"));
const payload = Buffer.alloc(256 * 1024);
for (let index = 0; index < payload.length; index += 1) payload[index] = index % 251;
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const expectedHash = sha256(payload);
const commands = [];
let rangeRequests = 0;
const server = createServer((request, response) => {
  if (request.url !== "/sample.bin" || !["GET", "HEAD"].includes(request.method)) {
    response.writeHead(404).end();
    return;
  }
  let start = 0;
  let end = payload.length - 1;
  if (request.headers.range) {
    const match = /^bytes=(\d+)-(\d*)$/.exec(request.headers.range);
    start = match ? Number(match[1]) : -1;
    end = match?.[2] ? Math.min(Number(match[2]), end) : end;
    if (start < 0 || start > end) {
      response.writeHead(416, { "Content-Range": `bytes */${payload.length}` }).end();
      return;
    }
    rangeRequests += 1;
    response.setHeader("Content-Range", `bytes ${start}-${end}/${payload.length}`);
  }
  response.writeHead(request.headers.range ? 206 : 200, {
    "Content-Type": "application/octet-stream",
    "Accept-Ranges": "bytes",
    "Content-Length": end - start + 1,
  });
  response.end(request.method === "HEAD" ? undefined : payload.subarray(start, end + 1));
});
const execute = promisify(execFile);
async function cli(args, json = true) {
  // long: 异步等待 CLI，让同一进程内的 HTTP 服务继续响应，不因测试脚本阻塞制造下载超时。
  const { stdout, stderr } = await execute(binary, ["--store", join(workDir, "queue.json"), ...args], {
    timeout: 60_000,
    maxBuffer: 1024 * 1024,
    windowsHide: true,
    env: { ...process.env, NO_PROXY: "127.0.0.1,localhost", no_proxy: "127.0.0.1,localhost" },
  });
  commands.push({ args, stdout, stderr });
  return json ? JSON.parse(stdout) : stdout.trim();
}
const report = { version, platform: process.platform, arch: process.arch, binary, workDir, commands };
try {
  await new Promise((ready, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", ready);
  });
  const source = `http://127.0.0.1:${server.address().port}/sample.bin`;
  assert.equal(await cli(["--version"], false), `fluxdown ${version}`);
  assert.equal(await cli(["detect", source], false), "http");
  const queuedDir = join(workDir, "queued");
  const task = await cli(["add", source, "--output", queuedDir, "--sha256", expectedHash]);
  assert.equal(task.file_name, "sample.bin");
  assert.equal(task.state, "queued");
  assert.equal((await cli(["pause", task.id])).state, "paused");
  assert.equal((await cli(["resume", task.id])).state, "queued");
  const queue = await cli(["run", "--concurrency", "1", "--threads", "4", "--retry-attempts", "1"]);
  assert.equal(queue.started, 1);
  assert.equal(queue.finished, 1);
  assert.equal(queue.failed, 0);
  const tasks = await cli(["list"]);
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].state, "finished");
  assert.equal(tasks[0].downloaded_bytes, payload.length);
  assert.equal(tasks[0].total_bytes, payload.length);
  const directDir = join(workDir, "direct");
  const direct = await cli(["download", source, "--output", directDir, "--threads", "4", "--sha256", expectedHash]);
  assert.equal(direct.bytes_written, payload.length);
  assert.equal(direct.display_name, "sample.bin");
  for (const directory of [queuedDir, directDir]) {
    const downloaded = readFileSync(join(directory, "sample.bin"));
    assert.equal(downloaded.length, payload.length);
    assert.equal(sha256(downloaded), expectedHash);
  }
  assert.ok(rangeRequests >= 2, "Release CLI did not exercise HTTP Range requests");
  Object.assign(report, { status: "passed", bytes: payload.length, sha256: expectedHash, rangeRequests });
  console.log(`Release CLI smoke passed: ${process.platform}/${process.arch}, ${payload.length} bytes, SHA-256 ${expectedHash}`);
} catch (error) {
  Object.assign(report, { status: "failed", error: error.stack ?? String(error), stderr: error.stderr });
  console.error(error);
  process.exitCode = 1;
} finally {
  server.closeAllConnections();
  await new Promise((done) => server.close(done));
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
}
