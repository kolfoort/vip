begin;
update portal_private.mfa_policy set enforce_admin=true where singleton;
notify pgrst,'reload schema';
commit;
