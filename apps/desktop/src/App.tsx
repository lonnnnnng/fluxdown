import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties, ReactNode } from "react";
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

type DownloadState = "queued" | "running" | "finished" | "failed" | "paused";
type QueueFilter =
  | "all"
  | "running"
  | "queued"
  | "paused"
  | "finished"
  | "failed"
  | "history";
type Page = "queue" | "settings";
type TaskAction = "idle" | "start" | "pause" | "remove" | "copy" | "open";
type SettingsSection =
  | "general"
  | "download"
  | "protocol"
  | "storage"
  | "security"
  | "diagnostics";
type IconName =
  | "alert"
  | "arrow-left"
  | "check"
  | "clock"
  | "copy"
  | "download"
  | "folder"
  | "link"
  | "more"
  | "pause"
  | "play"
  | "refresh"
  | "search"
  | "settings"
  | "trash";

type DownloadTask = {
  id: string;
  source: string;
  protocol: Protocol;
  support: SupportStatus;
  state: DownloadState;
  output_dir: string;
  file_name?: string | null;
  expected_sha256?: string | null;
  torrent_file_indices?: number[];
  total_bytes?: number | null;
  downloaded_bytes: number;
  current_speed_bytes_per_second?: number;
  error?: string | null;
  created_at_ms?: number;
  updated_at_ms?: number;
  started_at_ms?: number | null;
  finished_at_ms?: number | null;
};

type DownloadSummary = {
  protocol: Protocol;
  backend: Backend;
  output_path: string;
  display_name?: string | null;
  bytes_written: number;
  resumed_from: number;
  total_bytes?: number | null;
  segments_written?: number | null;
  sha256?: string | null;
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

type Settings = {
  outputDir: string;
  concurrency: number;
  threadCount: number;
  retryAttempts: number;
  speedLimitMbps: number;
  autoStart: boolean;
  refreshIntervalMs: number;
};

const settingsKey = "fluxdown.desktop.settings.v2";
const defaultSettings: Settings = {
  outputDir: "",
  concurrency: 1,
  threadCount: 8,
  retryAttempts: 1,
  speedLimitMbps: 0,
  autoStart: true,
  refreshIntervalMs: 600,
};

const queueFilters: QueueFilter[] = [
  "all",
  "running",
  "queued",
  "paused",
  "finished",
  "failed",
  "history",
];

const filterIcons: Record<QueueFilter, IconName> = {
  all: "download",
  running: "play",
  queued: "clock",
  paused: "pause",
  finished: "check",
  failed: "alert",
  history: "folder",
};

const stateIcons: Record<DownloadState, IconName> = {
  queued: "clock",
  running: "download",
  finished: "check",
  failed: "alert",
  paused: "pause",
};

const settingsSections: Array<{
  id: SettingsSection;
  icon: IconName;
  subtitle: string;
  title: string;
}> = [
  { id: "general", icon: "settings", title: "基础设置", subtitle: "保存位置和界面行为" },
  { id: "download", icon: "download", title: "下载策略", subtitle: "并发、线程和限速" },
  { id: "protocol", icon: "link", title: "协议能力", subtitle: "HTTP、M3U8、BT、SFTP" },
  { id: "storage", icon: "folder", title: "存储与完成", subtitle: "命名、校验和完成动作" },
  { id: "security", icon: "alert", title: "安全与隐私", subtitle: "脱敏、校验和外部命令" },
  { id: "diagnostics", icon: "check", title: "高级诊断", subtitle: "自检、报告和后端状态" },
];

const iconPaths: Record<IconName, string[]> = {
  alert: [
    "M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z",
    "M12 9v4",
    "M12 17h.01",
  ],
  "arrow-left": ["M19 12H5", "M12 19l-7-7 7-7"],
  check: ["M20 6 9 17l-5-5"],
  clock: ["M12 8v5l3 2", "M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0"],
  copy: ["M8 8h10v12H8z", "M6 16H4V4h12v2"],
  download: ["M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4", "M7 10l5 5 5-5", "M12 15V3"],
  folder: ["M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"],
  link: [
    "M10 13a5 5 0 0 0 7.1 0l2-2a5 5 0 0 0-7.1-7.1l-1.1 1.1",
    "M14 11a5 5 0 0 0-7.1 0l-2 2A5 5 0 0 0 12 20.1l1.1-1.1",
  ],
  more: ["M12 6h.01", "M12 12h.01", "M12 18h.01"],
  pause: ["M8 5v14", "M16 5v14"],
  play: ["M8 5v14l11-7Z"],
  refresh: ["M21 12a9 9 0 0 1-15.3 6.4L3 16", "M3 21v-5h5", "M3 12A9 9 0 0 1 18.3 5.6L21 8", "M21 3v5h-5"],
  search: ["M21 21l-4.3-4.3", "M11 18a7 7 0 1 1 0-14 7 7 0 0 1 0 14Z"],
  settings: [
    "M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Z",
    "M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1-1.5 1.7 1.7 0 0 0-1.9.3l-.1.1A2 2 0 1 1 4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1 1.7 1.7 0 0 0-.3-1.9L4.2 7A2 2 0 1 1 7 4.2l.1.1a1.7 1.7 0 0 0 1.9.3h.1a1.7 1.7 0 0 0 .9-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.9-.3l.1-.1A2 2 0 1 1 19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9v.1a1.7 1.7 0 0 0 1.5.9h.1a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1Z",
  ],
  trash: ["M3 6h18", "M8 6V4h8v2", "M19 6l-1 14H6L5 6", "M10 11v5", "M14 11v5"],
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
  const protocol = fallbackDetect(source);
  if (protocol === "ed2k") {
    return { protocol, backend: "system-handoff", executable: true };
  }
  if (supportedNow.has(protocol)) {
    return { protocol, backend: "built-in", executable: true };
  }
  return { protocol, backend: "planned", executable: false };
}

function loadSettings(): Settings {
  try {
    const raw = window.localStorage.getItem(settingsKey);
    if (!raw) return defaultSettings;
    const saved = JSON.parse(raw) as Partial<Settings>;
    return {
      outputDir:
        typeof saved.outputDir === "string" && saved.outputDir.trim()
          ? saved.outputDir
          : defaultSettings.outputDir,
      concurrency: clampNumber(saved.concurrency, 1, 30, 1),
      threadCount: clampNumber(saved.threadCount, 1, 32, defaultSettings.threadCount),
      retryAttempts: clampNumber(saved.retryAttempts, 0, 10, defaultSettings.retryAttempts),
      speedLimitMbps: clampNumber(saved.speedLimitMbps, 0, 10000, defaultSettings.speedLimitMbps),
      autoStart:
        typeof saved.autoStart === "boolean"
          ? saved.autoStart
          : defaultSettings.autoStart,
      refreshIntervalMs: clampNumber(
        saved.refreshIntervalMs,
        300,
        5000,
        defaultSettings.refreshIntervalMs,
      ),
    };
  } catch {
    return defaultSettings;
  }
}

function saveSettings(settings: Settings) {
  try {
    window.localStorage.setItem(settingsKey, JSON.stringify(settings));
  } catch {
    // Local storage can be unavailable in restricted web previews.
  }
}

function shouldUseDefaultOutputDir(value: string) {
  const normalized = value.trim();
  return (
    normalized === "" ||
    normalized === "." ||
    normalized === "./" ||
    normalized === "downloads" ||
    normalized === "./downloads"
  );
}

function clampNumber(
  value: unknown,
  min: number,
  max: number,
  fallback: number,
) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, Math.round(parsed)));
}

function taskTitle(task: DownloadTask) {
  if (task.file_name?.trim()) return task.file_name.trim();
  const sourceName = suggestedFileName(task.source);
  return sourceName || protocolLabel(task.protocol);
}

function suggestedFileName(source: string) {
  if (source.startsWith("magnet:?")) {
    const params = new URLSearchParams(source.slice("magnet:?".length));
    return params.get("dn") || "magnet-download";
  }
  const protocol = fallbackDetect(source);
  try {
    const url = new URL(source);
    const segment = decodeURIComponent(url.pathname.split("/").pop() ?? "");
    if (protocol === "m3u8") {
      const baseName = segment
        ? segment.replace(/\.[^/.]+$/, "")
        : url.hostname || "playlist";
      return `${baseName}.mp4`;
    }
    return segment || url.hostname || source;
  } catch {
    const segment = source.split(/[\\/]/).pop() || source;
    if (protocol === "m3u8") {
      return `${segment.replace(/\.[^/.]+$/, "") || "playlist"}.mp4`;
    }
    return segment;
  }
}

function displayTaskSource(task: DownloadTask) {
  return redactCredentials(task.source);
}

function displayTaskError(task: DownloadTask) {
  return task.error ? redactCredentialsInText(task.error) : null;
}

function safeErrorText(error: unknown) {
  if (isMissingTauriBackendError(error)) {
    // 作者: long
    // Web 预览只能验证界面状态，不能调用桌面下载后端；用户可见提示要说明运行边界，避免暴露底层 invoke 异常。
    return "Web 预览模式缺少桌面后端，请在桌面客户端中执行该操作";
  }
  return redactCredentialsInText(String(error));
}

function isMissingTauriBackendError(error: unknown) {
  const text = String(error);
  return (
    text.includes("Cannot read properties of undefined") &&
    text.includes("invoke")
  );
}

function normalizeExpectedSha256(value: string) {
  const trimmed = value.trim();
  if (!trimmed) return null;
  const normalized = trimmed.replace(/^sha256:/i, "").trim().toLowerCase();
  return /^[0-9a-f]{64}$/.test(normalized) ? normalized : undefined;
}

function parseTorrentFileIndices(value: string) {
  const trimmed = value.trim();
  if (!trimmed) return [];
  const parts = trimmed.split(/[,\s]+/).filter(Boolean);
  const indices = new Set<number>();
  for (const part of parts) {
    const parsed = Number(part);
    if (!Number.isInteger(parsed) || parsed < 0) return undefined;
    indices.add(parsed);
  }
  return Array.from(indices).sort((left, right) => left - right);
}

function redactCredentialsInText(text: string) {
  return text.replace(
    /(?:[a-z][a-z0-9+.-]*:\/\/|magnet:\?)[^\s"'`<>]+/gi,
    (candidate) => {
      const match = candidate.match(/^(.+?)([.,;:]+)?$/);
      if (!match) return redactCredentials(candidate);
      return `${redactCredentials(match[1])}${match[2] ?? ""}`;
    },
  );
}

function redactCredentials(source: string) {
  try {
    const url = new URL(source);
    let changed = false;
    if (url.username || url.password) {
      // 作者: long
      // 属性页和错误提示只用于识别来源，账号密码保留在任务原始数据里用于复制和下载，展示时统一隐藏。
      url.username = "***";
      if (url.password) url.password = "***";
      changed = true;
    }

    for (const [key, value] of Array.from(url.searchParams.entries())) {
      const redactedValue = redactCredentials(value);
      if (redactedValue !== value) {
        url.searchParams.set(key, redactedValue);
        changed = true;
      }
    }

    return changed ? url.toString() : source;
  } catch {
    return source;
  }
}

function protocolLabel(protocol: Protocol) {
  return protocol === "unknown" ? "UNKNOWN" : protocol.toUpperCase();
}

function backendLabel(backend: Backend) {
  const labels: Record<Backend, string> = {
    "built-in": "内建",
    "system-handoff": "系统移交",
    aria2: "aria2",
    amule: "aMule",
    "smb-client": "SMB 客户端",
    ipfs: "IPFS",
    planned: "规划中",
  };
  return labels[backend];
}

function stateLabel(state: DownloadState) {
  const labels: Record<DownloadState, string> = {
    queued: "排队中",
    running: "下载中",
    finished: "已完成",
    failed: "失败",
    paused: "已暂停",
  };
  return labels[state];
}

function filterLabel(filter: QueueFilter) {
  const labels: Record<QueueFilter, string> = {
    all: "全部",
    queued: "排队中",
    running: "下载中",
    paused: "已暂停",
    finished: "已完成",
    failed: "失败",
    history: "历史记录",
  };
  return labels[filter];
}

function filterMatches(task: DownloadTask, filter: QueueFilter) {
  if (filter === "all") return true;
  if (filter === "history") {
    return task.state === "finished" || task.state === "failed";
  }
  return task.state === filter;
}

function taskCounts(tasks: DownloadTask[]) {
  return {
    all: tasks.length,
    queued: tasks.filter((task) => filterMatches(task, "queued")).length,
    running: tasks.filter((task) => task.state === "running").length,
    paused: tasks.filter((task) => task.state === "paused").length,
    finished: tasks.filter((task) => task.state === "finished").length,
    failed: tasks.filter((task) => task.state === "failed").length,
    history: tasks.filter((task) => filterMatches(task, "history")).length,
  } satisfies Record<QueueFilter, number>;
}

function progressRatio(task: DownloadTask) {
  const total = task.total_bytes;
  if (!total || total <= 0) return task.state === "finished" ? 1 : 0;
  return Math.min(1, Math.max(0, task.downloaded_bytes / total));
}

function formatBytes(value?: number | null) {
  if (!value || value <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let size = value;
  let index = 0;
  while (size >= 1024 && index < units.length - 1) {
    size /= 1024;
    index += 1;
  }
  return `${size >= 10 || index === 0 ? size.toFixed(0) : size.toFixed(1)} ${units[index]}`;
}

function currentSpeed(task: DownloadTask) {
  return `${formatBytes(task.current_speed_bytes_per_second ?? 0)}/s`;
}

function taskActionTitle(task: DownloadTask) {
  if (task.state === "running") return "点击暂停";
  if (task.state === "finished" || task.state === "failed") return "点击重新下载";
  return "点击开始";
}

function taskMatchesSearch(task: DownloadTask, query: string) {
  const normalized = query.trim().toLowerCase();
  if (!normalized) return true;
  return [
    taskTitle(task),
    displayTaskSource(task),
    task.output_dir,
    protocolLabel(task.protocol),
    stateLabel(task.state),
  ]
    .filter(Boolean)
    .some((value) => value.toLowerCase().includes(normalized));
}

function formatTaskProgress(task: DownloadTask) {
  const percent = Math.round(progressRatio(task) * 100);
  const size = task.total_bytes
    ? `${formatBytes(task.downloaded_bytes)} / ${formatBytes(task.total_bytes)}`
    : formatBytes(task.downloaded_bytes);
  return `${percent}% · ${size}`;
}

function taskSpeedLabel(task: DownloadTask) {
  if (task.state === "finished") return "完成";
  if (task.state === "paused") return "0 B/s";
  if (task.state === "queued" || task.state === "failed") return "--";
  return currentSpeed(task);
}

function formatRemainingTime(tasks: DownloadTask[]) {
  const activeTasks = tasks.filter((task) => task.state === "running");
  const speed = activeTasks.reduce(
    (total, task) => total + (task.current_speed_bytes_per_second ?? 0),
    0,
  );
  const remainingBytes = activeTasks.reduce((total, task) => {
    const totalBytes = task.total_bytes ?? 0;
    return total + Math.max(0, totalBytes - task.downloaded_bytes);
  }, 0);
  if (speed <= 0 || remainingBytes <= 0) return "--";
  const seconds = Math.ceil(remainingBytes / speed);
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.ceil(seconds / 60)}m`;
  return `${Math.ceil(seconds / 3600)}h`;
}

function Icon({ name }: { name: IconName }) {
  return (
    <svg aria-hidden="true" className={`uiIcon icon-${name}`} viewBox="0 0 24 24">
      {iconPaths[name].map((path) => (
        <path d={path} key={path} />
      ))}
    </svg>
  );
}

function App() {
  const [page, setPage] = useState<Page>("queue");
  const [filter, setFilter] = useState<QueueFilter>("all");
  const [settings, setSettings] = useState<Settings>(loadSettings);
  const [tasks, setTasks] = useState<DownloadTask[]>([]);
  const [message, setMessage] = useState("就绪");
  const [searchQuery, setSearchQuery] = useState("");
  const [doctorReport, setDoctorReport] = useState<DoctorReport | null>(null);
  const [newDialogOpen, setNewDialogOpen] = useState(false);
  const [source, setSource] = useState("");
  const [sourceSupport, setSourceSupport] = useState<SupportStatus | null>(null);
  const [fileName, setFileName] = useState("");
  const [expectedSha256, setExpectedSha256] = useState("");
  const [torrentFileIndices, setTorrentFileIndices] = useState("");
  const [outputDir, setOutputDir] = useState(settings.outputDir);
  const [activeTaskId, setActiveTaskId] = useState<string | null>(null);
  const [queueActive, setQueueActive] = useState(false);
  const [menuTaskId, setMenuTaskId] = useState<string | null>(null);
  const [propertyTask, setPropertyTask] = useState<DownloadTask | null>(null);
  const [action, setAction] = useState<TaskAction>("idle");
  const autoRunKeyRef = useRef("");

  const counts = useMemo(() => taskCounts(tasks), [tasks]);
  const visibleTasks = useMemo(
    () =>
      tasks
        .filter((task) => filterMatches(task, filter))
        .filter((task) => taskMatchesSearch(task, searchQuery)),
    [filter, searchQuery, tasks],
  );
  const runningTasks = useMemo(
    () => tasks.filter((task) => task.state === "running"),
    [tasks],
  );
  const totalCurrentSpeed = useMemo(
    () =>
      runningTasks.reduce(
        (total, task) => total + (task.current_speed_bytes_per_second ?? 0),
        0,
      ),
    [runningTasks],
  );
  const completedBytes = useMemo(
    () =>
      tasks
        .filter((task) => task.state === "finished")
        .reduce((total, task) => total + task.downloaded_bytes, 0),
    [tasks],
  );
  const protocolReadyCount =
    doctorReport?.protocols.filter((item) => item.executable).length ??
    supportedNow.size;
  const protocolTotalCount = doctorReport?.protocols.length ?? supportedNow.size;
  const protocolCoverage = protocolTotalCount
    ? Math.round((protocolReadyCount / protocolTotalCount) * 100)
    : 0;

  const runQueue = useCallback(async () => {
    setQueueActive(true);
    try {
      const report = await invoke<QueueRunReport>("run_queue", {
        concurrency: settings.concurrency,
        retryAttempts: settings.retryAttempts,
        threadCount: settings.threadCount,
        speedLimitMbps:
          settings.speedLimitMbps && settings.speedLimitMbps > 0
            ? settings.speedLimitMbps
            : null,
        restartExisting: false,
      });
      if (report.tasks.length > 0) {
        setTasks(await invoke<DownloadTask[]>("list_downloads"));
        setMessage(`队列完成：${report.finished} 个完成，${report.failed} 个失败`);
      }
    } catch (error) {
      setMessage(
        isMissingTauriBackendError(error)
          ? "Web 预览模式：任务已加入本地预览队列，运行队列需要桌面后端"
          : safeErrorText(error),
      );
    } finally {
      setQueueActive(false);
    }
  }, [
    settings.concurrency,
    settings.retryAttempts,
    settings.speedLimitMbps,
    settings.threadCount,
  ]);

  useEffect(() => {
    saveSettings(settings);
  }, [settings]);

  useEffect(() => {
    refreshTasks();
    invoke<string>("default_output_dir")
      .then((defaultDir) => {
        setSettings((current) =>
          shouldUseDefaultOutputDir(current.outputDir)
            ? { ...current, outputDir: defaultDir }
            : current,
        );
        setOutputDir((current) =>
          shouldUseDefaultOutputDir(current) ? defaultDir : current,
        );
      })
      .catch(() => {
        // Web preview has no Tauri backend; keep the empty value and let the
        // preview fallback create an in-memory task.
      });
    invoke<DoctorReport>("doctor")
      .then(setDoctorReport)
      .catch(() => setDoctorReport(null));
  }, []);

  useEffect(() => {
    if (!queueActive && !tasks.some((task) => task.state === "running")) return;
    const timer = window.setInterval(refreshTasks, settings.refreshIntervalMs);
    return () => window.clearInterval(timer);
  }, [queueActive, settings.refreshIntervalMs, tasks]);

  useEffect(() => {
    if (!settings.autoStart) {
      autoRunKeyRef.current = "";
      return;
    }
    if (queueActive) return;
    if (tasks.some((task) => task.state === "running")) {
      autoRunKeyRef.current = "";
      return;
    }
    const queuedIds = tasks
      .filter((task) => task.state === "queued")
      .map((task) => task.id)
      .join(",");
    if (!queuedIds) {
      autoRunKeyRef.current = "";
      return;
    }
    if (autoRunKeyRef.current === queuedIds) return;

    // 作者: long
    // 自动开始由队列状态驱动，已有任务运行时新任务只排队，等运行槽位释放后再按并发设置启动。
    autoRunKeyRef.current = queuedIds;
    void runQueue();
  }, [queueActive, runQueue, settings.autoStart, tasks]);

  useEffect(() => {
    const normalizedSource = source.trim();
    if (!newDialogOpen || !normalizedSource) {
      return;
    }

    let cancelled = false;
    const timer = window.setTimeout(() => {
      invoke<SupportStatus>("support", { source: normalizedSource })
        .then((status) => {
          if (!cancelled) setSourceSupport(status);
        })
        .catch(() => {
          // 作者: long
          // Web 预览没有 Tauri 后端，保留本地识别结果，避免新建弹框在预览态空白。
        });
    }, 180);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [newDialogOpen, source]);

  async function refreshTasks() {
    const result = await invoke<DownloadTask[]>("list_downloads").catch(
      () => null,
    );
    if (result) setTasks(result);
  }

  async function refreshTasksWithMessage() {
    await refreshTasks();
    setMessage("任务列表已刷新");
  }

  async function refreshDoctorReport() {
    try {
      const report = await invoke<DoctorReport>("doctor");
      setDoctorReport(report);
      setMessage("后端自检已更新");
      return true;
    } catch {
      setDoctorReport(null);
      setMessage("Web 预览模式无法调用后端自检");
      return false;
    }
  }

  function updateSettings(patch: Partial<Settings>) {
    setSettings((current) => ({ ...current, ...patch }));
  }

  async function createTask() {
    const normalizedSource = source.trim();
    if (!normalizedSource) {
      setMessage("下载链接不能为空");
      return;
    }
    const normalizedOutput = outputDir.trim() || settings.outputDir;
    const normalizedSha256 = normalizeExpectedSha256(expectedSha256);
    if (normalizedSha256 === undefined) {
      setMessage("SHA-256 需要是 64 位十六进制");
      return;
    }
    const selectedTorrentFiles = parseTorrentFileIndices(torrentFileIndices);
    if (selectedTorrentFiles === undefined) {
      setMessage("Torrent 文件编号只能填写非负整数");
      return;
    }
    const task = await invoke<DownloadTask>("enqueue_download", {
      payload: {
        source: normalizedSource,
        output_dir: normalizedOutput,
        file_name: fileName.trim() || null,
        expected_sha256: normalizedSha256,
        torrent_file_indices: selectedTorrentFiles,
      },
    }).catch(() => {
      const protocol = fallbackDetect(normalizedSource);
      return {
        id: `preview-${Date.now()}`,
        source: normalizedSource,
        protocol,
        support: fallbackSupport(normalizedSource),
        state: "queued",
        output_dir: normalizedOutput,
        file_name: fileName.trim() || suggestedFileName(normalizedSource),
        expected_sha256: normalizedSha256,
        torrent_file_indices: selectedTorrentFiles,
        total_bytes: null,
        downloaded_bytes: 0,
        created_at_ms: Date.now(),
        updated_at_ms: Date.now(),
      } satisfies DownloadTask;
    });

    setTasks((current) => [task, ...current.filter((item) => item.id !== task.id)]);
    setNewDialogOpen(false);
    updateNewTaskSource("");
    setFileName("");
    setExpectedSha256("");
    setTorrentFileIndices("");
    setOutputDir(settings.outputDir);
    setMessage(`${taskTitle(task)} 已加入队列`);
  }

  async function pasteFromClipboard() {
    try {
      const text = await navigator.clipboard.readText();
      const normalizedText = text.trim();
      if (normalizedText) {
        updateNewTaskSource(normalizedText);
      }
    } catch {
      setMessage("无法读取剪切板");
    }
  }

  async function openPasteDialog() {
    openNewDialog();
    await pasteFromClipboard();
  }

  async function copyText(text: string, successMessage: string) {
    setAction("copy");
    try {
      await navigator.clipboard.writeText(text);
      setMessage(successMessage);
    } catch {
      setMessage("复制失败");
    } finally {
      setAction("idle");
    }
  }

  async function taskOutputPath(task: DownloadTask) {
    return invoke<string>("task_output_path", { id: task.id }).catch(
      () => `${task.output_dir}/${taskTitle(task)}`,
    );
  }

  async function copyTaskPath(task: DownloadTask) {
    const path = await taskOutputPath(task);
    await copyText(path, "文件路径已复制");
  }

  async function openTaskOutput(task: DownloadTask) {
    setAction("open");
    try {
      await invoke("open_task_output", { id: task.id });
      setMessage(`${taskTitle(task)} 已打开`);
    } catch (error) {
      setMessage(safeErrorText(error));
    } finally {
      setAction("idle");
    }
  }

  async function revealTaskOutput(task: DownloadTask, message = "已在文件夹中显示") {
    setAction("open");
    try {
      await invoke("reveal_task_output", { id: task.id });
      setMessage(message);
    } catch (error) {
      setMessage(safeErrorText(error));
    } finally {
      setAction("idle");
    }
  }

  async function startTask(task: DownloadTask, restartExisting = false) {
    if (!task.support.executable) {
      setMessage(task.support.note || "当前协议不可执行");
      return;
    }
    setAction("start");
    setActiveTaskId(task.id);
    setTasks((current) =>
      current.map((item) =>
        item.id === task.id ? { ...item, state: "running" } : item,
      ),
    );
    try {
      const report = await invoke<TaskRunReport>("start_download", {
        id: task.id,
        concurrency: settings.concurrency,
        retryAttempts: settings.retryAttempts,
        threadCount: settings.threadCount,
        speedLimitMbps:
          settings.speedLimitMbps && settings.speedLimitMbps > 0
            ? settings.speedLimitMbps
            : null,
        restartExisting,
      });
      setTasks((current) =>
        current.map((item) => (item.id === task.id ? report.task : item)),
      );
      setMessage(
        report.summary
          ? `已保存 ${formatBytes(report.summary.bytes_written)}`
          : `${taskTitle(report.task)} ${stateLabel(report.task.state)}`,
      );
    } catch (error) {
      setMessage(safeErrorText(error));
      refreshTasks();
    } finally {
      setAction("idle");
      setActiveTaskId(null);
    }
  }

  async function pauseTask(task: DownloadTask) {
    setAction("pause");
    try {
      const updated = await invoke<DownloadTask>("pause_download", {
        id: task.id,
      });
      setTasks((current) =>
        current.map((item) => (item.id === task.id ? updated : item)),
      );
      setMessage(`${taskTitle(task)} 已暂停`);
    } catch (error) {
      setMessage(safeErrorText(error));
    } finally {
      setAction("idle");
    }
  }

  async function removeTask(task: DownloadTask) {
    setAction("remove");
    try {
      await invoke<DownloadTask>("remove_download", { id: task.id });
      setTasks((current) => current.filter((item) => item.id !== task.id));
      setMessage(`${taskTitle(task)} 已删除`);
    } catch (error) {
      setMessage(safeErrorText(error));
    } finally {
      setAction("idle");
    }
  }

  async function redownloadTask(task: DownloadTask) {
    setMenuTaskId(null);
    await startTask(task, true);
  }

  function toggleTask(task: DownloadTask) {
    if (task.state === "running") {
      pauseTask(task);
    } else {
      // 作者: long
      // 已结束任务再次点击属于重新下载，必须清理旧输出，避免完整文件被 HTTP 续传逻辑误判。
      startTask(task, task.state === "finished" || task.state === "failed");
    }
  }

  function openNewDialog() {
    setOutputDir(settings.outputDir);
    setSourceSupport(source.trim() ? fallbackSupport(source.trim()) : null);
    setNewDialogOpen(true);
  }

  function closeNewDialog() {
    setNewDialogOpen(false);
    setSourceSupport(null);
  }

  function updateNewTaskSource(value: string) {
    const normalizedSource = value.trim();
    setSource(value);
    setSourceSupport(normalizedSource ? fallbackSupport(normalizedSource) : null);
    if (!fileName.trim()) setFileName(suggestedFileName(value));
  }

  const currentMenuTask = tasks.find((task) => task.id === menuTaskId) ?? null;

  return (
    <>
      {page === "queue" ? (
        <main className="appShell" data-testid="queue-page">
          <aside className="sidebar">
            <div>
              <div className="brand">
                <span className="brandMark" aria-label="FluxDown">
                  FD
                </span>
                <div>
                  <strong>FluxDown</strong>
                  <span>下载控制台</span>
                </div>
              </div>

              <p className="sidebarSectionTitle">任务状态</p>
              <nav className="statusNav" aria-label="下载任务状态">
                {queueFilters.map((item) => (
                  <button
                    className={`statusButton ${filter === item ? "active" : ""}`}
                    data-filter={item}
                    key={item}
                    onClick={() => setFilter(item)}
                  >
                    <Icon name={filterIcons[item]} />
                    <span>{item === "all" ? "全部任务" : filterLabel(item)}</span>
                    <em>{counts[item]}</em>
                  </button>
                ))}
              </nav>
            </div>

            <div
              className="protocolPanel"
              style={{ "--coverage": `${protocolCoverage}%` } as CSSProperties}
            >
              <strong>
                协议能力 {protocolReadyCount} / {protocolTotalCount}
              </strong>
              <small>HTTP、M3U8、BT、SFTP、SMB、IPFS 等后端可用性</small>
              <div className="protocolMeter">
                <span />
              </div>
              <div className="protocolChips">
                <span>HTTP</span>
                <span>M3U8</span>
                <span>BT</span>
                <span>SFTP</span>
                <span>SMB</span>
                <span>IPFS</span>
              </div>
            </div>
          </aside>

          <section className="workspace">
            <header className="workspaceHeader">
              <div className="titleBlock">
                <h1>下载任务</h1>
                <p>左侧切换状态，右侧集中执行队列操作。{message}</p>
              </div>
              <div className="toolbar">
                <label className="searchBox">
                  <Icon name="search" />
                  <input
                    data-testid="task-search-input"
                    onChange={(event) => setSearchQuery(event.target.value)}
                    placeholder="搜索文件名、协议或来源"
                    value={searchQuery}
                  />
                </label>
                <button
                  className="actionButton primary"
                  data-action="new-task"
                  data-testid="new-task-button"
                  onClick={openNewDialog}
                >
                  <Icon name="download" />
                  新建任务
                </button>
                <button
                  className="actionButton"
                  data-action="paste-link"
                  data-testid="paste-link-button"
                  onClick={openPasteDialog}
                >
                  <Icon name="link" />
                  粘贴链接
                </button>
                <button
                  className="actionButton"
                  data-action="start-queue"
                  data-testid="start-queue-button"
                  disabled={queueActive}
                  onClick={runQueue}
                >
                  <Icon name="play" />
                  {queueActive ? "运行中" : "开始队列"}
                </button>
                <div className="iconActions">
                  <button
                    data-action="refresh"
                    data-testid="refresh-button"
                    title="刷新列表"
                    onClick={refreshTasksWithMessage}
                  >
                    <Icon name="refresh" />
                  </button>
                  <button
                    data-action="settings"
                    data-testid="settings-button"
                    title="设置"
                    onClick={() => setPage("settings")}
                  >
                    <Icon name="settings" />
                  </button>
                </div>
              </div>
            </header>

            <section className="contentView queueView">
              <div className="insights">
                <div className="metric accent">
                  <span>实时下载速度</span>
                  <strong>{formatBytes(totalCurrentSpeed)}/s</strong>
                  <small>{runningTasks.length} 个任务正在占用带宽</small>
                </div>
                <div className="metric">
                  <span>已完成数据</span>
                  <strong>{formatBytes(completedBytes)}</strong>
                  <small>{counts.finished} 个任务完成</small>
                </div>
                <div className="metric">
                  <span>队列并发</span>
                  <strong>
                    {runningTasks.length} / {settings.concurrency}
                  </strong>
                  <small>{settings.autoStart ? "自动接续已开启" : "自动接续已关闭"}</small>
                </div>
                <div className="metric">
                  <span>剩余时间</span>
                  <strong>{formatRemainingTime(tasks)}</strong>
                  <small>按当前速度估算</small>
                </div>
              </div>

              <DownloadList
                activeTaskId={activeTaskId}
                action={action}
                filter={filter}
                menuTaskId={menuTaskId}
                onMenu={setMenuTaskId}
                onOpen={openTaskOutput}
                onToggle={toggleTask}
                searchQuery={searchQuery}
                tasks={visibleTasks}
                totalTasks={tasks.length}
              />
            </section>
          </section>
        </main>
      ) : (
        <SettingsPage
          doctorReport={doctorReport}
          onBack={() => setPage("queue")}
          onChange={updateSettings}
          onRefreshDoctor={refreshDoctorReport}
          settings={settings}
        />
      )}

      {newDialogOpen ? (
        <NewTaskDialog
          expectedSha256={expectedSha256}
          fileName={fileName}
          onClose={closeNewDialog}
          onCreate={createTask}
          onExpectedSha256Change={setExpectedSha256}
          onFileNameChange={setFileName}
          onOutputDirChange={setOutputDir}
          onPaste={pasteFromClipboard}
          onSourceChange={updateNewTaskSource}
          onTorrentFileIndicesChange={setTorrentFileIndices}
          outputDir={outputDir}
          source={source}
          support={sourceSupport}
          torrentFileIndices={torrentFileIndices}
        />
      ) : null}

      {currentMenuTask ? (
        <TaskMenu
          onClose={() => setMenuTaskId(null)}
          onCopyLink={() =>
            copyText(currentMenuTask.source, "下载链接已复制").then(() =>
              setMenuTaskId(null),
            )
          }
          onCopyPath={() =>
            copyTaskPath(currentMenuTask).then(() => setMenuTaskId(null))
          }
          onOpen={() =>
            openTaskOutput(currentMenuTask).then(() => setMenuTaskId(null))
          }
          onProperties={() => {
            setPropertyTask(currentMenuTask);
            setMenuTaskId(null);
          }}
          onReveal={() =>
            revealTaskOutput(currentMenuTask).then(() => setMenuTaskId(null))
          }
          onRedownload={() => redownloadTask(currentMenuTask)}
          onRemove={() => {
            setMenuTaskId(null);
            removeTask(currentMenuTask);
          }}
          onShare={() =>
            revealTaskOutput(currentMenuTask, "已定位文件，可从系统文件管理器分享").then(
              () => setMenuTaskId(null),
            )
          }
          task={currentMenuTask}
        />
      ) : null}

      {propertyTask ? (
        <PropertyDialog
          onClose={() => setPropertyTask(null)}
          task={propertyTask}
        />
      ) : null}
    </>
  );
}

function DownloadList({
  activeTaskId,
  action,
  filter,
  menuTaskId,
  onMenu,
  onOpen,
  onToggle,
  searchQuery,
  tasks,
  totalTasks,
}: {
  activeTaskId: string | null;
  action: TaskAction;
  filter: QueueFilter;
  menuTaskId: string | null;
  onMenu: (id: string | null) => void;
  onOpen: (task: DownloadTask) => void;
  onToggle: (task: DownloadTask) => void;
  searchQuery: string;
  tasks: DownloadTask[];
  totalTasks: number;
}) {
  const emptyTitle = emptyTaskTitle(filter, searchQuery, totalTasks);
  const emptySubtitle = emptyTaskSubtitle(filter, searchQuery, totalTasks);

  return (
    <section className="taskBoard" data-testid="task-board">
      <div className="boardHead">
        <span>任务</span>
        <span>状态</span>
        <span>进度</span>
        <span>速度</span>
        <span>操作</span>
      </div>
      <div className="taskList" data-testid="task-list">
        {tasks.length === 0 ? (
          <div className="emptyNote">
            <span>{emptyTitle}</span>
            <strong>{emptySubtitle}</strong>
          </div>
        ) : (
          tasks.map((task) => (
            <TaskRow
              action={activeTaskId === task.id ? action : "idle"}
              key={task.id}
              menuOpen={menuTaskId === task.id}
              onMenu={onMenu}
              onOpen={onOpen}
              onToggle={onToggle}
              task={task}
            />
          ))
        )}
      </div>
    </section>
  );
}

function emptyTaskTitle(
  filter: QueueFilter,
  searchQuery: string,
  totalTasks: number,
) {
  if (searchQuery.trim()) return "没有匹配的任务";
  if (filter === "history") return "暂无历史记录";
  if (totalTasks === 0) return "暂无下载记录";
  return "当前状态没有任务";
}

function emptyTaskSubtitle(
  filter: QueueFilter,
  searchQuery: string,
  totalTasks: number,
) {
  if (searchQuery.trim()) return "换个关键词，或清空搜索后查看完整任务列表。";
  if (filter === "history") return "完成或失败的任务会自动出现在这里。";
  if (totalTasks === 0) return "新建任务后会保留在这里，完成和失败任务也会进入历史记录。";
  return "切换左侧状态或历史记录，可查看其他下载任务。";
}

function TaskRow({
  action,
  menuOpen,
  onMenu,
  onOpen,
  onToggle,
  task,
}: {
  action: TaskAction;
  menuOpen: boolean;
  onMenu: (id: string | null) => void;
  onOpen: (task: DownloadTask) => void;
  onToggle: (task: DownloadTask) => void;
  task: DownloadTask;
}) {
  const progress = progressRatio(task);
  const width = `${Math.round(progress * 100)}%`;

  return (
    <article
      className={`taskRow ${task.state}`}
      data-task-id={task.id}
      data-task-output-dir={task.output_dir}
      data-task-protocol={task.protocol}
      data-task-source={displayTaskSource(task)}
      data-task-state={task.state}
      data-task-title={taskTitle(task)}
      data-state={task.state}
      data-testid="task-row"
      onContextMenu={(event) => {
        event.preventDefault();
        onMenu(task.id);
      }}
      style={{ "--value": width } as CSSProperties}
    >
      <div className="taskFile">
        <div className="fileMark">
          <Icon name={stateIcons[task.state]} />
        </div>
        <div className="taskName">
          <strong>{taskTitle(task)}</strong>
          <span>
            {protocolLabel(task.protocol)} · {displayTaskSource(task)}
          </span>
          {displayTaskError(task) ? <em>{displayTaskError(task)}</em> : null}
        </div>
      </div>
      <span className="statusPill">{stateLabel(task.state)}</span>
      <div className="progressCell">
        <div className="progressTrack">
          <span />
        </div>
        <small>{formatTaskProgress(task)}</small>
      </div>
      <span className="speedCell">{taskSpeedLabel(task)}</span>
      <div className="rowActions">
        <button
          data-testid="task-toggle-button"
          onClick={() => onToggle(task)}
          title={taskActionTitle(task)}
        >
          <Icon name={task.state === "running" ? "pause" : "play"} />
        </button>
        <button data-testid="task-open-button" onClick={() => onOpen(task)} title="打开文件">
          <Icon name="folder" />
        </button>
        <button
          aria-pressed={menuOpen}
          data-testid="task-more-button"
          onClick={() => onMenu(menuOpen ? null : task.id)}
          title="更多"
        >
          <Icon name="more" />
        </button>
      </div>
      {action === "start" ? <span className="busyDot" /> : null}
    </article>
  );
}

function NewTaskDialog({
  expectedSha256,
  fileName,
  onClose,
  onCreate,
  onExpectedSha256Change,
  onFileNameChange,
  onOutputDirChange,
  onPaste,
  onSourceChange,
  onTorrentFileIndicesChange,
  outputDir,
  source,
  support,
  torrentFileIndices,
}: {
  expectedSha256: string;
  fileName: string;
  onClose: () => void;
  onCreate: () => void;
  onExpectedSha256Change: (value: string) => void;
  onFileNameChange: (value: string) => void;
  onOutputDirChange: (value: string) => void;
  onPaste: () => void;
  onSourceChange: (value: string) => void;
  onTorrentFileIndicesChange: (value: string) => void;
  outputDir: string;
  source: string;
  support: SupportStatus | null;
  torrentFileIndices: string;
}) {
  const protocol = support?.protocol ?? fallbackDetect(source);
  const isTorrentLike = protocol === "torrent" || protocol === "magnet";

  return (
    <div className="modalBackdrop" data-testid="new-task-backdrop" onMouseDown={onClose}>
      <section
        className="taskDialog"
        data-testid="new-task-dialog"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="dialogHeader">
          <div>
            <span className="dialogMark">＋</span>
            <h2>新建任务</h2>
          </div>
          <div className="dialogTools">
            <button data-testid="new-task-paste" title="从剪切板读取" onClick={onPaste}>
              ⧉
            </button>
            <button data-testid="new-task-close" title="关闭" onClick={onClose}>
              ×
            </button>
          </div>
        </header>
        <label className="fieldBlock">
          <span>下载链接</span>
          <textarea
            autoFocus
            data-testid="new-task-source"
            onChange={(event) => onSourceChange(event.target.value)}
            placeholder="粘贴 HTTP、m3u8、torrent、magnet、FTP、SFTP、SMB 等下载源"
            rows={4}
            value={source}
          />
        </label>
        {support ? <SupportPreview status={support} /> : null}
        <label className="fieldBlock">
          <span>另存为文件名</span>
          <input
            data-testid="new-task-file-name"
            onChange={(event) => onFileNameChange(event.target.value)}
            placeholder="留空则按下载资源自动命名"
            value={fileName}
          />
        </label>
        <label className="fieldBlock">
          <span>保存路径</span>
          <input
            data-testid="new-task-output-dir"
            onChange={(event) => onOutputDirChange(event.target.value)}
            value={outputDir}
          />
        </label>
        <label className="fieldBlock">
          <span>SHA-256 校验</span>
          <input
            data-testid="new-task-sha256"
            onChange={(event) => onExpectedSha256Change(event.target.value)}
            placeholder="可选，64 位十六进制"
            value={expectedSha256}
          />
        </label>
        {isTorrentLike ? (
          <label className="fieldBlock">
            <span>Torrent 文件编号</span>
            <input
              data-testid="new-task-torrent-indices"
              onChange={(event) => onTorrentFileIndicesChange(event.target.value)}
              placeholder="可选，如 0,2；留空下载全部文件"
              value={torrentFileIndices}
            />
          </label>
        ) : null}
        <footer className="dialogFooter">
          <button data-testid="new-task-cancel" onClick={onClose}>取消</button>
          <button className="primary" data-testid="new-task-create" onClick={onCreate}>
            创建任务
          </button>
        </footer>
      </section>
    </div>
  );
}

function SupportPreview({ status }: { status: SupportStatus }) {
  const detail = status.missing_command
    ? `缺少 ${status.missing_command}`
    : status.note || backendLabel(status.backend);

  return (
    <div className={`supportPreview ${status.executable ? "ready" : "blocked"}`}>
      <span>{protocolLabel(status.protocol)}</span>
      <span>{backendLabel(status.backend)}</span>
      <strong>{status.executable ? "可下载" : "不可执行"}</strong>
      <em>{detail}</em>
    </div>
  );
}

function TaskMenu({
  onClose,
  onCopyLink,
  onCopyPath,
  onOpen,
  onProperties,
  onReveal,
  onRedownload,
  onRemove,
  onShare,
  task,
}: {
  onClose: () => void;
  onCopyLink: () => void;
  onCopyPath: () => void;
  onOpen: () => void;
  onProperties: () => void;
  onReveal: () => void;
  onRedownload: () => void;
  onRemove: () => void;
  onShare: () => void;
  task: DownloadTask;
}) {
  return (
    <div className="menuBackdrop" onMouseDown={onClose}>
      <section className="taskMenu" onMouseDown={(event) => event.stopPropagation()}>
        <header>
          <strong>{taskTitle(task)}</strong>
          <button onClick={onClose}>×</button>
        </header>
        <button onClick={onCopyLink}>复制下载链接</button>
        <button onClick={onCopyPath}>复制文件路径</button>
        <button onClick={onOpen}>打开</button>
        <button onClick={onReveal}>在文件夹中显示</button>
        <button onClick={onShare}>分享</button>
        <button onClick={onProperties}>属性</button>
        <button onClick={onRedownload}>重新下载</button>
        <button className="danger" onClick={onRemove}>
          删除
        </button>
      </section>
    </div>
  );
}

function PropertyDialog({
  onClose,
  task,
}: {
  onClose: () => void;
  task: DownloadTask;
}) {
  return (
    <div className="modalBackdrop" onMouseDown={onClose}>
      <section className="propertyDialog" onMouseDown={(event) => event.stopPropagation()}>
        <header className="dialogHeader">
          <h2>任务属性</h2>
          <button title="关闭" onClick={onClose}>
            ×
          </button>
        </header>
        <dl>
          <dt>文件名</dt>
          <dd>{taskTitle(task)}</dd>
          <dt>下载链接</dt>
          <dd>{displayTaskSource(task)}</dd>
          <dt>保存路径</dt>
          <dd>{task.output_dir}</dd>
          <dt>协议</dt>
          <dd>{protocolLabel(task.protocol)}</dd>
          <dt>状态</dt>
          <dd>{stateLabel(task.state)}</dd>
          <dt>大小</dt>
          <dd>
            {formatBytes(task.downloaded_bytes)} / {formatBytes(task.total_bytes)}
          </dd>
          {task.expected_sha256 ? (
            <>
              <dt>SHA-256</dt>
              <dd>{task.expected_sha256}</dd>
            </>
          ) : null}
          {task.torrent_file_indices?.length ? (
            <>
              <dt>Torrent 文件编号</dt>
              <dd>{task.torrent_file_indices.join(", ")}</dd>
            </>
          ) : null}
        </dl>
      </section>
    </div>
  );
}

function SettingsPage({
  doctorReport,
  onBack,
  onChange,
  onRefreshDoctor,
  settings,
}: {
  doctorReport: DoctorReport | null;
  onBack: () => void;
  onChange: (patch: Partial<Settings>) => void;
  onRefreshDoctor: () => Promise<boolean>;
  settings: Settings;
}) {
  const [section, setSection] = useState<SettingsSection>("general");
  const [notice, setNotice] = useState("设置变更会自动保存到本机");
  const backends =
    doctorReport?.backends ?? [
      {
        backend: "built-in" as Backend,
        available: true,
        note: "已编译进 FluxDown core",
      },
    ];
  const protocols =
    doctorReport?.protocols ??
    Array.from(supportedNow).map((protocol) => ({
      protocol,
      backend: protocol === "ed2k" ? "system-handoff" : ("built-in" as Backend),
      executable: true,
      note: "当前版本支持清单",
    }));
  const activeSection =
    settingsSections.find((item) => item.id === section) ?? settingsSections[0];
  const availableBackendCount = backends.filter((backend) => backend.available).length;
  const healthScore = backends.length
    ? Math.round((availableBackendCount / backends.length) * 100)
    : 100;

  function updateSetting(patch: Partial<Settings>, label: string) {
    // 作者: long
    // 设置页变更会影响新建任务和队列运行参数，统一走外层状态更新，再由根组件持久化到本机存储。
    onChange(patch);
    setNotice(`${label} 已更新，设置会自动保存`);
  }

  function saveCurrentSettings() {
    saveSettings(settings);
    setNotice("设置已保存到本机");
  }

  async function runDoctorCheck() {
    const refreshed = await onRefreshDoctor();
    setNotice(refreshed ? "后端自检已更新" : "Web 预览模式无法调用桌面后端自检");
  }

  return (
    <main className="settingsShell" data-testid="settings-page">
      <aside className="settingsSidebar">
        <button className="settingsReturn" data-testid="settings-back-button" onClick={onBack}>
          <Icon name="arrow-left" />
          返回任务
        </button>

        <div className="settingsTitleBlock">
          <h1>设置</h1>
          <p>用独立工作台管理下载策略、协议能力、存储路径和安全选项。</p>
        </div>

        <nav className="settingsNav" aria-label="设置分类">
          {settingsSections.map((item) => (
            <button
              className={`settingsNavButton ${section === item.id ? "active" : ""}`}
              data-section={item.id}
              data-testid="settings-nav-button"
              key={item.id}
              onClick={() => setSection(item.id)}
            >
              <Icon name={item.icon} />
              <span>
                <strong>{item.title}</strong>
                <span>{item.subtitle}</span>
              </span>
            </button>
          ))}
        </nav>

        <div className="settingsSidebarFoot">
          <strong>当前配置健康度 {healthScore}%</strong>
          <span data-settings-notice="sidebar">
            {availableBackendCount} / {backends.length} 个后端可用，设置变更会自动保存到本机。
          </span>
        </div>
      </aside>

      <section className="settingsDetail">
        <header className="settingsDetailHead">
          <div>
            <h2>{activeSection.title}</h2>
            <p>{activeSection.subtitle}</p>
          </div>
          <div className="settingsDetailActions">
            <button className="actionButton" data-testid="settings-detail-back-button" onClick={onBack}>
              <Icon name="arrow-left" />
              返回任务
            </button>
            <button
              className="actionButton"
              data-action="check-backend"
              data-testid="settings-check-backend-button"
              onClick={runDoctorCheck}
            >
              <Icon name="refresh" />
              检查后端
            </button>
            <button
              className="actionButton primary"
              data-action="save-settings"
              data-testid="settings-save-button"
              onClick={saveCurrentSettings}
            >
              <Icon name="check" />
              保存设置
            </button>
          </div>
        </header>
        <div className="settingsNotice" data-settings-notice="detail">
          {notice}
        </div>

        <div className="settingsLayout">
          {section === "general" ? (
            <section className="settingsBlock">
              <header>
                <div>
                  <h3>基础设置</h3>
                  <span>定义新任务的默认行为和桌面端刷新节奏。</span>
                </div>
                <div className="settingsBadge">推荐</div>
              </header>
              <SettingRow
                dataSetting="outputDir"
                title="默认保存位置"
                subtitle="新建任务会优先写入此目录，也会用于打开目录动作。"
              >
                <input
                  data-setting-input="outputDir"
                  data-testid="setting-output-dir"
                  onChange={(event) =>
                    updateSetting({ outputDir: event.target.value }, "默认保存位置")
                  }
                  value={settings.outputDir}
                />
              </SettingRow>
              <SettingRow
                dataSetting="autoStart"
                title="创建后自动开始"
                subtitle="任务入队后按并发设置自动启动。"
              >
                <button
                  aria-pressed={settings.autoStart}
                  className={`toggle ${settings.autoStart ? "on" : ""}`}
                  data-setting-input="autoStart"
                  data-testid="setting-auto-start"
                  onClick={() =>
                    updateSetting({ autoStart: !settings.autoStart }, "创建后自动开始")
                  }
                >
                  <span />
                </button>
              </SettingRow>
              <SettingRow
                dataSetting="refreshIntervalMs"
                title="列表刷新间隔"
                subtitle="下载中任务的状态刷新频率，单位毫秒。"
              >
                <input
                  data-setting-input="refreshIntervalMs"
                  data-testid="setting-refresh-interval"
                  max={5000}
                  min={300}
                  onChange={(event) =>
                    updateSetting(
                      {
                        refreshIntervalMs: clampNumber(
                          event.target.value,
                          300,
                          5000,
                          defaultSettings.refreshIntervalMs,
                        ),
                      },
                      "列表刷新间隔",
                    )
                  }
                  step={100}
                  type="number"
                  value={settings.refreshIntervalMs ?? defaultSettings.refreshIntervalMs}
                />
              </SettingRow>
            </section>
          ) : null}

          {section === "download" ? (
            <section className="settingsBlock">
              <header>
                <div>
                  <h3>下载策略</h3>
                  <span>控制全局队列、单任务线程和失败重试。</span>
                </div>
                <div className="settingsBadge">队列</div>
              </header>
              <SettingRow
                dataSetting="concurrency"
                title="同时运行任务数"
                subtitle="限制全局并发，避免挤占桌面网络。"
              >
                <input
                  data-setting-input="concurrency"
                  data-testid="setting-concurrency"
                  max={30}
                  min={1}
                  onChange={(event) =>
                    updateSetting(
                      {
                        concurrency: clampNumber(event.target.value, 1, 30, 1),
                      },
                      "同时运行任务数",
                    )
                  }
                  type="number"
                  value={settings.concurrency ?? defaultSettings.concurrency}
                />
              </SettingRow>
              <SettingRow
                dataSetting="threadCount"
                title="单任务线程数"
                subtitle="HTTP、FTP 等分段下载协议使用。"
              >
                <input
                  data-setting-input="threadCount"
                  data-testid="setting-thread-count"
                  max={32}
                  min={1}
                  onChange={(event) =>
                    updateSetting(
                      {
                        threadCount: clampNumber(event.target.value, 1, 32, 8),
                      },
                      "单任务线程数",
                    )
                  }
                  type="number"
                  value={settings.threadCount ?? defaultSettings.threadCount}
                />
              </SettingRow>
              <SettingRow
                dataSetting="retryAttempts"
                title="自动重试数"
                subtitle="任务失败后的重试次数，0-10。"
              >
                <input
                  data-setting-input="retryAttempts"
                  data-testid="setting-retry-attempts"
                  max={10}
                  min={0}
                  onChange={(event) =>
                    updateSetting(
                      {
                        retryAttempts: clampNumber(event.target.value, 0, 10, 1),
                      },
                      "自动重试数",
                    )
                  }
                  type="number"
                  value={settings.retryAttempts ?? defaultSettings.retryAttempts}
                />
              </SettingRow>
              <SettingRow
                dataSetting="speedLimitMbps"
                title="最大下载网速"
                subtitle="单位 MB/s，0 表示不限速。"
              >
                <input
                  data-setting-input="speedLimitMbps"
                  data-testid="setting-speed-limit"
                  max={10000}
                  min={0}
                  onChange={(event) =>
                    updateSetting(
                      {
                        speedLimitMbps: clampNumber(event.target.value, 0, 10000, 0),
                      },
                      "最大下载网速",
                    )
                  }
                  placeholder="不限速"
                  type="number"
                  value={
                    settings.speedLimitMbps && settings.speedLimitMbps > 0
                      ? settings.speedLimitMbps
                      : ""
                  }
                />
              </SettingRow>
            </section>
          ) : null}

          {section === "protocol" ? (
            <section className="settingsBlock" data-testid="settings-section-protocol">
              <header>
                <div>
                  <h3>协议能力</h3>
                  <span>展示本机下载后端和协议执行状态。</span>
                </div>
                <div className="settingsBadge">{availableBackendCount} 可用</div>
              </header>
              <div className="backendList" data-testid="settings-protocol-backends">
                {backends.map((backend, index) => (
                  <div
                    className="backendItem"
                    data-protocol-backend={backend.backend}
                    key={`${backend.backend}-${index}`}
                  >
                    <span>{backendLabel(backend.backend)}</span>
                    <strong>
                      {backend.available
                        ? "可用"
                        : backend.command
                          ? `缺少 ${backend.command}`
                          : "不可用"}
                    </strong>
                  </div>
                ))}
              </div>
              {protocols.length ? (
                <div className="protocolGrid" data-testid="settings-protocol-grid">
                  {protocols.map((item) => (
                    <span
                      className={item.executable ? "ready" : "blocked"}
                      data-protocol-chip={item.protocol}
                      data-protocol-executable={item.executable ? "true" : "false"}
                      key={item.protocol}
                    >
                      {protocolLabel(item.protocol)}
                    </span>
                  ))}
                </div>
              ) : null}
            </section>
          ) : null}

          {section === "storage" ? (
            <section className="settingsBlock">
              <header>
                <div>
                  <h3>存储与完成</h3>
                  <span>对齐当前下载核心已经支持的命名、校验和完成动作。</span>
                </div>
                <div className="settingsBadge">文件</div>
              </header>
              <SettingRow
                dataSetting="fileNaming"
                readOnly
                title="文件命名策略"
                subtitle="新建任务可手动填写文件名，留空时按链接自动推断。"
              >
                <span className="settingValue">自动推断 / 手动覆盖</span>
              </SettingRow>
              <SettingRow
                dataSetting="sha256"
                readOnly
                title="SHA-256 校验"
                subtitle="任务提供摘要时，下载完成后由后端校验文件完整性。"
              >
                <span className="settingValue">按任务启用</span>
              </SettingRow>
              <SettingRow
                dataSetting="torrentFileSelection"
                readOnly
                title="Torrent 文件选择"
                subtitle="磁力和种子任务可填写文件编号，只下载指定文件。"
              >
                <span className="settingValue">新建任务中配置</span>
              </SettingRow>
              <SettingRow
                dataSetting="openWhenFinished"
                readOnly
                title="完成后打开"
                subtitle="任务菜单支持打开文件和在文件夹中显示。"
              >
                <span className="settingValue">任务菜单</span>
              </SettingRow>
            </section>
          ) : null}

          {section === "security" ? (
            <section className="settingsBlock">
              <header>
                <div>
                  <h3>安全与隐私</h3>
                  <span>下载链接、错误提示和外部命令展示保持安全边界。</span>
                </div>
                <div className="settingsBadge">默认开启</div>
              </header>
              <SettingRow
                dataSetting="redactUrl"
                readOnly
                title="敏感链接脱敏"
                subtitle="界面展示 URL 时隐藏用户名、密码和嵌套凭据。"
              >
                <button aria-pressed="true" className="toggle on locked" disabled>
                  <span />
                </button>
              </SettingRow>
              <SettingRow
                dataSetting="redactError"
                readOnly
                title="错误提示脱敏"
                subtitle="下载失败信息会过滤链接中的敏感认证信息。"
              >
                <button aria-pressed="true" className="toggle on locked" disabled>
                  <span />
                </button>
              </SettingRow>
              <SettingRow
                dataSetting="externalBackendNotice"
                readOnly
                title="外部后端提示"
                subtitle="缺少命令时只展示命令名和后端状态，不暴露本地敏感路径。"
              >
                <span className="settingValue">按后端自检展示</span>
              </SettingRow>
            </section>
          ) : null}

          {section === "diagnostics" ? (
            <section className="settingsBlock" data-testid="settings-section-diagnostics">
              <header>
                <div>
                  <h3>高级诊断</h3>
                  <span>集中查看本机后端可用性和当前配置健康度。</span>
                </div>
                <div className="settingsBadge">{healthScore}%</div>
              </header>
              <div
                className="healthPanel"
                data-health-score={healthScore}
                data-testid="settings-health-panel"
              >
                <div className="healthScore">{healthScore}</div>
                <div>
                  <strong>能力完整度</strong>
                  <p>
                    {availableBackendCount} / {backends.length} 个后端可用。Web
                    预览模式无法调用 Tauri 后端，桌面客户端中会读取真实自检结果。
                  </p>
                </div>
              </div>
              <div className="backendList" data-testid="settings-diagnostics-backends">
                {backends.map((backend, index) => (
                  <div
                    className={`backendItem ${backend.available ? "" : "warn"}`}
                    data-diagnostics-backend={backend.backend}
                    key={`${backend.backend}-${index}`}
                  >
                    <span>{backendLabel(backend.backend)}</span>
                    <strong>{backend.available ? "可用" : backend.note}</strong>
                  </div>
                ))}
              </div>
            </section>
          ) : null}
        </div>
      </section>
    </main>
  );
}

function SettingRow({
  children,
  dataSetting,
  readOnly = false,
  subtitle,
  title,
}: {
  children: ReactNode;
  dataSetting: string;
  readOnly?: boolean;
  subtitle: string;
  title: string;
}) {
  return (
    <div
      className={`settingRow ${readOnly ? "readOnly" : ""}`}
      data-setting-row={dataSetting}
      data-setting-type={readOnly ? "readonly" : "editable"}
    >
      <div>
        <strong>{title}</strong>
        <span>{subtitle}</span>
      </div>
      <div className="settingControl">{children}</div>
    </div>
  );
}

export default App;
