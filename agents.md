# Repository Guidelines

## Project Structure & Module Organization
This repository contains two app implementations:
- `src/` for the Electron/macOS widget app.
- `DevPulseNative/` for the Swift/Xcode native app and widget extension.

Within `src/`, keep process code in `src/main.js`, preload code in `src/preload.js`, shared logic in `src/core/`, helper utilities in `src/utils/`, and UI assets in `src/renderer/`. Tests live in `test/`. Generated or packaged assets belong in `build/`. Scripts live in `scripts/`.

Within `DevPulseNative/`, keep app code in `App/`, shared models and scan logic in `Core/`, reusable helpers in `Utilities/`, and Widget code in `Widget/`. Avoid committing Xcode user data, DerivedData, or build output from this directory.

## Build, Test, and Development Commands
- `npm install` installs Electron and build dependencies.
- `npm start` launches the Electron app locally.
- `npm test` runs the Node test suite with `node --test`.
- `npm run build:icon` regenerates the app icon from the SVG source.
- `npm run build:app` packages the macOS app with `electron-builder`.
- `npm run scan:secrets` runs the repository secret scan.
- `xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -destination platform=macOS build` builds the native macOS app and Widget extension.

## Coding Style & Naming Conventions
Use plain JavaScript with CommonJS modules in `src/`. Follow the existing style: two-space indentation, semicolon-terminated statements, and small focused modules. Prefer descriptive camelCase for variables and functions, and kebab-case for filenames where practical, such as `git-status-reader.js`. Keep renderer files split by concern: HTML, CSS, and browser JS.

## Testing Guidelines
Use the Node test runner in `test/*.test.js`. Name tests after the unit or behavior under test, for example `activity-ranker.test.js`. Prefer deterministic tests that avoid real Git or filesystem side effects unless the test explicitly uses fixtures. Run `npm test` before submitting changes that touch logic in `src/core/` or `src/utils/`.

## Commit & Pull Request Guidelines
Recent commits use short, imperative subjects, often with a conventional prefix such as `feat:` or `fix:`. Keep commits narrowly scoped and explain behavior changes, not implementation trivia. Pull requests should summarize the user-visible impact, list verification steps, and include screenshots or screen recordings for UI changes.

## Security & Configuration Tips
Do not commit real secrets, credentials, or private keys. Use `.env.example` for documented placeholders and keep local overrides untracked. The app reads local Git metadata only, so avoid adding code that opens repository file contents unless the change is explicitly required.

When preparing a public release, double-check for local signing identities, Team IDs, Xcode workspace user state, and any build artifacts before pushing.
