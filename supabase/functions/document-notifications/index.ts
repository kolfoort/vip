import {createClient} from 'npm:@supabase/supabase-js@2.102.0';
import nodemailer from 'npm:nodemailer@7.0.11';
const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
const esc=(s:unknown)=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const hash=async(s:string)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)))).map(b=>b.toString(16).padStart(2,'0')).join('');
function template(title:string,description:string,label:string,url:string){return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="margin:0;background:#f3f6f9;font-family:Arial,Helvetica,sans-serif;color:#002040"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:32px 16px"><table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:100%;max-width:600px;background:#fff;border:1px solid #dce3eb"><tr><td style="padding:28px 32px;border-bottom:3px solid #bd9a45"><img src="https://vipcapital.eu/portal-logo.png" width="180" alt="VIP Capital" style="display:block;border:0"></td></tr><tr><td style="padding:32px"><p style="font-size:11px;letter-spacing:2px;font-weight:bold;color:#9b7929">PRIVATE CLIENT PORTAL</p><h1 style="font:normal 30px/1.25 Georgia,serif;color:#002040">${esc(title)}</h1><p style="font-size:15px;line-height:1.7;color:#637387">${esc(description)}</p><p style="padding:18px 0;border-top:1px solid #dce3eb;border-bottom:1px solid #dce3eb;font-size:15px;line-height:1.6;font-weight:bold">${esc(label)}</p><table role="presentation" cellpadding="0" cellspacing="0"><tr><td bgcolor="#002040"><a href="${url}" style="display:inline-block;padding:16px 26px;color:#fff;font-size:13px;font-weight:bold;text-decoration:none">Open secure portal</a></td></tr></table><p style="font-size:12px;line-height:1.7;color:#637387;margin-top:26px">Sign in with your registered email address to view the document. No document is attached to this email. This notification does not change any terms or constitute a signature or acceptance.</p></td></tr><tr><td style="background:#002040;padding:22px 32px;color:#fff;font-size:11px;line-height:1.8"><strong>VIP CAPITAL</strong><br>Oude Apeldoornseweg 45-067 · 7333 NR Apeldoorn · The Netherlands<br><a href="mailto:info@vipcapital.eu" style="color:white">info@vipcapital.eu</a> · www.vipcapital.eu</td></tr></table></td></tr></table></body></html>`;}
Deno.serve(async req=>{
 if(req.method!=='POST')return new Response('POST required',{status:405});
 let body;try{const raw=await req.text();if(raw.length>1000)return new Response('Too large',{status:413});body=JSON.parse(raw);}catch{return new Response('Invalid request',{status:400});}
 if(typeof body.id!=='string'||!/^[0-9a-f-]{36}$/i.test(body.id)||typeof body.token!=='string'||!/^[0-9a-f]{64}$/.test(body.token))return new Response('Unauthorized',{status:401});
 const {data,error}=await db.rpc('claim_document_notification',{p_id:body.id,p_token_hash:await hash(body.token)});if(error)return new Response('Queue unavailable',{status:500});if(!data?.length)return new Response('No pending notification');
 const n=data[0];const update=async(values:Record<string,unknown>)=>{const {error}=await db.from('portal_document_notifications').update(values).eq('id',n.id).eq('lease',n.lease);if(error)throw error;};
 let mail;
 try{
  const {data:m,error:me}=await db.from('portal_members').select('email,active,is_admin').eq('user_id',n.recipient).maybeSingle();if(me)throw me;
  let visible=!!m?.active&&!m?.is_admin;
  const {data:map,error:mapError}=await db.from('portal_company_members').select('company_id').eq('user_id',n.recipient).maybeSingle();if(mapError)throw mapError;
  if(map){const {data:c,error}=await db.from('portal_companies').select('access_state').eq('id',map.company_id).single();if(error)throw error;visible=visible&&c.access_state==='active';}
  let url='https://vipcapital.eu/documents.html',needsSignature=false;
  if(n.kind==='document'){
   const {data:grant,error:gerr}=await db.from('portal_document_access').select('document_id').eq('user_id',n.recipient).eq('document_id',n.entity_id).maybeSingle();if(gerr)throw gerr;
   const {data:doc,error:derr}=await db.from('portal_documents').select('published,storage_path,version_date').eq('id',n.entity_id).maybeSingle();if(derr)throw derr;visible=visible&&!!grant&&!!doc?.published&&n.version_key===(doc.storage_path||'')+':'+(doc.version_date||'');
  }else if(n.kind==='mcnda'){
   const {data:a,error}=await db.from('portal_mcnda_assignments').select('status,user_id,template_version').eq('id',n.entity_id).maybeSingle();if(error)throw error;visible=visible&&a?.user_id===n.recipient&&a?.status==='assigned'&&a?.template_version===n.version_key;needsSignature=true;
  }else{
   const table={commission:'commission_agreements',spa:'spa_agreements',fco:'fco_agreements'}[n.kind as string];if(!table)throw Error('Unknown notification kind');
   const {data:a,error}=await db.from(table).select('status,recipient,version').eq('id',n.entity_id).maybeSingle();if(error)throw error;visible=visible&&a?.recipient===n.recipient&&a?.status==='awaiting_client'&&String(a?.version)===n.version_key;
   url='https://vipcapital.eu/'+({commission:'commission-agreements.html',spa:'spa-agreements.html',fco:'fco-agreements.html'}[n.kind as string])+'?agreement='+encodeURIComponent(n.entity_id);needsSignature=true;
  }
  if(!visible){await update({skipped_at:new Date().toISOString(),leased_at:null,last_error:'Access withdrawn or item no longer awaits action'});return new Response('No longer applicable');}
  const password=Deno.env.get('VIP_SMTP_PASSWORD');if(!password)throw Error('SMTP unavailable');
  mail=nodemailer.createTransport({host:'smtp.transip.email',port:465,secure:true,auth:{user:'info@vipcapital.eu',pass:password},connectionTimeout:10000,greetingTimeout:10000,socketTimeout:15000,tls:{minVersion:'TLSv1.2',rejectUnauthorized:true}});
  const title=needsSignature?'A document is ready for your review.':'A new document is available.';
  const intro=needsSignature?'VIP Capital has assigned a document to your account. Please sign in to review the complete document and complete the requested acknowledgment or signature.':'VIP Capital has shared a new document with your account. Please sign in to view it securely.';
  await mail.sendMail({from:'VIP Capital <info@vipcapital.eu>',to:m!.email,subject:'VIP Capital | '+(needsSignature?'Document ready for review':'New document in your portal'),text:title+'\n\n'+intro+'\n\n'+n.title+'\n\nOpen secure portal: '+url+'\n\nNo document is attached. This notification is not a signature or acceptance.\n\nVIP Capital\ninfo@vipcapital.eu',html:template(title,intro,n.title,url),messageId:`<document-${n.id}@nexint.eu>`});
  await update({sent_at:new Date().toISOString(),leased_at:null,last_error:null});return new Response('Notification sent');
 }catch{await update({leased_at:null,last_error:'Delivery pending; retry scheduled',next_attempt_at:new Date(Date.now()+300000).toISOString()}).catch(()=>{});return new Response('Delivery pending',{status:502});}finally{mail?.close();}
});
