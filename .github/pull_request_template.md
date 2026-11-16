## What and why
<!-- One purpose per PR. -->

## Briefing and map
- Briefing IDs implemented: <!-- e.g. M0a-020, M0a-092 -->
- Modules touched: <!-- e.g. M0a, M2 -->
- Flows (F…) and events (E…) touched: <!-- e.g. F12, E04 -->
- Status of the lines: Decided only? <!-- yes / list any Proposal and the approval -->

## Database changes
- [ ] New migration file(s) only (no applied migration edited)
- [ ] RLS enabled on every new table, policies listed below
- [ ] Every new policy has a pgTAP test tagged `-- covers: <policy>`
- [ ] Column grants for function-only fields
- Policies added / changed:

## Tests
<!-- Paste the output. "Done" only with the output. -->
```
deno task check && deno task test
supabase test db
```

## Risks, deviations, open questions
<!-- Contradictions in the briefing: name the IDs. -->
