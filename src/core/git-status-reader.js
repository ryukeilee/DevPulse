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
    return stdout.trim();
  } catch {
    return '';
  }
}

function parseStatusShort(output) {
  return output
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .filter(Boolean)
    .map((line) => {
      const rawPath = line.slice(3).trim();
      const renameTarget = rawPath.includes(' -> ') ? rawPath.split(' -> ').pop() : rawPath;
      return renameTarget.replace(/^"|"$/g, '');
    })
    .filter(Boolean);
}

async function readGitStatus(repoPath) {
  const [branch, statusOutput, lastCommitMessage, lastCommitAt] = await Promise.all([
    runGit(['branch', '--show-current'], repoPath),
    runGit(['status', '--short'], repoPath),
    runGit(['log', '-1', '--pretty=%s'], repoPath),
    runGit(['log', '-1', '--pretty=%cI'], repoPath)
  ]);

  const changedFiles = parseStatusShort(statusOutput);

  return {
    name: path.basename(repoPath),
    path: repoPath,
    branch: branch || 'unknown',
    dirty: changedFiles.length > 0,
    changedFiles,
    lastCommitMessage,
    lastCommitAt: lastCommitAt || null,
    lastActivityAt: changedFiles.length > 0 ? new Date().toISOString() : null
  };
}

module.exports = {
  parseStatusShort,
  readGitStatus,
  runGit
};
