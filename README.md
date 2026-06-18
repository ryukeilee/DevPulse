# DevPulse

DevPulse is a local-first macOS app and widget for seeing recent Git activity at a glance.

This repository contains two implementations:

- `DevPulseNative/` for the Swift macOS app and Widget extension.
- `src/` for the Electron/macOS widget app.

## What It Shows

DevPulse is designed for a quick desktop glance:

- which local repositories changed most recently
- which files changed, shown by filename only
- whether a repository is dirty
- how long ago the last activity happened

DevPulse is not a todo app, task tracker, AI summarizer, or cloud dashboard.

## Privacy

DevPulse only reads local Git metadata.

It does not:

- read file contents
- read prompts or chat history
- read `.env` files, credentials, browser data, cookies, or private keys
- connect to AI, LLM, Notion, GitHub API, or other cloud services
- upload or sync data

Changed files are displayed as basenames, not full file contents.

## Native App

The Swift app keeps its data local to the machine and shares snapshots with the widget through the App Group container.

Open `DevPulseNative/DevPulseNative.xcodeproj` in Xcode to work on the native app.

Useful native commands:

```sh
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -destination platform=macOS build
```

## Electron App

The Electron prototype remains in `src/`.

Useful commands:

```sh
npm install
npm test
npm start
npm run build:app
```

## Configuration

The native app stores shared snapshot data in the App Group container and keeps scan configuration in shared defaults. Missing scan roots are treated as warnings, not fatal errors.

## Secret Safety

- Keep real credentials in local `.env` files only.
- Commit `.env.example` with placeholder values when configuration needs to be documented.
- Do not commit private keys, certificates, production dumps, or generated secrets.
- Do not commit Xcode user state, derived data, or build outputs.
- Run the repository secret scan before publishing a public release.
