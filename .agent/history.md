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

## Loop 9 — 2026-08-10（执行维护循环后合并提交推送前）

- **问题**：无（本轮判定无高价值问题，记录「无变更」后进入合并提交推送流程）。
- **证据**：
  - 工作区未提交改动 = 用户既有 WIP（`DailyDevelopmentSummary` 系列，Loop 6/7）+ 项目健康状态概览（`RepositoryHealthOverview` 系列 + `ContentView` 接入 + pbxproj 成员，Loop 8）+ `.agent/history.md` 记录；`git status --porcelain=v2 --branch` → `branch.ab +0 -0`，HEAD `60683d3`，与 origin/main 同步。
  - `grep -rn -e TODO -e FIXME DevPulseNative/` → 无匹配。
  - 本轮 `bash ./scripts/verify.sh build` → `[verify] Build succeeded`（编译基线正常）。
  - `git diff --check` → 通过。
  - Loop 8 已对该工作树跑全量测试：`Test run with 832 tests passed`、`** TEST EXECUTE SUCCEEDED **`、0 失败。
- **原因**：无新增可复现 Bug / 测试失败 / 行为异常 / 用户反馈；按规则「没有足够证据 → 不修改」。用户授权将既有未提交改动合并提交并推送。
- **修改**：无代码改动；追加本轮 Loop 记录。
- **验证**：build 通过、diff --check 通过（全量测试证据沿用 Loop 8 同一工作树结果）。
- **剩余风险**：概览与摘要的最终视觉布局仍需签名安装后在 macOS App 中人工确认。

---

## Loop 10 — 2026-08-11（项目健康概览评分与异常状态）

- **问题**：项目健康概览只呈现四个原始维度，未提供综合评分或原因；其中 `risk` 仅表示变更文件风险，不能代表项目维护健康度；旧活动时间可能遮住新提交，未来时间戳会被误判为活跃。
- **证据**：`RepositoryHealthOverviewBuilder` 原实现只有维度映射/排序，没有评分；`activityTimestamp` 使用 `lastActivityAt ?? lastChangedAt`；`classifyActivityLevel` 对未来时间的负间隔直接判为 `.active`。用户目标明确要求重新校准评分、指标权重、解释和异常处理。
- **原因**：这是当前健康状态入口的直接数据价值问题；可在现有 `RepositorySnapshot` 纯派生层修正，不新增扫描流程，不改变 Widget 或刷新链路。
- **修改**：
  - `Core/RepositoryHealthOverview.swift`：新增 0–100 综合健康分（活跃度 35、维护状态 35、数据可信度 20、变更风险 10）、健康/需关注/风险较高/数据不足/无法评估状态与原因说明；综合两个已有活动时间戳并过滤无效/未来值；对上次成功、未知、读取错误和不可用数据进行降级或不评分。
  - `App/RepositoryHealthOverviewView.swift`：展示评分、状态颜色和最多两项主要原因，标题说明评分构成。
  - `DevPulseNativeTests/RepositoryHealthOverviewTests.swift`：补充评分权重、活跃/沉寂、维护问题、陈旧数据、未知/不可用数据、旧新时间戳和未来时间边界测试。
- **验证**：
  - `bash ./scripts/verify.sh build` → Build succeeded。
  - `bash ./scripts/verify.sh test DevPulseTests/RepositoryHealthOverviewTests` → tests passed（26 个用例）。
  - `bash ./scripts/verify.sh widgetkit` → 15 PASS, 0 FAIL。
  - `bash ./scripts/verify.sh final` → full test suite passed，Final acceptance passed。
  - `git diff --check` → 通过；最终业务 diff 仅限上述 3 个文件，无生成物、Widget/刷新/共享快照改动。
- **剩余风险**：CLI 无法证明签名 macOS 窗口的最终横向布局，评分行在窄窗口下的视觉效果仍需手动确认；评分是基于最近一次已有快照的可解释估计，不代表未运行 DevPulse 期间的完整活动历史。

---

## Loop 11 — 2026-08-11（合并提交推送前复验）

- **问题**：无（本轮判定无高价值问题，记录「无变更」后进入签名安装与合并提交推送流程）。
- **证据**：
  - 工作区未提交改动 = Loop 10 的健康评分 WIP（`Core/RepositoryHealthOverview.swift` / `App/RepositoryHealthOverviewView.swift` / `DevPulseNativeTests/RepositoryHealthOverviewTests.swift`）+ 本记录；`git status --porcelain=v2 --branch` → `branch.ab +0 -0`，HEAD `aa436d4`，与 origin/main 同步。
  - `grep -rn -e TODO -e FIXME DevPulseNative/` → 无匹配（exit 1）。
  - `git diff --check` → 通过。
  - 本轮 `bash ./scripts/verify.sh build` → `[verify] Build succeeded`（编译基线正常）。
  - 定向测试 `bash ./scripts/verify.sh test DevPulseTests/RepositoryHealthOverviewTests` → `[verify] tests passed`。
  - 全量验收 `bash ./scripts/verify.sh final` → `full test suite passed`、`Final acceptance passed — all checks green`（47.6s）。
  - 无新增用户反馈；Loop 10 已记录该功能的实现与验证细节。
- **原因**：不满足 `loop.md` Evidence 阶段的任何有效依据（无新增可复现 Bug / 测试失败 / 行为异常 / 用户反馈）；按规则「没有足够证据 → 不修改」。用户授权将既有未提交改动签名安装后合并提交并推送。
- **修改**：无业务代码改动；追加本轮 Loop 记录。
- **验证**：build、定向测试、全量验收（`verify.sh final`）、`git diff --check` 全部通过。
- **剩余风险**：评分行在签名 macOS 窗口中的最终视觉布局仍需安装后人工确认（本流程随后执行签名安装）；评分基于最近一次已有快照的可解释估计。

---

## Loop 12 — 2026-08-11

- **问题**：无（本轮判定无高价值问题，记录「无变更」）。
- **证据**：
  - 工作区：`git status --porcelain=v2 --branch` → `branch.ab +0 -0`，无未提交改动，HEAD `3eecded`（docs 提交，仅更新根/DevPulseNative AGENTS.md，无业务代码），与 origin/main 同步
  - 最近提交：`git log --oneline -15` → Loop 11 之后仅有 `44c254c`（健康评分，已验收）与 `3eecded`（文档）
  - `grep -rn -e TODO -e FIXME DevPulseNative/` → 无匹配（exit 1）
  - 上次验证：Loop 11 在同一代码上 `verify.sh final` 全量通过；本轮 `bash ./scripts/verify.sh build` → `[verify] Build succeeded`（编译基线正常）
  - 历史遗留：Loop 10/11 剩余风险仅为「评分视觉布局需安装后人工确认」「评分基于最近快照的估计」等已注明的手动确认项，非 CLI 可验证 Bug
  - 本轮无用户反馈的具体问题（任务为「运行一次 loop」）
- **原因**：不满足 `loop.md` Evidence 阶段的任何有效依据（可复现 Bug / 测试失败 / 行为异常 / 用户反馈 / 稳定性风险 / 性能问题 / 测试缺口）。按规则「没有足够证据 → 不修改」「无高价值问题 → 记录无变更，不要强行修改」。
- **修改**：无（零代码变更，未强行修改）。
- **验证**：`bash ./scripts/verify.sh build` → `[verify] Build succeeded`（确认编译基线）；`git status` / `git log` / `grep` 结果均无异常。
- **剩余风险**：本轮未运行完整测试套件（无具体问题指向时不强制，见 `loop.md`）；Loop 10/11 已注明的「需手动确认」项（评分视觉布局、基于最近快照的评分估计）仍需人工确认。

---

## Loop 13 — 2026-08-11（开发信息总览体验优化）

- **问题**：Overview 中今日摘要、最近变化、项目健康和趋势各自占据完整区块，存在统计口径提示重复、活动记录与变化列表语义不清、健康问题可能被最近活动项目挤到后面，以及首次扫描/扫描中/读取异常状态不够突出的体验问题。
- **证据**：
  - `TodayDevelopmentSummaryView` 原先在三个指标卡片内重复显示「近 7 天有活动日均」长趋势文案，第四张「活动记录」卡片又重复了最近变化列表的记录数量。
  - `RepositoryHealthOverviewBuilder` 原实现仅按最近活动时间排序，健康分较低、仓库不可用或数据不足的项目可能排在健康项目之后。
  - `StatusTab` 原先把刷新状态放在页面底部；摘要与健康视图分别调用 `Date()`，跨日重绘时可能使用不同的参照日；健康和最近变化空态未单独说明扫描进行中。
- **原因**：这是用户打开 Overview 后快速理解当前开发状态的直接阻碍，属于用户可见的信息优先级、数据口径和异常状态问题；可在既有内存派生与 SwiftUI 展示层解决，不触碰扫描、共享快照或 Widget 链路。
- **修改**：
  - `App/ContentView.swift`：Overview 先展示刷新可信度，再展示今日摘要、项目健康和最近变化；同一次 body 使用统一 `now` 传给摘要与健康派生。
  - `App/TodayDevelopmentSummaryView.swift`：将指标收敛为提交/活跃项目/估算专注时间，新增单一「开发趋势」区块，集中说明比较口径；强化读取异常、扫描中、首次扫描、跨日未扫描和今日无变化空态，减少无历史时的重复提示。
  - `App/RepositoryHealthOverviewView.swift`：健康问题优先、分数徽标突出，健康行不重复渲染解释；增加整体状态汇总、扫描中/失败/降级/首次扫描空态。
  - `App/ActivityTimelineView.swift`：改为「最近变化」，默认只展示最近 8 条并保留「显示全部」入口，单独提示冲突/读取异常；不再重复渲染无需动作的建议。
  - `Core/RepositoryHealthOverview.swift`：增加与实际行同源的状态汇总，并按健康严重度/分数优先排序。
  - `DevPulseNativeTests/RepositoryHealthOverviewTests.swift`：更新排序预期，覆盖概览汇总与数据异常计数一致性。
- **验证**：
  - `bash ./scripts/verify.sh build` → Build succeeded。
  - `bash ./scripts/verify.sh test DevPulseTests/DailyDevelopmentSummaryTests` → tests passed。
  - `bash ./scripts/verify.sh test DevPulseTests/RepositoryHealthOverviewTests` → tests passed。
  - `bash ./scripts/verify.sh widgetkit` → 15 PASS, 0 FAIL。
  - `bash ./scripts/verify.sh final` → full test suite passed，Final acceptance passed。
  - `git diff --check` → 通过；未修改扫描、共享快照、Widget 源文件或项目配置。
- **剩余风险**：CLI 无法证明 macOS 窗口在最小宽度下的最终视觉换行、滚动高度和颜色对比，需在应用窗口中手动确认；未执行签名安装或运行时视觉验收。

---

## Loop 14 — 2026-08-11（复验现有总览体验改动并完成签名安装）

- **问题**：无（本轮未发现新的高价值问题）；工作区已有 Loop 13 的总览体验改动，本轮只复验、签名安装并运行新 App，未重写或扩大业务范围。
- **证据**：
  - `git status --porcelain=v2 --branch` → `main` 与 `origin/main` 同步，已有 7 个未提交文件；改动集中在总览视图、健康派生逻辑、健康测试和 Loop 记录。
  - `grep -rn -e TODO -e FIXME DevPulseNative/` → 无匹配。
  - `git diff --check` → 通过。
  - 本轮无新的 Bug 复现、失败测试或具体行为异常反馈。
- **原因**：没有新证据支持业务修改；最高价值动作是确认现有改动可构建、测试通过，并完成用户要求的签名安装运行验收。
- **修改**：无业务代码修改；追加本轮 Loop 记录。
- **验证**：
  - `bash ./scripts/verify.sh build` → Build succeeded。
  - `bash ./scripts/verify.sh test DevPulseTests/DailyDevelopmentSummaryTests` → tests passed。
  - `bash ./scripts/verify.sh test DevPulseTests/RepositoryHealthOverviewTests` → tests passed。
  - `bash ./scripts/verify.sh widgetkit` → 15 PASS, 0 FAIL。
  - `bash ./scripts/verify.sh final` → full test suite passed，Final acceptance passed。
  - 标准 `bash ./scripts/install-and-self-check.sh` → 被本机环境阻塞：`No Xcode Apple account is configured on this Mac`。
  - 使用当前已安装且匹配 bundle 的本地签名资料完成手动签名安装：`codesign --verify --deep --strict` 通过；`/Applications/DevPulse.app` 运行进程路径校验通过；测试 bundle 不存在；`--self-check` → `self_check.result=pass`、`self_check.validation=pass`、`lifecycle.widget_registration=active`。
- **剩余风险**：标准自动签名流程仍需在 Xcode 登录 Apple 账号并刷新 provisioning profiles；本次手动签名安装和运行时自检已通过，但 Overview 最小窗口下的最终视觉换行、滚动高度和颜色对比仍需人工确认。

---

## Loop 15 — 2026-08-11（六大体验区域证据驱动深度优化：口径统一 + 完整性 + 重复派生清理）

- **问题**：今日摘要 / 最近变化 / 项目健康 / 开发趋势 / 项目列表与详情 / Widget-App 六区域存在跨模块口径不一致与无效重复派生，用户打开 Overview 时可能看到互相矛盾的"最近活动"时间与缺失的完整性警告。
- **证据**（详见 `{SCRATCH}/review.md`）：
  - 最近活动时间三处口径不同：健康概览 `max(lastActivityAt, lastChangedAt)`（`Core/RepositoryHealthOverview.swift:230-243`）、列表行 `lastActivityAt ?? lastChangedAt`（`Core/Models.swift:1043`）、Widget `.current` 仅 `lastChangedAt`（`Widget/DevPulseWidget.swift:1738-1740`）；同一快照可显示"活跃 1 小时前"（App）与"改动 3 天前"（Widget）。
  - 今日摘要完整性漏报：`unavailableProjectCount` 只统计今日新增 `readFailed`（`Core/DailyDevelopmentSummary.swift:101-108`），昨日已失败今日仍不可读的仓库不触发 `hasDataWarning`（`App/TodayDevelopmentSummaryView.swift:157-160`）。
  - 重复派生：`TodayDevelopmentSummaryView.summary`、`RepositoryHealthOverviewView.items/overviewSummary`、`ActivityTimelineView.decisionsByRepositoryID` 为计算属性，一次 body 求值内被访问 10+ 次，每次都全量重算。
  - 死分支：`Core/DailyDevelopmentSummary.swift:106-108` `guard day <= todayStart` 恒真。
- **原因**：六区域数据来源统一但派生口径分裂，属于用户可见的矛盾与无效计算，符合计划要求的检查维度；修复全部落在既有纯函数与视图层，不触碰扫描管线、快照格式与 Widget 刷新策略。
- **修改**：
  - `Core/Models.swift`：新增共享纯函数 `RepositorySnapshot.mostRecentActivityTimestamp`（取两者较新、过滤未来时间戳）；列表行 `recentActivityLabel` 与 `ActivityTimelineItem.mostRecentActivityTimestamp` 改用它。
  - `Core/RepositoryHealthOverview.swift`：`activityTimestamp` 委托同一共享函数。
  - `Widget/DevPulseWidget.swift`：`.current` 活跃文案改由共享派生（`lastChangedAt` → `mostRecentActivityTimestamp`，前缀"改动"→"活跃"），落在 widget 编译子集内。
  - `Core/DailyDevelopmentSummary.swift`：`unavailableProjectCount` 改为"窗口内最新读取状态为 readFailed"的仓库数（跨日未恢复计入）；删除恒真死分支；复用今日 focusMinutes。
  - `App/TodayDevelopmentSummaryView.swift` / `App/RepositoryHealthOverviewView.swift` / `App/ActivityTimelineView.swift`：body 内一次派生后传入子视图；警告文案"今天有 N 个"→"当前有 N 个"。
  - `App/RepositoryDetailView.swift`：`.lastSuccessful` 仓库变更文件空态改为"上次成功时…"。
  - `DevPulseNativeTests/RepositoryActivityConsistencyTests.swift`（新增）：同一夹具喂健康/列表/共享派生，断言一致；`DailyDevelopmentSummaryTests.swift`：新增跨日失败计入、恢复后清除、再失败重计三例。
- **验证**：
  - `bash scripts/verify.sh build` → Build succeeded。
  - 定向测试全过：DailyDevelopmentSummaryTests、RepositoryActivityConsistencyTests、RepositoryHealthOverviewTests、CommitReadinessEngineTests、ActivityEventTests、WidgetLifecycleScenariosTests、WidgetDegradedRenderingTests。
  - `bash scripts/verify.sh final` → full test suite passed，Final acceptance passed。
  - `bash scripts/verify.sh widgetkit` → 15 PASS, 0 FAIL。
  - `bash scripts/verify-activity-timeline.sh` → passed；`bash scripts/verify-build-consistency.sh` → 20 pass, 0 fail, 1 skip。
  - 两次 `--self-check` 启动冒烟（无签名测试构建）：报告除动态 written_at 外逐行一致，退出码一致（exit=1）；`lifecycle.self_heal=^pass`、`widget_registration=active`。扫描自检 fail 系未签名构建无 App Group/扫描根目录权限的环境限制，已按计划回退条款以构建+全量测试+widget 接线作为接受标准。
  - `git diff --stat`：仅 6 个目标区域文件 + 3 个 Core/Widget 派生文件 + 2 个测试文件；未改 project.yml、entitlements、签名、快照格式、扫描管线。
- **剩余风险**：Widget 活跃文案（前缀/相对时间）与最活跃项目趋势的视觉呈现需在真实安装 + 桌面上人工确认；`mostRecentActivityTimestamp` 的未来时间戳（时钟偏差）边缘语义在列表与健康概览间仍有"时间未知/无活动记录"措辞差异（语义一致，文案不同）；未做签名安装。

---

## Loop 16 — 2026-08-11（签名安装运行新 app，提交推送 Loop 15 改动）

- **问题**：无新的高价值代码问题（Decide 判定本轮无 Bug）。工作区有 Loop 15 已完成并验证的六区域优化改动，用户要求执行 loop 后签名安装运行新 app，并把改动合并提交推送（明确授权 commit/push）。
- **证据**：
  - `git status --porcelain=v2 --branch` → main 与 origin/main 同步（4217561），工作区 11 个未提交文件（Loop 15 改动 + 本文件）。
  - `grep -rn -e TODO -e FIXME DevPulseNative/` → 无匹配。
  - Loop 15 已验证：`verify.sh final`（full test suite passed）、`verify.sh widgetkit`（15 PASS, 0 FAIL）、`verify-activity-timeline.sh`、`verify-build-consistency.sh`（20 pass, 0 fail）。
  - 签名环境：keychain 有 `Apple Development: ryukei_li@hotmail.com (5BJ9GM7VZR)`；本地 provisioning profiles 匹配 bundle（team JYL9G28DP3）；Xcode 无登录账号。
- **原因**：无新证据支持业务修改；最高价值动作是把已验证改动落地：签名安装运行（用户要求）并提交推送（用户授权）。
- **修改**：
  - 无业务代码修改；追加 Loop 16 记录。
  - 标准 `install-and-self-check.sh` 被环境阻塞：`ERROR: No Xcode Apple account is configured on this Mac`（与 Loop 14 相同）。
  - 手动签名路径（沿用 Loop 14 成功方案 + 脚本 re-sign 逻辑）：
    - 用 `verify.sh build` 产物复制、移除测试 bundle、放入 embedded.provisionprofile（host + widget，从已安装 app 复制）。
    - `codesign --force --sign` host（`--entitlements App/DevPulse.entitlements`，保留 App Group）与 widget（`--entitlements Widget/DevPulseWidgetExtension.entitlements`）。
    - 安装到 `/Applications/DevPulse.app`（旧版备份到临时目录），`open -n` 启动。
- **验证**：
  - `codesign --verify --deep --strict` → valid on disk, satisfies Designated Requirement；host/widget entitlements 均含 `com.apple.security.application-groups`；无测试 bundle。
  - GUI 进程运行，命令路径 = `/Applications/DevPulse.app/Contents/MacOS/DevPulse`。
  - `--self-check`（签名后）→ `self_check.result=pass`、`refresh_phase=success`、`repository_count=3`、`validation=pass`、`lifecycle.widget_registration=active`、`lifecycle.self_heal=^pass`、exit=0（对比无签名构建的 result=fail）。
  - 共享快照：`generatedAt/writtenAt/lastSuccessfulRefreshAt` 为启动后新值；`DevPulse status=changed changed=11` 与工作区 11 个未提交文件一致。
  - 提交前：`scripts/secret-scan.sh staged`、`git diff --cached --check` 通过；push 到 `origin/main`。
- **剩余风险**：无签名自动安装能力（需 Xcode 登录 Apple 账号）——手动签名路径已验证可用但每次需人工执行；Widget 在桌面上的实际渲染与交互仍需人工确认。

---

## Loop 17 — 2026-08-12（「最近变化」注意力计数稳定性修复：仅统计未解除的冲突/读取异常）

- **问题**：「最近变化」提示条的注意力计数把已解除/已恢复的事件永久计入——`ActivityTimelineAttention.count(in:)` 无条件统计所有 `.conflictStarted` / `.readFailed`（`Core/ActivityEvent.swift` 修复前 ~237-241），导致冲突已解决、读取已恢复后，Overview 提示条仍持续显示「建议优先确认 N 项」，直到事件过期（7 天）或用户展开查看。折叠态下视图用 `max(0, count(ordered) - count(displayed))` 分算，显示区按子集计算家族状态会漏计「更早记录」中的未解除事件（如 repo-B 的读取失败在折叠区外、其恢复在折叠区外，而显示区内 repo-C 的读取失败已在全列表中恢复——additional 被 clamp 成 0，漏报）。
- **证据**：
  - 既有测试 `attentionCountCoversConflictsAndReadFailuresOnly`（`DevPulseNativeTests/ActivityEventTests.swift`）注释自述「冲突解除、读取恢复与普通改动不计入…已解除/已恢复的注意力事件同样不计入：它们不再需要优先确认」，但其断言 `count(in: all) == 2`（all 含 resolved/recovered 事件）与注释意图直接矛盾——测试把注释写成意图、断言写成旧行为。
  - 视图文案为「建议优先确认」（`App/ActivityTimelineView.swift` `attentionNotice`），已解除状态不再需要确认。
  - `pre-fix.log`：未修复代码上定向测试 5 处断言失败（`(ActivityTimelineAttention.count(in: all) → 2) == 0`、`count([conflictStarted, conflictResolved]) → 1 == 0`、`count([readFailed, readRecovered]) → 1 == 0`、跨仓库 `→ 2 == 1` 等），与缺陷语义一致。
  - Loop 13/15 记录声明的「时间线提示条与计数共用此定义」是共享口径的要求，并非「已解除事件必须计数」；本次修复保留共享口径并使其感知解除状态。
- **原因**：`count(in:)` 只按事件类型过滤、不感知同仓库同类型的后续解除/恢复事件，导致可见状态与提示不一致（已确认的注意力事件仍被提示）；折叠态分算公式在不同子集上重复计算家族状态，产生漏报。修复全部落在纯逻辑层与视图消费点，不触碰扫描管线、快照格式、Widget 或项目配置。
- **修改**：
  - `Core/ActivityEvent.swift`：`ActivityTimelineAttention` 重写为「未解除状态感知」——`attentionFamily(for:)`（conflict/read 两族）、`openAttentionEvents(in:)`（按 (repositoryID, family) 取最新事件，最新为冲突开始/读取失败才计入，保持入参顺序）、`count(in:)`（委托 openAttentionEvents）、`split(events:displayedPrefix:)`（折叠态下 displayed=显示区内未解除数、additional=更早记录中未解除数，两数之和恒等于总数，恒非负）。`newestFirst` 排序复用 `DateFormatting` 与 id 决胜，与 `ActivityEventOrdering` 同构。
  - `App/ActivityTimelineView.swift`：提示条计数由 `max(0, count(ordered) - count(displayed))` 改为 `split(events:displayedPrefix:displayedEvents.count)`，`attentionNotice(displayedCount:additionalCount:)` 签名不变。
  - `DevPulseNativeTests/ActivityEventTests.swift`：`attentionCountCoversConflictsAndReadFailuresOnly` 断言 `== 2` → `== 0`（与注释意图一致）；新增 `attentionCountReflectsUnresolvedStateOnly`（未解除计入 / 解除不计入 / 再次开始恢复计入 / 跨仓库独立）与 `attentionSplitSeparatesDisplayedAndEarlierRecords`（12 条事件折叠 8 / 展开 12 / prefix 0 / prefix 3 / prefix 1 的 displayed/additional 拆分）。
  - 实施中第一版修复漏校验「家族最新事件自身是注意力类型」，导致解除/恢复事件被计入（`count([conflictResolved, readRecovered, changed]) → 2`）；定向测试立即暴露，补上类型校验后全绿——TDD 按证据迭代，未扩大范围。
- **验证**：
  - `bash scripts/verify.sh build` → Build succeeded（多次）。
  - `bash scripts/verify.sh test DevPulseTests/ActivityEventTests`（pre-fix）→ 5 处断言失败，捕获 `{SCRATCH}/pre-fix.log`；修复后 → 18/18 通过，捕获 `{SCRATCH}/post-fix.log`。
  - `bash scripts/verify-activity-timeline.sh` → Activity timeline verification passed。
  - `bash scripts/verify.sh final` → full test suite passed，Final acceptance passed — all checks green。
  - `git diff --check` → 通过；`git status` 仅 3 个目标文件（Core/App 源文件 + 测试文件），无生成物、无扫描/快照/签名/project.yml 改动。
  - 独立交叉 Review：委派给同工作区空闲的 codex（w4:p2，非主要修改者），只读审查本次 diff。
- **剩余风险**：CLI 无法无头验证 macOS 窗口内提示条的实际布局/文案渲染（折叠/展开切换、更早记录计数展示），需签名安装后在应用窗口中人工确认；`displayedPrefix` 与视图实际展示条数由 `showsAllEvents` 状态决定，其联动逻辑未被单独测试覆盖（视图体内部状态），但计数口径本身已由纯层测试覆盖。

---

## Loop 18 — 2026-08-12（「最近变化总览」「今日摘要」「Project Health」显示链路可靠性修复：App/Widget 语义统一、无状态回退、无多余 reload）

- **问题**：显示链路存在 6 项经一手证据确认的缺陷（A-E 修复，F 为低危观察不修）：
  - A（HIGH）：`ScanScheduler.refreshTrustAssessment`（原 1395-1399）只在 `phase == .failure` 时传 failureMessage，不感知内容级降级；降级扫描冻结 `lastSuccessfulRefreshAt` 且 phase 会被重置 `.idle`（cancel 1909-1913、self-check 2469-2471、shutdown 3830-3832）→ App 显示「数据过期」而 Widget 显示「部分仓库待确认」，同源快照两种口径。`SettingsView.swift:717-719` 直接显示该 title，同一修复覆盖。
  - B（HIGH）：`RepositoryEmptyStateBuilder`（`Models.swift` 1436-1470）缺 `.degraded` 分支 → degraded + 空仓库 + `lastScanAt != nil` 落到「未发现 Git 仓库」，与同屏健康概览「扫描部分完成」（`RepositoryHealthOverviewView.swift` 160-170）矛盾。
  - C（HIGH）：`TodayDevelopmentSummaryView` 内部矛盾：`headerDescription`（「今天检测到 N 条开发变化」）、`trendContent`（`summary.hasActivity ||` 绕过可靠性闸）、`mostActiveProject` 不遵守 `hasReliableTodayCounts`，而 `metricNumber` 遵守；`ContentView.swift:184` 实传 `lastSuccessfulRefreshAt` → 仅降级扫描时三处仍展示不完整数据。
  - D（MEDIUM-HIGH）：`widgetReloadDecision`（原 425-450）guard `reason == "scan"`，`scan-nochanges` 写回路径绕过 guard 无条件 reload；死参数 `lastReloadRequestedAt`/`now`；死常量 `widgetReloadThrottleInterval`。cancel 路径 reason="cancel" 保持无条件 reload 为有意设计（widget 60s 自愈兜底）。
  - E（LOW）：`restorePersistedSnapshot` 两处 `AppGroupStore.write`（原 3000、3043）无 `observedStorageRevision`，绕过跨进程 CAS。
  - F（低危观察，不修）：scan-start isRefreshing 直写与 watchdog 直写不入写链，可能被 revision guard 静默拒绝（功能降级非数据错误）。
- **证据**：上述每条均含代码路径与复现方式；A/B/C/D 均有「修复前失败」的定向测试或内容级断言；E 的 store 级正/负路径已有 `DataFreshnessStateTests.refreshingSnapshotDoesNotCorruptRevision` 与 `staleRefreshingWriteRejected` 覆盖。
- **原因**：修复全部收敛于既有纯派生层与单一消费点，未复制口径；App 端 `refreshTrustAssessment` 改为与 Widget 同源（`RefreshStatusFormatter.snapshotAssessment`），消除双口径。
- **修改**：
  - A：`ScanScheduler.refreshTrustAssessment`：phase==.failure 保留原 `refreshAssessment(failureMessage:)`，否则返回 `snapshotAssessment(snapshot: lastResult)`（与 Widget 完全同源），注释说明取消/自检中断窗口。
  - B：`RepositoryEmptyStateBuilder` 在 .failure 分支后加 `.degraded` 分支（title「扫描部分完成」、icon「exclamationmark.triangle」、detail 说明部分仓库未能确认，`accessWarning ??` 兜底）。
  - C：`DailyDevelopmentSummaryPresentationBuilder` 新增 `shouldShowTrend(hasActivity:comparisonActivityDayCount:hasReliableTodayCounts:)`、`shouldShowMostActiveProject(hasReliableTodayCounts:)`、`headerDescription(activityCount:hasReliableTodayCounts:)`；`TodayDevelopmentSummaryView` 三处改为调用（trendContent 首条件、mostActiveProject 前置条件、headerDescription 委托），不可靠时文案「今日尚未完成成功扫描，计数待确认。」
  - D：`widgetReloadDecision`/`shouldRequestWidgetReload` 移除死参数，guard 改为 `reason == "scan" || reason == "scan-nochanges"`，删除 `widgetReloadThrottleInterval`；调用点同步去参。
  - E：`restorePersistedSnapshot` 维护 `observedStorageRevision`，两处 write 均传 observed。
  - 测试：DataFreshnessStateTests（WidgetEntry.freshnessState 10 分支映射、`appTrustAssessmentContentDegraded`、`emptyStateBuilderDegradedShowsPartialScan`、`widgetFreshnessDegraded` 增强、头部注释修正）；CommitReadinessEngineTests（`widgetReloadDecisionSkipsNoChangeScanWriteBack`、`widgetReloadDecisionReloadsNoChangeScanWhenContentChanged`、`refreshStatusExactlyThirtyMinutesIsStaleNotExpired`、snapshotTrustAssessment 4 个新测试）；DailyDevelopmentSummaryTests（shouldShowTrend/shouldShowMostActiveProject/headerDescription 可靠性闸 4 个 + 时序 3 个 + 决胜 1 个）；ActivityEventTests（timelineBuilder 空态、widgetSummary 3 条上限/未来 +60s 容忍/7 天窗口/非法日期过滤 4 个，叠加在用户 Loop 17 修改之上）；RefreshCompletionTests（`staleRevisionRejected` 零断言空壳改为真实断言）；WidgetDegradedRenderingTests（误导注释修正）；WidgetLifecycleScenariosTests（`timelineReloadThrottling` 零断言改为真实断言，观察 UserDefaults 键 `DevPulseWidgetLastForcedReloadAt`）。
- **验证**：
  - `bash scripts/verify.sh build` → Build succeeded（多轮）。
  - 11 个受影响测试类全过（ActivityEventTests、DailyDevelopmentSummaryTests、CommitReadinessEngineTests、DataFreshnessStateTests、RefreshCompletionTests、WidgetDegradedRenderingTests、WidgetLifecycleScenariosTests、SharedSnapshotStoreTests、SnapshotStoreRecoveryTests、RepositoryHealthOverviewTests、RefreshEngineIntegrationTests），捕获 `{SCRATCH}/targeted-tests.log`。
  - `bash scripts/verify.sh final` → Build succeeded + full test suite passed + Final acceptance passed，捕获 `{SCRATCH}/final-tests.log`。
  - `bash scripts/verify.sh widgetkit` → 15 PASS, 0 FAIL，捕获 `{SCRATCH}/widgetkit.log`。
  - `git diff --check` 通过；`git status` 14 个文件（用户 4 个脏文件保留 + 本 Loop 10 个），无生成物/调试残留；ActivityEvent/ActivityEventTests 为用户 Loop 17 文件，本次仅叠加。
  - 证据链核对：问题清单 → diff hunk → 测试一一对应；「App/Widget 语义统一」由 `appTrustAssessmentContentDegraded` + `widgetFreshnessDegraded`（同源 snapshotAssessment）证明；「无状态回退」由 write 链 revision guard 未改动 + `SnapshotStoreRecoveryTests.crossProcessWriteDetection` + `RefreshCompletionTests.staleRevisionRejected` 证明；「无多余 reload」由 `widgetReloadDecisionSkipsNoChangeScanWriteBack` 证明。
- **剩余风险**：本环境无 GUI，`TodayDevelopmentSummaryView` 头部文案与降级空态的实际渲染需签名安装后人工确认；F 观察项（isRefreshing/watchdog 直写可能被 revision guard 静默拒绝）未修改，属功能降级非数据错误；cancel 路径保留无条件 reload 为有意设计。

---

## Loop 19 — 2026-08-12（签名安装运行新 app，合并提交推送 Loop 17+18 改动）

- **问题**：无新的高价值代码问题（Observe/Evidence 阶段未发现新 Bug 证据，Decide 判定本轮无变更）。工作区有 Loop 17（注意力计数）与 Loop 18（显示链路可靠性）已完成并验证的改动共 14 个文件，用户要求执行 loop 后签名安装运行新 app，并把改动合并提交推送（明确授权 commit/push）。
- **证据**：
  - `git status --porcelain=v2 --branch` → main 与 origin/main 同步（HEAD `713de83`，ab +0 -0），14 个未提交文件（Loop 17 的 4 个 + Loop 18 的 10 个），无 untracked 生成物。
  - `grep -rn -e TODO -e FIXME DevPulseNative/` → 无匹配；`git diff --check` → 通过。
  - Loop 18 已全量验证：`verify.sh final`（Build succeeded + full test suite passed + Final acceptance passed）、`verify.sh widgetkit`（15 PASS, 0 FAIL）、11 个受影响测试类全过。
  - 签名环境：keychain 有 `Apple Development: ryukei_li@hotmail.com (5BJ9GM7VZR)`；已安装 app 内含 host/widget 的 embedded.provisionprofile（可复用，Loop 14/16 已验证匹配 bundle）；Xcode 无登录账号。
- **原因**：无新证据支持业务修改；最高价值动作是把已验证改动落地：签名安装运行（用户要求）并提交推送（用户授权）。
- **修改**：无业务代码修改；追加 Loop 19 记录。
- **验证**：
  - 标准 `install-and-self-check.sh` 被环境阻塞（`No Xcode Apple account is configured on this Mac`，与 Loop 14/16 相同）。
  - 手动签名路径（沿用 Loop 16 成功方案 + AGENTS.md re-sign 注意事项）：用 `/tmp/devpulse-build` 的 build-for-testing 产物复制、移除 `DevPulseTests.xctest`、放入 embedded.provisionprofile（host + widget 从已安装 app 复制）、`codesign --force --sign` host（`--entitlements App/DevPulse.entitlements`）与 widget（`--entitlements Widget/DevPulseWidgetExtension.entitlements`）。
  - `codesign --verify --deep --strict` → valid on disk，satisfies Designated Requirement；host/widget entitlements 均含 `com.apple.security.application-groups`；无测试 bundle。
  - 安装到 `/Applications/DevPulse.app`（旧版备份到 `/tmp/devpulse-install-loop19/DevPulse.app.bak`），`open -n` 启动，进程运行（PID 75431）。
  - `--self-check`（签名后）→ `self_check.result=pass`、`refresh_phase=success`、`repository_count=3`、`validation=pass`、`lifecycle.widget_registration=active`、`lifecycle.self_heal=^pass`、exit=0。
  - 共享快照（`~/Library/Group Containers/group.local.devpulse/repositories.json`）：`generatedAt=2026-08-12T11:13:05Z`、`writtenAt=11:13:07Z`、`lastSuccessfulRefreshAt=11:13:05Z` 为启动后新值；`storageRevision=6755`；`DevPulse status=changed` 与工作区 14 个未提交文件一致。
  - 提交前：`scripts/secret-scan.sh staged`、`git diff --cached --check` 通过；push 到 `origin/main`。
- **剩余风险**：无签名自动安装能力（需 Xcode 登录 Apple 账号）——手动签名路径已验证可用但每次需人工执行；Widget 在桌面上的实际渲染与交互、今日摘要降级文案与空态渲染仍需人工确认。

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
