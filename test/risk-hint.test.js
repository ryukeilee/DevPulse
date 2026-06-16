const test = require('node:test');
const assert = require('node:assert/strict');
const { assessRiskHint } = require('../src/core/risk-hint');

test('returns low risk when there are no changed files', () => {
  const hint = assessRiskHint([]);

  assert.equal(hint.level, 'low');
  assert.equal(hint.message, '暂无明显风险');
  assert.deepEqual(hint.matchedRules, ['no-risk']);
  assert.deepEqual(hint.matchedFiles, []);
});

test('sensitive config takes highest priority', () => {
  const hint = assessRiskHint([
    'package.json',
    '.env.local'
  ]);

  assert.equal(hint.level, 'high');
  assert.equal(hint.message, '敏感配置相关文件发生变化，建议确认没有泄露敏感信息。');
  assert.deepEqual(hint.matchedRules, ['sensitive-config']);
  assert.deepEqual(hint.matchedFiles, ['.env.local']);
});

test('dependency and build config files are high risk', () => {
  const hint = assessRiskHint(['package-lock.json']);

  assert.equal(hint.level, 'high');
  assert.deepEqual(hint.matchedRules, ['dependency-or-build-config']);
  assert.deepEqual(hint.matchedFiles, ['package-lock.json']);
});

test('electron main and preload files are high risk', () => {
  const hint = assessRiskHint(['src/preload.js', 'src/renderer/widget.js']);

  assert.equal(hint.level, 'high');
  assert.deepEqual(hint.matchedRules, ['electron-main-or-preload']);
  assert.deepEqual(hint.matchedFiles, ['src/preload.js']);
});

test('large change set is high risk after higher priority rules do not match', () => {
  const hint = assessRiskHint(Array.from({ length: 10 }, (_, index) => `src/feature/file-${index}.js`));

  assert.equal(hint.level, 'high');
  assert.deepEqual(hint.matchedRules, ['large-change-set']);
  assert.equal(hint.matchedFiles.length, 10);
});

test('storage, git scanner, and config changes use medium risk priority order', () => {
  const storageHint = assessRiskHint(['src/core/state-store.js', 'src/core/git-status-reader.js']);
  const gitHint = assessRiskHint(['src/core/repo-watcher.js', 'src/settings/view.js']);
  const configHint = assessRiskHint(['src/settings/preferences.js']);

  assert.equal(storageHint.level, 'medium');
  assert.deepEqual(storageHint.matchedRules, ['storage-change']);
  assert.equal(gitHint.level, 'medium');
  assert.deepEqual(gitHint.matchedRules, ['git-scanner-change']);
  assert.equal(configHint.level, 'medium');
  assert.deepEqual(configHint.matchedRules, ['config-change']);
});
