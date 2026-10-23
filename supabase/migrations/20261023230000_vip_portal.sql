begin;
create extension if not exists pg_net with schema extensions;
do $$begin if to_regclass('public.portal_members') is not null then raise exception 'Portal already exists; do not reinstall';end if;end$$;
-- Apply ONLY to the separate VIP Capital Supabase project, through SQL Editor.

create schema if not exists portal_private;
revoke all on schema portal_private from public, anon;
grant usage on schema portal_private to authenticated;

create table public.portal_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  active boolean not null default true,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);
create table public.portal_documents (
  id uuid primary key default gen_random_uuid(),
  title text not null check(length(title) between 1 and 180),
  description text not null default '' check(length(description)<=2000),
  category text not null check(category in ('Commercial Documents','Contract Templates','Terms & Conditions','Company Documents')),
  version_date date not null,
  is_draft boolean not null default true,
  published boolean not null default false,
  storage_path text not null unique check(storage_path = id::text || '.pdf'),
  created_at timestamptz not null default now()
);
create table public.portal_document_access (
  document_id uuid references public.portal_documents(id) on delete cascade,
  user_id uuid references public.portal_members(user_id) on delete cascade,
  primary key(document_id,user_id)
);
create index portal_access_user on public.portal_document_access(user_id);

create function portal_private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.portal_members where user_id=(select auth.uid()) and active and is_admin);
$$;
create function portal_private.is_active() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.portal_members where user_id=(select auth.uid()) and active);
$$;
revoke all on function portal_private.is_admin() from public,anon;
revoke all on function portal_private.is_active() from public,anon;
grant execute on function portal_private.is_admin(),portal_private.is_active() to authenticated;

create function portal_private.sync_member() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if TG_OP='INSERT' then
    insert into public.portal_members(user_id,email) values(new.id,new.email);
  else
    update public.portal_members set email=new.email where user_id=new.id;
  end if;
  return new;
end;
$$;
revoke all on function portal_private.sync_member() from public,anon,authenticated;
create trigger nexora_member_insert after insert on auth.users for each row execute function portal_private.sync_member();
create trigger nexora_member_email after update of email on auth.users for each row execute function portal_private.sync_member();

alter table public.portal_members enable row level security;
alter table public.portal_documents enable row level security;
alter table public.portal_document_access enable row level security;
revoke all on public.portal_members,public.portal_documents,public.portal_document_access from anon,authenticated;
grant select,update on public.portal_members to authenticated;
grant select,insert,update,delete on public.portal_documents,public.portal_document_access to authenticated;

create policy member_read on public.portal_members for select to authenticated
using(user_id=(select auth.uid()) or (select portal_private.is_admin()));
create policy member_manage on public.portal_members for update to authenticated
using((select portal_private.is_admin())) with check((select portal_private.is_admin()));
create policy access_read on public.portal_document_access for select to authenticated
using((select portal_private.is_admin()) or (user_id=(select auth.uid()) and (select portal_private.is_active())));
create policy access_manage on public.portal_document_access for all to authenticated
using((select portal_private.is_admin())) with check((select portal_private.is_admin()));
create policy document_read on public.portal_documents for select to authenticated
using((select portal_private.is_admin()) or (
  published and (select portal_private.is_active()) and exists(
    select 1 from public.portal_document_access a where a.document_id=portal_documents.id and a.user_id=(select auth.uid())
  )
));
create policy document_manage on public.portal_documents for all to authenticated
using((select portal_private.is_admin())) with check((select portal_private.is_admin()));

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('vip-documents','vip-documents',false,20971520,array['application/pdf']);
create policy nexora_file_read on storage.objects for select to authenticated using(
  bucket_id='vip-documents' and (
    (select portal_private.is_admin()) or exists(
      select 1 from public.portal_documents d where d.storage_path=storage.objects.name
    )
  )
);
create policy nexora_file_insert on storage.objects for insert to authenticated
with check(bucket_id='vip-documents' and (select portal_private.is_admin()));
create policy nexora_file_update on storage.objects for update to authenticated
using(bucket_id='vip-documents' and (select portal_private.is_admin()))
with check(bucket_id='vip-documents' and (select portal_private.is_admin()));
create policy nexora_file_delete on storage.objects for delete to authenticated
using(bucket_id='vip-documents' and (select portal_private.is_admin()));


-- NexInt only. Add private client submissions without changing existing documents.

create table public.portal_submissions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.portal_members(user_id) on delete cascade,
  title text not null check(length(trim(title)) between 1 and 180),
  note text not null default '' check(length(note)<=2000),
  storage_path text not null unique check(storage_path=user_id::text || '/' || id::text || '.pdf'),
  status text not null default 'received' check(status in ('received','reviewed')),
  created_at timestamptz not null default now()
);
create index portal_submissions_user on public.portal_submissions(user_id,created_at desc);
alter table public.portal_submissions enable row level security;
revoke all on public.portal_submissions from public,anon,authenticated;
grant select on public.portal_submissions to authenticated;
grant insert(id,user_id,title,note,storage_path) on public.portal_submissions to authenticated;
grant update(status) on public.portal_submissions to authenticated;
create policy submission_read on public.portal_submissions for select to authenticated
using((select portal_private.is_admin()) or (user_id=(select auth.uid()) and (select portal_private.is_active())));
create policy submission_insert on public.portal_submissions for insert to authenticated
with check(user_id=(select auth.uid()) and (select portal_private.is_active()) and status='received');
create policy submission_review on public.portal_submissions for update to authenticated
using((select portal_private.is_admin())) with check((select portal_private.is_admin()));

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('vip-client-uploads','vip-client-uploads',false,20971520,array['application/pdf']);
create policy client_upload_read on storage.objects for select to authenticated
using(bucket_id='vip-client-uploads' and (
  (select portal_private.is_admin()) or (
    (select portal_private.is_active()) and (storage.foldername(name))[1]=(select auth.uid())::text
  )
));
create policy client_upload_insert on storage.objects for insert to authenticated
with check(bucket_id='vip-client-uploads' and (select portal_private.is_active())
  and name ~ ('^' || (select auth.uid())::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$')
);
-- Clients may clean up their own incomplete upload, but cannot delete a submitted PDF.
create policy client_upload_cleanup on storage.objects for delete to authenticated
using(bucket_id='vip-client-uploads' and (
  (select portal_private.is_admin()) or (
    (select portal_private.is_active()) and (storage.foldername(name))[1]=(select auth.uid())::text
    and not exists(select 1 from public.portal_submissions s where s.storage_path=storage.objects.name)
  )
));


-- NexInt: document assessment and administrator-only deletion.

alter table public.portal_submissions drop constraint if exists portal_submissions_status_check;
-- A previously reviewed document is not automatically approved.
update public.portal_submissions set status='in_review' where status='reviewed';
alter table public.portal_submissions add constraint portal_submissions_status_check
check(status in ('received','in_review','approved','denied'));
grant delete on public.portal_submissions to authenticated;
create policy submission_delete on public.portal_submissions for delete to authenticated
using((select portal_private.is_admin()));



create table public.portal_companies (
 id uuid primary key default gen_random_uuid(),
 details jsonb not null,
 version integer not null default 1,
 status text not null default 'pending' check(status in ('pending','approved')),
 approved_by uuid references public.portal_members(user_id),
 approved_at timestamptz,
 updated_at timestamptz not null default now(),
 created_by uuid not null references public.portal_members(user_id)
);
create table public.portal_company_members (
 user_id uuid primary key references public.portal_members(user_id) on delete cascade,
 company_id uuid not null references public.portal_companies(id)
);
create index portal_company_members_company on public.portal_company_members(company_id);
create table public.portal_document_profiles (
 submission_id uuid primary key references public.portal_submissions(id) on delete cascade,
 company_id uuid not null references public.portal_companies(id),
 company_version integer not null,
 company_status text not null,
 details jsonb not null,
 captured_at timestamptz not null default now()
);
alter table public.portal_companies enable row level security;
alter table public.portal_company_members enable row level security;
alter table public.portal_document_profiles enable row level security;
revoke all on public.portal_companies,public.portal_company_members,public.portal_document_profiles from public,anon,authenticated;
grant select on public.portal_companies,public.portal_company_members,public.portal_document_profiles to authenticated;
grant insert,update,delete on public.portal_company_members to authenticated;
create policy company_read on public.portal_companies for select to authenticated using((select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(select 1 from public.portal_company_members m where m.user_id=(select auth.uid()) and m.company_id=portal_companies.id)));
create policy company_member_read on public.portal_company_members for select to authenticated using((select portal_private.is_admin()) or (user_id=(select auth.uid()) and (select portal_private.is_active())));
create policy company_member_manage on public.portal_company_members for all to authenticated using((select portal_private.is_admin())) with check((select portal_private.is_admin()));
create policy document_profile_read on public.portal_document_profiles for select to authenticated using((select portal_private.is_admin()) or exists(select 1 from public.portal_submissions s where s.id=submission_id and s.user_id=(select auth.uid()) and (select portal_private.is_active())));

create function portal_private.save_company_details(p_details jsonb,p_expected_version integer) returns public.portal_companies
language plpgsql security definer set search_path='' as $$
declare company public.portal_companies; normalized jsonb;key text;max_length integer;stamp text;
begin
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 -- Serialize first profile creation as well as edits for one account.
 perform 1 from public.portal_members where user_id=auth.uid() for update;
 normalized:='{}'::jsonb;
 foreach key in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL','B_WEBSITE'] loop
  if jsonb_typeof(p_details->key) is distinct from 'string' then raise exception 'Missing company detail: %',key;end if;
  max_length:=case key when 'B_ADDRESS' then 150 when 'B_REGISTRATION' then 60 when 'B_COUNTRY' then 60 when 'B_REPRESENTATIVE' then 80 when 'B_TITLE' then 80 when 'B_PHONE' then 50 else 100 end;
  if length(trim(p_details->>key))>max_length or (key<>'B_WEBSITE' and length(trim(p_details->>key))=0) then raise exception 'Invalid company detail: %',key;end if;
  normalized:=normalized||jsonb_build_object(key,trim(p_details->>key));
 end loop;
 select c.* into company from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=auth.uid() for update of c;
 if coalesce(company.id::text,'') is distinct from coalesce(p_details->>'B_PROFILE_ID','') then raise exception 'Company link changed; refresh first';end if;
 stamp:=coalesce(p_details->>'B_STAMP_PATH','');
 if stamp<>'' then
  if stamp is distinct from coalesce(company.details->>'B_STAMP_PATH','') and stamp !~ ('^'||auth.uid()::text||'/[0-9a-f-]{36}\.png$') then raise exception 'Invalid company stamp';end if;
  if not exists(select 1 from storage.objects where bucket_id='vip-company-assets' and name=stamp) then raise exception 'Company stamp not found';end if;
 end if;
 normalized:=normalized||jsonb_build_object('B_STAMP_PATH',stamp);
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
revoke all on function portal_private.save_company_details(jsonb,integer) from public,anon,authenticated;
create function public.save_my_company_profile(p_details jsonb,p_expected_version integer) returns public.portal_companies
language sql security definer set search_path='' as $$select portal_private.save_company_details(p_details,p_expected_version);$$;
revoke all on function public.save_my_company_profile(jsonb,integer) from public,anon;
grant execute on function public.save_my_company_profile(jsonb,integer) to authenticated;

create function public.approve_company_profile(p_company_id uuid,p_expected_version integer) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 update public.portal_companies set status='approved',approved_by=auth.uid(),approved_at=now() where id=p_company_id and version=p_expected_version;
 if not found then raise exception 'Profile changed; refresh first';end if;
end;$$;
revoke all on function public.approve_company_profile(uuid,integer) from public,anon;
grant execute on function public.approve_company_profile(uuid,integer) to authenticated;

create function portal_private.capture_document_profile() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into public.portal_document_profiles(submission_id,company_id,company_version,company_status,details)
 select new.id,c.id,c.version,c.status,c.details from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=new.user_id;
 return new;
end;$$;
revoke all on function portal_private.capture_document_profile() from public,anon,authenticated;
create trigger capture_company_profile after insert on public.portal_submissions for each row execute function portal_private.capture_document_profile();

create function public.submit_company_mcnda(p_id uuid,p_details jsonb,p_expected_version integer,p_note text) returns public.portal_companies
language plpgsql security definer set search_path='' as $$
declare company public.portal_companies;path text;
begin
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 path:=auth.uid()::text||'/'||p_id::text||'.pdf';
 if not exists(select 1 from storage.objects where bucket_id='vip-client-uploads' and name=path) then raise exception 'Upload the PDF first';end if;
 if length(p_note)>2000 then raise exception 'Note too long';end if;
 company:=portal_private.save_company_details(p_details,p_expected_version);
 insert into public.portal_submissions(id,user_id,title,note,storage_path) values(p_id,auth.uid(),left('MCNDA - '||(company.details->>'B_COMPANY'),180),p_note,path);
 return company;
end;$$;
revoke all on function public.submit_company_mcnda(uuid,jsonb,integer,text) from public,anon;
grant execute on function public.submit_company_mcnda(uuid,jsonb,integer,text) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('vip-company-assets','vip-company-assets',false,5242880,array['image/png']);
create function portal_private.can_read_company_stamp(p_name text) returns boolean language sql stable security definer set search_path='' as $$
 select (select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(select 1 from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=auth.uid() and c.details->>'B_STAMP_PATH'=p_name));
$$;
revoke all on function portal_private.can_read_company_stamp(text) from public,anon;
grant execute on function portal_private.can_read_company_stamp(text) to authenticated;
create function portal_private.company_stamp_unreferenced(p_name text) returns boolean language sql stable security definer set search_path='' as $$
 select not exists(select 1 from public.portal_companies where details->>'B_STAMP_PATH'=p_name) and not exists(select 1 from public.portal_document_profiles where details->>'B_STAMP_PATH'=p_name);
$$;
revoke all on function portal_private.company_stamp_unreferenced(text) from public,anon;
grant execute on function portal_private.company_stamp_unreferenced(text) to authenticated;
create policy company_stamp_cleanup on storage.objects for delete to authenticated using(bucket_id='vip-company-assets' and (select portal_private.is_active()) and (storage.foldername(name))[1]=(select auth.uid())::text and (select portal_private.company_stamp_unreferenced(name)));
create policy company_stamp_read on storage.objects for select to authenticated using(bucket_id='vip-company-assets' and ((select portal_private.can_read_company_stamp(name)) or ((select portal_private.is_active()) and (storage.foldername(name))[1]=(select auth.uid())::text)));
create policy company_stamp_insert on storage.objects for insert to authenticated with check(bucket_id='vip-company-assets' and (select portal_private.is_active()) and name ~ ('^'||(select auth.uid())::text||'/[0-9a-f-]{36}\.png$'));


create or replace function portal_private.save_company_details(p_details jsonb,p_expected_version integer) returns public.portal_companies
language plpgsql security definer set search_path='' as $$
declare company public.portal_companies; normalized jsonb;key text;max_length integer;stamp text;
begin
 if not (select portal_private.is_active()) then raise exception 'Active account required';end if;
 -- Serialize first profile creation as well as edits for one account.
 perform 1 from public.portal_members where user_id=auth.uid() for update;
 normalized:='{}'::jsonb;
 foreach key in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL','B_WEBSITE'] loop
  if jsonb_typeof(p_details->key) is distinct from 'string' then raise exception 'Missing company detail: %',key;end if;
  max_length:=case key when 'B_ADDRESS' then 150 when 'B_REGISTRATION' then 60 when 'B_COUNTRY' then 60 when 'B_REPRESENTATIVE' then 80 when 'B_TITLE' then 80 when 'B_PHONE' then 50 else 100 end;
  if length(trim(p_details->>key))>max_length or (key<>'B_WEBSITE' and length(trim(p_details->>key))=0) then raise exception 'Invalid company detail: %',key;end if;
  normalized:=normalized||jsonb_build_object(key,trim(p_details->>key));
 end loop;
 select c.* into company from public.portal_companies c join public.portal_company_members m on m.company_id=c.id where m.user_id=auth.uid() for update of c;
 if coalesce(company.id::text,'') is distinct from coalesce(p_details->>'B_PROFILE_ID','') then raise exception 'Company link changed; refresh first';end if;
 stamp:=coalesce(p_details->>'B_STAMP_PATH','');
 if stamp<>'' then
  if stamp is distinct from coalesce(company.details->>'B_STAMP_PATH','') and stamp !~ ('^'||auth.uid()::text||'/[0-9a-f-]{36}\.png$') then raise exception 'Invalid company stamp';end if;
  if not exists(select 1 from storage.objects where bucket_id='vip-company-assets' and name=stamp) then raise exception 'Company stamp not found';end if;
 end if;
 normalized:=normalized||jsonb_build_object('B_STAMP_PATH',stamp);
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


create table public.portal_access_requests (
 id uuid primary key default gen_random_uuid(),details jsonb not null,message text not null default '',source_key text not null,
 status text not null default 'pending' check(status in ('pending','inviting','invited','declined','invitation_failed','existing_account')),
 reviewed_by uuid references public.portal_members(user_id),reviewed_at timestamptz,
 invite_lease uuid,invite_started_at timestamptz,invited_user_id uuid references public.portal_members(user_id),invitation_error text,
 admin_notified boolean not null default false,applicant_notified boolean not null default false,
 notify_attempts integer not null default 0,notify_token_hash text,notify_lease uuid,notify_leased_at timestamptz,next_notification_at timestamptz not null default now(),
 created_at timestamptz not null default now()
);
create index access_request_email on public.portal_access_requests((details->>'B_EMAIL'),created_at desc);
create index access_request_source on public.portal_access_requests(source_key,created_at desc);
alter table public.portal_access_requests enable row level security;
revoke all on public.portal_access_requests from public,anon,authenticated;
grant select on public.portal_access_requests to authenticated;
grant all on public.portal_access_requests to service_role;
create policy access_request_admin_read on public.portal_access_requests for select to authenticated using((select portal_private.is_admin()));

create function public.register_access_request(p_details jsonb,p_message text,p_source_key text) returns uuid
language plpgsql security definer set search_path='' as $$
declare new_id uuid;k text;v text;normalized jsonb:='{}'::jsonb;
begin
 if length(p_source_key)<>64 or p_source_key !~ '^[0-9a-f]+$' or length(p_message)>2000 then raise exception 'Invalid request';end if;
 perform pg_advisory_xact_lock(hashtextextended('vip-access-global',0));
 if (select count(*) from public.portal_access_requests where created_at>now()-interval '1 hour')>=50 then return null;end if;
 if (select count(*) from public.portal_access_requests where source_key=p_source_key and created_at>now()-interval '1 hour')>=5 then return null;end if;
 foreach k in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL','B_WEBSITE'] loop
  v:=trim(coalesce(p_details->>k,''));
  if length(v)>(case k when 'B_ADDRESS' then 150 when 'B_REGISTRATION' then 60 when 'B_COUNTRY' then 60 when 'B_REPRESENTATIVE' then 80 when 'B_TITLE' then 80 when 'B_PHONE' then 50 else 100 end) then raise exception 'Field too long';end if;
  if k in ('B_COMPANY','B_COUNTRY','B_REPRESENTATIVE','B_EMAIL') and v='' then raise exception 'Required field missing';end if;
  if k='B_EMAIL' then v:=lower(v);if v !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email';end if;end if;
  normalized:=normalized||jsonb_build_object(k,v);
 end loop;
 if exists(select 1 from public.portal_access_requests where details->>'B_EMAIL'=normalized->>'B_EMAIL' and (status in ('pending','inviting','invitation_failed','existing_account') or created_at>now()-interval '24 hours')) then return null;end if;
 insert into public.portal_access_requests(details,message,source_key) values(normalized,p_message,p_source_key) returning id into new_id;
 return new_id;
end;$$;
revoke all on function public.register_access_request(jsonb,text,text) from public,anon,authenticated;
grant execute on function public.register_access_request(jsonb,text,text) to service_role;

create function public.claim_access_notification(p_id uuid,p_token_hash text) returns setof public.portal_access_requests
language plpgsql security definer set search_path='' as $$
begin
 return query update public.portal_access_requests set notify_token_hash=null,notify_lease=gen_random_uuid(),notify_leased_at=now(),notify_attempts=notify_attempts+1,next_notification_at=now()+interval '5 minutes'
 where id=p_id and notify_token_hash=p_token_hash and notify_attempts<5 and (notify_leased_at is null or notify_leased_at<now()-interval '5 minutes') returning *;
end;$$;
revoke all on function public.claim_access_notification(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_access_notification(uuid,text) to service_role;
create function portal_private.dispatch_access_notifications() returns void language plpgsql security definer set search_path='' as $$
declare item record;token text;
begin
 for item in select id from public.portal_access_requests where (not admin_notified or not applicant_notified) and notify_attempts<5 and next_notification_at<=now() and (notify_leased_at is null or notify_leased_at<now()-interval '5 minutes') order by created_at limit 10 for update skip locked loop
  token:=encode(extensions.gen_random_bytes(32),'hex');
  update public.portal_access_requests set notify_token_hash=encode(extensions.digest(token,'sha256'),'hex'),next_notification_at=now()+interval '5 minutes' where id=item.id;
  perform net.http_post(url:='https://lwhsrxxagevisfeihxcy.supabase.co/functions/v1/access-requests',headers:=jsonb_build_object('Content-Type','application/json'),body:=jsonb_build_object('action','notify','id',item.id,'token',token),timeout_milliseconds:=45000);
 end loop;
end;$$;
revoke all on function portal_private.dispatch_access_notifications() from public,anon,authenticated;
create function portal_private.queue_access_notification() returns trigger language plpgsql security definer set search_path='' as $$
begin
 begin perform portal_private.dispatch_access_notifications();exception when others then null;end;
 return new;
end;$$;
revoke all on function portal_private.queue_access_notification() from public,anon,authenticated;
create trigger notify_access_request after insert on public.portal_access_requests for each row execute function portal_private.queue_access_notification();

create function public.review_access_request(p_id uuid,p_admin uuid,p_action text) returns setof public.portal_access_requests
language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.portal_members where user_id=p_admin and active and is_admin) then raise exception 'Administrator required';end if;
 if p_action='decline' then
  return query update public.portal_access_requests set status='declined',reviewed_by=p_admin,reviewed_at=now() where id=p_id and status in ('pending','invitation_failed','existing_account') returning *;
 elsif p_action='approve' then
  return query update public.portal_access_requests set status='inviting',reviewed_by=p_admin,reviewed_at=now(),invite_lease=gen_random_uuid(),invite_started_at=now(),invitation_error=null where id=p_id and (status in ('pending','invitation_failed') or (status='inviting' and invite_started_at<now()-interval '10 minutes')) returning *;
 else raise exception 'Invalid action';end if;
end;$$;
revoke all on function public.review_access_request(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.review_access_request(uuid,uuid,text) to service_role;

create function public.finish_access_invitation(p_id uuid,p_lease uuid,p_user_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare r public.portal_access_requests;company_id uuid;
begin
 select * into r from public.portal_access_requests where id=p_id and invite_lease=p_lease and status='inviting' for update;
 if not found then raise exception 'Invitation changed';end if;
 if not exists(select 1 from auth.users where id=p_user_id and lower(email)=r.details->>'B_EMAIL' and raw_user_meta_data->>'nexora_access_request'=r.id::text) then raise exception 'Invitee mismatch';end if;
 if exists(select 1 from public.portal_company_members where user_id=p_user_id) then raise exception 'User already linked; review manually';end if;
 insert into public.portal_companies(details,created_by) values(r.details||jsonb_build_object('B_STAMP_PATH',''),p_user_id) returning id into company_id;
 insert into public.portal_company_members(user_id,company_id) values(p_user_id,company_id);
 update public.portal_access_requests set status='invited',invited_user_id=p_user_id,invitation_error=null where id=p_id;
end;$$;
revoke all on function public.finish_access_invitation(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.finish_access_invitation(uuid,uuid,uuid) to service_role;

create function public.find_access_invitee(p_id uuid) returns uuid language sql security definer set search_path='' as $$
 select u.id from auth.users u join public.portal_access_requests r on lower(u.email)=r.details->>'B_EMAIL' where r.id=p_id and u.raw_user_meta_data->>'nexora_access_request'=r.id::text limit 1;
$$;
revoke all on function public.find_access_invitee(uuid) from public,anon,authenticated;
grant execute on function public.find_access_invitee(uuid) to service_role;

create or replace function public.approve_company_profile(p_company_id uuid,p_expected_version integer) returns void language plpgsql security definer set search_path='' as $$
declare details jsonb;k text;
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 select c.details into details from public.portal_companies c where c.id=p_company_id and c.version=p_expected_version for update;
 if not found then raise exception 'Profile changed; refresh first';end if;
 foreach k in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL'] loop
  if trim(coalesce(details->>k,''))='' then raise exception 'Client must complete company details before approval';end if;
 end loop;
 update public.portal_companies set status='approved',approved_by=auth.uid(),approved_at=now() where id=p_company_id and version=p_expected_version;
end;$$;


-- Server-only access required by the authenticated access-request handler.
-- No changes to client roles, membership, document access, or RLS policies.
grant select (user_id,email,active,is_admin) on public.portal_members to service_role;


alter table public.portal_companies add column access_state text not null default 'active' check(access_state in ('active','paused','archived'));
create table public.portal_company_events (
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.portal_companies(id),actor_id uuid references public.portal_members(user_id),event text not null,metadata jsonb not null default '{}'::jsonb,created_at timestamptz not null default now()
);
create index company_events_by_company on public.portal_company_events(company_id,created_at desc);
alter table public.portal_company_events enable row level security;
revoke all on public.portal_company_events from public,anon,authenticated;
grant select on public.portal_company_events to authenticated;
create policy company_event_admin_read on public.portal_company_events for select to authenticated using((select portal_private.is_admin()));
-- Company suspension applies on every database and storage request that uses is_active.
-- Existing individual suspensions stay intact when a company is resumed.
create or replace function portal_private.is_active() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.portal_members p where p.user_id=(select auth.uid()) and p.active and (p.is_admin or not exists(select 1 from public.portal_company_members m join public.portal_companies c on c.id=m.company_id where m.user_id=p.user_id and c.access_state<>'active')));
$$;
create function public.my_portal_access_allowed() returns boolean language sql stable security definer set search_path='' as $$select portal_private.is_active();$$;
revoke all on function public.my_portal_access_allowed() from public,anon;
grant execute on function public.my_portal_access_allowed() to authenticated;

create function public.manage_company_access(p_company_id uuid,p_expected_version integer,p_expected_state text,p_action text) returns void language plpgsql security definer set search_path='' as $$
declare c public.portal_companies;next_state text;
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 select * into c from public.portal_companies where id=p_company_id for update;
 if not found or c.version<>p_expected_version or c.access_state<>p_expected_state then raise exception 'Company changed; refresh and try again';end if;
 if exists(select 1 from public.portal_company_members m join public.portal_members p on p.user_id=m.user_id where m.company_id=c.id and p.is_admin) then raise exception 'Unlink administrator accounts before changing company access';end if;
 if p_action='pause' and c.access_state='active' then next_state:='paused';
 elsif p_action='resume' and c.access_state='paused' then next_state:='active';
 elsif p_action='archive' and c.access_state in ('active','paused') then next_state:='archived';
 elsif p_action='restore' and c.access_state='archived' then next_state:='paused';
 else raise exception 'Invalid company action';end if;
 update public.portal_companies set access_state=next_state,updated_at=now() where id=c.id;
 insert into public.portal_company_events(company_id,actor_id,event,metadata) values(c.id,auth.uid(),p_action,jsonb_build_object('from',c.access_state,'to',next_state));
end;$$;
revoke all on function public.manage_company_access(uuid,integer,text,text) from public,anon;
grant execute on function public.manage_company_access(uuid,integer,text,text) to authenticated;

create function public.admin_save_company_details(p_company_id uuid,p_expected_version integer,p_details jsonb) returns void language plpgsql security definer set search_path='' as $$
declare c public.portal_companies;normalized jsonb:='{}'::jsonb;k text;v text;max_length integer;changed text[]:='{}';
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 select * into c from public.portal_companies where id=p_company_id for update;
 if not found or c.version<>p_expected_version then raise exception 'Profile changed; refresh and try again';end if;
 if c.access_state='archived' then raise exception 'Restore this company before editing';end if;
 foreach k in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL','B_WEBSITE'] loop
  if jsonb_typeof(p_details->k) is distinct from 'string' then raise exception 'Missing company field';end if;
  v:=trim(p_details->>k);max_length:=case k when 'B_ADDRESS' then 150 when 'B_REGISTRATION' then 60 when 'B_COUNTRY' then 60 when 'B_REPRESENTATIVE' then 80 when 'B_TITLE' then 80 when 'B_PHONE' then 50 else 100 end;
  if length(v)>max_length or (k<>'B_WEBSITE' and v='') then raise exception 'Complete all required company details';end if;
  if k='B_EMAIL' and v !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid business email';end if;
  normalized:=normalized||jsonb_build_object(k,v);
  if v is distinct from c.details->>k then changed:=array_append(changed,k);end if;
 end loop;
 normalized:=normalized||jsonb_build_object('B_STAMP_PATH',coalesce(c.details->>'B_STAMP_PATH',''));
 if normalized is distinct from c.details then
  update public.portal_companies set details=normalized,version=version+1,status='pending',approved_by=null,approved_at=null,updated_at=now() where id=c.id;
  insert into public.portal_company_events(company_id,actor_id,event,metadata) values(c.id,auth.uid(),'details_updated',jsonb_build_object('version',c.version+1,'fields',changed));
 end if;
end;$$;
revoke all on function public.admin_save_company_details(uuid,integer,jsonb) from public,anon;
grant execute on function public.admin_save_company_details(uuid,integer,jsonb) to authenticated;

-- Audit client edits and profile approvals.
create function portal_private.audit_company_change() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='approved' and (old.status is distinct from new.status or old.approved_at is distinct from new.approved_at) then
  insert into public.portal_company_events(company_id,actor_id,event,metadata) values(new.id,auth.uid(),'profile_approved',jsonb_build_object('version',new.version));
 elsif new.version<>old.version and not (select portal_private.is_admin()) then
  insert into public.portal_company_events(company_id,actor_id,event,metadata) values(new.id,auth.uid(),'client_details_updated',jsonb_build_object('version',new.version));
 end if;
 return new;
end;$$;
revoke all on function portal_private.audit_company_change() from public,anon,authenticated;
create trigger audit_company_change after update on public.portal_companies for each row execute function portal_private.audit_company_change();
create or replace function public.approve_company_profile(p_company_id uuid,p_expected_version integer) returns void language plpgsql security definer set search_path='' as $$
declare details jsonb;k text;
begin
 if not (select portal_private.is_admin()) then raise exception 'Administrator required';end if;
 select c.details into details from public.portal_companies c where c.id=p_company_id and c.version=p_expected_version for update;
 if not found then raise exception 'Profile changed; refresh first';end if;
 if exists(select 1 from public.portal_companies where id=p_company_id and access_state='archived') then raise exception 'Restore this company before approval';end if;
 foreach k in array array['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL'] loop
  if trim(coalesce(details->>k,''))='' then raise exception 'Client must complete company details before approval';end if;
 end loop;
 update public.portal_companies set status='approved',approved_by=auth.uid(),approved_at=now() where id=p_company_id and version=p_expected_version;
end;$$;



create table public.commission_counters(year integer primary key,value integer not null);
revoke all on public.commission_counters from public,anon,authenticated;
create table public.commission_agreements(id uuid primary key default gen_random_uuid(),recipient uuid not null references public.portal_members(user_id),status text not null default 'draft' check(status in ('draft','awaiting_client','awaiting_approval','completed','cancelled')),version integer not null default 1,revision integer not null default 1,transaction_code text not null,data jsonb not null,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table public.commission_events(id bigint generated always as identity primary key,agreement_id uuid not null references public.commission_agreements(id),actor uuid not null,actor_email text not null,event text not null,created_at timestamptz not null default now());
create table public.commission_final_pdfs(agreement_id uuid primary key references public.commission_agreements(id),pdf_base64 text not null,sha256 text not null);
create table public.commission_assets(name text primary key check(name in ('signature','stamp')),png_base64 text not null);
alter table public.commission_agreements enable row level security;
alter table public.commission_events enable row level security;
alter table public.commission_final_pdfs enable row level security;
alter table public.commission_assets enable row level security;
revoke all on public.commission_agreements,public.commission_events,public.commission_final_pdfs,public.commission_assets from public,anon,authenticated;
grant select on public.commission_agreements,public.commission_events,public.commission_final_pdfs,public.commission_assets to authenticated;
create policy commission_read on public.commission_agreements for select to authenticated using ((select portal_private.is_admin()) or (recipient=(select auth.uid()) and status<>'draft' and (select portal_private.is_active())));
create policy commission_event_read on public.commission_events for select to authenticated using(exists(select 1 from public.commission_agreements a where a.id=agreement_id));
create policy commission_pdf_read on public.commission_final_pdfs for select to authenticated using(exists(select 1 from public.commission_agreements a where a.id=agreement_id and a.status='completed'));
create policy commission_asset_read on public.commission_assets for select to authenticated using((select portal_private.is_admin()));
create function public.commission_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}'::jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.commission_agreements;d jsonb;v jsonb;uid uuid:=auth.uid();adm boolean;email text;recipient_id uuid;y integer;n integer;k text;method text;fields text[];new_id uuid;pdf_bytes bytea;
begin
 if uid is null or not portal_private.is_active() then raise exception 'Active portal membership required';end if;
 adm:=portal_private.is_admin();select m.email into email from public.portal_members m where m.user_id=uid;
 if length(p_payload::text)>3500000 then raise exception 'Request too large';end if;
 if p_action='create' then
  if not adm then raise exception 'Administrator required';end if;
  recipient_id:=(p_payload->>'recipient')::uuid;
  if not exists(select 1 from public.portal_members m where m.user_id=recipient_id and m.active and not m.is_admin) then raise exception 'Select an active registered client';end if;
  y:=extract(year from now() at time zone 'Europe/Amsterdam');
  insert into public.commission_counters(year,value) values(y,1) on conflict(year) do update set value=public.commission_counters.value+1 returning value into n;
  d:='{}';foreach k in array array['title','services','scope','covered','formula','trigger','deadline'] loop d:=d||jsonb_build_object(k,left(trim(coalesce(p_payload->>k,'')),2000));end loop;
  d:=d||jsonb_build_object('transaction','NEX-COM-'||y||'-'||case when n<10000 then lpad(n::text,4,'0') else n::text end,'terms_version','2026-10-22');
  insert into public.commission_agreements(recipient,transaction_code,data) values(recipient_id,d->>'transaction',d) returning * into a;
 else
  select * into a from public.commission_agreements where id=p_id for update;
  if not found or (not adm and (a.recipient<>uid or a.status='draft')) then raise exception 'Agreement not found';end if;
  if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;
  d:=a.data;
  if p_action in ('save','issue','approve','cancel','revise') and not adm then raise exception 'Administrator required';end if;
  if p_action in ('client-save','sign') and (adm or a.recipient<>uid or a.status<>'awaiting_client') then raise exception 'Client action unavailable';end if;
  case p_action
  when 'save' then
   if a.status<>'draft' then raise exception 'Only drafts can be edited';end if;
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
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose bank or crypto';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   v:='{}';foreach k in array fields loop
    if jsonb_typeof(p_payload->'payment'->k) is distinct from 'string' or length(p_payload->'payment'->>k)>1000 then raise exception 'Invalid payment details';end if;
    v:=v||jsonb_build_object(k,trim(p_payload->'payment'->>k));end loop;d:=d||jsonb_build_object('payment',v);
  when 'sign' then
   foreach k in array array['legal_name','registration','address','country','representative','role','email','method'] loop if trim(coalesce(d->>k,''))='' then raise exception 'Complete client details';end if;end loop;
   if d->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email';end if;
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose a payment method';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   foreach k in array fields loop if trim(coalesce(d->'payment'->>k,''))='' then raise exception 'Complete payment details; mark unused fields Not applicable';end if;end loop;
   if p_payload->'authority' is distinct from 'true'::jsonb or p_payload->'accept' is distinct from 'true'::jsonb or p_payload->>'name' is distinct from d->>'representative' or p_payload->'reviewed' is distinct from 'true'::jsonb then raise exception 'Review the agreement and confirm authority, name and acceptance';end if;
   d:=d||jsonb_build_object('signed_payload_hash',encode(sha256(convert_to(d::text,'UTF8')),'hex'),'client_signature',jsonb_build_object('name',p_payload->>'name','at',now(),'account',email,'user_id',uid,'authority',true,'accepted',true,'method','typed name with authenticated portal acceptance'));
   a.status:='awaiting_approval';
  when 'approve' then
   if a.status<>'awaiting_approval' or p_payload->'verified' is distinct from 'true'::jsonb then raise exception 'Review beneficiary and verify payment instructions before approval';end if;
   if not exists(select 1 from public.commission_assets where name='signature') or not exists(select 1 from public.commission_assets where name='stamp') then raise exception 'Signature assets are not configured';end if;
   if length(coalesce(p_payload->>'pdf','')) not between 100 and 3000000 then raise exception 'Final PDF required';end if;
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
   insert into public.commission_agreements(recipient,version,transaction_code,data) values(a.recipient,a.version+1,a.transaction_code,v) returning id into new_id;
   insert into public.commission_events(agreement_id,actor,actor_email,event) values(new_id,uid,email,'revision_created');return new_id;
  else raise exception 'Unknown action';end case;
  update public.commission_agreements set status=a.status,data=d,revision=revision+1,updated_at=now() where id=a.id;
 end if;
 insert into public.commission_events(agreement_id,actor,actor_email,event) values(a.id,uid,email,p_action);return a.id;
end;$$;
revoke all on function public.commission_action(text,uuid,integer,jsonb) from public,anon;
grant execute on function public.commission_action(text,uuid,integer,jsonb) to authenticated;
create unique index commission_one_successor on public.commission_agreements ((data->>'previous_id')) where data ? 'previous_id';

select 'Commission workflow installed' as result;


create table public.portal_mcnda_assignments(id uuid primary key default gen_random_uuid(),user_id uuid not null references public.portal_members(user_id),template_version text not null default '2026-10-20',status text not null default 'assigned' check(status in ('assigned','completed','cancelled')),assigned_by uuid,assigned_at timestamptz not null default now(),submission_id uuid references public.portal_submissions(id) on delete set null,completed_at timestamptz);
create unique index mcnda_one_pending on public.portal_mcnda_assignments(user_id) where status='assigned';
alter table public.portal_mcnda_assignments enable row level security;
revoke all on public.portal_mcnda_assignments from public,anon,authenticated;
grant select on public.portal_mcnda_assignments to authenticated;
create policy mcnda_assignment_read on public.portal_mcnda_assignments for select to authenticated using((select portal_private.is_admin()) or (user_id=(select auth.uid()) and (select portal_private.is_active())));
-- Preserve and link previously completed portal MCNDAs. Do not issue new requests.
insert into public.portal_mcnda_assignments(user_id,status,assigned_at,submission_id,completed_at)
select user_id,'completed',created_at,id,created_at from public.portal_submissions where title ~* '^MCNDA[[:space:]]*-' and note like 'Completed and electronically signed via the VIP Capital portal.%';
create function public.assign_client_mcnda(p_user_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not portal_private.is_admin() then raise exception 'Administrator required';end if;
 if not exists(select 1 from public.portal_members where user_id=p_user_id and active and not is_admin) then raise exception 'Select an active client';end if;
 insert into public.portal_mcnda_assignments(user_id,assigned_by) values(p_user_id,auth.uid()) returning id into result;return result;
end;$$;
revoke all on function public.assign_client_mcnda(uuid) from public,anon;
grant execute on function public.assign_client_mcnda(uuid) to authenticated;
create function public.cancel_client_mcnda(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not portal_private.is_admin() then raise exception 'Administrator required';end if;
 update public.portal_mcnda_assignments set status='cancelled' where id=p_id and status='assigned';
 if not found then raise exception 'Only pending requests can be cancelled';end if;
end;$$;
revoke all on function public.cancel_client_mcnda(uuid) from public,anon;
grant execute on function public.cancel_client_mcnda(uuid) to authenticated;
create or replace function public.submit_company_mcnda(p_id uuid,p_details jsonb,p_expected_version integer,p_note text) returns public.portal_companies language plpgsql security definer set search_path='' as $$
declare company public.portal_companies;path text;request_id uuid;
begin
 if not portal_private.is_active() then raise exception 'Active account required';end if;
 select id into request_id from public.portal_mcnda_assignments where user_id=auth.uid() and status='assigned' for update;
 if not found then raise exception 'VIP Capital must assign an MCNDA to your account before you can submit it';end if;
 path:=auth.uid()::text||'/'||p_id::text||'.pdf';
 if not exists(select 1 from storage.objects where bucket_id='vip-client-uploads' and name=path) then raise exception 'Upload the PDF first';end if;
 if length(p_note)>2000 then raise exception 'Note too long';end if;
 company:=portal_private.save_company_details(p_details,p_expected_version);
 insert into public.portal_submissions(id,user_id,title,note,storage_path) values(p_id,auth.uid(),left('MCNDA - '||(company.details->>'B_COMPANY'),180),p_note,path);
 update public.portal_mcnda_assignments set status='completed',submission_id=p_id,completed_at=now() where id=request_id;
 return company;
end;$$;
drop policy if exists nda_template_member_read on storage.objects;
create policy nda_template_member_read on storage.objects for select to authenticated using(bucket_id='vip-documents' and name='nda-template-v20261020.pdf' and ((select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(select 1 from public.portal_mcnda_assignments where user_id=(select auth.uid()) and status='assigned'))));
create table public.portal_broker_clients(id uuid primary key default gen_random_uuid(),client_user_id uuid not null references public.portal_members(user_id),broker_user_id uuid not null references public.portal_members(user_id),created_by uuid not null,created_at timestamptz not null default now(),active boolean not null default true,unique(client_user_id,broker_user_id),check(client_user_id<>broker_user_id));
alter table public.portal_broker_clients enable row level security;
revoke all on public.portal_broker_clients from public,anon,authenticated;
grant select on public.portal_broker_clients to authenticated;
create policy broker_link_admin_read on public.portal_broker_clients for select to authenticated using((select portal_private.is_admin()));
create function public.link_client_broker(p_client uuid,p_broker uuid,p_active boolean default true) returns void language plpgsql security definer set search_path='' as $$
begin
 if not portal_private.is_admin() then raise exception 'Administrator required';end if;
 if not exists(select 1 from public.portal_members where user_id=p_client and active and not is_admin) or not exists(select 1 from public.portal_members where user_id=p_broker and active and not is_admin) or p_client=p_broker then raise exception 'Select two different active registered accounts';end if;
 insert into public.portal_broker_clients(client_user_id,broker_user_id,created_by,active) values(p_client,p_broker,auth.uid(),p_active) on conflict(client_user_id,broker_user_id) do update set active=excluded.active;
end;$$;
revoke all on function public.link_client_broker(uuid,uuid,boolean) from public,anon;
grant execute on function public.link_client_broker(uuid,uuid,boolean) to authenticated;
alter table public.commission_agreements add column client_user_id uuid references public.portal_members(user_id);
alter table public.portal_mcnda_assignments add column client_user_id uuid references public.portal_members(user_id);
create function public.assign_client_mcnda(p_user_id uuid,p_client_user_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not portal_private.is_admin() then raise exception 'Administrator required';end if;
 if not exists(select 1 from public.portal_members where user_id=p_user_id and active and not is_admin) then raise exception 'Select an active signer';end if;
 if p_user_id<>p_client_user_id and not exists(select 1 from public.portal_broker_clients where client_user_id=p_client_user_id and broker_user_id=p_user_id and active) then raise exception 'Link this broker to the client first';end if;
 insert into public.portal_mcnda_assignments(user_id,client_user_id,assigned_by) values(p_user_id,p_client_user_id,auth.uid()) returning id into result;return result;
end;$$;
revoke all on function public.assign_client_mcnda(uuid,uuid) from public,anon;
grant execute on function public.assign_client_mcnda(uuid,uuid) to authenticated;

create or replace function public.commission_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}'::jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.commission_agreements;d jsonb;v jsonb;uid uuid:=auth.uid();adm boolean;email text;recipient_id uuid;y integer;n integer;k text;method text;fields text[];new_id uuid;pdf_bytes bytea;client_id uuid;
begin
 if uid is null or not portal_private.is_active() then raise exception 'Active portal membership required';end if;
 adm:=portal_private.is_admin();select m.email into email from public.portal_members m where m.user_id=uid;
 if length(p_payload::text)>3500000 then raise exception 'Request too large';end if;
 if p_action='create' then
  if not adm then raise exception 'Administrator required';end if;
  recipient_id:=(p_payload->>'recipient')::uuid;
  if not exists(select 1 from public.portal_members m where m.user_id=recipient_id and m.active and not m.is_admin) then raise exception 'Select an active registered client';end if;
  client_id:=coalesce((p_payload->>'client_user_id')::uuid,recipient_id);
  if client_id<>recipient_id and not exists(select 1 from public.portal_broker_clients where client_user_id=client_id and broker_user_id=recipient_id and active) then raise exception 'Link the broker to this client first';end if;
  y:=extract(year from now() at time zone 'Europe/Amsterdam');
  insert into public.commission_counters(year,value) values(y,1) on conflict(year) do update set value=public.commission_counters.value+1 returning value into n;
  d:='{}';foreach k in array array['title','services','scope','covered','formula','trigger','deadline'] loop d:=d||jsonb_build_object(k,left(trim(coalesce(p_payload->>k,'')),2000));end loop;
  d:=d||jsonb_build_object('transaction','NEX-COM-'||y||'-'||case when n<10000 then lpad(n::text,4,'0') else n::text end,'terms_version','2026-10-22');
  insert into public.commission_agreements(recipient,client_user_id,transaction_code,data) values(recipient_id,client_id,d->>'transaction',d) returning * into a;
 else
  select * into a from public.commission_agreements where id=p_id for update;
  if not found or (not adm and (a.recipient<>uid or a.status='draft')) then raise exception 'Agreement not found';end if;
  if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;
  d:=a.data;
  if p_action in ('save','issue','approve','cancel','revise') and not adm then raise exception 'Administrator required';end if;
  if p_action in ('client-save','sign') and (adm or a.recipient<>uid or a.status<>'awaiting_client') then raise exception 'Client action unavailable';end if;
  case p_action
  when 'save' then
   if a.status<>'draft' then raise exception 'Only drafts can be edited';end if;
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
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose bank or crypto';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   v:='{}';foreach k in array fields loop
    if jsonb_typeof(p_payload->'payment'->k) is distinct from 'string' or length(p_payload->'payment'->>k)>1000 then raise exception 'Invalid payment details';end if;
    v:=v||jsonb_build_object(k,trim(p_payload->'payment'->>k));end loop;d:=d||jsonb_build_object('payment',v);
  when 'sign' then
   foreach k in array array['legal_name','registration','address','country','representative','role','email','method'] loop if trim(coalesce(d->>k,''))='' then raise exception 'Complete client details';end if;end loop;
   if d->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email';end if;
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose a payment method';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   foreach k in array fields loop if trim(coalesce(d->'payment'->>k,''))='' then raise exception 'Complete payment details; mark unused fields Not applicable';end if;end loop;
   if p_payload->'authority' is distinct from 'true'::jsonb or p_payload->'accept' is distinct from 'true'::jsonb or p_payload->>'name' is distinct from d->>'representative' or p_payload->'reviewed' is distinct from 'true'::jsonb then raise exception 'Review the agreement and confirm authority, name and acceptance';end if;
   d:=d||jsonb_build_object('signed_payload_hash',encode(sha256(convert_to(d::text,'UTF8')),'hex'),'client_signature',jsonb_build_object('name',p_payload->>'name','at',now(),'account',email,'user_id',uid,'authority',true,'accepted',true,'method','typed name with authenticated portal acceptance'));
   a.status:='awaiting_approval';
  when 'approve' then
   if a.status<>'awaiting_approval' or p_payload->'verified' is distinct from 'true'::jsonb then raise exception 'Review beneficiary and verify payment instructions before approval';end if;
   if not exists(select 1 from public.commission_assets where name='signature') or not exists(select 1 from public.commission_assets where name='stamp') then raise exception 'Signature assets are not configured';end if;
   if length(coalesce(p_payload->>'pdf','')) not between 100 and 3000000 then raise exception 'Final PDF required';end if;
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

drop policy if exists submission_insert on public.portal_submissions;
create policy submission_insert on public.portal_submissions for insert to authenticated with check(user_id=(select auth.uid()) and (select portal_private.is_active()) and status='received' and title !~* '^MCNDA' and note not like 'Completed and electronically signed via the VIP Capital portal.%');

select 'Client file and personal MCNDA assignment installed' as result;

-- Routing and intermediary instructions are optional; preserve all other payment validation.
create or replace function public.commission_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}'::jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.commission_agreements;d jsonb;v jsonb;uid uuid:=auth.uid();adm boolean;email text;recipient_id uuid;y integer;n integer;k text;method text;fields text[];new_id uuid;pdf_bytes bytea;client_id uuid;
begin
 if uid is null or not portal_private.is_active() then raise exception 'Active portal membership required';end if;
 adm:=portal_private.is_admin();select m.email into email from public.portal_members m where m.user_id=uid;
 if length(p_payload::text)>3500000 then raise exception 'Request too large';end if;
 if p_action='create' then
  if not adm then raise exception 'Administrator required';end if;
  recipient_id:=(p_payload->>'recipient')::uuid;
  if not exists(select 1 from public.portal_members m where m.user_id=recipient_id and m.active and not m.is_admin) then raise exception 'Select an active registered client';end if;
  client_id:=coalesce((p_payload->>'client_user_id')::uuid,recipient_id);
  if client_id<>recipient_id and not exists(select 1 from public.portal_broker_clients where client_user_id=client_id and broker_user_id=recipient_id and active) then raise exception 'Link the broker to this client first';end if;
  y:=extract(year from now() at time zone 'Europe/Amsterdam');
  insert into public.commission_counters(year,value) values(y,1) on conflict(year) do update set value=public.commission_counters.value+1 returning value into n;
  d:='{}';foreach k in array array['title','services','scope','covered','formula','trigger','deadline'] loop d:=d||jsonb_build_object(k,left(trim(coalesce(p_payload->>k,'')),2000));end loop;
  d:=d||jsonb_build_object('transaction','NEX-COM-'||y||'-'||case when n<10000 then lpad(n::text,4,'0') else n::text end,'terms_version','2026-10-22');
  insert into public.commission_agreements(recipient,client_user_id,transaction_code,data) values(recipient_id,client_id,d->>'transaction',d) returning * into a;
 else
  select * into a from public.commission_agreements where id=p_id for update;
  if not found or (not adm and (a.recipient<>uid or a.status='draft')) then raise exception 'Agreement not found';end if;
  if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;
  d:=a.data;
  if p_action in ('save','issue','approve','cancel','revise') and not adm then raise exception 'Administrator required';end if;
  if p_action in ('client-save','sign') and (adm or a.recipient<>uid or a.status<>'awaiting_client') then raise exception 'Client action unavailable';end if;
  case p_action
  when 'save' then
   if a.status<>'draft' then raise exception 'Only drafts can be edited';end if;
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
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose bank or crypto';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   v:='{}';foreach k in array fields loop
    if jsonb_typeof(p_payload->'payment'->k) is distinct from 'string' or length(p_payload->'payment'->>k)>1000 then raise exception 'Invalid payment details';end if;
    v:=v||jsonb_build_object(k,trim(p_payload->'payment'->>k));end loop;d:=d||jsonb_build_object('payment',v);
  when 'sign' then
   foreach k in array array['legal_name','registration','address','country','representative','role','email','method'] loop if trim(coalesce(d->>k,''))='' then raise exception 'Complete client details';end if;end loop;
   if d->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email';end if;
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose a payment method';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   foreach k in array fields loop if k not in ('routing','intermediary') and trim(coalesce(d->'payment'->>k,''))='' then raise exception 'Complete payment details; mark unused fields Not applicable';end if;end loop;
   if p_payload->'authority' is distinct from 'true'::jsonb or p_payload->'accept' is distinct from 'true'::jsonb or p_payload->>'name' is distinct from d->>'representative' or p_payload->'reviewed' is distinct from 'true'::jsonb then raise exception 'Review the agreement and confirm authority, name and acceptance';end if;
   d:=d||jsonb_build_object('signed_payload_hash',encode(sha256(convert_to(d::text,'UTF8')),'hex'),'client_signature',jsonb_build_object('name',p_payload->>'name','at',now(),'account',email,'user_id',uid,'authority',true,'accepted',true,'method','typed name with authenticated portal acceptance'));
   a.status:='awaiting_approval';
  when 'approve' then
   if a.status<>'awaiting_approval' or p_payload->'verified' is distinct from 'true'::jsonb then raise exception 'Review beneficiary and verify payment instructions before approval';end if;
   if not exists(select 1 from public.commission_assets where name='signature') or not exists(select 1 from public.commission_assets where name='stamp') then raise exception 'Signature assets are not configured';end if;
   if length(coalesce(p_payload->>'pdf','')) not between 100 and 3000000 then raise exception 'Final PDF required';end if;
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

-- Private reusable signing images; read only by their owner and active VIP Capital administrators.
create table if not exists public.portal_signing_profiles (
 user_id uuid primary key references public.portal_members(user_id),
 signature text not null, stamp text not null, version uuid not null default gen_random_uuid(), updated_at timestamptz not null default now()
);
alter table public.portal_signing_profiles enable row level security;
revoke all on public.portal_signing_profiles from anon,authenticated;
grant select on public.portal_signing_profiles to authenticated;
create policy signing_profiles_read on public.portal_signing_profiles for select to authenticated using (portal_private.is_active() and (user_id=auth.uid() or portal_private.is_admin()));
create or replace function public.save_my_signing_profile(p_signature text,p_stamp text,p_expected_version uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
declare previous uuid; fresh uuid:=gen_random_uuid(); img text; raw bytea;
begin
 if auth.uid() is null or not portal_private.is_active() or portal_private.is_admin() then raise exception 'Active client account required';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
 select version into previous from public.portal_signing_profiles where user_id=auth.uid() for update;
 if previous is distinct from p_expected_version then raise exception 'Signing images changed; refresh and try again';end if;
 foreach img in array array[p_signature,p_stamp] loop
  if img is null or length(img) not between 50 and 900000 or img not like 'data:image/png;base64,%' then raise exception 'Upload PNG signing images, maximum 650 KB each';end if;
  raw:=decode(substring(img from 23),'base64');
  if substring(raw from 1 for 8)<>decode('89504e470d0a1a0a','hex') then raise exception 'Invalid PNG image';end if;
 end loop;
 insert into public.portal_signing_profiles(user_id,signature,stamp,version) values(auth.uid(),p_signature,p_stamp,fresh)
 on conflict(user_id) do update set signature=excluded.signature,stamp=excluded.stamp,version=excluded.version,updated_at=now();
 return fresh;
end;$$;
revoke all on function public.save_my_signing_profile(text,text,uuid) from public,anon;
grant execute on function public.save_my_signing_profile(text,text,uuid) to authenticated;

create or replace function public.commission_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}'::jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.commission_agreements;d jsonb;v jsonb;uid uuid:=auth.uid();adm boolean;email text;recipient_id uuid;y integer;n integer;k text;method text;fields text[];new_id uuid;pdf_bytes bytea;client_id uuid;signing public.portal_signing_profiles;
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
  d:=d||jsonb_build_object('transaction','NEX-COM-'||y||'-'||case when n<10000 then lpad(n::text,4,'0') else n::text end,'terms_version','2026-10-22');
  insert into public.commission_agreements(recipient,client_user_id,transaction_code,data) values(recipient_id,client_id,d->>'transaction',d) returning * into a;
 else
  select * into a from public.commission_agreements where id=p_id for update;
  if not found or (not adm and (a.recipient<>uid or a.status='draft')) then raise exception 'Agreement not found';end if;
  if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;
  d:=a.data;
  if p_action in ('save','issue','approve','cancel','revise') and not adm then raise exception 'Administrator required';end if;
  if p_action in ('client-save','sign') and (adm or a.recipient<>uid or a.status<>'awaiting_client') then raise exception 'Client action unavailable';end if;
  case p_action
  when 'save' then
   if a.status<>'draft' then raise exception 'Only drafts can be edited';end if;
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
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose bank or crypto';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   v:='{}';foreach k in array fields loop
    if jsonb_typeof(p_payload->'payment'->k) is distinct from 'string' or length(p_payload->'payment'->>k)>1000 then raise exception 'Invalid payment details';end if;
    v:=v||jsonb_build_object(k,trim(p_payload->'payment'->>k));end loop;d:=d||jsonb_build_object('payment',v);
  when 'sign' then
   foreach k in array array['legal_name','registration','address','country','representative','role','email','method'] loop if trim(coalesce(d->>k,''))='' then raise exception 'Complete client details';end if;end loop;
   if d->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email';end if;
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose a payment method';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   foreach k in array fields loop if k not in ('routing','intermediary') and trim(coalesce(d->'payment'->>k,''))='' then raise exception 'Complete payment details; mark unused fields Not applicable';end if;end loop;
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


-- Advance the 2026 sequence without reusing or changing existing transaction codes.
lock table public.commission_counters in share row exclusive mode;
insert into public.commission_counters(year,value)
select 2026,greatest(44,coalesce(max(split_part(transaction_code,'-',4)::integer),0)) from public.commission_agreements where transaction_code ~ '^NEX-COM-2026-[0-9]+$'
on conflict(year) do update set value=greatest(public.commission_counters.value,excluded.value);
create or replace function public.commission_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}'::jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.commission_agreements;d jsonb;v jsonb;uid uuid:=auth.uid();adm boolean;email text;recipient_id uuid;y integer;n integer;k text;method text;fields text[];new_id uuid;pdf_bytes bytea;client_id uuid;signing public.portal_signing_profiles;
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
  d:=d||jsonb_build_object('transaction','NEX-COM-'||y||'-'||n::text,'terms_version','2026-10-22');
  insert into public.commission_agreements(recipient,client_user_id,transaction_code,data) values(recipient_id,client_id,d->>'transaction',d) returning * into a;
 else
  select * into a from public.commission_agreements where id=p_id for update;
  if not found or (not adm and (a.recipient<>uid or a.status='draft')) then raise exception 'Agreement not found';end if;
  if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;
  d:=a.data;
  if p_action in ('save','issue','approve','cancel','revise') and not adm then raise exception 'Administrator required';end if;
  if p_action in ('client-save','sign') and (adm or a.recipient<>uid or a.status<>'awaiting_client') then raise exception 'Client action unavailable';end if;
  case p_action
  when 'save' then
   if a.status<>'draft' then raise exception 'Only drafts can be edited';end if;
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
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose bank or crypto';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   v:='{}';foreach k in array fields loop
    if jsonb_typeof(p_payload->'payment'->k) is distinct from 'string' or length(p_payload->'payment'->>k)>1000 then raise exception 'Invalid payment details';end if;
    v:=v||jsonb_build_object(k,trim(p_payload->'payment'->>k));end loop;d:=d||jsonb_build_object('payment',v);
  when 'sign' then
   foreach k in array array['legal_name','registration','address','country','representative','role','email','method'] loop if trim(coalesce(d->>k,''))='' then raise exception 'Complete client details';end if;end loop;
   if d->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Invalid email';end if;
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose a payment method';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   foreach k in array fields loop if k not in ('routing','intermediary') and trim(coalesce(d->'payment'->>k,''))='' then raise exception 'Complete payment details; mark unused fields Not applicable';end if;end loop;
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


select 'NEX-COM-'||year||'-'||(value+1)::text as next_transaction_code from public.commission_counters where year=2026;

-- Crypto requires only wallet and exact network. Preserve all other agreement and signature controls.

create or replace function public.commission_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}'::jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare a public.commission_agreements;d jsonb;v jsonb;uid uuid:=auth.uid();adm boolean;email text;recipient_id uuid;y integer;n integer;k text;method text;fields text[];new_id uuid;pdf_bytes bytea;client_id uuid;signing public.portal_signing_profiles;
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
  d:=d||jsonb_build_object('transaction','NEX-COM-'||y||'-'||n::text,'terms_version','2026-10-22');
  insert into public.commission_agreements(recipient,client_user_id,transaction_code,data) values(recipient_id,client_id,d->>'transaction',d) returning * into a;
 else
  select * into a from public.commission_agreements where id=p_id for update;
  if not found or (not adm and (a.recipient<>uid or a.status='draft')) then raise exception 'Agreement not found';end if;
  if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;
  d:=a.data;
  if p_action in ('save','issue','approve','cancel','revise') and not adm then raise exception 'Administrator required';end if;
  if p_action in ('client-save','sign') and (adm or a.recipient<>uid or a.status<>'awaiting_client') then raise exception 'Client action unavailable';end if;
  case p_action
  when 'save' then
   if a.status<>'draft' then raise exception 'Only drafts can be edited';end if;
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
   method:=d->>'method';if method not in ('bank','crypto') then raise exception 'Choose bank or crypto';end if;
   fields:=case when method='bank' then array['holder','holder_address','bank','bank_address','country','account','iban','swift','routing','intermediary','reference'] else array['asset','network','wallet','memo','price_source','valuation','fees','confirmations','verification'] end;
   v:='{}';foreach k in array fields loop
    if ((p_payload->'payment') ? k) and (jsonb_typeof(p_payload->'payment'->k) is distinct from 'string' or length(p_payload->'payment'->>k)>1000) then raise exception 'Invalid payment details';end if;
    v:=v||jsonb_build_object(k,trim(coalesce(p_payload->'payment'->>k,'')));end loop;d:=d||jsonb_build_object('payment',v);
  when 'sign' then
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


select 'Crypto requires wallet and network only' as result;


alter table public.portal_document_access add column if not exists can_download boolean not null default true;
alter table public.portal_documents add column if not exists default_can_download boolean not null default true;
create table if not exists public.portal_document_previews (
 document_id uuid primary key references public.portal_documents(id) on delete cascade,
 storage_prefix text not null check(storage_prefix ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}$'),
 page_count integer not null check(page_count between 1 and 200),
 source_sha256 text not null check(source_sha256 ~ '^[0-9a-f]{64}$'),
 created_at timestamptz not null default now()
);
alter table public.portal_document_previews enable row level security;
revoke all on public.portal_document_previews from anon,authenticated;
grant select,insert,update,delete on public.portal_document_previews to authenticated;
create policy document_preview_read on public.portal_document_previews for select to authenticated using (
 (select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(
 select 1 from public.portal_document_access a join public.portal_documents d on d.id=a.document_id
 where a.document_id=portal_document_previews.document_id and a.user_id=(select auth.uid()) and d.published))
);
create policy document_preview_manage on public.portal_document_previews for all to authenticated using((select portal_private.is_admin())) with check((select portal_private.is_admin()));
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('vip-document-previews','vip-document-previews',false,5242880,array['image/webp']) on conflict(id) do nothing;
create policy document_preview_page_read on storage.objects for select to authenticated using(
 bucket_id='vip-document-previews' and ((select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(
 select 1 from public.portal_document_previews p join public.portal_document_access a on a.document_id=p.document_id join public.portal_documents d on d.id=p.document_id
 where a.user_id=(select auth.uid()) and d.published and name like p.storage_prefix||'/%')))
);
create policy document_preview_page_write on storage.objects for insert to authenticated with check(bucket_id='vip-document-previews' and (select portal_private.is_admin()));
create policy document_preview_page_delete on storage.objects for delete to authenticated using(bucket_id='vip-document-previews' and (select portal_private.is_admin()));
-- Retain private metadata access for preview-only recipients, but deny original PDF bytes.
drop policy if exists nexora_file_read on storage.objects;
create policy nexora_file_read on storage.objects for select to authenticated using(
 bucket_id='vip-documents' and ((select portal_private.is_admin()) or ((select portal_private.is_active()) and exists(
 select 1 from public.portal_documents d join public.portal_document_access a on a.document_id=d.id
 where d.storage_path=storage.objects.name and d.published and a.user_id=(select auth.uid()) and a.can_download)))
);
-- A preview-only grant cannot be enabled before private page previews are ready.
create or replace function portal_private.require_document_preview() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not new.can_download and not exists(select 1 from public.portal_document_previews where document_id=new.document_id) then raise exception 'Prepare the private document preview before enabling preview-only access';end if;
 return new;
end;$$;
create trigger require_document_preview before insert or update of can_download,document_id on public.portal_document_access for each row execute function portal_private.require_document_preview();

select 'Per-recipient preview and download permissions installed' as result;


create table public.spa_templates(version text primary key,terms jsonb not null,products jsonb not null,created_at timestamptz not null default now());
create table public.spa_counters(year integer primary key,value integer not null);
create table public.spa_agreements(id uuid primary key default gen_random_uuid(),recipient uuid not null references public.portal_members(user_id),company_id uuid not null references public.portal_companies(id),template_version text not null references public.spa_templates(version),transaction_code text not null,version integer not null default 1,revision integer not null default 1,status text not null default 'draft' check(status in ('draft','awaiting_client','awaiting_approval','completed','cancelled')),data jsonb not null,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),created_by uuid not null references public.portal_members(user_id),unique(transaction_code,version));
create index spa_recipient on public.spa_agreements(recipient,created_at desc);
create table public.spa_events(id bigint generated always as identity primary key,agreement_id uuid not null references public.spa_agreements(id),actor uuid not null,actor_email text not null,event text not null,details jsonb not null default '{}',created_at timestamptz not null default now());
create table public.spa_final_pdfs(agreement_id uuid primary key references public.spa_agreements(id),pdf_base64 text not null,pdf_sha256 text not null,created_at timestamptz not null default now());
create table public.spa_reviews(token uuid primary key default gen_random_uuid(),agreement_id uuid not null references public.spa_agreements(id),actor uuid not null,revision integer not null,payload_hash text not null,asset_version uuid,created_at timestamptz not null default now());
alter table public.spa_templates enable row level security;
alter table public.spa_agreements enable row level security;
alter table public.spa_events enable row level security;
alter table public.spa_final_pdfs enable row level security;
alter table public.spa_counters enable row level security;
alter table public.spa_reviews enable row level security;
revoke all on public.spa_templates,public.spa_agreements,public.spa_events,public.spa_final_pdfs,public.spa_counters,public.spa_reviews from public,anon,authenticated;
grant select on public.spa_templates,public.spa_agreements,public.spa_events,public.spa_final_pdfs to authenticated;
create policy spa_template_read on public.spa_templates for select to authenticated using((select portal_private.is_active()));
create policy spa_agreement_read on public.spa_agreements for select to authenticated using((select portal_private.is_active()) and ((select portal_private.is_admin()) or (recipient=(select auth.uid()) and status<>'draft')));
create policy spa_event_read on public.spa_events for select to authenticated using(exists(select 1 from public.spa_agreements a where a.id=agreement_id));
create policy spa_pdf_read on public.spa_final_pdfs for select to authenticated using(exists(select 1 from public.spa_agreements a where a.id=agreement_id and a.status='completed'));
insert into public.spa_templates(version,terms,products) values('2026-10-23-v1',$terms$[["1", "Binding scope and conditions", "Seller shall sell and Buyer shall purchase the quantities in Schedule A. Before the first advance, each party shall complete counterparty and signatory verification; the permitted origin, terminal, price formula, specification and shipment programme must be agreed. No supply obligation is deemed satisfied merely by sending allocation documents. No party warrants future market prices or an unverified third party's capacity."], ["2", "Quantity, measurement and price", "One MT means 1,000 kg. Loading quantity is the independent inspector's certified net mass, excluding free water and sediment, calculated from calibrated shore measurements and density at 15 degrees C using the agreed petroleum measurement method. Vessel figures are a cross-check. Schedule C must name the applicable measurement standards, calibration and reconciliation procedure. The B/L, inspection report and invoice shall be consistent; any material discrepancy must be resolved before the final balance falls due. Seller may not invoice tolerances twice. Freight is included in the CFR differential; marine cargo insurance is not. Export charges are Seller's; destination taxes, lawful import duties and Buyer's inland logistics are Buyer's. Unloading charges included in Seller's carriage contract may not be charged again to Buyer."], ["3", "30% advance by bank transfer", "For each cargo, Seller issues a provisional invoice using the nominated quantity and the Schedule A benchmark averaged over the three publication days before that invoice. Before payment Seller supplies the agreed preliminary package in Schedule C and permits independent verification directly with the issuer using independently verified contact details. Buyer pays 30% of the provisional invoice in cleared USD funds within two Banking Days after receiving that package and the verified invoice, and no later than five Banking Days before the agreed laycan, unless Schedule C fixes another date. If the timetable is impossible the parties first revise the Shipment Order in writing. Payment is to Seller's verified account only. Allocation letters and preliminary documents do not themselves transfer title or constitute a bank or performance guarantee."], ["4", "70% balance and final reconciliation", "After loading, Seller supplies readable copies of the complete final documentary package through the agreed secure channel. Final price and quantity determine the final invoice. The amount due is the final invoice less the advance actually credited (normally about 70%; it may differ after reconciliation). Buyer shall identify specific documentary defects within one Banking Day of receipt; Seller shall promptly cure them. The undisputed compliant balance is payable in cleared USD funds within two Banking Days after receipt of the complete compliant package and final invoice. A genuine defect affecting title, shipment identity, quantity, quality or legality suspends only the affected amount until cured. No new documentary requirement may be added unilaterally. Seller retains control of the negotiable originals pending cleared final payment and releases or endorses them within one Banking Day thereafter. Schedule C must ensure the carrier accepts this sequence without disrupting the voyage or lawful discharge."], ["5", "Failure to load and refund", "The shipment longstop is ten calendar days after the final agreed laycan date, unless extended in a signed amendment. If Seller fails to load by that date, Buyer may terminate the affected Shipment Order by notice and Seller shall refund its unused advance within five Banking Days. No deduction is permitted for Seller's financing or unperformed supply costs. If the Buyer defaults, Seller may recover only documented recoverable direct losses, account for avoided costs and resale proceeds, and refund any surplus advance; the advance is not automatically forfeited. Overpayments are refunded within five Banking Days of reconciliation. Force majeure or sanctions do not allow indefinite retention of an advance for undelivered cargo."], ["6", "Risk and ownership", "Under CFR Incoterms 2020, risk passes when the cargo is placed on board the nominated vessel at the loading port. The inspector's loading completion record is evidence of that event; reference to a flange does not independently replace this Incoterms delivery point. Seller remains liable for its own breach and any non-conformity existing at risk transfer. Title to the identified shipment passes upon Seller's receipt of the full final invoice in cleared funds and transfer of the corresponding endorsed negotiable transport document or legally effective electronic equivalent. Seller warrants lawful authority and good title free from liens and third-party claims at transfer. Before title passes Buyer has an insurable interest arising from the risk allocation. The parties shall obtain advice on any mandatory property law applicable to the cargo location; this clause does not purport to bind a carrier or other third party."], ["7", "Insurance and freight", "Seller contracts and pays for carriage to the named discharge port and supplies the relevant carriage terms and restrictions before the advance. Buyer shall arrange marine cargo cover, including the agreed war and other route risks, effective from risk transfer through its intended transit and storage exposure, and provide insurer/broker evidence before loading. Seller must not load without that evidence or an agreed written solution. Vessel P&amp;I and hull cover do not replace Buyer's cargo insurance. Seller provides voyage and claim information reasonably needed by Buyer and its insurer. No CIF insurance undertaking is implied."], ["8", "Vessel and terminal nominations", "Seller nominates a suitable clean-products vessel at least ten calendar days before laycan with name, IMO, flag, class, Q88, P&amp;I, ETA and last three cargoes. Buyer accepts or gives documented reasonable objections within 48 hours. Replacement vessels require the same checks. Vessels must satisfy applicable SOLAS, MARPOL, ISM, ISPS, sanctions and terminal vetting requirements, including applicable SIRE/OCIMF requirements. Buyer confirms a safe compatible berth, receiving capacity, draft, connections, pumping limits and import/terminal approvals before loading. ETA updates are provided at 120, 72, 48, 24 and 12 hours where operationally available. A voyage is not required to wait for final payment where that conflicts with the agreed carrier arrangements; delivery of document copies does not itself release cargo."], ["9", "Laytime, demurrage and costs", "Schedule C must state the incorporated charterparty provisions or a complete agreed extract, allowed laytime, demurrage rate and currency, valid Notice of Readiness requirements, commencement, exclusions, pumping warranty, weather/port treatment and despatch, if any. No undisclosed charterparty term binds Buyer. Costs are allocated to the party whose breach or agreed sphere of responsibility caused them, subject to mitigation and evidence; Buyer is not liable for Seller or carrier fault merely because a delay occurs at destination. Claims require a calculation, NOR, statement of facts, time sheets and supporting invoices within 60 calendar days after discharge, failing which the claim is barred except fraud or mandatory law."], ["10", "Safety and permits", "Seller is responsible for lawful export and safe loading within its control; Buyer for import permits, excise/customs arrangements and safe receiving/storage facilities within its control. Seller supplies current safety data and legally required cargo information. Both parties cooperate on spill response, terminal compatibility and incident reporting. Risk transfer does not discharge either party's statutory environmental duties or liability for its own conduct. Tank-to-tank, dip-and-pay and terminal-transfer structures are outside this CFR template and require a separately executed agreement."], ["11", "Specification and independent inspection", "Product shall meet the fixed EN 590 edition and destination/seasonal grade agreed in Schedule B, including all applicable parameters, not merely sulphur. Seller pays the agreed independent loading inspection, issued directly by the appointed inspector. The certificate is conclusive evidence of loading quality and quantity absent fraud or manifest error; it does not excuse latent non-conformity existing at risk transfer or Seller-caused contamination. Buyer may inspect at discharge at its cost without reopening a correctly determined loading result solely because transit loss or destination contamination occurred. Normal voyage loss is not evidence of a loading shortage."], ["12", "Sampling, notice and remedies", "The inspector takes representative sealed samples of each shipment under the agreed standard, identifying tank/lot, date, location, seals and chain of custody. Three sets are retained by inspector/Seller/Buyer or held to their order for at least 180 days after discharge, longer if a timely claim remains open. Buyer notifies apparent quality/quantity claims within seven Banking Days after discharge, with available evidence; a latent defect not reasonably discoverable then must be notified within seven Banking Days of discovery and in any event within 90 calendar days of discharge, except fraud or mandatory law. Evidence not yet available follows promptly. Failure bars the affected claim only, not unrelated rights. For a disputed test, parties appoint an independent accredited laboratory within five Banking Days; failing agreement, either may request appointment by the ICC International Centre for ADR under its applicable appointment rules. The expert determines the technical test issue only, subject to fraud or manifest error; legal liability remains for arbitration. For proven pre-transfer non-conformity, Buyer may seek an agreed price reduction, prompt replacement or rejection/refund for a material defect, plus recoverable direct losses under clause 15. No automatic acceptance applies to fuel outside mandatory specification. Destination contamination or Buyer's improper handling is Buyer's responsibility to the extent causative."], ["13", "Sanctions, origin and integrity", "Each party complies with laws applicable to it and the transaction, including relevant EU, UN, UK and US sanctions where applicable, AML, anti-bribery, export/import and end-use rules. Neither party is required to act contrary to mandatory law applicable to it. Before advance and again before loading, Seller supplies the refinery/production country, origin and routing evidence, and evidence of crude feedstock provenance where applicable, sufficient for the destination's restrictions. A third-country refining certificate alone is not conclusive proof of permitted crude origin. No prohibited blending, evasion, concealment, vessel or bank may be used. Both parties supply verified corporate, UBO, authority and source-of-funds information reasonably required; it is confidential and limited to lawful transaction purposes. Neither party is obligated to accept physical cash, third-party account payments or undisclosed intermediaries. Anti-bribery applies to all agents and fees."], ["14", "Compliance suspension", "A party may suspend the affected performance on a documented reasonable concern of illegality, sanctions, fraud or AML breach, promptly notifying the other to the extent lawful. It requests evidence and reviews it without unreasonable delay; suspicion alone is not an unrestricted right to retain money or cancel unrelated shipments. If performance is unlawful or the material concern is not resolved within ten Banking Days, either party may terminate the affected shipment; unused advances are refunded within five Banking Days, subject only to mandatory asset-freeze rules. Required funds remain segregated in accounting records pending lawful disposition. No clause requires prohibited payment or disclosure."], ["15", "Default and liability", "A material breach not cured within ten Banking Days after a notice specifying it permits termination of the affected shipment; repeated or fundamental breach may justify master termination. For overdue payment Seller may suspend the affected shipment immediately on notice and terminate it after five Banking Days without cure. No cure period is required for irremediable fraud, prohibited performance or insolvency to the extent lawful. Termination does not prejudice accrued payment, refund or claim rights. Parties mitigate losses and avoid double recovery. Each party's aggregate liability for claims arising from a shipment is capped at its final invoice value. This cap does not limit Buyer's price debt, Seller's refund obligations, title obligations, fraud, wilful misconduct, bribery, sanctions breach or liability that cannot lawfully be limited. Neither party recovers indirect/consequential loss, lost profit or punitive damages, subject to those same exceptions. Proven reasonable direct cover, inspection, freight or disposal loss is not excluded solely because it is a third-party cost."], ["16", "Force majeure and hardship", "Relief requires proof that performance is prevented by an event beyond reasonable control, not reasonably foreseeable at execution and not reasonably avoidable or overcome. Notice is due promptly and within five Banking Days, stating impact, evidence, mitigation and expected duration. A supplier failure qualifies only if the underlying event and inability reasonably to source an alternative meet that test. Price movement, reduced margin, lack of funds or inability to obtain financing alone do not qualify. Relief is limited to the affected obligation and duration; accrued payment and refund obligations remain due unless payment itself is legally prohibited. After 90 consecutive calendar days either party may terminate affected undelivered shipments and recover unused advances under clause 5. Material exceptional hardship prompts good-faith discussions for 15 Banking Days but does not permit unilateral price amendment or suspension; unresolved disputes follow clause 17."], ["17", "Law and disputes", "This Agreement and non-contractual obligations arising from it are governed by the laws of England and Wales, excluding conflict-of-law rules. The CISG is expressly excluded to the extent it might otherwise apply. Disputes, including formation, validity, performance and termination, are finally resolved under the ICC Rules of Arbitration by one arbitrator appointed under those Rules. Seat: London, United Kingdom. Language: English. The award is binding. A party may seek urgent interim relief from a competent court without waiving arbitration. Technical expert findings under clause 12 bind only within their stated scope."], ["18", "Confidentiality and intermediaries", "Commercial terms, prices, banking and due-diligence records are confidential, except disclosure to authorized personnel, verified transaction counterparties, banks, insurers, professional advisers or authorities on a need-to-know/legal basis. Existing MCNDA obligations continue; this clause creates no disclosure right over another client's or broker's confidential terms. Commissions, if any, are governed only by separate signed agreements; a broker has no authority to bind Seller or Buyer without express written authority. No partnership, agency or fiduciary relationship is created. Neither party may assign contractual obligations without prior written consent; an assignment of receivables does not change payment instructions without clause 19 verification."], ["19", "Notices and payment fraud protection", "Banking Day means a day on which commercial banks are open for USD transfers in New York and in the receiving account jurisdiction, excluding weekends/public holidays. Notices use the verified emails on page 1; receipt is the recipient's acknowledgement or verifiable delivery into its designated system, with after-hours receipt treated as the next Banking Day. Bank changes require a signed instruction, secure transmission and an independent callback to a previously verified number, never a number supplied only in the change message. A transfer to an unverified substitute account does not discharge the debt unless the proper creditor authorized or ratified it, subject to applicable law and proven allocation of fault. Both parties promptly report suspected compromise, request bank recall and preserve evidence. Payment instructions cannot be changed by a bare email or chat message."], ["20", "Entire agreement, precedence and execution", "This Agreement supersedes prior commercial negotiations; separate confidentiality and commission agreements survive in their respective scope. Mandatory law prevails, followed by a later signed amendment expressly identifying the changed clause, completed Schedule A, the main clauses, Schedule B, and an accepted Shipment Order for shipment-specific operational matters. An order cannot silently override payment, liability, title or dispute terms. Invoices and third-party carriage terms do not amend the SPA. Changes require both parties' authorized signatures. Electronic counterparts and agreed electronic signatures may constitute originals without subsequent paper exchange. Identity, authority, signature consent, exact document version and delivery must be evidenced; a pasted image alone does not establish qualified-signature status. Severability, accrued rights and non-waiver apply. Confidentiality, payment/refund, liability and dispute clauses survive termination."]]$terms$::jsonb,$products${"EN590": {"name": "EN590 10 ppm ULSD", "standard": "EN 590:2025", "fields": [["sulphur", "Maximum sulphur / unit"], ["fame", "FAME grade / maximum"], ["cfpp", "Seasonal class / CFPP"], ["density", "Density range / reference temperature"]]}, "RON95": {"name": "RON95 unleaded petrol", "standard": "EN 228:2025", "fields": [["ron", "Minimum RON"], ["mon", "Minimum MON"], ["ethanol", "E5 / E10 and oxygen limits"], ["vapour", "Seasonal vapour-pressure class"]]}, "JET_A1": {"name": "Jet A-1 aviation turbine fuel", "standard": "ASTM D1655-26b", "fields": [["freeze", "Maximum freezing point"], ["flash", "Minimum flash point"], ["additives", "Approved additives / limits"], ["aviation", "Aviation quality / release requirements"]]}}$products$::jsonb);

create function portal_private.spa_profile(p_recipient uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare c public.portal_companies;
begin
 select co.* into c from public.portal_companies co join public.portal_company_members m on m.company_id=co.id where m.user_id=p_recipient;
 if not found or c.access_state<>'active' then raise exception 'Select a client with an active company profile';end if;
 return jsonb_build_object('buyer',c.details->>'B_COMPANY','registration',c.details->>'B_REGISTRATION','buyer_address',c.details->>'B_ADDRESS','buyer_country',c.details->>'B_COUNTRY','representative',c.details->>'B_REPRESENTATIVE','buyer_role',c.details->>'B_TITLE','buyer_email',c.details->>'B_EMAIL','buyer_profile_id',c.id,'buyer_profile_version',c.version,'buyer_profile_snapshot',c.details,'buyer_profile_status',c.status);
end;$$;
revoke all on function portal_private.spa_profile(uuid) from public,anon,authenticated;
create function portal_private.spa_edit_fields(p_data jsonb) returns jsonb language plpgsql set search_path='' as $$
declare d jsonb:='{}'; k text; t jsonb:='{}';
begin
 if jsonb_typeof(p_data) is distinct from 'object' or length(p_data::text)>100000 then raise exception 'Invalid commercial details';end if;
 foreach k in array array['title','product','standard','incoterm','law','quantity','months','lot','start','benchmark','differential','price_calendar','season','specification','inspector','sampling','measurement','load_port','discharge_port','origin','refinery','laycan','longstop','laytime','demurrage','nor','carriage','insurance','bank_holder','bank_name','bank_address','bank_country','iban','swift','routing'] loop
 if jsonb_typeof(p_data->k) not in ('string','number') and p_data ? k then raise exception 'Invalid field %',k;end if;
 if length(coalesce(p_data->>k,''))>(case when k in ('specification','carriage','insurance') then 12000 else 2000 end) then raise exception 'Field % is too long',k;end if;
 d:=d||jsonb_build_object(k,trim(coalesce(p_data->>k,'')));end loop;
 foreach k in array array['sulphur','fame','cfpp','density','ron','mon','ethanol','vapour','freeze','flash','additives','aviation'] loop
 if length(coalesce(p_data->'technical'->>k,''))>2000 then raise exception 'Technical field too long';end if;
 t:=t||jsonb_build_object(k,trim(coalesce(p_data->'technical'->>k,'')));end loop;
 d:=d||jsonb_build_object('technical',t,'spec_confirmed',p_data->'spec_confirmed'='true'::jsonb,'commercial_confirmed',p_data->'commercial_confirmed'='true'::jsonb,'bank_verified',p_data->'bank_verified'='true'::jsonb);
 return d;
end;$$;
revoke all on function portal_private.spa_edit_fields(jsonb) from public,anon,authenticated;
create function portal_private.spa_validate(d jsonb) returns void language plpgsql set search_path='' as $$
declare k text; fields text[];
begin
 foreach k in array array['buyer','registration','buyer_address','buyer_country','representative','buyer_role','buyer_email','product','standard','quantity','months','lot','start','incoterm','load_port','discharge_port','origin','refinery','benchmark','differential','price_calendar','inspector','sampling','measurement','specification','season','laycan','longstop','laytime','demurrage','nor','carriage','insurance','bank_holder','bank_name','bank_address','bank_country','iban','swift'] loop
 if trim(coalesce(d->>k,''))='' then raise exception 'Complete % before assignment',replace(k,'_',' ');end if;end loop;
 if d->>'product' not in ('EN590','RON95','JET_A1') or d->>'incoterm' not in ('FOB','CFR','CIF') or d->>'law' not in ('ENGLISH','DUTCH') then raise exception 'Select product, delivery rule and governing law';end if;
 foreach k in array array['quantity','months','lot'] loop
 if d->>k !~ '^[0-9]+([.][0-9]+)?$' or (d->>k)::numeric<=0 or (d->>k)::numeric>1000000000 then raise exception 'Invalid %',k;end if;end loop;
 if (d->>'months')::numeric<>trunc((d->>'months')::numeric) or (d->>'months')::numeric>120 then raise exception 'Duration must be 1 to 120 whole months';end if;
 if d->>'differential' !~ '^-?[0-9]+([.][0-9]+)?$' then raise exception 'Differential must be numeric';end if;
 if (d->>'start')::date<date '2020-01-01' then raise exception 'Invalid start date';end if;
 if d->>'buyer_email' !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then raise exception 'Company profile business email is invalid';end if;
 fields:=case d->>'product' when 'EN590' then array['sulphur','fame','cfpp','density'] when 'RON95' then array['ron','mon','ethanol','vapour'] else array['freeze','flash','additives','aviation'] end;
 foreach k in array fields loop if trim(coalesce(d->'technical'->>k,''))='' then raise exception 'Complete product specification: %',k;end if;end loop;
 if d->'spec_confirmed' is distinct from 'true'::jsonb or d->'commercial_confirmed' is distinct from 'true'::jsonb or d->'bank_verified' is distinct from 'true'::jsonb then raise exception 'Confirm complete specification, commercial terms and independently verified banking instructions';end if;
end;$$;
revoke all on function portal_private.spa_validate(jsonb) from public,anon,authenticated;
create function public.spa_review(p_id uuid,p_revision integer,p_asset_version uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.spa_agreements; r public.spa_reviews; profile public.portal_signing_profiles; h text;
begin
 if not portal_private.is_active() then raise exception 'Active account required';end if;
 select * into a from public.spa_agreements where id=p_id;
 if not found or (not portal_private.is_admin() and (a.recipient<>auth.uid() or a.status='draft')) then raise exception 'Agreement not found';end if;
 if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh';end if;
 if not portal_private.is_admin() and a.status='awaiting_client' then
 select * into profile from public.portal_signing_profiles where user_id=auth.uid();
 if not found or profile.version is distinct from p_asset_version then raise exception 'Save signature and stamp, then review again';end if;
 end if;
 h:=encode(sha256(convert_to(a.data::text,'UTF8')),'hex');
 insert into public.spa_reviews(agreement_id,actor,revision,payload_hash,asset_version) values(a.id,auth.uid(),a.revision,h,p_asset_version) returning * into r;
 return jsonb_build_object('token',r.token,'hash',h,'revision',r.revision,'created_at',r.created_at);
end;$$;
revoke all on function public.spa_review(uuid,integer,uuid) from public,anon;
grant execute on function public.spa_review(uuid,integer,uuid) to authenticated;
create function public.spa_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}') returns uuid language plpgsql security definer set search_path='' as $$
declare a public.spa_agreements; d jsonb; profile jsonb; adm boolean; uid uuid:=auth.uid(); email text; rid uuid; y integer; n integer; k text; signing public.portal_signing_profiles; review public.spa_reviews; final_bytes bytea; result uuid; comp public.portal_companies;
begin
 if uid is null or not portal_private.is_active() then raise exception 'Active account required';end if;
 adm:=portal_private.is_admin();select m.email into email from public.portal_members m where m.user_id=uid;
 if jsonb_typeof(p_payload) is distinct from 'object' or length(p_payload::text)>12000000 then raise exception 'Invalid request';end if;
 if p_action='create' then
 if not adm then raise exception 'Administrator required';end if;
 rid:=(p_payload->>'recipient')::uuid;
 if not exists(select 1 from public.portal_members where user_id=rid and active and not is_admin) then raise exception 'Select an active client';end if;
 profile:=portal_private.spa_profile(rid);
 y:=extract(year from now() at time zone 'Europe/Amsterdam');insert into public.spa_counters values(y,1) on conflict(year) do update set value=public.spa_counters.value+1 returning value into n;
 d:=profile||jsonb_build_object('product','EN590','standard','EN 590:2025','incoterm','CFR','law','ENGLISH','months','12','bank_holder','La Clava Elit B.V.','technical','{}'::jsonb,'seller',jsonb_build_object('legal_name','La Clava Elit B.V.','business_name','VIP Capital','registration','84285699','vat','NL863159825B01','registered_address','Oude Apeldoornseweg 45-067, 7333 NR Apeldoorn, The Netherlands','address','Oude Apeldoornseweg 45-067, 7333 NR Apeldoorn, The Netherlands','representative','J.P. Kolfoort','role','MD','email','info@vipcapital.eu'));
 insert into public.spa_agreements(recipient,company_id,template_version,transaction_code,data,created_by) values(rid,(profile->>'buyer_profile_id')::uuid,'2026-10-23-v1','NEX-SPA-'||y||'-'||n,d,uid) returning * into a;
 else
 select * into a from public.spa_agreements where id=p_id for update;
 if not found or (not adm and (a.recipient<>uid or a.status='draft')) then raise exception 'Agreement not found';end if;
 if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;d:=a.data;
 if p_action<>'sign' and not adm then raise exception 'Administrator required';end if;
 case p_action
 when 'save' then
 if a.status<>'draft' then raise exception 'Only a draft may be edited';end if;
 d:=d||portal_private.spa_edit_fields(p_payload->'data');
 when 'sync_profile' then
 if a.status<>'draft' then raise exception 'Signed or assigned profile snapshots cannot change';end if;
 profile:=portal_private.spa_profile(a.recipient);d:=d||profile;a.company_id:=(profile->>'buyer_profile_id')::uuid;
 when 'issue' then
 if a.status<>'draft' then raise exception 'Only draft agreements may be assigned';end if;
 profile:=portal_private.spa_profile(a.recipient);
 if profile->>'buyer_profile_status'<>'approved' then raise exception 'Approve the company profile before assigning the SPA';end if;
 if profile->>'buyer_profile_id' is distinct from d->>'buyer_profile_id' or profile->>'buyer_profile_version' is distinct from d->>'buyer_profile_version' then raise exception 'Company profile changed; refresh the draft snapshot first';end if;
 if not exists(select 1 from public.portal_members where user_id=a.recipient and active and not is_admin) then raise exception 'Client account is disabled';end if;
 perform portal_private.spa_validate(d);a.status:='awaiting_client';
 when 'sign' then
 if adm or uid<>a.recipient or a.status<>'awaiting_client' then raise exception 'Only the assigned buyer may sign';end if;
 perform portal_private.spa_validate(d);
 select * into comp from public.portal_companies where id=a.company_id;
 if comp.access_state<>'active' then raise exception 'Company access is disabled';end if;
 if p_payload->>'name' is distinct from d->>'representative' or p_payload->'authority' is distinct from 'true'::jsonb or p_payload->'accept' is distinct from 'true'::jsonb or p_payload->'use_saved_assets' is distinct from 'true'::jsonb then raise exception 'Confirm exact authorized name, authority, acceptance and use of saved signing images';end if;
 select * into signing from public.portal_signing_profiles where user_id=uid for share;
 if not found or p_payload->>'asset_version' is distinct from signing.version::text then raise exception 'Signing images changed; save and review again';end if;
 select * into review from public.spa_reviews where token=(p_payload->>'review_token')::uuid and agreement_id=a.id and actor=uid and revision=a.revision and created_at>now()-interval '24 hours';
 if not found or review.asset_version is distinct from signing.version or review.payload_hash<>encode(sha256(convert_to(d::text,'UTF8')),'hex') then raise exception 'Preview this exact version and signing images before signing';end if;
 d:=d||jsonb_build_object('client_signing_assets',jsonb_build_object('signature',signing.signature,'stamp',signing.stamp,'version',signing.version,'confirmed_at',now(),'confirmed_by',uid),'client_signature',jsonb_build_object('name',p_payload->>'name','at',now(),'user_id',uid,'account',email,'authority',true,'accepted',true,'use_saved_assets',true,'review_token',review.token,'content_hash',review.payload_hash),'signed_payload_hash',review.payload_hash);
 a.status:='awaiting_approval';
 when 'prepare_approval' then
 if a.status<>'awaiting_approval' or not (d ? 'client_signature') or p_payload->'verified' is distinct from 'true'::jsonb then raise exception 'Buyer must sign and admin must verify the exact agreement';end if;
 select * into review from public.spa_reviews where token=(p_payload->>'review_token')::uuid and agreement_id=a.id and actor=uid and revision=a.revision and created_at>now()-interval '24 hours';
 if not found or review.payload_hash<>encode(sha256(convert_to(d::text,'UTF8')),'hex') then raise exception 'Review the client-signed PDF before final approval';end if;
 if not exists(select 1 from public.commission_assets where name='signature') or not exists(select 1 from public.commission_assets where name='stamp') then raise exception 'VIP Capital signature and stamp are unavailable';end if;
 d:=d||jsonb_build_object('approval_request',jsonb_build_object('token',gen_random_uuid(),'at',now(),'by',email,'user_id',uid));
 when 'approve' then
 if a.status<>'awaiting_approval' or not(d ? 'client_signature') or p_payload->'verified' is distinct from 'true'::jsonb or p_payload->>'approval_token' is distinct from d->'approval_request'->>'token' or d->'approval_request'->>'user_id' is distinct from uid::text or (d->'approval_request'->>'at')::timestamptz<now()-interval '15 minutes' then raise exception 'Final approval request expired or invalid';end if;
 if length(coalesce(p_payload->>'pdf','')) not between 100 and 10000000 then raise exception 'Final PDF required';end if;
 final_bytes:=decode(p_payload->>'pdf','base64');if substring(final_bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid final PDF';end if;
 insert into public.spa_final_pdfs(agreement_id,pdf_base64,pdf_sha256) values(a.id,p_payload->>'pdf',encode(sha256(final_bytes),'hex'));
 d:=d||jsonb_build_object('seller_signature',d->'approval_request','pdf_sha256',encode(sha256(final_bytes),'hex'));d:=d-'approval_request';a.status:='completed';
 when 'cancel' then
 if a.status in ('completed','cancelled') then raise exception 'Completed records cannot be cancelled';end if;a.status:='cancelled';
 when 'revise' then
 if a.status='draft' then raise exception 'Save the existing draft';end if;
 d:=d-'client_signature'-'client_signing_assets'-'signed_payload_hash'-'seller_signature'-'approval_request'-'pdf_sha256';
 perform pg_advisory_xact_lock(hashtextextended(a.transaction_code,0));select coalesce(max(version),0)+1 into n from public.spa_agreements where transaction_code=a.transaction_code;
 d:=d||portal_private.spa_profile(a.recipient)||jsonb_build_object('previous_id',a.id);
 insert into public.spa_agreements(recipient,company_id,template_version,transaction_code,version,data,created_by) values(a.recipient,(d->>'buyer_profile_id')::uuid,a.template_version,a.transaction_code,n,d,uid) returning id into result;
 insert into public.spa_events(agreement_id,actor,actor_email,event) values(result,uid,email,'revision_created');return result;
 else raise exception 'Unknown SPA action';end case;
 update public.spa_agreements set company_id=a.company_id,status=a.status,data=d,revision=revision+1,updated_at=now() where id=a.id;
 end if;
 insert into public.spa_events(agreement_id,actor,actor_email,event) values(a.id,uid,email,p_action);return a.id;
end;$$;
revoke all on function public.spa_action(text,uuid,integer,jsonb) from public,anon;
grant execute on function public.spa_action(text,uuid,integer,jsonb) to authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('vip-spa-templates','vip-spa-templates',false,20000000,array['application/pdf']) on conflict(id) do nothing;
create policy spa_blank_read on storage.objects for select to authenticated using(bucket_id='vip-spa-templates' and name='VIP Capital_Master_SPA_Blank.pdf' and (select portal_private.is_active()));
create policy spa_blank_admin_insert on storage.objects for insert to authenticated with check(bucket_id='vip-spa-templates' and name='VIP Capital_Master_SPA_Blank.pdf' and (select portal_private.is_admin()));
create policy spa_blank_admin_update on storage.objects for update to authenticated using(bucket_id='vip-spa-templates' and name='VIP Capital_Master_SPA_Blank.pdf' and (select portal_private.is_admin())) with check(bucket_id='vip-spa-templates' and name='VIP Capital_Master_SPA_Blank.pdf' and (select portal_private.is_admin()));



create table public.fco_templates(version text primary key,terms jsonb not null,products jsonb not null,created_at timestamptz not null default now());
create table public.fco_counters(year integer primary key,value integer not null);
create table public.fco_agreements(id uuid primary key default gen_random_uuid(),recipient uuid not null references public.portal_members(user_id),company_id uuid not null references public.portal_companies(id),template_version text not null references public.fco_templates(version),transaction_code text not null,version integer not null default 1,revision integer not null default 1,status text not null default 'draft' check(status in ('draft','awaiting_client','awaiting_approval','completed','cancelled')),data jsonb not null,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),created_by uuid not null references public.portal_members(user_id),unique(transaction_code,version));
create index fco_recipient on public.fco_agreements(recipient,created_at desc);
create table public.fco_events(id bigint generated always as identity primary key,agreement_id uuid not null references public.fco_agreements(id),actor uuid not null,actor_email text not null,event text not null,details jsonb not null default '{}',created_at timestamptz not null default now());
create table public.fco_final_pdfs(agreement_id uuid primary key references public.fco_agreements(id),pdf_base64 text not null,pdf_sha256 text not null,created_at timestamptz not null default now());
create table public.fco_reviews(token uuid primary key default gen_random_uuid(),agreement_id uuid not null references public.fco_agreements(id),actor uuid not null,revision integer not null,payload_hash text not null,asset_version uuid,created_at timestamptz not null default now());
alter table public.fco_templates enable row level security;
alter table public.fco_agreements enable row level security;
alter table public.fco_events enable row level security;
alter table public.fco_final_pdfs enable row level security;
alter table public.fco_counters enable row level security;
alter table public.fco_reviews enable row level security;
revoke all on public.fco_templates,public.fco_agreements,public.fco_events,public.fco_final_pdfs,public.fco_counters,public.fco_reviews from public,anon,authenticated;
grant select on public.fco_templates,public.fco_agreements,public.fco_events,public.fco_final_pdfs to authenticated;
create policy fco_template_read on public.fco_templates for select to authenticated using((select portal_private.is_active()));
create policy fco_agreement_read on public.fco_agreements for select to authenticated using((select portal_private.is_active()) and ((select portal_private.is_admin()) or (recipient=(select auth.uid()) and status<>'draft')));
create policy fco_event_read on public.fco_events for select to authenticated using(exists(select 1 from public.fco_agreements a where a.id=agreement_id));
create policy fco_pdf_read on public.fco_final_pdfs for select to authenticated using(exists(select 1 from public.fco_agreements a where a.id=agreement_id and a.status='completed'));
insert into public.fco_templates(version,terms,products) values('2026-10-23-fco-v1',$terms$[{"title": "Commercial and supply terms", "blocks": [{"text": "Pricing and invoicing", "heading": true}, {"text": "The price is the arithmetic average of S&P Global Platts Diesel 10 ppm FOB ARA quotations, code AAXRW00, less USD 40 per MT, for the bill of lading date minus one day, the bill of lading date and the bill of lading date plus one day. The SPA must specify the treatment of non-publication days. The final invoice is based on independently certified loaded quantity and the agreed pricing formula.", "heading": false}, {"text": "Supply programme", "heading": true}, {"text": "The proposed programme runs for thirty-six months, with an initial trial cargo of 100,000 MT and subsequent supply of up to 100,000 MT per month. Monthly quantities are proposed supply capability, subject to a mutually agreed lifting schedule and a \u00b15% tolerance unless the SPA states otherwise. Any extension requires mutual written agreement.", "heading": false}, {"text": "Each lifting depends on refinery allocation, terminal scheduling, operational readiness, destination approval, suitable vessel availability and the final SPA. This FCO does not guarantee an allocation, vessel or monthly volume.", "heading": false}, {"text": "Delivery and destination costs", "heading": true}, {"text": "CFR delivery includes cargo supply and ocean transportation to the agreed discharge port. Unless otherwise stated in the SPA or included in the contract of carriage, the Buyer bears discharge and receiving terminal costs, import duties, taxes, customs clearance and destination-specific charges. The SPA must allocate these costs expressly.", "heading": false}, {"text": "Houston (USHOU) is the indicated destination. The exact port, receiving terminal, destination fuel requirements and acceptance conditions must be confirmed before contracting. Delivery remains subject to route safety, vessel and terminal acceptance and compliance clearance.", "heading": false}, {"text": "Product quality and inspection", "heading": true}, {"text": "The proposed product is export-grade ULSD EN590 10 PPM from a refinery allocation subject to compliance clearance. Appendix I contains the offered indicative parameters. The complete contractual specification, applicable edition of EN590 and destination-specific seasonal requirements must be agreed in the SPA.", "heading": false}, {"text": "Cargo must be free from contamination, adulteration and prohibited substances. Blending, commingling or additive modification requires the parties\u2019 written agreement. SGS, Intertek, Bureau Veritas or a mutually agreed equivalent shall perform independent quantity and quality inspection. Loading certificates are final and binding subject to the re-testing and dispute procedures agreed in the SPA.", "heading": false}]}, {"title": "Transaction and payment procedure", "blocks": [{"text": "1  Buyer qualification", "heading": true}, {"text": "Buyer submits an LOI addressed to VIP Capital, corporate profile, KYC package and a bank comfort letter covering the estimated value of three months of proposed deliveries. VIP Capital conducts corporate, banking, AML, sanctions and commercial due diligence.", "heading": false}, {"text": "2  Transaction meeting and SPA", "heading": true}, {"text": "Following satisfactory due diligence, VIP Capital arranges a transaction meeting remotely or at a mutually agreed location. The parties confirm specifications, logistics, inspection, documentation, payment milestones and the definitive SPA.", "heading": false}, {"text": "3  Advance payment and nomination", "heading": true}, {"text": "After both parties execute the SPA, Buyer transfers 30% of the estimated value of the relevant monthly lifting to the verified account designated in the SPA. After cleared receipt, VIP Capital arranges a suitable tanker and coordinates loading, subject to operational availability and terminal acceptance.", "heading": false}, {"text": "4  Loading and independent inspection", "heading": true}, {"text": "Independent quantity and quality inspection is completed after loading. Inspection is at Buyer\u2019s expense unless the SPA states otherwise. VIP Capital provides the certificates and other documents required for the balance payment under the SPA.", "heading": false}, {"text": "5  Balance payment and sailing", "heading": true}, {"text": "Buyer transfers the remaining 70%, adjusted to the final invoice, following issuance of the agreed independent quantity and quality certificates. Sailing proceeds after confirmed cleared payment, subject to port clearance and operational requirements.", "heading": false}, {"text": "6  Recurring monthly liftings", "heading": true}, {"text": "The agreed 30% / 70% mechanism repeats for each monthly lifting. VIP Capital coordinates cargo tracking, voyage updates and operational support to the nominated discharge port.", "heading": false}, {"text": "Payments are by bank transfer. The BCL is evidence of financial capability; it is not a payment instrument or a substitute for cleared funds. No DLC or SBLC forms part of the offered payment mechanism.", "heading": false}]}, {"title": "Qualification and documentation", "blocks": [{"text": "Buyer qualification package", "heading": true}, {"text": "The Buyer provides the following documents for verification before SPA execution. VIP Capital may request additional evidence appropriate to the Buyer, bank, jurisdiction or proposed transaction.", "heading": false}, {"text": "\u2022 Letter of intent confirming product, quantity, delivery basis and proposed destination.", "heading": false}, {"text": "\u2022 Corporate profile, certificate of incorporation and recent registry extract or certificate of good standing.", "heading": false}, {"text": "\u2022 Ownership and ultimate beneficial owner declaration.", "heading": false}, {"text": "\u2022 Authorized representative identification and board resolution or power of attorney, where applicable.", "heading": false}, {"text": "\u2022 Bank comfort letter from a financial institution acceptable to VIP Capital, covering three months of proposed deliveries; additional proof of funds or banking readiness as agreed.", "heading": false}, {"text": "\u2022 Sanctions, AML and anti-corruption declarations; destination and end-use declaration.", "heading": false}, {"text": "\u2022 Bank details and banking officer contact information, subject to verification.", "heading": false}, {"text": "Shipment documentation", "heading": true}, {"text": "The definitive SPA shall state the exact documents, timing and delivery method. The indicative package comprises:", "heading": false}, {"text": "\u2022 Commercial invoice; certificate of origin; certificates of quantity and quality; independent inspection report.", "heading": false}, {"text": "\u2022 Full set clean on-board ocean bills of lading; cargo manifest; ullage report; notice of readiness.", "heading": false}, {"text": "\u2022 Port clearance and export authorizations; vessel particulars and Q88 where applicable.", "heading": false}, {"text": "\u2022 Insurance documentation where applicable and additional documents required by law, terminal rules or the agreed destination.", "heading": false}, {"text": "Maritime coordination", "heading": true}, {"text": "VIP Capital coordinates vessel nomination, voyage planning, port agency liaison, loading, documentation and voyage reporting through appointed carriers and service providers. Suitable product tankers remain subject to vetting, flag state requirements, chartering availability, terminal acceptance and voyage feasibility. No particular fleet size or dedicated vessel allocation is represented.", "heading": false}]}, {"title": "Conditions and acknowledgment", "blocks": [{"text": "Compliance and withdrawal", "heading": true}, {"text": "Transactions are subject to applicable EU, UK, US and UN sanctions, AML and KYC controls, anti-bribery requirements and relevant maritime, environmental and safety rules. VIP Capital may reject any Buyer, bank, payment route, vessel, jurisdiction or destination that does not meet its compliance and commercial requirements. VIP Capital may amend, suspend or withdraw this indicative offer before SPA execution.", "heading": false}, {"text": "Confidentiality and introduced relationships", "heading": true}, {"text": "This FCO and related transaction information are intended for the named recipient and must not be disclosed without VIP Capital\u2019s written consent. The parties shall not circumvent relationships introduced in connection with the programme. Any separately executed confidentiality or non-circumvention agreement governs those obligations according to its terms.", "heading": false}, {"text": "Governing law and dispute resolution", "heading": true}, {"text": "The proposed governing law is the law of England and Wales. Disputes under the definitive SPA shall be referred to LCIA arbitration seated in London, in English. The parties must expressly confirm the governing law and forum in that SPA. This FCO remains subject to contract and does not itself create a binding sale and purchase agreement.", "heading": false}, {"text": "Buyer acknowledgment", "heading": true}, {"text": "Buyer may indicate its intention to proceed by submitting an LOI and the qualification package. Acknowledgment of this FCO does not replace the definitive SPA or create a cargo allocation or payment obligation.", "heading": false}]}, {"title": "Appendix I  Product specification", "blocks": [{"text": "ULSD EN590 10 PPM automotive diesel. Origin and refinery are allocation dependent. These offered parameters must be read with the complete specification agreed in the SPA; this summary is not an exhaustive statement of EN590 conformity.", "heading": false}, {"text": "Destination and seasonal requirements", "heading": true}, {"text": "The SPA must confirm the applicable climate grade, seasonal cold-flow limits, destination fuel regulations and any additional contractual tests. The independent loading certificate of quality confirms the tested cargo parameters, subject to the sampling, re-testing and dispute procedures in the SPA.", "heading": false}]}]$terms$::jsonb,$products${"EN590": {"name": "EN590 10 ppm ULSD", "standard": "EN 590:2025", "fields": [["sulphur", "Maximum sulphur / unit"], ["fame", "FAME grade / maximum"], ["cfpp", "Seasonal class / CFPP"], ["density", "Density range / reference temperature"]]}, "RON95": {"name": "RON95 unleaded petrol", "standard": "EN 228:2025", "fields": [["ron", "Minimum RON"], ["mon", "Minimum MON"], ["ethanol", "E5 / E10 and oxygen limits"], ["vapour", "Seasonal vapour-pressure class"]]}, "JET_A1": {"name": "Jet A-1 aviation turbine fuel", "standard": "ASTM D1655-26b", "fields": [["freeze", "Maximum freezing point"], ["flash", "Minimum flash point"], ["additives", "Approved additives / limits"], ["aviation", "Aviation quality / release requirements"]]}}$products$::jsonb);
create function portal_private.fco_edit_fields(p_data jsonb) returns jsonb language plpgsql set search_path='' as $$
declare d jsonb:='{}'; k text; t jsonb:='{}';
begin
 if jsonb_typeof(p_data) is distinct from 'object' or length(p_data::text)>4500000 then raise exception 'Invalid commercial details';end if;
 foreach k in array array['title','product','standard','incoterm','quantity','months','lot','issue_date','validity','benchmark','quotation_code','differential','price_calendar','specification','destination','spec_filename','spec_pdf','spec_sha256'] loop
 if jsonb_typeof(p_data->k) not in ('string','number') and p_data ? k then raise exception 'Invalid field %',k;end if;
 if length(coalesce(p_data->>k,''))>(case when k='spec_pdf' then 4200000 when k='specification' then 12000 else 2000 end) then raise exception 'Field % is too long',k;end if;
 d:=d||jsonb_build_object(k,trim(coalesce(p_data->>k,'')));end loop;
 if coalesce(d->>'spec_pdf','')<>'' then
 if length(decode(d->>'spec_pdf','base64'))>3000000 or substring(decode(d->>'spec_pdf','base64') from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Upload a PDF smaller than 3 MB';end if;
 d:=d||jsonb_build_object('spec_sha256',encode(sha256(decode(d->>'spec_pdf','base64')),'hex'));
 end if;
 d:=d||jsonb_build_object('spec_confirmed',coalesce(p_data->'spec_confirmed'='true'::jsonb,false),'commercial_confirmed',coalesce(p_data->'commercial_confirmed'='true'::jsonb,false));
 return d;
end;$$;
revoke all on function portal_private.fco_edit_fields(jsonb) from public,anon,authenticated;
create function portal_private.fco_validate(d jsonb) returns void language plpgsql set search_path='' as $$
declare k text;
begin
 foreach k in array array['buyer','registration','buyer_address','buyer_country','representative','buyer_role','buyer_email','product','standard','quantity','months','lot','issue_date','validity','incoterm','destination','benchmark','quotation_code','differential','price_calendar','spec_filename','spec_pdf','spec_sha256'] loop
 if trim(coalesce(d->>k,''))='' then raise exception 'Complete % before assignment',replace(k,'_',' ');end if;end loop;
 if d->>'product' not in ('EN590','RON95','JET_A1') or d->>'incoterm' not in ('FOB','CFR','CIF') then raise exception 'Select product and delivery rule';end if;
 foreach k in array array['quantity','months','lot','validity'] loop
 if d->>k !~ '^[0-9]+([.][0-9]+)?$' or (d->>k)::numeric<=0 or (d->>k)::numeric>1000000000 then raise exception 'Invalid %',k;end if;end loop;
 if (d->>'months')::numeric<>trunc((d->>'months')::numeric) or (d->>'months')::numeric>120 then raise exception 'Duration must be 1 to 120 whole months';end if;
 if (d->>'validity')::numeric<>trunc((d->>'validity')::numeric) or (d->>'validity')::numeric>365 then raise exception 'Validity must be 1 to 365 whole days';end if;
 if d->>'differential' !~ '^-?[0-9]+([.][0-9]+)?$' then raise exception 'Differential must be numeric';end if;
 if (d->>'issue_date')::date<date '2020-01-01' or (d->>'issue_date')::date+(d->>'validity')::integer<current_date then raise exception 'Set a current issue date and validity';end if;
 if d->>'buyer_email' !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then raise exception 'Company business email is invalid';end if;
 foreach k in array array['standard','destination','benchmark','quotation_code','price_calendar'] loop if d->>k like '%[%' then raise exception 'Replace the placeholder in % before assignment',k;end if;end loop;
 if d->'spec_confirmed' is distinct from 'true'::jsonb or d->'commercial_confirmed' is distinct from 'true'::jsonb then raise exception 'Confirm the attached specification and commercial terms';end if;
 if encode(sha256(decode(d->>'spec_pdf','base64')),'hex') is distinct from d->>'spec_sha256' then raise exception 'Specsheet checksum mismatch';end if;
end;$$;
revoke all on function portal_private.fco_validate(jsonb) from public,anon,authenticated;
create function public.fco_review(p_id uuid,p_revision integer,p_asset_version uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.fco_agreements; r public.fco_reviews; profile public.portal_signing_profiles; h text;
begin
 if not portal_private.is_active() then raise exception 'Active account required';end if;
 select * into a from public.fco_agreements where id=p_id;
 if not found or (not portal_private.is_admin() and (a.recipient<>auth.uid() or a.status='draft')) then raise exception 'Agreement not found';end if;
 if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh';end if;
 if not portal_private.is_admin() and a.status='awaiting_client' then
 select * into profile from public.portal_signing_profiles where user_id=auth.uid();
 if not found or profile.version is distinct from p_asset_version then raise exception 'Save signature and stamp, then review again';end if;
 end if;
 h:=encode(sha256(convert_to(a.data::text,'UTF8')),'hex');
 insert into public.fco_reviews(agreement_id,actor,revision,payload_hash,asset_version) values(a.id,auth.uid(),a.revision,h,p_asset_version) returning * into r;
 return jsonb_build_object('token',r.token,'hash',h,'revision',r.revision,'created_at',r.created_at);
end;$$;
revoke all on function public.fco_review(uuid,integer,uuid) from public,anon;
grant execute on function public.fco_review(uuid,integer,uuid) to authenticated;
create function public.fco_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}') returns uuid language plpgsql security definer set search_path='' as $$
declare a public.fco_agreements; d jsonb; profile jsonb; adm boolean; uid uuid:=auth.uid(); email text; rid uuid; y integer; n integer; k text; signing public.portal_signing_profiles; review public.fco_reviews; final_bytes bytea; result uuid; comp public.portal_companies;
begin
 if uid is null or not portal_private.is_active() then raise exception 'Active account required';end if;
 adm:=portal_private.is_admin();select m.email into email from public.portal_members m where m.user_id=uid;
 if jsonb_typeof(p_payload) is distinct from 'object' or length(p_payload::text)>22000000 then raise exception 'Invalid request';end if;
 if p_action='create' then
 if not adm then raise exception 'Administrator required';end if;
 rid:=(p_payload->>'recipient')::uuid;
 if not exists(select 1 from public.portal_members where user_id=rid and active and not is_admin) then raise exception 'Select an active client';end if;
 profile:=portal_private.spa_profile(rid);
 y:=extract(year from now() at time zone 'Europe/Amsterdam');insert into public.fco_counters values(y,1) on conflict(year) do update set value=public.fco_counters.value+1 returning value into n;
 d:=profile||jsonb_build_object('product','EN590','standard','EN 590:2025','incoterm','CFR','law','ENGLISH','title','FCO Petroleum','months','36','quantity','100000','lot','100000','issue_date',to_char(current_date,'YYYY-MM-DD'),'validity','10','benchmark','S&P Global Platts Diesel 10 ppm FOB ARA','quotation_code','AAXRW00','differential','-40','price_calendar','B/L date minus one publication day, B/L date and B/L date plus one publication day. Confirm publication calendar, time zone and non-publication day treatment.','destination','','spec_pdf','','spec_filename','','specification','','seller',jsonb_build_object('legal_name','La Clava Elit B.V.','business_name','VIP Capital','registration','84285699','vat','NL863159825B01','registered_address','Oude Apeldoornseweg 45-067, 7333 NR Apeldoorn, The Netherlands','address','Oude Apeldoornseweg 45-067, 7333 NR Apeldoorn, The Netherlands','representative','J.P. Kolfoort','role','MD','email','info@vipcapital.eu'));
 insert into public.fco_agreements(recipient,company_id,template_version,transaction_code,data,created_by) values(rid,(profile->>'buyer_profile_id')::uuid,'2026-10-23-fco-v1','NEX-FCO-'||y||'-'||n,d,uid) returning * into a;
 else
 select * into a from public.fco_agreements where id=p_id for update;
 if not found or (not adm and (a.recipient<>uid or a.status='draft')) then raise exception 'Agreement not found';end if;
 if a.revision is distinct from p_revision then raise exception 'Agreement changed; refresh and try again';end if;d:=a.data;
 if p_action<>'sign' and not adm then raise exception 'Administrator required';end if;
 case p_action
 when 'save' then
 if a.status<>'draft' then raise exception 'Only a draft may be edited';end if;
 d:=d||portal_private.fco_edit_fields(p_payload->'data');
 when 'sync_profile' then
 if a.status<>'draft' then raise exception 'Signed or assigned profile snapshots cannot change';end if;
 profile:=portal_private.spa_profile(a.recipient);d:=d||profile;a.company_id:=(profile->>'buyer_profile_id')::uuid;
 when 'issue' then
 if a.status<>'draft' then raise exception 'Only draft agreements may be assigned';end if;
 profile:=portal_private.spa_profile(a.recipient);
 if profile->>'buyer_profile_status'<>'approved' then raise exception 'Approve the company profile before assigning the FCO';end if;
 if profile->>'buyer_profile_id' is distinct from d->>'buyer_profile_id' or profile->>'buyer_profile_version' is distinct from d->>'buyer_profile_version' then raise exception 'Company profile changed; refresh the draft snapshot first';end if;
 if not exists(select 1 from public.portal_members where user_id=a.recipient and active and not is_admin) then raise exception 'Client account is disabled';end if;
 perform portal_private.fco_validate(d);a.status:='awaiting_client';
 when 'sign' then
 if adm or uid<>a.recipient or a.status<>'awaiting_client' then raise exception 'Only the assigned buyer may sign';end if;
 perform portal_private.fco_validate(d);
 select * into comp from public.portal_companies where id=a.company_id;
 if comp.access_state<>'active' then raise exception 'Company access is disabled';end if;
 if p_payload->>'name' is distinct from d->>'representative' or p_payload->'authority' is distinct from 'true'::jsonb or p_payload->'accept' is distinct from 'true'::jsonb or p_payload->'use_saved_assets' is distinct from 'true'::jsonb then raise exception 'Confirm exact authorized name, authority, acceptance and use of saved signing images';end if;
 select * into signing from public.portal_signing_profiles where user_id=uid for share;
 if not found or p_payload->>'asset_version' is distinct from signing.version::text then raise exception 'Signing images changed; save and review again';end if;
 select * into review from public.fco_reviews where token=(p_payload->>'review_token')::uuid and agreement_id=a.id and actor=uid and revision=a.revision and created_at>now()-interval '24 hours';
 if not found or review.asset_version is distinct from signing.version or review.payload_hash<>encode(sha256(convert_to(d::text,'UTF8')),'hex') then raise exception 'Preview this exact version and signing images before signing';end if;
 d:=d||jsonb_build_object('client_signing_assets',jsonb_build_object('signature',signing.signature,'stamp',signing.stamp,'version',signing.version,'confirmed_at',now(),'confirmed_by',uid),'client_signature',jsonb_build_object('name',p_payload->>'name','at',now(),'user_id',uid,'account',email,'authority',true,'accepted',true,'use_saved_assets',true,'review_token',review.token,'content_hash',review.payload_hash),'signed_payload_hash',review.payload_hash);
 a.status:='awaiting_approval';
 when 'prepare_approval' then
 if a.status<>'awaiting_approval' or not (d ? 'client_signature') or p_payload->'verified' is distinct from 'true'::jsonb then raise exception 'Buyer must sign and admin must verify the exact agreement';end if;
 select * into review from public.fco_reviews where token=(p_payload->>'review_token')::uuid and agreement_id=a.id and actor=uid and revision=a.revision and created_at>now()-interval '24 hours';
 if not found or review.payload_hash<>encode(sha256(convert_to(d::text,'UTF8')),'hex') then raise exception 'Review the client-signed PDF before final approval';end if;
 if not exists(select 1 from public.commission_assets where name='signature') or not exists(select 1 from public.commission_assets where name='stamp') then raise exception 'VIP Capital signature and stamp are unavailable';end if;
 d:=d||jsonb_build_object('approval_request',jsonb_build_object('token',gen_random_uuid(),'at',now(),'by',email,'user_id',uid));
 when 'approve' then
 if a.status<>'awaiting_approval' or not(d ? 'client_signature') or p_payload->'verified' is distinct from 'true'::jsonb or p_payload->>'approval_token' is distinct from d->'approval_request'->>'token' or d->'approval_request'->>'user_id' is distinct from uid::text or (d->'approval_request'->>'at')::timestamptz<now()-interval '15 minutes' then raise exception 'Final approval request expired or invalid';end if;
 if length(coalesce(p_payload->>'pdf','')) not between 100 and 20000000 then raise exception 'Final PDF required';end if;
 final_bytes:=decode(p_payload->>'pdf','base64');if substring(final_bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid final PDF';end if;
 insert into public.fco_final_pdfs(agreement_id,pdf_base64,pdf_sha256) values(a.id,p_payload->>'pdf',encode(sha256(final_bytes),'hex'));
 d:=d||jsonb_build_object('seller_signature',d->'approval_request','pdf_sha256',encode(sha256(final_bytes),'hex'));d:=d-'approval_request';a.status:='completed';
 when 'cancel' then
 if a.status in ('completed','cancelled') then raise exception 'Completed records cannot be cancelled';end if;a.status:='cancelled';
 when 'revise' then
 if a.status='draft' then raise exception 'Save the existing draft';end if;
 d:=d-'client_signature'-'client_signing_assets'-'signed_payload_hash'-'seller_signature'-'approval_request'-'pdf_sha256';
 perform pg_advisory_xact_lock(hashtextextended(a.transaction_code,0));select coalesce(max(version),0)+1 into n from public.fco_agreements where transaction_code=a.transaction_code;
 d:=d||portal_private.spa_profile(a.recipient)||jsonb_build_object('previous_id',a.id);
 insert into public.fco_agreements(recipient,company_id,template_version,transaction_code,version,data,created_by) values(a.recipient,(d->>'buyer_profile_id')::uuid,a.template_version,a.transaction_code,n,d,uid) returning id into result;
 insert into public.fco_events(agreement_id,actor,actor_email,event) values(result,uid,email,'revision_created');return result;
 else raise exception 'Unknown FCO action';end case;
 update public.fco_agreements set company_id=a.company_id,status=a.status,data=d,revision=revision+1,updated_at=now() where id=a.id;
 end if;
 insert into public.fco_events(agreement_id,actor,actor_email,event) values(a.id,uid,email,p_action);return a.id;
end;$$;
revoke all on function public.fco_action(text,uuid,integer,jsonb) from public,anon;
grant execute on function public.fco_action(text,uuid,integer,jsonb) to authenticated;


drop trigger if exists notify_access_request on public.portal_access_requests;

insert into public.portal_members(user_id,email) select id,email from auth.users on conflict(user_id) do nothing;


create table public.portal_mcnda_approvals(id uuid primary key references public.portal_mcnda_assignments(id),recipient uuid not null references public.portal_members(user_id),submission_id uuid not null references public.portal_submissions(id),status text not null default 'awaiting_approval' check(status in('awaiting_approval','completed')),revision integer not null default 1,client_pdf text not null,client_hash text not null,final_pdf text,final_hash text,approval_token uuid,approval_by uuid,approval_at timestamptz,created_at timestamptz not null default now());
alter table public.portal_mcnda_approvals enable row level security;
revoke all on public.portal_mcnda_approvals from public,anon,authenticated;
grant select on public.portal_mcnda_approvals to authenticated;
create policy mcnda_approval_read on public.portal_mcnda_approvals for select to authenticated using((select portal_private.is_active()) and ((select portal_private.is_admin()) or recipient=(select auth.uid())));
create function public.submit_mcnda_for_approval(p_id uuid,p_details jsonb,p_expected_version integer,p_note text,p_pdf text) returns public.portal_companies language plpgsql security definer set search_path='' as $$
declare company public.portal_companies;request public.portal_mcnda_assignments;bytes bytea;
begin
 if not portal_private.is_active() or portal_private.is_admin() then raise exception 'Active client account required';end if;
 select * into request from public.portal_mcnda_assignments where user_id=auth.uid() and status='assigned' for update;
 if not found then raise exception 'MCNDA assignment required';end if;
 if length(coalesce(p_pdf,'')) not between 100 and 20000000 then raise exception 'Client-signed PDF required';end if;
 bytes:=decode(p_pdf,'base64');if substring(bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid PDF';end if;
 company:=public.submit_company_mcnda(p_id,p_details,p_expected_version,p_note);
 insert into public.portal_mcnda_approvals(id,recipient,submission_id,client_pdf,client_hash) values(request.id,auth.uid(),p_id,p_pdf,encode(sha256(bytes),'hex'));
 return company;
end;$$;
revoke all on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text) from public,anon;
grant execute on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text) to authenticated;
revoke execute on function public.submit_company_mcnda(uuid,jsonb,integer,text) from public,anon,authenticated;
create function public.approve_mcnda(p_id uuid,p_revision integer,p_action text,p_reviewed_hash text,p_pdf text default null,p_token uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.portal_mcnda_approvals;bytes bytea;email text;
begin
 if not portal_private.is_admin() then raise exception 'Administrator required';end if;
 select * into a from public.portal_mcnda_approvals where id=p_id for update;
 if not found or a.status<>'awaiting_approval' or a.revision<>p_revision or a.client_hash is distinct from p_reviewed_hash then raise exception 'MCNDA changed; preview again';end if;
 if not exists(select 1 from public.portal_members where user_id=a.recipient and active) then raise exception 'Client disabled';end if;
 if p_action='prepare' then
 if not exists(select 1 from public.commission_assets where name='signature') or not exists(select 1 from public.commission_assets where name='stamp') then raise exception 'VIP Capital signing assets unavailable';end if;
 update public.portal_mcnda_approvals set approval_token=gen_random_uuid(),approval_by=auth.uid(),approval_at=now(),revision=revision+1 where id=a.id returning * into a;
 return jsonb_build_object('token',a.approval_token,'at',a.approval_at,'revision',a.revision);
 elsif p_action='finalize' then
 if a.approval_token is distinct from p_token or a.approval_by is distinct from auth.uid() or a.approval_at<now()-interval '15 minutes' then raise exception 'Approval expired';end if;
 if length(coalesce(p_pdf,'')) not between 100 and 20000000 then raise exception 'Final PDF required';end if;
 bytes:=decode(p_pdf,'base64');if substring(bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid final PDF';end if;
 update public.portal_mcnda_approvals set status='completed',final_pdf=p_pdf,final_hash=encode(sha256(bytes),'hex'),approval_token=null,revision=revision+1 where id=a.id;
 return jsonb_build_object('status','completed');
 else raise exception 'Invalid action';end if;
end;$$;
revoke all on function public.approve_mcnda(uuid,integer,text,text,text,uuid) from public,anon;
grant execute on function public.approve_mcnda(uuid,integer,text,text,text,uuid) to authenticated;
commit;