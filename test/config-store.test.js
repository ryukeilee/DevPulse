const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const { loadConfig, saveConfig } = require('../src/core/config-store');

test('loadConfig defaults floating displayMode to full', async () => {
  const configDir = await makeConfigDir();
  const config = await loadConfig(configDir);

  assert.equal(config.floatingWindow.displayMode, 'full');
  assert.equal(config.floatingWindow.collapsed, false);
  assert.equal(config.notificationsEnabled, false);
  assert.equal(config.openAtLogin, false);
  assert.equal(config.dataRetentionDays, 14);
});

test('loadConfig keeps persisted mini displayMode', async () => {
  const configDir = await makeConfigDir();
  await fs.writeFile(path.join(configDir, 'config.json'), `${JSON.stringify({
    floatingWindow: {
      displayMode: 'mini'
    }
  })}\n`);

  const config = await loadConfig(configDir);

  assert.equal(config.floatingWindow.displayMode, 'mini');
  assert.equal(config.floatingWindow.collapsed, true);
});

test('loadConfig falls back to full for invalid displayMode', async () => {
  const configDir = await makeConfigDir();
  await fs.writeFile(path.join(configDir, 'config.json'), `${JSON.stringify({
    floatingWindow: {
      displayMode: 'compact'
    }
  })}\n`);

  const config = await loadConfig(configDir);

  assert.equal(config.floatingWindow.displayMode, 'full');
  assert.equal(config.floatingWindow.collapsed, false);
});

test('loadConfig falls back to full when local settings cannot be parsed', async () => {
  const configDir = await makeConfigDir();
  await fs.writeFile(path.join(configDir, 'config.json'), '{');

  const config = await loadConfig(configDir);

  assert.equal(config.floatingWindow.displayMode, 'full');
  assert.equal(config.floatingWindow.collapsed, false);
});

test('saveConfig persists floating displayMode locally', async () => {
  const configDir = await makeConfigDir();
  const config = await loadConfig(configDir);

  await saveConfig({
    ...config,
    floatingWindow: {
      ...config.floatingWindow,
      displayMode: 'mini',
      collapsed: true
    }
  }, configDir);

  const saved = JSON.parse(await fs.readFile(path.join(configDir, 'config.json'), 'utf8'));
  assert.equal(saved.floatingWindow.displayMode, 'mini');
});

test('loadConfig keeps local settings values', async () => {
  const configDir = await makeConfigDir();
  await fs.writeFile(path.join(configDir, 'config.json'), `${JSON.stringify({
    pollFallbackMs: 60000,
    notificationsEnabled: true,
    openAtLogin: true,
    dataRetentionDays: 30
  })}\n`);

  const config = await loadConfig(configDir);

  assert.equal(config.pollFallbackMs, 60000);
  assert.equal(config.notificationsEnabled, true);
  assert.equal(config.openAtLogin, true);
  assert.equal(config.dataRetentionDays, 30);
});

test('loadConfig clamps data retention days', async () => {
  const configDir = await makeConfigDir();
  await fs.writeFile(path.join(configDir, 'config.json'), `${JSON.stringify({
    dataRetentionDays: 120
  })}\n`);

  const config = await loadConfig(configDir);

  assert.equal(config.dataRetentionDays, 90);
});

async function makeConfigDir() {
  return fs.mkdtemp(path.join(os.tmpdir(), 'devpulse-config-'));
}
