begin;
create table public.staff_workspaces(id text primary key,revision bigint not null default 1,data jsonb not null,updated_at timestamptz not null default now());
create table public.staff_audit(id bigint generated always as identity primary key,workspace text not null references public.staff_workspaces(id),employee text,shift text,actor uuid not null,kind text not null,at timestamptz not null default clock_timestamp(),payload jsonb not null default '{}');
create table public.staff_requests(actor uuid not null,request_id uuid not null,result jsonb not null,at timestamptz not null default now(),primary key(actor,request_id));
alter table public.staff_workspaces enable row level security;
alter table public.staff_audit enable row level security;
alter table public.staff_requests enable row level security;
revoke all on public.staff_workspaces,public.staff_audit,public.staff_requests from public,anon,authenticated;
create function portal_private.staff_immutable() returns trigger language plpgsql set search_path='' as $$begin raise exception 'Audit records are append only.';end;$$;
create trigger staff_audit_no_changes before update or delete on public.staff_audit for each row execute function portal_private.staff_immutable();
insert into public.staff_workspaces(id,data) values('koninghoek',jsonb_build_object('employees','[]'::jsonb,'assignments','[]'::jsonb,'shifts','[]'::jsonb,'corrections','[]'::jsonb,'managers','[]'::jsonb));
create function portal_private.staff_context() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid();mail text;w public.staff_workspaces;e jsonb;
begin
 if uid is null then raise exception 'Bitte anmelden.';end if;
 if not portal_private.session_mfa_allowed() then raise exception 'STAFF_MFA_REQUIRED';end if;
 if exists(select 1 from auth.mfa_factors where user_id=uid and status='verified') and coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'STAFF_MFA_REQUIRED';end if;
 if portal_private.is_admin() then return jsonb_build_object('role','admin','workspace','koninghoek','actor',uid);end if;
 select lower(email) into mail from auth.users where id=uid and email_confirmed_at is not null;
 if mail is null then raise exception 'E-Mail-Adresse zuerst bestätigen.';end if;
 for w in select * from public.staff_workspaces loop
  if exists(select 1 from jsonb_array_elements(w.data->'managers') m where lower(m->>'email')=mail and (m->>'active')::boolean) then if not exists(select 1 from auth.mfa_factors where user_id=uid and status='verified') then raise exception 'STAFF_MFA_ENROLL';end if;return jsonb_build_object('role','admin','workspace',w.id,'actor',uid,'hotel_manager',true);end if;
  select x into e from jsonb_array_elements(w.data->'employees') x where lower(x->>'email')=mail and (x->>'active')::boolean;
  if e is not null then if not exists(select 1 from auth.mfa_factors where user_id=uid and status='verified') then raise exception 'STAFF_MFA_ENROLL';end if;return jsonb_build_object('role','employee','workspace',w.id,'actor',uid,'employee',e->>'id');end if;
 end loop;
 raise exception 'Für dieses Konto ist kein aktiver Personalzugang hinterlegt. Bitte die Verwaltung kontaktieren.';
end;$$;
create function portal_private.staff_item(a jsonb,k text) returns jsonb language sql immutable set search_path='' as $$select x from jsonb_array_elements(a) x where x->>'id'=k limit 1;$$;
create function portal_private.staff_replace(a jsonb,r jsonb) returns jsonb language sql immutable set search_path='' as $$select coalesce(jsonb_agg(case when x->>'id'=r->>'id' then r else x end order by n),'[]'::jsonb) from jsonb_array_elements(a) with ordinality t(x,n);$$;
create function portal_private.staff_shift(s jsonb) returns jsonb language plpgsql stable set search_path='' as $$
declare a timestamptz:=coalesce(s->>'effective_start',s->>'start')::timestamptz;b timestamptz:=coalesce(s->>'effective_end',s->>'end',now()::text)::timestamptz;p jsonb;breaks jsonb:=coalesce(s->'effective_breaks',s->'breaks','[]'::jsonb);bm numeric:=0;q numeric:=0;work numeric;need integer;signals jsonb:='[]';cursor_at timestamptz;longest numeric:=0;pa timestamptz;pb timestamptz;
begin
 cursor_at:=a;
 if not (s?'effective_breaks') and s->>'break_open' is not null then breaks:=breaks||jsonb_build_array(jsonb_build_array(s->>'break_open',b));end if;
 for p in select * from jsonb_array_elements(breaks) loop
  pa:=(p->>0)::timestamptz;pb:=coalesce(p->>1,b::text)::timestamptz;
  bm:=bm+extract(epoch from pb-pa)/60;
  if extract(epoch from pb-pa)>=900 then q:=q+extract(epoch from pb-pa)/60;longest:=greatest(longest,extract(epoch from pa-cursor_at)/60);cursor_at:=pb;end if;
 end loop;
 longest:=greatest(longest,extract(epoch from b-cursor_at)/60);
 work:=greatest(0,extract(epoch from b-a)/60-bm);
 if work>600 then signals:=signals||'"Mehr als zehn Stunden: tägliche Höchstgrenze prüfen."'::jsonb;elsif work>480 then signals:=signals||'"Mehr als acht Stunden: Durchschnitt und Ausgleich prüfen."'::jsonb;end if;
 need:=case when work>540 then 45 when work>360 then 30 else 0 end;
 if q+0.01<need then signals:=signals||jsonb_build_array(format('Pausenprüfung: %s Minuten erforderlich; %s Minuten in Abschnitten ab 15 Minuten erfasst.',need,floor(q)));end if;
 if longest>360 then signals:=signals||'"Mehr als sechs Stunden ohne anrechenbare Ruhepause."'::jsonb;end if;
 if extract(isodow from a at time zone 'Europe/Berlin')=7 or extract(isodow from b at time zone 'Europe/Berlin')=7 then signals:=signals||'"Sonntagsarbeit: Ersatzruhetag und zulässige Ausnahme prüfen."'::jsonb;end if;
 if b-a>interval '24 hours' then signals:=signals||'"Schicht länger als 24 Stunden: fehlendes Ausstempeln prüfen."'::jsonb;end if;
 return s||jsonb_build_object('net_minutes',round(work,2),'break_minutes',round(bm,2),'qualifying_break_minutes',round(q,2),'effective_start',a,'effective_end',b,'corrected',s?'effective_start','signals',signals,'on_break',s->>'break_open' is not null);
end;$$;
create function public.staff_state() returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb:=portal_private.staff_context();d jsonb;em jsonb;sh jsonb;ass jsonb;corr jsonb;r jsonb;ev jsonb;outsh jsonb:='[]';prior_end timestamptz;
begin
 select data into d from public.staff_workspaces where id=ctx->>'workspace';
 em:=d->'employees';sh:=d->'shifts';ass:=d->'assignments';corr:=d->'corrections';
 if ctx->>'role'='employee' then
  select coalesce(jsonb_agg(x),'[]') into em from jsonb_array_elements(em) x where x->>'id'=ctx->>'employee';
  select coalesce(jsonb_agg(x),'[]') into sh from jsonb_array_elements(sh) x where x->>'employee'=ctx->>'employee';
  select coalesce(jsonb_agg(x),'[]') into ass from jsonb_array_elements(ass) x where x->>'employee'=ctx->>'employee';
  select coalesce(jsonb_agg(x),'[]') into corr from jsonb_array_elements(corr) x where x->>'employee'=ctx->>'employee';
 end if;
 for r in select x from jsonb_array_elements(sh) x order by x->>'start' desc loop
  r:=portal_private.staff_shift(r);
  select max(coalesce(x->>'effective_end',x->>'end')::timestamptz) into prior_end from jsonb_array_elements(d->'shifts') x where x->>'employee'=r->>'employee' and x->>'id'<>r->>'id' and x->>'end' is not null and coalesce(x->>'effective_end',x->>'end')::timestamptz<= (r->>'effective_start')::timestamptz;
  if prior_end is not null and (r->>'effective_start')::timestamptz-prior_end<interval '11 hours' then r:=jsonb_set(r,'{signals}',r->'signals'||'"Weniger als elf Stunden Ruhezeit: Ausnahme und Ausgleich prüfen."'::jsonb);end if;
  select coalesce(jsonb_agg(jsonb_build_object('kind',a.kind,'actor',a.actor,'at',a.at,'payload',a.payload) order by a.id),'[]') into ev from public.staff_audit a where a.workspace=ctx->>'workspace' and a.shift=r->>'id';
  outsh:=outsh||jsonb_build_array(r||jsonb_build_object('events',ev));
 end loop;
 return jsonb_build_object('role',ctx->>'role','actor',ctx->>'employee','hotel_manager',coalesce((ctx->>'hotel_manager')::boolean,false),'employees',em,'assignments',ass,'shifts',outsh,'corrections',corr,'managers',case when ctx->>'role'='admin' then d->'managers' else '[]'::jsonb end,'clients',jsonb_build_array(jsonb_build_object('id','koninghoek','name','Landgasthof Koninghoek UG (haftungsbeschränkt)','timezone','Europe/Berlin','country','DE')),'server_now',clock_timestamp(),'timezone','Europe/Berlin','mode','live');
end;$$;
create function public.staff_action(p_action text,p_payload jsonb,p_request uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb:=portal_private.staff_context();uid uuid:=auth.uid();d jsonb;result jsonb;old jsonb;r jsonb;e jsonb;a jsonb;s jsonb;c jsonb;w jsonb;arr jsonb;ev jsonb;id text;eid text;sid text;kind text:=p_action;mail text;nm text;reason text;decision text;t timestamptz:=clock_timestamp();ts timestamptz;te timestamptz;pa timestamptz;pb timestamptz;cur timestamptz;br jsonb;rate bigint;rate_at date;admin boolean:=ctx->>'role'='admin';
begin
 if p_request is null or jsonb_typeof(p_payload)<>'object' or length(p_payload::text)>24000 then raise exception 'Ungültige Anfrage.';end if;
 select data into d from public.staff_workspaces where id=ctx->>'workspace' for update;
 select x.result into result from public.staff_requests x where actor=uid and request_id=p_request;
 if result is not null then return result;end if;
 if p_action in ('employee_save','employee_edit','assignment','rate_save','approve','correction_review','manager_save') and not admin then raise exception 'Nur die Verwaltung darf diese Aktion ausführen.';end if;
 if p_action in ('clock_in','clock_out','break_start','break_end','correction_request') and admin then raise exception 'Bitte das persönliche Mitarbeiterkonto verwenden.';end if;
 case p_action
 when 'employee_save','employee_edit' then
  nm:=trim(p_payload->>'name');mail:=lower(trim(p_payload->>'email'));
  if coalesce(nm,'')='' or length(nm)>150 or mail !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or length(mail)>250 or coalesce(p_payload->>'adult','false')<>'true' then raise exception 'Name, E-Mail und Volljährigkeitsbestätigung sind erforderlich.';end if;
  id:=case when p_action='employee_save' then pg_catalog.gen_random_uuid()::text else p_payload->>'id' end;
  old:=portal_private.staff_item(d->'employees',id);
  if p_action='employee_edit' and old is null then raise exception 'Person nicht gefunden.';end if;
  if old is not null and old->>'email'<>mail then raise exception 'E-Mail-Wechsel erfordert eine gesonderte Kontoprüfung.';end if;
  if exists(select 1 from jsonb_array_elements(d->'employees') x where lower(x->>'email')=mail and x->>'id'<>id) or exists(select 1 from jsonb_array_elements(d->'managers') x where lower(x->>'email')=mail) then raise exception 'Diese E-Mail ist bereits zugeordnet.';end if;
  if p_payload->>'language' not in ('de','nl','en') then raise exception 'Sprache ungültig.';end if;
  r:=jsonb_build_object('id',id,'name',nm,'email',mail,'employer','Landgasthof Koninghoek UG (haftungsbeschränkt)','language',p_payload->>'language','adult',true,'active',coalesce((p_payload->>'active')::boolean,true),'rates',coalesce(old->'rates','[]'::jsonb),'privacy_ack',old->'privacy_ack','privacy_ack_at',old->'privacy_ack_at');
  if old is null then d:=jsonb_set(d,'{employees}',d->'employees'||jsonb_build_array(r));d:=jsonb_set(d,'{assignments}',d->'assignments'||jsonb_build_array(jsonb_build_object('id',pg_catalog.gen_random_uuid()::text,'employee',id,'client','koninghoek','role',coalesce(nullif(trim(p_payload->>'job'),''),'Service'),'active',true)));
  else
   if not (r->>'active')::boolean and exists(select 1 from jsonb_array_elements(d->'shifts') x where x->>'employee'=id and x->>'end' is null) then raise exception 'Zuerst laufende Schicht abschließen.';end if;
   d:=jsonb_set(d,'{employees}',portal_private.staff_replace(d->'employees',r));
  end if;
  eid:=id;ev:=jsonb_build_object('before',old,'after',r);
 when 'rate_save' then
  eid:=p_payload->>'employee';e:=portal_private.staff_item(d->'employees',eid);rate_at:=(p_payload->>'effective_from')::date;
  if e is null then raise exception 'Person nicht gefunden.';end if;
  if p_payload->>'rate' !~ '^[0-9]{1,4}([.][0-9]{1,2})?$' then raise exception 'Stundenlohn mit höchstens zwei Nachkommastellen eingeben.';end if;
  rate:=round((p_payload->>'rate')::numeric*100);
  if rate<=0 or rate_at<(t at time zone 'Europe/Berlin')::date then raise exception 'Positiver Bruttostundenlohn und heutiges oder zukünftiges Datum erforderlich.';end if;
  if exists(select 1 from jsonb_array_elements(e->'rates') x where (x->>'effective_from')::date=rate_at) then raise exception 'Für dieses Datum ist bereits ein Tarif gespeichert. Bitte einen neuen Gültigkeitsbeginn verwenden.';end if;
  r:=jsonb_build_object('id',pg_catalog.gen_random_uuid()::text,'effective_from',rate_at,'cents',rate,'currency','EUR','created_at',t);
  old:=e;e:=jsonb_set(e,'{rates}',e->'rates'||jsonb_build_array(r));d:=jsonb_set(d,'{employees}',portal_private.staff_replace(d->'employees',e));ev:=jsonb_build_object('rate',r);
 when 'assignment' then
  eid:=p_payload->>'employee';e:=portal_private.staff_item(d->'employees',eid);
  if e is null or coalesce(trim(p_payload->>'role'),'')='' or p_payload->>'client'<>'koninghoek' then raise exception 'Person, Kunde und Tätigkeit prüfen.';end if;
  r:=jsonb_build_object('id',pg_catalog.gen_random_uuid()::text,'employee',eid,'client','koninghoek','role',left(trim(p_payload->>'role'),150),'active',true);
  d:=jsonb_set(d,'{assignments}',d->'assignments'||jsonb_build_array(r));ev:=r;
 when 'clock_in','clock_out','break_start','break_end' then
  eid:=ctx->>'employee';e:=portal_private.staff_item(d->'employees',eid);
  select x into s from jsonb_array_elements(d->'shifts') x where x->>'employee'=eid and x->>'end' is null;
  if p_action='clock_in' then
   if coalesce(e->>'privacy_ack','')<>'2026-10-31' then raise exception 'Datenschutzhinweise zuerst lesen und bestätigen.';end if;
   if s is not null then raise exception 'Es läuft bereits eine Schicht.';end if;
   a:=portal_private.staff_item(d->'assignments',p_payload->>'assignment');
   if a is null or a->>'employee'<>eid or not (a->>'active')::boolean then raise exception 'Keine aktive Zuordnung.';end if;
   select x into w from jsonb_array_elements(e->'rates') x where (x->>'effective_from')::date<=(t at time zone 'Europe/Berlin')::date order by x->>'effective_from' desc limit 1;
   sid:=pg_catalog.gen_random_uuid()::text;s:=jsonb_build_object('id',sid,'employee',eid,'assignment',a->>'id','start',t,'end',null,'status','open','breaks','[]'::jsonb,'break_open',null,'rate_snapshot',w);
   d:=jsonb_set(d,'{shifts}',d->'shifts'||jsonb_build_array(s));
  else
   if s is null then raise exception 'Keine laufende Schicht.';end if;sid:=s->>'id';
   if p_action='break_start' then
    if s->>'break_open' is not null then raise exception 'Eine Pause läuft bereits.';end if;
    s:=s||jsonb_build_object('break_open',t);
   elsif p_action='break_end' then
    if s->>'break_open' is null then raise exception 'Keine laufende Pause.';end if;
    s:=s||jsonb_build_object('breaks',s->'breaks'||jsonb_build_array(jsonb_build_array(s->>'break_open',t)),'break_open',null);
   else
    if s->>'break_open' is not null then s:=s||jsonb_build_object('breaks',s->'breaks'||jsonb_build_array(jsonb_build_array(s->>'break_open',t)),'break_open',null);end if;
    s:=s||jsonb_build_object('end',t,'status','pending');
   end if;
   d:=jsonb_set(d,'{shifts}',portal_private.staff_replace(d->'shifts',s));
  end if;
  ev:=jsonb_build_object('server_time',true,'shift',s);
 when 'correction_request' then
  sid:=p_payload->>'shift';eid:=ctx->>'employee';s:=portal_private.staff_item(d->'shifts',sid);reason:=trim(p_payload->>'reason');
  if s is null or s->>'employee'<>eid or s->>'end' is null then raise exception 'Abgeschlossene eigene Schicht erforderlich.';end if;
  if p_payload->>'start' !~ '(Z|[+-][0-9]{2}:[0-9]{2})$' or p_payload->>'end' !~ '(Z|[+-][0-9]{2}:[0-9]{2})$' then raise exception 'Zeitpunkte mit UTC-Offset angeben.';end if;
  ts:=(p_payload->>'start')::timestamptz;te:=(p_payload->>'end')::timestamptz;
  if coalesce(length(reason),0)<8 or length(reason)>1500 or te<=ts or te-ts>interval '24 hours' or te>t then raise exception 'Begründung und Zeitpunkte prüfen (höchstens 24 Stunden, nicht in der Zukunft).';end if;
  if exists(select 1 from jsonb_array_elements(d->'corrections') x where x->>'shift'=sid and x->>'status'='pending') then raise exception 'Es liegt bereits ein offener Korrekturantrag vor.';end if;
  if exists(select 1 from jsonb_array_elements(d->'shifts') x where x->>'employee'=eid and x->>'id'<>sid and coalesce(x->>'effective_start',x->>'start')::timestamptz<te and coalesce(x->>'effective_end',x->>'end',t::text)::timestamptz>ts) then raise exception 'Die beantragten Zeiten überschneiden sich mit einer anderen Schicht.';end if;
  br:=coalesce(p_payload->'breaks','[]'::jsonb);cur:=ts;
  if jsonb_typeof(br)<>'array' or jsonb_array_length(br)>30 then raise exception 'Pausenliste ungültig.';end if;
  for r in select * from jsonb_array_elements(br) loop
   if jsonb_array_length(r)<>2 or r->>0 !~ '(Z|[+-][0-9]{2}:[0-9]{2})$' or r->>1 !~ '(Z|[+-][0-9]{2}:[0-9]{2})$' then raise exception 'Pausen mit UTC-Offset angeben.';end if;
   pa:=(r->>0)::timestamptz;pb:=(r->>1)::timestamptz;
   if pa<cur or pb<=pa or pb>te then raise exception 'Pausen müssen geordnet innerhalb der Schicht liegen.';end if;cur:=pb;
  end loop;
  c:=jsonb_build_object('id',pg_catalog.gen_random_uuid()::text,'employee',eid,'shift',sid,'requested_by',uid,'reason',reason,'start',ts,'end',te,'breaks',br,'status','pending','requested_at',t);
  d:=jsonb_set(d,'{corrections}',d->'corrections'||jsonb_build_array(c));s:=s||jsonb_build_object('status','pending');d:=jsonb_set(d,'{shifts}',portal_private.staff_replace(d->'shifts',s));ev:=c;
 when 'correction_review' then
  id:=p_payload->>'id';c:=portal_private.staff_item(d->'corrections',id);reason:=trim(p_payload->>'reason');decision:=p_payload->>'decision';
  if c is null or c->>'status'<>'pending' or decision not in ('approved','rejected') or coalesce(length(reason),0)<8 then raise exception 'Offenen Antrag, Entscheidung und Begründung angeben.';end if;
  eid:=c->>'employee';sid:=c->>'shift';
  if decision='approved' then
   if exists(select 1 from jsonb_array_elements(d->'shifts') x where x->>'employee'=eid and x->>'id'<>sid and coalesce(x->>'effective_start',x->>'start')::timestamptz<(c->>'end')::timestamptz and coalesce(x->>'effective_end',x->>'end',t::text)::timestamptz>(c->>'start')::timestamptz) then raise exception 'Überschneidung mit anderer Schicht. Antrag erneut prüfen.';end if;
   s:=portal_private.staff_item(d->'shifts',sid);s:=s||jsonb_build_object('effective_start',c->'start','effective_end',c->'end','effective_breaks',c->'breaks','status','pending');d:=jsonb_set(d,'{shifts}',portal_private.staff_replace(d->'shifts',s));
  end if;
  c:=c||jsonb_build_object('status',decision,'review_reason',left(reason,1500),'reviewed_at',t,'reviewed_by',uid);d:=jsonb_set(d,'{corrections}',portal_private.staff_replace(d->'corrections',c));ev:=c;
 when 'approve' then
  sid:=p_payload->>'id';s:=portal_private.staff_item(d->'shifts',sid);reason:=trim(p_payload->>'reason');
  if s is null or s->>'end' is null or s->>'status'<>'pending' or coalesce(length(reason),0)<8 then raise exception 'Abgeschlossene Schicht und Prüfbegründung erforderlich.';end if;
  if exists(select 1 from jsonb_array_elements(d->'corrections') x where x->>'shift'=sid and x->>'status'='pending') then raise exception 'Zuerst Korrekturantrag bearbeiten.';end if;
  eid:=s->>'employee';s:=s||jsonb_build_object('status','approved','reviewed_at',t,'reviewed_by',uid,'review_reason',left(reason,1500));d:=jsonb_set(d,'{shifts}',portal_private.staff_replace(d->'shifts',s));ev:=jsonb_build_object('reason',reason,'snapshot',portal_private.staff_shift(s));
 when 'manager_save' then
  if not portal_private.is_admin() then raise exception 'Nur VIP-Administratoren dürfen Arbeitgeberzugänge ändern.';end if;
  mail:=lower(trim(p_payload->>'email'));
  if mail !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or p_payload->>'confirmed'<>'true' then raise exception 'Verwaltungszugang ausdrücklich bestätigen.';end if;
  if exists(select 1 from jsonb_array_elements(d->'employees') x where x->>'email'=mail) then raise exception 'Diese E-Mail ist bereits als Mitarbeiterkonto hinterlegt.';end if;
  select coalesce(jsonb_agg(x),'[]') into arr from jsonb_array_elements(d->'managers') x where x->>'email'<>mail;
  r:=jsonb_build_object('email',mail,'active',coalesce((p_payload->>'active')::boolean,true),'granted_by',uid,'granted_at',t);d:=jsonb_set(d,'{managers}',arr||jsonb_build_array(r));ev:=r;
 when 'privacy_ack' then
  if admin then raise exception 'Persönliches Mitarbeiterkonto erforderlich.';end if;
  eid:=ctx->>'employee';e:=portal_private.staff_item(d->'employees',eid);e:=e||jsonb_build_object('privacy_ack','2026-10-31','privacy_ack_at',t);d:=jsonb_set(d,'{employees}',portal_private.staff_replace(d->'employees',e));ev:=jsonb_build_object('notice_version','2026-10-31','acknowledgement_not_consent',true);
 when 'export' then ev:=jsonb_build_object('scope',ctx->>'role','employee',ctx->>'employee');
 else raise exception 'Unbekannte Aktion.';
 end case;
 update public.staff_workspaces set data=d,revision=revision+1,updated_at=t where id=ctx->>'workspace';
 insert into public.staff_audit(workspace,employee,shift,actor,kind,at,payload) values(ctx->>'workspace',eid,sid,uid,kind,t,coalesce(ev,'{}'));
 result:=jsonb_build_object('ok',true,'id',id,'server_time',t);insert into public.staff_requests(actor,request_id,result) values(uid,p_request,result);return result;
end;$$;
revoke all on function portal_private.staff_immutable(),portal_private.staff_context(),portal_private.staff_item(jsonb,text),portal_private.staff_replace(jsonb,jsonb),portal_private.staff_shift(jsonb) from public,anon,authenticated;
revoke all on function public.staff_state(),public.staff_action(text,jsonb,uuid) from public,anon;
grant execute on function public.staff_state(),public.staff_action(text,jsonb,uuid) to authenticated;
-- Workforce-created accounts are not activated as VIP client accounts.
create or replace function portal_private.sync_member() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_OP='INSERT' then
  insert into public.portal_members(user_id,email,active) values(new.id,new.email,coalesce(new.raw_user_meta_data->>'staff_portal','false')<>'true');
 else update public.portal_members set email=new.email where user_id=new.id;end if;
 return new;
end;$$;
notify pgrst,'reload schema';
commit;
