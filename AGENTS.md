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
Run commands from the repository root unless a command states otherwise.

Use repository verification entry points before inventing ad hoc commands.

- Build: `xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -destination platform=macOS CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`
- Tests: `xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -derivedDataPath /tmp/devpulse-build -destination platform=macOS CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test`
- Widget wiring: `./scripts/verify-widgetkit.sh`
- Activity timeline logic: `./scripts/verify-activity-timeline.sh`

When the task touches installation, signing, launch, snapshot generation, or the app/widget runtime contract, prefer `./scripts/install-and-self-check.sh` if the environment is authorized and a signing identity is available.

For local install or Widget acceptance on a machine without an Xcode Developer account session, prefer this order:

- `./scripts/install-and-self-check.sh`
- `./scripts/verify-widgetkit.sh`
- `pluginkit -vm -A -D -i local.devpulse.app.widget`
- `/Applications/DevPulse.app/Contents/MacOS/DevPulse --self-check`
- targeted `log show` checks for `amfid`, `taskgated-helper`, `chronod`, and `runningboardd`

Treat `codesign --verify` as necessary but not sufficient for Widget launch.
If logs show `No matching profile found` or `no eligible provisioning profiles found`, record that as an Apple provisioning-profile blocker for the current machine instead of continuing to modify app logic.

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
- Do not add account identifiers, team identifiers, certificate hashes, provisioning UUIDs, or other machine-specific signing values to docs unless the task explicitly requires them.
- Do not introduce broad formatting churn or unrelated file moves.

## Testing Guidance
Prefer focused coverage in `DevPulseNative/DevPulseNativeTests/` when changing scan logic, readiness rules, repository discovery, or launch-at-login behavior.

If a change affects widget rendering or shared snapshot consumption, verify both:
- native build or tests
- `scripts/verify-widgetkit.sh` and/or `scripts/verify-activity-timeline.sh`, depending on the touched path

If real runtime behavior cannot be fully proven in CLI, state what was verified and what still needs manual confirmation in the installed app or widget.

## Definition Of Done
- The requested behavior is implemented with the smallest sufficient in-scope change.
- The narrowest relevant verifier passes; broaden to build, tests, Widget wiring, or runtime self-check only when the touched behavior requires it.
- Documentation-only changes are checked by focused inspection and do not require unrelated builds.
- The final diff and Git status contain no unrelated edits, generated artifacts, build products, or machine-local state.
- The final report names checks actually run and any remaining manual confirmation, environment limitation, or blocker.

## Review Guidelines
- Report only actionable defects introduced by the change, with the affected path and concrete impact; do not report style-only preferences as findings.
- Treat regressions in the local-first privacy boundary as blocking, including unexpected file-content reads, network or cloud access, Git writes, or disclosure of paths beyond the intended basename-only UI.
- Flag incidental changes to bundle identifiers, App Group wiring, entitlements, signing configuration, deployment target, or the shared snapshot contract.
- Flag committed secrets, signing material, machine-specific identifiers, build products, DerivedData, installed app bundles, or Xcode user state.
- Verify that changed scan, readiness, discovery, Widget, snapshot, or launch-at-login behavior has focused coverage or an explicit verification path; flag weakened or bypassed tests.

## Security And Privacy
Do not commit secrets, signing material, or private keys. Keep `.env.example` as placeholder-only documentation.

DevPulse's privacy boundary is part of the product contract:
- no file-content reads unless explicitly required
- no secret harvesting
- no network or cloud integration added implicitly
- no Git write operations

Before commit or release-oriented work, run `./scripts/secret-scan.sh staged` when relevant.
