const os = require('node:os');
const path = require('node:path');

function expandHome(inputPath) {
  if (!inputPath || inputPath === '~') {
    return os.homedir();
  }

  if (inputPath.startsWith('~/')) {
    return path.join(os.homedir(), inputPath.slice(2));
  }

  return inputPath;
}

function defaultConfigDir(appName = 'DevPulse') {
  return path.join(os.homedir(), 'Library', 'Application Support', appName);
}

function basenameOnly(filePath) {
  return path.basename(filePath || '');
}

module.exports = {
  basenameOnly,
  defaultConfigDir,
  expandHome
};
