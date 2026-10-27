begin;
create table public.admin_billing_workspaces(owner uuid primary key references auth.users(id),revision integer not null default 1,data jsonb not null,updated_at timestamptz not null default now());
create table public.admin_billing_counters(issuer_registration text not null,year integer not null,value integer not null,primary key(issuer_registration,year));
alter table public.admin_billing_counters enable row level security;
revoke all on public.admin_billing_counters from public,anon,authenticated;
create table public.admin_billing_events(id bigint generated always as identity primary key,owner uuid not null references auth.users(id),action text not null,entity_id integer,revision integer not null,created_at timestamptz not null default now());
create table public.admin_billing_pdfs(owner uuid not null references auth.users(id),invoice_id integer not null,pdf_base64 text not null,pdf_sha256 text not null,created_at timestamptz not null default now(),primary key(owner,invoice_id));
alter table public.admin_billing_workspaces enable row level security;
alter table public.admin_billing_events enable row level security;
alter table public.admin_billing_pdfs enable row level security;
revoke all on public.admin_billing_workspaces,public.admin_billing_events,public.admin_billing_pdfs from public,anon,authenticated;
grant select on public.admin_billing_workspaces,public.admin_billing_events,public.admin_billing_pdfs to authenticated;
create policy billing_workspace_admin_read on public.admin_billing_workspaces for select to authenticated using(owner=(select auth.uid()) and (select portal_private.is_admin()));
create policy billing_event_admin_read on public.admin_billing_events for select to authenticated using(owner=(select auth.uid()) and (select portal_private.is_admin()));
create policy billing_pdf_admin_read on public.admin_billing_pdfs for select to authenticated using(owner=(select auth.uid()) and (select portal_private.is_admin()));
create function portal_private.billing_money(v text) returns bigint language plpgsql immutable set search_path='' as $$
begin
 if v is null or v !~ '^[0-9]{1,7}([.][0-9]{1,2})?$' then raise exception 'Gebruik een niet-negatief bedrag met maximaal twee decimalen.';end if;
 return (v::numeric*100)::bigint;
end;$$;
create function portal_private.billing_item(a jsonb,i integer) returns jsonb language plpgsql immutable set search_path='' as $$
declare r jsonb;
begin select e into r from jsonb_array_elements(a) e where (e->>'id')::integer=i;if r is null then raise exception 'Dit item bestaat niet meer.';end if;return r;end;$$;
create function portal_private.billing_replace(a jsonb,r jsonb) returns jsonb language sql immutable set search_path='' as $$
 select coalesce(jsonb_agg(case when e->>'id'=r->>'id' then r else e end order by n),'[]') from jsonb_array_elements(a) with ordinality t(e,n);
$$;
revoke all on function portal_private.billing_money(text),portal_private.billing_item(jsonb,integer),portal_private.billing_replace(jsonb,jsonb) from public,anon,authenticated;
create function public.billing_state() returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();w public.admin_billing_workspaces;
begin
 if uid is null or not portal_private.is_admin() then raise exception 'Deze administratie is alleen toegankelijk voor actieve VIP Capital-admins.';end if;
 insert into public.admin_billing_workspaces(owner,data) values(uid,jsonb_build_object('settings',jsonb_build_object('name','La Clava Elit B.V.','address',E'Oude Apeldoornseweg 45-067\n7333 NR Apeldoorn','country','Nederland','kvk','84285699','vat','NL863159825B01','email','info@kolfoort.com','phone','+31 (0)85-200 9082','website','www.kolfoort.com','eur_bank','','usd_bank','','payment_days',14,'footer','Dank voor uw vertrouwen.'),'clients','[]'::jsonb,'projects','[]'::jsonb,'entries','[]'::jsonb,'invoices','[]'::jsonb,'timer',null,'next_ids',jsonb_build_object('client',0,'project',0,'entry',0,'invoice',0),'counters','{}'::jsonb)) on conflict(owner) do nothing;
 select * into w from public.admin_billing_workspaces where owner=uid;
 return w.data||jsonb_build_object('revision',w.revision,'today',(now() at time zone 'Europe/Amsterdam')::date,'mode','live');
end;$$;
revoke all on function public.billing_state() from public,anon;
grant execute on function public.billing_state() to authenticated;
create function public.billing_action(p_action text,p_revision integer,p_payload jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();w public.admin_billing_workspaces;d jsonb;r jsonb;old jsonb;pr jsonb;cl jsonb;e jsonb;x jsonb;rows jsonb;sn jsonb;t jsonb;cfg jsonb;ids jsonb;key text;kind text;arr text;cur text;lang text;mode text;v text;id integer;num integer;yr integer;cid integer;pid integer;mins integer;pause integer;gross integer;startm integer;endm integer;rate bigint;subtotal bigint:=0;vat bigint;tax numeric;fx numeric;issue date;due date;raw bytea;number text;et jsonb;resultid integer;
begin
 if uid is null or not portal_private.is_admin() then raise exception 'Alleen actieve VIP Capital-admins hebben toegang.';end if;
 if jsonb_typeof(p_payload) is distinct from 'object' or length(p_payload::text)>12000000 then raise exception 'Ongeldige aanvraag.';end if;
 select * into w from public.admin_billing_workspaces where owner=uid for update;
 if not found then raise exception 'Open de administratie opnieuw.';end if;
 if p_revision is distinct from w.revision then raise exception 'De administratie is gewijzigd in een ander venster. Ververs de pagina en probeer opnieuw.';end if;
 d:=w.data;cfg:=d->'settings';id:=nullif(p_payload->>'id','')::integer;
 case p_action
 when 'settings' then
 foreach key in array array['name','address','country','kvk','vat','email','phone','website','eur_bank','usd_bank','footer'] loop
 v:=trim(coalesce(p_payload->>key,''));if length(v)>6000 then raise exception 'Tekst te lang: %',key;end if;
 if key in ('name','address','country') and v='' then raise exception 'Vul % in.',key;end if;cfg:=cfg||jsonb_build_object(key,v);end loop;
 num:=(p_payload->>'payment_days')::integer;if num not between 1 and 365 then raise exception 'Betaaltermijn moet 1 tot 365 dagen zijn.';end if;
 d:=jsonb_set(d,'{settings}',cfg||jsonb_build_object('payment_days',num));
 when 'client' then
 foreach key in array array['name','address','country'] loop if trim(coalesce(p_payload->>key,''))='' then raise exception 'Vul % in.',key;end if;end loop;
 lang:=coalesce(p_payload->>'language','nl');if lang not in ('nl','en','de') then raise exception 'Kies Nederlands, Engels of Duits.';end if;
 r:='{}';foreach key in array array['name','address','country','email','vat','reference'] loop v:=trim(coalesce(p_payload->>key,''));if length(v)>6000 then raise exception 'Tekst te lang.';end if;r:=r||jsonb_build_object(key,v);end loop;r:=r||jsonb_build_object('language',lang);
 if id is null then id:=coalesce((d->'next_ids'->>'client')::integer,0)+1;d:=jsonb_set(d,'{next_ids,client}',to_jsonb(id));r:=r||jsonb_build_object('id',id);d:=jsonb_set(d,'{clients}',d->'clients'||jsonb_build_array(r));else perform portal_private.billing_item(d->'clients',id);r:=r||jsonb_build_object('id',id);d:=jsonb_set(d,'{clients}',portal_private.billing_replace(d->'clients',r));end if;
 when 'project' then
 cid:=(p_payload->>'client_id')::integer;cl:=portal_private.billing_item(d->'clients',cid);cur:=p_payload->>'currency';rate:=portal_private.billing_money(p_payload->>'rate');v:=trim(coalesce(p_payload->>'name',''));
 if v='' or length(v)>6000 or (cur is null or cur not in ('EUR','USD')) then raise exception 'Vul projectnaam en EUR of USD in.';end if;
 r:=jsonb_build_object('client_id',cid,'name',v,'currency',cur,'rate_cents',rate,'active',1);
 if id is null then id:=coalesce((d->'next_ids'->>'project')::integer,0)+1;d:=jsonb_set(d,'{next_ids,project}',to_jsonb(id));r:=r||jsonb_build_object('id',id);d:=jsonb_set(d,'{projects}',d->'projects'||jsonb_build_array(r));else
 old:=portal_private.billing_item(d->'projects',id);
 if (old->>'currency'<>cur or (old->>'client_id')::integer<>cid) and (exists(select 1 from jsonb_array_elements(d->'entries') z where (z->>'project_id')::integer=id) or (d->'timer'->>'project_id')::integer=id) then raise exception 'Een project met uren houdt zijn klant en valuta. Maak een nieuw project aan.';end if;
 r:=r||jsonb_build_object('id',id);d:=jsonb_set(d,'{projects}',portal_private.billing_replace(d->'projects',r));end if;
 when 'entry' then
 pid:=(p_payload->>'project_id')::integer;pr:=portal_private.billing_item(d->'projects',pid);mode:=p_payload->>'input_mode';issue:=(p_payload->>'work_date')::date;pause:=0;
 if mode='times' then
 if coalesce(p_payload->>'start_time','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(p_payload->>'end_time','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Vul geldige begin- en eindtijden in.';end if;
 startm:=split_part(p_payload->>'start_time',':',1)::integer*60+split_part(p_payload->>'start_time',':',2)::integer;endm:=split_part(p_payload->>'end_time',':',1)::integer*60+split_part(p_payload->>'end_time',':',2)::integer;
 pause:=coalesce((p_payload->>'break_minutes')::integer,0);gross:=endm-startm+case when p_payload->'next_day'='true'::jsonb then 1440 else 0 end;
 if gross not between 1 and 1440 or pause not between 0 and 1439 then raise exception 'Controleer de tijden, pauze en volgende-dag-keuze.';end if;mins:=gross-pause;
 elsif mode='duration' then mins:=(p_payload->>'minutes')::integer;else raise exception 'Kies de manier van uren invoeren.';end if;
 if mins is null or mins not between 1 and 1440 or issue is null then raise exception 'Vul een datum en 1 minuut tot 24 uur netto werktijd in.';end if;
 v:=trim(coalesce(p_payload->>'description',''));if v='' or length(v)>6000 then raise exception 'Vul een omschrijving in.';end if;rate:=portal_private.billing_money(p_payload->>'rate');
 r:=jsonb_build_object('project_id',pid,'work_date',issue,'description',v,'minutes',mins,'rate_cents',rate,'currency',pr->>'currency','billable',case when p_payload->'billable'='true'::jsonb then 1 else 0 end,'invoice_id',null,'start_time',case when mode='times' then p_payload->>'start_time' else '' end,'end_time',case when mode='times' then p_payload->>'end_time' else '' end,'break_minutes',pause,'next_day',case when mode='times' and p_payload->'next_day'='true'::jsonb then 1 else 0 end,'input_mode',mode);
 if id is null then id:=coalesce((d->'next_ids'->>'entry')::integer,0)+1;d:=jsonb_set(d,'{next_ids,entry}',to_jsonb(id));r:=r||jsonb_build_object('id',id,'created_at',now());d:=jsonb_set(d,'{entries}',d->'entries'||jsonb_build_array(r));else
 old:=portal_private.billing_item(d->'entries',id);if old->>'invoice_id' is not null then raise exception 'Uren op een factuur zijn vergrendeld.';end if;r:=r||jsonb_build_object('id',id,'created_at',old->'created_at');d:=jsonb_set(d,'{entries}',portal_private.billing_replace(d->'entries',r));end if;
 when 'delete_entry' then
 old:=portal_private.billing_item(d->'entries',id);if old->>'invoice_id' is not null then raise exception 'Deze uren zijn aan een factuur gekoppeld.';end if;
 select coalesce(jsonb_agg(z order by n),'[]') into rows from jsonb_array_elements(d->'entries') with ordinality t(z,n) where (z->>'id')::integer<>id;d:=jsonb_set(d,'{entries}',rows);
 when 'timer_start' then
 if d->'timer'<>'null'::jsonb then raise exception 'Er loopt al een timer.';end if;pid:=(p_payload->>'project_id')::integer;pr:=portal_private.billing_item(d->'projects',pid);v:=trim(coalesce(p_payload->>'description',''));if v='' or length(v)>6000 then raise exception 'Vul een omschrijving in.';end if;
 d:=jsonb_set(d,'{timer}',jsonb_build_object('project_id',pid,'description',v,'started_at',now()));
 when 'timer_stop' then
 t:=d->'timer';if t='null'::jsonb then raise exception 'Er loopt geen timer.';end if;mins:=greatest(1,ceil(extract(epoch from (now()-(t->>'started_at')::timestamptz))/60))::integer;if mins>1440 then raise exception 'Deze timer loopt langer dan 24 uur. Annuleer hem en registreer per dag.';end if;
 pr:=portal_private.billing_item(d->'projects',(t->>'project_id')::integer);id:=coalesce((d->'next_ids'->>'entry')::integer,0)+1;d:=jsonb_set(d,'{next_ids,entry}',to_jsonb(id));
 r:=jsonb_build_object('id',id,'project_id',pr->'id','work_date',((t->>'started_at')::timestamptz at time zone 'Europe/Amsterdam')::date,'description',t->>'description','minutes',mins,'rate_cents',pr->'rate_cents','currency',pr->>'currency','billable',1,'invoice_id',null,'created_at',now(),'start_time','','end_time','','break_minutes',0,'next_day',0,'input_mode','duration');d:=jsonb_set(jsonb_set(d,'{entries}',d->'entries'||jsonb_build_array(r)),'{timer}','null');
 when 'timer_cancel' then d:=jsonb_set(d,'{timer}','null');
 when 'invoice' then
 ids:=p_payload->'entry_ids';if jsonb_typeof(ids) is distinct from 'array' or jsonb_array_length(ids) not between 1 and 500 then raise exception 'Selecteer 1 tot 500 urenregels.';end if;
 if (select count(distinct value) from jsonb_array_elements_text(ids))<>jsonb_array_length(ids) then raise exception 'Dubbele urenregels geselecteerd.';end if;
 rows:='[]';cid:=null;cur:=null;
 for e in select z from jsonb_array_elements(d->'entries') z where z->'id' in (select value from jsonb_array_elements(ids)) order by z->>'work_date',(z->>'id')::integer loop
 if e->>'invoice_id' is not null or (e->>'billable')::integer<>1 then raise exception 'Een urenregel is niet declarabel of al gekoppeld.';end if;
 pr:=portal_private.billing_item(d->'projects',(e->>'project_id')::integer);
 if cid is null then cid:=(pr->>'client_id')::integer;cur:=e->>'currency';elsif cid<>(pr->>'client_id')::integer or cur<>e->>'currency' then raise exception 'Kies uren van één klant en één valuta.';end if;
 rate:=round((e->>'minutes')::numeric*(e->>'rate_cents')::numeric/60)::bigint;subtotal:=subtotal+rate;
 r:=e||jsonb_build_object('client_id',cid,'project_name',pr->>'name','total_cents',rate);
 if p_payload->'descriptions' ? (e->>'id') then v:=trim(coalesce(p_payload->'descriptions'->>(e->>'id'),''));if v='' or length(v)>6000 then raise exception 'Vul een geldige factuuromschrijving in.';end if;r:=r||jsonb_build_object('original_description',e->>'description','description',v);end if;
 rows:=rows||jsonb_build_array(r);end loop;
 if jsonb_array_length(rows)<>jsonb_array_length(ids) then raise exception 'Een urenregel is gewijzigd. Ververs de pagina.';end if;
 cl:=portal_private.billing_item(d->'clients',cid);mode:=p_payload->>'tax_mode';if mode is null or mode not in ('21','9','0','reverse','exempt') then raise exception 'Kies de btw-behandeling.';end if;
 lang:=coalesce(p_payload->>'language',cl->>'language','nl');if lang not in ('nl','en','de') then raise exception 'Ongeldige factuurtaal.';end if;
 v:=trim(coalesce(p_payload->>'tax_note',''));if mode in ('0','reverse','exempt') and v='' then raise exception 'Vul de btw-toelichting in.';end if;
 if mode='reverse' and trim(coalesce(cl->>'vat',''))='' then raise exception 'Vul voor btw-verlegging eerst het VAT-nummer van de klant in.';end if;
 tax:=case when mode in ('21','9','0') then mode::numeric else 0 end;vat:=round(subtotal*tax/100)::bigint;
 if cur='USD' and vat>0 then
 if coalesce(p_payload->>'fx_rate','') !~ '^[0-9]+([.][0-9]{1,8})?$' then raise exception 'Vul de EUR-waarde van 1 USD in.';end if;
 fx:=(p_payload->>'fx_rate')::numeric;if fx<=0 or fx>100 or trim(coalesce(p_payload->>'fx_source',''))='' then raise exception 'Controleer de wisselkoers, bron en koersdatum.';end if;end if;
 issue:=(p_payload->>'issue_date')::date;due:=(p_payload->>'due_date')::date;if issue is null or due is null or due<issue then raise exception 'Controleer factuur- en vervaldatum.';end if;
 sn:=jsonb_build_object('language',lang,'issuer',cfg,'client',cl,'lines',rows,'issue_date',issue,'due_date',due,'currency',cur,'reference',coalesce(p_payload->>'reference',''),'tax_mode',mode,'tax_rate',tax::text,'tax_note',v,'subtotal_cents',subtotal,'vat_cents',vat,'total_cents',subtotal+vat,'vat_eur_cents',case when cur='EUR' then vat else coalesce(round(vat*fx)::bigint,0) end,'fx_rate',coalesce(fx::text,''),'fx_source',coalesce(p_payload->>'fx_source',''),'note',coalesce(p_payload->>'note',''));
 id:=coalesce((d->'next_ids'->>'invoice')::integer,0)+1;d:=jsonb_set(d,'{next_ids,invoice}',to_jsonb(id));
 r:=jsonb_build_object('id',id,'number','CONCEPT-'||id,'status','draft','currency',cur,'client_id',cid,'snapshot',sn,'created_at',now(),'doc_type','invoice');d:=jsonb_set(d,'{invoices}',d->'invoices'||jsonb_build_array(r));
 select jsonb_agg(case when z->'id' in (select value from jsonb_array_elements(ids)) then z||jsonb_build_object('invoice_id',id) else z end order by n) into rows from jsonb_array_elements(d->'entries') with ordinality t(z,n);d:=jsonb_set(d,'{entries}',rows);resultid:=id;
 when 'invoice_delete' then
 old:=portal_private.billing_item(d->'invoices',id);if old->>'status'<>'draft' then raise exception 'Alleen een concept kan worden verwijderd.';end if;
 select coalesce(jsonb_agg(z order by n),'[]') into rows from jsonb_array_elements(d->'invoices') with ordinality t(z,n) where (z->>'id')::integer<>id;d:=jsonb_set(d,'{invoices}',rows);
 select coalesce(jsonb_agg(case when (z->>'invoice_id')::integer=id then z||jsonb_build_object('invoice_id',null) else z end order by n),'[]') into rows from jsonb_array_elements(d->'entries') with ordinality t(z,n);d:=jsonb_set(d,'{entries}',rows);
 when 'prepare_issue' then
 old:=portal_private.billing_item(d->'invoices',id);if old->>'status'='pending_pdf' then return jsonb_build_object('invoice_id',id,'revision',w.revision);end if;
 if old->>'status'<>'draft' then raise exception 'Deze factuur is al vastgelegd.';end if;
 sn:=old->'snapshot';foreach key in array array['name','address','country','kvk','vat'] loop if trim(coalesce(sn->'issuer'->>key,''))='' then raise exception 'Vul eerst de factuurafzender volledig in: %',key;end if;end loop;
 if trim(coalesce(sn->'issuer'->>case when old->>'currency'='EUR' then 'eur_bank' else 'usd_bank' end,''))='' then raise exception 'Vul eerst de betaalgegevens voor deze valuta in. Maak daarna een nieuw concept.';end if;
 yr:=extract(year from (sn->>'issue_date')::date);key:=yr::text;insert into public.admin_billing_counters(issuer_registration,year,value) values(sn->'issuer'->>'kvk',yr,1) on conflict(issuer_registration,year) do update set value=public.admin_billing_counters.value+1 returning value into num;d:=jsonb_set(d,array['counters',key],to_jsonb(num));number:='LCE-'||key||'-'||lpad(num::text,4,'0');
 r:=old||jsonb_build_object('number',number,'status','pending_pdf','reserved_at',now());d:=jsonb_set(d,'{invoices}',portal_private.billing_replace(d->'invoices',r));resultid:=id;
 when 'finalize_issue' then
 old:=portal_private.billing_item(d->'invoices',id);if old->>'status'<>'pending_pdf' then raise exception 'De factuur is niet gereed voor PDF-vastlegging.';end if;
 if length(coalesce(p_payload->>'pdf','')) not between 100 and 10000000 then raise exception 'Definitieve PDF ontbreekt of is te groot.';end if;
 raw:=decode(p_payload->>'pdf','base64');if substring(raw from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Ongeldige PDF.';end if;
 insert into public.admin_billing_pdfs(owner,invoice_id,pdf_base64,pdf_sha256) values(uid,id,p_payload->>'pdf',encode(sha256(raw),'hex'));
 r:=old||jsonb_build_object('status','issued','issued_at',now(),'pdf_sha256',encode(sha256(raw),'hex'));d:=jsonb_set(d,'{invoices}',portal_private.billing_replace(d->'invoices',r));resultid:=id;
 when 'invoice_paid' then
 old:=portal_private.billing_item(d->'invoices',id);if old->>'status'<>'issued' or old->>'doc_type'='credit' then raise exception 'Alleen een uitgereikte factuur kan als betaald worden gemarkeerd.';end if;r:=old||jsonb_build_object('status','paid','paid_at',now());d:=jsonb_set(d,'{invoices}',portal_private.billing_replace(d->'invoices',r));
 when 'credit' then
 old:=portal_private.billing_item(d->'invoices',id);if old->>'status' not in ('issued','paid') or old->>'doc_type'='credit' then raise exception 'Alleen een gewone uitgereikte factuur kan worden gecrediteerd.';end if;
 if exists(select 1 from jsonb_array_elements(d->'invoices') z where z->>'original_id'=id::text) then raise exception 'Voor deze factuur bestaat al een creditnota.';end if;
 v:=trim(coalesce(p_payload->>'reason',''));if v='' or length(v)>6000 then raise exception 'Vul de reden voor de volledige creditnota in.';end if;
 sn:=old->'snapshot';select jsonb_agg(z||jsonb_build_object('minutes',-(z->>'minutes')::integer,'total_cents',-(z->>'total_cents')::bigint) order by n) into rows from jsonb_array_elements(sn->'lines') with ordinality t(z,n);
 sn:=sn||jsonb_build_object('lines',rows,'issue_date',(now() at time zone 'Europe/Amsterdam')::date,'due_date',(now() at time zone 'Europe/Amsterdam')::date,'reference',old->>'number','note',v,'subtotal_cents',-(sn->>'subtotal_cents')::bigint,'vat_cents',-(sn->>'vat_cents')::bigint,'total_cents',-(sn->>'total_cents')::bigint,'vat_eur_cents',-(sn->>'vat_eur_cents')::bigint,'doc_type','credit','original_number',old->>'number');
 resultid:=coalesce((d->'next_ids'->>'invoice')::integer,0)+1;d:=jsonb_set(d,'{next_ids,invoice}',to_jsonb(resultid));r:=jsonb_build_object('id',resultid,'number','CONCEPT-'||resultid,'status','draft','currency',old->>'currency','client_id',old->'client_id','snapshot',sn,'created_at',now(),'doc_type','credit','original_id',id);d:=jsonb_set(d,'{invoices}',d->'invoices'||jsonb_build_array(r));
 else raise exception 'Onbekende administratie-actie.';end case;
 -- Finalising a full credit preserves the original record and releases its hours for correction.
 if p_action='finalize_issue' and r->>'doc_type'='credit' then
 old:=portal_private.billing_item(d->'invoices',(r->>'original_id')::integer);old:=old||jsonb_build_object('status','credited','credited_by',id,'previous_status',old->>'status');d:=jsonb_set(d,'{invoices}',portal_private.billing_replace(d->'invoices',old));
 select coalesce(jsonb_agg(case when z->>'invoice_id'=r->>'original_id' then z||jsonb_build_object('invoice_id',null) else z end order by n),'[]') into rows from jsonb_array_elements(d->'entries') with ordinality t(z,n);d:=jsonb_set(d,'{entries}',rows);end if;
 update public.admin_billing_workspaces set data=d,revision=revision+1,updated_at=now() where owner=uid returning revision into num;
 insert into public.admin_billing_events(owner,action,entity_id,revision) values(uid,p_action,coalesce(resultid,id),num);
 return jsonb_build_object('ok',true,'invoice_id',resultid,'revision',num);
end;$$;
revoke all on function public.billing_action(text,integer,jsonb) from public,anon;
grant execute on function public.billing_action(text,integer,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
