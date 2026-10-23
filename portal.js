import {prepareDocumentPreview,setDocumentAccess} from './document-sharing.js?v=20261023-vip-mail1';
import {pdfBadge,previewButton,closePdfPreview} from './pdf-preview.js?v=20261023-vip-mail1';
import {loadAssignedDocuments} from './shared-documents.js?v=20261023-vip-mail1';
import {initClientFile,loadClientFile} from './client-file.js?v=20261023-vip-mail1';
import {initCompanyProfile,loadCompanyAdmin} from './company-profile.js?v=20261023-vip-mail1';
import { config } from './portal-config.js?v=20261023-vip-mail1';

const $ = id => document.getElementById(id);
const page = document.body.dataset.page;
let db, member, documents = [], members = [], submissions = [];
let generation = 0;
let documentProfiles=[];
let companyContext=null;
let mcndaAssignments=[];
function message(text) { $('status').textContent = text; $('status').hidden = !text; }
function node(tag, text, cls) { const e = document.createElement(tag); if(text !== undefined) e.textContent = text; if(cls) e.className = cls; return e; }
function fail(error) { console.error(error); message('Unable to complete this request. Please try again or contact info@vipcapital.eu.'); }
function check(result) { if(result.error) throw result.error; return result.data; }
function resetPrivateView() { closePdfPreview();generation++; documents = []; members = []; submissions = []; for(const id of ['document-list','member-list','admin-documents','submission-list','incoming-list']) if($(id)) $(id).replaceChildren(); if($('protected')) $('protected').hidden = true; if($('nda-frame')) $('nda-frame').src='about:blank'; }
function date(value) { return value ? new Date(value+'T12:00:00').toLocaleDateString('en-GB',{day:'numeric',month:'short',year:'numeric'}) : '—'; }
async function action(button, work) { button.disabled = true; try { await work(); } catch(error) { fail(error); } finally { button.disabled = false; } }
async function authorize() {
  const {user} = check(await db.auth.getUser());
  if(!user) { location.replace('client-login.html'); return false; }
  member = check(await db.from('portal_members').select('user_id,email,is_admin,active').eq('user_id',user.id).maybeSingle());
  if(!member?.active) { resetPrivateView(); message('Your access has not been enabled. Please contact VIP Capital.'); return false; }
  if(!check(await db.rpc('my_portal_access_allowed'))) {resetPrivateView();message('Your company access is paused or archived. Please contact VIP Capital.');return false;}
  if(page === 'admin' && !member.is_admin) { resetPrivateView(); message('This page is reserved for VIP Capital administrators.'); return false; }
  if(member.is_admin){document.querySelectorAll('header .nav a[href^="company-profile.html"]').forEach(link=>link.remove());if(page==='company'){location.replace('document-admin.html');return false;}}
  if(page==='documents'&&member.is_admin){location.replace('client-files.html');return false;}
  $('account').textContent = member.email;
  $('protected').hidden = false;
  if(member.is_admin && $('admin-link')) $('admin-link').hidden = false;
  return true;
}
async function loadDocuments() {
  const current = generation;
  const data = await loadAssignedDocuments(db,member.user_id,'id,title,description,category,version_date,is_draft,storage_path');
  if(current !== generation) return;
  documents = data;
  renderDocuments();
  if(page==='documents')await loadClientFile({db,member,company:companyContext});
}
async function downloadPDF(bucket, path, title) {
  const blob = check(await db.storage.from(bucket).download(path));
  const url = URL.createObjectURL(blob), a = document.createElement('a');
  a.href = url; a.download = title.replace(/[^a-zA-Z0-9 _.-]/g,'_')+'.pdf'; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}
async function validPDF(file) {
  if(!file || file.size===0 || file.size>20*1024*1024 || !file.name.toLowerCase().endsWith('.pdf')) return false;
  // Convenience validation only: private storage and database RLS enforce access.
  const signature = new TextDecoder().decode(await file.slice(0,5).arrayBuffer());
  return signature === '%PDF-';
}
function missingUploadSetup(error) { return ['PGRST205','42P01'].includes(error?.code); }
async function loadSubmissions() {
  const current=generation;
  const result=await db.from('portal_submissions').select('id,user_id,title,note,storage_path,status,created_at').order('created_at',{ascending:false});
  if(current!==generation) return;
  if(result.error && missingUploadSetup(result.error)) {
    if($('client-upload-section')) $('client-upload-section').hidden=true;
    if($('incoming-list')) $('incoming-list').replaceChildren(node('p','Client uploads are being prepared.'));
    return;
  }
  submissions=check(result);
  documentProfiles=check(await db.from('portal_document_profiles').select('submission_id,company_id,company_version,company_status,details'));
  if(page==='documents') {
    $('client-upload-section').hidden=false;
    renderSubmissions($('submission-list'),false);
    mcndaAssignments=check(await db.from('portal_mcnda_assignments').select('*').order('assigned_at',{ascending:false}));
    renderMcndaStatus();
    await loadClientFile({db,member,company:companyContext});
  } else renderSubmissions($('incoming-list'),true);
}
function renderMcndaStatus() {
  const existing=$('nda-existing'),preparation=$('nda-preparation');if(!existing||!preparation)return;
  const profile=companyContext?.getProfile();
  const signed=submissions.find(item=>{
    if(item.user_id!==member.user_id || !/^MCNDA\s*-/i.test(item.title) || !item.note?.startsWith('Completed and electronically signed via the VIP Capital portal.'))return false;
    const snapshot=documentProfiles.find(record=>record.submission_id===item.id);
    return !snapshot?.company_id || !profile?.id || snapshot.company_id===profile.id;
  });
  existing.replaceChildren();existing.hidden=!signed;preparation.hidden=!!signed;if($('nda-readonly'))$('nda-readonly').hidden=!!signed;$('nda-form-intro').hidden=!!signed;
  const pending=mcndaAssignments.some(a=>a.user_id===member.user_id&&a.status==='assigned');
  if(!signed&&!pending){$('nda-section').hidden=true;return;}
  $('nda-section').hidden=false;
  if(pending){existing.hidden=true;preparation.hidden=false;if($('nda-readonly'))$('nda-readonly').hidden=false;$('nda-form-intro').hidden=false;$('nda-heading').textContent='Assigned MCNDA';$('nda-intro').hidden=true;return;}
  if(!signed){$('nda-section').hidden=true;return;}
  $('nda-heading').textContent='MCNDA signed & submitted';$('nda-intro').hidden=false;
  $('nda-intro').textContent=signed.status==='denied'?'Your previous MCNDA was signed and submitted, but was not approved. Contact VIP Capital about the next steps.':'Your signed MCNDA has been shared with VIP Capital. You do not need to complete it again.';
  preparation.open=false;
  const statuses={received:['Awaiting review','VIP Capital has received your signed MCNDA.'],in_review:['In review','VIP Capital is reviewing your signed MCNDA.'],approved:['Approved','VIP Capital has approved your submitted MCNDA.'],denied:['Denied','VIP Capital has denied this submission. Contact VIP Capital before preparing a replacement.']};
  const [label,description]=statuses[signed.status]||['Submitted','Your signed MCNDA has been submitted.'];
  existing.append(node('div',label,'tag'),node('p',description),node('p','Submitted '+new Intl.DateTimeFormat('en-GB',{dateStyle:'medium',timeStyle:'short',timeZone:'Europe/Amsterdam'}).format(new Date(signed.created_at))+' · Amsterdam time','account'));
  const download=node('button','Download signed MCNDA','secondary');download.type='button';download.addEventListener('click',()=>action(download,()=>downloadPDF('vip-client-uploads',signed.storage_path,signed.title)));existing.append(previewButton({db,bucket:'vip-client-uploads',path:signed.storage_path,title:signed.title}),download);

}
function renderSubmissions(container, admin) {
  container.replaceChildren();
  if(!submissions.length) { container.append(node('p',admin?'No client documents have been received yet.':'You have not shared any documents with VIP Capital yet.')); return; }
  for(const item of submissions) {
    const row=node('article',undefined,'submission');
    const labels={received:'Received',in_review:'In review',reviewed:'In review',approved:'Approved',denied:'Denied'};
    const status=labels[item.status] || 'Received';
    row.append(node('div',status,'tag status-'+(item.status==='reviewed'?'in_review':item.status)),node('h3',item.title));
    if(admin) row.append(node('div',members.find(p=>p.user_id===item.user_id)?.email || 'Client account','account'));
    row.append(node('div',new Date(item.created_at).toLocaleString('en-GB',{dateStyle:'medium',timeStyle:'short'}),'meta'));
    if(item.note){const note=node('details');note.append(node('summary','Submission details'),node('p',item.note));row.append(note);}
    const savedProfile=documentProfiles.find(p=>p.submission_id===item.id);
    if(savedProfile){const details=node('details');details.append(node('summary','Company record at submission · Version '+savedProfile.company_version+' · '+(savedProfile.company_status==='approved'?'Approved':'Pending review')));for(const [key,label] of [['B_COMPANY','Company'],['B_REGISTRATION','Registration'],['B_ADDRESS','Address'],['B_COUNTRY','Country'],['B_REPRESENTATIVE','Representative'],['B_TITLE','Title'],['B_PHONE','Phone'],['B_EMAIL','Email'],['B_WEBSITE','Website']])details.append(node('div',label+': '+(savedProfile.details[key]||'—'),'account'));row.append(details);}

    const controls=node('div',undefined,'submission-actions'), download=node('button','Download PDF','secondary'); download.type='button';
    download.addEventListener('click',()=>action(download,()=>downloadPDF('vip-client-uploads',item.storage_path,item.title))); controls.append(previewButton({db,bucket:'vip-client-uploads',path:item.storage_path,title:item.title}),download);row.prepend(pdfBadge());
    if(admin) {
      const reviewLabel=node('label','Document status','status-control');
      const select=document.createElement('select');select.setAttribute('aria-label','Status for '+item.title);
      for(const value of ['received','in_review','approved','denied']) {
        const option=node('option',labels[value]); option.value=value;select.append(option);
      }
      select.value=item.status==='reviewed'?'in_review':item.status;
      reviewLabel.append(select);
      const save=node('button','Save status');save.type='button';
      save.addEventListener('click',()=>action(save,async()=>{
        check(await db.from('portal_submissions').update({status:select.value}).eq('id',item.id).select('id').single());
        await loadSubmissions();message('Document status updated. The client can see the new status after refreshing.');
      }));
      const remove=node('button','Delete','danger');remove.type='button';
      remove.addEventListener('click',()=>{
        if(!window.confirm('Permanently delete “'+item.title+'” and its PDF? This cannot be undone.')) return;
        action(remove,async()=>{
          // Remove the actual private PDF first, so a failed delete cannot leave an accessible orphan.
          check(await db.storage.from('vip-client-uploads').remove([item.storage_path]));
          check(await db.from('portal_submissions').delete().eq('id',item.id).select('id').single());
          await loadSubmissions();message('Document and PDF deleted.');
        });
      });
      controls.append(reviewLabel,save,remove);
    }
    row.append(controls);container.append(row);
  }
}
function bindClientUpload() {
  $('client-upload').addEventListener('submit',event=>{
    event.preventDefault(); action($('client-upload-button'),async()=>{
      const form=event.target,file=form.elements.file.files[0];
      if(!await validPDF(file)){message('Please select a valid PDF smaller than 20 MB.');return;}
      const title=form.elements.title.value.trim();
      if(!title){message('Please enter a document title.');return;}
      const id=crypto.randomUUID(),path=member.user_id+'/'+id+'.pdf';
      check(await db.storage.from('vip-client-uploads').upload(path,file,{contentType:'application/pdf',upsert:false}));
      const result=await db.from('portal_submissions').insert({id,user_id:member.user_id,title,note:form.elements.note.value.trim(),storage_path:path});
      if(result.error) { await db.storage.from('vip-client-uploads').remove([path]); throw result.error; }
      form.reset(); message('Your document has been shared with VIP Capital. It is visible only to your account and authorized VIP Capital administrators.'); await loadSubmissions();
    });
  });
}
function renderDocuments() {
  const term = $('search').value.trim().toLowerCase(), category = $('category').value;
  const visible = documents.filter(d => (!category || d.category === category) && (d.title+' '+d.description).toLowerCase().includes(term));
  $('document-list').replaceChildren();
  if(!visible.length) { $('document-list').append(node('p', documents.length ? 'No documents match your search.' : 'No documents have been assigned to your account yet.')); return; }
  for(const doc of visible) {
    const card = node('article',undefined,'card');
    card.append(node('div',doc.category+(doc.is_draft?' · DRAFT':''),'tag'),node('h2',doc.title),node('p',doc.description),node('div','Version: '+date(doc.version_date),'meta'));
    const button = node('button','Download PDF'); button.type='button';
    button.addEventListener('click', () => action(button, async () => {
      await downloadPDF('vip-documents',doc.storage_path,doc.title);
    }));
    if(doc.can_download===false)card.append(node('div','Preview only','tag'));card.prepend(pdfBadge());const actions=node('div',undefined,'document-actions');actions.append(previewButton({db,bucket:'vip-documents',path:doc.storage_path,title:doc.title,documentId:doc.id,canDownload:doc.can_download!==false}),...(doc.can_download===false?[]:[button]));card.append(actions); $('document-list').append(card);
  }
}
async function loadAdmin() {
  const current = generation;
  const [people, docs, grants] = await Promise.all([
    db.from('portal_members').select('user_id,email,active,is_admin').order('email'),
    db.from('portal_documents').select('*').order('created_at',{ascending:false}),
    db.from('portal_document_access').select('document_id,user_id,can_download')
  ]);
  if(current !== generation) return;
  members=check(people); documents=check(docs); const access=check(grants);
  $('member-list').replaceChildren(); $('admin-documents').replaceChildren();
  for(const person of members) {
    const row=node('div',undefined,'member');
    row.append(node('strong',person.email),node('div',(person.is_admin?'Administrator':'Client')+' · '+(person.active?'Active':'Disabled'),'account'));
    if(person.user_id !== member.user_id && !person.is_admin) {
      const b=node('button',person.active?'Disable access':'Enable access','secondary'); b.type='button';
      b.addEventListener('click',()=>action(b,async()=>{check(await db.from('portal_members').update({active:!person.active}).eq('user_id',person.user_id));await loadAdmin();})); row.append(b);
    }
    $('member-list').append(row);
  }
  if(!documents.length) $('admin-documents').append(node('p','No documents uploaded yet.'));
  for(const doc of documents) {
    const row=node('section',undefined,'admin-doc'); row.append(node('h3',doc.title),node('p',doc.category+' · '+date(doc.version_date)+(doc.is_draft?' · DRAFT':'')));
    const toggle=node('button',doc.published?'Unpublish':'Publish','secondary'); toggle.type='button';
    toggle.addEventListener('click',()=>action(toggle,async()=>{check(await db.from('portal_documents').update({published:!doc.published}).eq('id',doc.id));await loadAdmin();}));
    const controls=node('div',undefined,'submission-actions');
    const remove=node('button','Delete','danger');remove.type='button';
    remove.setAttribute('aria-label','Delete '+doc.title);
    remove.addEventListener('click',()=>{
      if(!window.confirm('Permanently delete “'+doc.title+'”, its PDF and all client access assignments? This cannot be undone. Previously downloaded copies will remain with recipients.')) return;
      action(remove,async()=>{
        const inputs=[...row.querySelectorAll('button,input')];inputs.forEach(e=>e.disabled=true);
        try {
          if(!member.is_admin || doc.storage_path!==doc.id+'.pdf') throw new Error('Invalid document deletion request.');
          // Stop client downloads before removing the private file. Database policies enforce admin access.
          check(await db.from('portal_documents').update({published:false}).eq('id',doc.id).select('id').single());
          check(await db.storage.from('vip-documents').remove([doc.storage_path]));
          // Client access rows are removed by the existing ON DELETE CASCADE foreign key.
          check(await db.from('portal_documents').delete().eq('id',doc.id).select('id').single());
          await loadAdmin();message('Document, PDF and client access assignments deleted.');
        } catch(error) {
          await loadAdmin();
          message('Deletion could not be completed. Refresh the document list before trying again. If the document was unpublished, it remains unavailable to clients.');
          console.error(error);
        } finally {inputs.forEach(e=>e.disabled=false);}
      });
    });
    row.prepend(pdfBadge());controls.append(previewButton({db,bucket:'vip-documents',path:doc.storage_path,title:doc.title}),toggle,remove);row.append(controls);
    row.append(node('p','Client access'));
    for(const person of members.filter(p=>!p.is_admin)) {
      let assigned=access.find(a=>a.document_id===doc.id&&a.user_id===person.user_id);
      const permissionRow=node('div',undefined,'document-permission-row'),label=node('label',undefined,'check'),box=document.createElement('input'),mode=document.createElement('select');box.type='checkbox';box.checked=!!assigned;
      mode.setAttribute('aria-label','Document permission for '+person.email);for(const [value,text] of [['preview','Preview only'],['download','Preview + download']]){const option=node('option',text);option.value=value;mode.append(option)}
      mode.value=(assigned?assigned.can_download:doc.default_can_download)!==false?'download':'preview';mode.disabled=!box.checked;
      async function saveAccess(){const old=assigned,oldMode=old?.can_download===false?'preview':'download';box.disabled=mode.disabled=true;try{
        if(box.checked){await setDocumentAccess({db,doc,userId:person.user_id,canDownload:mode.value==='download',progress:message});assigned={document_id:doc.id,user_id:person.user_id,can_download:mode.value==='download'};message('Document permission saved: '+(assigned.can_download?'preview + download.':'preview only.'))}
        else{check(await db.from('portal_document_access').delete().eq('document_id',doc.id).eq('user_id',person.user_id));assigned=null;message('Document access removed.')}
      }catch(error){box.checked=!!old;mode.value=oldMode;message(error.message||'Unable to save this document permission.')}finally{box.disabled=false;mode.disabled=!box.checked}}
      box.onchange=saveAccess;mode.onchange=saveAccess;label.append(box,document.createTextNode(person.email+(person.active?'':' (disabled)')));permissionRow.append(label,mode);row.append(permissionRow);
    }
    $('admin-documents').append(row);
  }
}
function bindAdmin() {
  $('upload').addEventListener('submit',event=>{
    event.preventDefault(); action($('upload-button'),async()=>{
      const form=event.target, file=form.elements.file.files[0];
      if(!await validPDF(file)) { message('Please select a valid PDF smaller than 20 MB.'); return; }
      const id=crypto.randomUUID(), path=id+'.pdf';
      check(await db.storage.from('vip-documents').upload(path,file,{contentType:'application/pdf',upsert:false}));
      try { check(await db.from('portal_documents').insert({id,title:form.elements.title.value.trim(),description:form.elements.description.value.trim(),category:form.elements.category.value,version_date:form.elements.version_date.value,is_draft:form.elements.is_draft.checked,storage_path:path,published:false,default_can_download:form.elements.default_access.value==='download'})); }
      catch(error) { await db.storage.from('vip-documents').remove([path]); throw error; }
      if(form.elements.default_access.value==='preview'){try{await prepareDocumentPreview({db,doc:{id,storage_path:path},progress:message})}catch(error){await loadAdmin();message('PDF saved as an unpublished draft. Preview preparation failed: '+error.message);return;}}
      form.reset(); message('PDF uploaded. Assign client access and publish when ready.'); await loadAdmin();
    });
  });
}
async function start() {
  if(!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(config.url) || !config.publishableKey) { message('The VIP Capital client portal is being prepared. Please contact info@vipcapital.eu for document requests.'); return; }
  // An explicit guard prevents accidentally linking the Black Pearl project.
  if(config.url.includes('bibzafctpkekixsevqfx')) throw new Error('VIP Capital requires its own Supabase project.');
  const {createClient} = await import('https://esm.sh/@supabase/supabase-js@2.102.0');
  db=createClient(config.url,config.publishableKey,{auth:{storage:window.sessionStorage,persistSession:true,autoRefreshToken:true,detectSessionInUrl:true,flowType:'implicit'}});
  db.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT'){resetPrivateView();if(page!=='login')location.replace('client-login.html');}});
  const {session}=check(await db.auth.getSession());
  if($('logout')) $('logout').addEventListener('click',()=>action($('logout'),async()=>{check(await db.auth.signOut());location.replace('client-login.html');}));
  if(page==='login') {
    $('login-form').hidden=false;
    if(session) { location.replace('documents.html?v=20261023-vip-mail1'); return; }
    $('login-form').addEventListener('submit',event=>{event.preventDefault();action($('login-button'),async()=>{
      const result=await db.auth.signInWithPassword({email:$('email').value.trim(),password:$('password').value});
      if(result.error){message('Sign-in unsuccessful. Check your email and password, or contact VIP Capital.');return;}
      location.replace('documents.html?v=20261023-vip-mail1');
    });});
  } else if(page==='recovery') {
    $('recovery-form').hidden=false;
    $('recovery-form').addEventListener('submit',event=>{event.preventDefault();action($('recovery-button'),async()=>{
      if(!$('recovery-form').reportValidity())return;
      const response=await fetch(config.url+'/functions/v1/portal-auth',{method:'POST',headers:{'Content-Type':'application/json',apikey:config.publishableKey,Authorization:'Bearer '+config.functionKey},body:JSON.stringify({action:'recovery',email:$('recovery-email').value.trim()})});const result={error:!response.ok};
      const feedback=$('recovery-result');feedback.hidden=false;
      if(result.error){feedback.textContent='We could not process your request. Please wait a moment and try again.';return;}
      feedback.textContent='If this email is eligible for a VIP Capital account, you will receive a password reset email shortly. Check your spam folder and use the link in the newest email.';
      $('recovery-form').hidden=true;
    });});
  } else if(page==='password') {
    if(!session) {message('This invitation or reset link is invalid or has expired. Please contact VIP Capital for a new link.');return;}
    // Remove credentials from the address bar after Supabase has processed the link.
    history.replaceState(null,'',location.pathname);
    $('password-form').hidden=false;
    $('password-form').addEventListener('submit',event=>{event.preventDefault();action($('save-password'),async()=>{
      if($('password').value!==$('confirm').value){message('The passwords do not match.');return;}
      check(await db.auth.updateUser({password:$('password').value})); location.replace('documents.html?v=20261023-vip-mail1');
    });});
  } else if(await authorize()) {
    if($('refresh-submissions')) $('refresh-submissions').addEventListener('click',()=>action($('refresh-submissions'),loadSubmissions));
    if(page==='company') await initCompanyProfile({db,member,check,action,message});
    if(page==='documents') { initClientFile(); const company=await initCompanyProfile({db,member,check,action,message}); companyContext=company; company.subscribe(()=>loadClientFile({db,member,company})); const {bindNda}=await import('./nda.js?v=20261023-vip-mail1');await bindNda({db,member,check,action,message,onSubmitted:loadSubmissions,company}); $('search').addEventListener('input',renderDocuments);$('category').addEventListener('change',renderDocuments);bindClientUpload();await loadDocuments();await loadSubmissions(); }
    if(page==='admin') {const {initAdminWorkspace}=await import('./admin-workspace.js?v=20261023-vip-mail1');initAdminWorkspace();const {bindAccessAdmin}=await import('./access-requests.js?v=20261023-vip-mail1');await bindAccessAdmin({db,check,message,onInvited:async()=>{await loadAdmin();await loadCompanyAdmin({db,check,action,message,members});}});bindAdmin();await loadAdmin();await loadSubmissions();await loadCompanyAdmin({db,check,action,message,members});$('refresh-companies').addEventListener('click',()=>action($('refresh-companies'),()=>loadCompanyAdmin({db,check,action,message,members})));}
  }
}
start().catch(fail);
