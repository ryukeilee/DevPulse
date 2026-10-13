# 共享快照 commit 的目录屏障合并（2026-10-14）

本轮针对「完整扫描后的快照生成 → JSON 编解码 → 持久化 → Widget 同步」链路，只做一项改动：
消除 `SharedSnapshotStore` 提交尾部一次**冗余的目录耐久屏障**，使每次刷新快照写入少一次
`F_FULLFSYNC`。不改扫描结果、快照格式、recovery 语义、跨进程并发语义，也不新增缓存或抽象。

## 1. 定位过程（时间花在哪里）

真实生产路径（`ScanScheduler.syncSharedSnapshot` → `AppGroupStore.write` →
`SharedSnapshotStore.commit`）在 timer 刷新里每轮执行 **2–3 次完整 commit**
（`refresh-start` 置 `isRefreshing`、扫描结束同步、pending-items 变化时再同步）。E2E 探针
（4 仓库、约 7 KB 快照）显示单次 `snapshot_commit_and_verify` 中位数 33.7 ms，占
`scheduler_wall_ms` 约 130 ms 的四分之一，是扫描之外最大的单项。

把 commit 拆到原语级（`scripts/benchmark-snapshot-persistence.sh` 的 `io_*` 阶段，Release
`-O`，同一 APFS 卷）：

| 原语 | 8 仓库 (14.5 KB) | 60 仓库 (84 KB) | 240 仓库 (307 KB) |
| --- | ---: | ---: | ---: |
| payload 写入 + 文件 `F_FULLFSYNC` | 3.05 ms | ~5.5 ms | ~7.0 ms |
| rename + 目录 `F_FULLFSYNC` | ~3.9 ms | ~3.1 ms | ~2.7 ms |
| 目录 `F_FULLFSYNC`（无待刷元数据） | 0.04 ms | 0.04 ms | 0.04 ms |
| `json_decode_full`（含编码） | 0.47 ms | 1.49 ms | 5.6 ms |

结论：**目录屏障本身便宜，贵的是它真正冲刷 rename 元数据的那一次**。稳态 commit 由
`staging atomicWrite` + `backup atomicWrite` 组成，因此每轮写入了两份 payload，并冲刷了两次
目录（4 次 `F_FULLFSYNC`）。其中提交点之前的 recovery copy 写入是必需的（提交点必须已有
durable、已验证的 fallback）；**提交点之后把 recovery copy 推进到本代的那个 rename，不需要
自己的屏障**。

## 2. 改动

`DevPulseNative/Core/SharedSnapshotStore.swift`（+66 / −7）：

1. `atomicWrite(_:to:synchronizingDirectory:)` 新增屏障开关，默认 `true`。提交点之前的写入
   （`prepareRecoveryCopy` 的四个 plan）保持默认值，语义不变。
2. `refreshRecoveryCopyAfterCommit` 改为 `synchronizingDirectory: false`：本代 recovery copy
   仍然先 `synchronizeFile` 落盘，再 rename 就位，只是不再为这次 rename 单独开一个目录屏障。
3. `synchronizeDirectoryBestEffort()` 返回 `Bool`（提交点屏障是否成功），并在失败时记一条
   warning。**若提交点屏障失败，recovery 推进自动改回带屏障的路径**，把这次改动去掉的
   「第二次耐久机会」原样还回去。
4. 新增故障注入 phase `beforePrimaryBarrier`，用于确定性验证第 3 点。

于是稳态 commit 的耐久操作由 `2 写 + 4 屏障` 变为 `2 写 + 3 屏障`；非 identical recovery
copy 对照路径由 `3 写 + 6 屏障` 变为 `3 写 + 5 屏障`。

### 2.1 为什么少这一次屏障是安全的

- **recovery copy 不可能比 primary 新。** recovery rename 严格排在提交点 rename 及其目录
  屏障之后，两次 rename 之间不存在任何屏障。任何能让 recovery rename 变持久的屏障本身都排在
  提交点 rename 之后（必然同时冲刷它）；而 `primary → barrier → recovery` 之间没有屏障，所以
  recovery rename 无法被单独冲刷。崩溃后持久态只可能是
  `(primary=N, backup=N)` 或 `(primary=N, backup=N-1)`，两者都完整可读。
- **提交点仍然有 fallback。** 本轮崩溃窗口里最老的 durable recovery copy 仍然有效，因为
  `prepareRecoveryCopy` 在提交点之前已按 plan 保证了一份 durable、已验证的副本（`primary`
  缺失时走 `.preserveExistingBackup`，会同时同步文件与目录，从不在本次省略的屏障上打滑）。
- **提交点本身没有变弱。** 提交点 rename 之后的目录屏障仍然执行（成功时只执行一次即足够），
  失败时由 recovery 推进补上一次。
- **判定依据是确定性计数，不是时序推断。** ledger 与内容指纹都在测试中固定（见 §3）。

独立只读审查（子代理，只读、未运行构建）共两轮：第一轮未能证伪上述 1/2/4 条，给出上述「更强」
的排序论证，并指出第 3 条的初始版本（无条件省略）会让提交点从「两次屏障机会」降为「一次且错误
被 `try?` 吞掉」。该发现已由第 3 点的条件回退修复并新增定向测试；第二轮逐路径复核后确认：
第二次机会在所有生产可达路径上恢复（唯二没有第二次屏障的路径改动前同样没有，且其中一条只有
注入器可达），新增 phase 不影响任何既有分支，日志量在持久故障下约每 5 分钟数行。第二轮同时
指出手工证据端的两处弱点——门禁只做「两版之间」比较、失败路径测试单独看不足以钉住「条件性」
——两者均已修正（门禁增加逐变体断言并已用合成输入验证；失败路径测试改为在同一测试内同时断言
失败与成功两种顺序）。

## 3. 行为等价证据

`scripts/benchmark-snapshot-persistence.sh` 现在把等价性做成**退出码门禁**，不再是人工目视：

- **内容指纹**：33 个 `(stage, 仓库数)` 组合的 canonical 指纹（对 payload 做与磁盘格式无关的
  确定性重编码后取 SHA-256 前 16 位）在两版之间**逐字相同**。基线/候选的指纹对例如
  `ced3c4ef/ced3c4ef`、`ca8c468a/ca8c468a`、`e6d2d8ea/e6d2d8ea`。
- **recovery 不变式（逐变体）**：每个以 commit 结尾的阶段（`load_*` / `read_*` / `commit_*`，共 10 个
  组合）结束后 `primary == backup` 字节相等，**两个变体各自**都必须为真；若两版同样损坏也会被拒。
- 输出末行 `equivalence=identical stages=22 recovery_invariant_stages=10 runs=2 fingerprints=matched
  recovery_copy=identical`，任一指纹或不变式不一致即以非零退出并打印 `EQUIVALENCE MISMATCH`。
  门禁本身已用合成输入验证：健康输入退出 0；两版“同样损坏”（两侧
  `recovery_copy_identical=0`）退出 1；指纹不同退出 1。
- 生产链路 E2E 采样脚本自带的 `refresh_result_equivalent=yes` 与两侧相同的
  `refresh_result_signature` 一并成立。

测试侧固定同一不变式：`SharedSnapshotStoreTests.steadyStateCommitEndsWithoutASecondDirectoryBarrier()`
断言稳态 commit 只有一个 `.fullDirectorySync`、最后一次操作是 `.fullFileSync`（即 recovery
rename 之后没有屏障），并断言 commit 后 `primary == backup`；
`failedCommitPointBarrierKeepsASecondDurabilityChance()` 断言屏障失败时 commit 仍返回成功、
仍然只有一个 `.fullDirectorySync`，但它落在那次 recovery rename **之后**。

## 4. A/B 数据

### 4.1 独立 Release 基准（`swiftc -O -whole-module-optimization`）

`./scripts/benchmark-snapshot-persistence.sh --baseline-git 9ca8173`（5 轮交替、每轮 21 次采样
取中位数、再取轮间中位数；基线与候选使用同一套编译参数）：

| 阶段 | 8 仓库 | 60 仓库 | 240 仓库 |
| --- | ---: | ---: | ---: |
| `commit_only`（稳态 commit） | **−23.1%** (16.19→12.46 ms) | **−20.6%** (21.36→16.95 ms) | −3.2% (24.55→23.77 ms) |
| `read_then_commit`（生产序列：读 revision + commit） | **−23.3%** (16.70→12.81 ms) | **−11.6%** (20.05→17.72 ms) | −6.2% (28.63→26.87 ms) |
| `commit_divergent_recovery_copy` | −11.8% | −8.7% | −11.9% |
| `commit_after_primary_loss` | −17.9% | −17.2% | −10.1% |
| `load_steady` / `json_*` / `io_*`（应不受影响） | −2.3%…+10.8%（噪声，无一致方向） | 同 | 同 |

240 仓库时收益被 JSON 编解码 CPU 摊薄，这是预期结果：该规模下 CPU（约 13 ms）已接近 I/O。
CPU 列两版一致（如 `commit_only` 240 仓库 13.28 → 12.95 ms），说明收益来自等待而非计算。

### 4.2 仓库自带 commit 基准（`LifecyclePerformanceTests`，Debug 构建）

该测试在**同一实现内**比较稳态快路径与 divergent recovery copy 路径，不是本次改动的前后对比，
因此只用于交叉印证屏障成本的量级；改动方向由其中的 ledger 断言钉住（已更新为
`redundant_full_syncs=5` / `optimized_full_syncs=3`）。在提交后的修订上复跑：

| 仓库数 | divergent（3 写/5 屏障） | 稳态（2 写/3 屏障） | 配对中位差 | 更快配对 |
| ---: | ---: | ---: | ---: | ---: |
| 5 | 23.398 ms | 15.789 ms | 7.486 ms | 29/30 |
| 50 | 33.555 ms | 21.850 ms | 11.173 ms | 30/30 |

差值落在 §4.1 原语级估计的「一次目录屏障 + 一次 payload 写入」量级内。

### 4.3 真实生产链路 E2E（`scripts/measure-end-to-end-refresh.sh`）

`BASELINE_REV=9ca8173`（= 当前 HEAD，因此两版差异仅为本轮改动），4 仓库合成增量刷新，
每配对交替先跑哪一版：

| 组 | 配对数 | 基线 `snapshot_commit_and_verify` | 候选 | 变化 |
| --- | ---: | ---: | ---: | ---: |
| A | 7 | 33.730 ms | 25.770 ms | **−23.6%** |
| B | 15 | 33.733 ms | 27.776 ms | **−17.7%** |

两组独立采样方向一致；`refresh_result_equivalent=yes` 两组均成立。

**总刷新耗时没有可报告的改善**：`scheduler_wall_ms` 配对中位差 +0.6 ms（15 对，paired MAD
8.7 ms，sign p=1.00），`elapsed_improvement_beyond_noise=no`。原因是该窗口内 git 子进程耗时
波动约 ±10 ms 量级（本轮候选侧 `coreStatusGitRunner_sum_ms` 中位数反而高 24 ms），而目标阶段
只占其中约 6 ms。**不主张端到端总耗时改善**，只主张目标阶段的确定性改善。

## 5. 验证

实际执行：

- `./scripts/verify.sh build`：通过。
- 定向套件：`SharedSnapshotStoreTests`(31)、`SnapshotStoreRecoveryTests`(9)、
  `LifecyclePerformanceTests`、`CrossProcessConcurrencyTests`、`CrossProcessPipelineTests`
  合计 69 tests / 5 suites 通过。
- Widget / 生命周期：`WidgetDegradedRenderingTests`、`WidgetLifecycleScenariosTests`、
  `DataFreshnessStateTests`（68 tests / 3 suites）与 `StartupDiagnosticsTests`、
  `LifecycleCoordinatorTests`、`CoordinatorAdvancedTests`、`RefreshEngineIntegrationTests` 通过。
  `RefreshCompletionTests.initialStateIsIdle()` 失败与 `docs/main-test-baseline.md` 记录的
  无签名环境既有假象一致（同一断言、同一行）。
- `./scripts/verify.sh final`：982 tests / 96 suites passed；`./scripts/verify.sh widgetkit`：16 PASS / 0 FAIL。
- `./scripts/verify-activity-timeline.sh`：passed。
- `./scripts/benchmark-snapshot-persistence.sh --baseline-git 9ca8173`：`equivalence=identical`，退出码 0。
- `BASELINE_REV=9ca8173 RUNS=15 ./scripts/measure-end-to-end-refresh.sh`：退出码 0，结果签名一致。
- `./scripts/secret-scan.sh staged`：通过。

顺带修复验证脚本可用性：`scripts/measure-end-to-end-refresh.sh` 在 `BASELINE_REV` 与当前
版本无差异（即比较与扫描器无关的改动，例如本轮的持久化层）时，`git diff | git apply` 会因空
补丁报 `No valid patches in input` 而中断；现在改为空差异时跳过注入。

## 6. 已测量但本轮未做的冗余（留给后续）

按实测收益排序，均需要更大的语义取舍，本轮不做：

1. **每轮刷新不必要的第二次完整 commit。** `refresh-start` 只把 `isRefreshing` 置真，却重写了
   整份 payload（每轮约 12–34 ms）。把它移出快照文件需要改动共享数据契约与 Widget 读取路径，
   影响 Widget 新鲜度语义。
2. **recovery copy 的重复 payload 写入。** 同一份字节一轮写两遍（staging 与 backup）。消除它
   只能靠 hard link / `clonefile` 共享 inode，而两者都会削弱「primary 介质损坏时 backup 仍完整」
   这一冗余——现有测试正是用原地覆盖 primary 来验证该冗余。已否决。
3. **大 payload 下的解码/校验重复。** 240–600 仓库时 commit CPU 由 6 次 JSON 解析 + 3 次
   `validatePersistedSnapshot` 主导（600 仓库约 29 ms）。去掉 staging 回读解码可省约 2.5 ms/千字节
   级，但那是提交前的安全网，不属于冗余。
4. **一次 `load()` 解析同一缓冲区 3 遍**（version header / metadata header / payload）。
   实测额外两遍很便宜（8 仓库 0.007 ms、240 仓库约 0.6 ms），不值得改动。

## 7. 剩余风险与未验证

- 未在真实掉电条件下验证 APFS 目录 `F_FULLFSYNC` 的取舍顺序。§2.1 的排序论证依赖「目录屏障
  覆盖该目录内全部 pending 元数据」，属代码级论证 + 确定性 ledger 证据，不是掉电实测。
- 提交点屏障失败时的「第二次机会」只有定向注入测试覆盖（`beforePrimaryBarrier`）；真实
  `open`/`fcntl` 失败路径未能构造。
- 未安装或改动用户正在运行的 App，未验证桌面上已注册 Widget 的实际唤起与呈现时延。
- 性能数字来自本机隔离合成 Git 仓库与临时目录（同一 APFS 卷），不能外推为所有用户仓库的收益；
  240 仓库以上的收益显著小于小规模场景。
