import { useEffect, useMemo, useRef, useState } from "react";
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
type QueueFilter = "all" | "queued" | "running" | "finished" | "failed";
type Page = "queue" | "settings";
type TaskAction = "idle" | "start" | "pause" | "remove" | "copy" | "open";

type DownloadTask = {
  id: string;
  source: string;
  protocol: Protocol;
  support: SupportStatus;
  state: DownloadState;
  output_dir: string;
  file_name?: string | null;
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
    finished: "已完成",
    failed: "失败",
  };
  return labels[filter];
}

function filterMatches(task: DownloadTask, filter: QueueFilter) {
  if (filter === "all") return true;
  if (filter === "queued") return task.state === "queued" || task.state === "paused";
  return task.state === filter;
}

function taskCounts(tasks: DownloadTask[]) {
  return {
    all: tasks.length,
    queued: tasks.filter((task) => filterMatches(task, "queued")).length,
    running: tasks.filter((task) => task.state === "running").length,
    finished: tasks.filter((task) => task.state === "finished").length,
    failed: tasks.filter((task) => task.state === "failed").length,
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

function formatClock(value?: number | null) {
  if (!value) return "--:--";
  return new Date(value).toLocaleTimeString("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  });
}

function formatDuration(start?: number, end?: number) {
  if (!start || !end || end < start) return "00:00";
  const totalSeconds = Math.floor((end - start) / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

function averageSpeed(task: DownloadTask) {
  const start = task.started_at_ms ?? task.created_at_ms;
  const end =
    task.finished_at_ms ??
    (task.state === "running" || task.state === "paused" ? task.updated_at_ms : undefined);
  if (!start || !end || task.downloaded_bytes <= 0) {
    return "0 B/s";
  }
  const elapsed = Math.max(1, end - start);
  return `${formatBytes((task.downloaded_bytes * 1000) / elapsed)}/s`;
}

function currentSpeed(task: DownloadTask) {
  return `${formatBytes(task.current_speed_bytes_per_second ?? 0)}/s`;
}

function taskActionTitle(task: DownloadTask) {
  if (task.state === "running") return "点击暂停";
  if (task.state === "finished" || task.state === "failed") return "点击重新下载";
  return "点击开始";
}

function App() {
  const [page, setPage] = useState<Page>("queue");
  const [filter, setFilter] = useState<QueueFilter>("all");
  const [settings, setSettings] = useState<Settings>(loadSettings);
  const [tasks, setTasks] = useState<DownloadTask[]>([]);
  const [message, setMessage] = useState("就绪");
  const [doctorReport, setDoctorReport] = useState<DoctorReport | null>(null);
  const [newDialogOpen, setNewDialogOpen] = useState(false);
  const [source, setSource] = useState("");
  const [fileName, setFileName] = useState("");
  const [outputDir, setOutputDir] = useState(settings.outputDir);
  const [activeTaskId, setActiveTaskId] = useState<string | null>(null);
  const [queueActive, setQueueActive] = useState(false);
  const [menuTaskId, setMenuTaskId] = useState<string | null>(null);
  const [propertyTask, setPropertyTask] = useState<DownloadTask | null>(null);
  const [action, setAction] = useState<TaskAction>("idle");
  const autoRunKeyRef = useRef("");

  const counts = useMemo(() => taskCounts(tasks), [tasks]);
  const visibleTasks = useMemo(
    () => tasks.filter((task) => filterMatches(task, filter)),
    [filter, tasks],
  );

  useEffect(() => {
    saveSettings(settings);
  }, [settings]);

  useEffect(() => {
    setOutputDir((current) => current || settings.outputDir);
  }, [settings.outputDir]);

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
  }, [queueActive, settings.autoStart, tasks]);

  async function refreshTasks() {
    const result = await invoke<DownloadTask[]>("list_downloads").catch(
      () => null,
    );
    if (result) setTasks(result);
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
    const task = await invoke<DownloadTask>("enqueue_download", {
      payload: {
        source: normalizedSource,
        output_dir: normalizedOutput,
        file_name: fileName.trim() || null,
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
        total_bytes: null,
        downloaded_bytes: 0,
        created_at_ms: Date.now(),
        updated_at_ms: Date.now(),
      } satisfies DownloadTask;
    });

    setTasks((current) => [task, ...current.filter((item) => item.id !== task.id)]);
    setNewDialogOpen(false);
    setSource("");
    setFileName("");
    setOutputDir(settings.outputDir);
    setMessage(`${taskTitle(task)} 已加入队列`);
  }

  async function pasteFromClipboard() {
    try {
      const text = await navigator.clipboard.readText();
      if (text.trim()) {
        setSource(text.trim());
        if (!fileName.trim()) setFileName(suggestedFileName(text.trim()));
      }
    } catch {
      setMessage("无法读取剪切板");
    }
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
      setMessage(String(error));
    } finally {
      setAction("idle");
    }
  }

  async function revealTaskOutput(task: DownloadTask, message = "已在 Finder 中显示") {
    setAction("open");
    try {
      await invoke("reveal_task_output", { id: task.id });
      setMessage(message);
    } catch (error) {
      setMessage(String(error));
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
      setMessage(String(error));
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
      setMessage(String(error));
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
      setMessage(String(error));
    } finally {
      setAction("idle");
    }
  }

  async function redownloadTask(task: DownloadTask) {
    setMenuTaskId(null);
    await startTask(task, true);
  }

  async function runQueue() {
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
      setMessage(String(error));
      // Web preview or unsupported runtime: queued items stay visible.
    } finally {
      setQueueActive(false);
    }
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
    setNewDialogOpen(true);
  }

  const currentMenuTask = tasks.find((task) => task.id === menuTaskId) ?? null;

  return (
    <main className="appShell">
      <section className="fixedPane">
        <header className="appHeader">
          {page === "queue" ? (
            <span className="brandMark" aria-label="FluxDown">
              FD
            </span>
          ) : (
            <button
              className="pageIcon"
              title="返回下载列表"
              onClick={() => setPage("queue")}
            >
              ‹
            </button>
          )}
          <div>
            <h1>{page === "queue" ? "下载列表" : "设置"}</h1>
            <p>
              {page === "queue"
                ? `${tasks.length} 个任务 · ${message}`
                : "下载保存位置、队列和速度"}
            </p>
          </div>
          {page === "queue" ? (
            <button
              className="pageIcon right"
              title="设置"
              onClick={() => setPage("settings")}
            >
              ⚙
            </button>
          ) : (
            <span className="headerSpacer" aria-hidden="true" />
          )}
        </header>

        {page === "queue" ? (
          <nav className="statusTabs" aria-label="下载任务状态">
            {(["all", "queued", "running", "finished", "failed"] as const).map(
              (item) => (
                <button
                  key={item}
                  className={filter === item ? "active" : ""}
                  onClick={() => setFilter(item)}
                >
                  {filterLabel(item)}({counts[item]})
                </button>
              ),
            )}
          </nav>
        ) : null}
      </section>

      {page === "queue" ? (
        <DownloadList
          activeTaskId={activeTaskId}
          action={action}
          filter={filter}
          menuTaskId={menuTaskId}
          onMenu={setMenuTaskId}
          onToggle={toggleTask}
          tasks={visibleTasks}
        />
      ) : (
        <SettingsPage
          doctorReport={doctorReport}
          onChange={updateSettings}
          settings={settings}
        />
      )}

      {page === "queue" ? (
        <button
          className="floatingAdd"
          title="新建任务"
          onClick={openNewDialog}
        >
          +
        </button>
      ) : null}

      {newDialogOpen ? (
        <NewTaskDialog
          fileName={fileName}
          onClose={() => setNewDialogOpen(false)}
          onCreate={createTask}
          onFileNameChange={setFileName}
          onOutputDirChange={setOutputDir}
          onPaste={pasteFromClipboard}
          onSourceChange={(value) => {
            setSource(value);
            if (!fileName.trim()) setFileName(suggestedFileName(value));
          }}
          outputDir={outputDir}
          source={source}
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
            revealTaskOutput(currentMenuTask, "已定位文件，可从 Finder 使用系统分享").then(
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
    </main>
  );
}

function DownloadList({
  activeTaskId,
  action,
  filter,
  menuTaskId,
  onMenu,
  onToggle,
  tasks,
}: {
  activeTaskId: string | null;
  action: TaskAction;
  filter: QueueFilter;
  menuTaskId: string | null;
  onMenu: (id: string | null) => void;
  onToggle: (task: DownloadTask) => void;
  tasks: DownloadTask[];
}) {
  if (tasks.length === 0) {
    return (
      <section className="scrollPane emptyPane">
        <div className="emptyState">
          <span>▣</span>
          <strong>{filter === "all" ? "等待添加任务" : "当前状态没有任务"}</strong>
          <p>点击右下角按钮新建下载。</p>
        </div>
      </section>
    );
  }

  return (
    <section className="scrollPane taskList">
      {tasks.map((task) => (
        <TaskRow
          action={activeTaskId === task.id ? action : "idle"}
          key={task.id}
          menuOpen={menuTaskId === task.id}
          onMenu={onMenu}
          onToggle={onToggle}
          task={task}
        />
      ))}
    </section>
  );
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
  const startedAt = task.started_at_ms ?? task.created_at_ms;
  const finishedAt =
    task.finished_at_ms ??
    (task.state === "running" || task.state === "paused" ? task.updated_at_ms : undefined);
  const elapsed = formatDuration(startedAt, finishedAt);

  return (
    <article
      className={`taskRow state-${task.state}`}
      onClick={() => onToggle(task)}
      onContextMenu={(event) => {
        event.preventDefault();
        onMenu(task.id);
      }}
      style={{ "--progress": width } as CSSProperties}
      title={taskActionTitle(task)}
    >
      <div className="taskProgressFill" />
      <div className="taskMain">
        <div className="taskTitleLine">
          <strong>{taskTitle(task)}</strong>
          <span>{protocolLabel(task.protocol)}</span>
          <em>{stateLabel(task.state)}</em>
        </div>
        <div className="taskMetrics">
          <span title="开始时间">↘ {formatClock(startedAt)}</span>
          <span title="结束时间">↗ {formatClock(task.finished_at_ms)}</span>
          <span title="共计耗时">◷ {elapsed}</span>
          <span title="实时速度">↯ {currentSpeed(task)}</span>
          <span title="平均速度">⇅ {averageSpeed(task)}</span>
          <span title="已下载/总大小">
            {formatBytes(task.downloaded_bytes)} / {formatBytes(task.total_bytes)}
          </span>
        </div>
        {task.error ? <p className="taskError">{task.error}</p> : null}
      </div>
      <button
        className="moreButton"
        onClick={(event) => {
          event.stopPropagation();
          onMenu(menuOpen ? null : task.id);
        }}
        title="任务操作"
      >
        ⋮
      </button>
      {action === "start" ? <span className="busyDot" /> : null}
    </article>
  );
}

function NewTaskDialog({
  fileName,
  onClose,
  onCreate,
  onFileNameChange,
  onOutputDirChange,
  onPaste,
  onSourceChange,
  outputDir,
  source,
}: {
  fileName: string;
  onClose: () => void;
  onCreate: () => void;
  onFileNameChange: (value: string) => void;
  onOutputDirChange: (value: string) => void;
  onPaste: () => void;
  onSourceChange: (value: string) => void;
  outputDir: string;
  source: string;
}) {
  return (
    <div className="modalBackdrop" onMouseDown={onClose}>
      <section className="taskDialog" onMouseDown={(event) => event.stopPropagation()}>
        <header className="dialogHeader">
          <div>
            <span className="dialogMark">＋</span>
            <h2>新建任务</h2>
          </div>
          <div className="dialogTools">
            <button title="从剪切板读取" onClick={onPaste}>
              ⧉
            </button>
            <button title="关闭" onClick={onClose}>
              ×
            </button>
          </div>
        </header>
        <label className="fieldBlock">
          <span>下载链接</span>
          <textarea
            autoFocus
            onChange={(event) => onSourceChange(event.target.value)}
            placeholder="粘贴 HTTP、m3u8、torrent、magnet、FTP、SFTP、SMB 等下载源"
            rows={4}
            value={source}
          />
        </label>
        <label className="fieldBlock">
          <span>另存为文件名</span>
          <input
            onChange={(event) => onFileNameChange(event.target.value)}
            placeholder="留空则按下载资源自动命名"
            value={fileName}
          />
        </label>
        <label className="fieldBlock">
          <span>保存路径</span>
          <input
            onChange={(event) => onOutputDirChange(event.target.value)}
            value={outputDir}
          />
        </label>
        <footer className="dialogFooter">
          <button onClick={onClose}>取消</button>
          <button className="primary" onClick={onCreate}>
            创建任务
          </button>
        </footer>
      </section>
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
        <button onClick={onReveal}>在 Finder 中显示</button>
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
          <dd>{task.source}</dd>
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
        </dl>
      </section>
    </div>
  );
}

function SettingsPage({
  doctorReport,
  onChange,
  settings,
}: {
  doctorReport: DoctorReport | null;
  onChange: (patch: Partial<Settings>) => void;
  settings: Settings;
}) {
  const backends =
    doctorReport?.backends ?? [
      {
        backend: "built-in" as Backend,
        available: true,
        note: "已编译进 FluxDown core",
      },
    ];

  return (
    <section className="scrollPane settingsPage">
      <div className="settingsCard">
        <SettingRow title="下载保存位置" subtitle="新建任务默认保存到这里">
          <input
            onChange={(event) => onChange({ outputDir: event.target.value })}
            value={settings.outputDir}
          />
        </SettingRow>
        <SettingRow title="并发下载数" subtitle="同时运行的队列任务，1-30">
          <input
            max={30}
            min={1}
            onChange={(event) =>
              onChange({
                concurrency: clampNumber(event.target.value, 1, 30, 1),
              })
            }
            type="number"
            value={settings.concurrency ?? defaultSettings.concurrency}
          />
        </SettingRow>
        <SettingRow title="下载线程数" subtitle="单个任务使用的线程，1-32">
          <input
            max={32}
            min={1}
            onChange={(event) =>
              onChange({
                threadCount: clampNumber(event.target.value, 1, 32, 8),
              })
            }
            type="number"
            value={settings.threadCount ?? defaultSettings.threadCount}
          />
        </SettingRow>
        <SettingRow title="自动重试数" subtitle="任务失败后的重试次数，0-10">
          <input
            max={10}
            min={0}
            onChange={(event) =>
              onChange({
                retryAttempts: clampNumber(event.target.value, 0, 10, 1),
              })
            }
            type="number"
            value={settings.retryAttempts ?? defaultSettings.retryAttempts}
          />
        </SettingRow>
        <SettingRow title="最大下载网速" subtitle="单位 MB/s，0 表示不限速">
          <input
            max={10000}
            min={0}
            onChange={(event) =>
              onChange({
                speedLimitMbps: clampNumber(event.target.value, 0, 10000, 0),
              })
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
        <SettingRow title="创建后自动开始" subtitle="新任务入队后自动按并发数运行">
          <button
            className={`toggle ${settings.autoStart ? "on" : ""}`}
            onClick={() => onChange({ autoStart: !settings.autoStart })}
          >
            <span />
          </button>
        </SettingRow>
        <SettingRow title="列表刷新间隔" subtitle="下载中任务的界面刷新频率">
          <input
            max={5000}
            min={300}
            onChange={(event) =>
              onChange({
                refreshIntervalMs: clampNumber(
                  event.target.value,
                  300,
                  5000,
                  defaultSettings.refreshIntervalMs,
                ),
              })
            }
            step={100}
            type="number"
            value={settings.refreshIntervalMs ?? defaultSettings.refreshIntervalMs}
          />
        </SettingRow>
      </div>

      <div className="settingsCard subtle">
        <div className="settingsSectionTitle">
          <strong>协议能力</strong>
          <span>本机后端状态</span>
        </div>
        <div className="backendList">
          {backends.map((backend) => (
            <div className="backendItem" key={backend.backend}>
              <span>{backendLabel(backend.backend)}</span>
              <strong>{backend.available ? "可用" : backend.command ? `缺少 ${backend.command}` : "不可用"}</strong>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function SettingRow({
  children,
  subtitle,
  title,
}: {
  children: ReactNode;
  subtitle: string;
  title: string;
}) {
  return (
    <div className="settingRow">
      <div>
        <strong>{title}</strong>
        <span>{subtitle}</span>
      </div>
      <div className="settingControl">{children}</div>
    </div>
  );
}

export default App;
