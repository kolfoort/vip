create table public.admin_billing_vies_checks (
 owner uuid not null references auth.users(id) on delete cascade,
 vat text not null,
 requester_vat text not null,
 status text not null check (status in ('valid', 'invalid')),
 checked_at timestamptz not null,
 name text not null,
 request_identifier text not null,
 primary key (owner, vat, requester_vat)
);
alter table public.admin_billing_vies_checks enable row level security;
revoke all on public.admin_billing_vies_checks from public, anon, authenticated;
grant select on public.admin_billing_vies_checks to authenticated;
grant select, insert, update on public.admin_billing_vies_checks to service_role;
create policy billing_vies_admin_read on public.admin_billing_vies_checks
 for select to authenticated using (owner=(select auth.uid()) and (select portal_private.is_admin()));
