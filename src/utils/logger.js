function log(...args) {
  console.log('[DevPulse]', ...args);
}

function warn(...args) {
  console.warn('[DevPulse]', ...args);
}

module.exports = { log, warn };
