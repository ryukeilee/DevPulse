# Repository Guidelines

## Current Scope
DevPulse is a local-first native macOS app with a WidgetKit extension. The entire product lives in `DevPulseNative/`. There is no Electron app, no backend, no cloud sync, no GitHub API integration, no AI integration, and no Git write path.

GitHub remote: `origin https://github.com/ryukeilee/DevPulse.git`

Preserve these boundaries unless the task explicitly changes product scope:
- read local Git metadata only (`git status --porcelain=v2 --branch`, `git log -1`)
- show changed file basenames only; do not expose full paths unnecessarily
- do not read repository file contents unless the task requires it
- do not add commit, push, fetch, checkout, reset, or other Git mutations
- do not add network or cloud access implicitly

## Project Initialization

First-time setup:

```sh
# Install Node.js dependencies (build tooling, icon generation)
npm install

# Ensure git hooks point to this repo's hooks
git config core.hooksPath .githooks
```

`.env` with credentials should exist in the repo root; if missing, copy `.env.example` and populate.

## Repository Layout

```
.
├── .claude/worktrees/        # Claude worktree sessions
├── .githooks/
│   ├── pre-commit            # runs scripts/secret-scan.sh staged
│   └── pre-push              # runs scripts/secret-scan.sh tracked
├── DevPulseNative/           # ⬅ primary product (see DevPulseNative/AGENTS.md)
│   ├── App/                  # SwiftUI views (DevPulseApp, ContentView, settings, etc.)
│   ├── Core/                 # scanning, models, readiness, risk, activity, snapshots
│   ├── Utilities/            # ProcessRunner, DateFormatting
│   ├── Widget/               # WidgetKit extension
│   ├── DevPulseNativeTests/  # Swift Testing coverage
│   ├── Assets.xcassets/      # app icon
│   ├── project.yml           # XcodeGen declarative project spec
│   └── AGENTS.md             # detailed native-app agent guidelines
├── scripts/
│   ├── verify-widgetkit.sh
│   ├── verify-activity-timeline.sh
│   ├── install-and-self-check.sh
│   ├── secret-scan.sh
│   └── generate-icon.mjs
├── docs/
│   └── widgetkit-troubleshooting.md
├── CLAUDE.md
├── AGENTS.md
├── README.md
├── SECURITY.md
├── .env.example
└── .gitignore
```

Do not commit DerivedData, build products, installed app bundles, or Xcode user state.

## Core files (DevPulseNative/Core/)

| File | Purpose |
|------|---------|
| `Models.swift` | RepositorySnapshot, RiskLevel, AppGroupData, WidgetRepositoryEntry, ScanSummary |
| `GitRepositoryScanner.swift` | actor-based repo discovery + batched git-status read + slow-repo tracking |
| `GitStatusParser.swift` | parse `git status --short` output |
| `AppGroupStore.swift` | read/write AppGroupData to shared container |
| `SharedSnapshotStore.swift` | atomic snapshot persistence for app + Widget sharing |
| `ActivityEvent.swift` | activity event model and derivation |
| `RepositorySorter.swift` | sort repos by recency, dirtiness, branch |
| `RiskHintEngine.swift` | flag risky changes |
| `CommitReadinessEngine.swift` | rules-based readiness assessment |
| `CommitReadinessBadge.swift` | badge rendering logic for readiness |
| `ScanScheduler.swift` | timer-based scan scheduling; manages pending item lifecycle |
| `ScanLocationProvider.swift` | scan root resolution |
| `ExcludedDirectoryRules.swift` | directory exclusion rules |
| `LaunchAtLoginController.swift` | ServiceManagement-based launch-at-login |
| `PendingItem.swift` | pending item model, severity/lifecycle enums, notification strategy, widget summary |
| `PendingItemStore.swift` | atomic persistence for pending items, user action management, schema migration |
| `PendingItemNotificationStore.swift` | notification state persistence, cooldown tracking |
| `PendingItemEvaluator.swift` | 12-rule engine for repository and workspace anomaly detection |

## Test files (DevPulseNative/DevPulseNativeTests/)

| File | Coverage |
|------|----------|
| `ActivityEventTests.swift` | activity event derivation |
| `CommitReadinessEngineTests.swift` | readiness rules |
| `LaunchAtLoginControllerTests.swift` | login item registration |
| `RepositoryDiscoveryExperienceTests.swift` | discovery flow |
| `ScanPerformanceTests.swift` | scanning performance |
| `SharedSnapshotStoreTests.swift` | snapshot persistence |
| `PendingItemTests.swift` | pending item model, state machine, deduplication (when added) |

## Build and Verification

Run commands from the repository root unless stated otherwise.

### Unified verification script (recommended)

`./scripts/verify.sh` orchestrates the entire build/test workflow with a single
shared DerivedData cache, avoiding redundant compilation:

```sh
# Build once (compile app + test bundle)
./scripts/verify.sh build

# Run targeted tests (no recompilation — uses pre-built bundle)
./scripts/verify.sh test DevPulseTests/ActivityEventTests
./scripts/verify.sh test DevPulseTests/CommitReadinessEngineTests
./scripts/verify.sh test DevPulseTests/SharedSnapshotStoreTests

# Full acceptance gate: build + full test suite
./scripts/verify.sh final

# WidgetKit wiring check
./scripts/verify.sh widgetkit

# Activity timeline logic check
./scripts/verify-activity-timeline.sh
```

The script uses `build-for-testing` (compile once) and `test-without-building`
(reuse pre-built bundle) internally, so test iterations after the initial build
skip recompilation entirely.

Override defaults via environment:

```sh
DERIVED_DATA_PATH=/tmp/devpulse-custom BUILD_TIMEOUT=600 ./scripts/verify.sh final
```

### Raw xcodebuild commands (for CI or advanced workflows)

Build and test **share the same DerivedData** so incremental compilation is preserved:

```sh
# Build native app (no signing)
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/devpulse-build}"
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj \
  -scheme DevPulse -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build-for-testing

# Run targeted tests (reuses the build above — no recompilation)
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj \
  -scheme DevPulse -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination 'platform=macOS' \
  -only-testing:DevPulseTests/ActivityEventTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  test-without-building

# Run full test suite
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj \
  -scheme DevPulse -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  test-without-building

# Widget wiring check
DERIVED_DATA_PATH="$DERIVED_DATA_PATH" ./scripts/verify-widgetkit.sh

# Activity timeline logic check
./scripts/verify-activity-timeline.sh

# Signed local install + runtime self-check (requires signing identity)
./scripts/install-and-self-check.sh
```

### Targeted testing

After modifying source code, run the narrowest affected test class first.
The `verify.sh build` step is needed only once per session — subsequent
`verify.sh test <TestClass>` calls use `test-without-building` and complete
in seconds.

| Source area                     | Targeted test class                          |
|---------------------------------|----------------------------------------------|
| `Core/ActivityEvent.swift`      | `DevPulseTests/ActivityEventTests`           |
| `Core/CommitReadinessEngine.swift` | `DevPulseTests/CommitReadinessEngineTests` |
| `Core/LaunchAtLoginController.swift` | `DevPulseTests/LaunchAtLoginControllerTests` |
| `Core/Models.swift`             | `DevPulseTests/SharedSnapshotStoreTests`, `DevPulseTests/ActivityEventTests` |
| `Core/PendingItem*.swift`       | `DevPulseTests/PendingItemStaleLifecycleTests` |
| `Core/SharedSnapshotStore.swift` | `DevPulseTests/SharedSnapshotStoreTests`   |
| `Core/RefreshEngine.swift`      | `DevPulseTests/RefreshEngineIntegrationTests` |
| `Core/ScanScheduler.swift`      | `DevPulseTests/CommitReadinessEngineTests`  |
| repository discovery            | `DevPulseTests/RepositoryDiscoveryExperienceTests` |
| scanning / performance          | `DevPulseTests/ScanPerformanceTests`        |
| data consistency                | `DevPulseTests/ScanDataConsistencyTests`    |
| Widget extension                | `DevPulseTests/WidgetDegradedRenderingTests`, `DevPulseTests/WidgetLifecycleScenariosTests` |
| Lifecycle / sleep-wake          | `DevPulseTests/LifecycleIntegrationTests`, `DevPulseTests/LifecycleSystemTests` |
| Build config consistency        | `DevPulseTests/BuildConfigConsistencyTests` |

### Timeouts and failure logs

- `verify.sh` applies a **5-minute build timeout** and a **10-minute test timeout**
  by default, configurable via `BUILD_TIMEOUT` / `TEST_TIMEOUT`.
- Build and test logs are captured to temporary files; on failure, the last
  120–200 lines are printed and the full log path is reported.
- Raw `xcodebuild` commands should be wrapped with `timeout` in CI:

```sh
timeout 300 xcodebuild … build-for-testing
timeout 600 xcodebuild … test-without-building
```

## 验证策略

- 构建与测试必须复用同一个 DerivedData 路径，避免重复编译。
- 修改后优先运行受影响的定向测试，不得每次都直接运行完整测试套件。
- 最终验收阶段才运行一次完整测试。
- 优先使用 `build-for-testing` 配合 `test-without-building`，避免测试阶段重新构建。
- 测试超时时必须保留失败日志，并判断是测试卡死、模拟器问题还是单纯耗时过长。
- 不得仅通过延长超时时间掩盖重复编译或测试进程不退出的问题。

## Project Configuration

- app scheme: `DevPulse`
- app bundle id: `local.devpulse.app`
- widget bundle id: `local.devpulse.app.widget`
- shared App Group: `group.local.devpulse`
- test target bundle id: `local.devpulse.DevPulseTests`
- deployment target: macOS 14.0
- Swift: 6
- marketing version: 0.2.0

Changes affecting bundle IDs, entitlements, `Info.plist`, widget embedding, App Group wiring, or shared snapshot format are high-risk and must be verified explicitly.

`project.yml` is the declarative project definition; when changing targets, sources, build settings, or entitlements, update `project.yml` and regenerate with `cd DevPulseNative && xcodegen generate`. Do not hand-edit generated `.xcodeproj` data.

## Change Boundaries

- Make the smallest sufficient change; preserve existing SwiftUI structure, naming, and behavior.
- Keep repository scanning read-only.
- Preserve App Group sharing between app and widget.
- Do not change signing, Team configuration, bundle identifiers, or entitlements as incidental cleanup.
- Never insert personal Team ID, certificate hash, provisioning UUID, or other machine-specific signing values into tracked files.
- Do not introduce broad formatting churn or unrelated file moves.

## Testing Guidance

Add or update focused coverage in `DevPulseNative/DevPulseNativeTests/` when changing:
- scanning, parsing, concurrency, timeout, or performance
- repository discovery, exclusions, or scan-location handling
- commit readiness, risk hints, sorting, or activity-event derivation
- shared snapshot encoding, atomic persistence, recovery, or diagnostics
- launch-at-login behavior
- **pending item model, state machine, identity stability (cross-refresh/restart/path-change dedup)**
- **pending item evaluator rules (condition detection, escalation/de-escalation, auto-recovery)**
- **pending item store atomicity, schema migration, and corruption recovery**
- **notification strategy (cooldown, severity escalation, suppression, quiet hours)**
- **pending item widget summary aggregation**

Pending item logic (`PendingItem`, `PendingItemEvaluator`, `PendingItemNotificationStrategy`) is pure (no I/O), making it straightforward to validate in CLI tests without App Group or signing. Tests can construct `PendingItemEvaluationContext` directly.

Widget-facing changes to `PendingItemWidgetSummary` must verify both sides: production (`PendingItemWidgetSummary.build`) in Core and consumption (field in `AppGroupData`) in `Widget/`.

If runtime behavior cannot be fully proven in CLI, state what was verified and what remains for manual confirmation.

## Security and Privacy (Blocking Regressions)

- new file-content reads unrelated to explicit user intent
- network, cloud, telemetry, or remote API access added without scope authorization
- Git write operations
- UI or logs disclosing full repository paths where basenames suffice
- committed credentials, signing material, private keys, or machine-specific identifiers
- incidental changes to bundle IDs, App Group entitlements, signing, deployment target, or shared snapshot format

Before commit or release-oriented work, run `./scripts/secret-scan.sh staged`.

## Definition of Done

- The requested behavior is implemented with no material scope expansion.
- The narrowest relevant verifier passes; broaden to build/tests only when risk justifies it.
- The final diff is focused; Git status contains no generated or machine-local artifacts.
- The final report lists only checks actually run and clearly states any unverified runtime behavior, environmental blocker, or required manual confirmation.
