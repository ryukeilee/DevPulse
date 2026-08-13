# Archive: Loop 6（2026-08-10）

自 `.agent/history.md` 归档（2026-08-13，Loop 26 执行时按 20 条保留规则剪切）。

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
