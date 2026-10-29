begin;

create table portal_private.signing_confirmations (
 id uuid primary key,
 user_id uuid not null references auth.users(id),
 purpose text not null check(purpose in ('mcnda_client','mcnda_admin')),
 document_id uuid not null,
 document_hash text not null check(document_hash ~ '^[0-9a-f]{64}$'),
 assignment_id uuid,
 document_revision integer,
 recipient_email text not null,
 code_hash text,
 attempts integer not null default 0,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '10 minutes',
 delivered_at timestamptz,
 verified_at timestamptz,
 verification_token uuid,
 consumed_at timestamptz,
 invalidated_at timestamptz
);
alter table portal_private.signing_confirmations enable row level security;
revoke all on portal_private.signing_confirmations from public,anon,authenticated,service_role;
create index signing_confirmations_user_time on portal_private.signing_confirmations(user_id,created_at desc);

create function public.issue_signing_confirmation(p_user_id uuid,p_id uuid,p_purpose text,p_document_id uuid,p_document_hash text,p_code_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.portal_members; a public.portal_mcnda_approvals; assignment uuid; language text;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service required';end if;
 if p_purpose not in ('mcnda_client','mcnda_admin') or p_document_hash !~ '^[0-9a-f]{64}$' or p_code_hash !~ '^[0-9a-f]{64}$' then raise exception 'Invalid confirmation';end if;
 perform pg_advisory_xact_lock(hashtextextended('signing-confirmation:'||p_user_id::text,0));
 select * into m from public.portal_members where user_id=p_user_id and active;
 if not found or not exists(select 1 from auth.users where id=p_user_id and email_confirmed_at is not null and lower(email)=lower(m.email)) then raise exception 'Active verified account required';end if;
 if exists(select 1 from portal_private.signing_confirmations where user_id=p_user_id and created_at>now()-interval '60 seconds') or
 (select count(*) from portal_private.signing_confirmations where user_id=p_user_id and created_at>now()-interval '1 hour')>=5 then raise exception 'RATE_LIMIT';end if;
 if p_purpose='mcnda_client' then
  if exists(select 1 from public.portal_company_members cm join public.portal_companies pc on pc.id=cm.company_id where cm.user_id=p_user_id and pc.access_state<>'active') then raise exception 'Active profile required';end if;
  if m.is_admin then raise exception 'Client account required';end if;
  select id into assignment from public.portal_mcnda_assignments where user_id=p_user_id and status='assigned' for share;
  if assignment is null or exists(select 1 from public.portal_submissions where id=p_document_id) then raise exception 'Current assignment required';end if;
 else
  if not m.is_admin then raise exception 'Administrator required';end if;
  select * into a from public.portal_mcnda_approvals where id=p_document_id and status='awaiting_approval' and client_hash=p_document_hash for share;
  if not found or not exists(select 1 from public.portal_members where user_id=a.recipient and active) then raise exception 'Current review required';end if;
 end if;
 update portal_private.signing_confirmations set invalidated_at=now(),code_hash=null,verification_token=null
 where user_id=p_user_id and consumed_at is null and invalidated_at is null and (expires_at<now() or (purpose=p_purpose and document_id=p_document_id));
 insert into portal_private.signing_confirmations(id,user_id,purpose,document_id,document_hash,assignment_id,document_revision,recipient_email,code_hash)
 values(p_id,p_user_id,p_purpose,p_document_id,p_document_hash,assignment,a.revision,m.email,p_code_hash);
 language:=public.mail_language_for_email(m.email);
 return jsonb_build_object('email',m.email,'language',language,'expires_at',now()+interval '10 minutes');
end;$$;
revoke all on function public.issue_signing_confirmation(uuid,uuid,text,uuid,text,text) from public,anon,authenticated;
grant execute on function public.issue_signing_confirmation(uuid,uuid,text,uuid,text,text) to service_role;

create function public.complete_signing_confirmation_delivery(p_id uuid,p_delivered boolean) returns void
language plpgsql security definer set search_path='' as $$
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service required';end if;
 if p_delivered then update portal_private.signing_confirmations set delivered_at=now() where id=p_id and invalidated_at is null;
 else update portal_private.signing_confirmations set invalidated_at=now(),code_hash=null,verification_token=null where id=p_id and consumed_at is null;end if;
end;$$;
revoke all on function public.complete_signing_confirmation_delivery(uuid,boolean) from public,anon,authenticated;
grant execute on function public.complete_signing_confirmation_delivery(uuid,boolean) to service_role;

create function public.verify_signing_confirmation(p_id uuid,p_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c portal_private.signing_confirmations; token uuid;
begin
 if not portal_private.is_active() then raise exception 'Sign in required';end if;
 select * into c from portal_private.signing_confirmations where id=p_id and user_id=auth.uid() for update;
 if not found or c.delivered_at is null or c.invalidated_at is not null or c.consumed_at is not null or c.verified_at is not null or c.expires_at<now() or c.attempts>=5 then return jsonb_build_object('verified',false);end if;
 -- Failed attempts return normally so the increment is committed, rather than rolled back.
 update portal_private.signing_confirmations set attempts=attempts+1 where id=c.id;
 if p_code !~ '^[0-9]{8}$' or c.code_hash is distinct from encode(sha256(convert_to(c.id::text||':'||p_code,'UTF8')),'hex') then
  if c.attempts>=4 then update portal_private.signing_confirmations set invalidated_at=now(),code_hash=null where id=c.id;end if;
  return jsonb_build_object('verified',false);
 end if;
 token:=gen_random_uuid();
 update portal_private.signing_confirmations set verified_at=now(),verification_token=token,code_hash=null where id=c.id;
 return jsonb_build_object('verified',true,'confirmation_id',c.id,'confirmation_token',token,'verified_at',now());
end;$$;
revoke all on function public.verify_signing_confirmation(uuid,text) from public,anon;
grant execute on function public.verify_signing_confirmation(uuid,text) to authenticated;

create function portal_private.consume_signing_confirmation(p_id uuid,p_token uuid,p_purpose text,p_document_id uuid,p_document_hash text,p_revision integer default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c portal_private.signing_confirmations;
begin
 select * into c from portal_private.signing_confirmations where id=p_id and user_id=auth.uid() for update;
 if not found or c.purpose<>p_purpose or c.document_id<>p_document_id or c.document_hash<>p_document_hash or c.verification_token is distinct from p_token or p_token is null or c.verified_at is null or c.verified_at<now()-interval '3 minutes' or c.expires_at<now() or c.consumed_at is not null or c.invalidated_at is not null then raise exception 'Confirm this exact document with a fresh email code';end if;
 if p_purpose='mcnda_client' and not exists(select 1 from public.portal_mcnda_assignments where id=c.assignment_id and user_id=auth.uid() and status='assigned') then raise exception 'Assignment changed';end if;
 if p_purpose='mcnda_admin' and c.document_revision is distinct from p_revision then raise exception 'Review changed';end if;
 update portal_private.signing_confirmations set consumed_at=now(),verification_token=null where id=c.id;
 return jsonb_build_object('confirmation_id',c.id,'confirmation_method','registered_email_code','confirmed_at',c.verified_at,'document_sha256',c.document_hash,'account_id',c.user_id,'account_email',c.recipient_email,'document_id',c.document_id,'purpose',c.purpose);
end;$$;
revoke all on function portal_private.consume_signing_confirmation(uuid,uuid,text,uuid,text,integer) from public,anon,authenticated,service_role;

alter function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) rename to submit_mcnda_before_signing_confirmation;
revoke all on function public.submit_mcnda_before_signing_confirmation(uuid,jsonb,integer,text,text,jsonb) from public,anon,authenticated,service_role;
create function public.submit_mcnda_for_approval(p_id uuid,p_details jsonb,p_expected_version integer,p_note text,p_pdf text,p_attestation jsonb)
returns public.portal_companies language plpgsql security definer set search_path='' as $$
declare proof jsonb; result public.portal_companies; bytes bytea;
begin
 if not portal_private.is_active() or portal_private.is_admin() then raise exception 'Active client required';end if;
 if length(coalesce(p_pdf,'')) not between 100 and 20000000 then raise exception 'PDF required';end if;
 bytes:=decode(p_pdf,'base64');
 proof:=portal_private.consume_signing_confirmation((p_attestation->>'confirmation_id')::uuid,(p_attestation->>'confirmation_token')::uuid,'mcnda_client',p_id,encode(sha256(bytes),'hex'));
 result:=public.submit_mcnda_before_signing_confirmation(p_id,p_details,p_expected_version,p_note,p_pdf,(p_attestation-'confirmation_token')||jsonb_build_object('email_confirmation',proof));
 -- Record the actual approved document version, rather than the legacy hard-coded template label.
 update public.portal_mcnda_approvals set client_attestation=client_attestation||jsonb_build_object('template',p_attestation->>'document_template_version') where submission_id=p_id;
 return result;
end;$$;
revoke all on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) from public,anon;
grant execute on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) to authenticated;

alter table public.portal_mcnda_approvals add column admin_email_confirmation jsonb;
alter function public.approve_mcnda(uuid,integer,text,text,text,uuid) rename to approve_mcnda_before_signing_confirmation;
revoke all on function public.approve_mcnda_before_signing_confirmation(uuid,integer,text,text,text,uuid) from public,anon,authenticated,service_role;
create function public.approve_mcnda(p_id uuid,p_revision integer,p_action text,p_reviewed_hash text,p_pdf text default null,p_token uuid default null,p_confirmation_id uuid default null,p_confirmation_token uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare proof jsonb; result jsonb;
begin
 if not portal_private.is_admin() then raise exception 'Administrator required';end if;
 if p_action='prepare' then
  proof:=portal_private.consume_signing_confirmation(p_confirmation_id,p_confirmation_token,'mcnda_admin',p_id,p_reviewed_hash,p_revision);
  result:=public.approve_mcnda_before_signing_confirmation(p_id,p_revision,p_action,p_reviewed_hash,p_pdf,p_token);
  update public.portal_mcnda_approvals set admin_email_confirmation=proof where id=p_id;
  return result;
 elsif p_action='finalize' then
  if not exists(select 1 from public.portal_mcnda_approvals where id=p_id and admin_email_confirmation->>'account_id'=auth.uid()::text and admin_email_confirmation->>'document_sha256'=p_reviewed_hash and admin_email_confirmation->>'purpose'='mcnda_admin' and approval_by=auth.uid()) then raise exception 'Confirmed administrator approval required';end if;
  return public.approve_mcnda_before_signing_confirmation(p_id,p_revision,p_action,p_reviewed_hash,p_pdf,p_token);
 else raise exception 'Invalid action';end if;
end;$$;
revoke all on function public.approve_mcnda(uuid,integer,text,text,text,uuid,uuid,uuid) from public,anon;
grant execute on function public.approve_mcnda(uuid,integer,text,text,text,uuid,uuid,uuid) to authenticated;

commit;
