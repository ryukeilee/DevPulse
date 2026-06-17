const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { buildState, loadState } = require('../src/core/state-store');

test('full refresh preserves stale dirty activity when changed files are unchanged', () => {
  const previousState = {
    projects: [
      project('old-dirty', {
        dirty: true,
        changedEntries: [{ status: 'M', path: 'README.md' }],
        changedFiles: ['README.md'],
        lastActivityAt: '2026-06-12T11:00:00.000Z'
      })
    ],
    activeProjectPath: '/tmp/old-dirty',
    updatedAt: '2026-06-12T11:00:00.000Z'
  };

  const next = buildState([
    project('old-dirty', {
      dirty: true,
      changedEntries: [{ status: 'M', path: 'README.md' }],
      changedFiles: ['README.md']
    })
  ], previousState, new Date('2026-06-12T12:00:00.000Z'));

  assert.equal(next.projects[0].lastActivityAt, '2026-06-12T11:00:00.000Z');
});

test('watcher-observed activity outranks stale dirty projects', () => {
  const previousState = {
    projects: [
      project('stale-dirty', {
        dirty: true,
        changedEntries: [{ status: 'M', path: 'README.md' }],
        changedFiles: ['README.md'],
        lastActivityAt: '2026-06-12T11:00:00.000Z'
      }),
      project('devpulse', {
        dirty: false,
        lastActivityAt: '2026-06-12T10:00:00.000Z'
      })
    ],
    activeProjectPath: '/tmp/stale-dirty',
    updatedAt: '2026-06-12T11:00:00.000Z'
  };

  const next = buildState([
    project('stale-dirty', {
      dirty: true,
      changedEntries: [{ status: 'M', path: 'README.md' }],
      changedFiles: ['README.md']
    }),
    project('devpulse', {
      dirty: true,
      changedEntries: [{ status: 'M', path: 'src/main.js' }],
      changedFiles: ['src/main.js'],
      activityObservedAt: '2026-06-12T12:00:00.000Z'
    })
  ], previousState, new Date('2026-06-12T12:00:00.000Z'));

  assert.equal(next.activeProjectPath, '/tmp/devpulse');
  assert.equal(next.projects[0].name, 'devpulse');
});

test('buildState includes recent activity records', () => {
  const next = buildState([
    project('devpulse', {
      dirty: true,
      changedEntries: [{ status: 'M', path: 'src/core/state-store.js' }],
      changedFiles: ['src/core/state-store.js']
    })
  ], {
    projects: [],
    activities: [],
    activeProjectPath: null,
    updatedAt: '2026-06-12T11:00:00.000Z'
  }, new Date('2026-06-12T12:00:00.000Z'));

  assert.equal(next.activityTimeline.length, 1);
  assert.equal(next.activities.length, 1);
  assert.equal(next.activities[0].projectName, 'devpulse');
  assert.equal(next.activities[0].changedFileCount, 1);
  assert.equal(next.activities[0].summary, '本地改动');
  assert.deepEqual(next.activities, next.activityTimeline);
});

test('loadState safely degrades to empty timeline when state file is corrupted', async () => {
  const configDir = await fs.mkdtemp(path.join(os.tmpdir(), 'devpulse-state-'));
  await fs.writeFile(path.join(configDir, 'state.json'), '{not-json');

  const state = await loadState(configDir);

  assert.deepEqual(state.projects, []);
  assert.deepEqual(state.activityTimeline, []);
  assert.deepEqual(state.activities, []);
  assert.equal(state.activeProjectPath, null);
});

test('buildState includes risk hints from changed files', () => {
  const next = buildState([
    project('devpulse', {
      dirty: true,
      changedEntries: [{ status: 'M', path: 'src/preload.js' }],
      changedFiles: ['src/preload.js']
    })
  ], {
    projects: [],
    activities: [],
    activeProjectPath: null,
    updatedAt: '2026-06-12T11:00:00.000Z'
  }, new Date('2026-06-12T12:00:00.000Z'));

  assert.equal(next.projects[0].riskHint.level, 'high');
  assert.equal(next.projects[0].riskHint.message, '主进程或 Electron 配置已变更，建议重点验证窗口行为与启动流程。');
  assert.deepEqual(next.projects[0].riskHint.matchedRules, ['electron-main-or-preload']);
  assert.deepEqual(next.projects[0].riskHint.matchedFiles, ['src/preload.js']);
});

test('buildState includes commit readiness from changed files', () => {
  const next = buildState([
    project('devpulse', {
      dirty: true,
      changedEntries: [{ status: 'M', path: 'README.md' }],
      changedFiles: ['README.md']
    })
  ], {
    projects: [],
    activities: [],
    activeProjectPath: null,
    updatedAt: '2026-06-12T11:00:00.000Z'
  }, new Date('2026-06-12T12:00:00.000Z'));

  assert.equal(next.projects[0].commitReadiness.status, 'ready');
  assert.equal(next.projects[0].commitReadiness.statusLabel, '适合提交');
  assert.equal(next.projects[0].commitReadiness.message, '文档类改动，适合直接提交。');
  assert.deepEqual(next.projects[0].commitReadiness.matchedRules, ['docs-only-change']);
});

function project(name, overrides = {}) {
  return {
    name,
    path: `/tmp/${name}`,
    branch: 'main',
    dirty: false,
    changedEntries: [],
    changedFiles: [],
    lastCommitMessage: '',
    lastCommitAt: null,
    ...overrides
  };
}
