# CLAUDE.md – rules for this repository (binding)

This repo is the Supabase backend for the MS Dach office app. These rules apply to
every change, by a human or by Claude. If a rule here conflicts with a request,
stop and ask in the PR; do not choose silently.

## Before building
- Every module starts with a plan in `docs/specs/<module>.md`: tables, events (E…),
  flows (F…), check step, effort. Building starts only after the plan is approved.
- The briefing is binding. Build only lines with status **Decided**. Proposal / Idea:
  ask back first. Existing: continue, never rebuild. Reference: built elsewhere.

## Database
- **RLS on every table.** No table without at least one policy. Never a policy for
  `anon` or `public` unless the spec says so.
- **One pgTAP test for every policy** (allowed and denied case), tagged
  `-- covers: <policy_name>`. `scripts/check_policy_coverage.sh` enforces this in CI.
- **Archive instead of delete.** No DELETE grants; delete triggers raise.
- Fields that only a function may change (numbers, confirmations, audit) get
  column-level grants, never a plain table grant.
- `SECURITY DEFINER` functions pin `set search_path = ''` and are revoked from
  `public` and `anon`. Policies call `(select auth.uid())`.
- **Migrations are append-only.** Never edit a migration that exists on `main`; write a
  new one. `scripts/check_migrations_immutable.sh` and a hook enforce this.
- Payroll lives in its own schema with its own roles. Sending only through the
  Outbox. Prompts only from the prompt table.

## Edge Functions
- Logic in `handler.ts` (pure, injectable dependencies), wiring in `index.ts`.
- Validate every input; stable error codes; idempotent on the sender's ID.
- Never log secrets or personal data. Keys come from env, never from code.

## Tests and done
- Run `deno task check`, `deno task test` and `supabase test db` before you say done.
  "Done" only with the test output pasted in the PR.
- The acceptance cases of the briefing are automated tests.

## Pull requests
- One branch per task (`feat/`, `fix/`, `refactor/`, `docs/` + module + short name),
  never on `main`. No deploy from a laptop: migrations and functions only via CI.
- Fill in `.github/pull_request_template.md`: briefing IDs, modules, flows (F…) and
  events (E…), DB changes, tests with result, risks.
- Before a PR is opened, the `rls-reviewer` agent reviews every migration change;
  its **high** findings are fixed first.

## Language
- Visible program texts are German. Code, comments, commits and PRs are English.
- No real customer data in code, tests, fixtures or PR text.
