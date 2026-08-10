# DevPulseNative Repository Guidelines

## Scope and Product Boundaries

DevPulseNative is a local-first native macOS app with a WidgetKit extension. The repository contains no backend, cloud sync, remote GitHub API, AI integration, or Git write path.

Preserve these boundaries unless the task explicitly changes product scope:

- inspect local repositories with read-only Git commands only
- do not add commit, push, fetch, checkout, reset, or other repository mutations
- do not add network or cloud access implicitly
- show changed file basenames in the UI; do not expose full paths unnecessarily
- do not read working-tree file contents merely to calculate repository status

The scanner currently derives state from `git status --porcelain=v2 --branch` and latest-commit metadata from `git log -1`. Treat expansion beyond that metadata boundary as a product and privacy change.

## Repository Layout

- `App/`: SwiftUI app entry point, repository screens, repository health overview (RepositoryHealthOverviewView), today development summary (TodayDevelopmentSummaryView), activity timeline, pending center (PendingCenterView, PendingItemDetailView), settings, and diagnostics UI
- `Core/`: repository discovery and scanning, scheduling, readiness/risk logic, repository health overview and daily summary derivation, models, activity events, pending items (PendingItem, PendingItemStore, PendingItemEvaluator, PendingItemNotificationStore), launch-at-login, and shared snapshot persistence
- `Utilities/`: process execution and date formatting helpers
- `Widget/`: WidgetKit extension and its property list/entitlements
- `DevPulseNativeTests/`: Swift Testing coverage for scanning, discovery, readiness, health overview, development summary, activity events, snapshots, performance, and launch-at-login
- `Assets.xcassets/`: app icon and asset catalog
- `project.yml`: XcodeGen project definition
- `DevPulseNative.xcodeproj/`: checked-in Xcode project and shared schemes

Repository-root `scripts/` provides the unified verification entry points (`verify.sh`, `verify-widgetkit.sh`, `verify-activity-timeline.sh`, `install-and-self-check.sh`); see the Build and Test section below. Do not cite or depend on helpers that do not exist.

## Project Configuration

Important current values:

- app scheme: `DevPulse`
- app bundle identifier: `local.devpulse.app`
- widget bundle identifier: `local.devpulse.app.widget`
- test bundle identifier: `local.devpulse.DevPulseTests`
- shared App Group: `group.local.devpulse`
- deployment target: macOS 14.0
- Swift language version: Swift 6
- marketing version: 0.2.0

`project.yml` is the declarative project definition, while the checked-in `.xcodeproj` is what normal build commands consume. When changing targets, sources, build settings, dependencies, schemes, bundle identifiers, or entitlements, update `project.yml`, regenerate the project with the repository-compatible XcodeGen version, and inspect the resulting `.xcodeproj` diff. Do not hand-edit generated project data for an incidental change.

Bundle identifiers, App Group wiring, signing settings, entitlements, deployment target, and the app/widget shared snapshot contract are high-risk. Never insert a personal Team ID, certificate hash, provisioning UUID, or other machine-specific signing value into tracked files.

## Build and Test

Run commands from this directory (or use `./scripts/verify.sh` from the repository root).

### Unified verification script (recommended)

The repository root provides `./scripts/verify.sh` which orchestrates the entire
workflow with a single shared DerivedData cache, `build-for-testing` + `test-without-building`,
timeouts, and failure log capture:

```sh
# Build once (compile app + test bundle)
./scripts/verify.sh build

# Run targeted tests (no recompilation)
./scripts/verify.sh test DevPulseTests/ActivityEventTests
./scripts/verify.sh test DevPulseTests/CommitReadinessEngineTests

# Full acceptance gate: build + full test suite
./scripts/verify.sh final

# WidgetKit wiring check
./scripts/verify.sh widgetkit
```

### Build-for-testing (compile once)

```sh
xcodebuild -project DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/devpulse-build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build-for-testing
```

### Test-without-building (reuse pre-built bundle — seconds, not minutes)

Run the full suite:

```sh
xcodebuild -project DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug \
  -derivedDataPath /tmp/devpulse-build \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  test-without-building
```

Run a targeted test class:

```sh
xcodebuild -project DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug \
  -derivedDataPath /tmp/devpulse-build \
  -destination 'platform=macOS' \
  -only-testing:DevPulseTests/SharedSnapshotStoreTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  test-without-building
```

> **Note:** Build and test **share the same DerivedData** (`-derivedDataPath /tmp/devpulse-build`).
> This ensures incremental compilation is preserved across build and test invocations.
> The old approach (build without `-derivedDataPath`, test with one) used two separate
> caches, causing full recompilation for each test.

### Targeted testing flow

After modifying source code:
1. Run `verify.sh build` or the raw `build-for-testing` command once.
2. Run `verify.sh test DevPulseTests/AffectedTest` repeatedly while iterating.
3. At final acceptance, run `verify.sh final` for the full suite.

Each `verify.sh test` call completes in seconds because it reuses the pre-built
bundle — no recompilation, re-linking, or re-indexing.

| Source area                      | Targeted test class                              |
|----------------------------------|--------------------------------------------------|
| `Core/ActivityEvent.swift`       | `DevPulseTests/ActivityEventTests`               |
| `Core/CommitReadiness*.swift`    | `DevPulseTests/CommitReadinessEngineTests`       |
| `Core/DailyDevelopmentSummary.swift` | `DevPulseTests/DailyDevelopmentSummaryTests`  |
| `Core/LaunchAtLoginController.swift` | `DevPulseTests/LaunchAtLoginControllerTests`  |
| `Core/Models.swift`              | `DevPulseTests/SharedSnapshotStoreTests`, `DevPulseTests/ActivityEventTests` |
| `Core/PendingItem*.swift`        | `DevPulseTests/PendingItemStaleLifecycleTests`   |
| `Core/SharedSnapshotStore.swift` | `DevPulseTests/SharedSnapshotStoreTests`         |
| `Core/RefreshEngine.swift`       | `DevPulseTests/RefreshEngineIntegrationTests`    |
| `Core/RepositoryHealthOverview.swift` | `DevPulseTests/RepositoryHealthOverviewTests` |
| `Core/RepositoryHistoryStore.swift` | `DevPulseTests/RepositoryHistoryStoreTests`   |
| `Core/ScanScheduler.swift`       | `DevPulseTests/CommitReadinessEngineTests`       |
| repository discovery             | `DevPulseTests/RepositoryDiscoveryExperienceTests` |
| scanning / performance           | `DevPulseTests/ScanPerformanceTests`, `DevPulseTests/ScanConfigSanitizationTests`, `DevPulseTests/ScannerTimeoutErrorTests` |
| data consistency                 | `DevPulseTests/ScanDataConsistencyTests`         |
| Widget extension                 | `DevPulseTests/WidgetDegradedRenderingTests`, `DevPulseTests/WidgetLifecycleScenariosTests` |
| Lifecycle / sleep-wake           | `DevPulseTests/LifecycleIntegrationTests`, `DevPulseTests/LifecycleSystemTests`, `DevPulseTests/LifecycleSleepWakeTests` |
| Build config consistency         | `DevPulseTests/BuildConfigConsistencyTests`      |

### Timeouts and failure logs

- `verify.sh` imposes a **5-minute build timeout** and a **10-minute test timeout**
  by default (overridable via `BUILD_TIMEOUT` / `TEST_TIMEOUT`).
- Logs are captured to temp files; on failure, the last 120–200 lines are printed
  and the full log path is reported.
- When using raw `xcodebuild`, wrap with `timeout` in CI or scripts:

```sh
timeout 300 xcodebuild … build-for-testing
timeout 600 xcodebuild … test-without-building
```

### Widget and high-risk changes

Changes to project configuration, the Widget target, App Group storage, shared models,
or snapshot encoding require at least a host-app build and the relevant native tests.
Real Widget launch also requires a correctly signed local build and may need manual
confirmation in macOS.

If runtime logs report `No matching profile found` or `no eligible provisioning
profiles found`, record an Apple provisioning-profile/environment blocker. Do not
modify app logic, identifiers, or entitlements merely to bypass local signing state.

## 验证策略

- 构建与测试必须复用同一个 DerivedData 路径，避免重复编译。
- 修改后优先运行受影响的定向测试，不得每次都直接运行完整测试套件。
- 最终验收阶段才运行一次完整测试。
- 优先使用 `build-for-testing` 配合 `test-without-building`，避免测试阶段重新构建。
- 测试超时时必须保留失败日志，并判断是测试卡死、模拟器问题还是单纯耗时过长。
- 不得仅通过延长超时时间掩盖重复编译或测试进程不退出的问题。

## Change Discipline

- Make the smallest sufficient change and preserve existing SwiftUI structure, naming, public APIs, compatibility, and behavior unless the task requires otherwise.
- Inspect Git status before material edits and at the final gate. Preserve unrelated and user-owned changes.
- Do not perform unrelated refactors, dependency upgrades, formatting sweeps, file moves, test weakening, or cleanup.
- Keep repository scanning read-only and preserve App Group sharing between the host app and Widget.
- Do not commit DerivedData, build products, installed app bundles, temporary diagnostics, or Xcode user state.
- Do not commit, push, release, install into `/Applications`, or alter signing/provisioning state without explicit authorization.

## Testing Guidance

Add or update focused coverage in `DevPulseNativeTests/` when changing:

- scanning, parsing, concurrency, timeout, or performance behavior
- repository discovery, exclusions, or scan-location handling
- commit readiness, risk hints, sorting, or activity-event derivation
- shared snapshot encoding, atomic persistence, recovery, or diagnostics
- launch-at-login behavior
- pending item model, lifecycle state machine, identity stability, and deduplication
- pending item evaluator rules and condition detection
- pending item store atomicity, schema migration, and corruption recovery
- notification strategy (cooldown, suppression, severity escalation)
- pending item widget summary aggregation

Pending item logic is pure (no I/O for models and evaluator rules), making it straightforward to validate in CLI tests without App Group or signing.
The evaluator (`PendingItemEvaluator.evaluate`) is a pure function: same input -> same output. Tests can construct `PendingItemEvaluationContext` directly.

Widget-facing changes to `PendingItemWidgetSummary` must verify both sides: the production side (`PendingItemWidgetSummary.build`) and the consumption side (field in `AppGroupData` read by Widget `WidgetSnapshotStore`).

Widget-facing changes must verify both sides of the contract: snapshot production in the app/Core path and snapshot consumption/rendering in `Widget/`. If CLI validation cannot prove installed Widget behavior, report exactly what passed and what remains for manual confirmation.

## Privacy and Security Review

Treat these as blocking regressions:

- new file-content reads unrelated to explicit user intent
- network, cloud, telemetry, or remote API access added without scope authorization
- Git write operations
- UI or logs disclosing repository paths where basenames are sufficient
- committed credentials, signing material, private keys, or machine-specific identifiers
- incidental changes to bundle IDs, App Group entitlements, signing, deployment target, or shared snapshot compatibility

## Definition of Done

- The requested behavior is implemented with no material scope expansion.
- The narrowest relevant verifier passes, followed by broader build/tests when the affected risk requires them.
- The final diff is focused and the final Git status contains no generated or machine-local artifacts.
- The final report lists only checks actually run and clearly states any unverified runtime behavior, environmental blocker, or required manual confirmation.
