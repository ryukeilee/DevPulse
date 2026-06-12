const test = require('node:test');
const assert = require('node:assert/strict');
const { rankProjects, scoreProject } = require('../src/core/activity-ranker');

const now = new Date('2026-06-12T12:30:00.000Z');

test('recently changed project ranks first', () => {
  const ranked = rankProjects([
    project('old', { lastActivityAt: '2026-06-12T11:40:00.000Z' }),
    project('recent', { lastActivityAt: '2026-06-12T12:28:00.000Z' })
  ], now);

  assert.equal(ranked[0].name, 'recent');
});

test('dirty project receives dirty score', () => {
  const cleanScore = scoreProject(project('clean', { dirty: false }), now);
  const dirtyScore = scoreProject(project('dirty', { dirty: true }), now);

  assert.equal(dirtyScore - cleanScore, 30);
});

test('recent commit receives commit score', () => {
  const score = scoreProject(project('commit', {
    lastCommitAt: '2026-06-12T12:10:00.000Z'
  }), now);

  assert.ok(score >= 40);
});

test('stable ordering is preserved when scores tie', () => {
  const ranked = rankProjects([
    project('a', { dirty: true }),
    project('b', { dirty: true })
  ], now);

  assert.deepEqual(ranked.map((item) => item.name), ['a', 'b']);
});

function project(name, overrides = {}) {
  return {
    name,
    path: `/tmp/${name}`,
    branch: 'main',
    dirty: false,
    changedFiles: [],
    lastCommitAt: null,
    lastActivityAt: null,
    ...overrides
  };
}
