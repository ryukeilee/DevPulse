# 刷新阶段 Git 子进程等待与协作线程池（2026-10-20）

本轮只改一处：`RefreshEngine` 的 Git 命令不再在 Swift 协作线程池线程上阻塞等待子进程，
改为在专用队列上阻塞、由任务继续等待结果。命令参数、只读范围、并发上限、超时、取消语义、
进程组终止、输出上限和快照内容全部不变。

## 1. 定位过程

### 1.1 端到端阶段归因

用 `ScanScheduler` 的临时时间戳探针（已撤除，不进入提交）测量一次 timer 增量刷新（200 个仓库、
App Group 与 defaults suite 隔离）的完整链路：

```text
performScanNow 入口 → refresh-start 快照写入        4.3 ms
→ scanTask 启动                                   11.0 ms
→ 扫描根解析（200 个带 security-scoped bookmark 的自定义目录） 839 ms
→ RefreshEngine.before → after                   1693 ms
→ 完成块（applyPins、pending items、updateScanInterval） 40 ms
→ 共享快照写入（revision 读 + 提交 + 回读）          43 ms
→ handleSyncSnapshotSuccess（回读派生 + Widget 投影）  5 ms
```

`RefreshEngine` 内部 1693 ms 中 `coreStatus` 占 1206 ms，`discovery` 占 429 ms；
`coreStatus` 阶段单次 `git status` 的平均墙钟是 **46.4 ms**，而同一份仓库、同样 10 并发的
独立进程内测量只要 **13.8 ms**，git 本体只要 **6 ms**。

### 1.2 多出来的时间在哪里

同一进程内用测试宿主直接跑生产 `GitCommandRunner`（200 仓库、并发 10）：

| 运行环境 | 200 次 status 墙钟 | 单次 |
| --- | ---: | ---: |
| 独立测试宿主内直接调用 runner | 356.3 ms | 13.83 ms |
| `RefreshEngine` 的 status 阶段 | 1206 ms | 46.4 ms |

差距不在 `ProcessRunner` 本身。用 `measurementObserver` 临时记录每个仓库任务的阶段：

| 记录项 | 200 个任务合计 |
| --- | ---: |
| `engine_task_wait`（提交到任务体开始） | 542 ms |
| `engine_task_invalidate_hop`（任务内 `await isInvalidated`） | 780 ms |
| `engine_result_invalidate`（结果侧 actor 跳转） | 0.2 ms |
| `core_status_git_runner`（同步 Git 调用） | 8687 ms |

结论：`ProcessRunner.runDetailed` 用 1 ms 轮询等待子进程，**占住的是 Swift 协作线程池线程**。
扫描并发默认 10，而协作池宽度等于核心数（本机 8）。10 个任务同时阻塞后，池里没有空线程来
恢复引擎自己的 actor 工作：一次本该几微秒的 actor 跳转要等 3.9 ms，新任务要等 2.7 ms 才能开始，
于是每次 `git status` 的墙钟被拉长到 46 ms。采样也印证了这一点：`coreStatus` 期间协作线程
90% 的样本停在 `ProcessRunner.runDetailed` 的 `Thread.sleep` 上。

### 1.3 为什么不是解析或派生

同一份实测里 `core_status_snapshot_build_ms`（解析 + 构造快照）200 次共 43 ms，`merge` 6 ms；
扫描后派生链（`applyPins` + 预写派生 + 回读派生 + Widget 投影）约 40 ms；共享快照提交 29 ms。
这些都远小于 1206 ms，本轮不动。

## 2. 改动

`DevPulseNative/Core/RefreshEngine.swift`（+70 / −8，含注释）：

1. 新增 `BlockingGitExecution.queue`：一条 `.concurrent` 专用队列，只用于阻塞等待 Git 子进程。
2. 新增 `runGitCommandOffExecutor(...)`：把一次阻塞 `gitCommandRunner` 调用提交到该队列，
   用 `withCheckedContinuation` 让任务等待结果，协作线程池线程立即归还。
3. `withTaskCancellationHandler` 把**任务取消**桥接进 runner 的取消闭包
   （`OffloadedCallCancellation`，`OSAllocatedUnfairLock<Bool>`）。此前 runner 在本任务上下文中
   直接读 `Task.isCancelled`；现在由取消处理器置位共享标志，runner 的 1 ms 轮询仍按原粒度
   发现取消并终止进程组。
4. `coreStatus` 与 `extendedInfo` 两处 Git 调用改用该入口；命令参数、超时值、输出上限、
   取消闭包的其余来源（`engine.isCancelled`、代际 `stale`）逐字保留。

没有新增缓存、跨刷新状态、依赖或快照字段；并发上限仍由 `ScanConfig.maxConcurrentGitOps`
（1…10）决定，队列宽度由该上限自然约束（最多 10 个阻塞调用）。

### 2.1 语义等价性

- **命令与只读边界**：参数仍为 `git status --porcelain=v2 --branch`、`git log -1 --pretty=…`。
- **超时**：`timeout` 在提交前算好并原样传入；`ProcessRunner` 的超时、进程组终止、
  输出上限、EOF 排空、失败分类逻辑一行未改。
- **取消**：任务取消 → `onCancel` → 共享标志 → runner 下一次 1 ms 轮询返回 `.cancelled`
  （与改动前同级延迟）；`engine.cancel()`、代际失效路径不变。新增测试
  `taskCancellationStopsInFlightGitCommands` 覆盖“只取消外层任务”的路径：
  去掉桥接时该测试在 28.5 s 后因 `cancellationObservedCount > 0` 与 `elapsed < 10` 失败。
- **顺序与结果归属**：结果仍按 index 写回 slot，任务组完成顺序不变；
  `counters.peak` 仍按在飞任务数统计（实测仍为 10）。
- **快照内容**：12 个样本（6 组配对）的 `refresh_result_signature` 只有一个取值
  （`85d3dabac04ca70a…`），两侧相同。该签名覆盖仓库名、分支、状态、各类文件计数与 pin 状态
  （9 个字段），不含提交元数据、Widget 汇总或完整持久化结构，因此这里主张的是这些字段等价，
  不是整份载荷逐字节相同；两侧 `total_git_calls` 均为 200。
- **期限语义边界**：超时值仍在提交给队列之前计算，队列排队与 continuation 恢复不计入
  `ProcessRunner` 自己的子进程超时（改动前，任务调度时间同样不计入）。代际 `stale` 仍是
  一次性捕获值：代际推进本身不会立即通知全部在飞命令，改由结果侧检测后 `group.cancelAll()`，
  这与改动前一致，本条不新增即时取消保证。

## 3. 可复现数据

### 3.1 端到端配对测量（Debug，即 `install-and-self-check.sh` 安装的配置）

```sh
# 200 个仓库目录各作为一个自定义扫描目录（harness 的契约：快照仓库数 == 列表条目数）
REAL_REPOSITORIES_FILE=/tmp/devpulse-repos.txt PAIRS=6 \
  OUTPUT_DIR=/tmp/devpulse-refresh-ab DERIVED_DATA_PATH=/tmp/devpulse-refresh-ab-dd \
  ./scripts/measure-refresh-execution-ab.sh
```

`scripts/measure-end-to-end-refresh.sh` 不能直接用于本轮对比：它会把工作区
`ScanScheduler.swift`/`RefreshEngine.swift` 的 diff 套用到基线树上（用于注入测量探针），
而本轮生产改动正好位于 `RefreshEngine.swift`，会把改动同时带进基线。新增的
`measure-refresh-execution-ab.sh` 不改基线树：它把 `REF`（默认 `HEAD`）检出到独立 worktree，
两侧各自 `build-for-testing`，样本交替配对，每个样本使用一次性 App Group 容器与 defaults suite，
并输出 `samples.tsv`、`summary.txt`、`summary.json`。

200 个真实 Git 仓库（列表文件，harness 支持的自定义目录形态），12 个样本交替配对：

| 指标 | 基线中位 | 候选中位 | 配对中位差 | 配对 MAD | 更快配对 | 双侧 sign p |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `scheduler_wall_ms` | 2824.9 | 1940.9 | **−873.5 (−31.3%)** | 32.7 | 6/6 | 0.03125 |
| `refresh_engine_ms` | 1700.7 | 831.2 | −874.3 (−51.4%) | 13.6 | 6/6 | 0.03125 |
| `core_status_ms` | 1248.7 | 384.9 | −866.4 (−69.4%) | 8.7 | 6/6 | 0.03125 |
| `core_status_git_runner_ms`（200 次合计） | 9592.0 | 3657.8 | −5953.2 | 83.6 | 6/6 | 0.03125 |
| `discovery_ms` | 438.2 | 435.9 | −1.2 | 4.1 | 3/6 | 1.0 |
| `snapshot_commit_and_verify_ms` | 28.8 | 29.3 | +1.8 | 2.0 | 2/6 | 0.69 |
| `refresh_cpu_user_ms` | 2392.9 | 2556.5 | +141.9 | 29.5 | 0/6 | 0.03125 |
| `refresh_cpu_system_ms` | 1394.7 | 1575.0 | +158.9 | 15.3 | 0/6 | 0.03125 |

这里的 CPU 是 `RUSAGE_SELF + RUSAGE_CHILDREN` 在刷新窗口内的增量，包含 Git 子进程
（下节 `-O` 基准只统计 `RUSAGE_SELF`，不含子进程，两处数值不可直接相加比较）。改动没有减少
工作量（仍是 200 次 status），只是不再让线程池空转等待：同一窗口内 CPU 上升约 8%，墙钟下降
31%。**本轮不主张 CPU 或内存改善**；`discovery`、快照提交未受影响（配对差在噪声内）。

原始逐样本数据：`docs/refresh-git-execution-results.json`。

### 3.2 优化构建（`swiftc -O -whole-module-optimization`）

```sh
BENCH_CONCURRENCY=10 python3 scripts/benchmark-git-refresh.py \
  --baseline-git da95f8a --runs 7 --repos 200 --output /tmp/devpulse-git-refresh.json
```

`-O` 下 200 仓库、并发 10（应用 `ScanConfig` 默认值）：`incremental_refresh`
墙钟基线中位 436.1 ms → 候选 420.8 ms（配对中位 −14.5 ms，7/7 配对，p=0.0156），
`RUSAGE_SELF` CPU 中位 319.3 → 313.0 ms（−8.3 ms，7/7，p=0.0156）。`cold_refresh` 墙钟
−15.0 ms（6/7，p=0.125，在 7 组样本下不构成显著方向结论），同一场景 CPU −17.7 ms
（7/7，p=0.0156）。`concurrency_probe`（无真实子进程的受控 runner）墙钟 −281.9 ms，
说明被移除的是编排侧的阻塞等待。

`-O` 阶段拆分（200 仓库、并发 10、候选）：`coreStatus` 353.2 ms、`discovery` 56.7 ms、
`merge` 0.4 ms，增量刷新墙钟 411.8 ms。即优化构建下 `git status` 本身已是主要成本，
本轮节省的是等待，不是 Git 工作量。

`incremental_scanner`（旧 `GitRepositoryScanner` 批量路径，非日常刷新入口）无变化
（−0.0 ms，3/7），本轮未改动该路径，也不从本轮数据推论它。

### 3.3 基准脚本的可复现性说明

`scripts/benchmarks/git-refresh.swift` 原来把并发写死为 6。本机核心数为 8，并发 6 时协作池
仍有空线程，构造不出生产默认值（10）下的争用，`-O` 对比会得出“无收益”的结论。为此该基准
新增两个只影响基准的环境开关：`BENCH_CONCURRENCY`（覆盖并发）与 `BENCH_STAGES=1`（打印阶段耗时）。
未设置时行为与原来完全一致（并发 6、无阶段输出）。

## 4. 验证

- `./scripts/verify.sh build`：App、Widget、测试包构建通过。
- 定向套件：`RefreshEngineIntegrationTests`（26 tests，含新增取消测试；
  撤掉桥接后该测试在 28.5 s 后失败）、`RefreshCompletionTests`（13 tests）、
  `ScannerTimeoutErrorTests`、`ScanConcurrencyTests` 全部通过。
- `./scripts/verify.sh final`：1029 tests / 96 suites 通过（86.4 s）。
- `./scripts/verify.sh widgetkit`：16 PASS / 0 FAIL；`./scripts/verify-activity-timeline.sh` 通过。
- 行为对照：12 个端到端样本的 `refresh_result_signature` 相同；`total_git_calls` 两侧均为 200；
  `discovery`/快照提交阶段无回归；`-O` 基准的 5 个场景在两侧内容指纹一致（脚本自带语义门禁）。

## 5. 剩余风险与边界

- 新增测试覆盖“命令进入轮询后取消外层任务”的路径；预先取消与 continuation 建立期间取消
  由 `withTaskCancellationHandler` 的语义保证（取消处理器在安装时即触发），但没有单独测试，
  `extendedInfo` 的取消路径也仍由既有套件覆盖而非新测试覆盖。
- 本轮未把同样的“不要在协作线程上阻塞子进程”处理推广到旧 `GitRepositoryScanner`
  批量路径（`incremental_scanner` 场景），该路径不是日常刷新入口，也未测出回归。
- 自定义扫描目录的 bookmark 解析（`URL(resolvingBookmarkData:options:.withSecurityScope)`）
  每次刷新每个目录约 4 ms，且走 `SecCodeCopySelf`/scoped-bookmarks agent XPC。本轮测量夹具
  用 200 个自定义目录会放大到约 840 ms，但真实用户通常只有个位数目录，故本轮不改；
  若将来出现“目录很多”的真实场景，应优先并发化该解析，而不是降低校验。
- 端到端数据来自本机 Debug 构建与合成夹具（每个仓库 5 个文件、约 1/3 有未提交改动），
  不能外推为所有用户仓库的收益；真实大型仓库的 `git status` 本体耗时不由本轮改变。
- Widget 在本轮测量中未发生 reload（状态无变化），未验证安装态 Widget 呈现时间。
