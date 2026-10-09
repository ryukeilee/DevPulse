# 扫描结果更新后的活动时间线性能

2026-10-09，基线为 `7ada40e`。仅比较本次三个生产文件的变化；工作区已有的 Tab 更新隔离修改不在本次提交或验收源码树中。

## 修改

- `ActivityTimelineView` 只为展示记录涉及的仓库派生决策：折叠显示 8 条、展开最多 100 条；无记录时直接返回空决策上下文。每次更新都使用实时输入，无跨刷新缓存。
- `ActivityTimelineAttention` 先筛选冲突开始/解除、读取失败/恢复事件，再按原比较规则排序。普通开发事件不参与注意力状态，避免对整个活动列表反复解析时间。提示仍覆盖全部未解除的注意力事件，输出顺序和折叠计数不变。

没有更改扫描结果、导航、页面局部状态、共享快照格式或 Widget 行为。

## 可复现测量

```sh
rtk proxy python3 scripts/benchmark-timeline.py --baseline-git 7ada40e --repos 1200 --runs 3 --output /tmp/devpulse-timeline-results.json
```

环境为 macOS 27.0.1、arm64、Apple Swift 6.4。基准挂载真实 `NSHostingView<ActivityTimelineView>`，在主线程更新仓库数组、运行事件循环、布局和提交渲染事务。两个版本均使用相同合成数据与 `-O -whole-module-optimization`，独立进程运行三次。仅在临时源码副本加入决策派生和页面求值计数，未模拟或替换生产算法；不扫描用户仓库、不读取偏好、不访问 App Group。

两个场景各执行六次快照更新，比较 `getrusage(RUSAGE_SELF)` 的 user + system CPU 时间，以下为三轮中位数。原始结果见 [timeline-performance-results.json](timeline-performance-results.json)。

| 场景 | 基线 CPU ms | 优化后 CPU ms | 降幅 |
| --- | ---: | ---: | ---: |
| 空时间线，1,200 个仓库 | 22.539 | 3.112 | 86.2% |
| 折叠时间线，1,200 个仓库、120 条普通开发事件 | 9,289.607 | 70.888 | 99.2% |

两版每个场景均求值六次，证明快照继续到达页面。决策派生次数分别从 7,200 次降为零和 48 次。第一次仅缩小决策上下文时，有记录场景整体耗时未改善；筛选注意力事件后，最终三轮均观察到明显下降。

这是组件实际呈现路径的改善，不代表整个 App、Git 扫描耗时或滚动帧率。注意力事件较多时仍使用原有排序和时间解析，收益会随活动构成变化。未测安装后的 Widget。基准进程在执行沙箱内输出 LaunchServices/XPC `Connection invalid` 日志，仍正常完成挂载、布局、六次页面求值及测量；两版运行环境一致。

## 功能验证

验收使用临时目录中的 `HEAD + 本次修改`，复用 `/tmp/devpulse-tabs-build`，采用 unsigned 构建和隔离测试存储。由于 Swift 宏的嵌套沙箱在当前环境报 `sandbox_apply: Operation not permitted`，验证命令附加 `OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'`；没有修改项目构建设置。原生测试在可连接 `testmanagerd` 的执行环境运行。

新增覆盖验证选择性决策与全量决策一致、重复 ID 仍以最后一条为准、展开所需上下文、刷新与仓库移除，以及普通事件不影响冲突解除或折叠提示。现有测试继续覆盖读取失败/恢复、冲突重启、时间线与列表/详情/Widget 决策一致。

最终版本实际通过：

- `verify.sh build`：App、Widget 和测试包构建。
- `verify.sh test DevPulseTests/ActivityEventTests DevPulseTests/CommitReadinessEngineTests`：200 个测试、2 个套件。
- `verify.sh final`：941 个测试、94 个套件，104.795 秒。
- A/B 基准：每版三次独立进程运行，空态及折叠态每次均完成六次页面更新。
- `git diff --check`、暂存源码与验收源码逐文件一致性检查、`secret-scan.sh staged`。

本次未进行签名安装或手工验证安装后的 App/Widget；验证范围为原生构建、隔离回归和真实时间线组件的内存快照更新路径。
