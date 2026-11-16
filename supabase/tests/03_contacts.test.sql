-- pgTAP for 20261116120000_m0a_contacts.sql: every policy allowed + denied,
-- archive instead of delete, audit trail.
begin;
select plan(9);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a3', 'backoffice@test.local'),
  ('00000000-0000-0000-0000-0000000000a4', 'vertrieb@test.local'),
  ('00000000-0000-0000-0000-0000000000a5', 'monteur@test.local'),
  ('00000000-0000-0000-0000-0000000000a6', 'dispo@test.local');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000000a3', 'backoffice'),
  ('00000000-0000-0000-0000-0000000000a4', 'vertrieb'),
  ('00000000-0000-0000-0000-0000000000a5', 'monteur'),
  ('00000000-0000-0000-0000-0000000000a6', 'dispo');
insert into public.customers (id, kind, name) values
  ('00000000-0000-0000-0000-00000000c001', 'hvw', 'HV Nord GmbH');
insert into public.contacts (id, customer_id, name, role_label) values
  ('00000000-0000-0000-0000-00000000b001', '00000000-0000-0000-0000-00000000c001',
   'Frau Beispiel', 'Hausverwaltung');

create function pg_temp.act_as(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;

-- covers: contacts_select
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a5');
select is((select count(*)::int from public.contacts), 0, 'contacts_select: monteur sees no contacts');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a6');
select is((select count(*)::int from public.contacts), 1, 'contacts_select: dispo reads contacts');
reset role;

-- covers: contacts_insert
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a6');
select throws_ok(
  $$ insert into public.contacts (customer_id, name) values ('00000000-0000-0000-0000-00000000c001', 'X') $$,
  '42501', null, 'contacts_insert: dispo cannot create a contact');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a4');
select lives_ok(
  $$ insert into public.contacts (customer_id, name) values ('00000000-0000-0000-0000-00000000c001', 'Herr Mieter') $$,
  'contacts_insert: vertrieb creates a contact');
reset role;

-- covers: contacts_update
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a4');
select is_empty(
  $$ update public.contacts set phone = '0401234' where id = '00000000-0000-0000-0000-00000000b001' returning 1 $$,
  'contacts_update: vertrieb cannot change a contact');
reset role;
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3');
select isnt_empty(
  $$ update public.contacts set phone = '0401234' where id = '00000000-0000-0000-0000-00000000b001' returning 1 $$,
  'contacts_update: backoffice changes a contact');
select throws_ok(
  $$ delete from public.contacts where id = '00000000-0000-0000-0000-00000000b001' $$,
  '42501', null, 'no DELETE privilege on contacts');
reset role;

select throws_ok(
  $$ delete from public.contacts where id = '00000000-0000-0000-0000-00000000b001' $$,
  null, 'archive_only: set archived_at instead of deleting contacts',
  'even the owner cannot hard-delete a contact');
select is(
  (select count(*)::int from public.audit_log where table_name = 'contacts' and action = 'UPDATE'),
  1, 'the change of the contact is in the audit log');

select * from finish();
rollback;
