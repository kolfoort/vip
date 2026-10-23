begin;
alter table public.portal_mcnda_approvals add column client_attestation jsonb not null default '{}'::jsonb, add column company_snapshot jsonb not null default '{}'::jsonb;
drop function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text);
create function public.submit_mcnda_for_approval(p_id uuid,p_details jsonb,p_expected_version integer,p_note text,p_pdf text,p_attestation jsonb) returns public.portal_companies language plpgsql security definer set search_path='' as $$
declare company public.portal_companies;request public.portal_mcnda_assignments;bytes bytea;hash text;sv integer;
begin
 if not portal_private.is_active() or portal_private.is_admin() then raise exception 'Active client account required';end if;
 select * into request from public.portal_mcnda_assignments where user_id=auth.uid() and status='assigned' for update;
 if not found then raise exception 'MCNDA assignment required';end if;
 if length(coalesce(p_pdf,'')) not between 100 and 20000000 then raise exception 'Client-signed PDF required';end if;
 bytes:=decode(p_pdf,'base64');if substring(bytes from 1 for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Invalid PDF';end if;hash:=encode(sha256(bytes),'hex');
 if p_attestation->>'authority' is distinct from 'true' or p_attestation->>'acceptance' is distinct from 'true' or p_attestation->>'reviewed_hash' is distinct from hash or p_attestation->>'name' is distinct from p_details->>'B_REPRESENTATIVE' then raise exception 'Review and acceptance required for this exact PDF';end if;
 if p_attestation->>'signing_version' is not null then
 select version into sv from public.portal_signing_profiles where user_id=auth.uid() for share;
 if sv is distinct from (p_attestation->>'signing_version')::integer or p_attestation->>'assets_authorized' is distinct from 'true' then raise exception 'Signing images changed or not authorized';end if;
 end if;
 company:=public.submit_company_mcnda(p_id,p_details,p_expected_version,p_note);
 insert into public.portal_mcnda_approvals(id,recipient,submission_id,client_pdf,client_hash,client_attestation,company_snapshot) values(request.id,auth.uid(),p_id,p_pdf,hash,p_attestation||jsonb_build_object('signed_at',now(),'account_id',auth.uid(),'template','VIP-2026-10-23'),jsonb_build_object('details',company.details,'version',company.version,'status',company.status));
 return company;
end;$$;
revoke all on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) from public,anon;
grant execute on function public.submit_mcnda_for_approval(uuid,jsonb,integer,text,text,jsonb) to authenticated;
alter table public.portal_mcnda_assignments alter column template_version set default 'VIP-2026-10-23';
commit;
