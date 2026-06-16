const widget = document.getElementById('widget');
const projectName = document.getElementById('project-name');
const projectMeta = document.getElementById('project-meta');
const overallStatus = document.getElementById('overall-status');
const refreshStatusBadge = document.getElementById('refresh-status-badge');
const activityCount = document.getElementById('activity-count');
const riskCount = document.getElementById('risk-count');
const readinessSummary = document.getElementById('readiness-summary');
const nextAction = document.getElementById('next-action');
const changeSummary = document.getElementById('change-summary');
const changedCount = document.getElementById('changed-count');
const lastUpdate = document.getElementById('last-update');
const activityList = document.getElementById('activity-list');
const riskHintList = document.getElementById('risk-hint-list');
const commitReadinessStatus = document.getElementById('commit-readiness-status');
const commitReadinessReason = document.getElementById('commit-readiness-reason');
const commitReadinessAction = document.getElementById('commit-readiness-action');
const settingsForm = document.getElementById('settings-form');
const refreshInterval = document.getElementById('refresh-interval');
const miniModeSetting = document.getElementById('mini-mode-setting');
const notificationsSetting = document.getElementById('notifications-setting');
const openAtLoginSetting = document.getElementById('open-at-login-setting');
const retentionDays = document.getElementById('retention-days');
const miniTitle = document.getElementById('mini-title');
const miniStatus = document.getElementById('mini-status');
const miniMeta = document.getElementById('mini-meta');
const miniActivityList = document.getElementById('mini-activity-list');
const miniNextAction = document.getElementById('mini-next-action');
const collapseButton = document.getElementById('collapse-button');
const pinButton = document.getElementById('pin-button');
const miniExpandButton = document.getElementById('mini-expand-button');
const closeButton = document.getElementById('widget-close-button');

let latestState = null;
let latestConfig = null;
let settingsSaveTimer = null;
let floatingState = {
  isAlwaysOnTop: true,
  isCollapsed: false,
  displayMode: 'full'
};

function render(state) {
  latestState = state || emptyUiState();
  const viewModel = buildViewModel(latestState);

  renderProjectHeader(viewModel);
  renderPulseSummary(viewModel);
  renderActivityTimeline(viewModel);
  renderRiskHints(viewModel);
  renderCommitReadiness(viewModel);
  renderMiniMode(viewModel);
}

function renderProjectHeader(viewModel) {
  projectName.textContent = viewModel.projectName;
  projectMeta.textContent = `${viewModel.branch} · refreshed ${formatClock(viewModel.updatedAt)}`;
  overallStatus.textContent = viewModel.overallStatus.label;
  overallStatus.className = `overall-status overall-status--${viewModel.overallStatus.tone}`;
  refreshStatusBadge.textContent = viewModel.refreshLabel;
  refreshStatusBadge.className = `refresh-badge refresh-badge--${viewModel.refreshTone}`;
  lastUpdate.textContent = formatClock(viewModel.updatedAt);
}

function renderPulseSummary(viewModel) {
  activityCount.textContent = String(viewModel.activityCount);
  riskCount.textContent = String(viewModel.riskCount);
  readinessSummary.textContent = viewModel.readinessLabel;
  nextAction.textContent = viewModel.nextAction;
}

function renderActivityTimeline(viewModel) {
  changeSummary.textContent = viewModel.changeSummary;
  changedCount.textContent = `${viewModel.changedEntries.length} ${viewModel.changedEntries.length === 1 ? 'file' : 'files'}`;

  if (viewModel.timelineItems.length === 0) {
    activityList.replaceChildren(emptyListItem('暂无最近活动'));
    return;
  }

  activityList.replaceChildren(...viewModel.timelineItems.map((item) => activityItem(item)));
}

function renderRiskHints(viewModel) {
  if (viewModel.riskCards.length === 0) {
    riskHintList.replaceChildren(emptyState('没有本地规则命中，当前状态健康。'));
    return;
  }

  riskHintList.replaceChildren(...viewModel.riskCards.map((hint) => riskHintCard(hint)));
}

function renderCommitReadiness(viewModel) {
  commitReadinessStatus.textContent = viewModel.readinessDisplay;
  commitReadinessStatus.className = `readiness-status commit-readiness--${viewModel.readinessTone}`;
  commitReadinessReason.textContent = viewModel.readinessReason;
  commitReadinessAction.textContent = viewModel.readinessAction;
}

function renderMiniMode(viewModel) {
  miniTitle.textContent = viewModel.projectName;
  miniStatus.textContent = viewModel.overallStatus.label;
  miniStatus.className = `mini-status overall-status--${viewModel.overallStatus.tone}`;
  miniMeta.textContent = `${viewModel.branch} · ${viewModel.riskCount} risks · ${viewModel.readinessDisplay}`;
  miniNextAction.textContent = viewModel.nextAction;

  if (viewModel.miniItems.length === 0) {
    miniActivityList.replaceChildren(emptyMiniItem('暂无最近活动'));
    return;
  }

  miniActivityList.replaceChildren(...viewModel.miniItems.map((item) => emptyMiniItem(item)));
}

function renderConfig(config) {
  latestConfig = config || defaultUiConfig();
  refreshInterval.value = nearestRefreshOption(latestConfig.pollFallbackMs);
  miniModeSetting.checked = latestConfig.floatingWindow?.displayMode === 'mini';
  notificationsSetting.checked = Boolean(latestConfig.notificationsEnabled);
  openAtLoginSetting.checked = Boolean(latestConfig.openAtLogin);
  retentionDays.value = String(latestConfig.dataRetentionDays || 14);
}

function renderFloating(nextState) {
  floatingState = { ...floatingState, ...nextState };
  const displayMode = normalizeDisplayMode(floatingState.displayMode || (floatingState.isCollapsed ? 'mini' : 'full'));
  const isMini = displayMode === 'mini';
  floatingState.displayMode = displayMode;
  floatingState.isCollapsed = isMini;
  widget.classList.toggle('is-collapsed', isMini);
  collapseButton.textContent = 'Mini';
  collapseButton.title = '切换为迷你模式';
  pinButton.textContent = floatingState.isAlwaysOnTop ? 'Pin' : 'Free';
  pinButton.title = floatingState.isAlwaysOnTop ? '关闭置顶' : '开启置顶';
  miniExpandButton.textContent = 'Full';
  miniExpandButton.title = '切换为完整模式';

  if (latestConfig) {
    renderConfig({
      ...latestConfig,
      floatingWindow: {
        ...latestConfig.floatingWindow,
        displayMode
      }
    });
  }
}

function buildViewModel(state) {
  const active = (state.projects || []).find((project) => project.path === state.activeProjectPath);
  const updatedAt = state.updatedAt || new Date().toISOString();
  const changedEntries = active ? normalizeEntries(active) : [];
  const riskHint = active?.riskHint || { level: 'low', message: '暂无明显风险', matchedFiles: [] };
  const readiness = active?.commitReadiness || {
    status: 'empty',
    statusLabel: '暂无待提交改动',
    message: ''
  };
  const timelineItems = buildTimelineItems(state.activities || [], active, changedEntries, updatedAt);
  const riskCards = buildRiskCards(riskHint);
  const readinessTone = normalizeReadinessTone(readiness.status);
  const overall = resolveOverallStatus(riskHint.level, readiness.status);
  const readinessAction = nextReadinessAction(readiness.status);

  return {
    projectName: active?.name || '暂无活跃项目',
    branch: active?.branch || 'local Git',
    updatedAt,
    refreshLabel: active ? 'Live' : 'Fallback',
    refreshTone: active ? 'live' : 'fallback',
    overallStatus: overall,
    activityCount: timelineItems.length,
    riskCount: riskCards.filter((hint) => hint.level !== 'low').length,
    readinessLabel: readiness.statusLabel || '暂无待提交改动',
    readinessDisplay: readinessDisplay(readiness.status),
    readinessTone,
    readinessReason: readiness.message || readiness.statusLabel || '暂无待提交改动',
    readinessAction,
    nextAction: active ? resolveNextAction(riskHint, readiness, changedEntries) : '选择或修改一个本地 Git 项目后开始观察。',
    changeSummary: active?.summary || '等待本地 Git 变化',
    changedEntries,
    timelineItems,
    miniItems: timelineItems.slice(0, 3).map((item) => `${statusLabel(item.status)} ${basename(item.path)}`),
    riskCards
  };
}

function buildTimelineItems(activities, active, changedEntries, updatedAt) {
  if (changedEntries.length > 0) {
    return changedEntries.slice(0, 8).map((entry) => ({
      status: normalizeGitStatus(entry.status),
      path: entry.path,
      meta: active?.lastActivityAt ? formatRelativeTime(active.lastActivityAt, updatedAt) : '当前工作区',
      summary: statusSummary(entry.status)
    }));
  }

  return activities.slice(0, 6).map((activity) => ({
    status: 'M',
    path: activity.changeTypeSummary || activity.projectName || 'Git 工作区改动',
    meta: formatRelativeTime(activity.createdAt, updatedAt),
    summary: `${activity.changedFileCount || 0} files`
  }));
}

function buildRiskCards(hint) {
  if (!hint || hint.level === 'low') {
    return [];
  }

  return [{
    level: hint.level,
    title: riskTitle(hint.level),
    reason: hint.message || '本地规则识别到需要关注的改动。',
    action: riskAction(hint.level, hint.matchedFiles),
    files: hint.matchedFiles || []
  }];
}

function resolveOverallStatus(riskLevel, readinessStatus) {
  if (riskLevel === 'high' || readinessStatus === 'blocked') {
    return { label: 'Risk', tone: 'risk' };
  }

  if (riskLevel === 'medium' || readinessStatus === 'review') {
    return { label: 'Attention', tone: 'attention' };
  }

  return { label: 'Good', tone: 'good' };
}

function resolveNextAction(riskHint, readiness, entries) {
  if (riskHint?.level === 'high') {
    return '先处理高风险改动，再考虑提交。';
  }

  if (readiness?.status === 'blocked') {
    return nextReadinessAction(readiness.status);
  }

  if (readiness?.status === 'review') {
    return '快速检查 diff，确认是否需要拆分提交。';
  }

  if (entries.length > 0) {
    return '状态稳定，可以准备提交。';
  }

  return '暂无待处理改动，保持低资源观察。';
}

function activityItem(item) {
  const row = document.createElement('li');
  row.className = 'timeline-item';

  const badge = document.createElement('span');
  badge.className = `change-badge change-badge--${item.status}`;
  badge.textContent = statusLabel(item.status);

  const copy = document.createElement('span');
  copy.className = 'timeline-copy';

  const path = document.createElement('span');
  path.className = 'timeline-path';
  path.textContent = item.path || '未命名改动';

  const meta = document.createElement('span');
  meta.className = 'timeline-meta';
  meta.textContent = `${item.meta} · ${item.summary}`;

  copy.append(path, meta);
  row.append(badge, copy);
  return row;
}

function riskHintCard(hint) {
  const card = document.createElement('article');
  card.className = `risk-card risk-card--${hint.level}`;

  const title = document.createElement('div');
  title.className = 'risk-card__title';
  title.textContent = hint.title;

  const reason = document.createElement('div');
  reason.className = 'risk-card__reason';
  reason.textContent = hint.reason;

  const action = document.createElement('div');
  action.className = 'risk-card__action';
  action.textContent = hint.action;

  card.append(title, reason, action);
  return card;
}

function emptyState(text) {
  const node = document.createElement('div');
  node.className = 'empty-state';
  node.textContent = text;
  return node;
}

function emptyMiniItem(text) {
  const item = document.createElement('li');
  item.textContent = text;
  return item;
}

function emptyListItem(text) {
  const item = document.createElement('li');
  item.className = 'empty-state';
  item.textContent = text;
  return item;
}

function normalizeEntries(project) {
  if (project.changedEntries?.length) {
    return project.changedEntries;
  }

  return (project.changedFiles || []).map((path) => ({
    status: project.dirty ? 'M' : '',
    path
  }));
}

function normalizeGitStatus(status) {
  const value = String(status || '').toUpperCase();
  if (value.includes('A') || value.includes('?')) {
    return 'added';
  }

  if (value.includes('D')) {
    return 'deleted';
  }

  return 'modified';
}

function statusLabel(status) {
  if (status === 'added') {
    return 'A';
  }

  if (status === 'deleted') {
    return 'D';
  }

  return 'M';
}

function statusSummary(status) {
  if (normalizeGitStatus(status) === 'added') {
    return 'added';
  }

  if (normalizeGitStatus(status) === 'deleted') {
    return 'deleted';
  }

  return 'modified';
}

function readinessDisplay(status) {
  if (status === 'ready') {
    return 'Ready';
  }

  if (status === 'blocked') {
    return 'Not Ready';
  }

  if (status === 'empty') {
    return 'Ready';
  }

  return 'Need Review';
}

function normalizeReadinessTone(status) {
  if (status === 'ready' || status === 'empty') {
    return 'ready';
  }

  if (status === 'blocked') {
    return 'blocked';
  }

  return 'review';
}

function nextReadinessAction(status) {
  if (status === 'blocked') {
    return '先运行相关验证，再提交。';
  }

  if (status === 'review') {
    return '检查 diff 和模块边界。';
  }

  return '可以提交，或继续观察。';
}

function riskTitle(level) {
  if (level === 'high') {
    return 'High risk';
  }

  if (level === 'medium') {
    return 'Medium risk';
  }

  return 'Low risk';
}

function riskAction(level, files = []) {
  if (level === 'high') {
    return files.length > 0 ? `重点检查 ${basename(files[0])}` : '先完成验证再提交。';
  }

  return '确认影响范围后继续。';
}

function basename(filePath) {
  return String(filePath || '').split(/[\\/]/).pop() || '';
}

function formatClock(value) {
  if (!value) {
    return '--:--';
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return '--:--';
  }

  return new Intl.DateTimeFormat('zh-CN', {
    hour: '2-digit',
    minute: '2-digit',
    hour12: false
  }).format(date);
}

function formatRelativeTime(value, nowValue) {
  const date = new Date(value);
  const now = nowValue ? new Date(nowValue) : new Date();
  if (Number.isNaN(date.getTime()) || Number.isNaN(now.getTime())) {
    return '刚刚';
  }

  const diffMs = Math.max(0, now.getTime() - date.getTime());
  const minutes = Math.floor(diffMs / 60000);
  if (minutes < 1) {
    return '刚刚';
  }

  if (minutes < 60) {
    return `${minutes} 分钟前`;
  }

  const hours = Math.floor(minutes / 60);
  if (hours < 24) {
    return `${hours} 小时前`;
  }

  return `${Math.floor(hours / 24)} 天前`;
}

function nearestRefreshOption(value) {
  const allowed = ['15000', '30000', '60000', '300000'];
  const stringValue = String(value || 30000);
  return allowed.includes(stringValue) ? stringValue : '30000';
}

function defaultUiConfig() {
  return {
    pollFallbackMs: 30000,
    notificationsEnabled: false,
    openAtLogin: false,
    dataRetentionDays: 14,
    floatingWindow: {
      displayMode: 'full'
    }
  };
}

function emptyUiState() {
  return {
    projects: [],
    activities: [],
    activeProjectPath: null,
    updatedAt: new Date().toISOString()
  };
}

function normalizeDisplayMode(displayMode) {
  return displayMode === 'mini' ? 'mini' : 'full';
}

function scheduleSettingsSave() {
  clearTimeout(settingsSaveTimer);
  settingsSaveTimer = setTimeout(saveSettings, 250);
}

async function saveSettings() {
  const displayMode = miniModeSetting.checked ? 'mini' : 'full';
  const nextConfig = await window.devPulse.updateSettings({
    pollFallbackMs: Number(refreshInterval.value),
    displayMode,
    notificationsEnabled: notificationsSetting.checked,
    openAtLogin: openAtLoginSetting.checked,
    dataRetentionDays: Number(retentionDays.value)
  });
  renderConfig(nextConfig);
}

collapseButton.addEventListener('click', async () => {
  const displayMode = await setDisplayMode('mini');
  renderFloating({ displayMode });
});

pinButton.addEventListener('click', async () => {
  const isAlwaysOnTop = await window.floatingWindow.toggleAlwaysOnTop();
  renderFloating({ isAlwaysOnTop });
});

miniExpandButton.addEventListener('click', async () => {
  const displayMode = await setDisplayMode('full');
  renderFloating({ displayMode });
});

closeButton.addEventListener('click', () => {
  window.desktopWidget?.quitApp();
});

settingsForm.addEventListener('change', scheduleSettingsSave);

window.devPulse.getState().then(render);
window.devPulse.getConfig().then(renderConfig);
window.devPulse.onStateChanged(render);
window.devPulse.onConfigChanged(renderConfig);

window.floatingWindow.getState().then(renderFloating);
window.floatingWindow.onStateChanged(renderFloating);
window.floatingWindow.onCollapsedChanged((isCollapsed) => {
  renderFloating({ isCollapsed, displayMode: isCollapsed ? 'mini' : 'full' });
  if (latestState) {
    render(latestState);
  }
});

async function setDisplayMode(displayMode) {
  if (window.floatingWindow.setDisplayMode) {
    return window.floatingWindow.setDisplayMode(displayMode);
  }

  await window.floatingWindow.toggleCollapse();
  return displayMode;
}
