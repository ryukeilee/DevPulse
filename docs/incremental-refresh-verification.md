# 增量刷新性能改动：集成与终局验收核验

本文档主体 §1–§9 是核验线程 `hp/devpulse/t-0009` 对当时 integration-verify 状态的历史记录，
其原始范围截至当时的集成 tip；旧结论不得自动视为后续交付的当前事实。§10–§11 记录 t-0031
对 commit `2db9218` 的终局复核，保留其当时事实与结论。t-0037 集成及最新端到端测量见 §12，测量适用
commit `b35eebfff499976655a8d99b9b9444564304d60e`；§12 是当前性能结论的权威来源，并明确取代旧章节中
「整次刷新端到端 wall clock 未测」的当前缺口说法，不改写历史记录。

- t-0009 核验者立场为只核验、不修复；历史测量保留原样，不追溯改写。
- t-0031 未改生产代码；除本轮唯一的 canonicalization 测试 fixture 隔离修正外，其余只新增本文档当时的复核附录。原始输出保存在
  `.herdr-project/devpulse-t-0031/library/raw-evidence/`（线程工作目录的忽略目录，不随当时 commit 提交）。
- 操作者提供的 `PROJECT.md` 五条 Acceptance 原文及目标原文逐字收录于 §11；§11 的状态判定仅适用于 t-0031 / `2db9218`，最新状态见 §12。

---

## 0. t-0031 历史判定总览（适用 commit `2db9218`）

> 本表保留 t-0031 当时的判定，不代表 t-0037 集成后的当前状态。最新判定见 §12。

| # | Acceptance 原文判定 | 当前状态 | 依据 |
| --- | --- | --- | --- |
| 1 | 不改功能与数据正确性；全量验证 exit 0；CAS 与既有行为不变；无新增旁路写入 | **成立** | §11.1 |
| 2 | 基于既有基准，同机同命令提供 before/after 数字与原始输出 | **成立** | §11.2 |
| 3 | 刷新耗时 / Git spawn / 资源占用至少一项可复现且超噪声改善 | **部分成立（缺口）**：共享快照 commit 持久化阶段 latency 显著改善，整体 refresh latency 未测；另两类指标分别见 §11.3 | §11.3 |
| 4 | 其他关键基准无 RegressionGate 回退、无关键指标恶化 | **部分成立（缺口）**：已运行 Gate/基准无回退；未执行场景与 Gate 局限见 §11.4 | §11.4 |
| 5 | 定位最高实际开销并以文件/符号证据消除重复工作 | **部分成立（缺口）**：C1–C5 重复工作有实测/符号证据，但未证明完整刷新所有开销已排序穷尽 | §11.5 |

**历史集成版（截至 t-0009 当时）的观察**：`SharedSnapshotStore` commit 的结构计数与该时点基准
见 §2–§3；不可外推到本次 C5 终局的完整刷新耗时。t-0031 在同一既有 scanner 脚本下重测的结果见
§10.3。该 scanner 脚本不覆盖 `RefreshEngine` 内的路径规范化、`ScanScheduler`、历史存储或
`SharedSnapshotStore`，任何单项结果均须按其真实边界解释。

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
5. **历史记录，适用范围仅限 t-0009 当时的 integration-verify 与 pristine `7f29c0f`**：当时全量
   分别为 899 / 89 / 5–6 issues 与 893 / 89 / 6 issues。该结论已被后续 `e221536` 测试隔离改动
   取代；当前 C5 交付状态的两次实测为 917 / 91 / 0，见 §10.2。旧数字与失败集保留作历史，不得再写成当前结论。
6. B 的三项资源 / 耗时指标在噪声内未移动；本文档不主张它们改善。
7. `/tmp` 下的原始日志会被系统清理，因此已在库目录保留副本（§1.4）。
8. C 的独立性有限：`checkNoResourceGrowth` 的「无回退」结论与 §3.3 的基准共用同一组数字，
   并非来自独立的端到端场景；本文档已就此明确标注，未把它当作强证明。

---

## 9. 历史记录：标准 1 的豁免口径（仅适用 e221536 之前的状态）

标准 1 的**原文**包含两项要求：

1. 「`./scripts/verify.sh final` 或等价的既有入口与 `DevPulseNative/DevPulseNativeTests/` 全部
   单元测试通过，退出码 0」；
2. 「共享快照 / CAS 语义与既有行为测试不变，无新增旁路写入」。

**历史结论（仅适用于 e221536 之前的验证脚本和测试隔离状态）**：pristine main（`7f29c0f`）当时实测
`✘ Test run with 893 tests in 89 suites failed after 45.250 seconds with 6 issues`（等价入口退出码 1）。
该结论是历史事实，不是当前环境结论。`e221536` 加入一次性 App Group 容器与一次性 suite 的测试隔离后，
本机 unsigned 全量可以退出码 0；t-0031 对 C5 最终交付状态连续两次重新验证通过，详见 §10.2。

因此本条的实际判定口径为（本节即显式豁免声明）：

> **以「相对 pristine main 无新增失败」替代「退出码 0」**，判定必须同时满足：
> (a) 集成分支的失败集合是 pristine main 失败集合的**子集**（按测试名逐一比对）；
> (b) 相同测试名的**原始断言文本逐字不变**（文件:行号、表达式、展开值）；
> (c) 新增的测试全部通过；
> (d) 共享快照 / CAS 语义相关既有行为测试全部通过且无新增旁路写入。

**历史依据（只对应上述旧提交）**：§4.3 的六项逐条比对满足 (a)(b)；§4.2 的 `899 − 893 = 6` 且 6 个新增测试全部通过满足 (c)；§5.2–§5.3 满足 (d)。当前不得沿用这套旧失败集合或将豁免当成现行前提。

**该豁免不覆盖的情形**（出现即判不通过）：任何不在基线清单内的新失败；任何同名测试断言文本
发生变化；任何既有测试被跳过 / 改写断言 / 通过调整签名设置绕过。本次核验**均未出现**。

**该豁免的剩余风险**：根因已由机制隔离实验与签名对照证实；详见
[`docs/main-test-baseline.md`](main-test-baseline.md)。其中 5 项是无签名 test host 缺少 App Group
entitlement 的环境假象，另 1 项是与签名无关的既有 SleepWake 时序 flake。

---

## 10. t-0031 终局复核（2026-09-23；当前交付 `2db9218`）

本节替代 §0 的旧「当前」总结与 §8.5 / §9 的旧豁免结论。§1–§9 中当时的原始数据与失败记录
不删改，但只适用于旧集成核验提交；本节的当前测试、基准、Gate 和静态审计原始文件保存于线程
证据目录 `.herdr-project/devpulse-t-0031/library/raw-evidence/`。

### 10.1 验收状态代码版本背景

操作者说明 `PROJECT.md` 是项目指令目录中的文件，而非 Git 工作树文件；并在本轮提供其逐字内容。
规范本身以 §11 原文为依据，文档不再把 `git ls-tree` 查不到该项目外文件当作阻塞。

另核对起点：`git rev-parse 7f29c0f 2db9218 origin/main` 输出依次为
`7f29c0f24266fc3014c363671b2aeca8fdafee6c`、
`2db9218a8bcd9f167a8d790fb916cb6a0e71c8f0`、
`e22153642e2dd0607bfd8d055ba7b51ced0d1128`。当前 tip `2db9218` 是 `e221536` + C5；改动前
基线仍是 `7f29c0f`。

### 10.2 标准 1 摘要：测试通过与写入边界

独立 DerivedData 下连续两次实际运行：

```sh
DERIVED_DATA_PATH=/tmp/devpulse-t0031-final-1 ./scripts/verify.sh final
DERIVED_DATA_PATH=/tmp/devpulse-t0031-final-2 ./scripts/verify.sh final
```

第 1 次原始输出（退出码 `0`）：

```text
[verify] Building for testing (DerivedData: /tmp/devpulse-t0031-final-1)…
[verify] Test environment: unsigned (test host writes to an isolated scratch container)
[verify] Build succeeded
[verify] Test environment: unsigned (test host writes to an isolated scratch container)
[verify] Test isolation: container=/var/folders/1z/bw5lw7ds72ngrqfz9fmz48mh0000gn/T//devpulse-appgroup.cClpP2 defaults=local.devpulse.app.tests.27502434-7087-403b-8116-f3115f3886cd
[verify] Running full test suite
[verify] full test suite passed
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds.
✔ Test run with 917 tests in 91 suites passed after 107.866 seconds.
[verify] Final acceptance passed — all checks green
exit_code=0
```

第 2 次原始输出（退出码 `0`）：

```text
[verify] Building for testing (DerivedData: /tmp/devpulse-t0031-final-2)…
[verify] Test environment: unsigned (test host writes to an isolated scratch container)
[verify] Build succeeded
[verify] Test environment: unsigned (test host writes to an isolated scratch container)
[verify] Test isolation: container=/var/folders/1z/bw5lw7ds72ngrqfz9fmz48mh0000gn/T//devpulse-appgroup.1l3qk8 defaults=local.devpulse.app.tests.0e965611-8ddf-43c8-ae13-d0a7486db854
[verify] Running full test suite
[verify] full test suite passed
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds.
✔ Test run with 917 tests in 91 suites passed after 106.445 seconds.
[verify] Final acceptance passed — all checks green
exit_code=0
```

Thus current claim is **exit 0, 917 tests / 91 suites / failedTests 0, 2/2 runs**. Each run used a distinct
DerivedData path and the script's disposable App Group container + preferences suite. Raw full command output
is in `current/final-1.log`, `current/final-2.log`.

C5-specific equivalence / deterministic-count command (same unsigned test host isolation, isolated build):

```sh
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/devpulse-t0031-current-dd \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:DevPulseTests/RepositoryPathCanonicalizationReuseTests test-without-building
```

原始关键输出，退出码 `0`：

```text
canonicalization_equivalence inputs=30 lookups=60 computations=29 reuses=31 distinct=29
canonicalization repos=5 before{lookups=72,computations=72,reuses=0,distinct=6} after{lookups=72,computations=6,reuses=66,distinct=6}
canonicalization repos=20 before{lookups=282,computations=282,reuses=0,distinct=21} after{lookups=282,computations=21,reuses=261,distinct=21}
✔ Test incrementalRefreshComputesEachDistinctPathOnce() passed after 2.119 seconds.
canonicalization_scheduler_remainder repos=20 before{lookups=162,computations=162} after{lookups=162,computations=20}
canonicalization_cost per_call_us=54.68 samples=1000 total_ms=54.7 loadavg=5.29/4.79/4.94
✔ Test run with 8 tests in 1 suite passed after 2.280 seconds.
```

新增 C5 测试逐输入验证 canonical path 与 ID 不变，refresh 返回 repository digest / warning 不变，scope
不跨 refresh；也测出 `applyPins` 仍在 scope 外。这些通过不替代全量测试，但与两次全量一致。

**delivery diff 静态旁路写入审计**只针对交付提交 `HEAD=2db9218` 的新增行，命令：

```sh
git show --format= --unified=0 HEAD | rg '^\+' | rg -v '^\+\+\+' | rg -n 'Process\(|ProcessRunner|\.write\(|AppGroupStore|removeItem|createDirectory|rename'
```

完整原始命中保存在 `current/diff-audit.txt`；共有 20 行（重复命中按原始 grep 行保留），归类如下：

- `Process()`：仅 `RepositoryPathCanonicalizationReuseTests.swift` 的 `runGit` fixture helper，执行
  `/usr/bin/git init/config/add/commit` 来构造**测试临时仓库**；没有新增生产 `Process` / `ProcessRunner`。
- `.write(`：仅测试 fixture 写临时 README / 表格文件，不是 App Group / snapshot 写入。
- `createDirectory`：仅建立测试 scratch 仓库、符号链接目标与临时 fixture。
- `removeItem`：仅测试 `defer` 清理 scratch；但 `canonicalizationTableIsStable` 使用固定
  `/tmp/devpulse-canon-table`，`prepareTableScratch()` 会先 `removeItem(atPath:)`，测试结束再删除。
  在最初 C5 tip `2db9218` 上，这是确定的测试临时路径碰撞风险；本轮 follow-up 已将该路径改为
  `FileManager.default.temporaryDirectory` 下附 UUID 的子目录，移除预清理固定路径的操作，并保留 defer 清理。
  这是测试夹具隔离修正，不是生产旁路写入；修改后全量测试见 §11.6。
- `ProcessRunner`、`AppGroupStore`、`rename`：无命中。

结论限于**没有新增生产旁路写入**；不能表述成「新增 diff 完全没有文件操作」。上述固定 `/tmp`
fixture 风险需保留在剩余风险中。

### 10.3 标准 2 / 3 摘要：同命令对比、噪声与可测范围

改动前由 `git archive 7f29c0f | tar -x -C /tmp/devpulse-t0031-before-source` 导出到 `/tmp`，
未切换、删除或改动任何其他检出。把同一个 `scripts/measure-incremental-refresh.sh` 放入导出目录，
两边均独立构建并运行同一入口；改动前构建命令以 `build-for-testing` 完成，构建原始日志
`before/build.log`。测量命令完全相同，仅输入树、DerivedData 与输出位置各自隔离：

```sh
# before：
cd /tmp/devpulse-t0031-before-source
DERIVED_DATA_PATH=/tmp/devpulse-t0031-before-dd RUNS=5 \
OUTPUT_DIR=/Users/ryukeili/.herdr/worktrees/DevPulse/hp-devpulse-t-0031-5/.herdr-project/devpulse-t-0031/library/raw-evidence/before/measure \
./scripts/measure-incremental-refresh.sh

# current：从线程工作目录运行
cd /Users/ryukeili/.herdr/worktrees/DevPulse/hp-devpulse-t-0031-5
DERIVED_DATA_PATH=/tmp/devpulse-t0031-current-dd RUNS=5 \
OUTPUT_DIR=/Users/ryukeili/.herdr/worktrees/DevPulse/hp-devpulse-t-0031-5/.herdr-project/devpulse-t-0031/library/raw-evidence/current/measure \
./scripts/measure-incremental-refresh.sh
```

改动前原始样本 / 汇总：

```text
1  37  4  179765248  87573464
2  38  4  179961856  88032216
3  38  4  180240384  88343512
4  37  4  180535296  88802264
5  49  4  180748288  88507304
metric                         mean          stddev_population  min       max       n
incremental_elapsed_ms         39.800        4.622              37        49        5
incremental_git_calls          4.000         0.000              4         4         5
command_max_rss_bytes           180250214.400 359941.229         179765248 180748288 5
command_peak_footprint_bytes    88251752.000  420728.143         87573464  88802264  5
```

交付状态原始样本 / 汇总：

```text
1  36  4  179912704  87507928
2  38  4  179847168  88015808
3  37  4  180404224  88556504
4  35  4  180682752  88851416
5  37  4  181026816  88523712
metric                         mean          stddev_population  min       max       n
incremental_elapsed_ms         36.600        1.020              35        38        5
incremental_git_calls          4.000         0.000              4         4         5
command_max_rss_bytes           180374732.800 450056.283         179847168 181026816 5
command_peak_footprint_bytes    88291073.600  474899.086         87507928  88851416  5
```

并另作 **5 组交替配对**（每次独立运行均重新创建测试临时 Git 仓库；`current → before`），原始
`elapsed_ms / git_calls` 配对如下：

```text
pair 1: current 48 / 4, before 49 / 4
pair 2: current 37 / 4, before 59 / 4
pair 3: current 37 / 4, before 37 / 4
pair 4: current 38 / 4, before 37 / 4
pair 5: current 48 / 4, before 39 / 4
before-current paired deltas (ms): +1, +22, 0, -1, -9
```

样本创建方式与顺序解决同目录 commit/writeback 偏差和部分时间漂移问题；不能消除系统负载、缓存、
常驻 App/Widget 干扰。本轮前组测量时 `uptime` 为
`load averages: 2.89 4.63 4.93`；前组测量期间记录到 DevPulse.app 和 Widget、多个 `pi` / Herdr
进程、`xcodebuildmcp` 服务。配对轮的采样 1-min load average 约 4.07–4.44（完整 1/5/15 分钟值见
`paired/samples.tsv`）；同一时间系统另有其他进程，后续进程快照可见另一个仓库的 Git 刷新基准任务。
因此墙钟仅作带噪声观察，不声称受控空闲基准。

- `incremental_elapsed_ms`：5 次非配对均值 39.8 → 36.6 ms，差 −3.2 ms；改动前 `2×population SD`
  噪声参考为 9.244 ms，绝对差没有超过该参考。5 组配对差中位数为 0 ms，仅 2/5 严格改善、2/5
  变慢、1/5 相同（含 +22 ms 离群对）。判定：**未证明改善超出噪声**。
- `incremental_git_calls`：4 → 4，逐样本恒定，确定性地无变化；无调用数改善。
- command RSS：均值差 +124,518 bytes（+0.07%），小于改动前 SD 359,941 bytes；peak footprint 差
  +39,322 bytes（+0.045%），小于改动前 SD 420,728 bytes。两者量测整个 `xcodebuild` 命令及测试 host，
  不是 scanner 独占资源，未证明改善。
- C5 真正被改变的确定性指标是 `RepositoryIdentity.canonicalPath` **计算次数**：5 repo 72→6（−66，
  −91.7%），20 repo 282→21（−261，−92.6%）；输入 lookup 总数保持不变，结果与 ID 不变。这是
  filesystem path-resolution 工作次数，不是 Git spawn 数。测试内的单次计算成本样本
  `54.68 µs / 1000 calls` 只作成本量级线索，受当时负载影响，不能乘算并冒充完整 refresh wall time。

该仓库已有 `measure-incremental-refresh.sh` 只调用 `GitRepositoryScanner.scan`，并不执行
`RefreshEngine.execute` 的完整定时刷新路径；其 Git 计数只覆盖 `ScanMetrics` 测量区间，无法测 discovery
阶段未注入的 worktree 查询。故它不能验证 C5 是否改善完整 refresh wall clock / 总 Git spawn。
`BenchmarkRunner.gitSubprocessCount` 是前后瞬时活动进程数，不是累计启动数；`BenchmarkScenario` 未接真实
刷新，两者均不作为结论指标。`--self-check` 强制发现与 `.manual` source，也不是稳态刷新指标；本轮未运行。

### 10.4 标准 4 摘要：RegressionGate 场景与局限

当前定向测试均用隔离容器、同一 `/tmp/devpulse-t0031-current-dd`、无并发 xcodebuild 顺序运行：

| Gate / 情景 | 本轮实际证据 | 判定与局限 |
| --- | --- | --- |
| `checkNoZombieGitProcesses` | `FullRegressionGateTests.zombieGitCheckDoesNotCrash()` 与 `RegressionGateTests.noZombieGitProcesses()` 通过 | 本轮观测通过；该实现用 `pgrep` 瞬时进程匹配，不能证明刷新期间没有短命 spawn |
| `checkNoMainThreadStall` | `FullRegressionGateTests.mainThreadStallCheckReturnsNilOnIdle()` 通过 | 当前 app-hosted 测试 main queue 有运行机会；无头命令行 harness 会因 semaphore 等待人为报 stall，不能据其判产品回退 |
| `checkNoTaskLeak` | `taskLeakDetectsAddedTasks()` 通过 | 证明合成输入可识别一个新增 task；未在真实完整刷新前后采集任务集合，不能证明生产刷新零泄漏 |
| `checkNoDuplicateSnapshotWrite` | `duplicateSnapshotDetection()` 通过 | 证明合成重复 runID 可被识别；未提供真实刷新 observation store 的端到端审计 |
| `checkNoInfiniteRetries` | `RegressionGateTests.infiniteRetryDetection()` 通过 | 合成 `RefreshResult` 测试通过；没有对真实刷新所有重试链路作全量采样 |
| `checkNoResourceGrowth` / `LifecyclePerformanceTests` | 同轮基准输出：5 repos paired median delta 6.914ms、positive 30/30；50 repos delta 6.290ms、positive 29/30；测试通过 | 本轮 Gate 没有 regression；但实现 `isRegression = delta > threshold`，优化值低于 baseline 时必为 false，无法捕获相对 baseline 的任何反向问题以外的「无退化」证明，强度有限 |
| `checkAll` 完整组合 | 本轮未为 result/store/tasks 所有真实分支提供统一生产输入 | **不能判定**；个别 Gate 单测通过不等于生产 `checkAll` 完整场景通过 |
| `continuousManualRefresh` | 无生产/测试刷新入口连接此 scenario | **不能判定**，没有真实数据；不得虚构结果 |

这份 Gate 判定不扩大为「所有场景无回退」。另外 `checkNoResourceGrowth` 在
`optimized < baseline` 时 `isRegression` 数学上必为 false；“测试 assert false”不能独立证成无回退。

### 10.5 标准 5 摘要：C1–C5 文件/符号证据及未测开销

| 改动 | 当前文件 / 符号证据与实测 |
| --- | --- |
| C1 (`5cc516f`) | `SharedSnapshotStore.swift` 的 `.preserveIdenticalBackup` 判定/执行与 `SharedSnapshotStoreTests` observer。当前定向实测 `non-identical writes=3, F_FULLFSYNC=6`，steady-state `writes=2, F_FULLFSYNC=4`；保护路径与稳态路径分开。`LifecyclePerformanceTests` 本轮 5/50 repos old/new median 分别 `41.619/35.791 ms` 与 `79.519/74.006 ms`，paired positive `30/30` 与 `29/30`；是测试内 commit A/B，不是完整 App 刷新。 |
| C2 (`676919f`) | `RepositoryHistoryStore.recordSnapshotStates`、`loadGrouped`、`ScanScheduler` 调用点与 archive decode metrics。当前测试：300 entries / 5 repos / 30 iterations，old/new decode `150/30`、bytes `26088750/5217750`，median `10.280541/2.1295 ms`；定向 suite 13 tests passed。 |
| C3 (`5cc516f`) | `DateFormatting.TimestampParser` 与 `SharedSnapshotStore.validateRepositoryPayload` 一次操作内复用 parser。存在 file/symbol 级实现证据，但本轮没有单独隔离计量 C3 时间收益；不宣称已量化消除多少总耗时。 |
| C4 (`f2bcffa` 与后续 `9c34f8a` / `dedc1c5`) | `ScanScheduler.recordActivityEvents` 与 refresh observation 只在内容变化时保存；串行保存队列和陈旧回调不回滚内存列表。当前 `IdleRoundActivityArchiveTests` 原始输出 `activity_idle_round_writes=[0, 0, 0]`，每轮 0 writes / 0 bytes，archive 保持 316184 bytes；suite 6 tests passed。本轮未对 refresh-observation archive 作单独端到端文件写计数。 |
| C5 (`2db9218`) | `RepositoryIdentity.canonicalPath` 的 refresh-scope map（`Models.swift`）由 `RefreshEngine.execute` 包围；当前真实 `RefreshEngine.execute(source: .timer)` 测试 72→6（5 repos）、282→21（20 repos），result digest / warnings 相同，scope 不跨轮。`applyPins` scope 外 162→20 的独立项亦被测试观察；未主张此余项已被整体消除。 |

当前可证明的是各改动针对的重复工作与预期结构计数；本轮**没有**完成安装态完整 App 刷新端到端
耗时、CPU/RSS 资源、全部文件 I/O、Widget reload、主线程真实交互 stall、所有仓库规模/异常路径长期测量。
不能把 scanner microbenchmark 的 36.6 ms 称为完整用户刷新耗时，不能把 per-call 54.68µs 外推成 C5
端到端收益，也不能称最高成本被全局排尽。

### 10.6 当前结论与历史适用范围

- §9 原「退出码 0 在当前环境无法满足」**已经过时**。当前 `e221536` 测试隔离下，本轮 C5 状态两次
  unsigned `verify.sh final` 均 exit 0 / 917 tests / 91 suites / 0 failures；保留 §9 作为 e221536
  之前的历史记录，不再作为豁免或当前判据。
- §4 中 `899 / 89 / 5–6 issues` 与 `893 / 89 / 6 issues`、失败集合及其断言文本，只适用于旧
  integration-verify 和 `7f29c0f` 的旧脚本环境，不是当前交付的失败集合。
- §2–§3 的集成版 commit benchmark 数字适用于旧 tip；当前 C1/C2/C4/C5 的本轮原始输出见本节与
  `current/*.log`，不得把历史数字标成 t-0031 本轮复测。
- §11 根据操作者提供的五条原文逐条判定；历史摘要、旧失败集合仍严格标明适用状态。
- C5 新增测试的固定临时目录碰撞风险已在本轮 follow-up 改成 UUID 唯一的 temporaryDirectory 子目录；完整全量验证见 §11.6。原 C5 提交的历史 grep 命中仍留作证据，不再代表 follow-up 后的当前夹具。

---

## 11. Acceptance 原文的正式逐条判定（操作员 2026-09-23 提供）

### 11.0 目标原文与判定摘要（仅适用于 t-0031 / `2db9218`）

> 本节及 §11.3 中「整次刷新 elapsed 未测」的判定是 `2db9218` 当时的历史事实。t-0037 已运行完整 timer 刷新端到端测量；该缺口已关闭，当前标准 3 判定见 §12.5。

> 在不改变现有功能和数据正确性的前提下，优化 DevPulse 当前 main 的日常增量刷新性能：基于现有基准定位最高实际开销并消除不必要的重复工作，使刷新耗时、Git 子进程或资源占用至少一项获得可复现改善且其他关键指标不明显回退，相关测试与验证通过。

| # | 正式判定 | 核心理由 |
| --- | --- | --- |
| 1 | **成立** | 最新测试夹具改动后 `verify.sh final` exit 0；共享快照/CAS 既有套件通过；增量代码没有新增生产旁路写入。 |
| 2 | **成立** | `7f29c0f` 与交付状态用同机、同一仓库既有 scanner 基准命令对比，各 5 个新目录样本并有 5 组交替配对与原始输出。 |
| 3 | **部分成立（缺口）** | `SharedSnapshotStore.commit` 这一真实刷新持久化阶段的配对耗时改善超过本组配对噪声；全刷新端到端耗时并未测出改善。Git spawn 无改善；进程 RSS/footprint 无改善；若资源按持久化 I/O 工作量衡量则有确定性改善。 |
| 4 | **部分成立（缺口）** | 已运行的 `RegressionGate` 场景及关键基准未见回退，但 Gate 覆盖不是完整端到端，存在假阴性性质，`continuousManualRefresh` 没有可执行入口。 |
| 5 | **部分成立（缺口）** | C1–C5 均有文件/符号级的重复工作证据和目标计数；但没有全局排序并测完所有刷新路径，故不声称穷尽“最高实际开销”。 |

### 11.1 标准 1 原文及判定：成立

> 不改功能与数据正确性：改动后仓库既有验证入口（`./scripts/verify.sh final` 或等价的既有入口）与 `DevPulseNative/DevPulseNativeTests/` 全部单元测试通过，退出码 0；共享快照/CAS 语义与既有行为测试不变，无新增旁路写入。

前两次完整套件在未改测试夹具前均 exit 0，917 / 91 / 0；本轮将测试夹具改为唯一目录后，按要求再次运行完整验证：

```sh
DERIVED_DATA_PATH=/tmp/devpulse-t0031-final-final ./scripts/verify.sh final
```

原始输出（命令退出码 `0`）：

```text
[verify] Building for testing (DerivedData: /tmp/devpulse-t0031-final-final)…
[verify] Test environment: unsigned (test host writes to an isolated scratch container)
[verify] Build succeeded
[verify] Test environment: unsigned (test host writes to an isolated scratch container)
[verify] Test isolation: container=/var/folders/1z/bw5lw7ds72ngrqfz9fmz48mh0000gn/T//devpulse-appgroup.D4i8I4 defaults=local.devpulse.app.tests.f1bb2257-a9d4-446b-806a-82d45ca873fc
[verify] Running full test suite
[verify] full test suite passed
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds
✔ Test run with 917 tests in 91 suites passed after 106.435 seconds.
[verify] Final acceptance passed — all checks green
exit_code=0
```

原始完整日志：`current/final-final.log`；此前两轮仍保留于 `current/final-1.log` / `current/final-2.log`，第一次夹具修改后的全量在 `current/final-revised.log`。
“Executed 0 tests”是 xcodebuild XCTest wrapper 的空壳汇总行；Swift Testing 的实际汇总是紧随其后的
`917 tests in 91 suites passed`，不能把 wrapper 行误作零测试。

同一交付中，共享快照语义由全量套件及定向 `SharedSnapshotStoreTests` 验证：原始行
`non-identical recovery operations: writes=3, F_FULLFSYNC=6`、`steady-state operations: writes=2,
F_FULLFSYNC=4`，以及 `28 tests in 1 suite passed`（完整 stdout 在 `current/SharedSnapshotStoreTests.log`）。
C5 生产 diff 只涉及路径规范化 helper 与 `RefreshEngine.execute` scope 接线；不改共享快照/CAS 实现。

对当前 C5 delivery commit 新增行做静态审计：

```sh
git show --format= --unified=0 2db9218 | rg '^\+' | rg -v '^\+\+\+' | rg -n 'Process\(|ProcessRunner|\.write\(|AppGroupStore|removeItem|createDirectory|rename'
```

本轮原始审计文件 `current/diff-audit.txt` 中全部命中均为 C5 测试 fixture 的临时 Git 仓库、临时文本、
符号链接目录及其清理；未命中生产 `ProcessRunner`、`AppGroupStore` 或 `rename`。测试中的 `Process()`
仅用于初始化临时 Git 仓库。最初使用固定 `/tmp/devpulse-canon-table` 的确存在并发碰撞；本轮唯一
测试夹具修改已改用 `FileManager.default.temporaryDirectory` + UUID 子目录，且测试退出时仍 `defer`
清理。该修正后的最后一次全量通过。静态检查结果限定为“无新增生产旁路写入”，不代表“无文件写入”。

### 11.2 标准 2 原文及判定：成立

> 基于现有基准：使用仓库既有基准设施（`BenchmarkSuite.swift`、`PerformanceBaseline.swift`、`BaselineManager.swift`、`RegressionGate.swift`、`LifecyclePerformanceTests.swift`），在同一机器、同一命令下给出改动前后的对比数字，报告中附命令与原始输出。

以 `git archive 7f29c0f` 导出 pristine before 到 `/tmp/devpulse-t0031-before-source`；没有切换或改动其他
checkout。两侧均用 `scripts/measure-incremental-refresh.sh`，同机同一命令参数、macOS 27 / Xcode 27、各自
独立 DerivedData、`RUNS=5`；脚本驱动仓库既有 `ScanPerformanceTests`，并输出 performance-baselines JSON。
精确命令、每个 before/current 原始 5 行、summary 和 5 组交替配对已完整列于 §10.3，原始文件位于
`before/measure/{samples.tsv,summary.tsv}`、`current/measure/{samples.tsv,summary.tsv}`、
`paired/samples.tsv`。例如原始汇总：

```text
before incremental_elapsed_ms 39.800, stddev_population 4.622, n=5
current incremental_elapsed_ms 36.600, stddev_population 1.020, n=5
before/current incremental_git_calls 4.000 / 4.000, stddev_population 0 / 0
before/current command_max_rss_bytes 180250214.400 / 180374732.800
before/current command_peak_footprint_bytes 88251752.000 / 88291073.600
```

并且本轮在当前二进制里重跑既有 `LifecyclePerformanceTests.steadyStateCommitBenchmark()`，该设施按
同一 payload 做 30 组配对 A/B、交替执行顺序、每个单次 commit 使用新 UUID 临时目录；原始命令完整输出
见 `current/LifecyclePerformanceTests.log`。本条只要求有同机、同命令、基于既有设施的改动前后数字，故
判定成立；不把组件 A/B 冒充 7f29c0f 旧二进制结果。

### 11.3 标准 3 原文及逐指标判定：部分成立（缺口）

> 可复现改善：刷新耗时、Git 子进程调用次数、资源占用三项中至少一项有超出噪声范围的改善，并说明噪声估计与重复测量方法。

**刷新耗时。** 全刷新整体 elapsed 没有通过现有 scanner 基准证明改善：before/current 五次均值
39.8→36.6ms，差 −3.2ms，而改动前 `2×population SD = 9.244ms`；交替 5 对的
`before-current = +1,+22,0,-1,-9ms`，中位差 0ms、改善 2/5、变慢 2/5、相同 1/5。因此
`GitRepositoryScanner.scan` 的耗时改善**未超噪声**。这一入口不覆盖 `RefreshEngine` 完整刷新与持久化。

另一方面，既有 `LifecyclePerformanceTests` 测的 `SharedSnapshotStore.commit` 是刷新 persistence 阶段的
真实操作，其同命令内按仓库数做 30 组配对，单次样本使用新目录，baseline/optimized 顺序交替。噪声使用
**配对差的 MAD**，不拿单组 MAD 作显著性标准：

```text
SharedSnapshotStore benchmark repositories=5 iterations=30 baseline_median_ms=41.619 baseline_p95_ms=49.394 baseline_mad_ms=4.028 optimized_median_ms=35.791 optimized_p95_ms=40.797 optimized_mad_ms=3.898 paired_median_delta_ms=6.914 paired_mad_delta_ms=2.571 paired_positive=30
SharedSnapshotStore benchmark repositories=50 iterations=30 baseline_median_ms=79.519 baseline_p95_ms=89.546 baseline_mad_ms=2.245 optimized_median_ms=74.006 optimized_p95_ms=80.028 optimized_mad_ms=1.360 paired_median_delta_ms=6.290 paired_mad_delta_ms=2.267 paired_positive=29
```

5-repo 的 paired 中位收益 6.914ms > 2×paired MAD 5.142ms，且 30/30 对都更快；50-repo 收益
6.290ms > 2×paired MAD 4.534ms，且 29/30 对更快。因此**刷新持久化组件耗时**的改善超出该测试自身
配对噪声；差异以 paired delta 分布为判据。该 A/B 是“必须发布不同 recovery copy 的旧语义”与“复用相同
recovery copy 的优化语义”，同一命令/同一进程当前构建内测试，不是 whole-refresh elapsed。
因此这一项支持标准 3 的刷新阶段耗时改善，但因没有完整端到端 refresh wall clock，正式结论为
**部分成立（组件成立、整体刷新时间缺口）**。

`RepositoryHistoryStoreTests` 同轮 30 次循环的历史归档解码 benchmark 原始行：

```text
history-load-benchmark entries=300 repositories=5 iterations=30 old_median_ms=10.280541 old_p95_ms=10.569375 old_mad_ms=0.12904300000000113 new_median_ms=2.1295 new_p95_ms=2.21775 new_mad_ms=0.059708000000000094 old_decodes=150 new_decodes=30 old_bytes=26088750 new_bytes=5217750
```

该测试按 old block 后 new block 连续计时，不是配对设计；不以它的墙钟差单独声称显著性。它的确定性
结构数据（150→30 次 decode、26,088,750→5,217,750 bytes read，5 倍）证明避免重复解码/读档，不受
墙钟噪声影响。

**Git 子进程调用次数。** 同一 `measure-incremental-refresh.sh` 每侧五次均输出 `incremental_git_calls=4`，
SD 均为 0；五组配对也全为 `4/4`。结论：无 Git 子进程调用次数减少，也未观察到增加。此计数只覆盖 scanner
测试区间，不能数 discovery 阶段 worktree 查询；`BenchmarkRunner.gitSubprocessCount` 是瞬时进程存量，
不是累计 spawn，不能替代该指标。

**资源占用——进程内存定义。** 主定义采用已有测量脚本输出的命令级
`command_max_rss_bytes`（maximum resident set）和 `command_peak_footprint_bytes`（peak memory footprint），
范围是一整条 `xcodebuild test-without-building` 及测试 host，并非 scanner 独占资源。五次样本组的均值：
RSS 180,250,214.4→180,374,732.8 bytes（增加 124,518.4，约 +0.07%）；footprint
88,251,752→88,291,073.6 bytes（增加 39,321.6，约 +0.045%）。增量分别小于 before 组的
population SD 359,941.229 和 420,728.143 bytes；判定：没有超噪声改善，也未见明显回退。

**资源占用——持久化 I/O 定义（另列，不与内存混称）。** 若将存储 I/O 操作也算资源消耗，则有确定性
减少：

```text
SharedSnapshotStore non-identical recovery operations: writes=3, F_FULLFSYNC=6
SharedSnapshotStore steady-state operations: writes=2, F_FULLFSYNC=4
activity_idle_round=1 writes=0 bytes=0 archive_bytes=316184
activity_idle_round=2 writes=0 bytes=0 archive_bytes=316184
activity_idle_round=3 writes=0 bytes=0 archive_bytes=316184
activity_idle_round_writes=[0, 0, 0]
```

一次稳态 snapshot commit 少 1 次文件写与 2 次 `F_FULLFSYNC`，非 identical recovery 的保护路径保持
3/6；三轮 idle activity archive 确实 0 写、0 字节，原 316,184-byte 档案保留。C2 对历史归档的读取
字节亦为 5 倍减少。以上是 I/O 工作量而不是内存占用；这些结构计数无采样噪声，且来自 operation observer
或 test write observer。

综合三项：Git spawn 不改善；RSS/footprint 不改善；scanner 全刷新替代入口的 elapsed 未超噪声；但共享快照
commit 这个实际刷新阶段 latency 通过 30 组配对显示可复现改善，持久化写/同步工作也确定性减少。标准 3
因此**部分成立**，不延伸声称全刷新总时长或进程内存已经改善。

### 11.4 标准 4 原文及判定：部分成立（缺口）

> 不明显回退：其他关键基准场景无 `RegressionGate` 判定的回退，未出现为改善单点指标而恶化的其他关键指标。

本轮实际运行的 Gate 证据（对应原始日志 `current/FullRegressionGateTests.log`、
`current/RegressionGateTests.log`、`current/LifecyclePerformanceTests.log`）：

```text
✔ Test zombieGitCheckDoesNotCrash() passed
✔ Test mainThreadStallCheckReturnsNilOnIdle() passed
✔ Test taskLeakDetectsAddedTasks() passed
✔ Test duplicateSnapshotDetection() passed
✔ Test noZombieGitProcesses() passed
✔ Test infiniteRetryDetection() passed
✔ Test "SharedSnapshotStore steady-state commit benchmark" passed
```

对应命令为同一 `/tmp/devpulse-t0031-current-dd` 上 unsigned `xcodebuild ... -only-testing:DevPulseTests/FullRegressionGateTests test-without-building`、`.../RegressionGateTests ...`、`.../LifecyclePerformanceTests ...`；每个进程注入独立 `TEST_RUNNER_DEVPULSE_APP_GROUP_CONTAINER_PATH` 和 `TEST_RUNNER_DEVPULSE_APP_GROUP_DEFAULTS_SUITE`。Lifecycle benchmark 中两种 repo count 的 `checkNoResourceGrowth(...).isRegression == false`；并且两个 paired benchmark 没有关键指标反向恶化。标准 3 中 scanner 的 Git calls、RSS/footprint也没有观察到显著恶化。

但结论必须受以下边界约束：

- `RegressionGate.checkNoResourceGrowth` 设 `isRegression = delta > threshold`；若 `optimized < baseline`，则 delta 为负，结果恒为 `false`。所以该 gate 只能发现耗时反向超阈，不是无退化的强证明。
- `checkNoMainThreadStall()` 在无 main run loop 的 headless harness 会因等待 main queue 而产生工具假象；本轮 app-hosted XCTest 中对应 idle test 通过，也不能替代 GUI/运行态主线程响应测试。
- `BenchmarkScenario.continuousManualRefresh` 无生产或测试入口实际驱动，无法判定该场景。
- `checkTaskLeak` 与 `checkNoDuplicateSnapshotWrite` 的测试使用合成 leak/duplicate 输入证明检测逻辑，不是完整生产刷新前后数据；没有覆盖 `checkAll` 所有实际参数组合。

因此在已执行场景内没有观察到 RegressionGate 判回退，但对“其他所有关键基准场景无回退”判为
**部分成立（缺口）**，而非全场景成立。

### 11.5 标准 5 原文及判定：部分成立（缺口）

> 只消除重复工作，定位到最高实际开销（有文件/符号级证据），而非凭猜测重构。

有文件/符号级且与本轮实测对应的证据：

- C1 `SharedSnapshotStore.swift`：identical recovery backup 路径只跳过重复 pre-commit recovery write；steady state 3 writes/6 sync→2/4，non-identical recovery 仍为 3/6。commit A/B paired time 如 §11.3。
- C2 `RepositoryHistoryStore.recordSnapshotStates`、`loadGrouped` 与 `ScanScheduler` 调用点：5 仓库历史归档 30 次循环 decode 150→30，读取字节 26,088,750→5,217,750；同轮 refresh archive decode 有专门 ≤2 次断言。
- C3 `DateFormatting.TimestampParser` 在 `SharedSnapshotStore.validateRepositoryPayload` 中复用 formatter；文件/符号级证据明确，但无单独计量其耗时贡献。
- C4 `ScanScheduler.recordActivityEvents` / observation 变化判断：idle 轮历史事件档案实测 3 轮 `[0,0,0]` 写入，已有内容无变化时不全档重写；按提交顺序保存与陈旧回调不回滚有针对性竞态测试。
- C5 `Models.swift:RepositoryIdentity.canonicalPath` / refresh canonicalization scope 与 `RefreshEngine.execute`：真实 `RefreshEngine.execute(source: .timer)` 测试中 5 repos computations 72→6、20 repos 282→21，lookup 总数不变、repository digest 与 warnings 相同；每 refresh scope 结束释放 map，下一轮会重新 resolve。测试另量出 `applyPins` scope 外 20 repo computations 162→20，说明仍有明确剩余项。

据此可成立的是 C1–C5 都针对已观察的重复工作，有源码位置与可重跑证据，不是凭猜测重构。但本轮没有端到端测全部 refresh stages，也没对所有阶段开销做同口径排名；`BenchmarkSuite` 的其它 scenario 有些未连接真实刷新，C3 未独立计时。故“消除已定位重复工作”证实，“已定位全局最高实际开销并证明其为所有路径最高”仍有缺口，正式判定为**部分成立**。

### 11.6 本轮唯一测试夹具修正与最终验证

原 `canonicalizationTableIsStable` 使用共享固定路径 `/tmp/devpulse-canon-table`，多个并行 xcodebuild test host 会删建同一路径；并发碰撞风险成立。唯一代码改动（测试 fixture，不改产品行为）：

```swift
private static let tableScratchPath = FileManager.default.temporaryDirectory
    .appendingPathComponent("devpulse-canon-table-\(UUID().uuidString)")
    .path
```

同时移除 `prepareTableScratch()` 先删除固定路径的调用；测试结束仍用 `defer` 清理本次唯一的目录。这样每个测试 host 生成独立 scratch，不触碰其他运行的目录。改动后完整、无签名验证命令与原始输出见 §11.1；结果 **exit 0，917 tests / 91 suites / 0 failures**。`current/final-final.log` 为夹具及其注释修订后的最后一次执行的完整日志。

---

## 12. t-0037 集成与当前验收结论（2026-09-23）

本节是最新当前事实，适用于三条分支集成后的测量候选 commit
`b35eebfff499976655a8d99b9b9444564304d60e`（短 OID `b35eebf`）；其中测量原始文件保存在
`.herdr-project/devpulse-t-0037/library/e2e-measurement-20260923-0858/`。§1–§11 的历史结论均保留，
但早期「整次刷新端到端 wall clock 未测」只适用于其标明的旧 commit。

### 12.1 集成及全量验收

按 `t-0032` → `t-0035` → `t-0034` 顺序集成：`b1ad2c6`、`d2e7674`（含 `72c88fd`）、
`eb8d492`。`.agent/history.md` 的冲突保留双方 Loop 38 记录，顺排为 Loop 38/39；
`project.pbxproj` 冲突由 `project.yml` 经 `xcodegen generate` 重建解决，生成差异为 4 行纯新增，
`DiscoveryGitCallAccountingTests.swift` 与 `EndToEndRefreshMeasurementTests.swift` 均出现在
DevPulseTests 的 Sources 列表。两测试文件各自在对应源分支相对 `origin/main` 均为 `A`（纯新增）。

集成候选上的全量验收命令与原始汇总：

```text
DEVPULSE_SIGNING_MODE=unsigned DERIVED_DATA_PATH=/tmp/devpulse-t0037-prepublish-final ./scripts/verify.sh final
[verify] Building for testing (DerivedData: /tmp/devpulse-t0037-prepublish-final)…
[verify] Test environment: unsigned (test host writes to an isolated scratch container)
[verify] Build succeeded
[verify] Test environment: unsigned (test host writes to an isolated scratch container)
[verify] Running full test suite
[verify] full test suite passed
✔ Test run with 919 tests in 93 suites passed after 106.204 seconds.
[verify] Final acceptance passed — all checks green
exit_code=0; failedTests=0
```

### 12.2 整次刷新端到端 wall clock：历史缺口已关闭

命令（基线 `7f29c0f`，当前候选 `b35eebf`；两版本各构建一次，随后每样本使用
`test-without-building`；`RUNS=10` 为 10 组配对）：

```sh
RUNS=10 BASELINE_REV=7f29c0f \
DERIVED_DATA_PATH=/tmp/devpulse-t0037-e2e-derived \
OUTPUT_DIR=.herdr-project/devpulse-t-0037/library/e2e-measurement-20260923-0858 \
./scripts/measure-end-to-end-refresh.sh
```

测量设施、样本边界、隔离方式和噪声规则详见 [`docs/refresh-end-to-end-measurement.md`](refresh-end-to-end-measurement.md)。
奇数配对先 baseline、偶数配对先 current；每个样本使用新 workspace、4 个临时仓库、独立 App Group
目录和 defaults suite。`scheduler_wall_ms` 覆盖 timer refresh 到 snapshot、activity archive 与 history
archive 全部完成；初次 fixture / forced discovery 不在计时区间内。

样本表（单位 ms；差值为 current − baseline）：

| pair | 顺序 | baseline scheduler | current scheduler | 配对差 |
|---:|---|---:|---:|---:|
| 1 | baseline first | 294.135 | 216.117 | -78.018 |
| 2 | current first | 308.640 | 220.854 | -87.786 |
| 3 | baseline first | 284.696 | 214.836 | -69.860 |
| 4 | current first | 304.456 | 214.763 | -89.693 |
| 5 | baseline first | 303.938 | 224.827 | -79.111 |
| 6 | current first | 311.263 | 236.609 | -74.654 |
| 7 | baseline first | 272.904 | 205.370 | -67.534 |
| 8 | current first | 289.461 | 221.089 | -68.372 |
| 9 | baseline first | 303.710 | 235.715 | -67.995 |
| 10 | current first | 293.112 | 222.514 | -70.598 |

`summary.txt` 原始摘要（同一内容保存在该线程的 measurement artifact 目录）：

```text
metric	baseline_median	current_median	paired_median_delta(current-baseline)	paired_MAD	faster_pairs	slower_pairs	tied_pairs	two_sided_sign_p
scheduler_wall_ms	298.923	220.971	-72.626	4.862	10/10	0/10	0/10	0.00195
refresh_engine_ms	142.803	118.267	-23.757	10.170
command_max_rss_bytes	179576832	179912704	106496	212992	4/10	6/10	0/10	0.75391
command_peak_footprint_bytes	88728536	88835032	-24588	204776
elapsed_group_summary	baseline_mean=296.632	baseline_population_sd=11.395	current_mean=221.269	current_population_sd=9.063	pairs=10
elapsed_improvement_beyond_noise=yes
elapsed_improved_pairs=10/10
elapsed_paired_median_delta_ms=-72.626
elapsed_paired_MAD_ms=4.862
elapsed_exact_two_sided_sign_p=0.00195
```

**显式结论：scheduler 端到端刷新耗时改善超出本轮测量噪声。** 10/10 配对更快，配对中位差
`-72.626 ms`，配对差 MAD `4.862 ms`，精确双侧 sign test `p=0.00195`；本结论依据配对方向
检验及交替顺序，不使用“中位数差大于单组 MAD”的简单规则。当前中位数 220.971 ms，相对基线
298.923 ms 约快 24.3%。故「整次刷新端到端 wall clock 未测」缺口已关闭，标准 3 的耗时条件成立。

RSS 是整条 `xcodebuild test-without-building` 命令与 test host 的峰值，不是刷新进程独占内存；
配对 RSS 差中位数 `+106,496 bytes`，`p=0.75391`，没有内存改善证据。peak footprint 差中位数
`-24,588 bytes`，也不据此主张内存改善。Git 子进程数不由此 wall clock 推断。

原始证据路径：`samples.tsv`、`summary.txt`、`samples.tsv.raw`、`raw/`、`system/` 及每个样本独立
目录均在 `.herdr-project/devpulse-t-0037/library/e2e-measurement-20260923-0858/`；目录包含命令元数据、
两版本构建日志、20 次测试原始日志、`/usr/bin/time -l` 输出和系统快照。

### 12.3 机器状态、并发与测量可信度

测量前 `2026-09-23T08:58:32+0800` 执行 `ps`、`uptime` 与精确进程名检查：load average
`2.14 / 2.33 / 2.25`；`pgrep -x xcodebuild` / `pgrep -x xctest` 均无进程。可见常驻
`xcodebuildmcp` helper（非实际构建）、Pi/Herdr、Chrome、Ghostty、Clash Verge，以及已运行的
`/Applications/DevPulse.app` 和 Widget extension。测量脚本自身的初始快照记录 macOS 27.0、Xcode 27.0、
Apple M2（Mac14,2，arm64，8 CPU，16 GiB）；build 前 load 为 `1.84 / 2.21 / 2.21`，两版本 build
后、样本开始前为 `8.32 / 4.22 / 2.98`。各样本前后 1-min load 约 `4.83–9.25`，5-min
`4.20–4.70`，15-min `2.98–3.22`；完整逐项快照均在上述 `system/` 目录。

因此这是「无其他 xcodebuild/xctest 并发、但非完全空闲机器」上的受控配对测量；候选与基线交替执行，
配对方向 10/10 一致且显著，但并发非测试进程和 build 后 load 抬升降低了严格隔离性。可信度结论：
本轮有强方向性证据支持改善，仍建议未来在真正空闲机器复测一次作为独立复现，不把本轮表述成无负载实验室基准。

### 12.4 Git 计数口径修正及确定性重复工作

`RefreshEngine.buildDiagnostics` 旧实现曾以 `core + extended` 重新计算并覆盖汇总的
`totalGitCalls`，漏掉 discovery 阶段已执行的 Git 调用；其中包括**每轮 discovery 的一次**
`git worktree list --porcelain -z`。t-0035 `d2e7674` 起 diagnostics 保留 discovery collector 的
调用数。真实主仓库 + linked worktree 的回归测试记录 discovery/core/extended 为 `1/2/2`，独立 ledger
为 `5`，修复后 `totalGitCalls=5` 与 ledger 一致，旧覆盖值为 `4`。因此此前的 Git 总数必须按新口径解释；
端到端脚本本身没有累计 Git spawn，不从耗时推断调用次数。

t-0032 `b1ad2c6` 对 `ScanScheduler.applyPins` 的路径规范化作用域复用有独立确定性测试：20 仓库
`computations 162→20`，lookups 不变，输出语义相同。它是本轮仍成立的确定性重复工作削减证据，不能与
Git 子进程数混为一谈。稳态 snapshot 写入/同步结构计数则遵守旧结论：writes `3→2`、
`F_FULLFSYNC 6→4`，non-identical recovery 仍为 `3/6`（适用 C1 `5cc516f`，非本轮三条分支的新改动）。

### 12.5 当前 Acceptance 判定与仍未关闭的缺口

- **标准 1：成立**——集成候选上的无签名全量验收 exit 0、919 tests / 93 suites、`failedTests=0`；
  新增的两套测试均纳入工程。
- **标准 2：成立**——基线 `7f29c0f` 与测量候选 `b35eebf` 在同机、同脚本、10 组交替配对；完整样本及原始
  输出路径见 §12.2。
- **标准 3：成立**——timer refresh 的端到端 wall clock 在本轮超出噪声改善；RSS / footprint 未证明改善，
  Git spawn 未由本测量主张改善；确定性 `applyPins` 路径规范化计算仍为 `162→20`。
- **标准 4：部分成立（仍有测量缺口）**——全量测试通过且本轮端到端资源指标未显示有意义的反向变化；但
  没有针对所有 RegressionGate 场景作独立同口径 before/after 测量。`continuousManualRefresh` 仍无可运行入口，
  UI 响应、真实用户目录扫描和 Widget reload latency 未测，不声称所有其它关键场景均已排除回退。
- **标准 5：部分成立（全局最高开销仍未穷尽）**——`applyPins` 的路径规范化重复计算和 diagnostics 的 discovery
  调用漏计均有文件/符号与独立计数证据；端到端样本证明总耗时改善，但未对每个 refresh stage 作 profile 排序，
  不宣称已证明所有路径中最高实际耗时已完全定位。

仍未关闭的缺口：真正空闲主机上的独立 e2e 复测；更多仓库规模与用户目录的安装态刷新；CPU/RSS 的刷新进程独占
测量；所有 RegressionGate 场景的统一 before/after 与完整 `checkAll` 实际参数组合；`continuousManualRefresh`、
UI 主线程 stall、Widget reload wall clock，以及刷新阶段最高实际开销的完整排序。