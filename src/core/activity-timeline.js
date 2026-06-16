const crypto = require('node:crypto');

const MAX_ACTIVITY_RECORDS = 30;
const DEDUPE_WINDOW_MS = 2 * 60 * 1000;

const SUMMARY_RULES = [
  {
    title: '菜单与界面调整',
    terms: ['ui', 'renderer', 'component']
  },
  {
    title: 'Git 监听与扫描调整',
    terms: ['git', 'watcher', 'scanner']
  },
  {
    title: '本地存储调整',
    terms: ['storage', 'store', 'config']
  },
  {
    title: '日志与诊断调整',
    terms: ['log', 'debug', 'diagnostic']
  },
  {
    title: '项目配置或主进程调整',
    terms: ['package.json', 'package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock', 'pnpm-lock.yaml', 'main', 'preload', 'electron']
  }
];

function updateActivityTimeline(projects, previousState, now = new Date()) {
  const previousActivities = previousState.activities || [];
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

  const createdAt = project.activityObservedAt || now.toISOString();
  const duplicateIndex = activities.findIndex((activity) => {
    return isDuplicateWithinWindow(activity, project.path, currentSignature, createdAt);
  });
  if (duplicateIndex !== -1) {
    const duplicate = activities[duplicateIndex];
    const rest = activities.filter((_, index) => index !== duplicateIndex);
    return [
      {
        ...duplicate,
        projectName: project.name,
        changedFileCount: changedFiles.length,
        changedFiles,
        changeTypeSummary: summarizeActivityChange(changedFiles),
        createdAt
      },
      ...rest
    ].slice(0, MAX_ACTIVITY_RECORDS);
  }

  return [
    {
      id: activityId(project.path, currentSignature, createdAt),
      projectName: project.name,
      repoPath: project.path,
      changedFileCount: changedFiles.length,
      changedFiles,
      changeTypeSummary: summarizeActivityChange(changedFiles),
      createdAt
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

  return 'Git 工作区改动';
}

function isDuplicateWithinWindow(activity, repoPath, signature, createdAt) {
  if (!activity || activity.repoPath !== repoPath) {
    return false;
  }

  if (changedFilesSignature(activity.changedFiles) !== signature) {
    return false;
  }

  const previousTime = new Date(activity.createdAt).getTime();
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
  return [...new Set((changedFiles || []).filter(Boolean))].sort();
}

function changedFilesSignature(changedFiles = []) {
  return normalizeChangedFiles(changedFiles).join('|');
}

module.exports = {
  DEDUPE_WINDOW_MS,
  MAX_ACTIVITY_RECORDS,
  changedFilesSignature,
  maybeRecordActivity,
  summarizeActivityChange,
  updateActivityTimeline
};
