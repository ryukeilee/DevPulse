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

const expandedSize = { width: 360, height: 380 };
const collapsedSize = { width: 300, height: 72 };

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
    height: size.height,
    minWidth: collapsedSize.width,
    minHeight: collapsedSize.height,
    frame: false,
    transparent: true,
    resizable: false,
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
  floatingWindow.setVisibleOnAllWorkspaces(true, {
    visibleOnFullScreen: false,
    skipTransformProcessType: true
  });
  floatingWindow.setSkipTaskbar(true);
  floatingWindow.setMenuBarVisibility(false);

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

  ipcMain.handle('devpulse:get-state', () => state);
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
  await saveState(state, defaultConfigDir());
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
  const size = isCollapsed ? collapsedSize : expandedSize;
  floatingWindow?.setSize(size.width, size.height, true);
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

  const size = isCollapsed ? collapsedSize : expandedSize;
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
