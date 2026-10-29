import {confirmSigning} from './signing-confirmation.js?v=20261029-all-signatures2';
import {isIndividual,individualParty,individualFields} from './individual-profile.js?v=20261028-vip-alignment';
async function blobBase64(blob){const bytes=new Uint8Array(await blob.arrayBuffer());let s='';for(let i=0;i<bytes.length;i+=8192)s+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(s)}
import { companyFields } from './company-profile.js?v=20261028-vip-alignment';
const $=id=>document.getElementById(id);
let specs=companyFields;
const dateText=d=>new Intl.DateTimeFormat('en-GB',{timeZone:'Europe/Amsterdam',day:'numeric',month:'long',year:'numeric'}).format(d);
import {createNda,MCNDA_VERSION} from './mcnda-pdf.js?v=20261029-all-signatures2';
export {createNda};
async function imageFile(file){
 if(!file || !['image/png','image/jpeg'].includes(file.type)||file.size>5*1024*1024)throw new Error('Choose a PNG or JPG smaller than 5 MB.');
 const bitmap=await createImageBitmap(file);try{if(bitmap.width*bitmap.height>24000000)throw new Error('This image is too large. Please use a smaller image.');const c=document.createElement('canvas');const scale=Math.min(1,1400/Math.max(bitmap.width,bitmap.height));c.width=Math.round(bitmap.width*scale);c.height=Math.round(bitmap.height*scale);c.getContext('2d').drawImage(bitmap,0,0,c.width,c.height);return c.toDataURL('image/png');}finally{bitmap.close();}
}
export async function bindNda({db,member,check,action,message,onSubmitted,company}){
 const form=$('nda-form'),container=$('nda-fields');let identityReady=false,signed=false,stamp=null,signatureImage=null,review=null,revision=0,stampLoading=false,stampRevision=0,stampPath='',savedAssetsVersion=null;
 const savedConsent=document.createElement('label');savedConsent.hidden=true;savedConsent.innerHTML='<input type="checkbox" id="nda-saved-assets-consent"> I authorize use of my saved signature and company stamp on this MCNDA.';form.insertBefore(savedConsent,$('nda-preview'));
 function renderFields(details={}){container.replaceChildren();specs=isIndividual(details)?[...individualFields,['PASSPORT_NUMBER','Passport number',30,true]]:companyFields;for(const [key,label,max,required] of specs){const wrap=document.createElement('div'),l=document.createElement('label'),input=document.createElement('input');l.htmlFor=key;l.textContent=label+(required?'':' (optional)');input.id=key;input.name=key;input.maxLength=max;input.required=required;if(key==='B_EMAIL'){input.type='email';input.value=member.email;}if(key==='PASSPORT_NUMBER')input.readOnly=true;wrap.append(l,input);container.append(wrap);}}renderFields();
 let readPreviewUrl=null;
 function clearReadPreview(){if(readPreviewUrl)URL.revokeObjectURL(readPreviewUrl);readPreviewUrl=null;if($('nda-read-result'))$('nda-read-result').hidden=true;if($('nda-read-frame'))$('nda-read-frame').src='about:blank';}
 if($('nda-read-button'))$('nda-read-button').addEventListener('click',()=>action($('nda-read-button'),async()=>{
  const profile=company.getProfile(),values=profile?.details?individualParty({...profile.details,...(isIndividual(profile.details)?{PASSPORT_NUMBER:form.elements.PASSPORT_NUMBER?.value||''}:{})}):null;
  if(!values||specs.some(([key,,,required])=>required&&!String(values[key]||'').trim())){message('Complete and save all required company profile details before previewing the MCNDA.');return;}
  clearReadPreview();const current=revision;
  try{
   const blob=await createNda(values,null,null,{draft:true,reference:'Unsigned preview',email:member.email});
   if(current!==revision)return;
   readPreviewUrl=URL.createObjectURL(blob);$('nda-read-frame').src=readPreviewUrl;$('nda-read-download').href=readPreviewUrl;$('nda-read-download').download='VIP Capital_MCNDA_Unsigned_Preview.pdf';$('nda-read-result').hidden=false;$('nda-read-result').scrollIntoView({behavior:'smooth',block:'start'});
  }catch(error){message(error.message.includes('WinAnsi')?'A company detail contains a character that cannot be displayed in this PDF. Please use Latin characters.':error.message);}
 }));
 const canvas=$('nda-signature'),ctx=canvas.getContext('2d');ctx.strokeStyle='#002040';ctx.lineWidth=2.4;ctx.lineCap='round';ctx.lineJoin='round';let drawing=false,last=null;
 function invalidate(){revision++;if(review){URL.revokeObjectURL(review.url);review=null;}$('nda-review').hidden=true;$('nda-frame').src='about:blank';$('nda-confirm').checked=false;}
 form.addEventListener('input',e=>{if(e.target.id!=='nda-confirm')invalidate();});
 function point(e){const r=canvas.getBoundingClientRect();return[(e.clientX-r.left)*canvas.width/r.width,(e.clientY-r.top)*canvas.height/r.height];}
 canvas.addEventListener('pointerdown',e=>{if(e.button!==0)return;e.preventDefault();canvas.setPointerCapture(e.pointerId);drawing=true;last=point(e);invalidate();signatureImage=null;$('nda-signature-file').value='';});
 canvas.addEventListener('pointermove',e=>{if(!drawing)return;const p=point(e);ctx.beginPath();ctx.moveTo(...last);ctx.lineTo(...p);ctx.stroke();last=p;signed=true;});
 for(const ev of ['pointerup','pointercancel','lostpointercapture'])canvas.addEventListener(ev,()=>{drawing=false;});
 $('nda-clear').addEventListener('click',()=>{ctx.clearRect(0,0,canvas.width,canvas.height);signed=false;signatureImage=null;$('nda-signature-file').value='';invalidate();});
 $('nda-signature-file').addEventListener('change',()=>action($('nda-preview'),async()=>{invalidate();signed=false;signatureImage=null;ctx.clearRect(0,0,canvas.width,canvas.height);if(!$('nda-signature-file').files[0])return;try{const data=await imageFile($('nda-signature-file').files[0]);const img=new Image();img.src=data;await img.decode();const s=Math.min(canvas.width/img.width,canvas.height/img.height);ctx.drawImage(img,(canvas.width-img.width*s)/2,(canvas.height-img.height*s)/2,img.width*s,img.height*s);signatureImage=data;signed=true;}catch(e){message(e.message);}}));
 $('nda-stamp').addEventListener('change',async()=>{invalidate();stamp=null;stampPath='';$('nda-stamp-preview').hidden=true;const f=$('nda-stamp').files[0];if(!f)return;const current=++stampRevision;stampLoading=true;$('nda-preview').disabled=true;try{const data=await imageFile(f);if(current!==stampRevision)return;stamp=data;$('nda-stamp-preview').src=data;$('nda-stamp-preview').hidden=false;}catch(e){message(e.message);$('nda-stamp').value='';}finally{stampLoading=false;$('nda-preview').disabled=false;}});
 form.addEventListener('submit',e=>{e.preventDefault();action($('nda-preview'),async()=>{
  if(isIndividual(company.getProfile()?.details)&&!identityReady){message('Upload your signed passport copy in your profile before signing the MCNDA');return;}
  if(!form.reportValidity())return;if(savedAssetsVersion&&!$('nda-saved-assets-consent').checked){message('Please confirm use of your saved signature and stamp for this MCNDA.');return;}if(!signed){message('Please draw your signature or upload a signature image.');return;}if(stampLoading)return;
  invalidate();const current=revision,values=individualParty({...company.getProfile()?.details,...Object.fromEntries(specs.map(([k])=>[k,form.elements[k].value.trim()]))});if(specs.some(([k,,,required])=>required&&!values[k])){message('Please complete all required company details.');return;}
  const id=crypto.randomUUID(),now=new Date();let blob;
  try{blob=await createNda(values,signatureImage||canvas.toDataURL('image/png'),stamp,{now,reference:id,email:member.email});}catch(error){message(error.message.includes('WinAnsi')?'A character cannot be included in the PDF. Please use Latin characters for the company details.':error.message);return;}
  if(current!==revision)return;const url=URL.createObjectURL(blob);review={id,blob,url,values,now,savedAssetsVersion,hasStamp:!!stamp,stampData:stamp,stampPath,profileVersion:company.getProfile()?.version||0,profileId:company.getProfile()?.id||''};$('nda-frame').src=url;$('nda-download').href=url;$('nda-download').download='VIP Capital_MCNDA_Review.pdf';$('nda-review').hidden=false;message('Review all pages of the PDF, then confirm and submit.');$('nda-review').scrollIntoView({behavior:'smooth'});
 });});
 $('nda-submit').addEventListener('click',()=>action($('nda-submit'),async()=>{
  if(!review||!$('nda-confirm').checked){message('Review the PDF and confirm your authority and agreement before submitting.');return;}
  if(dateText(review.now)!==dateText(new Date())){invalidate();message('The date has changed. Please generate a new preview.');return;}
  if(review.savedAssetsVersion){const latest=check(await db.from('portal_signing_profiles').select('version').eq('user_id',member.user_id).maybeSingle());if(latest?.version!==review.savedAssetsVersion){invalidate();await applyProfile(company.getProfile());message('Your saved signing images changed. Please review and confirm a new MCNDA preview.');return;}}
  const current=review,pdfHash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',await current.blob.arrayBuffer()))).map(x=>x.toString(16).padStart(2,'0')).join('');
  const confirmation=await confirmSigning({db,purpose:'mcnda_client',documentId:current.id,pdfHash});if(!confirmation)return;if(review!==current||dateText(current.now)!==dateText(new Date())){invalidate();message('The MCNDA or signature date changed. Generate and review a new PDF before signing.');return;}
  const path=member.user_id+'/'+current.id+'.pdf';if(current.blob.size>20*1024*1024){message('The PDF exceeds 20 MB. Please use smaller images.');return;}
  check(await db.storage.from('vip-client-uploads').upload(path,current.blob,{contentType:'application/pdf',upsert:false}));
  let newStampPath='',savedStampPath=current.stampPath;
  try {
    if(current.stampData&&!savedStampPath){
      newStampPath=member.user_id+'/'+crypto.randomUUID()+'.png';
      const stampBlob=await (await fetch(current.stampData)).blob();
      check(await db.storage.from('vip-company-assets').upload(newStampPath,stampBlob,{contentType:'image/png',upsert:false}));savedStampPath=newStampPath;
    }
    const result=await db.rpc('submit_mcnda_for_approval',{p_pdf:await blobBase64(current.blob),p_attestation:{confirmation_id:confirmation.confirmation_id,confirmation_token:confirmation.confirmation_token,document_template_version:MCNDA_VERSION,account_type:isIndividual(current.values)?'individual':'company',name:current.values.B_REPRESENTATIVE,authority:true,acceptance:true,assets_authorized:!!current.savedAssetsVersion,signing_version:current.savedAssetsVersion||null,reviewed_hash:pdfHash},p_id:current.id,p_details:{...current.values,MCNDA_TEMPLATE_VERSION:MCNDA_VERSION,B_STAMP_PATH:savedStampPath||'',B_PROFILE_ID:current.profileId},p_expected_version:current.profileVersion,p_note:'Completed and electronically signed via the VIP Capital portal. Awaiting explicit VIP Capital countersignature. Template '+MCNDA_VERSION+'. Reference: '+current.id+'. Account: '+member.email+'. Submitted: '+current.now.toISOString()+'. Company stamp: '+(current.hasStamp?'included':'not supplied')+'. '+(isIndividual(current.values)?'Individual signed in a personal capacity and confirmed agreement.':'Representative confirmed authority and agreement.')+(current.savedAssetsVersion?' Saved signing images explicitly authorized for this MCNDA. Signing profile version: '+current.savedAssetsVersion+'.':'')});
    check(result);
  } catch(error){
    await db.storage.from('vip-client-uploads').remove([path]);
    if(newStampPath)await db.storage.from('vip-company-assets').remove([newStampPath]);
    message('Unable to submit. Your MCNDA assignment or company profile may have changed. Refresh your client file and contact VIP Capital if the agreement is no longer assigned.');console.error(error);return;
  }
  await company.refresh();
  $('nda-result-download').href=current.url;$('nda-result-download').download='VIP Capital_MCNDA_Submitted.pdf';$('nda-success').hidden=false;$('nda-review').hidden=true;form.hidden=true;message('Your signed MCNDA has been submitted to VIP Capital for review. You can download it below or from Your shared documents.');await onSubmitted();
 }));
 async function applyProfile(profile){
  identityReady=false;const current=++stampRevision;clearReadPreview();invalidate();ctx.clearRect(0,0,canvas.width,canvas.height);signed=false;signatureImage=null;stamp=null;stampPath='';savedAssetsVersion=null;savedConsent.hidden=true;$('nda-saved-assets-consent').checked=false;
  $('nda-signature-file').value='';$('nda-stamp').value='';
  const personal=isIndividual(profile?.details);const stampInput=$('nda-stamp');for(const el of [stampInput,stampInput.previousElementSibling,stampInput.previousElementSibling?.previousElementSibling,stampInput.nextElementSibling])if(el)el.hidden=personal;form.querySelector('h3').textContent=personal?'1. Personal details':'1. Company details';form.querySelectorAll('h3')[2].textContent=personal?'2. Personal signature':'3. Authorized signature';savedConsent.lastChild.textContent=personal?' I authorize use of my saved signature on this MCNDA.':' I authorize use of my saved signature and company stamp on this MCNDA.';
  $('nda-form-intro').querySelector('p').textContent=personal?'Review your personal details and passport number, then sign the VIP Capital mutual confidentiality agreement in your personal capacity. Review the complete PDF before sharing it with VIP Capital.':'Review your company details, add your company stamp and sign the VIP Capital mutual confidentiality agreement. Review the complete PDF before sharing it with VIP Capital.';
  $('nda-readonly').querySelector('p').textContent=personal?'Read the complete agreement with your saved personal details before adding a signature. This unsigned preview does not sign or submit the MCNDA.':'Read the complete agreement with your saved company details before adding a signature. This unsigned preview does not sign or submit the MCNDA.';
  $('nda-review').querySelector('h3').textContent=personal?'3. Review & submit':'4. Review & submit';
  $('nda-review').querySelector('p').textContent=personal?'Read all eight pages and check your personal details, passport number and signature. This PDF will be shared with VIP Capital when you submit.':'Read all eight pages and check your company details, signature and stamp. This PDF will be shared with VIP Capital when you submit.';
  $('nda-confirm').parentElement.lastChild.textContent=personal?'I have read this MCNDA, agree to its terms, and sign in my personal capacity as the individual identified in the agreement.':'I have read this MCNDA, agree to its terms, and confirm that I am authorized to sign on behalf of the company shown.';
  renderFields(profile?.details||{});for(const [key] of specs)form.elements[key].value=profile?.details[key]||(key==='B_EMAIL'?member.email:'');
  $('nda-stamp-preview').hidden=true;stampLoading=true;$('nda-preview').disabled=true;
  try{
   if(isIndividual(profile?.details)){const identity=check(await db.rpc('individual_identity',{p_user_id:member.user_id,p_request_id:null}));if(current!==stampRevision)return;if(!identity?.passport_number)throw Error('Passport details are unavailable. Contact VIP Capital.');form.elements.PASSPORT_NUMBER.value=identity.passport_number;identityReady=!!identity.copy_path;}
   const assets=check(await db.from('portal_signing_profiles').select('signature,stamp,version').eq('user_id',member.user_id).maybeSingle());if(current!==stampRevision)return;
   if(assets?.signature){const img=new Image();img.src=assets.signature;await img.decode();if(current!==stampRevision)return;const scale=Math.min(canvas.width/img.width,canvas.height/img.height);ctx.drawImage(img,(canvas.width-img.width*scale)/2,(canvas.height-img.height*scale)/2,img.width*scale,img.height*scale);signatureImage=assets.signature;signed=true;}
   if(assets?.stamp&&!personal)stamp=assets.stamp;
   if(assets?.signature||(!personal&&assets?.stamp)){savedAssetsVersion=assets.version;savedConsent.hidden=false;}
   const saved=profile?.details.B_STAMP_PATH;
   if(!personal&&!stamp&&saved){const blob=check(await db.storage.from('vip-company-assets').download(saved));const data=await new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=reject;reader.readAsDataURL(blob);});if(current!==stampRevision)return;stamp=data;stampPath=saved;}
   if(stamp){$('nda-stamp-preview').src=stamp;$('nda-stamp-preview').hidden=false;}
  }catch(error){message('Saved signing images could not be loaded. Refresh your company profile before preparing the MCNDA.');console.error(error);}
  finally{if(current===stampRevision){stampLoading=false;$('nda-preview').disabled=false;}}
 }
 window.addEventListener('vip-identity-updated',()=>applyProfile(company.getProfile()));
 company.subscribe(applyProfile);await applyProfile(company.getProfile());
 window.addEventListener('pagehide',()=>{clearReadPreview();if(review)URL.revokeObjectURL(review.url);});
}
