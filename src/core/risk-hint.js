const NO_RISK_HINT = {
  level: 'low',
  message: '暂无明显风险',
  matchedRules: ['no-risk'],
  matchedFiles: []
};

const RISK_RULES = [
  {
    key: 'sensitive-config',
    level: 'high',
    message: '敏感配置相关文件发生变化，建议确认没有泄露敏感信息。',
    match: ({ file }) => pathIncludesAny(file, ['auth', 'token', 'credential', '.env'])
  },
  {
    key: 'dependency-or-build-config',
    level: 'high',
    message: '依赖或构建配置已变更，建议重新安装依赖并运行构建验证。',
    match: ({ basename }) => ['package.json', 'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock'].includes(basename)
  },
  {
    key: 'electron-main-or-preload',
    level: 'high',
    message: '主进程或 Electron 配置已变更，建议重点验证窗口行为与启动流程。',
    match: ({ file, basename }) => file.includes('electron-builder') || basename.includes('main') || basename.includes('preload')
  },
  {
    key: 'large-change-set',
    level: 'high',
    message: '改动范围较大，建议检查 diff 后再继续。',
    matchSet: (files) => files.length >= 10
  },
  {
    key: 'storage-change',
    level: 'medium',
    message: '本地存储逻辑已变更，建议验证数据读写和旧数据兼容。',
    match: ({ file }) => pathIncludesAny(file, ['storage', 'store', 'data'])
  },
  {
    key: 'git-scanner-change',
    level: 'medium',
    message: 'Git 扫描逻辑已变更，建议验证刷新和改动识别是否正常。',
    match: ({ file }) => pathIncludesAny(file, ['git', 'watcher', 'scanner'])
  },
  {
    key: 'config-change',
    level: 'medium',
    message: '配置文件已变更，建议检查默认值和兼容性。',
    match: ({ file }) => pathIncludesAny(file, ['config', 'settings'])
  }
];

function assessRiskHint(changedFiles = []) {
  const files = normalizeFiles(changedFiles);
  if (files.length === 0) {
    return { ...NO_RISK_HINT };
  }

  for (const rule of RISK_RULES) {
    if (rule.matchSet?.(files)) {
      return {
        level: rule.level,
        message: rule.message,
        matchedRules: [rule.key],
        matchedFiles: files
      };
    }

    const matchedFiles = files.filter((filePath) => {
      return rule.match?.({
        file: filePath.toLowerCase(),
        basename: basename(filePath).toLowerCase()
      });
    });

    if (matchedFiles.length > 0) {
      return {
        level: rule.level,
        message: rule.message,
        matchedRules: [rule.key],
        matchedFiles
      };
    }
  }

  return { ...NO_RISK_HINT };
}

function normalizeFiles(changedFiles = []) {
  return [...new Set((changedFiles || []).filter(Boolean))].sort();
}

function basename(filePath) {
  return String(filePath || '').split(/[\\/]/).pop() || '';
}

function pathIncludesAny(filePath, terms) {
  return terms.some((term) => filePath.includes(term));
}

module.exports = {
  NO_RISK_HINT,
  RISK_RULES,
  assessRiskHint
};
