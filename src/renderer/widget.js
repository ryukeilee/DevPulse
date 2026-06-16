const widget = document.getElementById('widget');
const projectName = document.getElementById('project-name');
const projectMeta = document.getElementById('project-meta');
const changeSummary = document.getElementById('change-summary');
const riskHint = document.getElementById('risk-hint');
const commitReadiness = document.getElementById('commit-readiness');
const changedCount = document.getElementById('changed-count');
const lastUpdate = document.getElementById('last-update');
const recentFiles = document.getElementById('recent-files');
const activityList = document.getElementById('activity-list');
const miniTitle = document.getElementById('mini-title');
const miniMeta = document.getElementById('mini-meta');
const collapseButton = document.getElementById('collapse-button');
const pinButton = document.getElementById('pin-button');
const miniExpandButton = document.getElementById('mini-expand-button');
const closeButton = document.getElementById('widget-close-button');

let latestState = null;
let floatingState = {
  isAlwaysOnTop: true,
  isCollapsed: false,
  displayMode: 'full'
};

function render(state) {
  latestState = state;
  const active = (state.projects || []).find((project) => project.path === state.activeProjectPath);
  renderActivities(state.activities || [], state.updatedAt);

  if (!active) {
    projectName.textContent = '暂无活跃项目';
    projectMeta.textContent = 'waiting · local Git only';
    changeSummary.textContent = '等待本地 Git 变化';
    renderRiskHint();
    renderCommitReadiness();
    changedCount.textContent = '0 files';
    lastUpdate.textContent = formatClock(state.updatedAt);
    recentFiles.replaceChildren(fileItem('', '暂无'));
    renderMiniSummary(state, null, []);
    return;
  }

  const entries = normalizeEntries(active);
  const count = entries.length;
  const updateAt = active.lastActivityAt || state.updatedAt;

  projectName.textContent = active.name;
  projectMeta.textContent = `${active.branch || 'unknown'} · ${active.dirty ? 'dirty' : 'clean'}`;
  changeSummary.textContent = active.summary || '项目文件改动';
  renderRiskHint(active.riskHint);
  renderCommitReadiness(active.commitReadiness);
  changedCount.textContent = `${count} ${count === 1 ? 'file' : 'files'}`;
  lastUpdate.textContent = formatClock(updateAt);
  recentFiles.replaceChildren(...(entries.length ? entries.slice(0, 5).map((entry) => {
    return fileItem(entry.status, basename(entry.path));
  }) : [fileItem('', '暂无')]));

  renderMiniSummary(state, active, entries);
}

function renderRiskHint(hint) {
  const nextHint = hint || {
    level: 'low',
    message: '暂无明显风险'
  };
  riskHint.className = `risk-hint risk-hint--${nextHint.level || 'low'}`;
  if (nextHint.level === 'low') {
    riskHint.textContent = nextHint.message || '暂无明显风险';
    return;
  }

  riskHint.textContent = `${riskLevelLabel(nextHint.level)} · ${nextHint.message}`;
}

function renderCommitReadiness(readiness) {
  const nextReadiness = readiness || {
    status: 'empty',
    statusLabel: '暂无待提交改动',
    message: ''
  };
  commitReadiness.className = `commit-readiness commit-readiness--${nextReadiness.status || 'review'}`;
  commitReadiness.textContent = nextReadiness.message
    ? `${nextReadiness.statusLabel} · ${nextReadiness.message}`
    : nextReadiness.statusLabel;
}

function renderActivities(activities, nowValue) {
  const recentActivities = activities.slice(0, 3);
  if (recentActivities.length === 0) {
    activityList.replaceChildren(activityItem('暂无最近活动'));
    return;
  }

  activityList.replaceChildren(...recentActivities.map((activity) => {
    const fileLabel = `${activity.changedFileCount} 文件`;
    return activityItem(`${formatRelativeTime(activity.createdAt, nowValue)} · ${fileLabel} · ${activity.changeTypeSummary}`);
  }));
}

function renderFloating(nextState) {
  floatingState = { ...floatingState, ...nextState };
  const displayMode = normalizeDisplayMode(floatingState.displayMode || (floatingState.isCollapsed ? 'mini' : 'full'));
  const isMini = displayMode === 'mini';
  floatingState.displayMode = displayMode;
  floatingState.isCollapsed = isMini;
  widget.classList.toggle('is-collapsed', isMini);
  collapseButton.textContent = '迷你';
  collapseButton.title = '切换为迷你模式';
  pinButton.textContent = floatingState.isAlwaysOnTop ? 'Pin' : 'Free';
  pinButton.title = floatingState.isAlwaysOnTop ? '关闭置顶' : '开启置顶';
  miniExpandButton.textContent = '完整';
  miniExpandButton.title = '切换为完整模式';
}

function renderMiniSummary(state, active, entries) {
  const projectLabel = active?.name || 'DevPulse';
  const count = entries.length;
  const changedLabel = `${count} 改`;
  const activityAt = active?.lastActivityAt || latestActivityAtForProject(state.activities || [], active);
  const statusLabel = miniStatusLabel({
    riskHint: active?.riskHint,
    commitReadiness: active?.commitReadiness || active?.commitReadinessStatus || state.commitReadiness,
    activityAt,
    nowValue: state.updatedAt
  });

  miniTitle.textContent = `${projectLabel} · ${changedLabel} · ${statusLabel}`;
  miniMeta.textContent = active?.branch || 'local Git';
}

function miniStatusLabel({ riskHint, commitReadiness, activityAt, nowValue }) {
  if (riskHint?.level === 'high') {
    return '高风险';
  }

  const readinessStatus = typeof commitReadiness === 'string' ? commitReadiness : commitReadiness?.status;
  if (readinessStatus === 'blocked') {
    return '建议先验证';
  }

  if (readinessStatus === 'review') {
    return '建议检查';
  }

  if (activityAt) {
    return formatRelativeTime(activityAt, nowValue);
  }

  return '暂无明显风险';
}

function latestActivityAtForProject(activities, active) {
  if (!active) {
    return activities[0]?.createdAt || null;
  }

  return activities.find((activity) => activity.repoPath === active.path)?.createdAt || null;
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

function fileItem(status, text) {
  const item = document.createElement('li');
  const statusNode = document.createElement('span');
  const pathNode = document.createElement('span');
  statusNode.className = 'file-status';
  statusNode.textContent = status;
  pathNode.textContent = text;
  item.append(statusNode, pathNode);
  return item;
}

function activityItem(text) {
  const item = document.createElement('li');
  item.textContent = text;
  return item;
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

function riskLevelLabel(level) {
  if (level === 'high') {
    return '高风险';
  }

  if (level === 'medium') {
    return '中风险';
  }

  return '低风险';
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

window.devPulse.getState().then(render);
window.devPulse.onStateChanged(render);

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

function normalizeDisplayMode(displayMode) {
  return displayMode === 'mini' ? 'mini' : 'full';
}
