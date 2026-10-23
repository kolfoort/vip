import { createClient } from 'npm:@supabase/supabase-js@2.102.0';
import nodemailer from 'npm:nodemailer@7.0.11';

// Invoked by the database webhook. Recipient and portal URL are fixed server-side.
const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const json = (status: number, message: string) => Response.json({ message }, { status });

function notificationHtml(email:string,title:string,when:string,id:string){
 const escape=(s:string)=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
 return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="margin:0;background:#f3f6f9;font-family:Arial,Helvetica,sans-serif;color:#172d43"><div style="display:none;max-height:0;overflow:hidden">A new document has been received in the VIP Capital Client Portal.</div><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f3f6f9"><tr><td align="center" style="padding:32px 16px"><table role="presentation" width="600" cellspacing="0" cellpadding="0" style="width:100%;max-width:600px;background:white;border:1px solid #dce3eb"><tr><td style="padding:28px 32px;border-bottom:3px solid #bd9a45"><img src="https://vipcapital.eu/portal-logo.png" width="180" alt="VIP Capital" style="display:block;border:0;width:200px;height:69px"></td></tr><tr><td style="padding:36px 32px"><p style="margin:0 0 16px;font-size:11px;font-weight:bold;letter-spacing:2px;color:#a48131">CLIENT DOCUMENT EXCHANGE</p><h1 style="margin:0 0 20px;font:normal 32px/1.2 Georgia,serif;color:#002040">New document received.</h1><p style="font-size:15px;line-height:1.7">A client has shared a document through the VIP Capital Client Portal. It is ready for your review.</p><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:24px 0;background:#f3f6f9;border-top:2px solid #bd9a45;font-size:14px;line-height:1.7"><tr><td style="padding:18px 20px;color:#637387">Client<br><strong style="color:#002040;word-break:break-word">${escape(email)}</strong></td></tr><tr><td style="padding:0 20px 18px;color:#637387">Document<br><strong style="color:#002040;word-break:break-word">${escape(title)}</strong></td></tr><tr><td style="padding:0 20px 18px;color:#637387">Received<br><strong style="color:#002040">${escape(when)} · Amsterdam time</strong></td></tr></table><table role="presentation" cellpadding="0" cellspacing="0"><tr><td bgcolor="#002040"><a href="https://vipcapital.eu/document-admin.html" style="display:inline-block;padding:16px 26px;color:white;font-size:13px;font-weight:bold;text-decoration:none">View document</a></td></tr></table><p style="margin:24px 0 0;font-size:12px;line-height:1.7;color:#637387">Sign in with your VIP Capital administrator account to view and review the document. The document remains in the portal and is not attached to this email.</p><p style="font-size:10px;color:#637387;word-break:break-all">Reference: ${escape(id)}</p></td></tr><tr><td style="padding:22px 32px;background:#002040;color:white;font-size:11px;line-height:1.8"><strong style="letter-spacing:1px">VIP CAPITAL</strong><br>Oude Apeldoornseweg 45-067 · 7333 NR Apeldoorn · The Netherlands<br><a href="mailto:info@vipcapital.eu" style="color:white;text-decoration:none">info@vipcapital.eu</a> · <a href="https://vipcapital.eu" style="color:white;text-decoration:none">www.vipcapital.eu</a></td></tr></table></td></tr></table></body></html>`;
}

Deno.serve(async request => {
  if (request.method !== 'POST') return json(405, 'POST required');
  const password = Deno.env.get('VIP_SMTP_PASSWORD');
  if (!password) return json(503, 'Email delivery is not configured');
  let body;
  try { body = await request.json(); } catch { return json(400, 'Invalid request'); }
  const id = body.submission_id;
  if (typeof body.token !== 'string' || !/^[0-9a-f]{64}$/.test(body.token)) return json(401, 'Unauthorized');
  const tokenHash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(body.token)))).map(b=>b.toString(16).padStart(2,'0')).join('');
  if (typeof id !== 'string' || !/^[0-9a-f-]{36}$/i.test(id)) return json(400, 'Invalid submission');
  const { data: claimed, error: claimError } = await admin.rpc('claim_upload_notification', { p_submission_id: id, p_token_hash: tokenHash });
  if (claimError) return json(500, 'Unable to claim notification');
  if (!claimed?.length) return json(200, 'Already sent or being processed');
  const job = claimed[0];
  const transporter = nodemailer.createTransport({
    host: 'smtp.transip.email', port: 465, secure: true,
    auth: { user: 'info@vipcapital.eu', pass: password },
    connectionTimeout: 12000, greetingTimeout: 12000, socketTimeout: 20000,
    tls: { minVersion: 'TLSv1.2', rejectUnauthorized: true },
  });
  try {
    const when = new Intl.DateTimeFormat('en-GB', {timeZone: 'Europe/Amsterdam',dateStyle:'long',timeStyle:'short'}).format(new Date(job.uploaded_at));
    const text = [
      'A new document has been submitted through the VIP Capital Client Portal.', '',
      `Client: ${job.client_email}`, `Document: ${job.document_title}`,
      `Received: ${when} (Amsterdam time)`, `Reference: ${id}`, '',
      'View and review the document:', 'https://vipcapital.eu/document-admin.html', '',
      'The document remains in the portal and is not attached to this email.',
    ].join('\n');
    await transporter.sendMail({ from: 'VIP Capital <info@vipcapital.eu>', to: 'info@vipcapital.eu',
      subject: 'VIP Capital | New document received', text, html: notificationHtml(job.client_email,job.document_title,when,id),
      messageId: `<upload-${id}@vipcapital.eu>`,
    });
    const { error } = await admin.from('portal_upload_notifications').update({status:'sent',sent_at:new Date().toISOString(),last_error:null}).eq('submission_id',id).eq('lease_id',job.lease_id);
    if (error) return json(500, 'Email accepted; notification state requires review');
    return json(200, 'Notification sent');
  } catch {
    // Never log SMTP credentials, message bodies, documents or recipient data.
    await admin.from('portal_upload_notifications').update({status:'pending',last_error:'SMTP delivery failed',next_attempt_at:new Date(Date.now()+300000).toISOString()}).eq('submission_id',id).eq('lease_id',job.lease_id);
    return json(502, 'Email delivery failed; retry scheduled');
  } finally { transporter.close(); }
});
