const test = require('node:test');
const assert = require('node:assert/strict');
const { parseStatusEntries, parseStatusShort } = require('../src/core/git-status-reader');

test('parses git status short changed file paths', () => {
  const output = [
    ' M src/core/flow-advice.js',
    '?? test/flow-advice.test.js'
  ].join('\n');

  assert.deepEqual(parseStatusShort(output), [
    'src/core/flow-advice.js',
    'test/flow-advice.test.js'
  ]);
});

test('parses rename target from git status short', () => {
  assert.deepEqual(parseStatusShort('R  old.js -> src/new.js'), ['src/new.js']);
});

test('parses status entries with status codes', () => {
  const output = [
    ' M src/main.js',
    'A  src/floating-window.js',
    '?? test/floating-window.test.js'
  ].join('\n');

  assert.deepEqual(parseStatusEntries(output), [
    { status: 'M', path: 'src/main.js' },
    { status: 'A', path: 'src/floating-window.js' },
    { status: '??', path: 'test/floating-window.test.js' }
  ]);
});
