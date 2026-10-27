begin;
create table public.portal_counterparty_roles (
 user_id uuid primary key references public.portal_members(user_id),
 counterparty_role text not null check(counterparty_role in ('introducer_broker','end_buyer_user','jv_partner','trader_reseller','supplier_seller')),
 updated_by uuid not null references public.portal_members(user_id),
 updated_at timestamptz not null default now()
);
alter table public.portal_counterparty_roles enable row level security;
revoke all on public.portal_counterparty_roles from public,anon,authenticated;
grant select on public.portal_counterparty_roles to authenticated;
create policy counterparty_role_read on public.portal_counterparty_roles for select to authenticated using ((select portal_private.is_admin()) or (user_id=(select auth.uid()) and (select portal_private.is_active())));
create function public.save_counterparty_role(p_user_id uuid,p_role text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 if p_user_id is distinct from auth.uid() and not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 if p_role not in ('introducer_broker','end_buyer_user','jv_partner','trader_reseller','supplier_seller') or p_role is null then raise exception 'Select a valid counterparty type';end if;
 if not exists(select 1 from public.portal_members where user_id=p_user_id and active) then raise exception 'Active registered account required';end if;
 insert into public.portal_counterparty_roles(user_id,counterparty_role,updated_by) values(p_user_id,p_role,auth.uid()) on conflict(user_id) do update set counterparty_role=excluded.counterparty_role,updated_by=excluded.updated_by,updated_at=now();
end;$$;
revoke all on function public.save_counterparty_role(uuid,text) from public,anon;
grant execute on function public.save_counterparty_role(uuid,text) to authenticated;
commit;
