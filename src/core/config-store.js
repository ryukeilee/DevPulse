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
    pollFallbackMs: 30000
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
    if (error.code !== 'ENOENT') {
      throw error;
    }

    const config = defaultConfig();
    await fs.writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`);
    return normalizeConfig(config, configPath);
  }
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
    pollFallbackMs: Number.isInteger(config.pollFallbackMs) ? config.pollFallbackMs : 30000
  };
}

module.exports = {
  DEFAULT_IGNORED_DIRS,
  defaultConfig,
  loadConfig
};
