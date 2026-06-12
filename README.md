# DevPulse

DevPulse repository initialized with a baseline secret-protection setup.

## Secret Safety

- Keep real credentials in local `.env` files only.
- Commit `.env.example` with placeholder values when configuration needs to be documented.
- Do not commit private keys, certificates, tokens, production dumps, or generated secrets.
- A local Git pre-commit hook scans staged changes for common secret patterns before commits.

