begin;

create table portal_private.auth_mail_limits(key text primary key,window_start timestamptz not null default now(),hits integer not null default 1);
alter table portal_private.auth_mail_limits enable row level security;
revoke all on portal_private.auth_mail_limits from public,anon,authenticated;
create function public.claim_portal_recovery(p_email text,p_source text) returns uuid language plpgsql security definer set search_path='' as $$
declare k text; n integer; who uuid;begin
 if p_source !~ '^[0-9a-f]{64}$' or length(p_email)>254 then return null;end if;
 foreach k in array array['source:'||p_source,'email:'||encode(sha256(convert_to(lower(p_email),'UTF8')),'hex'),'global'] loop
 insert into portal_private.auth_mail_limits(key) values(k) on conflict(key) do update set hits=case when portal_private.auth_mail_limits.window_start<now()-interval '1 hour' then 1 else portal_private.auth_mail_limits.hits+1 end,window_start=case when portal_private.auth_mail_limits.window_start<now()-interval '1 hour' then now() else portal_private.auth_mail_limits.window_start end returning hits into n;
 if n>(case when k='global' then 100 when k like 'source:%' then 10 else 3 end) then return null;end if;
 end loop;
 select m.user_id into who from public.portal_members m where lower(m.email)=lower(p_email) and m.active and not exists(select 1 from public.portal_company_members cm join public.portal_companies c on c.id=cm.company_id where cm.user_id=m.user_id and c.access_state<>'active');return who;
end;$$;
revoke all on function public.claim_portal_recovery(text,text) from public,anon,authenticated;grant execute on function public.claim_portal_recovery(text,text) to service_role;
create table public.portal_bootstrap_mail(id uuid primary key default gen_random_uuid(),email text not null check(email='info@vipcapital.eu'),token_hash text not null,expires_at timestamptz not null,status text not null default 'pending' check(status in('pending','claimed','sent','failed')),user_id uuid references auth.users(id),sent_at timestamptz);
alter table public.portal_bootstrap_mail enable row level security;
revoke all on public.portal_bootstrap_mail from public,anon,authenticated;
create function public.claim_portal_bootstrap(p_hash text) returns table(id uuid,email text) language plpgsql security definer set search_path='' as $$begin return query update public.portal_bootstrap_mail b set status='claimed' where b.token_hash=p_hash and b.status='pending' and b.expires_at>now() returning b.id,b.email;end;$$;
revoke all on function public.claim_portal_bootstrap(text) from public,anon,authenticated;grant execute on function public.claim_portal_bootstrap(text) to service_role;
grant select,insert,update on public.portal_bootstrap_mail to service_role;
alter table public.portal_access_requests add column invitation_mailed_at timestamptz;


create or replace function portal_private.dispatch_access_notifications() returns void language plpgsql security definer set search_path='' as $$
declare item record;token text;
begin
 for item in select id from public.portal_access_requests where (not admin_notified or not applicant_notified) and notify_attempts<5 and next_notification_at<=now() and (notify_leased_at is null or notify_leased_at<now()-interval '5 minutes') order by created_at limit 10 for update skip locked loop
  token:=encode(extensions.gen_random_bytes(32),'hex');
  update public.portal_access_requests set notify_token_hash=encode(extensions.digest(token,'sha256'),'hex'),next_notification_at=now()+interval '5 minutes' where id=item.id;
  perform net.http_post(url:='https://lwhsrxxagevisfeihxcy.supabase.co/functions/v1/access-requests',headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx3aHNyeHhhZ2V2aXNmZWloeGN5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0NDQ2MTIsImV4cCI6MjEwODAyMDYxMn0.eBQrl8GIyHqpl-5AfGOa0xsEwa_Mkcu4U1MT2k8HpdU','apikey','eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx3aHNyeHhhZ2V2aXNmZWloeGN5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0NDQ2MTIsImV4cCI6MjEwODAyMDYxMn0.eBQrl8GIyHqpl-5AfGOa0xsEwa_Mkcu4U1MT2k8HpdU'),body:=jsonb_build_object('action','notify','id',item.id,'token',token),timeout_milliseconds:=45000);
 end loop;
end;$$;
revoke all on function portal_private.dispatch_access_notifications() from public,anon,authenticated;


create extension if not exists pg_cron with schema pg_catalog;
create table public.portal_document_notifications(
 id uuid primary key default gen_random_uuid(),recipient uuid not null references public.portal_members(user_id) on delete cascade,kind text not null check(kind in('document','mcnda','commission','spa','fco')),entity_id uuid not null,version_key text not null,title text not null,created_at timestamptz not null default now(),sent_at timestamptz,skipped_at timestamptz,attempts integer not null default 0,token_hash text,lease uuid,leased_at timestamptz,next_attempt_at timestamptz not null default now(),last_error text,unique(recipient,kind,entity_id,version_key));
alter table public.portal_document_notifications enable row level security;
revoke all on public.portal_document_notifications from public,anon,authenticated;
grant all on public.portal_document_notifications to service_role;
grant select on public.portal_document_notifications to authenticated;
create policy notification_admin_read on public.portal_document_notifications for select to authenticated using((select portal_private.is_admin()));
create function public.claim_document_notification(p_id uuid,p_token_hash text) returns setof public.portal_document_notifications language plpgsql security definer set search_path='' as $$
begin
 return query update public.portal_document_notifications set token_hash=null,lease=gen_random_uuid(),leased_at=now(),attempts=attempts+1,next_attempt_at=now()+interval '5 minutes' where id=p_id and token_hash=p_token_hash and sent_at is null and skipped_at is null and attempts<5 and (leased_at is null or leased_at<now()-interval '5 minutes') returning *;
end;$$;
revoke all on function public.claim_document_notification(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_document_notification(uuid,text) to service_role;
create function portal_private.dispatch_document_notifications() returns void language plpgsql security definer set search_path='' as $$
declare item record;token text;
begin
 for item in select id from public.portal_document_notifications where sent_at is null and skipped_at is null and attempts<5 and next_attempt_at<=now() and (leased_at is null or leased_at<now()-interval '5 minutes') order by created_at limit 10 for update skip locked loop
 token:=encode(extensions.gen_random_bytes(32),'hex');
 update public.portal_document_notifications set token_hash=encode(extensions.digest(token,'sha256'),'hex'),next_attempt_at=now()+interval '5 minutes' where id=item.id;
 perform net.http_post(url:='https://lwhsrxxagevisfeihxcy.supabase.co/functions/v1/document-notifications',headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx3aHNyeHhhZ2V2aXNmZWloeGN5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0NDQ2MTIsImV4cCI6MjEwODAyMDYxMn0.eBQrl8GIyHqpl-5AfGOa0xsEwa_Mkcu4U1MT2k8HpdU','apikey','eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx3aHNyeHhhZ2V2aXNmZWloeGN5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0NDQ2MTIsImV4cCI6MjEwODAyMDYxMn0.eBQrl8GIyHqpl-5AfGOa0xsEwa_Mkcu4U1MT2k8HpdU'),body:=jsonb_build_object('id',item.id,'token',token),timeout_milliseconds:=45000);
 end loop;
end;$$;
revoke all on function portal_private.dispatch_document_notifications() from public,anon,authenticated;
create function portal_private.queue_document_notification(p_recipient uuid,p_kind text,p_entity uuid,p_version text,p_title text) returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.portal_members where user_id=p_recipient and active and not is_admin) then return;end if;
 insert into public.portal_document_notifications(recipient,kind,entity_id,version_key,title) values(p_recipient,p_kind,p_entity,p_version,left(coalesce(p_title,'New document'),200)) on conflict do nothing;
 begin perform portal_private.dispatch_document_notifications();exception when others then null;end;
end;$$;
revoke all on function portal_private.queue_document_notification(uuid,text,uuid,text,text) from public,anon,authenticated;
create function portal_private.notify_shared_document() returns trigger language plpgsql security definer set search_path='' as $$
declare d public.portal_documents;r record;
begin
 if tg_table_name='portal_document_access' then
 select * into d from public.portal_documents where id=new.document_id;
 if d.published then perform portal_private.queue_document_notification(new.user_id,'document',d.id,coalesce(d.storage_path,'')||':'||coalesce(d.version_date::text,''),d.title);end if;
 else
 if not new.published then return new;end if;
 if tg_op='UPDATE' and old.published and new.storage_path is not distinct from old.storage_path and new.version_date is not distinct from old.version_date then return new;end if;
 for r in select user_id from public.portal_document_access where document_id=new.id loop
 perform portal_private.queue_document_notification(r.user_id,'document',new.id,coalesce(new.storage_path,'')||':'||coalesce(new.version_date::text,''),new.title);
 end loop;
 end if;
 return new;
end;$$;
revoke all on function portal_private.notify_shared_document() from public,anon,authenticated;
create trigger notify_document_grant after insert on public.portal_document_access for each row execute function portal_private.notify_shared_document();
create trigger notify_document_publish after insert or update of published,storage_path,version_date on public.portal_documents for each row execute function portal_private.notify_shared_document();
create function portal_private.notify_assigned_agreement() returns trigger language plpgsql security definer set search_path='' as $$
declare kind text;recipient uuid;version text;title text;
begin
 if tg_table_name='portal_mcnda_assignments' then
 if new.status<>'assigned' then return new;end if;
 if tg_op='UPDATE' and old.status='assigned' then return new;end if;
 kind:='mcnda';recipient:=new.user_id;version:=new.template_version;title:='MCNDA';
 else
 if new.status<>'awaiting_client' then return new;end if;
 if tg_op='UPDATE' and old.status='awaiting_client' then return new;end if;
 kind:=case tg_table_name when 'commission_agreements' then 'commission' when 'spa_agreements' then 'spa' else 'fco' end;
 recipient:=new.recipient;version:=new.version::text;title:=coalesce(new.data->>'title',case kind when 'commission' then 'Commission agreement' when 'spa' then 'SPA' else 'FCO Petroleum' end)||' | '||new.transaction_code;
 end if;
 perform portal_private.queue_document_notification(recipient,kind,new.id,version,title);return new;
end;$$;
revoke all on function portal_private.notify_assigned_agreement() from public,anon,authenticated;
create trigger notify_mcnda_assignment after insert or update of status on public.portal_mcnda_assignments for each row execute function portal_private.notify_assigned_agreement();
create trigger notify_commission_assignment after insert or update of status on public.commission_agreements for each row execute function portal_private.notify_assigned_agreement();
create trigger notify_spa_assignment after insert or update of status on public.spa_agreements for each row execute function portal_private.notify_assigned_agreement();
create trigger notify_fco_assignment after insert or update of status on public.fco_agreements for each row execute function portal_private.notify_assigned_agreement();
select cron.schedule('vip-document-email-retry','*/5 * * * *',$$select portal_private.dispatch_document_notifications();$$);
create trigger notify_access_request after insert on public.portal_access_requests for each row execute function portal_private.queue_access_notification();
select cron.schedule('vip-access-email-retry','*/5 * * * *',$$select portal_private.dispatch_access_notifications();$$);


-- NexInt only. Requires deployed function and NEXORA_SMTP_PASSWORD secret.

create extension if not exists pg_net with schema extensions;
create table public.portal_upload_notifications (
 submission_id uuid primary key references public.portal_submissions(id) on delete cascade,
 status text not null default 'pending' check(status in ('pending','sending','sent')),
 attempts integer not null default 0,
 next_attempt_at timestamptz not null default now(),
 token_hash text,
 lease_id uuid,
 leased_at timestamptz,
 sent_at timestamptz,
 last_error text,
 created_at timestamptz not null default now()
);
alter table public.portal_upload_notifications enable row level security;
revoke all on public.portal_upload_notifications from public,anon,authenticated;
grant select,insert,update,delete on public.portal_upload_notifications to service_role;

create function public.claim_upload_notification(p_submission_id uuid,p_token_hash text)
returns table(lease_id uuid,client_email text,document_title text,uploaded_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare claimed_lease uuid;
begin
 update public.portal_upload_notifications n
 set status='sending',token_hash=null,attempts=n.attempts+1,lease_id=gen_random_uuid(),leased_at=now(),next_attempt_at=now()+interval '5 minutes'
 where n.submission_id=p_submission_id and n.token_hash=p_token_hash and n.attempts<5
 and (n.status='pending' or (n.status='sending' and n.leased_at<now()-interval '5 minutes'))
 returning n.lease_id into claimed_lease;
 if claimed_lease is null then return;end if;
 return query select claimed_lease,m.email,s.title,s.created_at
 from public.portal_submissions s join public.portal_members m on m.user_id=s.user_id
 where s.id=p_submission_id;
end;$$;
revoke all on function public.claim_upload_notification(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_upload_notification(uuid,text) to service_role;

create function portal_private.dispatch_upload_notifications() returns void
language plpgsql security definer set search_path='' as $$
declare token text;job record;
begin
 for job in select submission_id from public.portal_upload_notifications
 where attempts<5 and ((status='pending' and next_attempt_at<=now()) or (status='sending' and leased_at<now()-interval '5 minutes'))
 order by created_at limit 10 for update skip locked
 loop
  token:=encode(extensions.gen_random_bytes(32),'hex');
  update public.portal_upload_notifications set token_hash=encode(extensions.digest(token,'sha256'),'hex'),next_attempt_at=now()+interval '5 minutes' where submission_id=job.submission_id;
  perform net.http_post(
   url:='https://lwhsrxxagevisfeihxcy.supabase.co/functions/v1/upload-notification',
   headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx3aHNyeHhhZ2V2aXNmZWloeGN5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0NDQ2MTIsImV4cCI6MjEwODAyMDYxMn0.eBQrl8GIyHqpl-5AfGOa0xsEwa_Mkcu4U1MT2k8HpdU','apikey','eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx3aHNyeHhhZ2V2aXNmZWloeGN5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0NDQ2MTIsImV4cCI6MjEwODAyMDYxMn0.eBQrl8GIyHqpl-5AfGOa0xsEwa_Mkcu4U1MT2k8HpdU'),
   body:=jsonb_build_object('submission_id',job.submission_id,'token',token),timeout_milliseconds:=45000
  );
 end loop;
end;$$;
revoke all on function portal_private.dispatch_upload_notifications() from public,anon,authenticated;

create function portal_private.queue_upload_notification() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into public.portal_upload_notifications(submission_id) values(new.id) on conflict do nothing;
 begin
  perform portal_private.dispatch_upload_notifications();
 exception when others then
  -- Email availability must not prevent a client from submitting a document.
  update public.portal_upload_notifications set last_error='Dispatch unavailable; queued for retry' where submission_id=new.id;
 end;
 return new;
end;$$;
revoke all on function portal_private.queue_upload_notification() from public,anon,authenticated;
create trigger nexora_upload_notification after insert on public.portal_submissions
for each row execute function portal_private.queue_upload_notification();
select cron.schedule('vip-upload-email-retry','*/5 * * * *',$$select portal_private.dispatch_upload_notifications();$$);

-- After enabling pg_cron, schedule using 006_schedule_notifications.sql.

commit;