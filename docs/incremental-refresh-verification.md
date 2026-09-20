# 增量刷新性能改动：集成与终局验收核验

本文档是 Goal「在不改变现有功能和数据正确性的前提下，优化日常增量刷新性能」的
**独立终局核验记录**。它由核验线程 `hp/devpulse/t-0009` 产出，可以脱离任何线程报告单独
阅读：每条结论都附有可复核的命令、原始输出与临时日志路径。

- 核验者立场：**只核验，不修复**。核对中发现的所有问题都按原样记录；未修改任何生产代码、
  测试或断言，未调整签名设置，未跳过测试。
- 本分支只新增本文件。

---

## 0. 判定总览

| # | 验收标准（原文摘要） | 判定 | 主要依据 |
| --- | --- | --- | --- |
| 1 | 不改功能与数据正确性；既有验证入口与全部单元测试通过；共享快照/CAS 语义与既有行为测试不变；无新增旁路写入 | **通过**（在 §9 显式写出的豁免口径下） | §4（全量比对）、§5（边界与旁路写入） |
| 2 | 基于现有基准，同机同命令给出改动前后对比数字，附命令与原始输出 | **通过** | §2、§3（A/B/C 三组对比均附命令与原始输出） |
| 3 | 刷新耗时 / Git 子进程调用次数 / 资源占用三项中至少一项有超出噪声范围的改善，并说明噪声估计与重复测量方法 | **通过**（改善落在共享快照 commit 的确定性 I/O 与 commit 墙钟；扫描器级耗时、Git 调用次数、资源占用均**未移动**） | §2（A：F_FULLFSYNC 6→4、写入 3→2、整档解码 5→1）；§3.3（commit 中位数 39.5→29.9 ms） |
| 4 | 其他关键基准场景无 `RegressionGate` 判定的回退，未出现为改善单点指标而恶化的其他关键指标 | **通过**（限「有可无头运行入口的场景」）；未接入口的 `continuousManualRefresh` 为**无法判定** | §3.4（C：`checkNoResourceGrowth` / `checkRegression` 全部 `isRegression=false`，正向对照 +30% 为 `true`） |
| 5 | 只消除重复工作，定位到最高实际开销（有文件/符号级证据），而非凭猜测重构 | **通过** | §6（文件:符号级证据 + 真实耗时量级） |

**本次改动实际改善的指标**：`SharedSnapshotStore` 一次 commit 的写次数、`F_FULLFSYNC`
次数与 commit 墙钟中位数；一轮刷新内 `RepositoryHistoryStore` 的整档 JSON 解码次数与历史
读取耗时。

**本次改动没有改善的指标**：`GitRepositoryScanner` 扫描器级增量刷新耗时
（`incremental_elapsed_ms`）、Git 子进程调用次数（`incremental_git_calls`）、
`xcodebuild` 命令级 RSS / footprint。这三项在噪声内未移动，本文档不把它们包装成改善。

---

## 1. 环境、起点与集成方式

### 1.1 测量环境

```sh
date '+%Y-%m-%d %H:%M:%S %z'   # 2026-09-20 22:43:24 +0800
sw_vers                        # macOS 27.0 (26A428)
xcodebuild -version            # Xcode 27.0 / Build version 27A266a
sysctl -n hw.model             # Mac14,2
uname -m                       # arm64
sysctl -n hw.ncpu              # 8
uptime                         # load averages: 3.49 3.45 3.83
```

**负载如实记录**：核验期间系统负载均值常驻 3.2–3.5（8 核），本机同时存在其它线程 / 其它
仓库的构建活动。所有墙钟结论因此都按「多轮独立测量 + 噪声带」判定，不依赖单次采样；
详见 §3.2。

### 1.2 集成分支

```sh
git log --oneline -1 origin/main
# 7f29c0f docs(agent): record maintenance loop 37 - no new high-value issues; archive loop 17

git checkout -b hp/devpulse/integration-verify
git merge hp/devpulse/t-0005 hp/devpulse/t-0006 hp/devpulse/t-0007
```

原始输出：

```text
ok hp/devpulse/integration-verify (new)
Fast-forwarding to: hp/devpulse/t-0005
Trying simple merge with hp/devpulse/t-0006
Trying simple merge with hp/devpulse/t-0007
Merge made by the 'octopus' strategy.
 DevPulseNative/Core/RepositoryHistoryStore.swift   | 257 +++++++++++++++------
 DevPulseNative/Core/ScanScheduler.swift            |  68 +-----
 DevPulseNative/Core/SharedSnapshotStore.swift      |  54 ++++-
 .../LifecyclePerformanceTests.swift                | 181 +++++++++++++++
 .../RepositoryHistoryStoreTests.swift              | 135 +++++++++++
 .../SharedSnapshotStoreTests.swift                 |  91 ++++++++
 DevPulseNative/Utilities/DateFormatting.swift      |  23 +-
 docs/incremental-refresh-baseline.md               | 102 ++++++++
 scripts/measure-incremental-refresh.sh             |  97 ++++++++
 9 files changed, 863 insertions(+), 145 deletions(-)
 create mode 100644 docs/incremental-refresh-baseline.md
 create mode 100755 scripts/measure-incremental-refresh.sh
```

**无冲突**。三条线程分支的改动文件几乎不相交（t-0005 只加脚本与文档；t-0006 改
`SharedSnapshotStore` / `DateFormatting` 及其测试；t-0007 改 `RepositoryHistoryStore` /
`ScanScheduler` 及其测试），octopus 合并未触发任何冲突，也没有任何一方语义被改写。

集成分支提交列表（相对 `origin/main`）：

```sh
git log --oneline origin/main..HEAD
# 896e87b Merge branches 'hp/devpulse/t-0005', 'hp/devpulse/t-0006' and 'hp/devpulse/t-0007' into hp/devpulse/integration-verify
# 5cc516f perf: avoid redundant shared snapshot recovery writes
# 676919f perf: eliminate repeated history archive decoding
# 3505e39 docs: add incremental refresh measurement baseline
```

（核验文档本身作为该 merge 的子提交存在，因此不在上面的列表里。集成分支最终为
`origin/main..HEAD` 共 5 个提交：上述 4 个 + 本文件所在的那一个。）

改动范围（相对 `origin/main`，`...` 为 merge-base 语义）：

```sh
git diff origin/main...HEAD --stat
```

```text
 DevPulseNative/Core/RepositoryHistoryStore.swift   | 257 +++++++++++++++------
 DevPulseNative/Core/ScanScheduler.swift            |  68 +-----
 DevPulseNative/Core/SharedSnapshotStore.swift      |  54 ++++-
 .../LifecyclePerformanceTests.swift                | 181 +++++++++++++++
 .../RepositoryHistoryStoreTests.swift              | 135 +++++++++++
 .../SharedSnapshotStoreTests.swift                 |  91 ++++++++
 DevPulseNative/Utilities/DateFormatting.swift      |  23 +-
 docs/incremental-refresh-baseline.md               | 102 ++++++++
 scripts/measure-incremental-refresh.sh             |  97 ++++++++
 9 files changed, 863 insertions(+), 145 deletions(-)
```

### 1.3 独立 DerivedData 与 pristine main 对照

所有构建与测试都使用 **`DERIVED_DATA_PATH=/tmp/devpulse-build-verify`**，与其它线程的共享
路径 `/tmp/devpulse-build` 隔离。

为取得「同一台机器、同一条命令」的 pristine main 对照，核验期间在**仓库之外**建立了一份
只读用途的临时克隆（**未**新增 / 删除 / 移动任何 worktree 或分支，未 push，未合并 main）：

```sh
git clone --local --no-hardlinks --quiet /Users/ryukeili/GitHub/DevPulse /tmp/devpulse-main-baseline
cd /tmp/devpulse-main-baseline && git log --oneline -1
# 7f29c0f docs(agent): record maintenance loop 37 - no new high-value issues; archive loop 17

DERIVED_DATA_PATH=/tmp/devpulse-build-main ./scripts/verify.sh build   # Build succeeded
```

### 1.4 原始日志路径

- 集成分支原始日志（临时路径）：
  - `/tmp/devpulse-verify-results/raw/`
  - `/tmp/devpulse-verify-results/samples.tsv`、`summary.tsv`、`performance-baselines.json`
  - `/tmp/devpulse-verify-results/interleave/samples.tsv`
- pristine main 对照原始日志（临时路径）：`/tmp/devpulse-main-baseline-results/`
- 上述两份已在核验结束时复制到交付库目录，避免 `/tmp` 被清理后无法复核：
  - `library/raw-evidence/integration-verify/`（= `/tmp/devpulse-verify-results/`）
  - `library/raw-evidence/main-baseline-verify/`（= `/tmp/devpulse-main-baseline-results/`）
  - `library/raw-evidence/C-gatecheck.log`（集成版 RegressionGate 无头 harness 输出）
  - `library/raw-evidence/C-gatecheck-maincontrol.log`（pristine main 版同一 harness 输出）
  - `library/raw-evidence/gatecheck-harness-main.swift`（harness 源码，未进入仓库）

被引用的基线文档 `docs/main-test-baseline.md` **不在本分支上**，它位于只读分支
`hp/devpulse/t-0008-main`（`5663297`）。复核方式：

```sh
git show hp/devpulse/t-0008-main:docs/main-test-baseline.md
```

---

## 2. A —— 确定性计数（主证据，全部由本线程重跑复现）

### 2.1 A.1 共享快照 commit 的稳态 I/O

`verify.sh test` 在成功时会删除自身日志，为取得测试内的原始 `print` 行，这里直接运行它内部
完全相同的 `xcodebuild test-without-building`，同一命令重复 3 次：

```sh
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj \
  -scheme DevPulse -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/devpulse-build-verify \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:DevPulseTests/SharedSnapshotStoreTests test-without-building
```

原始输出（3 次独立运行，逐字相同；日志 `raw/A1-snapshot-raw-run{1,2,3}.log`）：

```text
SharedSnapshotStore non-identical recovery operations: writes=3, F_FULLFSYNC=6
SharedSnapshotStore steady-state operations: writes=2, F_FULLFSYNC=4
SharedSnapshotStore non-identical recovery operations: writes=3, F_FULLFSYNC=6
SharedSnapshotStore steady-state operations: writes=2, F_FULLFSYNC=4
SharedSnapshotStore non-identical recovery operations: writes=3, F_FULLFSYNC=6
SharedSnapshotStore steady-state operations: writes=2, F_FULLFSYNC=4
```

测试汇总（3 次均为）：

```text
✔ Test run with 28 tests in 1 suite passed after 5.511 seconds.
```

- 稳定态（primary 与 backup 字节相同）：**writes 3 → 2，F_FULLFSYNC 6 → 4**。
- 非 identical 对照路径：**writes=3，F_FULLFSYNC=6，与改动前完全一致**。

**关键：safeguard 没有被一起省掉。** 该观测来自
`SharedSnapshotStoreTests.nonIdenticalRecoveryCopyRetainsPreCommitSafeguard()`：它先各自
commit 一个内容不同的 `alternate` 快照，然后把 alternate 的 **primary 文件字节**直接拷成
待测 store 的 `backupURL`（于是 `storageRevision` 相同、字节不同），再执行下一次 commit，
最后断言 `writes == 3`、`F_FULLFSYNC == 6`，且 commit 后 `primaryURL` 与 `backupURL` 字节
相等（`#expect(try Data(contentsOf: snapshotStore.primaryURL) == Data(contentsOf: snapshotStore.backupURL))`）。

生产代码的判定顺序（`DevPulseNative/Core/SharedSnapshotStore.swift:505-530`）保证了这一点：

```swift
if let validPrimary {
    if let validBackup {
        if backupIsNewer(primary: validPrimary.snapshot, backup: validBackup.snapshot) {
            return CommitBaseline(snapshot: validBackup.snapshot,
                                  recoveryCopyPlan: .preserveExistingBackup)
        }
        if validBackup.snapshot.storageRevision == validPrimary.snapshot.storageRevision,
           validBackup.bytes == validPrimary.bytes {
            return CommitBaseline(snapshot: validPrimary.snapshot,
                                  recoveryCopyPlan: .preserveIdenticalBackup)
        }
    }
    return CommitBaseline(snapshot: validPrimary.snapshot,
                          recoveryCopyPlan: .publish(validPrimary.bytes))
}
```

即：**只有「revision 相同 **且** 字节相同」**才进入新分支 `.preserveIdenticalBackup`
（`SharedSnapshotStore.swift:855-859` 的 `break`）。`backupIsNewer` 优先于新分支；revision
相同但字节不同仍落入 `.publish(validPrimary.bytes)`，在 primary rename（唯一提交点，
`SharedSnapshotStore.swift:452`）之前把已校验的 primary 字节写回 backup 并 `F_FULLFSYNC`
同步。原保护路径完整保留。

安全性论证（代码级，非推测）：新分支跳过的只是「提交点之前的重复写入」。稳态下
「backup 与 primary 字节相同」这一前提由**上一次 commit 的收尾步骤**建立
（`refreshRecoveryCopyAfterCommit` → `atomicWrite`：写 → `synchronizeFile`(F_FULLFSYNC)
→ `rename` → `synchronizeDirectory`；`SharedSnapshotStore.swift:821-840`、`865-872`），
因此在本轮 rename 之前，盘上已经存在一份 durable、内容等同于当前 primary 的 recovery copy。

### 2.2 A.2 历史归档解码

同一命令重复 3 次：

```sh
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj \
  -scheme DevPulse -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/devpulse-build-verify \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:DevPulseTests/RepositoryHistoryStoreTests test-without-building
```

原始输出（300 条 / 5 仓库 / 30 次迭代微基准，3 次独立运行，逐字抄录自
`raw/A2-history-raw-run{1,2,3}.log`）：

```text
history-load-benchmark entries=300 repositories=5 iterations=30 old_median_ms=11.292459 old_p95_ms=11.350375 old_mad_ms=0.03154199999999996 new_median_ms=2.35 new_p95_ms=2.386125 new_mad_ms=0.004999999999999893 old_decodes=150 new_decodes=30 old_bytes=26088750 new_bytes=5217750
history-load-benchmark entries=300 repositories=5 iterations=30 old_median_ms=11.708542 old_p95_ms=12.059542 old_mad_ms=0.1990009999999991 new_median_ms=2.44825 new_p95_ms=2.591083 new_mad_ms=0.0378750000000001 old_decodes=150 new_decodes=30 old_bytes=26088750 new_bytes=5217750
history-load-benchmark entries=300 repositories=5 iterations=30 old_median_ms=11.407042 old_p95_ms=11.554125 old_mad_ms=0.12187400000000004 new_median_ms=2.384417 new_p95_ms=2.472209 new_mad_ms=0.01795800000000014 old_decodes=150 new_decodes=30 old_bytes=26088750 new_bytes=5217750
```

汇总（3 次一致）：

| 指标 | old（改动前语义） | new（改动后） | 比值 |
| --- | --- | --- | --- |
| median | 11.29 / 11.71 / 11.41 ms | 2.35 / 2.45 / 2.38 ms | ≈ 4.8× |
| p95 | 11.35 / 12.06 / 11.55 ms | 2.39 / 2.59 / 2.47 ms | ≈ 4.7× |
| MAD | 0.032 / 0.199 / 0.122 ms | 0.005 / 0.038 / 0.018 ms | — |
| decodes（30 迭代 × 5 仓库） | 150 | 30 | 5× |
| bytes read | 26 088 750 | 5 217 750 | 5× |

**同轮整档解码次数（目标 ≤ 2）**：由
`RepositoryHistoryStoreTests.refreshHistoryPathsDecodeArchiveAtMostTwice()` 断言并通过：
`recordSnapshotStates(...)` 之后 `archiveDecodeCount == 1`；再调用一次 `loadGrouped()` 之后
`== 2`。该测试在集成分支全量套件中的原始行：

```text
✔ Test refreshHistoryPathsDecodeArchiveAtMostTwice() passed after 0.231 seconds.
```

对照改动前：`ScanScheduler` 的 health assessment 对每个仓库各调用一次
`historyStore.load(for:)`（每次都完整解码整个归档），历史记录路径又先 `load()` 再
`record()`→内部再 `loadUnlocked()`，因此每轮解码次数约为 `仓库数 + 2`（5 仓库时 7 次），
现在恒为 ≤ 2 次。

### 2.3 A.3 可复现性

- 上述两项 **各独立重跑 3 次**（见 2.1 / 2.2 的三行原始输出）。确定性计数（writes /
  F_FULLFSYNC / decodes / bytes）**逐字相同**；wall-clock 中位数抖动远小于新旧差值。
- 测试**内部**另有 30 次迭代并给出 median / p95 / MAD：历史读取 MAD 0.005–0.038 ms 对差值
  ≈ 9 ms；commit 路径 MAD 0.49–2.87 ms 对差值 ≈ 7–10 ms（§3.3）。两者差值都是自身 MAD 的
  3 倍以上，不是单次抖动。
- 这两组新测试在 4 个互相独立的执行上下文中都通过：定向 `SharedSnapshotStoreTests`（3 次）、
  定向 `RepositoryHistoryStoreTests`（3 次）、定向 `LifecyclePerformanceTests`（1 次）、
  全量套件（2 次）。

`RepositoryHistoryStoreTests` 测试汇总（3 次均为）：

```text
✔ Test run with 13 tests in 1 suite passed after 1.061 seconds.
```

---

## 3. B / C —— 扫描器级与基准关卡对比

### 3.1 命令与原始样本

改动后（after）：

```sh
DERIVED_DATA_PATH=/tmp/devpulse-build-verify RUNS=5 \
OUTPUT_DIR=/tmp/devpulse-verify-results \
./scripts/measure-incremental-refresh.sh
```

原始 `samples.tsv`（列：run / incremental_elapsed_ms / incremental_git_calls /
command_max_rss_bytes / command_peak_footprint_bytes）：

```text
1	36	4	183058432	89048048
2	46	4	182894592	89506776
3	38	4	183156736	89555904
4	38	4	182992896	89555928
5	39	4	182878208	89048024
```

原始 `summary.tsv`：

```text
metric	mean	stddev_population	min	max	n
incremental_elapsed_ms	39.400	3.441	36	46	5
incremental_git_calls	4.000	0.000	4	4	5
command_max_rss_bytes	182996172.800	103828.551	182878208	183156736	5
command_peak_footprint_bytes	89342936.000	241452.491	89048024	89555928	5
```

改动前（before）：**不引用 t-0005 文档里的历史数字**，而是在本次核验中于 pristine main 上
重跑。`scripts/measure-incremental-refresh.sh` 本身是 t-0005 新增的脚本（不在 main 上），
因此把它原样拷进临时克隆后以**完全相同的参数**运行（脚本内 `$ROOT_DIR` 解析到克隆根，
`TEST_SPEC` 在 main 上存在）：

```sh
cp <integration>/scripts/measure-incremental-refresh.sh /tmp/devpulse-main-baseline/scripts/
cd /tmp/devpulse-main-baseline
DERIVED_DATA_PATH=/tmp/devpulse-build-main RUNS=5 \
OUTPUT_DIR=/tmp/devpulse-main-baseline-results \
./scripts/measure-incremental-refresh.sh
```

原始输出：

```text
1	43	4	181944320	88261568
2	42	4	181633024	88327128
3	43	4	182321152	88753112
4	42	4	182517760	89179096
5	43	4	182583296	88687576
metric	mean	stddev_population	min	max	n
incremental_elapsed_ms	42.600	0.490	42	43	5
incremental_git_calls	4.000	0.000	4	4	5
command_max_rss_bytes	182199910.400	360388.417	181633024	182583296	5
command_peak_footprint_bytes	88641696.000	330686.432	88261568	89179096	5
```

### 3.2 噪声估计与「是否超出噪声」的结论

因为本机同时有其它负载（§1.1），仅比较两组各 5 次仍不够，于是在**同一会话内交替运行**两侧
（`integration → main → integration → main → integration → main`）以抵消环境漂移。原始输出：

```text
round	tree	incremental_elapsed_ms	incremental_git_calls
1	integration	42	4
1	main	42	4
2	integration	42	4
2	main	38	4
3	integration	36	4
3	main	38	4
```

合并 8 个样本（5 次脚本 + 3 次交替）：

| 组 | n | mean | sd（总体） | median | min | max |
| --- | --- | --- | --- | --- | --- | --- |
| integration（改动后） | 8 | **39.625 ms** | 3.238 | 38.5 | 36 | 46 |
| pristine main（改动前） | 8 | **41.375 ms** | 1.996 | 42.0 | 38 | 43 |

- 均值差 **−1.75 ms（−4.23%）**。
- 噪声带（按 t-0005 文档与 `RegressionGate` 同族口径，取 `2 × 总体标准差`）：main 侧
  `2 × 1.996 = 3.99 ms`；集成侧 `2 × 3.238 = 6.48 ms`。
- `|−1.75 ms| < 3.99 ms` → **落在噪声带内**。

**明确结论：扫描器级 `incremental_elapsed_ms` 未移动（在噪声内）。** 不写成改善。同理：

- `incremental_git_calls` = **4 / 4**，两侧完全一致，无增加。
- `command_max_rss_bytes`：main 182 199 910 ± 360 388，集成 182 996 173 ± 103 829；差 +0.44%，
  小于两侧任一标准差 → **未移动**。
- `command_peak_footprint_bytes`：main 88 641 696 ± 330 686，集成 89 342 936 ± 241 452；
  差 +0.79% → **未移动**。

**为什么扫描器级指标不动（结构性原因，不是「噪声解释」）**：该入口驱动的测试是
`DevPulseNative/DevPulseNativeTests/ScanPerformanceTests.swift:120-176` 的
`unchangedKnownScopeReusesDiscoveryAndCommitMetadata()`，它**直接调用
`GitRepositoryScanner.scan(...)`**，不经过 `ScanScheduler`、`RepositoryHistoryStore` 或
`SharedSnapshotStore`：

```swift
let first = await GitRepositoryScanner.scan(
    config: scanConfig(maxConcurrentGitOps: 3), scanRoots: [root.path],
    forceRepositoryDiscovery: true, previousSnapshot: .empty(), metrics: firstMetrics)
...
let second = await GitRepositoryScanner.scan(
    config: scanConfig(maxConcurrentGitOps: 3), scanRoots: [root.path],
    knownRepositoryPaths: first.discoveredRepositoryPaths,
    previousSnapshot: first.data, metrics: secondMetrics)
```

改动清单里没有任何文件落在 `GitRepositoryScanner.swift`。因此 B 指标**结构上不可能**反映
C1/C2/C3，它在这条路径上是「未移动」而非「有改善」——与实测一致。

**改动落在哪个阶段**：C1/C3 落在「扫描完成后的持久化阶段」——`SharedSnapshotStore.commit`
（每轮刷新会发生 2–3 次 commit）；C2 落在「扫描完成后的健康评估与历史归档阶段」——
`ScanScheduler` 的健康评估循环与历史记录后台任务。这两个阶段**不在** B 的测量范围内，其
指标由 **A**（确定性计数）与 §3.3（commit 基准）给出，并且确实改善。

### 3.3 SharedSnapshotStore commit 基准（仓库既有基准类内）

该基准由 t-0006 加在 `DevPulseNative/DevPulseNativeTests/LifecyclePerformanceTests.swift`
（`@Test("SharedSnapshotStore steady-state commit benchmark")`），属于**既有**基准类
`LifecyclePerformanceTests`。运行命令：

```sh
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj \
  -scheme DevPulse -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/devpulse-build-verify \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:DevPulseTests/LifecyclePerformanceTests test-without-building
```

三次互相独立执行（1 次定向 + 2 次全量套件）的原始 `print` 行：

```text
# 定向 LifecyclePerformanceTests（退出码 0，9 tests / 1 suite / 0 issues）
SharedSnapshotStore benchmark repositories=5  iterations=30 baseline_median_ms=39.513 baseline_p95_ms=41.482 baseline_mad_ms=1.051 optimized_median_ms=29.866 optimized_p95_ms=34.042 optimized_mad_ms=1.160
SharedSnapshotStore benchmark repositories=50 iterations=30 baseline_median_ms=78.567 baseline_p95_ms=84.562 baseline_mad_ms=2.207 optimized_median_ms=70.020 optimized_p95_ms=75.009 optimized_mad_ms=0.997

# 全量套件第 1 次
SharedSnapshotStore benchmark repositories=5  iterations=30 baseline_median_ms=36.577 baseline_p95_ms=41.478 baseline_mad_ms=1.956 optimized_median_ms=29.006 optimized_p95_ms=30.360 optimized_mad_ms=0.490
SharedSnapshotStore benchmark repositories=50 iterations=30 baseline_median_ms=78.673 baseline_p95_ms=87.542 baseline_mad_ms=2.866 optimized_median_ms=69.982 optimized_p95_ms=71.011 optimized_mad_ms=0.940

# 全量套件第 2 次（verify.sh final 保留下来的原始日志）
SharedSnapshotStore benchmark repositories=5  iterations=30 baseline_median_ms=39.420 baseline_p95_ms=42.562 baseline_mad_ms=1.010 optimized_median_ms=29.033 optimized_p95_ms=32.001 optimized_mad_ms=0.966
SharedSnapshotStore benchmark repositories=50 iterations=30 baseline_median_ms=79.644 baseline_p95_ms=83.628 baseline_mad_ms=1.179 optimized_median_ms=73.054 optimized_p95_ms=75.073 optimized_mad_ms=0.973
```

| 仓库数 | baseline median（3 次） | optimized median（3 次） | 差值 | baseline MAD（3 次） |
| --- | --- | --- | --- | --- |
| 5 | 39.51 / 36.58 / 39.42 ms | 29.87 / 29.01 / 29.03 ms | −9.6 / −7.6 / −10.4 ms | 1.05 / 1.96 / 1.01 ms |
| 50 | 78.57 / 78.67 / 79.64 ms | 70.02 / 69.98 / 73.05 ms | −8.5 / −8.7 / −6.6 ms | 2.21 / 2.87 / 1.18 ms |

差值约为自身 MAD 的 4–10 倍（5 仓库）与 3–7 倍（50 仓库）→ **超出噪声**。测试内部亦断言
`optimizedSummary.median < baselineSummary.median - baselineSummary.mad`，三次均通过。

范围界定（避免误读）：该基准的 `baseline` 是**测试进程内构造的 A/B 对照**（同一 payload、
同一 store 配置，唯一差别是强制 backup 与 primary 不同字节以复现旧的「pre-commit 再写一遍
recovery copy」行为），不是 `PerformanceBaselineManager` 里持久化的线上基线。它的价值在于
**确定性、可复现地量化 C1 省掉的那一步写入**，不代表完整 App UI 刷新时延。

### 3.4 C —— RegressionGate 逐项结果

`DevPulseNative/Core/RegressionGate.swift` 的检查项大多是 `internal`，没有 CLI 入口；
`RegressionGate` 在生产代码中**没有任何调用点**（`rg -n "RegressionGate\."` 只命中测试与
`project.pbxproj`）。核验分三路：

**(a) 通过测试目标运行（仓库既有入口）**

```sh
DERIVED_DATA_PATH=/tmp/devpulse-build-verify ./scripts/verify.sh test DevPulseTests/ReliabilityLabTests        # 退出码 0
DERIVED_DATA_PATH=/tmp/devpulse-build-verify ./scripts/verify.sh test DevPulseTests/LifecyclePerformanceTests  # 退出码 0
```

```text
✔ Test run with 9 tests in 1 suite passed after 13.626 seconds.   # LifecyclePerformanceTests
```

`ReliabilityLabTests` 覆盖的 gate 及引用位置：`checkNoZombieGitProcesses()`
（`ReliabilityLabTests.swift:234,502`）、`checkNoInfiniteRetries(result:)`（`:262`）、
`checkNoMainThreadStall()`（`:506`）、`checkNoTaskLeak(before:after:)`（`:514`）、
`checkNoDuplicateSnapshotWrite(store:)`（`:544`）。定向运行退出码 `0`（日志
`raw/C-reliability-lab.log`）。

**(b) 独立无头 harness（用仓库自己的实现，未改仓库）**

由于 `checkNoResourceGrowth` / `checkAll` 是 `internal`，核验时把 `DevPulseNative/Core/*.swift`
与 `DevPulseNative/Utilities/*.swift` 拷到仓库外的临时目录，与调用 harness 一起编成**同一个
模块**的可执行文件，从而直接调用仓库自己的实现（harness 源码：
`library/raw-evidence/gatecheck-harness-main.swift`）：

```sh
swiftc -swift-version 6 -O -o /tmp/gatecheck/gatecheck src/*.swift main.swift && /tmp/gatecheck/gatecheck
```

用 **t-0005 产出的 `performance-baselines.json`** 作为 baseline，原始输出：

```text
== load t-0005 performance-baselines.json artifacts
main baseline collection: ["incrementalRefresh": "0.0426s/stddev=0.00049/n=5"]
integration baseline collection: ["incrementalRefresh": "0.0394s/stddev=0.003441/n=5"]
observed main mean=0.041375s integration mean=0.039625s
== RegressionGate.checkNoResourceGrowth using the t-0005 baseline artifact as the baseline
checkNoResourceGrowth[integration-observed-vs-main-baseline] isRegression=false exceedsBudget=false deltaPercent=-6.98 evidence=["observed: 0.040", "baseline: 0.043", "threshold: 0.009", "delta: -7.0%"]
checkNoResourceGrowth[integration-observed-vs-integration-baseline] isRegression=false exceedsBudget=false deltaPercent=0.57 evidence=["observed: 0.040", "baseline: 0.039", "threshold: 0.008", "delta: 0.6%"]
checkNoResourceGrowth[main-observed-vs-integration-baseline] isRegression=false exceedsBudget=false deltaPercent=5.01 evidence=["observed: 0.041", "baseline: 0.039", "threshold: 0.008", "delta: 5.0%"]
== PerformanceBaselineManager.checkRegression (public) using the t-0005 baseline artifact
checkRegression[integration-observed] isRegression=false exceedsBudget=false deltaPercent=0.57 evidence=["observed: 0.040", "baseline: 0.039", "threshold: 0.008", "delta: 0.6%"]
checkRegression[main-observed] isRegression=false exceedsBudget=false deltaPercent=5.01 evidence=["observed: 0.041", "baseline: 0.039", "threshold: 0.008", "delta: 5.0%"]
checkRegression[control-plus-30pct] isRegression=true exceedsBudget=false deltaPercent=30.00 evidence=["observed: 0.051", "baseline: 0.039", "threshold: 0.008", "delta: 30.0%"]
== RegressionGate.checkNoZombieGitProcesses() and checkNoMainThreadStall()
checkNoZombieGitProcesses=true
checkNoMainThreadStall=Optional(0.05259491666604299)
== RegressionGate.checkAll with no refresh result / store / tasks
checkAll findings count=1 :: ["gate-main-stall:isRegression=true"]
```

三点必须同时看：

1. `checkNoResourceGrowth` 在三种比较下都是 `isRegression=false` → **无回归**。
2. 正向对照 `control-plus-30pct`（观测值人为抬高 30%）返回 `isRegression=true`，说明该 gate
   在这套数字下**确实能触发**，`false` 不是恒定假阴性。
3. `checkNoMainThreadStall()` 报出 `~0.0526 s` 停滞，**这是 harness 假象**，不是产品回归：
   该检查从主线程 `DispatchQueue.main.async` 后立刻用 semaphore 阻塞 50 ms，而命令行可执行
   文件没有为 main queue 提供服务的机会，必然吃满超时。**对照实验**：用 pristine main 的同一
   批源码编译同一个 harness，输出**逐字相同**（`checkNoMainThreadStall=Optional(0.054093416667659766)`、
   `checkAll findings count=1 :: ["gate-main-stall:isRegression=true"]`，见
   `library/raw-evidence/C-gatecheck-maincontrol.log`）→ 改动前后一致，属工具假象。

**(c) t-0006 声称的「benchmark 内断言过 `checkNoResourceGrowth == false`」独立复现**

- 测试侧：`LifecyclePerformanceTests.steadyStateCommitBenchmark()` 内的
  `#expect(regression?.isRegression == false)` 在定向运行与 2 次全量套件中均通过
  （`✔ Test "SharedSnapshotStore steady-state commit benchmark" passed after 13.335 seconds.`）。
- 独立计算侧：上面的 harness 用 §3.3 打印出的同一组 median/MAD 数字，走仓库自己的
  `RegressionGate.checkNoResourceGrowth` 复算出 `isRegression=false`。手算核对（与 gate 内公式
  `threshold = max(mean*0.2, stddev*2)`、`isRegression = delta > threshold` 一致）：
  - 5 仓库：mean=0.039513、stddev=0.001051 → threshold=0.0079026；
    delta=0.029866−0.039513=−0.009647 → `false`。
  - 50 仓库：mean=0.078567、stddev=0.002207 → threshold=0.0157134；
    delta=0.070020−0.078567=−0.008547 → `false`。

**结论（C）**：能无头运行的 gate 全部无回退。**但必须指出该断言的强度有限**：当 optimized
小于 baseline 时 `delta < 0 < threshold`，`isRegression` 必然为 `false` —— 它只能捕获「优化
把 commit 变慢了」这一种反向情形，不能作为「不退化」的强证明。真正的不回退证据来自 §4 的
全量测试比对与 §5 的语义不变性核查。

**不能运行的 gate 及原因**：

| Gate | 状态 | 原因 |
| --- | --- | --- |
| `checkNoInfiniteRetries(result:)` | 仅测试内运行 | 需要 `RefreshResult`，无 CLI/无头生产入口；`ReliabilityLabTests` 内已通过 |
| `checkNoDuplicateSnapshotWrite(store:)` | 仅测试内运行 | 需要 `RefreshObservationStore`，同上 |
| `checkNoTaskLeak(before:after:)` | 仅测试内运行 | 需要调用方提供 before/after task 集合，同上 |
| `checkAll(...)` 的 result/store/tasks 分支 | **本次未运行** | 同上；harness 只跑了不需要 `RefreshResult` / `RefreshObservationStore` 的分支 |
| `PerformanceBaseline.checkRegression` 的 `budget` 分支 | **本次未运行** | 无生产调用点提供 per-stage budget |
| `continuousManualRefresh` 场景 | **无法判定** | `BenchmarkSuite.swift` 定义了该 scenario，但仓库内**没有**任何生产调用点或测试入口驱动它（t-0005 文档亦如此记录）。没有可运行入口就没有可比数字 |

---

## 4. D —— 全量验证与既有失败比对

### 4.1 官方入口

```sh
DERIVED_DATA_PATH=/tmp/devpulse-build-verify ./scripts/verify.sh final
```

（原始输出 `raw/D-verify-final.log`；失败时 `verify.sh` 保留的完整日志另存为
`raw/D-verify-final-full.log`。）

```text
[verify] Building for testing (shared DerivedData: /tmp/devpulse-build-verify)…
[verify] Build succeeded
[verify] Running full test suite
✘ Test run with 899 tests in 89 suites failed after 58.497 seconds with 5 issues.
[verify] ERROR: full test suite failed — full log preserved: /var/folders/.../devpulse-test.c9mtq5
```

- **退出码：`1`**。构建成功，失败只来自测试断言。
- 汇总：**899 tests / 89 suites / 5 issues**（本次 `SleepWakeLifecycleTests` 恰好通过）。
- 另一次等价的裸 `xcodebuild` 全量运行（`raw/D-fullsuite-integration.log`）为
  **899 tests / 89 suites / 6 issues**（`SleepWakeLifecycleTests` 失败）。同一改动、同一机器、
  同一套件两次相差 1 个 issue，与基线文档记录的 flaky 行为一致。

### 4.2 pristine main 对照（本次核验内重跑，不引用历史数字）

```sh
cd /tmp/devpulse-main-baseline
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/devpulse-build-main \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test-without-building
```

```text
✘ Test run with 893 tests in 89 suites failed after 45.250 seconds with 6 issues.
```

- **退出码：`65`**（等价于 `verify.sh final` 的退出码 `1`，两者都是测试断言失败）。
- 增量差异：**899 − 893 = 6 个测试**，与新增测试数完全对应：`SharedSnapshotStoreTests`
  26→28（+2）、`RepositoryHistoryStoreTests` 10→13（+3）、`LifecyclePerformanceTests`
  8→9（+1），合计 +6。套件数不变（89）。
- 新增的 6 个测试全部通过（全量日志原始行）：

```text
✔ Test "SharedSnapshotStore steady-state commit benchmark" passed after 13.335 seconds.
✔ Test nonIdenticalRecoveryCopyRetainsPreCommitSafeguard() passed after 0.078 seconds.
✔ Test identicalRecoveryCopyAvoidsRedundantPreCommitWriteAndSync() passed after 0.052 seconds.
✔ Test groupedLoadPreservesPerRepositoryDescendingOrder() passed after 0.235 seconds.
✔ Test refreshHistoryPathsDecodeArchiveAtMostTwice() passed after 0.231 seconds.
✔ Test groupedLoadBenchmark300EntriesFiveRepositories() passed after 0.660 seconds.
```

### 4.3 逐项比对（测试名 + 原始断言文本）

| # | 失败测试 | integration 原始断言文本（本次） | main 原始断言文本（本次重跑） | 判定 |
| --- | --- | --- | --- | --- |
| 1 | `SleepWakeLifecycleTests.suspendForSleepCancelsActiveScan()` | `✘ Test "suspendForSleep cancels active scan task" recorded an issue at LifecycleSleepWakeTests.swift:199:9: Expectation failed: scheduler.isScanning == false` / `↳ Scan should be cancelled after sleep` / `↳ scheduler.isScanning == false → false` / `↳   scheduler.isScanning → true` | 逐字相同 | **main 既有（flaky）**：本次全量第 1 次失败、第 2 次（`verify.sh final`）通过 |
| 2 | `RefreshCompletionTests.initialStateIsIdle()` | `✘ Test "Refresh state is idle after initialization" recorded an issue at RefreshCompletionTests.swift:72:9: Expectation failed: await scheduler.refreshPhase == .idle` / `↳ await scheduler.refreshPhase == .idle → <not evaluated>` | 逐字相同 | **main 既有（稳定）**：两次全量均失败 |
| 3 | `RepositoryDiscoveryExperienceTests.schedulerRebuildMigratesLegacyPinsAndSharedSnapshotIdentity()` | `... at RepositoryDiscoveryExperienceTests.swift:139:28: Expectation failed: scheduler.lastResult.repositories.first` / `↳ scheduler.lastResult.repositories.first → nil` / `↳   scheduler.lastResult.repositories → []` / `↳   first → nil` | 逐字相同 | **main 既有（稳定）** |
| 4 | `...schedulerRebuildMigratesIgnoredPathsAndRewritesSharedSnapshotScope()` | `... at RepositoryDiscoveryExperienceTests.swift:227:29: Expectation failed: try? AppGroupStore.read().get()` / `↳ try? AppGroupStore.read().get() → nil` | 逐字相同 | **main 既有（稳定）** |
| 5 | `...ignoringRepositoryImmediatelyFiltersAppAndSharedWidgetSnapshotAndForcesScopedScan()` | `... at RepositoryDiscoveryExperienceTests.swift:351:26: Expectation failed: try? AppGroupStore.read().get()` / `↳ try? AppGroupStore.read().get() → nil` | 逐字相同 | **main 既有（稳定）** |
| 6 | `...repositoryRetryAfterBackupRecoveryCommitsAWidgetReadableSnapshot()` | `... at RepositoryDiscoveryExperienceTests.swift:921:29: Expectation failed: await waitForSnapshotWrite()` / `↳ await waitForSnapshotWrite() → nil` | 逐字相同 | **main 既有（稳定）** |

两侧 `Failing tests:` 清单（本次核验重跑所得）完全一致：

```text
Failing tests:
	SleepWakeLifecycleTests.suspendForSleepCancelsActiveScan()
	RefreshCompletionTests.initialStateIsIdle()
	RepositoryDiscoveryExperienceTests.schedulerRebuildMigratesLegacyPinsAndSharedSnapshotIdentity()
	RepositoryDiscoveryExperienceTests.schedulerRebuildMigratesIgnoredPathsAndRewritesSharedSnapshotScope()
	RepositoryDiscoveryExperienceTests.ignoringRepositoryImmediatelyFiltersAppAndSharedWidgetSnapshotAndForcesScopedScan()
	RepositoryDiscoveryExperienceTests.repositoryRetryAfterBackupRecoveryCommitsAWidgetReadableSnapshot()
```

- **没有任何不在基线清单内的失败。**
- **没有任何「测试名相同但断言文本已改变」的项**：文件:行号、表达式、展开值全部逐字一致，
  仅耗时不同（例如 flaky 项 `failed after 0.102`（集成）vs `0.103`（main 基线文档））。
- 与 `docs/main-test-baseline.md`（分支 `hp/devpulse/t-0008-main`，commit `5663297`）记录的
  「稳定失败 5 项 + flaky 1 项」逐项吻合；本次 pristine main 重跑亦为「893 / 89 / 6 issues」，
  与该文档一致。
- 该文档记录的成因线索（测试进程内 `group.local.devpulse` 容器权限错误）在本次运行中同样
  出现，示例原始行：

```text
[PendingItemStore] pending items read failed: The file “pending-items.json” couldn’t be opened because you don’t have permission to view it.
[PendingItemStore] failed to replace corrupt pending items file: 待处理事项写入失败：staging: You don’t have permission to save the file “.pending-items.tmp-…” in the folder “group.local.devpulse”.
```

### 4.4 其它既有验证入口

```sh
DERIVED_DATA_PATH=/tmp/devpulse-build-verify ./scripts/verify.sh widgetkit   # 退出码 0
./scripts/verify-activity-timeline.sh                                        # 退出码 0
```

```text
PASS: widget entitlements include the shared App Group
PASS: project embeds the widget extension
PASS: project declares the widget target dependency
PASS: project sets the app bundle identifier
PASS: project sets the widget bundle identifier
PASS: project passes the app bundle id to the widget
PASS: app 与 widget target 均已启用 App Groups
WidgetKit verification passed: 16 PASS, 0 FAIL
Activity timeline verification passed
```

`./scripts/install-and-self-check.sh`（签名安装 + 运行时自检）**本次未运行**：它需要本机签名
身份，并会把真实 App bundle 安装到系统位置，超出本核验线程「只读核验 + 仅新增一个文档」的
边界。因此 `--self-check` 的 `scan_git_calls` 等运行时计数未被本次独立复现——这条路径的结论
由 §5 的静态证据（无新增 spawn、调用次数不变）与 §3.1 的 `incremental_git_calls` 支撑。

---

## 5. E —— 边界与旁路写入核查（对应标准 1 后半句）

### 5.1 集成分支相对 main 的全部改动

```sh
git log --oneline origin/main..HEAD     # 见 §1.2（3 个 commit + 1 个 merge commit）
git diff origin/main...HEAD --stat      # 见 §1.2
git diff origin/main...HEAD --name-only
```

```text
DevPulseNative/Core/RepositoryHistoryStore.swift
DevPulseNative/Core/ScanScheduler.swift
DevPulseNative/Core/SharedSnapshotStore.swift
DevPulseNative/DevPulseNativeTests/LifecyclePerformanceTests.swift
DevPulseNative/DevPulseNativeTests/RepositoryHistoryStoreTests.swift
DevPulseNative/DevPulseNativeTests/SharedSnapshotStoreTests.swift
DevPulseNative/Utilities/DateFormatting.swift
docs/incremental-refresh-baseline.md
scripts/measure-incremental-refresh.sh
```

**生产代码只改了 4 个文件**，其中 1 个是纯工具（`DateFormatting`）。以下目录 / 文件均
**未改动**：

```sh
git diff origin/main...HEAD --name-only -- DevPulseNative/Widget DevPulseNative/App
git diff origin/main...HEAD --name-only -- DevPulseNative/Core/AppGroupStore.swift \
  DevPulseNative/Core/Models.swift DevPulseNative/Core/RefreshEngine.swift \
  DevPulseNative/Core/PendingItemWidgetSummary.swift
# 两次输出均为空
```

### 5.2 是否引入对共享快照 / App Group 的新写入路径

对**全部新增的生产代码行**做关键字扫描（Core + Utilities，257 行新增）：

```sh
git diff origin/main...HEAD -U0 -- DevPulseNative/Core DevPulseNative/Utilities \
  | rg '^\+' | rg -v '^\+\+\+' \
  | rg -i 'Process\(|ProcessRunner|git |commit\(|\.write\(|AppGroupStore|writeJSON|removeItem|createDirectory'
# 无输出（退出码 1）
```

对全量 diff 的新增行做同样扫描，**只命中测试文件里本来就在用的 `store.commit(...)` /
`Data.write(to:)`**（`SharedSnapshotStoreTests.swift`、`LifecyclePerformanceTests.swift`），
以及 `scripts/measure-incremental-refresh.sh` 里生成 JSON 的 `printf` 字符串 —— **没有任何
新增的生产写入调用点**。

`SharedSnapshotStore` 的写入相关改动只有两类，都不新增写入：

1. 插入 `operationObserver?(.fileWrite)` / `?(.fullFileSync)` / `?(.fullDirectorySync)` 三个
   **纯观测回调**（`SharedSnapshotStore.swift:411, 827, 933, 957`）。默认 `nil`；生产代码与
   所有既有调用点都不传该参数。
2. **减少**一次稳定态写入（`.preserveIdenticalBackup` 的 `break`），见 §2.1。

`RepositoryHistoryStore` 的新增 API（`recordSnapshotStates`、`loadGrouped`、`loadMetrics`）
**全部只读或复用既有 `saveUnlocked`**；没有新开文件、没有新目录、没有绕过 `saveUnlocked` 的
原子写路径。

生产侧历史存储调用方清单：

```sh
rg -n 'historyStore\.(load|loadGrouped|record|recordSnapshotStates|recordState|count|compact|diagnosticsSnapshot)' \
   DevPulseNative/App DevPulseNative/Core DevPulseNative/Widget
```

```text
DevPulseNative/App/RepositoryHealthView.swift:392:  let loadResult = historyStore.load(for: repositoryID)
DevPulseNative/Core/ScanScheduler.swift:723:        switch historyStore.load(for: repositoryID) {
DevPulseNative/Core/ScanScheduler.swift:934:        switch historyStore.loadGrouped() {
DevPulseNative/Core/ScanScheduler.swift:2912:            switch historyStore.recordSnapshotStates(...)
```

写入仍全部经 `historyStore` 自身的 `saveUnlocked`（`RepositoryHistoryStore.swift:525-563`），
没有旁路。

`recordSnapshotStates` 在无条目可写时**提前返回且不写盘**（`RepositoryHistoryStore.swift:129-131,
141-143`），与改动前 `guard !historyEntries.isEmpty else { return }` 一致；`.failure` 分支保持
原有的「分类用空 previous state，然后让 read-merge-write 再做一次 recovery 尝试」语义
（`RepositoryHistoryStore.swift:131-141`），与 main 上
`load 失败 → previousStates=[:] → record()→loadUnlocked()` 的两步行为等价。

`recordUnlocked`（`RepositoryHistoryStore.swift:454-523`）的去重 / 合并 / 压缩 / 诊断计数逻辑
与 main 的 `record()`（`git show origin/main:DevPulseNative/Core/RepositoryHistoryStore.swift`
第 100-190 行）逐句对应；唯一被移除的是一个只做自增、从未被读取的局部变量 `dedupSkipped`
（有效计数 `skipped` 的计算方式未变）。

### 5.3 `isRefreshing` 语义 / Widget 消费契约 / App Group schema

```sh
git diff origin/main...HEAD -U0 | rg -n 'isRefreshing'
# 无匹配
```

- `isRefreshing`：diff 中**零命中**；`AppGroupData`、`Models.swift`、`Widget/` 都不在改动
  清单内。相关既有行为测试在集成分支全量套件中全部通过（原始行）：

```text
✔ Test "AppGroupData with isRefreshing true round-trips through Codable" passed after 0.001 seconds.
✔ Test "AppGroupData without isRefreshing decodes as nil" passed after 0.001 seconds.
✔ Test "with* methods preserve isRefreshing" passed after 0.001 seconds.
✔ Test "isRefreshing snapshot does not interfere with storage revision guarding" passed after 0.069 seconds.
✔ Test "stale isRefreshing write is rejected by cross-process guard" passed after 0.046 seconds.
✔ Test "Snapshot without isRefreshing is not stuck in refreshing state" passed after 0.001 seconds.
✔ Test "builder returns refreshing when isRefreshing is true" passed after 0.001 seconds.
```

- Widget 消费契约：`Widget/` 目录零改动；widget 相关测试全部通过：

```text
✔ Test "widget placeholder entry maps to refreshing" passed after 0.001 seconds.
✔ Test "widget no-snapshot entry maps to failed" passed after 0.001 seconds.
✔ Test "widget load-failed entry maps to failed" passed after 0.001 seconds.
✔ Test "widget refreshing flag takes priority over snapshot content" passed after 0.001 seconds.
✔ Test "widget fresh snapshot maps to normal" passed after 0.001 seconds.
✔ Test "widget stale snapshot maps to stale" passed after 0.001 seconds.
✔ Test "widget expired snapshot maps to stale" passed after 0.001 seconds.
✔ Test "widget degraded snapshot maps to degraded even when time looks fresh" passed after 0.001 seconds.
```

- schema：`RepositorySnapshotSchema.version = 3`、`oldestMigratableVersion = 1`、
  `RepositoryHistorySchema.version = 1` 与 main 完全一致（`Models.swift` 不在改动清单）。
  新增的 `recordUnlocked` 写盘时用的仍是 `RepositoryHistorySchema.version`
  （`RepositoryHistoryStore.swift:279-280`），与 main 的 `record()` 一致。相关测试通过：

```text
✔ Test "Schema versions are consistent across RepositorySnapshotSchema and UnifiedLifecycleSchema" passed after 0.001 seconds.
✔ Test "Schema version is consistent across RepositorySnapshotSchema and AppGroupData" passed after 0.001 seconds.
✔ Test "SharedSnapshotStore and Widget use the same schema constant" passed after 0.001 seconds.
✔ Test "SharedSnapshotLocation constants match between app and widget paths" passed after 0.001 seconds.
```

- 共享快照 / CAS 语义：跨进程 revision 守卫的既有测试全部通过，均未退化：

```text
✔ Test "commit succeeds when observedStorageRevision matches on-disk revision" passed after 0.074 seconds.
✔ Test "commit fails with crossProcessWriteDetected when on-disk revision advanced" passed after 0.057 seconds.
✔ Test "commit with observedStorageRevision succeeds after re-reading current revision" passed after 0.081 seconds.
✔ Test "commit without observedStorageRevision bypasses cross-process check" passed after 0.070 seconds.
✔ Test "cross-process write conflict leaves on-disk snapshot intact and not overwritten" passed after 0.059 seconds.
✔ Test "AppGroupStore.write with observedStorageRevision rejects stale writes" passed after 0.055 seconds.
✔ Test "AppGroupStore.write without observedStorageRevision bypasses check" passed after 0.020 seconds.
✔ Test "validateCrossProcess returns .stale when snapshot revision advanced past observed" passed after 0.001 seconds.
✔ Test "VersionedSnapshotProtocol rejects future storage format version" passed after 0.001 seconds.
```

### 5.4 Git 子进程调用次数没有增加

- 扫描器级计数（§3.1）：`incremental_git_calls` = **4**（集成）vs **4**（pristine main），5 次
  运行的总体标准差均为 0.000，完全一致。
- 静态核查：新增的生产代码行中**没有任何** `Process(`、`ProcessRunner`、`GitRepositoryScanner`
  调用或 `"git"` 字样（§5.2 的 `rg` 无输出）。`GitRepositoryScanner.swift`、
  `GitStatusParser.swift`、`GitCommitLogParser.swift`、`ProcessRunner.swift` 都不在改动清单内。
- 唯一被改动的存储访问形态不产生进程：`ScanScheduler` 把「每仓库一次
  `historyStore.load(for:)`」换成「一次 `historyStore.loadGrouped()`」。

### 5.5 未新增的其它边界

- 未新增网络 / 云 / 遥测调用（改动清单里没有 `URLSession`、`Network`、域名等；新增代码只做
  JSON 编解码、字典聚合与文件 I/O 观测）。
- 未新增文件内容读取：`RepositoryHistoryStore` 读的仍是既有的 `repository-history.json`；
  `SharedSnapshotStore` 读的仍是既有 primary/backup。
- 未改动 bundle id、entitlements、签名、部署目标、`project.yml`、`.xcodeproj`（改动清单不含
  这些文件；`verify.sh widgetkit` 16 PASS / 0 FAIL 亦证实 wiring 未变）。

---

## 6. 标准 5 —— 「只消除重复工作，定位到最高实际开销」的文件 / 符号级证据

改动只包含三类，每一类都指向**同一份数据在一轮刷新中被重复处理的既定事实**（「消除重复
工作」），并附真实耗时量级，而不是凭猜测的重构：

| 改动 | 被消除的重复工作 | 文件:符号证据 | 真实开销量级 |
| --- | --- | --- | --- |
| C1（t-0006）`SharedSnapshotStore` 新增 `.preserveIdenticalBackup` | 稳态下 recovery copy 被**写两遍**：上一轮 commit 已把同样的字节写完并 `F_FULLFSYNC` 过，本轮提交点前又整文件重写 + 重同步一次 | `SharedSnapshotStore.swift:505-530`（判定）、`:842-863`（`prepareRecoveryCopy`）、`:865-872`（`refreshRecoveryCopyAfterCommit`） | 每次 commit **−1 次整文件写、−2 次 `F_FULLFSYNC`**；commit 中位数 39.5 → 29.9 ms（5 仓库）、78.6 → 70.0 ms（50 仓库）；每轮刷新发生 2–3 次 commit |
| C2（t-0007）`RepositoryHistoryStore.recordSnapshotStates` + `loadGrouped`，`ScanScheduler` 改用 | ① health assessment 对**每个仓库**各整档解码一次（仓库数 次）；② 历史记录路径先 `load()` 再 `record()`→内部 `loadUnlocked()`，**同一轮解码两次** | 旧代码：`ScanScheduler.swift:2911`（`historyStore.load()`）+ `:2954`（`historyStore.record(...)` → 内部再次 `loadUnlocked()`）；`:931-940`（per-repo `load(for:)` 循环）。新代码：`RepositoryHistoryStore.swift:113-143`（一次解码完成分类 + read-merge-write）、`:208-220`（`loadGrouped` 一次解码）、`ScanScheduler.swift:934, 2912` | 同轮整档解码 **5 → 1**（5 仓库；含另一次读取为 ≤2）；300 条历史 × 30 次迭代：解码 150 → 30、字节 26.1 MB → 5.2 MB、median 11.4 → 2.4 ms |
| C3（t-0006）`DateFormatting.TimestampParser` | 校验每个仓库时间戳时**反复新建** `ISO8601DateFormatter` | `DateFormatting.swift:4-20`；使用点 `SharedSnapshotStore.swift:689-704`（`validateRepositoryPayload` 内复用同一 parser） | 纯分配开销削减；与 C1 同属 commit 路径，**未单独量化**（不夸大） |

**落点自洽性**：三者都落在「扫描完成之后」的持久化 / 归档阶段，而 §3.1 的扫描器级基线只
覆盖 `GitRepositoryScanner.scan` 本身。因此「扫描器指标不变 + 持久化阶段指标改善」这一组合与
改动的落点自洽。

`DateFormatting.date(from:)` 的语义未变：改动前是
`formatter(fractional).date(...) ?? ISO8601DateFormatter().date(...)`，改动后是
`TimestampParser()` 内的两个同配置 formatter，只是把「每次新建两个 formatter」换成「一次操作
内复用同一对 formatter」。

**剩余未消除的重复**（如实记录；既不是回退，也不在本次目标范围内）：

- `ScanScheduler.swift:723`（`healthAssessment(for:repositoryName:)`）与
  `App/RepositoryHealthView.swift:392` 仍是「按单个仓库整档解码」。前者是单仓库 UI 辅助方法，
  后者是视图按需查询，都**不在增量刷新的每轮循环里**，因此本次没有一并改造。
- `RepositoryHistoryStore.record(entries:)` 在改动后**已无生产调用点**（仅测试使用），见 §5.2
  的调用方清单。这是保留旧 API 的冗余，不影响行为。
- `BenchmarkSuite.BenchmarkScenario.continuousManualRefresh` 仍无生产 / 测试入口（§3.4 末表），
  因此没有对应的可复现性能证据。

---

## 7. 与线程报告的比对 / 不一致之处

| 线程报告 | 本次独立核验结果 | 一致？ |
| --- | --- | --- |
| t-0006：稳态 commit 省掉一次冗余 recovery copy 写 | 原始行 `writes=2, F_FULLFSYNC=4`（改动前语义为 3 / 6），3 次重跑逐字一致 | 一致 |
| t-0006：benchmark 内断言 `checkNoResourceGrowth == false` | 定向与 2 次全量的 `✔ Test "SharedSnapshotStore steady-state commit benchmark" passed`；另以仓库自身实现独立复算亦为 `false`，正向对照 +30% 为 `true` | 一致 |
| t-0006：non-identical 路径保持原样 | `writes=3, F_FULLFSYNC=6`，且 commit 后 primary 与 backup 字节相等 | 一致 |
| t-0007：同轮整档解码次数 ≤ 2 | `refreshHistoryPathsDecodeArchiveAtMostTwice()` 断言 1 / 2 并通过；旧语义为 5 仓库时 7 次 | 一致 |
| t-0007：300 条 / 5 仓库微基准 old/new 对比 | old median 11.29 / 11.71 / 11.41 ms → new 2.35 / 2.45 / 2.38 ms | 一致 |
| t-0005：`incremental_elapsed_ms` 均值 40.8 ms、标准差 6.4 ms、`incremental_git_calls` 4 | 本次 pristine main 重跑为 42.600 / 0.490 / 4；交替 8 样本合并后 main 41.375、集成 39.625、git_calls 4 | **部分一致**：均值差 1.8 ms（< 1 个标准差），属同机不同负载下的正常波动；`incremental_git_calls` 完全一致 |
| （隐含读法）「增量刷新变快了」 | 扫描器级 `incremental_elapsed_ms` **未移动**（差 1.75 ms < 2×sd 3.99 ms）。改善发生在持久化 / 归档阶段（§2 与 §3.3），**不在**该指标上 | **需要按 §0 的口径理解**：本目标不是靠降低扫描器耗时达成的 |
| `docs/main-test-baseline.md`：main 稳定失败 5 + flaky 1 | 本次 pristine main 重跑 893 / 89 / 6 issues，失败清单与断言文本逐字一致；集成为 899 / 89 / 5–6 issues，无新增失败 | 一致 |

**需要协调者 / 用户注意的三点（不是缺陷，但影响结论适用范围）**

1. `RegressionGate.checkNoResourceGrowth` 当 `optimized < baseline` 时恒为 `false`，该断言不能
   证明「无退化」，只能捕获反向情形（§3.4 (c)）。
2. `RegressionGate.checkNoMainThreadStall()` 在**无 main run loop** 的无头上下文里必然报停滞；
   集成与 pristine main 的 harness 输出逐字相同（0.0526 s vs 0.0541 s），是工具假象而非产品
   回归。若要真正评估主线程停滞，需要在 App 运行态下测量（本次未做）。
3. B 的测量入口只覆盖 `GitRepositoryScanner.scan`。若后续需要「端到端增量刷新耗时」的权威
   数字，需要新建立完整 `RefreshEngine` / `ScanScheduler` 的测量入口（t-0005 文档已声明该
   缺口，本次核验确认它仍然存在）。

---

## 8. 未做与限制

1. **未运行** `./scripts/install-and-self-check.sh`、`verify-install-upgrade.sh`、
   `verify-upgrade.sh`、`verify-build-consistency.sh`：需要签名身份 / 安装真实 App bundle /
   修改系统状态，超出核验线程「只读 + 仅新增一个文档」的边界。因此 `--self-check` 的
   `scan_git_calls` 等运行时计数未被独立复现（由 §5.4 静态证据替代）。
2. **未运行** `continuousManualRefresh` 场景：仓库内无可运行入口（§3.4）。
3. **未评估** App 运行态的主线程停滞、真实用户目录扫描、Widget reload 时延：需要真实运行
   环境与用户数据。
4. **未覆盖** 多机器 / 多会话的长期稳定性；本核验为单机单会话（约 50 分钟，负载均值 3.2–3.5），
   且以交替测量抵消环境漂移。
5. 全量套件在本机**退出码为 1**（pristine main 同样 6 个 issue）。标准 1 中「退出码 0」的字面
   要求在当前环境下无法满足，故按 §9 的显式豁免口径判定，而不是默认套用。
6. B 的三项资源 / 耗时指标在噪声内未移动；本文档不主张它们改善。
7. `/tmp` 下的原始日志会被系统清理，因此已在库目录保留副本（§1.4）。
8. C 的独立性有限：`checkNoResourceGrowth` 的「无回退」结论与 §3.3 的基准共用同一组数字，
   并非来自独立的端到端场景；本文档已就此明确标注，未把它当作强证明。

---

## 9. 标准 1 的豁免口径（显式写出）

标准 1 的**原文**包含两项要求：

1. 「`./scripts/verify.sh final` 或等价的既有入口与 `DevPulseNative/DevPulseNativeTests/` 全部
   单元测试通过，退出码 0」；
2. 「共享快照 / CAS 语义与既有行为测试不变，无新增旁路写入」。

**第 1 项的字面要求（退出码 0）在当前环境下无法满足**：pristine main（`7f29c0f`）在**本次
核验内重跑**即为 `✘ Test run with 893 tests in 89 suites failed after 45.250 seconds with
6 issues`（等价入口退出码 1）。这 6 个 issue 是环境相关的既有失败，与本次改动无关。

因此本条的实际判定口径为（本节即显式豁免声明）：

> **以「相对 pristine main 无新增失败」替代「退出码 0」**，判定必须同时满足：
> (a) 集成分支的失败集合是 pristine main 失败集合的**子集**（按测试名逐一比对）；
> (b) 相同测试名的**原始断言文本逐字不变**（文件:行号、表达式、展开值）；
> (c) 新增的测试全部通过；
> (d) 共享快照 / CAS 语义相关既有行为测试全部通过且无新增旁路写入。

**依据**：§4.3 的六项逐条比对满足 (a)(b)；§4.2 的 `899 − 893 = 6` 且 6 个新测试全部通过满足
(c)；§5.2–§5.3 满足 (d)。

**该豁免不覆盖的情形**（出现即判不通过）：任何不在基线清单内的新失败；任何同名测试断言文本
发生变化；任何既有测试被跳过 / 改写断言 / 通过调整签名设置绕过。本次核验**均未出现**。

**该豁免的剩余风险**：本机 `group.local.devpulse` 容器的权限问题使这 6 项既有失败无法在当前
环境判定成因（与基线文档一致）。这 6 项中有 4 项与共享快照 / App Group 写入、discovery/pin
迁移、backup recovery 区域**直接重叠**。若要在干净环境（带正确签名与 App Group 权限）下确认
这 4 项本身是否也是既有失败，需要一次带签名身份的独立验证——本次未能执行。
