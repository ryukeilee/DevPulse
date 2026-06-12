const test = require('node:test');
const assert = require('node:assert/strict');
const { classifyChanges } = require('../src/core/change-classifier');

test('refresh files match refresh scheduling summary', () => {
  const result = classifyChanges(['src/core/refresh-scheduler.js']);
  assert.equal(result.title, '刷新调度优化');
});

test('menu files match menu and interface summary', () => {
  const result = classifyChanges(['src/notification/menu-bar-presenter.js']);
  assert.equal(result.title, '菜单与界面调整');
});

test('log and debug files match diagnostics summary', () => {
  const result = classifyChanges(['src/utils/debug-logger.js']);
  assert.equal(result.title, '日志与诊断能力');
});

test('README files match docs summary', () => {
  const result = classifyChanges(['README.md']);
  assert.equal(result.title, '文档更新');
});

test('multiple categories compose a combined summary', () => {
  const result = classifyChanges([
    'src/core/refresh-scheduler.js',
    'src/session/monitor-service.js',
    'src/notification/menu-bar-presenter.js'
  ]);

  assert.equal(result.title, '刷新链路与菜单状态');
  assert.deepEqual(result.tags, ['refresh', 'menu']);
});

test('config and docs compose a natural summary', () => {
  const result = classifyChanges([
    'README.md',
    'apps/api/src/config/configuration.ts'
  ]);

  assert.equal(result.title, '配置与文档更新');
});

test('unknown files fall back to generic project change summary', () => {
  const result = classifyChanges(['src/core/alpha.js']);
  assert.equal(result.title, '项目文件改动');
});
