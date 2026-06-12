const projectName = document.getElementById('project-name');
const changeSummary = document.getElementById('change-summary');
const recentFiles = document.getElementById('recent-files');
const statusText = document.getElementById('status-text');
const otherProjects = document.getElementById('other-projects');
const otherList = document.getElementById('other-list');

function render(state) {
  const active = (state.projects || []).find((project) => project.path === state.activeProjectPath);

  if (!active) {
    projectName.textContent = '暂无活跃项目';
    changeSummary.textContent = '等待本地 Git 变化';
    recentFiles.replaceChildren(listItem('暂无'));
    statusText.textContent = '正在监听项目目录';
    otherProjects.hidden = true;
    return;
  }

  projectName.textContent = active.name;
  changeSummary.textContent = active.summary || '项目文件改动';

  const files = (active.changedFiles || []).slice(0, 3).map((file) => basename(file));
  recentFiles.replaceChildren(...(files.length ? files.map(listItem) : [listItem('暂无')]));

  const changedCount = active.changedFiles?.length || 0;
  const dirtyText = active.dirty ? `${changedCount} 个文件已修改` : '工作区干净';
  statusText.textContent = `${dirtyText} · ${relativeTime(active.lastActivityAt || state.updatedAt)}`;

  const others = (state.projects || [])
    .filter((project) => project.path !== active.path && project.score > 0)
    .slice(0, 2);

  otherProjects.hidden = others.length === 0;
  otherList.replaceChildren(...others.map((project) => {
    return listItem(`${project.name} · ${relativeTime(project.lastActivityAt || project.lastCommitAt)}`);
  }));
}

function listItem(text) {
  const item = document.createElement('li');
  item.textContent = text;
  return item;
}

function basename(filePath) {
  return String(filePath || '').split(/[\\/]/).pop() || '';
}

function relativeTime(value) {
  if (!value) {
    return '刚刚';
  }

  const deltaMs = Date.now() - new Date(value).getTime();
  if (!Number.isFinite(deltaMs) || deltaMs < 60 * 1000) {
    return '刚刚';
  }

  const minutes = Math.floor(deltaMs / 60000);
  if (minutes < 60) {
    return `${minutes} 分钟前`;
  }

  const hours = Math.floor(minutes / 60);
  if (hours < 24) {
    return `${hours} 小时前`;
  }

  return `${Math.floor(hours / 24)} 天前`;
}

window.devPulse.getState().then(render);
window.devPulse.onStateChanged(render);
