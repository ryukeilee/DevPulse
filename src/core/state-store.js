const fs = require('node:fs/promises');
const path = require('node:path');
const { defaultConfigDir } = require('../utils/path-utils');
const { classifyChanges } = require('./change-classifier');
const { pickActiveProject, rankProjects } = require('./activity-ranker');
const { normalizeActivities, updateActivityTimeline } = require('./activity-timeline');
const { assessRiskHint } = require('./risk-hint');
const { assessCommitReadiness } = require('./commit-readiness');

function emptyState() {
  return {
    projects: [],
    activityTimeline: [],
    activities: [],
    activeProjectPath: null,
    updatedAt: new Date().toISOString()
  };
}

async function loadState(configDir = defaultConfigDir()) {
  const statePath = path.join(configDir, 'state.json');
  try {
    const raw = await fs.readFile(statePath, 'utf8');
    return normalizeState(JSON.parse(raw));
  } catch (error) {
    if (error.code === 'ENOENT' || error instanceof SyntaxError) {
      return emptyState();
    }
    throw error;
  }
}

async function saveState(state, configDir = defaultConfigDir()) {
  await fs.mkdir(configDir, { recursive: true });
  const statePath = path.join(configDir, 'state.json');
  await fs.writeFile(statePath, `${JSON.stringify(state, null, 2)}\n`);
}

function buildState(projects, previousState = emptyState(), now = new Date()) {
  const previousByPath = new Map((previousState.projects || []).map((project) => [project.path, project]));
  const enriched = projects.map((project) => {
    const previous = previousByPath.get(project.path);
    const changedFiles = project.changedFiles || [];
    const summary = classifyChanges(changedFiles);
    const currentSignature = changeSignature(project);
    const previousSignature = previous ? changeSignature(previous) : '';
    const lastActivityAt = resolveLastActivityAt({
      project,
      previous,
      currentSignature,
      previousSignature,
      now
    });

    return {
      ...project,
      changeSignature: currentSignature,
      lastActivityAt,
      summary: summary.title,
      tags: summary.tags,
      riskHint: assessRiskHint(changedFiles),
      commitReadiness: assessCommitReadiness(changedFiles)
    };
  });

  const rankedProjects = rankProjects(enriched, now);
  const activeProject = pickActiveProject(rankedProjects, now);
  const activityTimeline = updateActivityTimeline(rankedProjects, previousState, now);

  return {
    projects: rankedProjects,
    activityTimeline,
    activities: activityTimeline,
    activeProjectPath: activeProject?.path || null,
    updatedAt: now.toISOString()
  };
}

function normalizeState(state = {}) {
  const base = emptyState();
  const activityTimeline = normalizeActivities(state.activityTimeline || state.activities || []);

  return {
    projects: Array.isArray(state.projects) ? state.projects : base.projects,
    activityTimeline,
    activities: activityTimeline,
    activeProjectPath: typeof state.activeProjectPath === 'string' ? state.activeProjectPath : null,
    updatedAt: typeof state.updatedAt === 'string' ? state.updatedAt : base.updatedAt
  };
}

function resolveLastActivityAt({ project, previous, currentSignature, previousSignature, now }) {
  if (project.activityObservedAt) {
    return project.activityObservedAt;
  }

  if (project.dirty && currentSignature && currentSignature !== previousSignature) {
    return now.toISOString();
  }

  if (project.dirty) {
    return previous?.lastActivityAt || null;
  }

  return previous?.lastActivityAt || project.lastCommitAt || null;
}

function changeSignature(project) {
  const entries = project.changedEntries?.length
    ? project.changedEntries
    : (project.changedFiles || []).map((filePath) => ({ status: '', path: filePath }));

  return entries
    .map((entry) => `${entry.status || ''}:${entry.path}`)
    .sort()
    .join('|');
}

module.exports = {
  buildState,
  emptyState,
  loadState,
  normalizeState,
  saveState
};
