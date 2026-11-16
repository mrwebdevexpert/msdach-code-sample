-- One allowed and one denied case for every RLS policy.
-- Each block is tagged "-- covers: <policy>"; scripts/check_policy_coverage.sh
-- fails the CI if a policy in supabase/migrations has no tag here.
begin;
select plan(45);

-- Fixtures (table owner, RLS bypassed)
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
  ('00000000-0000-0000-0000-0000000000a2', 'teamlead@test.local'),
  ('00000000-0000-0000-0000-0000000000a3', 'backoffice@test.local'),
  ('00000000-0000-0000-0000-0000000000a4', 'vertrieb@test.local'),
  ('00000000-0000-0000-0000-0000000000a5', 'monteur@test.local'),
  ('00000000-0000-0000-0000-0000000000a6', 'dispo@test.local'),
  ('00000000-0000-0000-0000-0000000000a7', 'neu@test.local');   -- no role yet
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin'),
  ('00000000-0000-0000-0000-0000000000a2', 'teamlead'),
  ('00000000-0000-0000-0000-0000000000a3', 'backoffice'),
  ('00000000-0000-0000-0000-0000000000a4', 'vertrieb'),
  ('00000000-0000-0000-0000-0000000000a5', 'monteur'),
  ('00000000-0000-0000-0000-0000000000a6', 'dispo');
insert into public.customers (id, kind, name) values
  ('00000000-0000-0000-0000-00000000c001', 'privat', 'Erika Muster');
insert into public.objects (id, customer_id, street, postal_code, city) values
  ('00000000-0000-0000-0000-00000000e001', '00000000-0000-0000-0000-00000000c001',
   'Hauptstr. 1', '20095', 'Hamburg');
insert into public.invoice_recipients (id, customer_id, name, street, postal_code, city) values
  ('00000000-0000-0000-0000-00000000d001', '00000000-0000-0000-0000-00000000c001',
   'Erika Muster', 'Hauptstr. 1', '20095', 'Hamburg');
insert into public.inquiries (id, source, external_id, match_status) values
  ('00000000-0000-0000-0000-00000000f001', 'form', 'web-1', 'new');
insert into public.reserved_customer_numbers (from_no, to_no, reason) values (20000, 20099, 'fixture');

create function pg_temp.act_as(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;

-- Users
-- a1 admin · a2 teamlead · a3 backoffice · a4 vertrieb · a5 monteur · a6 dispo · a7 new user (role tests)

-- covers: user_roles_select
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a5');
select is((select count(*)::int from public.user_roles), 1, 'user_roles_select: monteur sees only own role');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a1');
select is((select count(*)::int from public.user_roles), 6, 'user_roles_select: admin sees all roles');
reset role;

-- covers: user_roles_admin_insert
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(
  $$ insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000a2', 'admin') $$,
  '42501', null, 'user_roles_admin_insert: teamlead cannot grant itself admin');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok(
  $$ insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000a7', 'monteur') $$,
  'user_roles_admin_insert: admin grants a role');
reset role;

-- covers: user_roles_admin_update
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3');
select is_empty(
  $$ update public.user_roles set role = 'admin'
       where user_id = '00000000-0000-0000-0000-0000000000a3' returning 1 $$,
  'user_roles_admin_update: backoffice cannot change its role');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a1');
select isnt_empty(
  $$ update public.user_roles set role = 'dispo'
       where user_id = '00000000-0000-0000-0000-0000000000a7' and role = 'monteur' returning 1 $$,
  'user_roles_admin_update: admin changes a role');
reset role;

-- covers: app_settings_select
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a4');
select is((select count(*)::int from public.app_settings), 0, 'app_settings_select: vertrieb sees no settings');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3');
select is((select count(*)::int from public.app_settings), 1, 'app_settings_select: backoffice reads settings');
reset role;

-- covers: app_settings_admin_update
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a2');
select is_empty(
  $$ update public.app_settings set value = 'false'::jsonb where key = 'lunds_active' returning 1 $$,
  'app_settings_admin_update: teamlead cannot switch LUNDS off');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a1');
select isnt_empty(
  $$ update public.app_settings set value = value where key = 'lunds_active' returning 1 $$,
  'app_settings_admin_update: admin changes a setting');
reset role;

-- covers: reserved_numbers_select
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3');
select is((select count(*)::int from public.reserved_customer_numbers), 0,
  'reserved_numbers_select: backoffice sees no reserved ranges');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a2');
select is((select count(*)::int from public.reserved_customer_numbers), 1,
  'reserved_numbers_select: teamlead sees reserved ranges');
reset role;

-- covers: reserved_numbers_admin_insert
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a2');
select throws_ok(
  $$ insert into public.reserved_customer_numbers (from_no, to_no) values (30000, 30001) $$,
  '42501', null, 'reserved_numbers_admin_insert: teamlead cannot reserve a range');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a1');
select lives_ok(
  $$ insert into public.reserved_customer_numbers (from_no, to_no) values (30000, 30001) $$,
  'reserved_numbers_admin_insert: admin reserves a range');
reset role;

-- covers: reserved_numbers_admin_update
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a2');
select is_empty(
  $$ update public.reserved_customer_numbers set reason = 'x' where from_no = 20000 returning 1 $$,
  'reserved_numbers_admin_update: teamlead cannot change a range');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a1');
select isnt_empty(
  $$ update public.reserved_customer_numbers set reason = 'changed' where from_no = 20000 returning 1 $$,
  'reserved_numbers_admin_update: admin changes a range');
reset role;

-- covers: customers_select
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a5');
select is((select count(*)::int from public.customers), 0, 'customers_select: monteur sees no customers');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a6');
select is((select count(*)::int from public.customers), 1, 'customers_select: dispo reads customers');
reset role;

-- covers: customers_insert
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a6');
select throws_ok(
  $$ insert into public.customers (kind, name) values ('firma', 'Dispo GmbH') $$,
  '42501', null, 'customers_insert: dispo cannot create a customer');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a4');
select lives_ok(
  $$ insert into public.customers (kind, name) values ('firma', 'Vertrieb GmbH') $$,
  'customers_insert: vertrieb creates a customer');
reset role;

-- covers: customers_update
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a6');
select is_empty(
  $$ update public.customers set name = 'X' where id = '00000000-0000-0000-0000-00000000c001' returning 1 $$,
  'customers_update: dispo cannot change a customer');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a2');
select isnt_empty(
  $$ update public.customers set name = 'Erika Muster' where id = '00000000-0000-0000-0000-00000000c001' returning 1 $$,
  'customers_update: teamlead changes a customer');
reset role;

-- covers: objects_select
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a5');
select is((select count(*)::int from public.objects), 0, 'objects_select: monteur sees no properties');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a6');
select is((select count(*)::int from public.objects), 1, 'objects_select: dispo reads properties');
reset role;

-- covers: objects_insert
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a6');
select throws_ok(
  $$ insert into public.objects (customer_id, street, postal_code, city)
     values ('00000000-0000-0000-0000-00000000c001', 'Weg 2', '20095', 'Hamburg') $$,
  '42501', null, 'objects_insert: dispo cannot create a property');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a4');
select lives_ok(
  $$ insert into public.objects (customer_id, street, postal_code, city)
     values ('00000000-0000-0000-0000-00000000c001', 'Weg 2', '20095', 'Hamburg') $$,
  'objects_insert: vertrieb creates a property');
reset role;

-- covers: objects_update
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a4');
select is_empty(
  $$ update public.objects set city = 'Kiel' where id = '00000000-0000-0000-0000-00000000e001' returning 1 $$,
  'objects_update: vertrieb cannot change a property');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3');
select isnt_empty(
  $$ update public.objects set city = 'Hamburg' where id = '00000000-0000-0000-0000-00000000e001' returning 1 $$,
  'objects_update: backoffice changes a property');
reset role;

-- covers: invoice_recipients_select
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a5');
select is((select count(*)::int from public.invoice_recipients), 0,
  'invoice_recipients_select: monteur sees no invoice recipients');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a6');
select is((select count(*)::int from public.invoice_recipients), 1,
  'invoice_recipients_select: dispo reads invoice recipients');
reset role;

-- covers: invoice_recipients_insert
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a4');
select throws_ok(
  $$ insert into public.invoice_recipients (customer_id, name)
     values ('00000000-0000-0000-0000-00000000c001', 'HV Nord') $$,
  '42501', null, 'invoice_recipients_insert: vertrieb cannot create an invoice recipient');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3');
select lives_ok(
  $$ insert into public.invoice_recipients (customer_id, name)
     values ('00000000-0000-0000-0000-00000000c001', 'HV Nord') $$,
  'invoice_recipients_insert: backoffice creates an invoice recipient');
reset role;

-- covers: invoice_recipients_update
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a4');
select is_empty(
  $$ update public.invoice_recipients set email = 'x@y.de'
       where id = '00000000-0000-0000-0000-00000000d001' returning 1 $$,
  'invoice_recipients_update: vertrieb cannot change an invoice recipient');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3');
select isnt_empty(
  $$ update public.invoice_recipients set email = 'rechnung@example.de'
       where id = '00000000-0000-0000-0000-00000000d001' returning 1 $$,
  'invoice_recipients_update: backoffice changes an invoice recipient');
reset role;

-- covers: inquiries_select
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a6');
select is((select count(*)::int from public.inquiries), 0, 'inquiries_select: dispo sees no inquiries');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a4');
select is((select count(*)::int from public.inquiries), 1, 'inquiries_select: vertrieb reads inquiries');
reset role;

-- covers: inquiries_update
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a4');
select is_empty(
  $$ update public.inquiries set match_status = 'matched',
       customer_id = '00000000-0000-0000-0000-00000000c001'
       where id = '00000000-0000-0000-0000-00000000f001' returning 1 $$,
  'inquiries_update: vertrieb cannot resolve a match');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3');
select isnt_empty(
  $$ update public.inquiries set match_status = 'matched',
       customer_id = '00000000-0000-0000-0000-00000000c001'
       where id = '00000000-0000-0000-0000-00000000f001' returning 1 $$,
  'inquiries_update: backoffice resolves a match');
reset role;

-- covers: audit_log_select
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3');
select is((select count(*)::int from public.audit_log), 0, 'audit_log_select: backoffice cannot read the audit log');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a2');
select ok((select count(*) from public.audit_log) > 0, 'audit_log_select: teamlead reads the audit log');
reset role;

-- Column privileges behind the policies: fields that only a function may write
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  $$ update public.customers set customer_number = 99999 where id = '00000000-0000-0000-0000-00000000c001' $$,
  '42501', null, 'even admin cannot write customer_number directly');
select throws_ok(
  $$ update public.invoice_recipients set address_confirmed_at = now()
       where id = '00000000-0000-0000-0000-00000000d001' $$,
  '42501', null, 'even admin cannot confirm an address without confirm_invoice_address()');
select throws_ok(
  $$ insert into public.inquiries (source, external_id, match_status) values ('form', 'x', 'new') $$,
  '42501', null, 'only the intake function (service role) writes inquiries');
select throws_ok(
  $$ insert into public.audit_log (table_name, row_id, action) values ('x', gen_random_uuid(), 'INSERT') $$,
  '42501', null, 'nobody writes the audit log by hand');
reset role;

-- anon sees nothing
set local role anon;
select throws_ok($$ select 1 from public.customers $$, '42501', null, 'anon has no access to customers');
reset role;

select * from finish();
rollback;
