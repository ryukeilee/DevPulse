# Memory（长期项目知识）

只记录**稳定事实**：稳定架构信息、已确认设计、已解决的重要问题、避免重复
检查的区域。单次修改细节、临时日志**不写入本文件**——它们属于 `history.md`。

权威来源（出现矛盾时以它们为准）：`CLAUDE.md`（架构速览）、根 `AGENTS.md`
与 `DevPulseNative/AGENTS.md`（详细指南）。

## 产品本质

- local-first 原生 macOS 应用 + WidgetKit 扩展；无后端、无云同步、无 GitHub
  API、无 AI、无 Git 写路径。
- 只读本地 Git 元数据：`git status --porcelain=v2 --branch` 与 `git log -1`。
- 产品代码全部在 `DevPulseNative/`。

## 已确认架构设计

- **App ↔ Widget 契约**：应用分析扫描结果，将 JSON snapshot（`AppGroupData`，
  见 `Core/Models.swift`）写入 App Group 容器 `group.local.devpulse`；Widget
  经 `Widget/DevPulseWidget.swift` 内的 `WidgetSnapshotStore` 读取渲染。
  应用只能向 Widget 发起 reload 请求，刷新节奏由系统控制。
- **快照持久化**：所有读写走 `Core/SharedSnapshotStore.swift` / `AppGroupStore`
  （stage + verify + 原子 rename + POSIX 锁 + `.backup` 文件）。**禁止直写容器。**
- **Widget 编译固定 Core 子集**：`Widget/DevPulseWidget.swift`、
  `Core/CommitReadinessEngine.swift`、`Core/CommitReadinessBadge.swift`、
  `Core/ActivityEvent.swift`、`Core/Models.swift`、`Core/PendingItem.swift`、
  `Core/SharedSnapshotStore.swift`、`Utilities/DateFormatting.swift`。Widget
  change 需要使用的源码必须来自此列表（或在 `project.yml` 加源并重新生成）。
- **project.yml 是源**：改 targets / sources / build settings / entitlements →
  改 `project.yml` → `cd DevPulseNative && xcodegen generate`，不手改 `.xcodeproj`。
- **入口与状态**：`App/DevPulseApp.swift`（`@main`，MenuBarExtra + 主窗口）
  持有 `ScanScheduler`（核心状态中枢）与 `LifecycleCoordinator`；还分发
  headless `AppCommand`（`--self-check` 等）供安装/自检脚本使用。
- **刷新管线**：`Core/RefreshEngine.swift`（actor）：
  discovery → coreStatus → extendedInfo → merge → persistence → widgetSync，
  带阶段时间预算与 generation 取消机制。
- **大文件注意**：`Core/Models.swift`（~152 KB，共享数据契约）、
  `Core/ScanScheduler.swift`（~184 KB，调度 + store API）。
- **PendingItem 体系**：模型 + `PendingItemEvaluator` 12 规则为纯逻辑（无 I/O），
  可直接在 CLI 测试中构造 `PendingItemEvaluationContext`，无需 App Group/签名。

## 构建与验证（已确认流程）

- 统一入口 `./scripts/verify.sh`：共享 DerivedData `/tmp/devpulse-build`；
  `build`（编译一次）/ `test <TestClass>`（复用 bundle，秒级）/ `final`
  （构建 + 全量测试）/ `widgetkit`。超时 build 300s / test 600s，可用
  `BUILD_TIMEOUT` / `TEST_TIMEOUT` 覆盖。
- 测试用 **Swift Testing**（`@Test` / `#expect`，`import Testing`），非 XCTest。
  target 名 `DevPulseTests`，源码目录 `DevPulseNativeTests/`。
- 源码 ↔ 测试类映射表：根 `AGENTS.md` 的「Targeted testing」一节。
- 已签名本地安装 + 运行时自检：`scripts/install-and-self-check.sh`（需要签名身份）。

## 已解决的重要问题（避免重复调查）

- Widget 陈旧 / 过期数据渲染 → 已通过后台扫描定时器与 reload 时机修复；
  排障见 `docs/widgetkit-troubleshooting.md`。
- 跨进程并发、扫描数据一致性、刷新完成处理已有专项测试覆盖
  （`CrossProcess*Tests`、`Scan*Tests`、`Refresh*Tests`）。
- 扫描慢仓库、跳过批次数据丢失、重签名丢 App Group 等历史问题均已在近期
  提交中修复并有对应测试（见 `git log`）。

## 避免重复检查的区域

- Widget 接线 / 排障：先读 `docs/widgetkit-troubleshooting.md`。
- 「是否允许」类问题（git 写操作、网络、签名、共享 snapshot 格式）：
  直接查 `AGENTS.md` / `CLAUDE.md` 边界，不必重新推断。
- 常见验证命令与超时语义：见根 `AGENTS.md` 的「Build and Verification」。

## 更新原则

- 仅在确认一项设计 / 事实稳定后追加。
- 不记录单次修复细节（归 `history.md`）。
- 与 `AGENTS.md` / `CLAUDE.md` 矛盾时，以那些权威文件为准并修正本条。
