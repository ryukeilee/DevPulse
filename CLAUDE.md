# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DevPulse is a local-first macOS app that surfaces recent Git activity at a glance. It shows which local repos changed recently, which files changed (basename only), whether a repo is dirty, and how long ago the last activity happened. It reads only local Git metadata — no file contents, no network calls, no cloud services.

Two implementations live side-by-side:
- **`DevPulseNative/`** — Swift 6 macOS app + Widget extension (Xcode project)
- **`src/`** — Electron prototype (`main.js`, preload, renderer)

## Build, Test, and Run

```sh
# Electron app
npm install                    # install dependencies (electron 31, chokidar, electron-builder)
npm start                      # launch Electron app
npm test                       # run test suite (node --test test/*.test.js)
npm run build:icon             # regenerate app icon from build/icon.svg
npm run build:app              # package macOS .dmg via electron-builder
npm run scan:secrets           # run secret scan on tracked files

# Swift native app
# NOTE: Use -derivedDataPath /tmp/devpulse-build for worktree/Desktop builds.
# iCloud Desktop adds com.apple.FinderInfo to new directories, which codesign rejects.
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj \
  -scheme DevPulse -configuration Debug -derivedDataPath /tmp/devpulse-build build

# Widget Extension standalone build
xcodebuild -project DevPulseNative/DevPulseNative.xcodeproj \
  -scheme DevPulseWidgetExtension -configuration Debug \
  -derivedDataPath /tmp/devpulse-build build

# Regenerate Xcode project from project.yml (after editing project.yml)
cd DevPulseNative && xcodegen generate
```

## Architecture

### Electron App (`src/`)

```
src/main.js              ← Main process: window, tray, IPC, watcher orchestration
src/preload.js           ← contextBridge: exposes devPulse/floatingWindow/desktopWidget APIs
src/core/                ← Pure logic modules (no Electron imports except chokidar)
  config-store.js        → load/save config.json from ~/Library/Application Support/DevPulse
  state-store.js         → load/save/rebuild state.json; assembles projects + activityTimeline
  git-status-reader.js   → spawns `git status --short`, parses output into entries/files
  repo-discovery.js      → walks configured scan roots to find .git directories
  repo-watcher.js        → RepoWatcher class: per-repo chokidar watchers with dedup
  activity-ranker.js     → scores projects by recency, dirty state, branch
  activity-timeline.js   → deduplicates and timestamps activity records (max 10)
  change-classifier.js   → classifies changed files into categories (refresh, data, menu, etc.)
  commit-readiness.js    → rules-based readiness assessment (blocked/review/ready)
  risk-hint.js           → flags risky changes (secrets, build config, large diffs, etc.)
src/renderer/            ← HTML/CSS/JS loaded in BrowserWindow (contextIsolation on)
src/utils/
  debounce.js            → generic debounce utility
  logger.js              → thin wrappers: log() → console.log, warn() → console.warn
  path-utils.js          → expandHome(), defaultConfigDir(), basenameOnly()
```

**Data flow**: `discoverRepositories()` walks scan roots → `readGitStatus()` spawns git → `buildState()` enriches with rank/risk/readiness/timeline → `saveState()` persists to `state.json` → IPC pushes to renderer. `RepoWatcher` uses chokidar per-repo for live updates; a configurable poll fallback (`pollFallbackMs`, default 30s) runs `refreshAllProjects()` as a safety net.

**State shape** (in `state.json`):
```js
{
  projects: [{ name, path, branch, dirty, changedFiles, summary, tags, riskHint, commitReadiness, score, ... }],
  activityTimeline: [{ id, projectName, projectPath, summary, files, changedFileCount, createdAt, updatedAt }],
  activeProjectPath: string|null,
  updatedAt: ISO string
}
```

### Swift Native App (`DevPulseNative/`)

```
DevPulseNative/
├── App/                      — SwiftUI views (DevPulseApp, ContentView, RepositoryListView, ScanStatusView, SettingsView)
├── Core/
│   ├── Models.swift          — RepositorySnapshot, RiskLevel, AppGroupData, WidgetRepositoryEntry, ScanSummary
│   ├── GitRepositoryScanner.swift — discovery + batched git-status read + slow-repo tracking (actor)
│   ├── GitStatusParser.swift — parses `git status --short` output
│   ├── AppGroupStore.swift   — reads/writes AppGroupData to shared container
│   ├── RepositorySorter.swift
│   ├── RiskHintEngine.swift
│   ├── ScanScheduler.swift
│   ├── ScanLocationProvider.swift
│   └── ExcludedDirectoryRules.swift
├── Utilities/
│   ├── DateFormatting.swift
│   └── ProcessRunner.swift   — spawns git processes with timeout
├── Widget/                   — WidgetKit extension (small/medium/large sizes)
└── project.yml               — XcodeGen spec; generates .xcodeproj
```

**App Group sharing**: The native app writes `AppGroupData` (schema v1) to the shared container `group.local.devpulse`. The Widget extension reads the shared snapshot. The Electron app stores its own state independently in `~/Library/Application Support/DevPulse/`.

**Key Swift config**: macOS 14.0+, Swift 6.0, XcodeGen (project.yml), optional SwiftLint pre-build script.

## Coding Conventions

- **`src/`**: Plain JavaScript with CommonJS (`require`/`module.exports`). Two-space indent, semicolons, descriptive camelCase, kebab-case filenames. Electron main process code stays in `src/main.js`; keep `src/core/` modules free of Electron imports (only chokidar is allowed).
- **`DevPulseNative/`**: Swift 6, structured concurrency, SwiftUI, WidgetKit. Use `struct` value types by default, actors for shared mutable state, `let` over `var`.

## Testing

- Node test runner (`node --test`) with `node:assert/strict`. Tests live in `test/*.test.js`.
- Tests should be deterministic — use temp directories for file I/O, mock git output when testing parsers. See `test/config-store.test.js` for the pattern.
- Swift tests use `@Test` macro and `#expect` (Swift Testing framework).

## Configuration

Config lives at `~/Library/Application Support/DevPulse/config.json`. Defaults:
- `scanDepth`: 3 (max directory depth for repo discovery)
- `pollFallbackMs`: 30000 (full rescan interval)
- `refreshDebounceMs`: 1000 (filesystem watch debounce)
- `dataRetentionDays`: 14 (activity timeline pruning)
- `ignoredDirs`: `node_modules`, `.git`, `dist`, `build`, `.next`, `.turbo`, `coverage`

`roots` default to `~/Projects`, `~/Developer`, `~/Code`, `~/Documents/GitHub` — only existing directories are watched.

## Security Constraints

- Never read file contents — only Git metadata (filenames, status, branch, commit messages)
- Never add network calls, AI/LLM integration, cloud sync, or telemetry
- Secrets stay in `.env` (gitignored); `.env.example` has placeholder values only
- Pre-commit hook blocks common secret patterns in staged files
- Run `npm run scan:secrets` before public releases
