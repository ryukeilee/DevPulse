const path = require('node:path');
const { app, BrowserWindow, Menu, Tray, ipcMain, nativeImage, screen } = require('electron');
const { loadConfig, saveConfig } = require('./core/config-store');
const { discoverRepositories } = require('./core/repo-discovery');
const { buildState, emptyState, loadState, saveState } = require('./core/state-store');
const { RepoWatcher } = require('./core/repo-watcher');
const { defaultConfigDir } = require('./utils/path-utils');
const { debounce } = require('./utils/debounce');
const { log, warn } = require('./utils/logger');

const expandedSize = { width: 360, height: 260 };
const collapsedSize = { width: 260, height: 72 };

let floatingWindow = null;
let config = null;
let state = emptyState();
let watcher = null;
let pollTimer = null;
let tray = null;
let isAlwaysOnTop = true;
let isCollapsed = false;
let isQuitting = false;
let saveFloatingBounds = null;

async function createFloatingWindow() {
  isAlwaysOnTop = config.floatingWindow.alwaysOnTop;
  isCollapsed = config.floatingWindow.collapsed;
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
  floatingWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: false });
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
  if (process.platform === 'darwin') {
    app.setActivationPolicy('accessory');
    app.dock.hide();
  }

  const configDir = defaultConfigDir();
  config = await loadConfig(configDir);
  state = await loadState(configDir);

  ipcMain.handle('devpulse:get-state', () => state);
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

app.whenReady().then(bootstrap);

app.on('window-all-closed', (event) => {
  event.preventDefault();
});

app.on('before-quit', async () => {
  isQuitting = true;
  if (pollTimer) {
    clearInterval(pollTimer);
  }
  await watcher?.close();
});

function registerFloatingIpc() {
  ipcMain.handle('floating:get-state', () => getFloatingState());
  ipcMain.handle('floating:toggle-always-on-top', () => {
    setFloatingAlwaysOnTop(!isAlwaysOnTop);
    return isAlwaysOnTop;
  });
  ipcMain.handle('floating:toggle-collapse', () => {
    setCollapsed(!isCollapsed);
    return isCollapsed;
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
    isCollapsed
  };
}

function setFloatingAlwaysOnTop(enabled) {
  isAlwaysOnTop = enabled;
  floatingWindow?.setAlwaysOnTop(enabled, enabled ? 'floating' : 'normal');
  persistFloatingBounds();
  updateTrayMenu();
  floatingWindow?.webContents.send('floating:state-changed', getFloatingState());
}

function setCollapsed(next) {
  isCollapsed = next;
  const size = next ? collapsedSize : expandedSize;
  floatingWindow?.setSize(size.width, size.height, true);
  persistFloatingBounds();
  updateTrayMenu();
  floatingWindow?.webContents.send('floating:collapsed-changed', next);
  floatingWindow?.webContents.send('floating:state-changed', getFloatingState());
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
      collapsed: isCollapsed
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
    { type: 'separator' },
    {
      label: '置顶悬浮窗',
      type: 'checkbox',
      checked: isAlwaysOnTop,
      click: (item) => setFloatingAlwaysOnTop(item.checked)
    },
    {
      label: '折叠悬浮窗',
      type: 'checkbox',
      checked: isCollapsed,
      click: (item) => setCollapsed(item.checked)
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
