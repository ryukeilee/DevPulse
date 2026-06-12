const fs = require('node:fs/promises');
const path = require('node:path');
const { defaultConfigDir } = require('../utils/path-utils');
const { classifyChanges } = require('./change-classifier');
const { pickActiveProject, rankProjects } = require('./activity-ranker');

function emptyState() {
  return {
    projects: [],
    activeProjectPath: null,
    updatedAt: new Date().toISOString()
  };
}

async function loadState(configDir = defaultConfigDir()) {
  const statePath = path.join(configDir, 'state.json');
  try {
    const raw = await fs.readFile(statePath, 'utf8');
    return JSON.parse(raw);
  } catch (error) {
    if (error.code === 'ENOENT') {
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

    return {
      ...project,
      lastActivityAt: project.lastActivityAt || previous?.lastActivityAt || project.lastCommitAt || null,
      summary: summary.title,
      tags: summary.tags
    };
  });

  const rankedProjects = rankProjects(enriched, now);
  const activeProject = pickActiveProject(rankedProjects, now);

  return {
    projects: rankedProjects,
    activeProjectPath: activeProject?.path || null,
    updatedAt: now.toISOString()
  };
}

module.exports = {
  buildState,
  emptyState,
  loadState,
  saveState
};
