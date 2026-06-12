const path = require('node:path');

const CATEGORIES = [
  {
    key: 'refresh',
    title: '刷新调度优化',
    terms: ['refresh', 'scheduler', 'interval', 'timer', 'resume', 'sleep', 'wake', 'retry', 'backoff']
  },
  {
    key: 'data',
    title: '数据读取与额度状态',
    terms: ['source', 'reader', 'snapshot', 'quota', 'rate-limit', 'ratelimits', 'usage', 'app-server', 'wham']
  },
  {
    key: 'menu',
    title: '菜单与界面调整',
    terms: ['menu', 'tray', 'presenter', 'view', 'window', 'style', 'css', 'renderer', 'component']
  },
  {
    key: 'config',
    title: '配置与偏好设置',
    terms: ['settings', 'preferences', 'config', 'option', 'toggle']
  },
  {
    key: 'diagnostic',
    title: '日志与诊断能力',
    terms: ['log', 'logger', 'diagnostic', 'trace', 'error', 'debug', 'health']
  },
  {
    key: 'test',
    title: '测试与验证',
    terms: ['test', 'spec', 'mock', 'fixture']
  },
  {
    key: 'docs',
    title: '文档更新',
    terms: ['readme', 'docs', 'agents', 'changelog', 'md']
  },
  {
    key: 'build',
    title: '构建与工程配置',
    terms: ['package', 'build', 'dist', 'electron-builder', 'vite', 'webpack', 'script']
  }
];

function classifyChanges(changedFiles) {
  const counts = countCategories(changedFiles);
  const ranked = [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || categoryIndex(a[0]) - categoryIndex(b[0]))
    .filter(([, count]) => count > 0);

  if (ranked.length === 0) {
    return { title: '项目文件改动', tags: [] };
  }

  if (ranked.length === 1 || ranked[1][1] < ranked[0][1]) {
    const category = categoryByKey(ranked[0][0]);
    return { title: category.title, tags: [category.key] };
  }

  const primary = categoryByKey(ranked[0][0]);
  const secondary = categoryByKey(ranked[1][0]);
  return {
    title: composeTitle(primary.key, secondary.key),
    tags: [primary.key, secondary.key]
  };
}

function countCategories(changedFiles = []) {
  const counts = new Map(CATEGORIES.map((category) => [category.key, 0]));

  for (const file of changedFiles) {
    const normalized = file.toLowerCase();
    const ext = path.extname(normalized).replace('.', '');

    for (const category of CATEGORIES) {
      const hit = category.terms.some((term) => normalized.includes(term)) ||
        (category.key === 'docs' && ext === 'md');
      if (hit) {
        counts.set(category.key, counts.get(category.key) + 1);
      }
    }
  }

  return counts;
}

function composeTitle(primaryKey, secondaryKey) {
  const pairs = {
    'refresh:menu': '刷新链路与菜单状态',
    'menu:refresh': '菜单与刷新链路',
    'refresh:diagnostic': '刷新链路与诊断能力',
    'diagnostic:refresh': '诊断与刷新链路',
    'data:menu': '数据读取与界面状态',
    'menu:data': '界面与数据读取',
    'config:menu': '配置与界面调整',
    'menu:config': '界面与偏好设置'
  };

  const key = `${primaryKey}:${secondaryKey}`;
  if (pairs[key]) {
    return pairs[key];
  }

  const primary = categoryByKey(primaryKey).title.replace(/优化|调整|能力|设置|状态|配置/g, '');
  const secondary = categoryByKey(secondaryKey).title.replace(/优化|调整|能力|设置|状态|配置/g, '');
  return `${primary}与${secondary}`.replace(/\s+/g, '');
}

function categoryByKey(key) {
  return CATEGORIES.find((category) => category.key === key);
}

function categoryIndex(key) {
  return CATEGORIES.findIndex((category) => category.key === key);
}

module.exports = {
  CATEGORIES,
  classifyChanges,
  countCategories
};
