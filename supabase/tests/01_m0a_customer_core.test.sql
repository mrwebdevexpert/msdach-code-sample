-- pgTAP tests for 20261112000000_m0a_customer_core_sample.sql
-- Run with: supabase test db
begin;
select plan(23);

-- ---------------------------------------------------------------------------
-- Fixtures (as the table owner, RLS bypassed)
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local'),
  ('00000000-0000-0000-0000-0000000000a2', 'teamlead@test.local'),
  ('00000000-0000-0000-0000-0000000000a3', 'backoffice@test.local'),
  ('00000000-0000-0000-0000-0000000000a4', 'vertrieb@test.local'),
  ('00000000-0000-0000-0000-0000000000a5', 'monteur@test.local');

insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin'),
  ('00000000-0000-0000-0000-0000000000a2', 'teamlead'),
  ('00000000-0000-0000-0000-0000000000a3', 'backoffice'),
  ('00000000-0000-0000-0000-0000000000a4', 'vertrieb'),
  ('00000000-0000-0000-0000-0000000000a5', 'monteur');

insert into public.customers (id, kind, name, email, phone) values
  ('00000000-0000-0000-0000-00000000c001', 'privat', 'Erika Muster',
   '  Erika@Example.DE ', '+49 (171) 123-45');

insert into public.invoice_recipients (id, customer_id, name, street, postal_code, city) values
  ('00000000-0000-0000-0000-00000000d001', '00000000-0000-0000-0000-00000000c001',
   'Erika Muster', 'Hauptstr. 1', '20095', 'Hamburg'),
  ('00000000-0000-0000-0000-00000000d002', '00000000-0000-0000-0000-00000000c001',
   'WEG Beispiel c/o HV', null, null, null);

-- Helper: switch to a logged-in user. Call `reset role` first when switching again.
create function pg_temp.act_as(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;

-- ---------------------------------------------------------------------------
-- Generated normalisation columns
-- ---------------------------------------------------------------------------
select is(
  (select email_normalized from public.customers where id = '00000000-0000-0000-0000-00000000c001'),
  'erika@example.de', 'email is trimmed and lowercased');
select is(
  (select phone_normalized from public.customers where id = '00000000-0000-0000-0000-00000000c001'),
  '+4917112345', 'phone keeps only digits and +');

-- ---------------------------------------------------------------------------
-- Invoice address status (never guessed)
-- ---------------------------------------------------------------------------
select is(
  (select address_status from public.invoice_recipients_with_status
    where id = '00000000-0000-0000-0000-00000000d001'),
  'unconfirmed', 'complete but unconfirmed address -> unconfirmed');
select is(
  (select address_status from public.invoice_recipients_with_status
    where id = '00000000-0000-0000-0000-00000000d002'),
  'missing', 'missing address -> missing');

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3'); -- backoffice
select throws_ok(
  $$ select public.confirm_invoice_address('00000000-0000-0000-0000-00000000d002') $$,
  'address_incomplete', 'cannot confirm an incomplete address');
select lives_ok(
  $$ select public.confirm_invoice_address('00000000-0000-0000-0000-00000000d001') $$,
  'backoffice confirms a complete address');
reset role;
select is(
  (select address_status from public.invoice_recipients_with_status
    where id = '00000000-0000-0000-0000-00000000d001'),
  'confirmed', 'address is now confirmed');

update public.invoice_recipients set street = 'Nebenstr. 2'
  where id = '00000000-0000-0000-0000-00000000d001';
select is(
  (select address_status from public.invoice_recipients_with_status
    where id = '00000000-0000-0000-0000-00000000d001'),
  'unconfirmed', 'editing the address withdraws the confirmation');

-- ---------------------------------------------------------------------------
-- RLS: who can see / create / change customers
-- ---------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a5'); -- monteur
select is((select count(*)::int from public.customers), 0, 'monteur sees no customers');
reset role;

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a4'); -- vertrieb
select is((select count(*)::int from public.customers), 1, 'vertrieb can read customers');
select lives_ok(
  $$ insert into public.customers (kind, name) values ('firma', 'Dach AG') $$,
  'vertrieb can create a customer');
select is_empty(
  $$ update public.customers set name = 'Hacked'
       where id = '00000000-0000-0000-0000-00000000c001' returning id $$,
  'vertrieb cannot change a customer (RLS filters the row)');
reset role;

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3'); -- backoffice
select isnt_empty(
  $$ update public.customers set name = 'Erika Muster-Neu'
       where id = '00000000-0000-0000-0000-00000000c001' returning id $$,
  'backoffice can change a customer');
select throws_ok(
  $$ insert into public.customers (kind, name, customer_number) values ('privat', 'X', 50000) $$,
  '42501', null, 'customer_number cannot be set directly (column privilege)');
select throws_ok(
  $$ delete from public.customers where id = '00000000-0000-0000-0000-00000000c001' $$,
  '42501', null, 'no DELETE privilege: archive instead of delete');
reset role;

select throws_ok(
  $$ delete from public.customers where id = '00000000-0000-0000-0000-00000000c001' $$,
  null, 'archive_only: set archived_at instead of deleting customers',
  'even the owner cannot hard-delete (trigger)');

-- ---------------------------------------------------------------------------
-- Customer numbers
-- ---------------------------------------------------------------------------
alter sequence public.customer_number_seq restart with 12883;  -- transactional, keeps the test repeatable
insert into public.reserved_customer_numbers (from_no, to_no, reason) values (12884, 12885, 'test range');

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a2'); -- teamlead
select throws_ok(
  $$ select public.assign_customer_number('00000000-0000-0000-0000-00000000c001') $$,
  'lunds_still_active', 'no number while LUNDS is the leading system');
reset role;

update public.app_settings set value = 'false'::jsonb where key = 'lunds_active';

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3'); -- backoffice
select throws_ok(
  $$ select public.assign_customer_number('00000000-0000-0000-0000-00000000c001') $$,
  '42501', 'forbidden', 'backoffice may not assign customer numbers');
reset role;

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a2'); -- teamlead
select is(
  public.assign_customer_number('00000000-0000-0000-0000-00000000c001'),
  12883, 'first number is 12,883');
select throws_ok(
  $$ select public.assign_customer_number('00000000-0000-0000-0000-00000000c001') $$,
  'already_numbered', 'a customer is numbered only once');
reset role;

insert into public.customers (id, kind, name) values
  ('00000000-0000-0000-0000-00000000c002', 'firma', 'Zweite Firma GmbH');

select pg_temp.act_as('00000000-0000-0000-0000-0000000000a2'); -- teamlead
select is(
  public.assign_customer_number('00000000-0000-0000-0000-00000000c002'),
  12886, 'reserved range 12,884-12,885 is skipped');
reset role;

-- ---------------------------------------------------------------------------
-- Audit trail
-- ---------------------------------------------------------------------------
select pg_temp.act_as('00000000-0000-0000-0000-0000000000a3'); -- backoffice
select is((select count(*)::int from public.audit_log), 0, 'backoffice cannot read the audit log');
reset role;

select throws_ok(
  $$ update public.audit_log set action = 'INSERT' $$,
  'audit_log_is_append_only', 'audit log is append-only');

select * from finish();
rollback;
