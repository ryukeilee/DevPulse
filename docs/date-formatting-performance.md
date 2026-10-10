# 时间戳格式化与解析性能验证

本轮只改时间戳工具本身。`DateFormatting` 的每个入口都在每次调用时新建 `ISO8601DateFormatter` / `DateFormatter`，而构造（含 `formatOptions` 赋值）实测约 190µs，远超其后的解析（约 57µs）与格式化（约 1.2µs）。列表行、健康概览、历史信号等派生模型每条记录会调用多次，因此这一路径的成本由构造主导。

改动分两部分：

1. 规范时间戳——`YYYY-MM-DDTHH:MM:SSZ` 与 `YYYY-MM-DDTHH:MM:SS±HH:MM`，即本应用写出（`DateFormatting.isoString`）和 `git log %cI` 读入的形状——走一段不建 formatter 的算术解析。
2. 其余输入（分数秒、非规范形状）仍走与改动前完全相同的 `fractional ?? standard` 组合，只是实例改为构建一次并由锁保护。

`isoString` 复用共享的 `ISO8601DateFormatter`；`displayString` 复用共享的 `DateFormatter`，并在每次调用时刷新 `TimeZone.current`，保持旧的逐次捕获语义。

## 等价性边界

快速路径只接受同时满足下列条件的输入，其余一律回落到 formatter：

- 形状恰为 `YYYY-MM-DDTHH:MM:SSZ` 或 `YYYY-MM-DDTHH:MM:SS±HH:MM`，且每个字段都是 ASCII 数字；
- 时钟字段在范围内（`hh < 24`、`mm < 60`、`ss < 60`）；
- 月、日构成合法日历日（含闰年规则）；
- UTC 偏移不超过 `±14:00`（即 `hh == 14` 时 `mm` 必须为 `00`），且 `mm <= 59`；
- `(year, month, day) >= (1582, 10, 15)`。

这样就排除了两套实现存在分歧的全部形状：

- `ISO8601DateFormatter` 在 1582-10-15 之前按儒略历解释（包括 1582-10-05..14 这些被跳过的日期），快速路径的格里高利历算术在那里不成立；
- 时钟字段越界——formatter 拒绝，而 `Date.ISO8601FormatStyle` 会归一化接受；
- UTC 偏移越界（`> ±14:00`，含 `±14:01`–`±14:59`，或 `mm > 59`）——formatter 接受，而 `Date.ISO8601FormatStyle` 拒绝；
- 需要归一化的日历日（如 `2025-02-29`）、分数秒，以及任何形状不匹配的输入。

因此被接受的输入都是合法日历日：算术不涉及归一化，整数秒转 `Double` 精确（最大 `days × 86400 ≈ 2.53e11`，远小于 2^53），与 formatter 逐位一致。偏移量在 `Z` 的情况下按 `9999-12-31T23:59:59-14:00` 之类的极端输入已验证无整数溢出。

`DevPulseNativeTests/DateFormattingTests.swift` 把上述边界固化为可执行断言：规范形状的全字段矩阵、分歧形状表、儒略历切分点、随机变异模糊输入，以及 `isoString` 在 0001-01-01 至 9999-12-31 范围内的输出比对。删除儒略历守卫后该测试会失败（已用变异验证），因此守卫不会被无声放宽。

### 修订：偏移守卫的 `±14:00` 上界

初版守卫写作 `offsetHour <= 14, offsetMinute <= 59`，实际接受 `±14:01` 至 `±14:59`（直接调用修订前的 `canonicalDate` 得到接受表），与注释及本文档声明的 `±14:00` 不符。当前 Foundation 的 `ISO8601DateFormatter` 恰好仍按字面读取这些越界偏移，所以快速路径的算术结果与 formatter 相同，仅比对解析值无法暴露这一差异。

同一套差分夹具在修订前后分别与改动前的 `fractional ?? standard` 逐位比对：全偏移组合（0–99 时 × 0–99 分 × 两种符号 × 3 个极端时间戳，共 60,000 个）、12 个世纪的月/日矩阵、时钟字段极值、儒略历切分点，以及随机结构与字节变异输入；修订后共 132,060 个输入，0 处分歧。但 `ISO8601DateFormatter` 在 `±14:00` 之外的行为没有规范约束，等价性不应建立在它的宽容上。

守卫因此收紧为 `magnitude <= 14 * 3_600`：`±14:01` 至 `±14:59` 与更大的偏移一起回落 formatter，取值由与改动前完全相同的实现决定；`±14:00` 及以内的快速路径不变。`canonicalDate` 由 `private` 改为 internal，`DateFormattingTests.canonicalFastPathStopsAtPlusMinus14Hours` 直接断言快速路径在 `±14:00` 处接受、在 `±14:01` 起拒绝，并对每个边界偏移（含 1582-10-15 与 9999-12-31 的日期边界组合）比对 formatter 基准。

修订后 `./scripts/verify.sh final`：974 个测试、96 个套件通过。`python3 scripts/benchmark-date-formatting.py --baseline-git e295cdf` 的输出指纹仍为 `f11087eb6bdfc045`，与下表一致；`parse_offset` 3792x（表中原值 3808x，属测量噪声），即行为不变且无性能退化。

## 复现

基线：`e295cdf1b6ad809136d94c3d0cce160643b1e321`。

```sh
python3 scripts/benchmark-date-formatting.py --baseline-git e295cdf
```

脚本用 `swiftc -O` 分别编译基线与当前的 `DateFormatting.swift`，交替两侧的测量顺序，并对每个工作负载的全部派生值计算 FNV-1a 指纹；两侧指纹不一致时返回非零退出码，因此只有行为等价的提速才会被接受。默认参数 `BENCH_TIMESTAMPS=2000 BENCH_ROWS=250 BENCH_ITERATIONS=5`，耗时约 1 分钟。

测量环境：arm64、macOS 27.0.1、Apple Swift 6.4。耗时受硬件及负载影响。

## 实测结果

```text
output fingerprint: f11087eb6bdfc045

workload                      baseline ms   current ms   speedup
parse_canonical                   806.468        0.228  3532.62x
parse_offset                      808.822        0.212  3808.46x
parse_fractional                  702.946      117.257     5.99x
iso_string                       1020.960        2.515   405.87x
relative_time_chinese             810.006        0.180  4493.79x
display_string                    993.189        3.235   307.00x
repository_row_derivation         423.071        9.979    42.39x
```

`repository_row_derivation` 对应列表行一次求值所需的时间戳派生：数据来源标签、最新提交标签与最近活动标签各一次，其中最近活动会先解析两个候选时间戳。250 行合计 423.1ms → 10.0ms，即 1.69ms → 0.040ms/行，是本轮最贴近用户可见路径的负载。

`parse_fractional` 仍保留回落路径，约 6x 的提升来自共享实例替代逐次构造；剩余成本是 `ISO8601DateFormatter` 的解析本身。真实数据里应用只写出非分数秒时间戳（`DateFormatting.isoString`），因此该路径只在读取历史或外来数据时命中。

## 端到端

`scripts/benchmark-git-refresh.py`（配对测量，24 仓库、6 轮，`git status` 子进程延迟占主导）：

```text
scenario                           baseline   candidate    delta      p    faster
cold_refresh                         119.33      114.12    -1.2%  1.0000   3/6
committed_incremental_refresh         38.33       36.12    -2.3%  0.6875   4/6
concurrency_probe                    251.02      246.20    -2.1%  1.0000   3/6
incremental_refresh                   69.06       66.99    -1.1%  0.6875   4/6
incremental_scanner                   93.30       85.67    -7.8%  0.0312   6/6
```

`incremental_scanner` 是唯一达到统计显著的场景（6/6 配对更快，p=0.031）。把 `DateFormatting.swift` 单独还原到基线后重跑同一基准，五个场景的 delta 落在 `+2.1%` 至 `-5.9%` 且 p >= 0.22，即上面这 7.8% 归因于本轮的时间戳改动，而不是扫描/刷新阶段的改动。

## 同批次的其余改动

同批次还改了两处，二者都不改变可观察数据（由定向测试与 `verify.sh final` 覆盖），但在上述基准的规模下低于噪声，因此不把它们记为已量化的加速：

- `GitRepositoryScanner` 目录遍历：`canonicalExistingFilePath` 原先对每个条目无条件执行（含被排除的条目与普通文件），现在只在确认要遍历的目录，以及需要报告属性读取失败时才计算；同一父目录下子任务的合并由逐子任务重建累计结果改为就地累加，避免随兄弟目录数平方增长。收益取决于被遍历的非仓库目录里有多少条目，基准夹具里几乎没有这类条目。
- `RefreshEngine` merge 阶段：旧快照索引改为首次查询时构建。它只服务"本轮没有产出快照"的回退路径；正常刷新不查询该索引，却要为每个旧仓库支付一次 `RepositoryIdentity.normalize`。24 仓库时约省 0.8ms，低于该基准的噪声；收益随旧快照仓库数线性增长。

## 验收

- `./scripts/verify.sh build`：通过。
- 定向测试 `DateFormattingTests`、`RefreshEngineIntegrationTests`、`CommitReadinessEngineTests`、`ScanDataConsistencyTests`、`RepositoryDiscoveryExperienceTests`、`RepositoryActivityConsistencyTests`、`ActivityEventTests`、`RepositoryHealthOverviewTests`、`DailyDevelopmentSummaryTests`、`WorkspaceAggregationTests`、`PendingItemStaleLifecycleTests`、`RefreshCompletionTests`、`RepositoryPathCanonicalizationReuseTests`：通过。
- 复用 `/tmp/devpulse-build` 运行 `./scripts/verify.sh final`：973 个测试、96 个套件通过。
- `./scripts/verify-build-consistency.sh`（20 pass / 0 fail）、`./scripts/verify-widgetkit.sh`（16 PASS / 0 FAIL）、`./scripts/verify-activity-timeline.sh`：通过。
- `python3 -m py_compile scripts/benchmark-date-formatting.py`、`git diff --check`：通过。

**未验证**：GUI 手工验证。`repository_row_derivation` 是 `RepositoryListItemPresentationBuilder` 时间戳部分的等价负载，不是 SwiftUI `body` 求值的实测；真实列表渲染的收益未做仪器化确认。
