import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties, ReactNode } from "react";
import { invoke } from "@tauri-apps/api/core";
import { open as openNativeDialog } from "@tauri-apps/plugin-dialog";
import {
  AlertTriangle,
  ArrowLeft,
  Check,
  ClipboardPaste,
  Clock3,
  Copy,
  Download,
  ExternalLink,
  FolderOpen,
  Gauge,
  HardDrive,
  Info,
  Link2,
  MoreVertical,
  Pause,
  Play,
  Plus,
  RefreshCw,
  Search,
  Settings,
  Share2,
  Timer,
  Trash2,
  X,
  Zap,
  type LucideIcon,
} from "lucide-react";
import appMark from "../src-tauri/icons/source.svg";
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
  | "unknown";

type Backend =
  | "built-in"
  | "system-handoff"
  | "aria2"
  | "amule"
  | "smb-client"
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
  | "clipboard"
  | "clock"
  | "copy"
  | "download"
  | "external-link"
  | "folder"
  | "gauge"
  | "hard-drive"
  | "info"
  | "link"
  | "more"
  | "pause"
  | "play"
  | "plus"
  | "refresh"
  | "search"
  | "settings"
  | "share"
  | "timer"
  | "trash"
  | "x"
  | "zap";

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
  speed_limit_mbps?: number | null;
  hls_variant_index?: number | null;
  hls_keep_transport_stream?: boolean;
  error?: string | null;
  created_at_ms?: number;
  updated_at_ms?: number;
  started_at_ms?: number | null;
  finished_at_ms?: number | null;
};

type HlsVariantInfo = {
  index: number;
  uri: string;
  bandwidth: number;
  average_bandwidth?: number | null;
  codecs?: string | null;
  resolution?: string | null;
  frame_rate?: number | null;
};

type TorrentDetailsFile = {
  index: number;
  path: string;
  size: number;
  progress_bytes?: number | null;
  sampled_speed_bps?: number | null;
};

type TorrentPeerSummary = {
  live: number;
  connecting: number;
  queued: number;
  seen: number;
  dead: number;
};

type TorrentDetails = {
  runtime: boolean;
  name?: string | null;
  info_hash?: string | null;
  files: TorrentDetailsFile[];
  trackers: string[];
  total_bytes?: number | null;
  progress_bytes?: number | null;
  uploaded_bytes?: number | null;
  download_speed_bps?: number | null;
  upload_speed_bps?: number | null;
  eta_seconds?: number | null;
  peers?: TorrentPeerSummary | null;
  error?: string | null;
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
  notifyOnFinish: boolean;
  clipboardMonitor: boolean;
};

type UpdateCheckReport = {
  current_version: string;
  latest_version: string;
  has_update: boolean;
  release_url: string;
  release_notes?: string | null;
  published_at?: string | null;
  download_url?: string | null;
  download_file_name?: string | null;
  download_size_bytes?: number | null;
};

type UpdateDialogState =
  | "closed"
  | "checking"
  | "upToDate"
  | "available"
  | "downloading"
  | "installReady"
  | "error";

const updateIgnoredVersionKey = "fluxdown.desktop.ignoredUpdate";

function loadIgnoredUpdateVersion(): string {
  try {
    return window.localStorage.getItem(updateIgnoredVersionKey) ?? "";
  } catch {
    return "";
  }
}

function saveIgnoredUpdateVersion(version: string) {
  try {
    if (version) {
      window.localStorage.setItem(updateIgnoredVersionKey, version);
    } else {
      window.localStorage.removeItem(updateIgnoredVersionKey);
    }
  } catch {
    // Local storage can be unavailable in restricted web previews.
  }
}

const settingsKey = "fluxdown.desktop.settings.v2";
const defaultSettings: Settings = {
  outputDir: "",
  concurrency: 5,
  threadCount: 16,
  retryAttempts: 3,
  speedLimitMbps: 0,
  autoStart: true,
  refreshIntervalMs: 600,
  notifyOnFinish: true,
  clipboardMonitor: true,
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

const iconComponents: Record<IconName, LucideIcon> = {
  alert: AlertTriangle,
  "arrow-left": ArrowLeft,
  check: Check,
  clipboard: ClipboardPaste,
  clock: Clock3,
  copy: Copy,
  download: Download,
  "external-link": ExternalLink,
  folder: FolderOpen,
  gauge: Gauge,
  "hard-drive": HardDrive,
  info: Info,
  link: Link2,
  more: MoreVertical,
  pause: Pause,
  play: Play,
  plus: Plus,
  refresh: RefreshCw,
  search: Search,
  settings: Settings,
  share: Share2,
  timer: Timer,
  trash: Trash2,
  x: X,
  zap: Zap,
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
      concurrency: clampNumber(saved.concurrency, 1, 30, defaultSettings.concurrency),
      threadCount: clampNumber(saved.threadCount, 1, 32, defaultSettings.threadCount),
      retryAttempts: clampNumber(saved.retryAttempts, 0, 10, defaultSettings.retryAttempts),
      // 作者: long
      // 限速允许小数，读取旧配置时不能复用整数设置的四舍五入，否则 1.5 MiB/s 会被恢复成 2 MiB/s。
      speedLimitMbps: clampDecimal(
        saved.speedLimitMbps,
        0,
        10000,
        defaultSettings.speedLimitMbps,
      ),
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
      notifyOnFinish:
        typeof saved.notifyOnFinish === "boolean"
          ? saved.notifyOnFinish
          : defaultSettings.notifyOnFinish,
      clipboardMonitor:
        typeof saved.clipboardMonitor === "boolean"
          ? saved.clipboardMonitor
          : defaultSettings.clipboardMonitor,
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
  const parsed = typeof value === "string" && value.trim() === "" ? NaN : Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, Math.round(parsed)));
}

function clampDecimal(
  value: unknown,
  min: number,
  max: number,
  fallback: number,
) {
  const parsed =
    typeof value === "string" && value.trim() === ""
      ? NaN
      : Number(typeof value === "string" ? value.trim().replace(/,/g, ".") : value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

function parseDecimalSetting(value: string, min: number, max: number) {
  const normalized = value.trim().replace(/,/g, ".");
  if (!normalized) return 0;
  const parsed = Number(normalized);
  if (!Number.isFinite(parsed)) return null;
  return Math.min(max, Math.max(min, parsed));
}

function compareVersions(left: string, right: string): number {
  const toParts = (version: string) =>
    version
      .trim()
      .replace(/^v/i, "")
      .split(".")
      .map((part) => {
        const parsed = Number.parseInt(part.trim(), 10);
        return Number.isFinite(parsed) ? parsed : 0;
      });
  const leftParts = toParts(left);
  const rightParts = toParts(right);
  const length = Math.max(leftParts.length, rightParts.length);
  for (let index = 0; index < length; index += 1) {
    const l = leftParts[index] ?? 0;
    const r = rightParts[index] ?? 0;
    if (l !== r) return l - r;
  }
  return 0;
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

function taskEtaLabel(task: DownloadTask) {
  if (task.state !== "running") return "--";
  const speed = task.current_speed_bytes_per_second ?? 0;
  const remaining = (task.total_bytes ?? 0) - task.downloaded_bytes;
  if (speed <= 0 || remaining <= 0) return "--";
  const seconds = Math.ceil(remaining / speed);
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
  return `${Math.floor(seconds / 86400)}d ${Math.floor((seconds % 86400) / 3600)}h`;
}

function createBrowserPreviewTask(
  task: Omit<DownloadTask, "id" | "created_at_ms" | "updated_at_ms">,
): DownloadTask {
  // 作者: long
  // 浏览器预览没有后端生成任务标识和时间戳，只在用户提交事件中补齐，不能在组件渲染阶段产生不稳定值。
  const now = Date.now();
  return {
    ...task,
    id: `preview-${now}`,
    created_at_ms: now,
    updated_at_ms: now,
  };
}

function Icon({ name }: { name: IconName }) {
  const Component = iconComponents[name];
  return <Component aria-hidden="true" className={`uiIcon icon-${name}`} />;
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
  const fileNameEditedRef = useRef(false);
  const [expectedSha256, setExpectedSha256] = useState("");
  const [torrentFileIndices, setTorrentFileIndices] = useState("");
  const [outputDir, setOutputDir] = useState(settings.outputDir);
  const [activeTaskId, setActiveTaskId] = useState<string | null>(null);
  const [queueActive, setQueueActive] = useState(false);
  const [menuTaskId, setMenuTaskId] = useState<string | null>(null);
  const [propertyTask, setPropertyTask] = useState<DownloadTask | null>(null);
  const [action, setAction] = useState<TaskAction>("idle");
  const [updateDialogState, setUpdateDialogState] =
    useState<UpdateDialogState>("closed");
  const [updateReport, setUpdateReport] = useState<UpdateCheckReport | null>(
    null,
  );
  const [updateError, setUpdateError] = useState("");
  const [hlsVariants, setHlsVariants] = useState<HlsVariantInfo[]>([]);
  const [hlsVariantIndex, setHlsVariantIndex] = useState("");
  const [hlsKeepTs, setHlsKeepTs] = useState(false);
  const [taskSpeedLimit, setTaskSpeedLimit] = useState("");
  const [torrentFiles, setTorrentFiles] = useState<TorrentDetailsFile[]>([]);
  const [selectedTorrentFileIndices, setSelectedTorrentFileIndices] = useState<number[]>([]);
  const [torrentMetadataLoading, setTorrentMetadataLoading] = useState(false);
  const [torrentMetadataError, setTorrentMetadataError] = useState("");
  const [torrentDetailsTask, setTorrentDetailsTask] =
    useState<DownloadTask | null>(null);
  const [torrentDetails, setTorrentDetails] = useState<TorrentDetails | null>(
    null,
  );
  const [clipboardSuggestion, setClipboardSuggestion] = useState<string | null>(
    null,
  );
  const lastClipboardRef = useRef<string | null>(null);
  const clipboardSeenRef = useRef(false);
  const dismissedClipboardRef = useRef<Set<string>>(new Set());
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

  // 作者: long
  // 完成通知：对比上一轮任务状态，只有从进行中转为完成/失败的任务才通知，
  // 避免启动时对历史任务重复提醒；窗口隐藏（托盘驻留）时这是唯一的完成感知。
  const previousStatesRef = useRef<Map<string, DownloadState>>(new Map());

  const notifyFinishedTasks = useCallback(async (nextTasks: DownloadTask[]) => {
    const previous = previousStatesRef.current;
    const events: Array<{ title: string; body: string }> = [];
    for (const task of nextTasks) {
      const before = previous.get(task.id);
      previous.set(task.id, task.state);
      if (!before || before === task.state) continue;
      if (before !== "running" && before !== "queued") continue;
      const title = taskTitle(task);
      if (task.state === "finished") {
        events.push({ title: "下载完成", body: `${title} 已完成` });
      } else if (task.state === "failed") {
        events.push({
          title: "下载失败",
          body: `${title} 失败：${displayTaskError(task) || "未知错误"}`,
        });
      }
    }
    if (!events.length || !settings.notifyOnFinish) return;
    for (const event of events) {
      await invoke("send_notification", {
        title: event.title,
        body: event.body,
      }).catch(() => null);
    }
  }, [settings.notifyOnFinish]);

  const refreshTasks = useCallback(async () => {
    const result = await invoke<DownloadTask[]>("list_downloads").catch(
      () => null,
    );
    if (result) {
      setTasks(result);
      void notifyFinishedTasks(result);
    }
  }, [notifyFinishedTasks]);

  useEffect(() => {
    saveSettings(settings);
  }, [settings]);

  const runUpdateCheck = useCallback(async () => {
    setUpdateDialogState("checking");
    setUpdateError("");
    try {
      const report = await invoke<UpdateCheckReport>("check_update");
      setUpdateReport(report);
      const ignored = loadIgnoredUpdateVersion();
      // 作者: long
      // 用户对某个版本点过“忽略此版本”后，再次检查时不再按有更新打扰，按最新已忽略处理。
      const suppressed =
        ignored &&
        !compareVersions(report.latest_version, ignored);
      if (!report.has_update || suppressed) {
        setUpdateDialogState("upToDate");
      } else {
        setUpdateDialogState("available");
      }
    } catch (error) {
      setUpdateError(safeErrorText(error));
      setUpdateDialogState("error");
    }
  }, []);

  const closeUpdateDialog = useCallback(() => {
    if (updateDialogState === "downloading") return;
    setUpdateDialogState("closed");
    setUpdateError("");
  }, [updateDialogState]);

  const ignoreUpdateVersion = useCallback(() => {
    if (updateReport?.latest_version) {
      saveIgnoredUpdateVersion(updateReport.latest_version);
      setMessage(`已忽略 ${updateReport.latest_version}，此后检查更新不再提示该版本`);
    }
    setUpdateDialogState("closed");
  }, [updateReport]);

  const openDownloadPage = useCallback(async () => {
    try {
      await invoke("open_download_page");
    } catch (error) {
      setMessage(safeErrorText(error));
    }
  }, []);

  const startOnlineUpdate = useCallback(async () => {
    if (!updateReport?.download_url || !updateReport.download_file_name) return;
    setUpdateDialogState("downloading");
    setUpdateError("");
    try {
      await invoke("download_and_install_update", {
        url: updateReport.download_url,
        fileName: updateReport.download_file_name,
      });
      // 作者: long
      // Rust 端启动系统安装器后会延迟退出应用；这里只负责提示，不必等待。
      setUpdateDialogState("installReady");
    } catch (error) {
      setUpdateError(safeErrorText(error));
      setUpdateDialogState("error");
    }
  }, [updateReport]);

  function openTorrentDetails(task: DownloadTask) {
    setTorrentDetailsTask(task);
    setTorrentDetails(null);
  }

  function closeTorrentDetails() {
    setTorrentDetailsTask(null);
    setTorrentDetails(null);
  }

  const inspectedTorrent = tasks.find((task) => task.id === torrentDetailsTask?.id)
    ?? torrentDetailsTask;
  const inspectedTorrentId = inspectedTorrent?.id;
  const inspectedTorrentSource = inspectedTorrent?.source;
  const inspectedTorrentState = inspectedTorrent?.state;

  // 作者: long
  // 详情跟随队列当前状态刷新；关闭或切换任务后丢弃旧响应，防止慢请求覆盖新任务的文件进度。
  useEffect(() => {
    if (!inspectedTorrentId || !inspectedTorrentSource) return;
    let cancelled = false;
    let pending = false;
    let fileSamples = new Map<number, { bytes: number; at: number }>();
    const active = inspectedTorrentState === "running" || inspectedTorrentState === "queued";
    const refresh = async () => {
      if (pending) return;
      pending = true;
      try {
        const details = await invoke<TorrentDetails>("torrent_task_details", {
          taskId: active ? inspectedTorrentId : null,
          source: inspectedTorrentSource,
        });
        if (!cancelled) {
          // 作者: long
          // 文件速率只取同一活动会话两次已下载量的差值，不按文件大小分摊总速率；
          // 暂停、切换、重下或首次采样都重置基线，避免旧任务速度串入新快照。
          const at = performance.now();
          const nextSamples = new Map<number, { bytes: number; at: number }>();
          const files = details.files.map((file) => {
            const bytes = file.progress_bytes;
            const previous = fileSamples.get(file.index);
            let speed: number | null = null;
            if (active && details.runtime && bytes != null && Number.isFinite(bytes) && bytes >= 0) {
              if (previous && at > previous.at && bytes >= previous.bytes) {
                speed = (bytes - previous.bytes) * 1000 / (at - previous.at);
              }
              nextSamples.set(file.index, { bytes, at });
            }
            return { ...file, sampled_speed_bps: speed };
          });
          fileSamples = nextSamples;
          setTorrentDetails({ ...details, files });
        }
      } catch (error) {
        if (!cancelled) {
          fileSamples.clear();
          setTorrentDetails({ runtime: false, files: [], trackers: [], error: safeErrorText(error) });
        }
      } finally {
        pending = false;
      }
    };
    void refresh();
    const timer = active ? window.setInterval(() => void refresh(), 2000) : null;
    return () => {
      cancelled = true;
      if (timer != null) window.clearInterval(timer);
    };
  }, [inspectedTorrentId, inspectedTorrentSource, inspectedTorrentState]);

  useEffect(() => {
    queueMicrotask(() => void refreshTasks());
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
        // 作者: long
        // 浏览器预览没有 Tauri 后端，此处保留空路径，后续仍可用内存任务检查桌面布局和交互。
      });
    invoke<DoctorReport>("doctor")
      .then(setDoctorReport)
      .catch(() => setDoctorReport(null));
  }, [refreshTasks]);

  useEffect(() => {
    if (!queueActive && !tasks.some((task) => task.state === "running")) return;
    const timer = window.setInterval(refreshTasks, settings.refreshIntervalMs);
    return () => window.clearInterval(timer);
  }, [queueActive, refreshTasks, settings.refreshIntervalMs, tasks]);

  // 作者: long
  // 新建任务里输入 m3u8 源时，拉取 master playlist 的清晰度列表供用户选择；
  // 非 master（单一码流）或拉取失败时保持空列表，界面回退到默认行为。
  useEffect(() => {
    const normalizedSource = source.trim();
    const protocol = sourceSupport?.protocol ?? fallbackDetect(normalizedSource);
    if (!newDialogOpen || protocol !== "m3u8" || !normalizedSource) {
      return;
    }
    let cancelled = false;
    invoke<HlsVariantInfo[]>("list_hls_variants", { source: normalizedSource })
      .then((variants) => {
        if (!cancelled) setHlsVariants(variants);
      })
      .catch(() => {
        if (!cancelled) setHlsVariants([]);
      });
    return () => {
      cancelled = true;
    };
  }, [newDialogOpen, source, sourceSupport]);

  // 作者: long
  // 剪贴板监听：Rust 端读系统剪贴板（不受 WebView 权限限制），检测到新的
  // 可下载链接时显示提示条。首次读取只记录不提示，避免启动时弹旧链接。
  useEffect(() => {
    if (!settings.clipboardMonitor) {
      return;
    }
    let cancelled = false;
    let inFlight = false;
    const tick = async () => {
      if (cancelled || inFlight) return;
      inFlight = true;
      try {
        const text = await invoke<string | null>("read_clipboard_text");
        const normalized = (text ?? "").trim();
        if (!normalized) return;
        const seen = lastClipboardRef.current;
        lastClipboardRef.current = normalized;
        if (!clipboardSeenRef.current) {
          clipboardSeenRef.current = true;
          return;
        }
        if (normalized === seen || dismissedClipboardRef.current.has(normalized)) {
          return;
        }
        const protocol = sourceSupport
          ? (sourceSupport.protocol ?? fallbackDetect(normalized))
          : fallbackDetect(normalized);
        if (supportedNow.has(protocol)) {
          setClipboardSuggestion(normalized);
        }
      } catch {
        // 剪贴板不可用（无后端/被占用）时静默跳过本轮。
      } finally {
        inFlight = false;
      }
    };
    const timer = window.setInterval(() => void tick(), 1500);
    void tick();
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [settings.clipboardMonitor, sourceSupport]);

  function acceptClipboardSuggestion() {
    if (!clipboardSuggestion) return;
    updateNewTaskSource(clipboardSuggestion);
    setClipboardSuggestion(null);
    openNewDialog();
  }

  function dismissClipboardSuggestion() {
    if (clipboardSuggestion) {
      dismissedClipboardRef.current.add(clipboardSuggestion);
    }
    setClipboardSuggestion(null);
  }

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

  useEffect(() => {
    const normalizedSource = source.trim();
    const protocol = sourceSupport?.protocol ?? fallbackDetect(normalizedSource);
    const isTorrentLike = protocol === "torrent" || protocol === "magnet";
    if (!newDialogOpen || !isTorrentLike || !normalizedSource) {
      return;
    }

    let cancelled = false;
    const timer = window.setTimeout(() => {
      setTorrentMetadataLoading(true);
      setTorrentMetadataError("");
      invoke<TorrentDetails>("torrent_task_details", {
        taskId: null,
        source: normalizedSource,
      })
        .then((details) => {
          if (cancelled) return;
          if (details.files.length === 0) {
            setTorrentFiles([]);
            setSelectedTorrentFileIndices([]);
            setTorrentMetadataError(details.error || "暂未获取到文件列表，请检查 tracker 或网络");
            return;
          }
          const indices = details.files.map((file) => file.index);
          setTorrentFiles(details.files);
          setSelectedTorrentFileIndices(indices);
          setTorrentFileIndices(indices.join(","));
          if (!fileNameEditedRef.current && details.name) setFileName(details.name);
          setTorrentMetadataError("");
        })
        .catch((error) => {
          if (!cancelled) {
            setTorrentFiles([]);
            setSelectedTorrentFileIndices([]);
            setTorrentMetadataError(safeErrorText(error));
          }
        })
        .finally(() => {
          if (!cancelled) setTorrentMetadataLoading(false);
        });
    }, 260);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [newDialogOpen, source, sourceSupport?.protocol]);

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
    if (patch.clipboardMonitor === false) setClipboardSuggestion(null);
    setSettings((current) => ({ ...current, ...patch }));
  }

  async function pickDirectory(initialPath: string) {
    try {
      const selected = await openNativeDialog({
        directory: true,
        multiple: false,
        title: "选择下载保存位置",
        defaultPath: initialPath.trim() || undefined,
      });
      return typeof selected === "string" ? selected : null;
    } catch (error) {
      setMessage(safeErrorText(error));
      return null;
    }
  }

  async function pickSettingsOutputDir() {
    const selected = await pickDirectory(settings.outputDir);
    if (!selected) return;
    updateSettings({ outputDir: selected });
    setOutputDir(selected);
    setMessage("默认保存位置已更新");
  }

  async function pickNewTaskOutputDir() {
    const selected = await pickDirectory(outputDir || settings.outputDir);
    if (selected) setOutputDir(selected);
  }

  async function createTask() {
    const normalizedSource = source.trim();
    if (!normalizedSource) {
      setMessage("下载链接不能为空");
      return;
    }
    if (torrentMetadataLoading) {
      setMessage("正在解析 Torrent 文件列表");
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
    // 作者: long
    // 旧队列用空编号表示下载全部；文件树显式取消全选时必须阻止提交，不能反向变成全量下载。
    if (torrentFiles.length > 0 && selectedTorrentFileIndices.length === 0) {
      setMessage("Torrent 至少选择一个文件");
      return;
    }
    const parsedSpeedLimit = Number.parseFloat(taskSpeedLimit.trim());
    const speedLimitMbps =
      taskSpeedLimit.trim() && Number.isFinite(parsedSpeedLimit) && parsedSpeedLimit > 0
        ? parsedSpeedLimit
        : null;
    const parsedVariantIndex = Number.parseInt(hlsVariantIndex.trim(), 10);
    const variantIndex =
      hlsVariantIndex.trim() && Number.isFinite(parsedVariantIndex)
        ? parsedVariantIndex
        : null;
    let task: DownloadTask;
    try {
      task = await invoke<DownloadTask>("enqueue_download", {
        payload: {
          source: normalizedSource,
          output_dir: normalizedOutput,
          file_name: fileName.trim() || null,
          expected_sha256: normalizedSha256,
          torrent_file_indices: selectedTorrentFiles,
          speed_limit_mbps: speedLimitMbps,
          hls_variant_index: variantIndex,
          hls_keep_transport_stream: hlsKeepTs || null,
        },
      });
    } catch (error) {
      if (!isMissingTauriBackendError(error)) {
        setMessage(safeErrorText(error));
        return;
      }
      // 作者: long
      // 只有浏览器预览没有 Tauri 后端时才创建内存任务；桌面入队失败必须保留真实错误，避免把权限问题伪装成成功。
      const protocol = fallbackDetect(normalizedSource);
      task = createBrowserPreviewTask({
        source: normalizedSource,
        protocol,
        support: fallbackSupport(normalizedSource),
        state: "queued",
        output_dir: normalizedOutput,
        file_name: fileName.trim() || suggestedFileName(normalizedSource),
        expected_sha256: normalizedSha256,
        torrent_file_indices: selectedTorrentFiles,
        speed_limit_mbps: speedLimitMbps,
        hls_variant_index: variantIndex,
        hls_keep_transport_stream: hlsKeepTs,
        total_bytes: null,
        downloaded_bytes: 0,
      });
    }

    setTasks((current) => [task, ...current.filter((item) => item.id !== task.id)]);
    setNewDialogOpen(false);
    updateNewTaskSource("");
    setFileName("");
    fileNameEditedRef.current = false;
    setExpectedSha256("");
    setTorrentFileIndices("");
    setOutputDir(settings.outputDir);
    setTaskSpeedLimit("");
    setHlsVariantIndex("");
    setHlsKeepTs(false);
    setHlsVariants([]);
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

  async function openTorrentFile(task: DownloadTask, fileIndex: number) {
    try {
      await invoke("open_torrent_file", { id: task.id, fileIndex });
      setMessage("已打开 Torrent 文件");
    } catch (error) {
      setMessage(safeErrorText(error));
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
    setHlsVariants([]);
    setTorrentFiles([]);
    setSelectedTorrentFileIndices([]);
    const protocol = fallbackDetect(source.trim());
    setTorrentMetadataLoading(protocol === "torrent" || protocol === "magnet");
    setTorrentMetadataError("");
    fileNameEditedRef.current = false;
    setNewDialogOpen(true);
  }

  function closeNewDialog() {
    setNewDialogOpen(false);
    setSourceSupport(null);
    setHlsVariants([]);
    setTorrentFiles([]);
    setSelectedTorrentFileIndices([]);
    setTorrentMetadataLoading(false);
    setTorrentMetadataError("");
    fileNameEditedRef.current = false;
  }

  function updateNewTaskSource(value: string) {
    const normalizedSource = value.trim();
    const detectedProtocol = normalizedSource ? fallbackDetect(normalizedSource) : null;
    setSource(value);
    setSourceSupport(normalizedSource ? fallbackSupport(normalizedSource) : null);
    setHlsVariants([]);
    setTorrentFiles([]);
    setSelectedTorrentFileIndices([]);
    setTorrentFileIndices("");
    setTorrentMetadataLoading(detectedProtocol === "torrent" || detectedProtocol === "magnet");
    setTorrentMetadataError("");
    if (!fileNameEditedRef.current) setFileName(normalizedSource ? suggestedFileName(value) : "");
  }

  function toggleTorrentFile(index: number) {
    const next = selectedTorrentFileIndices.includes(index)
      ? selectedTorrentFileIndices.filter((item) => item !== index)
      : [...selectedTorrentFileIndices, index].sort((left, right) => left - right);
    setSelectedTorrentFileIndices(next);
    setTorrentFileIndices(next.join(","));
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
                  <img alt="" src={appMark} />
                </span>
                <div>
                  <strong>FluxDown</strong>
                  <span>传输控制台</span>
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
              <small>HTTP、M3U8、BT、SFTP、SMB 等后端可用性</small>
              <div className="protocolMeter">
                <span />
              </div>
              <div className="protocolChips">
                <span>HTTP</span>
                <span>M3U8</span>
                <span>BT</span>
                <span>SFTP</span>
                <span>SMB</span>
              </div>
            </div>
          </aside>

          <section className="workspace">
            <header className="workspaceHeader">
              <div className="titleBlock">
                <span className="pageEyebrow">传输中心</span>
                <h1>下载任务</h1>
                <p aria-live="polite" className="systemMessage">
                  <i aria-hidden="true" />
                  {message}
                </p>
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
                  <Icon name="plus" />
                  新建
                </button>
                <button
                  aria-label="从剪切板新建任务"
                  className="iconButton"
                  data-action="paste-link"
                  data-testid="paste-link-button"
                  onClick={openPasteDialog}
                  title="从剪切板新建任务"
                >
                  <Icon name="clipboard" />
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
                    aria-label="刷新列表"
                    data-action="refresh"
                    data-testid="refresh-button"
                    title="刷新列表"
                    onClick={refreshTasksWithMessage}
                  >
                    <Icon name="refresh" />
                  </button>
                  <button
                    aria-label="检查更新"
                    data-action="check-update"
                    data-testid="check-update-button"
                    title="检查更新"
                    onClick={runUpdateCheck}
                  >
                    <Icon name="download" />
                  </button>
                  <button
                    aria-label="打开设置"
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

            {clipboardSuggestion ? (
              <div className="clipboardSuggestion" data-testid="clipboard-suggestion">
                <Icon name="clipboard" />
                <span className="clipboardSuggestionText">
                  检测到下载链接：
                  <strong>{clipboardSuggestion}</strong>
                </span>
                <button
                  className="actionButton primary"
                  data-testid="clipboard-suggestion-accept"
                  onClick={acceptClipboardSuggestion}
                >
                  新建任务
                </button>
                <button
                  className="iconButton"
                  aria-label="忽略此剪贴板链接"
                  data-testid="clipboard-suggestion-dismiss"
                  title="忽略"
                  onClick={dismissClipboardSuggestion}
                >
                  <Icon name="x" />
                </button>
              </div>
            ) : null}

            <section className="contentView queueView">
              <div className="insights">
                <div className="metric accent">
                  <span><Icon name="gauge" />实时速度</span>
                  <strong>{formatBytes(totalCurrentSpeed)}/s</strong>
                  <small>{runningTasks.length} 个下载中</small>
                </div>
                <div className="metric">
                  <span><Icon name="hard-drive" />已完成数据</span>
                  <strong>{formatBytes(completedBytes)}</strong>
                  <small>{counts.finished} 个任务完成</small>
                </div>
                <div className="metric">
                  <span><Icon name="zap" />队列并发</span>
                  <strong>
                    {runningTasks.length} / {settings.concurrency}
                  </strong>
                  <small>{settings.autoStart ? "自动接续" : "手动启动"}</small>
                </div>
                <div className="metric">
                  <span><Icon name="timer" />剩余时间</span>
                  <strong>{formatRemainingTime(tasks)}</strong>
                  <small>动态估算</small>
                </div>
              </div>

              <DownloadList
                activeTaskId={activeTaskId}
                action={action}
                filter={filter}
                menuTaskId={menuTaskId}
                onMenu={setMenuTaskId}
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
            onPickOutputDir={pickSettingsOutputDir}
            onRefreshDoctor={refreshDoctorReport}
            settings={settings}
          />
      )}

      {newDialogOpen ? (
          <NewTaskDialog
          expectedSha256={expectedSha256}
          fileName={fileName}
          hlsVariants={hlsVariants}
          hlsVariantIndex={hlsVariantIndex}
          hlsKeepTs={hlsKeepTs}
          selectedTorrentFileIndices={selectedTorrentFileIndices}
          taskSpeedLimit={taskSpeedLimit}
          torrentFiles={torrentFiles}
          torrentMetadataError={torrentMetadataError}
          torrentMetadataLoading={torrentMetadataLoading}
          onClose={closeNewDialog}
          onCreate={createTask}
          onExpectedSha256Change={setExpectedSha256}
          onFileNameChange={(value) => {
            // 作者: long
            // 手工命名只阻止 metadata 覆盖名称，不重新解析链接或重置用户已经勾选的文件。
            fileNameEditedRef.current = true;
            setFileName(value);
          }}
          onHlsKeepTsChange={setHlsKeepTs}
          onHlsVariantIndexChange={setHlsVariantIndex}
          onOutputDirChange={setOutputDir}
          onPickOutputDir={pickNewTaskOutputDir}
          onPaste={pasteFromClipboard}
          onSourceChange={updateNewTaskSource}
          onTaskSpeedLimitChange={setTaskSpeedLimit}
          onTorrentFileIndicesChange={setTorrentFileIndices}
          onToggleTorrentFile={toggleTorrentFile}
          outputDir={outputDir}
          source={source}
          support={sourceSupport}
          torrentFileIndices={torrentFileIndices}
        />
      ) : null}

      {torrentDetailsTask ? (
        <TorrentDetailsDialog
          details={torrentDetails}
          onOpenFile={(fileIndex) => {
            if (inspectedTorrent) void openTorrentFile(inspectedTorrent, fileIndex);
          }}
          onClose={closeTorrentDetails}
          task={inspectedTorrent ?? torrentDetailsTask}
        />
      ) : null}

      {updateDialogState !== "closed" ? (
        <UpdateDialog
          dialogState={updateDialogState}
          errorText={updateError}
          onClose={closeUpdateDialog}
          onIgnore={ignoreUpdateVersion}
          onOpenDownloadPage={openDownloadPage}
          onRetry={runUpdateCheck}
          onStartUpdate={startOnlineUpdate}
          report={updateReport}
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
          onDetails={() => {
            setMenuTaskId(null);
            openTorrentDetails(currentMenuTask);
          }}
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
        <span aria-hidden="true" />
      </div>
      <div className="taskList" data-testid="task-list">
        {tasks.length === 0 ? (
          <div className="emptyNote">
            <span className="emptyGlyph" aria-hidden="true">
              <Icon name="download" />
            </span>
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
  onToggle,
  task,
}: {
  action: TaskAction;
  menuOpen: boolean;
  onMenu: (id: string | null) => void;
  onToggle: (task: DownloadTask) => void;
  task: DownloadTask;
}) {
  const progress = progressRatio(task);
  const width = `${Math.round(progress * 100)}%`;
  const longPressTimerRef = useRef<number | null>(null);
  const longPressTriggeredRef = useRef(false);

  function cancelLongPress() {
    if (longPressTimerRef.current !== null) {
      window.clearTimeout(longPressTimerRef.current);
      longPressTimerRef.current = null;
    }
  }

  function startLongPress(event: React.PointerEvent<HTMLElement>) {
    if (event.button !== 0 || (event.target as HTMLElement).closest("button")) return;
    longPressTriggeredRef.current = false;
    cancelLongPress();
    // 作者: long
    // 触控板和触摸屏长按沿用移动端任务菜单，普通桌面鼠标仍可使用右键或三点按钮。
    longPressTimerRef.current = window.setTimeout(() => {
      longPressTriggeredRef.current = true;
      onMenu(task.id);
    }, 520);
  }

  function handleRowClick(event: React.MouseEvent<HTMLElement>) {
    if ((event.target as HTMLElement).closest("button")) return;
    if (longPressTriggeredRef.current) {
      longPressTriggeredRef.current = false;
      return;
    }
    onToggle(task);
  }

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
      aria-label={`${taskActionTitle(task)}：${taskTitle(task)}`}
      onClick={handleRowClick}
      onContextMenu={(event) => {
        event.preventDefault();
        cancelLongPress();
        onMenu(task.id);
      }}
      onKeyDown={(event) => {
        if (event.target !== event.currentTarget) return;
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onToggle(task);
        }
      }}
      onPointerCancel={cancelLongPress}
      onPointerDown={startLongPress}
      onPointerLeave={cancelLongPress}
      onPointerUp={cancelLongPress}
      style={{ "--value": width } as CSSProperties}
      tabIndex={0}
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
        <small>
          {formatTaskProgress(task)}
          {taskEtaLabel(task) !== "--" ? ` · 剩余 ${taskEtaLabel(task)}` : ""}
        </small>
      </div>
      <span className="speedCell">{taskSpeedLabel(task)}</span>
      <div className="rowActions">
        <button
          aria-label="更多任务操作"
          aria-pressed={menuOpen}
          data-testid="task-more-button"
          onClick={(event) => {
            event.stopPropagation();
            onMenu(menuOpen ? null : task.id);
          }}
          onPointerDown={(event) => event.stopPropagation()}
          title="更多任务操作"
        >
          <Icon name="more" />
        </button>
      </div>
      {action === "start" ? <span className="busyDot" /> : null}
    </article>
  );
}

function TorrentFileProgressRow({
  file,
  onOpen,
  speedBps,
  canOpen,
}: {
  file: TorrentDetailsFile;
  onOpen: (fileIndex: number) => void;
  speedBps?: number | null;
  canOpen: boolean;
}) {
  const size = Number.isFinite(file.size) ? Math.max(0, file.size) : 0;
  const downloaded = file.progress_bytes != null && Number.isFinite(file.progress_bytes)
    ? Math.min(size, Math.max(0, file.progress_bytes))
    : null;
  // 作者: long
  // 静态种子没有下载进度，不能冒充 0% 或完成；只有引擎返回已下载量时才显示确定进度。
  const percent = downloaded == null ? null : size === 0 ? 100 : downloaded / size * 100;
  const fileReady = canOpen;
  return (
    <div className="torrentFileRow torrentTransferRow" data-file-index={file.index}>
      <span className="torrentFileIndex">#{file.index}</span>
      <div className="torrentFileContent">
        <span className="torrentFilePath" title={file.path}>{file.path || "-"}</span>
        <div className="torrentFileMetrics">
          <span>{downloaded == null ? "--" : formatBytes(downloaded)} / {formatBytes(size)}</span>
          <span>{percent == null ? "进度未知" : `${percent.toFixed(1)}%`}</span>
          <span>{speedBps != null ? `${formatBytes(speedBps)}/s` : "速度未知"}</span>
        </div>
        <div
          className="torrentFileProgress"
          role="progressbar"
          aria-label={`${file.path || `文件 ${file.index}`} 下载进度`}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={percent ?? undefined}
          aria-valuetext={percent == null ? "进度未知" : `${percent.toFixed(1)}%`}
        >
          <span style={{ width: `${percent ?? 0}%` }} />
        </div>
      </div>
      <button
        aria-label={`打开 ${file.path || `文件 ${file.index}`}`}
        className="torrentFileOpen"
        disabled={!fileReady}
        onClick={(event) => {
          event.stopPropagation();
          onOpen(file.index);
        }}
        title={fileReady ? "打开文件" : "文件完成后可打开"}
      >
        <Icon name="external-link" />
      </button>
    </div>
  );
}

function TorrentDetailsDialog({
  details,
  onOpenFile,
  onClose,
  task,
}: {
  details: TorrentDetails | null;
  onOpenFile: (fileIndex: number) => void;
  onClose: () => void;
  task: DownloadTask;
}) {
  const selectedTorrentFileIndices = task.torrent_file_indices ?? [];

  return (
    <div
      className="modalBackdrop"
      data-testid="torrent-details-backdrop"
      onMouseDown={onClose}
    >
      <section
        className="taskDialog torrentDetailsDialog"
        data-testid="torrent-details-dialog"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="dialogHeader">
          <div>
            <span className="dialogMark"><Icon name="download" /></span>
            <h2>Torrent 详情</h2>
          </div>
          <div className="dialogTools">
            <button aria-label="关闭" data-testid="torrent-details-close" onClick={onClose}>
              <Icon name="x" />
            </button>
          </div>
        </header>

        {details ? (
          <div className="torrentDetailsBody" data-testid="torrent-details-body">
            <p className="updateStatus">
              {details.runtime ? (
                <>
                  运行中快照 ·{" "}
                  <strong>
                    {formatBytes(details.download_speed_bps)}/s ↓{" "}
                    {formatBytes(details.upload_speed_bps)}/s ↑
                  </strong>
                  {details.eta_seconds ? ` · 剩余 ${details.eta_seconds}s` : ""}
                </>
              ) : (
                <strong>静态解析（任务未在运行，无实时速率）</strong>
              )}
            </p>
            {details.error ? (
              <p className="updateStatus failed">{details.error}</p>
            ) : null}
            <dl className="detailGrid">
              <div>
                <dt>名称</dt>
                <dd>{details.name ?? taskTitle(task)}</dd>
              </div>
              <div>
                <dt>大小</dt>
                <dd>{details.total_bytes ? formatBytes(details.total_bytes) : "--"}</dd>
              </div>
              <div>
                <dt>已完成</dt>
                <dd>{details.progress_bytes != null ? formatBytes(details.progress_bytes) : "--"}</dd>
              </div>
              <div>
                <dt>已上传</dt>
                <dd>{details.uploaded_bytes != null ? formatBytes(details.uploaded_bytes) : "--"}</dd>
              </div>
              {details.peers ? (
                <div>
                  <dt>Peer</dt>
                  <dd>
                    活跃 {details.peers.live} · 连接中 {details.peers.connecting} · 排队{" "}
                    {details.peers.queued} · 发现 {details.peers.seen}
                  </dd>
                </div>
              ) : null}
            </dl>
            {details.files.length > 0 ? (
              <div className="updateNotesBlock">
                <span>文件列表（{details.files.length}）</span>
                <div className="torrentFileList" data-testid="torrent-files">
                  {details.files.map((file) => (
                    <TorrentFileProgressRow
                      canOpen={(selectedTorrentFileIndices.length === 0
                        || selectedTorrentFileIndices.includes(file.index))
                        && (task.state === "finished"
                          || (file.progress_bytes != null && file.progress_bytes >= file.size))}
                      file={file}
                      key={file.index}
                      onOpen={onOpenFile}
                      speedBps={file.sampled_speed_bps}
                    />
                  ))}
                </div>
              </div>
            ) : null}
            {details.trackers.length > 0 ? (
              <div className="updateNotesBlock">
                <span>Tracker（{details.trackers.length}）</span>
                <div className="torrentFileList" data-testid="torrent-trackers">
                  {details.trackers.map((tracker) => (
                    <div className="torrentFileRow" key={tracker}>
                      <span className="torrentFilePath">{tracker}</span>
                    </div>
                  ))}
                </div>
              </div>
            ) : null}
          </div>
        ) : (
          <p className="updateStatus" data-testid="torrent-details-loading">
            正在读取种子详情…
          </p>
        )}

        <footer className="dialogFooter">
          <button data-testid="torrent-details-close-footer" onClick={onClose}>
            关闭
          </button>
        </footer>
      </section>
    </div>
  );
}

function UpdateDialog({
  dialogState,
  errorText,
  onClose,
  onIgnore,
  onOpenDownloadPage,
  onRetry,
  onStartUpdate,
  report,
}: {
  dialogState: UpdateDialogState;
  errorText: string;
  onClose: () => void;
  onIgnore: () => void;
  onOpenDownloadPage: () => void;
  onRetry: () => void;
  onStartUpdate: () => void;
  report: UpdateCheckReport | null;
}) {
  const busy = dialogState === "checking" || dialogState === "downloading";
  const currentVersion = report?.current_version ?? "";
  const latestVersion = report?.latest_version ?? "";

  return (
    <div
      className="modalBackdrop"
      data-testid="update-backdrop"
      onMouseDown={busy ? undefined : onClose}
    >
      <section
        className="taskDialog updateDialog"
        data-testid="update-dialog"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="dialogHeader">
          <div>
            <span className="dialogMark"><Icon name="download" /></span>
            <h2>检查更新</h2>
          </div>
          <div className="dialogTools">
            <button
              aria-label="关闭"
              data-testid="update-header-close"
              disabled={busy}
              title="关闭"
              onClick={onClose}
            >
              <Icon name="x" />
            </button>
          </div>
        </header>

        {dialogState === "checking" ? (
          <p className="updateStatus" data-testid="update-checking">
            正在检查更新…
          </p>
        ) : null}

        {dialogState === "upToDate" && report ? (
          <div data-testid="update-up-to-date">
            <p className="updateStatus ready">
              当前已是最新版本 v{currentVersion}
            </p>
          </div>
        ) : null}

        {dialogState === "available" && report ? (
          <div data-testid="update-available">
            <p className="updateStatus">
              当前版本为 <strong>v{currentVersion}</strong>，最新版本为{" "}
              <strong>v{latestVersion}</strong>
            </p>
            <div className="updateNotesBlock">
              <span>更新内容</span>
              <pre className="updateNotes" data-testid="update-notes">
                {report.release_notes?.trim() || "暂无更新说明"}
              </pre>
            </div>
          </div>
        ) : null}

        {dialogState === "downloading" ? (
          <p className="updateStatus" data-testid="update-downloading">
            正在下载更新包…完成后将自动启动安装器并退出应用
          </p>
        ) : null}

        {dialogState === "installReady" && report ? (
          <p className="updateStatus ready" data-testid="update-install-ready">
            安装器已启动（{report.download_file_name ?? "更新包"}），应用即将退出以完成更新。
          </p>
        ) : null}

        {dialogState === "error" ? (
          <p className="updateStatus failed" data-testid="update-error">
            {errorText || "检查更新失败，请稍后重试"}
          </p>
        ) : null}

        <footer className="dialogFooter">
          <button data-testid="update-close" disabled={busy} onClick={onClose}>
            关闭
          </button>
          {dialogState === "available" ? (
            <button data-testid="update-ignore" onClick={onIgnore}>
              忽略此版本
            </button>
          ) : null}
          {dialogState === "available" ? (
            <button data-testid="update-open-page" onClick={onOpenDownloadPage}>
              打开下载页
            </button>
          ) : null}
          {dialogState === "available" ? (
            <button
              className="primary"
              data-testid="update-install"
              disabled={!report?.download_url}
              title={
                report?.download_url
                  ? "下载最新安装包并启动安装"
                  : "当前平台没有可用的自动更新安装包，请使用“打开下载页”"
              }
              onClick={onStartUpdate}
            >
              在线更新
            </button>
          ) : null}
          {dialogState === "error" ? (
            <button className="primary" data-testid="update-retry" onClick={onRetry}>
              重试
            </button>
          ) : null}
        </footer>
      </section>
    </div>
  );
}

function NewTaskDialog({
  expectedSha256,
  fileName,
  hlsVariants,
  hlsVariantIndex,
  hlsKeepTs,
  selectedTorrentFileIndices,
  taskSpeedLimit,
  torrentFiles,
  torrentMetadataError,
  torrentMetadataLoading,
  onClose,
  onCreate,
  onExpectedSha256Change,
  onFileNameChange,
  onHlsKeepTsChange,
  onHlsVariantIndexChange,
  onOutputDirChange,
  onPickOutputDir,
  onPaste,
  onSourceChange,
  onTaskSpeedLimitChange,
  onTorrentFileIndicesChange,
  onToggleTorrentFile,
  outputDir,
  source,
  support,
  torrentFileIndices,
}: {
  expectedSha256: string;
  fileName: string;
  hlsVariants: HlsVariantInfo[];
  hlsVariantIndex: string;
  hlsKeepTs: boolean;
  selectedTorrentFileIndices: number[];
  taskSpeedLimit: string;
  torrentFiles: TorrentDetailsFile[];
  torrentMetadataError: string;
  torrentMetadataLoading: boolean;
  onClose: () => void;
  onCreate: () => void;
  onExpectedSha256Change: (value: string) => void;
  onFileNameChange: (value: string) => void;
  onHlsKeepTsChange: (value: boolean) => void;
  onHlsVariantIndexChange: (value: string) => void;
  onOutputDirChange: (value: string) => void;
  onPickOutputDir: () => void;
  onPaste: () => void;
  onSourceChange: (value: string) => void;
  onTaskSpeedLimitChange: (value: string) => void;
  onTorrentFileIndicesChange: (value: string) => void;
  onToggleTorrentFile: (index: number) => void;
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
            <span className="dialogMark"><Icon name="plus" /></span>
            <h2>新建任务</h2>
          </div>
          <div className="dialogTools">
            <button aria-label="从剪切板读取" data-testid="new-task-paste" title="从剪切板读取" onClick={onPaste}>
              <Icon name="clipboard" />
            </button>
            <button aria-label="关闭" data-testid="new-task-close" title="关闭" onClick={onClose}>
              <Icon name="x" />
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
          <div className="pathInputGroup">
            <input
              data-testid="new-task-output-dir"
              onChange={(event) => onOutputDirChange(event.target.value)}
              value={outputDir}
            />
            <button
              aria-label="选择保存目录"
              data-testid="new-task-pick-output-dir"
              onClick={onPickOutputDir}
              title="选择保存目录"
              type="button"
            >
              <Icon name="folder" />
            </button>
          </div>
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
          <div className="fieldBlock torrentSelectionBlock">
            <div className="fieldLabelRow">
              <span>选择下载文件</span>
              {torrentFiles.length > 0 ? (
                <small>{selectedTorrentFileIndices.length} / {torrentFiles.length}</small>
              ) : null}
            </div>
            {torrentMetadataLoading ? (
              <div className="torrentMetadataState" data-testid="torrent-metadata-loading">正在获取文件列表…</div>
            ) : torrentFiles.length > 0 ? (
              <div className="torrentSelectionList" data-testid="new-task-torrent-files">
                {torrentFiles.map((file) => (
                  <label className="torrentSelectionRow" key={file.index}>
                    <input
                      checked={selectedTorrentFileIndices.includes(file.index)}
                      data-testid={`new-task-torrent-file-${file.index}`}
                      onChange={() => onToggleTorrentFile(file.index)}
                      type="checkbox"
                    />
                    <span className="torrentSelectionPath" title={file.path}>{file.path}</span>
                    <span className="torrentSelectionSize">{formatBytes(file.size)}</span>
                  </label>
                ))}
              </div>
            ) : (
              <>
                <div className="torrentMetadataState warning" data-testid="torrent-metadata-error">
                  {torrentMetadataError || "暂未获取到 metadata，可先创建任务，运行后再查看文件列表。"}
                </div>
                <label className="torrentIndexFallback">
                  <span>文件编号（可选）</span>
                  <input
                    data-testid="new-task-torrent-indices"
                    onChange={(event) => onTorrentFileIndicesChange(event.target.value)}
                    placeholder="如 0,2；留空下载全部文件"
                    value={torrentFileIndices}
                  />
                </label>
              </>
            )}
          </div>
        ) : null}
        {protocol === "m3u8" && hlsVariants.length > 0 ? (
          <label className="fieldBlock">
            <span>清晰度（HLS variant）</span>
            <select
              data-testid="new-task-hls-variant"
              onChange={(event) => onHlsVariantIndexChange(event.target.value)}
              value={hlsVariantIndex}
            >
              <option value="">默认（第一个 variant）</option>
              {hlsVariants.map((variant) => (
                <option key={variant.index} value={String(variant.index)}>
                  #{variant.index}
                  {variant.resolution ? ` · ${variant.resolution}` : ""}
                  {` · ${Math.round(variant.bandwidth / 1000)} kbps`}
                  {variant.codecs ? ` · ${variant.codecs}` : ""}
                </option>
              ))}
            </select>
          </label>
        ) : null}
        {protocol === "m3u8" ? (
          <label className="fieldBlock inline">
            <input
              checked={hlsKeepTs}
              data-testid="new-task-hls-keep-ts"
              onChange={(event) => onHlsKeepTsChange(event.target.checked)}
              type="checkbox"
            />
            <span>保留 TS 原始流（不转封装为 MP4）</span>
          </label>
        ) : null}
        <label className="fieldBlock">
          <span>任务限速（MiB/s，留空跟随全局设置）</span>
          <input
            data-testid="new-task-speed-limit"
            inputMode="decimal"
            onChange={(event) => onTaskSpeedLimitChange(event.target.value)}
            placeholder="例如 2.5"
            value={taskSpeedLimit}
          />
        </label>
        <footer className="dialogFooter">
          <button data-testid="new-task-cancel" onClick={onClose}>取消</button>
          <button className="primary" data-testid="new-task-create" disabled={isTorrentLike && torrentMetadataLoading} onClick={onCreate}>
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
  onDetails,
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
  onDetails: () => void;
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
          <button aria-label="关闭" onClick={onClose}><Icon name="x" /></button>
        </header>
        <button onClick={onCopyLink}><Icon name="link" />复制下载链接</button>
        <button onClick={onCopyPath}><Icon name="copy" />复制文件路径</button>
        <button onClick={onOpen}><Icon name="external-link" />打开</button>
        <button onClick={onReveal}><Icon name="folder" />在文件夹中显示</button>
        <button onClick={onShare}><Icon name="share" />分享</button>
        {task.protocol === "torrent" || task.protocol === "magnet" ? (
          <button onClick={onDetails} data-testid="task-details-button">
            <Icon name="download" />详情
          </button>
        ) : null}
        <button onClick={onProperties}><Icon name="info" />属性</button>
        <button onClick={onRedownload}><Icon name="refresh" />重新下载</button>
        <button className="danger" onClick={onRemove}>
          <Icon name="trash" />删除
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
          <button aria-label="关闭" title="关闭" onClick={onClose}>
            <Icon name="x" />
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
  onPickOutputDir,
  onRefreshDoctor,
  settings,
}: {
  doctorReport: DoctorReport | null;
  onBack: () => void;
  onChange: (patch: Partial<Settings>) => void;
  onPickOutputDir: () => void;
  onRefreshDoctor: () => Promise<boolean>;
  settings: Settings;
}) {
  const [section, setSection] = useState<SettingsSection>("general");
  const speedLimitInputRef = useRef<HTMLInputElement>(null);
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

  function commitSpeedLimit() {
    const input = speedLimitInputRef.current;
    if (!input) return;
    const parsed = parseDecimalSetting(input.value, 0, 10000);
    if (parsed === null) {
      input.value = settings.speedLimitMbps > 0 ? String(settings.speedLimitMbps) : "";
      return;
    }
    input.value = parsed > 0 ? String(parsed) : "";
    updateSetting({ speedLimitMbps: parsed }, "最大下载网速");
  }

  async function runDoctorCheck() {
    const refreshed = await onRefreshDoctor();
    setNotice(refreshed ? "后端自检已更新" : "Web 预览模式无法调用桌面后端自检");
  }

  return (
    <main className="settingsShell" data-testid="settings-page">
      <aside className="settingsSidebar">
        <div className="brand settingsBrand">
          <span className="brandMark" aria-label="FluxDown">
            <img alt="" src={appMark} />
          </span>
          <div>
            <strong>FluxDown</strong>
            <span>偏好设置</span>
          </div>
        </div>

        <div className="settingsTitleBlock">
          <h1>设置</h1>
          <p>下载策略与本机能力</p>
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
            {availableBackendCount} / {backends.length} 个后端可用，修改后实时生效并自动保存。
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
            <button
              aria-label="返回任务"
              className="iconButton"
              data-testid="settings-detail-back-button"
              onClick={onBack}
              title="返回任务"
            >
              <Icon name="arrow-left" />
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
              aria-label="保存设置"
              className="iconButton primary"
              data-action="save-settings"
              data-testid="settings-save-button"
              onClick={saveCurrentSettings}
              title="保存设置"
            >
              <Icon name="check" />
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
                <div className="pathInputGroup settingsPathInput">
                  <input
                    data-setting-input="outputDir"
                    data-testid="setting-output-dir"
                    onChange={(event) =>
                      updateSetting({ outputDir: event.target.value }, "默认保存位置")
                    }
                    value={settings.outputDir}
                  />
                  <button
                    aria-label="选择默认保存目录"
                    data-testid="setting-pick-output-dir"
                    onClick={onPickOutputDir}
                    title="选择默认保存目录"
                    type="button"
                  >
                    <Icon name="folder" />
                  </button>
                </div>
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
                dataSetting="notifyOnFinish"
                title="完成系统通知"
                subtitle="任务完成或失败时弹出系统通知，驻留托盘时也能感知。"
              >
                <button
                  aria-pressed={settings.notifyOnFinish}
                  className={`toggle ${settings.notifyOnFinish ? "on" : ""}`}
                  data-setting-input="notifyOnFinish"
                  data-testid="setting-notify-on-finish"
                  onClick={() =>
                    updateSetting(
                      { notifyOnFinish: !settings.notifyOnFinish },
                      "完成系统通知",
                    )
                  }
                >
                  <span />
                </button>
              </SettingRow>
              <SettingRow
                dataSetting="clipboardMonitor"
                title="剪贴板监听"
                subtitle="检测到复制的下载链接时提示创建任务。"
              >
                <button
                  aria-pressed={settings.clipboardMonitor}
                  className={`toggle ${settings.clipboardMonitor ? "on" : ""}`}
                  data-setting-input="clipboardMonitor"
                  data-testid="setting-clipboard-monitor"
                  onClick={() =>
                    updateSetting(
                      { clipboardMonitor: !settings.clipboardMonitor },
                      "剪贴板监听",
                    )
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
                        concurrency: clampNumber(
                          event.target.value,
                          1,
                          30,
                          defaultSettings.concurrency,
                        ),
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
                        threadCount: clampNumber(
                          event.target.value,
                          1,
                          32,
                          defaultSettings.threadCount,
                        ),
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
                        retryAttempts: clampNumber(
                          event.target.value,
                          0,
                          10,
                          defaultSettings.retryAttempts,
                        ),
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
                subtitle="单位 MiB/s，留空表示不限速；作用于未单独限速的任务。"
              >
                <input
                  data-setting-input="speedLimitMbps"
                  data-testid="setting-speed-limit"
                  defaultValue={
                    settings.speedLimitMbps > 0 ? String(settings.speedLimitMbps) : ""
                  }
                  inputMode="decimal"
                  // 作者: long
                  // 只重建限速输入即可同步外部配置，保留设置页当前分类和其他交互状态。
                  key={settings.speedLimitMbps}
                  onBlur={commitSpeedLimit}
                  onKeyDown={(event) => {
                    if (event.key === "Enter") commitSpeedLimit();
                  }}
                  placeholder="不限速"
                  ref={speedLimitInputRef}
                  type="text"
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
