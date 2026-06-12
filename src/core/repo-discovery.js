const fs = require('node:fs/promises');
const path = require('node:path');
const { readGitStatus, runGit } = require('./git-status-reader');

async function discoverRepositories(config) {
  const discovered = new Map();

  for (const root of config.roots) {
    if (!(await exists(root))) {
      continue;
    }

    await walkForRepos(root, {
      currentDepth: 0,
      maxDepth: config.scanDepth,
      ignoredDirs: new Set(config.ignoredDirs),
      discovered
    });
  }

  return Promise.all([...discovered.keys()].map(readGitStatus));
}

async function walkForRepos(dir, context) {
  if (context.currentDepth > context.maxDepth) {
    return;
  }

  if (context.ignoredDirs.has(path.basename(dir))) {
    return;
  }

  if (await isGitRepository(dir)) {
    context.discovered.set(dir, true);
    return;
  }

  let entries = [];
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    if (!entry.isDirectory() || context.ignoredDirs.has(entry.name)) {
      continue;
    }

    await walkForRepos(path.join(dir, entry.name), {
      ...context,
      currentDepth: context.currentDepth + 1
    });
  }
}

async function isGitRepository(dir) {
  if (await exists(path.join(dir, '.git'))) {
    return true;
  }

  const topLevel = await runGit(['rev-parse', '--show-toplevel'], dir, 2000);
  return topLevel === dir;
}

async function exists(targetPath) {
  try {
    await fs.access(targetPath);
    return true;
  } catch {
    return false;
  }
}

module.exports = {
  discoverRepositories,
  isGitRepository
};
