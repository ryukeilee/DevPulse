# 测试入口的两种签名环境（signed / unsigned）

`./scripts/verify.sh` 的测试环境由两个模式控制：**signed**（开发签名，
test host 带 `com.apple.security.application-groups` entitlement）与
**unsigned**（历史行为，硬编码 `CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO`，test host 没有任何 entitlement）。

## 为什么需要两种模式

DevPulse 的 host app 在 `DevPulseNative/App/DevPulse.entitlements` 里声明了
App Group `group.local.devpulse`。**经 LaunchServices 启动、但没有
`com.apple.security.application-groups` 的 app bundle，其 App Group 容器路径
仍然可以解析，但读写会被拒绝。** 于是一批依赖共享容器的测试在 unsigned 模式下
必然失败——这是测试环境的假象，不是产品缺陷（成因与机制隔离实验见
[`docs/main-test-baseline.md`](main-test-baseline.md)）。

unsigned 模式下稳定失败的项（无条件复现）：

- `RefreshCompletionTests.initialStateIsIdle()`
- `RepositoryDiscoveryExperienceTests.schedulerRebuildMigratesLegacyPinsAndSharedSnapshotIdentity()`
- `RepositoryDiscoveryExperienceTests.schedulerRebuildMigratesIgnoredPathsAndRewritesSharedSnapshotScope()`
- `RepositoryDiscoveryExperienceTests.ignoringRepositoryImmediatelyFiltersAppAndSharedWidgetSnapshotAndForcesScopedScan()`
- `RepositoryDiscoveryExperienceTests.repositoryRetryAfterBackupRecoveryCommitsAWidgetReadableSnapshot()`

另外 `SleepWakeLifecycleTests.suspendForSleepCancelsActiveScan()` 是**与签名
无关的真实 flake**（测试用固定 `Task.sleep(100ms)` 等待取消传播），两种模式下
都可能偶发失败，判定时必须与上面 5 项区分。

## 选择模式

| 环境变量 | 取值 | 行为 |
| --- | --- | --- |
| `DEVPULSE_SIGNING_MODE` | `auto`（默认） | 能在本机解析出 Apple Development 身份时用 signed；否则回退 unsigned 并打印已知失败提示 |
| | `signed` | 强制签名；解析不到身份时立即失败，不静默降级 |
| | `unsigned` | 强制历史的无签名行为 |
| `DEVELOPMENT_TEAM` | 任意 team id | 直接指定 team（等价于 signed） |
| `CODE_SIGN_IDENTITY` | identity 名称 | 覆盖签名身份名称，默认 `Apple Development` |

team 的解析顺序：

1. 环境变量 `DEVELOPMENT_TEAM`；
2. 本机 provisioning profile（先 host `local.devpulse.app`，再 widget
   `local.devpulse.app.widget`，两者 TeamIdentifier 必须一致）；
3. Xcode 首选项 `com.apple.dt.Xcode.plist` 的 `teamID`；
4. Apple Development 证书主体的 `OU` 字段。

> `security find-identity -v -p codesigning` 输出**括号里的值不是 team ID**
> （那是证书标识符），脚本不会取它。本机三处一致的值是 `JYL9G28DP3`。

`auto` 是默认值以保证**没有证书的机器（CI）行为不比以前更差**：无法解析身份时
自动退回 unsigned，并明确提示这会触发上述 5 项 entitlement 假失败。

## 用法

```sh
# 本机（有 Apple Development 身份）—— 自动使用 signed
DERIVED_DATA_PATH=/tmp/devpulse-build ./scripts/verify.sh final

# 强制签名（无身份即失败，适合验收）
DEVPULSE_SIGNING_MODE=signed DERIVED_DATA_PATH=/tmp/devpulse-build ./scripts/verify.sh final

# 强制无签名（对照 / CI）
DEVPULSE_SIGNING_MODE=unsigned DERIVED_DATA_PATH=/tmp/devpulse-build ./scripts/verify.sh final

# 显式指定 team
DEVELOPMENT_TEAM=JYL9G28DP3 DERIVED_DATA_PATH=/tmp/devpulse-build ./scripts/verify.sh final
```

构建设置与测试设置必须一致：`build-for-testing` 与 `test-without-building`
共用同一个 `COMMON_ARGS`，因此同一模式下 `build` → `test` / `final` 复用同一份
DerivedData，不会因为签名设置不同而重新编译。

## 约束

- signed 模式依赖本机 provisioning profile 的有效期。profile 过期后
  `DEVPULSE_SIGNING_MODE=signed` 会构建失败，不会退回 unsigned（这是刻意的：
  静默降级会重新引入 5 项假失败）。此时请更新 profile，或显式用
  `DEVPULSE_SIGNING_MODE=unsigned` 并预期 5 项失败。
- 判定"是否引入新失败"必须比对**测试名 + 原始断言文本**，并始终使用独立的
  `DERIVED_DATA_PATH`（默认 `/tmp/devpulse-build` 是共享路径，并发跑会互相抢占）。
