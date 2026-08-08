# Agent Rules（项目级边界）

本文件是 `.agent/` Maintenance Loop 的强制边界。与根 `AGENTS.md`、
`DevPulseNative/AGENTS.md`、`CLAUDE.md` 冲突时，**以更严格的为准**。

## 必须（Must）

- **基于证据工作**：任何修改必须由可复现 Bug、测试失败、明确行为异常、
  用户反馈、稳定性 / 性能风险或测试缺口驱动（详见 `loop.md` Evidence 阶段）。
- **最小修改**：只做解决单一最高价值问题所需的最小 diff；小范围、可审查。
- **尊重现有架构**：沿用现有类型、命名、数据流与验证模式。`project.yml`
  是 XcodeGen 声明式源；需改 targets / sources / build settings 时改
  `project.yml` 后运行 `cd DevPulseNative && xcodegen generate`，
  **禁止手改生成的 `.xcodeproj`**。
- **保留用户修改**：不得丢弃、回退或覆盖用户未提交的改动。
- **明确验证结果**：如实报告实际运行的命令与结果；未验证项必须注明
  「需手动确认」。
- **先读再动**：每轮 Loop 先读 `.agent/rules.md`、`.agent/memory.md`、
  `.agent/history.md` 最近记录。
- **维护 Loop 记录**：每轮完成后更新 `.agent/history.md`。

## 禁止（Must Not）

- **禁止 commit / push / 发布 / 部署**（提交、推送、发布、部署均需用户显式授权）
- **禁止修改凭证、密钥、签名材料、机器特定标识**（Team ID、证书哈希、
  provisioning UUID 等），不得写入被跟踪文件
- **禁止删除用户数据**（用户工作区文件、App Group 容器数据、备份数据）
- **禁止伪造测试结果、隐藏失败**（不得为通过而修改测试）
- **禁止超出任务范围的行为变更**：不新增功能、不做无关重构或优化
- **禁止网络 / 云 / 遥测访问**；对本地 Git 仓库只读
  `git status --porcelain=v2 --branch` 与 `git log -1`
- **禁止读取工作树文件内容**以计算仓库状态；UI 只展示文件 basename
- **禁止把 bundle ID、entitlements、App Group、部署目标、共享 snapshot 格式
  作为无关清理顺手修改**；若问题本身要求改动，必须显式验证并记录
- **禁止共享 snapshot 直写**：App Group 容器读写一律经
  `AppGroupStore` / `SharedSnapshotStore`

## 高风险项（修改前必须显式验证）

- bundle identifiers / entitlements / App Group 接线
- 部署目标、Swift 版本、营销版本
- Widget 嵌入与共享 snapshot 格式
- 签名与本地安装（`scripts/install-and-self-check.sh` 需要签名身份，
  且重签名必须带 entitlements 以保留 App Group）
