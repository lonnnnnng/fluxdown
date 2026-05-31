import { useEffect, useMemo, useState } from 'react'
import { invoke } from '@tauri-apps/api/core'
import './App.css'

type Protocol =
  | 'http'
  | 'https'
  | 'webdav'
  | 'webdavs'
  | 'ftp'
  | 'ftps'
  | 'torrent'
  | 'magnet'
  | 'ed2k'
  | 'm3u8'
  | 'sftp'
  | 'smb'
  | 'ipfs'
  | 'unknown'

type Backend = 'built-in' | 'system-handoff' | 'aria2' | 'amule' | 'smb-client' | 'ipfs' | 'planned'

type SupportStatus = {
  protocol: Protocol
  backend: Backend
  configured?: boolean
  executable: boolean
  missing_command?: string | null
  note?: string
}

type BackendAvailability = {
  backend: Backend
  command?: string | null
  available: boolean
  note: string
}

type DoctorReport = {
  backends: BackendAvailability[]
  protocols: SupportStatus[]
}

type DownloadTask = {
  id: string
  source: string
  protocol: Protocol
  support: SupportStatus
  state: string
  output_dir: string
  file_name?: string | null
  total_bytes?: number | null
  downloaded_bytes: number
  error?: string | null
  created_at_ms?: number
  updated_at_ms?: number
}

type DownloadSummary = {
  protocol: Protocol
  backend: Backend
  output_path: string
  bytes_written: number
  resumed_from: number
  total_bytes?: number | null
  segments_written?: number | null
}

type QueueRunReport = {
  total_queued: number
  started: number
  finished: number
  failed: number
  tasks: DownloadTask[]
}

type TaskRunReport = {
  task: DownloadTask
  summary?: DownloadSummary | null
}

const supportedNow = new Set<Protocol>([
  'http',
  'https',
  'webdav',
  'webdavs',
  'ftp',
  'ftps',
  'torrent',
  'magnet',
  'ed2k',
  'm3u8',
  'sftp',
  'smb',
  'ipfs',
])

const examples = [
  'https://speed.hetzner.de/100MB.bin',
  'webdavs://cloud.example.com/remote.php/dav/files/archive.zip',
  'https://example.com/live/playlist.m3u8',
  'magnet:?xt=urn:btih:0123456789abcdef',
  'ed2k://|file|example.iso|123|ABCDEF|/',
  'ftp://ftp.example.com/pub/file.zip',
  'sftp://user:pass@example.com/home/user/archive.zip',
  'smb://user:pass@nas.local/Share/archive.zip',
]

function fallbackDetect(source: string): Protocol {
  const value = source.trim().toLowerCase()
  if (value.startsWith('magnet:?')) return 'magnet'
  if (value.startsWith('ed2k://')) return 'ed2k'
  if (hasPathExtension(value, '.torrent')) return 'torrent'
  if (hasPathExtension(value, '.m3u8')) return 'm3u8'
  if (value.startsWith('https://')) return 'https'
  if (value.startsWith('http://')) return 'http'
  if (value.startsWith('webdavs://')) return 'webdavs'
  if (value.startsWith('webdav://')) return 'webdav'
  if (value.startsWith('ftps://')) return 'ftps'
  if (value.startsWith('ftp://')) return 'ftp'
  if (value.startsWith('sftp://')) return 'sftp'
  if (value.startsWith('smb://')) return 'smb'
  if (value.startsWith('ipfs://')) return 'ipfs'
  return 'unknown'
}

function hasPathExtension(source: string, extension: string) {
  if (source.endsWith(extension)) return true

  try {
    return new URL(source).pathname.toLowerCase().endsWith(extension)
  } catch {
    return false
  }
}

function fallbackSupport(source: string): SupportStatus {
  const detected = fallbackDetect(source)
  if (detected === 'ed2k') {
    return { protocol: detected, backend: 'system-handoff', executable: true }
  }

  if (supportedNow.has(detected)) {
    return { protocol: detected, backend: 'built-in', executable: true }
  }

  return { protocol: detected, backend: 'planned', executable: false }
}

function progressPercent(task: DownloadTask) {
  if (!task.total_bytes || task.total_bytes <= 0) return 0
  return Math.min(100, Math.round((task.downloaded_bytes / task.total_bytes) * 100))
}

function App() {
  const [source, setSource] = useState(examples[0])
  const [outputDir, setOutputDir] = useState('./downloads')
  const [fileName, setFileName] = useState('')
  const [tasks, setTasks] = useState<DownloadTask[]>([])
  const [message, setMessage] = useState('Ready')
  const [runtimeSupport, setRuntimeSupport] = useState<SupportStatus | null>(null)
  const [doctorReport, setDoctorReport] = useState<DoctorReport | null>(null)
  const [concurrency, setConcurrency] = useState(2)
  const [activeRuns, setActiveRuns] = useState(0)

  const fallbackStatus = useMemo(() => fallbackSupport(source), [source])
  const supportStatus = runtimeSupport ?? fallbackStatus
  const protocol = supportStatus.protocol
  const canStart = supportStatus.executable

  useEffect(() => {
    let cancelled = false
    invoke<SupportStatus>('support', { source })
      .then((status) => {
        if (!cancelled) setRuntimeSupport(status)
      })
      .catch(() => {
        if (!cancelled) setRuntimeSupport(null)
      })
    return () => {
      cancelled = true
    }
  }, [source])

  useEffect(() => {
    invoke<DoctorReport>('doctor')
      .then(setDoctorReport)
      .catch(() => setDoctorReport(null))
  }, [])

  useEffect(() => {
    invoke<DownloadTask[]>('list_downloads')
      .then(setTasks)
      .catch(() => undefined)
  }, [])

  useEffect(() => {
    const hasRunningTasks = tasks.some((task) => task.state === 'running')
    if (activeRuns <= 0 && !hasRunningTasks) return

    const timer = window.setInterval(() => {
      invoke<DownloadTask[]>('list_downloads')
        .then(setTasks)
        .catch(() => undefined)
    }, 600)

    return () => window.clearInterval(timer)
  }, [activeRuns, tasks])

  async function addTask() {
    const fallbackTask: DownloadTask = {
      id: `preview-${Date.now()}`,
      source,
      protocol,
      state: 'queued',
      output_dir: outputDir,
      file_name: fileName || null,
      support: fallbackSupport(source),
      total_bytes: null,
      downloaded_bytes: 0,
    }

    const task = await invoke<DownloadTask>('enqueue_download', {
      payload: {
        source,
        output_dir: outputDir,
        file_name: fileName || null,
      },
    }).catch(() => fallbackTask)

    setTasks((current) => [task, ...current])
    setMessage(`${task.protocol.toUpperCase()} task queued`)
  }

  async function startDownload(id: string) {
    setMessage(`Starting ${id}...`)
    setActiveRuns((count) => count + 1)
    setTasks((current) => current.map((item) => (item.id === id ? { ...item, state: 'running' } : item)))
    try {
      const report = await invoke<TaskRunReport>('start_download', {
        id,
      })
      setTasks((current) => current.map((item) => (item.id === id ? report.task : item)))
      if (report.summary) {
        setMessage(
          `Saved ${report.summary.bytes_written.toLocaleString()} bytes to ${report.summary.output_path}${
            report.summary.resumed_from > 0 ? `, resumed from ${report.summary.resumed_from.toLocaleString()}` : ''
          }`,
        )
      } else if (report.task.state === 'paused') {
        setMessage(`${id} paused`)
      } else if (report.task.state === 'failed') {
        setMessage(report.task.error || `${id} failed`)
      } else {
        setMessage(`${id} finished with state ${report.task.state}`)
      }
    } catch (error) {
      setMessage(String(error))
      setTasks(await invoke<DownloadTask[]>('list_downloads').catch(() => tasks))
    } finally {
      setActiveRuns((count) => Math.max(0, count - 1))
    }
  }

  async function pauseDownload(id: string) {
    const task = await invoke<DownloadTask>('pause_download', { id })
    setTasks((current) => current.map((item) => (item.id === id ? task : item)))
    setMessage(`${id} paused`)
  }

  async function resumeDownload(id: string) {
    const task = await invoke<DownloadTask>('resume_download', { id })
    setTasks((current) => current.map((item) => (item.id === id ? task : item)))
    setMessage(`${id} queued`)
  }

  async function removeDownload(id: string) {
    await invoke<DownloadTask>('remove_download', { id })
    setTasks((current) => current.filter((item) => item.id !== id))
    setMessage(`${id} removed`)
  }

  async function runQueue() {
    setMessage(`Running queued tasks with concurrency ${concurrency}...`)
    setActiveRuns((count) => count + 1)
    try {
      const report = await invoke<QueueRunReport>('run_queue', { concurrency })
      setMessage(`Run complete: ${report.finished} finished, ${report.failed} failed`)
      setTasks(await invoke<DownloadTask[]>('list_downloads').catch(() => tasks))
    } catch (error) {
      setMessage(String(error))
      setTasks(await invoke<DownloadTask[]>('list_downloads').catch(() => tasks))
    } finally {
      setActiveRuns((count) => Math.max(0, count - 1))
    }
  }

  return (
    <main className="shell">
      <aside className="sidebar">
        <div className="brand">
          <div className="mark">F</div>
          <div>
            <strong>FluxDown</strong>
            <span>multi-protocol downloader</span>
          </div>
        </div>
        <nav>
          <button className="navItem active">Queue</button>
          <button className="navItem">Protocols</button>
          <button className="navItem">Settings</button>
        </nav>
        <section className="protocolPanel">
          <h2>Recognized</h2>
          <div className="protocolGrid">
            {['HTTP', 'FTP', 'WebDAV', 'Torrent', 'Magnet', 'ed2k', 'm3u8', 'SFTP', 'SMB', 'IPFS'].map((item) => (
              <span key={item}>{item}</span>
            ))}
          </div>
        </section>
      </aside>

      <section className="workspace">
        <header className="topbar">
          <div>
            <h1>Download queue</h1>
            <p>Desktop GUI for Windows, macOS, and Linux backed by the shared Rust engine.</p>
          </div>
          <div className={`status ${canStart ? 'ready' : 'planned'}`}>
            {canStart ? 'Ready' : supportStatus.missing_command ? `Missing ${supportStatus.missing_command}` : 'Adapter planned'}
          </div>
        </header>

        <section className="composer">
          <label>
            Source
            <input value={source} onChange={(event) => setSource(event.target.value)} placeholder="URL, WebDAV, magnet, ed2k, torrent path, m3u8" />
          </label>
          <div className="row">
            <label>
              Output folder
              <input value={outputDir} onChange={(event) => setOutputDir(event.target.value)} />
            </label>
            <label>
              File name
              <input value={fileName} onChange={(event) => setFileName(event.target.value)} placeholder="optional" />
            </label>
          </div>
          <div className="actions">
            <div className="detected">
              <span>Detected</span>
              <strong>{protocol}</strong>
              <em>{supportStatus.backend}</em>
            </div>
            <button onClick={addTask}>Add to queue</button>
            <button className="primary" onClick={addTask}>Queue</button>
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
            <h2>Queue runner</h2>
            <span>Processes queued tasks and writes final state back to the persistent store.</span>
          </div>
          <label>
            Concurrency
            <input
              min={1}
              max={8}
              type="number"
              value={concurrency}
              onChange={(event) => setConcurrency(Math.max(1, Number(event.target.value) || 1))}
            />
          </label>
          <button className="primary" onClick={runQueue}>Run queue</button>
        </section>

        <section className="doctor">
          <div className="queueHeader">
            <h2>Runtime backends</h2>
            <span>{doctorReport ? 'checked on this machine' : 'web preview fallback'}</span>
          </div>
          <div className="backendGrid">
            {(doctorReport?.backends ?? [
              { backend: 'built-in', available: true, note: 'compiled into FluxDown core' },
            ]).map((backend) => (
              <div className="backend" key={backend.backend}>
                <strong>{backend.backend}</strong>
                <span>{backend.available ? 'available' : backend.command ? `missing ${backend.command}` : 'not available'}</span>
              </div>
            ))}
          </div>
        </section>

        <section className="queue">
          <div className="queueHeader">
            <h2>Tasks</h2>
            <span>{message}</span>
          </div>
          {tasks.length === 0 ? (
            <div className="empty">No queued tasks yet.</div>
          ) : (
            tasks.map((task) => (
              <article className="task" key={task.id}>
                <div>
                  <strong>{task.source}</strong>
                  <span>{task.output_dir}</span>
                  <span>
                    {task.downloaded_bytes.toLocaleString()}
                    {task.total_bytes ? ` / ${task.total_bytes.toLocaleString()}` : ''} bytes
                  </span>
                  <div className="progressTrack" aria-label={`Progress ${progressPercent(task)} percent`}>
                    <div style={{ width: `${progressPercent(task)}%` }} />
                  </div>
                  {task.error ? <span className="errorText">{task.error}</span> : null}
                </div>
                <div className="taskMeta">
                  <span>{task.protocol}</span>
                  <span>{task.support.backend}</span>
                  <span>{task.state}</span>
                  <div className="taskButtons">
                    <button disabled={!task.support.executable} onClick={() => startDownload(task.id)}>Start</button>
                    <button onClick={() => pauseDownload(task.id)}>Pause</button>
                    <button onClick={() => resumeDownload(task.id)}>Resume</button>
                    <button onClick={() => removeDownload(task.id)}>Remove</button>
                  </div>
                </div>
              </article>
            ))
          )}
        </section>
      </section>
    </main>
  )
}

export default App
