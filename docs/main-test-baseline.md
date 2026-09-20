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

## 成因分类：仅基于原始输出

| 失败 | 分类 | 依据与限制 |
| --- | --- | --- |
| `suspendForSleepCancelsActiveScan()` | 无法判定 | 原始输出只显示 `scheduler.isScanning` 仍为 `true`，且定向重跑两次通过；没有 macOS/Xcode API、签名、沙盒或 App Group 错误与该断言建立因果关系。 |
| `initialStateIsIdle()` | 无法判定 | 原始输出为 `await scheduler.refreshPhase == .idle → <not evaluated>`，未给出相位值或底层错误。测试进程确有其它 `PendingItemStore` 权限日志，但原始输出不能证明它导致此断言。 |
| `schedulerRebuildMigratesLegacyPinsAndSharedSnapshotIdentity()` | 无法判定 | 断言只显示仓库列表为 `[]`。同一测试进程启动时记录了 `PendingItemStore` 的 App Group 写权限错误，但没有该测试直接的权限错误或产品逻辑栈，不能据此归因。 |
| `schedulerRebuildMigratesIgnoredPathsAndRewritesSharedSnapshotScope()` | 无法判定 | 断言显示 `try? AppGroupStore.read().get() → nil`，与 App Group 读写路径相关；但原始文本未给出 `AppGroupStore.read()` 返回失败的具体错误，不能在环境问题和产品逻辑/断言问题之间确定归因。 |
| `ignoringRepositoryImmediatelyFiltersAppAndSharedWidgetSnapshotAndForcesScopedScan()` | 无法判定 | 同上：仅有 `try? AppGroupStore.read().get() → nil`，无具体读失败原因。 |
| `repositoryRetryAfterBackupRecoveryCommitsAWidgetReadableSnapshot()` | 无法判定 | `await waitForSnapshotWrite() → nil` 表示等待未得到快照写入；原始输出没有写入失败、API 变化或权限错误与该等待建立因果关系。 |

作为环境线索（**不是因果结论**），两次失败的定向类测试均在运行时输出：

```text
[PendingItemStore] pending items read failed: The file “pending-items.json” couldn’t be opened because you don’t have permission to view it.
[PendingItemStore] failed to replace corrupt pending items file: 待处理事项写入失败：staging: You don’t have permission to save the file “.pending-items.tmp-…” in the folder “group.local.devpulse”.
```

要把任一“无法判定”分类为环境或产品逻辑，需要该失败点的可关联底层错误、测试隔离存储的配置/权限证据，或修复前后的最小复现证据；本基线不做此推断。

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
