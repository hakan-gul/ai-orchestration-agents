#!/usr/bin/env bash
# Build dist/AI-ORCHESTRATION.md (guide + full source of every file, extractable) and dist/ai-agents.tar.gz
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dist
FILES=$(git ls-files --cached --others --exclude-standard | grep -vE '^(dist/|docs/GUIDE\.md$)' | sort)
F="$(printf '~%.0s' 1 2 3 4 5 6 7 8)"   # fence; built at runtime so this file does not contain it
grep -l -- "$F" $FILES >/dev/null 2>&1 && { echo "a file contains the fence $F" >&2; exit 1; }
N=$(echo "$FILES" | wc -l)
{
  cat docs/GUIDE.md
  echo
  echo "---"
  echo
  echo "## Appendix: full source"
  echo
  echo "Each file follows a \`<!-- file: PATH mode: PERM -->\` marker, fenced with \`$F\`. Extract them with the command in the installation guide (\"Get the files\"). Packed $(date +%F), $N files."
  echo
  for f in $FILES; do
    mode=644; [ -x "$f" ] && mode=755
    case "$f" in *.sh|tests/stubs/*) lang=bash;; *.py) lang=python;; *.json) lang=json;; *.md) lang=markdown;; *) lang=text;; esac
    printf '### `%s`\n\n<!-- file: %s mode: %s -->\n%s%s\n' "$f" "$f" "$mode" "$F" "$lang"
    cat "$f"; [ -n "$(tail -c1 "$f")" ] && echo
    printf '%s\n\n' "$F"
  done
} > dist/AI-ORCHESTRATION.md
tar -czf dist/ai-agents.tar.gz $FILES docs/GUIDE.md
echo "dist/AI-ORCHESTRATION.md ($(wc -c < dist/AI-ORCHESTRATION.md) bytes, $N files)  dist/ai-agents.tar.gz ($(wc -c < dist/ai-agents.tar.gz) bytes)"
