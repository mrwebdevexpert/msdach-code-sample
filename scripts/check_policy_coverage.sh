#!/usr/bin/env bash
# Fails if an RLS policy created in supabase/migrations has no pgTAP test.
# A test block declares what it covers with a line:  -- covers: <policy_name>
set -euo pipefail
cd "$(dirname "$0")/.."

policies=$(grep -hoiE 'create policy +[a-z0-9_]+' supabase/migrations/*.sql | awk '{print $3}' | sort -u)
covered=$(grep -hoE -- '-- covers: +[a-z0-9_]+' supabase/tests/*.sql | awk '{print $3}' | sort -u)

missing=$(comm -23 <(echo "$policies") <(echo "$covered"))
total=$(echo "$policies" | grep -c . || true)

if [[ -n "$missing" ]]; then
  echo "Policies without a pgTAP test (add a '-- covers: <name>' block):"
  echo "$missing" | sed 's/^/  - /'
  exit 1
fi
echo "Policy coverage: $total of $total policies have a pgTAP test."
