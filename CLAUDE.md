# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

DevPulse is a **local-first macOS Git activity glance widget**: a SwiftUI app + WidgetKit extension that scans local Git repositories, reads only Git metadata, and shows recent activity, repo health, and commit-readiness. The entire product lives in `DevPulseNative/` — there is no Electron app, backend, cloud, or AI integration.

## Hard Boundaries (treat as blocking regressions)

- Read-only Git access only: `git status --porcelain=v2 --branch`, `git log -1`. No commit/push/fetch/write operations.
- No network/cloud/telemetry/API access. No AI. No LLM.
- Never read working-tree file contents; the UI shows file **basenames** only.
- Never insert personal Team ID, certificate hash, provisioning UUID, or other machine-specific signing values into tracked files.
- High-risk, verify explicitly: bundle IDs, entitlements, App Group wiring, deployment target, shared snapshot format.

See `AGENTS.md` and `DevPulseNative/AGENTS.md` for the full change discipline, testing guidance, and Definition of Done.

## Build, Test, Verify

Run from the repo root. All commands reuse a **single shared DerivedData** (`/tmp/devpulse-build`) so `build-for-testing` compiles once and `test-without-building` reuses the bundle.

```sh
# One-time setup (build tooling + icon generation)
npm install
git config core.hooksPath .githooks   # pre-commit/pre-push run scripts/secret-scan.sh

# Unified verification script (recommended)
./scripts/verify.sh build                        # compile once (5-min build timeout)
./scripts/verify.sh test DevPulseTests/ActivityEventTests   # targeted test, seconds
./scripts/verify.sh final                        # build + full suite (acceptance gate)
./scripts/verify.sh widgetkit                    # WidgetKit wiring check

# Raw xcodebuild (CI / advanced); must share -derivedDataPath
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/devpulse-build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build-for-testing
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse \
  -derivedDataPath /tmp/devpulse-build -destination 'platform=macOS' \
  -only-testing:DevPulseTests/ActivityEventTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test-without-building
```

- Tests use **Swift Testing** (`@Test`/`#expect`, `import Testing`), not XCTest. The test target is named `DevPulseTests` though the folder is `DevPulseNativeTests/`.
- Always run the narrowest affected test class first after a change; only run the full suite at final acceptance. A source→test mapping table lives in `AGENTS.md`.
- `verify.sh` applies a 5-min build / 10-min test timeout (override with `BUILD_TIMEOUT`/`TEST_TIMEOUT`); on failure it prints the last 120–200 log lines and keeps the full log path.
- `./scripts/install-and-self-check.sh` is a **signed** local install + runtime self-check (needs a signing identity). Widget launch and runtime behavior may need manual confirmation on macOS.

## Architecture

### App entry and state flow
`DevPulseNative/App/DevPulseApp.swift` is the `@main` entry: a `MenuBarExtra` + main window, holding `ScanScheduler` (an `ObservableObject`, ~184 KB — the central state hub) and a `LifecycleCoordinator`. It also dispatches headless `AppCommand`s (`--self-check`, launch-at-login) used by install/self-check scripts.

### Refresh pipeline
`Core/RefreshEngine.swift` is an actor orchestrating the full refresh: `discovery → coreStatus → extendedInfo → merge → persistence → widgetSync`, with per-stage time budgets and generation-based cancellation. `Core/ScanScheduler.swift` schedules scans, batches refresh requests, and manages the pending-item/workspace stores.

Scanning is done by `Core/GitRepositoryScanner.swift` (actor): batched read-only git status reads, slow-repo tracking, directory exclusions (`ExcludedDirectoryRules`), and scan-root resolution (`ScanLocationProvider`). Parsers: `GitStatusParser`, `GitCommitLogParser`.

### The app ↔ widget contract (the key big picture)
- The app analyzes scan results and writes a JSON **snapshot** (`AppGroupData` in `Core/Models.swift`) into the App Group container `group.local.devpulse`.
- `Core/SharedSnapshotStore.swift` does the atomic persistence: stage + verify payload, then a single `rename`, guarded by a POSIX advisory lock, keeping a separately verified `.backup` file. **All snapshot reads/writes go through this store / `AppGroupStore` — never write to the container directly.**
- The widget reads that snapshot via its own `WidgetSnapshotStore` in `Widget/DevPulseWidget.swift` and renders `DevPulseWidget`. Widget refresh cadence is system-controlled; the app can only *request* a reload.
- Trust state (existence / readability / decode / freshness / app-widget consistency) is surfaced in the Settings Diagnostics tab; `docs/widgetkit-troubleshooting.md` covers the common failure modes.

### Critical constraint: the Widget target compiles a fixed subset of Core
`DevPulseNative/project.yml` defines three targets. The Widget extension sources are **only**: `Widget/DevPulseWidget.swift`, `Core/CommitReadinessEngine.swift`, `Core/CommitReadinessBadge.swift`, `Core/ActivityEvent.swift`, `Core/Models.swift`, `Core/PendingItem.swift`, `Core/SharedSnapshotStore.swift`, `Utilities/DateFormatting.swift`. Anything a widget change needs must come from that list (or be added to `project.yml` + regenerated). The test target also compiles `Widget/DevPulseWidget.swift` under a `WIDGET_TEST` compilation condition.

### project.yml is the source of truth
`DevPulseNative/project.yml` is a declarative XcodeGen spec. To change targets, sources, build settings, or entitlements: edit `project.yml`, then run `cd DevPulseNative && xcodegen generate`. **Never hand-edit the generated `.xcodeproj`.** Current identity: app `local.devpulse.app`, widget `local.devpulse.app.widget`, App Group `group.local.devpulse`, test target `local.devpulse.DevPulseTests`, macOS 14.0 deployment, Swift 6, marketing version 0.2.0.

### Big files to know
- `Core/Models.swift` (~152 KB) — schema constants, `RepositorySnapshot`, `AppGroupData`, `WidgetRepositoryEntry`, risk levels, diagnostics, freshness state. The shared data contract.
- `Core/ScanScheduler.swift` (~184 KB) — scan request queue, freshness/refresh decisions, snapshot-store state, and the user-facing store APIs.
- `Core/RefreshEngine.swift` — the pipeline; most scan-analysis decisions live here.
- `Core/PendingItem*.swift` — the 12-rule pending-item / anomaly system; model + evaluator are **pure** (no I/O), so they're directly unit-testable without App Group/signing.
- Analysis engines (commit/release readiness, risk hints, repository health, change impact, workspaces, backup/restore) are separate files under `Core/` and its `Core/Backup/` subfolder — each has a matching test class in `DevPulseNativeTests/`.

## Repo layout

- `DevPulseNative/` — the product: `App/` (SwiftUI views), `Core/` (all logic + models), `Utilities/` (`ProcessRunner`, `DateFormatting`), `Widget/`, `DevPulseNativeTests/`.
- `scripts/` — `verify.sh`, `verify-widgetkit.sh`, `install-and-self-check.sh`, `secret-scan.sh`, icon generation, and other verification scripts.
- `docs/widgetkit-troubleshooting.md` — widget/signing troubleshooting.
- `.githooks/` — pre-commit / pre-push secret scans.
