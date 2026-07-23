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

- `App/`: SwiftUI app entry point, repository screens, activity timeline, pending center (PendingCenterView, PendingItemDetailView), settings, and diagnostics UI
- `Core/`: repository discovery and scanning, scheduling, readiness/risk logic, models, activity events, pending items (PendingItem, PendingItemStore, PendingItemEvaluator, PendingItemNotificationStore), launch-at-login, and shared snapshot persistence
- `Utilities/`: process execution and date formatting helpers
- `Widget/`: WidgetKit extension and its property list/entitlements
- `DevPulseNativeTests/`: Swift Testing coverage for scanning, discovery, readiness, activity events, snapshots, performance, and launch-at-login
- `Assets.xcassets/`: app icon and asset catalog
- `project.yml`: XcodeGen project definition
- `DevPulseNative.xcodeproj/`: checked-in Xcode project and shared schemes

There are currently no repository-owned `scripts/` or `docs/` verification entry points. Do not cite or depend on nonexistent helpers.

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

Run commands from this directory.

Build without requiring local signing:

```sh
xcodebuild -project DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Run the native test suite with disposable DerivedData outside the repository:

```sh
xcodebuild -project DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -derivedDataPath /tmp/devpulse-build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
```

For small logic changes, run the narrowest relevant test first when feasible, then broaden according to risk. Changes to project configuration, the Widget target, App Group storage, shared models, or snapshot encoding require at least a host-app build and the relevant native tests. Real Widget launch also requires a correctly signed local build and may need manual confirmation in macOS.

If runtime logs report `No matching profile found` or `no eligible provisioning profiles found`, record an Apple provisioning-profile/environment blocker. Do not modify app logic, identifiers, or entitlements merely to bypass local signing state.

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
