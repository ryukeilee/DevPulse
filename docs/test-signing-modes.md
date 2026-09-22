# 测试与真实 App Group 的隔离（以及可选的签名环境）

`./scripts/verify.sh` 的 `test` / `final` 会把测试进程指向一个**一次性的
scratch 容器与偏好域**，因此无论 test host 是否签名，测试都不会读写用户真实
的 App Group 数据。签名（`signed` 模式）仍然可用，但不再是测试通过的前提。

## 为什么必须隔离

DevPulse 的 host app 在 `DevPulseNative/App/DevPulse.entitlements` 里声明了
App Group `group.local.devpulse`；Widget 与多个 Core store 直接读写
`~/Library/Group Containers/group.local.devpulse` 与偏好域
`group.local.devpulse`。

历史上测试宿主直接使用这些真实位置：`ScanScheduler` 通过
`UserDefaults(suiteName: AppGroupStore.appGroupIdentifier)` 持久化扫描配置，
各 store 通过
`FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`
读写真实容器。于是 `RepositoryDiscoveryExperienceTests` 中调用
`addCustomPath(...)` 的用例会把指向 `DevPulseTests-*` 临时目录的
`scan_locations_v1_json` / `last_repository_discovery_scan_roots` 写进真实偏好
域，使已安装的 App 扫描 0 个仓库。这是真实缺陷，已由本目录描述的隔离修复。

## 隔离机制

`test` / `final` 设置两个环境变量；xcodebuild 会把 `TEST_RUNNER_<VAR>`
去掉前缀后透传给 test host：

| test host 侧环境变量 | 作用 |
| --- | --- |
| `DEVPULSE_APP_GROUP_CONTAINER_PATH` | `SharedSnapshotLocation.containerURL` 返回该临时目录；`AppGroupStore` 及所有 store 的容器读写都指向它 |
| `DEVPULSE_APP_GROUP_DEFAULTS_SUITE` | `SharedSnapshotLocation.defaults` 改用该 suite，扫描配置/固定项/发现标记不再写入真实偏好域 |

生产运行时不设置这两个变量，路径与行为与之前完全一致；只有真实 App Group
identifier（`group.local.devpulse`）会被重定向，代码中刻意探测不存在 group 的
场景仍然返回 `nil`。运行结束后 `verify.sh` 通过 EXIT trap 删除临时容器与临时
suite。

## 结果

- 5 项依赖共享容器读写语义的测试在 **unsigned** 模式下也全部通过：
  `RefreshCompletionTests.initialStateIsIdle()` 与 4 项
  `RepositoryDiscoveryExperienceTests`。它们断言的是注入的临时容器上真实落盘
  的文件（`repositories.json` 等），而不是内存状态。
- 全量测试不需要 provisioning profile，也不需要 Xcode 账号。

## 模式

| `DEVPULSE_SIGNING_MODE` | 行为 |
| --- | --- |
| `auto`（默认） | 本机存在同时匹配 app 与 widget bundle id 的本地 profile 时用 `signed`，否则 `unsigned` |
| `signed` | 强制 profile 签名；解析不到 team/profile 时立即失败（不静默降级） |
| `unsigned` | 无签名 test host（本机默认） |

`DEVELOPMENT_TEAM` 显式设置时等价于 `signed`；`CODE_SIGN_IDENTITY` 覆盖签名
身份名。

## 命令

```sh
# 默认（本机无匹配 profile 时自动 unsigned）：隔离 + 全量
DERIVED_DATA_PATH=/tmp/devpulse-build ./scripts/verify.sh final

# 显式 unsigned
DEVPULSE_SIGNING_MODE=unsigned DERIVED_DATA_PATH=/tmp/devpulse-build ./scripts/verify.sh final

# 定向
DERIVED_DATA_PATH=/tmp/devpulse-build ./scripts/verify.sh test DevPulseTests/ActivityEventTests
```

## 约束

- 判定"是否引入新失败"必须比对**测试名 + 原始断言文本**，并始终使用独立的
  `DERIVED_DATA_PATH`（默认 `/tmp/devpulse-build` 是共享路径，并发跑会互相抢占）。
- `verify.sh widgetkit` 会在同一个 DerivedData 里做无签名构建；`signed` 模式下
  先跑 `test` 需要重新 `build`。
