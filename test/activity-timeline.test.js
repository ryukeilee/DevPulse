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
  assert.equal(activities[0].projectPath, '/tmp/devpulse');
  assert.equal(activities[0].changedFileCount, 2);
  assert.deepEqual(activities[0].files, ['src/core/git-status-reader.js', 'src/core/repo-watcher.js']);
  assert.equal(activities[0].summary, '监听与扫描优化');
  assert.equal(activities[0].createdAt, '2026-06-16T10:00:00.000Z');
  assert.equal(activities[0].updatedAt, '2026-06-16T10:00:00.000Z');
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
        files: ['src/renderer/widget.js'],
        createdAt: '2026-06-16T09:00:00.000Z',
        updatedAt: '2026-06-16T09:00:00.000Z'
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

test('debounce-merges same repo activity within ninety seconds', () => {
  const existing = activity({
    files: ['src/renderer/widget.js'],
    createdAt: '2026-06-16T10:00:00.000Z',
    updatedAt: '2026-06-16T10:00:00.000Z'
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
  assert.equal(activities[0].createdAt, '2026-06-16T10:00:00.000Z');
  assert.equal(activities[0].updatedAt, '2026-06-16T10:01:30.000Z');
});

test('same project continuous changes do not create multiple rows', () => {
  const activities = maybeRecordActivity([
    activity({
      files: ['src/renderer/widget.js'],
      createdAt: '2026-06-16T10:00:00.000Z',
      updatedAt: '2026-06-16T10:00:00.000Z'
    })
  ], project('devpulse', {
    dirty: true,
    changedFiles: ['src/renderer/widget.js', 'src/renderer/widget.css'],
    activityObservedAt: '2026-06-16T10:01:10.000Z'
  }), project('devpulse', {
    dirty: true,
    changedFiles: ['src/renderer/widget.js']
  }));

  assert.equal(activities.length, 1);
  assert.deepEqual(activities[0].files, ['src/renderer/widget.css', 'src/renderer/widget.js']);
  assert.equal(activities[0].summary, '界面优化');
  assert.equal(activities[0].updatedAt, '2026-06-16T10:01:10.000Z');
});

test('deduplicates matching activity even when another repo is newer', () => {
  const matching = activity({
    id: 'matching',
    files: ['src/renderer/widget.js'],
    createdAt: '2026-06-16T10:00:00.000Z',
    updatedAt: '2026-06-16T10:00:00.000Z'
  });
  const newerOtherRepo = {
    ...activity({
      id: 'other',
      files: ['src/core/state-store.js'],
      summary: '本地改动',
      createdAt: '2026-06-16T10:00:30.000Z',
      updatedAt: '2026-06-16T10:00:30.000Z'
    }),
    projectName: 'other',
    projectPath: '/tmp/other',
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
  assert.equal(activities[0].updatedAt, '2026-06-16T10:01:30.000Z');
  assert.equal(activities[1].id, 'other');
});

test('keeps a new record for same project activity after debounce window', () => {
  const activities = maybeRecordActivity([
    activity({
      files: ['src/renderer/widget.js'],
      createdAt: '2026-06-16T10:00:00.000Z',
      updatedAt: '2026-06-16T10:00:00.000Z'
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

test('keeps at most ten records', () => {
  const previousActivities = Array.from({ length: MAX_ACTIVITY_RECORDS }, (_, index) => {
    return activity({
      id: `old-${index}`,
      files: [`old-${index}.js`],
      summary: '本地改动',
      createdAt: `2026-06-16T09:${String(index).padStart(2, '0')}:00.000Z`,
      updatedAt: `2026-06-16T09:${String(index).padStart(2, '0')}:00.000Z`
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
  assert.equal(activities[0].files[0], 'src/core/state-store.js');
  assert.equal(activities.at(-1).id, 'old-1');
});

test('summarizes activity by local filename rules', () => {
  assert.equal(summarizeActivityChange(['package.json']), '配置调整');
  assert.equal(summarizeActivityChange(['src/renderer/widget.js']), '界面优化');
  assert.equal(summarizeActivityChange(['src/core/repo-watcher.js']), '监听与扫描优化');
  assert.equal(summarizeActivityChange(['test/activity-timeline.test.js']), '测试更新');
  assert.equal(summarizeActivityChange(['README.md']), '本地改动');
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
    projectPath: '/tmp/devpulse',
    repoPath: '/tmp/devpulse',
    summary: '界面优化',
    files: ['src/renderer/widget.js'],
    changedFileCount: 1,
    changedFiles: ['src/renderer/widget.js'],
    changeTypeSummary: '界面优化',
    createdAt: '2026-06-16T10:00:00.000Z',
    updatedAt: '2026-06-16T10:00:00.000Z',
    ...overrides
  };
}
