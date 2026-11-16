#!/usr/bin/env bash
# Runs the pgTAP suite on a throw-away plain Postgres 16 (no Docker needed).
# CI runs the same tests on the real Supabase stack (supabase start + supabase test db).
set -euo pipefail
cd "$(dirname "$0")/.."
PGBIN="${PGBIN:-$(pg_config --bindir 2>/dev/null || echo /opt/homebrew/opt/postgresql@16/bin)}"
DIR=$(mktemp -d); PORT=${PORT:-54329}
trap '"$PGBIN/pg_ctl" -D "$DIR" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$DIR"' EXIT
"$PGBIN/initdb" -D "$DIR" -U postgres -A trust >/dev/null
"$PGBIN/pg_ctl" -D "$DIR" -o "-p $PORT -k $DIR" -l "$DIR/log" start -w >/dev/null
PSQL=("$PGBIN/psql" -h "$DIR" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q -X)
"${PSQL[@]}" -f scripts/local/auth_stub.sql >/dev/null
for m in supabase/migrations/*.sql; do "${PSQL[@]}" -f "$m" >/dev/null; done
fail=0; total=0
for t in supabase/tests/*.test.sql; do
  out=$("${PSQL[@]}" -t -A -f "$t" 2>&1) || { echo "$out"; fail=1; }
  n_ok=$(grep -c '^ok ' <<<"$out" || true); n_bad=$(grep -c '^not ok' <<<"$out" || true)
  plan=$(grep -oE '^1\.\.[0-9]+' <<<"$out" | cut -d. -f3)
  total=$((total + n_ok))
  printf '%-40s %s/%s passed\n' "$(basename "$t")" "$n_ok" "${plan:-?}"
  if [[ "$n_bad" != 0 || "$n_ok" != "${plan:-x}" ]]; then grep -E '^not ok|^#' <<<"$out"; fail=1; fi
done
echo "pgTAP total: $total passed"; exit $fail
