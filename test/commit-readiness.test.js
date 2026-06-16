const test = require('node:test');
const assert = require('node:assert/strict');
const { assessCommitReadiness, classifyReadinessCategories } = require('../src/core/commit-readiness');

test('returns empty readiness when there are no changed files', () => {
  const readiness = assessCommitReadiness([]);

  assert.equal(readiness.status, 'empty');
  assert.equal(readiness.statusLabel, '暂无待提交改动');
  assert.equal(readiness.message, '');
  assert.equal(readiness.changedFileCount, 0);
  assert.deepEqual(readiness.categories, []);
  assert.deepEqual(readiness.matchedRules, ['empty']);
});

test('dependency and build config files block commit readiness', () => {
  const readiness = assessCommitReadiness(['src/renderer/widget.js', 'package-lock.json']);

  assert.equal(readiness.status, 'blocked');
  assert.equal(readiness.message, '依赖或构建配置已变更，建议完成安装与构建验证后再提交。');
  assert.deepEqual(readiness.matchedRules, ['dependency-or-build-config']);
});

test('electron main and preload changes block commit readiness', () => {
  const readiness = assessCommitReadiness(['src/preload.js', 'src/renderer/widget.js']);

  assert.equal(readiness.status, 'blocked');
  assert.equal(readiness.message, '主进程或 Electron 配置已变更，建议验证启动、窗口行为和关闭逻辑后再提交。');
  assert.deepEqual(readiness.matchedRules, ['electron-main-or-preload']);
});

test('storage changes block before large and multi-category review rules', () => {
  const readiness = assessCommitReadiness([
    'src/core/state-store.js',
    'src/core/git-status-reader.js',
    'src/renderer/widget.js',
    'src/renderer/widget.css',
    'src/core/file-1.js',
    'src/core/file-2.js',
    'src/core/file-3.js',
    'src/core/file-4.js',
    'src/core/file-5.js',
    'src/core/file-6.js'
  ]);

  assert.equal(readiness.status, 'blocked');
  assert.deepEqual(readiness.matchedRules, ['storage-change']);
});

test('large change sets use review when higher priority rules do not match', () => {
  const readiness = assessCommitReadiness(Array.from({ length: 10 }, (_, index) => {
    return `src/feature/file-${index}.js`;
  }));

  assert.equal(readiness.status, 'review');
  assert.deepEqual(readiness.matchedRules, ['large-change-set']);
});

test('multi-category changes suggest checking split commits', () => {
  const readiness = assessCommitReadiness([
    'src/renderer/widget.js',
    'src/core/git-status-reader.js'
  ]);

  assert.equal(readiness.status, 'review');
  assert.deepEqual(readiness.categories, ['git', 'ui']);
  assert.deepEqual(readiness.matchedRules, ['multi-category-change']);
});

test('git scanner changes suggest validation when focused in git scanning logic', () => {
  const readiness = assessCommitReadiness(['src/core/repo-watcher.js']);

  assert.equal(readiness.status, 'review');
  assert.equal(readiness.message, 'Git 扫描逻辑已变更，建议验证刷新和改动识别后提交。');
  assert.deepEqual(readiness.matchedRules, ['git-scanner-change']);
});

test('ui focused changes are ready', () => {
  const readiness = assessCommitReadiness([
    'src/renderer/widget.js',
    'src/renderer/widget.css'
  ]);

  assert.equal(readiness.status, 'ready');
  assert.equal(readiness.statusLabel, '适合提交');
  assert.deepEqual(readiness.categories, ['ui']);
  assert.deepEqual(readiness.matchedRules, ['ui-focused-change']);
});

test('docs only changes are ready', () => {
  const readiness = assessCommitReadiness(['README.md', 'docs/usage.md']);

  assert.equal(readiness.status, 'ready');
  assert.equal(readiness.message, '文档类改动，适合直接提交。');
  assert.deepEqual(readiness.categories, ['docs']);
  assert.deepEqual(readiness.matchedRules, ['docs-only-change']);
});

test('unknown changes fall back to generic review', () => {
  const readiness = assessCommitReadiness(['src/core/activity-ranker.js']);

  assert.equal(readiness.status, 'review');
  assert.deepEqual(readiness.categories, []);
  assert.deepEqual(readiness.matchedRules, ['generic-review']);
});

test('category classifier only uses changed file paths and names', () => {
  const categories = classifyReadinessCategories([
    'src/renderer/widget.css',
    'src/core/state-store.js',
    'src/core/git-status-reader.js',
    'README.md'
  ]);

  assert.deepEqual(categories, ['docs', 'git', 'storage', 'ui']);
});
