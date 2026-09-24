# 端到端增量刷新测量

本入口补足 `scripts/measure-incremental-refresh.sh` 的扫描器级盲点：实际驱动 `ScanScheduler` 的 timer 刷新和 `RefreshEngine.execute`，等待共享快照提交及活动/历史档案更新。它是**测量设施**，不修改生产刷新逻辑。

## 可复跑命令

```sh
RUNS=10 \
BASELINE_REV=7f29c0f \
DERIVED_DATA_PATH=/tmp/devpulse-refresh-e2e \
OUTPUT_DIR=/tmp/devpulse-refresh-e2e-results \
./scripts/measure-end-to-end-refresh.sh
```

`RUNS` 是配对数，最小为 5。脚本分别构建 `BASELINE_REV` 和运行时 `git log -1` 的当前版本；每个版本使用同一个 `DERIVED_DATA_PATH` 下的独立子目录，测量调用统一使用 `xcodebuild test-without-building`，避免把编译时间计入刷新时延。`OUTPUT_DIR` 必须不存在或为空，脚本不覆盖已有证据。需要 Xcode、XcodeGen、Git 和 macOS `/usr/bin/time -l`。

输出目录包含：

- `samples.tsv`：每条样本的配对序号、采样顺序、scheduler 墙钟、`RefreshEngine` 自报耗时、命令级 RSS 和 peak footprint。
- `summary.txt`：配对中位差、MAD、方向计数、精确双侧 sign test，以及兼容 `PerformanceBaselineManager` 的噪声结论。
- `performance-baselines.json`：`endToEndIncrementalRefresh` 的 mean/stddev/sampleCount，时间单位为秒。
- `raw/`：两版本构建日志、每次测试的原始输出和 `/usr/bin/time -l` 输出。
- `system/`：构建前、采样前后及每条样本前后的时间戳、load average 和 build/test 进程快照。
- `samples/`：每次独立的临时 Git 工作区、App Group 目录和偏好 suite。

现有 `./scripts/verify.sh final` 会发现并运行 `EndToEndRefreshMeasurementTests`，但未设置测量环境变量时它**有意 no-op**；完整重复基准需另行运行上述脚本。该脚本自行构建、测量，不需要先运行 `verify.sh build`。原扫描器级入口 `scripts/measure-incremental-refresh.sh` 保持独立，不能把它的结果当作完整刷新时延。

## 场景与测量边界

每条样本都创建新的 workspace、4 个临时 Git 仓库、临时 App Group 容器和唯一 UserDefaults suite。先通过 `ScanScheduler.scanNow(forceRepositoryDiscovery: true, source: .manual)` 建立完整已知仓库范围和初始快照；随后仅改动一个仓库中的 `README.md`，将计时起点设在 `scanNow(forceRepositoryDiscovery: false, source: .timer)` 调用前。测试等待：

1. `ScanScheduler` 进入 `.success`；
2. 新的共享快照 revision 已提交、刷新标记关闭，4 个仓库中有工作树改动；
3. 活动事件档案和仓库历史档案都已更新；
4. 执行记录确认 `RefreshEngine` 实际运行、`forceRepositoryDiscovery == false`、已知仓库数和结果仓库数均为 4。

因此 `scheduler_wall_ms` 覆盖调度触发到快照及两个档案完成更新，`refresh_engine_ms` 是 `RefreshEngine` diagnostics 的内部总耗时。初次发现/fixture 创建不在被计时区间内。它不代表 UI 交互、Widget reload 完成时间或用户真实目录扫描。

`7f29c0f` 尚无当前测试使用的 App Group 环境隔离 seam。测量脚本只在 `git archive` 导出的临时基线树内回补这个测试隔离 seam；未修改基线提交或当前生产代码。没有设置 override 时 shim 仍使用原 `group.local.devpulse` 容器/suite；实际样本则使用临时容器与唯一 suite。临时工作区和样本数据不触碰常驻 App/Widget 的真实 App Group 容器。

## 记录的对比结果

比较对象：基线 `7f29c0f` 与当前代码 `646205558929f7309f20163a7a624fe854eb205d`。同机同脚本运行 10 组配对样本：奇数组先 baseline、偶数组先 current；每个单次运行都使用全新目录。完整数值、每次原始 xcodebuild/time 日志和系统快照保存在 `.herdr-project/devpulse-t-0034/library/e2e-measurement-6462055-final/`。

| 配对 | 顺序 | baseline scheduler (ms) | current scheduler (ms) | 配对差 current−baseline (ms) |
|---:|---|---:|---:|---:|
| 1 | baseline first | 380.118 | 324.651 | -55.467 |
| 2 | current first | 390.256 | 326.630 | -63.626 |
| 3 | baseline first | 383.632 | 323.419 | -60.213 |
| 4 | current first | 384.385 | 326.252 | -58.133 |
| 5 | baseline first | 380.140 | 328.266 | -51.874 |
| 6 | current first | 375.066 | 320.900 | -54.166 |
| 7 | baseline first | 382.231 | 317.062 | -65.169 |
| 8 | current first | 438.444 | 322.925 | -115.519 |
| 9 | baseline first | 385.456 | 317.390 | -68.066 |
| 10 | current first | 382.582 | 314.703 | -67.879 |

摘要结果摘录（完整原始 TSV 输出见 `.herdr-project/devpulse-t-0034/library/e2e-measurement-6462055-final/summary.txt`）：

```text
metric  baseline_median  current_median  paired_median_delta(current-baseline)  paired_MAD  faster_pairs  slower_pairs  tied_pairs  two_sided_sign_p
scheduler_wall_ms  383.107  323.172  -61.919  6.053  10/10  0/10  0/10  0.00195
refresh_engine_ms  231.939  215.855  -14.516  2.545
command_max_rss_bytes  181215232  181231616  0  24576  3/10  4/10  3/10  1.00000
command_peak_footprint_bytes  89162712  89220032  57344  311296
elapsed_group_summary  baseline_mean=388.231  baseline_population_sd=17.151  current_mean=322.220  current_population_sd=4.339  pairs=10
elapsed_improvement_beyond_noise=yes
elapsed_improved_pairs=10/10
elapsed_paired_median_delta_ms=-61.919
elapsed_paired_MAD_ms=6.053
elapsed_exact_two_sided_sign_p=0.00195
```

**结论：端到端刷新耗时有超出噪声的改善。** 当前相对基线的配对中位差为 **-61.919 ms**，约为基线中位数的 **16.2%**；10/10 配对更快。绝对配对改善也大于基线总体标准差的 2 倍（61.919 ms 对 34.302 ms）。同时用非参数精确双侧 sign test 检验 10 组非平局配对的方向一致性：`p=0.00195`。判断没有使用“中位数差大于单组 MAD”作为显著性规则；配对 MAD `6.053 ms` 只作离散程度描述。第 8 组基线 `438.444 ms` 完整保留，没有剔除离群样本。

`RefreshEngine` 内部耗时的配对中位差为 `-14.516 ms`；该次测量未对它单独做显著性检验。不能把 scheduler 总改善进一步归因到某个未单独计时的阶段。内存指标是一次完整 `xcodebuild test-without-building` 命令及测试宿主的峰值，不是刷新进程独占值：RSS 配对差中位数为 0、3/10 更低、4/10 更高、3/10 持平（`p=1.0`）；peak footprint 中位数仅相差 `57,344 bytes`。**没有可支持的内存改善结论**，本次明确改善项是耗时。

每次日志都确认 `repositories=4 known_repositories=4 forced_discovery=false` 且活动/历史档案更新。Git subprocess 次数没有在这个入口单独计数，不从墙钟推断该计数。

## 与既有基准设施的关系

入口遵循既有测量脚本的 `RUNS`、`DERIVED_DATA_PATH`、`OUTPUT_DIR` 约定，并生成 `PerformanceBaselineManager.load(from:)` 可读取的 `ScenarioBaseline` JSON。它不把 `BenchmarkSuite` 中名为 `incrementalRefresh` 的通用 scenario 误当成生产刷新：通用 `BenchmarkRunner` 需要调用方传入 setup/action，本身不建立 `ScanScheduler` 的 App Group、首次发现与快照历史状态；这里由 Swift Testing fixture 建立真实调度器状态，并走其生产刷新路径。时间噪声判断同时报告配对精确 sign test，并与既有 RegressionGate 的 `max(meanElapsed * 20%, 2 * populationSD)` 基线阈值对照；不使用中位数差与 MAD 的简单大小比较判显著。

本次仅添加测试、测量入口、文档和生成的测试 target 引用；未改生产代码，因此不改变其他生产 benchmark scenario 的实现或行为。除端到端测量外，未在本线程重跑其他独立 benchmark，不据此额外声称那些场景的数值无回退。

## 机器、并发与验证

采样机器为 Apple M2（`Mac14,2`，arm64，8 个逻辑 CPU，16 GiB），macOS 27.0（build `26A428`），Xcode 27.0（build `27A266a`）。测量在同一进程环境连续完成：开始时 load average 为 `1.73 / 3.06 / 3.45`，build 后、样本前为 `3.91 / 3.47 / 3.58`，结束为 `2.20 / 3.00 / 3.39`（分别为 1/5/15 分钟）。单样本前后快照中未观察到并发 `xcodebuild` / `xctest`；空闲的 XcodeBuild MCP helper 持续存在。常驻 `DevPulse.app` 与 Widget extension 在测量开始前可见；它们使用真实容器，而测量使用隔离容器。它们仍可能带来少量系统资源噪声，因此保留了交替配对和每样本 load/进程快照。

最终全量验收使用独立 DerivedData 执行 `DERIVED_DATA_PATH=/tmp/devpulse-t0034-e2e-final ./scripts/verify.sh final`：构建通过，`918 tests / 92 suites` 全部通过，退出码 0。端到端重复采样自身的 build 与 20 次定向 `test-without-building` 已由上述入口执行；常规 `verify.sh final` 中该测量测试因缺少样本环境而 no-op。安装态签名自检、真实用户目录扫描和 Widget reload 不属于此测量范围。提交 hash 与原始 Git 输出在工作线程报告 `report.md` 中记录。

## 完整 refresh pipeline 分段 profiling（t-0053）

新增测量输出覆盖 `RefreshEngine` 的 discovery/coreStatus/extendedInfo/merge/persistence preparation/deferred widgetSync；scheduler 的 result `applyPins`、final snapshot prepare/applyPins、snapshot revision read、snapshot commit + read-back verification、activity archive save queue、repository history archive update，以及 `WidgetCenter.reloadTimelines` API 请求耗时与调用数。所有计时都用 `ProcessInfo.systemUptime`。snapshot/archive 工作可并发执行，阶段耗时不可简单相加；`scheduler_wall_ms` 是真实 timer 增量刷新总墙钟。

Git 分阶段调用计数现取自实际 runner 调用：`coreStatus` 使用 status 实际调用数，`extendedInfo` 单独计数真实 runner invocation（不再把“完成处理的仓库数/复用元数据仓库数”误当 git log 调用数），discovery 使用 scanner 的 `ScanMetrics` ledger。`DiscoveryGitCallAccountingTests` 增加真实 runner 账本对照及不变 HEAD 增量刷新覆盖。

在 `2f0dc09` 基线与本线程 measurement-instrumented checkout 上运行 10 对交替配对样本，命令：

```sh
RUNS=10 BASELINE_REV=2f0dc09 \
  DERIVED_DATA_PATH=/tmp/devpulse-t0053-profile-dd-final \
  OUTPUT_DIR=/tmp/devpulse-t0053-profile-final \
  ./scripts/measure-end-to-end-refresh.sh
```

fixture 是 4 个临时仓库、一个 README 工作树变更、`forceRepositoryDiscovery=false`。10 对结果的阶段中位数如下，按测得耗时降序（互相重叠的 I/O/调度计时不做相加）：

| 阶段 | baseline 中位数 | instrumented 中位数 | 计数/含义 |
|---|---:|---:|---|
| RefreshEngine coreStatus | 210.300 ms | 210.139 ms | 4 次 status Git 调用 |
| snapshot commit + read-back verify | 28.679 ms | 27.409 ms | scheduler 最终快照提交一次 |
| activity archive save queue | 11.537 ms | 11.534 ms | 一次异步串行队列保存耗时（含排队） |
| snapshot revision read | 12.287 ms | 12.227 ms | 一次 `AppGroupStore.read()` |
| snapshot prepare `applyPins` | 8.463 ms | 8.974 ms | final snapshot prepare |
| scheduler result `applyPins` | 4.418 ms | 4.351 ms | engine 返回后的一次 |
| discovery | 4.642 ms | 4.578 ms | 本 fixture 已知仓库路径复用；0 Git 调用 |
| history archive update | 1.026 ms | 1.023 ms | 一次 read/merge/write 更新 |
| merge | 1.957 ms | 1.399 ms | RefreshEngine merge |
| engine persistence preparation | 0.714 ms | 0.724 ms | 仅内存快照准备，不是磁盘持久化 |
| extendedInfo | 0.065 ms | 0.088 ms | 0 次 Git log 调用 |
| Widget reload request API | 0 ms | 0 ms | timer 刷新判定为 skip；未请求 reload |

调用账本每次均为 `totalGitCalls=4`：`discovery=0`、`coreStatus=4`、`extendedInfo=0`；activity archive/history/snapshot commit 均成功更新，Widget reload decision 为 skip、reload API 调用 0。实际扫描 discovery 仍被计时，尽管此增量场景在已知仓库集合上没有 discovery Git spawn。

整轮 `scheduler_wall_ms` baseline/current 中位数 `321.178 / 319.289 ms`，配对中位差 `-3.564 ms`、配对 MAD `8.674 ms`，方向为 6/10 更快，精确双侧 sign test `p=0.75391`：**无超噪声端到端改善证据**。本次是计量/diagnostics 校正，不是性能优化；不以小幅中位差声称收益。峰值 RSS/footprint 是 xcodebuild 测试命令级，不代表刷新进程独占值。

测量环境为 Mac14,2 Apple M2 / 8 logical CPUs / macOS 27.0 / Xcode 27.0；metadata 与每样本前后 load/process 快照在附带证据中。测量前后未见并发 xcodebuild/xctest；常驻 Widget 扩展存在但测量用独立 App Group/suite。原始 TSV、summary、完整日志、系统快照和临时 fixture 已随工作线程交付物存于 `.herdr-project/devpulse-t-0053/library/refresh-profile-baseline-2f0dc09/`。

WidgetKit API 的同步调用时间已测；在这组**真正计时的 timer 刷新**中 reload decision 为 skip（`widget_reload_request_calls=0`），因此不把启动初次 refresh 时的请求混算进增量刷新。Widget extension 实际何时唤起、何时读取并呈现快照不受本进程控制，仍需独立运行时观测。

## coreStatus 安全候选验证（t-0053 后续）

`coreStatus` 子阶段计量将 stage 拆为 status runner 调用耗时总和（并行单调用时间的和，不应与 stage wall-clock 相加）和解析/buildSnapshot 时间总和。真实 workload 4 个仓库的 runner 累计中位耗时约 795 ms，而解析/buildSnapshot 约 2.6 ms；4 个必需 `git status` 调用未减少。此前已证明 timestamp 跳过不安全（工作树变化不必触动 HEAD/index），且 parser 候选无收益，不再复试。

安全候选：将 `ProcessRunner` 监视子进程退出、取消和输出 EOF 的轮询间隔由 10 ms 缩至 1 ms。只改变父进程观察已发生事件的频率，不改变 Git 参数、结果解析、持久化或错误状态；更快观察取消/超时并发事件，潜在代价是增加轮询 CPU。用 `02310ae`（10 ms）和候选当前代码（1 ms）交替配对 10 次，每次独立 fixture；两侧注入相同的计量探针。

| 指标 | 10 ms baseline | 1 ms candidate | 配对结果 |
|---|---:|---:|---|
| scheduler wall | 315.139 ms | 175.361 ms | median delta -137.685 ms；10/10 更快；p=0.00195 |
| coreStatus wall | 206.428 ms | 64.948 ms | -141.480 ms |
| 4 次 status runner 累计时间 | 795.326 ms | 209.981 ms | -585.345 ms |
| 4 次 snapshot build 累计时间 | 2.580 ms | 2.752 ms | +0.172 ms |
| 总 Git 调用 | 4 | 4 | discovery 0 / status 4 / log 0，不变 |
| xcodebuild 命令 CPU（user+sys） | 0.930 s | 0.930 s | 无可分辨变化（time 输出精度 0.01 s） |

端到端 scheduler 墙钟中位数降低约 43.7%；配对 MAD 16.924 ms，精确双侧 sign test `p=0.00195`，大于噪声且 10/10 方向一致。刷新结果签名 baseline/candidate 逐轮完全一致（`repo-0` changed 1 file，其余 3 仓库 clean），档案更新断言通过；Git 调用数和关键 snapshot commit/archive 指标未见明显回退。CPU 比较只到 xcodebuild 测试命令精度；高分辨率 process/thread CPU 及外部真实目录场景仍未测。

可复跑命令：

```sh
RUNS=10 BASELINE_REV=02310ae \
  DERIVED_DATA_PATH=/tmp/devpulse-t0053-core-poll-dd2 \
  OUTPUT_DIR=/tmp/devpulse-t0053-core-poll-1ms-final \
  ./scripts/measure-end-to-end-refresh.sh
```

全量原始结果在工作线程 library 的 `coreStatus-poll-1ms/` 目录（如本轮证据已归档）。
