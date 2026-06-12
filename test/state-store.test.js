const test = require('node:test');
const assert = require('node:assert/strict');
const { buildState } = require('../src/core/state-store');

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
