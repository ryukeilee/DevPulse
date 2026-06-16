const test = require('node:test');
const assert = require('node:assert/strict');
const {
  MAX_ACTIVITY_RECORDS,
  maybeRecordActivity,
  summarizeActivityChange,
  updateActivityTimeline
} = require('../src/core/activity-timeline');

test('records activity when changed files appear', () => {
  const activities = updateActivityTimeline([
    project('devpulse', {
      dirty: true,
      changedFiles: ['src/core/repo-watcher.js', 'src/core/git-status-reader.js']
    })
  ], emptyPreviousState(), new Date('2026-06-16T10:00:00.000Z'));

  assert.equal(activities.length, 1);
  assert.equal(activities[0].projectName, 'devpulse');
  assert.equal(activities[0].repoPath, '/tmp/devpulse');
  assert.equal(activities[0].changedFileCount, 2);
  assert.deepEqual(activities[0].changedFiles, ['src/core/git-status-reader.js', 'src/core/repo-watcher.js']);
  assert.equal(activities[0].changeTypeSummary, 'Git 监听与扫描调整');
  assert.equal(activities[0].createdAt, '2026-06-16T10:00:00.000Z');
});

test('does not record unchanged dirty projects on refresh', () => {
  const previousState = {
    projects: [
      project('devpulse', {
        dirty: true,
        changedFiles: ['src/renderer/widget.js']
      })
    ],
    activities: [
      activity({
        changedFiles: ['src/renderer/widget.js'],
        createdAt: '2026-06-16T09:00:00.000Z'
      })
    ]
  };

  const activities = updateActivityTimeline([
    project('devpulse', {
      dirty: true,
      changedFiles: ['src/renderer/widget.js']
    })
  ], previousState, new Date('2026-06-16T10:00:00.000Z'));

  assert.equal(activities.length, 1);
  assert.equal(activities[0].createdAt, '2026-06-16T09:00:00.000Z');
});

test('deduplicates same repo and same changed file set within two minutes', () => {
  const existing = activity({
    changedFiles: ['src/renderer/widget.js'],
    createdAt: '2026-06-16T10:00:00.000Z'
  });

  const activities = maybeRecordActivity([
    existing
  ], project('devpulse', {
    dirty: true,
    changedFiles: ['src/renderer/widget.js'],
    activityObservedAt: '2026-06-16T10:01:30.000Z'
  }), project('devpulse', {
    dirty: true,
    changedFiles: ['src/renderer/widget.js']
  }));

  assert.equal(activities.length, 1);
  assert.equal(activities[0].id, existing.id);
  assert.equal(activities[0].createdAt, '2026-06-16T10:01:30.000Z');
});

test('deduplicates matching activity even when another repo is newer', () => {
  const matching = activity({
    id: 'matching',
    changedFiles: ['src/renderer/widget.js'],
    createdAt: '2026-06-16T10:00:00.000Z'
  });
  const newerOtherRepo = {
    ...activity({
      id: 'other',
      changedFiles: ['src/core/state-store.js'],
      createdAt: '2026-06-16T10:00:30.000Z'
    }),
    projectName: 'other',
    repoPath: '/tmp/other'
  };

  const activities = maybeRecordActivity([
    newerOtherRepo,
    matching
  ], project('devpulse', {
    dirty: true,
    changedFiles: ['src/renderer/widget.js'],
    activityObservedAt: '2026-06-16T10:01:30.000Z'
  }), project('devpulse', {
    dirty: true,
    changedFiles: ['src/renderer/widget.js']
  }));

  assert.equal(activities.length, 2);
  assert.equal(activities[0].id, 'matching');
  assert.equal(activities[0].createdAt, '2026-06-16T10:01:30.000Z');
  assert.equal(activities[1].id, 'other');
});

test('keeps a new record for same changed file set after two minutes', () => {
  const activities = maybeRecordActivity([
    activity({
      changedFiles: ['src/renderer/widget.js'],
      createdAt: '2026-06-16T10:00:00.000Z'
    })
  ], project('devpulse', {
    dirty: true,
    changedFiles: ['src/renderer/widget.js'],
    activityObservedAt: '2026-06-16T10:03:00.000Z'
  }), project('devpulse', {
    dirty: true,
    changedFiles: ['src/renderer/widget.js']
  }));

  assert.equal(activities.length, 2);
  assert.equal(activities[0].createdAt, '2026-06-16T10:03:00.000Z');
});

test('keeps at most thirty records', () => {
  const previousActivities = Array.from({ length: MAX_ACTIVITY_RECORDS }, (_, index) => {
    return activity({
      id: `old-${index}`,
      changedFiles: [`old-${index}.js`],
      createdAt: `2026-06-16T09:${String(index).padStart(2, '0')}:00.000Z`
    });
  });

  const activities = updateActivityTimeline([
    project('devpulse', {
      dirty: true,
      changedFiles: ['src/core/state-store.js']
    })
  ], {
    projects: [],
    activities: previousActivities
  }, new Date('2026-06-16T10:00:00.000Z'));

  assert.equal(activities.length, MAX_ACTIVITY_RECORDS);
  assert.equal(activities[0].changedFiles[0], 'src/core/state-store.js');
  assert.equal(activities.at(-1).id, 'old-28');
});

test('summarizes activity by local filename rules', () => {
  assert.equal(summarizeActivityChange(['src/renderer/widget.js']), '菜单与界面调整');
  assert.equal(summarizeActivityChange(['src/core/repo-watcher.js']), 'Git 监听与扫描调整');
  assert.equal(summarizeActivityChange(['src/core/state-store.js']), '本地存储调整');
  assert.equal(summarizeActivityChange(['src/utils/debug-logger.js']), '日志与诊断调整');
  assert.equal(summarizeActivityChange(['src/main.js']), '项目配置或主进程调整');
  assert.equal(summarizeActivityChange(['README.md']), 'Git 工作区改动');
});

function emptyPreviousState() {
  return {
    projects: [],
    activities: []
  };
}

function project(name, overrides = {}) {
  return {
    name,
    path: `/tmp/${name}`,
    branch: 'main',
    dirty: false,
    changedFiles: [],
    ...overrides
  };
}

function activity(overrides = {}) {
  return {
    id: 'activity-1',
    projectName: 'devpulse',
    repoPath: '/tmp/devpulse',
    changedFileCount: 1,
    changedFiles: ['src/renderer/widget.js'],
    changeTypeSummary: '菜单与界面调整',
    createdAt: '2026-06-16T10:00:00.000Z',
    ...overrides
  };
}
