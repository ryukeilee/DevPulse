# 本轮性能优化与成果收敛（2026-10-09）

## 基准与已有成果

开始及同步远端后，`main`、`origin/main` 均为 `08f33bacc3c818d7e749db97dfb7a03637ffdb1a`。没有提前提交、覆盖或丢弃工作区修改。Git 历史确认以下优化已存在，本轮没有重复实现：

- `37f2c42`：不变的 worktree 拓扑缓存。
- `2db9218`、`b1ad2c6`、`2f366d6`：刷新作用域内路径规范化复用、共享快照解码复用。
- `b6d6c5d`：Git 进程结果观察轮询由 10 ms 缩至 1 ms。
- `f2bcffa`、`2e2605d`、`9c34f8a`：无变化活动档案免重写及保存顺序保护。
- `da5b955`、`7ada40e`、`08f33ba`：工作区聚合、仓库排序输入、活动时间线派生优化。

原工作区的六个页面、`ContentView`、`LifecyclePerformanceTests` 修改，以及 `benchmark-tabs.py`、`tab-performance.swift`、页面性能文档和原始 JSON 全部保留。它们通过 `RetainedTab` 保留页面身份和局部状态，通过 `TabUpdateScope` 抑制隐藏页面的 scheduler 更新。原 [1,200 仓库记录](tab-performance.md) 保留其原基线和验证时间，不把历史数据改写为本轮结果。

`.agent/` 已由历史提交 `d3d4dec` 删除；本轮不重新创建旧维护体系。

## 本轮刷新修改

旧 `GitRepositoryScanner` 已跳过无提交仓库的 `git log`，`RefreshEngine` 没有相同保护。后者在首次及后续刷新中都会重复执行必然失败的 `git log -1`。

本轮将 **当前 status 明确报告 unborn branch** 的路径在 core/extended 两阶段间传递，直接采用本轮状态，跳过 log。该集合仅存活于一次刷新，不增加共享快照字段或跨刷新缓存。每个可读仓库仍执行 `git status --porcelain=v2 --branch`，不会依据 HEAD/index 时间戳跳过工作树检查。

同时清除 orphan branch 上的旧提交信息。只有非空 HEAD OID 与上一轮相同且已确认元数据可用时才继承提交时间和摘要；HEAD 变化后若 log 失败，元数据保持不可用，下一轮会重试。独立静态审查指出的“首次提交后 log 失败导致永不重试”问题已修复并通过一次定向复查。

没有修改进程执行、取消、超时、并发上限、Git 参数、签名配置、App Group 或持久化格式。

## 可复现性能证据

复跑入口：

```sh
rtk proxy python3 scripts/benchmark-git-refresh.py --baseline-git 08f33ba --runs 10 --output /tmp/devpulse-git-refresh.json
rtk proxy python3 scripts/benchmark-tabs.py --baseline-git 08f33ba --repos 300 --runs 3 --output /tmp/devpulse-tabs-latest.json
```

Git 基准使用相同 macOS SDK、Swift 6、`-O -whole-module-optimization`，从 `git archive` 导出基线、复制当前源码，分别编译一次。10 对按先基线/先候选交替运行，每次独立进程及 App Group/defaults suite。24 个临时 Git 仓库各有 100 个文件：12 个已有提交且有未暂存修改，12 个尚无提交。提交日期固定，Git 配置隔离；不读取用户仓库文件。

结果摘要校验仓库名、分支、状态、文件计数和预览、提交 ID/摘要/时间。路径及扫描时间戳不参与对照；无提交状态的可用标记是被修正的语义，由原生测试单独验证。所有配对摘要相同。CPU 指标为 `RUSAGE_SELF` 的 user + system 增量，**不包括 Git 子进程 CPU**，不主张总系统 CPU 或内存改善。

两次独立的 10 对结果保存在 [首次候选结果](git-refresh-performance-results.json) 和 [补充对照结果](git-refresh-end-to-end-results.json)。后一次对应增加元数据失败重试保护的最终实现：

| 场景 | 基线中位 ms | 候选中位 ms | 配对中位差 ms | 配对 MAD ms | 更快配对 | 双侧 sign p |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 冷提交元数据刷新 | 160.850 | 134.426 | -26.001 | 5.010 | 9/10 | 0.02148 |
| 混合仓库增量刷新 | 128.951 | 104.535 | -25.315 | 3.544 | 10/10 | 0.00195 |
| 全已提交仓库增量刷新（12 个） | 62.237 | 62.617 | -0.196 | 0.726 | 6/10 | 0.75391 |
| 旧扫描器增量对照 | 174.773 | 174.064 | -0.999 | 0.721 | 7/10 | 0.34375 |

混合增量场景中位耗时下降 **18.9%**，冷元数据刷新下降 **16.4%**。首次候选分别下降 20.8% 和 15.3%，两次方向一致。每轮 status 仍为 24 次；冷刷新 log 24→12，增量刷新 log 12→0。并发峰值两侧均为 6，mock 并发探针也达到配置上限，因此没有重写并发调度。

这些收益适用于包含尚无提交仓库的集合。全已提交仓库和旧扫描器均无超噪声收益证据，不作更广泛加速承诺。

### 被拒绝的调度耗时结论

补充结果同时探索完整 `ScanScheduler` timer 刷新、快照提交及活动/历史档案字节一致性。功能检查全部通过，Git log 同样 12→0。但独立 CLI 的 WidgetKit 调用出现重复 `sandbox_extension_issue_file failed` 警告，scheduler 时延 8/10 更快、`p=0.109375`，CPU 噪声也大。该组 JSON 已标记 `scheduler_measurement_valid=false`，**拒绝以此宣称完整端到端耗时改善**。不延长超时或调整产品行为来制造收益。

基准默认不再运行这个环境受限的探索项；需要时可显式加 `--include-scheduler`。脚本会记录 stderr 情况，sandbox extension 失败时将 scheduler 测量标记为无效。真实完整链路的功能验收由原生测试承担。

## 本轮验收

所有原生验证共用 `/tmp/devpulse-next-perf-build`，unsigned 模式，隔离 App Group 和 UserDefaults。第一次沙箱构建因 `SwiftMacros.TaskLocalMacro` 插件无法执行而失败，完整日志保留在 `/var/folders/1z/bw5lw7ds72ngrqfz9fmz48mh0000gn/T/devpulse-build.gYc68g`。在正常本机执行环境重跑通过，没有修改项目的宏或签名设置。

已实际通过：

- `verify.sh build`：App、Widget 和测试包构建。
- 六个定向套件（RefreshEngineIntegration、RefreshCompletion、DiscoveryGitCallAccounting、RetainedTab、WidgetDegradedRendering、WidgetLifecycleScenarios）：66 tests / 6 suites，8.628 秒。
- `verify.sh final`：948 tests / 95 suites，106.999 秒；完整回归仅运行一次。
- `verify.sh widgetkit`：16 PASS / 0 FAIL，实际产物、嵌入、bundle identifiers、App Group 配置均匹配。
- 原生 NSHostingView 测试验证隐藏时抑制求值、激活读取实时状态、状态/身份/工厂/onAppear 保留及 Settings 导航 Binding。
- 真实 Git fixture 验证无提交→首次提交→orphan branch；六组错误组合验证无提交/已有提交后 HEAD 变化 × timeout/nonZero/outputLimit 的恢复重试；缺失 OID 不视为无提交。

最新 `main` 上的真实 NSHostingView 页面重测也通过，300 个合成仓库、两版各三次，原始记录见 [tab-performance-latest-results.json](tab-performance-latest-results.json)：

| 场景（整个序列） | 基线 CPU ms 中位数 | 候选 CPU ms 中位数 | 降幅 |
| --- | ---: | ---: | ---: |
| 七页切换 | 7542.638 | 2943.734 | 61.0% |
| 十次后台进度更新 | 13109.767 | 2148.043 | 83.6% |
| 三次快照替换 | 3827.113 | 1280.467 | 66.5% |

三次均重现隐藏页面求值和偏好读取计数的削减。该入口先运行全部 baseline，再运行全部 candidate，未交替配对；幅度大且计算次数确定，支持保留已有成果，但不将短序列 settle p95 解释为 FPS 或真实交互延迟。

`git diff --check`、两个 Python 基准脚本的 AST 语法检查及新基准 CLI 参数检查均通过。已有页面成果和本轮刷新成果分别暂存后，`secret-scan.sh staged` 均通过。页面成果已单独提交为 `9339997`，刷新成果与本报告另作一次提交。

## 剩余风险与边界

没有安装或改动用户正在运行的 App，也没有验证桌面上已注册 Widget 的实际唤起、呈现时间和 reload latency。Widget 构建、共享数据/降级逻辑及 wiring 已验证；安装态视觉与签名运行仍需单独验证。全提交的大型真实仓库集合和完整调度耗时没有新增可靠加速结论。性能数字来自此机器上的隔离合成 Git 仓库，不能外推为所有用户仓库的收益。
