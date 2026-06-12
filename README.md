# DevPulse

DevPulse is a local-first macOS desktop widget that shows the most recent activity across local Git repositories.

It is meant for one glance at the desktop:

- which local project changed most recently
- which files changed, shown by filename only
- what kind of change it looks like, using local filename rules
- whether the project has uncommitted changes
- how long ago the last activity happened

DevPulse is not a todo tool, project manager, commit-message generator, AI summarizer, or dashboard.

## Privacy

DevPulse only reads local Git status metadata.

It does not:

- read file contents
- read prompts or chat history
- read `.env` files, credentials, browser data, cookies, or private keys
- connect to AI, LLM, Notion, GitHub API, or cloud services
- upload or sync data

The widget displays changed file basenames, such as `monitor-service.js`, not absolute paths or file contents.

## Configuration

On first launch, DevPulse creates:

```text
~/Library/Application Support/DevPulse/config.json
```

Default roots:

```json
{
  "roots": [
    "/Users/you/Projects",
    "/Users/you/Developer",
    "/Users/you/Code",
    "/Users/you/Documents/GitHub"
  ],
  "ignoredDirs": [
    "node_modules",
    ".git",
    "dist",
    "build",
    ".next",
    ".turbo",
    "coverage"
  ],
  "scanDepth": 3,
  "maxRecentFiles": 3,
  "refreshDebounceMs": 1000,
  "pollFallbackMs": 30000
}
```

Edit `roots` to add project directories. Missing directories are skipped.

Floating window state is saved in the same config file:

```json
{
  "floatingWindow": {
    "x": 1200,
    "y": 120,
    "alwaysOnTop": true,
    "collapsed": false
  }
}
```

The floating window defaults to always-on-top, uses `showInactive()` so it does not steal focus, and can be collapsed, unpinned, hidden, or restored from the menu bar item.

Runtime state is stored locally at:

```text
~/Library/Application Support/DevPulse/state.json
```

## Run

```sh
npm install
npm test
npm start
```

## Package

```sh
npm run build:app
```

The build script uses `electron-builder` to produce a macOS app package.

## Development

Important modules:

- `src/core/repo-discovery.js`: finds Git repositories under configured roots
- `src/core/git-status-reader.js`: runs allowed read-only Git commands
- `src/core/repo-watcher.js`: watches repositories with debounced refreshes
- `src/core/activity-ranker.js`: scores and ranks active projects
- `src/core/change-classifier.js`: summarizes change direction from filenames
- `src/renderer/*`: native HTML/CSS/JS desktop widget

Allowed Git commands are read-only:

- `git rev-parse --show-toplevel`
- `git branch --show-current`
- `git status --short`
- `git log -1 --pretty=%s`
- `git log -1 --pretty=%cI`

## Secret Safety

- Keep real credentials in local `.env` files only.
- Commit `.env.example` with placeholder values when configuration needs to be documented.
- Do not commit private keys, certificates, production dumps, or generated secrets.
- Local Git hooks scan staged and tracked files for common secret patterns before commits and pushes.

## FAQ

### Does DevPulse read my code?

No. V1 only reads Git command output and filesystem event paths. It does not open changed files or inspect file contents for product behavior.

### Does DevPulse call GitHub?

No. It observes local Git repositories only.

### Why is a project shown as active?

The ranking favors recent workspace changes, dirty repositories, recent commits, and non-main branches.

### Why is the summary sometimes generic?

The summary is rule-based and uses filenames only. If filenames do not match known categories, DevPulse shows `项目文件改动`.

### Can I add more project folders?

Yes. Edit `roots` in `~/Library/Application Support/DevPulse/config.json`.
