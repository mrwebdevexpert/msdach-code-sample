#!/usr/bin/env bash
# Fails if a PR changes or deletes a migration that already exists on the base
# branch. Applied migrations are never edited; a change is a new migration.
set -euo pipefail
base="${1:-origin/main}"
changed=$(git diff --name-status "$base"...HEAD -- supabase/migrations | awk '$1 != "A" {print $0}')
if [[ -n "$changed" ]]; then
  echo "Existing migrations were modified or deleted (create a new migration instead):"
  echo "$changed" | sed 's/^/  /'
  exit 1
fi
echo "Migrations: only new files added."
