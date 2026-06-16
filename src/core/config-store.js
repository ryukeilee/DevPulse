const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { defaultConfigDir, expandHome } = require('../utils/path-utils');

const DEFAULT_IGNORED_DIRS = [
  'node_modules',
  '.git',
  'dist',
  'build',
  '.next',
  '.turbo',
  'coverage'
];

function defaultConfig() {
  return {
    roots: [
      path.join(os.homedir(), 'Projects'),
      path.join(os.homedir(), 'Developer'),
      path.join(os.homedir(), 'Code'),
      path.join(os.homedir(), 'Documents', 'GitHub')
    ],
    ignoredDirs: DEFAULT_IGNORED_DIRS,
    scanDepth: 3,
    maxRecentFiles: 3,
    refreshDebounceMs: 1000,
    pollFallbackMs: 30000,
    notificationsEnabled: false,
    openAtLogin: false,
    dataRetentionDays: 14,
    floatingWindow: {
      x: null,
      y: null,
      alwaysOnTop: true,
      collapsed: false,
      displayMode: 'full'
    }
  };
}

async function loadConfig(configDir = defaultConfigDir()) {
  await fs.mkdir(configDir, { recursive: true });
  const configPath = path.join(configDir, 'config.json');

  try {
    const raw = await fs.readFile(configPath, 'utf8');
    const parsed = JSON.parse(raw);
    return normalizeConfig({ ...defaultConfig(), ...parsed }, configPath);
  } catch (error) {
    if (error.code === 'ENOENT') {
      const config = defaultConfig();
      await fs.writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`);
      return normalizeConfig(config, configPath);
    }

    return normalizeConfig(defaultConfig(), configPath);
  }
}

async function saveConfig(config, configDir = defaultConfigDir()) {
  await fs.mkdir(configDir, { recursive: true });
  const configPath = config.configPath || path.join(configDir, 'config.json');
  const { configPath: _configPath, ...serializableConfig } = config;
  await fs.writeFile(configPath, `${JSON.stringify(serializableConfig, null, 2)}\n`);
}

function normalizeConfig(config, configPath) {
  return {
    ...config,
    configPath,
    roots: [...new Set((config.roots || []).map(expandHome))],
    ignoredDirs: [...new Set(config.ignoredDirs || DEFAULT_IGNORED_DIRS)],
    scanDepth: Number.isInteger(config.scanDepth) ? config.scanDepth : 3,
    maxRecentFiles: Number.isInteger(config.maxRecentFiles) ? config.maxRecentFiles : 3,
    refreshDebounceMs: Number.isInteger(config.refreshDebounceMs) ? config.refreshDebounceMs : 1000,
    pollFallbackMs: Number.isInteger(config.pollFallbackMs) ? config.pollFallbackMs : 30000,
    notificationsEnabled: typeof config.notificationsEnabled === 'boolean' ? config.notificationsEnabled : false,
    openAtLogin: typeof config.openAtLogin === 'boolean' ? config.openAtLogin : false,
    dataRetentionDays: normalizeDataRetentionDays(config.dataRetentionDays),
    floatingWindow: normalizeFloatingWindow(config.floatingWindow)
  };
}

function normalizeDataRetentionDays(days) {
  if (!Number.isInteger(days)) {
    return 14;
  }

  return Math.min(90, Math.max(1, days));
}

function normalizeFloatingWindow(floatingWindow = {}) {
  const displayMode = ['full', 'mini'].includes(floatingWindow.displayMode)
    ? floatingWindow.displayMode
    : 'full';

  return {
    x: Number.isFinite(floatingWindow.x) ? floatingWindow.x : null,
    y: Number.isFinite(floatingWindow.y) ? floatingWindow.y : null,
    alwaysOnTop: typeof floatingWindow.alwaysOnTop === 'boolean' ? floatingWindow.alwaysOnTop : true,
    collapsed: displayMode === 'mini',
    displayMode
  };
}

module.exports = {
  DEFAULT_IGNORED_DIRS,
  defaultConfig,
  loadConfig,
  saveConfig
};
