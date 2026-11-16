-- M0a: contact persons per customer (M0a-003: tables customer, contact, ...).
-- Same rules as the customer core: RLS, column grants, archive instead of delete,
-- every change logged.

create table public.contacts (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers (id),
  name        text not null check (length(btrim(name)) > 0),
  email       text,
  phone       text,
  -- e.g. "Hausverwaltung", "Mieter vor Ort" – free text until the value list is decided
  role_label  text,
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index contacts_customer_id_idx on public.contacts (customer_id);

create trigger contacts_touch before update on public.contacts
  for each row execute function public.touch_updated_at();
create trigger contacts_no_delete before delete on public.contacts
  for each row execute function public.forbid_delete();
create trigger contacts_audit_insert after insert on public.contacts
  for each row execute function public.log_row_change();
create trigger contacts_audit_update after update on public.contacts
  for each row when (old.* is distinct from new.*)
  execute function public.log_row_change();

revoke all on table public.contacts from anon, authenticated;
grant select on public.contacts to authenticated;
grant insert (customer_id, name, email, phone, role_label) on public.contacts to authenticated;
grant update (name, email, phone, role_label, archived_at) on public.contacts to authenticated;

alter table public.contacts enable row level security;

-- Same matrix as customers: read all office roles and sales, create incl. sales,
-- change office only; the fitter sees no contacts here.
create policy contacts_select on public.contacts for select to authenticated
  using (public.has_any_role(array['admin', 'teamlead', 'backoffice', 'dispo', 'vertrieb']::public.app_role[]));
create policy contacts_insert on public.contacts for insert to authenticated
  with check (public.has_any_role(array['admin', 'teamlead', 'backoffice', 'vertrieb']::public.app_role[]));
create policy contacts_update on public.contacts for update to authenticated
  using (public.has_any_role(array['admin', 'teamlead', 'backoffice']::public.app_role[]))
  with check (public.has_any_role(array['admin', 'teamlead', 'backoffice']::public.app_role[]));
