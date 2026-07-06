# DevPulse

DevPulse is a local-first macOS Git activity glance widget.

It automatically scans Git repositories on your Mac, reads only local Git metadata, and gives you a quick view of recent activity, repository health, and commit readiness. The project now ships only the native Swift app in `DevPulseNative/`.

## Why DevPulse Exists

Git status is useful, but it is not great for a fast desktop glance. DevPulse is meant to answer a small set of questions quickly:

- which local repositories changed recently
- what files changed, shown by filename only
- whether a repository is dirty
- how many files changed
- whether the repo looks ready to commit

## Current State

DevPulse is currently a native macOS + WidgetKit MVP.

It includes:

- a SwiftUI macOS app
- a WidgetKit extension
- local repository discovery
- read-only Git metadata scanning
- an App Group snapshot shared between the app and widget
- WidgetKit diagnostics in the app
- an Overview Widget data trust status bar
- activity timeline views
- rules-based commit readiness hints

## What DevPulse Is Not

DevPulse is not:

- a Git GUI
- a todo app
- an AI commit generator
- an automatic commit tool
- a remote sync service
- a cloud dashboard

It does not create commits, push code, or write to Git history.

## Privacy Boundary

DevPulse is designed to stay local.

It reads:

- repository path
- repository name
- branch name
- Git status
- file basenames
- change counts
- recent scan time

It does not read:

- file contents
- `.env` files
- secrets or credentials
- chat history
- browser data
- private keys

It does not:

- call GitHub, Notion, AI, LLM, or cloud APIs
- upload or sync data
- run `git` write commands
- generate commit messages

Changed files are shown as basenames only.

## Install And Run

### Prerequisites

- macOS 14 or later
- Xcode 16 or later
- the same signing setup for both targets

### Open The Project

Open the native project:

```sh
open DevPulseNative/DevPulseNative.xcodeproj
```

### Choose Signing Setup

In Xcode:

1. Select the `DevPulse` target.
2. Open `Signing & Capabilities`.
3. Pick the same signing setup for both the app and `DevPulseWidgetExtension`.
4. If you do have a Developer account session, keep both targets on the same Team.
5. If you do not have a Developer account session, you can still use the local-install downgrade path below.
6. Make sure both targets keep the same App Group: `group.local.devpulse`.

### Run A Debug Build

Use Xcode's Run button, or run the Debug build from the command line:

```sh
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -destination platform=macOS build
```

If the machine does not have matching provisioning profiles, use the no-signing build for compile verification:

```sh
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -destination platform=macOS CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

### Install A Local Debug Build

If you only need a local `/Applications` install, prefer the repository script:

```sh
./scripts/install-and-self-check.sh
```

This script:

- builds the app without Xcode-managed signing
- signs the host app and widget with the same local identity
- installs the latest build to `/Applications/DevPulse.app`
- launches the app
- runs the headless self-check
- verifies shared snapshot generation

The manual equivalent is:

```sh
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -derivedDataPath /tmp/devpulse-build -destination platform=macOS CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
security find-identity -v -p codesigning
codesign --force --sign <SIGNING_IDENTITY_HASH> --timestamp=none --entitlements DevPulseNative/Widget/DevPulseWidgetExtension.entitlements /tmp/devpulse-build/Build/Products/Debug/DevPulse.app/Contents/PlugIns/DevPulseWidgetExtension.appex
codesign --force --sign <SIGNING_IDENTITY_HASH> --timestamp=none --entitlements DevPulseNative/App/DevPulse.entitlements /tmp/devpulse-build/Build/Products/Debug/DevPulse.app
codesign --verify --deep --strict --verbose=2 /tmp/devpulse-build/Build/Products/Debug/DevPulse.app
ditto /tmp/devpulse-build/Build/Products/Debug/DevPulse.app /Applications/DevPulse.app
open -n /Applications/DevPulse.app
```

If you ran tests immediately before installing and the build product contains `DevPulseTests.xctest` inside `DevPulse.app/Contents/PlugIns/`, remove that test bundle from the build product before signing the app for installation.

### Local Acceptance Without A Developer Account

On a machine with no Xcode Developer account session, treat Widget launch as a separate runtime check instead of assuming local signing is enough.

Recommended acceptance sequence:

```sh
./scripts/install-and-self-check.sh
./scripts/verify-widgetkit.sh
pluginkit -vm -A -D -i local.devpulse.app.widget
/Applications/DevPulse.app/Contents/MacOS/DevPulse --self-check
```

Interpret the results this way:

- if `install-and-self-check` passes and `self_check.validation=pass`, the host app and shared snapshot path are locally healthy
- if `pluginkit` shows the widget, WidgetKit discovery succeeded on this machine
- if the widget still fails and logs show `No matching profile found`, treat it as an Apple provisioning-profile blocker for that machine

Useful runtime log check:

```sh
log show --last 10m --style compact --predicate 'process == "amfid" OR process == "taskgated-helper" OR process == "chronod"'
```

If the logs say the app or widget was disallowed because no eligible provisioning profiles were found, stop changing app code and treat that as an external signing limitation.

### Verify The Widget Wiring

Run the widget verification script from the repository root:

```sh
./scripts/verify-widgetkit.sh
```

This checks the project wiring, the widget extension point, the App Group entitlement, and the host/widget bundle relationship.

### Run Native Tests

Use the shared `DevPulse` scheme and disable code signing for local CLI test runs:

```sh
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -derivedDataPath /tmp/devpulse-build -destination platform=macOS CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
```

To run only the diagnostics and commit-readiness tests:

```sh
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -derivedDataPath /tmp/devpulse-build -destination platform=macOS CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:DevPulseTests/CommitReadinessEngineTests test
```

## How To Use The Widget

1. Launch DevPulse and run a scan.
2. Right-click the desktop and choose `Edit Widgets...`.
3. Search for `DevPulse`.
4. Add the widget in the size you want.
5. Keep the app open when you want to rescan or inspect diagnostics.

The widget footer shows the current shared snapshot age. When the widget shows states such as `尚未生成快照`, `共享快照损坏`, `快照版本不匹配`, or `数据可能已过期`, open DevPulse and use `Refresh Data` or `Rescan Now`, then confirm the Diagnostics section.

Widget refresh cadence is managed by macOS. DevPulse can request updates after a scan, but it does not control the system refresh clock.

## How To Rescan

Use the `Rescan Now` button in the app's Overview or Settings tabs.

The Settings tab also exposes `Refresh Data`, which is useful when you want to force a fresh snapshot after changing signing, App Group, or scan directories.

The Overview tab includes a Widget data trust status bar above the activity timeline. It summarizes whether the Widget data is trustworthy, stale, or currently not reliable, and its `Refresh Data` button rewrites the shared snapshot and requests a WidgetKit timeline refresh.

## How To Check Diagnostics

Open the app and go to `Settings`.

The Diagnostics section shows:

- a top-level Widget data trust card that says whether the current Widget data is trustworthy, stale, or needs repair
- a trust checklist for snapshot existence, app read/write, decode status, freshness, and App/Widget consistency
- App and widget bundle identifiers
- App Group status
- shared snapshot path
- whether the shared snapshot exists
- whether the shared snapshot is readable and writable
- whether the snapshot decoded successfully
- generated / written timestamps and current freshness assessment
- when the app last requested a WidgetKit reload
- recent scan and validation state

If the widget is not behaving correctly, this is the first place to look. Start with the Widget data trust card, then follow the listed next steps such as `Refresh Data`, `Rescan Now`, checking App Group / Signing, or doing a clean rebuild.

## WidgetKit And Signing Troubleshooting

For detailed troubleshooting, see [docs/widgetkit-troubleshooting.md](docs/widgetkit-troubleshooting.md).

Common checks:

- the app and widget use the same App Group ID
- the widget Info.plist uses the WidgetKit extension point
- the widget is embedded in the host app
- the app and widget share the same Team
- stale derived data is cleared after signing changes
- old app installs are removed before retrying

## Common Questions

### Does DevPulse read file contents?

No. It only reads local Git metadata and file basenames.

### Does DevPulse connect to GitHub or the cloud?

No. There is no GitHub API, Notion API, AI, LLM, or other cloud integration in the native app.

### Does DevPulse auto-commit code?

No. It never writes Git history or commits on your behalf.

### Why does the widget refresh slowly?

WidgetKit controls refresh cadence. DevPulse can request updates, but macOS decides when the widget actually redraws.

### Why can commit readiness say "review" instead of "ready"?

The readiness rule set is intentionally conservative. Large diffs, deleted files, untracked files, high-risk changes, or scan errors can push a repo into review.

## Known Limitations

- Best suited for the local developer who is running it on the same Mac
- Free Apple ID and non-notarized local signing have practical limits
- WidgetKit refresh cadence is system-managed
- Only read-only Git metadata is supported
- Very large or complex monorepos may need manual scan-root tuning
- Remote repository state is not tracked
- Commit message generation is not part of the product

## Roadmap

This roadmap stays intentionally narrow:

- Improve WidgetKit reliability
- Better repository discovery controls
- More precise readiness rules
- Lightweight release packaging
- Optional signed release path

## Contributing

Contributions are welcome if they stay within the current scope.

Please:

- keep changes small and reviewable
- avoid adding network, cloud, AI, or sync dependencies
- avoid reading file contents
- keep the docs accurate to the code
- run the WidgetKit verification script before opening a PR

## Repository Layout

- `DevPulseNative/` - native Swift macOS app and WidgetKit extension
- `src/` - legacy Electron prototype
- `scripts/` - verification and maintenance scripts
- `docs/` - troubleshooting and support docs
