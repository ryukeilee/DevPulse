# Repository Guidelines

## Current Scope
DevPulse is currently a local-first native macOS app plus WidgetKit extension. The product scope in this repository is the Swift/Xcode app under `DevPulseNative/`; there is no web app, backend, cloud sync, GitHub API, AI integration, or Git write path here.

Preserve these boundaries unless the task explicitly changes product scope:
- read local Git metadata only
- show changed file basenames only
- do not read repository file contents unless the task requires it
- do not add commit, push, sync, or remote API behavior

## Project Structure
Primary code lives in `DevPulseNative/`.

- `App/`: SwiftUI app entry and screens
- `Core/`: repository scanning, models, sorting, readiness, shared snapshot logic
- `Utilities/`: reusable helpers
- `Widget/`: WidgetKit extension
- `DevPulseNativeTests/`: focused native tests

Support files:

- `scripts/verify-widgetkit.sh`: build plus Widget/App Group wiring checks
- `scripts/verify-activity-timeline.sh`: timeline model verification harness
- `scripts/install-and-self-check.sh`: signed local install plus runtime self-check
- `scripts/secret-scan.sh`: staged or tracked secret scan
- `scripts/generate-icon.mjs`: local icon asset generator
- `docs/widgetkit-troubleshooting.md`: WidgetKit/signing troubleshooting reference

Avoid committing DerivedData, build products, installed app bundles, or Xcode user state.

## Build And Verification
Use repository verification entry points before inventing ad hoc commands.

- Build: `xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -destination platform=macOS CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`
- Tests: `xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -derivedDataPath /tmp/devpulse-build -destination platform=macOS CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test`
- Widget wiring: `./scripts/verify-widgetkit.sh`
- Activity timeline logic: `./scripts/verify-activity-timeline.sh`

When the task touches installation, signing, launch, snapshot generation, or the app/widget runtime contract, prefer `./scripts/install-and-self-check.sh` if the environment is authorized and a signing identity is available.

For small logic changes, run the narrowest relevant verifier first, then the broader build/test command if risk justifies it.

## Project Facts That Matter During Changes
Current native targets and identifiers:

- app scheme: `DevPulse`
- app bundle id: `local.devpulse.app`
- widget bundle id: `local.devpulse.app.widget`
- shared App Group: `group.local.devpulse`
- test target bundle id: `local.devpulse.DevPulseTests`
- deployment target: macOS 14.0

This project builds a host app, a widget extension, and native tests from one Xcode project. Changes affecting bundle IDs, entitlements, `Info.plist`, widget embedding, or shared snapshot format are high-risk and should be verified explicitly.

## Change Boundaries
Keep changes tightly scoped to the active goal.

- Preserve existing SwiftUI structure and naming unless the task requires a refactor.
- Keep repository scanning read-only.
- Preserve App Group sharing between app and widget unless the task is specifically about that contract.
- Do not change signing, Team configuration, bundle identifiers, or entitlements as incidental cleanup.
- Do not introduce broad formatting churn or unrelated file moves.

## Testing Guidance
Prefer focused coverage in `DevPulseNative/DevPulseNativeTests/` when changing scan logic, readiness rules, repository discovery, or launch-at-login behavior.

If a change affects widget rendering or shared snapshot consumption, verify both:
- native build or tests
- `scripts/verify-widgetkit.sh` and/or `scripts/verify-activity-timeline.sh`, depending on the touched path

If real runtime behavior cannot be fully proven in CLI, state what was verified and what still needs manual confirmation in the installed app or widget.

## Security And Privacy
Do not commit secrets, signing material, or private keys. Keep `.env.example` as placeholder-only documentation.

DevPulse's privacy boundary is part of the product contract:
- no file-content reads unless explicitly required
- no secret harvesting
- no network or cloud integration added implicitly
- no Git write operations

Before commit or release-oriented work, run `./scripts/secret-scan.sh staged` when relevant.
