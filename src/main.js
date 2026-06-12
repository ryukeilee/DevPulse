const path = require('node:path');
const { app, BrowserWindow, ipcMain } = require('electron');
const { loadConfig } = require('./core/config-store');
const { discoverRepositories } = require('./core/repo-discovery');
const { buildState, emptyState, loadState, saveState } = require('./core/state-store');
const { RepoWatcher } = require('./core/repo-watcher');
const { defaultConfigDir } = require('./utils/path-utils');
const { log, warn } = require('./utils/logger');

let mainWindow = null;
let config = null;
let state = emptyState();
let watcher = null;
let pollTimer = null;

async function createWindow() {
  mainWindow = new BrowserWindow({
    width: 300,
    height: 240,
    frame: false,
    transparent: true,
    resizable: false,
    skipTaskbar: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  mainWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: false });
  mainWindow.setSkipTaskbar(true);
  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  mainWindow.once('ready-to-show', () => {
    mainWindow.setPositionToDesktopCorner?.();
    mainWindow.showInactive();
  });
}

async function bootstrap() {
  if (process.platform === 'darwin') {
    app.dock.hide();
  }

  const configDir = defaultConfigDir();
  config = await loadConfig(configDir);
  state = await loadState(configDir);

  ipcMain.handle('devpulse:get-state', () => state);

  await createWindow();
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
  mainWindow?.webContents.send('devpulse:state-changed', state);
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
  if (pollTimer) {
    clearInterval(pollTimer);
  }
  await watcher?.close();
});

BrowserWindow.prototype.setPositionToDesktopCorner = function setPositionToDesktopCorner() {
  const { screen } = require('electron');
  const display = screen.getPrimaryDisplay();
  const margin = 24;
  const bounds = display.workArea;
  this.setPosition(
    Math.round(bounds.x + bounds.width - this.getBounds().width - margin),
    Math.round(bounds.y + margin)
  );
};
