#!/usr/bin/env bash
# PostToolUse hook (Edit|Write|MultiEdit): runs the fast checks for what was
# just changed and feeds failures back to Claude (exit 2), so it fixes them
# before moving on.
set -uo pipefail
input=$(cat)
file=$(jq -r '.tool_input.file_path // empty' <<<"$input")
cd "$CLAUDE_PROJECT_DIR" || exit 0

case "$file" in
  *supabase/functions/*.ts)
    if ! out=$(deno fmt --check "$file" 2>&1 && deno lint "$file" 2>&1 && deno check "$file" 2>&1 && deno task test 2>&1); then
      echo "Checks failed after editing $file:" >&2; tail -40 <<<"$out" >&2; exit 2
    fi ;;
  *supabase/migrations/*.sql|*supabase/tests/*.sql)
    if ! out=$(./scripts/check_policy_coverage.sh 2>&1); then
      echo "$out" >&2; exit 2
    fi
    if command -v pg_config >/dev/null 2>&1; then
      if ! out=$(./scripts/test-db-local.sh 2>&1); then
        echo "pgTAP failed after editing $file:" >&2; grep -E '^not ok|^#|ERROR' <<<"$out" | head -40 >&2; exit 2
      fi
    fi ;;
esac
exit 0
