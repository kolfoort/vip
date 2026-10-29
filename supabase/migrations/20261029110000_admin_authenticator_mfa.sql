begin;
-- Stage enforcement until the enrollment UI and authenticated Edge routes are published.
create table portal_private.mfa_policy(singleton boolean primary key default true check(singleton),enforce_admin boolean not null default false);
insert into portal_private.mfa_policy values(true,false);
alter table portal_private.mfa_policy enable row level security;
revoke all on portal_private.mfa_policy from public,anon,authenticated,service_role;
-- Read membership directly inside a security-definer function to avoid RLS recursion.
create function portal_private.session_mfa_allowed() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and case
 when (coalesce((select enforce_admin from portal_private.mfa_policy where singleton),false) and exists(select 1 from public.portal_members where user_id=auth.uid() and active and is_admin))
   or exists(select 1 from auth.mfa_factors where user_id=auth.uid() and status='verified')
 then coalesce(auth.jwt()->>'aal'='aal2',false) and exists(select 1 from auth.mfa_factors where user_id=auth.uid() and status='verified')
 else true end;
$$;
revoke all on function portal_private.session_mfa_allowed() from public,anon,service_role;
grant execute on function portal_private.session_mfa_allowed() to authenticated;

-- This is the only pre-MFA portal RPC. It returns the caller's own security status only.
create function public.my_portal_security() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare m public.portal_members;verified boolean;
begin
 if auth.uid() is null then raise exception 'Sign in required';end if;
 select * into m from public.portal_members where user_id=auth.uid();
 if not found or not m.active then return jsonb_build_object('active',false,'allowed',false);end if;
 verified:=exists(select 1 from auth.mfa_factors where user_id=auth.uid() and status='verified');
 return jsonb_build_object('active',true,'admin',m.is_admin,'required',(m.is_admin and coalesce((select enforce_admin from portal_private.mfa_policy where singleton),false)) or verified,'enrolled',verified,'allowed',portal_private.session_mfa_allowed());
end;$$;
revoke all on function public.my_portal_security() from public,anon,service_role;
grant execute on function public.my_portal_security() to authenticated;

-- Preserve the existing suspension and role checks, adding MFA to both central helpers.
do $$declare original text;begin
 original:=pg_get_functiondef('portal_private.is_active()'::regprocedure);
 execute replace(original,'portal_private.is_active()','portal_private.is_active_before_mfa()');
 original:=pg_get_functiondef('portal_private.is_admin()'::regprocedure);
 execute replace(original,'portal_private.is_admin()','portal_private.is_admin_before_mfa()');
end;$$;
revoke all on function portal_private.is_active_before_mfa(),portal_private.is_admin_before_mfa() from public,anon,authenticated,service_role;
create or replace function portal_private.is_active() returns boolean language sql stable security definer set search_path='' as $$select portal_private.is_active_before_mfa() and portal_private.session_mfa_allowed();$$;
create or replace function portal_private.is_admin() returns boolean language sql stable security definer set search_path='' as $$select portal_private.is_admin_before_mfa() and portal_private.session_mfa_allowed();$$;
revoke all on function portal_private.is_active(),portal_private.is_admin() from public,anon,service_role;
grant execute on function portal_private.is_active(),portal_private.is_admin() to authenticated;

-- A restrictive policy also covers older policies with direct membership checks.
do $$declare t record;begin
 for t in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p') and c.relrowsecurity loop
  execute format('create policy portal_mfa_gate on public.%I as restrictive for all to authenticated using ((select portal_private.session_mfa_allowed())) with check ((select portal_private.session_mfa_allowed()))',t.relname);
 end loop;
end;$$;
create policy portal_mfa_gate on storage.objects as restrictive for all to authenticated
using ((select portal_private.session_mfa_allowed())) with check ((select portal_private.session_mfa_allowed()));

-- Every authenticated security-definer RPC receives a gate. Preserve its arguments/defaults,
-- return contract and role grants. Private implementations cannot be called through REST.
do $migration$
declare f record;legacy text;args text;callargs text;result_type text;body text;can_anon boolean;can_service boolean;has_out boolean;
begin
 for f in select p.*,pg_get_function_arguments(p.oid) args_decl,pg_get_function_result(p.oid) result_decl
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prokind='f' and p.prorettype not in ('trigger'::regtype,'event_trigger'::regtype) and p.prosecdef and p.proname<>'my_portal_security' and has_function_privilege('authenticated',p.oid,'EXECUTE')
 loop
  legacy:='mfa_implementation_'||f.oid::text;
  can_anon:=has_function_privilege('anon',f.oid,'EXECUTE');can_service:=has_function_privilege('service_role',f.oid,'EXECUTE');
  select string_agg('$'||i,', ' order by i) into callargs from generate_series(1,f.pronargs) i;
  callargs:=coalesce(callargs,'');args:=f.args_decl;result_type:=f.result_decl;
  has_out:=f.proargmodes is not null and ('o'=any(f.proargmodes) or 'b'=any(f.proargmodes));
  execute format('alter function public.%I(%s) rename to %I',f.proname,pg_get_function_identity_arguments(f.oid),legacy);
  execute format('alter function public.%I(%s) set schema portal_private',legacy,pg_get_function_identity_arguments(f.oid));
  execute format('revoke all on function portal_private.%I(%s) from public,anon,authenticated,service_role',legacy,pg_get_function_identity_arguments(f.oid));
  body:='begin if auth.uid() is not null and not portal_private.session_mfa_allowed() then raise exception ''MFA_REQUIRED'' using errcode=''42501'';end if; ';
  if f.proretset then body:=body||format('return query select * from portal_private.%I(%s);return;',legacy,callargs);
  elsif f.prorettype='void'::regtype then body:=body||format('perform portal_private.%I(%s);return;',legacy,callargs);
  elsif has_out then
   -- No current application RPC is expected to have non-set OUT parameters.
   raise exception 'Review OUT-parameter RPC before MFA migration: %',f.proname;
  else body:=body||format('return portal_private.%I(%s);',legacy,callargs);end if;
  body:=body||'end;';
  execute format('create function public.%I(%s) returns %s language plpgsql volatile security definer set search_path='''' as %L',f.proname,args,result_type,body);
  execute format('revoke all on function public.%I(%s) from public,anon,authenticated,service_role',f.proname,pg_get_function_identity_arguments(f.oid));
  execute format('grant execute on function public.%I(%s) to authenticated',f.proname,pg_get_function_identity_arguments(f.oid));
  if can_anon then execute format('grant execute on function public.%I(%s) to anon',f.proname,pg_get_function_identity_arguments(f.oid));end if;
  if can_service then execute format('grant execute on function public.%I(%s) to service_role',f.proname,pg_get_function_identity_arguments(f.oid));end if;
 end loop;
end;$migration$;
notify pgrst,'reload schema';
commit;
