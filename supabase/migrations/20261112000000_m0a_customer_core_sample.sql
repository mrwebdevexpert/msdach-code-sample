-- =============================================================================
-- Sample migration: customer core (modelled on M0a: customer, object,
-- invoice recipient, inquiry) with roles, RLS, audit trail and customer numbers.
--
-- Design rules applied (M0a briefing):
--   * archive instead of delete, every change logged            (M0a-020)
--   * users and roles exist once, six roles                      (M0a-007, -008)
--   * customer numbers after LUNDS end start at 12,883 and skip
--     reserved ranges; before that only an internal ID exists    (Map section 2)
--   * invoice address is never guessed: it is confirmed explicitly,
--     missing or unconfirmed -> warning status                   (M0a-092)
--   * inquiries carry an internal ID + matching result only      (M0a-019)
--
-- Security model: RLS on every table, column-level grants for fields that must
-- only change through a controlled function, SECURITY DEFINER helpers with a
-- pinned search_path, no DELETE privilege anywhere.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Types
-- -----------------------------------------------------------------------------
create type public.app_role as enum
  ('admin', 'teamlead', 'backoffice', 'dispo', 'monteur', 'vertrieb');

create type public.customer_kind as enum
  ('privat', 'hvw', 'firma', 'staatlich', 'partner');

create type public.customer_category as enum ('A+', 'A', 'B', 'C');

-- -----------------------------------------------------------------------------
-- 2. Roles and settings
-- -----------------------------------------------------------------------------
create table public.user_roles (
  user_id uuid not null references auth.users (id) on delete cascade,
  role    public.app_role not null,
  primary key (user_id, role)
);

create table public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

-- LUNDS is still the leading system for customer numbers until switched off.
insert into public.app_settings (key, value) values ('lunds_active', 'true'::jsonb);

create table public.reserved_customer_numbers (
  from_no integer not null,
  to_no   integer not null,
  reason  text,
  check (from_no <= to_no)
);

-- Role helpers. SECURITY DEFINER + empty search_path: policies can call them
-- without recursing into the RLS of user_roles.
create function public.has_any_role(p_roles public.app_role[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_roles ur
    where ur.user_id = (select auth.uid())
      and ur.role = any (p_roles)
  );
$$;

revoke all on function public.has_any_role(public.app_role[]) from public, anon;
grant execute on function public.has_any_role(public.app_role[]) to authenticated;

-- -----------------------------------------------------------------------------
-- 3. Core tables
-- -----------------------------------------------------------------------------
create table public.customers (
  id                uuid primary key default gen_random_uuid(),
  -- Assigned only by assign_customer_number(); never written by the client.
  customer_number   integer unique check (customer_number between 1 and 999989),
  kind              public.customer_kind not null,
  category          public.customer_category,
  -- "N" is only a marker "neu"; the category itself is the pre-sorted one.
  category_is_new   boolean not null default true,
  name              text not null check (length(btrim(name)) > 0),
  email             text,
  phone             text,
  -- Normalised copies for matching. Must stay in sync with
  -- supabase/functions/_shared/matching.ts.
  email_normalized  text generated always as (nullif(lower(btrim(email)), '')) stored,
  phone_normalized  text generated always as
                      (nullif(regexp_replace(coalesce(phone, ''), '[^0-9+]', '', 'g'), '')) stored,
  automation_enabled boolean not null default false,
  archived_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index customers_email_normalized_idx on public.customers (email_normalized)
  where email_normalized is not null;
create index customers_phone_normalized_idx on public.customers (phone_normalized)
  where phone_normalized is not null;

create sequence public.customer_number_seq start with 12883 minvalue 12883;

create table public.objects (
  id              uuid primary key default gen_random_uuid(),
  customer_id     uuid not null references public.customers (id),
  lunds_object_id integer unique,           -- import only, never written by the app
  street          text not null,
  postal_code     text not null,
  city            text not null,
  address_key     text generated always as
                    (lower(regexp_replace(coalesce(street, '') || '|' || coalesce(postal_code, ''),
                                          '\s+', '', 'g'))) stored,
  archived_at     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index objects_customer_id_idx on public.objects (customer_id);
create index objects_address_key_idx on public.objects (address_key);

create table public.invoice_recipients (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null references public.customers (id),
  name                  text not null check (length(btrim(name)) > 0),
  street                text,
  postal_code           text,
  city                  text,
  email                 text,
  leitweg_id            text,
  purchase_order_number text,
  default_tax_mode      text not null default 'standard'
                          check (default_tax_mode in ('standard', 'reverse_charge_13b')),
  address_confirmed_at  timestamptz,
  address_confirmed_by  uuid references auth.users (id),
  archived_at           timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create index invoice_recipients_customer_id_idx on public.invoice_recipients (customer_id);

-- Warning status for the UI: missing/unconfirmed invoice address = red warning.
create view public.invoice_recipients_with_status
with (security_invoker = true)
as
select
  ir.*,
  case
    when nullif(btrim(ir.street), '') is null
      or nullif(btrim(ir.postal_code), '') is null
      or nullif(btrim(ir.city), '') is null then 'missing'
    when ir.address_confirmed_at is null then 'unconfirmed'
    else 'confirmed'
  end as address_status
from public.invoice_recipients ir;

create table public.inquiries (
  id               uuid primary key default gen_random_uuid(),
  source           text not null check (source in ('email', 'phone', 'form', 'kipanel')),
  external_id      text not null,            -- id in the sender's system (idempotency)
  click_url        text,
  contact_name     text,
  contact_email    text,
  contact_phone    text,
  street           text,
  postal_code      text,
  raw              jsonb not null default '{}'::jsonb,
  match_status     text not null check (match_status in ('matched', 'ambiguous', 'new')),
  customer_id      uuid references public.customers (id),
  match_candidates uuid[] not null default '{}',
  created_at       timestamptz not null default now(),
  unique (source, external_id)
);

create index inquiries_customer_id_idx on public.inquiries (customer_id);

-- -----------------------------------------------------------------------------
-- 4. Audit trail (append-only) and generic triggers
-- -----------------------------------------------------------------------------
create table public.audit_log (
  id         bigint generated always as identity primary key,
  table_name text not null,
  row_id     uuid not null,
  action     text not null check (action in ('INSERT', 'UPDATE')),
  actor      uuid,                           -- null = service role / migration
  old_data   jsonb,
  new_data   jsonb,
  created_at timestamptz not null default now()
);

create index audit_log_row_idx on public.audit_log (table_name, row_id, created_at desc);

create function public.log_row_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.audit_log (table_name, row_id, action, actor, new_data)
    values (tg_table_name, new.id, tg_op, (select auth.uid()), to_jsonb(new));
  else
    insert into public.audit_log (table_name, row_id, action, actor, old_data, new_data)
    values (tg_table_name, new.id, tg_op, (select auth.uid()), to_jsonb(old), to_jsonb(new));
  end if;
  return null;
end;
$$;

create function public.audit_log_is_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'audit_log_is_append_only';
end;
$$;

create trigger audit_log_no_change
  before update or delete on public.audit_log
  for each row execute function public.audit_log_is_append_only();

create function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create function public.forbid_delete()
returns trigger
language plpgsql
as $$
begin
  -- Archive instead of delete (M0a-020). A GDPR erasure runs as a separate,
  -- audited admin procedure and is not part of this sample.
  raise exception 'archive_only: set archived_at instead of deleting %', tg_table_name;
end;
$$;

-- An edited invoice address is no longer confirmed: it must be asked again.
create function public.reset_invoice_address_confirmation()
returns trigger
language plpgsql
as $$
begin
  if (new.name, new.street, new.postal_code, new.city)
     is distinct from (old.name, old.street, old.postal_code, old.city) then
    new.address_confirmed_at := null;
    new.address_confirmed_by := null;
  end if;
  return new;
end;
$$;

create trigger customers_touch before update on public.customers
  for each row execute function public.touch_updated_at();
create trigger objects_touch before update on public.objects
  for each row execute function public.touch_updated_at();
create trigger invoice_recipients_touch before update on public.invoice_recipients
  for each row execute function public.touch_updated_at();

create trigger invoice_recipients_reset_confirmation before update on public.invoice_recipients
  for each row execute function public.reset_invoice_address_confirmation();

create trigger customers_no_delete before delete on public.customers
  for each row execute function public.forbid_delete();
create trigger objects_no_delete before delete on public.objects
  for each row execute function public.forbid_delete();
create trigger invoice_recipients_no_delete before delete on public.invoice_recipients
  for each row execute function public.forbid_delete();

create trigger customers_audit_insert after insert on public.customers
  for each row execute function public.log_row_change();
create trigger customers_audit_update after update on public.customers
  for each row when (old.* is distinct from new.*)
  execute function public.log_row_change();
create trigger objects_audit_insert after insert on public.objects
  for each row execute function public.log_row_change();
create trigger objects_audit_update after update on public.objects
  for each row when (old.* is distinct from new.*)
  execute function public.log_row_change();
create trigger invoice_recipients_audit_insert after insert on public.invoice_recipients
  for each row execute function public.log_row_change();
create trigger invoice_recipients_audit_update after update on public.invoice_recipients
  for each row when (old.* is distinct from new.*)
  execute function public.log_row_change();

-- -----------------------------------------------------------------------------
-- 5. Controlled write paths (SECURITY DEFINER functions)
-- -----------------------------------------------------------------------------

-- Customer numbers: only after LUNDS is switched off, consecutive from 12,883,
-- skipping reserved ranges, only by admin/teamlead.
create function public.assign_customer_number(p_customer_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lunds_active boolean;
  v_existing     integer;
  v_no           integer;
begin
  if not public.has_any_role(array['admin', 'teamlead']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select (value)::boolean into v_lunds_active
  from public.app_settings where key = 'lunds_active';
  if coalesce(v_lunds_active, true) then
    raise exception 'lunds_still_active';
  end if;

  select customer_number into v_existing
  from public.customers where id = p_customer_id for update;
  if not found then
    raise exception 'customer_not_found';
  end if;
  if v_existing is not null then
    raise exception 'already_numbered';
  end if;

  loop
    v_no := nextval('public.customer_number_seq');
    exit when not exists (
      select 1 from public.reserved_customer_numbers r
      where v_no between r.from_no and r.to_no
    );
  end loop;

  if v_no > 999989 then
    raise exception 'number_range_exhausted';
  end if;

  update public.customers set customer_number = v_no where id = p_customer_id;
  return v_no;
end;
$$;

-- Explicit confirmation of the invoice address (never guessed, never defaulted).
create function public.confirm_invoice_address(p_recipient_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.invoice_recipients;
begin
  if not public.has_any_role(array['admin', 'teamlead', 'backoffice']::public.app_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select * into v_row from public.invoice_recipients where id = p_recipient_id for update;
  if not found then
    raise exception 'recipient_not_found';
  end if;
  if nullif(btrim(v_row.street), '') is null
     or nullif(btrim(v_row.postal_code), '') is null
     or nullif(btrim(v_row.city), '') is null then
    raise exception 'address_incomplete';
  end if;

  update public.invoice_recipients
  set address_confirmed_at = now(),
      address_confirmed_by = (select auth.uid())
  where id = p_recipient_id;
end;
$$;

revoke all on function public.assign_customer_number(uuid) from public, anon;
revoke all on function public.confirm_invoice_address(uuid) from public, anon;
grant execute on function public.assign_customer_number(uuid) to authenticated;
grant execute on function public.confirm_invoice_address(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 6. Privileges: default-deny, then grant the minimum (column-level where a
--    field may only change through a function above).
-- -----------------------------------------------------------------------------
revoke all on table
  public.user_roles, public.app_settings, public.reserved_customer_numbers,
  public.customers, public.objects, public.invoice_recipients,
  public.invoice_recipients_with_status, public.inquiries, public.audit_log
from anon, authenticated;
revoke all on sequence public.customer_number_seq from anon, authenticated;

grant select on public.user_roles, public.app_settings, public.reserved_customer_numbers,
  public.customers, public.objects, public.invoice_recipients,
  public.invoice_recipients_with_status, public.inquiries, public.audit_log
  to authenticated;

grant update (value) on public.app_settings to authenticated;
grant insert, update on public.user_roles to authenticated;
grant insert, update on public.reserved_customer_numbers to authenticated;

grant insert (kind, category, category_is_new, name, email, phone, automation_enabled)
  on public.customers to authenticated;
grant update (kind, category, category_is_new, name, email, phone, automation_enabled, archived_at)
  on public.customers to authenticated;

grant insert (customer_id, street, postal_code, city) on public.objects to authenticated;
grant update (street, postal_code, city, archived_at) on public.objects to authenticated;

grant insert (customer_id, name, street, postal_code, city, email, leitweg_id,
              purchase_order_number, default_tax_mode)
  on public.invoice_recipients to authenticated;
grant update (name, street, postal_code, city, email, leitweg_id,
              purchase_order_number, default_tax_mode, archived_at)
  on public.invoice_recipients to authenticated;

-- Inquiries are written by the intake Edge Function (service role); the office
-- may only resolve the match (assign the customer).
grant update (customer_id, match_status) on public.inquiries to authenticated;

-- -----------------------------------------------------------------------------
-- 7. Row Level Security
-- -----------------------------------------------------------------------------
alter table public.user_roles                enable row level security;
alter table public.app_settings              enable row level security;
alter table public.reserved_customer_numbers enable row level security;
alter table public.customers                 enable row level security;
alter table public.objects                   enable row level security;
alter table public.invoice_recipients        enable row level security;
alter table public.inquiries                 enable row level security;
alter table public.audit_log                 enable row level security;

-- user_roles: everyone sees their own roles; admin manages all.
create policy user_roles_select on public.user_roles for select to authenticated
  using (user_id = (select auth.uid())
         or public.has_any_role(array['admin']::public.app_role[]));
create policy user_roles_admin_insert on public.user_roles for insert to authenticated
  with check (public.has_any_role(array['admin']::public.app_role[]));
create policy user_roles_admin_update on public.user_roles for update to authenticated
  using (public.has_any_role(array['admin']::public.app_role[]))
  with check (public.has_any_role(array['admin']::public.app_role[]));

-- settings
create policy app_settings_select on public.app_settings for select to authenticated
  using (public.has_any_role(array['admin', 'teamlead', 'backoffice']::public.app_role[]));
create policy app_settings_admin_update on public.app_settings for update to authenticated
  using (public.has_any_role(array['admin']::public.app_role[]))
  with check (public.has_any_role(array['admin']::public.app_role[]));

create policy reserved_numbers_select on public.reserved_customer_numbers for select to authenticated
  using (public.has_any_role(array['admin', 'teamlead']::public.app_role[]));
create policy reserved_numbers_admin_insert on public.reserved_customer_numbers for insert to authenticated
  with check (public.has_any_role(array['admin']::public.app_role[]));
create policy reserved_numbers_admin_update on public.reserved_customer_numbers for update to authenticated
  using (public.has_any_role(array['admin']::public.app_role[]))
  with check (public.has_any_role(array['admin']::public.app_role[]));

-- customers / objects / invoice recipients:
--   read    admin, teamlead, backoffice, dispo, vertrieb (monteur gets tour data via M7, not here)
--   create  admin, teamlead, backoffice, vertrieb
--   change  admin, teamlead, backoffice
create policy customers_select on public.customers for select to authenticated
  using (public.has_any_role(array['admin', 'teamlead', 'backoffice', 'dispo', 'vertrieb']::public.app_role[]));
create policy customers_insert on public.customers for insert to authenticated
  with check (public.has_any_role(array['admin', 'teamlead', 'backoffice', 'vertrieb']::public.app_role[]));
create policy customers_update on public.customers for update to authenticated
  using (public.has_any_role(array['admin', 'teamlead', 'backoffice']::public.app_role[]))
  with check (public.has_any_role(array['admin', 'teamlead', 'backoffice']::public.app_role[]));

create policy objects_select on public.objects for select to authenticated
  using (public.has_any_role(array['admin', 'teamlead', 'backoffice', 'dispo', 'vertrieb']::public.app_role[]));
create policy objects_insert on public.objects for insert to authenticated
  with check (public.has_any_role(array['admin', 'teamlead', 'backoffice', 'vertrieb']::public.app_role[]));
create policy objects_update on public.objects for update to authenticated
  using (public.has_any_role(array['admin', 'teamlead', 'backoffice']::public.app_role[]))
  with check (public.has_any_role(array['admin', 'teamlead', 'backoffice']::public.app_role[]));

create policy invoice_recipients_select on public.invoice_recipients for select to authenticated
  using (public.has_any_role(array['admin', 'teamlead', 'backoffice', 'dispo', 'vertrieb']::public.app_role[]));
create policy invoice_recipients_insert on public.invoice_recipients for insert to authenticated
  with check (public.has_any_role(array['admin', 'teamlead', 'backoffice']::public.app_role[]));
create policy invoice_recipients_update on public.invoice_recipients for update to authenticated
  using (public.has_any_role(array['admin', 'teamlead', 'backoffice']::public.app_role[]))
  with check (public.has_any_role(array['admin', 'teamlead', 'backoffice']::public.app_role[]));

-- inquiries: read-only for sales/office; resolving a match = backoffice and up.
create policy inquiries_select on public.inquiries for select to authenticated
  using (public.has_any_role(array['admin', 'teamlead', 'backoffice', 'vertrieb']::public.app_role[]));
create policy inquiries_update on public.inquiries for update to authenticated
  using (public.has_any_role(array['admin', 'teamlead', 'backoffice']::public.app_role[]))
  with check (public.has_any_role(array['admin', 'teamlead', 'backoffice']::public.app_role[]));

-- audit log: readable by admin/teamlead; written only by the trigger.
create policy audit_log_select on public.audit_log for select to authenticated
  using (public.has_any_role(array['admin', 'teamlead']::public.app_role[]));
