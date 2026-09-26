# 日常开发反馈周期：重复定向测试启动测量

## 发现与改动

仓库现有路径已避免重复编译：`./scripts/verify.sh build` 调用 `build-for-testing`，之后的 `test` 用 `test-without-building` 复用同一 `DERIVED_DATA_PATH`。完整验收 `./scripts/verify.sh final` 仍是完整 build + 全量测试。

但修改跨多个测试套件的共享 Core、App 或 Widget 行为时，基线 `verify.sh test` 只接受一个测试筛选器。开发者按文档逐套件运行时，每个命令都会重新启动 `xcodebuild`，启动测试宿主、创建/清理隔离 App Group 目录与 defaults suite；这段开销在健康/Widget 的快速套件上远大于测试本身。

本次候选改动仅扩展 `scripts/verify.sh test`：可传入多个测试筛选器，脚本仍逐一添加 `-only-testing:<selector>`，但由同一次 `xcodebuild test-without-building` 执行。单筛选器用法保持兼容；未传筛选器仍运行完整套件；`final` 仍不带筛选器、运行完整套件；显式空筛选器会失败关闭。没有更改测试、过滤规则、断言、超时、签名、隔离方式或 release gate。

## 开发、Widget/App 与预发布路径图

| 场景 | 入口 | 实际工作与重复点 |
|---|---|---|
| 实现或测试改动 | `./scripts/verify.sh build` → `./scripts/verify.sh test DevPulseTests/<suite>` | 一次 build-for-testing 后复用产物；过去每个相关 suite 都需再启动一个 `xcodebuild` 和隔离环境。现在可把相关 selectors 放在一次 `test` 调用中。 |
| 完整验收 | `./scripts/verify.sh final` | build-for-testing + 不带筛选器的全量 test-without-building；候选未改变此路径。 |
| Widget/App 接线 | `./scripts/verify.sh widgetkit` | 委派给 `verify-widgetkit.sh`，构建 Debug App/Widget、读 build settings，并检查嵌入、bundle ID、WidgetKit extension point、App Group 与 target dependency。 |
| 构建配置 | `bash scripts/verify-build-consistency.sh` | 对 `project.yml`、Info.plist 与 entitlements 做源配置检查；传 `--app-path` 才会额外核对已构建包。 |
| 发布前 / 安装态 | `./scripts/secret-scan.sh staged`、`./scripts/install-and-self-check.sh`、`verify-install-upgrade.sh`、`verify-upgrade.sh` | 包含 staged secret scan、签名安装/运行自检、已安装 App/Widget 与升级兼容检查。此任务禁止安装、启动或修改真实 App/Widget，故未执行安装态入口。 |

## 基线与复现方法

基线是本线程起始提交 `e1fcdaa51f5c526f773bb08e83ed8068d3e3bb56`；基线源码树用 `git archive` 导出到临时目录，候选源码树是本线程工作树。两边产品源码相同，仅验证脚本不同。分别用独立 DerivedData 执行 `./scripts/verify.sh build`，随后只测量 `test-without-building` 阶段；每次 `verify.sh test` 都使用脚本生成的临时 App Group 容器和唯一 defaults suite，不接触已安装 App 的用户数据。

三个代表性工作流及准确命令如下（在相应基线/候选树根目录执行；环境变量值是本次实测值）：

```sh
# App 实现 / 项目健康行为：RepositoryHealthOverview.swift 所属回归范围
# 基线（两个独立 xcodebuild 调用）
DERIVED_DATA_PATH=/tmp/devpulse-t0060-base-dd ./scripts/verify.sh test DevPulseTests/RepositoryHealthOverviewTests
DERIVED_DATA_PATH=/tmp/devpulse-t0060-base-dd ./scripts/verify.sh test DevPulseTests/RepositoryActivityConsistencyTests
# 候选（一个 xcodebuild 调用）
DERIVED_DATA_PATH=/tmp/devpulse-t0060-baseline-dd ./scripts/verify.sh test DevPulseTests/RepositoryHealthOverviewTests DevPulseTests/RepositoryActivityConsistencyTests

# Refresh 测试改动：刷新完成与引擎集成回归
# 基线
DERIVED_DATA_PATH=/tmp/devpulse-t0060-base-dd ./scripts/verify.sh test DevPulseTests/RefreshEngineIntegrationTests
DERIVED_DATA_PATH=/tmp/devpulse-t0060-base-dd ./scripts/verify.sh test DevPulseTests/RefreshCompletionTests
# 候选
DERIVED_DATA_PATH=/tmp/devpulse-t0060-baseline-dd ./scripts/verify.sh test DevPulseTests/RefreshEngineIntegrationTests DevPulseTests/RefreshCompletionTests

# Widget/App 改动：Widget 渲染与生命周期回归
# 基线
DERIVED_DATA_PATH=/tmp/devpulse-t0060-base-dd ./scripts/verify.sh test DevPulseTests/WidgetDegradedRenderingTests
DERIVED_DATA_PATH=/tmp/devpulse-t0060-base-dd ./scripts/verify.sh test DevPulseTests/WidgetLifecycleScenariosTests
# 候选
DERIVED_DATA_PATH=/tmp/devpulse-t0060-baseline-dd ./scripts/verify.sh test DevPulseTests/WidgetDegradedRenderingTests DevPulseTests/WidgetLifecycleScenariosTests
```

每个场景基线/候选各重复 5 组，调用顺序按组交替（base→candidate、candidate→base）。Python 3 `time.perf_counter_ns()` 包住完整 `verify.sh test` 子进程；基线两次命令时间相加，候选一次多 selector 命令计时。因而计时涵盖脚本启动、隔离环境建立/清理、`xcodebuild` 与测试宿主启动和测试运行，但不包含 build。所有 30 个基线 suite 调用及 15 个候选组合调用均退出码 0。完整原始命令输出与机器可读样本在本次运行的 `/tmp/devpulse-t0060-measurements/`；下表保留全部重复测量，便于在该临时目录清理后仍核对结果。

测试结果逐套件相等：

- App 健康：基线 `28 tests / 1 suite` + `7 tests / 1 suite`；候选 `35 tests / 2 suites`，通过。
- Refresh：基线 `19 tests / 1 suite` + `13 tests / 1 suite`；候选 `32 tests / 2 suites`，通过。
- Widget/App：基线 `17 tests / 1 suite` + `9 tests / 1 suite`；候选 `26 tests / 2 suites`，通过。

### 配对墙钟（毫秒）

`delta = candidate − baseline`；负数表示候选更快。原始数据未剔除离群值。

| 工作流 | 组 | 基线（分别运行各 suite） | 候选（合并 selectors） | 配对差 |
|---|---:|---:|---:|---:|
| App 健康 | 1 | 5006.914 | 2650.628 | -2356.285 |
| App 健康 | 2 | 4477.564 | 2351.605 | -2125.959 |
| App 健康 | 3 | 4488.019 | 2298.802 | -2189.216 |
| App 健康 | 4 | 4549.167 | 2301.695 | -2247.472 |
| App 健康 | 5 | 4606.729 | 2291.145 | -2315.585 |
| Refresh | 1 | 11287.619 | 13458.175 | +2170.556 |
| Refresh | 2 | 10413.457 | 8333.927 | -2079.530 |
| Refresh | 3 | 10516.954 | 8093.386 | -2423.568 |
| Refresh | 4 | 10379.382 | 8153.990 | -2225.392 |
| Refresh | 5 | 10403.658 | 8096.910 | -2306.748 |
| Widget/App | 1 | 4575.580 | 2314.837 | -2260.743 |
| Widget/App | 2 | 4554.395 | 2402.599 | -2151.797 |
| Widget/App | 3 | 6202.246 | 3181.684 | -3020.562 |
| Widget/App | 4 | 4477.607 | 3000.350 | -1477.257 |
| Widget/App | 5 | 4488.188 | 2323.411 | -2164.777 |

| 工作流 | 基线中位数 | 候选中位数 | 配对差中位数 | 配对差 MAD | 更快组数 |
|---|---:|---:|---:|---:|---:|
| App 健康 | 4549.167 ms | 2301.695 ms | -2247.472 ms | 68.113 ms | 5/5 |
| Refresh | 10413.457 ms | 8153.990 ms | -2225.392 ms | 145.862 ms | 4/5 |
| Widget/App | 4554.395 ms | 2402.599 ms | -2164.777 ms | 95.966 ms | 5/5 |

总体方向一致且改善量远高于配对差 MAD；直接、可复现的工作量证据是三类场景每次由 2 个 `xcodebuild` 进程降为 1 个（15 次组合验证少启动 15 个 `xcodebuild`）。测试运行本身没有被删减，最终测试数量与基线相同。Refresh 第 1 组候选比基线慢 `2170.556 ms`，完整保留；它包含一次高耗时测试运行，不能据其余样本宣称每轮必快。各场景仅 5 对，数据不作为刷新性能、资源占用或正式 release gate 的统计结论。

### 构建、Widget/App 与配置检查输出

构建产物彼此隔离。基线归档树的首次 build 命令：

```sh
cd /tmp/devpulse-t0060-base-src
/usr/bin/time -p env DERIVED_DATA_PATH=/tmp/devpulse-t0060-base-dd ./scripts/verify.sh build
```

输出：`[verify] Build succeeded`，`real 63.20`、`user 169.01`、`sys 13.36` 秒。候选树首次 build：

```sh
/usr/bin/time -p env DERIVED_DATA_PATH=/tmp/devpulse-t0060-candidate-dd ./scripts/verify.sh build
```

输出：`[verify] Build succeeded`，`real 38.28`、`user 147.43`、`sys 11.80` 秒。两次均成功，但编译器/系统缓存与采样时负载不同，这两个冷 build 时间不是配对样本，不能据此声称 build 加速；候选也没有改 build 路径。

候选 `DERIVED_DATA_PATH=/tmp/devpulse-t0060-candidate-dd ./scripts/verify.sh widgetkit` → `WidgetKit verification passed: 16 PASS, 0 FAIL`。`bash scripts/verify-build-consistency.sh` → `20 pass, 0 fail, 1 skip`（未给 `--app-path`，所以跳过构建包检查）。直接执行 `./scripts/verify-build-consistency.sh` 在该文件现有执行权限下返回 `126 Permission denied`，因此用 `bash` 调用现有脚本完成检查；未顺手修改其文件模式。

## 环境、边界与风险

Apple M2 / `Mac14,2`、arm64、8 个逻辑 CPU、16 GiB；macOS 27.0 (`26A428`)、Xcode 27.0 (`27A266a`)。测量窗口开始前的 load average 为 `9.99 / 11.23 / 8.16`，结束后为 `6.71 / 8.98 / 8.04`；窗口两端未见其他 `xcodebuild` 或 `xctest` 进程，但机器并非空闲。候选/基线以交替顺序测量，并完整保留高延迟样本；因此报告中把可复现的进程数减半与重复中位差作为证据，不外推到其他机器或单 suite 用法。

工作流类别是实际 DevPulse 测试套件与真实 `verify.sh` 命令的 post-build 验证场景；测量没有为了造数据修改产品/测试源码，也不测 Swift 增量编译成本。候选只对调用者明确要求的多 suite 定向回归有收益；单 suite、WidgetKit 构建、源码配置检查与全量 `final` 不会减少工作。测试套件在一次 xcodebuild 测试进程中共享该次临时 defaults suite，和全量测试同属一个隔离测试运行；若某 suite 隐式依赖每次 xcodebuild 的全新 suite，合并运行会暴露这种跨套件耦合，需按失败正常处理，不能拆掉断言或过滤来掩盖。

未安装、启动、停止或修改真实 DevPulse App/Widget；未读取或改写用户 App Group 数据、TinyBuddy 或签名材料；测试脚本只使用一次性 App Group 与 preferences suite。全量 `./scripts/verify.sh final` 是候选代码的严格验收命令，不被本优化替代。
