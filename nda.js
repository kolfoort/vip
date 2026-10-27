async function blobBase64(blob){const bytes=new Uint8Array(await blob.arrayBuffer());let s='';for(let i=0;i<bytes.length;i+=8192)s+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(s)}
import { PDFDocument, StandardFonts, rgb } from './assets/vendor/pdf-lib.esm.min.js';
import { companyFields } from './company-profile.js?v=20261027-viproles1';
const $=id=>document.getElementById(id);
const specs=companyFields;
const dateText=d=>new Intl.DateTimeFormat('en-GB',{timeZone:'Europe/Amsterdam',day:'numeric',month:'long',year:'numeric'}).format(d);
function fit(page,text,font,rect,size=9){let [x,y,r,t]=rect;while(font.widthOfTextAtSize(text,size)>r-x && size>6)size-=.25;if(font.widthOfTextAtSize(text,size)>r-x)throw new Error('A company detail is too long to fit. Please shorten the address or company name.');font.encodeText(text);page.drawText(text,{x,y:y+2,size,font,color:rgb(0,.125,.25)});}
import {terms} from './mcnda-terms.js';
export async function createNda(values,signature,stamp,{now=new Date(),reference='',email='',draft=false}={}){
 const pdf=await PDFDocument.create(),regular=await pdf.embedFont(StandardFonts.Helvetica),bold=await pdf.embedFont(StandardFonts.HelveticaBold),navy=rgb(0,32/255,64/255),gold=rgb(189/255,154/255,69/255);
 const response=await fetch('portal-logo.png');if(!response.ok)throw Error('VIP logo unavailable');const logo=await pdf.embedPng(await response.arrayBuffer());
 const day=dateText(now);let page,y;
 function newPage(){page=pdf.addPage([595.28,841.89]);page.drawImage(logo,{x:43,y:748,width:145,height:81});for(const [i,line]of ['VIP CAPITAL','Oude Apeldoornseweg 45-067','7333 NR Apeldoorn · The Netherlands','info@vipcapital.eu · +31 (0)85-200 9082'].entries())page.drawText(line,{x:313,y:803-i*12,size:i?8:9,font:i?regular:bold,color:navy});page.drawLine({start:{x:43,y:741},end:{x:552,y:741},thickness:1.5,color:gold});y=718;}
 function lines(text,font,size,width){const out=[];let line='';for(const word of text.split(/\s+/)){const next=line?line+' '+word:word;if(font.widthOfTextAtSize(next,size)>width&&line){out.push(line);line=word}else line=next}if(line)out.push(line);return out}
 function paragraph(text,heading=false){const font=heading?bold:regular,size=heading?11:9.5;for(const line of lines(text,font,size,509)){if(y<65)newPage();page.drawText(line,{x:43,y,size,font,color:navy});y-=heading?16:13.4}y-=heading?7:6;}
 newPage();paragraph('MUTUAL CONFIDENTIALITY, NON-DISCLOSURE & NON-CIRCUMVENTION AGREEMENT',true);paragraph('PRIVATE & CONFIDENTIAL · MCNDA',true);paragraph('Effective date: '+day);paragraph('Portal reference: '+reference);paragraph('PARTY A · VIP CAPITAL',true);paragraph('Oude Apeldoornseweg 45-067, 7333 NR Apeldoorn, The Netherlands. Represented by J.P. Kolfoort, MD.');paragraph('PARTY B · '+values.B_COMPANY,true);
 for(const [label,key] of [['Registered address','B_ADDRESS'],['Registration','B_REGISTRATION'],['Country','B_COUNTRY'],['Representative','B_REPRESENTATIVE'],['Title','B_TITLE'],['Email','B_EMAIL'],['Telephone','B_PHONE'],['Website','B_WEBSITE']])if(values[key])paragraph(label+': '+values[key]);
 paragraph('The Parties identified above agree to the following terms.');newPage();
 for(const t of terms){const text=t.replaceAll('[EFFECTIVE DATE]',day);paragraph(text,text.length<110&&text===text.toUpperCase())}
 newPage();paragraph('EXECUTION',true);paragraph('IN WITNESS WHEREOF, the Parties, intending to be legally bound, execute the Agreement identified by the reference above.');
 paragraph('PARTY A · VIP CAPITAL',true);paragraph('J.P. Kolfoort · Managing Director (MD)');
 page.drawRectangle({x:43,y:475,width:509,height:140,borderWidth:.5,borderColor:gold});page.drawText('Pending explicit final administrator approval',{x:55,y:588,size:9,font:regular,color:navy});
 y=443;paragraph('PARTY B · '+values.B_COMPANY,true);paragraph(values.B_REPRESENTATIVE+' · '+values.B_TITLE);paragraph(values.B_ADDRESS);
 const boxes=[{x:43,y:232,w:240,h:115,label:'Authorized signature'},{x:310,y:232,w:242,h:115,label:'Company stamp'}];for(const box of boxes){page.drawText(box.label,{x:box.x,y:358,size:9,font:bold,color:navy});page.drawRectangle({x:box.x,y:box.y,width:box.w,height:box.h,borderWidth:.5,borderColor:gold})}
 for(const [data,box]of [[signature,boxes[0]],[stamp,boxes[1]]])if(data){const img=await pdf.embedPng(data),scale=Math.min((box.w-20)/img.width,(box.h-20)/img.height);page.drawImage(img,{x:box.x+(box.w-img.width*scale)/2,y:box.y+(box.h-img.height*scale)/2,width:img.width*scale,height:img.height*scale})}
 y=211;paragraph('Date: '+day);paragraph('Account: '+email);paragraph('Reference: '+reference);paragraph(draft?'UNSIGNED PREVIEW · Not submitted':'Client signature submitted for final VIP Capital approval.');
 const pages=pdf.getPages();for(const [i,p]of pages.entries()){p.drawText('VIP CAPITAL · PRIVATE & CONFIDENTIAL',{x:43,y:35,size:7,font:regular,color:navy});p.drawText((i+1)+' / '+pages.length,{x:515,y:35,size:7,font:regular,color:navy});if(draft)p.drawText('UNSIGNED PREVIEW',{x:240,y:35,size:7,font:bold,color:navy})}
 pdf.setTitle('VIP Capital MCNDA · '+values.B_COMPANY);pdf.setCreationDate(now);return new Blob([await pdf.save()],{type:'application/pdf'});
}
async function imageFile(file){
 if(!file || !['image/png','image/jpeg'].includes(file.type)||file.size>5*1024*1024)throw new Error('Choose a PNG or JPG smaller than 5 MB.');
 const bitmap=await createImageBitmap(file);try{if(bitmap.width*bitmap.height>24000000)throw new Error('This image is too large. Please use a smaller image.');const c=document.createElement('canvas');const scale=Math.min(1,1400/Math.max(bitmap.width,bitmap.height));c.width=Math.round(bitmap.width*scale);c.height=Math.round(bitmap.height*scale);c.getContext('2d').drawImage(bitmap,0,0,c.width,c.height);return c.toDataURL('image/png');}finally{bitmap.close();}
}
export async function bindNda({db,member,check,action,message,onSubmitted,company}){
 const form=$('nda-form'),container=$('nda-fields');let signed=false,stamp=null,signatureImage=null,review=null,revision=0,stampLoading=false,stampRevision=0,stampPath='',savedAssetsVersion=null;
 const savedConsent=document.createElement('label');savedConsent.hidden=true;savedConsent.innerHTML='<input type="checkbox" id="nda-saved-assets-consent"> I authorize use of my saved signature and company stamp on this MCNDA.';form.insertBefore(savedConsent,$('nda-preview'));
 for(const [key,label,max,required] of specs){const wrap=document.createElement('div'),l=document.createElement('label'),input=document.createElement('input');l.htmlFor=key;l.textContent=label+(required?'':' (optional)');input.id=key;input.name=key;input.maxLength=max;input.required=required;if(key==='B_EMAIL'){input.type='email';input.value=member.email;}wrap.append(l,input);container.append(wrap);}
 let readPreviewUrl=null;
 function clearReadPreview(){if(readPreviewUrl)URL.revokeObjectURL(readPreviewUrl);readPreviewUrl=null;if($('nda-read-result'))$('nda-read-result').hidden=true;if($('nda-read-frame'))$('nda-read-frame').src='about:blank';}
 if($('nda-read-button'))$('nda-read-button').addEventListener('click',()=>action($('nda-read-button'),async()=>{
  const profile=company.getProfile(),values=profile?.details;
  if(!values||specs.some(([key,,,required])=>required&&!String(values[key]||'').trim())){message('Complete and save all required company profile details before previewing the MCNDA.');return;}
  clearReadPreview();const current=revision;
  try{
   const blob=await createNda(values,null,null,{draft:true,reference:'Unsigned preview',email:member.email,loadTemplate:async()=>{const result=await db.storage.from('vip-documents').download('nda-template-v20261020.pdf');if(result.error)throw new Error('The MCNDA template could not be loaded. Please contact VIP Capital.');return result.data.arrayBuffer();}});
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
  if(!form.reportValidity())return;if(savedAssetsVersion&&!$('nda-saved-assets-consent').checked){message('Please confirm use of your saved signature and stamp for this MCNDA.');return;}if(!signed){message('Please draw your signature or upload a signature image.');return;}if(stampLoading)return;
  invalidate();const current=revision,values=Object.fromEntries(specs.map(([k])=>[k,form.elements[k].value.trim()]));if(specs.some(([k,,,required])=>required&&!values[k])){message('Please complete all required company details.');return;}
  const id=crypto.randomUUID(),now=new Date();let blob;
  try{blob=await createNda(values,signatureImage||canvas.toDataURL('image/png'),stamp,{now,reference:id,email:member.email,loadTemplate:async()=>{const result=await db.storage.from('vip-documents').download('nda-template-v20261020.pdf');if(result.error)throw new Error('The private MCNDA template has not been enabled for your account. Please contact VIP Capital.');return result.data.arrayBuffer();}});}catch(error){message(error.message.includes('WinAnsi')?'A character cannot be included in the PDF. Please use Latin characters for the company details.':error.message);return;}
  if(current!==revision)return;const url=URL.createObjectURL(blob);review={id,blob,url,values,now,savedAssetsVersion,hasStamp:!!stamp,stampData:stamp,stampPath,profileVersion:company.getProfile()?.version||0,profileId:company.getProfile()?.id||''};$('nda-frame').src=url;$('nda-download').href=url;$('nda-download').download='VIP Capital_MCNDA_Review.pdf';$('nda-review').hidden=false;message('Review all pages of the PDF, then confirm and submit.');$('nda-review').scrollIntoView({behavior:'smooth'});
 });});
 $('nda-submit').addEventListener('click',()=>action($('nda-submit'),async()=>{
  if(!review||!$('nda-confirm').checked){message('Review the PDF and confirm your authority and agreement before submitting.');return;}
  if(dateText(review.now)!==dateText(new Date())){invalidate();message('The date has changed. Please generate a new preview.');return;}
  if(review.savedAssetsVersion){const latest=check(await db.from('portal_signing_profiles').select('version').eq('user_id',member.user_id).maybeSingle());if(latest?.version!==review.savedAssetsVersion){invalidate();await applyProfile(company.getProfile());message('Your saved signing images changed. Please review and confirm a new MCNDA preview.');return;}}
  const current=review,path=member.user_id+'/'+current.id+'.pdf';if(current.blob.size>20*1024*1024){message('The PDF exceeds 20 MB. Please use smaller images.');return;}
  check(await db.storage.from('vip-client-uploads').upload(path,current.blob,{contentType:'application/pdf',upsert:false}));
  let newStampPath='',savedStampPath=current.stampPath;
  try {
    if(current.stampData&&!savedStampPath){
      newStampPath=member.user_id+'/'+crypto.randomUUID()+'.png';
      const stampBlob=await (await fetch(current.stampData)).blob();
      check(await db.storage.from('vip-company-assets').upload(newStampPath,stampBlob,{contentType:'image/png',upsert:false}));savedStampPath=newStampPath;
    }
    const result=await db.rpc('submit_mcnda_for_approval',{p_id:current.id,p_details:{...current.values,B_STAMP_PATH:savedStampPath||'',B_PROFILE_ID:current.profileId},p_expected_version:current.profileVersion,p_pdf:await blobBase64(current.blob),p_attestation:{name:current.values.B_REPRESENTATIVE,authority:true,acceptance:true,assets_authorized:!!current.savedAssetsVersion,signing_version:current.savedAssetsVersion||null,reviewed_hash:Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',await current.blob.arrayBuffer()))).map(x=>x.toString(16).padStart(2,'0')).join('')},p_note:'Client signed; awaiting explicit VIP Capital administrator approval. Template VIP-2026-10-23. Reference: '+current.id+'. Account: '+member.email+'. Submitted: '+current.now.toISOString()+'. Company stamp: '+(current.hasStamp?'included':'not supplied')+'. Representative confirmed authority and agreement.'+(current.savedAssetsVersion?' Saved signing images explicitly authorized for this MCNDA. Signing profile version: '+current.savedAssetsVersion+'.':'')});
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
  const current=++stampRevision;clearReadPreview();invalidate();ctx.clearRect(0,0,canvas.width,canvas.height);signed=false;signatureImage=null;stamp=null;stampPath='';savedAssetsVersion=null;savedConsent.hidden=true;$('nda-saved-assets-consent').checked=false;
  $('nda-signature-file').value='';$('nda-stamp').value='';
  for(const [key] of specs)form.elements[key].value=profile?.details[key]||(key==='B_EMAIL'?member.email:'');
  $('nda-stamp-preview').hidden=true;stampLoading=true;$('nda-preview').disabled=true;
  try{
   const assets=check(await db.from('portal_signing_profiles').select('signature,stamp,version').eq('user_id',member.user_id).maybeSingle());if(current!==stampRevision)return;
   if(assets?.signature){const img=new Image();img.src=assets.signature;await img.decode();if(current!==stampRevision)return;const scale=Math.min(canvas.width/img.width,canvas.height/img.height);ctx.drawImage(img,(canvas.width-img.width*scale)/2,(canvas.height-img.height*scale)/2,img.width*scale,img.height*scale);signatureImage=assets.signature;signed=true;}
   if(assets?.stamp)stamp=assets.stamp;
   if(assets?.signature||assets?.stamp){savedAssetsVersion=assets.version;savedConsent.hidden=false;}
   const saved=profile?.details.B_STAMP_PATH;
   if(!stamp&&saved){const blob=check(await db.storage.from('vip-company-assets').download(saved));const data=await new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=reject;reader.readAsDataURL(blob);});if(current!==stampRevision)return;stamp=data;stampPath=saved;}
   if(stamp){$('nda-stamp-preview').src=stamp;$('nda-stamp-preview').hidden=false;}
  }catch(error){message('Saved signing images could not be loaded. Refresh your company profile before preparing the MCNDA.');console.error(error);}
  finally{if(current===stampRevision){stampLoading=false;$('nda-preview').disabled=false;}}
 }
 company.subscribe(applyProfile);await applyProfile(company.getProfile());
 window.addEventListener('pagehide',()=>{clearReadPreview();if(review)URL.revokeObjectURL(review.url);});
}
