const path = require('node:path');
const fs = require('node:fs');
const chokidar = require('chokidar');
const { app, BrowserWindow, Menu, Tray, ipcMain, nativeImage, screen } = require('electron');
const { loadConfig, saveConfig } = require('./core/config-store');
const { discoverRepositories } = require('./core/repo-discovery');
const { buildState, emptyState, loadState, saveState } = require('./core/state-store');
const { RepoWatcher } = require('./core/repo-watcher');
const { defaultConfigDir } = require('./utils/path-utils');
const { debounce } = require('./utils/debounce');
const { log, warn } = require('./utils/logger');

const expandedSize = { width: 390, height: 720, minHeight: 620 };
const collapsedSize = { width: 320, height: 210 };
const floatingWindowMargin = 48;

let floatingWindow = null;
let config = null;
let state = emptyState();
let watcher = null;
let configWatcher = null;
let rootDiscoveryWatcher = null;
let pollTimer = null;
let tray = null;
let isAlwaysOnTop = true;
let isCollapsed = false;
let displayMode = 'full';
let isQuitting = false;
let saveFloatingBounds = null;
const scheduleRefreshAllProjects = debounce(refreshAllProjects, 1000);

function hideMacDock() {
  if (process.platform !== 'darwin') {
    return;
  }

  app.setActivationPolicy('accessory');
  if (app.dock) {
    app.dock.hide();
  }
  app.hide();
}

function configureMacBackgroundMode() {
  if (process.platform !== 'darwin') {
    return;
  }

  app.once('ready', () => {
    hideMacDock();
  });
  app.on('activate', () => {
    hideMacDock();
  });
}

hideMacDock();

async function createFloatingWindow() {
  isAlwaysOnTop = config.floatingWindow.alwaysOnTop;
  displayMode = normalizeDisplayMode(config.floatingWindow.displayMode);
  isCollapsed = displayMode === 'mini';
  const size = isCollapsed ? collapsedSize : expandedSize;

  floatingWindow = new BrowserWindow({
    width: size.width,
    height: isCollapsed ? size.height : resolveExpandedHeight(size.height),
    minWidth: collapsedSize.width,
    minHeight: collapsedSize.height,
    maxWidth: expandedSize.width,
    frame: false,
    transparent: true,
    resizable: true,
    useContentSize: true,
    movable: true,
    alwaysOnTop: isAlwaysOnTop,
    skipTaskbar: true,
    show: false,
    backgroundColor: '#00000000',
    vibrancy: 'under-window',
    visualEffectState: 'active',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  floatingWindow.setAlwaysOnTop(isAlwaysOnTop, isAlwaysOnTop ? 'floating' : 'normal');
  if (process.platform === 'darwin') {
    floatingWindow.setVisibleOnAllWorkspaces(false);
  }
  floatingWindow.setSkipTaskbar(true);
  floatingWindow.setMenuBarVisibility(false);
  applyWindowSizing();

  restoreFloatingBounds();
  saveFloatingBounds = debounce(persistFloatingBounds, 250);

  floatingWindow.on('moved', saveFloatingBounds);
  floatingWindow.on('move', saveFloatingBounds);
  floatingWindow.on('show', () => {
    floatingWindow?.webContents.send('devpulse:state-changed', state);
    floatingWindow?.webContents.send('floating:state-changed', getFloatingState());
  });
  floatingWindow.on('close', (event) => {
    if (!isQuitting) {
      event.preventDefault();
      floatingWindow.hide();
    }
  });

  floatingWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  floatingWindow.once('ready-to-show', () => {
    if (!hasSavedPosition()) {
      setPositionToDesktopCorner(floatingWindow);
    }
    floatingWindow.showInactive();
  });
}

async function bootstrap() {
  hideMacDock();

  const configDir = defaultConfigDir();
  config = await loadConfig(configDir);
  state = await loadState(configDir);
  syncOpenAtLogin(config.openAtLogin);

  ipcMain.handle('devpulse:get-state', () => state);
  ipcMain.handle('devpulse:get-config', () => publicConfig(config));
  ipcMain.handle('devpulse:update-settings', async (_event, settings) => updateSettings(settings));
  ipcMain.handle('app:quit', () => {
    isQuitting = true;
    app.quit();
    return true;
  });
  registerFloatingIpc();

  await createFloatingWindow();
  createTrayMenu();
  await refreshAllProjects();

  watcher = new RepoWatcher({
    config,
    onProjectUpdate: async (project) => {
      const projects = mergeProject(state.projects, project);
      state = buildState(projects, state);
      await publishState();
    }
  });
  watcher.watch(state.projects);
  startConfigWatcher();
  startRootDiscoveryWatcher();

  pollTimer = setInterval(refreshAllProjects, config.pollFallbackMs);
}

async function refreshAllProjects() {
  try {
    const projects = await discoverRepositories(config);
    state = buildState(projects, state);
    await publishState();
    watcher?.watch(state.projects);
    log(`Tracking ${state.projects.length} repositories`);
  } catch (error) {
    warn('Refresh failed', error.message);
  }
}

async function reloadConfigAndRefresh() {
  try {
    const previousDiscoverySignature = discoverySignature(config);
    const previousPollFallbackMs = config.pollFallbackMs;
    const nextConfig = await loadConfig(defaultConfigDir());
    const shouldRefreshDiscovery = previousDiscoverySignature !== discoverySignature(nextConfig);
    config = nextConfig;

    if (pollTimer && previousPollFallbackMs !== config.pollFallbackMs) {
      clearInterval(pollTimer);
      pollTimer = setInterval(refreshAllProjects, config.pollFallbackMs);
    }

    watcher.config = config;
    if (shouldRefreshDiscovery) {
      startRootDiscoveryWatcher();
      await refreshAllProjects();
    }
    updateTrayMenu();
    log('Config reloaded');
  } catch (error) {
    warn('Config reload failed', error.message);
  }
}

async function updateSettings(settings = {}) {
  const nextPollFallbackMs = normalizePollFallbackMs(settings.pollFallbackMs, config.pollFallbackMs);
  const nextDisplayMode = normalizeDisplayMode(settings.displayMode || config.floatingWindow.displayMode);
  const nextConfig = {
    ...config,
    pollFallbackMs: nextPollFallbackMs,
    notificationsEnabled: typeof settings.notificationsEnabled === 'boolean'
      ? settings.notificationsEnabled
      : config.notificationsEnabled,
    openAtLogin: typeof settings.openAtLogin === 'boolean'
      ? settings.openAtLogin
      : config.openAtLogin,
    dataRetentionDays: normalizeDataRetentionDays(settings.dataRetentionDays, config.dataRetentionDays),
    floatingWindow: {
      ...config.floatingWindow,
      displayMode: nextDisplayMode,
      collapsed: nextDisplayMode === 'mini'
    }
  };

  await saveConfig(nextConfig, defaultConfigDir());
  config = await loadConfig(defaultConfigDir());

  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = setInterval(refreshAllProjects, config.pollFallbackMs);
  }

  syncOpenAtLogin(config.openAtLogin);
  setDisplayMode(config.floatingWindow.displayMode);
  updateTrayMenu();
  floatingWindow?.webContents.send('devpulse:config-changed', publicConfig(config));
  return publicConfig(config);
}

function publicConfig(nextConfig) {
  return {
    pollFallbackMs: nextConfig.pollFallbackMs,
    notificationsEnabled: nextConfig.notificationsEnabled,
    openAtLogin: nextConfig.openAtLogin,
    dataRetentionDays: nextConfig.dataRetentionDays,
    floatingWindow: {
      displayMode: normalizeDisplayMode(nextConfig.floatingWindow?.displayMode)
    }
  };
}

function syncOpenAtLogin(enabled) {
  if (process.platform !== 'darwin') {
    return;
  }

  app.setLoginItemSettings({
    openAtLogin: Boolean(enabled),
    openAsHidden: true
  });
}

function normalizePollFallbackMs(value, fallback) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return fallback;
  }

  return Math.min(30 * 60 * 1000, Math.max(5000, Math.round(numeric)));
}

function normalizeDataRetentionDays(value, fallback) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return fallback;
  }

  return Math.min(90, Math.max(1, Math.round(numeric)));
}

function discoverySignature(nextConfig) {
  return JSON.stringify({
    roots: nextConfig.roots,
    ignoredDirs: nextConfig.ignoredDirs,
    scanDepth: nextConfig.scanDepth
  });
}

function startConfigWatcher() {
  configWatcher?.close().catch((error) => warn('Failed to close config watcher', error.message));
  configWatcher = chokidar.watch(config.configPath, {
    ignoreInitial: true,
    persistent: true,
    awaitWriteFinish: {
      stabilityThreshold: 200,
      pollInterval: 100
    }
  });

  configWatcher
    .on('change', debounce(reloadConfigAndRefresh, 500))
    .on('error', (error) => warn('Config watcher error', error.message));
}

function startRootDiscoveryWatcher() {
  rootDiscoveryWatcher?.close().catch((error) => warn('Failed to close root watcher', error.message));
  const existingRoots = config.roots.filter((root) => fs.existsSync(root));
  if (existingRoots.length === 0) {
    rootDiscoveryWatcher = null;
    return;
  }

  const ignoredDirs = new Set(config.ignoredDirs);
  const ignored = (targetPath) => {
    const parts = targetPath.split(/[\\/]/);
    return parts.some((part) => ignoredDirs.has(part));
  };

  rootDiscoveryWatcher = chokidar.watch(existingRoots, {
    ignored,
    ignoreInitial: true,
    persistent: true,
    depth: config.scanDepth + 1
  });

  rootDiscoveryWatcher
    .on('addDir', scheduleRefreshAllProjects)
    .on('unlinkDir', scheduleRefreshAllProjects)
    .on('error', (error) => warn('Root watcher error', error.message));
}

async function publishState() {
  try {
    await saveState(state, defaultConfigDir());
  } catch (error) {
    warn('Failed to persist state', error.message);
  }

  if (floatingWindow && !floatingWindow.isDestroyed() && floatingWindow.isVisible()) {
    floatingWindow.webContents.send('devpulse:state-changed', state);
  }
}

function mergeProject(projects, updatedProject) {
  const byPath = new Map(projects.map((project) => [project.path, project]));
  byPath.set(updatedProject.path, updatedProject);
  return [...byPath.values()];
}

configureMacBackgroundMode();
app.whenReady().then(bootstrap);

app.on('window-all-closed', (event) => {
  if (!isQuitting) {
    event.preventDefault();
  }
});

app.on('before-quit', async () => {
  isQuitting = true;
  if (pollTimer) {
    clearInterval(pollTimer);
  }
  await watcher?.close();
  await configWatcher?.close();
  await rootDiscoveryWatcher?.close();
});

function registerFloatingIpc() {
  ipcMain.handle('floating:get-state', () => getFloatingState());
  ipcMain.handle('floating:toggle-always-on-top', () => {
    setFloatingAlwaysOnTop(!isAlwaysOnTop);
    return isAlwaysOnTop;
  });
  ipcMain.handle('floating:toggle-collapse', () => {
    setDisplayMode(isCollapsed ? 'full' : 'mini');
    return isCollapsed;
  });
  ipcMain.handle('floating:set-display-mode', (_event, nextMode) => {
    setDisplayMode(nextMode);
    return displayMode;
  });
  ipcMain.handle('floating:hide', () => {
    floatingWindow?.hide();
    return true;
  });
  ipcMain.handle('floating:show', () => {
    floatingWindow?.showInactive();
    return true;
  });
}

function getFloatingState() {
  return {
    isAlwaysOnTop,
    isCollapsed,
    displayMode
  };
}

function setFloatingAlwaysOnTop(enabled) {
  isAlwaysOnTop = enabled;
  floatingWindow?.setAlwaysOnTop(enabled, enabled ? 'floating' : 'normal');
  persistFloatingBounds();
  updateTrayMenu();
  floatingWindow?.webContents.send('floating:state-changed', getFloatingState());
}

function setDisplayMode(nextMode) {
  displayMode = normalizeDisplayMode(nextMode);
  isCollapsed = displayMode === 'mini';
  applyWindowSizing(true);
  persistFloatingBounds();
  updateTrayMenu();
  floatingWindow?.webContents.send('floating:collapsed-changed', isCollapsed);
  floatingWindow?.webContents.send('floating:state-changed', getFloatingState());
}

function normalizeDisplayMode(nextMode) {
  return nextMode === 'mini' ? 'mini' : 'full';
}

function restoreFloatingBounds() {
  if (!hasSavedPosition()) {
    return;
  }

  const size = isCollapsed
    ? collapsedSize
    : { width: expandedSize.width, height: resolveExpandedHeight(expandedSize.height) };
  floatingWindow.setBounds({
    x: config.floatingWindow.x,
    y: config.floatingWindow.y,
    width: size.width,
    height: size.height
  });
}

function hasSavedPosition() {
  return Number.isFinite(config.floatingWindow?.x) && Number.isFinite(config.floatingWindow?.y);
}

function persistFloatingBounds() {
  if (!floatingWindow || floatingWindow.isDestroyed()) {
    return;
  }

  const bounds = floatingWindow.getBounds();
  config = {
    ...config,
    floatingWindow: {
      x: bounds.x,
      y: bounds.y,
      alwaysOnTop: isAlwaysOnTop,
      collapsed: isCollapsed,
      displayMode
    }
  };

  saveConfig(config, defaultConfigDir()).catch((error) => warn('Failed to save floating window state', error.message));
}

function createTrayMenu() {
  tray = new Tray(nativeImage.createEmpty());
  tray.setTitle('DevPulse');
  tray.setToolTip('DevPulse');
  updateTrayMenu();
}

function updateTrayMenu() {
  if (!tray) {
    return;
  }

  tray.setContextMenu(Menu.buildFromTemplate([
    {
      label: '显示悬浮窗',
      click: () => floatingWindow?.showInactive()
    },
    {
      label: '隐藏悬浮窗',
      click: () => floatingWindow?.hide()
    },
    {
      label: '刷新项目列表',
      click: () => refreshAllProjects()
    },
    { type: 'separator' },
    {
      label: '置顶悬浮窗',
      type: 'checkbox',
      checked: isAlwaysOnTop,
      click: (item) => setFloatingAlwaysOnTop(item.checked)
    },
    {
      label: '迷你模式',
      type: 'checkbox',
      checked: displayMode === 'mini',
      click: (item) => setDisplayMode(item.checked ? 'mini' : 'full')
    },
    { type: 'separator' },
    {
      label: '退出',
      click: () => app.quit()
    }
  ]));
}

function setPositionToDesktopCorner(window) {
  const display = screen.getPrimaryDisplay();
  const margin = 24;
  const bounds = display.workArea;
  window.setPosition(
    Math.round(bounds.x + bounds.width - window.getBounds().width - margin),
    Math.round(bounds.y + margin)
  );
  persistFloatingBounds();
}

function applyWindowSizing(shouldResize = false) {
  if (!floatingWindow || floatingWindow.isDestroyed()) {
    return;
  }

  if (isCollapsed) {
    floatingWindow.setResizable(false);
    floatingWindow.setMinimumSize(collapsedSize.width, collapsedSize.height);
    floatingWindow.setMaximumSize(collapsedSize.width, collapsedSize.height);
    if (shouldResize) {
      floatingWindow.setSize(collapsedSize.width, collapsedSize.height, true);
    }
    return;
  }

  const maxHeight = maxExpandedHeight();
  const currentBounds = floatingWindow.getBounds();
  const nextHeight = clampExpandedHeight(currentBounds.height || expandedSize.height, maxHeight);

  floatingWindow.setResizable(true);
  floatingWindow.setMinimumSize(expandedSize.width, expandedSize.minHeight);
  floatingWindow.setMaximumSize(expandedSize.width, maxHeight);

  if (shouldResize || currentBounds.width !== expandedSize.width || currentBounds.height !== nextHeight) {
    floatingWindow.setSize(expandedSize.width, nextHeight, true);
  }
}

function maxExpandedHeight() {
  const display = floatingWindow
    ? screen.getDisplayMatching(floatingWindow.getBounds())
    : screen.getPrimaryDisplay();

  return Math.max(
    expandedSize.minHeight,
    Math.min(display.workArea.height - floatingWindowMargin, expandedSize.height)
  );
}

function resolveExpandedHeight(height) {
  return clampExpandedHeight(height, maxExpandedHeight());
}

function clampExpandedHeight(height, maxHeight = maxExpandedHeight()) {
  return Math.max(expandedSize.minHeight, Math.min(maxHeight, Math.round(height || expandedSize.height)));
}
