begin;
drop policy commission_read on public.commission_agreements;
create policy commission_read on public.commission_agreements for select to authenticated using((select portal_private.is_admin()) or (recipient=(select auth.uid()) and (select portal_private.is_active()) and (status<>'draft' or coalesce(data->>'draft_shared','false')='true')));
create or replace function public.commission_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}'::jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.commission_agreements;d jsonb;v jsonb;uid uuid:=auth.uid();adm boolean;email text;recipient_id uuid;y integer;n integer;k text;method text;fields text[];new_id uuid;pdf_bytes bytea;client_id uuid;signing public.portal_signing_profiles;person public.portal_companies;identity jsonb;
begin
 if uid is null or not portal_private.is_active() then raise exception 'Active portal membership required';end if;
 adm:=portal_private.is_admin();select m.email into email from public.portal_members m where m.user_id=uid;
 if length(p_payload::text)>10000000 then raise exception 'Request too large';end if;
 if p_action='create' then
  if not adm then raise exception 'Administrator required';end if;
  recipient_id:=(p_payload->>'recipient')::uuid;
  if not exists(select 1 from public.portal_members m where m.user_id=recipient_id and m.active and not m.is_admin) then raise exception 'Select an active registered client';end if;
  client_id:=coalesce((p_payload->>'client_user_id')::uuid,recipient_id);
  if client_id<>recipient_id and not exists(select 1 from public.portal_broker_clients where client_user_id=client_id and broker_user_id=recipient_id and active) then raise exception 'Link the broker to this client first';end if;
  y:=extract(year from now() at time zone 'Europe/Amsterdam');
  insert into public.commission_counters(year,value) values(y,1) on conflict(year) do update set value=public.commission_counters.value+1 returning value into n;
  d:='{}';foreach k in array array['title','services','scope','covered','formula','trigger','deadline'] loop d:=d||jsonb_build_object(k,left(trim(coalesce(p_payload->>k,'')),2000));end loop;
  d:=d||jsonb_build_object('transaction','VIP-COM-'||y||'-'||n::text,'terms_version','2026-10-22');
  insert into public.commission_agreements(recipient,client_user_id,transaction_code,data) values(recipient_id,client_id,d->>'transaction',d) returning * into a;
 else
  select * into a from public.commission_agreements where id=p_id for update;
  if not found or (not adm and (a.recipient<>uid or (a.status='draft' and coalesce(a.data->>'draft_shared','false')<>'true'))) then raise exception 'Agreement not found';end if;
  if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;
  d:=a.data;
  if p_action in ('save','issue','approve','cancel','revise','share_draft','unshare_draft') and not adm then raise exception 'Administrator required';end if;
  if p_action in ('client-save','sign') and (adm or a.recipient<>uid or a.status<>'awaiting_client') then raise exception 'Client action unavailable';end if;
  case p_action
  when 'share_draft' then
   if a.status<>'draft' then raise exception 'Only drafts may be shared';end if;
   if not exists(select 1 from public.portal_members where user_id=a.recipient and active and not is_admin) then raise exception 'Active client required';end if;
   d:=d||jsonb_build_object('draft_shared',true,'draft_shared_at',now());
  when 'unshare_draft' then
   if a.status<>'draft' then raise exception 'Only draft review access may be withdrawn';end if;
   d:=d-'draft_shared'-'draft_shared_at';
  when 'save' then
   if a.status<>'draft' then raise exception 'Only drafts can be edited';end if;d:=d-'draft_shared'-'draft_shared_at';
   foreach k in array array['title','services','scope','covered','formula','trigger','deadline'] loop d:=d||jsonb_build_object(k,left(trim(coalesce(p_payload->>k,'')),2000));end loop;
  when 'issue' then
   if a.status<>'draft' then raise exception 'Only drafts can be issued';end if;
   foreach k in array array['title','services','scope','covered','formula','trigger','deadline'] loop if trim(coalesce(d->>k,''))='' then raise exception 'Complete all commercial fields';end if;end loop;
   if d->>'deadline' !~ '^[0-9]{1,3}$' or (d->>'deadline')::integer not between 1 and 365 then raise exception 'Deadline must be 1 to 365 business days';end if;
   if not exists(select 1 from public.portal_members m where m.user_id=a.recipient and m.active) then raise exception 'Client access is disabled';end if;
   a.status:='awaiting_client';
  when 'client-save' then
   foreach k in array array['legal_name','registration','address','country','representative','role','email','method'] loop
    if jsonb_typeof(p_payload->k) is distinct from 'string' or length(p_payload->>k)>500 then raise exception 'Invalid client details';end if;
    d:=d||jsonb_build_object(k,trim(p_payload->>k));end loop;
   select c.* into person from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=uid;
   if person.details->>'ACCOUNT_TYPE'='individual' then d:=d||jsonb_build_object('account_type','individual','legal_name',person.details->>'B_COMPANY','representative',person.details->>'B_REPRESENTATIVE','address',person.details->>'B_ADDRESS','country',person.details->>'B_COUNTRY','registration','Not applicable - private individual','role','Private individual');end if;
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose bank or crypto';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   v:='{}';foreach k in array fields loop
    if ((p_payload->'payment') ? k) and (jsonb_typeof(p_payload->'payment'->k) is distinct from 'string' or length(p_payload->'payment'->>k)>1000) then raise exception 'Invalid payment details';end if;
    v:=v||jsonb_build_object(k,trim(coalesce(p_payload->'payment'->>k,'')));end loop;d:=d||jsonb_build_object('payment',v);
  when 'sign' then
   select c.* into person from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=uid;
   if person.details->>'ACCOUNT_TYPE'='individual' then
    identity:=public.individual_identity(uid,null);if identity->>'copy_path' is null then raise exception 'Upload your signed passport copy in your profile before signing';end if;
    if d->>'legal_name' is distinct from person.details->>'B_COMPANY' or d->>'representative' is distinct from person.details->>'B_REPRESENTATIVE' then raise exception 'Save current personal profile details before signing';end if;
   end if;

   foreach k in array array['legal_name','registration','address','country','representative','role','email','method'] loop if trim(coalesce(d->>k,''))='' then raise exception 'Complete client details';end if;end loop;
   if d->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email';end if;
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose a payment method';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   foreach k in array fields loop if ((method='bank' and k not in ('routing','intermediary')) or (method='crypto' and k in ('wallet','network'))) and trim(coalesce(d->'payment'->>k,''))='' then raise exception 'Complete the required payment details';end if;end loop;
   if p_payload->'authority' is distinct from 'true'::jsonb or p_payload->'accept' is distinct from 'true'::jsonb or p_payload->>'name' is distinct from d->>'representative' or p_payload->'reviewed' is distinct from 'true'::jsonb then raise exception 'Review the agreement and confirm authority, name and acceptance';end if;
   select * into signing from public.portal_signing_profiles where user_id=uid for share;
   if not found then raise exception 'Save your private signature and company stamp before signing';end if;
   if p_payload->'use_saved_assets' is distinct from 'true'::jsonb or p_payload->>'asset_version' is distinct from signing.version::text then raise exception 'Review your saved signing images and explicitly authorize their use for this agreement';end if;
   d:=d||jsonb_build_object('beneficiary_signing_assets',jsonb_build_object('signature',signing.signature,'stamp',signing.stamp,'version',signing.version,'confirmed_at',now(),'confirmed_by',uid));
   d:=d||jsonb_build_object('signed_payload_hash',encode(sha256(convert_to(d::text,'UTF8')),'hex'),'client_signature',jsonb_build_object('name',p_payload->>'name','at',now(),'account',email,'user_id',uid,'authority',true,'accepted',true,'method','typed name with authenticated portal acceptance'));
   a.status:='awaiting_approval';
  when 'approve' then
   if a.status<>'awaiting_approval' or p_payload->'verified' is distinct from 'true'::jsonb then raise exception 'Review beneficiary and verify payment instructions before approval';end if;
   if not exists(select 1 from public.commission_assets where name='signature') or not exists(select 1 from public.commission_assets where name='stamp') then raise exception 'Signature assets are not configured';end if;
   if length(coalesce(p_payload->>'pdf','')) not between 100 and 8000000 then raise exception 'Final PDF required';end if;
   pdf_bytes:=decode(p_payload->>'pdf','base64');if substring(pdf_bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid PDF';end if;
   insert into public.commission_final_pdfs values(a.id,p_payload->>'pdf',encode(sha256(pdf_bytes),'hex'));
   d:=d||jsonb_build_object('approved_at',now(),'approved_by',email,'approved_user_id',uid,'pdf_sha256',encode(sha256(pdf_bytes),'hex'));
   a.status:='completed';
  when 'cancel' then
   if a.status in ('completed','cancelled') then raise exception 'Completed records cannot be cancelled';end if;a.status:='cancelled';
  when 'revise' then
   if a.status not in ('completed','cancelled','awaiting_approval') then raise exception 'Revision unavailable';end if;
   v:='{}';foreach k in array array['title','services','scope','covered','formula','trigger','deadline','transaction','terms_version'] loop v:=v||jsonb_build_object(k,d->k);end loop;
   v:=v||jsonb_build_object('previous_id',a.id);
   insert into public.commission_agreements(recipient,client_user_id,version,transaction_code,data) values(a.recipient,a.client_user_id,a.version+1,a.transaction_code,v) returning id into new_id;
   insert into public.commission_events(agreement_id,actor,actor_email,event) values(new_id,uid,email,'revision_created');return new_id;
  else raise exception 'Unknown action';end case;
  update public.commission_agreements set status=a.status,data=d,revision=revision+1,updated_at=now() where id=a.id;
 end if;
 insert into public.commission_events(agreement_id,actor,actor_email,event) values(a.id,uid,email,p_action);return a.id;
end;$$;

alter table public.portal_mcnda_assignments drop constraint portal_mcnda_assignments_status_check;
alter table public.portal_mcnda_assignments add constraint portal_mcnda_assignments_status_check check(status in ('draft_review','assigned','completed','cancelled'));
drop index public.mcnda_one_pending;
create unique index mcnda_one_pending on public.portal_mcnda_assignments(user_id) where status in ('draft_review','assigned');
create function public.mcnda_review_assignment(p_action text,p_id uuid default null,p_user_id uuid default null,p_client_user_id uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.portal_mcnda_assignments; result uuid;
begin
 if not portal_private.is_admin() then raise exception 'Administrator required';end if;
 if p_action='share_draft' then
 if p_user_id is null or p_client_user_id is null then raise exception 'Select a signer and client';end if;
 if not exists(select 1 from public.portal_members where user_id=p_user_id and active and not is_admin) then raise exception 'Active signer required';end if;
 if not exists(select 1 from public.portal_members where user_id=p_client_user_id and active and not is_admin) then raise exception 'Active client required';end if;
 if p_user_id<>p_client_user_id and not exists(select 1 from public.portal_broker_clients where client_user_id=p_client_user_id and broker_user_id=p_user_id and active) then raise exception 'Link this broker first';end if;
 insert into public.portal_mcnda_assignments(user_id,client_user_id,status,assigned_by) values(p_user_id,p_client_user_id,'draft_review',auth.uid()) returning id into result;
 return result;
 end if;
 select * into a from public.portal_mcnda_assignments where id=p_id for update;
 if not found or a.status<>'draft_review' then raise exception 'A draft review assignment is required';end if;
 if p_action='release' then
 if not exists(select 1 from public.portal_members where user_id=a.user_id and active and not is_admin) then raise exception 'Active signer required';end if;
 update public.portal_mcnda_assignments set status='assigned' where id=a.id;
 elsif p_action='withdraw' then
 update public.portal_mcnda_assignments set status='cancelled' where id=a.id;
 else raise exception 'Unknown action';end if;
 return a.id;
end;$$;
revoke all on function public.mcnda_review_assignment(text,uuid,uuid,uuid) from public,anon;
grant execute on function public.mcnda_review_assignment(text,uuid,uuid,uuid) to authenticated;
drop policy nda_template_member_read on storage.objects;
create policy nda_template_member_read on storage.objects for select to authenticated using(bucket_id='vip-documents' and name='nda-template-v20261020.pdf' and ((select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(select 1 from public.portal_mcnda_assignments where user_id=(select auth.uid()) and status in ('draft_review','assigned')))));
alter table public.portal_document_notifications drop constraint if exists portal_document_notifications_kind_check;
alter table public.portal_document_notifications add constraint portal_document_notifications_kind_check check(kind in('document','mcnda','commission','spa','fco','jv'));
alter table public.portal_document_notifications add column if not exists event text not null default 'released';
alter table public.portal_document_notifications add column if not exists document_version text;
alter table public.portal_document_notifications drop constraint if exists portal_document_notifications_event_check;
alter table public.portal_document_notifications add constraint portal_document_notifications_event_check check(event in('available','draft_review','released','client_signed','completed','withdrawn','cancelled'));

create or replace function portal_private.queue_document_event(p_client uuid,p_kind text,p_entity uuid,p_version text,p_revision text,p_event text,p_title text) returns void language plpgsql security definer set search_path='' as $$
declare r record;
begin
 for r in select user_id from public.portal_members where active and ((p_event='client_signed' and is_admin) or (p_event<>'client_signed' and not is_admin and user_id=p_client)) loop
 insert into public.portal_document_notifications(recipient,kind,entity_id,version_key,document_version,event,title)
 values(r.user_id,p_kind,p_entity,p_version||':'||p_event||':'||p_revision,p_version,p_event,left(p_title,200)) on conflict do nothing;
 end loop;
 begin perform portal_private.dispatch_document_notifications();exception when others then null;end;
end;$$;
revoke all on function portal_private.queue_document_event(uuid,text,uuid,text,text,text,text) from public,anon,authenticated;

create or replace function portal_private.notify_assigned_agreement() returns trigger language plpgsql security definer set search_path='' as $$
declare k text;v text;rev text;client uuid;ev text;t text;o jsonb:='{}';d jsonb:=to_jsonb(new);
begin
 if tg_op='UPDATE' then o:=to_jsonb(old);end if;
 if tg_table_name='portal_mcnda_assignments' then
 k:='mcnda';client:=new.user_id;v:=new.template_version;rev:=coalesce(d->>'assigned_at','');t:='MCNDA';
 if new.status='draft_review' and o->>'status' is distinct from 'draft_review' then ev:='draft_review';
 elsif new.status='assigned' and o->>'status' is distinct from 'assigned' then ev:='released';
 elsif new.status='cancelled' and o->>'status'='draft_review' then ev:='withdrawn';
 elsif new.status='cancelled' and o->>'status'='assigned' then ev:='cancelled';
 end if;
 else
 k:=case tg_table_name when 'commission_agreements' then 'commission' when 'spa_agreements' then 'spa' when 'fco_agreements' then 'fco' when 'jv_agreements' then 'jv' end;
 if k is null then return new;end if;
 client:=new.recipient;v:=new.version::text;rev:=coalesce(d->>'revision','1');t:=case k when 'commission' then 'Commission Agreement' when 'spa' then 'SPA' when 'fco' then 'FCO' when 'jv' then 'JVA' end||' | '||new.transaction_code;
 if new.status='awaiting_client' and o->>'status' is distinct from 'awaiting_client' then ev:='released';
 elsif new.status='awaiting_approval' and o->>'status' is distinct from 'awaiting_approval' then ev:='client_signed';
 elsif new.status='completed' and o->>'status' is distinct from 'completed' then ev:='completed';
 elsif new.status='cancelled' and (coalesce(o->>'status','draft')<>'draft' or o->'data'->>'draft_shared'='true') then ev:='cancelled';
 elsif new.status='draft' and d->'data'->>'draft_shared'='true' and (o->>'status' is distinct from 'draft' or o->'data'->>'draft_shared' is distinct from 'true') then ev:='draft_review';
 elsif new.status='draft' and coalesce(d->'data'->>'draft_shared','false')<>'true' and o->'data'->>'draft_shared'='true' then ev:='withdrawn';
 end if;
 end if;
 if ev is not null then perform portal_private.queue_document_event(client,k,new.id,v,rev,ev,t);end if;
 return new;
end;$$;
revoke all on function portal_private.notify_assigned_agreement() from public,anon,authenticated;
drop trigger if exists notify_mcnda_assignment on public.portal_mcnda_assignments;
drop trigger if exists notify_commission_assignment on public.commission_agreements;
create trigger notify_mcnda_assignment after insert or update of status on public.portal_mcnda_assignments for each row execute function portal_private.notify_assigned_agreement();
create trigger notify_commission_assignment after insert or update of status,data on public.commission_agreements for each row execute function portal_private.notify_assigned_agreement();

create or replace function portal_private.notify_mcnda_approval_event() returns trigger language plpgsql security definer set search_path='' as $$
declare a public.portal_mcnda_assignments;ev text;
begin
 select * into a from public.portal_mcnda_assignments where id=new.id;
 if tg_op='INSERT' and new.status='awaiting_approval' then ev:='client_signed';
 elsif tg_op='UPDATE' and new.status='completed' and old.status is distinct from 'completed' then ev:='completed';end if;
 if ev is not null then perform portal_private.queue_document_event(new.recipient,'mcnda',new.id,a.template_version,new.revision::text,ev,'MCNDA');end if;
 return new;
end;$$;
revoke all on function portal_private.notify_mcnda_approval_event() from public,anon,authenticated;
drop trigger if exists notify_mcnda_approval_event on public.portal_mcnda_approvals;
create trigger notify_mcnda_approval_event after insert or update of status on public.portal_mcnda_approvals for each row execute function portal_private.notify_mcnda_approval_event();

create or replace function public.document_notification_context(p_id uuid,p_lease uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.portal_document_notifications;m public.portal_members;a jsonb;ap jsonb;allowed boolean;owner_id uuid;table_name text;url text:='https://vipcapital.eu/documents.html';v text;st text;test_to text;
begin
 select * into n from public.portal_document_notifications where id=p_id and lease=p_lease and leased_at>now()-interval '5 minutes' and sent_at is null and skipped_at is null;
 if not found then raise exception 'No active delivery lease';end if;
 select * into m from public.portal_members where user_id=n.recipient;
 allowed:=coalesce(m.active,false);v:=coalesce(n.document_version,n.version_key);
 if n.kind='document' then
 allowed:=allowed and not m.is_admin and exists(select 1 from public.portal_document_access g join public.portal_documents d on d.id=g.document_id where g.user_id=n.recipient and d.id=n.entity_id and d.published and coalesce(d.storage_path,'')||':'||coalesce(d.version_date::text,'')=v);
 owner_id:=n.recipient;
 else
 if n.kind='mcnda' then
 select to_jsonb(x) into a from public.portal_mcnda_assignments x where id=n.entity_id;
 select to_jsonb(x) into ap from public.portal_mcnda_approvals x where id=n.entity_id;
 owner_id:=(a->>'user_id')::uuid;st:=case when n.event in('client_signed','completed') then ap->>'status' else a->>'status' end;
 allowed:=allowed and a->>'template_version'=v;
 else
 table_name:=case n.kind when 'commission' then 'commission_agreements' when 'spa' then 'spa_agreements' when 'fco' then 'fco_agreements' when 'jv' then 'jv_agreements' end;
 if table_name is null then raise exception 'Unsupported document type';end if;
 execute format('select to_jsonb(a) from public.%I a where id=$1',table_name) into a using n.entity_id;
 owner_id:=(a->>'recipient')::uuid;st:=a->>'status';allowed:=allowed and a->>'version'=v;
 end if;
 allowed:=allowed and case n.event
 when 'draft_review' then (st='draft_review' or (st='draft' and a->'data'->>'draft_shared'='true'))
 when 'released' then st in('assigned','awaiting_client')
 when 'client_signed' then st='awaiting_approval'
 when 'completed' then st='completed'
 when 'withdrawn' then (n.kind='mcnda' and st='cancelled') or (st='draft' and coalesce(a->'data'->>'draft_shared','false')<>'true')
 when 'cancelled' then st='cancelled'
 else false end;
 if n.event='client_signed' then
 allowed:=allowed and m.is_admin;
 url:='https://vipcapital.eu/client-files.html?client='||coalesce(a->>'client_user_id',owner_id::text);
 else allowed:=allowed and not m.is_admin and owner_id=n.recipient;
 end if;
 end if;
 if not m.is_admin and exists(select 1 from public.portal_company_members cm join public.portal_companies c on c.id=cm.company_id where cm.user_id=n.recipient and c.access_state is distinct from 'active') then allowed:=false;end if;
 -- Test overrides exist only for database-created test entities and expire automatically.
 return jsonb_build_object('allowed',coalesce(allowed,false),'email',case when allowed then m.email else null end,'url',url,'event',case when n.kind='document' then 'available' else n.event end,'needs_signature',n.event='released' and n.kind<>'document','test',false);
end;$$;
revoke all on function public.document_notification_context(uuid,uuid) from public,anon,authenticated;
grant execute on function public.document_notification_context(uuid,uuid) to service_role;
create or replace function portal_private.queue_upload_notification() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.title ~* '^MCNDA[[:space:]]*-' and new.note like 'Completed and electronically signed via the VIP Capital portal. Awaiting explicit VIP Capital countersignature.%' then return new;end if;
 insert into public.portal_upload_notifications(submission_id) values(new.id) on conflict do nothing;
 begin perform portal_private.dispatch_upload_notifications();exception when others then update public.portal_upload_notifications set last_error='Dispatch unavailable; queued for retry' where submission_id=new.id;end;
 return new;
end;$$;
create table public.portal_language_preferences(user_id uuid primary key references public.portal_members(user_id),language text not null check(language in('en','nl','de','es','ar')),updated_at timestamptz not null default now());
alter table public.portal_language_preferences enable row level security;
revoke all on public.portal_language_preferences from public,anon,authenticated;
grant select on public.portal_language_preferences to authenticated;
create policy language_own_read on public.portal_language_preferences for select to authenticated using(user_id=(select auth.uid()) and (select portal_private.is_active()));
create function public.my_portal_language() returns text language sql security definer set search_path='' as $$ select coalesce((select language from public.portal_language_preferences where user_id=auth.uid()),(select case when raw_user_meta_data->>'language' in('en','nl','de','es','ar') then raw_user_meta_data->>'language' end from auth.users where id=auth.uid())) where (select portal_private.is_active()); $$;
revoke all on function public.my_portal_language() from public,anon;
grant execute on function public.my_portal_language() to authenticated;
create function public.save_my_portal_language(p_language text) returns text language plpgsql security definer set search_path='' as $$
begin
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 if p_language is null or p_language not in('en','nl','de','es','ar') then raise exception 'Select a supported language';end if;
 insert into public.portal_language_preferences(user_id,language) values(auth.uid(),p_language) on conflict(user_id) do update set language=excluded.language,updated_at=now();
 update auth.users set raw_user_meta_data=coalesce(raw_user_meta_data,'{}'::jsonb)||jsonb_build_object('language',p_language) where id=auth.uid();
 return p_language;
end;$$;
revoke all on function public.save_my_portal_language(text) from public,anon;
grant execute on function public.save_my_portal_language(text) to authenticated;
create function public.mail_language_for_email(p_email text) returns text language sql security definer set search_path='' as $$
 select coalesce((select p.language from public.portal_language_preferences p join public.portal_members m on m.user_id=p.user_id where lower(m.email)=lower(p_email)),(select u.raw_user_meta_data->>'language' from auth.users u where lower(u.email)=lower(p_email) and u.raw_user_meta_data->>'language' in('en','nl','de','es','ar')),'en');
$$;
revoke all on function public.mail_language_for_email(text) from public,anon,authenticated;
grant execute on function public.mail_language_for_email(text) to service_role;
-- Authentication metadata is only a presentation preference, never an access claim.
create function portal_private.capture_invited_language() returns trigger language plpgsql security definer set search_path='' as $$
declare pref text;
begin
 select raw_user_meta_data->>'language' into pref from auth.users where id=new.user_id;
 if pref in('en','nl','de','es','ar') then insert into public.portal_language_preferences(user_id,language) values(new.user_id,pref) on conflict do nothing;end if;
 return new;
end;$$;
revoke all on function portal_private.capture_invited_language() from public,anon,authenticated;
create trigger capture_invited_language after insert on public.portal_members for each row execute function portal_private.capture_invited_language();
-- Preserve all existing registration validation and throttling.
alter function public.register_access_request(jsonb,text,text) rename to register_access_request_before_languages;
revoke all on function public.register_access_request_before_languages(jsonb,text,text) from public,anon,authenticated,service_role;
create function public.register_access_request(p_details jsonb,p_message text,p_source_key text) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;pref text:=p_details->>'B_LANGUAGE';
begin
 if pref is not null and pref not in('en','nl','de','es','ar') then raise exception 'Select a supported language';end if;
 result:=public.register_access_request_before_languages(p_details,p_message,p_source_key);
 if result is not null and pref is not null then update public.portal_access_requests set details=details||jsonb_build_object('B_LANGUAGE',pref) where id=result;end if;
 return result;
end;$$;
revoke all on function public.register_access_request(jsonb,text,text) from public,anon,authenticated;
grant execute on function public.register_access_request(jsonb,text,text) to service_role;
-- Store the language on queued mail; retries retain the original language.
alter table public.portal_document_notifications add column language text check(language in('en','nl','de','es','ar'));
alter table public.portal_upload_notifications add column language text check(language in('en','nl','de','es','ar'));
create function portal_private.snapshot_mail_language() returns trigger language plpgsql security definer set search_path='' as $$
declare email text;
begin
 if tg_table_name='portal_document_notifications' then select m.email into email from public.portal_members m where m.user_id=new.recipient;else email:='info@vipcapital.eu';end if;
 if new.language is null then new.language:=public.mail_language_for_email(email);end if;return new;
end;$$;
revoke all on function portal_private.snapshot_mail_language() from public,anon,authenticated;
create trigger snapshot_document_language before insert on public.portal_document_notifications for each row execute function portal_private.snapshot_mail_language();
create trigger snapshot_upload_language before insert on public.portal_upload_notifications for each row execute function portal_private.snapshot_mail_language();
alter function public.document_notification_context(uuid,uuid) rename to document_notification_context_before_languages;
revoke all on function public.document_notification_context_before_languages(uuid,uuid) from public,anon,authenticated,service_role;
create function public.document_notification_context(p_id uuid,p_lease uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare ctx jsonb;pref text;
begin
 ctx:=public.document_notification_context_before_languages(p_id,p_lease);
 select coalesce(n.language,public.mail_language_for_email(m.email)) into pref from public.portal_document_notifications n join public.portal_members m on m.user_id=n.recipient where n.id=p_id and n.lease=p_lease;
 return ctx||jsonb_build_object('language',pref);
end;$$;
revoke all on function public.document_notification_context(uuid,uuid) from public,anon,authenticated;
grant execute on function public.document_notification_context(uuid,uuid) to service_role;
create function public.admin_client_language(p_user_id uuid) returns text language plpgsql security definer set search_path='' as $$
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator access required';end if;
 if not exists(select 1 from public.portal_members where user_id=p_user_id and not is_admin) then raise exception 'Client account not found';end if;
 return coalesce((select language from public.portal_language_preferences where user_id=p_user_id),(select case when raw_user_meta_data->>'language' in('en','nl','de','es','ar') then raw_user_meta_data->>'language' end from auth.users where id=p_user_id));
end;$$;
create function public.admin_save_client_language(p_user_id uuid,p_language text,p_expected_language text) returns text language plpgsql security definer set search_path='' as $$
declare previous text;
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator access required';end if;
 perform 1 from public.portal_members where user_id=p_user_id and not is_admin for update;
 if not found then raise exception 'Client account not found';end if;
 if p_language is null or p_language not in('en','nl','de','es','ar') then raise exception 'Select a supported language';end if;
 previous:=public.admin_client_language(p_user_id);
 if previous is distinct from p_expected_language then raise exception 'Language was changed. Refresh the client file and try again.';end if;
 insert into public.portal_language_preferences(user_id,language) values(p_user_id,p_language) on conflict(user_id) do update set language=excluded.language,updated_at=now();
 update auth.users set raw_user_meta_data=coalesce(raw_user_meta_data,'{}'::jsonb)||jsonb_build_object('language',p_language) where id=p_user_id;
 return p_language;
end;$$;
revoke all on function public.admin_client_language(uuid) from public,anon;
revoke all on function public.admin_save_client_language(uuid,text,text) from public,anon;
grant execute on function public.admin_client_language(uuid) to authenticated;
grant execute on function public.admin_save_client_language(uuid,text,text) to authenticated;
create table portal_private.individual_identity(request_id uuid primary key references public.portal_access_requests(id),passport_number text not null,copy_path text not null,created_at timestamptz not null default now());
alter table portal_private.individual_identity enable row level security;
revoke all on portal_private.individual_identity from public,anon,authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('vip-private-identity','vip-private-identity',false,4194304,array['application/pdf','image/jpeg','image/png']);
create function portal_private.can_read_identity(p_path text) returns boolean language sql stable security definer set search_path='' as $$
select (select portal_private.is_active()) and exists(select 1 from portal_private.individual_identity i join public.portal_access_requests r on r.id=i.request_id where i.copy_path=p_path and ((select portal_private.is_admin()) or r.invited_user_id=auth.uid()));$$;
revoke all on function portal_private.can_read_identity(text) from public,anon;grant execute on function portal_private.can_read_identity(text) to authenticated;
create policy private_identity_read on storage.objects for select to authenticated using(bucket_id='vip-private-identity' and (select portal_private.can_read_identity(name)));
create function public.individual_identity(p_user_id uuid default null,p_request_id uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 if not (select portal_private.is_admin()) and (p_request_id is not null or p_user_id is distinct from auth.uid()) then raise exception 'Access denied';end if;
 select jsonb_build_object('passport_number',i.passport_number,'copy_path',i.copy_path) into result from portal_private.individual_identity i join public.portal_access_requests r on r.id=i.request_id where (p_request_id is not null and r.id=p_request_id) or (p_request_id is null and r.invited_user_id=p_user_id) limit 1;
 return result;
end;$$;
revoke all on function public.individual_identity(uuid,uuid) from public,anon;grant execute on function public.individual_identity(uuid,uuid) to authenticated;
-- The passport never enters general profile JSON, authentication metadata or notification payloads.
create function public.register_individual_access(p_details jsonb,p_message text,p_source_key text,p_passport text,p_copy_path text) returns uuid language plpgsql security definer set search_path='' as $$
declare new_request_id uuid;k text;
begin
 if p_details->>'ACCOUNT_TYPE' is distinct from 'individual' or length(trim(p_passport)) not between 3 and 30 then raise exception 'Invalid personal application';end if;
 foreach k in array array['P_FIRST_NAME','P_LAST_NAME','P_ADDRESS','P_POSTCODE','P_CITY','P_COUNTRY'] loop
 if trim(coalesce(p_details->>k,''))='' then raise exception 'Required personal detail missing';end if;end loop;
 if p_copy_path !~ '^[0-9a-f-]{36}\.(pdf|jpg|png)$' or not exists(select 1 from storage.objects where bucket_id='vip-private-identity' and name=p_copy_path) then raise exception 'Signed passport copy required';end if;
 new_request_id:=public.register_access_request(p_details,p_message,p_source_key);
 if new_request_id is not null then
 update public.portal_access_requests set details=details||jsonb_build_object('ACCOUNT_TYPE','individual','P_FIRST_NAME',p_details->>'P_FIRST_NAME','P_LAST_NAME',p_details->>'P_LAST_NAME','P_ADDRESS',p_details->>'P_ADDRESS','P_POSTCODE',p_details->>'P_POSTCODE','P_CITY',p_details->>'P_CITY','P_COUNTRY',p_details->>'P_COUNTRY') where portal_access_requests.id=new_request_id;
 insert into portal_private.individual_identity values(new_request_id,trim(p_passport),p_copy_path,now());
 end if;return new_request_id;
end;$$;
revoke all on function public.register_individual_access(jsonb,text,text,text,text) from public,anon,authenticated;grant execute on function public.register_individual_access(jsonb,text,text,text,text) to service_role;
create function portal_private.personal_profile_extra(p_details jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare result jsonb:='{}';k text;
begin
 if p_details->>'ACCOUNT_TYPE'='individual' then
 foreach k in array array['P_FIRST_NAME','P_LAST_NAME','P_ADDRESS','P_POSTCODE','P_CITY','P_COUNTRY'] loop
 if length(trim(coalesce(p_details->>k,'')))=0 or length(p_details->>k)>100 then raise exception 'Invalid personal profile';end if;result:=result||jsonb_build_object(k,trim(p_details->>k));end loop;
 result:=result||jsonb_build_object('ACCOUNT_TYPE','individual');end if;return result;
end;$$;
revoke all on function portal_private.personal_profile_extra(jsonb) from public,anon,authenticated;
create or replace function portal_private.save_company_details(p_details jsonb,p_expected_version integer) returns public.portal_companies
language plpgsql security definer set search_path='' as $$
declare company public.portal_companies; normalized jsonb;key text;max_length integer;stamp text;
begin
 if p_details->>'ACCOUNT_TYPE'='individual' and not exists(select 1 from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=auth.uid() and c.details->>'ACCOUNT_TYPE'='individual') then raise exception 'Individual account required';end if;
 if exists(select 1 from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=auth.uid() and c.details->>'ACCOUNT_TYPE'='individual') and p_details->>'ACCOUNT_TYPE' is distinct from 'individual' then raise exception 'Individual account type cannot be changed';end if;
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 -- Serialize first profile creation as well as edits for one account.
 perform 1 from public.portal_members where user_id=auth.uid() for update;
 normalized:='{}'::jsonb;
 foreach key in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL','B_WEBSITE'] loop
  if jsonb_typeof(p_details->key) is distinct from 'string' then raise exception 'Missing company detail: %',key;end if;
  max_length:=case key when 'B_ADDRESS' then 150 when 'B_REGISTRATION' then 60 when 'B_COUNTRY' then 60 when 'B_REPRESENTATIVE' then 80 when 'B_TITLE' then 80 when 'B_PHONE' then 50 else 100 end;
  if length(trim(p_details->>key))>max_length or (key<>'B_WEBSITE' and not (coalesce(p_details->>'ACCOUNT_TYPE','company')='individual' and key in('B_REGISTRATION','B_TITLE')) and length(trim(p_details->>key))=0) then raise exception 'Invalid company detail: %',key;end if;
  normalized:=normalized||jsonb_build_object(key,trim(p_details->>key));
 end loop;
 select c.* into company from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=auth.uid() for update of c;
 if coalesce(company.id::text,'') is distinct from coalesce(p_details->>'B_PROFILE_ID','') then raise exception 'Company link changed; refresh first';end if;
 stamp:=coalesce(p_details->>'B_STAMP_PATH','');
 if stamp<>'' then
  if stamp is distinct from coalesce(company.details->>'B_STAMP_PATH','') and stamp !~ ('^'||auth.uid()::text||'/[0-9a-f-]{36}\.png$') then raise exception 'Invalid company stamp';end if;
  if not exists(select 1 from storage.objects where bucket_id='vip-company-assets' and name=stamp) then raise exception 'Company stamp not found';end if;
 end if;
 normalized:=normalized||jsonb_build_object('B_STAMP_PATH',stamp)||portal_private.personal_profile_extra(p_details);
 if company.id is null then
  if p_expected_version<>0 then raise exception 'Profile changed; refresh first';end if;
  insert into public.portal_companies(details,created_by) values(normalized,auth.uid()) returning * into company;
  insert into public.portal_company_members(user_id,company_id) values(auth.uid(),company.id);
 else
  if company.version is distinct from p_expected_version then raise exception 'Profile changed; refresh first';end if;
  if company.details is distinct from normalized then
   update public.portal_companies set details=normalized,version=version+1,status='pending',approved_by=null,approved_at=null,updated_at=now() where id=company.id returning * into company;
  end if;
 end if;
 return company;
end;$$;
create or replace function public.admin_save_company_details(p_company_id uuid,p_expected_version integer,p_details jsonb) returns void language plpgsql security definer set search_path='' as $$
declare c public.portal_companies;normalized jsonb:='{}'::jsonb;k text;v text;max_length integer;changed text[]:='{}';
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 select * into c from public.portal_companies where id=p_company_id for update;
 if not found or c.version<>p_expected_version then raise exception 'Profile changed; refresh and try again';end if;
 if c.access_state='archived' then raise exception 'Restore this company before editing';end if;
 if coalesce(c.details->>'ACCOUNT_TYPE','company') is distinct from coalesce(p_details->>'ACCOUNT_TYPE','company') then raise exception 'Account type cannot be changed';end if;
 foreach k in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL','B_WEBSITE'] loop
  if jsonb_typeof(p_details->k) is distinct from 'string' then raise exception 'Missing company field';end if;
  v:=trim(p_details->>k);max_length:=case k when 'B_ADDRESS' then 150 when 'B_REGISTRATION' then 60 when 'B_COUNTRY' then 60 when 'B_REPRESENTATIVE' then 80 when 'B_TITLE' then 80 when 'B_PHONE' then 50 else 100 end;
  if length(v)>max_length or (k<>'B_WEBSITE' and not (coalesce(p_details->>'ACCOUNT_TYPE','company')='individual' and k in('B_REGISTRATION','B_TITLE')) and v='') then raise exception 'Complete all required company details';end if;
  if k='B_EMAIL' and v !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid business email';end if;
  normalized:=normalized||jsonb_build_object(k,v);
  if v is distinct from c.details->>k then changed:=array_append(changed,k);end if;
 end loop;
 normalized:=normalized||jsonb_build_object('B_STAMP_PATH',coalesce(c.details->>'B_STAMP_PATH',''))||portal_private.personal_profile_extra(p_details);
 if normalized is distinct from c.details then
  update public.portal_companies set details=normalized,version=version+1,status='pending',approved_by=null,approved_at=null,updated_at=now() where id=c.id;
  insert into public.portal_company_events(company_id,actor_id,event,metadata) values(c.id,auth.uid(),'details_updated',jsonb_build_object('version',c.version+1,'fields',changed));
 end if;
end;$$;
create or replace function public.approve_company_profile(p_company_id uuid,p_expected_version integer) returns void language plpgsql security definer set search_path='' as $$
declare details jsonb;k text;
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 select c.details into details from public.portal_companies c where c.id=p_company_id and c.version=p_expected_version for update;
 if not found then raise exception 'Profile changed; refresh first';end if;
 if exists(select 1 from public.portal_companies where id=p_company_id and access_state='archived') then raise exception 'Restore this company before approval';end if;
 foreach k in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL'] loop
  if not (coalesce(details->>'ACCOUNT_TYPE','company')='individual' and k in('B_REGISTRATION','B_TITLE')) and trim(coalesce(details->>k,''))='' then raise exception 'Client must complete company details before approval';end if;
 end loop;
 update public.portal_companies set status='approved',approved_by=auth.uid(),approved_at=now() where id=p_company_id and version=p_expected_version;
end;$$;
create function portal_private.individual_broker_role() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='invited' and new.details->>'ACCOUNT_TYPE'='individual' and new.invited_user_id is not null then
 insert into public.portal_counterparty_roles(user_id,counterparty_role,updated_by) values(new.invited_user_id,'introducer_broker',new.invited_user_id) on conflict(user_id) do update set counterparty_role='introducer_broker',updated_at=now();end if;
 return new;end;$$;
revoke all on function portal_private.individual_broker_role() from public,anon,authenticated;
create trigger individual_broker_role after update of status on public.portal_access_requests for each row execute function portal_private.individual_broker_role();
create or replace function public.save_counterparty_role(p_user_id uuid,p_role text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 if p_user_id is distinct from auth.uid() and not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 if p_role not in ('introducer_broker','end_buyer_user','jv_partner','trader_reseller','supplier_seller') or p_role is null then raise exception 'Select a valid counterparty type';end if;
 if not exists(select 1 from public.portal_members where user_id=p_user_id and active) then raise exception 'Active registered account required';end if;
 if p_role<>'introducer_broker' and exists(select 1 from public.portal_company_members m join public.portal_companies c on c.id=m.company_id where m.user_id=p_user_id and c.details->>'ACCOUNT_TYPE'='individual') then raise exception 'Private individuals are Introducer / Broker';end if;
 insert into public.portal_counterparty_roles(user_id,counterparty_role,updated_by) values(p_user_id,p_role,auth.uid()) on conflict(user_id) do update set counterparty_role=excluded.counterparty_role,updated_by=excluded.updated_by,updated_at=now();
end;$$;
alter function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) rename to submit_mcnda_before_individuals;
revoke all on function public.submit_mcnda_before_individuals(uuid,jsonb,integer,text,text,jsonb) from public,anon,authenticated,service_role;
create function public.submit_mcnda_for_approval(p_id uuid,p_details jsonb,p_expected_version integer,p_note text,p_pdf text,p_attestation jsonb) returns public.portal_companies language plpgsql security definer set search_path='' as $$
declare identity jsonb;
begin
 if exists(select 1 from public.portal_company_members m join public.portal_companies c on c.id=m.company_id where m.user_id=auth.uid() and c.details->>'ACCOUNT_TYPE'='individual') then
 identity:=public.individual_identity(auth.uid(),null);
 if p_details->>'ACCOUNT_TYPE' is distinct from 'individual' or identity->>'passport_number' is null or p_details->>'PASSPORT_NUMBER' is distinct from identity->>'passport_number' then raise exception 'Personal passport details must match the registered application';end if;
 end if;
 return public.submit_mcnda_before_individuals(p_id,p_details,p_expected_version,p_note,p_pdf,p_attestation);
end;$$;
revoke all on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) from public,anon;
grant execute on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) to authenticated;
alter table portal_private.individual_identity alter column copy_path drop not null;
create or replace function public.register_individual_access(p_details jsonb,p_message text,p_source_key text,p_passport text,p_copy_path text) returns uuid language plpgsql security definer set search_path='' as $$
declare new_request_id uuid;k text;
begin
 if p_details->>'ACCOUNT_TYPE' is distinct from 'individual' or length(trim(p_passport)) not between 3 and 30 then raise exception 'Invalid personal application';end if;
 foreach k in array array['P_FIRST_NAME','P_LAST_NAME','P_ADDRESS','P_POSTCODE','P_CITY','P_COUNTRY'] loop
 if trim(coalesce(p_details->>k,''))='' then raise exception 'Required personal detail missing';end if;end loop;
 if p_copy_path is not null and (p_copy_path !~ '^[0-9a-f-]{36}\.(pdf|jpg|png)$' or not exists(select 1 from storage.objects where bucket_id='vip-private-identity' and name=p_copy_path) ) then raise exception 'Signed passport copy required';end if;
 new_request_id:=public.register_access_request(p_details,p_message,p_source_key);
 if new_request_id is not null then
 update public.portal_access_requests set details=details||jsonb_build_object('ACCOUNT_TYPE','individual','P_FIRST_NAME',p_details->>'P_FIRST_NAME','P_LAST_NAME',p_details->>'P_LAST_NAME','P_ADDRESS',p_details->>'P_ADDRESS','P_POSTCODE',p_details->>'P_POSTCODE','P_CITY',p_details->>'P_CITY','P_COUNTRY',p_details->>'P_COUNTRY') where portal_access_requests.id=new_request_id;
 insert into portal_private.individual_identity values(new_request_id,trim(p_passport),p_copy_path,now());
 end if;return new_request_id;
end;$$;

create policy private_identity_upload on storage.objects for insert to authenticated with check(
 bucket_id='vip-private-identity' and (select portal_private.is_active()) and name ~ ('^'||(select auth.uid())::text||'/[0-9a-f-]{36}\.(pdf|jpg|png)$') and exists(select 1 from public.portal_company_members m join public.portal_companies c on c.id=m.company_id where m.user_id=(select auth.uid()) and c.details->>'ACCOUNT_TYPE'='individual'));
create function public.save_my_passport_copy(p_path text,p_signed boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if not (select portal_private.is_active()) or not public.my_portal_access_allowed() then raise exception 'Active portal access required';end if;
 if p_signed is distinct from true or p_path !~ ('^'||auth.uid()::text||'/[0-9a-f-]{36}\.(pdf|jpg|png)$') or p_path is null then raise exception 'Signed passport copy required';end if;
 if not exists(select 1 from storage.objects where bucket_id='vip-private-identity' and name=p_path and (metadata->>'size')::bigint between 1 and 4194304 and metadata->>'mimetype' in('application/pdf','image/jpeg','image/png')) then raise exception 'Upload a valid passport copy first';end if;
 update portal_private.individual_identity i set copy_path=p_path from public.portal_access_requests r where r.id=i.request_id and r.invited_user_id=auth.uid() and r.status='invited' and r.details->>'ACCOUNT_TYPE'='individual';
 if not found then raise exception 'Individual invitation required';end if;
end;$$;
revoke all on function public.save_my_passport_copy(text,boolean) from public,anon;
grant execute on function public.save_my_passport_copy(text,boolean) to authenticated;
create or replace function public.submit_mcnda_for_approval(p_id uuid,p_details jsonb,p_expected_version integer,p_note text,p_pdf text,p_attestation jsonb) returns public.portal_companies language plpgsql security definer set search_path='' as $$
declare identity jsonb;
begin
 if exists(select 1 from public.portal_company_members m join public.portal_companies c on c.id=m.company_id where m.user_id=auth.uid() and c.details->>'ACCOUNT_TYPE'='individual') then
 identity:=public.individual_identity(auth.uid(),null);
 if identity->>'copy_path' is null or not exists(select 1 from storage.objects where bucket_id='vip-private-identity' and name=identity->>'copy_path') then raise exception 'Upload your signed passport copy in your profile before signing the MCNDA';end if;
 if p_details->>'ACCOUNT_TYPE' is distinct from 'individual' or identity->>'passport_number' is null or p_details->>'PASSPORT_NUMBER' is distinct from identity->>'passport_number' then raise exception 'Personal passport details must match the registered application';end if;
 end if;
 return public.submit_mcnda_before_individuals(p_id,p_details,p_expected_version,p_note,p_pdf,p_attestation);
end;$$;
revoke all on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) from public,anon;
grant execute on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) to authenticated;
drop function public.claim_upload_notification(uuid,text);
create function public.claim_upload_notification(p_submission_id uuid,p_token_hash text) returns table(lease_id uuid,client_email text,document_title text,uploaded_at timestamptz,language text) language plpgsql security definer set search_path='' as $$
declare claimed_lease uuid;
begin
 update public.portal_upload_notifications n set status='sending',token_hash=null,attempts=n.attempts+1,lease_id=gen_random_uuid(),leased_at=now(),next_attempt_at=now()+interval '5 minutes' where n.submission_id=p_submission_id and n.token_hash=p_token_hash and n.attempts<5 and (n.status='pending' or (n.status='sending' and n.leased_at<now()-interval '5 minutes')) returning n.lease_id into claimed_lease;
 if claimed_lease is null then return;end if;
 return query select claimed_lease,m.email,s.title,s.created_at,n.language from public.portal_submissions s join public.portal_members m on m.user_id=s.user_id join public.portal_upload_notifications n on n.submission_id=s.id where s.id=p_submission_id;
end;$$;
revoke all on function public.claim_upload_notification(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_upload_notification(uuid,text) to service_role;


alter table public.portal_signing_profiles alter column stamp drop not null;
create or replace function public.save_my_signing_profile(p_signature text,p_stamp text,p_expected_version uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
declare previous uuid;fresh uuid:=gen_random_uuid();img text;raw bytea;individual boolean;
begin
 if auth.uid() is null or not portal_private.is_active() or portal_private.is_admin() then raise exception 'Active client account required';end if;
 select coalesce(c.details->>'ACCOUNT_TYPE'='individual',false) into individual from public.portal_company_members m join public.portal_companies c on c.id=m.company_id where m.user_id=auth.uid();
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));select version into previous from public.portal_signing_profiles where user_id=auth.uid() for update;
 if previous is distinct from p_expected_version then raise exception 'Signing images changed; refresh and try again';end if;
 foreach img in array (case when individual then array[p_signature] else array[p_signature,p_stamp] end) loop
 if img is null or length(img) not between 50 and 900000 or img not like 'data:image/png;base64,%' then raise exception 'Upload valid PNG signing images';end if;
 raw:=decode(substring(img from 23),'base64');if substring(raw from 1 for 8)<>decode('89504e470d0a1a0a','hex') then raise exception 'Invalid PNG image';end if;end loop;
 insert into public.portal_signing_profiles(user_id,signature,stamp,version) values(auth.uid(),p_signature,case when individual then null else p_stamp end,fresh) on conflict(user_id) do update set signature=excluded.signature,stamp=excluded.stamp,version=excluded.version,updated_at=now();return fresh;
end;$$;

notify pgrst,'reload schema';
commit;
