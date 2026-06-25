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

## About free Apple ID and ad-hoc signing

This project is intended for local development.

Free Apple ID and ad-hoc signing can work for local testing, but they may be fragile when the account state, entitlements, or derived data change. If the widget or App Group stops working after a signing change:

- switch back to Automatic signing
- select the same Team on both targets
- clean build
- reinstall the app

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
