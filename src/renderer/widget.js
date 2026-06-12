const widget = document.getElementById('widget');
const projectName = document.getElementById('project-name');
const projectMeta = document.getElementById('project-meta');
const statusPill = document.getElementById('status-pill');
const changeSummary = document.getElementById('change-summary');
const changedCount = document.getElementById('changed-count');
const lastUpdate = document.getElementById('last-update');
const recentFiles = document.getElementById('recent-files');
const miniTitle = document.getElementById('mini-title');
const miniMeta = document.getElementById('mini-meta');
const collapseButton = document.getElementById('collapse-button');
const pinButton = document.getElementById('pin-button');
const closeButton = document.getElementById('close-button');
const miniExpandButton = document.getElementById('mini-expand-button');

let latestState = null;
let floatingState = {
  isAlwaysOnTop: true,
  isCollapsed: false
};

function render(state) {
  latestState = state;
  const active = (state.projects || []).find((project) => project.path === state.activeProjectPath);

  if (!active) {
    projectName.textContent = '暂无活跃项目';
    projectMeta.textContent = 'waiting · local Git only';
    statusPill.textContent = 'Clean';
    statusPill.classList.remove('status-pill--dirty');
    changeSummary.textContent = '等待本地 Git 变化';
    changedCount.textContent = '0 files';
    lastUpdate.textContent = formatClock(state.updatedAt);
    recentFiles.replaceChildren(fileItem('', '暂无'));
    miniTitle.textContent = 'DevPulse · watching';
    miniMeta.textContent = `local Git · ${formatClock(state.updatedAt)}`;
    return;
  }

  const entries = normalizeEntries(active);
  const count = entries.length;
  const updateAt = active.lastActivityAt || state.updatedAt;

  projectName.textContent = active.name;
  projectMeta.textContent = `${active.branch || 'unknown'} · ${active.dirty ? 'dirty' : 'clean'}`;
  statusPill.textContent = active.dirty ? 'Dirty' : 'Clean';
  statusPill.classList.toggle('status-pill--dirty', active.dirty);
  changeSummary.textContent = active.summary || '项目文件改动';
  changedCount.textContent = `${count} ${count === 1 ? 'file' : 'files'}`;
  lastUpdate.textContent = formatClock(updateAt);
  recentFiles.replaceChildren(...(entries.length ? entries.slice(0, 5).map((entry) => {
    return fileItem(entry.status, basename(entry.path));
  }) : [fileItem('', '暂无')]));

  miniTitle.textContent = `DevPulse · ${count} ${count === 1 ? 'file' : 'files'} changed`;
  miniMeta.textContent = `${active.branch || 'unknown'} · ${formatClock(updateAt)}`;
}

function renderFloating(nextState) {
  floatingState = { ...floatingState, ...nextState };
  widget.classList.toggle('is-collapsed', floatingState.isCollapsed);
  collapseButton.textContent = floatingState.isCollapsed ? '+' : '-';
  collapseButton.title = floatingState.isCollapsed ? '展开' : '折叠';
  pinButton.textContent = floatingState.isAlwaysOnTop ? 'Pin' : 'Free';
  pinButton.title = floatingState.isAlwaysOnTop ? '关闭置顶' : '开启置顶';
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

collapseButton.addEventListener('click', async () => {
  const isCollapsed = await window.floatingWindow.toggleCollapse();
  renderFloating({ isCollapsed });
});

pinButton.addEventListener('click', async () => {
  const isAlwaysOnTop = await window.floatingWindow.toggleAlwaysOnTop();
  renderFloating({ isAlwaysOnTop });
});

closeButton.addEventListener('click', () => {
  window.floatingWindow.hide();
});

miniExpandButton.addEventListener('click', async () => {
  const isCollapsed = await window.floatingWindow.toggleCollapse();
  renderFloating({ isCollapsed });
});

window.devPulse.getState().then(render);
window.devPulse.onStateChanged(render);

window.floatingWindow.getState().then(renderFloating);
window.floatingWindow.onStateChanged(renderFloating);
window.floatingWindow.onCollapsedChanged((isCollapsed) => {
  renderFloating({ isCollapsed });
  if (latestState) {
    render(latestState);
  }
});
