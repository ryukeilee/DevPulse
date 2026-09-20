# 增量刷新性能基线

此入口只测量，不改变产品代码、扫描配置、共享快照或任何 Git 工作树内容。

## 可重跑入口

```sh
DERIVED_DATA_PATH=/tmp/devpulse-incremental-refresh ./scripts/verify.sh build
RUNS=5 \
DERIVED_DATA_PATH=/tmp/devpulse-incremental-refresh \
OUTPUT_DIR=/tmp/devpulse-incremental-refresh-results \
./scripts/measure-incremental-refresh.sh
```

`RUNS` 不能小于 5。脚本会保存：

- `samples.tsv`：每次原始数值；
- `summary.tsv`：总体均值、总体标准差、min/max；
- `performance-baselines.json`：可由 `PerformanceBaselineManager.load(from:)` 读取的
  `incrementalRefresh` 基线（时间已从 ms 换算为秒）；
- `raw/run-N.log`：每次 `xcodebuild` 原始输出，含 `scan_benchmark` 行；
- `raw/run-N.time.log`：`/usr/bin/time -l` 原始资源输出。

`DERIVED_DATA_PATH` 必须与预构建使用同一路径。测量阶段使用
`test-without-building`，因此不会把编译时间混进单次结果。

## 被测场景与边界

脚本驱动现有 Swift Testing 测试：

```text
DevPulseTests/ScanPerformanceTests/unchangedKnownScopeReusesDiscoveryAndCommitMetadata()
```

该测试创建 4 个临时 Git 仓库，先完成一次强制发现/初次扫描，再以：

- `knownRepositoryPaths: first.discoveredRepositoryPaths`
- `previousSnapshot: first.data`
- 未强制 discovery

运行第二次 `GitRepositoryScanner.scan`。测试中的 `ScanMetricsCollector` 会输出
`scan_benchmark.*`；其中 `incremental_elapsed_ms` 是第二次扫描的单次墙钟时间，
`incremental_git_calls` 是该次扫描的 Git 调用总数。这个场景复用了已知仓库范围和
提交元数据，但仍会对每个可读仓库执行 `git status`，以保持未暂存工作树变更的正确性。

这是**扫描器级**增量刷新基线，不是完整 App UI/Widget 生命周期时延：它不包含
`ScanScheduler` 的 App Group 写入、Widget reload、UI 调度和真实用户扫描目录。这样可
用确定的临时仓库重复测量，并且不会读取用户仓库的工作树文件。后续优化若涉及完整
`RefreshEngine`/`ScanScheduler`，应额外建立相应端到端测量，而不能把本基线错误描述为
完整 UI 刷新。

`continuousManualRefresh` 目前没有生产调用点或测试入口驱动 `BenchmarkRunner`；现有
`rapidRefreshStormDeduplication` 只使用 `BlockingScanProbe`，不能提供实际 Git 刷新性能
数据。因此本基线不为它生成虚构数字。

## 内存指标

每次运行同时记录 `/usr/bin/time -l` 的：

- `command_max_rss_bytes`（`maximum resident set size`）
- `command_peak_footprint_bytes`（`peak memory footprint`）

它们覆盖一次 `xcodebuild test-without-building` 命令及其测试宿主，而非只覆盖第二次
`GitRepositoryScanner.scan`；报告时必须保留这个范围说明，不能把它称作扫描器独占 RSS。
现有 `ScanMetricsCollector` 和 `RefreshObservationCollector` 不在该路径采样逐扫描 RSS。

## 现有设施的关系

- `BenchmarkSuite.swift` 只定义 `BenchmarkScenario`（包括 `incrementalRefresh` 与
  `continuousManualRefresh`）和通用 `BenchmarkRunner`。它需要调用方提供 `setup`/`action`；
  仓库没有把这两个 scenario 接到生产刷新或上述测试。其 `gitSubprocessCount` 是前后
  `pgrep` 的活动进程计数，不是一次刷新内的 spawned Git 次数，故脚本采用
  `ScanMetricsCollector.gitCommandCount`。
- `PerformanceBaseline.swift` 的 `PerformanceBaselineManager` 默认文件是
  `FileManager.default.temporaryDirectory/performance-baselines.json`；只有显式 `save()` 或
  `autoSave: true` 才写入。它保存的是 `ScenarioBaseline`（mean/stddev/sampleCount），不保存
  原始 `BenchmarkResult`。本脚本输出的 `performance-baselines.json` 是兼容该集合
  格式的可复用副本，但不会写入它的默认临时位置。
- 名为 `BaselineManager.swift` 的 `BaselineManager` 是每仓库 Git **基线分支**管理器，使用
  `git rev-parse --verify`，与性能基线文件无关。
- `RegressionGate` 的耗时门槛来自
  `max(meanElapsed * 0.20, stddevElapsed * 2.0)`；`PerformanceBaselineManager.checkRegression`
  也使用相同公式。`RegressionGate.checkNoResourceGrowth` 的 `exceedsBudget` 另以当前耗时
  `> meanElapsed * 1.5` 标记，但 `isRegression` 仍由上述阈值决定。无样本或样本数 < 3 时，
  `PerformanceBaselineManager.checkRegression` 返回 `nil`。
- `DiagnosticReport` 导出已保存的 `RefreshObservation` 的聚合数据：总体耗时、Git 调用、
  各阶段、仓库数、复用数及资源字段，并把路径变成 basename。`RefreshEngine` 只在有 Git
  工作或资源数据时保存 observation；本脚本不写 App Group observation store。
- `LifecyclePerformanceTests` 是 5 秒 self-heal、每项 2 秒、共享快照 commit 平均 500ms 等
  上限测试，不驱动 incremental refresh。
- `RefreshEngineIntegrationTests` 验证 RefreshEngine 的 discovery/coreStatus/extendedInfo/
  merge/persistence/widgetSync 阶段、并发、取消和诊断；其中没有重复采样的性能基线入口。
- `scripts/verify.sh`：`build` 执行 `build-for-testing`；`test` 对同一 DerivedData 执行
  `test-without-building`；`final` 是 build 后完整测试；`widgetkit` 委派
  `verify-widgetkit.sh`。它在 PATH 有 `timeout` 时强制超时，否则明确提示后直接运行。

## 比较规则

后续线程应使用同一机器、同一 Xcode/SDK、同一命令、相同 `RUNS >= 5` 和相同临时仓库情景。
先比较均值，并以本基线标准差估计噪声；依照现有 RegressionGate，候选观测值相对于均值
变慢超过 `max(20%, 2 × population stddev)` 才是时间回退。对“改善”，建议至少要求改善
绝对值大于 `2 × baseline stddev`，并报告原始样本，避免把单次抖动当成优化。
