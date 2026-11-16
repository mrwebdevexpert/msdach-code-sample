-- DEMO of the guards: this migration breaks the rules on purpose.
-- A staging table for LUNDS imports without RLS, and a second table whose
-- policy has no pgTAP test. CI and the review must block this pull request.
create table public.lunds_import_staging (
  id         bigint generated always as identity primary key,
  payload    jsonb not null,
  loaded_at  timestamptz not null default now()
);

create table public.import_runs (
  id         bigint generated always as identity primary key,
  started_at timestamptz not null default now(),
  status     text not null
);
alter table public.import_runs enable row level security;
create policy import_runs_select on public.import_runs for select to authenticated using (true);
