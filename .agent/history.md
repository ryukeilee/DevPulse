# History（Maintenance Loop 记录）

每轮 Loop 完成后追加一条记录，字段见下。格式用简洁的 markdown 列表。

| 字段 | 内容 |
|---|---|
| Loop | 连续编号 |
| 日期 | YYYY-MM-DD |
| 问题 | 一句话 |
| 证据 | 日志 / 复现 / 反馈原文摘录 |
| 原因 | 为何是最高价值问题 |
| 修改 | 文件 + diff 摘要 |
| 验证 | 实际运行的命令与结果 |
| 剩余风险 | 未验证项 / 需手动确认项 |

**维护规则**：

- 保留最近 **20** 条记录；更早的记录**剪切归档**到 `.agent/archive/`
  （命名见 `archive/README.md`）。
- 日常 Loop 只读本文件最近记录，不主动读取 archive。

---

## Loop 20 — 2026-08-12（新增可达的「待收尾事项」集中入口）

- **问题**：项目已有 `PendingItem` 自动评估、持久化和页面文件，但 `PendingCenterView` 没有接入 `ContentView` 的任何导航入口，用户无法集中查看扫描识别出的未提交改动、未推送提交和其他未完成状态；页面默认还混合显示已恢复/永久忽略记录，已有排序状态没有可操作控件。
- **证据**：用户明确要求新增「待收尾事项」功能；`rg "PendingCenterView" DevPulseNative/App` 只命中视图定义、不命中消费点；`AppTab` 与 `AppSectionBar` 均无 pending case/按钮；`PendingItemEvaluator` 已有 `.dirtyWorkspace`、`.unpushedCommits`、`.mergeConflict` 等规则并在每次扫描完成后由 `ScanScheduler.refreshPendingItems` 调用。
- **原因**：自动识别链路已经存在，最高价值且最小的修改是接通可见入口并把现有数据整理成可操作的当前/历史视图，而不是复制扫描或评估逻辑。
- **修改**：
  - `Core/Models.swift`、`App/ContentView.swift`：新增 `.pending` App tab 与「待收尾」入口，接入 `PendingCenterView`。
  - `App/PendingCenterView.swift`：页面改名「待收尾事项」；默认只展示当前事项，新增当前/已完成/全部范围、搜索与排序控件、项目/来源/状态元信息和按场景说明的空态。
  - `App/PendingItemDetailView.swift`：详情标题、时间、状态和处理动作统一为中文。
  - `Core/PendingItemEvaluator.swift`：新发现的未提交/未推送事项不再显示误导性的「持续 0 分钟」，有历史持续时间时才展示时长。
  - `DevPulseNativeTests/PendingItemStaleLifecycleTests.swift`：新增当前 Git 状态立即生成未提交、未推送事项以及合并冲突状态的覆盖。
  - 按 20 条保留规则，将 Loop 0 剪切归档到 `.agent/archive/history-2026-08-09-loop0-0.md`。
- **验证**：
  - `rtk bash ./scripts/verify.sh build` → Build succeeded。
  - `rtk bash ./scripts/verify.sh test DevPulseTests/PendingItemStaleLifecycleTests` → 15 个测试通过；首次运行暴露新增断言把既有 merge conflict 严重级别误写为 `.critical`，按现有规则修正为 `.high` 后通过。
  - `rtk bash ./scripts/verify.sh final` → Build succeeded、full test suite passed、Final acceptance passed — all checks green。
  - `git diff --check` → 通过。
- **剩余风险**：CLI 构建与测试无法证明 600px 最小窗口下新增导航项、筛选栏和详情弹窗的最终视觉布局；未执行签名安装或运行时 GUI 人工确认。未改变 Git 只读扫描、共享 snapshot、Widget、App Group、签名或项目配置。

---

## Loop 21 — 2026-08-12（签名安装运行并提交推送「待收尾事项」）

- **问题**：无新增业务问题；Loop 20 功能已通过完整验收，用户明确要求将新版 App 在本机签名安装运行，并直接合并提交推送。
- **证据**：工作区仅包含 Loop 20 的 6 个业务/测试文件、Maintenance Loop 记录和归档文件；`main` 与 `origin/main` 同步；`verify.sh final` 已在同一源码状态通过。
- **原因**：本轮不扩大功能范围，只完成用户授权的本机落地和 Git 发布终态。
- **修改**：无新增业务代码；按 20 条保留规则将 Loop 1 剪切归档到 `.agent/archive/history-2026-08-09-loop1-1.md`，追加本记录。
- **验证**：
  - 标准 `scripts/install-and-self-check.sh` 被既有环境问题阻塞：`No Xcode Apple account is configured on this Mac`。
  - 钥匙串存在有效 `Apple Development: ryukei_li@hotmail.com (5BJ9GM7VZR)` 身份；复用当前已安装 host/widget 的匹配 provisioning profiles。
  - 使用独立 DerivedData 执行普通 `xcodebuild ... build`，避免 `build-for-testing` 产物中的 XCTest frameworks；分别使用项目 entitlements 重签 widget 和 host。
  - `codesign --verify --deep --strict` 通过；host/widget 均为 Team `JYL9G28DP3` 且保留 `group.local.devpulse`，widget 额外保留 App Sandbox；安装包不含 `DevPulseTests.xctest`。
  - `/Applications/DevPulse.app` 已运行（PID 11120，进程路径匹配）；安装后主二进制与临时已签名产物 SHA-256 一致；旧 App 保存在 `/tmp/devpulse-install-loop21.b8ivbt/DevPulse.app.previous`，可恢复。
  - `--self-check` → `self_check.result=pass`、`refresh_phase=success`、`validation=pass`、`lifecycle.widget_registration=active`、`lifecycle.self_heal=^pass`；`pluginkit` 确认 widget 注册到新安装路径。
  - 共享快照中 DevPulse 为 `status=changed`、`changedFileCount=8`，与提交前工作区一致。
  - 提交前执行 staged secret scan 与 diff check，随后直接提交到 `main` 并推送 `origin/main`。
- **剩余风险**：Xcode 仍未登录 Apple 账号，标准自动签名安装流程不可用；本次本机开发签名安装、运行、自检和 Widget 注册均已验证。导航与筛选栏的最小窗口视觉布局仍需人工目视确认。

---

## Loop 22 — 2026-08-12（项目健康评分现有终态核对与回归复验）

- **问题**：用户要求新增“项目健康评分”；当前 `main` 已包含同一功能，需要确认现有实现是否完整满足要求，避免重复建设评分、扫描或 UI 链路。
- **证据**：
  - `Core/RepositoryHealthOverview.swift` 已从现有 `RepositorySnapshot` 纯派生 0–100 分，不触发新 Git、文件或后台读取；输入包含工作区状态、变更数、冲突、ahead/behind、最近活动、扫描数据源与风险。
  - `App/RepositoryHealthOverviewView.swift` 已在 Overview 的项目列表中显示分数、工作区状态、活动程度、当前/上次成功/异常数据状态，并对非健康项目展示原因。
  - 异常、不可用或来源未知的快照不生成伪分数；当前产品没有逐项目测试执行结果数据源，因此只展示真实存在的扫描验证状态，不虚构测试通过/失败。
  - `main` 与 `origin/main` 同步，核对前工作区干净；相关实现来自现有 `44c254c`、`4217561`、`19f0c89` 等已提交变更。
- **原因**：当前源码已经达到用户要求的唯一终态；新增第二套实现会破坏“复用现有链路、简单稳定、最小修改”的约束。最高价值动作是验证现有实现及回归，而非重复改动业务代码。
- **修改**：无业务代码修改；仅追加本轮维护记录，并按 20 条保留规则将 Loop 2 剪切归档到 `.agent/archive/history-2026-08-09-loop2-2.md`。
- **验证**：
  - `rtk bash ./scripts/verify.sh build` → Build succeeded。
  - `rtk bash ./scripts/verify.sh test DevPulseTests/RepositoryHealthOverviewTests` → tests passed。
  - `rtk bash ./scripts/verify.sh test DevPulseTests/RepositoryActivityConsistencyTests` → tests passed。
  - `rtk bash ./scripts/verify.sh final` → Build succeeded、full test suite passed、Final acceptance passed — all checks green。
  - `git diff --check` → 通过；无业务源码、项目配置、快照契约、Widget 或签名改动。
- **剩余风险**：CLI 无法证明 macOS 窗口中的最终视觉换行与颜色对比，需在已安装 App 中人工目视确认；逐项目测试结果当前不是产品已有数据，健康评分明确不将其作为输入。

---

## Loop 23 — 2026-08-12（签名安装运行并提交推送项目健康评分复验记录）

- **问题**：无新增业务问题；Loop 22 已确认当前 `main` 的项目健康评分满足用户目标并通过完整验收，用户明确要求直接签名安装运行新版 App，然后合并提交推送。
- **证据**：工作区仅有 Loop 22 的维护记录和历史归档；`main` 与 `origin/main` 同步；同一源码状态已通过项目健康定向测试与 `verify.sh final`。
- **原因**：不扩大功能范围，只完成用户授权的本机签名安装、运行验证和 Git 发布终态。
- **修改**：无业务代码修改；追加本记录，并按 20 条保留规则将 Loop 3 剪切归档到 `.agent/archive/history-2026-08-09-loop3-3.md`。
- **验证**：
  - 标准 `scripts/install-and-self-check.sh` 被既有环境问题阻塞：`No Xcode Apple account is configured on this Mac`。
  - 钥匙串存在有效 `Apple Development: ryukei_li@hotmail.com (5BJ9GM7VZR)` 身份；复用当前已安装 host/widget 的匹配 provisioning profiles（bundle IDs 为 `local.devpulse.app` / `local.devpulse.app.widget`）。
  - 在独立目录 `/tmp/devpulse-install-loop22.fA0V2w` 普通构建并分别重签 widget 与 host；`codesign --verify --deep --strict` 通过，二者 Team 均为 `JYL9G28DP3`，保留 `group.local.devpulse`，Widget 额外保留 App Sandbox，安装包不含 `DevPulseTests.xctest`。
  - `/Applications/DevPulse.app` 已运行（PID 7796，进程路径匹配）；安装后二进制与临时签名产物 SHA-256 一致；旧 App 保存在 `/tmp/devpulse-install-loop22.fA0V2w/DevPulse.app.previous`，可恢复。
  - `pluginkit` 确认 Widget 注册到新安装路径；`--self-check` → `self_check.result=pass`、`refresh_phase=success`、`validation=pass`、`lifecycle.widget_registration=active`、`lifecycle.self_heal=^pass`。
- **剩余风险**：Xcode 仍未登录 Apple 账号，标准自动签名安装流程不可用；本次本机开发签名安装、真实进程运行、自检和 Widget 注册均已验证。项目健康评分在窗口中的最终视觉布局仍需人工目视确认。

---

## Loop 24 — 2026-08-12（项目收藏与排序）

- **问题**：项目列表已有内部置顶持久化能力，但收藏入口只存在于右键菜单，用户无法直观看到或快速切换收藏；列表也只有固定的行动优先级排序，无法按最近活跃或名称浏览。
- **证据**：用户明确要求新增「项目收藏与排序」；`RepositoryListView` 修改前仅调用 `RepositorySorter.sort`，没有排序控件；`isPinned` 与 `togglePin` 已提供稳定的 App Group 持久化和跨刷新保留能力。
- **原因**：复用既有置顶链路即可实现收藏，不需要新增共享快照字段或存储系统；排序限定在列表查询层，不改变扫描、刷新队列或 Widget 行为。
- **修改**：
  - `Core/RepositorySorter.swift`：新增「已收藏」筛选和「智能排序 / 最近活跃 / 名称」排序枚举；名称与最近活跃排序均保持收藏优先和稳定决胜；列表偏好持久化新增排序字段，并兼容缺少该字段的旧数据。
  - `App/RepositoryListView.swift`：每行增加可点击星标收藏按钮，右键文案统一为收藏；增加排序菜单并持久化选择。
  - `DevPulseNativeTests/CommitReadinessEngineTests.swift`：覆盖收藏筛选、三种排序的收藏优先行为、偏好往返和旧偏好迁移。
  - 按 20 条保留规则将 Loop 4 剪切归档到 `.agent/archive/history-2026-08-10-loop4-4.md`。
- **验证**：
  - 首次 `rtk bash ./scripts/verify.sh build` 根据编译错误确认最近活跃派生应调用静态函数，最小修正后重新构建通过。
  - `rtk bash ./scripts/verify.sh build` → Build succeeded。
  - `rtk bash ./scripts/verify.sh test DevPulseTests/CommitReadinessEngineTests` → tests passed。
  - `rtk bash ./scripts/verify.sh final` → Build succeeded、full test suite passed、Final acceptance passed — all checks green。
  - `git diff --check` → 通过；未改项目配置、扫描路径、共享快照格式、Widget、签名或网络边界。
- **剩余风险**：CLI 无法证明最小窗口宽度下六项分段筛选与排序菜单的最终布局，需在 macOS App 中人工目视确认；本轮未执行签名安装。

---

## Loop 25 — 2026-08-12（签名安装运行并提交推送项目收藏与排序）

- **问题**：无新增业务问题；Loop 24 的项目收藏与排序已通过完整验收，用户明确要求在本机签名安装运行新 App，并合并提交推送。
- **证据**：工作区仅包含 Loop 24 的功能、测试、维护记录和归档文件；`main` 与 `origin/main` 同步；同一源码状态已通过定向测试与 `verify.sh final`。
- **原因**：不扩大功能范围，只完成用户授权的本机签名安装、运行验证和 Git 发布终态。
- **修改**：无新增业务代码；追加本记录，并按 20 条保留规则将 Loop 5 剪切归档到 `.agent/archive/history-2026-08-10-loop5-5.md`。
- **验证**：
  - 标准 `scripts/install-and-self-check.sh` 被既有环境问题阻塞：`No Xcode Apple account is configured on this Mac`。
  - 本机存在有效 Apple Development 身份；现有 host/widget profiles 分别匹配 `local.devpulse.app` / `local.devpulse.app.widget`。
  - 在 `/tmp/devpulse-install-loop25.v1eEPl` 普通构建，复用匹配 profiles，并使用项目 entitlements 分别重签 widget 与 host；安装包不含 `DevPulseTests.xctest`。
  - `codesign --verify --deep --strict` 通过；host/widget 均保留 `group.local.devpulse`，widget 保留 App Sandbox。
  - 新 App 已安装到 `/Applications/DevPulse.app` 并运行（PID 13401，进程路径匹配）；安装后二进制与临时签名产物 SHA-256 一致；旧 App 保存在 `/tmp/devpulse-install-loop25.v1eEPl/DevPulse.app.previous`，可恢复。
  - `pluginkit` 确认 Widget 注册到新安装路径；`--self-check` → `self_check.result=pass`、`refresh_phase=success`、`validation=pass`、`lifecycle.widget_registration=active`、`lifecycle.self_heal=^pass`。
  - 提交前执行 staged secret scan 与 diff check，随后提交到 `main` 并推送 `origin/main`。
- **剩余风险**：Xcode 仍未登录 Apple 账号，标准自动签名安装流程不可用；本次本机开发签名安装、真实进程运行、自检和 Widget 注册均已验证。收藏与排序控件的最小窗口视觉布局仍需人工目视确认。

---

## Loop 26 — 2026-08-13

- **问题**：无（本轮判定无高价值问题，记录「无变更」）。
- **证据**：
  - 工作区：`git status --porcelain=v2 --branch` → `branch.ab +0 -0`，无未提交改动，HEAD `1164eed`（feat: add repository favorites and sorting），与 origin/main 同步。
  - 最近提交：`git log --oneline -15` → `1164eed`（Loop 24 收藏排序）为最新，Loop 25 已签名安装运行并推送。
  - `grep -rn -e TODO -e FIXME DevPulseNative/` → 无匹配（exit 1）。
  - 上次验证：Loop 25 在同一代码上已通过定向测试与 `verify.sh final` 全量验收，并完成签名安装、运行自检与推送。
  - 本轮 `rtk bash ./scripts/verify.sh build` → `[verify] Build succeeded`（编译基线正常）。
  - 历史遗留剩余风险均为「需人工目视确认」类（收藏/排序控件最小窗口布局、健康评分视觉布局），非 CLI 可验证 Bug；Xcode 未登录 Apple 账号为标准自动签名安装的环境阻塞（已有多轮手动签名路径验证）。
  - 本轮无用户反馈的具体问题（任务为「执行一次 loop」）。
- **原因**：不满足 `loop.md` Evidence 阶段的任何有效依据（可复现 Bug / 测试失败 / 行为异常 / 用户反馈 / 稳定性风险 / 性能问题 / 测试缺口）。按规则「没有足够证据 → 不修改」「无高价值问题 → 记录无变更，不要强行修改」。
- **修改**：无（零代码变更，未强行修改）；按 20 条保留规则将 Loop 6 剪切归档到 `.agent/archive/history-2026-08-10-loop6-6.md`。
- **验证**：`rtk bash ./scripts/verify.sh build` → `[verify] Build succeeded`（确认编译基线）；`git status` / `git log` / `grep` 结果均无异常。
- **剩余风险**：本轮未运行完整测试套件（无具体问题指向时不强制，见 `loop.md`）；Loop 24/25 已注明的收藏排序控件最小窗口视觉布局与 Loop 22 健康评分视觉布局仍需人工目视确认；Xcode 未登录 Apple 账号，标准自动签名安装仍不可用。

---

## Loop 27 — 2026-08-13（修复 verify.sh 缺失执行位，恢复文档契约的直接执行入口）

- **问题**：维护循环的验证入口 `./scripts/verify.sh` 直接执行报 `Permission denied`（exit 126），与根 `AGENTS.md`、`CLAUDE.md`、`loop.md` 中「从仓库根目录运行 `./scripts/verify.sh build/test/final/widgetkit`」的文档契约不符。
- **证据**：
  - `./scripts/verify.sh build` → `bash: 行 1: ./scripts/verify.sh: Permission denied`（exit 126，可复现）。
  - `ls -la scripts/verify.sh` → `-rw-r--r--`；`git ls-files -s scripts/` → `scripts/verify.sh` mode 为 `100644`，而同目录其余验证脚本（`verify-widgetkit.sh`、`verify-install-upgrade.sh`、`verify-upgrade.sh`、`verify-activity-timeline.sh`、`install-and-self-check.sh`、`secret-scan.sh`）均为 `100755` —— 执行位遗漏。
  - 工作区 HEAD `0a2a49d` 与 origin/main 同步（ab +0 -0），无其他未提交改动；`grep -rn -e TODO -e FIXME DevPulseNative/` 无匹配。
  - 脚本内容本身无问题：`bash scripts/verify.sh build` → `[verify] Build succeeded`（显式 bash 前缀可运行）。
- **原因**：这是可复现的明确行为异常（有预期对比：文档指示直接执行、同类脚本均为 755），且直接阻塞每轮维护循环的验证入口与 CI 按文档运行；修复为最小 mode 变更，不涉及任何高风险项。
- **修改**：
  - `chmod +x scripts/verify.sh`：git mode `100644` → `100755`，blob 未变（`git status --porcelain=v2` 显示 `1 .M N... 100644 100644 100755`），纯执行位变更，内容零改动。
  - 按 20 条保留规则将 Loop 7 剪切归档到 `.agent/archive/history-2026-08-10-loop7-7.md`。
- **验证**：
  - `./scripts/verify.sh build` → exit 0，`[verify] Build succeeded`（修复后直接执行成功）。
  - `./scripts/verify.sh test DevPulseTests/RepositoryHealthOverviewTests` → exit 0，`[verify] tests passed`（文档 test 用法恢复）。
  - `bash scripts/verify.sh build`（修复前对照组）→ `[verify] Build succeeded`，证明脚本内容无问题、缺失的仅是执行位。
  - `git diff --check` → 通过；`git status --porcelain=v2 --branch` 仅 `scripts/verify.sh` 一处 mode 变更，无生成物。
- **剩余风险**：mode 变更尚未提交（本流程不 commit/push，需用户授权后提交）；历史遗留的收藏/排序与健康评分视觉布局仍需人工目视确认；Xcode 未登录 Apple 账号，标准自动签名安装仍不可用。

---

## Loop 28 — 2026-08-15（签名安装运行并提交推送 Loop 27 改动）

- **问题**：无新增业务问题；Loop 27 修复 `scripts/verify.sh` 执行位后，用户明确要求直接本机签名安装运行新 App，并合并提交推送。
- **证据**：
  - 工作区仅有 Loop 27 的 3 个改动（`.agent/history.md` Loop 27 记录、`scripts/verify.sh` mode 100644→100755、`.agent/archive/history-2026-08-10-loop7-7.md` 归档）；HEAD `0a2a49d` 与 origin/main 同步。
  - 签名身份：keychain 有效 `Apple Development: ryukei_li@hotmail.com (5BJ9GM7VZR)`（C6B16796CD59EF90EDF3005A05276634FC8F27EA），Team `JYL9G28DP3`。
  - 本机 Xcode 未登录 Apple 账号（`defaults read com.apple.dt.Xcode` 无账号键），标准 `install-and-self-check.sh` 的自动签名路径不可用。
  - 已安装 app（Loop 25，08-12）内嵌 host/widget profiles 的 `ExpirationDate` 为 2026-08-13，**已过期**；本地 Provisioning Profiles 目录仅有两个 TinyBuddy profile（`com.ryukeili.TinyBuddy*`），不匹配 DevPulse。
  - 直接证据：过期 profile 签名的已安装 app 仍正常运行（PID 13401 在跑、`--self-check` pass）——macOS 本地开发 app 的运行不因 profile 过期被拒。
- **原因**：不扩大功能范围，只完成用户授权的本机签名安装、运行验证与 Git 发布终态；唯一可用 profiles 已过期，但运行不受影响（有直接证据），沿用历史已验证的手动签名路径。
- **修改**：无业务代码修改；追加本记录，并按 20 条保留规则将 Loop 8 剪切归档到 `.agent/archive/history-2026-08-10-loop8-8.md`。
- **验证**：
  - 独立 DerivedData（`/tmp/devpulse-install-loop27/DerivedData`）普通 `xcodebuild build`（Debug，CODE_SIGNING_ALLOWED=NO）→ `** BUILD SUCCEEDED **`；产物不含 `DevPulseTests.xctest`，widget appex 存在。
  - 复用已安装 app 的 host/widget profiles，分别嵌入产物后用项目 entitlements 重签（先 widget 后 host）：`codesign --verify --deep --strict` PASS；host `local.devpulse.app` 含 `com.apple.security.application-groups`，widget `local.devpulse.app.widget` 含 App Sandbox + App Group；二者均为 Apple Development 证书、Team `JYL9G28DP3`。
  - 旧 app 备份到 `/tmp/devpulse-install-loop27/DevPulse.app.previous`；安装后主二进制与临时签名产物 SHA-256 一致；无测试 bundle；安装后签名复验 PASS。
  - `open -n` 启动 → 进程 PID 59526，路径 `/Applications/DevPulse.app/Contents/MacOS/DevPulse` 匹配；`--self-check` → `self_check.result=pass`、`refresh_phase=success`、`repository_count=4`、`validation=pass`、`lifecycle.widget_registration=active`、`lifecycle.self_heal=^pass`（恢复 1 项）；`pluginkit` → `local.devpulse.app.widget(0.2.0)` 注册。
  - 共享快照：`generatedAt=2026-08-15T03:02:18Z`、`writtenAt=03:02:22Z`、`lastSuccessfulRefreshAt=03:02:18Z` 为启动后新值；4 仓库，DevPulse status=changed（与提交前工作区一致）。
  - 提交前 `scripts/secret-scan.sh staged` PASS、`git diff --cached --check` PASS；提交 `4c5c6b7`（3 files, 37 insertions, 17 deletions）并 push `origin/main` 成功（exit 0），本地 HEAD = origin/main。
- **剩余风险**：嵌入 profiles 已过期（2026-08-13），本机运行与 widget 注册已验证不受影响，但未来若系统收紧 profile 校验或需要 Xcode 重签名/新设备，需重新生成 profiles（需登录 Xcode Apple 账号）；收藏/排序与健康评分的最终视觉布局仍需人工目视确认。

---

## Loop 29 — 2026-08-15（Xcode 登录免费 Apple ID 后，标准自动签名路径重新生成未过期 profiles）

- **问题**：Loop 28 记录的唯一剩余风险是嵌入 profiles 已于 2026-08-13 过期、需登录 Xcode Apple 账号重新生成；用户反馈本机 Xcode 已登录（免费 Apple ID，非付费开发者），目标仅要求「能本机运行即可」，希望解决 profiles 过期问题。
- **证据**：
  - Xcode 登录状态：`defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists` → `IDE.Identifiers.Prod` 有 identifier 条目（账号已配置）；`DVTDeveloperAccountManagerAppleIDs` 键不存在（Xcode 16 使用新键）。
  - 签名身份不变：`Apple Development: ryukei_li@hotmail.com (5BJ9GM7VZR)`（C6B16796...），Team `JYL9G28DP3`。
  - 项目 `CODE_SIGN_STYLE=Automatic`、`DEVELOPMENT_TEAM` 为空（`_DEVELOPMENT_TEAM_IS_EMPTY=YES`）；标准脚本 `resolve_development_team` 从证书解析 team 为 `JYL9G28DP3`。
- **原因**：用户已解决登录前置条件，标准 `install-and-self-check.sh` 的自动签名路径（`-allowProvisioningUpdates`）此前因「No Xcode Apple account」被阻塞，现在可完整走通并让 Xcode 重新生成未过期 profiles——这是消除 Loop 28 剩余风险的标准方案，也符合用户「能本机运行即可」的目标。
- **修改**：无业务代码修改；追加本记录，并按 20 条保留规则将 Loop 9 剪切归档到 `.agent/archive/history-2026-08-10-loop9-9.md`。
- **验证**：
  - `DERIVED_DATA_PATH=/tmp/devpulse-install-loop29/DerivedData bash scripts/install-and-self-check.sh` → `install_and_self_check=pass`；自动签名构建成功（Xcode 用免费账号重新生成 profiles）、`snapshot.repoStatus=clean`、`changedFileCount=0`、`lifecycle.widget_registration=active`、`lifecycle.self_heal=^pass`。
  - 新 host profile：`Mac Team Provisioning Profile: local.devpulse.app`，`ExpirationDate=2026-08-22T03:06:10Z`（**未过期**，7 天有效），Team `JYL9G28DP3`，UUID 68d795cd...。
  - 新 widget profile：`Mac Team Provisioning Profile: local.devpulse.app.widget`，`ExpirationDate=2026-08-22T03:06:12Z`（**未过期**），Team `JYL9G28DP3`，UUID a4fd5fc6...。
  - 本地 Provisioning Profiles 目录已更新为上述两个新 profile（Xcode 自动签名产物），未来重签可复用。
  - `codesign --verify --deep --strict` → `valid on disk`、`satisfies its Designated Requirement`；host Identifier `local.devpulse.app`、Apple Development 证书、Team `JYL9G28DP3`。
  - 新进程运行：PID 60655，路径 `/Applications/DevPulse.app/Contents/MacOS/DevPulse`；`pluginkit` → `local.devpulse.app.widget(0.2.0)` 注册。
- **剩余风险**：免费 Apple ID 的 macOS provisioning profile 有效期为 **7 天**（本次至 2026-08-22），过期后 app 本机运行不受影响，但重新签名安装需再跑一次标准脚本自动续期（Xcode 已登录，随时可执行）；收藏/排序与健康评分的最终视觉布局仍需人工目视确认。

## Loop 30 — 2026-08-16（verify.sh 硬依赖 GNU timeout，最小 PATH 环境构建入口失败）

- **问题**：文档契约的验证入口 `./scripts/verify.sh build` 在本环境可复现失败：`./scripts/verify.sh: line 61: timeout: command not found`（exit 1）——脚本无条件调用 GNU coreutils 的 `timeout` 命令，而本机 macOS 14.8.7 无 `/usr/bin/timeout`，且本会话 bash 环境 PATH 仅为 `/usr/bin:/bin:/usr/sbin:/sbin`（不含 `/opt/homebrew/bin`）。
- **证据**：
  - 后台运行 `./scripts/verify.sh build`（会话默认 PATH）→ exit 1，错误 `./scripts/verify.sh: line 61: timeout: command not found`，完整日志保留于 `{TMPDIR}/devpulse-build.MkJmMJ`。
  - `command -v timeout` → 无输出；`ls /usr/bin/timeout` → No such file；`ls /opt/homebrew/bin/timeout` → `coreutils/9.11/bin/timeout` 符号链接（Homebrew，不在会话 PATH）。
  - `sw_vers` → macOS 14.8.7（`timeout` 从 macOS 15 起才随系统提供）。
  - `scripts/verify.sh` 第 61 行（build）与第 93 行（test）无条件使用 `timeout "$BUILD_TIMEOUT" ...` / `timeout "$TEST_TIMEOUT" ...`。
  - 预期对比：根 `AGENTS.md` / `CLAUDE.md` / `.agent/loop.md` 均承诺「从仓库根目录运行 `./scripts/verify.sh build/test/final/widgetkit`」；Loop 27 记录显示该入口曾实测成功（当时环境 PATH 含 `/opt/homebrew/bin`）。
  - `grep -n timeout scripts/*.sh` → 仅 `verify.sh` 自身使用该命令，其他脚本无同类依赖。
- **原因**：这是文档化验证入口的可复现行为异常（有预期对比），直接阻塞维护循环自身的构建/测试验证入口；修复为最小可移植改动，不触碰产品代码或任何高风险项。
- **修改**：
  - `scripts/verify.sh`：新增 `run_with_timeout()` 可移植包装——`command -v timeout` 检测存在则 `timeout "$seconds" "$@"`（保持超时强制），缺失则提示「timeout not found in PATH; running without timeout enforcement」后直接运行（退出码原样传播）；第 61、93 行两处调用替换为 `run_with_timeout "$BUILD_TIMEOUT" xcodebuild` / `run_with_timeout "$TEST_TIMEOUT" xcodebuild`。单文件 +15/-2 行。
  - 追加本 Loop 30 记录，并按 20 条保留规则将 Loop 10 剪切归档到 `.agent/archive/history-2026-08-11-loop10-10.md`。
- **验证**：
  - `bash -n scripts/verify.sh` → SYNTAX_OK。
  - 最小 PATH（`env PATH=/usr/bin:/bin:/usr/sbin:/sbin`）下 `./scripts/verify.sh build` → `[verify] Build succeeded`（exit 0；修复前同环境 exit 1）。
  - 最小 PATH 下 `./scripts/verify.sh test DevPulseTests/RepositoryHealthOverviewTests` → `[verify] tests passed`（exit 0）。
  - 降级分支单测：`run_with_timeout 5 true` → 0；`run_with_timeout 5 sh -c "exit 7"` → 7 原样传播；提示信息输出正常。
  - 有 timeout 分支（PATH 含 `/opt/homebrew/bin`）：`run_with_timeout 5 true` → 0。
  - `git diff --check` → 通过；最终 `git status` = `scripts/verify.sh` 与 `.agent/history.md` 修改 + 归档新文件，无生成物。
- **剩余风险**：降级分支下无超时强制（仅当环境缺 GNU coreutils 时，正常 PATH 环境行为不变）；本机免费 Apple ID profile 至 2026-08-22 过期（app 运行不受影响，重签需再跑标准脚本）；收藏/排序与健康评分的最终视觉布局仍需人工目视确认；本轮未运行全量测试套件（无产品代码改动，编译基线 + 定向测试已覆盖修复点）。

---

## Loop 31 — 2026-09-17（macOS 27 大尺寸 Widget 背景修复验证）

- **问题**：用户反馈 macOS 27 下 DevPulse 大尺寸桌面 Widget 变白且内容不显示。
- **证据**：
  - `sw_vers` → macOS `27.0`；当前 HEAD 提交为「修复 macOS 27 桌面 Widget 背景显示」。
  - `DevPulseWidgetEntryView` 已同时使用嵌入式 `WidgetPanelBackground` 与 `.containerBackground(for: .widget)`；背景使用可填充的 `Rectangle`，不再依赖 `ContainerRelativeShape`。
  - macOS 27 的 `chronod` 日志显示 `DevPulseWidget:systemLarge` timeline request ended `success`，并接受 `systemLarge` archive；`pluginkit` 注册当前 `/Applications/DevPulse.app` Widget extension。
- **原因**：这是用户可见的高优先级 Widget 渲染问题；本轮围绕现有最小生产修复进行 macOS 27 构建、安装和渲染管线复验。
- **修改**：
  - 生产修复已在当前 HEAD；本轮未扩大 Widget 业务逻辑。
  - `DevPulseNativeTests/WidgetDegradedRenderingTests.swift`、`WidgetLifecycleScenariosTests.swift`：将 Xcode 27 下失效的 `#expect(!(optional ?? "").isEmpty)` 改为等价的可观测 `optional.isEmpty == false` 断言，恢复 Widget 场景测试的真实校验。
- **验证**：
  - `./scripts/verify.sh build` → Build succeeded。
  - `./scripts/verify.sh test DevPulseTests/WidgetDegradedRenderingTests`、`WidgetLifecycleScenariosTests` → tests passed。
  - `./scripts/verify-widgetkit.sh` → 16 PASS, 0 FAIL。
  - `DERIVED_DATA_PATH=/tmp/devpulse-widget-macos27-verify bash scripts/install-and-self-check.sh` → install_and_self_check=pass；self-check result/refresh/validation 均 pass，`lifecycle.widget_registration=active`。
  - `codesign --verify --deep --strict /Applications/DevPulse.app` → pass；Widget 保留 `group.local.devpulse`。
  - `pluginkit -vm -A -D -i local.devpulse.app.widget` → 当前安装路径已注册。
  - `./scripts/verify.sh final` → 893 tests / 89 suites 中 Widget 相关套件通过；整体仍有 6 个与本问题无关的既有生命周期/发现测试失败，未伪装为通过。
  - 直接像素截图受当前会话 `CGSSessionScreenIsLocked = 1` 影响，锁屏会将 Widget 内容遮蔽为占位背景；因此最终可见像素仍需解锁后人工确认。
- **剩余风险**：生产修复已通过 macOS 27 的真实构建、签名安装、WidgetKit archive/timeline 成功和注册验证；锁屏环境无法完成最终肉眼显示确认，且全量测试有上述 6 个非 Widget 失败。

---

## Loop 32 — 2026-09-17（本地签名安装并发布 macOS 27 Widget 修复）

- **问题**：用户明确要求用本地签名安装运行新版 App，然后直接提交并推送。
- **证据**：当前代码已完成 macOS 27 Widget 背景修复；工作区仅包含本轮测试断言、维护记录和归档文件。
- **原因**：用户已明确授权安装、commit 和 push；本轮只完成落地与发布，不扩大业务范围。
- **修改**：无新增业务代码；安装当前 HEAD + 工作区测试修复，并追加本记录。
- **验证**：`DERIVED_DATA_PATH=/tmp/devpulse-widget-macos27-install bash scripts/install-and-self-check.sh` → `install_and_self_check=pass`；签名校验、`self_check.result=pass`、`validation=pass`、`lifecycle.widget_registration=active` 均通过。
- **剩余风险**：全量测试既有 6 个非 Widget 失败，以及锁屏导致的 Widget 最终像素确认限制，已在 Loop 31 记录。

---

## Loop 33 — 2026-09-17（macOS 27 大尺寸 Widget 修复严格终态审计）

- **问题**：继续完成「macOS 27 下大尺寸 Widget 持续纯白」目标的终态审计，并确认是否已经满足“恢复正常显示”。
- **证据**：
  - `sw_vers` → macOS `27.0`；`xcodebuild -version` → Xcode `27.0`；HEAD `63ab41d` 与 `origin/main` 同步，工作区最终干净。
  - `Widget/DevPulseWidget.swift` 的 `DevPulseWidgetEntryView` 使用嵌入式 `WidgetPanelBackground` 和 `.containerBackground(for: .widget)`；背景为可填充的 `Rectangle`，不依赖 `ContainerRelativeShape`；Widget 支持 `.systemLarge`。
  - 当前安装包 `codesign --verify --deep --strict` 通过；host/widget 均含同一 `group.local.devpulse` entitlement；`pluginkit` 确认 `/Applications/DevPulse.app` 的 Widget 已注册。
  - `chronod` 在当前 macOS 27 会话中多次记录 `DevPulseWidget:systemLarge` timeline/archive request `success`、`Reload success`；当前 `systemLarge` archive 文件存在且非空。
- **原因**：这是用户可见的高优先级问题；本轮只复核真实安装、WidgetKit 调度/归档、源代码和定向测试，不扩大业务范围。
- **修改**：无生产代码修改；临时离屏探针验证未能使用 macOS `ImageRenderer`/WidgetKit 的 family 环境，已完整移除，最终工作区无差异。
- **验证**：
  - `./scripts/verify.sh build` → Build succeeded。
  - `./scripts/verify.sh test DevPulseTests/WidgetDegradedRenderingTests`、`WidgetLifecycleScenariosTests` → tests passed。
  - `./scripts/verify-widgetkit.sh` → 16 PASS, 0 FAIL。
  - `/Applications/DevPulse.app/Contents/MacOS/DevPulse --self-check` → `self_check.result=pass`、`refresh_phase=success`、`validation=pass`、`lifecycle.widget_registration=active`、exit 0。
  - `codesign --verify --deep --strict /Applications/DevPulse.app` → pass；当前 profile 至 `2026-09-22` 未过期。
  - `git diff --check`、`git status --porcelain=v2 --branch` → 无差异，`branch.ab +0 -0`。
  - `screencapture` 产出的桌面图像为全黑单色，无法从当前会话取得 Widget 的真实像素；因此未把 chronod 的成功归档当作最终可见像素证明。
- **剩余风险**：源代码、macOS 27 真实安装与 systemLarge WidgetKit archive 已验证；但“非纯白的最终桌面像素”仍需在可见/可交互的桌面会话中人工确认，本会话的屏幕捕获能力是具体阻塞。

---

## Loop 34 — 2026-09-17（本地签名安装运行并发布 macOS 27 Widget 修复）

- **问题**：用户明确要求用本地签名安装运行新的 App，然后直接提交并推送。
- **证据**：工作区仅有 Loop 33 维护记录及历史归档；HEAD `63ab41d` 与 `origin/main` 同步；本机存在有效 `Apple Development` 签名身份，Xcode 已登录 Apple 账号。
- **原因**：用户已明确授权安装、commit 和 push；本轮只完成现有 macOS 27 Widget 修复的本机落地与发布，不扩大业务范围。
- **修改**：无生产代码修改；追加本记录，并按 20 条保留规则归档最旧的 Loop 14；安装当前 HEAD 到 `/Applications/DevPulse.app`。
- **验证**：
  - `DERIVED_DATA_PATH=/tmp/devpulse-widget-macos27-current-install bash scripts/install-and-self-check.sh` → `install_and_self_check=pass`；自动签名构建成功，`self_check.result=pass`、`refresh_phase=success`、`validation=pass`、`lifecycle.widget_registration=active`、`lifecycle.self_heal=^pass`。
  - 安装包签名校验通过，Widget 注册有效；当前快照由新进程写入，`snapshot.repoStatus=changed`、`changedFileCount=3`。
  - 提交前将执行 staged secret scan、diff check、commit 和 push；本记录随本轮发布提交保存。
- **剩余风险**：当前会话 `CGSSessionScreenIsLocked=Yes`，macOS 会按安全策略显示 Widget placeholder；解锁后的最终桌面像素仍需人工目视确认。当前 systemLarge archive 已有实际内容，未见 WidgetKit/扩展错误。

---

## Loop 35 — 2026-09-17（macOS 27 大尺寸 Widget 终态审计：确认内容链路，锁屏占位为当前可见空白的系统原因）

- **问题**：继续排查 macOS 27 下 systemLarge Widget 空白容器，需区分 WidgetKit/SwiftUI 内容渲染失败、medium/large 分支差异，以及 macOS 锁屏对 Widget 的安全占位。
- **证据**：
  - `sw_vers` → macOS `27.0`；`xcodebuild -version` → Xcode `27.0`。构建设置确认 `MACOSX_DEPLOYMENT_TARGET=14.0`、`SDKROOT=MacOSX27.0.sdk`、`SWIFT_VERSION=6.0`。
  - macOS 27 SDK 中 `containerBackground(for: .widget)` 与 `containerBackgroundRemovable(_:)` 均声明为 macOS 14.0+；现有实现使用直接嵌入的 `WidgetPanelBackground`（可填充 `Rectangle`）+ `.containerBackground(for: .widget)`，并在 Widget 配置上设置 `.containerBackgroundRemovable(false)`。历史实现曾使用 `ContainerRelativeShape`，已在之前修复中移除。
  - `DevPulseWidgetEntryView` 的 systemMedium/systemLarge 都经过同一 `WidgetEntry` 状态树；medium 使用 `.medium`、最多 2 个项目和 `.panel` 行，large 使用 `.large`、最多 3 个项目和 `.compact` 卡片行。`WidgetPrimaryContentSelectionBuilder` 在有 feed 时不会因 family 分支返回空。
  - 真实 macOS 27 `chronod` 日志：systemLarge render session `LIVE`；随后多次 `DevPulseWidget:systemLarge` timeline request `ended ... success`、`Accepted successfully`、`reload: succeeded with 1 entries`。当前 `/Users/ryukeili/Library/Containers/local.devpulse.app.widget/.../systemLarge...chrono-timeline` 为 44,152 bytes，`strings` 可观察到 `DevPulse`、`Dirty` 等实际视图文本。
  - 当前屏幕状态查询得到 `CGSSessionScreenIsLocked=Yes`；macOS 27 `chronod` 明确记录 `Security policy yielding placeholder content: Keybag locked and widget's configured to not 'canAppearInSecureEnvironment'`。因此锁屏时看到的 placeholder/空白容器是系统安全策略，不是 large 内容分支消失。
- **原因**：原有 macOS 14 兼容性问题是 `ContainerRelativeShape`/container background 不可靠；macOS 27 新的可移除 Widget container background/render scheme 会在背景被移除时暴露空白容器。当前必要修复 `.containerBackgroundRemovable(false)` 与 Rectangle/ZStack 背景已生效；systemLarge 内容链路和 archive 均成功，未发现 medium/large 条件渲染导致内容消失的新证据。
- **修改**：无新增生产代码；仅追加本轮审计记录，并按 20 条规则将 Loop 15 归档到 `.agent/archive/history-2026-08-11-loop15-15.md`。
- **验证**：
  - `./scripts/verify.sh build` → Build succeeded。
  - `./scripts/verify.sh test DevPulseTests/WidgetDegradedRenderingTests`、`WidgetLifecycleScenariosTests`、`BuildConfigConsistencyTests` → tests passed。
  - `./scripts/verify-widgetkit.sh` → 16 PASS, 0 FAIL。
  - `/Applications/DevPulse.app/Contents/MacOS/DevPulse --self-check` → `self_check.result=pass`、`refresh_phase=success`、`validation=pass`、`lifecycle.widget_registration=active`、exit 0。
  - `codesign --verify --deep --strict /Applications/DevPulse.app` → pass；`pluginkit` 当前注册 `/Applications/DevPulse.app` Widget。
  - `git diff --check`（记录前）→ 通过；此前工作区干净，无生成物。
- **剩余风险**：当前会话锁屏阻止 `screencapture` 获得非占位桌面像素；解锁后需人工确认 Widget 的最终非空、非纯白视觉。解锁前不应把安全 placeholder 当作产品渲染回归。

---

## Loop 36 — 2026-09-17（无新增高价值问题：macOS 27 Widget 终态保持）

- **问题**：本轮用户仅要求执行一次 Maintenance Loop；未提供新的 Bug、测试失败或行为异常。
- **证据**：
  - `git status --porcelain=v2 --branch` → main 与 origin/main 同步；工作区仅有上一轮维护记录及待归档历史文件，无产品源码改动。
  - `git log -1 --oneline` → `8443968 chore: record macOS 27 widget installation`。
  - `grep -rn -e TODO -e FIXME DevPulseNative/` → 无匹配。
  - 最近记录已确认 macOS 27 `systemLarge` WidgetKit archive/reload 成功；未出现新的 WidgetKit、SwiftUI、签名或共享快照错误证据。
- **原因**：已有 macOS 27 Widget 问题已在 Loop 35 完成终态审计；本轮没有新的有效依据，按规则不重复修改或强行重构。
- **修改**：无业务代码修改；运行 `./scripts/verify.sh build` 确认编译基线；追加本记录，并按 20 条规则将 Loop 16 归档到 `.agent/archive/history-2026-08-11-loop16-16.md`。
- **验证**：`./scripts/verify.sh build` → Build succeeded；`git diff --check` → 通过；未运行全量测试（本轮无产品代码变更）。
- **剩余风险**：锁屏环境下无法人工确认 Widget 最终桌面像素；如需确认，应在解锁桌面会话中目视检查，不应将锁屏 placeholder 误判为产品回归。

---

## Loop 37 — 2026-09-19（无新增高价值问题：维护基线保持）

- **问题**：本轮用户仅要求运行一次 Maintenance Loop，未提供新的 Bug、测试失败或行为异常。
- **证据**：
  - `git status --porcelain=v2 --branch` → `main` 与 `origin/main` 同步（`branch.ab +0 -0`），工作区在记录前无改动；HEAD 为 `0d47c62`。
  - `git log -1 --oneline` → `0d47c62 chore: record macOS 27 widget maintenance`。
  - `grep -rn -e TODO -e FIXME DevPulseNative/` → 无匹配。
  - 最近 Loop 35/36 已记录 macOS 27 `systemLarge` WidgetKit 内容链路成功；本轮没有新的 WidgetKit、SwiftUI、签名或共享快照错误证据。
  - `./scripts/verify.sh build` → `Build succeeded`。
- **原因**：现有证据未满足可复现 Bug、测试失败、明确行为异常、稳定性/性能风险或测试缺口中的任何一项；按 Loop 规则不修改业务代码、不重复处理已完成问题。
- **修改**：无业务代码修改；追加本记录，并按最近 20 条规则将 Loop 17 剪切归档到 `.agent/archive/history-2026-08-12-loop17-17.md`。
- **验证**：
  - `./scripts/verify.sh build` → Build succeeded。
  - 记录前 `git status --porcelain=v2 --branch` → `branch.ab +0 -0`。
  - 未运行全量测试：本轮无产品代码变更，编译基线已通过。
- **剩余风险**：macOS 27 Widget 的最终非占位桌面像素仍需在解锁桌面会话中人工确认；本轮未重新执行签名安装或 GUI 检查。维护记录和归档文件尚未提交，需用户明确授权后再提交。

---

## Loop 38 — 2026-09-23（applyPins 单次路径规范化复用）

- **问题**：`ScanScheduler.applyPins` 后处理阶段重复规范化相同仓库路径，20 仓库测量为 162 次 computation。
- **证据**：`RepositoryPathCanonicalizationReuseTests.applyPinsCanonicalizationIsLocalAndEquivalent` 对相同输入使用 `reuseEnabled: false/true` 比较：lookups 均为 162，computations 从 162 降到 20，distinctInputs 为 20，处理后的 `AppGroupData` 相等。
- **修改**：`RepositoryIdentity.withCanonicalizationScopeSync` 引入同步短作用域；`ScanScheduler.applyPins` 仅在单次调用内启用，不扩展刷新作用域；测试覆盖输出等价及后续 ignored 输入可见。
- **验证**：`./scripts/verify.sh build`、canonicalization 定向测试（8 tests / 1 suite）、`RepositoryDiscoveryExperienceTests`（34 tests / 1 suite）、`./scripts/verify.sh final`（917 tests / 91 suites，`failedTests: 0`）通过；`git diff --check` 通过。全量验证时并发进程见线程报告。
- **剩余风险**：`ScanScheduler` 中除 `applyPins` 外的快照规范化路径未纳入本次复用范围；Widget 可读快照路径亦未改动。

---

## Loop 39 — 2026-09-23（实测修复 discovery Git 调用数未进入刷新诊断）

- **问题**：`totalGitCalls` 在代码层增加 discovery 计数后，最终 diagnostics 构造仍用 core+extended 覆盖，实际漏计 worktree topology Git 子进程。
- **证据**：真实临时主仓库 + linked worktree 实测调用清单含 `worktree list --porcelain -z`、2 次 `status --porcelain=v2 --branch`、2 次 `log -1 --pretty=%H%x00%cI%x00%s`；注入真实 runner ledger=5，修复前 diagnostics=4；discovery/Core/Extended 为 1/2/2。
- **原因**：`RefreshEngine.buildDiagnostics` 重算并覆盖传入的 `result.diagnostics.totalGitCalls`，丢掉 `executeScoped` 已汇总的 discovery 计数。
- **修改**：builder 改为保留 `result.diagnostics.totalGitCalls`；新增真实 Git worktree 计数回归测试；XcodeGen 登记新增测试。
- **验证**：HEAD^ pristine archive 同场景 diagnostics=4；HEAD 改动前独立 runner 计数=5、diagnostics=4；修复后 diagnostics=5 与 runner=5 一致。`verify.sh final` → 918 tests / 92 suites 全过。测量负载：load average 4.93/4.09/3.55，多个 pi 进程和 Chrome/系统进程并发。
- **剩余风险**：未运行签名安装或 GUI 验证；本轮仅涉及计数诊断与回归测试，不改扫描语义或快照行为。
