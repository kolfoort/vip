import {individualFields,isIndividual,individualParty,mountIdentity} from './individual-profile.js?v=20261028-vip-alignment';
import {mountLanguagePreference} from './portal-language.js?v=20261028-vip-alignment';
import {mountCounterpartyRole} from './counterparty-role.js?v=20261028-vip-alignment';
import {initSigningImages} from './signing-images.js?v=20261028-vip-alignment';
export const companyFields=[['B_COMPANY','Legal company name',100,true],['B_REGISTRATION','Company registration number',60,true],['B_ADDRESS','Registered address',150,true],['B_COUNTRY','Country of incorporation',60,true],['B_REPRESENTATIVE','Authorized representative',80,true],['B_TITLE','Position / title',80,true],['B_PHONE','Telephone',50,true],['B_EMAIL','Business email',100,true],['B_WEBSITE','Website',100,false]];
const $=id=>document.getElementById(id);
const element=(tag,text)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;return e;};
function fields(container,prefix,details={}){for(const [key,label,max,required] of (isIndividual(details)?individualFields:companyFields)){const wrap=element('div'),l=element('label',label+(required?'':' (optional)')),input=element('input');input.id=prefix+key;input.name=key;l.htmlFor=input.id;input.maxLength=max;input.required=required;input.value=details[key]||'';if(key==='B_EMAIL')input.type='email';wrap.append(l,input);container.append(wrap);}}
export async function initCompanyProfile({db,member,check,action,message}){
 let profile=null;const listeners=[];
 const form=$('company-profile-form');fields($('company-profile-fields'),'company-');
 async function refresh(notify=false){
  const mapping=check(await db.from('portal_company_members').select('company_id').eq('user_id',member.user_id).maybeSingle());
  profile=mapping?check(await db.from('portal_companies').select('*').eq('id',mapping.company_id).single()):null;
  const d=profile?.details||{};$('company-profile-fields').replaceChildren();fields($('company-profile-fields'),'company-',d);for(const [key] of (isIndividual(d)?individualFields:companyFields))form.elements[key].value=d[key]||(key==='B_EMAIL'?member.email:'');
  $('company-profile-status').textContent=profile?(profile.status==='approved'?'Approved':'Pending review')+' · Version '+profile.version:'No company profile yet';
  $('company-profile-summary').textContent=profile?.details.B_COMPANY||'Your company details will be saved when you submit your MCNDA. You can also save them here first.';
  $('company-profile-stamp-note').textContent=profile?.details.B_STAMP_PATH?'A company stamp is saved privately and will be available when preparing your MCNDA.':'You can add your company stamp when preparing your MCNDA.';
  if(notify)for(const listener of listeners)await listener(profile);
 }
 form.addEventListener('submit',e=>{e.preventDefault();action($('company-profile-save'),async()=>{
  if(!form.reportValidity())return;
  const current=profile?.details||{},details=individualParty({...current,...Object.fromEntries((isIndividual(current)?individualFields:companyFields).map(([key])=>[key,form.elements[key].value.trim()]))});details.B_STAMP_PATH=profile?.details.B_STAMP_PATH||'';details.B_PROFILE_ID=profile?.id||'';
  const result=await db.rpc('save_my_company_profile',{p_details:details,p_expected_version:profile?.version||0});
  if(result.error){message('Unable to save. The company profile may have changed. Refresh the profile and try again.');return;}
  await refresh(true);message('Company profile saved. Changed details require VIP Capital approval. Existing documents remain unchanged.');
 });});
 $('company-profile-refresh').addEventListener('click',()=>action($('company-profile-refresh'),()=>refresh(true)));
 await refresh();
 if(isIndividual(profile?.details))await mountIdentity({db,container:form.parentElement,userId:member.user_id,message});
 mountLanguagePreference({db,container:form.parentElement,message});
 await mountCounterpartyRole({db,userId:member.user_id,container:form.parentElement,message,individual:isIndividual(profile?.details)});
 await initSigningImages({db,container:form.parentElement,message,onChange:()=>refresh(true)});
 return {getProfile:()=>profile,refresh,subscribe:listener=>listeners.push(listener)};
}
export {loadCompanyAdmin} from './company-management.js?v=20261028-vip-alignment';
