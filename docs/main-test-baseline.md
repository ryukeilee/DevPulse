# main 测试失败基线（HEAD `7f29c0f`）

> 用途：此文档记录未修改的 `main` 在指定机器上的失败集合。性能改动分支用它区分既有失败与新增失败；它不是修复说明，也不表示这些失败可接受。

## 测量环境与源码

| 项目 | 值 |
| --- | --- |
| 分支 | `hp/devpulse/t-0008-main` |
| 提交 | `7f29c0f24266fc3014c363671b2aeca8fdafee6c` |
| macOS | `27.0 (26A428)` |
| Xcode | `27.0 (27A266a)` |
| 机型 / 架构 | `Mac14,2` / `arm64` |
| DerivedData | `/tmp/devpulse-build-t-0008` |

环境由以下命令取得：

```sh
sw_vers
xcodebuild -version
sysctl -n hw.model
uname -m
git branch --show-current
git log -1 --format='%H%n%s'
```

## 全量验证

执行时间：2026-09-20 22:08:53 至 22:09:50 +0800。

```sh
DERIVED_DATA_PATH=/tmp/devpulse-build-t-0008 ./scripts/verify.sh final
```

退出码：`1`。构建输出为 `[verify] Build succeeded`；全量测试原始汇总如下：

```text
✘ Test run with 893 tests in 89 suites failed after 48.737 seconds with 6 issues.
```

完整失败清单与原始断言/错误文本：

1. `SleepWakeLifecycleTests.suspendForSleepCancelsActiveScan()`

   ```text
   ✘ Test "suspendForSleep cancels active scan task" recorded an issue at LifecycleSleepWakeTests.swift:199:9: Expectation failed: scheduler.isScanning == false
   ↳ Scan should be cancelled after sleep
   ↳ scheduler.isScanning == false → false
   ↳   scheduler.isScanning → true
   ✘ Test "suspendForSleep cancels active scan task" failed after 0.103 seconds with 1 issue.
   ```

2. `RefreshCompletionTests.initialStateIsIdle()`

   ```text
   ✘ Test "Refresh state is idle after initialization" recorded an issue at RefreshCompletionTests.swift:72:9: Expectation failed: await scheduler.refreshPhase == .idle
   ↳ await scheduler.refreshPhase == .idle → <not evaluated>
   ✘ Test "Refresh state is idle after initialization" failed after 0.006 seconds with 1 issue.
   ```

3. `RepositoryDiscoveryExperienceTests.schedulerRebuildMigratesLegacyPinsAndSharedSnapshotIdentity()`

   ```text
   ✘ Test schedulerRebuildMigratesLegacyPinsAndSharedSnapshotIdentity() recorded an issue at RepositoryDiscoveryExperienceTests.swift:139:28: Expectation failed: scheduler.lastResult.repositories.first
   ↳ scheduler.lastResult.repositories.first → nil
   ↳   scheduler.lastResult.repositories → []
   ↳   first → nil
   ✘ Test schedulerRebuildMigratesLegacyPinsAndSharedSnapshotIdentity() failed after 0.006 seconds with 1 issue.
   ```

4. `RepositoryDiscoveryExperienceTests.schedulerRebuildMigratesIgnoredPathsAndRewritesSharedSnapshotScope()`

   ```text
   ✘ Test schedulerRebuildMigratesIgnoredPathsAndRewritesSharedSnapshotScope() recorded an issue at RepositoryDiscoveryExperienceTests.swift:227:29: Expectation failed: try? AppGroupStore.read().get()
   ↳ try? AppGroupStore.read().get() → nil
   ✘ Test schedulerRebuildMigratesIgnoredPathsAndRewritesSharedSnapshotScope() failed after 0.006 seconds with 1 issue.
   ```

5. `RepositoryDiscoveryExperienceTests.ignoringRepositoryImmediatelyFiltersAppAndSharedWidgetSnapshotAndForcesScopedScan()`

   ```text
   ✘ Test ignoringRepositoryImmediatelyFiltersAppAndSharedWidgetSnapshotAndForcesScopedScan() recorded an issue at RepositoryDiscoveryExperienceTests.swift:351:26: Expectation failed: try? AppGroupStore.read().get()
   ↳ try? AppGroupStore.read().get() → nil
   ✘ Test ignoringRepositoryImmediatelyFiltersAppAndSharedWidgetSnapshotAndForcesScopedScan() failed after 0.014 seconds with 1 issue.
   ```

6. `RepositoryDiscoveryExperienceTests.repositoryRetryAfterBackupRecoveryCommitsAWidgetReadableSnapshot()`

   ```text
   ✘ Test repositoryRetryAfterBackupRecoveryCommitsAWidgetReadableSnapshot() recorded an issue at RepositoryDiscoveryExperienceTests.swift:921:29: Expectation failed: await waitForSnapshotWrite()
   ↳ await waitForSnapshotWrite() → nil
   ✘ Test repositoryRetryAfterBackupRecoveryCommitsAWidgetReadableSnapshot() failed after 3.017 seconds with 1 issue.
   ```

全量入口最后列出的失败名称与上述六项一致：

```text
Failing tests:
	SleepWakeLifecycleTests.suspendForSleepCancelsActiveScan()
	RefreshCompletionTests.initialStateIsIdle()
	RepositoryDiscoveryExperienceTests.schedulerRebuildMigratesLegacyPinsAndSharedSnapshotIdentity()
	RepositoryDiscoveryExperienceTests.schedulerRebuildMigratesIgnoredPathsAndRewritesSharedSnapshotScope()
	RepositoryDiscoveryExperienceTests.ignoringRepositoryImmediatelyFiltersAppAndSharedWidgetSnapshotAndForcesScopedScan()
	RepositoryDiscoveryExperienceTests.repositoryRetryAfterBackupRecoveryCommitsAWidgetReadableSnapshot()
```

## 确定性重跑

所有重跑均复用上节已经构建的同一个 DerivedData，未再编译：

```sh
DERIVED_DATA_PATH=/tmp/devpulse-build-t-0008 ./scripts/verify.sh test DevPulseTests/SleepWakeLifecycleTests
DERIVED_DATA_PATH=/tmp/devpulse-build-t-0008 ./scripts/verify.sh test DevPulseTests/SleepWakeLifecycleTests
DERIVED_DATA_PATH=/tmp/devpulse-build-t-0008 ./scripts/verify.sh test DevPulseTests/RefreshCompletionTests
DERIVED_DATA_PATH=/tmp/devpulse-build-t-0008 ./scripts/verify.sh test DevPulseTests/RefreshCompletionTests
DERIVED_DATA_PATH=/tmp/devpulse-build-t-0008 ./scripts/verify.sh test DevPulseTests/RepositoryDiscoveryExperienceTests
DERIVED_DATA_PATH=/tmp/devpulse-build-t-0008 ./scripts/verify.sh test DevPulseTests/RepositoryDiscoveryExperienceTests
```

| 测试类 | 第 1 次 | 第 2 次 | 结论 |
| --- | --- | --- | --- |
| `SleepWakeLifecycleTests` | 退出码 `0`，`[verify] tests passed` | 退出码 `0`，`[verify] tests passed` | `suspendForSleepCancelsActiveScan()` 在全量中失败一次、定向两次均通过；3 次观测为 **失败 1 / 通过 2**，属于 flaky。 |
| `RefreshCompletionTests` | 退出码 `1`；13 tests / 1 suite / 1 issue，唯一失败为 `initialStateIsIdle()` | 退出码 `1`；13 tests / 1 suite / 1 issue，唯一失败相同 | 3 次观测均失败，当前机器上确定复现。 |
| `RepositoryDiscoveryExperienceTests` | 退出码 `1`；34 tests / 1 suite / 4 issues，失败集合为上述第 3–6 项 | 退出码 `1`；34 tests / 1 suite / 4 issues，失败集合相同 | 四项在全量及两次定向中均失败，当前机器上确定复现。 |

两次 `RefreshCompletionTests` 重跑的原始汇总均为：

```text
✘ Test run with 13 tests in 1 suite failed after 0.274 seconds with 1 issue.
✘ Test run with 13 tests in 1 suite failed after 0.255 seconds with 1 issue.
```

两次 `RepositoryDiscoveryExperienceTests` 重跑的原始汇总均为：

```text
✘ Test run with 34 tests in 1 suite failed after 4.809 seconds with 4 issues.
✘ Test run with 34 tests in 1 suite failed after 4.798 seconds with 4 issues.
```

每次重跑中失败项的断言文本与“全量验证”章节逐字相同（耗时除外）。

## 成因分类：已由机制隔离实验证实

证据出处：t-0010 报告及其原始日志目录 `.herdr-project/devpulse-t-0010/library/logs/`（`unsigned-*.log`、`signed-*.log`、`main-signed-*.log`、`codesign-entitlements-both.txt`、`agprobe-evidence.txt`、`signing-identity-evidence.txt`）。

**5 项稳定失败是无签名测试环境假象，不是产品缺陷：** `scripts/verify.sh` 的 `COMMON_ARGS` 硬编码 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`，使 test host 没有 entitlement。经 LaunchServices 启动的 app bundle 没有 `com.apple.security.application-groups` 时，`group.local.devpulse` 路径仍可解析但读写被拒；机制探针显示同一 bundle 未签名被拒、仅加该 entitlement 即成功，错误文本与测试日志逐字相同。签名后以下 5 项在工作区定向测试 2/2、pristine main 定向测试 2/2 均通过，权限错误计数降为 0：

- `RefreshCompletionTests.initialStateIsIdle()`
- `RepositoryDiscoveryExperienceTests.schedulerRebuildMigratesLegacyPinsAndSharedSnapshotIdentity()`
- `RepositoryDiscoveryExperienceTests.schedulerRebuildMigratesIgnoredPathsAndRewritesSharedSnapshotScope()`
- `RepositoryDiscoveryExperienceTests.ignoringRepositoryImmediatelyFiltersAppAndSharedWidgetSnapshotAndForcesScopedScan()`
- `RepositoryDiscoveryExperienceTests.repositoryRetryAfterBackupRecoveryCommitsAWidgetReadableSnapshot()`

**1 项是 main 上真实既有的时序 flake，与签名无关：** `SleepWakeLifecycleTests.suspendForSleepCancelsActiveScan()`。无签名与签名定向均失败；签名全量 3 次为 1 次通过 / 2 次失败。测试 `LifecycleSleepWakeTests.swift:186-198` 用固定 `Task.sleep(100ms)` 等待取消传播。

因此，`./scripts/verify.sh final` 在不修改仓库文件的前提下无法稳定达到退出码 0：两个独立阻塞分别是上述 5 项无签名失败与 SleepWake flake。仅删掉两个 signing override 会直接构建失败（`has entitlements that require signing with a development certificate`）；启用签名必须显式提供 team + profile。

本机签名证据为 identity `Apple Development: ryukei_li@hotmail.com`、team `JYL9G28DP3`；`security find-identity` 括号中的 `5BJ9GM7VZR` 不是 team ID（详见 `signing-identity-evidence.txt`）。本机 profile 于 2026-09-22 到期。

### 可选改法（未实施，属构建/产品决策）

- **A 环境侧签名（最小）**：测试入口使用开发签名，依赖 team/profile；本机 profile 2026-09-22 到期。
- **B 测试隔离 App Group（更稳）**：将测试改为注入临时目录，与真实 App Group 容器解耦；改动较大。
- **C 修复时序竞态（必须配套）**：修复 SleepWake 测试固定 100ms 等待，改为确定性的取消完成信号；否则任何配置下都不能稳定 exit 0。

### 可直接复制的复现命令

```sh
cd /Users/ryukeili/.herdr/worktrees/DevPulse/hp-devpulse-t-0010-vs
DERIVED_DATA_PATH=/tmp/devpulse-build-t-0010-unsigned ./scripts/verify.sh final
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/devpulse-build-t-0010-signed DEVELOPMENT_TEAM=JYL9G28DP3 -allowProvisioningUpdates build-for-testing
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/devpulse-build-t-0010-signed DEVELOPMENT_TEAM=JYL9G28DP3 -only-testing:DevPulseTests/RepositoryDiscoveryExperienceTests test-without-building
rm -rf /tmp/devpulse-main-t0010 && git clone --local --no-hardlinks /Users/ryukeili/GitHub/DevPulse /tmp/devpulse-main-t0010 && cd /tmp/devpulse-main-t0010 && git checkout 7f29c0f
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/devpulse-build-t-0010-main-signed DEVELOPMENT_TEAM=JYL9G28DP3 -allowProvisioningUpdates build-for-testing
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/devpulse-build-t-0010-main-signed DEVELOPMENT_TEAM=JYL9G28DP3 test-without-building
```

## 与性能改动区域的重叠

性能改动关注区域为：共享快照 `SharedSnapshotStore` / App Group 写入、`RepositoryHistoryStore` 历史归档、discovery/pin 迁移。

| 失败 | 重叠关系 | 对“无新增失败”判定的影响 |
| --- | --- | --- |
| `suspendForSleepCancelsActiveScan()` | 未从测试名或原始断言看到共享快照、App Group、历史归档或 discovery/pin 迁移。 | 可独立比较；但它是 flaky，不能以单次通过/失败判定回归。 |
| `initialStateIsIdle()` | 未从测试名或原始断言直接看到四个区域；只涉及 scheduler 初始 `refreshPhase`。 | 暂按不直接重叠处理；仍须比较其原始断言，因为刷新调度改动可能间接影响它。 |
| `schedulerRebuildMigratesLegacyPinsAndSharedSnapshotIdentity()` | **直接重叠** discovery/pin 迁移和共享快照身份。 | 不能仅因同名失败就认定性能分支无回归；需比较完整断言，并以定向/隔离存储证据区分。 |
| `schedulerRebuildMigratesIgnoredPathsAndRewritesSharedSnapshotScope()` | **直接重叠** discovery 范围迁移及共享快照/App Group 读写。 | 同上，高风险重叠。 |
| `ignoringRepositoryImmediatelyFiltersAppAndSharedWidgetSnapshotAndForcesScopedScan()` | **直接重叠** discovery 范围、共享快照/App Group 与 Widget 快照。 | 同上，高风险重叠。 |
| `repositoryRetryAfterBackupRecoveryCommitsAWidgetReadableSnapshot()` | **直接重叠** 共享快照/App Group 写入与 recovery；未从名称/断言显示历史归档或 pin 迁移。 | 同上，高风险重叠。 |

六项中没有一项的失败名称或原始断言直接涉及 `RepositoryHistoryStore`；不得把同一进程中其它测试输出的历史归档权限日志当作这些六项的成因。

## 分支比较步骤（判定“无新增失败”）

1. 在待比较分支、同一机器上使用新的独立目录运行：

   ```sh
   DERIVED_DATA_PATH=/tmp/devpulse-build-<branch> ./scripts/verify.sh final
   ```

2. 保存完整测试日志，记录退出码、tests/suites/issues 总数、所有失败测试全名和每项原始断言文本。
3. 失败集合只能是本文件列出的六个名称；任何额外测试名、构建失败、超时或不同的原始错误文本均为**新增失败/需调查**。
4. 对 `RefreshCompletionTests` 和 `RepositoryDiscoveryExperienceTests` 各重跑两次。基线期望分别稳定为 `1 issue`（`initialStateIsIdle()`）与 `4 issues`（上表第 3–6 项）；减少或消失也应记录，不能隐去。
5. 对 `SleepWakeLifecycleTests` 重跑至少两次。此项基线为 3 次观测失败 1 / 通过 2；单次结果不构成新增失败证据。若出现不同断言、同类中其他失败，或多轮失败率明显变化，应标记为需调查。
6. 对四个直接重叠的 discovery/共享快照失败，除文本比对外，应保留隔离存储或相应定向测试的原始证据；不能把它们笼统扣除后宣称“无新增失败”。

## 限制

- 本次只记录基线，不修改生产 Swift、测试、`project.yml` 或 `.xcodeproj`。
- 同机同时存在并行构建/基准任务；本次全程使用指定的独立 DerivedData。未观察到构建异常，因此未因并发重试全量构建。
- 原始测试日志由 `verify.sh` 写入系统临时目录；本文保留了完整失败项的原始断言文本和可复现命令，作为长期可引用证据。

## 当前 main 基线修订（`eb41ba0`）

上面的历史记录基于 `7f29c0f`（893 tests / 89 suites），未包含随后合入的性能基准测试。当前集成起点 `eb41ba0` 的已知失败集合为 **7 项**（899 tests / 89 suites）：上文列出的 6 项，加上：

- `LifecyclePerformanceTests.steadyStateCommitBenchmark()`

该项的原始失败断言为 `Optimized median did not exceed the baseline noise band.`，对应断言表达式 `optimizedSummary.median < baselineSummary.median - baselineSummary.mad`；它与签名环境无关，属于性能基准时序波动。终局集成使用 signed 入口后，`verify.sh final` 两次均为退出码 `0`；裸 `xcodebuild test-without-building` 原始输出为 **905 tests / 90 suites passed**，因此终局分支没有保留上述已知失败。
