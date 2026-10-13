# 仓库身份摘要编码与扫描后派生链性能验证

本轮只改仓库身份 ID 的摘要编码。`RepositoryIdentity.id(for:)` 之前用
`digest.map { String(format: "%02x", $0) }.joined()` 把 SHA-256 摘要写成十六进制，
即每个摘要字节重新进入一次 C varargs 格式化器。该函数在扫描与扫描后的派生链里
按仓库、按派生重复调用，是这条链上最大的单项开销。

## 调用路径与实测定位

扫描完成后，`ScanScheduler` 会对同一份扫描结果重复派生：

| 调用点 | 位置 | 说明 |
|---|---|---|
| 完成时 `applyPins(result.data)` | `ScanScheduler.swift`（`scheduler_apply_pins`） | 刷新结果落到 `lastResult` |
| 写入前 `applyPins(snapshot)` | `syncSharedSnapshot`（`snapshot_prepare_apply_pins`） | 提交共享快照前的最终形态 |
| 回读后 `applyPins(readBack)` | `handleSyncSnapshotSuccess` | 提交成功后重建内存态 |
| Widget 可读快照过滤 | `setWidgetReadableSnapshot` | `RepositoryScope.filtering` |

每次 `applyPins` 都是
`RepositoryScope.filtering` → `RepositoryIdentityMigration.migrate` → 置 `isPinned` → `RepositorySorter.sort`，
而 `filtering`/`migrate`/`normalize` 内部都按仓库调用
`RepositoryIdentity.id(for:)`（`normalize` 一次、`migrate` 两到三次、`filtering` 的
活动事件过滤再算一次集合）。

在 M2 / macOS 27.0.1 / Apple Swift 6.4 上，1,200 个仓库、canonical path 已在
refresh scope 内解析完的稳态下测得：

```text
id_current_ms=34.9824 per_call_us=29.152      ← 改动前的 id(for:)
sha256_data_only_ms=0.4593 per_call_us=0.383  ← 仅 SHA256 本体
hex_string_format_ms=35.7103 per_call_us=29.759 ← 仅 String(format:) 十六进制编码
hex_table_ms=1.2091 per_call_us=1.008         ← 数字表编码
```

即单次 `id(for:)` 的 29.15 µs 里有 29.76 µs（>97%）花在逐字节 `String(format:)`
上；SHA-256 本体只占 0.38 µs。按每个仓库每次派生 4~5 次 `id` 调用、每轮刷新 4 次
派生计算，1,200 仓库规模下这条链在这一个函数上就要花费数百毫秒。

## 改动

`DevPulseNative/Core/Models.swift` 增加 `RepositoryIdentity.hexDigest(_:)`，用
16 项数字表把摘要写成小写十六进制，`id(for:)` 改为 `prefix + hexDigest(digest)`。
没有新增缓存、没有改 `canonicalPath`、没有改任何调用点、没有改快照格式。

## 等价性边界

`id(for:)` 的输出是持久化字段：共享快照里的 `repository.id`、pin 键、工作区成员、
活动/历史档案、备份数据都引用它。编码必须逐字节保持，因此改动的等价性按三层验证：

1. **逐字节穷举**：0–255 每个字节值与 `String(format: "%02x", byte)` 完全一致（0 处不一致）。
2. **摘要级差分**：0–599 共 600 个长度的字节序列，其 SHA-256 摘要编码与参考实现逐字节一致。
3. **生产路径差分**：4,200 条路径输入（空串、空白、`~` 展开、`..`、尾随分隔符、大小写、
   不存在路径、非 ASCII）先经生产的 `RepositoryIdentity.canonicalPath`，再比
   `id(for:)` 与参考实现：0 处不一致；同时断言这些摘要覆盖了全部 256 个字节值，
   否则上一条比较可能因样本不足而假通过。

测试固化在 `DevPulseNativeTests/RepositoryPathCanonicalizationReuseTests.swift`，
参考实现（改动前的 `String(format:)` 写法）作为独立 oracle 保留在测试内：

```text
canonicalization_identity_encoding inputs=4200 distinct_digest_bytes=256 mismatches=0
canonicalization_identity_byte_table digests=56 distinct_digest_bytes=256 mismatches=0
```

（`digests=56` 表示 56 个摘要即覆盖全部 256 个字节值，测试在覆盖完成后即可停止。）

## A/B 数据

基线：`a17ba9e`（本轮改动前的 `HEAD`）。命令：

```sh
./scripts/benchmark-repository-identity.sh --baseline-git a17ba9e
```

脚本用同一个 `swiftc -O -whole-module-optimization -swift-version 6` 编译基线与当前
源码，交替运行 3 轮（每轮 15 次迭代、3 次预热），取每轮中位数的中位数。每个阶段都对
**该阶段的真实输出**计算 SHA-256 指纹：仓库 ID 序列、过滤后的快照、迁移后的快照、
整套派生结果。测量时无并发 xcodebuild/xctest；机器 load average 1.61–1.87，基线/当前
交替顺序，因此负载漂移对两侧同等作用。

| 阶段（1,200 仓库） | 基线 | 当前 | 加速 |
|---|---:|---:|---:|
| `identity_sweep_scoped`（canonical path 已解析，稳态 id 计算） | 33.44 ms | 0.91 ms | **36.7×** |
| `identity_migration`（`RepositoryIdentityMigration.migrate`） | 105.99 ms | 34.95 ms | 3.03× |
| `scope_filtering`（`RepositoryScope.filtering`） | 69.00 ms | 33.83 ms | 2.04× |
| `post_scan_derivations`（一轮刷新的 4 次派生之和） | 514.17 ms | 174.23 ms | **2.95×（−339.94 ms/轮）** |
| `identity_sweep_unscoped`（每次调用重新解析 canonical path，未改动语义） | 65.92 ms | 31.33 ms | 2.10× |

| 阶段（100 仓库） | 基线 | 当前 | 加速 |
|---|---:|---:|---:|
| `identity_sweep_scoped` | 2.795 ms | 0.081 ms | 34.4× |
| `identity_migration` | 8.792 ms | 2.934 ms | 3.00× |
| `scope_filtering` | 5.741 ms | 2.819 ms | 2.04× |
| `post_scan_derivations` | 42.233 ms | 14.097 ms | 3.00×（−28.14 ms/轮） |
| `identity_sweep_unscoped` | 5.500 ms | 2.612 ms | 2.11× |

| 阶段（4 仓库） | 基线 | 当前 | 加速 |
|---|---:|---:|---:|
| `identity_sweep_scoped` | 0.1165 ms | 0.0035 ms | 33.3× |
| `identity_migration` | 0.428 ms | 0.124 ms | 3.46× |
| `scope_filtering` | 0.249 ms | 0.121 ms | 2.06× |
| `post_scan_derivations` | 1.893 ms | 0.553 ms | 3.43×（−1.34 ms/轮） |
| `identity_sweep_unscoped` | 0.236 ms | 0.107 ms | 2.21× |

同一命令此前独立复跑一次，各阶段中位数与上表相差均在 3% 以内（1,200 仓库
`post_scan_derivations` 508.84 → 171.19 ms）。

三个规模下脚本都报告 `output equivalence: every stage fingerprint identical across
variants and runs`：每个阶段的输出指纹在基线与当前之间一致，且在每个变体内部跨 3 轮
稳定（脚本对单侧指纹不唯一的情况单独报错，避免偶然相同被当成等价）。

`identity_sweep_unscoped` 的剩余开销是 `canonicalPath` 的文件系统解析（`getpwuid`、
`standardize`、`stat`/`readlink`），本轮未改动；它同时说明稳态（scope 内）与冷路径的
差异：加速发生在解析之后的摘要编码，而不是路径解析。

提速幅度随仓库数增长：4 仓库时整条派生链只省 1.34 ms，1,200 仓库时省 339.94 ms，
因为该开销与仓库数×派生次数成正比，而 `canonicalPath` 的部分在 scope 内已被复用。

## 未覆盖与剩余风险

- **未运行端到端配对测量**：`scripts/measure-end-to-end-refresh.sh` 的 fixture 是
  4 个临时仓库，本轮改动在该规模下只省 ~1.34 ms（占该 fixture ~320 ms 刷新墙钟的
  ~0.4%），远低于该测量的噪声，因此没有用它宣称收益。端到端行为等价由以下证据覆盖：
  阶段输出指纹逐字节一致；`DERIVED_DATA_PATH=/tmp/devpulse-persistDD ./scripts/verify.sh final`
  通过（构建成功，980 tests / 96 suites 全部通过，退出码 0），其中包含引用仓库 ID 的
  `SharedSnapshotStoreTests`、`SnapshotStoreRecoveryTests`、`PersistenceRecoveryTests`、
  `CrossProcessConcurrencyTests`、`CrossProcessPipelineTests`、`BackupEngineTests`、
  `RepositoryHistoryStoreTests`、`RepositoryActivityConsistencyTests`、
  `WidgetDegradedRenderingTests`、`RepositoryDiscoveryExperienceTests`，以及新增的两条
  摘要编码等价测试（定向运行时 141 tests / 9 suites 通过）。
- **未做进程级 CPU/能耗测量**：本轮只测函数级墙钟与阶段耗时。
- **同形态代码未一起改**：`WorkspaceModel.swift`（2 处）、`PendingItem.swift`（1 处）、
  `DependencyInferenceEngine.swift`（6 处）也有 `SHA256…map { String(format: "%02x", $0) }.joined()`。
  它们按工作区/待办项/文件计数调用，不在本轮实测热点上，按最小改动原则未动。
- **未验证的运行时不变量**：`canonicalPath` 的 scope 复用语义、共享快照的原子提交与
  跨进程 CAS 保护均未改动，因此其运行时边界沿用既有验证；本轮的测试只覆盖仓库 ID
  编码与派生链输出等价。
