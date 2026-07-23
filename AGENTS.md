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

```sh
# Build native app (no signing)
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj \
  -scheme DevPulse -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

# Run native tests
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj \
  -scheme DevPulse -configuration Debug \
  -derivedDataPath /tmp/devpulse-build \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test

# Widget wiring check
./scripts/verify-widgetkit.sh

# Activity timeline logic check
./scripts/verify-activity-timeline.sh

# Signed local install + runtime self-check (requires signing identity)
./scripts/install-and-self-check.sh
```

For small logic changes, run the narrowest relevant test first, then broaden according to risk.

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
