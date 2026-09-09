// 作者: long
// Playwright CLI 隔离会话的 UI 回归，不连接 Tauri 或真实队列；这些数据仅验证显示和异步竞态，不代表真实下载。
async (page) => {
  const results = [];
  const check = (condition, name) => {
    if (!condition) throw new Error(name);
    results.push(name);
  };
  const origin = await page.evaluate(() => window.location.origin);
  if (!/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(origin)) {
    throw new Error('Open the local FluxDown web development server first');
  }
  await page.addInitScript(() => {
    const task = {
      id: 'regression-torrent', source: 'https://example.com/regression.torrent',
      protocol: 'torrent', state: 'running', output_dir: '/tmp/fluxdown-ui-regression',
      file_name: '回归测试文件夹', support: { protocol: 'torrent', backend: 'built-in', executable: true },
      total_bytes: 4096, downloaded_bytes: 1024, current_speed_bytes_per_second: 512,
      created_at_ms: Date.now(), updated_at_ms: Date.now(), started_at_ms: Date.now(),
    };
    window.__torrentProgressTest = { task, bytes: 1024, calls: 0, delay: 0, error: false, enqueued: null, opened: null };
    window.__TAURI_INTERNALS__ = {
      invoke: async (command, args) => {
        const fixture = window.__torrentProgressTest;
        if (command === 'list_downloads') return [{ ...fixture.task }];
        if (command === 'default_output_dir') return '/tmp/fluxdown-ui-regression';
        if (command === 'doctor') return { backends: [], protocols: [] };
        if (command === 'open_torrent_file') {
          fixture.opened = args;
          return null;
        }
        if (command === 'enqueue_download') {
          fixture.enqueued = args.payload;
          return { ...fixture.task, ...args.payload, id: 'selection-regression', state: 'queued' };
        }
        if (command !== 'torrent_task_details') return null;
        fixture.calls++;
        const bytes = fixture.bytes;
        if (fixture.delay) await new Promise((resolve) => setTimeout(resolve, fixture.delay));
        if (fixture.error) throw new Error('回归测试网络错误');
        return {
          runtime: Boolean(args.taskId), name: '回归测试文件夹', total_bytes: 4096,
          progress_bytes: bytes, trackers: [],
          files: [
            { index: 0, path: '第一部分/超长文件名称用于测试自动换行的资料-20260908-abcdef0123456789.mp4',
              size: 4096, progress_bytes: args.taskId ? bytes : null },
            { index: 1, path: '空文件.txt', size: 0, progress_bytes: args.taskId ? 0 : null },
          ],
        };
      },
    };
  });
  await page.goto(origin);
  const open = async (waitForFiles = true) => {
    await page.getByRole('article').filter({ hasText: '回归测试文件夹' }).click({ button: 'right' });
    await page.getByTestId('task-details-button').click();
    if (waitForFiles) await page.locator('[data-file-index="0"] [role="progressbar"]').waitFor();
  };
  const waitPercent = (value) => page.waitForFunction((expected) =>
    document.querySelector('[data-file-index="0"] [role="progressbar"]')?.getAttribute('aria-valuenow') === expected,
  value);
  await open();
  await waitPercent('25');
  check(await page.locator('[data-file-index="0"]').innerText().then((text) => text.includes('1.0 KB / 4.0 KB')), 'downloaded / total bytes');
  check(await page.locator('[data-file-index="1"] [role="progressbar"]').getAttribute('aria-valuenow') === '100', 'zero-byte file');

  for (const [width, height, name] of [[1280, 820, 'wide'], [980, 680, 'compact']]) {
    await page.setViewportSize({ width, height });
    check(await page.locator('.torrentFileList').first().evaluate((list) =>
      list.scrollWidth <= list.clientWidth && [...list.querySelectorAll('.torrentFileContent')].every((row) => row.scrollWidth <= row.clientWidth),
    ), `long file name fits ${name} viewport`);
    await page.getByTestId('torrent-details-dialog').screenshot({ path: `output/playwright/torrent-progress-${name}.png` });
  }
  await page.evaluate(() => { window.__torrentProgressTest.bytes = 3072; });
  await waitPercent('75');
  results.push('polling updates 25% to 75%');
  check(await page.locator('[data-file-index="0"] .torrentFileMetrics span').last().innerText()
    .then((text) => text.endsWith('/s')), 'per-file speed derives from successive samples');

  await page.evaluate(() => { window.__torrentProgressTest.task.state = 'paused'; });
  await waitPercent(null);
  check(await page.locator('[data-file-index="0"]').innerText().then((text) => text.includes('进度未知')), 'static metadata does not claim completion');
  check(await page.locator('[data-file-index="0"]').innerText().then((text) => text.includes('速度未知')), 'paused details clear sampled speed');
  const stoppedCalls = await page.evaluate(() => window.__torrentProgressTest.calls);
  await page.waitForTimeout(2300);
  check(await page.evaluate(() => window.__torrentProgressTest.calls) === stoppedCalls, 'paused task stops polling');

  await page.getByTestId('torrent-details-close').click();
  await page.evaluate(() => { window.__torrentProgressTest.task.state = 'running'; window.__torrentProgressTest.error = true; });
  await page.getByRole('button', { name: '刷新列表', exact: true }).click();
  await open(false);
  await page.locator('.updateStatus.failed').filter({ hasText: '回归测试网络错误' }).waitFor();
  await page.evaluate(() => { window.__torrentProgressTest.error = false; });
  await waitPercent('75');
  results.push('error renders and next poll recovers');

  await page.evaluate(() => { window.__torrentProgressTest.delay = 1800; window.__torrentProgressTest.bytes = 1024; });
  const beforeSlow = await page.evaluate(() => window.__torrentProgressTest.calls);
  await page.waitForFunction((before) => window.__torrentProgressTest.calls > before, beforeSlow);
  await page.getByTestId('torrent-details-close').click();
  await page.evaluate(() => { window.__torrentProgressTest.delay = 0; window.__torrentProgressTest.bytes = 4096; });
  await open();
  await waitPercent('100');
  await page.waitForTimeout(1900);
  check(await page.locator('[data-file-index="0"] [role="progressbar"]').getAttribute('aria-valuenow') === '100', 'old response cannot overwrite reopened details');
  await page.getByTestId('torrent-details-close').click();
  const closedCalls = await page.evaluate(() => window.__torrentProgressTest.calls);
  await page.waitForTimeout(2300);
  check(await page.evaluate(() => window.__torrentProgressTest.calls) === closedCalls, 'closed dialog stops polling');

  await page.evaluate(() => {
    window.__torrentProgressTest.task.state = 'finished';
    window.__torrentProgressTest.task.torrent_file_indices = [0];
  });
  await page.getByRole('button', { name: '刷新列表', exact: true }).click();
  await open();
  check(await page.locator('[data-file-index="0"] button').isEnabled()
    && await page.locator('[data-file-index="1"] button').isDisabled(), 'finished selected files can open but unselected files cannot');
  await page.locator('[data-file-index="0"] button').click();
  check(await page.evaluate(() => window.__torrentProgressTest.opened.fileIndex) === 0, 'file open passes the metadata index');
  await page.getByTestId('torrent-details-close').click();

  await page.getByTestId('new-task-button').click();
  await page.getByTestId('new-task-source').fill('https://example.com/selection.torrent');
  await page.getByTestId('new-task-torrent-files').waitFor();
  check(await page.getByTestId('new-task-torrent-file-0').isChecked()
    && await page.getByTestId('new-task-torrent-file-1').isChecked(), 'metadata files initially selected');
  await page.getByTestId('new-task-dialog').screenshot({ path: 'output/playwright/torrent-new-task-compact.png' });
  await page.getByTestId('new-task-torrent-file-1').uncheck();
  const callsBeforeRename = await page.evaluate(() => window.__torrentProgressTest.calls);
  await page.getByTestId('new-task-file-name').fill('手工命名');
  await page.waitForTimeout(400);
  check(!await page.getByTestId('new-task-torrent-file-1').isChecked()
    && await page.evaluate(() => window.__torrentProgressTest.calls) === callsBeforeRename,
  'renaming preserves selection without refetch');
  await page.getByTestId('new-task-torrent-file-0').uncheck();
  await page.getByTestId('new-task-create').click();
  check(await page.getByTestId('new-task-dialog').isVisible()
    && await page.evaluate(() => window.__torrentProgressTest.enqueued) === null,
  'empty explicit selection cannot become download all');
  await page.getByTestId('new-task-torrent-file-1').check();
  await page.getByTestId('new-task-create').click();
  check(await page.evaluate(() => JSON.stringify(window.__torrentProgressTest.enqueued.torrent_file_indices)) === '[1]',
    'selected file indices reach enqueue payload');
  return { passed: results.length, checks: results };
}
