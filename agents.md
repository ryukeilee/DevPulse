# Repository Guidelines

## Project Structure & Module Organization
This repository contains the native Swift/Xcode app and widget extension in `DevPulseNative/`.

Within `DevPulseNative/`, keep app code in `App/`, shared models and scan logic in `Core/`, reusable helpers in `Utilities/`, and Widget code in `Widget/`. Scripts live in `scripts/`. Avoid committing Xcode user data, DerivedData, or build output from this directory.

## Build, Test, and Development Commands
- `xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj -scheme DevPulse -configuration Debug -destination platform=macOS build` builds the native macOS app and Widget extension.

## Coding Style & Naming Conventions
Use Swift conventions already established in `DevPulseNative/`. Keep types and views focused, preserve existing naming, and avoid unrelated structural rewrites while working on the native app or widget.

## Testing Guidelines
For native Swift changes, prefer focused tests in `DevPulseNative/DevPulseNativeTests/` and run the shared `DevPulse` scheme with code signing disabled for CLI verification.

## Commit & Pull Request Guidelines
Recent commits use short, imperative subjects, often with a conventional prefix such as `feat:` or `fix:`. Keep commits narrowly scoped and explain behavior changes, not implementation trivia. Pull requests should summarize the user-visible impact, list verification steps, and include screenshots or screen recordings for UI changes.

## Security & Configuration Tips
Do not commit real secrets, credentials, or private keys. Use `.env.example` for documented placeholders and keep local overrides untracked. The native app reads local Git metadata only, so avoid adding code that opens repository file contents unless the change is explicitly required.

When preparing a public release, double-check for local signing identities, Team IDs, Xcode workspace user state, and any build artifacts before pushing.
