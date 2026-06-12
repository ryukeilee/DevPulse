const chokidar = require('chokidar');
const { readGitStatus } = require('./git-status-reader');
const { debounce } = require('../utils/debounce');
const { warn } = require('../utils/logger');

class RepoWatcher {
  constructor({ config, onProjectUpdate }) {
    this.config = config;
    this.onProjectUpdate = onProjectUpdate;
    this.watchers = new Map();
    this.running = new Set();
    this.pending = new Set();
    this.debouncedRefresh = new Map();
  }

  watch(projects) {
    const currentPaths = new Set(projects.map((project) => project.path));

    for (const [repoPath, watcher] of this.watchers.entries()) {
      if (!currentPaths.has(repoPath)) {
        watcher.close().catch((error) => warn('Failed to close watcher', repoPath, error.message));
        this.watchers.delete(repoPath);
      }
    }

    for (const project of projects) {
      if (!this.watchers.has(project.path)) {
        this.watchProject(project.path);
      }
    }
  }

  watchProject(repoPath) {
    const ignoredDirs = new Set(this.config.ignoredDirs);
    const ignored = (targetPath) => {
      const parts = targetPath.split(/[\\/]/);
      return parts.some((part) => ignoredDirs.has(part));
    };

    const refresh = debounce(() => this.refreshRepo(repoPath), this.config.refreshDebounceMs);
    this.debouncedRefresh.set(repoPath, refresh);

    const watcher = chokidar.watch(repoPath, {
      ignored,
      ignoreInitial: true,
      persistent: true,
      awaitWriteFinish: {
        stabilityThreshold: 300,
        pollInterval: 100
      },
      atomic: true,
      depth: 99
    });

    watcher
      .on('add', refresh)
      .on('change', refresh)
      .on('unlink', refresh)
      .on('error', (error) => warn('Watcher error', repoPath, error.message));

    this.watchers.set(repoPath, watcher);
  }

  async refreshRepo(repoPath) {
    if (this.running.has(repoPath)) {
      this.pending.add(repoPath);
      return;
    }

    this.running.add(repoPath);

    try {
      const project = {
        ...(await readGitStatus(repoPath)),
        activityObservedAt: new Date().toISOString()
      };
      await this.onProjectUpdate(project);
    } finally {
      this.running.delete(repoPath);
      if (this.pending.has(repoPath)) {
        this.pending.delete(repoPath);
        this.debouncedRefresh.get(repoPath)?.();
      }
    }
  }

  async close() {
    await Promise.all([...this.watchers.values()].map((watcher) => watcher.close()));
    this.watchers.clear();
    this.running.clear();
    this.pending.clear();
    this.debouncedRefresh.clear();
  }
}

module.exports = { RepoWatcher };
