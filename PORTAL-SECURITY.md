# Administrator authenticator recovery

## Normal operation

Each portal requires its own TOTP enrollment. The account holder signs in, opens Account security, scans the QR code personally and verifies the current app code. The agent must not read, copy or enroll the account holder's secret. QR codes, setup keys and app codes must never be logged, emailed or stored in project files.

After setup, add a separately enrolled backup authenticator on another trusted physical device. Verify that device before removing an old one. The portal only offers removal of a verified authenticator when another verified TOTP factor remains.

## Lost primary device

Use the verified backup factor to complete login. In Account security, add and verify the replacement device, then remove the lost factor. Refreshing the session follows factor removal. Check provider sessions and sign out other sessions if compromise is suspected.

## All factors unavailable

There is no password-only or email-only portal bypass and no native recovery-code feature. The Supabase project owner performs recovery through trusted project administration after a separately documented identity/authority check. Record the requester, affected account, verification method, operator, time and reason without copying TOTP secrets or codes. Review/revoke affected sessions. The human project owner removes the affected user's lost factors through Supabase Auth administration; require password recovery if compromise is suspected. The next portal login still requires a new authenticator enrollment before administrative access. A password reset by itself never clears MFA.

Do not disable the global MFA policy, promote a replacement account, grant additional data access, or remove authentication factors merely on an unverified email request. Credential-reset operations must be completed by the human project owner under the applicable confirmation/handoff rules.

## Deployment and maintenance

Base migration stages the new gates with admin enforcement disabled; the activation migration turns it on after the frontend and both authenticated Edge routes are published. Existing opt-in verified factors require AAL2 throughout. No business records are deleted. Existing administrator AAL1 sessions lose business-data access at activation and must complete setup/challenge.

Every future public SECURITY DEFINER RPC must enforce portal_private.session_mfa_allowed() for an authenticated caller before returning or modifying business data. Existing public RPC implementations are private and can only be called through their gated public wrappers. Service-role Edge routes must validate the actual user session via my_portal_security before acting on that user's authority. Do not restore execute grants on mfa_implementation_* or pre-MFA helper functions.

Current limits: no authenticator has been enrolled or deleted by the agent, and no real credential/contract action was performed for verification. The account holder completes enrollment and the first real MFA login.
