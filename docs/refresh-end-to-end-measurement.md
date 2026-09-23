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
