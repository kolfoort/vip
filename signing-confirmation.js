import {config} from './portal-config.js?v=20261029-all-signatures2';
import {getLanguage} from './portal-language.js?v=20261028-auth-flags';

const copy={
 en:['Confirm your MCNDA signature','Send a one-time code to your registered email address. The code confirms only the exact document you have reviewed.','Send confirmation code','Confirmation code','Confirm and continue','Cancel','The code has been sent. It is valid for 10 minutes.','The code is incorrect, expired or already used. Request a new code if needed.','Wait at least one minute between requests. A maximum of five codes per document per hour is allowed.','Unable to send the code. Please try again later.','Send a new code','Document reference','This email confirmation is not a qualified electronic signature.'],
 nl:['Bevestig uw MCNDA-ondertekening','Stuur een eenmalige code naar uw geregistreerde e-mailadres. De code bevestigt alleen het exacte document dat u heeft gecontroleerd.','Bevestigingscode versturen','Bevestigingscode','Bevestigen en doorgaan','Annuleren','De code is verstuurd en is 10 minuten geldig.','De code is onjuist, verlopen of al gebruikt. Vraag zo nodig een nieuwe code aan.','Wacht minimaal één minuut tussen aanvragen. Er zijn maximaal vijf codes per document per uur toegestaan.','De code kan niet worden verstuurd. Probeer het later opnieuw.','Nieuwe code versturen','Documentreferentie','Deze e-mailbevestiging is geen gekwalificeerde elektronische handtekening.'],
 de:['Bestätigen Sie Ihre MCNDA-Unterzeichnung','Senden Sie einen Einmalcode an Ihre registrierte E-Mail-Adresse. Der Code bestätigt nur das genaue Dokument, das Sie geprüft haben.','Bestätigungscode senden','Bestätigungscode','Bestätigen und fortfahren','Abbrechen','Der Code wurde gesendet und ist 10 Minuten gültig.','Der Code ist falsch, abgelaufen oder bereits verwendet. Fordern Sie bei Bedarf einen neuen Code an.','Warten Sie zwischen Anfragen mindestens eine Minute. Es sind höchstens fünf Codes pro Dokument und Stunde zulässig.','Der Code kann nicht gesendet werden. Versuchen Sie es später erneut.','Neuen Code senden','Dokumentreferenz','Diese E-Mail-Bestätigung ist keine qualifizierte elektronische Signatur.'],
 es:['Confirme la firma de su MCNDA','Envíe un código de un solo uso a su dirección de correo registrada. El código confirma únicamente el documento exacto que ha revisado.','Enviar código de confirmación','Código de confirmación','Confirmar y continuar','Cancelar','El código se ha enviado y es válido durante 10 minutos.','El código es incorrecto, ha caducado o ya se ha utilizado. Solicite uno nuevo si es necesario.','Espere al menos un minuto entre solicitudes. Se permite un máximo de cinco códigos por documento y hora.','No se puede enviar el código. Inténtelo más tarde.','Enviar un nuevo código','Referencia del documento','Esta confirmación por correo no es una firma electrónica cualificada.'],
 ar:['تأكيد توقيع اتفاقية MCNDA','أرسل رمز استخدام واحد إلى بريدك الإلكتروني المسجّل. يؤكد الرمز المستند المحدد الذي راجعته فقط.','إرسال رمز التأكيد','رمز التأكيد','تأكيد ومتابعة','إلغاء','تم إرسال الرمز وهو صالح لمدة 10 دقائق.','الرمز غير صحيح أو منتهي الصلاحية أو مستخدم بالفعل. اطلب رمزًا جديدًا عند الحاجة.','انتظر دقيقة واحدة على الأقل بين الطلبات. يُسمح بخمسة رموز لكل مستند كحد أقصى في الساعة.','تعذّر إرسال الرمز. يُرجى المحاولة لاحقًا.','إرسال رمز جديد','مرجع المستند','هذا التأكيد بالبريد الإلكتروني ليس توقيعًا إلكترونيًا مؤهلًا.']
};
const make=(tag,text)=>{const n=document.createElement(tag);if(text!==undefined)n.textContent=text;return n};
export async function confirmSigning({db,purpose,documentId,pdfHash,revision,reviewToken,documentName='MCNDA',pdfBytes}){
 const language=getLanguage(),t=(copy[language]||copy.en).map(value=>value.replaceAll('MCNDA',documentName));
 const dialog=make('dialog');dialog.dataset.i18nSkip='';dialog.lang=language;dialog.dir=language==='ar'?'rtl':'ltr';dialog.style.cssText='max-width:560px;width:calc(100% - 40px);box-sizing:border-box;border:1px solid #bd9a45;border-top:4px solid #bd9a45;padding:28px;color:#002040;background:#fff;max-height:90vh;overflow:auto';
 const heading=make('h2',t[0]);heading.id='signing-confirmation-heading';dialog.setAttribute('aria-labelledby',heading.id);
 const intro=make('p',t[1]),ref=make('p',t[11]+': '+documentId),fingerprint=make('p','SHA-256: '+pdfHash),send=make('button',t[2]),form=make('form'),label=make('label',t[3]),input=make('input'),verify=make('button',t[4]),cancel=make('button',t[5]),status=make('p'),note=make('p',t[12]);
 ref.className=fingerprint.className=note.className='meta';ref.dir=fingerprint.dir='ltr';fingerprint.style.overflowWrap='anywhere';
 input.id='signing-confirmation-code';label.htmlFor=input.id;input.type='text';input.inputMode='numeric';input.autocomplete='one-time-code';input.pattern='[0-9]{8}';input.maxLength=8;input.required=true;input.disabled=true;input.dir='ltr';
 status.setAttribute('role','status');status.setAttribute('aria-live','polite');verify.type='submit';verify.disabled=true;cancel.type=send.type='button';cancel.className='secondary';cancel.style.marginInlineStart='12px';
 form.append(label,input,verify,cancel);dialog.append(heading,intro,ref,fingerprint);
 const reviewLabels={en:'I have reviewed this complete PDF, including its signatures and attachments.',nl:'Ik heb deze volledige PDF gecontroleerd, inclusief de handtekeningen en bijlagen.',de:'Ich habe diese vollständige PDF einschließlich Unterschriften und Anlagen geprüft.',es:'He revisado este PDF completo, incluidas las firmas y los anexos.',ar:'راجعت ملف PDF هذا بالكامل، بما في ذلك التوقيعات والمرفقات.'};
 let reviewed=null,reviewUrl=null;
 if(pdfBytes){const frame=make('iframe');reviewUrl=URL.createObjectURL(new Blob([pdfBytes],{type:'application/pdf'}));frame.src=reviewUrl;frame.title=documentName;frame.style.cssText='width:100%;height:45vh;min-height:250px;border:1px solid #ccd7e4';const download=make('a',documentName+' PDF');download.href=reviewUrl;download.target='_blank';download.rel='noopener';const reviewLabel=make('label');reviewed=make('input');reviewed.type='checkbox';reviewLabel.append(reviewed,document.createTextNode(' '+(reviewLabels[language]||reviewLabels.en)));reviewLabel.className='check';reviewed.onchange=()=>{if(!busy)send.disabled=!reviewed.checked||Date.now()<retryAt};dialog.append(frame,download,reviewLabel);send.disabled=true;}
 dialog.append(send,form,status,note);document.body.append(dialog);dialog.showModal();
 let challenge=null,timer=null,busy=false,closed=false,retryAt=0;
 input.addEventListener('input',()=>{input.value=input.value.replace(/[٠-٩]/g,c=>String(c.charCodeAt(0)-1632)).replace(/[۰-۹]/g,c=>String(c.charCodeAt(0)-1776))});
 return await new Promise(resolve=>{
  function close(value){if(closed)return;closed=true;if(timer)clearTimeout(timer);dialog.close();dialog.remove();if(reviewUrl)URL.revokeObjectURL(reviewUrl);resolve(value)}
  cancel.onclick=()=>{if(!busy)close(null)};
  dialog.addEventListener('cancel',e=>{e.preventDefault();if(!busy)close(null)});
  send.onclick=async()=>{
   if(busy||(reviewed&&!reviewed.checked))return;busy=true;send.disabled=true;verify.disabled=true;input.disabled=true;cancel.disabled=true;challenge=null;input.value='';
   try{
    const {data,error}=await db.auth.getSession();if(error||!data.session)throw Error('Sign in required');
    const r=await fetch(config.url+'/functions/v1/signing-confirmation',{method:'POST',headers:{'Content-Type':'application/json',apikey:config.publishableKey,Authorization:'Bearer '+config.functionKey,'x-portal-authorization':'Bearer '+data.session.access_token},body:JSON.stringify({purpose,document_id:documentId,document_hash:pdfHash,revision,review_token:reviewToken})});
    if(!r.ok){status.textContent=r.status===429?t[8]:t[9];retryAt=Date.now()+60000;timer=setTimeout(()=>{send.disabled=!!(reviewed&&!reviewed.checked)},60000);return}
    const result=await r.json();challenge=result.challenge_id;status.textContent=t[6];send.textContent=t[10];input.disabled=false;verify.disabled=false;input.focus();retryAt=Date.now()+60000;timer=setTimeout(()=>{send.disabled=!!(reviewed&&!reviewed.checked)},60000);
   }catch{status.textContent=t[9];send.disabled=false}finally{busy=false;cancel.disabled=false}
  };
  form.onsubmit=async e=>{
   e.preventDefault();if(busy||!challenge||(reviewed&&!reviewed.checked)||!form.reportValidity())return;busy=true;verify.disabled=true;send.disabled=true;cancel.disabled=true;
   try{const r=await db.rpc('verify_signing_confirmation',{p_id:challenge,p_code:input.value.trim()});input.value='';if(r.error||!r.data?.verified){status.textContent=t[7];return}close(r.data)}
   catch{status.textContent=t[7]}finally{busy=false;verify.disabled=false;cancel.disabled=false;send.disabled=Date.now()<retryAt||!!(reviewed&&!reviewed.checked);if(!closed)input.focus()}
  };
 });
}

export async function hashPDF(bytes){return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))).map(x=>x.toString(16).padStart(2,'0')).join('')}
export async function confirmAgreement({db,kind,agreement,admin=false,bytes,pdfHash,reviewToken}){
 const hash=bytes?await hashPDF(bytes):pdfHash;if(!hash)throw Error('Preview the complete PDF before signing.');
 const names={commission:'Commission Agreement',spa:'SPA',jv:'JVA',fco:'FCO'};
 const result=await confirmSigning({db,purpose:kind+(admin?'_admin':'_client'),documentId:agreement.id,pdfHash:hash,revision:agreement.revision,reviewToken,documentName:names[kind],pdfBytes:admin?bytes:null});
 return result?{confirmation_id:result.confirmation_id,confirmation_token:result.confirmation_token,confirmation_pdf_hash:hash}:null;
}
