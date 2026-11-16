-- Structural guard: runs on every PR, before the behaviour tests.
-- Fails as soon as anyone adds a table without RLS or without a policy,
-- grants DELETE, or opens a policy to anon / public.
begin;
select plan(5);

select is(
  array(
    select c.relname::text from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
    order by 1),
  '{}'::text[],
  'every table in public has row level security enabled');

select is(
  array(
    select c.relname::text from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and not exists (select 1 from pg_policies p
                      where p.schemaname = 'public' and p.tablename = c.relname)
    order by 1),
  '{}'::text[],
  'every table in public has at least one policy');

select is(
  array(
    select p.tablename || '.' || p.policyname from pg_policies p
    where p.schemaname = 'public'
      and (p.roles @> array['anon']::name[] or p.roles @> array['public']::name[])
    order by 1),
  '{}'::text[],
  'no policy is open to anon or public');

select is(
  array(
    select distinct g.table_name::text from information_schema.role_table_grants g
    where g.table_schema = 'public' and g.grantee in ('anon', 'authenticated')
      and g.privilege_type = 'DELETE'
      -- objects created by an extension (e.g. pgTAP's own views) are not ours
      and not exists (
        select 1 from pg_depend d
        where d.classid = 'pg_class'::regclass and d.deptype = 'e'
          and d.objid = format('public.%I', g.table_name)::regclass)
    order by 1),
  '{}'::text[],
  'no DELETE privilege for anon or authenticated (archive instead of delete)');

select is(
  array(
    select p.proname::text from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) cfg
                      where cfg like 'search_path=%')
    order by 1),
  '{}'::text[],
  'every SECURITY DEFINER function pins its search_path');

select * from finish();
rollback;
