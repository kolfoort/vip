import {mountIdentity} from './individual-profile.js?v=20261028-vip-alignment';
import {languageSelect,setLanguage} from './portal-language.js?v=20261028-auth-flags';
import {config} from './portal-config.js';
const fields=['B_COMPANY','B_REGISTRATION','B_ADDRESS','B_COUNTRY','B_REPRESENTATIVE','B_TITLE','B_PHONE','B_EMAIL','B_WEBSITE'];
const el=(tag,text)=>{const node=document.createElement(tag);if(text!==undefined)node.textContent=text;return node;};
const form=document.getElementById('access-form');
if(form){const wrap=document.createElement('div'),label=document.createElement('label'),select=languageSelect('','access-language');select.name='B_LANGUAGE';label.htmlFor=select.id;label.textContent='Portal & email language';const note=document.createElement('p');note.className='language-policy';note.textContent='All documents, MCNDAs and Commission Agreements remain in English. English is the working language of VIP Capital.';wrap.append(label,select,note);form.prepend(wrap);select.onchange=()=>setLanguage(select.value)}

if(form){
 const typeWrap=el('div'),label=el('label','Applicant type'),type=el('select');type.id='applicant-type';type.name='ACCOUNT_TYPE';type.required=true;label.htmlFor=type.id;for(const [value,text]of [['','Select applicant type'],['company','Company'],['individual','Private individual']])type.add(new Option(text,value));type.options[0].disabled=true;typeWrap.append(label,type);form.children[0].after(typeWrap);
 const personal=el('div');personal.id='personal-application';personal.className='nda-fields';personal.hidden=true;
 for(const [key,text,max,autocomplete]of [['P_FIRST_NAME','First name',40,'given-name'],['P_LAST_NAME','Last name',39,'family-name'],['P_ADDRESS','Address',100,'street-address'],['P_POSTCODE','Postal code',16,'postal-code'],['P_CITY','City',30,'address-level2'],['P_COUNTRY','Country of residence',60,'country-name'],['P_EMAIL','Email',100,'email'],['P_PHONE','Telephone',50,'tel'],['P_PASSPORT','Passport number',30,'off']]){const wrap=el('div'),label=el('label',text),input=el('input');label.htmlFor=key;input.id=key;input.name=key;input.maxLength=max;input.autocomplete=autocomplete;input.type=key==='P_EMAIL'?'email':key==='P_PHONE'?'tel':'text';wrap.append(label,input);personal.append(wrap)}
 personal.append(el('p','Private individuals register as Introducer / Broker. After approval and sign-in, upload your signed passport copy in the portal and sign the English MCNDA.'));personal.append(el('p','Enter the passport document number, not your BSN or national personal number. Read Privacy & Cookies for how identity information is used.'));document.getElementById('company-application').before(personal);
 // The former optional company fields are now part of the same visible form.
 const company=document.getElementById('company-application');while(company.nextElementSibling?.classList.contains('nda-fields'))company.append(...company.nextElementSibling.children),company.nextElementSibling.remove();
 const change=()=>{const individual=type.value==='individual';company.hidden=individual;personal.hidden=!individual;for(const input of company.querySelectorAll('input'))input.disabled=individual;for(const input of personal.querySelectorAll('input')){input.disabled=!individual;input.required=individual}};type.onchange=change;change();
}
if(form)form.addEventListener('submit',async event=>{
 event.preventDefault();if(!form.reportValidity())return;
 const button=document.getElementById('request-submit'),result=document.getElementById('request-result');button.disabled=true;result.hidden=false;result.textContent='Submitting your request…';
 try{
  const details=Object.fromEntries(fields.map(key=>[key,form.elements[key].value.trim()]));details.B_LANGUAGE=form.elements.B_LANGUAGE.value;details.ACCOUNT_TYPE=form.elements.ACCOUNT_TYPE.value;let identity=null;if(details.ACCOUNT_TYPE==='individual'){for(const key of ['P_FIRST_NAME','P_LAST_NAME','P_ADDRESS','P_POSTCODE','P_CITY','P_COUNTRY'])details[key]=form.elements[key].value.trim();details.B_COMPANY=(details.P_FIRST_NAME+' '+details.P_LAST_NAME).trim();details.B_REPRESENTATIVE=details.B_COMPANY;details.B_REGISTRATION='';details.B_TITLE='';details.B_ADDRESS=[details.P_ADDRESS,details.P_POSTCODE+' '+details.P_CITY].join(', ');details.B_COUNTRY=details.P_COUNTRY;details.B_EMAIL=form.elements.P_EMAIL.value.trim();details.B_PHONE=form.elements.P_PHONE.value.trim();details.B_WEBSITE='';identity={passport_number:form.elements.P_PASSPORT.value.trim()};}
  const response=await fetch(config.url+'/functions/v1/access-requests',{method:'POST',headers:{'Content-Type':'application/json',apikey:config.publishableKey,Authorization:'Bearer '+config.functionKey},body:JSON.stringify({action:'request',details,identity,message:'',privacy:form.elements.privacy.checked,website_trap:form.elements.website_trap.value})});
  const data=await response.json();if(!response.ok)throw new Error(data.message||'Unable to submit your request. Please try again shortly.');
  result.textContent=data.message;for(const input of form.querySelectorAll('input,textarea,select,button'))input.disabled=true;result.scrollIntoView({block:'nearest',behavior:'smooth'});
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
   const dl=el('dl');dl.className='company-details';for(const [key,label] of [['B_REPRESENTATIVE','Contact person'],['B_EMAIL','Business email'],['B_COUNTRY','Country'],['B_REGISTRATION','Registration'],['B_ADDRESS','Registered address'],['B_TITLE','Position / title'],['B_PHONE','Telephone'],['B_WEBSITE','Website']])if(r.details[key])dl.append(el('dt',label),el('dd',r.details[key]));card.append(dl);if(r.details.ACCOUNT_TYPE==='individual')await mountIdentity({db,container:card,requestId:r.id,message});
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
     const session=await db.auth.getSession();if(session.error)throw session.error;const response=await fetch(config.url+'/functions/v1/access-requests',{method:'POST',headers:{'Content-Type':'application/json',apikey:config.publishableKey,Authorization:'Bearer '+config.functionKey,'x-portal-authorization':'Bearer '+session.data.session.access_token},body:JSON.stringify({action:kind,id:r.id})});const data=await response.json(),error=response.ok?null:new Error(data.message||'Unable to update request');
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

if(form&&['127.0.0.1','localhost'].includes(location.hostname)){
 const note=document.createElement('p');note.className='status';note.textContent='LOCAL PREVIEW — applications are not sent. Production activation is pending.';form.before(note);
 form.addEventListener('submit',event=>{event.preventDefault();event.stopImmediatePropagation();},true);
}
