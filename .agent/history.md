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

## Loop 0 — 2026-08-09

- **问题**：项目缺少可供任何智能体直接执行的、基于证据的现有功能维护闭环。
- **证据**：仓库无 `.agent/`、`.github/` 目录；根 `AGENTS.md` / `CLAUDE.md`
  已定义边界与验证命令，但未把「观察 → 证据 → 决策 → 执行 → 验证 → 记录」
  固化为可执行流程。
- **原因**：基础设施任务，用户明确要求建立 Loop（唯一目标，非功能问题）。
- **修改**：
  - 新增 `.agent/loop.md`（循环定义与六阶段）
  - 新增 `.agent/rules.md`（Agent 边界）
  - 新增 `.agent/memory.md`（长期项目知识）
  - 新增 `.agent/history.md`（本文件）
  - 新增 `.agent/archive/README.md`（归档规则）
  - 根 `AGENTS.md`：Repository Layout 增加 `.agent/` 条目，新增
    「Maintenance Loop」一节指向 `.agent/loop.md`
- **验证**：`git status --porcelain=v2 --branch` 确认仅新增 `.agent/` 与
  `AGENTS.md` 改动，`DevPulseNative/`（业务代码）零变更。
- **剩余风险**：无功能风险；后续 Loop 从 1 开始编号。

---

## Loop 1 — 2026-08-09

- **问题**：无（本轮判定无高价值问题，记录「无变更」）。
- **证据**：工作区干净（`git status --porcelain=v2 --branch` 为 `+0 -0`，
  无 diff）；`grep -rn "TODO\|FIXME" DevPulseNative/` 无匹配；`git log --oneline -15`
  近 15 条均为已修复问题且有对应测试；`history.md` Loop 0 无遗留待办；
  本轮无用户反馈。
- **原因**：不满足 `loop.md` Evidence 阶段的任何有效依据（可复现 Bug /
  测试失败 / 行为异常 / 用户反馈 / 稳定性风险 / 性能问题 / 测试缺口）。
  按规则「没有足够证据 → 不修改」。
- **修改**：无（零代码变更，未强行修改）。
- **验证**：`bash scripts/verify.sh build` → `[verify] Build succeeded`；
  `git status` / `git log` / `grep` 结果均无异常。
- **剩余风险**：本轮未运行完整测试套件（无具体问题指向时不强制，
  见 `loop.md`）；完整套件状态待有证据指向时确认。

---

## Loop 2 — 2026-08-09

- **问题**：审计并完善 `.agent/` Evidence-driven Maintenance Loop 基础设施，
  使未来任何智能体仅凭 `.agent/loop.md` 即可独立完成一轮维护闭环。
- **证据**：
  - 工作区：`git status --porcelain=v2 --branch` → `branch.ab +0 -0`，
    仅 `.agent/history.md` 有未提交改动（Loop 1 记录，进入会话前已存在）
  - 最近提交：`git log --oneline -15` → 最新 `23e15a1 docs: add
    evidence-driven maintenance loop (.agent/)`（基础设施已由此 commit 建立）
  - `grep -rn "TODO\|FIXME" DevPulseNative/` → 无匹配
  - 上次验证状态：history Loop 1 记录 `bash scripts/verify.sh build` →
    `[verify] Build succeeded`
  - 本轮无用户反馈（任务为 OBJECTIVE 定义的基础设施目标，非具体问题）
- **原因**：OBJECTIVE 明确本任务只建立/完善 Loop 基础设施、禁止修改业务
  代码；逐条审计五个文件是识别缺口的唯一方式。审计本身即本轮最高价值工作。
- **修改**（最小 additive 补差，未覆盖任何有效内容）：
  - `.agent/loop.md` Verify 节：补「禁止伪造测试结果」（原仅「未验证宣布
    完成 / 隐藏失败」；rules.md 已有该禁止，补入 loop.md 使单文件自包含）
  - `.agent/loop.md` Decide 节：补「允许连续维护同一个模块（须出现新证据、
    且非重复处理 history.md 已标记完成的问题）」正面表述（对齐 OBJECTIVE）
  - `rules.md` / `memory.md` / `history.md` / `archive/README.md`：
    审计无缺口，未改动
- **验证**：`bash scripts/verify.sh build` → `[verify] Build succeeded`
  （完整输出已捕获至 scratch build.log）；`git status --porcelain=v2 --branch`
  确认 `DevPulseNative/`（App/Core/Utilities/Widget/测试）零改动、无平行
  维护体系（根目录无 `.ai/`、`.github/` 等重复目录）。
- **剩余风险**：本轮为文档级 additive 修改，build 通过已证明不影响项目
  运行；未运行完整测试套件（无业务代码改动，不必要）。README.md 未单独
  提及 Maintenance Loop，属可选适配，未做。

### 本轮报告（最终报告四要素）

- **创建/修改文件**：修改 `.agent/loop.md`（2 处 additive 补丁）；其余
  四个 `.agent/` 文件仅审计未改动。无新建文件。
- **各文件职责**：`loop.md` 定义六阶段闭环（Observe→Evidence→Decide→
  Execute→Verify→Record）与执行前置必读；`rules.md` 定义 Loop 专属强制
  边界（Must/Must Not/高风险项）；`memory.md` 保存长期稳定项目知识；
  `history.md` 追加每轮 Loop 记录（保留最近 20 条）；`archive/README.md`
  定义旧记录归档命名与剪切规则。
- **如何执行一次 Maintenance Loop**：读取 `loop.md` 的「0. 执行前（必读）」
  三项 → 按 1~6 阶段依次执行（Observe 只收集证据不修改 → Evidence 判断
  是否有效 → Decide 选一个最高价值问题 → Execute 最小修改 → Verify 用
  `./scripts/verify.sh` 验证 → Record 追加 history.md）；无证据或无高价值
  问题时记录「无变更」结束。
- **是否需要额外适配**：否。基础设施已完整（commit `23e15a1` 建立，
  Loop 0/1 留痕），本轮仅两处补差；未来智能体可直接按 `loop.md` 执行。
  可选适配：README.md 增加指向 `.agent/loop.md` 的章节（非必需，未做）。

---

## Loop 3 — 2026-08-09

- **问题**：App 缺少基于既有扫描活动记录的「今日开发摘要」，无法在一个入口查看今日提交、活跃项目、专注时间、最活跃项目及近期趋势。
- **证据**：用户目标明确要求新增该 App 功能；现有 `ScanScheduler.activityEvents` 已保存扫描发现的增量活动，且不需要新增扫描链路即可计算日摘要。
- **原因**：直接面向用户的功能缺口；可复用现有活动记录，避免扩大刷新和 Widget 边界。
- **修改**：
  - 新增 `DailyDevelopmentSummary.swift`：纯内存摘要计算，排除读取失败事件，统计今日提交/项目/活动会话，按连续活动间隔估算专注时间，并与前 7 天日均比较。
  - 新增 `TodayDevelopmentSummaryView.swift`：在 Overview 内展示摘要卡片、最活跃项目和趋势；明确标注专注时间为估算且不触发额外扫描。
  - `ContentView.swift`：将摘要接入现有 Overview，数据仅来自 `scheduler.activityEvents`。
  - 新增 `DailyDevelopmentSummaryTests.swift`：覆盖今日统计、读取事件过滤、专注会话、日均趋势、未来事件和无历史状态。
  - `DevPulseNative.xcodeproj/project.pbxproj`：由 XcodeGen 纳入新增 App/测试源文件；未加入 Widget target。
- **验证**：
  - `bash scripts/verify.sh build` → Build succeeded。
  - `bash scripts/verify.sh test DevPulseTests/DailyDevelopmentSummaryTests` → tests passed。
  - `bash scripts/verify.sh widgetkit` → 15 PASS, 0 FAIL。
  - `bash scripts/verify.sh final` → full test suite passed，Final acceptance passed。
  - `git diff --check` → 通过；最终状态仅含本轮业务、生成项目和 Loop 记录改动，无生成物。
  - 首次 `./scripts/verify.sh build` 因脚本无执行权限返回 126，随后使用等价 `bash` 命令完成验证；中间编译错误已根据日志修复并重新通过。
- **剩余风险**：摘要依赖扫描发现的本地活动事件；首次建立基线或活动存储不可用时只能显示 0/近期数据不足。专注时间是基于事件间隔的估算，需在 macOS App 中手动确认视觉布局。

---

## Loop 4 — 2026-08-10

- **问题**：无（本轮判定无高价值问题，记录「无变更」）。
- **证据**：
  - 工作区：`git status --porcelain=v2 --branch` → `branch.ab +0 -0`，无未提交改动，与 origin/main 同步
  - 最近提交：`git log --oneline -15` → HEAD `1372ec7 feat: add today development summary to Overview`（即 Loop 3 的改动，本轮无新提交）
  - `grep -rn -e TODO -e FIXME DevPulseNative/` → 无匹配（exit 1）
  - 上次验证：history Loop 3 在同一 commit 上 `verify.sh final` 全量通过；本轮 `bash ./scripts/verify.sh build` → `[verify] Build succeeded`（20.3s，exit 0）
  - 历史遗留：Loop 3 剩余风险仅为「视觉布局需手动确认」「首次基线数据不足」等已注明的手动确认项，非 CLI 可验证 Bug
  - 本轮无用户反馈的具体问题（任务为「运行一次 loop」）
- **原因**：不满足 `loop.md` Evidence 阶段的任何有效依据（可复现 Bug / 测试失败 / 行为异常 / 用户反馈 / 稳定性风险 / 性能问题 / 测试缺口）。按规则「没有足够证据 → 不修改」「无高价值问题 → 记录无变更，不要强行修改」。
- **修改**：无（零代码变更，未强行修改）。
- **验证**：`bash ./scripts/verify.sh build` → `[verify] Build succeeded`（确认今日编译基线）。
- **剩余风险**：本轮未运行完整测试套件（无具体问题指向时不强制，见 `loop.md`）；Loop 3 的「需手动确认」项（摘要视觉布局、首次基线数据不足）仍未做人工确认。

---

## Loop 5 — 2026-08-10

- **问题**：无（本轮判定无高价值问题，记录「无变更」）。
- **证据**：
  - 工作区：`git status --porcelain=v2 --branch` → `branch.ab +0 -0`，无未提交改动，与 origin/main 同步
  - 最近提交：`git log --oneline -15` → HEAD `60683d3 docs(agent): record maintenance loop 4`（即 Loop 4 的记录提交，本轮无新提交）
  - `grep -rn -e TODO -e FIXME DevPulseNative/` → 无匹配（exit 1）
  - 上次验证：Loop 4 在同一 commit 上 `verify.sh build` 通过；本轮 `bash ./scripts/verify.sh build` → `[verify] Build succeeded`
  - 历史遗留：Loop 3 剩余风险仅为「摘要视觉布局需手动确认」「首次基线数据不足」等已注明的手动确认项，非 CLI 可验证 Bug
  - 本轮无用户反馈的具体问题（任务为「运行一次 loop」）
- **原因**：不满足 `loop.md` Evidence 阶段的任何有效依据（可复现 Bug / 测试失败 / 行为异常 / 用户反馈 / 稳定性风险 / 性能问题 / 测试缺口）。按规则「没有足够证据 → 不修改」「无高价值问题 → 记录无变更，不要强行修改」。
- **修改**：无（零代码变更，未强行修改）。
- **验证**：`bash ./scripts/verify.sh build` → `[verify] Build succeeded`（确认今日编译基线）。
- **剩余风险**：本轮未运行完整测试套件（无具体问题指向时不强制，见 `loop.md`）；Loop 3 与 Loop 4 已注明的「需手动确认」项（摘要视觉布局、首次基线数据不足）仍未做人工确认。

---

## Loop 6 — 2026-08-10

- **问题**：今日开发摘要把扫描事件直接呈现为“今日提交”，活动记录只显示布尔状态；稀疏历史会因空天数按 0 参与平均而放大趋势；读取失败和首次/跨日未扫描状态没有在摘要中显式区分。
- **证据**：
  - `DailyDevelopmentSummaryBuilder` 原实现对前 7 天所有日桶求平均，仅用 `hasPreviousActivity` 判断是否可用；今天 1 次提交、前 7 天仅 1 天 1 次提交时平均值为 `1/7`，会误报增长。
  - `TodayDevelopmentSummaryView` 原实现将第四张卡片渲染为“有活动/暂无活动”，且仅接收 `activityEvents`，无法区分首次扫描、跨日未扫描和今天确实无变化。
  - 原逻辑过滤 `.readFailed` 后不保留异常提示，读取异常会与“暂无活动”混淆。
- **原因**：属于用户可见的数据正确性和空/异常状态问题，且可在摘要层复用已有扫描事件和刷新状态解决，不触碰扫描管线或 Widget 契约。
- **修改**：
  - `DailyDevelopmentSummary.swift`：明确提交统计为“扫描检测到的提交变化”；新增真实活动记录数、读取异常项目数和有效历史活动日数；趋势平均仅使用近 7 天内有开发变化的日期，并保留读取失败告警信息。
  - `TodayDevelopmentSummaryView.swift`：提交卡片改为“发现新提交”，活动卡片显示数量；补充有读取异常、首次成功扫描、跨日未扫描、今日无变化和扫描进行中的状态展示；趋势和底部说明明确“有活动日均”语义。
  - `ContentView.swift`：向摘要传入 `lastSuccessfulRefreshAt` 与 `isScanning`，沿用现有刷新状态来源。
  - `DailyDevelopmentSummaryTests.swift`：更新稀疏历史趋势预期，新增活动数、稀疏平均和读取失败告警覆盖。
- **验证**：
  - `bash ./scripts/verify.sh build` → Build succeeded。
  - `bash ./scripts/verify.sh test DevPulseTests/DailyDevelopmentSummaryTests` → tests passed。
  - `bash ./scripts/verify.sh widgetkit` → 15 PASS, 0 FAIL。
  - `bash ./scripts/verify.sh final` → full test suite passed，Final acceptance passed。
  - `git diff --check` → 通过；无生成物或 Widget/扫描管线改动。
- **剩余风险**：摘要仍基于有界的本地扫描变化事件，无法推断未运行 DevPulse 期间的真实提交总数；专注时间仍是事件间隔估算，视觉效果需在 macOS App 中手动确认。

---

## Loop 7 — 2026-08-10

- **问题**：无（本轮判定无高价值问题，记录「无变更」）。
- **证据**：
  - 工作区存在用户未提交改动，范围为 `DailyDevelopmentSummary` 及其视图/测试与本记录；本轮未覆盖或回退这些改动。
  - 最近提交：`git log --oneline -15` → HEAD `60683d3 docs(agent): record maintenance loop 4`。
  - `grep -rn -e TODO -e FIXME DevPulseNative/` → 无匹配。
  - 本轮 `bash ./scripts/verify.sh build` → `[verify] Build succeeded`。
  - 受影响定向测试 `bash ./scripts/verify.sh test DevPulseTests/DailyDevelopmentSummaryTests` → `tests passed`。
  - `git diff --check` → 通过；本轮无新增业务行为或用户反馈。
- **原因**：没有新的可复现 Bug、失败测试、明确行为异常、稳定性/性能风险或测试缺口；按规则「没有足够证据 → 不修改」。
- **修改**：无业务代码修改；仅追加本轮 Loop 记录。
- **验证**：上述 build、定向测试和 `git diff --check` 均通过。
- **剩余风险**：工作区原有未提交改动仍需其作者审阅；Loop 6 已注明的摘要视觉布局与首次/跨日数据状态仍需 macOS App 手动确认；本轮未运行完整测试套件。

---

## Loop 8 — 2026-08-10（项目健康状态概览：复用并验证现有未提交实现）

- **问题**：目标「为 DevPulse 增加项目健康状态概览」；工作区已存在未提交实现（`RepositoryHealthOverview.swift` / `RepositoryHealthOverviewView.swift` / `RepositoryHealthOverviewTests.swift` + `ContentView.swift` 接入 + pbxproj 成员），按计划复用并验证，而非重写。
- **证据**：
  - 四维覆盖复核：最近活动时间（`lastActivityAt` → `lastChangedAt` 兜底）、仓库状态（clean / changed 计数 / error）、扫描状态（current / lastSuccessful / unknown / unavailable / error，优先级 unavailable > current > lastSuccessful > unknown/error）、活跃程度（≤24h 活跃、≤7d 一般、>7d 沉寂、无记录无活动）。
  - 纯派生约束：`RepositoryHealthOverview.swift` 与视图文件 grep 无 `ProcessRunner` / git / URLSession / FileManager / Timer / Task / async / await；数据源只读 `scheduler.lastResult.repositories`（`AppGroupData`）。
  - 范围：`git status` / `git diff --stat` 改动仅限三个概览新文件 + `ContentView.swift` 接入 + pbxproj 新文件成员；扫描链路（GitRepositoryScanner / RefreshEngine / ScanScheduler / SharedSnapshotStore / AppGroupStore / Models / project.yml）零改动；`git diff --check` 通过。
- **原因**：实现已符合计划验收标准，验证路径为「编译链接 + 纯派生单元测试 + 源码结构审查」。
- **修改**：无代码改动（复用既有未提交实现并验证）。
- **验证**：
  - `bash ./scripts/verify.sh build` → Build succeeded；直跑 `build-for-testing` → `** TEST BUILD SUCCEEDED **`，概览三文件均编译进 app / 测试 target。
  - `bash ./scripts/verify.sh test DevPulseTests/RepositoryHealthOverviewTests` → tests passed；直跑 test-without-building → 21 个用例全部通过、0 失败。
  - `bash ./scripts/verify.sh final` → Final acceptance passed；直跑全量 test-without-building → `Test run with 832 tests passed`、`** TEST EXECUTE SUCCEEDED **`、0 失败。
- **剩余风险**：概览为 macOS 原生 GUI，CLI 无法无头启动窗口做端到端视觉验证；四维行的最终视觉布局需签名安装后在 App 中人工确认（计划已列入剩余风险）。

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
