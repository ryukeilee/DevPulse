# WidgetKit, Signing, and App Group Troubleshooting

This guide covers the most common local-debug problems for the native macOS app and its WidgetKit extension.

## What `scripts/verify-widgetkit.sh` checks

Run this script from the repository root:

```sh
./scripts/verify-widgetkit.sh
```

It verifies the project wiring, not your Apple account state. The script checks that:

- the Debug build succeeds
- the widget bundle is produced
- the widget is embedded inside the app bundle
- the app and widget bundle identifiers match the project settings
- the widget Info.plist uses `com.apple.widgetkit-extension`
- the widget points back to the host app with `WKAppBundleIdentifier`
- both targets use the same App Group: `group.local.devpulse`
- the Xcode project embeds the widget target correctly

## If the widget does not appear in Widget Gallery

Check these items first:

1. Open `DevPulseNative/DevPulseNative.xcodeproj` in Xcode.
2. Select both `DevPulse` and `DevPulseWidgetExtension`.
3. In Signing & Capabilities, make sure both targets use the same Team.
4. Confirm both targets share the same App Group ID: `group.local.devpulse`.
5. Confirm the widget extension Info.plist still has the WidgetKit extension point.
6. Rebuild the app, then open `Edit Widgets...` and search for DevPulse again.

If the gallery still shows an old or missing entry:

- delete the previously installed app build
- remove the existing widget from the desktop
- clean the Xcode build folder
- rebuild and try the gallery again
- if needed, log out and back in, or restart the Mac to refresh WidgetKit caches

## If App Group is unavailable

The app and the widget must see the same App Group container.

Common causes:

- the app target and widget target are signed by different Teams
- one target lost the App Group entitlement
- the App Group ID changed in one place but not the other
- the widget was built from stale derived data

What to check:

- `App/DevPulse.entitlements`
- `Widget/DevPulseWidgetExtension.entitlements`
- `DevPulseNative/project.yml`
- the diagnostics panel in the app Settings tab

If the app still reports App Group unavailable:

1. Verify both entitlements contain `group.local.devpulse`.
2. Reopen the Xcode project and reselect your Team for both targets.
3. Clean build.
4. Delete the old app copy and rebuild from scratch.

## If the widget shows "尚未生成快照", "没有找到仓库", "数据可能已过期", or "共享快照损坏"

This usually means the shared `repositories.json` file is missing, empty, stale, unreadable, or incompatible with the current schema.

Useful checks:

- open the app
- click `Refresh Data` or `Rescan Now`
- open the Settings tab
- inspect the Diagnostics section, starting from the Widget data trust card
- confirm the trust checklist shows snapshot exists, app read/write, decodable, freshness, and App/Widget consistency
- then confirm `Generated at`, `Written at`, and `Reload requested`

Interpret the widget states this way:

- `尚未生成快照`: the shared snapshot file does not exist yet; trigger `Refresh Data` or `Rescan Now`
- `没有找到仓库`: the snapshot decoded, but it currently contains zero repositories; check scan roots
- `数据可能已过期`: the widget decoded a snapshot, but its `generatedAt` / `writtenAt` is outside the trusted freshness window
- `共享快照损坏`: the file exists but failed to decode; rewrite it from the app
- `快照版本不匹配`: the app and widget are not reading the same schema revision; rebuild both, then rewrite the snapshot

If decoding fails:

- the app and widget may be built from different code revisions
- derived data may be stale
- the shared snapshot may have been created before a schema change

Recovery steps:

1. Quit DevPulse.
2. Delete the existing app build.
3. Clean the Xcode build folder.
4. Rebuild and run the app.
5. Trigger `Rescan Now` so the app rewrites the shared snapshot.

## About free Apple account, local signing, and Widget discovery

This project is intended for local development.

For WidgetKit on macOS, the important distinction is:

- no paid Apple Developer Program membership may still be acceptable for local development
- but you still need an Apple account signed in to Xcode so automatic signing can obtain local development profiles

Ad-hoc or manual local `codesign` alone is not enough to make the system discover a WidgetKit extension. If the widget or App Group stops working after a signing change:

- switch back to Automatic signing
- select the same Team on both targets
- clean build
- reinstall the app

## Local install with an Apple account in Xcode

If this Mac has an Apple account signed in to Xcode, use the local install flow below to validate both the host app and Widget discovery.

Recommended local acceptance flow:

```sh
./scripts/install-and-self-check.sh
./scripts/verify-widgetkit.sh
pluginkit -vm -A -D -i local.devpulse.app.widget
/Applications/DevPulse.app/Contents/MacOS/DevPulse --self-check
```

What this proves:

- the host app builds locally
- the app and widget were built through Xcode automatic signing
- the app is installed to `/Applications/DevPulse.app`
- the app launches
- `self_check.result=pass`
- `self_check.validation=pass`
- the widget target is embedded and wired correctly

What this does not prove:

- that WidgetKit will accept and launch the widget if this Mac has no eligible local development profiles

If `pluginkit -i local.devpulse.app.widget` returns no match, or `chronod` keeps logging that it cannot find `local.devpulse.app.widget`, treat that as a runtime blocker outside the business logic first.

Useful log patterns:

- `Unknown extension process`
- `Unable to find local.devpulse.app.widget extension directly`
- `No matching profile found`
- `Disallowing local.devpulse.app.widget because no eligible provisioning profiles found`

If `amfid` or `taskgated-helper` reports `No matching profile found` for either:

- `/Applications/DevPulse.app/Contents/MacOS/DevPulse`
- `/Applications/DevPulse.app/Contents/PlugIns/DevPulseWidgetExtension.appex/Contents/MacOS/DevPulseWidgetExtension`

then stop changing app code. Record the failure as an Apple provisioning-profile blocker for this machine.

If `xcodebuild` fails earlier with either of these:

- `No Accounts: Add a new account in Accounts settings.`
- `No profiles for 'local.devpulse.app.widget' were found`

then the machine is missing the Apple-account-backed provisioning setup that WidgetKit needs. This is not fixable by local `codesign` alone.

## What the app diagnostics should look like

In the Settings tab, the Diagnostics section should eventually show:

- `当前 Widget 数据可信` in the Widget data trust card
- a trust checklist where snapshot file exists, the app can read/write it, the snapshot decodes, and App/Widget consistency is `一致`
- a valid App Bundle identifier
- a valid Widget Bundle identifier
- an App Group container path
- a snapshot file path
- `Snapshot exists: Yes`
- `Snapshot readable: Yes`
- `Snapshot writable: Yes`
- `Snapshot decodable: Yes`
- a recent `Generated at` / `Written at`
- a recent `Reload requested`
- matching shared read/write/widget snapshot state

If those fields disagree, the app, shared snapshot, and widget are not all looking at the same state yet.
