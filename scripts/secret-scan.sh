#!/usr/bin/env sh
set -eu

mode="${1:-staged}"

case "$mode" in
  staged)
    files="$(git diff --cached --name-only --diff-filter=ACMR)"
    diff_output="$(git diff --cached --unified=0 --no-ext-diff -- .)"
    ;;
  tracked)
    files="$(git ls-files)"
    diff_output="$(git grep -n -I -E '.' -- . || true)"
    ;;
  *)
    echo "Usage: scripts/secret-scan.sh [staged|tracked]" >&2
    exit 2
    ;;
esac

if [ -z "$files" ]; then
  exit 0
fi

blocked_files="$(printf '%s\n' "$files" \
  | grep -Ev '(^|/)\.env\.example$' \
  | grep -E '(^|/)\.env($|\.)|(^|/)(id_rsa|id_dsa|id_ecdsa|id_ed25519)$|\.(pem|key|p12|pfx|jks|keystore)$' || true)"

if [ -n "$blocked_files" ]; then
  echo "Blocked: sensitive-looking files are present:" >&2
  printf '%s\n' "$blocked_files" >&2
  echo "Move secrets to local ignored files and commit only safe examples." >&2
  exit 1
fi

secret_hits="$(printf '%s\n' "$diff_output" \
  | grep -Ei '((aws_access_key_id|aws_secret_access_key|api[_-]?key|secret[_-]?key|private[_-]?key|access[_-]?token|auth[_-]?token)[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9_./+=:-]{12,}|bearer[[:space:]]+[a-z0-9._~+/=-]{20,}|-----BEGIN (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----|ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,})' || true)"

if [ -n "$secret_hits" ]; then
  echo "Blocked: possible secret values found." >&2
  echo "$secret_hits" >&2
  echo "If this is a false positive, rewrite the line to avoid committing secret-like values." >&2
  exit 1
fi

exit 0
