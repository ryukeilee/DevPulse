# Git 命令输出管道排空链性能验证

本轮只改 `ProcessRunner.runDetailed` 的**输出收集方式**：把每根管道一个
`FileHandle.readabilityHandler` 换成共享串行队列上的 `DispatchSourceRead`
（`ProcessPipeDrain`）。进程启动、1 ms 轮询、超时/取消判定、输出上限、子进程清理
与命令条数均未改动。

## 调用路径

`GitRepositoryScanner.readSnapshots` 以 `ScanConfig.maxConcurrentGitOps`
（默认 10）并发执行 `readSingleSnapshot`，每个仓库运行

| 命令 | 触发条件 | 位置 |
|---|---|---|
| `git status --porcelain=v2 --branch` | 每个可读仓库每轮必执行 | `GitRepositoryScanner.swift:1832` |
| `git log -1 --pretty=%H%x00%cI%x00%s` | HEAD OID 变化时 | `GitRepositoryScanner.swift:1886` |

两者都经由 `defaultGitCommandRunner` → `ProcessRunner.runDetailed`，各创建 2 根
管道（stdout / stderr）。改动前每根管道的读端都设置 `readabilityHandler`，而
Foundation 的 `NSFileHandle` 实现会**为每个文件句柄创建一个专属串行队列**
（`com.apple.NSFileHandle.fd_monitoring`）并在其上挂 dispatch read source。于是
每条 Git 命令要付出 4 个队列 / 4 条监控线程的创建、唤醒与销毁成本，10 路并发时
主进程同时持有约 40 条这类线程。

`sample` 采样（200 仓库 × 60 轮、10 路并发）显示主进程的实际工作帧集中在
`read` / `fstat`（各约 7.4k 样本，即 fd_monitoring 读源反复 re-arm）与
`__semwait_signal`（1 ms 轮询休眠），而 `__posix_spawn` 只有 408 个样本 ——
瓶颈在管道监控机制，不在 `posix_spawn` 本身。

## 改动

`ProcessPipeDrain`（`DevPulseNative/Utilities/ProcessRunner.swift`）：

- 每根管道一个 `DispatchSourceRead`，target 为**共享串行队列**
  `local.devpulse.app.ProcessRunner.pipe-drain`。事件处理器用 `read(2)` 循环读，
  单次调用最多搬运 `bytesPerPass = 4 × 64 KiB` 后返回队列，让同一队列上其它命令的
  EOF 事件不被持续输出的子进程挤住；读源在描述符仍可读时会再次触发（由跨 19 个
  pass 的 4.8 MB 精确字节用例与 40 MB 并发压力探针实证）。
- 读端设置 `O_NONBLOCK`；EOF 由 `read() == 0` 判定，仍然写入同一个
  `ProcessOutputCollector`，因此“双流 EOF 才算成功”、合并输出上限、整块丢弃、
  超限优先等既有语义不变。
- 读端由 source 的 cancel handler 关闭（串行队列保证取消回调排在在途读事件之后，
  不会与 `read` 抢同一个描述符）；写端仍由 `ProcessRunner` 在启动后与 `stop()` 时
  关闭，取消、启动失败、超限、退出四条路径都调用 `stop()`（幂等）。
- 硬读错误不再伪装成正常 EOF：`markStreamFailure` 在**同一次持锁**中置
  `didFailStream` 并结束该流（既不让运行线程空等 0.25 s drain deadline，也不会让
  运行线程看到“已 EOF 但未置失败”的中间态），`runDetailed` 因此走既有的“输出不完整
  → `terminateDescendants` → `.timeout`”分支，绝不把截断输出报成成功。

## 实测（M2 / macOS 27.0.1 / Apple Swift 6.4 / git 2.54）

`./scripts/benchmark-git-command-execution.sh --baseline-git HEAD`
自建 200 个真实 Git 仓库（干净、脏、untracked、分支混合工作树），每轮每仓库执行
status + log，10 路并发，`-O -whole-module-optimization` 编译，A/B 交替各 5 轮，
取每轮中位数（最终提交版本）：

```text
metric                        baseline        current       change
wall_ms                        936.980        736.396       -21.4%
self_cpu_ms                   1929.989        295.613       -84.7%
self_sys_ms                   1439.462        222.465       -84.5%
self_user_ms                   475.481         72.770       -84.7%
self_cpu_us_per_command       4824.973        739.032       -84.7%
child_cpu_ms                  4588.178       4454.223        -2.9%
involuntary_ctx_switches      8221.000       5665.000       -31.1%
commands                       400.000        400.000         0.0%
status_commands                200.000        200.000         0.0%
log_commands                   200.000        200.000         0.0%
pass_failures                        0              0          n/a
scan equivalence: identical fingerprint (c311deeaa5b54708…)
```

每条 Git 命令的主进程 CPU 从 4825 µs 降到 739 µs。子进程 CPU 的 -2.9% 是环境噪声：
命令条数、命令种类与 stdout 完全一致（指纹相同），Git 侧工作量未变。扫描期间主进程
与 Git 子进程争抢同一批核心（8 核机器上 10 路并发），因此主进程 CPU 下降直接反映为
整体耗时下降。

未采纳的相邻改动（同轮实验，均未出现在最终 diff 中）：

| 方案 | self_cpu_ms | wall_ms | 结论 |
|---|---|---|---|
| 基线 | 1873 | 922 | — |
| 共享队列 read source（本轮改动） | 295 | 741 | 采纳 |
| 事件驱动退出等待 + 1 ms 取消轮询 | 1930（-7%） | 928（-1%） | 收益不明确，丢弃 |
| 共享队列 + 事件驱动退出等待 | 267（-86%） | 735（-22%） | 与仅换读源基本相同，故只保留读源改动 |
| 轮询间隔 1 ms → 10 ms | 5724（+174%） | 1463（+56%） | 明确更差，丢弃 |

## 验证

- `./scripts/verify.sh final`：构建 + 全量 **989 tests / 96 suites 全通过**。
- `./scripts/verify.sh test DevPulseTests/ScanPerformanceTests` 连续多轮通过（约 8.9 s）。
- `./scripts/verify-widgetkit.sh`：16 PASS / 0 FAIL；`./scripts/verify-activity-timeline.sh` 通过。
- 新增用例（`DevPulseNativeTests/ScanPerformanceTests.swift`）：
  - `processRunnerDrainsMultiMegabyteStdoutWithoutTruncation`：4.8 MB 输出（跨 19 次
    受预算限制的排空 pass）字节数精确、前后缀一致、不触发 drain deadline。
  - `processRunnerKeepsConcurrentStreamsIsolated`：8 条命令各自输出唯一 payload
    （200 KB stdout + 20 KB stderr），验证不串流、不缺字节、stderr 不混入 stdout。
  - `processRunnerKeepsShortCommandsResponsiveBehindSustainedOutput`：4 条持续输出
    命令（各 1.2 MB）与 8 条短命令混跑，短命令必须及时完成、持续输出必须完整。
  - `processRunnerEnforcesOutputLimitUnderConcurrency`：8 路并发超限必须全部是
    `.outputLimit`，不得退化成 `.timeout`。
  - `processRunnerDoesNotLeakPipeDescriptors`：25 条命令共 100 个管道描述符，
    结束后 fd 数不得增长（容差 ±2）。
- 既有约束用例（取消、硬停、后代持有管道、双管道背压、合并输出上限）全部原样通过。
- 额外压力探针（不在仓库内）：10 路并发各 4 MB stdout + 1 MB stderr 全部
  `.success` 且无 `.timeout`；8 路并发无限输出全部 `.outputLimit`。
- 三轮独立代码评审（T3 委派、非本线程模型）：第 1 轮指出共享队列 EOF 饥饿、读错误
  伪装 EOF、fd 用例偏弱；第 2 轮指出 `markStreamFailure` 的发布竞态（阻塞项）；
  第 3 轮确认该阻塞项已关闭，生产代码无新增阻断缺陷。上述前三项均已修复，测试断言
  中的时间窗口判定因存在误报风险已移除（见下）。

## 未覆盖 / 剩余风险

- **共享串行队列的公平性**只有代码层保证（`bytesPerPass`），没有确定性单元用例证明
  某条短命令的 EOF 一定排在持续输出的排空工作之后：黑盒测试无法在负载下确定性地制造
  该交错。证据为 40 MB 并发压力探针（无假超时）与 3200 条命令的 A/B 基准（无失败）。
  若未来放大管道缓冲、放宽 8 MiB 输出上限或把该队列改成并发队列，需要重新评估。
- **读错误的 `didFailStream` 分支**是防御性代码：独占匿名管道在读端没有可稳定复现的
  `read(2)` 失败路径，该分支只有静态论证，没有端到端用例。
- **fd 用例是进程级近似**：其他 suite 的 fd 开关可能造成误报，也可能掩盖泄漏；本轮
  泄漏证据主要来自单进程内连续 3200 条命令的 A/B 基准（若每条命令泄漏 2 个 fd，
  该进程会在早期即失败）。
- `fcntl(fd, F_SETFL, O_NONBLOCK)` 的返回值未检查。新建 pipe 上没有可触发的失败路径；
  若设置失败且 fd 仍阻塞，handler 的读会阻塞该共享队列，直到进程退出后由 EOF 解除。
- 每命令仍未消除的固定成本（`Process` 启动、`FileHandle` 包装）与运行期 1 ms 轮询
  本轮未改动：事件驱动退出等待在实验中只带来约 1%~2% 额外收益，不构成明确收益，
  故未纳入，避免为不确定收益扩大改动面。
