const { execFile } = require('node:child_process');
const path = require('node:path');
const { promisify } = require('node:util');

const execFileAsync = promisify(execFile);
const GIT_TIMEOUT_MS = 5000;

async function runGit(args, cwd, timeout = GIT_TIMEOUT_MS) {
  try {
    const { stdout } = await execFileAsync('git', args, {
      cwd,
      timeout,
      maxBuffer: 1024 * 256,
      windowsHide: true
    });
    return stdout.trimEnd();
  } catch {
    return '';
  }
}

function parseStatusShort(output) {
  return parseStatusEntries(output).map((entry) => entry.path);
}

function parseStatusEntries(output) {
  return output
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .filter(Boolean)
    .map((line) => {
      const status = line.slice(0, 2).trim() || '??';
      const rawPath = line.slice(3).trim();
      const renameTarget = rawPath.includes(' -> ') ? rawPath.split(' -> ').pop() : rawPath;
      return {
        status,
        path: renameTarget.replace(/^"|"$/g, '')
      };
    })
    .filter((entry) => entry.path);
}

async function readGitStatus(repoPath) {
  const [branch, statusOutput, lastCommitMessage, lastCommitAt] = await Promise.all([
    runGit(['branch', '--show-current'], repoPath),
    runGit(['status', '--short'], repoPath),
    runGit(['log', '-1', '--pretty=%s'], repoPath),
    runGit(['log', '-1', '--pretty=%cI'], repoPath)
  ]);

  const changedEntries = parseStatusEntries(statusOutput);
  const changedFiles = changedEntries.map((entry) => entry.path);

  return {
    name: path.basename(repoPath),
    path: repoPath,
    branch: branch.trim() || 'unknown',
    dirty: changedFiles.length > 0,
    changedEntries,
    changedFiles,
    lastCommitMessage: lastCommitMessage.trim(),
    lastCommitAt: lastCommitAt.trim() || null,
    lastActivityAt: changedFiles.length > 0 ? new Date().toISOString() : null
  };
}

module.exports = {
  parseStatusEntries,
  parseStatusShort,
  readGitStatus,
  runGit
};
