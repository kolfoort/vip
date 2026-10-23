import {createClient} from 'npm:@supabase/supabase-js@2.102.0';
import nodemailer from 'npm:nodemailer@7.0.11';
const secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const db=createClient(Deno.env.get('SUPABASE_URL')!,secret,{auth:{persistSession:false}});
const uuid=(s:unknown)=>typeof s==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
const escape=(s:unknown)=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const sha=async(s:string)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)))).map(b=>b.toString(16).padStart(2,'0')).join('');
function html(title:string,intro:string,rows:[string,string][],button:string,url:string){return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="margin:0;background:#f3f6f9;color:#172d43;font-family:Arial,Helvetica,sans-serif"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:32px 16px"><table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:100%;max-width:600px;background:white;border:1px solid #dce3eb"><tr><td style="padding:28px 32px;border-bottom:3px solid #bd9a45"><img src="https://vipcapital.eu/portal-logo.png" width="180" alt="VIP Capital" style="display:block;border:0"></td></tr><tr><td style="padding:36px 32px"><p style="color:#a48131;font-size:11px;font-weight:bold;letter-spacing:2px">PRIVATE CLIENT ACCESS</p><h1 style="font:normal 32px/1.2 Georgia,serif;color:#002040">${escape(title)}</h1><p style="font-size:15px;line-height:1.7">${escape(intro)}</p><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f6f9;border-top:2px solid #bd9a45;margin:24px 0">${rows.map(([label,value])=>`<tr><td style="padding:14px 20px;font-size:13px;line-height:1.7;color:#637387">${escape(label)}<br><strong style="color:#002040;word-break:break-word">${escape(value)}</strong></td></tr>`).join('')}</table><table role="presentation" cellpadding="0" cellspacing="0"><tr><td bgcolor="#002040"><a href="${url}" style="display:inline-block;padding:16px 26px;font-size:13px;font-weight:bold;color:white;text-decoration:none">${escape(button)}</a></td></tr></table><p style="font-size:12px;line-height:1.7;color:#637387;margin-top:24px">For assistance, contact info@vipcapital.eu. Keep your account activation link private.</p></td></tr><tr><td style="background:#002040;padding:22px 32px;color:white;font-size:11px;line-height:1.8"><strong>VIP CAPITAL</strong><br>Oude Apeldoornseweg 45-067 · 7333 NR Apeldoorn · The Netherlands<br>info@vipcapital.eu · www.vipcapital.eu</td></tr></table></td></tr></table></body></html>`;}
Deno.serve(async req=>{
 const origin=req.headers.get('origin');
 const allowed=!origin||['https://vipcapital.eu','https://www.vipcapital.eu'].includes(origin);
 const headers={'Access-Control-Allow-Origin':origin&&allowed?origin:'https://vipcapital.eu','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info,x-portal-authorization','Access-Control-Allow-Methods':'POST,OPTIONS','Vary':'Origin'};
 const response=(status:number,message:string)=>Response.json({message},{status,headers});
 if(!allowed)return response(403,'Origin not allowed');
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST')return response(405,'POST required');
 if(Number(req.headers.get('content-length')||0)>16000)return response(413,'Request too large');
 let body;
 try{const raw=await req.text();if(raw.length>16000)return response(413,'Request too large');body=JSON.parse(raw);}catch{return response(400,'Invalid request');}
 if(body.action==='request'){
  const received=()=>response(202,'Thank you. Your access request has been received. If eligible, you will receive a confirmation email. VIP Capital will review your request.');
  if(body.website_trap)return received();
  const details=body.details;if(!details||typeof details!=='object'||Array.isArray(details))return response(400,'Please complete the form.');
  const limits:Record<string,number>={B_COMPANY:100,B_REGISTRATION:60,B_ADDRESS:150,B_COUNTRY:60,B_REPRESENTATIVE:80,B_TITLE:80,B_PHONE:50,B_EMAIL:100,B_WEBSITE:100};
  for(const [key,max] of Object.entries(limits)){if(typeof details[key]!=='string'||details[key].length>max)return response(400,'Please check the company details.');}
  if(['B_COMPANY','B_COUNTRY','B_REPRESENTATIVE','B_EMAIL'].some(k=>!details[k].trim())||!/^\S+@[^\s@]+\.[^\s@]+$/.test(details.B_EMAIL)||typeof body.message!=='string'||body.message.length>2000||body.privacy!==true)return response(400,'Please complete the required fields and acknowledge the privacy notice.');
  // A keyed hash stores a pseudonymous abuse-control identifier, never the raw IP address.
  const ip=req.headers.get('x-forwarded-for')?.split(',')[0].trim()||req.headers.get('x-real-ip')||'unknown';
  const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const sourceKey=Array.from(new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(ip)))).map(b=>b.toString(16).padStart(2,'0')).join('');
  const {error}=await db.rpc('register_access_request',{p_details:details,p_message:body.message.trim(),p_source_key:sourceKey});
  if(error)return response(503,'Your request could not be saved. Please try again shortly.');
  return received();
 }
 if(body.action==='notify'){
  if(!uuid(body.id)||typeof body.token!=='string'||!/^[0-9a-f]{64}$/.test(body.token))return response(401,'Unauthorized');
  const {data,error}=await db.rpc('claim_access_notification',{p_id:body.id,p_token_hash:await sha(body.token)});
  if(error)return response(500,'Unable to claim notification');if(!data?.length)return response(200,'No notification to send');
  const r=data[0],password=Deno.env.get('VIP_SMTP_PASSWORD');
  const mail=nodemailer.createTransport({host:'smtp.transip.email',port:465,secure:true,auth:{user:'info@vipcapital.eu',pass:password},connectionTimeout:10000,greetingTimeout:10000,socketTimeout:15000,tls:{minVersion:'TLSv1.2',rejectUnauthorized:true}});
  const update=async(values:Record<string,unknown>)=>{const {error}=await db.from('portal_access_requests').update(values).eq('id',r.id).eq('notify_lease',r.notify_lease);if(error)throw error;};
  try{
   if(!password)throw new Error('SMTP unavailable');
   const rows:[string,string][]=[['Company',r.details.B_COMPANY],['Contact',r.details.B_REPRESENTATIVE],['Business email',r.details.B_EMAIL],['Country',r.details.B_COUNTRY]];
   if(!r.admin_notified){const url='https://vipcapital.eu/document-admin.html?v=20261020-access1#access-requests';await mail.sendMail({from:'VIP Capital <info@vipcapital.eu>',to:'info@vipcapital.eu',subject:'VIP Capital | New client access request',text:'A new client access request is ready for review.\n'+rows.map(([k,v])=>k+': '+v).join('\n')+'\n\nReview request: '+url,html:html('New access request.','A prospective client has requested access to the VIP Capital Client Portal. Review the company details before sending an invitation.',rows,'Review access request',url),messageId:`<access-admin-${r.id}@vipcapital.eu>`});await update({admin_notified:true});}
   if(!r.applicant_notified){const url='https://vipcapital.eu';await mail.sendMail({from:'VIP Capital <info@vipcapital.eu>',to:r.details.B_EMAIL,subject:'VIP Capital | We have received your access request',text:'Thank you for your interest in VIP Capital. Your access request has been received. Our team will review it and, if approved, send a separate invitation. This confirmation does not grant portal access.\n\nCompany: '+r.details.B_COMPANY+'\nContact: '+r.details.B_REPRESENTATIVE,html:html('Thank you for your interest.','We have received your request for access to the VIP Capital Client Portal. Our team will review it and, if approved, send you a separate invitation to activate your account.',rows.slice(0,2),'Visit VIP Capital',url),messageId:`<access-applicant-${r.id}@vipcapital.eu>`});await update({applicant_notified:true});}
   await update({notify_leased_at:null});return response(200,'Notifications sent');
  }catch{await update({notify_leased_at:null,next_notification_at:new Date(Date.now()+300000).toISOString()}).catch(()=>{});return response(502,'Notification delivery pending');}finally{mail.close();}
 }
 if(!['approve','decline'].includes(body.action)||!uuid(body.id))return response(400,'Invalid action');
 const jwt=req.headers.get('x-portal-authorization')?.replace(/^Bearer /i,'');if(!jwt)return response(401,'Sign in required');
 const {data:{user},error:userError}=await db.auth.getUser(jwt);if(userError||!user)return response(401,'Sign in required');
 const {data:member}=await db.from('portal_members').select('active,is_admin').eq('user_id',user.id).maybeSingle();if(!member?.active||!member.is_admin)return response(403,'Administrator required');
 const {data:claimed,error:claimError}=await db.rpc('review_access_request',{p_id:body.id,p_admin:user.id,p_action:body.action});
 if(claimError)return response(500,'Unable to update request');if(!claimed?.length)return response(409,'This request has changed. Refresh the request list.');
 const r=claimed[0];if(body.action==='decline')return response(200,'Access request declined. No invitation was sent.');
 async function mark(status:string,message:string){await db.from('portal_access_requests').update({status,invitation_error:message}).eq('id',r.id).eq('invite_lease',r.invite_lease);}
 try{
  let invitee:string|null=null;
  const recovered=await db.rpc('find_access_invitee',{p_id:r.id});if(recovered.error)throw recovered.error;invitee=recovered.data;
  if(!invitee){
   const existing=await db.from('portal_members').select('user_id').eq('email',r.details.B_EMAIL).maybeSingle();if(existing.error)throw existing.error;
   if(existing.data){await mark('existing_account','An account already exists. Review its company link manually.');return response(409,'This email already has an account. Review the existing account and company link manually; no new invitation was sent.');}
   const result=await db.auth.admin.generateLink({type:'invite',email:r.details.B_EMAIL,options:{redirectTo:'https://vipcapital.eu/set-password.html',data:{nexora_access_request:r.id,company_name:r.details.B_COMPANY}}});
   if(result.error||!result.data.user||!result.data.properties?.action_link){await mark('invitation_failed','Activation link could not be prepared.');return response(502,'The invitation could not be prepared. Review Auth logs and retry.');}
   invitee=result.data.user.id;
   const password=Deno.env.get('VIP_SMTP_PASSWORD');if(!password)throw Error('Mail configuration unavailable');
   const smtp=nodemailer.createTransport({host:'smtp.transip.email',port:465,secure:true,auth:{user:'info@vipcapital.eu',pass:password},connectionTimeout:10000,greetingTimeout:10000,socketTimeout:15000,tls:{minVersion:'TLSv1.2',rejectUnauthorized:true}});
   try{await smtp.sendMail({from:'VIP Capital <info@vipcapital.eu>',to:r.details.B_EMAIL,subject:'VIP Capital | Activate your portal account',text:'Your access request has been approved. Activate your account and choose a password:\n'+result.data.properties.action_link,html:html('Your private access.','Your company access request has been approved. Activate your account to access documents and agreements assigned to you.',[['Company',r.details.B_COMPANY]],'Activate your account',result.data.properties.action_link)});await db.from('portal_access_requests').update({invitation_mailed_at:new Date().toISOString()}).eq('id',r.id).eq('invite_lease',r.invite_lease);}finally{smtp.close();}

  }
  if(invitee&&r.invitation_mailed_at==null){
   const state=await db.from('portal_access_requests').select('invitation_mailed_at').eq('id',r.id).single();
   if(!state.data?.invitation_mailed_at){
    const link=await db.auth.admin.generateLink({type:'recovery',email:r.details.B_EMAIL,options:{redirectTo:'https://vipcapital.eu/set-password.html'}});if(link.error||!link.data.properties?.action_link)throw Error('Activation retry unavailable');
    const password=Deno.env.get('VIP_SMTP_PASSWORD');if(!password)throw Error('Mail unavailable');const mail=nodemailer.createTransport({host:'smtp.transip.email',port:465,secure:true,auth:{user:'info@vipcapital.eu',pass:password},connectionTimeout:10000,greetingTimeout:10000,socketTimeout:15000,tls:{minVersion:'TLSv1.2',rejectUnauthorized:true}});
    try{await mail.sendMail({from:'VIP Capital <info@vipcapital.eu>',to:r.details.B_EMAIL,subject:'VIP Capital | Activate your portal account',text:'Activate your VIP Capital account: '+link.data.properties.action_link,html:html('Your private access.','Your access request has been approved. Use this secure link to choose your portal password.',[['Company',r.details.B_COMPANY]],'Activate your account',link.data.properties.action_link)});await db.from('portal_access_requests').update({invitation_mailed_at:new Date().toISOString()}).eq('id',r.id).eq('invite_lease',r.invite_lease);}finally{mail.close();}
   }
  }
  const {error}=await db.rpc('finish_access_invitation',{p_id:r.id,p_lease:r.invite_lease,p_user_id:invitee});
  if(error){await mark('invitation_failed','Invitation exists; company setup needs retry.');return response(502,'The invitation exists, but company setup needs another attempt. Use Approve & invite again to finish the setup.');}
  return response(200,'Invitation sent and company profile prepared. No commercial documents have been assigned.');
 }catch{await mark('invitation_failed','Invitation processing needs review.');return response(500,'Unable to finish the invitation. Review the request and retry.');}
});
