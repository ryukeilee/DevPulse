const crypto = require('node:crypto');
const path = require('node:path');

const MAX_ACTIVITY_RECORDS = 10;
const DEDUPE_WINDOW_MS = 90 * 1000;

const SUMMARY_RULES = [
  {
    title: '配置调整',
    terms: ['package.json', 'package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock', 'pnpm-lock.yaml', 'config', '.json', '.yaml', '.yml', '.toml']
  },
  {
    title: '界面优化',
    terms: ['ui', 'renderer', 'component', 'view', 'widget', 'css']
  },
  {
    title: '监听与扫描优化',
    terms: ['git', 'watcher', 'scanner']
  },
  {
    title: '测试更新',
    terms: ['test', 'spec']
  }
];

function updateActivityTimeline(projects, previousState, now = new Date()) {
  const previousActivities = normalizeActivities(previousState.activityTimeline || previousState.activities || []);
  const previousByPath = new Map((previousState.projects || []).map((project) => [project.path, project]));

  return projects.reduce((activities, project) => {
    const previousProject = previousByPath.get(project.path);
    return maybeRecordActivity(activities, project, previousProject, now);
  }, previousActivities).slice(0, MAX_ACTIVITY_RECORDS);
}

function maybeRecordActivity(activities, project, previousProject, now = new Date()) {
  const changedFiles = normalizeChangedFiles(project.changedFiles);
  if (!project.dirty || changedFiles.length === 0) {
    return activities;
  }

  const previousSignature = changedFilesSignature(previousProject?.changedFiles);
  const currentSignature = changedFilesSignature(changedFiles);
  const changedFilesChanged = currentSignature !== previousSignature;
  const watcherObserved = Boolean(project.activityObservedAt);

  if (!changedFilesChanged && !watcherObserved) {
    return activities;
  }

  const observedAt = project.activityObservedAt || now.toISOString();
  const duplicateIndex = activities.findIndex((activity) => {
    return isDuplicateWithinWindow(activity, project.path, observedAt);
  });
  if (duplicateIndex !== -1) {
    const duplicate = activities[duplicateIndex];
    const rest = activities.filter((_, index) => index !== duplicateIndex);
    const mergedFiles = normalizeChangedFiles([
      ...(duplicate.files || duplicate.changedFiles || []),
      ...changedFiles
    ]);
    const summary = summarizeActivityChange(mergedFiles);
    return [
      {
        ...duplicate,
        projectName: project.name,
        projectPath: project.path,
        repoPath: project.path,
        files: mergedFiles,
        changedFiles: mergedFiles,
        changedFileCount: mergedFiles.length,
        summary,
        changeTypeSummary: summary,
        updatedAt: observedAt
      },
      ...rest
    ].slice(0, MAX_ACTIVITY_RECORDS);
  }

  const summary = summarizeActivityChange(changedFiles);
  return [
    {
      id: activityId(project.path, currentSignature, observedAt),
      projectName: project.name,
      projectPath: project.path,
      repoPath: project.path,
      summary,
      files: changedFiles,
      changedFileCount: changedFiles.length,
      changedFiles,
      changeTypeSummary: summary,
      createdAt: observedAt,
      updatedAt: observedAt
    },
    ...activities
  ].slice(0, MAX_ACTIVITY_RECORDS);
}

function summarizeActivityChange(changedFiles = []) {
  const normalizedFiles = normalizeChangedFiles(changedFiles).map((file) => file.toLowerCase());

  for (const rule of SUMMARY_RULES) {
    if (normalizedFiles.some((file) => rule.terms.some((term) => file.includes(term)))) {
      return rule.title;
    }
  }

  return '本地改动';
}

function isDuplicateWithinWindow(activity, repoPath, createdAt) {
  if (!activity || (activity.projectPath || activity.repoPath) !== repoPath) {
    return false;
  }

  const previousTime = new Date(activity.updatedAt || activity.createdAt).getTime();
  const nextTime = new Date(createdAt).getTime();
  if (Number.isNaN(previousTime) || Number.isNaN(nextTime)) {
    return false;
  }

  return Math.abs(nextTime - previousTime) <= DEDUPE_WINDOW_MS;
}

function activityId(repoPath, signature, createdAt) {
  return crypto
    .createHash('sha1')
    .update(`${repoPath}|${signature}|${createdAt}`)
    .digest('hex')
    .slice(0, 16);
}

function normalizeChangedFiles(changedFiles = []) {
  return [...new Set((changedFiles || []).filter(Boolean))]
    .map((filePath) => filePath.replace(/\\/g, '/'))
    .sort();
}

function changedFilesSignature(changedFiles = []) {
  return normalizeChangedFiles(changedFiles).join('|');
}

function normalizeActivities(activities = []) {
  return (activities || [])
    .filter(Boolean)
    .map((activity) => {
      const files = normalizeChangedFiles(activity.files || activity.changedFiles || []);
      const summary = activity.summary || activity.changeTypeSummary || summarizeActivityChange(files);
      const projectPath = activity.projectPath || activity.repoPath || '';
      const projectName = activity.projectName || path.basename(projectPath) || 'unknown';
      const createdAt = activity.createdAt || activity.updatedAt || new Date(0).toISOString();
      const updatedAt = activity.updatedAt || activity.createdAt || createdAt;

      return {
        id: activity.id || activityId(projectPath, changedFilesSignature(files), createdAt),
        projectName,
        projectPath,
        repoPath: projectPath,
        summary,
        files,
        changedFiles: files,
        changedFileCount: Number.isFinite(activity.changedFileCount) ? activity.changedFileCount : files.length,
        changeTypeSummary: summary,
        createdAt,
        updatedAt
      };
    })
    .sort((left, right) => {
      return new Date(right.updatedAt).getTime() - new Date(left.updatedAt).getTime();
    })
    .slice(0, MAX_ACTIVITY_RECORDS);
}

module.exports = {
  DEDUPE_WINDOW_MS,
  MAX_ACTIVITY_RECORDS,
  changedFilesSignature,
  maybeRecordActivity,
  normalizeActivities,
  summarizeActivityChange,
  updateActivityTimeline
};
