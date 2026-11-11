#!/usr/bin/env bash
# Lightweight static check for the shell scripts.
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

while IFS= read -r -d '' f; do
  if bash -n "$f"; then
    printf 'ok   %s\n' "${f#"$ROOT_DIR"/}"
  else
    printf 'FAIL %s\n' "${f#"$ROOT_DIR"/}"
    fail=1
  fi
done < <(find "$ROOT_DIR/scripts" -name '*.sh' -print0 | sort -z)

if command -v shellcheck >/dev/null 2>&1; then
  printf '\nshellcheck:\n'
  if shellcheck -x -S warning "$ROOT_DIR"/scripts/*.sh; then
    printf 'shellcheck clean\n'
  else
    fail=1
  fi
fi

exit "$fail"
