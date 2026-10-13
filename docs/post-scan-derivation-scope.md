# 扫描后派生链的规范路径复用（2026-10-14）

本轮针对「扫描结束 → 仓库派生 → 共享快照写入 → Widget 投影」这一段，只做一项改动：让同一条
派生序列里各次派生**共用一份规范路径复用表**。派生逻辑、快照内容、pins/ignore 语义、并发与
Widget 行为都不变，也不新增缓存层或跨刷新的长生命周期状态。

## 1. 定位过程

### 1.1 每轮刷新派生几次

`ScanScheduler` 对同一份仓库数据做多次派生，每次都会把每个仓库路径解析成规范形式：

| 触发点 | 派生次数 | 位置 |
| --- | ---: | --- |
| 扫描结束的 `applyPins(result.data)` | 1 | `ScanScheduler.performScanNow` |
| 本次扫描的共享快照写入序列（pre-write / post-write read-back / Widget 投影） | 3 | `syncSharedSnapshot` + `handleSyncSnapshotSuccess` + `setWidgetReadableSnapshot` |
| pending item 变化、pin 切换、ignore、取消、看门狗各自触发的快照写入序列 | 每次 3 | 同上 |
| 仓库重试、自检等 | 各自 1–3 | 同上 |

一次 timer 增量刷新实测会执行 **2–3 次完整快照写入序列**（`refresh-start` 不是派生序列），因此
同一份路径解析被重复执行很多次。

### 1.2 路径解析有多贵

`RepositoryIdentity.canonicalPath` 对每个输入做：空白/`~` 展开、`getpwuid` 取 home、
legacy container 前缀判定、`URL.standardizedFileURL`（两次）、`fileExists`（存在时再加
`resolvingSymlinksInPath`）。仓库存在时是真文件系统调用，不存在时也不便宜。仓库自带测试
`RepositoryPathCanonicalizationReuseTests.canonicalPathComputationCost` 在本机测得
**56.38 µs/次**。

把生产组合（`RepositoryScope.filtering` + `RepositoryIdentityMigration.migrate` + pin 应用 +
`RepositorySorter.sort`，即 `applyPins` 的全部内容）单独计时（`-O -whole-module-optimization`，
真实目录，Release）：

| 仓库数 | 单次派生（独立表） |
| --- | ---: |
| 8 | 0.49 ms |
| 60 | 3.46 ms |
| 240 | 13.81 ms |

其中大部分是路径解析：同一份输入的第二次调用在复用表内只需查表（240 仓库 13.81 ms →
3.39 ms，见 §4 的 `one_pass_own_scope` 与链式差值）。

结论：**派生逻辑本身要保留，但它对同一路径的重复解析是纯冗余**。

## 2. 改动

`DevPulseNative/Core/ScanScheduler.swift`（+64 / −14，其中约一半是注释与多行参数；无新类型）：

1. `applyPins(_:using:)` 新增 `scope` 参数；原 `applyPins(_:)` 保留为「自带一张表」的包装，
   行为不变。
2. `syncSharedSnapshot(from:previousSnapshot:reason:canonicalizationScope:)` 的 scope 参数为
   `nil` 时**在序列内部新建一张表**，并把同一张表用于该序列的 pre-write 派生、post-write
   read-back 派生和 Widget 投影。因此每个快照写入序列都只解析一次相同路径，无论由谁触发。
3. 扫描结束路径显式创建一张表，先用于 `applyPins(result.data)`，再传给本次写入序列，使扫描
   结束的那次派生也落在同一张表里。
4. 每张表的生命周期仍严格等于拥有它的那条序列（同步过程毫秒级；扫描结束序列与其写入序列
   同属一代扫描）。没有跨代、跨异步评估或进程级共享。

### 2.1 为什么复用不改变结果

- 复用表只缓存「raw path → canonical path」，不缓存过滤/迁移/排序结果；`RepositoryScope.filtering`、
  `RepositoryIdentityMigration.migrate`、pin 应用和 `RepositorySorter.sort` 每次都完整执行。
- 同一张表里，`canonicalPath` 的 **lookups 次数完全不变**（§4 的 6727 = 6727），只有
  computations（真正访问文件系统的次数）从 4N 降到 N；同一输入在一条序列内本就返回同一个值。
- 派生是幂等的：同一份数据连续派生多次的结果等于一次派生的结果，这一点由新增测试
  `postScanDerivationSequenceSharesOneReuseMap` 直接断言（`shared.result == perPass.result ==
  single`），也由内容指纹在 4/8/60/240 四个规模上固定（§3）。

## 3. 行为等价证据

`scripts/benchmark-post-scan-derivations.sh` 用生产组合对同一份输入跑两种调用方式，并对每种
输出取 SHA-256 内容指纹（对 payload 做与磁盘格式无关的确定性重编码），作为退出码门禁：

- **内容指纹**：4/8/60/240 四个规模上两种调用方式的指纹**逐字相同**（例如 240 仓库的
  `17e79b1978a0edb0`）。任何标识、路径、顺序或字段差异都会使指纹不同并以非零退出。
- **lookups 不变**：两种方式的 `lookups` 完全相同，证明改动只减少了文件系统访问，没有减少或
  改变任何派生问题。
- **确定性账本**：`computations` 由 `4 × 仓库数` 降为 `仓库数`（4 仓库 16→4、8 仓库 32→8、
  60 仓库 240→60、240 仓库 960→240）。
- 门禁自检：`equivalence=identical ledger=as_expected` 为该脚本的通过标志；指纹或账本不符时以
  非零退出并打印 `EQUIVALENCE/LEDGER MISMATCH`。

原生测试侧：

- `RepositoryPathCanonicalizationReuseTests.postScanDerivationSequenceSharesOneReuseMap`（新增）
  以确定性计数器固定：同一序列内 `lookups=546` 不变、`computations` 80→20（20 仓库 × 4 次
  派生），并断言三种计算（逐次独立表 / 共享表 / 单次派生）结果**逐字段相等**。
- 既有 `applyPinsCanonicalizationIsLocalAndEquivalent`、`widgetSnapshotFilteringReusesRepeatedCanonicalPaths`
  保持通过，未放宽任何断言。

生产链路等价性：`scripts/measure-end-to-end-refresh.sh` 的产出里，
`refresh_result_signature`（对最终共享快照的仓库字段取 SHA-256）在基线与候选的 **16 个样本中
只有一个取值**，即真实 timer 刷新写出的共享数据完全一致。

## 4. A/B 数据

### 4.1 生产组合（Release，真实目录）

`./scripts/benchmark-post-scan-derivations.sh`（4/8/60/240 仓库，每轮 21 次采样取中位数、再取
3 轮的中位数；仓库路径都是 harness 里真实创建的目录，因此 `canonicalPath` 走完整文件系统解析）：

| 仓库数 | 单次派生（独立表） | 序列·每次派生独立表（改动前） | 序列·共用一张表（改动后） | 降幅 | 路径解析次数 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 4 | 0.49 ms | 1.22 ms | 0.39 ms | −67.6% | 16 → 4 |
| 8 | 0.49 ms | 1.72 ms | 0.66 ms | −61.3% | 32 → 8 |
| 60 | 3.46 ms | 12.77 ms | 4.91 ms | −61.5% | 240 → 60 |
| 240 | 13.81 ms | 50.91 ms | 19.45 ms | −61.8% | 960 → 240 |

「序列」= 扫描结束派生 + pre-write 派生 + post-write read-back 派生 + Widget 投影，正是扫描结束后
那一条真实序列（每次派生仍执行完整逻辑，只有路径解析被复用）。降幅随仓库数进入噪声以上的
区间后稳定在约 62%；小规模（4–8 仓库）绝对收益约 0.8–1.1 ms。

### 4.2 真实生产链路（`EndToEndRefreshMeasurementTests`，240 个真实 Git 仓库，8 对交替配对）

命令（基线为含本轮之前全部优化的 `582a026`，两侧各自 `build-for-testing`，采样用
`test-without-running` 之外的 `test-without-building`；`DEVPULSE_E2E_MODE=real`）：

```sh
RUNS=8 OUT=<dir> bash <runner>   # 240 个真实仓库的 REAL_REPOSITORIES_FILE，配对交替顺序
```

| 阶段 | 基线中位 | 候选中位 | 配对中位差 | 配对 MAD | 更快配对 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `snapshot_prepare_apply_pins_ms`（写入序列的 pre-write 派生，本轮目标） | 43.08 ms | 31.14 ms | **−11.80 ms** | 0.08 ms | **8/8** |
| `scheduler_apply_pins_ms`（扫描结束派生；本轮未改动，对照组） | 24.97 ms | 24.74 ms | −0.14 ms | 0.37 ms | 5/8 |
| `snapshot_revision_read_ms`（无关阶段，对照组） | 11.53 ms | 11.58 ms | +0.06 ms | 0.15 ms | 3/8 |
| `snapshot_commit_and_verify_ms`（无关阶段，对照组） | 28.06 ms | 27.80 ms | −0.14 ms | 0.86 ms | 4/8 |
| `scheduler_wall_ms`（整轮墙钟） | 4617.14 ms | 4237.80 ms | −159.73 ms | 195.76 ms | 6/8 |

同一命令在扩展改动（让每次写入序列各自建表，§2 第 2 点）之前的一次独立复现：该阶段
−12.05 ms、MAD 0.19 ms、8/8；两个对照组分别 +0.01 ms 与 −0.10 ms。两次方向、量级与显著性一致。

- `snapshot_prepare_apply_pins_ms` 是**每次快照写入时 pre-write 派生的累计耗时**（测量 sink 对同名
  阶段求和）。该刷新窗口内执行了 3 次写入序列，其中扫描结束那次因共用扫描结束的复用表而变暖：
  43.10 ms → 31.10 ms；8 对全部更快、MAD 仅 0.19 ms，是确定性级的信号。其余两次写入序列的
  pre-write 派生仍是各自序列的第一次派生，因此这一项只体现了一次变暖。
- 两个对照阶段（扫描结束派生、快照 revision 读取）与这次改动无关，实测差异在 ±0.1 ms 内，
  说明上述信号不是环境漂移。
- **整轮墙钟与 CPU 在这组测试里不可分辨**：240 个真实仓库的定时刷新由 `git status` 子进程主导
  （`core_status_ms` 中位 2405–2817 ms，`scheduler_wall_ms` 约 4.2–4.6 s），单对差值在 −0.88 s ~
  +1.85 s 之间波动，而两次独立运行给出的整轮方向相反（一次 +150 ms、一次 −160 ms）。本轮不
  据此声称端到端墙钟或 CPU 收益。本机同时运行着其他负载（load average 约 5），这类 Git 子进程
  计时噪声远大于派生阶段的绝对收益。
- 该入口未单独计量 post-write read-back 派生与 Widget 投影，它们的收益由 §4.1 的同构序列覆盖。

## 5. 验证

- `./scripts/verify.sh build`：App、Widget、测试包构建通过。
- `./scripts/verify.sh test DevPulseTests/RepositoryPathCanonicalizationReuseTests
  DevPulseTests/CommitReadinessEngineTests DevPulseTests/RefreshEngineIntegrationTests
  DevPulseTests/RefreshCompletionTests DevPulseTests/DataFreshnessStateTests
  DevPulseTests/ScanDataConsistencyTests DevPulseTests/WidgetDegradedRenderingTests
  DevPulseTests/RepositoryDiscoveryExperienceTests`：322 tests / 7 suites 通过。
- `./scripts/verify.sh final`：完整回归（见提交说明）。
- `./scripts/benchmark-post-scan-derivations.sh`：`equivalence=identical ledger=as_expected`。
- 端到端 240 仓库配对 A/B：16 个样本 `refresh_result_signature` 唯一取值。

## 6. 已测量但本轮未做的部分

1. **第一次派生必须付出完整解析成本。** 每条序列的第一个派生没有可复用的表；扫描结束派生之所以
   能变暖，是因为它与自己触发的写入序列共用一张表。没有跨代共享，就没有跨代的陈旧风险。
2. **完全去掉重复派生（而不是只复用解析）。** 新增测试已证明重复派生是幂等的
   （`shared.result == single`），因此「写入序列的 pre-write 派生在输入已是 `lastResult` 派生
   结果时可以跳过」在数据上成立。本轮不做：该结论依赖调用方不变量（输入一定是 `applyPins`
   输出），当前实现正是靠重复派生兜底，去掉它会把未来的调用方失误变成静默的数据不一致。
3. **跨异步边界复用同一张表**（例如让 pending item 评估完成后的写入序列复用扫描代的表）。
   可省下该序列第一次派生的解析，但表的生命周期会拉长到一次异步评估（可能数十秒），
   而 `lastResult` 在此期间可能被 pin 切换、仓库重试或新一轮扫描替换；收益不足以为这点
   陈旧窗口与审查成本背书。本轮改法让该序列自己建表，生命周期仍是毫秒级。
4. **让 `canonicalPath` 对「已经是规范形式」的输入走快速通道。** 需要证明输入来源
   （否则无法判断是否已解析符号链接），本质上仍是复用来源问题，且容易把错误结论带到
   持久化的仓库身份上；不做。

## 7. 剩余风险与未验证

- 端到端墙钟与 CPU 未能在本机噪声下分辨（Git 子进程主导 + 机器有其他负载），本轮只声明派生阶段
  的配对差异与确定性账本，不外推为整轮加速。
- 性能数字来自本机隔离合成 fixture（真实目录、真实 Git 仓库），不能外推为所有用户仓库的收益；
  收益与仓库数近似线性（每仓库每多一次派生约省 43 µs，即 240 仓库每多一次派生约 10.4 ms）。
- 未安装或改动用户正在运行的 App，未验证桌面上已注册 Widget 的呈现时延。
