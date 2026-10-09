# 多标签页性能对照

2026-10-09，以 `main` 的 `7ada40e` 为基线，对照本次工作区实现。收益足以保留这次修改。

## 修改与边界

`ContentView` 继续挂载全部七个页面。`RetainedTabStorage` 通过 `StateObject` 的延迟初始化，只执行一次页面工厂，保留原有页面身份、局部状态、导航回调及 `Binding`。

六个读取共享扫描模型的页面，以及 Overview 的焦点卡片，改为订阅各自的 `TabUpdateScope`。隐藏页面不转发 `ScanScheduler.objectWillChange`，激活时发送一次更新。页面始终读取同一个实时 scheduler，没有保存旧快照。详情页仍使用原有 scheduler 环境。

初始化和 `onAppear` 行为继续保留；后台扫描、刷新、持久化、备份操作和数据模型没有修改。没有添加网络访问或 Git 写操作。没有进一步重构页面内的派生算法。

## 方法

```sh
rtk proxy python3 scripts/benchmark-tabs.py --baseline-git 7ada40e --repos 1200 --runs 3 --output /tmp/devpulse-tabs-ab.json
```

环境：macOS 27.0.1，arm64，Apple Swift 6.4。两个版本均使用相同 SDK、`-O -whole-module-optimization` 和独立进程。

基准实际挂载 `NSHostingView<ContentView>`，使用 1,200 个合成仓库。临时源码副本仅暴露标签选择为 `Binding`、注入相同的页面 `body` / 偏好读取计数，并将备份和 App Group 存储重定向至临时目录。scheduler 使用 `commandMode: true`，不扫描用户仓库。

每个版本运行三次，每次暖场后依次执行：

- 切换：遍历全部七个标签一次。
- 后台进度：Repositories 激活时变更 `isScanning` 十次。
- 大量数据刷新：Settings 激活时替换三份 1,200 仓库快照。

通过 `getrusage(RUSAGE_SELF)` 测量场景内累计 user + system CPU 时间。下面采用三次结果的中位数，时间是整个场景的 CPU 总耗时。原始记录见 [tab-performance-results.json](tab-performance-results.json)。

早期较多重复次数的基准达到 180 秒运行上限，最终减少重复次数，保留三个场景；没有延长超时。正式六次运行全部在原上限内完成。

## 结果

| 场景 | 基线 CPU 秒 | 优化后 CPU 秒 | 降幅 |
| --- | ---: | ---: | ---: |
| 七页切换 | 30.596 | 11.879 | 61.2% |
| 十次后台进度更新 | 54.795 | 8.753 | 84.0% |
| 三次大量数据快照替换 | 15.224 | 5.411 | 64.5% |

三轮均观察到相同的计算次数变化：

- 切换时，`StatusTab`、焦点卡片及 Repository 页面各从七次求值降为一次；偏好读取从七次降为零。
- 后台进度更新时，基线六个共享模型页面各求值十次；优化后只有当前 Repository 页面求值十次，五个隐藏页面及焦点卡片均为零。偏好读取从十次降为零。
- 快照替换时，基线六个页面各求值三次；优化后只有 Settings 求值三次，隐藏页面及焦点卡片均为零。偏好读取从三次降为零。

测量证明了真实页面在大量数据下的呈现 CPU 改善。后台刷新测量覆盖进度通知与快照投递到 UI 的阶段，不包含实际 Git 扫描耗时。原始记录的 `settle_p95_ms` 是短序列的排序采样值，包含每轮 20 ms 事件循环等待，不作为 FPS 或真实用户交互延迟承诺。未测量日常少量仓库、滚动帧率或安装后的 Widget 性能。

## 功能与测试验收

复用 `/tmp/devpulse-tabs-build`，使用 unsigned 构建与隔离 App Group 存储。受当前执行沙箱限制，编译器使用 `OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'`；原生测试需要允许连接 `testmanagerd` 的执行环境。没有修改项目构建设置或签名配置。

已运行并通过：

- `verify.sh build`。
- `verify.sh test DevPulseTests/RetainedTabTests DevPulseTests/RefreshCompletionTests DevPulseTests/DataFreshnessStateTests DevPulseTests/RepositoryDiscoveryExperienceTests`：93 个测试、4 个套件。
- 补充诊断导航测试后的 `verify.sh test DevPulseTests/RetainedTabTests`：4 个测试。
- `verify.sh final`：943 个测试、95 个套件，107.197 秒。
- `git diff --check`。

新增保活测试使用真实 `NSHostingView` 验证：隐藏时停止求值、切回显示最新扫描状态、局部状态与身份保留、页面工厂和 `onAppear` 仅执行一次、诊断导航 `Binding` 多次切换后仍有效，以及订阅不会形成自身保留循环。
