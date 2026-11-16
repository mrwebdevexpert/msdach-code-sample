#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|MultiEdit): blocks edits to migrations that are
# already committed, and to env/secret files. Exit 2 = block, message to Claude.
set -euo pipefail
input=$(cat)
file=$(jq -r '.tool_input.file_path // empty' <<<"$input")
[[ -z "$file" ]] && exit 0
root=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$CLAUDE_PROJECT_DIR")
rel=${file#"$root"/}

case "$rel" in
  .env|.env.*|*/.env|*/.env.*|supabase/.temp/*)
    echo "Blocked: $rel holds secrets. Keys come from env/CI secrets, never from files in the repo." >&2
    exit 2 ;;
  supabase/migrations/*.sql)
    if git -C "$root" cat-file -e "HEAD:$rel" 2>/dev/null; then
      echo "Blocked: $rel is already committed. Applied migrations are append-only (CLAUDE.md). Create a new migration with 'supabase migration new <name>'." >&2
      exit 2
    fi ;;
esac
exit 0
