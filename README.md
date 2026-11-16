# Code sample: customer core, RLS and inquiry intake

A small, self-contained sample of how we build on Supabase. It is **original
code written for this application**, modelled on the MS Dach M0a briefing. It
is not taken from a client project and contains no client data.

## What is in it

| Path | What it shows |
|---|---|
| `supabase/migrations/20261112000000_m0a_customer_core_sample.sql` | One migration: roles, customer / object / invoice recipient / inquiry tables, audit trail, customer-number allocation, RLS, privileges |
| `supabase/functions/inquiry-intake/` | One Edge Function: receives an inquiry, validates it, matches it against existing customers, stores it idempotently |
| `supabase/functions/_shared/matching.ts` | Pure matching rules (no I/O), shared and unit-tested |
| `supabase/tests/00_rls_guard.test.sql` | pgTAP guard (5): every table has RLS and a policy, no policy for anon, no DELETE grant, SECURITY DEFINER pins search_path |
| `supabase/tests/01_m0a_customer_core.test.sql` | pgTAP (23): behaviour – privileges, triggers, numbers, audit, invoice-address status |
| `supabase/tests/02_policies.test.sql` | pgTAP (45): every one of the 20 policies with an allowed and a denied case, plus column privileges |
| `supabase/functions/**/*_test.ts` | Deno tests (18): matching rules and the HTTP handler against a fake store |
| `.github/workflows/ci.yml` | CI on every PR: guards, Deno fmt/lint/check/test, Supabase stack + `db lint` + `supabase test db` |
| `.github/workflows/claude-review.yml` | Claude review on every PR; an open "high" finding fails the check |
| `CLAUDE.md`, `.claude/` | Rules file, hooks, review subagent and permissions Claude Code works under |
| `.mcp.json` | Supabase MCP server, read-only, on the staging project |
| `scripts/` | Policy-coverage check, migration-immutability check, local pgTAP run without Docker |
| `docs/specs/` | The plan format each module starts with |

## Rules from the briefing and where they are enforced

| Rule | Where |
|---|---|
| Archive instead of delete, every change logged (M0a-020) | No DELETE privilege, `forbid_delete` trigger, `audit_log` written by triggers and append-only |
| Six roles, users and roles once (M0a-007, M0a-008) | `app_role` enum, `user_roles`, `has_any_role()` used by every policy |
| Customer numbers from 12,883 after LUNDS ends, reserved ranges skipped | `assign_customer_number()`; refuses while `lunds_active` is true; `customer_number` has no insert/update privilege |
| Invoice address is never guessed (M0a-092) | `confirm_invoice_address()`; editing the address withdraws the confirmation; `invoice_recipients_with_status` gives `missing` / `unconfirmed` / `confirmed` |
| Inquiry = internal ID + matching until LUNDS ends (M0a-019) | `inquiries.match_status`; no customer number is created by intake |
| Every table reachable with the same rights as in the app (M0a-017) | Plain RLS, no separate API permission layer |

## Design decisions worth reading

- **Column-level grants** carry the fields that may only change through a
  function (customer number, invoice-address confirmation, audit log).
  Nobody can bypass them by writing to the table.
- **`SECURITY DEFINER` helpers** pin `search_path = ''` and are revoked from
  `public` / `anon`. Policies use `(select auth.uid())` so it is evaluated once
  per statement.
- **Matching is conservative.** An address alone never auto-matches, because
  property managements and owners' associations share addresses. Strong
  signals (e-mail, phone) match only when exactly one customer is behind them.
  Everything else goes to the office as `ambiguous`.
- **The Edge Function is split into `handler.ts` (pure, injectable store) and
  `index.ts` (wiring).** All request logic is tested without a network or a
  database.
- **Idempotent intake.** The sender may retry; `(source, external_id)` is
  unique and a retry returns the first result (a race is resolved on the unique
  violation).
- **Normalisation lives in two places** (generated columns in SQL, functions in
  TypeScript). The comment in both files says so, and the matching test pins the
  expected values.

## How we build with Claude here

- **Rules file:** `CLAUDE.md` is binding for humans and Claude (RLS, a pgTAP test per
  policy, append-only migrations, plan before building, German UI texts).
- **Hooks** (`.claude/settings.json`):
  - `PreToolUse` → `.claude/hooks/protect-migrations.sh` blocks edits to committed
    migrations and to `.env` files;
  - `PostToolUse` → `.claude/hooks/post-edit-check.sh` runs fmt/lint/type check/Deno
    tests after a TypeScript edit, and policy coverage + pgTAP after an SQL edit, and
    hands failures back to Claude.
- **Permissions:** deploys (`supabase db push`, `functions deploy`) and force-push are
  denied; changes reach production only through CI.
- **MCP:** Supabase MCP server in `--read-only` mode against staging, for schema
  questions and advisors.
- **Subagent:** `.claude/agents/rls-reviewer.md` reviews every migration.
- **Claude in CI:** `.github/workflows/claude-review.yml`.
- **Guards in CI:** `scripts/check_policy_coverage.sh` fails if a policy has no test
  tagged `-- covers: <policy>`; `scripts/check_migrations_immutable.sh` fails if an
  applied migration is changed.

## Running it

```bash
supabase start               # applies the migrations
supabase test db             # pgTAP: 73 tests
deno task check              # fmt, lint, type check
deno task test               # Deno: 18 tests
./scripts/check_policy_coverage.sh
./scripts/test-db-local.sh   # pgTAP on a plain Postgres 16, no Docker
# local function run:
INTAKE_API_KEY=local-key SB_SECRET_KEY=<local secret key> supabase functions serve inquiry-intake --no-verify-jwt
```

## Known limits of this sample

- Customer lookups in the Edge Function do not filter archived customers: a
  returning archived customer should still match.
- `automation_enabled` is writable by every role that can update a customer.
  Restricting it to team leads would be a guard trigger or a function.
- GDPR erasure (M0a-021) is not included; it needs its own audited procedure.
- Normalisation uses Postgres `lower()`; it matches JavaScript for the common
  German characters on a UTF-8 database, which should be re-checked on the
  production collation.
