# DevPulse Agent Notes

DevPulse is local-first and privacy-first.

Do:

- Read only local Git metadata through allowed read-only Git commands.
- Show only repository names, basenames of changed files, branch names, dirty state, and commit metadata.
- Keep the widget small, quiet, and low resource.
- Prefer small focused modules with tests for parsing, ranking, and classification.

Do not:

- Read file contents for product behavior.
- Read chat logs, prompts, browser data, credentials, `.env` files, private keys, cookies, or personal data.
- Call GitHub, Notion, AI, LLM, cloud APIs, or remote sync services from the app.
- Run Git write commands such as push, pull, checkout, reset, clean, or commit.

