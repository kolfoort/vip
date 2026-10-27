import {config} from '../portal-config.js';
import {createInvoicePDF} from './invoice-pdf.js?v=20261027-billing1';
const checked=r=>{if(r.error)throw r.error;return r.data};let db,revision,raw,member;const urls=[];
export const Billing={
 async init(){
  const {createClient}=await import('https://esm.sh/@supabase/supabase-js@2.102.0');db=createClient(config.url,config.publishableKey,{auth:{storage:sessionStorage,persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
  const {session}=checked(await db.auth.getSession());if(!session){location.replace('../client-login.html');return false;}
  member=checked(await db.from('portal_members').select('user_id,email,is_admin,active').eq('user_id',session.user.id).single());if(!member.active||!member.is_admin)throw Error('Deze administratie is alleen toegankelijk voor actieve VIP Capital-admins.');
  db.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT'){document.getElementById('billing-app').hidden=true;window.dispatchEvent(new Event('billing-signout'));raw=null;revision=null;location.replace('../client-login.html')}});
  document.getElementById('access-error').hidden=true;document.getElementById('billing-app').hidden=false;return true;
 },
 async state(){raw=checked(await db.rpc('billing_state'));revision=raw.revision;
  const projects=raw.projects.map(p=>({...p,client_name:raw.clients.find(c=>c.id===p.client_id)?.name||''}));
  const entries=raw.entries.map(e=>{const p=projects.find(p=>p.id===e.project_id),i=raw.invoices.find(i=>i.id===e.invoice_id);return {...e,project_name:p?.name||'',client_id:p?.client_id,client_name:p?.client_name||'',invoice_number:i?.number,invoice_status:i?.status}}).sort((a,b)=>b.work_date.localeCompare(a.work_date)||b.id-a.id);
  const events=checked(await db.from('admin_billing_events').select('created_at,action,entity_id').order('created_at',{ascending:false}).limit(50));return {...raw,projects,entries,invoices:[...raw.invoices].sort((a,b)=>b.id-a.id),events};
 },
 async action(action,payload){
  if(action==='invoice_issue'){
   let r=checked(await db.rpc('billing_action',{p_action:'prepare_issue',p_revision:revision,p_payload:payload}));revision=r.revision;
   raw=checked(await db.rpc('billing_state'));revision=raw.revision;const invoice=raw.invoices.find(i=>i.id===Number(payload.id));if(!invoice)throw Error('Factuur niet gevonden.');
   const bytes=await createInvoicePDF(invoice);let bin='';for(let i=0;i<bytes.length;i+=32768)bin+=String.fromCharCode(...bytes.subarray(i,i+32768));
   r=checked(await db.rpc('billing_action',{p_action:'finalize_issue',p_revision:revision,p_payload:{id:invoice.id,pdf:btoa(bin)}}));revision=r.revision;return r;
  }
  const r=checked(await db.rpc('billing_action',{p_action:action,p_revision:revision,p_payload:payload}));revision=r.revision;return r;
 },
 async downloadPDF(invoice){
  let bytes;if(['issued','paid','credited'].includes(invoice.status)){
   const r=checked(await db.from('admin_billing_pdfs').select('pdf_base64,pdf_sha256').eq('invoice_id',invoice.id).single());bytes=Uint8Array.from(atob(r.pdf_base64),c=>c.charCodeAt(0));
   const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');if(hash!==r.pdf_sha256)throw Error('De PDF-controle is mislukt. Download niet gebruiken.');
  }else bytes=await createInvoicePDF(invoice);
  const url=URL.createObjectURL(new Blob([bytes],{type:'application/pdf'}));urls.push(url);const a=document.createElement('a');a.href=url;a.download=invoice.number+'.pdf';a.click();
 },
 async signOut(){checked(await db.auth.signOut())}
};
window.addEventListener('pagehide',()=>{for(const u of urls)URL.revokeObjectURL(u)});
