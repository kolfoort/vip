import {config} from './portal-config.js';
const fields=['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL','B_WEBSITE'];
const el=(tag,text)=>{const node=document.createElement(tag);if(text!==undefined)node.textContent=text;return node;};
const form=document.getElementById('access-form');
if(form)form.addEventListener('submit',async event=>{
 event.preventDefault();if(!form.reportValidity())return;
 const button=document.getElementById('request-submit'),result=document.getElementById('request-result');button.disabled=true;result.hidden=false;result.textContent='Submitting your request…';
 try{
  const details=Object.fromEntries(fields.map(key=>[key,form.elements[key].value.trim()]));
  const response=await fetch(config.url+'/functions/v1/access-requests',{method:'POST',headers:{'Content-Type':'application/json',apikey:config.publishableKey},body:JSON.stringify({action:'request',details,message:form.elements.message.value.trim(),privacy:form.elements.privacy.checked,website_trap:form.elements.website_trap.value})});
  const data=await response.json();if(!response.ok)throw new Error(data.message||'Unable to submit your request. Please try again shortly.');
  result.textContent=data.message;for(const input of form.querySelectorAll('input,textarea,button'))input.disabled=true;result.scrollIntoView({block:'nearest',behavior:'smooth'});
 }catch(error){result.textContent=error.message||'Unable to submit your request. Please try again shortly.';button.disabled=false;}
});
export async function bindAccessAdmin({db,check,message,onInvited}){
 const list=document.getElementById('access-request-list'),refresh=document.getElementById('refresh-access');
 async function load(){
  const rows=check(await db.from('portal_access_requests').select('id,details,message,status,created_at,reviewed_at,invite_started_at,invitation_error,admin_notified,applicant_notified').order('created_at',{ascending:false}).limit(100));list.replaceChildren();
  if(!rows.length){list.append(el('p','No access requests yet. New applications will appear here.'));return;}
  const active=el('div'),history=el('details'),historyList=el('div');history.className='request-history';const completed=rows.filter(r=>['invited','declined'].includes(r.status));const summary=el('summary','View request history ('+completed.length+')');history.append(summary,historyList);
  if(rows.every(r=>['invited','declined'].includes(r.status)))active.append(el('p','No access requests need attention. Existing clients can be managed under Company profiles.'));
  list.append(active);if(completed.length)list.append(history);
  for(const r of rows){
   const card=el('article');card.className='access-request';const tag=el('span',({pending:'Awaiting review',inviting:'Invitation in progress',invited:'Invited',declined:'Declined',invitation_failed:'Invitation needs attention',existing_account:'Existing account — manual review'})[r.status]||r.status);tag.className='tag';card.append(tag,el('h3',r.details.B_COMPANY));
   const dl=el('dl');dl.className='company-details';for(const [key,label] of [['B_REPRESENTATIVE','Contact person'],['B_EMAIL','Business email'],['B_COUNTRY','Country'],['B_REGISTRATION','Registration'],['B_ADDRESS','Registered address'],['B_TITLE','Position / title'],['B_PHONE','Telephone'],['B_WEBSITE','Website']])if(r.details[key])dl.append(el('dt',label),el('dd',r.details[key]));card.append(dl);
   const date=el('p','Requested '+new Intl.DateTimeFormat('en-GB',{dateStyle:'medium',timeStyle:'short',timeZone:'Europe/Amsterdam'}).format(new Date(r.created_at))+' · Amsterdam time');date.className='meta';card.append(date);
   if(r.message){const note=el('p',r.message);note.className='request-note';card.append(note);}
   if(r.invitation_error)card.append(el('p',r.invitation_error));
   if(!r.admin_notified||!r.applicant_notified)card.append(el('p','Email delivery is pending. The application has been saved.'));
   const actions=el('div');actions.className='submission-actions';const feedback=el('div');feedback.className='status';feedback.hidden=true;feedback.setAttribute('role','status');feedback.setAttribute('aria-live','polite');
   const stale=r.status==='inviting'&&Date.now()-new Date(r.invite_started_at).getTime()>600000;
   const reviewable=['pending','invitation_failed'].includes(r.status)||stale;
   async function review(kind,button){
    const prompt=kind==='approve'?`Send a VIP Capital portal invitation to ${r.details.B_EMAIL} and prepare a company profile for ${r.details.B_COMPANY}? No commercial documents will be assigned.`:`Decline the access request from ${r.details.B_EMAIL}? No invitation or decline email will be sent.`;
    if(!confirm(prompt))return;
    for(const b of actions.querySelectorAll('button'))b.disabled=true;feedback.hidden=false;feedback.textContent=kind==='approve'?'Preparing invitation…':'Updating request…';
    try{
     const {data,error}=await db.functions.invoke('access-requests',{body:{action:kind,id:r.id}});
     if(error){let text='Unable to process the request. Refresh and try again.';try{const response=await error.context.json();text=response.message||text;}catch{}throw new Error(text);}
     message(data.message);document.getElementById('status')?.scrollIntoView({block:'nearest',behavior:'smooth'});await load();if(kind==='approve')await onInvited();
    }catch(error){feedback.hidden=false;feedback.textContent=error.message||'Unable to process the request.';message(feedback.textContent);for(const b of actions.querySelectorAll('button'))b.disabled=false;}
   }
   if(reviewable){const approve=el('button',r.status==='invitation_failed'||stale?'Retry approve & invite':'Approve & invite');approve.type='button';approve.addEventListener('click',()=>review('approve',approve));actions.append(approve);}
   if(['pending','invitation_failed','existing_account'].includes(r.status)){const decline=el('button','Decline');decline.type='button';decline.className='secondary';decline.addEventListener('click',()=>review('decline',decline));actions.append(decline);}
   card.append(actions,feedback);(['invited','declined'].includes(r.status)?historyList:active).append(card);
  }
 }
 refresh.addEventListener('click',async()=>{refresh.disabled=true;try{await load();}catch{message('Unable to load access requests. Please try again.');}finally{refresh.disabled=false;}});
 try{await load();}catch{list.replaceChildren(el('p','Access requests could not be loaded. Refresh to try again.'));}
}
