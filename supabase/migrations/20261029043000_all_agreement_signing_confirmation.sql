begin;
create or replace function portal_private.consume_signing_confirmation(p_id uuid,p_token uuid,p_purpose text,p_document_id uuid,p_document_hash text,p_revision integer default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c portal_private.signing_confirmations;
begin
 select * into c from portal_private.signing_confirmations where id=p_id and user_id=auth.uid() for update;
 if not found or c.purpose is distinct from p_purpose or c.document_id is distinct from p_document_id or c.document_hash is distinct from p_document_hash or c.verification_token is distinct from p_token or p_token is null or c.verified_at is null or c.verified_at<now()-interval '3 minutes' or c.expires_at<now() or c.consumed_at is not null or c.invalidated_at is not null then raise exception 'Confirm this exact document with a fresh email code';end if;
 if p_purpose='mcnda_client' and not exists(select 1 from public.portal_mcnda_assignments where id=c.assignment_id and user_id=auth.uid() and status='assigned') then raise exception 'Assignment changed';end if;
 if p_purpose='mcnda_admin' and c.document_revision is distinct from p_revision then raise exception 'Review changed';end if;
 update portal_private.signing_confirmations set consumed_at=now(),verification_token=null where id=c.id;
 return jsonb_build_object('confirmation_id',c.id,'confirmation_method','registered_email_code','confirmed_at',c.verified_at,'document_sha256',c.document_hash,'account_id',c.user_id,'account_email',c.recipient_email,'document_id',c.document_id,'purpose',c.purpose);
end;$$;
revoke all on function portal_private.consume_signing_confirmation(uuid,uuid,text,uuid,text,integer) from public,anon,authenticated,service_role;


alter table portal_private.signing_confirmations drop constraint signing_confirmations_purpose_check;
alter table portal_private.signing_confirmations add constraint signing_confirmations_purpose_check check(purpose in ('mcnda_client','mcnda_admin','commission_client','commission_admin'));
alter table portal_private.signing_confirmations add column context_hash text,add column document_kind text,add column review_token uuid;

create function portal_private.signing_agreement_context(p_kind text,p_id uuid,p_write boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;
begin
 if p_kind not in ('commission') then raise exception 'Unsupported document';end if;
 execute format('select to_jsonb(a) from public.%I a where id=$1 for '||case when p_write then 'update' else 'share' end,p_kind||'_agreements') into a using p_id;
 if a is null then raise exception 'Agreement unavailable';end if;
 return a;
end;$$;
revoke all on function portal_private.signing_agreement_context(text,uuid,boolean) from public,anon,authenticated,service_role;

create function public.issue_agreement_signing_confirmation(p_user_id uuid,p_id uuid,p_purpose text,p_document_id uuid,p_document_hash text,p_code_hash text,p_revision integer,p_review_token uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.portal_members;a jsonb;kind text;admin_step boolean;h text;valid_review boolean;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service required';end if;
 kind:=split_part(p_purpose,'_',1);admin_step:=split_part(p_purpose,'_',2)='admin';
 if p_purpose is null or p_purpose not in ('commission_client','commission_admin') or p_document_hash !~ '^[0-9a-f]{64}$' or p_code_hash !~ '^[0-9a-f]{64}$' then raise exception 'Invalid confirmation';end if;
 perform pg_advisory_xact_lock(hashtextextended('signing-confirmation:'||p_user_id::text,0));
 select * into m from public.portal_members where user_id=p_user_id and active;
 if not found or m.is_admin is distinct from admin_step or not exists(select 1 from auth.users where id=p_user_id and email_confirmed_at is not null and lower(email)=lower(m.email)) then raise exception 'Active verified account required';end if;
 if not m.is_admin and exists(select 1 from public.portal_company_members cm join public.portal_companies pc on pc.id=cm.company_id where cm.user_id=p_user_id and pc.access_state<>'active') then raise exception 'Active profile required';end if;
 if exists(select 1 from portal_private.signing_confirmations where user_id=p_user_id and document_id=p_document_id and created_at>now()-interval '60 seconds') or
 (select count(*) from portal_private.signing_confirmations where user_id=p_user_id and created_at>now()-interval '1 hour')>=30 or
 (select count(*) from portal_private.signing_confirmations where user_id=p_user_id and document_id=p_document_id and created_at>now()-interval '1 hour')>=5 then raise exception 'RATE_LIMIT';end if;
 a:=portal_private.signing_agreement_context(kind,p_document_id);
 if (a->>'revision')::integer is distinct from p_revision or (not admin_step and (a->>'recipient'<>p_user_id::text or a->>'status'<>'awaiting_client')) or (admin_step and a->>'status'<>'awaiting_approval') then raise exception 'Current assigned version required';end if;
 if not exists(select 1 from public.portal_members where user_id=(a->>'recipient')::uuid and active) or exists(select 1 from public.portal_company_members cm join public.portal_companies pc on pc.id=cm.company_id where cm.user_id=(a->>'recipient')::uuid and pc.access_state<>'active') then raise exception 'Client access unavailable';end if;
 h:=encode(sha256(convert_to((a->'data')::text,'UTF8')),'hex');
 if kind<>'commission' then
  if admin_step then
   if a->'data'->'approval_request'->>'user_id' is distinct from p_user_id::text or (a->'data'->'approval_request'->>'at')::timestamptz<now()-interval '15 minutes' then raise exception 'Prepare and review final approval first';end if;
  else
   execute format('select exists(select 1 from public.%I where token=$1 and agreement_id=$2 and actor=$3 and revision=$4 and payload_hash=$5 and created_at>now()-interval ''24 hours'')',kind||'_reviews') into valid_review using p_review_token,p_document_id,p_user_id,p_revision,h;
   if not valid_review then raise exception 'Review this exact document first';end if;
  end if;
 end if;
 update portal_private.signing_confirmations set invalidated_at=now(),code_hash=null,verification_token=null where user_id=p_user_id and consumed_at is null and invalidated_at is null and (expires_at<now() or (purpose=p_purpose and document_id=p_document_id));
 insert into portal_private.signing_confirmations(id,user_id,purpose,document_id,document_hash,document_revision,recipient_email,code_hash,context_hash,document_kind,review_token)
 values(p_id,p_user_id,p_purpose,p_document_id,p_document_hash,p_revision,m.email,p_code_hash,h,kind,case when not admin_step then p_review_token end);
 return jsonb_build_object('email',m.email,'language',public.mail_language_for_email(m.email),'expires_at',now()+interval '10 minutes');
end;$$;
revoke all on function public.issue_agreement_signing_confirmation(uuid,uuid,text,uuid,text,text,integer,uuid) from public,anon,authenticated;
grant execute on function public.issue_agreement_signing_confirmation(uuid,uuid,text,uuid,text,text,integer,uuid) to service_role;

create function portal_private.consume_agreement_signing_confirmation(p_kind text,p_id uuid,p_revision integer,p_payload jsonb,p_admin boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a jsonb;c portal_private.signing_confirmations;proof jsonb;h text;pdf_hash text;bytes bytea;person jsonb;
begin
 if not portal_private.is_active() or portal_private.is_admin() is distinct from p_admin then raise exception 'Active signing account required';end if;
 a:=portal_private.signing_agreement_context(p_kind,p_id,true);
 if (a->>'revision')::integer is distinct from p_revision or (not p_admin and (a->>'recipient'<>auth.uid()::text or a->>'status'<>'awaiting_client')) or (p_admin and a->>'status'<>'awaiting_approval') then raise exception 'Signing version changed';end if;
 if p_kind='commission' and not p_admin then
  select pc.details into person from public.portal_companies pc join public.portal_company_members cm on cm.company_id=pc.id where cm.user_id=auth.uid();
  if person->>'ACCOUNT_TYPE'='individual' then
   if public.individual_identity(auth.uid(),null)->>'copy_path' is null then raise exception 'Upload your signed passport copy before signing';end if;
   if a->'data'->>'legal_name' is distinct from person->>'B_COMPANY' or a->'data'->>'representative' is distinct from person->>'B_REPRESENTATIVE' then raise exception 'Save current personal profile details before signing';end if;
  end if;
 end if;
 if p_admin then
  if length(coalesce(p_payload->>'pdf','')) not between 100 and 22000000 then raise exception 'Final reviewed PDF required';end if;
  bytes:=decode(p_payload->>'pdf','base64');if substring(bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid PDF';end if;
  pdf_hash:=encode(sha256(bytes),'hex');
 else pdf_hash:=p_payload->>'confirmation_pdf_hash';end if;
 select * into c from portal_private.signing_confirmations where id=(p_payload->>'confirmation_id')::uuid and user_id=auth.uid() for update;
 h:=encode(sha256(convert_to((a->'data')::text,'UTF8')),'hex');
 if not found or c.document_kind is distinct from p_kind or c.document_revision is distinct from p_revision or c.context_hash is distinct from h or (not p_admin and p_kind<>'commission' and c.review_token is distinct from (p_payload->>'review_token')::uuid) then raise exception 'Confirm this exact version again';end if;
 proof:=portal_private.consume_signing_confirmation(c.id,(p_payload->>'confirmation_token')::uuid,p_kind||case when p_admin then '_admin' else '_client' end,p_id,pdf_hash);
 return proof||jsonb_build_object('document_kind',p_kind,'document_revision',p_revision,'payload_sha256',h,'review_token',c.review_token);
end;$$;
revoke all on function portal_private.consume_agreement_signing_confirmation(text,uuid,integer,jsonb,boolean) from public,anon,authenticated,service_role;

alter function public.commission_action(text,uuid,integer,jsonb) rename to commission_action_before_email_confirmation;
revoke all on function public.commission_action_before_email_confirmation(text,uuid,integer,jsonb) from public,anon,authenticated,service_role;
create function public.commission_action(p_action text,p_id uuid default null,p_revision integer default null,p_payload jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare proof jsonb;result uuid;actor_email text;
begin
 if p_action in ('sign','approve') then
  proof:=portal_private.consume_agreement_signing_confirmation('commission',p_id,p_revision,p_payload,p_action='approve');
 end if;
 result:=public.commission_action_before_email_confirmation(p_action,p_id,p_revision,p_payload-'confirmation_token'-'confirmation_id'-'confirmation_pdf_hash');
 if proof is not null then
  update public.commission_agreements set data=data||jsonb_build_object(case when p_action='sign' then 'client_email_confirmation' else 'admin_email_confirmation' end,proof) where id=result;
  select email into actor_email from public.portal_members where user_id=auth.uid();
  insert into public.commission_events(agreement_id,actor,actor_email,event,created_at) values(result,auth.uid(),actor_email,'signature_email_confirmed',(proof->>'confirmed_at')::timestamptz);
 elsif p_action='revise' then
  update public.commission_agreements set data=data-'client_email_confirmation'-'admin_email_confirmation' where id=result;
 end if;
 return result;
end;$$;
revoke all on function public.commission_action(text,uuid,integer,jsonb) from public,anon;
grant execute on function public.commission_action(text,uuid,integer,jsonb) to authenticated;
commit;
