import { useEffect, useMemo, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import "./App.css";

type Protocol =
  | "http"
  | "https"
  | "webdav"
  | "webdavs"
  | "ftp"
  | "ftps"
  | "torrent"
  | "magnet"
  | "ed2k"
  | "m3u8"
  | "sftp"
  | "smb"
  | "ipfs"
  | "unknown";

type Backend =
  | "built-in"
  | "system-handoff"
  | "aria2"
  | "amule"
  | "smb-client"
  | "ipfs"
  | "planned";

type SupportStatus = {
  protocol: Protocol;
  backend: Backend;
  configured?: boolean;
  executable: boolean;
  missing_command?: string | null;
  note?: string;
};

type BackendAvailability = {
  backend: Backend;
  command?: string | null;
  available: boolean;
  note: string;
};

type DoctorReport = {
  backends: BackendAvailability[];
  protocols: SupportStatus[];
};

type DownloadTask = {
  id: string;
  source: string;
  protocol: Protocol;
  support: SupportStatus;
  state: string;
  output_dir: string;
  file_name?: string | null;
  total_bytes?: number | null;
  downloaded_bytes: number;
  error?: string | null;
  created_at_ms?: number;
  updated_at_ms?: number;
};

type DownloadSummary = {
  protocol: Protocol;
  backend: Backend;
  output_path: string;
  bytes_written: number;
  resumed_from: number;
  total_bytes?: number | null;
  segments_written?: number | null;
};

type QueueRunReport = {
  total_queued: number;
  started: number;
  finished: number;
  failed: number;
  tasks: DownloadTask[];
};

type TaskRunReport = {
  task: DownloadTask;
  summary?: DownloadSummary | null;
};

type Language = "zh" | "en";

type TranslationKey =
  | "tagline"
  | "navQueue"
  | "navProtocols"
  | "navSettings"
  | "recognized"
  | "title"
  | "subtitle"
  | "ready"
  | "adapterPlanned"
  | "source"
  | "sourcePlaceholder"
  | "outputFolder"
  | "fileName"
  | "optional"
  | "detected"
  | "addToQueue"
  | "queue"
  | "queueRunner"
  | "queueRunnerHelp"
  | "concurrency"
  | "runQueue"
  | "runtimeBackends"
  | "checkedOnThisMachine"
  | "webPreviewFallback"
  | "compiledIntoCore"
  | "available"
  | "notAvailable"
  | "tasks"
  | "noQueuedTasks"
  | "start"
  | "pause"
  | "resume"
  | "remove"
  | "bytes"
  | "language"
  | "chinese"
  | "english";

const translations: Record<Language, Record<TranslationKey, string>> = {
  zh: {
    tagline: "多协议下载器",
    navQueue: "队列",
    navProtocols: "协议",
    navSettings: "设置",
    recognized: "已识别协议",
    title: "下载队列",
    subtitle:
      "适用于 Windows、macOS 和 Linux 的桌面 GUI，由共享 Rust 引擎驱动。",
    ready: "就绪",
    adapterPlanned: "适配器规划中",
    source: "下载源",
    sourcePlaceholder: "URL、WebDAV、磁力链接、ed2k、torrent 路径、m3u8",
    outputFolder: "输出目录",
    fileName: "文件名",
    optional: "可选",
    detected: "识别结果",
    addToQueue: "添加到队列",
    queue: "入队",
    queueRunner: "队列运行器",
    queueRunnerHelp: "处理已排队任务，并把最终状态写回持久化队列。",
    concurrency: "并发数",
    runQueue: "运行队列",
    runtimeBackends: "运行时后端",
    checkedOnThisMachine: "已在本机检查",
    webPreviewFallback: "网页预览兜底",
    compiledIntoCore: "已编译进 FluxDown core",
    available: "可用",
    notAvailable: "不可用",
    tasks: "任务",
    noQueuedTasks: "还没有排队任务。",
    start: "开始",
    pause: "暂停",
    resume: "继续",
    remove: "删除",
    bytes: "字节",
    language: "语言",
    chinese: "中文",
    english: "English",
  },
  en: {
    tagline: "multi-protocol downloader",
    navQueue: "Queue",
    navProtocols: "Protocols",
    navSettings: "Settings",
    recognized: "Recognized",
    title: "Download queue",
    subtitle:
      "Desktop GUI for Windows, macOS, and Linux backed by the shared Rust engine.",
    ready: "Ready",
    adapterPlanned: "Adapter planned",
    source: "Source",
    sourcePlaceholder: "URL, WebDAV, magnet, ed2k, torrent path, m3u8",
    outputFolder: "Output folder",
    fileName: "File name",
    optional: "optional",
    detected: "Detected",
    addToQueue: "Add to queue",
    queue: "Queue",
    queueRunner: "Queue runner",
    queueRunnerHelp:
      "Processes queued tasks and writes final state back to the persistent store.",
    concurrency: "Concurrency",
    runQueue: "Run queue",
    runtimeBackends: "Runtime backends",
    checkedOnThisMachine: "checked on this machine",
    webPreviewFallback: "web preview fallback",
    compiledIntoCore: "compiled into FluxDown core",
    available: "available",
    notAvailable: "not available",
    tasks: "Tasks",
    noQueuedTasks: "No queued tasks yet.",
    start: "Start",
    pause: "Pause",
    resume: "Resume",
    remove: "Remove",
    bytes: "bytes",
    language: "Language",
    chinese: "中文",
    english: "English",
  },
};

const supportedNow = new Set<Protocol>([
  "http",
  "https",
  "webdav",
  "webdavs",
  "ftp",
  "ftps",
  "torrent",
  "magnet",
  "ed2k",
  "m3u8",
  "sftp",
  "smb",
  "ipfs",
]);

const examples = [
  "https://speed.hetzner.de/100MB.bin",
  "webdavs://cloud.example.com/remote.php/dav/files/archive.zip",
  "https://example.com/live/playlist.m3u8",
  "magnet:?xt=urn:btih:0123456789abcdef",
  "ed2k://|file|example.iso|123|ABCDEF|/",
  "ftp://ftp.example.com/pub/file.zip",
  "sftp://user:pass@example.com/home/user/archive.zip",
  "smb://user:pass@nas.local/Share/archive.zip",
];

function fallbackDetect(source: string): Protocol {
  const value = source.trim().toLowerCase();
  if (value.startsWith("magnet:?")) return "magnet";
  if (value.startsWith("ed2k://")) return "ed2k";
  if (hasPathExtension(value, ".torrent")) return "torrent";
  if (hasPathExtension(value, ".m3u8")) return "m3u8";
  if (value.startsWith("https://")) return "https";
  if (value.startsWith("http://")) return "http";
  if (value.startsWith("webdavs://")) return "webdavs";
  if (value.startsWith("webdav://")) return "webdav";
  if (value.startsWith("ftps://")) return "ftps";
  if (value.startsWith("ftp://")) return "ftp";
  if (value.startsWith("sftp://")) return "sftp";
  if (value.startsWith("smb://")) return "smb";
  if (value.startsWith("ipfs://")) return "ipfs";
  return "unknown";
}

function hasPathExtension(source: string, extension: string) {
  if (source.endsWith(extension)) return true;

  try {
    return new URL(source).pathname.toLowerCase().endsWith(extension);
  } catch {
    return false;
  }
}

function fallbackSupport(source: string): SupportStatus {
  const detected = fallbackDetect(source);
  if (detected === "ed2k") {
    return { protocol: detected, backend: "system-handoff", executable: true };
  }

  if (supportedNow.has(detected)) {
    return { protocol: detected, backend: "built-in", executable: true };
  }

  return { protocol: detected, backend: "planned", executable: false };
}

function progressPercent(task: DownloadTask) {
  if (!task.total_bytes || task.total_bytes <= 0) return 0;
  return Math.min(
    100,
    Math.round((task.downloaded_bytes / task.total_bytes) * 100),
  );
}

function initialLanguage(): Language {
  try {
    return window.localStorage.getItem("fluxdown-language") === "en"
      ? "en"
      : "zh";
  } catch {
    return "zh";
  }
}

function protocolLabel(protocol: Protocol) {
  if (protocol === "unknown") return "Unknown";
  return protocol.toUpperCase();
}

function backendLabel(backend: Backend, language: Language) {
  const labels: Record<Backend, Record<Language, string>> = {
    "built-in": { zh: "内建", en: "built-in" },
    "system-handoff": { zh: "系统移交", en: "system handoff" },
    aria2: { zh: "aria2", en: "aria2" },
    amule: { zh: "aMule", en: "aMule" },
    "smb-client": { zh: "SMB 客户端", en: "SMB client" },
    ipfs: { zh: "IPFS", en: "IPFS" },
    planned: { zh: "规划中", en: "planned" },
  };
  return labels[backend][language];
}

function stateLabel(state: string, language: Language) {
  const labels: Record<string, Record<Language, string>> = {
    queued: { zh: "排队中", en: "queued" },
    running: { zh: "运行中", en: "running" },
    finished: { zh: "已完成", en: "finished" },
    failed: { zh: "失败", en: "failed" },
    paused: { zh: "已暂停", en: "paused" },
  };
  return labels[state]?.[language] ?? state;
}

function backendAvailabilityLabel(
  backend: BackendAvailability,
  language: Language,
  t: Record<TranslationKey, string>,
) {
  if (backend.available) return t.available;
  if (backend.command) {
    return language === "zh"
      ? `缺少 ${backend.command}`
      : `missing ${backend.command}`;
  }
  return t.notAvailable;
}

function App() {
  const [language, setLanguage] = useState<Language>(initialLanguage);
  const [source, setSource] = useState(examples[0]);
  const [outputDir, setOutputDir] = useState("./downloads");
  const [fileName, setFileName] = useState("");
  const [tasks, setTasks] = useState<DownloadTask[]>([]);
  const [message, setMessage] = useState("");
  const [runtimeSupport, setRuntimeSupport] = useState<SupportStatus | null>(
    null,
  );
  const [doctorReport, setDoctorReport] = useState<DoctorReport | null>(null);
  const [concurrency, setConcurrency] = useState(2);
  const [activeRuns, setActiveRuns] = useState(0);
  const t = translations[language];

  const fallbackStatus = useMemo(() => fallbackSupport(source), [source]);
  const supportStatus = runtimeSupport ?? fallbackStatus;
  const protocol = supportStatus.protocol;
  const canStart = supportStatus.executable;
  const visibleMessage = message || t.ready;

  useEffect(() => {
    try {
      window.localStorage.setItem("fluxdown-language", language);
    } catch {
      // Ignore storage failures in restricted preview environments.
    }
  }, [language]);

  useEffect(() => {
    let cancelled = false;
    invoke<SupportStatus>("support", { source })
      .then((status) => {
        if (!cancelled) setRuntimeSupport(status);
      })
      .catch(() => {
        if (!cancelled) setRuntimeSupport(null);
      });
    return () => {
      cancelled = true;
    };
  }, [source]);

  useEffect(() => {
    invoke<DoctorReport>("doctor")
      .then(setDoctorReport)
      .catch(() => setDoctorReport(null));
  }, []);

  useEffect(() => {
    invoke<DownloadTask[]>("list_downloads")
      .then(setTasks)
      .catch(() => undefined);
  }, []);

  useEffect(() => {
    const hasRunningTasks = tasks.some((task) => task.state === "running");
    if (activeRuns <= 0 && !hasRunningTasks) return;

    const timer = window.setInterval(() => {
      invoke<DownloadTask[]>("list_downloads")
        .then(setTasks)
        .catch(() => undefined);
    }, 600);

    return () => window.clearInterval(timer);
  }, [activeRuns, tasks]);

  async function addTask() {
    const fallbackTask: DownloadTask = {
      id: `preview-${Date.now()}`,
      source,
      protocol,
      state: "queued",
      output_dir: outputDir,
      file_name: fileName || null,
      support: fallbackSupport(source),
      total_bytes: null,
      downloaded_bytes: 0,
    };

    const task = await invoke<DownloadTask>("enqueue_download", {
      payload: {
        source,
        output_dir: outputDir,
        file_name: fileName || null,
      },
    }).catch(() => fallbackTask);

    setTasks((current) => [task, ...current]);
    setMessage(
      language === "zh"
        ? `${protocolLabel(task.protocol)} 任务已加入队列`
        : `${protocolLabel(task.protocol)} task queued`,
    );
  }

  async function startDownload(id: string) {
    setMessage(language === "zh" ? `正在启动 ${id}...` : `Starting ${id}...`);
    setActiveRuns((count) => count + 1);
    setTasks((current) =>
      current.map((item) =>
        item.id === id ? { ...item, state: "running" } : item,
      ),
    );
    try {
      const report = await invoke<TaskRunReport>("start_download", {
        id,
      });
      setTasks((current) =>
        current.map((item) => (item.id === id ? report.task : item)),
      );
      if (report.summary) {
        setMessage(
          language === "zh"
            ? `已保存 ${report.summary.bytes_written.toLocaleString()} 字节到 ${report.summary.output_path}${
                report.summary.resumed_from > 0
                  ? `，从 ${report.summary.resumed_from.toLocaleString()} 字节继续`
                  : ""
              }`
            : `Saved ${report.summary.bytes_written.toLocaleString()} bytes to ${report.summary.output_path}${
                report.summary.resumed_from > 0
                  ? `, resumed from ${report.summary.resumed_from.toLocaleString()}`
                  : ""
              }`,
        );
      } else if (report.task.state === "paused") {
        setMessage(language === "zh" ? `${id} 已暂停` : `${id} paused`);
      } else if (report.task.state === "failed") {
        setMessage(report.task.error || `${id} failed`);
      } else {
        setMessage(
          language === "zh"
            ? `${id} 结束，状态：${stateLabel(report.task.state, language)}`
            : `${id} finished with state ${report.task.state}`,
        );
      }
    } catch (error) {
      setMessage(String(error));
      setTasks(
        await invoke<DownloadTask[]>("list_downloads").catch(() => tasks),
      );
    } finally {
      setActiveRuns((count) => Math.max(0, count - 1));
    }
  }

  async function pauseDownload(id: string) {
    const task = await invoke<DownloadTask>("pause_download", { id });
    setTasks((current) =>
      current.map((item) => (item.id === id ? task : item)),
    );
    setMessage(language === "zh" ? `${id} 已暂停` : `${id} paused`);
  }

  async function resumeDownload(id: string) {
    const task = await invoke<DownloadTask>("resume_download", { id });
    setTasks((current) =>
      current.map((item) => (item.id === id ? task : item)),
    );
    setMessage(language === "zh" ? `${id} 已重新排队` : `${id} queued`);
  }

  async function removeDownload(id: string) {
    await invoke<DownloadTask>("remove_download", { id });
    setTasks((current) => current.filter((item) => item.id !== id));
    setMessage(language === "zh" ? `${id} 已删除` : `${id} removed`);
  }

  async function runQueue() {
    setMessage(
      language === "zh"
        ? `正在以 ${concurrency} 并发运行队列...`
        : `Running queued tasks with concurrency ${concurrency}...`,
    );
    setActiveRuns((count) => count + 1);
    try {
      const report = await invoke<QueueRunReport>("run_queue", { concurrency });
      setMessage(
        language === "zh"
          ? `运行完成：${report.finished} 个完成，${report.failed} 个失败`
          : `Run complete: ${report.finished} finished, ${report.failed} failed`,
      );
      setTasks(
        await invoke<DownloadTask[]>("list_downloads").catch(() => tasks),
      );
    } catch (error) {
      setMessage(String(error));
      setTasks(
        await invoke<DownloadTask[]>("list_downloads").catch(() => tasks),
      );
    } finally {
      setActiveRuns((count) => Math.max(0, count - 1));
    }
  }

  return (
    <main className="shell">
      <aside className="sidebar">
        <div className="brand">
          <div className="mark">F</div>
          <div>
            <strong>FluxDown</strong>
            <span>{t.tagline}</span>
          </div>
        </div>
        <nav>
          <button className="navItem active">{t.navQueue}</button>
          <button className="navItem">{t.navProtocols}</button>
          <button className="navItem">{t.navSettings}</button>
        </nav>
        <section className="protocolPanel">
          <h2>{t.recognized}</h2>
          <div className="protocolGrid">
            {[
              "HTTP",
              "FTP",
              "WebDAV",
              "Torrent",
              "Magnet",
              "ed2k",
              "m3u8",
              "SFTP",
              "SMB",
              "IPFS",
            ].map((item) => (
              <span key={item}>{item}</span>
            ))}
          </div>
        </section>
      </aside>

      <section className="workspace">
        <header className="topbar">
          <div>
            <h1>{t.title}</h1>
            <p>{t.subtitle}</p>
          </div>
          <div className="topbarControls">
            <label className="languageSelect">
              <span>{t.language}</span>
              <select
                value={language}
                onChange={(event) =>
                  setLanguage(event.target.value as Language)
                }
              >
                <option value="zh">{t.chinese}</option>
                <option value="en">{t.english}</option>
              </select>
            </label>
            <div className={`status ${canStart ? "ready" : "planned"}`}>
              {canStart
                ? t.ready
                : supportStatus.missing_command
                  ? language === "zh"
                    ? `缺少 ${supportStatus.missing_command}`
                    : `Missing ${supportStatus.missing_command}`
                  : t.adapterPlanned}
            </div>
          </div>
        </header>

        <section className="composer">
          <label>
            {t.source}
            <input
              value={source}
              onChange={(event) => setSource(event.target.value)}
              placeholder={t.sourcePlaceholder}
            />
          </label>
          <div className="row">
            <label>
              {t.outputFolder}
              <input
                value={outputDir}
                onChange={(event) => setOutputDir(event.target.value)}
              />
            </label>
            <label>
              {t.fileName}
              <input
                value={fileName}
                onChange={(event) => setFileName(event.target.value)}
                placeholder={t.optional}
              />
            </label>
          </div>
          <div className="actions">
            <div className="detected">
              <span>{t.detected}</span>
              <strong>{protocolLabel(protocol)}</strong>
              <em>{backendLabel(supportStatus.backend, language)}</em>
            </div>
            <button onClick={addTask}>{t.addToQueue}</button>
            <button className="primary" onClick={addTask}>
              {t.queue}
            </button>
          </div>
        </section>

        <section className="examples">
          {examples.map((example) => (
            <button key={example} onClick={() => setSource(example)}>
              {fallbackDetect(example)}
            </button>
          ))}
        </section>

        <section className="runner">
          <div>
            <h2>{t.queueRunner}</h2>
            <span>{t.queueRunnerHelp}</span>
          </div>
          <label>
            {t.concurrency}
            <input
              min={1}
              max={8}
              type="number"
              value={concurrency}
              onChange={(event) =>
                setConcurrency(Math.max(1, Number(event.target.value) || 1))
              }
            />
          </label>
          <button className="primary" onClick={runQueue}>
            {t.runQueue}
          </button>
        </section>

        <section className="doctor">
          <div className="queueHeader">
            <h2>{t.runtimeBackends}</h2>
            <span>
              {doctorReport ? t.checkedOnThisMachine : t.webPreviewFallback}
            </span>
          </div>
          <div className="backendGrid">
            {(
              doctorReport?.backends ?? [
                {
                  backend: "built-in",
                  available: true,
                  note: t.compiledIntoCore,
                },
              ]
            ).map((backend) => (
              <div className="backend" key={backend.backend}>
                <strong>{backendLabel(backend.backend, language)}</strong>
                <span>{backendAvailabilityLabel(backend, language, t)}</span>
              </div>
            ))}
          </div>
        </section>

        <section className="queue">
          <div className="queueHeader">
            <h2>{t.tasks}</h2>
            <span>{visibleMessage}</span>
          </div>
          {tasks.length === 0 ? (
            <div className="empty">{t.noQueuedTasks}</div>
          ) : (
            tasks.map((task) => (
              <article className="task" key={task.id}>
                <div>
                  <strong>{task.source}</strong>
                  <span>{task.output_dir}</span>
                  <span>
                    {task.downloaded_bytes.toLocaleString()}
                    {task.total_bytes
                      ? ` / ${task.total_bytes.toLocaleString()}`
                      : ""}{" "}
                    {t.bytes}
                  </span>
                  <div
                    className="progressTrack"
                    aria-label={
                      language === "zh"
                        ? `进度 ${progressPercent(task)}%`
                        : `Progress ${progressPercent(task)} percent`
                    }
                  >
                    <div style={{ width: `${progressPercent(task)}%` }} />
                  </div>
                  {task.error ? (
                    <span className="errorText">{task.error}</span>
                  ) : null}
                </div>
                <div className="taskMeta">
                  <span>{protocolLabel(task.protocol)}</span>
                  <span>{backendLabel(task.support.backend, language)}</span>
                  <span>{stateLabel(task.state, language)}</span>
                  <div className="taskButtons">
                    <button
                      disabled={!task.support.executable}
                      onClick={() => startDownload(task.id)}
                    >
                      {t.start}
                    </button>
                    <button onClick={() => pauseDownload(task.id)}>
                      {t.pause}
                    </button>
                    <button onClick={() => resumeDownload(task.id)}>
                      {t.resume}
                    </button>
                    <button onClick={() => removeDownload(task.id)}>
                      {t.remove}
                    </button>
                  </div>
                </div>
              </article>
            ))
          )}
        </section>
      </section>
    </main>
  );
}

export default App;
