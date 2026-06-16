const DEPENDENCY_OR_BUILD_CONFIG_FILES = new Set([
  'package.json',
  'package-lock.json',
  'pnpm-lock.yaml',
  'yarn.lock'
]);

const EMPTY_READINESS = {
  status: 'empty',
  statusLabel: '暂无待提交改动',
  message: '',
  changedFileCount: 0,
  categories: [],
  matchedRules: ['empty']
};

function assessCommitReadiness(changedFiles = []) {
  const files = normalizeFiles(changedFiles);
  const categories = classifyReadinessCategories(files);
  const context = { files, categories };

  for (const rule of READINESS_RULES) {
    if (rule.match(context)) {
      return buildReadiness(rule, files, categories);
    }
  }

  return buildReadiness(RULE_BY_KEY.get('generic-review'), files, categories);
}

const READINESS_RULES = [
  {
    key: 'dependency-or-build-config',
    status: 'blocked',
    statusLabel: '建议先验证再提交',
    message: '依赖或构建配置已变更，建议完成安装与构建验证后再提交。',
    match: ({ files }) => files.some((file) => DEPENDENCY_OR_BUILD_CONFIG_FILES.has(basename(file)))
  },
  {
    key: 'electron-main-or-preload',
    status: 'blocked',
    statusLabel: '建议先验证再提交',
    message: '主进程或 Electron 配置已变更，建议验证启动、窗口行为和关闭逻辑后再提交。',
    match: ({ files }) => files.some((file) => {
      const name = basename(file);
      return file.includes('electron-builder') ||
        file.includes('electron') ||
        name.includes('main') ||
        name.includes('preload');
    })
  },
  {
    key: 'storage-change',
    status: 'blocked',
    statusLabel: '建议先验证再提交',
    message: '本地存储逻辑已变更，建议验证数据读写和旧数据兼容后再提交。',
    match: ({ categories }) => categories.includes('storage')
  },
  {
    key: 'large-change-set',
    status: 'review',
    statusLabel: '建议检查后提交',
    message: '改动范围较大，建议检查 diff 后再提交。',
    match: ({ files }) => files.length >= 10
  },
  {
    key: 'multi-category-change',
    status: 'review',
    statusLabel: '建议检查后提交',
    message: '改动涉及多个模块，建议确认是否需要拆分提交。',
    match: ({ categories }) => categories.length > 1
  },
  {
    key: 'git-scanner-change',
    status: 'review',
    statusLabel: '建议检查后提交',
    message: 'Git 扫描逻辑已变更，建议验证刷新和改动识别后提交。',
    match: ({ categories }) => categories.includes('git')
  },
  {
    key: 'ui-focused-change',
    status: 'ready',
    statusLabel: '适合提交',
    message: '改动集中在界面层，适合检查后提交。',
    match: ({ files, categories }) => files.length > 0 && categories.length === 1 && categories[0] === 'ui'
  },
  {
    key: 'docs-only-change',
    status: 'ready',
    statusLabel: '适合提交',
    message: '文档类改动，适合直接提交。',
    match: ({ files, categories }) => files.length > 0 && categories.length === 1 && categories[0] === 'docs'
  },
  {
    key: 'generic-review',
    status: 'review',
    statusLabel: '建议检查后提交',
    message: '建议检查 diff 后再提交。',
    match: ({ files }) => files.length > 0
  },
  {
    key: 'empty',
    status: 'empty',
    statusLabel: '暂无待提交改动',
    message: '',
    match: ({ files }) => files.length === 0
  }
];

const RULE_BY_KEY = new Map(READINESS_RULES.map((rule) => [rule.key, rule]));

function classifyReadinessCategories(files = []) {
  const categories = new Set();

  for (const file of files) {
    const name = basename(file);
    const ext = extension(file);

    if (isDocsFile(file, name, ext)) {
      categories.add('docs');
    }

    if (pathIncludesAny(file, ['ui', 'renderer', 'component', 'style']) || ['css', 'scss', 'sass'].includes(ext)) {
      categories.add('ui');
    }

    if (pathIncludesAny(file, ['git', 'watcher', 'scanner'])) {
      categories.add('git');
    }

    if (pathIncludesAny(file, ['storage', 'store', 'data', 'migration'])) {
      categories.add('storage');
    }
  }

  return [...categories].sort();
}

function buildReadiness(rule, files, categories) {
  if (rule.key === 'empty') {
    return { ...EMPTY_READINESS };
  }

  return {
    status: rule.status,
    statusLabel: rule.statusLabel,
    message: rule.message,
    changedFileCount: files.length,
    categories,
    matchedRules: [rule.key]
  };
}

function normalizeFiles(changedFiles = []) {
  return [...new Set((changedFiles || []).filter(Boolean).map((file) => String(file).toLowerCase()))].sort();
}

function basename(filePath) {
  return String(filePath || '').split(/[\\/]/).pop() || '';
}

function extension(filePath) {
  const name = basename(filePath);
  const dotIndex = name.lastIndexOf('.');
  return dotIndex === -1 ? '' : name.slice(dotIndex + 1);
}

function isDocsFile(file, name, ext) {
  return ext === 'md' || pathIncludesAny(file, ['docs', 'readme']) || name === 'readme';
}

function pathIncludesAny(filePath, terms) {
  return terms.some((term) => filePath.includes(term));
}

module.exports = {
  EMPTY_READINESS,
  READINESS_RULES,
  assessCommitReadiness,
  classifyReadinessCategories
};
