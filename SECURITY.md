# Security

## Sensitive Data Policy

Do not commit credentials, tokens, private keys, certificates, production database dumps, or personal data.

Use local `.env` files for real secrets. Keep `.env.example` limited to placeholder names and safe defaults.

Before pushing, run:

```sh
git diff --cached
git status
```

The repository also installs a local pre-commit hook that blocks common secret patterns in staged files.
