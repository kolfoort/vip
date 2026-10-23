import {companyFields} from './company-profile.js?v=20261021-company1';
const el=(tag,text,cls)=>{const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(cls)n.className=cls;return n;};
let savedSearch='',savedFilter='current';
export async function loadCompanyAdmin({db,check,action,message,members}){
 const list=document.getElementById('company-admin-list');if(!list)return;
 const companies=check(await db.from('portal_companies').select('*').order('updated_at',{ascending:false}));
 const mappings=check(await db.from('portal_company_members').select('user_id,company_id'));
 const reload=()=>loadCompanyAdmin({db,check,action,message,members});
 list.replaceChildren();
 const tools=el('div',undefined,'tools'),search=el('input'),filter=el('select');search.type='search';search.placeholder='Search companies or email';search.setAttribute('aria-label','Search company profiles');search.value=savedSearch;filter.setAttribute('aria-label','Filter company access');
 for(const [value,label] of [['current','Current companies'],['active','Active'],['paused','Paused'],['archived','Archived'],['all','All companies']]){const o=el('option',label);o.value=value;filter.append(o);}filter.value=savedFilter;tools.append(search,filter);list.append(tools);
 const cards=el('div');list.append(cards);
 const announce=text=>{message(text);document.getElementById('status')?.scrollIntoView({block:'nearest',behavior:'smooth'});};
 function render(){
  cards.replaceChildren();const term=search.value.trim().toLowerCase();
  const shown=companies.filter(c=>{const state=c.access_state||'active';return (filter.value==='all'||(filter.value==='current'?state!=='archived':state===filter.value))&&[...Object.values(c.details),...mappings.filter(m=>m.company_id===c.id).map(m=>members.find(p=>p.user_id===m.user_id)?.email||'')].join(' ').toLowerCase().includes(term);});
  if(!shown.length)cards.append(el('p','No companies match this view. Choose another status or search term.'));
  for(const c of shown){
   const state=c.access_state||'active',linked=mappings.filter(m=>m.company_id===c.id),panel=el('section',undefined,'admin-doc company-card');
   panel.append(el('h3',c.details.B_COMPANY),el('p',state[0].toUpperCase()+state.slice(1)+' access · '+(c.status==='approved'?'Approved profile':'Pending profile review')+' · Version '+c.version));
   panel.append(el('p',linked.length+' linked '+(linked.length===1?'user':'users')+': '+(linked.map(m=>members.find(p=>p.user_id===m.user_id)?.email||'Account').join(', ')||'None')));
   if(state!=='active')panel.append(el('p',state==='archived'?'Archived: client access is blocked. Restore places the company on pause until you resume it.':'Paused: linked client accounts cannot access portal documents or upload files. Individual account suspensions remain separate.'));
   const details=el('details'),summary=el('summary','View company details');details.append(summary);const dl=el('dl',undefined,'company-details');for(const [key,label] of companyFields)dl.append(el('dt',label),el('dd',c.details[key]||'—'));details.append(dl);panel.append(details);
   const buttons=el('div',undefined,'submission-actions'),feedback=el('div',undefined,'status');feedback.hidden=true;feedback.setAttribute('role','status');panel.append(buttons,feedback);
   async function run(button,work){
    button.disabled=true;feedback.hidden=false;feedback.textContent='Saving…';
    try{const result=await work();await reload();announce(result);}catch(error){feedback.textContent=error.message||'Unable to save. Refresh the company list and try again.';button.disabled=false;}
   }
   function button(label,handler,cls='secondary'){const b=el('button',label,cls);b.type='button';b.addEventListener('click',()=>handler(b));buttons.append(b);return b;}
   const edit=el('details',undefined,'company-editor');edit.hidden=state==='archived';edit.append(el('summary','Edit company details'));
   const form=el('form'),grid=el('div',undefined,'nda-fields');
   for(const [key,label,max,required] of companyFields){const wrap=el('div'),l=el('label',label+(required?'':' (optional)')),input=el('input');input.id='admin-'+c.id+'-'+key;input.name=key;l.htmlFor=input.id;input.maxLength=max;input.required=required;input.value=c.details[key]||'';if(key==='B_EMAIL')input.type='email';wrap.append(l,input);grid.append(wrap);}
   const save=el('button','Save company details');save.type='submit';form.append(grid,el('p','Changed details create a new version and require profile approval. Existing documents retain their original company data. Changing the business email here does not change a user’s sign-in email.'),save);edit.append(form);panel.append(edit);
   form.addEventListener('submit',event=>{event.preventDefault();if(!form.reportValidity())return;run(save,async()=>{const data=Object.fromEntries(companyFields.map(([key])=>[key,form.elements[key].value.trim()]));check(await db.rpc('admin_save_company_details',{p_company_id:c.id,p_expected_version:c.version,p_details:data}));return 'Company details saved. Review and approve the new profile version.';});});
   if(c.status!=='approved'&&state!=='archived'){
    const approve=button('Approve company profile',b=>run(b,async()=>{check(await db.rpc('approve_company_profile',{p_company_id:c.id,p_expected_version:c.version}));return 'Company profile approved.';}),'');
    if(companyFields.some(([key,,,required])=>required&&!String(c.details[key]||'').trim())){approve.disabled=true;panel.append(el('p','Complete all required company details before approving this profile.'));}
   }
   if(c.details.B_STAMP_PATH)button('Download company stamp',b=>action(b,async()=>{const blob=check(await db.storage.from('vip-company-assets').download(c.details.B_STAMP_PATH));const url=URL.createObjectURL(blob),a=el('a');a.href=url;a.download='Company_stamp.png';a.click();setTimeout(()=>URL.revokeObjectURL(url),10000);}));
   const transitions=state==='archived'?[['restore','Restore company','Restore this company on pause? Client access will remain blocked until you choose Resume.']]:[[state==='active'?'pause':'resume',state==='active'?'Pause company':'Resume company',state==='active'?'Pause access for all linked client accounts? Files and agreements will be kept.':'Resume access for linked clients? Individually disabled accounts will stay disabled.'],['archive','Archive company','Archive this company and block all linked client accounts? Records will be retained, and you can restore the company later.']];
   for(const [kind,label,prompt] of transitions)button(label,b=>{if(!confirm(c.details.B_COMPANY+': '+prompt))return;run(b,async()=>{check(await db.rpc('manage_company_access',{p_company_id:c.id,p_expected_version:c.version,p_expected_state:state,p_action:kind}));return kind==='restore'?'Company restored on pause. Resume it when access should be enabled.':'Company '+({pause:'paused',resume:'resumed',archive:'archived'})[kind]+'.';});},kind==='archive'?'danger':'secondary');
   const history=el('details'),hs=el('summary','Management history'),historyList=el('div');history.append(hs,historyList);let historyLoaded=false;
   history.addEventListener('toggle',async()=>{if(!history.open||historyLoaded)return;historyList.textContent='Loading history…';try{const rows=check(await db.from('portal_company_events').select('event,actor_id,metadata,created_at').eq('company_id',c.id).order('created_at',{ascending:false}).limit(20));historyList.replaceChildren();if(!rows.length)historyList.append(el('p','No management changes recorded yet. History starts from this feature’s introduction.'));for(const row of rows){const date=new Intl.DateTimeFormat('en-GB',{dateStyle:'medium',timeStyle:'short',timeZone:'Europe/Amsterdam'}).format(new Date(row.created_at));historyList.append(el('p',date+' · '+(members.find(m=>m.user_id===row.actor_id)?.email||'System')+' · '+row.event.replaceAll('_',' ')+(row.metadata.to?' → '+row.metadata.to:'')+(row.metadata.version?' · Version '+row.metadata.version:'')));}historyLoaded=true;}catch{historyList.textContent='Unable to load history. Close and reopen to retry.';}});
   panel.append(history);cards.append(panel);
  }
 }
 search.addEventListener('input',()=>{savedSearch=search.value;render();});filter.addEventListener('change',()=>{savedFilter=filter.value;render();});render();
 if(companies.length){
  const links=el('details',undefined,'company-links');links.append(el('summary','Manage company users'));links.append(el('p','Link existing portal users to a company. Paused and archived companies block linked client access. Changing a company link can change access to its profile and saved stamp.'));
  for(const person of members.filter(m=>!m.is_admin)){
   const row=el('div',undefined,'member'),label=el('label',person.email),select=el('select');select.setAttribute('aria-label','Company for '+person.email);const blank=el('option','No company linked');blank.value='';select.append(blank);const current=mappings.find(m=>m.user_id===person.user_id)?.company_id||'';
   for(const c of companies.filter(c=>c.access_state!=='archived'||c.id===current)){const option=el('option',c.details.B_COMPANY+' · '+(c.access_state||'active'));option.value=c.id;select.append(option);}select.value=current;label.append(select);row.append(label);
   const save=el('button','Save company link','secondary');save.type='button';save.addEventListener('click',()=>{if(select.value===current||!confirm('Change the company linked to '+person.email+'? The user will have access to the selected active company profile and stamp. Previous documents will keep their original details.'))return;action(save,async()=>{if(select.value)check(await db.from('portal_company_members').upsert({user_id:person.user_id,company_id:select.value},{onConflict:'user_id'}));else check(await db.from('portal_company_members').delete().eq('user_id',person.user_id));await reload();announce('Company link updated.');});});row.append(save);links.append(row);
  }list.append(links);
 }
}
